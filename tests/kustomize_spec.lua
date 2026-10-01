-- cartograph.kustomize — overlays BUILT by kustomize itself (kubectl kustomize) and read as releases (CART-1300); a
-- component resolves inside the overlay that composes it. The repo is written inline; without kubectl/kustomize the
-- build tests skip by name.
local KZ = require 'cartograph.kustomize'
local K = require 'cartograph.k8s'

local function ready() return KZ.binary() ~= nil and pcall(vim.treesitter.get_string_parser, '', 'yaml') end
local function repo(files)
    local root = vim.fn.tempname()
    local list = {}
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
        list[#list + 1] = rel
    end
    table.sort(list)
    return root, list
end
local function lines(t) return table.concat(t, '\n') .. '\n' end
local FILES = {
    ['base/kustomization.yaml'] = lines({ 'apiVersion: kustomize.config.k8s.io/v1beta1', 'kind: Kustomization', 'resources:', '- web.yaml' }),
    ['base/web.yaml'] = lines({ 'apiVersion: apps/v1', 'kind: Deployment', 'metadata:', '  name: web', 'spec:', '  selector:', '    matchLabels:', '      app: web',
        '  template:', '    metadata:', '      labels:', '        app: web', '    spec:', '      containers:', '      - name: web', '        image: web' }),
    ['components/netpol/kustomization.yaml'] = lines({ 'apiVersion: kustomize.config.k8s.io/v1alpha1', 'kind: Component', 'resources:', '- np.yaml' }),
    ['components/netpol/np.yaml'] = lines({ 'apiVersion: networking.k8s.io/v1', 'kind: NetworkPolicy', 'metadata:', '  name: web', 'spec:', '  podSelector:', '    matchLabels:', '      app: web',
        '---', 'apiVersion: networking.k8s.io/v1', 'kind: NetworkPolicy', 'metadata:', '  name: cache', 'spec:', '  podSelector:', '    matchLabels:', '      app: cache' }),
    ['overlay/kustomization.yaml'] = lines({ 'apiVersion: kustomize.config.k8s.io/v1beta1', 'kind: Kustomization', 'resources:', '- ../base', 'components:', '- ../components/netpol' }),
}

test('kustomize: OVERLAYS are the Kustomizations, never the Components', function ()
    local root, list = repo(FILES)
    eq({ 'base', 'overlay' }, KZ.overlays(root, list))
    eq('Component', KZ.kind(root .. '/components/netpol'))
end)

test('kustomize: an overlay BUILT by kustomize composes its component — the policy for web resolves, the one for a pod no base ships is said', function ()
    if not ready() then skip 'no kubectl/kustomize (or no yaml parser)' end
    local root, list = repo(FILES)
    local s = KZ.attach(root, list)
    eq(2, s.kustomize.rendered)
    eq({}, s.kustomize.refused)
    eq({ 'NetworkPolicy/cache spec.podSelector selects no pod in overlay' }, s.soft.empty, 'the component\'s cache policy: no cache workload anywhere')
    eq(0, s.soft.composed, 'read through the overlay, nothing is left composed')
end)

test('kustomize: a REMOTE resource is refused by name (the network is never touched)', function ()
    if not ready() then skip 'no kubectl/kustomize (or no yaml parser)' end
    local files = vim.deepcopy(FILES)
    files['remote/kustomization.yaml'] = lines({ 'apiVersion: kustomize.config.k8s.io/v1beta1', 'kind: Kustomization', 'resources:', '- https://example.invalid/x/base?ref=v1' })
    local root, list = repo(files)
    local s = KZ.attach(root, list)
    eq(1, #s.kustomize.refused)
    ok(s.kustomize.refused[1]:find('^remote: '), s.kustomize.refused[1])
end)

test('k8s: a RENDER\'s `{{` is literal content; an unrendered document carrying it is refused as a template', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'yaml') then skip 'no yaml parser' end
    local src = lines({ 'apiVersion: v1', 'kind: ConfigMap', 'metadata:', '  name: alerts', 'data:', '  rule: "{{ $labels.instance }} is down"' })
    local d1, r1 = K.read(src)
    eq(0, #d1); eq(1, r1, 'unrendered: a template')
    local d2, r2 = K.read(src, { rendered = true })
    eq(1, #d2); eq(0, r2, 'rendered: alertmanager\'s own template text, read')
end)
