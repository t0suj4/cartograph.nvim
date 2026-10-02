-- cartograph.helmgraph — a chart's values IN THE GRAPH (CART-1313): keys are vars, template reads are sited uses, and
-- the cockpit's existing var view answers "where is this value used".
local G = require 'cartograph.helmgraph'
local store = require 'cartograph.store'

local function ready() if not pcall(vim.treesitter.get_string_parser, '', 'helm') then skip 'no helm grammar' end end
local function tree(files)
    local root = vim.fn.tempname()
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local CHART = {
    ['shop/Chart.yaml'] = 'apiVersion: v2\nname: shop\nversion: 0.1.0\n',
    ['shop/values.yaml'] = 'image:\n  repo: shop\n  tag: "1.0"\nresources: {}\nports:\n- 80\n- 443\n',
    ['shop/templates/_helpers.tpl'] = '{{- define "shop.image" -}}\n{{ .Values.image.repo }}:{{ .Values.image.tag }}\n{{- end -}}\n',
    ['shop/templates/deploy.yaml'] = table.concat({
        'kind: Deployment', 'spec:', '  image: {{ include "shop.image" . }}', '  tag: {{ .Values.image.tag }}',
        '  limits: {{ .Values.resources.limits }}', '  nope: {{ .Values.missing.key }}',
        '{{- with .Values.image }}', '  repo: {{ .repo }}', '{{- end }}', '  ports: {{ .Values.ports }}' }, '\n') .. '\n',
}

test('helmgraph: every values key a VAR at its line; every template read a USE sited at the read; undefined and relative reads counted', function ()
    ready()
    local data = { root = tree(CHART), nodes = {}, edges = {} }
    local s = G.attach(data)
    local keys = {}
    for _, n in ipairs(data.nodes) do if n.hv == 'key' then keys[#keys + 1] = n.name .. '@' .. (n.range.start.line + 1) end end
    table.sort(keys)
    eq({ 'image.repo@2', 'image.tag@3', 'image@1', 'ports@5', 'resources@4' }, keys, 'a list is one key: Helm reads it whole')
    local uses = {}
    for _, e in ipairs(data.edges) do
        if e.hv == 'reads' then
            local lines = vim.tbl_map(function (a) return a.start.line + 1 end, e.at)
            uses[#uses + 1] = e.from:match('[^/]+$') .. ' -> ' .. e.to:match('::(.*)$') .. ' ' .. table.concat(lines, ',')
        end
    end
    table.sort(uses)
    eq({
        '_helpers.tpl -> image.repo 2', '_helpers.tpl -> image.tag 2',
        'deploy.yaml -> image 7',          -- (the `with` condition reads image whole)
        'deploy.yaml -> image.tag 4',
        'deploy.yaml -> ports 10',
        'deploy.yaml -> resources 5',      -- (resources.limits reads INTO the key values.yaml defines)
    }, uses)
    eq(1, s.undefined, '.Values.missing.key: nothing values.yaml defines')
    eq(0, s.relative, '`.repo` inside with is not a .Values read to the STATIC reader at all (the symbolic render attributes it, CART-1302)')
    local V = require 'cartograph.validate'
    eq('schema: OK', (V.report(V.check(data)) or ''):match('^schema: OK'))
end)

test('helmgraph: the cockpit\'s VAR view of a values key lists the templates that read it', function ()
    ready()
    local data = { root = tree(CHART), nodes = {}, edges = {} }
    G.attach(data)
    data.schema = 1
    store.ingest(data)
    local readers = vim.tbl_map(function (u) return u.from:match('[^/]+$') .. ':' .. #u.at end, store.topo():var_used_by_detail('shop/values.yaml::image.tag'))
    table.sort(readers)
    eq({ '_helpers.tpl:1', 'deploy.yaml:1' }, readers)
end)
