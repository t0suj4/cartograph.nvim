-- CART-1042: the Helm release layer — which charts run where, with which values, layered how.
-- ★ MEASURED ON jenkins-infra/kubernetes-management: 4 helmfiles, 55 releases, 65 values layers;
-- k8s had refused all 113 documents and said nothing (CART-1043). These pin the rules on a
-- fixture shaped like that repo.

local H = require 'cartograph.helmfile'
local K = require 'cartograph.k8s'
local A = assert(require('cartograph.algebra').load())

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'yaml') then skip('no yaml tree-sitter parser') end
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
