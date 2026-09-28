-- cartograph.toolbelt — NAMED TACTICS, discovered from lua/cartograph/tactics/, each carrying the EXAMPLES that
-- explain it and test it (CART-1152's follow-on).
--
-- USER (2026-09-28): "I think we can now create a toolbelt of tactics" · "We can always parse the lua when we need it
-- as data" · "Recording the discoveries was there because we had no way to record the tactic concept" · "an example
-- (or several) can be a part of it, which explains usage and works also as a test".
--
-- So an entry is a PLAIN LUA FILE (its source is its serialized form — lift it with qlower when it is needed as data)
-- and there is NO CENTRAL LIST: dropping a file into tactics/ adds a tactic, which lets parallel sessions add their own
-- without sharing a registry. Two kinds:
--   write      a tactic TERM over write verbs:  build(params) -> term, run by tactic.run (forward recovery, stops only
--              on a decision), optionally accepted by the entry's `oracle`
--   discovery  a FINDING kept as the procedure that produced it: measure(store, params) -> value, and claim(value) ->
--              ok, why. The prose that used to record a discovery now points here; re-running says whether it still
--              holds. `measures` names the ticket whose claim it tracks.
-- Every entry carries `examples` = { { name, files, params(store) -> params, expect } }: the usage documentation, and
-- the toolbelt fence runs every one. An example's `expect` is checked against the run's result:
--   write:      { status = 'done' | 'stopped' | ..., applied = n?, check = fn(root, result) -> ok, why }
--   discovery:  { holds = true | false, check = fn(value) -> ok, why }
local M = {}

local REQUIRED = { name = 'string', kind = 'string', summary = 'string', examples = 'table' }
local KINDS = { write = true, discovery = true }

--- the BUILT-IN directory, derived from this module's own path
local function dir()
    local here = debug.getinfo(1, 'S').source:gsub('^@', '')
    return (here:gsub('toolbelt%.lua$', 'tactics'))
end
M.builtin_dir = dir

--- ★ THE PROJECT'S OWN TACTICS: `<root>/.cartograph/tactics/`. USER (2026-09-28): a tactic "can be created
--- project-local and then promoted". A session learns into the analysed project (contained, journaled, undoable);
--- promotion into the built-in toolbelt is a separate, reviewed act (the promote-tactic entry).
function M.project_dir(root) return root and (root .. '/.cartograph/tactics') or nil end

local function slurp(path) local fd = io.open(path); if not fd then return nil end; local x = fd:read('a'); fd:close(); return x end

--- ★ WHERE TACTICS COME FROM, AS A NAMESPACE (CART-1160 step 4): the built-in directory mounted at `tactics`, and a
--- project's `.cartograph/tactics/` UNIONED after it — two mounts and a precedence, not two hard-wired scans. `d`
--- confines it to one directory (a single mount). -> namespace value; each target is { dir, scope }
function M.namespace(d, root)
    local namespace = require 'cartograph.namespace'
    local ns = namespace.empty()
    if d then return (namespace.mount(ns, 'tactics', { dir = d, scope = 'given' })) end
    ns = namespace.mount(ns, 'tactics', { dir = dir(), scope = 'built-in' })
    local pd = M.project_dir(root)
    if pd and vim.fn.isdirectory(pd) == 1 then
        ns = namespace.mount(ns, 'tactics', { dir = pd, scope = 'project' }, { union = 'after' })
    end
    return ns
end

--- every entry file, by name -> path. No central list: the mounted directories ARE the list, read in the union's
--- precedence order (the first layer holding a name provides it).
--- ⚠ A NAME IN TWO LAYERS: byte-identical is a PROMOTED copy (the earlier layer wins, noted); different is a DECISION
--- — a project tactic never silently shadows a built-in one. ★ OVERRIDING IS AN EXPLICIT USER CHOICE, CONTENT-HASHED
--- (USER 2026-09-28): the choice lives in the user's SCOPED config, never in the analysed tree (the tree may select,
--- never supply — a project file cannot grant itself precedence), and it pins BOTH texts:
---   setup{ scoped = { ['<root>'] = { tactic_overrides = { ['<name>'] = { use = 'sha256:<project file>', over = 'sha256:<built-in>' } } } } }
--- Either side changing voids it: the choice was made about THAT pair, and a built-in that moved on may carry a fix the
--- override would now hide. The refusal prints the exact entry for the current pair; nothing writes it for the user.
--- -> files, conflicts { name -> why }, promoted { name -> later layer's path }, overridden { name -> { path, over, use } }
local function hash(path) local t = slurp(path); return t and ('sha256:' .. vim.fn.sha256(t)) or nil end

local function override_of(root, name, path, over)
    local use, was = hash(path), hash(over)
    local entry = ("setup{ scoped = { [%q] = { tactic_overrides = { [%q] = { use = %q, over = %q } } } } }")
        :format(tostring(root), name, tostring(use), tostring(was))
    local pins = root and require('cartograph.config').for_root(root, 'tactic_overrides')
    local pin = type(pins) == 'table' and pins[name] or nil
    if type(pin) == 'table' and pin.use == use and pin.over == was then return { path = path, over = over, use = use } end
    if type(pin) == 'table' then
        local moved = {}
        if pin.use ~= use then moved[#moved + 1] = ('the project file (%s) changed since you chose it'):format(path) end
        if pin.over ~= was then moved[#moved + 1] = ('the built-in it overrides (%s) changed since you chose it'):format(over) end
        return nil, ('your override of `%s` no longer holds: %s — re-choose it with %s, or drop it'):format(name,
            table.concat(moved, '; '), entry), 'decision'
    end
    return nil, entry, 'decision'
end

function M.files(d, root)
    local out, conflicts, promoted, owner, overridden = {}, {}, {}, {}, {}
    local hit = require('cartograph.namespace').resolve(M.namespace(d, root), 'tactics')
    for _, layer in ipairs(hit and hit.layers or {}) do
        for _, path in ipairs(vim.fn.globpath(layer.target.dir, '*.lua', false, true)) do
            local name = vim.fn.fnamemodify(path, ':t:r')
            if not out[name] then out[name], owner[name] = path, layer.target.scope
            elseif slurp(path) == slurp(out[name]) then promoted[name] = path
            else
                local ov, why = override_of(root, name, path, out[name])
                if ov then
                    overridden[name] = ov
                    out[name], owner[name] = path, layer.target.scope
                elseif why:find('no longer holds', 1, true) then
                    conflicts[name] = why
                else
                    conflicts[name] = ('the %s tactic %s has the name of a %s one and differs from it — rename it, promote it, or override it by your own choice: %s')
                        :format(layer.target.scope, path, owner[name]:upper(), why)
                end
            end
        end
    end
    return out, conflicts, promoted, overridden
end

--- a loaded entry, or nil, why — the SHAPE is checked here, by name, not trusted
function M.load(name, d, root)
    local files, conflicts, _, overridden = M.files(d, root)
    -- which of two tactics a name means is the USER's decision: never taken here, by precedence or by guess
    if conflicts[name] then return nil, conflicts[name], 'decision' end
    local path = files[name]
    if not path then return nil, ('no tactic `%s` in the toolbelt (%s%s)'):format(tostring(name), d or dir(),
        (not d and root) and (' + ' .. M.project_dir(root)) or ''), 'ill-posed' end
    local okl, e = pcall(dofile, path)
    if not okl then return nil, ('the tactic file %s raised: %s'):format(path, tostring(e)), 'unbuilt' end
    if type(e) ~= 'table' then return nil, ('%s returns no entry table'):format(path), 'unbuilt' end
    for field, ty in pairs(REQUIRED) do
        if type(e[field]) ~= ty then return nil, ('%s: `%s` must be a %s'):format(path, field, ty), 'unbuilt' end
    end
    if e.name ~= name then return nil, ('%s declares name `%s` — an entry is named by its FILE'):format(path, e.name), 'unbuilt' end
    if not KINDS[e.kind] then return nil, ('%s: kind `%s` is not write | discovery'):format(path, e.kind), 'unbuilt' end
    if e.kind == 'write' and type(e.build) ~= 'function' then return nil, path .. ': a write tactic needs build(params)', 'unbuilt' end
    if e.kind == 'discovery' and (type(e.measure) ~= 'function' or type(e.claim) ~= 'function') then
        return nil, path .. ': a discovery needs measure(store, params) and claim(value)', 'unbuilt'
    end
    if #e.examples == 0 then return nil, path .. ': at least one example — it is the usage AND the test', 'unbuilt' end
    e.path = path
    e.scope = (path:sub(1, #dir()) == dir()) and 'built-in' or 'project'
    -- an override says so on the entry: what it replaced, and the hash the user chose
    if overridden[name] then e.overrides, e.override_hash = overridden[name].over, overridden[name].use end
    return e
end

--- every entry, loaded: { entries }, { broken = { name -> why } }, { promoted = { name -> path } }, { overridden }
function M.list(d, root)
    local entries, broken = {}, {}
    local files, conflicts, promoted, overridden = M.files(d, root)
    local names = {}
    for name in pairs(files) do names[#names + 1] = name end
    for name in pairs(conflicts) do if not files[name] then names[#names + 1] = name end end
    table.sort(names)
    for _, name in ipairs(names) do
        local e, why = M.load(name, d, root)
        if e then entries[#entries + 1] = e else broken[name] = why end
    end
    return entries, broken, promoted, overridden
end

--- ★ PARAMETERS, COERCED BY THEIR DECLARED TYPE — one function for every caller (the CLI's strings, an MCP client's
--- JSON, a `T.use` in a term), so a param means the same thing however it arrives. `params = { name = 'type' }`, a
--- trailing `?` marks it optional:
---   ref     a durable ref table, or `file::name` — resolved against the graph; a miss says DID YOU MEAN, with the
---           near names in that file (cartograph.near), never a guess applied
---   string  as given; `@path` reads the file (a tactic's `text` is usually a whole definition)
---   list    a table, or `a,b,c`
--- An undeclared param, and a missing required one, refuse as ill-posed BY NAME.
--- -> params | nil, why, class
function M.coerce(store, e, raw)
    raw = raw or {}
    local decl = e.params or {}
    local out = {}
    for k in pairs(raw) do
        if decl[k] == nil then
            local names = {}
            for n in pairs(decl) do names[#names + 1] = n end
            table.sort(names)
            return nil, ('%s takes no param `%s` (it takes: %s)'):format(e.name, tostring(k),
                #names > 0 and table.concat(names, ', ') or 'none'), 'ill-posed'
        end
    end
    for k, ty in pairs(decl) do
        local base, optional = tostring(ty):gsub('%?$', '')
        optional = optional > 0
        local v = raw[k]
        if v == nil then
            if not optional then return nil, ('%s needs param `%s` (%s)'):format(e.name, k, base), 'ill-posed' end
        elseif base == 'ref' then
            if type(v) == 'string' then
                local file, name = v:match('^(.-)::(.+)$')
                if not file then return nil, ('param `%s`: a ref is `file::name`, got %q'):format(k, v), 'ill-posed' end
                local hit, names = nil, {}
                for _, n in ipairs((store.data and store.data.nodes) or {}) do
                    if n.file == file and (n.kind == 'function' or n.kind == 'method') then
                        names[#names + 1] = n.name
                        if n.name == name then hit = n end
                    end
                end
                if not hit then
                    local near = {}
                    for _, c in ipairs(require('cartograph.near').within(name, names)) do near[#near + 1] = file .. '::' .. c.value end
                    return nil, ('param `%s`: no function %s in %s%s'):format(k, name, file,
                        #near > 0 and (' — did you mean ' .. table.concat(near, ' or ') .. '?') or ''), 'ill-posed'
                end
                v = store.ref_of(hit.id)
            elseif type(v) ~= 'table' then
                return nil, ('param `%s` must be a ref (a table or file::name)'):format(k), 'ill-posed'
            end
        elseif base == 'string' then
            if type(v) ~= 'string' then return nil, ('param `%s` must be a string'):format(k), 'ill-posed' end
            local path = v:match('^@(.+)$')
            if path then
                local fd = io.open(path)
                if not fd then return nil, ('param `%s`: cannot read %s'):format(k, path), 'ill-posed' end
                -- ★ THE FILE'S BYTES, EXACTLY: stripping a final newline here (for a definition written by writefile) made
                -- every file CREATED through the edit verb lose its own (19 files, 2026-09-28) — a caller that wants a
                -- trimmed text trims it
                v = fd:read('a'); fd:close()
            end
        elseif base == 'list' then
            if type(v) == 'string' then
                local l = {}
                for item in v:gmatch('[^,]+') do l[#l + 1] = item end
                v = l
            elseif type(v) ~= 'table' then
                return nil, ('param `%s` must be a list (a table or a,b,c)'):format(k), 'ill-posed'
            end
        end
        out[k] = v
    end
    return out
end

--- ★ A TACTIC FROM AN EXAMPLE, as SOURCE: learn the rule `before -> after` demonstrates (cartograph.byexample) and render
--- the toolbelt entry that carries it. The file stores the EXAMPLE, not the learned rule — the rule is re-derived each
--- run, so the example stays the single source of truth — and the DEMONSTRATION IS ITS FIRST EXAMPLE, so the tactic is
--- born with its own test. Writing it is the `learn-tactic` verb's (a journaled create, run by learn-from-example).
--- opts: { name, before, after, summary? } -> source | nil, why
function M.learned_source(opts)
    opts = opts or {}
    local name = opts.name
    if type(name) ~= 'string' or not name:match('^[%w][%w%-_]*$') then
        return nil, 'a tactic needs a NAME of letters, digits, - and _ (it is the file name)', 'ill-posed'
    end
    local rules, why, why_class = require('cartograph.byexample').learn(opts.before or '', opts.after or '')
    if not rules then return nil, why, why_class or 'ill-posed' end
    local rt = {}
    for _, r in ipairs(rules) do rt[#rt + 1] = ('%s -> %s'):format(r.lhs_text, r.rhs_text) end
    -- a long-bracket level no line of either text can close
    local lvl = 0
    while (opts.before .. opts.after):find(']' .. ('='):rep(lvl) .. ']', 1, true) do lvl = lvl + 1 end
    local function q(s) return '[' .. ('='):rep(lvl) .. '[\n' .. s .. ']' .. ('='):rep(lvl) .. ']' end
    local summary = opts.summary or ('rewrite by example: %s (scope = all | a,b)'):format(table.concat(rt, ', '))
    local src = table.concat({
        ('-- %s: a tactic LEARNED FROM AN EXAMPLE (toolbelt.learn, %s). The rule is re-derived from BEFORE -> AFTER'):format(name, os.date('%Y-%m-%d')),
        ('-- each run (cartograph.byexample): %s. The example is a CLAIM, not a proof — the specs are the oracle.'):format(table.concat(rt, ', ')),
        "local T = require('cartograph.tactic').T",
        'local BEFORE = ' .. q(opts.before),
        'local AFTER = ' .. q(opts.after),
        'local function read(root, rel) local fd = io.open(root .. "/" .. rel); if not fd then return nil end; local s = fd:read("a"); fd:close(); return s end',
        'return {',
        ('    name = %q,'):format(name),
        "    kind = 'write',",
        ('    summary = %q,'):format(summary),
        "    params = { scope = 'string?' },",
        "    build = function (p) return T.step('rewrite-by-example', { before = BEFORE, after = AFTER, scope = p.scope }) end,",
        '    examples = {',
        '        {',
        "            name = 'the demonstration itself: run on BEFORE with scope = all, it produces AFTER',",
        "            files = { ['example.lua'] = BEFORE .. '\\n' },",
        "            params = { scope = 'all' },",
        "            expect = { status = 'done', applied = 1, check = function (root)",
        "                return read(root, 'example.lua') == AFTER .. '\\n', 'the demonstration did not reproduce AFTER'",
        '            end },',
        '        },',
        '        {',
        "            name = 'without a scope it STOPS to ask where — the matches are inferred',",
        "            files = { ['example.lua'] = BEFORE .. '\\n' },",
        "            expect = { status = 'stopped', applied = 0 },",
        '        },',
        '    },',
        '}',
        '',
    }, '\n')
    return src
end

--- ★ BORN WITH ITS OWN TEST: load an entry SOURCE from a scratch directory and run every one of its examples. In
--- process: each example runs in a SCOPED LENS (M.example), so the caller's graph is untouched. (This ran in a
--- separate nvim for a while: an in-process example used to re-ingest the singleton store, and the learn plan was then
--- built against the example's temp root — the learned file landed in a vanished directory while the run said done.)
--- -> true | false, why
function M.validate_source(name, src)
    local d = vim.fn.tempname(); vim.fn.mkdir(d, 'p')
    local fd = assert(io.open(d .. '/' .. name .. '.lua', 'w')); fd:write(src); fd:close()
    local e, why = M.load(name, d)
    if not e then vim.fn.delete(d, 'rf'); return false, 'it does not load: ' .. tostring(why) end
    for _, ex in ipairs(e.examples) do
        local ok, xwhy = M.example(e, ex)
        if not ok then vim.fn.delete(d, 'rf'); return false, ('it fails its own examples (%s): %s'):format(ex.name, tostring(xwhy)) end
    end
    vim.fn.delete(d, 'rf')
    return true
end

--- a plan CREATING one file `rel` under the graph root with `src` (the learn-tactic and promote-tactic verbs)
local function create_plan(store, verb, rel, src, desc, hazards, root)
    local txn = require 'cartograph.txn'
    return txn.protocol({ verb = verb, guards = { 'parses' }, generation = store.generation,
        touched = { rel }, creates = { [rel] = true }, stamps = { [rel] = txn.disk_stamp(root or store.data.root, rel) },
        refspecs = {}, hazards = hazards or {}, src = src, rel = rel,
        -- a NEW file: no existing symbol's behaviour changes
        preserves = 'all', preserves_why = 'it creates a new tactic file and edits nothing that exists',
        desc = desc },
        function (p) return function (r, before) if r == p.rel then return p.src end return before end end)
end

--- the `learn-tactic` verb: a journaled CREATE of `.cartograph/tactics/<name>.lua` in the analysed project, planned
--- only after the rendered entry passes its own examples. Re-run: an identical file is `empty`; a different one is
--- never overwritten.
function M.plan_learn(store, args)
    local txn = require 'cartograph.txn'
    local src, why, why_class = M.learned_source(args)
    if not src then return nil, why, why_class or 'ill-posed' end
    local rel = '.cartograph/tactics/' .. args.name .. '.lua'
    local existing = txn.read_file(store.data.root, rel)
    if existing == src then return nil, ('%s already holds this learned tactic'):format(rel), 'empty' end
    if existing then return nil, ('%s already exists and differs — a learned tactic never overwrites one'):format(rel), 'ill-posed' end
    if M.files()[args.name] then
        return nil, ('a BUILT-IN tactic is named `%s` — a project tactic never shadows one; pick another name'):format(args.name), 'ill-posed'
    end
    local ok, vwhy = M.validate_source(args.name, src)
    if not ok then return nil, ('the learned tactic was not written: %s'):format(vwhy), 'unbuilt' end
    return create_plan(store, 'learn-tactic', rel, src, ('learn tactic %s from an example'):format(args.name))
end

--- the `promote-tactic` verb: copy a PROJECT tactic into the BUILT-IN toolbelt. The graph must be the repository that
--- holds the built-in directory (the write is journaled against it). ★ ALWAYS A DECISION (`promote`): a promoted tactic
--- is in every session's toolbelt, so someone reads it first. Re-run: an identical built-in is `empty`.
--- args: { name, from = the project root, into? = the built-in directory (a test points it elsewhere) }
function M.plan_promote(store, args)
    local txn = require 'cartograph.txn'
    local name = args.name
    if type(name) ~= 'string' or name == '' then return nil, 'promote which tactic? (`name`)', 'ill-posed' end
    local src_path = M.project_dir(args.from or store.data.root) .. '/' .. name .. '.lua'
    local src = slurp(src_path)
    if not src then return nil, ('no project tactic %s'):format(src_path), 'ill-posed' end
    local root = store.data.root
    local into = (args.into or dir()):gsub('/+$', '')
    -- ★ INSIDE this graph's world, a plain write; OUTSIDE it, a CROSS-WORLD write into the toolbelt's own world
    -- (CART-1160 step 5) — it used to refuse with "run it with that repository as the graph"
    local inside = into:sub(1, #root + 1) == root .. '/'
    local wroot = inside and root or into
    local rel = inside and (into:sub(#root + 2) .. '/' .. name .. '.lua') or (name .. '.lua')
    local existing = txn.read_file(wroot, rel)
    if existing == src then return nil, ('`%s` is already promoted'):format(name), 'empty' end
    if existing then return nil, ('a built-in `%s` exists and differs — promotion never overwrites one'):format(name), 'ill-posed' end
    local ok, vwhy = M.validate_source(name, src)
    if not ok then return nil, ('`%s` was not promoted: %s'):format(name, vwhy), 'unbuilt' end
    -- the ONE question: promoting reaches every session, and (outside this world) it is also the grant to write there
    local hz = require('cartograph.hazard').new('promote', ('promoting `%s` puts it in EVERY session\'s toolbelt — read %s and its examples first%s')
        :format(name, src_path, inside and '' or (' (it writes %s, another world)'):format(into)),
        nil, { from = src_path, target = (not inside) and into or nil }, 'decision')
    local plan = create_plan(store, 'promote-tactic', rel, src, ('promote tactic %s into the built-in toolbelt'):format(name), { hz }, wroot)
    if plan and not inside then txn.target(plan, into, 'promotion writes the built-in toolbelt') end
    return plan
end

--- run an entry against the current graph.
--- write:     -> tactic.run's result (opts: apply, on_stop, correct), with the entry's oracle as the kernel
--- discovery: -> { value, holds, why }
function M.run(store, name, params, opts)
    opts = opts or {}
    local e, why, why_class = M.load(name, opts.dir, store.data and store.data.root)
    if not e then return nil, why, why_class or 'ill-posed' end
    local cls
    params, why, cls = M.coerce(store, e, params)
    if not params then return nil, why, cls or 'ill-posed' end
    if e.kind == 'discovery' then
        local okm, value = pcall(e.measure, store, params or {})
        if not okm then return nil, ('%s: the measurement raised: %s'):format(name, tostring(value)), 'unbuilt' end
        local holds, cwhy = e.claim(value)
        return { value = value, holds = holds and true or false, why = cwhy }
    end
    local term = e.build(params or {})
    local ropts = { apply = opts.apply, on_stop = opts.on_stop, correct = opts.correct, verbs = opts.verbs,
        approvals = opts.approvals }
    if e.oracle then ropts.oracle = function (st, res) return e.oracle(st, res, params or {}) end end
    return require('cartograph.tactic').run(store, term, ropts)
end

--- run ONE example of an entry on a fresh temp root: -> ok, why, result
--- ★ IN A SCOPED LENS (store.scoped, CART-1160): the example's scratch graph is active only while it runs, and the
--- CALLER's graph comes back afterwards — so any caller may run an example, a live session included. Before, an
--- example re-ingested the singleton store and replaced whatever the caller had loaded.
function M.example(e, ex)
    local store = require 'cartograph.store'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    for rel, text in pairs(ex.files or {}) do
        local d = (root .. '/' .. rel):match('^(.*)/[^/]*$')
        vim.fn.mkdir(d, 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return store.scoped(require('cartograph.providers.treesitter').extract(root), function ()
        local params = type(ex.params) == 'function' and ex.params(store) or (ex.params or {})
        local res, why = M.run(store, e.name, params, { apply = e.kind == 'write', on_stop = ex.on_stop,
            dir = e.path and vim.fn.fnamemodify(e.path, ':h') })
        if not res then return false, why end
        local want = ex.expect or {}
        if e.kind == 'discovery' then
            if want.holds ~= nil and res.holds ~= want.holds then
                return false, ('expected the claim to %s, it %s: %s'):format(want.holds and 'hold' or 'fail',
                    res.holds and 'held' or 'failed', tostring(res.why)), res
            end
            if want.check then local okc, cw = want.check(res.value); if not okc then return false, cw, res end end
        else
            if want.status and res.status ~= want.status then
                return false, ('expected status %s, got %s (%s)'):format(want.status, tostring(res.status), tostring(res.why)), res
            end
            if want.applied and res.applied ~= want.applied then
                return false, ('expected %d applied, got %d'):format(want.applied, res.applied), res
            end
            if want.check then local okc, cw = want.check(root, res); if not okc then return false, cw, res end end
        end
        return true, nil, res
    end)
end

return M
