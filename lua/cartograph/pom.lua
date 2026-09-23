-- pom.lua — THE MAVEN BUILD LAYER: a POM as a DIALECT of XML data (CART-1051).
--
-- USER (2026-09-23): "Got my hands on apps using maven, so we can work with build systems too";
-- "Do the XML, I think we'll have to treat it like any other extensible data format". So a
-- `pom.xml` is read by the one generic reader (`xmlvalue`) and this file is ONLY the dialect:
-- what Maven's model builder does to those documents before any plugin runs.
--
-- ── THE FOUR RELATIONS, KEPT APART (a POM tree is not one graph) ────────────────────
--   INHERITANCE   child -> parent: `<parent>` found at `relativePath` (default `../pom.xml`,
--                 empty = repository only), else among the tree's POMs by coordinates (what
--                 the reactor's workspace reader does), else a FRONTIER named by its GAV.
--   AGGREGATION   aggregator -> module: `<modules>`; NOT inherited, and a profile may add some.
--   INTERPOLATION `${x}` against the effective model — a SCOPE lookup, holes kept by class.
--   LINKING       a version-less dependency -> the `dependencyManagement` entry that supplies
--                 it, through the lineage and through imported BOMs (`scope=import`).
-- Inheritance and aggregation usually coincide and are DIFFERENT (a module's parent need not
-- aggregate it); a tree with only one of them is the case that proves it.
--
-- ── WHAT MAVEN DOES, IN ITS ORDER (DefaultModelBuilder, 3.x) ──────────────────────
--   1. per lineage POM: inject its ACTIVE PROFILES (profile dominant);
--   2. inheritance assembly, child dominant: properties by key; dependencies, managed
--      dependencies, plugins, executions, repositories BY KEY (child's first, then the
--      parent's extras); everything else recursively, child wins. NOT inherited: artifactId,
--      packaging, modules, name, prerequisites, profiles.
--   3. interpolation of the WHOLE model (packaging included — hadoop writes
--      `<packaging>${packagingType}</packaging>` and sets it per profile);
--   4. BOM import, then management injection (a dependency's absent fields from its entry).
-- ⚠ OUT OF SCOPE, SAID: url/scm path appending on inheritance; plugin CONFIGURATION merging
-- beyond the generic rule (combine.children/combine.self are not honoured); lifecycle-bound
-- default plugins; the super POM beyond `build.*` directory defaults.
--
-- ── PROFILES ARE VANTAGES, NOT DEFAULTS ─────────────────────────────────────────
-- A profile activated by jdk/os/property is decided by an ENVIRONMENT this reader does not
-- have. The VANTAGE names it: `{ profiles = {id=true|false}, props = {user -D props},
-- sys = {system properties}, jdk = '21', os = {name, family, arch, version} }`. `sys` is Maven's
-- SYSTEM properties (the JVM's java.*/os.*/user.*): they decide property activation and
-- interpolate AFTER the model's own properties, as Maven orders them (user > model > system). What the vantage cannot decide is NOT applied and
-- is LISTED (`undecided`): the effective model is then a lower bound and says so. A `file`
-- activation IS decided — the file is in the analysed tree. `activeByDefault` holds only when
-- no other profile of that POM is active.
--
-- ── HOLES ARE CLASSIFIED, NEVER GUESSED ─────────────────────────────────────────
-- An unresolved `${x}` stays literal (as Maven leaves it) with a CLASS:
--   basedir   the checkout location (a vantage fact)       env/settings/system/maven  ditto
--   beyond    not in the tree, and the lineage ends at an external parent that may define it
--   profile   defined only inside a profile this vantage did not apply
--   late      inside a plugin's <configuration>: Maven leaves it literal and the MOJO evaluates it
--             at execution, where -D and properties set by earlier mojos exist (and
--             `project.artifact.*`, made by the build) — the static model cannot decide it
--   undefined none of the above, in a position Maven reads while BUILDING THE MODEL — THE FINDING
-- THE ANALYSED TREE CAN SELECT, IT CANNOT SUPPLY: nothing here fetches a parent or runs Maven.

local M = {}

local X = require 'cartograph.xmlvalue'

-- ── kv helpers ─────────────────────────────────────────────────────────────────────
local function get(v, k) return type(v) == 'table' and v.o and v.o[k] or nil end
local function arr(v)
    if v == nil or (type(v) == 'string' and not v:find('[^ \t\r\n]')) then return {} end
    if type(v) == 'table' and v.a then return v.a end
    return { v }
end
local function str(v) return type(v) == 'string' and v or nil end
local function obj() return { o = {}, keys = {} } end
local function put(t, k, v)
    if t.o[k] == nil then t.keys[#t.keys + 1] = k end
    t.o[k] = v
end
local function pack(list)
    if #list == 0 then return nil end
    if #list == 1 then return list[1] end
    return { a = list }
end
local function copy(v)
    if type(v) ~= 'table' then return v end
    if v.o then
        local t = obj()
        for _, k in ipairs(v.keys) do put(t, k, copy(v.o[k])) end
        return t
    end
    if v.a then local a = {}; for i, x in ipairs(v.a) do a[i] = copy(x) end; return { a = a } end
    return v
end
local function as_obj(v) if type(v) == 'table' and v.o then return v end return obj() end
M._get, M._arr = get, arr

local function readf(p) local fd = io.open(p, 'rb'); if not fd then return nil end; local s = fd:read('*a'); fd:close(); return s end

local function dirname(rel) return rel:match('^(.*)/[^/]*$') or '' end

-- a root-relative path from a dir-relative one, `..` resolved; nil when it leaves the root
local function join(dir, rel)
    local parts = {}
    for seg in ((dir ~= '' and (dir .. '/') or '') .. rel):gmatch('[^/]+') do
        if seg == '..' then
            if #parts == 0 then return nil end
            table.remove(parts)
        elseif seg ~= '.' then parts[#parts + 1] = seg end
    end
    return table.concat(parts, '/')
end
M._join = join

-- ── KEYS: how Maven identifies an entry of a list it merges ────────────────────────
local function dep_key(d)
    return table.concat({ str(get(d, 'groupId')) or '', str(get(d, 'artifactId')) or '',
        str(get(d, 'type')) or 'jar', str(get(d, 'classifier')) or '' }, ':')
end
local function plugin_key(p)
    return (str(get(p, 'groupId')) or 'org.apache.maven.plugins') .. ':' .. (str(get(p, 'artifactId')) or '')
end
local function id_key(x) return str(get(x, 'id')) or 'default' end
M.dep_key, M.plugin_key = dep_key, plugin_key

-- a keyed list sits at <container>.<item>: the item, its key, and HOW a same-key pair combines.
-- ★ READ FROM THE JARS (javap on the system Maven's merger classes), after the oracle join caught
-- the field-wise guess: dependencies, managed dependencies and repositories use the BASE list
-- merge — a same-key entry from the dominant side REPLACES the whole element, nothing is merged
-- field by field (a child's version-less, scope-less `hadoop-annotations` does NOT pick up its
-- parent's `provided`). Only plugins and executions are merged field-wise (overridden mergers).
local KEYED = {
    ['dependencies'] = { 'dependency', dep_key, 'replace' },
    ['dependencyManagement.dependencies'] = { 'dependency', dep_key, 'replace' },
    ['build.plugins'] = { 'plugin', plugin_key, 'merge' },
    ['build.pluginManagement.plugins'] = { 'plugin', plugin_key, 'merge' },
    ['reporting.plugins'] = { 'plugin', plugin_key, 'merge' },
    ['repositories'] = { 'repository', id_key, 'replace' },
    ['pluginRepositories'] = { 'pluginRepository', id_key, 'replace' },
    -- inside a plugin (the path is relative to the plugin entry)
    ['plugin.executions'] = { 'execution', id_key, 'merge' },
    ['plugin.dependencies'] = { 'dependency', dep_key, 'replace' },
}
-- a list merged as a SET of strings (profile injection appends modules)
local UNION = { ['modules'] = 'module' }

local merge

-- ModelMerger's list merge. The TARGET is the model being built into — the CHILD during
-- inheritance (which is also the dominant side), the MODEL during profile injection (where the
-- profile dominates): `lead` says which side is the target. Target entries keep their order (a
-- duplicate key keeps its FIRST place, the later value — a LinkedHashMap); source entries with a
-- new key follow; a same-key source entry wins only when the source is dominant. When the source
-- list is empty the target list is kept as it is, duplicates and all.
local function merge_keyed(dom, rec, item, keyf, mode, path_of_item, lead)
    local tgt, src = arr(get(dom, item)), arr(get(rec, item))
    local src_dominant = false
    if lead == 'rec' then tgt, src, src_dominant = src, tgt, true end
    local t = obj()
    if #src == 0 then
        local v = pack(vim.deepcopy(tgt))
        if v ~= nil then put(t, item, v) end
        return t
    end
    local out, index = {}, {}
    for _, e in ipairs(tgt) do
        local k = keyf(e)
        if index[k] then out[index[k]] = e else out[#out + 1] = e; index[k] = #out end
    end
    for _, e in ipairs(src) do
        local k = keyf(e)
        local i = index[k]
        if not i then out[#out + 1] = copy(e); index[k] = #out
        elseif mode == 'merge' then
            out[i] = src_dominant and merge(e, out[i], path_of_item, lead) or merge(out[i], e, path_of_item, lead)
        elseif src_dominant then out[i] = copy(e) end
    end
    local v = pack(out)
    if v ~= nil then put(t, item, v) end
    return t
end

--- MERGE `dom` (dominant) over `rec` (recessive) at model path `path`; `lead` names the TARGET
--- side whose list order leads ('dom' for inheritance, 'rec' for profile injection).
function merge(dom, rec, path, lead)
    lead = lead or 'dom'
    if rec == nil then return copy(dom) end
    if dom == nil then return copy(rec) end
    -- ⚠ AN EMPTY ELEMENT CONTRIBUTES NOTHING: `<properties/>` (and, after the dialect's trim, a
    -- whitespace-only one) must not erase the other side's object — hadoop's
    -- client-check-invariants has exactly that, and it wiped all 178 inherited properties
    if type(dom) == 'string' and not dom:find('[^ \t\r\n]') and type(rec) == 'table' then return copy(rec) end
    if type(dom) ~= 'table' or not dom.o then return copy(dom) end
    if type(rec) ~= 'table' or not rec.o then return copy(dom) end
    local keyed = KEYED[path]
    if keyed then return merge_keyed(dom, rec, keyed[1], keyed[2], keyed[3], keyed[1] == 'plugin' and 'plugin' or nil, lead) end
    local union = UNION[path]
    if union then
        local out, seen = {}, {}
        for _, side in ipairs(lead == 'rec' and { rec, dom } or { dom, rec }) do
            for _, m in ipairs(arr(get(side, union))) do
                if not seen[m] then seen[m] = true; out[#out + 1] = m end
            end
        end
        local t = obj(); put(t, union, pack(out)); return t
    end
    local t = obj()
    for _, k in ipairs(dom.keys) do
        local sub = path and (path .. '.' .. k) or k
        put(t, k, rec.o[k] ~= nil and merge(dom.o[k], rec.o[k], sub, lead) or copy(dom.o[k]))
    end
    for _, k in ipairs(rec.keys) do if t.o[k] == nil then put(t, k, copy(rec.o[k])) end end
    return t
end
M.merge = merge

-- ── reading ───────────────────────────────────────────────────────────────────────────
-- ★ MAVEN'S READER TRIMS: every element's text and every attribute passes through Java's
-- String.trim() (MavenXpp3Reader; Xpp3DomBuilder for plugin configuration), which strips each
-- character <= U+0020 at both ends. xmlvalue keeps text EXACTLY, which is right for XML and wrong
-- for this dialect — the oracle join found it as ONE cause in 117 of 121 hadoop POMs (a multi-line
-- <extraJavaTestArgs>). A whitespace-only element becomes "", i.e. empty.
local function trimmed(v)
    if type(v) == 'string' then return (v:gsub('^[%z\1-\32]+', ''):gsub('[%z\1-\32]+$', '')) end
    if type(v) ~= 'table' then return v end
    if v.o then
        local t = obj()
        for _, k in ipairs(v.keys) do put(t, k, trimmed(v.o[k])) end
        return t
    end
    if v.a then local a = {}; for i, x in ipairs(v.a) do a[i] = trimmed(x) end; return { a = a } end
    return v
end
M._trimmed = trimmed

--- One POM document -> { path, dir, raw } or nil, why.
function M.read_pom(src, rel)
    local r, why = X.read(src)
    if not r then return nil, why end
    if r.root ~= 'project' then return nil, ('not a POM (root <%s>)'):format(tostring(r.root)) end
    return { path = rel, dir = dirname(rel or ''), raw = as_obj(trimmed(r.value)), entities = r.undefined_entities }
end

-- ⚠ NOT the code walk's EXCLUDE_DIRS: that set drops `build/`, `dist/`, `external/` as vendored
-- or generated CODE, and in a Maven tree those are real MODULES — wildfly's `build/pom.xml` and
-- `dist/pom.xml` are reactor members, and the shared set lost 7 POMs and made 7 modules "missing".
-- Only build OUTPUT and installed packages are skipped here.
local POM_EXCLUDE = { target = true, node_modules = true }

--- Every pom.xml under `root` (dot-directories, `target/` and `node_modules/` skipped).
function M.find(root, tp)
    tp = tp or require 'cartograph.transport'
    local out = {}
    local function rec(rel)
        for name, t in tp.dir(rel == '' and root or (root .. '/' .. rel)) do
            if name:sub(1, 1) ~= '.' then
                local r = rel == '' and name or (rel .. '/' .. name)
                if t == 'directory' then if not POM_EXCLUDE[name] then rec(r) end
                elseif name == 'pom.xml' then out[#out + 1] = r end
            end
        end
    end
    rec('')
    table.sort(out)
    return out
end

-- the RAW coordinates Maven compares when it checks a local parent: own, else the parent's
local function raw_coords(pom)
    local p, par = pom.raw, get(pom.raw, 'parent')
    return str(get(p, 'groupId')) or str(get(par, 'groupId')), str(get(p, 'artifactId')),
        str(get(p, 'version')) or str(get(par, 'version'))
end
local function gav(g, a, v) return ('%s:%s:%s'):format(g or '?', a or '?', v or '?') end

--- Read a tree of POMs and link each to its parent.
--- @return table model { root, poms = {[rel]=pom}, order, refusals, by_gav = {[gav]={rels}} }
function M.read(root, files, opts)
    opts = opts or {}
    local model = { root = root, poms = {}, order = {}, refusals = {}, by_gav = {}, cache = {} }
    for _, rel in ipairs(files) do
        local src = (opts.read or function(r) return readf(root .. '/' .. r) end)(rel)
        local pom, why
        if src then pom, why = M.read_pom(src, rel) else why = 'unreadable' end
        if pom then
            model.poms[rel] = pom
            model.order[#model.order + 1] = rel
            pom.g, pom.a, pom.v = raw_coords(pom)
            local k = gav(pom.g, pom.a, pom.v)
            model.by_gav[k] = model.by_gav[k] or {}
            table.insert(model.by_gav[k], rel)
        else
            model.refusals[#model.refusals + 1] = { path = rel, why = why }
        end
    end
    for _, rel in ipairs(model.order) do M.link_parent(model, model.poms[rel]) end
    return model
end

--- Maven's parent lookup: relativePath (checked against the declared coordinates), then the
--- tree by coordinates (the reactor), else a frontier. Sets pom.parent / pom.parent_via /
--- pom.frontier.
function M.link_parent(model, pom)
    local par = get(pom.raw, 'parent')
    if not par then return end
    local g, a, v = str(get(par, 'groupId')), str(get(par, 'artifactId')), str(get(par, 'version'))
    local rp = get(par, 'relativePath')
    if rp == nil then rp = '../pom.xml' end
    rp = str(rp) or ''
    if rp ~= '' then
        local path = join(pom.dir, rp)
        if path and not path:match('%.xml$') then path = join(path, 'pom.xml') end
        local cand = path and model.poms[path]
        if cand then
            if cand.g == g and cand.a == a and (v == nil or cand.v == v) then
                pom.parent, pom.parent_via = path, 'relativePath'
                return
            end
            pom.parent_mismatch = path -- Maven warns and falls back to the repository
        end
    end
    local hits = model.by_gav[gav(g, a, v)]
    if hits and #hits == 1 and hits[1] ~= pom.path then
        pom.parent, pom.parent_via = hits[1], 'reactor'
        return
    end
    pom.frontier = gav(g, a, v)
    if hits and #hits > 1 then pom.parent_ambiguous = #hits end
end

-- ── profiles ─────────────────────────────────────────────────────────────────────────
local SYSTEMISH = { java = true, os = true, user = true, file = true, line = true, path = true, sun = true }

local function jdk_matches(spec, jdk)
    local neg = spec:sub(1, 1) == '!'
    if neg then spec = spec:sub(2) end
    local r
    local lo_inc, lo, hi, hi_inc = spec:match('^([%[%(])%s*([^,]*)%s*,%s*([^%]%)]*)%s*([%]%)])$')
    if lo_inc then
        local function cmp(x, y) -- numeric dotted comparison
            local xs, ys = vim.split(x, '.', { plain = true }), vim.split(y, '.', { plain = true })
            for i = 1, math.max(#xs, #ys) do
                local a, b = tonumber(xs[i]) or 0, tonumber(ys[i]) or 0
                if a ~= b then return a < b and -1 or 1 end
            end
            return 0
        end
        r = true
        if lo ~= '' then local c = cmp(jdk, lo); r = r and (c > 0 or (c == 0 and lo_inc == '[')) end
        if hi ~= '' then local c = cmp(jdk, hi); r = r and (c < 0 or (c == 0 and hi_inc == ']')) end
    else
        r = jdk == spec or jdk:sub(1, #spec + 1) == spec .. '.'
    end
    if neg then return not r end
    return r
end

-- decide one profile: true / false / nil (undecided) and the triggers seen
local function decide(pom, prof, vantage, exists)
    local id = str(get(prof, 'id')) or 'default'
    local named = vantage.profiles and vantage.profiles[id]
    if named ~= nil then return named, { 'named' } end
    local act = get(prof, 'activation')
    if type(act) ~= 'table' then return false, {} end
    local triggers, result = {}, nil
    local function both(r) -- every trigger present must hold (Maven 3.2+: AND)
        if r == false then result = false
        elseif r == nil then if result ~= false then result = 'undecided' end
        elseif result == nil then result = true end
    end
    for _, k in ipairs(act.keys) do
        local v = act.o[k]
        if k == 'activeByDefault' then -- handled by the caller
        elseif k == 'property' then
            triggers[#triggers + 1] = 'property'
            local name, want = str(get(v, 'name')) or '', str(get(v, 'value'))
            local neg = name:sub(1, 1) == '!'
            if neg then name = name:sub(2) end
            local prefix = name:match('^([^.]+)%.')
            local have = (vantage.props and vantage.props[name]) or (vantage.sys and vantage.sys[name])
            if SYSTEMISH[prefix or ''] and have == nil and not vantage.sys then both(nil)
            else
                local r
                if want then
                    local wneg = want:sub(1, 1) == '!'
                    if wneg then r = have ~= nil and have ~= want:sub(2) else r = have == want end
                    if neg then r = not r end -- a malformed `!name` with a value; Maven negates
                else r = have ~= nil; if neg then r = not r end end
                both(r)
            end
        elseif k == 'jdk' then
            triggers[#triggers + 1] = 'jdk'
            if vantage.jdk then both(jdk_matches(str(v) or '', vantage.jdk)) else both(nil) end
        elseif k == 'os' then
            triggers[#triggers + 1] = 'os'
            if vantage.os then
                local r = true
                for _, f in ipairs({ 'name', 'family', 'arch', 'version' }) do
                    local want = str(get(v, f))
                    if want then
                        local neg = want:sub(1, 1) == '!'
                        if neg then want = want:sub(2) end
                        local have = vantage.os[f]
                        if have == nil then r = nil; break end
                        local m = want:lower() == tostring(have):lower()
                        if neg then m = not m end
                        r = r and m
                    end
                end
                both(r)
            else both(nil) end
        elseif k == 'file' then
            triggers[#triggers + 1] = 'file'
            local ex, miss = str(get(v, 'exists')), str(get(v, 'missing'))
            local function probe(p)
                -- relative to the POM's directory; `${basedir}` IS that directory (the root's is '')
                local rest = p:match('^%${project%.basedir}/?(.*)$') or p:match('^%${basedir}/?(.*)$') or p
                if rest:find('%${') or rest:sub(1, 1) == '/' then return nil end
                local rel = join(pom.dir, rest)
                if rel == nil then return nil end
                return exists(rel)
            end
            if ex then local e = probe(ex); both(e) elseif miss then local e = probe(miss); both(e == nil and nil or not e) end
        else
            triggers[#triggers + 1] = k
            both(nil)
        end
    end
    if result == 'undecided' then return nil, triggers end
    return result or false, triggers
end

-- the active profiles of ONE POM under a vantage
local function active_profiles(pom, vantage, exists)
    local out, undecided, defaults, any_active, any_undecided = {}, {}, {}, false, false
    for _, prof in ipairs(arr(get(get(pom.raw, 'profiles'), 'profile'))) do
        local id = str(get(prof, 'id')) or 'default'
        local r, triggers = decide(pom, prof, vantage, exists)
        if r == true then out[#out + 1] = { id = id, prof = prof, why = table.concat(triggers, '+') }; any_active = true
        elseif r == nil then undecided[#undecided + 1] = { pom = pom.path, id = id, triggers = triggers }; any_undecided = true
        elseif (vantage.profiles == nil or vantage.profiles[id] == nil)
            and str(get(get(prof, 'activation'), 'activeByDefault')) == 'true' then
            defaults[#defaults + 1] = { id = id, prof = prof, why = 'activeByDefault' }
        end
    end
    local contingent = false
    if not any_active then
        for _, d in ipairs(defaults) do out[#out + 1] = d end
        contingent = any_undecided and #defaults > 0
    end
    return out, undecided, contingent
end

-- a POM's raw model with its active profiles injected (profile dominant)
local PROFILE_PARTS = { 'properties', 'dependencies', 'dependencyManagement', 'modules', 'build', 'repositories',
    'pluginRepositories', 'reporting', 'distributionManagement' }
local function injected(pom, vantage, exists)
    local m = copy(pom.raw)
    local act, undecided, contingent = active_profiles(pom, vantage, exists)
    for _, p in ipairs(act) do
        for _, part in ipairs(PROFILE_PARTS) do
            local v = get(p.prof, part)
            if v ~= nil then put(m, part, merge(v, m.o[part], part, 'rec')) end
        end
    end
    m.o.profiles = nil
    for i, k in ipairs(m.keys) do if k == 'profiles' then table.remove(m.keys, i); break end end
    return m, act, undecided, contingent
end

-- ── interpolation ────────────────────────────────────────────────────────────────────
local SUPER_BUILD = {
    directory = '${project.basedir}/target',
    outputDirectory = '${project.build.directory}/classes',
    testOutputDirectory = '${project.build.directory}/test-classes',
    sourceDirectory = '${project.basedir}/src/main/java',
    scriptSourceDirectory = '${project.basedir}/src/main/scripts',
    testSourceDirectory = '${project.basedir}/src/test/java',
    finalName = '${project.artifactId}-${project.version}',
}
local SUPER = { ['reporting.outputDirectory'] = '${project.build.directory}/site' }
local VANTAGE_CLASS = { env = 'env', settings = 'settings', maven = 'maven', session = 'maven' }
local HOLE_RANK = { undefined = 5, beyond = 4, profile = 3, late = 2, cycle = 6 }

-- a model path lookup (`build.finalName`, `parent.version`) on the uninterpolated model
local function model_path(m, dotted)
    local v = m
    for seg in dotted:gmatch('[^.]+') do
        v = get(v, seg)
        if v == nil then break end
    end
    if type(v) == 'string' then return v end
    if v == nil and dotted:match('^build%.') then return SUPER_BUILD[dotted:sub(7)] end
    if v == nil and SUPER[dotted] then return SUPER[dotted] end
    if v == nil and dotted == 'packaging' then return 'jar' end
    return nil
end

--- Interpolate a string. `ctx` = { model, props, user, pom, frontier, profile_props }.
--- Returns the value (unresolved references left as written) and the holes met.
local function interp(s, ctx, holes, stack)
    stack = stack or {}
    return (s:gsub('%${([^}]+)}', function(expr)
        local function hole(class)
            holes[#holes + 1] = { expr = expr, class = class }
            return nil
        end
        if stack[expr] then hole('cycle'); return nil end
        local head = expr:match('^([^.]+)') or expr
        local value
        if expr == 'basedir' or expr == 'project.basedir' or expr == 'pom.basedir'
            or expr == 'project.baseUri' or expr == 'pom.baseUri' or expr == 'baseUri'
            -- MavenProject's parent chain (the MODEL's <parent> has no basedir): still a checkout fact
            or (expr:match('^project%.parent%.') and expr:gsub('^project%.', ''):gsub('parent%.', '') == 'basedir') then
            return hole('basedir')
        elseif expr:match('^project%.artifact%.') or expr:match('^project%.attachedArtifacts') then
            return hole('late')
        elseif (head == 'project' or head == 'pom') and expr ~= head then
            value = model_path(ctx.model, expr:sub(#head + 2))
        end
        if value == nil and ctx.user and ctx.user[expr] ~= nil then value = ctx.user[expr] end
        if value == nil and ctx.props[expr] ~= nil then value = ctx.props[expr] end
        if value == nil and ctx.sys and ctx.sys[expr] ~= nil then value = ctx.sys[expr] end
        if value == nil then
            if head == 'env' then return hole('env') end
            if VANTAGE_CLASS[head] or expr == 'maven.build.timestamp' then return hole(VANTAGE_CLASS[head] or 'maven') end
            if SYSTEMISH[head] and expr ~= head then return hole('system') end
            -- the deprecated unprefixed model form: ${version}, ${groupId}, ${artifactId}
            if not expr:find('.', 1, true) then value = model_path(ctx.model, expr) end
        end
        if value == nil then
            if ctx.profile_props[expr] then return hole('profile') end
            if ctx.frontier then return hole('beyond') end
            if ctx.late then return hole('late') end
            return hole('undefined')
        end
        stack[expr] = true
        local out = interp(value, ctx, holes, stack)
        stack[expr] = nil
        return out
    end))
end
M._interp = interp

local function worst(holes)
    local best, rank = nil, -1
    for _, h in ipairs(holes) do
        local r = HOLE_RANK[h.class] or 1
        if r > rank then best, rank = h.class, r end
    end
    return best
end

-- interpolate every string leaf (and attribute) of a kv value, tallying each `${}` occurrence
local function interp_tree(v, ctx, path, refs)
    if type(v) == 'string' then
        if not v:find('${', 1, true) then return v end
        local out = v:gsub('%${([^}]+)}', function(expr)
            local holes = {}
            local r = interp('${' .. expr .. '}', ctx, holes)
            refs.total = refs.total + 1
            local cls = worst(holes)
            if cls then
                refs.holes[cls] = (refs.holes[cls] or 0) + 1
                refs.list[#refs.list + 1] = { path = path, expr = expr, class = cls,
                    inner = holes[1] and holes[1].expr ~= expr and holes[1].expr or nil }
            else refs.resolved = refs.resolved + 1 end
            return r
        end)
        return out
    end
    if type(v) ~= 'table' then return v end
    if v.o then
        local t = obj()
        for _, k in ipairs(v.keys) do
            local was = ctx.late
            if k == 'configuration' then ctx.late = true end
            put(t, k, interp_tree(v.o[k], ctx, path .. '.' .. k, refs))
            ctx.late = was
        end
        return t
    end
    if v.a then
        local a = {}
        for i, x in ipairs(v.a) do a[i] = interp_tree(x, ctx, path .. '[' .. i .. ']', refs) end
        return { a = a }
    end
    return v
end

-- ── the effective model ─────────────────────────────────────────────────────────────
local function vkey(vantage)
    if not vantage or next(vantage) == nil then return '' end
    return vim.inspect(vantage, { newline = '', indent = '' })
end

local function exists_in(model)
    return model.exists or function(rel)
        return vim.uv.fs_stat(model.root .. '/' .. rel) ~= nil
    end
end

-- the lineage (child first) and the assembled, UNINTERPOLATED model; memoised per vantage
local function assemble(model, rel, vantage, seen)
    local key = rel .. '\0' .. vkey(vantage)
    local hit = model.cache[key]
    if hit then return hit end
    seen = seen or {}
    if seen[rel] then return nil, 'a parent cycle through ' .. rel end
    seen[rel] = true
    local pom = model.poms[rel]
    local mine, act, undecided, contingent = injected(pom, vantage, exists_in(model))
    local out = { lineage = { rel }, applied = {}, undecided = {}, contingent = contingent, profile_props = {} }
    for _, p in ipairs(act) do out.applied[#out.applied + 1] = { pom = rel, id = p.id, why = p.why } end
    for _, u in ipairs(undecided) do out.undecided[#out.undecided + 1] = u end
    -- properties defined only in a profile NOT applied here: a `${}` to one is a `profile` hole
    local applied_ids = {}
    for _, p in ipairs(act) do applied_ids[p.id] = true end
    for _, prof in ipairs(arr(get(get(pom.raw, 'profiles'), 'profile'))) do
        if not applied_ids[str(get(prof, 'id')) or 'default'] then
            for _, k in ipairs(as_obj(get(prof, 'properties')).keys) do out.profile_props[k] = str(get(prof, 'id')) or 'default' end
        end
    end
    local up
    if pom.parent then
        local err
        up, err = assemble(model, pom.parent, vantage, seen)
        if not up then return nil, err end
    end
    if up then
        local inherit = copy(up.model)
        for _, k in ipairs({ 'artifactId', 'packaging', 'modules', 'name', 'prerequisites' }) do inherit.o[k] = nil end
        local keys = {}
        for _, k in ipairs(inherit.keys) do if inherit.o[k] ~= nil then keys[#keys + 1] = k end end
        inherit.keys = keys
        out.model = merge(mine, inherit, nil)
        for _, r in ipairs(up.lineage) do out.lineage[#out.lineage + 1] = r end
        for _, a in ipairs(up.applied) do out.applied[#out.applied + 1] = a end
        for _, u in ipairs(up.undecided) do out.undecided[#out.undecided + 1] = u end
        for k, id in pairs(up.profile_props) do if out.profile_props[k] == nil then out.profile_props[k] = id end end
        out.contingent = out.contingent or up.contingent
        out.frontier = up.frontier
    else
        out.model = mine
        out.frontier = pom.frontier
    end
    -- groupId/version are inherited from the <parent> element itself when absent
    local par = get(pom.raw, 'parent')
    if par then
        for _, k in ipairs({ 'groupId', 'version' }) do
            if get(out.model, k) == nil and get(par, k) ~= nil then put(out.model, k, get(par, k)) end
        end
    end
    -- a property the model defines is not a profile hole, whatever a profile also says
    for _, k in ipairs(as_obj(get(out.model, 'properties')).keys) do out.profile_props[k] = nil end
    model.cache[key] = out
    return out
end

-- the managed entries of an interpolated model, BOMs imported (in-tree ones read, others frontier).
-- `raw` is the same list UNINTERPOLATED (interpolation keeps positions), whose keys name the
-- declaring POM: Maven merges by the raw key, before any `${}` is resolved.
local function managed(model, eff_model, raw_model, declared_in, vantage, imports, seen)
    local out, index = {}, {}
    local function add(d, from)
        local k = dep_key(d)
        if not index[k] then out[#out + 1] = { key = k, d = d, from = from }; index[k] = #out end
    end
    local function list(m) return arr(get(get(get(m, 'dependencyManagement'), 'dependencies'), 'dependency')) end
    local raw, boms = list(raw_model), {}
    for i, d in ipairs(list(eff_model)) do
        if str(get(d, 'scope')) == 'import' then boms[#boms + 1] = d
        else add(d, 'managed:' .. (raw[i] and declared_in[dep_key(raw[i])] or '?')) end
    end
    for _, b in ipairs(boms) do
        local g, a, v = str(get(b, 'groupId')), str(get(b, 'artifactId')), str(get(b, 'version'))
        local hits = model.by_gav[gav(g, a, v)]
        local brel = hits and #hits == 1 and hits[1] or nil
        imports[#imports + 1] = { gav = gav(g, a, v), rel = brel }
        if brel and not seen[brel] then
            seen[brel] = true
            local beff = M.effective(model, brel, vantage, seen)
            if beff then
                for _, e in ipairs(beff.dm) do add(e.d, 'bom:' .. brel) end
                -- ★ AN IN-TREE BOM'S OWN FRONTIER IMPORTS ARE OURS TOO: quarkus-bom (in the tree)
                -- imports smallrye-common-bom (not), and 598 version-less dependencies read
                -- `missing` until the frontier travelled up with the entries
                for _, im in ipairs(beff.imports) do
                    if not im.rel then imports[#imports + 1] = { gav = im.gav, via = im.via or brel } end
                end
            end
        end
    end
    return out, index
end

--- THE EFFECTIVE MODEL of one POM under a vantage.
--- @return table|nil eff { path, model, coords, deps, dm, imports, refs, lineage, frontier,
---   applied, undecided, contingent, lower_bound }
--- @return string|nil why
function M.effective(model, rel, vantage, seen)
    vantage = vantage or {}
    local key = 'E' .. rel .. '\0' .. vkey(vantage)
    if model.cache[key] then return model.cache[key] end
    if not model.poms[rel] then return nil, 'no POM ' .. rel end
    local asm, err = assemble(model, rel, vantage)
    if not asm then return nil, err end
    local raw = asm.model
    local props = {}
    for _, k in ipairs(as_obj(get(raw, 'properties')).keys) do props[k] = str(get(get(raw, 'properties'), k)) end
    local ctx = { model = raw, props = props, user = vantage.props, sys = vantage.sys, frontier = asm.frontier, profile_props = asm.profile_props }
    local refs = { total = 0, resolved = 0, holes = {}, list = {} }
    local m = interp_tree(raw, ctx, '$', refs)
    local imports = {}
    seen = seen or { [rel] = true }
    -- where each lineage entry was declared: the nearest POM whose own (profile-injected) model has the key
    local declared_in = {}
    for _, r in ipairs(asm.lineage) do
        local own = injected(model.poms[r], vantage, exists_in(model))
        for _, d in ipairs(arr(get(get(get(own, 'dependencyManagement'), 'dependencies'), 'dependency'))) do
            local k = dep_key(d)
            if declared_in[k] == nil then declared_in[k] = r end
        end
    end
    local dm, dmi = managed(model, m, raw, declared_in, vantage, imports, seen)
    -- management injection
    local deps = {}
    for _, d in ipairs(arr(get(get(m, 'dependencies'), 'dependency'))) do
        local k = dep_key(d)
        local e = dmi[k] and dm[dmi[k]]
        local v = str(get(d, 'version'))
        local rec = { key = k, g = str(get(d, 'groupId')), a = str(get(d, 'artifactId')), type = str(get(d, 'type')) or 'jar',
            classifier = str(get(d, 'classifier')), scope = str(get(d, 'scope')), optional = str(get(d, 'optional')) }
        if v then rec.v, rec.version_from = v, 'declared'
        elseif e then rec.v, rec.version_from = str(get(e.d, 'version')), e.from
        else
            -- no entry: a BOM we could not read or a parent beyond the tree may supply it
            local frontier_bom
            for _, im in ipairs(imports) do if not im.rel then frontier_bom = im.gav; break end end
            rec.version_from = (frontier_bom and ('frontier:bom ' .. frontier_bom))
                or (asm.frontier and ('frontier:beyond ' .. asm.frontier)) or 'missing'
        end
        if e and not rec.scope then rec.scope = str(get(e.d, 'scope')) end
        rec.scope = rec.scope or 'compile'
        deps[#deps + 1] = rec
    end
    local eff = {
        path = rel, model = m, deps = deps, dm = dm, imports = imports, refs = refs,
        lineage = asm.lineage, frontier = asm.frontier, applied = asm.applied, undecided = asm.undecided,
        contingent = asm.contingent,
        coords = { g = str(get(m, 'groupId')), a = str(get(m, 'artifactId')), v = str(get(m, 'version')),
            packaging = str(get(m, 'packaging')) or 'jar' },
    }
    eff.lower_bound = #asm.undecided > 0 or asm.contingent
    model.cache[key] = eff
    return eff
end

--- ★ THE PROJECTION: what this reader CLAIMS about one effective model, in the kv form — the
--- contract the Maven oracle (tools/oracles/maven_effective.py) is joined on. Anything outside
--- it (super-POM repositories, resources, reporting) is not claimed and not compared.
function M.projection(eff)
    local function norm(v)
        if type(v) ~= 'string' then return v end
        return (v:gsub('%${project%.basedir}', '${basedir}'):gsub('%${pom%.basedir}', '${basedir}'))
    end
    local coords = obj()
    for _, k in ipairs({ 'g', 'a', 'v', 'packaging' }) do
        put(coords, ({ g = 'groupId', a = 'artifactId', v = 'version', packaging = 'packaging' })[k], norm(eff.coords[k] or ''))
    end
    local props, pk = obj(), {}
    local po = as_obj(get(eff.model, 'properties'))
    for _, k in ipairs(po.keys) do pk[#pk + 1] = k end
    table.sort(pk)
    for _, k in ipairs(pk) do put(props, k, norm(str(po.o[k]) or '')) end
    local deps = {}
    for _, d in ipairs(eff.deps) do
        deps[#deps + 1] = table.concat({ d.key, norm(d.v or ''), d.scope or 'compile', d.optional or 'false' }, '|')
    end
    local dm = {}
    for _, e in ipairs(eff.dm) do
        dm[#dm + 1] = table.concat({ e.key, norm(str(get(e.d, 'version')) or ''), str(get(e.d, 'scope')) or 'compile' }, '|')
    end
    table.sort(dm)
    local mods = {}
    for _, m in ipairs(arr(get(get(eff.model, 'modules'), 'module'))) do mods[#mods + 1] = m end
    local t = obj()
    put(t, 'coords', coords); put(t, 'properties', props)
    put(t, 'dependencies', { a = deps }); put(t, 'managed', { a = dm }); put(t, 'modules', { a = mods })
    return t
end

-- ── the tree ────────────────────────────────────────────────────────────────────────
--- The whole tree under one vantage: the reactor, inter-module links, holes, no-op overrides.
function M.analyze(model, vantage)
    vantage = vantage or {}
    local A = { effective = {}, reactor = {}, orphans = {}, links = {}, skew = {}, noops = {}, holes = {},
        missing = {}, frontiers = {}, refs = { total = 0, resolved = 0, holes = {} }, errors = {},
        parent_via = {}, ambiguous = {} }
    for _, rel in ipairs(model.order) do
        local eff, err = M.effective(model, rel, vantage)
        if eff then A.effective[rel] = eff else A.errors[#A.errors + 1] = { path = rel, why = err } end
        local pom = model.poms[rel]
        if pom.parent_via then A.parent_via[pom.parent_via] = (A.parent_via[pom.parent_via] or 0) + 1 end
        if pom.frontier then A.frontiers[pom.frontier] = (A.frontiers[pom.frontier] or 0) + 1 end
        if pom.parent_ambiguous then A.ambiguous[#A.ambiguous + 1] = rel end
    end
    -- AGGREGATION: reachable from every POM no other POM lists as a module (and is not a child
    -- reached through inheritance only) — computed from the effective <modules> of each
    local listed = {}
    local children = {}
    for rel, eff in pairs(A.effective) do
        local dir = model.poms[rel].dir
        children[rel] = {}
        for _, m in ipairs(arr(get(get(eff.model, 'modules'), 'module'))) do
            local p = join(dir, m)
            if p and not p:match('%.xml$') then p = join(p, 'pom.xml') end
            if p and model.poms[p] then
                listed[p] = true
                table.insert(children[rel], p)
            else
                A.missing[#A.missing + 1] = { path = rel, module = m, what = 'module' }
            end
        end
    end
    local top = model.poms['pom.xml'] and { 'pom.xml' } or {}
    local reach = {}
    local function walk(r) if reach[r] then return end reach[r] = true; for _, c in ipairs(children[r] or {}) do walk(c) end end
    for _, t in ipairs(top) do walk(t) end
    for _, rel in ipairs(model.order) do
        if reach[rel] then A.reactor[#A.reactor + 1] = rel else A.orphans[#A.orphans + 1] = rel end
    end
    -- INTER-MODULE LINKS: a dependency whose coordinates are a reactor module's EFFECTIVE ones;
    -- the same g:a at another version is an EXTERNAL artifact of that name — counted as skew
    local by_ga = {}
    for _, rel in ipairs(A.reactor) do
        local eff = A.effective[rel]
        if eff and eff.coords.g and eff.coords.a then
            local ga = eff.coords.g .. ':' .. eff.coords.a
            by_ga[ga] = by_ga[ga] or {}
            table.insert(by_ga[ga], rel)
        end
    end
    for _, rel in ipairs(A.reactor) do
        local eff = A.effective[rel]
        for _, d in ipairs(eff and eff.deps or {}) do
            local hits = d.g and d.a and by_ga[d.g .. ':' .. d.a]
            if hits then
                local to
                for _, h in ipairs(hits) do if A.effective[h].coords.v == d.v then to = h end end
                if to then A.links[#A.links + 1] = { from = rel, to = to, scope = d.scope, type = d.type, version_from = d.version_from }
                else A.skew[#A.skew + 1] = { from = rel, dep = d.g .. ':' .. d.a, want = d.v, have = A.effective[hits[1]].coords.v } end
            end
            if d.version_from == 'missing' then A.missing[#A.missing + 1] = { path = rel, dep = d.key, what = 'version' } end
        end
    end
    -- holes and the rebuild check's totals, over the reactor
    for _, rel in ipairs(A.reactor) do
        local eff = A.effective[rel]
        if eff then
            A.refs.total = A.refs.total + eff.refs.total
            A.refs.resolved = A.refs.resolved + eff.refs.resolved
            for c, n in pairs(eff.refs.holes) do A.refs.holes[c] = (A.refs.holes[c] or 0) + n end
            for _, h in ipairs(eff.refs.list) do
                if h.class == 'undefined' or h.class == 'cycle' then A.holes[#A.holes + 1] = { path = rel, at = h.path, expr = h.expr, class = h.class, inner = h.inner } end
            end
        end
    end
    -- NO-OP OVERRIDES: a property a POM sets to exactly what its parent's effective model already says
    for _, rel in ipairs(model.order) do
        local pom = model.poms[rel]
        local up = pom.parent and A.effective[pom.parent]
        if up then
            local asm_up = assemble(model, pom.parent, vantage)
            local mine = as_obj(get(pom.raw, 'properties'))
            for _, k in ipairs(mine.keys) do
                local theirs = get(get(asm_up.model, 'properties'), k)
                if theirs ~= nil and vim.deep_equal(theirs, mine.o[k]) then
                    A.noops[#A.noops + 1] = { path = rel, key = k, value = mine.o[k], parent = pom.parent }
                end
            end
        end
    end
    return A
end

-- ── the session layer ────────────────────────────────────────────────────────────────
local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }

--- Mint the Maven build layer into `data`. Idempotent under refresh.
function M.attach(data, opts)
    local stats = { files = 0, reactor = 0, orphans = 0, refused = 0, links = 0, skew = 0, noops = 0, undefined = 0,
        missing = 0, frontiers = 0, lower_bound = 0 }
    if not data or not data.root then data.pom = nil; return stats end
    local keep, mine = {}, {}
    for _, n in ipairs(data.nodes or {}) do if n.pom then mine[n.id] = true else keep[#keep + 1] = n end end
    if next(mine) then
        local edges = {}
        for _, e in ipairs(data.edges or {}) do if not (e.pom or mine[e.from] or mine[e.to]) then edges[#edges + 1] = e end end
        data.nodes, data.edges = keep, edges
    end
    local files = (opts and opts.files) or M.find(data.root, opts and opts.transport)
    if #files == 0 then data.pom = nil; return stats end
    local model = M.read(data.root, files)
    local A = M.analyze(model, opts and opts.vantage)
    data.nodes = data.nodes or {}
    data.edges = data.edges or {}
    for _, rel in ipairs(model.order) do
        local eff = A.effective[rel]
        data.nodes[#data.nodes + 1] = { id = rel, name = eff and eff.coords.a and (eff.coords.a .. ' (pom)') or rel,
            kind = 'module', file = rel, range = R0, order = 0, pom = true }
        stats.files = stats.files + 1
        if eff and eff.lower_bound then stats.lower_bound = stats.lower_bound + 1 end
        local pom = model.poms[rel]
        -- `use`, not `import`: a build relation must not enter the code walks until CART-0163 decides
        if pom.parent then data.edges[#data.edges + 1] = { from = rel, to = pom.parent, kind = 'use', pom = 'parent', at = {} } end
    end
    local seen = {}
    for rel, eff in pairs(A.effective) do
        for _, m in ipairs(arr(get(get(eff.model, 'modules'), 'module'))) do
            local p = join(model.poms[rel].dir, m)
            if p and not p:match('%.xml$') then p = join(p, 'pom.xml') end
            if p and model.poms[p] and not seen[rel .. '>' .. p] then
                seen[rel .. '>' .. p] = true
                data.edges[#data.edges + 1] = { from = rel, to = p, kind = 'use', pom = 'module', at = {} }
            end
        end
    end
    for _, l in ipairs(A.links) do
        data.edges[#data.edges + 1] = { from = l.from, to = l.to, kind = 'use', pom = 'dependency', scope = l.scope, at = {} }
    end
    stats.refused = #model.refusals
    stats.reactor, stats.orphans = #A.reactor, #A.orphans
    stats.links, stats.skew, stats.noops = #A.links, #A.skew, #A.noops
    stats.undefined = #A.holes
    stats.missing = #A.missing
    for _ in pairs(A.frontiers) do stats.frontiers = stats.frontiers + 1 end
    data.pom = { model = model, analysis = A }
    return stats
end

function M.summary(s)
    if not s or s.files == 0 then return nil end
    return ('maven: %d POM(s), %d in the reactor, %d outside it; %d inter-module link(s), %d version skew;'
        .. ' %d external parent(s); %d no-op override(s); %d undefined reference(s), %d missing module/version%s%s')
        :format(s.files, s.reactor, s.orphans, s.links, s.skew, s.frontiers, s.noops, s.undefined, s.missing,
            s.lower_bound > 0 and (' — %d effective model(s) are LOWER BOUNDS (undecided profiles)'):format(s.lower_bound) or '',
            s.refused > 0 and (' — %d refused'):format(s.refused) or '')
end

return M
