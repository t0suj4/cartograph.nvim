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

--- RENDER a chart directory -> { dir, files = { rel … }, release, chart, version } | nil, why, cause (M.failure's record
--- with kind 'template', or { kind = 'dependency' }; absent for a refusal before Helm ran)
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
        local stderr = (r and r.stderr) or 'helm did not finish'
        local err = vim.trim(stderr:gsub('\n.*', ''))
        if err:find('missing in charts/ directory', 1, true) then
            return nil, 'a dependency Chart.yaml declares is not vendored in charts/ (helm dependency build needs the network): ' .. err,
                { kind = 'dependency', first = err }
        end
        local F = M.failure(stderr)
        local why = 'helm template failed: ' .. err
        -- (an INCLUDE CHAIN: the first line is the outermost frame, the cause is at the innermost one — CART-1384)
        if F.depth > 1 then why = why .. ('; innermost %s: %s (%d frames)'):format(F.innermost, F.message or '?', F.depth) end
        F.kind = 'template'
        return nil, why, F
    end
    local files = {}
    for _, p in ipairs(vim.fn.globpath(out, '**/*.yaml', false, true)) do files[#files + 1] = p:sub(#out + 2) end
    table.sort(files)
    return { dir = out, files = files, release = opts.release or 'release', chart = chart, version = M.version() }
end

--- Helm's stderr on a failed render, read whole -> { frames = { 'file:line:col' … } outermost first, innermost, message
--- (the innermost frame's own error), depth, first (stderr's first line) }. An include chain prints one frame per
--- template, each `executing … error calling include:`, and only the LAST names the cause (CART-1384: the first line
--- alone pointed at a checksum include three frames above a `replace` on a nil).
function M.failure(stderr)
    local F = { frames = {}, depth = 0, first = vim.trim((stderr or ''):gsub('\n.*', '')) }
    local last
    for line in ((stderr or '') .. '\n'):gmatch('([^\n]*)\n') do
        local t = vim.trim(line)
        local fr = t:match('^Error: (%S+:%d+:%d+)$') or t:match('^(%S+:%d+:%d+)$')
        local ex, msg = t:match('execution error at %((%S+:%d+:%d+)%): (.+)$')
        if fr then F.frames[#F.frames + 1] = fr
        elseif ex then F.frames[#F.frames + 1] = ex; last = msg
        elseif t:find('^Use %-%-debug') then break
        elseif t ~= '' and not t:find('^executing ') and t ~= 'error calling include:' and not t:find('^Error: ') then last = t end
    end
    F.depth = #F.frames
    F.innermost = F.frames[#F.frames]
    F.message = last
    return F
end

--- does the chart read a file that is NOT THERE? A template's `.Files.Get` returns "" for a missing file and the error
--- surfaces frames later, so this collects TWO FACTS, each cited: the templates' Files.Get / Files.Glob calls (file,
--- line) and the relative paths the chart could ask for — a literal `Files.Get "x"` argument, or a string in the
--- effective values (values.yaml, then opts.values files, then opts.set) — that do not exist under the chart.
--- -> { calls = { { file, line } }, missing = { { path, from = 'literal' | 'values', where } } }. A caller claims the
--- cause only when BOTH are non-empty.
function M.files_get(chart, opts)
    opts = opts or {}
    chart = vim.fn.fnamemodify(chart, ':p'):gsub('/$', '')
    local out, seen = { calls = {}, missing = {} }, {}
    local keys, anykey = {}, false
    local function want(path, from, where)
        if seen[path] or path:find('^/') or path:find('://', 1, true) or path:find('%s') then return end
        if not (path:find('/', 1, true) or path:find('%.%w+$')) then return end
        if vim.uv.fs_stat(chart .. '/' .. path) then return end
        seen[path] = true
        out.missing[#out.missing + 1] = { path = path, from = from, where = where }
    end
    for _, p in ipairs(vim.fn.globpath(chart .. '/templates', '**/*', false, true)) do
        local fd = vim.fn.isdirectory(p) == 0 and io.open(p)
        if fd then
            local n = 0
            for line in fd:lines() do
                n = n + 1
                if line:find('Files%.Get') or line:find('Files%.Glob') then
                    local rel = p:sub(#chart + 2)
                    out.calls[#out.calls + 1] = { file = rel, line = n }
                    for lit in line:gmatch('Files%.Get%s+"([^"]+)"') do want(lit, 'literal', rel .. ':' .. n) end
                    -- the FIELD the argument reads (`Files.Get .path`, `Files.Get .Values.files.x`): only values strings
                    -- under that key can be what it asks for; any other argument (a variable, a printf) reads anything
                    for i, arg in ipairs(vim.split(line, 'Files%.Get', { trimempty = false })) do
                        if i > 1 then -- (the text BEFORE the first call is no argument)
                            local a = arg:match('^%s+%(?%s*([%$%.%w_]+)') or arg:match('^%s+%(?%s*(%S+)')
                            local key = a and not a:find('^"') and a:match('^%$?%.[%w_.]*%.([%w_]+)$') or (a and a:match('^%$?%.([%w_]+)$'))
                            if key then keys[key] = true elseif a and not a:find('^"') then anykey = true end
                        end
                    end
                end
            end
            fd:close()
        end
    end
    if #out.calls == 0 then return out end
    local Y = require 'cartograph.yamlvalue'
    local function strings(v, path, where)
        local key = path:match('([%w_]+)$') or path:match('([%w_]+)%[%d+%]$')
        if type(v) == 'string' then
            if (key and keys[key]) or (anykey and v:find('/', 1, true)) then want(v, 'values', where .. ' ' .. path) end
        elseif type(v) == 'table' and v.o then for _, k in ipairs(v.keys or {}) do strings(v.o[k], path .. '.' .. k, where) end
        elseif type(v) == 'table' and v.a then for i, x in ipairs(v.a) do strings(x, path .. '[' .. i .. ']', where) end end
    end
    local files = { chart .. '/values.yaml' }
    for _, f in ipairs(opts.values or {}) do files[#files + 1] = f end
    for _, f in ipairs(files) do
        local fd = io.open(f)
        if fd then
            local v = Y.read_one(fd:read('a')); fd:close()
            if v then strings(v, '', vim.fn.fnamemodify(f, ':t')) end
        end
    end
    for _, s in ipairs(opts.set or {}) do
        local k, v = s:match('^([^=]+)=(.*)$')
        local key = k and k:match('([%w_]+)$')
        if k and ((key and keys[key]) or (anykey and v:find('/', 1, true))) then want(v, 'values', '--set ' .. k) end
    end
    return out
end

--- render, then READ the render with cartograph.k8s -> stats (k8s.attach's, with .helm = { chart, release, version,
--- files }), data | nil, why, cause (render's: kind 'dependency' | 'template', with the frames)
function M.attach(chart, opts)
    local R, why, cause = M.render(chart, opts)
    if not R then return nil, why, cause end
    local data = { root = R.dir, nodes = {}, edges = {} }
    local s = require('cartograph.k8s').attach(data, { files = R.files, rendered = true, schema = opts and opts.schema })
    s.helm = { chart = R.chart, release = R.release, version = R.version, files = #R.files, dir = R.dir }
    return s, data
end

return M
