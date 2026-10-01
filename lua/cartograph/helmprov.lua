-- cartograph.helmprov — HELM'S RENDER WITH ITS ATTRIBUTION KEPT (CART-0870): tools/helmprov is Helm's own engine over a
-- copy of text/template that records what the executor already knows — every rendered byte range to the template node
-- (file:line:col) that wrote it, every `.Values` chain to the node that evaluated it (inside included helpers too). The
-- renders are Helm's (verified per file against `helm template`, as documents); the attribution is exact (every text
-- span reproduces the template source at its location). Built OFFLINE on first use (tools/helmprov/build.sh).
-- USER, 2026-09-11: "quickly navigate into value use sites, so I can extend the helm chart there or here".
local M = {}

local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local SRC = REPO .. '/tools/helmprov'

--- the helmprov binary, built (offline) when missing or older than its sources -> path | nil, why
function M.binary()
    local out = vim.fn.stdpath('cache') .. '/cartograph/helmprov/helmprov'
    local newest = 0
    for _, f in ipairs(vim.fn.globpath(SRC, '**/*', false, true)) do
        if vim.fn.isdirectory(f) == 0 then newest = math.max(newest, vim.fn.getftime(f)) end
    end
    if vim.fn.executable(out) == 1 and vim.fn.getftime(out) >= newest then return out end
    if vim.fn.executable('go') == 0 then return nil, 'no go toolchain on PATH: helmprov is built from tools/helmprov' end
    local r = vim.system({ 'sh', SRC .. '/build.sh' }, { text = true, env = { OUT = out } }):wait(600000)
    if not r or r.code ~= 0 then
        return nil, 'helmprov did not build (offline: the helm checkout and its modules must be local): ' .. vim.trim(((r and r.stderr) or ''):sub(1, 300))
    end
    return out
end

--- RENDER with provenance -> { files = { [name] = { content, spans = { { start, end, loc, kind, values } } } },
--- reads = { { path, loc } }, chart } | nil, why. opts: release, namespace, values = { file … }, set = { 'k=v' … }
function M.render(chart, opts)
    opts = opts or {}
    local bin, why = M.binary()
    if not bin then return nil, why end
    chart = vim.fn.fnamemodify(chart, ':p'):gsub('/$', '')
    local cmd = { bin, '-release', opts.release or 'release', '-namespace', opts.namespace or 'default' }
    for _, f in ipairs(opts.values or {}) do cmd[#cmd + 1] = '-f'; cmd[#cmd + 1] = f end
    for _, s in ipairs(opts.set or {}) do cmd[#cmd + 1] = '-set'; cmd[#cmd + 1] = s end
    cmd[#cmd + 1] = chart
    local r = vim.system(cmd, { text = true }):wait(opts.timeout or 120000)
    if not r or r.code ~= 0 then return nil, 'helmprov: ' .. vim.trim(((r and r.stderr) or 'did not finish'):gsub('\n.*', '')) end
    local ok, d = pcall(vim.json.decode, r.stdout, { luanil = { object = true, array = true } })
    if not ok then return nil, 'helmprov: undecodable output' end
    d.chart = chart
    return d
end

--- a location `name/templates/x.yaml:12:4` -> the chart-relative file `templates/x.yaml`, line (1-based), col (0-based)
function M.loc(l)
    local path, line, col = l:match('^(.*):(%d+):(%d+)$')
    if not path then return nil end
    return path:match('^[^/]+/(.*)$') or path, tonumber(line), tonumber(col)
end

--- the USE SITES of a values path: every read of it, of a descendant, or of an ancestor (`toYaml .Values.x` reads all
--- of x) -> { { path, loc, file, line, col } } sorted by location
function M.uses(prov, path)
    local out, seen = {}, {}
    for _, r in ipairs(prov.reads or {}) do
        local p = r.path
        if p == path or p:sub(1, #path + 1) == path .. '.' or path:sub(1, #p + 1) == p .. '.' then
            local key = p .. '\0' .. r.loc
            if not seen[key] then
                seen[key] = true
                local f, line, col = M.loc(r.loc)
                out[#out + 1] = { path = p, loc = r.loc, file = f, line = line, col = col }
            end
        end
    end
    table.sort(out, function (a, b) return a.loc < b.loc end)
    return out
end

--- the span that wrote byte `b` (0-based) of rendered file `name` -> span | nil
function M.at(prov, name, b)
    local f = prov.files and prov.files[name]
    for _, sp in ipairs(f and f.spans or {}) do if b >= sp.start and b < sp['end'] then return sp end end
    return nil
end

--- the EXACT template position of rendered byte `b` of file `name` -> file, line, col (0-based), kind | nil. A text span
--- reproduces its template source byte for byte, so a byte inside it sits at the span's start advanced by the bytes
--- between (newlines move the line); an action's bytes all come from its `{{ … }}` (its location).
function M.position(prov, name, b)
    local sp = M.at(prov, name, b)
    if not sp then return nil end
    local f, line, col = M.loc(sp.loc)
    if sp.kind == 'text' then
        local seg = (prov.files[name].content or ''):sub(sp.start + 1, b)
        local nl = select(2, seg:gsub('\n', ''))
        if nl > 0 then line = line + nl; col = #seg - (seg:match('^.*()\n') or 0) else col = col + #seg end
    end
    return f, line, col, sp.kind
end

--- where a rendered document's TEXT came from: the document of `kind`/`name` in the render, and the first occurrence of
--- `text` inside it -> span, rendered file | nil (attributed by the rendered text — the document is read, its bytes known)
function M.locate(prov, kind, name, text)
    for fname, f in pairs(prov.files or {}) do
        local c = f.content or ''
        local pos = 1
        for doc in (c .. '\n---\n'):gmatch('(.-)\n%-%-%-[^\n]*\n') do
            local s = pos
            pos = pos + #doc + 5
            if doc:match('\nkind:%s*' .. vim.pesc(kind) .. '%s') or doc:match('^kind:%s*' .. vim.pesc(kind) .. '%s') then
                if doc:match('\n%s+name:%s*["\']?' .. vim.pesc(name) .. '["\']?%s') then
                    local i = doc:find(text, 1, true)
                    if i then
                        local b = s - 1 + i - 1
                        local file, line, col, kind = M.position(prov, fname, b)
                        return { file = file, line = line, col = col, kind = kind, span = M.at(prov, fname, b) }, fname
                    end
                end
            end
        end
    end
    return nil
end

--- the VALUES PATH of the key at a position of a YAML buffer (`images.tag` on the `tag:` line under `images:`) | nil — the
--- block mapping pairs enclosing the cursor, outermost first; a list item adds no segment (`.Values` chains do not index)
function M.path_at(buf, row, col)
    local ok, parser = pcall(vim.treesitter.get_parser, buf, 'yaml')
    if not ok or not parser then return nil end
    local root = parser:parse()[1]:root()
    local node = root:named_descendant_for_range(row, col, row, col)
    local segs = {}
    while node do
        if node:type() == 'block_mapping_pair' or node:type() == 'flow_pair' then
            local k = node:field('key')[1]
            if k then table.insert(segs, 1, (vim.treesitter.get_node_text(k, buf):gsub('^["\']', ''):gsub('["\']$', ''))) end
        end
        node = node:parent()
    end
    return #segs > 0 and table.concat(segs, '.') or nil
end

--- the chart a file belongs to: the nearest directory upward holding Chart.yaml | nil
function M.chart_of(file)
    local dir = vim.fn.fnamemodify(file, ':p:h')
    while dir and dir ~= '/' and dir ~= '' do
        if vim.fn.filereadable(dir .. '/Chart.yaml') == 1 then return dir end
        local up = vim.fn.fnamemodify(dir, ':h')
        if up == dir then break end
        dir = up
    end
    return nil
end

--- the USE SITES of a values path in a chart as quickfix items — rendered (helmprov: every evaluated read, helpers
--- included) when it builds, else the static reads of every template (helmlint: every branch, no helpers' indirection)
--- -> items, source ('rendered' | 'static')
function M.use_items(chart, path)
    local items = {}
    local prov = M.render(chart)
    if prov then
        for _, u in ipairs(M.uses(prov, path)) do
            items[#items + 1] = { filename = chart .. '/' .. u.file, lnum = u.line, col = u.col + 1, text = 'reads .Values.' .. u.path }
        end
        return items, 'rendered'
    end
    local L = require 'cartograph.helmlint'
    for _, f in ipairs(vim.fn.globpath(chart .. '/templates', '**/*', false, true)) do
        if vim.fn.isdirectory(f) == 0 then
            local fd = io.open(f); local src = fd and fd:read('a'); if fd then fd:close() end
            for _, r in ipairs((src and L.reads(src)) or {}) do
                local p = r.path
                if p == path or p:sub(1, #path + 1) == path .. '.' or path:sub(1, #p + 1) == p .. '.' then
                    items[#items + 1] = { filename = f, lnum = r.line, col = 1, text = 'reads .Values.' .. p .. (r.guarded and ' (guarded)' or '') }
                end
            end
        end
    end
    table.sort(items, function (a, b) return a.filename .. ('%06d'):format(a.lnum) < b.filename .. ('%06d'):format(b.lnum) end)
    return items, 'static'
end

return M
