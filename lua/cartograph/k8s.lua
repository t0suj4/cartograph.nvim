-- The Kubernetes manifest adapter: a deployment manifest is a DECLARED layer
-- beside the source and the contract, and it carries two things nothing in
-- cartograph reads today — the IDENTITY that maps a running service back to its
-- code, and the DECLARED service topology. Session post-pass, same family as
-- proto.lua / django.lua / symfony.lua. CART-0830.
--
-- ★★★ THIS IS THE PRE-`instance`-KIND CUT, AND IT SAYS SO. The user-authored
-- design at `cartograph-design/runtime-topology/03-instances-and-identity.md`
-- proposes FOUR node kinds for this domain — `instance` (the thing that
-- restarts), `workload` (the stable declared thing), `listener` (a bound
-- socket), `principal` (an authenticated identity) — and none of them exists in
-- `validate.NODE_KINDS`. Adding one is a SCHEMA change and belongs to CART-0140,
-- which owns that design. So this mints no new kind: the manifest FILE becomes a
-- `module` node, exactly as proto.lua does for a .proto, and the parts that need
-- no node at all — the identity map — ride on `data.k8s`.
-- ⚠ A `workload` node is the right long-term home for a Deployment. When
-- CART-0140 lands it, the identity map here is its input, not its competitor.
--
-- ★★ AND THE DECLARED TOPOLOGY IS A `use` EDGE, NOT AN `import`, ON MEASURED
-- GROUNDS. The k8s design calls these SOFT edges — "everything that binds
-- without owning" — and `import` is read at eight-plus sites including
-- store.lua:99, whose `imports_out` feeds portability's stage-map reachability
-- walk and preflight's spec cone. A yaml manifest declaring a dependency on
-- another service must not enter those walks. `use` is read at three sites and
-- carries the weaker "X refers to Y" meaning this needs.
--
-- ⚠ SCOPE: `kubernetes-manifests/*.yaml`-shaped plain manifests only. helm-chart/
-- and kustomize/ hold TEMPLATED yaml (`{{ .Values.x }}`) that does not parse to
-- values, and a reader that silently produced half a graph from them would be
-- the exact defect this file's refusal counter exists to prevent. A document
-- with no `kind:` is refused and COUNTED.

local M = {}

-- ★ THE IMAGE -> SOURCE MAPPING IS AN ORACLE, NOT A NAME MATCH. skaffold.yaml
-- declares `- image: cartservice / context: src/cartservice/src` — the one
-- service of twelve whose directory is NOT its image name. Matching on the name
-- would be right eleven times and wrong once, which is the worst kind of wrong:
-- it looks like it works. When no skaffold file is present the mapping is simply
-- absent, and `dir` stays nil rather than being guessed.
local function skaffold_map(root)
    local out = {}
    for _, name in ipairs({ 'skaffold.yaml', 'skaffold.yml' }) do
        local fd = io.open(root .. '/' .. name, 'r')
        if fd then
            local src = fd:read('a'); fd:close()
            local image
            for line in src:gmatch('[^\n]+') do
                local im = line:match('^%s*%-?%s*image:%s*([%w%._%-/]+)%s*$')
                local ctx = line:match('^%s*context:%s*([%w%._%-/]+)%s*$')
                if im then image = im:match('([^/]+)$') end
                if ctx and image then out[image] = ctx:gsub('/+$', ''); image = nil end
            end
            break
        end
    end
    return out
end

-- ── the yaml reader. Same parser ansible.lua uses; absent parser = absent
-- feature, reported rather than silently empty.
local function parse_docs(src)
    local ok, root = pcall(function ()
        return vim.treesitter.get_string_parser(src, 'yaml'):parse()[1]:root()
    end)
    if not ok or not root then return nil, 'yaml parse failed' end
    return root
end

--- Read one manifest's text into a list of documents:
---   { kind, name, app, image, init_images, ports = {n}, env = { NAME = value }, envfrom = { configmap … },
---     data = { KEY = value } (a ConfigMap), sa, source (its `# Source:` header), workload (a pod template),
---     shell_urls, embedded }
--- ★ AS A VALUE (yamlvalue), NOT A LINE MATCH (design helm-charts/02, 2026-10-01): two regexes missed
--- `- containerPort: 8080` and a name-first `- name: http / port: 8082` item — a silent `{}` that looks like
--- "declares no ports" — and the first `image:` anywhere named a Deployment by its INIT container. Walking
--- the document reads `containers[*].ports[*].containerPort`, `spec.ports[*].port`, `containers[1].image`,
--- and a commented-out env pair is no declaration. A document yamlvalue cannot read falls back to the
--- textual reading below, bounded as before. A value carrying `{{` is still a TEMPLATE, refused whole;
--- a document that is ONLY comments (Helm renders a disabled `if` as `# Source:` alone) is EMPTY, not
--- refused — counting it inflated the refusal counter this file's honesty rests on.
local Y = require 'cartograph.yamlvalue'
local function get(v, ...)
    for _, k in ipairs({ ... }) do
        if type(v) ~= 'table' then return nil end
        if type(k) == 'number' then v = v.a and v.a[k] else v = v.o and v.o[k] end
    end
    return v
end
local function list(v) return (type(v) == 'table' and v.a) or {} end
local function str(v) return type(v) == 'string' and v or nil end

-- ── THE DERIVED API (CART-1267, CART-1296): where each kind keeps its pod template and every SOFT-EDGE reference it
-- can make (a field that names another object without owning it — the edges the garbage collector does not walk),
-- with its target kind and cluster scope, from Kubernetes' OWN API types through the generated table
-- (tools/k8sapi.lua). No kind, path or field is listed in this file.
local API = require('cartograph.k8sapi').load()
local REFS_OF = {}
for _, r in ipairs(API and API.refs or {}) do
    REFS_OF[r[1]] = REFS_OF[r[1]] or {}
    table.insert(REFS_OF[r[1]], { path = r[2], target = r[3] or nil, how = r[4] })
end
--- every value at a derived path ('spec.template.spec.volumes[].secret.secretName'; `{}` = the map read whole)
local function at_path(v, path)
    local cur = { v }
    for seg in path:gmatch('[^.]+') do
        local name, suf = seg:match('^([^%[{]+)(.*)$')
        local nxt = {}
        for _, x in ipairs(cur) do
            local y = get(x, name)
            if y ~= nil then
                if suf == '[]' then for _, e in ipairs(list(y)) do nxt[#nxt + 1] = e end else nxt[#nxt + 1] = y end
            end
        end
        cur = nxt
        if #cur == 0 then break end
    end
    return cur
end
--- a label map (an object of strings) -> { key = value } | nil
local function labels(v)
    if type(v) ~= 'table' or not v.o then return nil end
    local out = {}
    for _, k in ipairs(v.keys or {}) do local s = str(v.o[k]); if s then out[k] = s end end
    return out
end
--- the soft-edge REFERENCES one document makes -> { { path, kind (the target's), name | sel (labels), how, optional } }
local function refs_of(v, kind)
    local out = {}
    for _, r in ipairs(REFS_OF[kind or ''] or {}) do
        for _, x in ipairs(at_path(v, r.path)) do
            if r.how == 'name' then
                local n = str(x)
                if n then out[#out + 1] = { path = r.path, kind = r.target, name = n, how = 'name' } end
            elseif r.how == 'ref' then
                local n, k = str(get(x, 'name')), r.target or str(get(x, 'kind'))
                -- (yamlvalue keeps a scalar as its TEXT: the boolean is the string 'true')
                if n and k then out[#out + 1] = { path = r.path, kind = k, name = n, how = 'ref', optional = str(get(x, 'optional')) == 'true' } end
            elseif r.how == 'selector' then
                local sel = labels(get(x, 'matchLabels')) or (r.path:sub(-2) == '{}' and labels(x)) or nil
                if sel and next(sel) then out[#out + 1] = { path = r.path, kind = r.target, sel = sel, how = 'selector' } end
            end
        end
    end
    return out
end
M._refs_of, M._api = refs_of, API
local function textual(chunk, d)
    d.kind = chunk:match('\nkind:%s*([%w]+)') or chunk:match('^kind:%s*([%w]+)')
    -- metadata.name is the FIRST `name:` at two-space indent
    d.name = chunk:match('\nmetadata:\n%s+name:%s*([%w%._%-]+)')
    d.app = chunk:match('\n%s+app:%s*([%w%._%-]+)')
    d.image = chunk:match('\n%s+image:%s*([%w%._%-/:]+)')
    d.sa = chunk:match('\n%s+serviceAccountName:%s*([%w%._%-]+)')
    for p in chunk:gmatch('\n[%s%-]+containerPort:%s*(%d+)') do d.ports[#d.ports + 1] = tonumber(p) end
    for p in chunk:gmatch('\n%s+%- port:%s*(%d+)') do d.ports[#d.ports + 1] = tonumber(p) end
    local pend
    for line in chunk:gmatch('[^\n]+') do
        local n = line:match('^%s*%-%s*name:%s*([%w_]+)%s*$')
        local v = line:match('^%s*value:%s*"?([^"]*)"?%s*$')
        if n then pend = n
        elseif v and pend then d.env[pend] = v; pend = nil end
    end
    d.workload = d.kind == 'Deployment'
end
local function from_value(v, d)
    d.kind = str(get(v, 'kind'))
    d.name = str(get(v, 'metadata', 'name'))
    d.app = str(get(v, 'metadata', 'labels', 'app')) or str(get(v, 'spec', 'template', 'metadata', 'labels', 'app'))
    -- the POD TEMPLATE, wherever its kind keeps it — DERIVED from Kubernetes' own types (CART-1267): every kind a
    -- PodSpec is reachable from, at the path the types give (CronJob spec.jobTemplate.spec.template.spec)
    local pod
    local pp = API and d.kind and API.pod[d.kind]
    if pp then
        pod = at_path(v, pp)[1]
        d.podlabels = labels(at_path(v, pp == 'spec' and 'metadata.labels' or (pp:gsub('%.spec$', '.metadata.labels')))[1])
    end
    d.refs = refs_of(v, d.kind)
    -- (the PROBES: a call the kubelet makes into the container, at the paths and handler fields the API types give —
    -- CART-0834. A gRPC probe calls the Health contract; an httpGet probe is a different boundary, recorded apart)
    d.probes = {}
    for _, path in ipairs(API and API.probes and API.probes[d.kind or ''] or {}) do
        for _, pr in ipairs(at_path(v, path)) do
            local g = API.probe_grpc and get(pr, API.probe_grpc)
            local h = API.probe_http and get(pr, API.probe_http)
            if type(g) == 'table' and g.o then d.probes[#d.probes + 1] = { kind = 'grpc', path = path, port = str(get(g, 'port')), service = str(get(g, 'service')) }
            elseif type(h) == 'table' and h.o then d.probes[#d.probes + 1] = { kind = 'http', path = path, port = str(get(h, 'port')), route = str(get(h, 'path')) } end
        end
    end
    if type(pod) == 'table' and pod.o then
        d.workload = true
        d.sa = str(get(pod, 'serviceAccountName'))
        local function shell(c)
            for _, key in ipairs({ 'command', 'args' }) do
                for _, x in ipairs(list(get(c, key))) do
                    if type(x) == 'string' and x:find('%a[%w+.-]*://') then d.shell_urls = (d.shell_urls or 0) + 1 end
                end
            end
        end
        -- DEBUG AND MANAGEMENT LISTENERS (CART-1388, the audit drill-down's finding of the walk itself): a JVM started
        -- with a JDWP agent in server mode bound to every interface, or a remote JMX port with authentication off, is
        -- remote code execution for anything that reaches the pod IP. Read from EVERY string the container is started
        -- with — its command / args items and its env values (JAVA_TOOL_OPTIONS and kin, without listing them).
        -- ⚠ PRECISION: JDWP only with server=y and an address on all interfaces (`*:N`, `0.0.0.0:N`, `[::]:N`) — a bare
        -- `address=N` binds localhost on JDK 9+; JMX only with authenticate=false AND a remote port (no port: local attach).
        local function listeners(c, init)
            local strings = {}
            for _, key in ipairs({ 'command', 'args' }) do
                for _, x in ipairs(list(get(c, key))) do if type(x) == 'string' then strings[#strings + 1] = x end end
            end
            for _, e in ipairs(list(get(c, 'env'))) do
                local val = str(get(e, 'value'))
                if val then strings[#strings + 1] = val end
            end
            local all = table.concat(strings, ' ')
            local cname = str(get(c, 'name')) or '?'
            for opts in all:gmatch('%-agentlib:jdwp=([^%s"\']+)') do d.debug = d.debug or {}; table.insert(d.debug, { jdwp = opts, container = cname, init = init }) end
            for opts in all:gmatch('%-Xrunjdwp:([^%s"\']+)') do d.debug = d.debug or {}; table.insert(d.debug, { jdwp = opts, container = cname, init = init }) end
            if all:find('com%.sun%.management%.jmxremote%.authenticate=false') then
                local port = all:match('com%.sun%.management%.jmxremote%.port=(%d+)')
                if port then
                    d.debug = d.debug or {}
                    table.insert(d.debug, { jmx = port, ssl_off = all:find('com%.sun%.management%.jmxremote%.ssl=false') ~= nil, container = cname, init = init })
                end
            end
        end
        d.init_images = {}
        for _, c in ipairs(list(get(pod, 'initContainers'))) do
            d.init_images[#d.init_images + 1] = str(get(c, 'image'))
            shell(c)
            listeners(c, true)
        end
        for i, c in ipairs(list(get(pod, 'containers'))) do
            if i == 1 then d.image = str(get(c, 'image')) end
            for _, p in ipairs(list(get(c, 'ports'))) do
                local n = tonumber(str(get(p, 'containerPort')) or '')
                if n then d.ports[#d.ports + 1] = n end
            end
            for _, e in ipairs(list(get(c, 'env'))) do
                local n, val = str(get(e, 'name')), str(get(e, 'value'))
                if n and val then d.env[n] = val end
            end
            for _, ef in ipairs(list(get(c, 'envFrom'))) do
                local cm = str(get(ef, 'configMapRef', 'name'))
                if cm then d.envfrom = d.envfrom or {}; d.envfrom[#d.envfrom + 1] = cm end
            end
            shell(c)
            listeners(c, false)
        end
    end
    if d.kind == 'Service' then
        for _, p in ipairs(list(get(v, 'spec', 'ports'))) do
            local n = tonumber(str(get(p, 'port')) or '')
            if n then d.ports[#d.ports + 1] = n end
        end
    end
    if d.kind == 'ConfigMap' then
        d.data = {}
        local data = get(v, 'data')
        for _, k in ipairs(type(data) == 'table' and data.keys or {}) do
            local x = str(data.o[k])
            -- (an EMBEDDED document — `application.yaml: |` — is a frontier: counted, not read)
            if x and x:find('\n') then d.embedded = (d.embedded or 0) + 1 elseif x then d.data[k] = x end
        end
    end
end
--- `opts.rendered`: the text is a RENDER (helm template, kubectl kustomize) — a `{{` inside it is LITERAL content (an
--- otel collector's or alertmanager's own template syntax), never an unrendered chart, so nothing is refused for it
function M.read(src, opts)
    local rendered = opts and opts.rendered
    local docs, refused, why = {}, 0, {}
    local ok = parse_docs(src)
    if not ok then return docs, 1, { 'yaml parse failed' } end
    -- (each document's LINE RANGE, by locating its chunk in the source — the object nodes of CART-1312 need it)
    local pos, counted, lines = 1, 1, 0
    local function line_of(byte)
        lines = lines + select(2, src:sub(counted, byte - 1):gsub('\n', ''))
        counted = byte
        return lines
    end
    for chunk in (src .. '\n---\n'):gmatch('(.-)\n%-%-%-%s*\n') do
        local at = src:find(chunk, pos, true) or pos
        local line0 = line_of(at)
        pos = at + #chunk
        -- (only comments and `---`: an EMPTY document, not a refused one)
        local body = chunk:gsub('#[^\n]*', ''):gsub('%-%-%-', '')
        if body:match('%S') then
            local d = { ports = {}, env = {}, source = chunk:match('#%s*Source:%s*([^\n%s]+)'),
                line0 = line0, line1 = line0 + select(2, (chunk:gsub('\n+$', '')):gsub('\n', '')), chunk = chunk }
            if not rendered and chunk:find('{{', 1, true) then
                -- a helm/kustomize template: the values are not here
                refused = refused + 1
                if #why < 6 then why[#why + 1] = 'templated ({{ }})' end
            else
                local v = Y.read_one(chunk)
                if type(v) == 'table' and v.o then from_value(v, d) else textual(chunk, d) end
                if d.kind then docs[#docs + 1] = d
                else
                    refused = refused + 1
                    if #why < 6 then why[#why + 1] = 'no kind:' end
                end
            end
        end
    end
    return docs, refused, why
end

-- ── ENUMERATION: reuse the WALK's exclusion set (see proto.lua). This is the
-- fifth adapter that must find files no spec claims, and the fourth to be
-- written after ansible hardcoded its own list; sharing the set is the half
-- that drifts. Unifying the walks is CART-0817's.
function M.find(root, tp)
    tp = tp or require 'cartograph.transport'
    local ts = require 'cartograph.providers.treesitter'
    local ex = ts.EXCLUDE_DIRS or {}
    local out = {}
    local function rec(rel)
        for name, t in tp.dir(rel == '' and root or (root .. '/' .. rel)) do
            if name:sub(1, 1) ~= '.' then
                local r = rel == '' and name or (rel .. '/' .. name)
                if t == 'directory' then
                    -- ⚠ helm-chart/ and kustomize/ hold TEMPLATED yaml. They are
                    -- not excluded here (the reader refuses a templated document
                    -- and counts it), so the refusal is VISIBLE rather than a
                    -- silent directory skip — CART-0817's own complaint.
                    if not ex[name:lower()] then rec(r) end
                elseif name:match('%.ya?ml$') then
                    out[#out + 1] = r
                end
            end
        end
    end
    rec('')
    table.sort(out) -- an artifact field: order is output (CART-0790)
    return out
end

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }

--- REQUEST-PATH TRACES from a workload object (CART-1316): every peer it declares (an env `*_SERVICE_ADDR`, a URL host),
--- hop by hop, each hop at its DECLARING line — the env line naming the peer -> the peer's Service (its port) -> the
--- workload the Service selects (the selector line) -> that workload's containerPort -> its gRPC health probe. A trace,
--- never a drawn network: flows are temporal, so each is a list of hops. -> { { peer, hops = { { text, file, line } } } }
--- | nil, why. A peer with no Service in the release ends in a `dangling` hop.
function M.traces(data, id)
    local s = data and data.k8s
    if not s then return nil, 'no Kubernetes pass on this graph' end
    local od = s.object_docs and s.object_docs[id]
    if not od then return nil, 'not a Kubernetes object: ' .. tostring(id) end
    local d, v = od.d, od.variant
    local svc = s.services_map[v .. '\31' .. tostring(d.name or d.app)]
    if not svc or not next(svc.addrs or {}) then return {} end
    local function line_of(doc, needle)
        local l = 0
        for line in ((doc.chunk or '') .. '\n'):gmatch('([^\n]*)\n') do
            l = l + 1
            if line:find(needle, 1, true) then return (doc.line0 or 0) + l end
        end
        return (doc.line0 or 0) + 1
    end
    local traces = {}
    local hosts = vim.tbl_keys(svc.addrs)
    table.sort(hosts)
    for _, host in ipairs(hosts) do
        local val = svc.addrs[host]
        local hops = { { text = ('%s/%s names %s'):format(d.kind, tostring(d.name), val), file = od.rel, line = line_of(d, val) } }
        local snode = (s.object_nodes or {})[v .. '\31Service\31' .. host]
        local sd = snode and s.object_docs[snode]
        if not sd then
            hops[#hops + 1] = { text = ('no Service %s in %s — dangling (an overlay or operator may supply it)'):format(host, v) }
        else
            local port = val:match(':(%d+)')
            hops[#hops + 1] = { text = 'Service/' .. host .. (port and (' port ' .. port) or ''), file = sd.rel,
                line = port and line_of(sd.d, port) or (sd.d.line0 or 0) + 1 }
            local selected = false
            for _, e in ipairs(data.edges or {}) do
                if e.k8 == 'selects' and e.from == snode then
                    local wd = s.object_docs[e.to]
                    if wd then
                        selected = true
                        hops[#hops + 1] = { text = 'selects ' .. wd.d.kind .. '/' .. tostring(wd.d.name), file = sd.rel,
                            line = e.at and e.at[1] and (e.at[1].start.line + 1) or (sd.d.line0 or 0) + 1 }
                        hops[#hops + 1] = { text = wd.d.kind .. '/' .. tostring(wd.d.name) .. ' listens', file = wd.rel, line = line_of(wd.d, 'containerPort') }
                        -- (probe edges are probes x vendored copies of the Health contract: count each apart)
                        local sites, copies, pline = {}, {}, nil
                        for _, pe in ipairs(data.edges or {}) do
                            if pe.k8 == 'probes' and pe.from == e.to then
                                local l = pe.at and pe.at[1] and (pe.at[1].start.line + 1)
                                if l then sites[l] = true end
                                copies[pe.to] = true
                                pline = (l and (not pline or l < pline)) and l or pline
                            end
                        end
                        local np, nc = vim.tbl_count(sites), vim.tbl_count(copies)
                        if nc > 0 then hops[#hops + 1] = { text = ('probed: gRPC health, %d probe%s, %d cop%s of the contract'):format(np, np == 1 and '' or 's', nc, nc == 1 and 'y' or 'ies'), file = wd.rel, line = pline } end
                    end
                end
            end
            if not selected then hops[#hops + 1] = { text = 'its selector matches no pod in ' .. v } end
        end
        traces[#traces + 1] = { peer = host, hops = hops }
    end
    return traces
end

--- the SITE of a field in a document (CART-1312): the line of `path` (the derived API path, `[]` for any list item,
--- `{}` for a map) in the document's text — the first one whose line names `value` when given — as a use edge's `at`
--- list { { start, end } } (0-based lines). Nothing found: {} (the edge stays, without a site).
function M.site(d, path, value)
    if not (d and d.chunk and path) then return {} end
    local lines = require('cartograph.helmprov').key_lines(d.chunk)
    local want = path:gsub('%[%]', '[*]'):gsub('{}$', '')
    local text = vim.split(d.chunk, '\n', { plain = true })
    local best
    for p, l in pairs(lines) do
        local norm = p:gsub('%[%d+%]', '[*]')
        if norm == want or norm == want .. '.name' then
            if not value or (text[l] or ''):find(value, 1, true) then
                if not best or l < best then best = l end
            end
        end
    end
    if not best then return {} end
    local line = (d.line0 or 0) + best - 1
    return { { start = { line = line, char = 0 }, ['end'] = { line = line, char = #(text[best] or '') } } }
end

--- Mint the declared deployment layer into `data`. Idempotent under refresh.
--- Sets `data.k8s = { services = { name -> {file, image, dir, ports, addrs} },
--- edges, docs, files, refused, refusals }` and returns it.
function M.attach(data, opts)
    local stats = { files = 0, docs = 0, services = 0, edges = 0, refused = 0,
        refusals = {}, services_map = {}, unmapped = {}, variants = {},
        dangling = {} }
    if not data or not data.root then data.k8s = nil; return stats end

    local ids, nodes = {}, {}
    for _, n in ipairs(data.nodes or {}) do
        if n.k8 then ids[n.id] = true else nodes[#nodes + 1] = n end
    end
    if next(ids) then
        local edges = {}
        for _, e in ipairs(data.edges or {}) do
            if not (e.k8 or ids[e.from] or ids[e.to]) then edges[#edges + 1] = e end
        end
        data.nodes, data.edges = nodes, edges
    end

    local files = (opts and opts.files) or M.find(data.root, opts and opts.transport)
    if #files == 0 then data.k8s = nil; return stats end
    data.nodes = data.nodes or {}
    data.edges = data.edges or {}
    local img2dir = skaffold_map(data.root)
    -- (the honesty of the INPUT, design helm-charts/02 §1: a chart root behind templated refusals is a chart that can
    -- be RENDERED; a service declared only by files git does not track is no part of the repo's answer)
    stats.chart_roots = {}
    for _, rel in ipairs(files) do
        if rel:match('^Chart%.ya?ml$') or rel:match('/Chart%.ya?ml$') then stats.chart_roots[#stats.chart_roots + 1] = rel:match('^(.*)/[^/]+$') or '.' end
    end
    local tracked
    do
        local r = vim.system({ 'git', '-C', data.root, 'ls-files', '-z' }, { text = true }):wait()
        if r.code == 0 then tracked = {}; for f in (r.stdout or ''):gmatch('([^%z]+)') do tracked[f] = true end end
    end

    -- ★★★ PASS 1, AND THE ROSTER IS KEYED BY DEPLOYMENT VARIANT. A repo routinely
    -- declares the SAME system several times over — microservices-demo carries
    -- `kubernetes-manifests/`, `release/`, `helm-chart/templates/` and
    -- `kustomize/`, and a first cut that keyed services by NAME alone merged
    -- them: currencyservice came back with `ports=7000,7000,7000`, one port per
    -- variant, as though it listened three times. They are ALTERNATIVE
    -- declarations of one system, not one system, and conflating them destroys
    -- the very comparison this layer is for — the k8s design's live-vs-declared
    -- and GitOps-drift findings are about exactly that disagreement.
    -- The variant is the manifest's DIRECTORY, which is measured rather than
    -- named: no list of known layouts, no guess.
    for _, rel in ipairs(files) do
        local fd = io.open(data.root .. '/' .. rel, 'r')
        local src = fd and fd:read('a')
        if fd then fd:close() end
        if src then
            local docs, refused, why = M.read(src, { rendered = opts and opts.rendered })
            stats.refused = stats.refused + refused
            for _, w in ipairs(why) do
                if #stats.refusals < 10 then
                    stats.refusals[#stats.refusals + 1] = rel .. ': ' .. w
                end
            end
            if #docs > 0 then
                stats.files = stats.files + 1
                stats.docs = stats.docs + #docs
                -- the FIELD SCHEMA check (CART-1308): unknown fields and wrong types, at their lines
                if not (opts and opts.schema == false) then
                    local ok, fs = pcall(require('cartograph.k8sschema').check_text, src)
                    if ok then
                        stats.schema = stats.schema or {}
                        for _, f in ipairs(fs) do f.file = rel; stats.schema[#stats.schema + 1] = f end
                    end
                end
                local dirvariant = rel:match('^(.*)/[^/]+$') or '.'
                local counted = {}
                data.nodes[#data.nodes + 1] = { id = rel, name = rel,
                    kind = 'module', file = rel, range = R0, order = 0,
                    k8 = 'manifest' }
                -- every OBJECT its own node (CART-1312): a REGION of its file, `Deployment/frontend`, spanning its document
                -- — the soft edges run between objects, so a reference inside one file is no longer a self-edge
                local used = {}
                for i, d in ipairs(docs) do
                    local base = rel .. '::' .. d.kind .. '/' .. (d.name or ('#' .. i))
                    local id = base
                    if used[id] then id = base .. '#' .. i end
                    used[id] = true
                    d.node = id
                    data.nodes[#data.nodes + 1] = { id = id, name = d.kind .. '/' .. (d.name or '?'), kind = 'region', file = rel,
                        order = d.line0 or 0, k8 = 'object',
                        range = { start = { line = d.line0 or 0, char = 0 }, ['end'] = { line = d.line1 or 0, char = 0 } } }
                end
                for _, d in ipairs(docs) do
                    -- ★ THE RELEASE ROOT, WHEN THE DOCUMENT NAMES IT (design helm-charts/02 §3b). A
                    -- `helm template --output-dir` render puts each service in its OWN directory, so a
                    -- directory variant split one release eleven ways and every cross-service peer read
                    -- as dangling. Every rendered document begins `# Source: <chart>/…`, and where the
                    -- file's path ENDS with that source path the variant is the prefix plus the chart:
                    -- the release. A document without the header keeps its directory (microservices-demo's
                    -- alternative deployments stay apart).
                    local variant = dirvariant
                    if d.source and #rel >= #d.source and rel:sub(-#d.source) == d.source then
                        variant = rel:sub(1, #rel - #d.source) .. (d.source:match('^([^/]+)') or '')
                    end
                    if not counted[variant] then counted[variant] = true; stats.variants[variant] = (stats.variants[variant] or 0) + 1 end
                    -- (each object's document, for the TRACES that walk it after the pass — CART-1316)
                    if d.node then stats.object_docs = stats.object_docs or {}; stats.object_docs[d.node] = { d = d, rel = rel, variant = variant } end
                    -- (every OBJECT by kind and name within its release, and every document that references or carries
                    -- pod labels: the soft-edge pass resolves against these)
                    if d.kind and d.name then
                        stats.objects = stats.objects or {}
                        stats.objects[variant .. '\31' .. d.kind .. '\31' .. d.name] = rel
                        stats.object_nodes = stats.object_nodes or {}
                        stats.object_nodes[variant .. '\31' .. d.kind .. '\31' .. d.name] = d.node
                    end
                    for _, pr in ipairs(d.probes or {}) do
                        stats.probes = stats.probes or {}
                        stats.probes[#stats.probes + 1] = { rel = rel, node = d.node, at = M.site(d, pr.path), variant = variant, name = d.name, kind = pr.kind, port = pr.port, service = pr.service, route = pr.route, path = pr.path }
                    end
                    if (d.refs and #d.refs > 0) or d.podlabels or d.debug then
                        stats.docs_soft = stats.docs_soft or {}
                        table.insert(stats.docs_soft, { rel = rel, variant = variant, d = d })
                    end
                    stats.shell_urls = (stats.shell_urls or 0) + (d.shell_urls or 0)
                    stats.embedded = (stats.embedded or 0) + (d.embedded or 0)
                    if d.kind == 'ConfigMap' and d.name and d.data then
                        stats.configmaps = stats.configmaps or {}
                        stats.configmaps[variant .. '\31' .. d.name] = d.data
                    end
                    local key = d.name or d.app
                    -- (every POD-TEMPLATE kind is a workload — StatefulSet, DaemonSet, Job, CronJob — not
                    -- only Deployment: design helm-charts/02 §2b)
                    if key and (d.workload or d.kind == 'Service') then
                        local vk = variant .. '\31' .. key
                        local s = stats.services_map[vk]
                        if not s then
                            s = { name = key, variant = variant, files = {},
                                ports = {}, addrs = {} }
                            stats.services_map[vk] = s
                            stats.services = stats.services + 1
                        end
                        s.files[#s.files + 1] = rel
                        if tracked and not tracked[rel] then s.untracked = (s.untracked or 0) + 1 end
                        if d.image then
                            -- ⚠ THE BASENAME ON BOTH SIDES. A release bundle
                            -- pins the registry path
                            -- (`us-central1-docker.pkg.dev/.../adservice`) while
                            -- skaffold names the artifact bare, so keying on the
                            -- full string mapped ONE service of fifteen and the
                            -- other fourteen looked like a missing oracle rather
                            -- than a key mismatch.
                            s.image = d.image:gsub(':.*$', ''):match('([^/]+)$')
                            -- ★ the ORACLE, never a name match
                            s.dir = img2dir[s.image]
                            if not s.dir then stats.unmapped[s.image] = true end
                        end
                        -- (a Deployment and its Service both declare the port: one port, not two)
                        s.portset = s.portset or {}
                        for _, p in ipairs(d.ports) do if not s.portset[p] then s.portset[p] = true; s.ports[#s.ports + 1] = p end end
                        s.env = s.env or {}
                        for k, v in pairs(d.env) do s.env[k] = v end
                        for _, cm in ipairs(d.envfrom or {}) do s.envfrom = s.envfrom or {}; s.envfrom[#s.envfrom + 1] = cm end
                    end
                end
            end
        end
    end

    -- pass 1b: the PEERS a workload declares, from its env and the ConfigMaps it takes as env
    -- (`envFrom`) — design helm-charts/02 §3, tiers 1-2:
    --   `NAME_SERVICE_ADDR: host:port`   the microservices-demo convention;
    --   a URL `scheme://host[:port]`     the host, when it is UNDOTTED (a Service name) or an in-cluster
    --                                    FQDN `<svc>.<ns>.svc[.cluster.local]` (reduced to <svc>);
    -- a dotted external host is a counted FRONTIER, never dangling (it would flood every real repo); a bind
    -- address (`0.0.0.0`, digits) or `localhost` is no peer; a scheme-less dotted `host:port` under any
    -- other key is not read. Embedded documents and shell are counted, not scraped (tiers 3-4).
    stats.external = stats.external or {}
    local function peer_host(v)
        local out = {}
        for host in v:gmatch('%a[%w+.-]*://([%w%._%-]+)') do
            local svc = host:match('^([%w_%-]+)%.[%w_%-]+%.svc$') or host:match('^([%w_%-]+)%.[%w_%-]+%.svc%.cluster%.local$')
            if svc then out[#out + 1] = svc
            elseif host == 'localhost' or host:match('^[%d%.]+$') then -- (a bind address, no peer)
            elseif host:find('.', 1, true) then stats.external[host] = true
            else out[#out + 1] = host end
        end
        return out
    end
    for _, s in pairs(stats.services_map) do
        local env = {}
        for k, v in pairs(s.env or {}) do env[k] = v end
        for _, cm in ipairs(s.envfrom or {}) do
            for k, v in pairs((stats.configmaps or {})[s.variant .. '\31' .. cm] or {}) do env[k] = env[k] or v end
        end
        for k, v in pairs(env) do
            local host = k:match('_SERVICE_ADDR$') and v:match('^([%w%._%-]+):')
            if host then s.addrs[host] = v end
            for _, h in ipairs(peer_host(v)) do s.addrs[h] = s.addrs[h] or v end
        end
    end

    -- pass 2: the DECLARED TOPOLOGY. A `*_SERVICE_ADDR` naming a service this
    -- roster knows is an edge; one naming anything else is a peer OUTSIDE the
    -- manifests and gets no fabricated target — the same refusal proto.lua makes
    -- for an import pointing out of the root.
    for _, s in pairs(stats.services_map) do
        for host in pairs(s.addrs) do
            -- WITHIN THE VARIANT: a manifest names a peer by its in-cluster DNS
            -- name, which resolves inside its own deployment, not across two.
            local peer = stats.services_map[s.variant .. '\31' .. host]
            if peer and peer ~= s and s.files[1] and peer.files[1] then
                data.edges[#data.edges + 1] = { from = s.files[1], to = peer.files[1],
                    kind = 'use', k8 = 'declares', at = {} }
                stats.edges = stats.edges + 1
            elseif not peer then
                -- ★★ A ONE-SIDED DECLARED EDGE, which is the k8s design's A4
                -- bipartite-completeness shape and the first lint this layer
                -- affords: a workload names a peer its own deployment does not
                -- contain. FOUND ON THE FIRST RUN — kubernetes-manifests/
                -- frontend.yaml:83 declares SHOPPING_ASSISTANT_SERVICE_ADDR and
                -- that variant ships no shoppingassistantservice (it is an
                -- optional kustomize component).
                -- ⚠ IT IS NOT AUTOMATICALLY A BUG, and the design says so in as
                -- many words: "unreferenced statically" != "dead", and the
                -- mirror holds — a declared peer may be supplied by an overlay,
                -- a feature flag, or an operator. Surfaced with its variant,
                -- never resolved into a fabricated edge.
                stats.dangling[#stats.dangling + 1] =
                    ('%s declares %s, absent from %s'):format(s.name, host, s.variant)
            end
        end
    end

    table.sort(stats.dangling) -- (an artifact field: order is output)

    -- ── PASS 2b: THE SOFT EDGES (design kubernetes/: everything that binds without owning, which GC never walks), from
    -- the DERIVED references (CART-1296). A name resolves to an object of that kind in the SAME release; absent, it is
    -- cluster-provided when the kind is cluster-scoped (a StorageClass, a Node: a frontier), optional when the reference
    -- says so, implicit for the `default` ServiceAccount, and otherwise DANGLING — a reference to an object the release
    -- does not ship (CART-0156's silent-success class: every tool reports success and the pod fails to start). A pod
    -- selector resolves to the workloads whose POD-TEMPLATE labels it matches; a selector matching none is the other
    -- silent success: a Service that exists and routes nowhere.
    local soft = { resolved = 0, cluster = 0, optional = 0, implicit = 0, selects = 0, dangling = {}, empty = {}, inbound = {}, composed = 0 }
    stats.soft = soft
    -- (a KUSTOMIZE COMPONENT is not a release: its directory's kustomization declares `kind: Component` — kustomize's own
    -- marker — and its objects are COMPOSED with a base, where their selectors and references resolve. Unresolved
    -- there, they are counted as `composed`, a frontier, never findings; the base is not read through the component)
    local component = {}
    for v in pairs(stats.variants) do
        for _, kf in ipairs({ 'kustomization.yaml', 'kustomization.yml', 'Kustomization' }) do
            local fd = io.open(data.root .. '/' .. v .. '/' .. kf, 'r')
            if fd then
                local txt = fd:read('a'); fd:close()
                if txt:match('\nkind:%s*Component%s') or txt:match('^kind:%s*Component%s') then component[v] = true end
                break
            end
        end
    end
    stats.components = component
    for _, e in ipairs(stats.docs_soft or {}) do
        local d = e.d
        for _, r in ipairs(d.refs or {}) do
            if r.how == 'selector' then
                if r.kind == 'Pod' then
                    local hits = 0
                    for _, o in ipairs(stats.docs_soft) do
                        if o.variant == e.variant and o.d.podlabels then
                            local ok = true
                            for k, v in pairs(r.sel) do if o.d.podlabels[k] ~= v then ok = false; break end end
                            if ok then
                                hits = hits + 1
                                -- (a workload's own spec.selector matches its own template: counted, no self-edge)
                                if o ~= e then data.edges[#data.edges + 1] = { from = e.d.node or e.rel, to = o.d.node or o.rel, kind = 'use', k8 = 'selects', kpath = r.path, at = M.site(d, r.path) }; soft.selects = soft.selects + 1 end
                            end
                        end
                    end
                    if hits == 0 and component[e.variant] then soft.composed = soft.composed + 1
                    elseif hits == 0 then soft.empty[#soft.empty + 1] = ('%s/%s %s selects no pod in %s'):format(d.kind, d.name or '?', r.path, e.variant) end
                else soft.cluster = soft.cluster + 1 end
            else
                local key = e.variant .. '\31' .. r.kind .. '\31' .. r.name
                local to = (stats.object_nodes or {})[key] or (stats.objects or {})[key]
                if to then
                    soft.resolved = soft.resolved + 1
                    soft.inbound[e.variant .. '\31' .. r.kind .. '\31' .. r.name] = true
                    local from = e.d.node or e.rel
                    if to ~= from then data.edges[#data.edges + 1] = { from = from, to = to, kind = 'use', k8 = 'references', kpath = r.path, at = M.site(d, r.path, r.name) } end
                elseif API and API.cluster[r.kind] then soft.cluster = soft.cluster + 1
                elseif r.optional then soft.optional = soft.optional + 1
                elseif r.kind == 'ServiceAccount' and r.name == 'default' then soft.implicit = soft.implicit + 1
                elseif component[e.variant] then soft.composed = soft.composed + 1
                else soft.dangling[#soft.dangling + 1] = ('%s/%s %s names %s/%s, absent from %s'):format(d.kind, d.name or '?', r.path, r.kind, r.name, e.variant) end
            end
        end
    end
    table.sort(soft.dangling)
    table.sort(soft.empty)
    -- the DEBUG / MANAGEMENT LISTENERS each workload starts (CART-1388), at the line that starts them
    stats.exposed = {}
    for _, e in ipairs(stats.docs_soft or {}) do
        local d = e.d
        local function line_of(needle)
            local l = 0
            for line in ((d.chunk or '') .. '\n'):gmatch('([^\n]*)\n') do
                l = l + 1
                if line:find(needle, 1, true) then return (d.line0 or 0) + l end
            end
            return (d.line0 or 0) + 1
        end
        for _, x in ipairs(d.debug or {}) do
            local where = ('%s/%s %scontainer %s'):format(d.kind, d.name or '?', x.init and 'init ' or '', x.container)
            if x.jdwp then
                local o = {}
                for k, v in x.jdwp:gmatch('([%w_]+)=([^,]*)') do o[k] = v end
                local host = (o.address or ''):match('^(.*):%d+$')
                if o.server == 'y' and host and (host == '*' or host == '0.0.0.0' or host == '::' or host == '[::]') then
                    stats.exposed[#stats.exposed + 1] = { finding = 'debug-listener', file = e.rel, line = line_of(x.jdwp),
                        message = ('%s starts a JDWP debugger listening on all interfaces (%s): remote code execution for anything that reaches the pod'):format(where, o.address) }
                end
            elseif x.jmx then
                stats.exposed[#stats.exposed + 1] = { finding = 'jmx-unauthenticated', file = e.rel, line = line_of('jmxremote.port=' .. x.jmx),
                    message = ('%s opens remote JMX on port %s with authentication off%s: anything that reaches the pod can invoke MBeans'):format(where, x.jmx, x.ssl_off and ' and SSL off' or '') }
            end
        end
    end
    table.sort(stats.exposed, function (a, b) if a.file ~= b.file then return a.file < b.file end return a.line < b.line end)

    -- ── PASS 2c: THE DELETION FRONTIER (CART-0139, design kubernetes/: "is this safe to delete?" is a question about
    -- ABSENT edges). Only DATA kinds are asked about — derived from the API table: the kinds some reference names
    -- (ConfigMap, Secret, PersistentVolumeClaim, ServiceAccount …) minus workloads (a pod template) and routers (a
    -- kind that itself declares a selector: Service). Each object of such a kind in the release is TIERED, never a
    -- delete button: LIVE (a reference resolves to it), `~` CANDIDATE (no static reference, but an operator or a
    -- monthly CronJob may read it by name through the API), DARK (the release ships a kind the API table does not know
    -- — a custom resource — whose references cartograph cannot read: the one row that matters, said with how far the
    -- sight goes).
    local data_kind = {}
    if API then
        local router = {}
        for _, r in ipairs(API.refs) do if r[4] == 'selector' then router[r[1]] = true end end
        for _, r in ipairs(API.refs) do
            local t = r[3]
            if t and (r[4] == 'name' or r[4] == 'ref') and not API.pod[t] and not router[t] and not API.cluster[t] then data_kind[t] = true end
        end
    end
    local unknown_kinds = {}
    for k in pairs(stats.objects or {}) do
        local variant, kind = k:match('^(.-)\31([^\31]+)\31')
        if API and kind and not API.group[kind] then unknown_kinds[variant] = unknown_kinds[variant] or {}; unknown_kinds[variant][kind] = true end
    end
    local orphans = { live = 0, candidates = {}, dark = {} }
    for k in pairs(stats.objects or {}) do
        local variant, kind, name = k:match('^(.-)\31([^\31]+)\31(.+)$')
        if kind and data_kind[kind] and not component[variant] then
            if soft.inbound[k] then orphans.live = orphans.live + 1
            elseif unknown_kinds[variant] then
                local ks = vim.tbl_keys(unknown_kinds[variant]); table.sort(ks)
                orphans.dark[#orphans.dark + 1] = ('%s/%s in %s — no reference cartograph can read, and the release ships %s (custom resources whose references are not read)'):format(kind, name, variant, table.concat(ks, ', '))
            else
                orphans.candidates[#orphans.candidates + 1] = ('%s/%s in %s — no static reference in the release (an operator or a job may still read it by name: never auto-delete)'):format(kind, name, variant)
            end
        end
    end
    table.sort(orphans.candidates); table.sort(orphans.dark)
    stats.orphans = orphans

    -- ── ★★★ PASS 3: THE EDGE THAT FUSES THE LAYER TO THE CODE. Without it the
    -- deployment is an ISLAND — measured on microservices-demo, the composed
    -- graph had 42 deployment->deployment edges and ZERO deployment->source, so
    -- the manifests were 68 nodes nobody could reach from a source file and
    -- nothing could reach from them. A manifest deploys an IMAGE, skaffold
    -- declares which directory BUILDS that image, and the source modules under
    -- that directory are what the manifest is about. One edge per service, every
    -- one of them oracle-backed; a service whose image skaffold does not name
    -- (redis, busybox) gets none, because it has no source here to point at.
    -- ⚠ DIRECTION: manifest -> source. The deployment REFERS to the code; the
    -- code does not know it is deployed.
    local bydir = {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'module' and n.file and not n.pb and not n.k8 then
            local d = n.file:match('^(.*)/[^/]+$')
            while d and d ~= '' do
                bydir[d] = bydir[d] or {}
                table.insert(bydir[d], n.id)
                d = d:match('^(.*)/[^/]+$')
            end
        end
    end
    for _, s in pairs(stats.services_map) do
        local mods = s.dir and (bydir[s.dir] or bydir[(s.dir:gsub('^src/', ''))])
        if mods and s.files[1] then
            for _, m in ipairs(mods) do
                data.edges[#data.edges + 1] = { from = s.files[1], to = m,
                    kind = 'use', k8 = 'deploys', at = {} }
                stats.deploys = (stats.deploys or 0) + 1
            end
        end
    end

    data.k8s = stats
    return stats
end

--- ★ THE PROBE IS A CALL SITE (CART-0834): the kubelet calls a gRPC probe's container on the gRPC HEALTH contract —
--- `/grpc.health.v1.Health/Check` — every few seconds, so the manifest DECLARES a caller the source never contains (on
--- microservices-demo, the most-called rpc of the running system). Runs AFTER the proto pass has minted the rpc nodes
--- (the post-pass calls it from the proto step: k8s runs before proto so `deploys` exists while contracts bind): a
--- `use` edge, k8 = 'probes', from the manifest to every rpc node whose WIRE path is the Health check (vendored copies
--- of health.proto are one contract, joined by wire). No such node: the probe is counted as a frontier (the contract
--- is not in this graph). An httpGet probe is a different boundary and is never minted as a gRPC call.
M.HEALTH_WIRE = '/grpc.health.v1.Health/Check'
function M.link_probes(data)
    local s = data and data.k8s
    if not s or not s.probes then return nil end
    local targets = {}
    for _, n in ipairs(data.nodes or {}) do if n.pb == 'rpc' and n.wire == M.HEALTH_WIRE then targets[#targets + 1] = n.id end end
    local p = { grpc = 0, linked = 0, unlinked = 0, http = 0, edges = 0 }
    for _, pr in ipairs(s.probes) do
        if pr.kind == 'http' then p.http = p.http + 1
        else
            p.grpc = p.grpc + 1
            if #targets > 0 then
                p.linked = p.linked + 1
                for _, t in ipairs(targets) do
                    data.edges[#data.edges + 1] = { from = pr.node or pr.rel, to = t, kind = 'use', k8 = 'probes', at = pr.at or {} }
                    p.edges = p.edges + 1
                end
            else p.unlinked = p.unlinked + 1 end
        end
    end
    s.probe_links = p
    return p
end

--- service name -> source directory, the join a runtime observation needs.
--- `service.name` in an OTel span is declared in NEITHER the source NOR the
--- manifests (CART-0829), so this is the only place the mapping can come from —
--- and it comes from skaffold's declared build context, not from a guess.
function M.dir_of(data, service)
    local k = data and data.k8s
    for _, s in pairs(k and k.services_map or {}) do
        if s.name == service and s.dir then return s.dir, s.variant end
    end
    return nil
end

--- the lines that say what the INPUT was: a renderable chart, untracked declarations, what was counted not read
local function honesty(s)
    local l = {}
    local templated = 0
    for _, r in ipairs(s.refusals or {}) do if r:find('templated', 1, true) then templated = templated + 1 end end
    if templated > 0 and #(s.chart_roots or {}) > 0 then
        l[#l + 1] = ('templated documents under a chart root (%s): render with `helm template --output-dir` to read them')
            :format(table.concat(s.chart_roots, ', '))
    end
    local only, total = {}, 0
    for _, sv in pairs(s.services_map or {}) do
        total = total + 1
        if sv.untracked and sv.untracked == #sv.files then only[#only + 1] = sv.name end
    end
    table.sort(only)
    if #only > 0 then l[#l + 1] = ('%d of %d service(s) declared ONLY by files git does not track: %s'):format(#only, total, table.concat(only, ' ')) end
    local ext = vim.tbl_keys(s.external or {})
    table.sort(ext)
    if #ext > 0 then l[#l + 1] = ('%d external host(s) named by URL (a frontier, not a peer): %s'):format(#ext, table.concat(ext, ' ')) end
    if (s.shell_urls or 0) > 0 then l[#l + 1] = ('%d URL(s) inside a command/args (shell is not read)'):format(s.shell_urls) end
    if (s.embedded or 0) > 0 then l[#l + 1] = ('%d embedded document(s) in ConfigMap data (counted, not read)'):format(s.embedded) end
    if #l == 0 then return '' end
    return '\n  · ' .. table.concat(l, '\n  · ')
end

--- the SOFT-EDGE lines: what resolved, what the cluster provides, and the two silent-success findings
local function soft_lines(s)
    local f = s.soft
    if not f then return '' end
    local l = {}
    if f.resolved + f.selects + f.cluster + f.optional + f.implicit + #f.dangling + #f.empty > 0 then
        l[#l + 1] = ('soft edges (derived from the API types, %s): %d reference(s) resolved, %d selector edge(s), %d cluster-provided (a frontier), %d optional, %d implicit%s')
            :format(API and API.stamp or 'no table', f.resolved, f.selects, f.cluster, f.optional, f.implicit,
                (f.composed or 0) > 0 and (', %d inside kustomize components (resolve in the base they compose with: a frontier)'):format(f.composed) or '')
    end
    if #f.dangling > 0 then l[#l + 1] = ('⚠ %d reference(s) to an object the release does not ship: %s'):format(#f.dangling, table.concat(f.dangling, ' · ')) end
    if #f.empty > 0 then l[#l + 1] = ('⚠ %d selector(s) match no pod template (exists, routes nowhere): %s'):format(#f.empty, table.concat(f.empty, ' · ')) end
    local pl = s.probe_links
    if pl and (pl.grpc + pl.http) > 0 then
        l[#l + 1] = ('probes: %d gRPC (%d linked to the Health contract, %d with no Health rpc in this graph — a frontier), %d httpGet (a different boundary, not linked)')
            :format(pl.grpc, pl.linked, pl.unlinked, pl.http)
    end
    local o = s.orphans
    if o and (o.live + #o.candidates + #o.dark) > 0 then
        l[#l + 1] = ('deletion frontier: %d data object(s) live (referenced), %d `~` candidate(s), %d dark%s%s'):format(o.live, #o.candidates, #o.dark,
            #o.candidates > 0 and (' — ~ ' .. table.concat(o.candidates, ' · ')) or '', #o.dark > 0 and (' — dark ' .. table.concat(o.dark, ' · ')) or '')
    end
    if #l == 0 then return '' end
    return '\n  · ' .. table.concat(l, '\n  · ')
end

function M.summary(s)
    -- ⚠ A REFUSAL-ONLY RESULT IS STILL A RESULT (CART-1043): with no manifest read but documents
    -- refused, the old `files == 0 -> nil` made the refusal counter silent exactly when the whole
    -- layer was refused (113 of 113 helmfile/values documents on jenkins-infra).
    if s and s.files == 0 and (s.refused or 0) > 0 then
        return ('k8s: 0 manifests read, %d document(s) refused (%s)'):format(s.refused,
            table.concat(s.refusals or {}, '; '):sub(1, 160)) .. honesty(s)
    end
    if not s or s.files == 0 then return nil end
    local unm = {}
    for i in pairs(s.unmapped) do unm[#unm + 1] = i end
    table.sort(unm)
    local mapped = 0
    for _, sv in pairs(s.services_map) do if sv.dir then mapped = mapped + 1 end end
    local vs = {}
    for v, n in pairs(s.variants) do vs[#vs + 1] = ('%s(%d)'):format(v, n) end
    table.sort(vs)
    return ('k8s: %d manifest(s) in %d deployment variant(s) [%s], %d document(s)'
        .. ' — %d service decl(s) (%d mapped to a source dir), %d declared'
        .. ' edge(s), %d deploys-edge(s) into the source%s%s')
        :format(s.files, #vs, table.concat(vs, ' '), s.docs, s.services, mapped, s.edges,
            s.deploys or 0,
            #unm > 0 and (' · %d image(s) with no skaffold context: %s')
                :format(#unm, table.concat(unm, ' ')) or '',
            s.refused > 0 and (' · %d REFUSED document(s): %s')
                :format(s.refused, table.concat(s.refusals, ' ')) or '')
        .. (#s.dangling > 0 and ('\n  ⚠ %d declared peer(s) absent from their own'
            .. ' deployment (one-sided edge, NOT automatically a bug): %s')
            :format(#s.dangling, table.concat(s.dangling, ' · ')) or '') .. soft_lines(s)
        .. ((s.schema and #s.schema > 0) and ('\n  ⚠ %d field(s) the API types do not accept (unknown fields are DROPPED, wrong types REJECTED): %s')
            :format(#s.schema, table.concat(vim.tbl_map(function (f) return f.file .. ':' .. f.line .. ' ' .. require('cartograph.k8sschema').text(f) end, { unpack(s.schema, 1, 3) }), ' · ')) or '')
        .. honesty(s)
end

return M
