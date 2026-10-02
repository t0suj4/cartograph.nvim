-- cartograph.helmbase — a chart's AUTHORED base (rendered with no values) against the INFERRED base of the plain
-- manifests (their keyed generalization): spot by spot, parameter / block / HARDCODED (located) / absent, and the knobs
-- the corpus never turns (CART-0873). Built on helmprov: without go (or the helm checkout) every test skips by name.
local B = require 'cartograph.helmbase'
local P = require 'cartograph.helmprov'

local built, why_not
local function ready()
    if built == nil then built, why_not = P.binary(); built = built or false end
    if not built then skip('helmprov not built: ' .. tostring(why_not)) end
    if not pcall(vim.treesitter.get_string_parser, '', 'yaml') then skip 'no yaml parser' end
end
local function tree(files)
    local root = vim.fn.tempname()
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local function deployment(svc, port, img, cpu)
    return table.concat({ 'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: ' .. svc, 'spec:', '  replicas: 1',
        '  template:', '    spec:', '      containers:', '      - name: server', '        image: ' .. img,
        '        ports:', '        - containerPort: ' .. port, '        resources:', '          requests:', '            cpu: ' .. cpu }, '\n') .. '\n'
end
local function template(svc, port)
    return table.concat({ 'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: {{ .Values.' .. svc .. '.name }}', 'spec:',
        '  replicas: {{ .Values.replicas }}', '  template:', '    spec:', '      containers:', '      - name: server',
        '        image: shop/' .. svc .. ':{{ .Values.tag }}', '        ports:', '        - containerPort: ' .. port,
        '        resources:', '          {{- toYaml .Values.' .. svc .. '.resources | nindent 10 }}' }, '\n') .. '\n'
end

test('helmbase: spot by spot — a parameter, a BLOCK parameter, a HARDCODED port located to each template line, a knob never turned', function ()
    ready()
    local root = tree({
        ['chart/Chart.yaml'] = 'apiVersion: v2\nname: shop\nversion: 0.1.0\n',
        ['chart/templates/a.yaml'] = template('a', 8080),
        ['chart/templates/b.yaml'] = template('b', 9090),
        ['manifests/a.yaml'] = deployment('a', 8080, 'shop/a:v1', '100m'),
        ['manifests/b.yaml'] = deployment('b', 9090, 'shop/b:v1', '200m'),
        -- c sets no resources on either side: it takes no part in that spot (not "absent from the chart")
        ['chart/templates/c.yaml'] = (template('c', 7070):gsub('        resources:\n[^\n]*\n', '')),
        ['manifests/c.yaml'] = (deployment('c', 7070, 'shop/c:v1', '1'):gsub('        resources:\n.*$', '')),
    })
    local r = assert(B.diff(root .. '/chart', root .. '/manifests'))
    eq(3, #r.pairs)
    local by = {}
    for _, s in ipairs(r.sites) do by[s.site] = s end
    eq('param', by['$.metadata.name'].class)
    eq('param', by['$.spec.template.spec.containers[name].server.image'].class, 'a placeholder INSIDE the string is a parameter there')
    eq('block', by['$.spec.template.spec.containers[name].server.resources.requests.cpu'].class, 'toYaml of the whole resources block')
    local port = by['$.spec.template.spec.containers[name].server.ports[1].containerPort']
    eq('hardcoded', port.class)
    table.sort(port.at)
    eq({ 'templates/a.yaml:13', 'templates/b.yaml:13', 'templates/c.yaml:13' }, port.at, 'the literal, at the template line that wrote it')
    eq({ '$.spec.replicas' }, vim.tbl_map(function (k) return k.site end, vim.tbl_filter(function (k) return k.name == 'a' end, r.knobs)),
        'every manifest says 1: the chart\'s replicas knob is never turned by this corpus')
    eq(3, #B.items(root .. '/chart', r))
end)

test('helmbase: documents pair by ORDINAL within a kind (an authored name is a placeholder); a spot the chart lacks is ABSENT', function ()
    ready()
    local two = 'apiVersion: v1\nkind: Service\nmetadata:\n  name: %s\n  labels:\n    app: %s\nspec:\n  type: ClusterIP\n'
    local root = tree({
        ['chart/Chart.yaml'] = 'apiVersion: v2\nname: shop\nversion: 0.1.0\n',
        ['chart/templates/a.yaml'] = (two:format('{{ .Values.a.name }}', '{{ .Values.a.name }}')) .. '---\napiVersion: v1\nkind: Service\nmetadata:\n  name: a-external\nspec:\n  type: LoadBalancer\n',
        ['chart/templates/b.yaml'] = two:format('{{ .Values.b.name }}', '{{ .Values.b.name }}'),
        ['manifests/a.yaml'] = two:format('a', 'a') .. '---\n' .. (two:format('a-external', 'a-external'):gsub('ClusterIP', 'LoadBalancer')),
        ['manifests/b.yaml'] = two:format('b', 'b'),
    })
    local r = assert(B.diff(root .. '/chart', root .. '/manifests'))
    eq({ 'a', 'a#2', 'b' }, (function () local n = vim.tbl_map(function (p) return p.name end, r.pairs); table.sort(n); return n end)())
    local by = {}
    for _, s in ipairs(r.sites) do by[s.site] = s end
    eq('mixed', by['$.metadata.labels.app'].class)
    eq('absent', by['$.metadata.labels.app'].per['a#2'], 'the external Service carries no app label in the chart')
    eq('hardcoded', by['$.spec.type'].class)
end)
