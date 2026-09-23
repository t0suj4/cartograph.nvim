-- helmfile.lua — the HELM RELEASE layer: which charts run where, with which values, layered
-- how (CART-1042). Session post-pass, same family as k8s.lua / proto.lua / ansible.lua.
--
-- ★ WHY A SEPARATE ADAPTER FROM k8s.lua. k8s reads PLAIN MANIFESTS (a document with `kind:`)
-- and refuses the rest. A helmfile repo holds no manifests at all: `clusters/<name>.yaml`
-- declares RELEASES (chart, pinned version, namespace, needs) and each release LAYERS values
-- files — shared `config/x.yaml`, then `config/<cluster>/x.yaml`. MEASURED on
-- jenkins-infra/kubernetes-management: k8s refused all 113 documents (and, until CART-1043,
-- said nothing). The values are data, not templates, so this reads them whole
-- (`yamlvalue`) and CLAIMS the files, so k8s no longer counts them as failed manifests.
--
-- ── WHAT IT MINTS AND WHAT IT KEEPS ON `data.helmfile` ───────────────────────────────
-- Nodes: each helmfile and each values file it reads is a `module` node (the proto/k8s
-- convention; a `release`/`workload` kind is CART-0140's schema change, not this file's).
-- Edges: helmfile -> values file, kind `use` (a soft "refers to"; `import` feeds the
-- portability and preflight walks, which a yaml reference must not enter).
-- Data: every release with its EFFECTIVE values (the layers merged by Helm's rule), the
-- layers' states (read / templated / missing / inline), secrets as a named FRONTIER (they
-- live in a private repo), no-op overrides, served hosts, chart families and version skew.
--
-- ⚠ A `.gotmpl` VALUES FILE IS A TEMPLATE, NOT DATA: it is counted and skipped, so the
-- effective values of a release that uses one are a LOWER BOUND, and the release says so.

local M = {}

local Y = require 'cartograph.yamlvalue'

local function readf(p)
    local fd = io.open(p, 'rb'); if not fd then return nil end
    local s = fd:read('*a'); fd:close(); return s
end

-- a root-relative path from a helmfile-relative one, `..` resolved; nil when it leaves the root
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

local function copy(v)
    if type(v) ~= 'table' then return v end
    if v.o then
        local o, keys = {}, {}
        for _, k in ipairs(v.keys) do o[k] = copy(v.o[k]); keys[#keys + 1] = k end
        return { o = o, keys = keys }
    end
    if v.a then local a = {}; for i, x in ipairs(v.a) do a[i] = copy(x) end; return { a = a } end
    return v
end

--- ★ HELM'S MERGE: a later values file wins; maps merge recursively, everything else
--- (scalars AND lists) replaces; an explicit `null` deletes the key.
function M.merge(base, over)
    if type(base) ~= 'table' or not base.o or type(over) ~= 'table' or not over.o then return copy(over) end
    local out = copy(base)
    for _, k in ipairs(over.keys) do
        local v = over.o[k]
        if v == 'null' or v == '~' then
            if out.o[k] ~= nil then
                out.o[k] = nil
                local ks = {}
                for _, x in ipairs(out.keys) do if x ~= k then ks[#ks + 1] = x end end
                out.keys = ks
            end
        else
            if out.o[k] == nil then out.keys[#out.keys + 1] = k end
            out.o[k] = M.merge(out.o[k], v)
        end
    end
    return out
end

--- Leaves in `over` that restate `base` at the same path: an override that changes nothing.
function M.noops(base, over, path, out)
    out = out or {}
    path = path or '$'
    local A = require('cartograph.algebra').load()
    if type(over) == 'table' and over.o then
        for _, k in ipairs(over.keys) do
            local b = type(base) == 'table' and base.o and base.o[k]
            if b ~= nil then M.noops(b, over.o[k], path .. '.' .. k, out) end
        end
    elseif base ~= nil and A.kv_eq(base, over) then
        out[#out + 1] = path
    end
    return out
end

local HOSTKEY = { host = true, hosts = true, hostname = true, domain = true }
--- Hostnames under host-ish keys (`host`, `hosts`, `hostname`, `domain`), with their paths.
--- ⚠ A KEY-NAME RULE, and it says so: a hostname stored under any other key is not seen.
function M.hosts(v, path, out, under)
    out = out or {}
    path = path or '$'
    if type(v) == 'string' then
        if under and v:match('^[%w%-]+%.[%w%-%.]*%a$') then out[#out + 1] = { host = v, path = path } end
    elseif type(v) == 'table' and v.o then
        for _, k in ipairs(v.keys) do M.hosts(v.o[k], path .. '.' .. k, out, HOSTKEY[k] or false) end
    elseif type(v) == 'table' and v.a then
        for i, x in ipairs(v.a) do M.hosts(x, path .. '[' .. i .. ']', out, under) end
    end
    return out
end

--- Is this document a helmfile? (a mapping with a `releases` list)
local function is_helmfile(v)
    return type(v) == 'table' and v.o and type(v.o.releases) == 'table' and v.o.releases.a ~= nil
end

--- Read one helmfile into its releases, each with its layered, effective values.
--- @return table|nil hf { file, cluster, releases }, string|nil why
function M.read(root, rel)
    local src = readf(root .. '/' .. rel)
    if not src then return nil, 'unreadable: ' .. rel end
    local doc, why = Y.read_one(src)
    if not doc then return nil, rel .. ': ' .. tostring(why) end
    if not is_helmfile(doc) then return nil, rel .. ': not a helmfile (no `releases:` list)' end
    local dir = rel:match('^(.*)/[^/]+$') or ''
    local hf = { file = rel, cluster = rel:match('([^/]+)%.ya?ml$'), releases = {} }
    for _, r in ipairs(doc.o.releases.a) do
        if type(r) == 'table' and r.o then
            local rr = { name = r.o.name, namespace = r.o.namespace, chart = r.o.chart,
                version = r.o.version, needs = {}, layers = {}, secrets = {}, noops = {},
                effective = { o = {}, keys = {} }, lower_bound = false }
            for _, n in ipairs(r.o.needs and r.o.needs.a or {}) do rr.needs[#rr.needs + 1] = n end
            local read_layers = {}
            for _, vf in ipairs(r.o.values and r.o.values.a or {}) do
                if type(vf) ~= 'string' then
                    rr.layers[#rr.layers + 1] = { state = 'inline' }
                    rr.effective = M.merge(rr.effective, vf)
                    read_layers[#read_layers + 1] = vf
                else
                    local p = join(dir, vf)
                    local s = p and readf(root .. '/' .. p)
                    if not s then
                        rr.layers[#rr.layers + 1] = { file = p or vf, state = 'missing' }
                    elseif vf:match('%.gotmpl$') or s:find('{{', 1, true) then
                        rr.layers[#rr.layers + 1] = { file = p, state = 'templated' }
                        rr.lower_bound = true
                    else
                        local v, vwhy = Y.read_one(s)
                        if not v then
                            rr.layers[#rr.layers + 1] = { file = p, state = 'unreadable', why = vwhy }
                        else
                            for _, prev in ipairs(read_layers) do M.noops(prev, v, '$', rr.noops) end
                            rr.layers[#rr.layers + 1] = { file = p, state = 'read' }
                            rr.effective = M.merge(rr.effective, v)
                            read_layers[#read_layers + 1] = v
                        end
                    end
                end
            end
            for _, s in ipairs(r.o.secrets and r.o.secrets.a or {}) do
                rr.secrets[#rr.secrets + 1] = type(s) == 'string' and (join(dir, s) or s) or '(inline)'
            end
            rr.hosts = M.hosts(rr.effective)
            hf.releases[#hf.releases + 1] = rr
        end
    end
    return hf
end

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }

--- Mint the release layer into `data`. Idempotent under refresh.
--- @return table stats
function M.attach(data, opts)
    local stats = { helmfiles = 0, releases = 0, layers = 0, templated = 0, missing = 0,
        secrets = 0, noops = 0, hosts = 0, skew = 0, refusals = {} }
    if not data or not data.root then data.helmfile = nil; return stats end
    -- idempotence: drop what a previous attach minted
    local keep, mine = {}, {}
    for _, n in ipairs(data.nodes or {}) do if n.hf then mine[n.id] = true else keep[#keep + 1] = n end end
    if next(mine) then
        local edges = {}
        for _, e in ipairs(data.edges or {}) do if not (e.hf or mine[e.from] or mine[e.to]) then edges[#edges + 1] = e end end
        data.nodes, data.edges = keep, edges
    end
    local candidates = (opts and opts.files) or require('cartograph.k8s').find(data.root, opts and opts.transport)
    local hfs = {}
    for _, rel in ipairs(candidates) do
        local src = readf(data.root .. '/' .. rel)
        local doc = src and src:find('releases:', 1, true) and Y.read_one(src)
        if doc and is_helmfile(doc) then
            local hf, why = M.read(data.root, rel)
            if hf then hfs[#hfs + 1] = hf
            elseif #stats.refusals < 10 then stats.refusals[#stats.refusals + 1] = why end
        end
    end
    if #hfs == 0 then data.helmfile = nil; return stats end
    data.nodes = data.nodes or {}
    data.edges = data.edges or {}
    local claimed, minted = {}, {}
    local function node(rel)
        if minted[rel] then return end
        minted[rel] = true
        data.nodes[#data.nodes + 1] = { id = rel, name = rel, kind = 'module', file = rel, range = R0, order = 0, hf = true }
    end
    local releases, charts, served = {}, {}, {}
    for _, hf in ipairs(hfs) do
        stats.helmfiles = stats.helmfiles + 1
        claimed[hf.file] = true
        node(hf.file)
        for _, r in ipairs(hf.releases) do
            stats.releases = stats.releases + 1
            local id = hf.cluster .. '/' .. tostring(r.name)
            r.id, r.cluster = id, hf.cluster
            releases[#releases + 1] = r
            for _, l in ipairs(r.layers) do
                stats.layers = stats.layers + 1
                if l.state == 'templated' then stats.templated = stats.templated + 1 end
                if l.state == 'missing' then stats.missing = stats.missing + 1 end
                if l.file and (l.state == 'read' or l.state == 'templated') then
                    claimed[l.file] = true
                    node(l.file)
                    data.edges[#data.edges + 1] = { from = hf.file, to = l.file, kind = 'use', hf = 'values',
                        release = r.name, at = {} }
                end
            end
            stats.secrets = stats.secrets + #r.secrets
            stats.noops = stats.noops + #r.noops
            local c = charts[r.chart or '?'] or { releases = {}, versions = {} }
            charts[r.chart or '?'] = c
            c.releases[#c.releases + 1] = id
            c.versions[tostring(r.version)] = (c.versions[tostring(r.version)] or 0) + 1
            for _, h in ipairs(r.hosts) do
                served[h.host] = served[h.host] or {}
                local seen = false
                for _, x in ipairs(served[h.host]) do if x == id then seen = true end end
                if not seen then table.insert(served[h.host], id) end
            end
        end
    end
    for _, c in pairs(charts) do
        local n = 0; for _ in pairs(c.versions) do n = n + 1 end
        if n > 1 then stats.skew = stats.skew + 1; c.skew = true end
    end
    for _ in pairs(served) do stats.hosts = stats.hosts + 1 end
    data.helmfile = { helmfiles = hfs, releases = releases, charts = charts, served = served, claimed = claimed }
    return stats
end

--- ★ A CHART FAMILY, recovered: every release of `chart` anchored over its effective values
--- (`drift.anchor`, keyed). Template = what every deployment of the chart shares; holes = the
--- per-deployment parameters. On demand, not at attach: it is the expensive part.
function M.family(data, chart)
    local hf = data and data.helmfile
    if not hf or not hf.charts[chart] then return nil, ('no releases of chart %s'):format(tostring(chart)) end
    local members = {}
    for _, r in ipairs(hf.releases) do
        if r.chart == chart then members[#members + 1] = { id = r.id, value = r.effective } end
    end
    return require('cartograph.drift').anchor(members, { keyed = true })
end

function M.summary(s)
    if not s or s.helmfiles == 0 then
        if s and #s.refusals > 0 then return ('helmfile: 0 helmfiles read, %d refused'):format(#s.refusals) end
        return nil
    end
    return ('helmfile: %d helmfile(s), %d release(s), %d values layer(s) (%d templated, %d missing), %d secrets ref(s)'
        .. ' (private — a frontier), %d no-op override(s), %d chart(s) with version skew, %d served host(s)')
        :format(s.helmfiles, s.releases, s.layers, s.templated, s.missing, s.secrets, s.noops, s.skew, s.hosts)
end

return M
