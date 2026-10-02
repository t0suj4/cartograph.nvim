-- cartograph.k8sschema — Kubernetes objects CHECKED against the field schema derived from Kubernetes' own API types
-- (CART-1308): unknown fields (with the indentation / spelling hint) and wrong types, each at its line, the object read
-- the way the API server parses it; a rendered Helm object located to the TEMPLATE line that wrote it.
local S = require 'cartograph.k8sschema'

local function ready() if not pcall(vim.treesitter.get_string_parser, '', 'yaml') then skip 'no yaml parser' end end

local DOC = table.concat({
    'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: web', '  annotations:', '    internal: true', 'spec:',
    '  replicas: "3"', '  template:', '    metadata:', '      labels:', '        app: web', '    containers:', '    - name: web', '      image: x',
    '    spec:', '      containers:', '      - name: web', '        image: x', '        imagePullPolcy: Always', '        ports:', '        - containerPort: "8080"',
    '        resources:', '          limits:', '            cpu: 1', '---', 'apiVersion: v1', 'kind: Service', 'metadata:', '  name: web', 'spec:',
    '  ports:', '  - port: 80', '    targetPort: http', '---', 'apiVersion: example.com/v1', 'kind: Widget', 'spec: {}' }, '\n') .. '\n'

test('k8sschema: unknown fields and wrong types at their lines — the indentation and spelling hints; Quantity and IntOrString accepted', function ()
    ready()
    local fs, skipped = S.check_text(DOC)
    eq({
        { 6, 'wrong-type', 'metadata.annotations.internal' },
        { 8, 'wrong-type', 'spec.replicas' },
        { 13, 'unknown-field', 'spec.template.containers' },
        { 20, 'unknown-field', 'spec.template.spec.containers[1].imagePullPolcy' },
        { 22, 'wrong-type', 'spec.template.spec.containers[1].ports[1].containerPort' },
    }, vim.tbl_map(function (f) return { f.line, f.problem, f.path } end, fs), 'cpu: 1 (a Quantity) and targetPort: http (IntOrString) pass')
    ok(fs[3].hint:find('belongs under `spec`', 1, true), fs[3].hint)
    ok(fs[4].hint:find('imagePullPolicy', 1, true), fs[4].hint)
    ok(S.text(fs[1]):find('bool true where string goes', 1, true), S.text(fs[1]))
    eq({ 'Widget: kind Widget is not in the schema (a custom resource?)' }, skipped)
end)

test('k8sschema: a kustomize patch\'s $-directives are not fields (strategic merge patch); the rest of the patch is still judged', function ()
    ready()
    local fs = S.check_text('apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: x\n$patch: delete\nspec:\n  replicaz: 2\n')
    eq({ 'spec.replicaz' }, vim.tbl_map(function (f) return f.path end, fs))
end)

test('k8sschema: a RENDERED Helm object\'s finding is located to the TEMPLATE line that wrote it (the classic missing | quote)', function ()
    ready()
    local P = require 'cartograph.helmprov'
    local bin, why = P.binary()
    if not bin then skip('helmprov not built: ' .. tostring(why)) end
    local root = vim.fn.tempname()
    local files = {
        ['Chart.yaml'] = 'apiVersion: v2\nname: shop\nversion: 0.1.0\nappVersion: "3.9"\n',
        ['templates/pod.yaml'] = 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: shop\n  labels:\n    app.kubernetes.io/version: {{ .Chart.AppVersion }}\nspec:\n  containers:\n  - name: shop\n    image: shop\n',
    }
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    local fs = S.check_render(assert(P.render(root)))
    eq(1, #fs)
    eq({ 'templates/pod.yaml', 6, 'wrong-type' }, { fs[1].file, fs[1].line, fs[1].problem })
    ok(S.text(fs[1]):find('number 3.9 where string goes', 1, true), S.text(fs[1]))
end)
