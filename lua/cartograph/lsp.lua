-- The LSP READ surface: ONE pure handler table, transport-free. A handler is
-- fn(store, params) -> LSP-shaped result — position math and the honesty
-- contract in one place, unit-testable without any transport
-- ([[cartograph-lsp-surface]]). T1 (in-process vim.lsp.start with cmd as a
-- function) wraps this table; T2 (stdio host) and T3 (MCP/HTTP) will reuse the
-- SAME handlers behind their own framing.
--
-- Everything reads through the Band (store.topo()) — topology from the fold,
-- identity/detail (named/nodes_of/calls_of/tier) from the wide index the Band
-- carries. The surface is READ-only; writes belong to the txn/apply family.
--
-- The honesty contract (the differentiator — no other server explains what it
-- does NOT know):
--   definition: resolved -> one Location; a navigable refusal (candidates) ->
--     the candidate Location[]; a frontier refusal / unresolved -> EMPTY, never
--     a fabricated tail-guess. The WHY lives on hover.
--   hover: name/kind + the resolution TIER (the full ladder) and, for the
--     unresolved, the refusal rule + candidate count.

local atr = require 'cartograph.at'

local M = {}

-- LSP SymbolKind (subset we mint). Nodes without a navigable file are omitted.
local SYMBOLKIND = {
    module = 2, ['function'] = 12, method = 6, var = 13, region = 3,
}

-- ── position / range helpers (utf-8 offsets: store chars ARE byte offsets, and
-- T1 declares positionEncoding utf-8, so no conversion here — T2 owns utf-16) ──
local function lsp_range(r)
    return {
        start = { line = atr.sl(r), character = atr.sc(r) },
        ['end'] = { line = atr.el(r), character = atr.ec(r) },
    }
end

-- half-open containment: [start, end) so the char just past a token is "not in"
local function contains(r, line, char)
    if not r then return false end
    local sl, sc, el, ec = atr.sl(r), atr.sc(r), atr.el(r), atr.ec(r)
    if line < sl or line > el then return false end
    if line == sl and char < sc then return false end
    if line == el and char >= ec then return false end
    return true
end

local function range_size(r)
    return (atr.el(r) - atr.sl(r)) * 100000 + (atr.ec(r) - atr.sc(r))
end

-- a node is navigable iff it has a real on-disk range; minted externals
-- (stdlib, file = 'zig-std') are honestly non-navigable (definition-to-stub is
-- a ladder item, not MVP) — hover still NAMES them.
local function navigable(n)
    return n ~= nil and n.file ~= nil and not n.external and n.range ~= nil
end

local function uri_of(store, file) return vim.uri_from_fname(store.abs(file)) end

-- LSP (uri) -> the store's file key (relative to root). Single-root MVP; a
-- multi-root corpus (roots map) is a later item, so fall back to the raw path.
local function file_key(store, uri)
    local p = vim.uri_to_fname(uri)
    local root = store.data and store.data.root
    if root and p:sub(1, #root + 1) == root .. '/' then return p:sub(#root + 2) end
    return p
end

local function location(store, id)
    local n = store.node(id)
    if not navigable(n) then return nil end
    return { uri = uri_of(store, n.file), range = lsp_range(n.range) }
end

-- ── position -> fact ──────────────────────────────────────────────────────
-- the call whose call-site span covers (line,char) — the cursor sits on a
-- REFERENCE (a usage). Scans the file's calls (Band FILE axis).
local function call_at(store, file, line, char)
    for _, c in ipairs(store.topo():calls_of(file)) do
        if contains(c.at, line, char) then return c end
    end
end

-- the innermost node whose range covers (line,char) — the cursor sits on / in
-- a DEFINITION. (node ranges are whole-def spans; innermost wins so a nested
-- fn beats its parent.) The def-site fallback when the cursor isn't on a call.
local function node_at(store, file, line, char)
    local best
    for _, id in ipairs(store.topo():nodes_of(file)) do
        local n = store.node(id)
        if n and contains(n.range, line, char) then
            if not best or range_size(n.range) < range_size(best.range) then best = n end
        end
    end
    return best
end

-- ── handlers ──────────────────────────────────────────────────────────────
M.handlers = {}

M.handlers['initialize'] = function ()
    return {
        capabilities = {
            positionEncoding = 'utf-8',
            definitionProvider = true,
            referencesProvider = true,
            documentSymbolProvider = true,
            hoverProvider = true,
            workspaceSymbolProvider = true,
        },
        serverInfo = { name = 'cartograph' },
    }
end
M.handlers['shutdown'] = function () return vim.NIL end

M.handlers['textDocument/definition'] = function (store, params)
    local file = file_key(store, params.textDocument.uri)
    local p = params.position
    local c = call_at(store, file, p.line, p.character)
    if c then
        if c.to then -- resolved (incl. hedged: one Location, the hedge shows on hover)
            local loc = location(store, c.to)
            return loc and { loc } or {}
        end
        if c.refused and c.refused.cands then -- a navigable fork: the candidate set
            local out = {}
            for _, cid in ipairs(c.refused.cands) do
                local loc = location(store, cid)
                if loc then out[#out + 1] = loc end
            end
            return out
        end
        return {} -- frontier / unresolved: never fabricate; the why is on hover
    end
    local n = node_at(store, file, p.line, p.character) -- cursor on a def itself
    if n then local loc = location(store, n.id); return loc and { loc } or {} end
    return {}
end

M.handlers['textDocument/references'] = function (store, params)
    local file = file_key(store, params.textDocument.uri)
    local p = params.position
    -- the target = what the cursor's call resolves to, else the def under it
    local c = call_at(store, file, p.line, p.character)
    local target = (c and c.to) or (function ()
        local n = node_at(store, file, p.line, p.character); return n and n.id
    end)()
    if not target then return {} end
    local band = store.topo()
    local out = {}
    -- call references: each caller's occurrence spans live in the caller's file
    for _, caller in ipairs(band:callers(target)) do
        local cn = store.node(caller)
        if cn and cn.file then
            for _, r in ipairs(store.occurrences(caller, target) or {}) do
                out[#out + 1] = { uri = uri_of(store, cn.file), range = lsp_range(r) }
            end
        end
    end
    -- variable references (target is a var): the use records carry the spans
    for _, u in ipairs(band:var_used_by_detail(target)) do
        local fn = store.node(u.from)
        if fn and fn.file then
            for _, r in ipairs(u.at or {}) do
                out[#out + 1] = { uri = uri_of(store, fn.file), range = lsp_range(r) }
            end
        end
    end
    if params.context and params.context.includeDeclaration then
        local decl = location(store, target)
        if decl then out[#out + 1] = decl end
    end
    return out
end

M.handlers['textDocument/documentSymbol'] = function (store, params)
    local file = file_key(store, params.textDocument.uri)
    local out = {}
    for _, id in ipairs(store.topo():nodes_of(file)) do
        local n = store.node(id)
        if navigable(n) and SYMBOLKIND[n.kind] then
            out[#out + 1] = {
                name = n.name or id,
                kind = SYMBOLKIND[n.kind],
                range = lsp_range(n.range),
                selectionRange = lsp_range(n.range),
            }
        end
    end
    return out
end

-- hover = THE honesty surface. Markdown: the fact, then the epistemic status.
local function md(lines) return { contents = { kind = 'markdown', value = table.concat(lines, '\n') } } end

M.handlers['textDocument/hover'] = function (store, params)
    local file = file_key(store, params.textDocument.uri)
    local p = params.position
    local c = call_at(store, file, p.line, p.character)
    if c then
        if c.to then
            local n = store.node(c.to)
            local t = store.topo():tier(c.fn, c.to) or 'matched'
            local where = navigable(n) and (n.file) or (n and n.external and 'stdlib') or '?'
            local lines = {
                ('**%s** %s'):format(n and n.name or c.callee or '?', n and n.kind or ''),
                ('tier: `%s`%s'):format(t, c.hedge and (' — ~ hedged: ' .. (c.hedge.rule or '?')) or ''),
                ('_from %s_'):format(where),
            }
            return md(lines)
        end
        if c.refused then
            local r = c.refused
            local ncand = (r.cands and #r.cands) or r.n or 0
            return md {
                ('**%s** — unresolved'):format(c.callee or '?'),
                ('refused: `%s`%s'):format(r.rule or '?',
                    ncand > 0 and (' — ' .. ncand .. ' candidate(s)') or ''),
                r.witness and ('_' .. tostring(r.witness) .. '_') or nil,
            }
        end
        return md {
            ('**%s** — external frontier'):format(c.callee or c.full or '?'),
            '_no definition in the graph (stdlib / vendor / dynamic)_',
        }
    end
    local n = node_at(store, file, p.line, p.character)
    if n then
        return md {
            ('**%s** %s'):format(n.name or n.id, n.kind or ''),
            n.exported and '_exported_' or '_local_',
        }
    end
    return vim.NIL
end

M.handlers['workspace/symbol'] = function (store, params)
    local q = (params.query or ''):lower()
    local out = {}
    for name, ids in pairs(store.by_name or {}) do
        -- exact, tail (M.foo ~ foo, C:m ~ m), or substring — clients re-filter
        local lname = name:lower()
        if q == '' or lname == q or lname:find(q, 1, true)
            or name:match('[.:]' .. q:gsub('(%W)', '%%%1') .. '$') then
            for _, id in ipairs(ids) do
                local n = store.node(id)
                if navigable(n) and SYMBOLKIND[n.kind] then
                    out[#out + 1] = {
                        name = n.name or id, kind = SYMBOLKIND[n.kind],
                        location = { uri = uri_of(store, n.file), range = lsp_range(n.range) },
                    }
                end
            end
        end
    end
    return out
end

--- Dispatch one request (the transport-agnostic entry). Returns result or nil.
function M.handle(store, method, params)
    local h = M.handlers[method]
    if not h then return nil, ('method not found: %s'):format(method) end
    return h(store, params or {})
end

-- ── T1: in-process server (nvim 0.10+ cmd-as-function) ────────────────────
-- A REAL LSP client attaches inside nvim; gd / K / gr and every LSP-consuming
-- plugin work unchanged, zero serialization, direct store access.
local function make_server(store)
    return function (_dispatchers)
        local closing = false
        return {
            request = function (method, params, callback)
                local h = M.handlers[method]
                if not h then
                    callback({ code = -32601, message = 'method not found: ' .. method }, nil)
                    return true
                end
                local ok, res = pcall(h, store, params)
                if ok then callback(nil, res)
                else callback({ code = -32603, message = tostring(res) }, nil) end
                return true
            end,
            notify = function (method) if method == 'exit' then closing = true end return true end,
            is_closing = function () return closing end,
            terminate = function () closing = true end,
        }
    end
end
M.make_server = make_server

--- Attach the in-process server to `bufnr` (default current). Serves from the
--- SAVED graph (honest-stale; refresh keeps it current on BufWritePost).
function M.attach(bufnr, store)
    store = store or require 'cartograph.store'
    if not (store.data and store.data.root) then
        return nil, 'no graph open'
    end
    return vim.lsp.start({
        name = 'cartograph',
        cmd = make_server(store),
        root_dir = store.data.root,
        offset_encoding = 'utf-8',
    }, { bufnr = bufnr or vim.api.nvim_get_current_buf() })
end

return M
