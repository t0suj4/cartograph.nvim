-- lua-ls ORACLE: tree-sitter builds the skeleton; a headless STOCK
-- lua-language-server session upgrades the resolution. Stock lua-ls
-- has no callHierarchy, so the oracle asks textDocument/references per
-- candidate definition and INTERSECTS the answers with the skeleton's
-- known call sites. The intersection is the phantom-caller guard:
-- only positions that are call tokens can upgrade edges — field reads
-- and prose mentions cannot (the Skada lesson, structural this time).
--
-- Honesty: only defs lua-ls answered for are rebuilt; unanswered keep
-- their ~ hypotheses. A site whose position matches the references of
-- TWO answered defs is an ambiguous oracle answer — left as it was.
-- Resolution quality is lua-ls's own: annotations help it here exactly
-- as they help hover.

local M = {}

local function find_bin()
    local cands = { 'lua-language-server',
        vim.fn.expand('~/.local/lib/lua-language-server/bin/lua-language-server') }
    local cfg = require('cartograph.config').luals_bin
    if cfg then table.insert(cands, 1, cfg) end
    for _, c in ipairs(cands) do
        if vim.fn.executable(c) == 1 then return c end
    end
end

-- the name POSITION inside a definition (lua-ls wants the cursor on
-- the name's last segment)
local function name_pos(node, lines)
    local tailname = node.name:match('([%w_]+)$') or node.name
    for l = node.range.start.line, math.min(node.range.start.line + 4,
        node.range['end'].line) do
        local text = lines[l + 1] or ''
        local s = text:find('%f[%w_]' .. tailname .. '%f[^%w_]')
        if s then return { line = l, character = s - 1 } end
    end
    return { line = node.range.start.line, character = node.range.start.char }
end

--- Enrich a tree-sitter extraction in place. Returns stats or nil, reason.
---@param data table  the neutral-schema graph (mutated)
---@param opts { bin:string?, timeout:number?, load_wait:number? }?
function M.enrich(data, opts)
    opts = opts or {}
    local bin = opts.bin or find_bin()
    if not bin then return nil, 'no lua-language-server binary (config.luals_bin / PATH)' end
    local root = data.root

    -- candidates: lua defs that either carry an inferred inbound call
    -- (upgrade-or-refute) or whose tail an UNRESOLVED call names (a
    -- refusal the oracle might settle)
    local inferred_in, want_tail = {}, {}
    for _, c in ipairs(data.calls or {}) do
        if c.file:match('%.lua$') and not c.dynamic then
            if c.to and c.inferred then
                inferred_in[c.to] = true
            elseif not c.to then
                want_tail[c.callee] = true
            end
        end
    end
    local cands, lua_files = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.file:match('%.lua$') then
            lua_files[n.file] = true
            if (n.kind == 'function' or n.kind == 'method') and not n.torn
                and (inferred_in[n.id]
                    or want_tail[n.name:match('([%w_]+)$') or n.name]) then
                cands[#cands + 1] = n
            end
        end
    end
    if #cands == 0 then return nil, 'nothing for the oracle to settle' end

    -- call-site index: position -> the call whose callee token covers it
    local sites = {} -- file .. '\31' .. line -> { call, ... }
    for _, c in ipairs(data.calls or {}) do
        if c.at and c.file:match('%.lua$') then
            local k = c.file .. '\31' .. c.at.start.line
            sites[k] = sites[k] or {}
            table.insert(sites[k], c)
        end
    end

    local client_id = vim.lsp.start({
        name = 'cartograph-luals',
        cmd = { bin },
        root_dir = root,
        settings = { Lua = {
            diagnostics = { enable = false }, -- resolution only
            telemetry = { enable = false },
        } },
    }, { attach = false })
    if not client_id then return nil, 'lua-language-server failed to start' end
    local client = vim.lsp.get_client_by_id(client_id)
    vim.wait(5000, function () return client.initialized end, 50)

    local texts = {}
    for file in pairs(lua_files) do
        local fd = io.open(root .. '/' .. file, 'r')
        if fd then
            texts[file] = fd:read('a')
            fd:close()
            client:notify('textDocument/didOpen', { textDocument = {
                uri = vim.uri_from_fname(root .. '/' .. file),
                languageId = 'lua', version = 0, text = texts[file] } })
        end
    end
    -- lua-ls queues requests until the workspace is loaded; the FIRST
    -- request gets the generous timeout, the rest a normal one
    local timeout = opts.timeout or 4000
    local first_timeout = opts.load_wait or 60000

    local matched = {}  -- call -> { def ids that claimed it }
    local answered = {} -- def id -> true (references succeeded)
    local first = true
    for _, n in ipairs(cands) do
        local lines = vim.split(texts[n.file] or '', '\n', { plain = true })
        local okr, res = pcall(client.request_sync, client,
            'textDocument/references', {
                textDocument = { uri = vim.uri_from_fname(root .. '/' .. n.file) },
                position = name_pos(n, lines),
                context = { includeDeclaration = false },
            }, first and first_timeout or timeout, 0)
        first = false
        if okr and res and res.result then
            answered[n.id] = true
            for _, loc in ipairs(res.result) do
                local ffile = vim.uri_to_fname(loc.uri):sub(#root + 2)
                local line = loc.range.start.line
                local ch = loc.range.start.character
                for _, c in ipairs(sites[ffile .. '\31' .. line] or {}) do
                    if ch >= c.at.start.char and ch < c.at['end'].char then
                        matched[c] = matched[c] or {}
                        table.insert(matched[c], n.id)
                    end
                end
            end
        end
    end
    client:stop()
    if not next(answered) then return nil, 'lua-ls answered nothing' end

    -- rebuild, only where the oracle spoke:
    --  * a site claimed by exactly ONE answered def links there, solid
    --  * an inferred call into an answered def that was NOT claimed
    --    loses the guess (the hypothesis was wrong)
    --  * everything else keeps its ~ / refusal
    local upgraded, cleared = 0, 0
    for c, defs in pairs(matched) do
        if #defs == 1 then
            if c.to ~= defs[1] or c.inferred then upgraded = upgraded + 1 end
            c.to = defs[1]
            c.inferred = nil
        end
    end
    for _, c in ipairs(data.calls or {}) do
        if c.to and c.inferred and answered[c.to] and not matched[c] then
            c.to = nil
            c.inferred = nil
            cleared = cleared + 1
        end
    end
    -- ref edges into answered defs follow the corrected calls
    local kept = {}
    for _, e in ipairs(data.edges) do
        if not (e.kind == 'ref' and answered[e.to]) then kept[#kept + 1] = e end
    end
    local by_pair = {}
    for _, c in ipairs(data.calls or {}) do
        if c.to and answered[c.to] and c.fn then
            local k = c.fn .. '\31' .. c.to
            local e = by_pair[k]
            if not e then
                e = { from = c.fn, to = c.to, kind = 'ref', at = {},
                    self = (c.fn == c.to) or nil,
                    inferred = c.inferred,
                    -- the oracle spoke: this edge is PROVEN, not guessed
                    proven = not c.inferred or nil }
                by_pair[k] = e
                kept[#kept + 1] = e
            end
            if c.at then e.at[#e.at + 1] = c.at end
            if not c.inferred then e.inferred = nil end
        end
    end
    data.edges = kept
    data.capabilities = data.capabilities or {}
    data.capabilities.resolution = data.capabilities.resolution
        and (data.capabilities.resolution .. '+luals') or 'luals'
    return { asked = #cands, answered = vim.tbl_count(answered),
        upgraded = upgraded, cleared = cleared }
end

--- Async enrichment — same result as M.enrich, but never blocks (lua-ls's
--- workspace load, which made the first request wait up to a minute, is just
--- a slow async response now). Runs on the shared oracle substrate. Calls
--- on_done(stats|nil, why?) on the main loop; its job is to splice + redraw.
function M.enrich_async(data, opts, on_done)
    opts = opts or {}
    local bin = opts.bin or find_bin()
    if not bin then
        if on_done then vim.schedule(function ()
            on_done(nil, 'no lua-language-server binary (config.luals_bin / PATH)')
        end) end
        return
    end
    local root = data.root

    local inferred_in, want_tail = {}, {}
    for _, c in ipairs(data.calls or {}) do
        if c.file:match('%.lua$') and not c.dynamic then
            if c.to and c.inferred then inferred_in[c.to] = true
            elseif not c.to then want_tail[c.callee] = true end
        end
    end
    local cands, lua_files = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.file:match('%.lua$') then
            lua_files[n.file] = true
            if (n.kind == 'function' or n.kind == 'method') and not n.torn
                and (inferred_in[n.id]
                    or want_tail[n.name:match('([%w_]+)$') or n.name]) then
                cands[#cands + 1] = n
            end
        end
    end
    if #cands == 0 then
        if on_done then vim.schedule(function ()
            on_done(nil, 'nothing for the oracle to settle')
        end) end
        return
    end
    local sites = {} -- file\31line -> { call, ... } (the phantom-caller guard)
    for _, c in ipairs(data.calls or {}) do
        if c.at and c.file:match('%.lua$') then
            local k = c.file .. '\31' .. c.at.start.line
            sites[k] = sites[k] or {}
            table.insert(sites[k], c)
        end
    end
    local files = {}
    for f in pairs(lua_files) do files[#files + 1] = f end
    local matched, answered = {}, {}

    require('cartograph.oracle').run({
        name = 'cartograph-luals',
        cmd = { bin },
        root = root,
        settings = { Lua = { diagnostics = { enable = false },
            telemetry = { enable = false } } },
        files = files,
        lang_id = function () return 'lua' end,
        items = cands,
        concurrency = opts.concurrency or 32,
        -- no settle: lua-ls queues the requests until the workspace loads,
        -- then answers — async, so the wait costs nothing (the deadline caps it)
        query = function (ses, n, step)
            local lines = vim.split(ses.texts[n.file] or '', '\n', { plain = true })
            local ok = ses.client:request('textDocument/references', {
                textDocument = { uri = vim.uri_from_fname(root .. '/' .. n.file) },
                position = name_pos(n, lines),
                context = { includeDeclaration = false },
            }, function (_, result)
                if result then
                    answered[n.id] = true
                    for _, loc in ipairs(result) do
                        local ffile = vim.uri_to_fname(loc.uri):sub(#root + 2)
                        local line = loc.range.start.line
                        local ch = loc.range.start.character
                        for _, c in ipairs(sites[ffile .. '\31' .. line] or {}) do
                            if ch >= c.at.start.char and ch < c.at['end'].char then
                                matched[c] = matched[c] or {}
                                table.insert(matched[c], n.id)
                            end
                        end
                    end
                end
                step()
            end)
            if not ok then step() end
        end,
        finalize = function ()
            local upgraded, cleared = 0, 0
            for c, defs in pairs(matched) do
                if #defs == 1 then
                    if c.to ~= defs[1] or c.inferred then upgraded = upgraded + 1 end
                    c.to = defs[1]
                    c.inferred = nil
                end
            end
            for _, c in ipairs(data.calls or {}) do
                if c.to and c.inferred and answered[c.to] and not matched[c] then
                    c.to = nil
                    c.inferred = nil
                    cleared = cleared + 1
                end
            end
            local kept = {}
            for _, e in ipairs(data.edges) do
                -- preserve cross-language (xlang) refs: async runs AFTER xlang
                if not (e.kind == 'ref' and answered[e.to] and not e.xlang) then
                    kept[#kept + 1] = e
                end
            end
            local by_pair = {}
            for _, c in ipairs(data.calls or {}) do
                if c.to and answered[c.to] and c.fn then
                    local k = c.fn .. '\31' .. c.to
                    local e = by_pair[k]
                    if not e then
                        e = { from = c.fn, to = c.to, kind = 'ref', at = {},
                            self = (c.fn == c.to) or nil, inferred = c.inferred,
                            proven = not c.inferred or nil }
                        by_pair[k] = e
                        kept[#kept + 1] = e
                    end
                    if c.at then e.at[#e.at + 1] = c.at end
                    if not c.inferred then e.inferred = nil end
                end
            end
            data.edges = kept
            data.capabilities = data.capabilities or {}
            data.capabilities.resolution = data.capabilities.resolution
                and (data.capabilities.resolution .. '+luals') or 'luals'
            return { asked = #cands, answered = vim.tbl_count(answered),
                upgraded = upgraded, cleared = cleared }
        end,
        init_timeout = opts.init_timeout or 8000,
        deadline = opts.deadline or 90000, -- lua-ls workspace-load headroom
    }, on_done)
end

return M
