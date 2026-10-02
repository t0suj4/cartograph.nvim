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
