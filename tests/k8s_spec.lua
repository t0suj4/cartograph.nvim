-- cartograph.k8s over a `helm template --output-dir` render (design helm-charts/02, 2026-10-01): the user's anonymized
-- fixture, vendored (tests/fixtures/k8s-rendered-chart — the design corpus's examples/k8s-rendered-chart/render). Each
-- arm of its expected table is asserted at its WANT; each counterexample must stay quiet. One release, one template
-- directory per service, peers wired by URL; `app-api` / `app-project-api` referenced but not rendered.
local K = require 'cartograph.k8s'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'yaml') end
local function tmproot(files)
    local root = vim.fn.tempname()
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local cached
local function run()
    if cached then return cached end
    local data = { root = vim.fn.getcwd() .. '/tests/fixtures/k8s-rendered-chart/render', nodes = {}, edges = {} }
    local s = K.attach(data)
    local by = {}
    for _, sv in pairs(s.services_map) do by[sv.name] = sv end
    local edges = {}
    for _, e in ipairs(data.edges) do
        if e.k8 == 'declares' then
            local function svc(f) return f:match('templates/([^/]+)/') .. '/' .. f:match('([^/]+)%.yaml$') end
            edges[svc(e.from) .. ' -> ' .. svc(e.to)] = true
        end
    end
    cached = { s = s, by = by, edges = edges, data = data }
    return cached
end
local function ports(sv) return table.concat(sv and sv.ports or {}, ',') end

test('k8s rendered chart: PORTS from the parsed lists — `- containerPort:`, a name-first Service item (P1-P3); the working shape kept (CE)', function ()
    if not ready() then skip 'no yaml parser' end
    local r = run()
    eq({ '8080', '8081', '8080' }, { ports(r.by['app-gateway']), ports(r.by['app-registry']), ports(r.by['app-history']) })
end)

test('k8s rendered chart: every POD-TEMPLATE kind is a workload (W1), the first CONTAINER names it — not an init container (W2, CE)', function ()
    if not ready() then skip 'no yaml parser' end
    local r = run()
    eq({ 'tracing', 'trigger', 'trigger-worker' }, { r.by['app-tracing'].image, r.by['app-trigger'].image, r.by['app-trigger-worker'].image })
end)

test('k8s rendered chart: the RELEASE ROOT is the variant (`# Source:`), so peers across template dirs resolve (E1-E4, CE)', function ()
    if not ready() then skip 'no yaml parser' end
    local r = run()
    local n = 0
    for _ in pairs(r.s.variants) do n = n + 1 end
    eq(1, n, 'one release, not one variant per directory')
    for _, e in ipairs({ 'gateway/deployment -> history/deployment', 'history/deployment -> registry/deployment',
        'trigger/deployment -> registry/deployment', 'trigger/worker -> trigger/deployment' }) do
        ok(r.edges[e], 'edge ' .. e)
    end
    local tracing = false
    for e in pairs(r.edges) do if e:match('^tracing/') and e:find('registry/', 1, true) then tracing = true end end
    ok(tracing, 'E2: the StatefulSet\'s URL env reaches registry')
end)

test('k8s rendered chart: DANGLING peers by exact host — D1, D2 (an in-cluster FQDN reduced), N4 never resolved to a prefix', function ()
    if not ready() then skip 'no yaml parser' end
    local d = table.concat(run().s.dangling, '\n')
    eq({ true, true, true, true }, { d:find('app-gateway declares app-api', 1, true) ~= nil, d:find('app-gateway declares app-project-api', 1, true) ~= nil,
        d:find('app-history declares app-api', 1, true) ~= nil, d:find('app-trigger declares app-registry-ui', 1, true) ~= nil })
    eq(5, #run().s.dangling)
end)

test('k8s rendered chart: COUNTEREXAMPLES stay quiet — an external host, a configMapRef name, shell, a comment, a bind address; an empty render is not refused', function ()
    if not ready() then skip 'no yaml parser' end
    local r = run()
    local d = table.concat(r.s.dangling, '\n')
    for _, quiet in ipairs({ 'broker', 'app-registry-config', 'app-legacy', '0.0.0.0' }) do ok(not d:find(quiet, 1, true), 'quiet: ' .. quiet) end
    ok(not r.by['app-legacy'], 'N5: a commented-out env pair declares nothing')
    eq({ 0, 1 }, { r.s.refused, r.s.shell_urls }, 'N7 not refused; N3 counted, not scraped')
    ok(K.summary(r.s):find('inside a command/args', 1, true), 'the summary names the counted shell')
end)

test('k8s: a DOTTED external URL host is a counted frontier, never dangling; `localhost` and a bind address are no peer', function ()
    if not ready() then skip 'no yaml parser' end
    local root = tmproot({ ['k/a.yaml'] = table.concat({
        'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: a', 'spec:', '  template:', '    spec:', '      containers:',
        '      - name: a', '        image: a', '        env:',
        '        - name: UPSTREAM_URL', '          value: https://api.example.org/v1',
        '        - name: SELF_URL', '          value: http://localhost:8080',
        '        - name: BIND_URL', '          value: http://0.0.0.0:9000',
        '        - name: PEER_URL', '          value: http://b:8080' }, '\n') .. '\n' })
    local s = K.attach({ root = root, nodes = {}, edges = {} })
    eq({ 'a declares b, absent from k' }, s.dangling, 'only the undotted peer dangles')
    eq({ ['api.example.org'] = true }, s.external)
end)
