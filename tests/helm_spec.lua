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
-- ── F18 (CART-1384, design corpus helm-charts/03): THE ERROR BELOW THE TOP FRAME. An include chain's first stderr line
-- is the OUTERMOST frame; the cause is at the innermost. Fixture: tests/fixtures/helm-files-get-unbuilt, vendored from
-- the corpus (three arms + two negative guards whose refusal is already right).
local FIX = vim.fn.getcwd() .. '/tests/fixtures/helm-files-get-unbuilt'
local STDERR = table.concat({
    'Error: app/templates/cronjob-connectors.yaml:2:19',
    '  executing "app/templates/cronjob-connectors.yaml" at <include (print $.Template.BasePath "/configmap-connectors.yaml") .>:',
    '    error calling include:',
    'app/templates/configmap-connectors.yaml:10:20',
    '  executing "app/templates/configmap-connectors.yaml" at <include .processor (dict "context" $context "file" $connector)>:',
    '    error calling include:',
    'app/templates/_helpers.tpl:2:102',
    '  executing "app.connector.orders" at <.context.Values.global.database.schema.value>:',
    '    invalid value; expected string',
    '',
    'Use --debug flag to render out invalid YAML', '' }, '\n')

test('helm: a failed render is read WHOLE — every include frame, the innermost one and its own message', function ()
    local F = H.failure(STDERR)
    eq({ 'app/templates/cronjob-connectors.yaml:2:19', 'app/templates/configmap-connectors.yaml:10:20', 'app/templates/_helpers.tpl:2:102' }, F.frames)
    eq('app/templates/_helpers.tpl:2:102', F.innermost)
    eq('invalid value; expected string', F.message)
    eq(3, F.depth)
    -- a single-frame `required` error: the frame is inside `execution error at (…)`, the message after it
    local R = H.failure('Error: execution error at (app/templates/configmap.yaml:6:11): global.database.host is required\n')
    eq(1, R.depth); eq('app/templates/configmap.yaml:6:11', R.innermost); eq('global.database.host is required', R.message)
end)

local function verb(arm, chart_rel)
    local store = { data = { root = FIX .. '/' .. arm } }
    return require('cartograph.agent').answer(store, 'helm_chart', { chart = chart_rel })
end

test('helm: F18 — a chart reading a file that is not there names the innermost frame, the Files.Get, the file; the producer only where the root holds it', function ()
    if not ready() then skip 'no helm binary (or no yaml parser)' end
    -- chart-only: rooted at the chart, nothing produces the file — cite none, and no DEPENDENCY remedy (none declared)
    local d, st = verb('chart-only', '.')
    eq('refusal', st)
    local r = d.refusal
    eq('unrenderable', r.rule, 'still unrenderable: an unbuilt dependency is unreachable, not a new kind')
    ok(r.reason:find('_helpers.tpl:2:102', 1, true) and r.reason:find('expected string', 1, true), 'the innermost frame: ' .. r.reason)
    ok(r.reason:find('Files.Get at templates/configmap-connectors.yaml:9', 1, true), 'the Files.Get call, cited: ' .. r.reason)
    ok(r.reason:find('files/connector-orders.json', 1, true), 'the missing file, named')
    ok(not r.reason:find('app.connector.orders', 1, true), 'a values string under a key Files.Get does not read is no file: ' .. r.reason)
    ok(not r.remedy:find('dependenc'), 'Chart.yaml declares no dependency: ' .. r.remedy)
    eq(0, #r.producers, 'rooted at the chart, no producer is visible and none is guessed')
    -- with-producer: the project root holds pom.xml's copy-config-files — named as EVIDENCE, the rule unchanged
    d = verb('with-producer', 'chart')
    r = d.refusal
    eq('unrenderable', r.rule)
    eq(1, #r.producers)
    eq('copy-config-files', r.producers[1].execution)
    eq('chart/files', r.producers[1].writes)
    eq(true, r.producers[1].names_file, 'its <includes> names connector-orders.json')
    ok(r.remedy:find('copy-config-files', 1, true), 'the remedy names the step to run: ' .. r.remedy)
    -- the SAME chart opened on its own, inside the project: the POM that writes chart/files sits ABOVE the root, so it is
    -- never read — the real chart lives under a project POM, and an upward walk would invent evidence
    d = verb('with-producer/chart', '.')
    eq(0, #d.refusal.producers, 'a POM above the graph root is not cited')
    -- built: the control renders
    local _, st3 = verb('built', 'chart')
    eq('ok', st3)
end)

test('helm: F18 GUARDS — a `required` value and an unvendored dependency keep the refusal they already had', function ()
    if not ready() then skip 'no helm binary (or no yaml parser)' end
    local d = verb('negative/missing-value', '.')
    eq('helm template failed: Error: execution error at (app/templates/configmap.yaml:6:11): global.database.host is required', d.refusal.reason)
    eq('pass the values the chart requires', d.refusal.remedy)
    eq(nil, d.refusal.producers, 'no Files.Get: no producer, no missing file')
    d = verb('negative/missing-dependency', '.')
    ok(d.refusal.reason:find('^a dependency Chart.yaml declares is not vendored in charts/'), d.refusal.reason)
    eq('vendor the chart dependencies, or pass the values the chart requires', d.refusal.remedy)
end)
