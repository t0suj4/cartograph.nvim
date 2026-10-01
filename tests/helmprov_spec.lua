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
