-- cartograph.k8sapi — KUBERNETES' OWN API TYPES as the source of what k8s.lua reads (CART-1267, CART-1296).
--
-- The Go structs under k8s.io/api (a kubernetes checkout's staging/src/k8s.io/api) ARE the schema: every KIND is a
-- type its group registers (`scheme.AddKnownTypes(…, &Deployment{}, …)` in register.go, the group its
-- `const GroupName`), every field has its JSON name in its struct tag, an embedded struct (`json:",inline"` or untagged)
-- lends its fields to the embedder, and a type is resolved in ITS package (an unqualified name) or through the file's
-- imports (`corev1.PodTemplateSpec`) — struct names repeat across packages (core's ResourceClaim is not resource's).
-- From that, two things k8s.lua used to list by hand are DERIVED:
--   POD TEMPLATES  every path from a kind to a PodSpec (Deployment spec.template.spec, CronJob
--                  spec.jobTemplate.spec.template.spec, Pod spec, PodTemplate template.spec …)
--   SOFT EDGES     every field that NAMES another object without owning it (design kubernetes/: the edges the garbage
--                  collector does not walk): a REFERENCE struct (a *Reference / *Ref type, or a struct embedding one:
--                  ConfigMapEnvSource, SecretKeySelector …), a `<x>Name` string, a SELECTOR — each with its TARGET KIND
-- THE TARGET is read from the SOURCE'S OWN WORDS, in order: (1) the json name's stem (secretRef, configMapKeyRef,
-- imagePullSecrets, serviceAccountName, namespaceSelector -> Secret, ConfigMap, Secret, ServiceAccount, Namespace) —
-- a kind equal to the stem, else the ONE kind the stem ends (claim -> PersistentVolumeClaim | ResourceClaim, the tie
-- broken by the containing struct's name: PersistentVolumeClaimVolumeSource); (2) a reference struct with its own
-- `kind` field names it at run time (scaleTargetRef, dataSourceRef: target nil); (3) a SELECTOR's doc comment — the
-- first kind it mentions ("Label selector for pods", "a label query over volumes"); a field whose words name no kind is
-- not an edge (schedulerName, signerName, a metric's selector).
local M = {}

local function readfile(p) local fd = io.open(p, 'rb'); if not fd then return nil end local s = fd:read('a'); fd:close(); return s end

--- a Go type expression -> qualifier (or nil), named type, shape ('one' | 'list' | 'map')
local function parse_type(t)
    t = t:gsub('%s+', '')
    local shape = 'one'
    if t:match('^map%[') then shape = 'map'; t = t:gsub('^map%b[]', '') end
    if t:match('^%[%]') then if shape ~= 'map' then shape = 'list' end t = t:gsub('^%[%]', '') end
    t = t:gsub('^%*', ''):gsub('^%[%]', ''):gsub('^%*', '')
    local q, n = t:match('^([%w_]+)%.([%w_]+)$')
    if q then return q, n, shape end
    return nil, t:match('([%w_]+)$') or t, shape
end
M._parse_type = parse_type

--- one Go file -> its structs added to pkg.structs, each field's type resolved to { pkg = path | false, name }
local function read_file(src, pkg, pkgs_by_import)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'go')
    if not ok then return end
    local root = parser:parse()[1]:root()
    local function tx(n) return vim.treesitter.get_node_text(n, src) end
    -- (the file's IMPORTS: alias -> import path; the alias defaults to the path's last element)
    local imports = {}
    for _, node in vim.treesitter.query.parse('go', '(import_spec) @s'):iter_captures(root, src, 0, -1) do
        local pathn, namen = node:field('path')[1], node:field('name')[1]
        local path = pathn and (tx(pathn):gsub('"', ''))
        if path then imports[namen and tx(namen) or path:match('([^/]+)$')] = path end
    end
    local q = vim.treesitter.query.parse('go', '(type_spec name: (type_identifier) @n type: (struct_type) @s)')
    local cur
    for id, node in q:iter_captures(root, src, 0, -1) do
        local cap = q.captures[id]
        if cap == 'n' then cur = tx(node); pkg.structs[cur] = { fields = {} }
        elseif cap == 's' and cur then
            local list = node:named_child(0)
            local comment = {}
            for fd in (list and list:iter_children() or function () end) do
                if fd:type() == 'comment' then comment[#comment + 1] = tx(fd):gsub('^//%s?', '')
                elseif fd:type() == 'field_declaration' then
                    local names, ty, tag = {}, fd:field('type')[1], fd:field('tag')[1]
                    for _, nm in ipairs(fd:field('name')) do names[#names + 1] = tx(nm) end
                    local tagtext = tag and tx(tag) or ''
                    local jname = tagtext:match('json:"([^",]*)')
                    local qual, tname, shape = parse_type(ty and tx(ty) or '')
                    local tpkg = qual and (pkgs_by_import[imports[qual] or ''] and imports[qual] or false) or pkg.path
                    local doc = table.concat(comment, ' ')
                    comment = {}
                    if #names == 0 then
                        local inline = (jname == nil or jname == '') or tagtext:find('inline', 1, true) ~= nil
                        table.insert(pkg.structs[cur].fields, { json = (not inline) and jname or nil, type = { pkg = tpkg, name = tname }, shape = shape, inline = inline, doc = doc })
                    else
                        for _, nm in ipairs(names) do
                            if jname ~= '-' then table.insert(pkg.structs[cur].fields, { json = jname or nm, type = { pkg = tpkg, name = tname }, shape = shape, doc = doc }) end
                        end
                    end
                else comment = {} end
            end
            cur = nil
        end
    end
end

--- the API packages under `dir` (…/staging/src/k8s.io/api) -> schema { pkgs = { [import path] = { group, version,
--- structs } }, kinds = { [Kind] = { pkg, group, version } } } | nil, why. A kind registered by several versions or groups
--- keeps the FIRST GA one (v1 over v1beta1; core over events for Event).
function M.read(dir)
    dir = vim.fn.fnamemodify(dir, ':p'):gsub('/$', '')
    local regs = vim.fn.glob(dir .. '/*/*/register.go', false, true)
    if #regs == 0 then return nil, 'no <group>/<version>/register.go under ' .. dir end
    local pkgs = {}
    for _, reg in ipairs(regs) do
        local pdir = vim.fn.fnamemodify(reg, ':h')
        local rel = pdir:sub(#dir + 2)
        local path = 'k8s.io/api/' .. rel
        local regtext = readfile(reg) or ''
        pkgs[path] = { path = path, dir = pdir, group = regtext:match('GroupName%s*=%s*"([^"]*)"') or '', version = vim.fn.fnamemodify(pdir, ':t'), structs = {}, reg = regtext }
    end
    local cluster = {}
    for _, pkg in pairs(pkgs) do
        for _, f in ipairs(vim.fn.glob(pkg.dir .. '/*.go', false, true)) do
            local base = vim.fn.fnamemodify(f, ':t')
            if not base:find('_test%.go$') and not base:find('^generated') and not base:find('^zz_generated') then
                local text = readfile(f) or ''
                read_file(text, pkg, pkgs)
                -- (CLUSTER-SCOPED kinds: the client generator's `+genclient:nonNamespaced` marker in the comment block
                -- right above `type X struct`)
                local block = false
                for line in text:gmatch('[^\n]*') do
                    if line:match('^//') then if line:find('+genclient:nonNamespaced', 1, true) then block = true end
                    else
                        local name = line:match('^type ([%u][%w_]*) struct')
                        if name and block then cluster[name] = true end
                        if line:match('%S') then block = false end
                    end
                end
            end
        end
    end
    -- the KINDS (a List / Options type is registered but is not an object a manifest declares)
    local kinds = {}
    local function rank(p) local v = p.version; return (v:match('^v%d+$') and 0 or 1), p.path end
    local order = vim.tbl_values(pkgs)
    table.sort(order, function (a, b) local ra, pa = rank(a); local rb, pb = rank(b); if ra ~= rb then return ra < rb end return pa < pb end)
    for _, pkg in ipairs(order) do
        for body in pkg.reg:gmatch('AddKnownTypes(%b())') do
            for k in body:gmatch('&([%u][%w_]*)%s*{%s*}') do
                if not k:find('List$') and not k:find('Options$') and not kinds[k] and pkg.structs[k] then
                    kinds[k] = { pkg = pkg.path, group = pkg.group, version = pkg.version }
                end
            end
        end
    end
    return { pkgs = pkgs, kinds = kinds, cluster = cluster }
end

--- a struct's fields with embedded (inline) structs flattened in -> { { json, type, shape, doc, owner } }
local function fields_of(S, ref, seen)
    seen = seen or {}
    local key = tostring(ref.pkg) .. '.' .. ref.name
    if seen[key] then return {} end
    seen[key] = true
    local pkg = ref.pkg and S.pkgs[ref.pkg]
    local st = pkg and pkg.structs[ref.name]
    local out = {}
    for _, f in ipairs(st and st.fields or {}) do
        if f.inline then
            for _, g in ipairs(fields_of(S, f.type, seen)) do out[#out + 1] = g end
        elseif f.json then out[#out + 1] = { json = f.json, type = f.type, shape = f.shape, doc = f.doc, owner = ref.name } end
    end
    seen[key] = nil
    return out
end
M._fields_of = fields_of

local function struct_of(S, ref) local p = ref.pkg and S.pkgs[ref.pkg]; return p and p.structs[ref.name] end

--- REFERENCE structs: a *Reference / *Ref type, and every struct embedding one -> { [pkg.name] = { kindfield } }
local function ref_structs(S)
    local R = {}
    for path, pkg in pairs(S.pkgs) do
        for name, st in pairs(pkg.structs) do
            local kf, nf = false, false
            for _, f in ipairs(st.fields) do if f.json == 'kind' then kf = true elseif f.json == 'name' then nf = true end end
            -- (a *Reference / *Ref type by NAME, or a reference by SHAPE: a struct carrying both a `kind` and a `name` —
            -- RBAC's Subject — names an object of a run-time kind)
            if name:find('Reference$') or name:find('Ref$') or (kf and nf) then R[path .. '.' .. name] = { kindfield = kf } end
        end
    end
    -- (the meta/v1 references live outside k8s.io/api: an EXTERNAL *Reference type is a reference by its name)
    local changed = true
    while changed do
        changed = false
        for path, pkg in pairs(S.pkgs) do
            for name, st in pairs(pkg.structs) do
                if not R[path .. '.' .. name] then
                    for _, f in ipairs(st.fields) do
                        local inner = R[tostring(f.type.pkg) .. '.' .. f.type.name]
                        if f.inline and inner then R[path .. '.' .. name] = { kindfield = inner.kindfield }; changed = true; break end
                    end
                end
            end
        end
    end
    return R
end

--- the kind a WORD names: equal to a kind (case-insensitive, a trailing s dropped), else the ONE kind it ends;
--- several -> the one `owner` begins with -> Kind | nil
local function kind_of_word(S, word, owner)
    local w = word:lower():gsub('s$', '')
    if w == '' then return nil end
    local exact, ends = nil, {}
    for k in pairs(S.kinds) do
        local lk = k:lower()
        if lk == w or lk == word:lower() then exact = k end
        if #w >= 4 and lk:sub(-#w) == w then ends[#ends + 1] = k end
    end
    if exact then return exact end
    if #ends == 1 then return ends[1] end
    if #ends > 1 and owner then
        local best
        for _, k in ipairs(ends) do if owner:sub(1, #k) == k and (not best or #k > #best) then best = k end end
        return best
    end
    return nil
end
M._kind_of_word = kind_of_word

--- a json name's STEM: secretKeyRef -> secret, imagePullSecrets -> imagePullSecret, serviceAccountName -> serviceAccount
local function stem(j)
    for _, suf in ipairs({ 'KeyRef', 'Refs', 'Ref', 'Names', 'Name', 'Selector' }) do
        if #j > #suf and j:sub(-#suf) == suf then return j:sub(1, -#suf - 1) end
    end
    return j
end

--- the first kind a doc comment mentions ("Label selector for pods" -> Pod) | nil
local function kind_in_doc(S, doc, self)
    for word in (doc or ''):gmatch('[%a]+') do
        if #word >= 3 then
            local k = kind_of_word(S, word)
            -- (not the kind declaring the selector: a selector selects OTHER objects — a Service's comment says
            -- "service traffic … pods")
            if k and k ~= self and not ({ Binding = 1, Status = 1, Scale = 1, Event = 1 })[k] then return k end
        end
    end
    return nil
end

--- the camel-case TAIL of a stem that names a kind: imagePullSecret -> Secret (the longest tail that does) | nil
local function kind_of_stem(S, st, owner)
    local k = kind_of_word(S, st, owner)
    if k then return k end
    -- (a compound stem: its camel-case tails, longest first — imagePullSecret: PullSecret, Secret)
    local i = 2
    while i <= #st do
        local c = st:sub(i, i)
        if c:match('%u') then
            local t = kind_of_word(S, st:sub(i), owner)
            if t then return t end
        end
        i = i + 1
    end
    return nil
end

--- DERIVE what k8s.lua reads -> { pod = { [Kind] = { path, … } }, refs = { { kind, path, target | nil (a run-time
--- `kind` field names it), how = 'ref' | 'name' | 'selector' } } }. Paths are JSON names joined by '.', a list element
--- `[]`, a map value `{}`; the walk stops at depth `opts.depth` (default 10) and never re-enters a struct on its path.
function M.derive(S, opts)
    opts = opts or {}
    local maxd = opts.depth or 10
    local R = ref_structs(S)
    local pod, refs, seen, probes = {}, {}, {}, {}
    local kl = vim.tbl_keys(S.kinds); table.sort(kl)
    for _, K in ipairs(kl) do
        local root = { pkg = S.kinds[K].pkg, name = K }
        local function walk(ref, path, depth, onpath)
            local key = tostring(ref.pkg) .. '.' .. ref.name
            if depth > maxd or onpath[key] then return end
            onpath[key] = true
            for _, f in ipairs(fields_of(S, ref)) do
                local p = (path == '' and '' or path .. '.') .. f.json .. (f.shape == 'list' and '[]' or f.shape == 'map' and '{}' or '')
                local tkey = tostring(f.type.pkg) .. '.' .. f.type.name
                local function add(target, how)
                    local k2 = K .. '\0' .. p
                    if not seen[k2] then seen[k2] = true; refs[#refs + 1] = { kind = K, path = p, target = target, how = how } end
                end
                if f.type.name == 'PodSpec' and f.shape == 'one' and f.type.pkg == 'k8s.io/api/core/v1' then
                    pod[K] = pod[K] or {}; table.insert(pod[K], p)
                end
                -- (a PROBE — readiness / liveness / startup — is a CALL the kubelet makes into the container: every
                -- field typed core Probe, CART-0834)
                if f.type.name == 'Probe' and f.type.pkg == 'k8s.io/api/core/v1' then
                    probes[K] = probes[K] or {}; table.insert(probes[K], p)
                end
                local isref = R[tkey] or (f.type.pkg == false and (f.type.name:find('Reference$') or f.type.name:find('Ref$')))
                if isref then
                    -- (the field's own words first; a reference carrying its own `kind` is resolved at run time; only
                    -- then the reference TYPE's words — ConfigMapEnvSource — never a generic tail like `Reference`)
                    -- (a reference with its OWN `kind` field is resolved at run time first: roleRef's kind is Role OR
                    -- ClusterRole, whatever its name says)
                    local target = not (R[tkey] and R[tkey].kindfield) and kind_of_stem(S, stem(f.json), f.owner) or nil
                    if target then add(target, 'ref')
                    elseif R[tkey] and R[tkey].kindfield then add(nil, 'ref')
                    else
                        target = kind_of_word(S, f.type.name:match('^(%u%l+%u?%l*)') or '', f.owner) or kind_of_word(S, f.type.name:match('^(%u%l+)') or '', f.owner)
                        if target then add(target, 'ref') end
                    end
                elseif f.type.name == 'LabelSelector' or (f.json:find('[sS]elector$') and f.shape == 'map') then
                    local target = (f.json ~= 'selector' and kind_of_stem(S, stem(f.json), f.owner)) or kind_in_doc(S, f.doc, K)
                    if target then add(target, 'selector') end
                elseif f.json == 'name' and f.type.name == 'string' and f.shape == 'one' and f.owner ~= 'ObjectMeta' then
                    -- (a plain `name` whose doc says it IS a reference, in the ACTIVE forms only: IngressServiceBackend's
                    -- "name is the referenced service" / "refers to the X" — a port that "can be referred to by
                    -- services" is a name others use, not a reference it makes)
                    local doc = (f.doc or ''):lower()
                    local word = doc:match('referenced%s+([%a]+)') or doc:match('refers%s+to%s+an?%s+([%a]+)') or doc:match('refers%s+to%s+the%s+([%a]+)') or doc:match('refers%s+to%s+([%a]+)')
                    local target = word and kind_of_word(S, word)
                    if target then add(target, 'name') end
                elseif f.type.name == 'string' and f.shape == 'one' and f.json:find('Name$') then
                    local target = kind_of_stem(S, stem(f.json), f.owner)
                    -- (a stem that only ENDS a kind's name — volume, claim — is a reference only where the field's doc
                    -- names that kind in full: a PVC's volumeName "the PersistentVolume backing this claim", not
                    -- scaleIO's "a volume already created in the ScaleIO system")
                    if target and target:lower() ~= stem(f.json):lower() and not (f.doc or ''):lower():find(target:lower(), 1, true) then target = nil end
                    if target then add(target, 'name') end
                end
                if not isref and struct_of(S, f.type) then walk(f.type, p, depth + 1, onpath) end
            end
            onpath[key] = nil
        end
        walk(root, '', 1, {})
    end
    for _, l in pairs(pod) do table.sort(l) end
    for _, l in pairs(probes) do table.sort(l) end
    table.sort(refs, function (a, b) return a.kind .. a.path < b.kind .. b.path end)
    -- (the probe HANDLER's fields by their TYPE: which json name holds a gRPC action, which an HTTP GET)
    local handler = {}
    local core = S.pkgs['k8s.io/api/core/v1']
    for _, f in ipairs(core and core.structs.ProbeHandler and core.structs.ProbeHandler.fields or {}) do
        if f.type.name == 'GRPCAction' then handler.grpc = f.json elseif f.type.name == 'HTTPGetAction' then handler.http = f.json end
    end
    return { pod = pod, refs = refs, probes = probes, probe_handler = handler }
end

--- the TABLE k8s.lua reads (what is derived, nothing of the walk) -> { stamp, pod = { [Kind] = path }, refs, cluster =
--- { [Kind] = true }, group = { [Kind] = group } }
function M.table(S, D, stamp)
    local t = { stamp = stamp, pod = {}, refs = {}, cluster = {}, group = {}, probes = D.probes or {},
        probe_grpc = D.probe_handler and D.probe_handler.grpc or false, probe_http = D.probe_handler and D.probe_handler.http or false }
    for k, paths in pairs(D.pod) do t.pod[k] = paths[1] end
    for _, r in ipairs(D.refs) do t.refs[#t.refs + 1] = { r.kind, r.path, r.target or false, r.how } end
    for k, info in pairs(S.kinds) do
        t.group[k] = info.group
        if S.cluster[k] then t.cluster[k] = true end
    end
    return t
end

--- the table as Lua source, DETERMINISTIC (sorted keys, one entry per line): the generated file and its drift check
function M.serialize(t, header)
    local o = { header or '', 'return {', ('    stamp = %q,'):format(t.stamp or '') }
    local function map(name, m, fmt)
        o[#o + 1] = '    ' .. name .. ' = {'
        local ks = vim.tbl_keys(m); table.sort(ks)
        for _, k in ipairs(ks) do o[#o + 1] = ('        %s = %s,'):format(k, fmt(m[k])) end
        o[#o + 1] = '    },'
    end
    map('pod', t.pod, function (v) return ('%q'):format(v) end)
    map('cluster', t.cluster, function () return 'true' end)
    map('group', t.group, function (v) return ('%q'):format(v) end)
    map('probes', t.probes or {}, function (v)
        local q = {}
        for _, p in ipairs(v) do q[#q + 1] = ('%q'):format(p) end
        return '{ ' .. table.concat(q, ', ') .. ' }'
    end)
    o[#o + 1] = ('    probe_grpc = %s,'):format(t.probe_grpc and ('%q'):format(t.probe_grpc) or 'false')
    o[#o + 1] = ('    probe_http = %s,'):format(t.probe_http and ('%q'):format(t.probe_http) or 'false')
    o[#o + 1] = '    refs = {'
    for _, r in ipairs(t.refs) do
        o[#o + 1] = ('        { %q, %q, %s, %q },'):format(r[1], r[2], r[3] and ('%q'):format(r[3]) or 'false', r[4])
    end
    o[#o + 1] = '    },'
    o[#o + 1] = '}'
    return table.concat(o, '\n') .. '\n'
end

--- the shipped, GENERATED table (tools/k8sapi.lua writes it from a kubernetes checkout) -> table | nil
function M.load()
    local ok, t = pcall(require, 'cartograph.k8sapi_table')
    return ok and type(t) == 'table' and t or nil
end

return M
