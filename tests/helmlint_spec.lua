-- cartograph.helmlint — HELM'S SILENT-SUCCESS CLASS, the design's own three findings rebuilt as an inline chart
-- (design helm-charts/README: the LDIF seed whose separator the chomp deletes, the checksum that misses .Values.groups,
-- the values typo that renders empty) with every rule's negative beside it.
local L = require 'cartograph.helmlint'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'helm') end
local function chart(files)
    local root = vim.fn.tempname()
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local function lines(t) return table.concat(t, '\n') .. '\n' end
local CHART = {
    ['Chart.yaml'] = 'apiVersion: v2\nname: ldap\nversion: 0.1.0\n',
    ['values.yaml'] = lines({ 'baseDn: dc=example,dc=org', 'users:', '- uid: ann', 'groups:', '- name: admins', 'opt:', '  x: 1', 'unused: 1' }),
    ['templates/seed.yaml'] = lines({
        '# Copyright: a license header', '',
        '{{- if .Values.users }}',
        'apiVersion: v1', 'kind: ConfigMap', 'metadata:', '  name: seed', 'data:',
        '  03-users.ldif: |',
        '  {{- range .Values.users }}',
        '    dn: uid={{ .uid }},ou=users,{{ $.Values.baseDn }}',
        '',
        '  {{- end }}',
        '  04-groups.ldif: {{ .Values.groups | toJson | quote }}',
        '{{- end }}' }),
    ['templates/deploy.yaml'] = lines({
        'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: ldap', 'spec:',
        '  selector:', '    matchLabels:', '      app: ldap', '  template:', '    metadata:',
        '      labels:', '        app: ldap',
        '      annotations:', '        checksum/seed: {{ .Values.users | toJson | sha256sum }}',
        '    spec:', '      containers:', '      - name: ldap', '        image: ldap',
        '        env:', '        - name: BASE', '          value: {{ .Values.baseDN | quote }}',
        '        - name: OPT', '          value: "{{ if .Values.opt }}{{ .Values.opt.y }}{{ end }}"',
        -- (`default` with the value as its ARGUMENT and no pipe — alpine's form — is defaulted too)
        '        - name: MODE', '          value: {{ default "ro" .Values.mode }}',
        -- (a range OUTSIDE any block scalar whose `{{- end }}` chomps a blank line: harmless, not flagged)
        '        {{- range .Values.users }}', '        - name: USER_{{ .uid }}', '          value: "1"', '', '        {{- end }}',
        '        volumeMounts:', '        - name: seed', '          mountPath: /seed',
        '      volumes:', '      - name: seed', '        configMap:', '          name: seed' }),
}

test('helmlint: DANGLING values path (a typo renders empty) — a guarded read and a default argument are not', function ()
    if not ready() then skip 'no helm grammar' end
    local r = L.lint(chart(CHART), { render = false })
    local d = {}
    for _, f in ipairs(r.findings) do if f.lint == 'dangling-values-path' then d[#d + 1] = f.msg:match('^(%S+)') end end
    eq({ '.Values.baseDN' }, d, 'the case typo of baseDn; opt.y is guarded by `if .Values.opt`; mode is default\'s argument')
end)

test('helmlint: ORPHAN value — defined, read by no template', function ()
    if not ready() then skip 'no helm grammar' end
    local r = L.lint(chart(CHART), { render = false })
    local o = {}
    for _, f in ipairs(r.findings) do if f.lint == 'orphan-value' then o[#o + 1] = f.msg:match('^(%S+)') end end
    eq({ '.Values.unused' }, o, 'users, groups, baseDn and opt are read (opt as a whole by its guard)')
end)

test('helmlint: CHOMPED SEPARATOR — the range inside the block scalar; the license-header chomp is the idiom, not a loss', function ()
    if not ready() then skip 'no helm grammar' end
    local r = L.lint(chart(CHART), { render = false })
    local c = {}
    for _, f in ipairs(r.findings) do if f.lint == 'chomped-separator' then c[#c + 1] = f.file .. ':' .. f.line end end
    eq({ 'templates/seed.yaml:13' }, c, 'the `{{- end }}` of the LDIF range — and not line 3 under the license header')
end)

test('helmlint: CHECKSUM UNDER-COVERAGE — the pod hashes users, the ConfigMap it mounts also reads groups', function ()
    if not ready() or not require('cartograph.helm').binary() then skip 'no helm grammar or binary' end
    local r = L.lint(chart(CHART))
    local c = {}
    for _, f in ipairs(r.findings) do if f.lint == 'checksum-under-coverage' then c[#c + 1] = f.msg end end
    eq(1, #c)
    ok(c[1]:find('ConfigMap/seed', 1, true) and c[1]:find('.Values.groups', 1, true) and not c[1]:find('.Values.users', 1, true), c[1])
end)

test('helmlint: a LIBRARY chart reads its includer\'s values — the value lints refuse, said', function ()
    if not ready() then skip 'no helm grammar' end
    local files = vim.deepcopy(CHART)
    files['Chart.yaml'] = 'apiVersion: v2\nname: lib\nversion: 0.1.0\ntype: Library\n'
    local r = L.lint(chart(files), { render = false })
    for _, f in ipairs(r.findings) do ok(f.lint ~= 'dangling-values-path' and f.lint ~= 'orphan-value', f.lint) end
    ok(table.concat(r.frontier, ' '):find('library chart', 1, true))
end)
