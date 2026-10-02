-- CART-1042: the Helm release layer — which charts run where, with which values, layered how.
-- ★ MEASURED ON jenkins-infra/kubernetes-management: 4 helmfiles, 55 releases, 65 values layers;
-- k8s had refused all 113 documents and said nothing (CART-1043). These pin the rules on a
-- fixture shaped like that repo.

local H = require 'cartograph.helmfile'
local K = require 'cartograph.k8s'
local A = assert(require('cartograph.algebra').load())

local function ready()
    if not parser_available('yaml') then skip('no yaml tree-sitter parser') end
end

local function repo(files)
    local root = vim.fn.tempname()
    for rel, body in pairs(files) do
        local p = root .. '/' .. rel
        vim.fn.mkdir(vim.fn.fnamemodify(p, ':h'), 'p')
        local fd = assert(io.open(p, 'w')); fd:write(body); fd:close()
    end
    return root
end

local FILES = {
    ['clusters/east.yaml'] = table.concat({
        'releases:',
        '  - name: site',
        '    namespace: web',
        '    chart: infra/website',
        '    version: 1.2.0',
        '    values:',
        '      - ../config/site.yaml',
        '      - ../config/east/site.yaml',
        '    secrets:',
        '      - ../secrets/site.yaml',
        '  - name: metrics',
        '    chart: vendor/metrics',
        '    version: 3.0.0',
        '    values:',
        '      - ../config/metrics.yaml.gotmpl',
        '      - ../config/east/gone.yaml',
        '' }, '\n'),
    ['clusters/west.yaml'] = table.concat({
        'releases:',
        '  - name: site',
        '    chart: infra/website',
        '    version: 1.3.0',
        '    values:',
        '      - ../config/site.yaml',
        '      - ../config/west/site.yaml',
        '' }, '\n'),
    ['config/site.yaml'] = 'replicas: 2\ningress:\n  hosts:\n    - site.example.org\n  class: nginx\n',
    ['config/east/site.yaml'] = 'replicas: 3\ningress:\n  class: nginx\n',          -- class restates the base
    ['config/west/site.yaml'] = 'ingress:\n  hosts:\n    - west.example.org\nreplicas: null\n', -- null deletes
    ['config/metrics.yaml.gotmpl'] = 'name: {{ .Environment.Name }}\n',
    ['deploy/manifest.yaml'] = 'apiVersion: v1\nkind: Service\nmetadata:\n  name: plain\n',
}

test('helmfile: releases, layered values merged by Helm\'s rule, and the states of every layer', function ()
    ready()
    local root = repo(FILES)
    local data = { root = root, nodes = {}, edges = {} }
    local s = H.attach(data)
    eq(2, s.helmfiles); eq(3, s.releases)
    eq(1, s.templated); eq(1, s.missing); eq(1, s.secrets)
    local by = {}
    for _, r in ipairs(data.helmfile.releases) do by[r.id] = r end
    -- east: the cluster layer overrides replicas, keeps the base host
    eq('3', by['east/site'].effective.o.replicas)
    eq('site.example.org', by['east/site'].effective.o.ingress.o.hosts.a[1])
    -- west: a LIST replaces (not merges), and `null` deletes the key
    eq(1, #by['west/site'].effective.o.ingress.o.hosts.a)
    eq('west.example.org', by['west/site'].effective.o.ingress.o.hosts.a[1])
    eq(nil, by['west/site'].effective.o.replicas)
    -- the gotmpl layer is a template: skipped, and the release says its values are a lower bound
    eq(true, by['east/metrics'].lower_bound)
end)

test('helmfile: a no-op override is found, hosts are served, and chart version SKEW is named', function ()
    ready()
    local data = { root = repo(FILES), nodes = {}, edges = {} }
    local s = H.attach(data)
    eq(1, s.noops) -- east restates `ingress.class`
    ok(data.helmfile.served['site.example.org'], 'the base host is served')
    ok(data.helmfile.served['west.example.org'], 'the west host is served')
    eq(1, s.skew) -- infra/website at 1.2.0 on east and 1.3.0 on west
    eq(true, data.helmfile.charts['infra/website'].skew)
end)

test('helmfile: files are CLAIMED, so k8s sees only real manifests; re-attaching is idempotent', function ()
    ready()
    local data = { root = repo(FILES), nodes = {}, edges = {} }
    H.attach(data)
    local n1, e1 = #data.nodes, #data.edges
    ok(data.helmfile.claimed['config/east/site.yaml'], 'a read values file is claimed')
    ok(not data.helmfile.claimed['deploy/manifest.yaml'], 'a plain manifest is not')
    H.attach(data)
    eq(n1, #data.nodes); eq(e1, #data.edges)
    local rest = {}
    for _, f in ipairs(K.find(data.root)) do if not data.helmfile.claimed[f] then rest[#rest + 1] = f end end
    local ks = K.attach(data, { files = rest })
    eq(0, ks.refused) -- without claiming, every values file would be a refused "manifest"
end)

test('helmfile: a CHART FAMILY is recovered — what every release of the chart shares, and the parameters', function ()
    ready()
    local data = { root = repo(FILES), nodes = {}, edges = {} }
    H.attach(data)
    local an = assert(H.family(data, 'infra/website'))
    eq(2, #an.families[1].ids)
    local R = an.families[1].R
    ok(#R.holes > 0, 'the two sites differ somewhere')
    -- the shared ingress class is part of the template, not a hole
    ok(A.kv_eq(R.template.o.ingress.o.class, 'nginx'), 'the class both share is fixed')
end)

test('k8s: a REFUSAL-ONLY result is reported, not silent (CART-1043)', function ()
    local line = K.summary({ files = 0, docs = 0, services = 0, refused = 3,
        refusals = { 'a.yaml: no kind:' }, services_map = {}, unmapped = {}, variants = {} })
    ok(line and line:find('3 document', 1, true), tostring(line))
    eq(nil, K.summary({ files = 0, refused = 0, refusals = {} }))
end)

test('helmfile: a NO-OP override is one HELM loads the same — a quoted "true" over `true` changes the type, `yes` over `true` does not', function ()
    if not parser_available('yaml') then skip('no yaml tree-sitter parser') end
    local Y = require 'cartograph.yamlvalue'
    local H = require 'cartograph.helmfile'
    local base = assert(Y.helm_values('ann:\n  internal: true\nport: 8080\n'))
    eq({}, H.noops(base, assert(Y.helm_values('ann:\n  internal: "true"\n'))),
        'jenkins-infra kubernetes-management: the cluster layer QUOTES the annotation (it must be a string) — not a no-op')
    eq({ '$.ann.internal' }, H.noops(base, assert(Y.helm_values('ann:\n  internal: yes\n'))), 'yes IS true to Helm (YAML 1.1)')
    eq({ '$.port' }, H.noops(base, assert(Y.helm_values('port: 8080.0\n'))), 'one float64 to Helm')
end)

test('helmfile: read() compares LAYERS as Helm types them — the quoted annotation is no no-op, a restated port is', function ()
    ready()
    local root = repo({
        ['clusters/c.yaml'] = 'releases:\n  - name: ingress\n    chart: x/ingress\n    values:\n      - ../config/common.yaml\n      - ../config/c/ingress.yaml\n',
        ['config/common.yaml'] = 'ann:\n  internal: true\nport: 80\n',
        ['config/c/ingress.yaml'] = 'ann:\n  internal: "true"\nport: 80\n',
    })
    local hf = assert(H.read(root, 'clusters/c.yaml'))
    eq({ '$.port' }, hf.releases[1].noops)
end)

test('helmfile: only a .gotmpl layer is a TEMPLATE — a `{{` in a plain values file is a string for the chart\'s own tpl', function ()
    ready()
    local root = repo({
        ['clusters/c.yaml'] = 'releases:\n  - name: kc\n    chart: x/keycloak\n    values:\n      - ../config/kc.yaml\n',
        ['config/kc.yaml'] = 'db:\n  name: \'{{ include "keycloak.fullname" . }}-db\'\n',
    })
    local r = assert(H.read(root, 'clusters/c.yaml')).releases[1]
    eq('read', r.layers[1].state)
    eq(false, r.lower_bound)
    eq('{{ include "keycloak.fullname" . }}-db', r.effective.o.db.o.name, 'kept literally, as helmfile hands it to the chart')
end)

test('helmfile: a .gotmpl layer RENDERED by helmfile itself — state values, .Release, a <no value> overridden or REACHING the chart, a private file stood in', function ()
    ready()
    if not H.binary() then skip 'no helmfile binary (install it: pkgit -i helmfile)' end
    local root = repo({
        ['clusters/c.yaml'] = table.concat({
            'values:', '  - region: eu', 'releases:',
            '  - name: app', '    chart: x/app', '    values:', '      - ../config/app.yaml.gotmpl', '      - ../config/c/app.yaml',
            '    secrets:', '      - ../secrets/app.yaml',
            '  - name: other', '    chart: x/other', '    values:', '      - ../config/other.yaml.gotmpl' }, '\n') .. '\n',
        -- (`get "k" nil` on an absent key PRINTS `<no value>`; a bare `.Values.nope` is an error: helmfile renders values
        -- templates with missingkey=error — kubernetes-management's datadog.yaml.gotmpl is the first shape)
        ['config/app.yaml.gotmpl'] = 'region: {{ .Values.region }}\nname: {{ .Release.Name }}\nlost: {{ .Values | get "nope" nil }}\n',
        ['config/c/app.yaml'] = 'lost: fixed\n',
        ['config/other.yaml.gotmpl'] = 'gone: {{ .Values | get "nope" nil }}\n',
    })
    vim.system({ 'sh', '-c', 'cd "$1" && git init -q && git add -A', 'sh', root }):wait()
    local data = { root = root, nodes = {}, edges = {} }
    local st = H.attach(data)
    eq({}, st.render_refusals)
    eq({ 'secrets/app.yaml' }, st.standins, 'the private file is stood in by {} and listed')
    local by = {}
    for _, r in ipairs(data.helmfile.releases) do by[r.name] = r end
    eq('rendered', by.app.layers[1].state)
    eq(false, by.app.lower_bound)
    eq('eu', by.app.effective.o.region, '.Values in a values template = the helmfile\'s STATE values')
    eq('app', by.app.effective.o.name, '.Release is the release')
    eq('fixed', by.app.effective.o.lost)
    eq({ { path = '$.lost', file = 'config/app.yaml.gotmpl', reaches = false } }, by.app.novalue, 'overridden by config/c/app.yaml')
    eq({ { path = '$.gone', file = 'config/other.yaml.gotmpl', reaches = true } }, by.other.novalue, 'nothing overrides it: the chart receives the literal string')
    -- a bare missing key is helmfile's own error: the render is REFUSED by name, the layer stays a lower bound
    local f = io.open(root .. '/config/other.yaml.gotmpl', 'w'); f:write('gone: {{ .Values.nope }}\n'); f:close()
    vim.system({ 'sh', '-c', 'cd "$1" && git add -A', 'sh', root }):wait()
    local data2 = { root = root, nodes = {}, edges = {} }
    local st2 = H.attach(data2)
    eq(1, #st2.render_refusals)
    ok(st2.render_refusals[1]:find('map has no entry for key "nope"', 1, true), st2.render_refusals[1])
    eq(true, data2.helmfile.releases[1].lower_bound)
end)
