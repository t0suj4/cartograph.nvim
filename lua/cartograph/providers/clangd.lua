-- clangd GraphProvider: tree-sitter builds the SKELETON (nodes, blocks,
-- litdata, df, the call inventory), then a headless clangd session upgrades
-- the resolution — callHierarchy/incomingCalls per function turns the
-- name-matched `~` edges into semantically PROVEN ones, wrong hypotheses
-- and all. clangd hands back each caller with its own range, so attribution
-- is its answer, not ours.
--
-- Honesty: only edges clangd answered for are rebuilt; functions it can't
-- see (no compile db coverage, macros) keep their `~` hypotheses. A
-- compile_commands.json or compile_flags.txt at the root is what gives
-- clangd cross-file eyes — without one the upgrade degrades to open-file
-- resolution and says so.

local M = {}

-- candidates, first hit wins: user config, PATH, the user-local deb tree
local function find_bin()
    local cands = { 'clangd', vim.fn.expand('~/.local/bin/clangd') }
    local cfg = require('cartograph.config').clangd_bin
    if cfg then table.insert(cands, 1, cfg) end
    for _, c in ipairs(cands) do
        if vim.fn.executable(c) == 1 then return c end
    end
end

local function lang_id(file)
    local e = file:match('%.([%w]+)$') or ''
    return (e == 'c' or e == 'h') and 'c' or 'cpp'
end

-- the name POSITION inside a definition: scan the def's first lines for the
-- name's last identifier segment (clangd wants the cursor on the name)
local function name_pos(node, lines)
    local tailname = node.name:match('([%w_]+)$') or node.name
    for l = node.range.start.line, math.min(node.range.start.line + 4,
        node.range['end'].line) do
        local text = lines[l + 1] or ''
        local init = 1
        while true do
            local s, e = text:find('%f[%w_]' .. tailname .. '%f[^%w_]', init)
            if not s then break end
            -- skip a match that is a call on the same line before the def
            return { line = l, character = s - 1 }
        end
    end
    return { line = node.range.start.line, character = node.range.start.char }
end

--- Enrich a tree-sitter extraction in place. Returns stats or nil, reason.
---@param data table  the neutral-schema graph (mutated)
---@param opts { bin:string?, timeout:number?, index_wait:number? }?
function M.enrich(data, opts)
    opts = opts or {}
    local bin = opts.bin or find_bin()
    if not bin then return nil, 'no clangd binary (config.clangd_bin / PATH)' end
    local root = data.root

    -- fn nodes per file, and a range index for attributing callers
    local by_file, fn_nodes = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            by_file[n.file] = by_file[n.file] or {}
            table.insert(by_file[n.file], n)
            fn_nodes[#fn_nodes + 1] = n
        end
    end
    if #fn_nodes == 0 then return nil, 'no functions to resolve' end
    local function node_at(file, line)
        local best
        for _, n in ipairs(by_file[file] or {}) do
            if n.range.start.line <= line and line <= n.range['end'].line
                and (not best or n.range.start.line >= best.range.start.line) then
                best = n
            end
        end
        return best
    end

    local indexing, index_done = false, false
    local client_id = vim.lsp.start({
        name = 'cartograph-clangd',
        cmd = { bin, '--background-index', '--log=error' },
        root_dir = root,
        handlers = {
            ['$/progress'] = function (_, p)
                if tostring(p.token or ''):find('backgroundIndex') then
                    indexing = true
                    if p.value and p.value.kind == 'end' then index_done = true end
                end
            end,
        },
    }, { attach = false })
    if not client_id then return nil, 'clangd failed to start' end
    local client = vim.lsp.get_client_by_id(client_id)
    vim.wait(5000, function () return client.initialized end, 50)

    -- open every workspace file so single-file setups still resolve
    local texts = {}
    for file in pairs(by_file) do
        local fd = io.open(root .. '/' .. file, 'r')
        if fd then
            texts[file] = fd:read('a')
            fd:close()
            client:notify('textDocument/didOpen', { textDocument = {
                uri = vim.uri_from_fname(root .. '/' .. file),
                languageId = lang_id(file), version = 0, text = texts[file] } })
        end
    end
    -- give the background indexer its chance — but only if one shows up:
    -- with every file open, resolution works without it
    vim.wait(3000, function () return indexing end, 100)
    if indexing then
        vim.wait(opts.index_wait or 20000, function () return index_done end, 200)
    end

    local answered, edges_added, upgraded = {}, 0, {}
    local timeout = opts.timeout or 4000
    for _, n in ipairs(fn_nodes) do
        local file = n.file
        local lines = vim.split(texts[file] or '', '\n', { plain = true })
        local uri = vim.uri_from_fname(root .. '/' .. file)
        local okp, prep = pcall(client.request_sync, client,
            'textDocument/prepareCallHierarchy',
            { textDocument = { uri = uri }, position = name_pos(n, lines) },
            timeout, 0)
        local item = okp and prep and prep.result and prep.result[1]
        if item then
            local okc, calls = pcall(client.request_sync, client,
                'callHierarchy/incomingCalls', { item = item }, timeout, 0)
            if okc and calls and calls.result then
                answered[n.id] = {}
                for _, inc in ipairs(calls.result) do
                    local ffile = vim.uri_to_fname(inc.from.uri)
                        :sub(#root + 2)
                    local from = node_at(ffile, inc.from.selectionRange.start.line)
                    if from then
                        local at = {}
                        for _, r in ipairs(inc.fromRanges or {}) do
                            at[#at + 1] = { start = { line = r.start.line,
                                    char = r.start.character },
                                ['end'] = { line = r['end'].line,
                                    char = r['end'].character } }
                        end
                        table.insert(answered[n.id], { from = from.id, at = at })
                    end
                end
            end
        end
    end

    client:stop()

    -- rebuild: PROVEN answers replace hypotheses, only where clangd spoke
    local kept = {}
    for _, e in ipairs(data.edges) do
        if not (e.kind == 'ref' and answered[e.to]) then kept[#kept + 1] = e end
    end
    for to, froms in pairs(answered) do
        local by_from = {}
        for _, f in ipairs(froms) do
            local e = by_from[f.from]
            if not e then
                e = { from = f.from, to = to, kind = 'ref', at = {},
                    self = (f.from == to) or nil }
                by_from[f.from] = e
                kept[#kept + 1] = e
                edges_added = edges_added + 1
            end
            vim.list_extend(e.at, f.at)
        end
        upgraded[#upgraded + 1] = to
    end
    data.edges = kept
    data.capabilities = data.capabilities or {}
    data.capabilities.resolution = 'clangd'
    return { resolved_fns = #upgraded, edges = edges_added,
        indexing_seen = indexing, index_done = index_done }
end

--- Full extraction: tree-sitter skeleton + clangd resolution.
function M.extract(root, opts)
    local ts = require('cartograph.providers.treesitter')
    local data = ts.extract(root)
    local stats, why = M.enrich(data, opts)
    if not stats then
        vim.notify('cartograph/clangd: resolution skipped — ' .. tostring(why)
            .. ' (graph stays name-matched)', vim.log.levels.WARN)
    end
    data.clangd = stats
    return data
end

return M
