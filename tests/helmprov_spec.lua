-- cartograph.helmprov — Helm's render with its ATTRIBUTION kept (CART-0870): every rendered byte range to the template
-- node that wrote it, every `.Values` read to the node that evaluated it. The chart is written inline to a temp dir; the
-- tool is built offline from tools/helmprov — without go (or the helm checkout it builds against) every test skips by name.
local P = require 'cartograph.helmprov'
local H = require 'cartograph.helm'

local built, why_not
local function ready()
    if built == nil then built, why_not = P.binary(); built = built or false end
    if not built then skip('helmprov not built: ' .. tostring(why_not)) end
    if not pcall(vim.treesitter.get_string_parser, '', 'yaml') then skip 'no yaml parser' end
end
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
    ['values.yaml'] = 'image:\n  repo: shop\n  tag: "1.2"\nport: 8080\nextra: false\n',
    ['templates/_helpers.tpl'] = '{{- define "shop.image" -}}\n{{ .Values.image.repo }}:{{ .Values.image.tag }}\n{{- end -}}\n',
    ['templates/deployment.yaml'] = table.concat({
        'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: {{ .Release.Name }}-shop', 'spec:',
        '  template:', '    spec:', '      containers:', '      - name: shop', '        image: {{ include "shop.image" . }}',
        '        ports:', '        - containerPort: {{ .Values.port }}',
        '{{- if .Values.extra }}', '        args: [--extra]', '{{- end }}', '  minReadySeconds: {{ len .Values.image }}' }, '\n') .. '\n',
}
local function read(p) local fd = assert(io.open(p)); local s = fd:read('a'); fd:close(); return s end
local function docs(text) -- the YAML documents of a render, comments and separators dropped
    local out = {}
    for d in (text .. '\n---\n'):gmatch('(.-)\n?%-%-%-[^\n]*\n') do
        d = vim.trim((d:gsub('# Source:[^\n]*\n?', '')))
        if d ~= '' then out[#out + 1] = d end
    end
    return out
end

test('helmprov: the render IS Helm\'s — every file\'s documents equal `helm template`\'s', function ()
    ready()
    if not H.binary() then skip 'no helm binary to compare against' end
    local root = chart(CHART)
    local p = assert(P.render(root, { release = 'r1' }))
    local R = assert(H.render(root, { release = 'r1' }))
    local n = 0
    for _, rel in ipairs(R.files) do
        local f = p.files[rel]
        ok(f, 'helmprov renders ' .. rel)
        eq(docs(read(R.dir .. '/' .. rel)), docs(f.content), rel)
        n = n + 1
    end
    eq(1, n, 'one rendered file (the helper renders nothing)')
end)

test('helmprov: every TEXT span reproduces the template source at its location; an action sits just inside its {{', function ()
    ready()
    local root = chart(CHART)
    local p = assert(P.render(root, { release = 'r1' }))
    local f = p.files['shop/templates/deployment.yaml']
    ok(f and #f.spans > 0, 'spans recorded')
    local src = vim.split(read(root .. '/templates/deployment.yaml'), '\n', { plain = true })
    local text, action, prev = 0, 0, 0
    for _, sp in ipairs(f.spans) do
        ok(sp.start >= prev, 'spans in order, not overlapping')
        prev = sp['end']
        local file, line, col = P.loc(sp.loc)
        if file == 'templates/deployment.yaml' then
            local at = table.concat(src, '\n', line):sub(col + 1)
            if sp.kind == 'text' then
                eq(f.content:sub(sp.start + 1, sp['end']), at:sub(1, sp['end'] - sp.start), sp.loc)
                text = text + 1
            else
                local before = table.concat(src, '\n', line):sub(1, col)
                ok(before:match('{{%-?%s*$'), sp.loc .. ' is the pipeline just inside an action\'s {{'); action = action + 1
            end
        end
    end
    ok(text > 0 and action > 0, ('both kinds checked (%d text, %d action)'):format(text, action))
end)

test('helmprov: USES of a values path — inside an included helper, by ancestor and descendant; an unread branch is absent', function ()
    ready()
    local p = assert(P.render(chart(CHART), { release = 'r1' }))
    local function sites(path) local l = {} for _, u in ipairs(P.uses(p, path)) do l[#l + 1] = u.path .. '@' .. u.file .. ':' .. u.line end return l end
    eq({ 'image.repo@templates/_helpers.tpl:2', 'image.tag@templates/_helpers.tpl:2', 'image@templates/deployment.yaml:16' }, sites('image'),
        'the reads sit in the HELPER, where `.Values.image.*` is evaluated, not on the include line')
    eq({ 'image.tag@templates/_helpers.tpl:2', 'image@templates/deployment.yaml:16' }, sites('image.tag'),
        '`len .Values.image` reads all of image, so it is a use of image.tag')
    eq({ 'port@templates/deployment.yaml:12' }, sites('port'))
    eq({ 'extra@templates/deployment.yaml:13' }, sites('extra'), 'the condition is a read')
    eq({}, sites('nope'))
end)

test('helmprov: POSITION of a rendered byte and LOCATE of a document\'s text map back to the template', function ()
    ready()
    local p = assert(P.render(chart(CHART), { release = 'r1' }))
    local name = 'shop/templates/deployment.yaml'
    local c = p.files[name].content
    local b = c:find('containerPort', 1, true) - 1
    local file, line, col, kind = P.position(p, name, b)
    eq({ 'templates/deployment.yaml', 12, 10, 'text' }, { file, line, col, kind }, 'inside a text span: exact')
    local l = assert(P.locate(p, 'Deployment', 'r1-shop', 'shop:1.2'))
    eq('templates/deployment.yaml', l.file); eq(10, l.line); ok(l.kind ~= 'text', 'the image was written by an action')
    eq(nil, P.locate(p, 'Deployment', 'other', 'shop'))
end)

test('helmprov: PATH_AT names the values key under the cursor; CHART_OF finds the chart; USE_ITEMS are quickfix rows', function ()
    ready()
    local root = chart(CHART)
    local buf = vim.fn.bufadd(root .. '/values.yaml'); vim.fn.bufload(buf)
    eq('image.tag', P.path_at(buf, 2, 3))
    eq('port', P.path_at(buf, 3, 0))
    eq(vim.fn.fnamemodify(root, ':p'):gsub('/$', ''), P.chart_of(root .. '/templates/deployment.yaml'))
    local items, src = P.use_items(root, 'image.tag')
    eq('rendered', src)
    eq(2, #items); eq(2, items[1].lnum); ok(items[1].filename:match('_helpers%.tpl$')); eq(16, items[2].lnum)
    vim.api.nvim_buf_delete(buf, { force = true })
end)

test('helmprov: without a render the use sites fall back to the STATIC reads, said so', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'yaml') then skip 'no yaml parser' end
    local root = chart(CHART)
    local render = P.render
    P.render = function () return nil, 'stubbed' end
    local okc, items, src = pcall(P.use_items, root, 'port')
    P.render = render
    ok(okc, tostring(items))
    eq('static', src)
    eq(1, #items); eq(12, items[1].lnum)
end)

-- ALL BRANCHES (CART-0871): the values take `none` of the extra arm, skip the sidecar arm (which cannot render without
-- a sidecar: a hole) and range over an empty list
local BR = vim.deepcopy(CHART)
BR['templates/deployment.yaml'] = table.concat({
    'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: {{ .Release.Name }}-shop', 'spec:',
    '  template:', '    spec:', '      containers:', '      - name: shop', '        image: {{ include "shop.image" . }}',
    '        ports:', '        - containerPort: {{ .Values.port }}',
    '{{- if .Values.extra }}', '        args: [--extra={{ .Values.extraArg }}]', '{{- end }}',
    '  minReadySeconds: {{ len .Values.image }}',
    '{{- if .Values.sidecar }}', '  paused: {{ .Values.sidecar.paused }}', '{{- end }}',
    '  # {{ range $t := .Values.tags }}{{ $t.name }}{{ end }}',
    '  # {{ if .Values.port }}p{{ else }}{{ .Values.fallbackPort }}{{ end }}' }, '\n') .. '\n'
BR['values.yaml'] = CHART['values.yaml'] .. 'tags: []\n'

test('helmprov: BRANCHES — an untaken arm\'s reads come back marked with the guard that skipped them; the render is unchanged', function ()
    ready()
    local root = chart(BR)
    local p0 = assert(P.render(root, { release = 'r1' }))
    local p = assert(P.render(root, { release = 'r1', branches = true }))
    eq(p0.files, p.files, 'files and spans are the unexplored render\'s')
    eq({}, P.uses(p0, 'extraArg'), 'without branches the skipped arm\'s read is invisible')
    local u = P.uses(p, 'extraArg')
    eq(1, #u); eq(14, u[1].line); eq(true, u[1].untaken)
    ok(u[1].guard:match('^shop/templates/deployment%.yaml:13:%d+ if %.Values%.extra %(then%)$'), u[1].guard)
    local e = P.uses(p, 'extra')
    eq(1, #e); eq(nil, e[1].untaken, 'the condition itself is evaluated: a taken read')
end)

test('helmprov: BRANCHES — control flow as HOLE DOMAINS (presence / rep), each skipped arm\'s text kept, a failing arm a HOLE', function ()
    ready()
    local p = assert(P.render(chart(BR), { release = 'r1', branches = true }))
    local by = {}
    for _, d in ipairs(P.domains(p)) do by[d.file .. ':' .. d.line] = d end
    local x = by['templates/deployment.yaml:13']
    eq('presence', x.domain); eq({ none = 1 }, x.taken)
    eq(1, #x.untaken); eq('then', x.untaken[1].arm); eq('\n        args: [--extra=]', x.untaken[1].text); eq(nil, x.untaken[1].err)
    local r = by['templates/deployment.yaml:20']
    eq('rep', r.domain); eq({ empty = 1 }, r.taken); eq('body', r.untaken[1].arm)
    eq('', r.untaken[1].text); eq(nil, r.untaken[1].err, 'a field of NO value is Go\'s zero, not an error: the body renders empty')
    local a = by['templates/deployment.yaml:21']
    eq('alt', a.domain); eq({ ['then'] = 1 }, a.taken); eq('else', a.untaken[1].arm)
    eq({ { 'fallbackPort', 21, true } }, vim.tbl_map(function (u) return { u.path, u.line, u.untaken } end, P.uses(p, 'fallbackPort')),
        'the ELSE the values skipped is explored too')
    local h = P.holes(p)
    eq(1, #h, 'the sidecar arm: a field of a nil INSIDE an interface fails')
    ok(h[1].guard:match(':17:%d+ if %.Values%.sidecar %(then%)$'), h[1].guard)
    ok(h[1].loc:match('templates/deployment%.yaml:18:'), h[1].loc); ok(h[1].err:match('nil pointer'), h[1].err)
    eq('\n  paused: ', h[1].text, 'the hole keeps the text up to the failure')
end)

test('helmprov: a site read in a taken arm ANYWHERE is taken (a range body takes and skips the same arm across iterations)', function ()
    local prov = { reads = {
        { path = 'a', loc = 'c/templates/t.yaml:3:4', untaken = true, guard = 'c/templates/t.yaml:2:6 if .on (then)' },
        { path = 'a', loc = 'c/templates/t.yaml:3:4' },
        { path = 'a', loc = 'c/templates/t.yaml:5:4', untaken = true, guard = 'g' } } }
    eq({ { 3, nil }, { 5, true } }, vim.tbl_map(function (u) return { u.line, u.untaken } end, P.uses(prov, 'a')))
end)

test('helmprov: SYMBOLIC — no values at all: .Values a placeholder, conditions unknown, a range one element, an uncallable call a placeholder', function ()
    ready()
    local files = vim.deepcopy(BR)
    files['values.yaml'] = nil
    files['templates/svc.yaml'] = 'apiVersion: v1\nkind: Service\nmetadata:\n  name: {{ .Values.name | trunc 63 | trimSuffix "-" }}\n'
    local p = assert(P.render(chart(files), { release = 'r1', symbolic = true }))
    local c = p.files['shop/templates/deployment.yaml'].content
    for _, want in ipairs({
        'image: \u{27e8}.Values.image.repo\u{27e9}:\u{27e8}.Values.image.tag\u{27e9}', -- through the include, as the helper wrote it
        'containerPort: \u{27e8}.Values.port\u{27e9}',
        'args: [--extra=\u{27e8}.Values.extraArg\u{27e9}]', -- the then-arm of an UNKNOWN condition renders
        'minReadySeconds: \u{27e8}len .Values.image\u{27e9}', -- a builtin given a placeholder is not called
        'paused: \u{27e8}.Values.sidecar.paused\u{27e9}', -- no hole: nothing is nil any more
        '# \u{27e8}.Values.tags[].name\u{27e9}', -- the range's one element, through its variable
    }) do ok(c:find(want, 1, true), want .. '\n' .. c) end
    ok(p.files['shop/templates/svc.yaml'].content:find('name: \u{27e8}.Values.name | trunc 63 | trimSuffix "-"\u{27e9}', 1, true),
        'a placeholder in a TYPED parameter: the call is not made, the stage keeps what was piped into it\n' .. p.files['shop/templates/svc.yaml'].content)
    for _, a in ipairs(p.arms) do
        if a.kind == 'range' then eq('body', a.taken) else eq('unknown', a.taken, a.loc) end
    end
    eq({ 'tags', 'tags[].name' }, vim.tbl_map(function (u) return u.path end, P.uses(p, 'tags')),
        'the range reads the list; an element\'s field, through the loop variable, is a use of it too')
    eq({ { 'fallbackPort', true } }, vim.tbl_map(function (u) return { u.path, u.untaken } end, P.uses(p, 'fallbackPort')),
        'the else of an unknown condition is explored')
    eq({}, P.holes(p))
end)
