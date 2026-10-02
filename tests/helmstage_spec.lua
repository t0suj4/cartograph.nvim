-- cartograph.helmstage — a plain chart's STAGES discovered from the repo's own helm command line, effective values per
-- stage, every stage rendered, and the cross-stage findings (CART-1269, design helm-charts/02 §4-5). The repo is written
-- inline: stage `st` disables the service `a` calls and leaves a placeholder; `prd` overrides it, carries a password.
local HS = require 'cartograph.helmstage'

local function ready() return require('cartograph.helm').binary() ~= nil and pcall(vim.treesitter.get_string_parser, '', 'yaml') end
local function repo(files)
    local root = vim.fn.tempname()
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local function svc(name)
    return table.concat({
        '{{- if .Values.' .. name .. '.enabled }}', 'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: ' .. name, 'spec:',
        '  selector:', '    matchLabels:', '      app: ' .. name, '  template:', '    metadata:', '      labels:', '        app: ' .. name,
        '    spec:', '      containers:', '      - name: ' .. name, '        image: ' .. name,
        '        env:', '        - name: PEER_URL', '          value: {{ .Values.' .. name .. '.peer | quote }}',
        '        - name: DB_HOST', '          value: {{ .Values.global.database.host | quote }}',
        '---', 'apiVersion: v1', 'kind: Service', 'metadata:', '  name: ' .. name, 'spec:', '  selector:', '    app: ' .. name, '  ports:', '  - port: 80',
        '{{- end }}' }, '\n') .. '\n'
end
local FILES = {
    ['.gitlab-ci.yml'] = table.concat({ 'deploy:', '  script:',
        '    - helm template app ./app \\', '        -f values-shared.yaml \\', '        -f stages/${CI_ENVIRONMENT_NAME}/values.yaml > out.yaml' }, '\n') .. '\n',
    ['app/Chart.yaml'] = 'apiVersion: v2\nname: app\nversion: 0.1.0\n',
    -- (`note` is a brace-wrapped LITERAL naming no values path: not a placeholder)
    ['app/values.yaml'] = 'global:\n  database:\n    host: "{global.database.host}"\nnote: "{literal}"\na:\n  enabled: true\n  peer: http://b:80\nb:\n  enabled: true\n  peer: ""\n',
    ['app/templates/a.yaml'] = svc('a'),
    ['app/templates/b.yaml'] = svc('b'),
    ['values-shared.yaml'] = 'a:\n  enabled: true\n',
    ['stages/st/values.yaml'] = 'b:\n  enabled: false\n',
    ['stages/prd/values.yaml'] = 'global:\n  database:\n    host: db.prod.internal\n    password: hunter2\n',
}

test('helmstage: the STAGES are discovered from the CI command — a ${VAR} values path is one stage per directory', function ()
    local root = repo(FILES)
    local st, refused = HS.discover(root, { '.gitlab-ci.yml' })
    eq({}, refused)
    eq({ 'prd', 'st' }, vim.tbl_map(function (s) return s.stage end, st))
    eq({ 'values-shared.yaml', 'stages/st/values.yaml' }, st[2].values, 'the chain in command order, the family path expanded')
    eq('app', st[1].chart)
    eq('CI_ENVIRONMENT_NAME', st[1].var)
end)

test('helmstage: EFFECTIVE values per stage — the must-override placeholder, a no-op override, a secret counted not echoed', function ()
    local root = repo(FILES)
    local st = HS.discover(root, { '.gitlab-ci.yml' })
    local prd, s = HS.effective(root, st[1]), HS.effective(root, st[2])
    eq({ '$.global.database.host = {global.database.host}' }, s.placeholders, 'st never overrides it')
    eq({}, prd.placeholders, 'prd does')
    eq({ 'values-shared.yaml $.a.enabled' }, s.noops, 'the shared layer restates the chart default')
    eq(1, prd.secrets, 'a password in a plaintext values file')
    eq('<redacted>', HS.show('password', 'hunter2'))
    eq('db.prod.internal', HS.show('host', 'db.prod.internal'))
end)

test('helmstage: every stage RENDERED, and the CROSS-STAGE drift — a service and a peer present in one stage only', function ()
    if not ready() then skip 'no helm binary (or no yaml parser)' end
    local root = repo(FILES)
    local r = HS.run(root, { '.gitlab-ci.yml' })
    eq(2, #r.stages)
    ok(r.stages[1].render and r.stages[2].render, 'both stages render')
    eq({ 'app: a declares b — dangles in [st], resolves in [prd]', 'app: service b rendered in [prd], NOT in [st]' }, r.drift)
    local text = table.concat(HS.lines(r), '\n')
    ok(not text:find('hunter2', 1, true), 'the password never reaches the report')
    ok(text:find('un-overridden placeholder', 1, true))
end)

test('helmstage: a stage layer that QUOTES a chart default changes its type — not a no-op; a restated number is one', function ()
    local root = repo({
        ['app/Chart.yaml'] = 'apiVersion: v2\nname: app\nversion: 0.1.0\n',
        ['app/values.yaml'] = 'ann:\n  internal: true\nport: 80\n',
        ['st.yaml'] = 'ann:\n  internal: "true"\nport: 80.0\n',
    })
    eq({ 'st.yaml $.port' }, HS.effective(root, { chart = 'app', values = { 'st.yaml' } }).noops)
end)
