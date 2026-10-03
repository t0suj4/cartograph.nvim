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

-- ── SOFT EDGES, from the DERIVED API table (CART-1267 / CART-1296): every class of absence, each counter pinned ─────
--- (one object per FILE, as `helm template --output-dir` writes them: edges join files, so a release in one file would
--- resolve its references without an edge to draw)
local function soft_release()
    local text = table.concat({
        'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: web', 'spec:',
        '  selector:', '    matchLabels:', '      app: web',
        '  template:', '    metadata:', '      labels:', '        app: web', '    spec:',
        '      serviceAccountName: default', '      containers:', '      - name: web', '        image: web',
        '        ports:', '        - name: http', '          containerPort: 8080',
        '        envFrom:', '        - configMapRef:', '            name: web-config',
        '        env:', '        - name: TOKEN', '          valueFrom:', '            secretKeyRef:', '              name: web-token', '              key: t',
        '        - name: FLAG', '          valueFrom:', '            configMapKeyRef:', '              name: flags', '              key: f', '              optional: true',
        '---', 'apiVersion: v1', 'kind: ConfigMap', 'metadata:', '  name: web-config', 'data:', '  A: "1"',
        '---', 'apiVersion: v1', 'kind: Service', 'metadata:', '  name: web', 'spec:', '  selector:', '    app: web', '  ports:', '  - port: 80',
        '---', 'apiVersion: v1', 'kind: Service', 'metadata:', '  name: api', 'spec:', '  selector:', '    app: api', '  ports:', '  - port: 80',
        '---', 'apiVersion: networking.k8s.io/v1', 'kind: Ingress', 'metadata:', '  name: in', 'spec:', '  rules:', '  - http:', '      paths:',
        '      - path: /', '        pathType: Prefix', '        backend:', '          service:', '            name: web', '            port:', '              number: 80',
        '---', 'apiVersion: v1', 'kind: PersistentVolumeClaim', 'metadata:', '  name: data', 'spec:', '  storageClassName: fast',
        '---', 'apiVersion: batch/v1', 'kind: CronJob', 'metadata:', '  name: nightly', 'spec:', '  schedule: "0 0 * * *"', '  jobTemplate:', '    spec:',
        '      template:', '        spec:', '          containers:', '          - name: job', '            image: nightly-job' }, '\n') .. '\n'
    local files, i = {}, 0
    for doc in (text .. '---\n'):gmatch('(.-)%-%-%-\n') do if doc:match('%S') then i = i + 1; files[('k/%02d.yaml'):format(i)] = doc end end
    return tmproot(files)
end

test('k8s: SOFT EDGES resolve by kind and name in the release; the classes of absence are told apart — CART-1296', function ()
    if not ready() then skip 'no yaml parser' end
    local data = { root = soft_release(), nodes = {}, edges = {} }
    local s = K.attach(data)
    local f = s.soft
    ok(K._api ~= nil, 'the generated API table loads')
    -- envFrom ConfigMap present + Ingress -> Service web: two resolved references
    eq(2, f.resolved, 'configMapRef web-config and the Ingress backend service web')
    eq({ 'Deployment/web spec.template.spec.containers[].env[].valueFrom.secretKeyRef names Secret/web-token, absent from k' }, f.dangling,
        'the Secret the release does not ship dangles — and the port NAME `http` is no reference')
    eq(1, f.optional, 'the optional configMapKeyRef is absent and allowed to be')
    eq(1, f.implicit, 'serviceAccountName: default exists in every namespace')
    eq(1, f.cluster, 'storageClassName: fast is the cluster\'s (StorageClass is cluster-scoped)')
    local by = {}
    for _, e in ipairs(data.edges) do if e.k8 then by[e.k8] = (by[e.k8] or 0) + 1 end end
    eq(2, by.references, 'resolved references are edges')
    eq(1, by.selects, 'Service web -> the Deployment whose pod template it selects (its own spec.selector makes no self-edge)')
end)

test('k8s: a selector matching NO pod template is the silent-success finding; a workload\'s own selector is not — CART-1296', function ()
    if not ready() then skip 'no yaml parser' end
    local s = K.attach({ root = soft_release(), nodes = {}, edges = {} })
    eq({ 'Service/api spec.selector{} selects no pod in k' }, s.soft.empty, 'Service api routes nowhere; Deployment web\'s own selector matches its template')
    ok(K.summary(s):find('selector(s) match no pod template', 1, true), 'the summary says it')
end)

test('k8s: the DELETION FRONTIER is tiered — live / ~ candidate / dark — never a delete list — CART-0139', function ()
    if not ready() then skip 'no yaml parser' end
    local function doc(t) return table.concat(t, '\n') .. '\n' end
    local root = tmproot({
        -- release a: one ConfigMap a workload reads (LIVE), one nothing reads (a ~ CANDIDATE)
        ['a/deploy.yaml'] = doc({ 'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: w', 'spec:', '  template:', '    spec:',
            '      containers:', '      - name: w', '        image: w', '        envFrom:', '        - configMapRef:', '            name: used' }),
        ['a/used.yaml'] = doc({ 'apiVersion: v1', 'kind: ConfigMap', 'metadata:', '  name: used', 'data:', '  A: "1"' }),
        ['a/stale.yaml'] = doc({ 'apiVersion: v1', 'kind: ConfigMap', 'metadata:', '  name: stale', 'data:', '  B: "2"' }),
        -- release b: a custom resource beside an unreferenced Secret: the Secret is DARK (the CR may name it)
        ['b/cert.yaml'] = doc({ 'apiVersion: cert-manager.io/v1', 'kind: Certificate', 'metadata:', '  name: tls', 'spec:', '  secretName: tls-key' }),
        ['b/key.yaml'] = doc({ 'apiVersion: v1', 'kind: Secret', 'metadata:', '  name: tls-key', 'data:', '  k: eA==' }),
    })
    local s = K.attach({ root = root, nodes = {}, edges = {} })
    local o = s.orphans
    eq(1, o.live, 'ConfigMap used')
    eq(1, #o.candidates); ok(o.candidates[1]:find('ConfigMap/stale in a', 1, true), o.candidates[1])
    eq(1, #o.dark); ok(o.dark[1]:find('Secret/tls-key in b', 1, true) and o.dark[1]:find('Certificate', 1, true), o.dark[1])
    ok(K.summary(s):find('deletion frontier', 1, true))
end)

test('k8s: a KUSTOMIZE COMPONENT (`kind: Component`) is composed with a base — its unresolved selector is a frontier, the same selector in a plain directory a finding', function ()
    if not ready() then skip 'no yaml parser' end
    local svc = table.concat({ 'apiVersion: v1', 'kind: Service', 'metadata:', '  name: s', 'spec:', '  selector:', '    app: elsewhere', '  ports:', '  - port: 80' }, '\n') .. '\n'
    local root = tmproot({
        ['comp/kustomization.yaml'] = 'apiVersion: kustomize.config.k8s.io/v1alpha1\nkind: Component\nresources:\n- svc.yaml\n',
        ['comp/svc.yaml'] = svc,
        ['plain/svc.yaml'] = svc,
    })
    local s = K.attach({ root = root, nodes = {}, edges = {} })
    eq({ 'Service/s spec.selector{} selects no pod in plain' }, s.soft.empty, 'only the plain directory is a release')
    eq(1, s.soft.composed, 'the component\'s selector resolves in the base it composes with')
end)

test('k8s: a gRPC PROBE is a call into the Health contract — linked when the rpc is in the graph, a frontier when not; httpGet is not a gRPC call — CART-0834', function ()
    if not ready() then skip 'no yaml parser' end
    local root = tmproot({ ['k/d.yaml'] = table.concat({
        'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: catalog', 'spec:', '  template:', '    spec:', '      containers:',
        '      - name: c', '        image: catalog', '        readinessProbe:', '          grpc:', '            port: 3550',
        '        livenessProbe:', '          httpGet:', '            path: /healthz', '            port: 8080' }, '\n') .. '\n' })
    local health = { id = 'protos/health.proto::Health::Check@41', name = 'Health::Check', kind = 'method', pb = 'rpc', wire = K.HEALTH_WIRE }
    local data = { root = root, nodes = { health }, edges = {} }
    K.attach(data)
    local p = K.link_probes(data)
    eq({ grpc = 1, linked = 1, unlinked = 0, http = 1, edges = 1 }, p)
    local e
    for _, x in ipairs(data.edges) do if x.k8 == 'probes' then e = x end end
    eq('protos/health.proto::Health::Check@41', e and e.to, 'manifest -> the Health rpc')
    local data2 = { root = root, nodes = {}, edges = {} }
    K.attach(data2)
    eq({ grpc = 1, linked = 0, unlinked = 1, http = 1, edges = 0 }, K.link_probes(data2), 'no Health rpc in the graph: a frontier, no edge')
end)

test('k8s: the POD TEMPLATE is where the API types put it — CronJob spec.jobTemplate.spec.template.spec — CART-1267', function ()
    if not ready() then skip 'no yaml parser' end
    local s = K.attach({ root = soft_release(), nodes = {}, edges = {} })
    local images = {}
    for _, sv in pairs(s.services_map) do if sv.image then images[sv.name] = sv.image end end
    eq('nightly-job', images.nightly, 'the CronJob is a workload and its image is read through the derived path')
    eq('web', images.web)
end)

test('k8s: every OBJECT is its own node (a region of its file) and the soft edges run between objects, SITED at the field — inside one file too — CART-1312', function ()
    if not ready() then skip 'no yaml parser' end
    local text = table.concat({
        'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: web', 'spec:',          -- 1-5
        '  selector:', '    matchLabels:', '      app: web',                                     -- 6-8
        '  template:', '    metadata:', '      labels:', '        app: web', '    spec:',         -- 9-13
        '      containers:', '      - name: web', '        image: web',                         -- 14-16
        '        envFrom:', '        - configMapRef:', '            name: web-config',          -- 17-19
        '---', 'apiVersion: v1', 'kind: ConfigMap', 'metadata:', '  name: web-config',           -- 20-24
        '---', 'apiVersion: v1', 'kind: Service', 'metadata:', '  name: web', 'spec:', '  selector:', '    app: web' }, '\n') .. '\n' -- 25-32
    local data = { root = tmproot({ ['all.yaml'] = text }), nodes = {}, edges = {} }
    K.attach(data)
    local objs = {}
    for _, n in ipairs(data.nodes) do if n.k8 == 'object' then objs[#objs + 1] = { n.id, n.kind, n.range.start.line + 1, n.range['end'].line + 1 } end end
    eq({ { 'all.yaml::Deployment/web', 'region', 1, 19 }, { 'all.yaml::ConfigMap/web-config', 'region', 21, 24 }, { 'all.yaml::Service/web', 'region', 26, 32 } }, objs)
    local edges = {}
    for _, e in ipairs(data.edges) do
        if e.k8 == 'references' or e.k8 == 'selects' then edges[#edges + 1] = { e.k8, e.from, e.to, e.at[1] and (e.at[1].start.line + 1) } end
    end
    table.sort(edges, function (a, b) return a[1] < b[1] end)
    eq({
        { 'references', 'all.yaml::Deployment/web', 'all.yaml::ConfigMap/web-config', 19 }, -- (inside ONE file: no longer a dropped self-edge)
        { 'selects', 'all.yaml::Service/web', 'all.yaml::Deployment/web', 31 },
    }, edges)
    local V = require 'cartograph.validate'
    eq('schema: OK', (V.report(V.check(data)) or ''):match('^schema: OK'), 'the post-pass graph is inside the closed schema')
end)

test('k8s: a REQUEST-PATH TRACE from a workload — env names the peer -> its Service port -> the selector -> the workload listening; a peer with no Service ends dangling — CART-1316', function ()
    if not ready() then skip 'no yaml parser' end
    local text = table.concat({
        'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: web', 'spec:',             -- 1-5
        '  template:', '    metadata:', '      labels:', '        app: web', '    spec:',           -- 6-10
        '      containers:', '      - name: web', '        image: web', '        env:',            -- 11-14
        '        - name: API_SERVICE_ADDR', '          value: "api:8080"',                         -- 15-16
        '        - name: GONE_SERVICE_ADDR', '          value: "gone:9000"',                        -- 17-18
        '---', 'apiVersion: v1', 'kind: Service', 'metadata:', '  name: api', 'spec:',              -- 19-24
        '  selector:', '    app: api', '  ports:', '  - port: 8080',                               -- 25-28
        '---', 'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: api', 'spec:',      -- 29-34
        '  template:', '    metadata:', '      labels:', '        app: api', '    spec:',           -- 35-39
        '      containers:', '      - name: api', '        image: api', '        ports:', '        - containerPort: 8080' }, '\n') .. '\n' -- 40-44
    local data = { root = tmproot({ ['all.yaml'] = text }), nodes = {}, edges = {} }
    K.attach(data)
    local ts = assert(K.traces(data, 'all.yaml::Deployment/web'))
    local function hops(t) return vim.tbl_map(function (h) return { h.text, h.line } end, t.hops) end
    eq({ 'api', 'gone' }, vim.tbl_map(function (t) return t.peer end, ts))
    eq({
        { 'Deployment/web names api:8080', 16 },
        { 'Service/api port 8080', 28 },
        { 'selects Deployment/api', 25 },
        { 'Deployment/api listens', 44 },
    }, hops(ts[1]))
    eq({ 'Deployment/web names gone:9000', 18 }, hops(ts[2])[1])
    ok(ts[2].hops[2].text:find('dangling', 1, true), ts[2].hops[2].text)
    local none = assert(K.traces(data, 'all.yaml::Deployment/api'))
    eq({}, none, 'api names no peer')
end)
test('k8s: the trace is a VERB — k8s_traces addressed by Kind/name or by file + line, one row per hop; no peer is an absence, no object a refusal (CART-1383)', function ()
    if not ready() then skip 'no yaml parser' end
    local text = table.concat({
        'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: web', 'spec:',             -- 1-5
        '  template:', '    metadata:', '      labels:', '        app: web', '    spec:',           -- 6-10
        '      containers:', '      - name: web', '        image: web', '        env:',            -- 11-14
        '        - name: API_SERVICE_ADDR', '          value: "api:8080"',                         -- 15-16
        '---', 'apiVersion: v1', 'kind: Service', 'metadata:', '  name: api', 'spec:',              -- 17-22
        '  selector:', '    app: api', '  ports:', '  - port: 8080',                               -- 23-26
        '---', 'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: api', 'spec:',      -- 27-32
        '  template:', '    metadata:', '      labels:', '        app: api', '    spec:',           -- 33-37
        '      containers:', '      - name: api', '        image: api', '        ports:', '        - containerPort: 8080' }, '\n') .. '\n' -- 38-42
    local data = { root = tmproot({ ['all.yaml'] = text }), nodes = {}, edges = {} }
    K.attach(data)
    local agent = require 'cartograph.agent'
    local store = { data = data }
    local d, st = agent.answer(store, 'k8s_traces', { object = 'Deployment/web' })
    eq('ok', st)
    eq({ 'Deployment/web names api:8080', 'Service/api port 8080', 'selects Deployment/api', 'Deployment/api listens' },
        vim.tbl_map(function (r) return r.text end, d.result))
    eq({ 1, 2, 3, 4 }, vim.tbl_map(function (r) return r.hop end, d.result))
    eq(16, d.result[1].line, 'each hop at its declaring line')
    -- the same object by POSITION, as :CartographK8sTrace finds it (a line inside its document)
    local p = agent.answer(store, 'k8s_traces', { file = 'all.yaml', line = 12 })
    eq(d.result, p.result)
    -- a workload naming no peer: an ABSENCE with its premise, not an empty list
    local none = agent.answer(store, 'k8s_traces', { object = 'Deployment/api' })
    eq('absent', none.absence); eq('no-peer', none.absence_why.premise)
    -- no such object, no address: REFUSALS by name
    local _, s1 = agent.answer(store, 'k8s_traces', { object = 'Deployment/nope' })
    eq('refusal', s1)
    local r2 = agent.answer(store, 'k8s_traces', {})
    eq('no-address', r2.refusal.rule)
end)
-- CART-1388 (the audit drill-down's finding of the walk itself, design corpus cve-drilldown/01): a container started
-- with a JDWP debugger in server mode on all interfaces, or remote JMX with authentication off, is remote code execution
-- for anything reaching the pod — found by hand on a real deployment, "larger than all 154 rows put together".
test('k8s: DEBUG and MANAGEMENT LISTENERS a container is started with — JDWP on all interfaces, JMX without auth — at their lines; localhost, client mode and authenticated JMX are not', function ()
    if not ready() then skip 'no yaml parser' end
    local text = table.concat({
        'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: cdc', 'spec:',                     -- 1-5
        '  template:', '    metadata:', '      labels:', '        app: cdc', '    spec:',                   -- 6-10
        '      initContainers:', '      - name: seed', '        image: seed',                             -- 11-13
        '        env:', '        - name: JAVA_TOOL_OPTIONS',                                             -- 14-15
        '          value: "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=0.0.0.0:8000"', -- 16
        '      containers:', '      - name: app', '        image: cdc', '        args:',                  -- 17-20
        '        - "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:7897"',              -- 21
        '        - "-Dcom.sun.management.jmxremote.port=9010"',                                          -- 22
        '        - "-Dcom.sun.management.jmxremote.authenticate=false"',                                 -- 23
        '        - "-Dcom.sun.management.jmxremote.ssl=false"',                                          -- 24
        '---', 'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: safe', 'spec:',          -- 25-30
        '  template:', '    metadata:', '      labels:', '        app: safe', '    spec:',               -- 31-35
        '      containers:', '      - name: a', '        image: a', '        command:',                  -- 36-39
        '        - java', '        - "-agentlib:jdwp=transport=dt_socket,server=y,address=localhost:5005"', -- 40-41
        '        - "-agentlib:jdwp=transport=dt_socket,server=y,address=5006"',                          -- 42 (JDK 9+: localhost)
        '        - "-agentlib:jdwp=transport=dt_socket,server=n,address=*:5007"',                        -- 43 (client mode: connects out)
        '        - "-Dcom.sun.management.jmxremote.port=9011"',                                          -- 44 (auth on by default)
        '      - name: b', '        image: b', '        args:',                                           -- 45-47
        '        - "-Dcom.sun.management.jmxremote.authenticate=false"' }, '\n') .. '\n'                -- 48 (no port: local attach)
    local data = { root = tmproot({ ['all.yaml'] = text }), nodes = {}, edges = {} }
    local s = K.attach(data)
    eq({
        { 'debug-listener', 16, 'Deployment/cdc init container seed starts a JDWP debugger listening on all interfaces (0.0.0.0:8000): remote code execution for anything that reaches the pod' },
        { 'debug-listener', 21, 'Deployment/cdc container app starts a JDWP debugger listening on all interfaces (*:7897): remote code execution for anything that reaches the pod' },
        { 'jmx-unauthenticated', 22, 'Deployment/cdc container app opens remote JMX on port 9010 with authentication off and SSL off: anything that reaches the pod can invoke MBeans' },
    }, vim.tbl_map(function (x) return { x.finding, x.line, x.message } end, s.exposed))
    -- and the agent verb serves them as findings, at their file and line
    local d = require('cartograph.agent').answer({ data = data }, 'k8s_findings', {})
    local got = {}
    for _, r in ipairs(d.result) do if r.finding == 'debug-listener' or r.finding == 'jmx-unauthenticated' then got[#got + 1] = r.file .. ':' .. r.line end end
    eq({ 'all.yaml:16', 'all.yaml:21', 'all.yaml:22' }, got)
end)
