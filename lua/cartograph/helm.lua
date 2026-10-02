-- cartograph.helm — HELM AS THE RENDER ORACLE (CART-1268). A chart's templates are Go text/template over values: the
-- manifests they declare exist only once RENDERED, and the renderer that decides what they are is Helm itself. So a
-- chart is read by asking Helm (`helm template --output-dir`) and reading what it emitted with cartograph.k8s — the
-- release root, the soft edges, the silent-success findings — never by guessing through the template syntax.
-- A chart that cannot be rendered is REFUSED BY NAME (no helm on PATH; a dependency Chart.yaml declares but charts/
-- does not hold — `helm dependency build` needs the network, which this module never touches; a template error), not
-- read as empty.
local M = {}

--- the helm binary on PATH | nil
function M.binary()
    local p = vim.fn.exepath('helm')
    return p ~= '' and p or nil
end

--- Helm's own version string (`v4.3`) | nil
function M.version()
    local h = M.binary()
    if not h then return nil end
    local r = vim.system({ h, 'version', '--template', '{{.Version}}' }, { text = true }):wait(20000)
    return r and r.code == 0 and vim.trim(r.stdout or '') or nil
end

--- RENDER a chart directory -> { dir, files = { rel … }, release, chart, version } | nil, why
--- opts: release (name, default 'release'), values = { file … }, set = { 'k=v' … }, namespace, out (directory), timeout
function M.render(chart, opts)
    opts = opts or {}
    local helm = M.binary()
    if not helm then return nil, 'no helm binary on PATH: a chart is read through its renderer (install helm)' end
    chart = vim.fn.fnamemodify(chart, ':p'):gsub('/$', '')
    if vim.fn.filereadable(chart .. '/Chart.yaml') == 0 then return nil, 'not a chart: no Chart.yaml in ' .. chart end
    local out = opts.out or vim.fn.tempname()
    vim.fn.mkdir(out, 'p')
    local cmd = { helm, 'template', opts.release or 'release', chart, '--output-dir', out }
    for _, v in ipairs(opts.values or {}) do cmd[#cmd + 1] = '--values'; cmd[#cmd + 1] = v end
    for _, s in ipairs(opts.set or {}) do cmd[#cmd + 1] = '--set'; cmd[#cmd + 1] = s end
    if opts.namespace then cmd[#cmd + 1] = '--namespace'; cmd[#cmd + 1] = opts.namespace end
    local r = vim.system(cmd, { text = true }):wait(opts.timeout or 120000)
    if not r or r.code ~= 0 then
        local err = vim.trim(((r and r.stderr) or 'helm did not finish'):gsub('\n.*', ''))
        if err:find('missing in charts/ directory', 1, true) then
            return nil, 'a dependency Chart.yaml declares is not vendored in charts/ (helm dependency build needs the network): ' .. err
        end
        return nil, 'helm template failed: ' .. err
    end
    local files = {}
    for _, p in ipairs(vim.fn.globpath(out, '**/*.yaml', false, true)) do files[#files + 1] = p:sub(#out + 2) end
    table.sort(files)
    return { dir = out, files = files, release = opts.release or 'release', chart = chart, version = M.version() }
end

--- render, then READ the render with cartograph.k8s -> stats (k8s.attach's, with .helm = { chart, release, version,
--- files }), data | nil, why
function M.attach(chart, opts)
    local R, why = M.render(chart, opts)
    if not R then return nil, why end
    local data = { root = R.dir, nodes = {}, edges = {} }
    local s = require('cartograph.k8s').attach(data, { files = R.files, rendered = true, schema = opts and opts.schema })
    s.helm = { chart = R.chart, release = R.release, version = R.version, files = #R.files, dir = R.dir }
    return s, data
end

return M
