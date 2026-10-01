-- cartograph.helm — a chart READ THROUGH ITS RENDERER (CART-1268): `helm template --output-dir`, then cartograph.k8s.
-- The chart is written inline to a temp dir; without a helm binary every test skips by name.
local H = require 'cartograph.helm'

local function ready() return H.binary() ~= nil and pcall(vim.treesitter.get_string_parser, '', 'yaml') end
local function chart(files)
    local root = vim.fn.tempname()
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local CHART = {
    ['Chart.yaml'] = 'apiVersion: v2\nname: shop\nversion: 0.1.0\n',
    ['values.yaml'] = 'image: shop:1.2\nbackendLabel: shop\n',
    ['templates/deployment.yaml'] = table.concat({
        'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: {{ .Release.Name }}-shop', 'spec:',
        '  selector:', '    matchLabels:', '      app: shop', '  template:', '    metadata:', '      labels:', '        app: shop',
        '    spec:', '      containers:', '      - name: shop', '        image: {{ .Values.image }}',
        '        envFrom:', '        - secretRef:', '            name: {{ .Release.Name }}-creds' }, '\n') .. '\n',
    ['templates/service.yaml'] = table.concat({
        'apiVersion: v1', 'kind: Service', 'metadata:', '  name: {{ .Release.Name }}-shop', 'spec:',
        '  selector:', '    app: {{ .Values.backendLabel }}', '  ports:', '  - port: 80' }, '\n') .. '\n',
}

test('helm: a chart is RENDERED by Helm and read by k8s — values applied, the release named, soft edges and findings', function ()
    if not ready() then skip 'no helm binary (or no yaml parser)' end
    local s, data = H.attach(chart(CHART), { release = 'r1' })
    ok(s, 'rendered')
    eq('r1', s.helm.release)
    eq(2, s.helm.files, 'one file per template')
    local images = {}
    for _, sv in pairs(s.services_map) do if sv.image then images[sv.name] = sv.image end end
    eq('shop', images['r1-shop'], 'the image comes from values.yaml, as Helm rendered it (basename, tag dropped)')
    eq(1, s.soft.selects, 'Service r1-shop selects the Deployment\'s pods (labels rendered from values)')
    eq({ 'Deployment/r1-shop spec.template.spec.containers[].envFrom[].secretRef names Secret/r1-creds, absent from shop' }, s.soft.dangling,
        'the Secret the chart never ships is the silent-success finding, named with the RENDERED name')
    ok(#data.edges >= 1)
end)

test('helm: --set overrides values; a selector the values break matches nothing and is SAID', function ()
    if not ready() then skip 'no helm binary (or no yaml parser)' end
    local s = H.attach(chart(CHART), { release = 'r2', set = { 'backendLabel=typo' } })
    eq(0, s.soft.selects)
    eq({ 'Service/r2-shop spec.selector{} selects no pod in shop' }, s.soft.empty)
end)

test('helm: what cannot be rendered is REFUSED BY NAME — not a chart; an unvendored dependency; a template error', function ()
    if not ready() then skip 'no helm binary (or no yaml parser)' end
    local r, why = H.render(chart({ ['x.yaml'] = 'a: 1\n' }))
    eq(nil, r); ok(why:find('not a chart', 1, true), why)
    local dep = vim.deepcopy(CHART)
    dep['Chart.yaml'] = dep['Chart.yaml'] .. 'dependencies:\n- name: redis\n  version: 1.0.0\n  repository: https://example.invalid/charts\n'
    r, why = H.render(chart(dep))
    eq(nil, r); ok(why:find('not vendored in charts/', 1, true), why)
    local bad = vim.deepcopy(CHART)
    bad['templates/broken.yaml'] = 'kind: {{ .Values.nope.deeper }}\n'
    r, why = H.render(chart(bad))
    eq(nil, r); ok(why:find('helm template failed', 1, true), why)
end)

test('helm: the MCP verb `helm_chart` answers through agent.answer — findings as rows, the render and the soft edges as notes', function ()
    if not ready() then skip 'no helm binary (or no yaml parser)' end
    local agent = require 'cartograph.agent'
    local d, status = agent.answer(require 'cartograph.store', 'helm_chart', { chart = chart(CHART), release = 'r3' })
    eq('ok', status)
    local found = {}
    for _, row in ipairs(d.result) do found[row.finding] = (found[row.finding] or 0) + 1 end
    eq(1, found['dangling-reference'], 'the Secret the chart never ships')
    local kinds = {}
    for _, n in ipairs(d.notes or {}) do kinds[n.kind] = true end
    ok(kinds.rendered and kinds['soft-edges'], 'the render and the soft-edge counts ride as notes')
    local _, st2 = agent.answer(require 'cartograph.store', 'helm_chart', { chart = vim.fn.tempname() })
    eq('refusal', st2, 'a path that is no chart is refused by name')
end)
