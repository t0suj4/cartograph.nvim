-- the COCKPIT over infrastructure (CART-1314, CART-1315): a Kubernetes object's RELATIONS as doors on its region (the
-- axis registry, no Kubernetes-only pane), and a chart's values.yaml at the file altitude as the TREE of its keys.
local store = require 'cartograph.store'
local symbols = require 'cartograph.panes.symbols'
local axes = require 'cartograph.panes.axes'

local function ready() if not pcall(vim.treesitter.get_string_parser, '', 'yaml') then skip 'no yaml parser' end end
local function tree(files)
    local root = vim.fn.tempname()
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local function lines(level, id)
    symbols.buf = nil; symbols.create()
    symbols.show(level, id)
    return vim.api.nvim_buf_get_lines(symbols.buf, 0, -1, false)
end

test('cockpit: a Kubernetes OBJECT shows its relations as doors; an axis row is the other object, and descends into it', function ()
    ready()
    local text = table.concat({
        'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: web', 'spec:',
        '  selector:', '    matchLabels:', '      app: web',
        '  template:', '    metadata:', '      labels:', '        app: web', '    spec:',
        '      containers:', '      - name: web', '        image: web',
        '        envFrom:', '        - configMapRef:', '            name: web-config',
        '---', 'apiVersion: v1', 'kind: ConfigMap', 'metadata:', '  name: web-config',
        '---', 'apiVersion: v1', 'kind: Service', 'metadata:', '  name: web', 'spec:', '  selector:', '    app: web' }, '\n') .. '\n'
    local data = { root = tree({ ['all.yaml'] = text }), nodes = {}, edges = {}, schema = 1 }
    require('cartograph.k8s').attach(data)
    store.ingest(data)
    local dep = 'all.yaml::Deployment/web'
    local l = lines('region', dep)
    eq('≡ Deployment/web', l[1])
    ok(vim.tbl_contains(l, '→ references (1)'), table.concat(l, '\n'))
    ok(vim.tbl_contains(l, '◉ selected by (1)'), table.concat(l, '\n'))
    ok(vim.tbl_contains(l, '◎ selects (0)'), 'its own selector makes no edge, and the reference is not a selection: ' .. table.concat(l, '\n'))
    local a = lines('axis', axes.key('k8_references', dep))
    eq('→ references of Deployment/web (1)', a[1])
    ok(a[2]:find('ConfigMap/web', 1, true), a[2])
    eq('all.yaml::ConfigMap/web-config', symbols.line_node[2], 'the row IS the ConfigMap: l descends into its own relations')
    local cm = lines('region', 'all.yaml::ConfigMap/web-config')
    ok(vim.tbl_contains(cm, '← referenced by (1)'), table.concat(cm, '\n'))
end)

test('cockpit: a chart\'s values.yaml altitude is the TREE of its keys — read counts, ∅ for a key nothing reads, rows are the key vars', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'helm') then skip 'no helm grammar' end
    local root = tree({
        ['shop/Chart.yaml'] = 'apiVersion: v2\nname: shop\nversion: 0.1.0\n',
        ['shop/values.yaml'] = 'image:\n  repo: shop\n  tag: "1.0"\nunused: 1\n',
        ['shop/templates/d.yaml'] = 'image: {{ .Values.image.repo }}:{{ .Values.image.tag }}\nagain: {{ .Values.image.tag }}\n',
    })
    local data = { root = root, nodes = {}, edges = {}, schema = 1 }
    require('cartograph.helmgraph').attach(data)
    store.ingest(data)
    local l = lines('file', 'shop/values.yaml')
    eq({ '⚙ values.yaml', '  4 keys · 2 read · 1 ∅', '  image', '    repo (1)', '    tag (2)', '  unused ∅' }, l)
    eq('shop/values.yaml::image.tag', symbols.line_node[5], 'a row is the key\'s var: l opens who reads it')
end)
