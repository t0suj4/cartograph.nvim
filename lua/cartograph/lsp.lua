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
local tier = require 'cartograph.tier'
local callrec = require 'cartograph.callrec'

local M = {}

-- semanticTokens legend: ONE token type (a call), the TIER rides the modifier
-- bitmask (the honest place for trust — like 'deprecated'/'readonly'). Order =
-- the canonical ladder, so a theme colors matched/inferred/typed/… distinctly.
local SEMTOK_MODS = {}
local TIER_BIT = {}
for i, rung in ipairs(tier.LADDER) do
    SEMTOK_MODS[i] = rung.name
    TIER_BIT[rung.name] = 2 ^ (i - 1)
end

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

-- RBS/profile ENRICHMENT ([[cartograph-stdlib-profile]]): a minted external node
-- `<runtime>::Owner#member` carries no real location, but its environment profile
-- may hold a distilled signature + source location. Looked up READ-SIDE (never
-- baked into the graph → deterministic). Returns { sig, file, line, runtime,
-- version, root } or nil.
local function profile_sig(node)
    if not (node and node.external and node.id) then return nil end
    local rt, path = node.id:match('^([%w%-]+)::(.+)$')
    if not rt then return nil end
    local prof = require('cartograph.spec.profile').load(rt)
    if not prof then return nil end
    -- core sig: keyed by the full Owner#member path (owner matches RBS)
    local s = prof.sigs and prof.sigs[path]
    if s then
        return { sig = s.sig, file = s.file, line = s.line, root = prof.sig_root,
            runtime = rt, version = prof.version }
    end
    -- Rails (framework) sig: keyed by MEMBER NAME (its RBS owner is a deep internal
    -- module ≠ the node's coarse owner), with that owner shown as provenance
    local member = path:match('[#.](.+)$')
    local rs = member and prof.rails_sigs and prof.rails_sigs[member]
    if rs then
        return { sig = rs.sig, file = rs.file, line = rs.line, root = prof.rails_root,
            runtime = rt, version = prof.version, owner = rs.owner }
    end
    return nil
end

-- the profile symbol's REAL source Location, resolved AT NAV TIME (config override
-- wins, else the artifact's baked root hint; absent file → nil = honest frontier,
-- never a fabricated location). Keeps the location out of the graph.
local function rbs_location(node)
    local ps = profile_sig(node)
    if not (ps and ps.file and ps.line) then return nil end
    local root = require('cartograph.config').rbs_root or ps.root
    if not root then return nil end
    local full = root .. '/' .. ps.file
    if vim.fn.filereadable(full) ~= 1 then return nil end
    local at = { line = math.max(0, ps.line - 1), character = 0 }
    return { uri = vim.uri_from_fname(full), range = { start = at, ['end'] = at } }
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

M.handlers['initialize'] = function (store)
    -- INDEX-ONLY honesty ([[cartograph-thin-index]]): the thin index has NO call graph, so
    -- references and call-hierarchy would answer EMPTY — which a client renders as an
    -- authoritative "no references / no callers", a fabricated negative. Don't advertise
    -- them: capability negotiation is the honest place for "not served here", so `gr` /
    -- call-hierarchy report unsupported instead of a false empty. definition still serves
    -- go-to-def-on-a-def (Tier-0 faithful); a full :Cartograph open + re-attach restores all.
    local calls = not (store and store.is_index_only and store.is_index_only())
    return {
        capabilities = {
            positionEncoding = 'utf-8',
            definitionProvider = true,
            referencesProvider = calls,
            documentSymbolProvider = true,
            hoverProvider = true,
            workspaceSymbolProvider = true,
            callHierarchyProvider = calls, -- the graph IS this, and it crosses languages
            typeDefinitionProvider = true, -- the value's type node (n.ret / n.ctype)
            implementationProvider = true, -- interface -> concrete impls (data.implements)
            semanticTokensProvider = { -- TIER-COLORING: honesty made visible
                legend = { tokenTypes = { 'function' }, tokenModifiers = SEMTOK_MODS },
                full = true,
            },
            -- namespaced extensions (never mistaken for a standard method):
            -- cartograph/why (the honesty record) + cartograph/graphInfo
            experimental = { cartograph = { why = true, graphInfo = true } },
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
            if loc then return { loc } end
            -- a minted profile symbol: jump into its RBS source if a checkout is
            -- resolvable (nav-time), else an honest empty (frontier, never faked)
            local rbs = rbs_location(store.node(c.to))
            return rbs and { rbs } or {}
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
                ('**%s** %s'):format(n and n.name or callrec.callee(c) or '?', n and n.kind or ''),
                ('tier: `%s`%s'):format(t, c.hedge and (' — ~ hedged: ' .. (c.hedge.rule or '?')) or ''),
                ('_from %s_'):format(where),
            }
            -- RBS enrichment: the real declared signature for a minted profile symbol
            local ps = profile_sig(n)
            if ps and ps.sig then
                lines[#lines + 1] = ('`%s: %s`'):format(n.name, ps.sig)
                -- a Rails framework sig carries its RBS defining module as provenance
                local prov = ps.owner and (ps.runtime .. ' · ' .. ps.owner) or ps.runtime
                lines[#lines + 1] = ('_%s · RBS %s_'):format(prov, ps.version or '?')
            end
            return md(lines)
        end
        if c.refused then
            local r = c.refused
            local ncand = (r.cands and #r.cands) or r.n or 0
            return md {
                ('**%s** — unresolved'):format(callrec.callee(c) or '?'),
                ('refused: `%s`%s'):format(r.rule or '?',
                    ncand > 0 and (' — ' .. ncand .. ' candidate(s)') or ''),
                r.witness and ('_' .. tostring(r.witness) .. '_') or nil,
            }
        end
        return md {
            ('**%s** — external frontier'):format(callrec.callee(c) or c.full or '?'),
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

-- ── callHierarchy: the graph IS a call hierarchy, and it crosses languages ──
-- (band:callers/callees walk the ref graph, which includes xlang edges — so a
-- TS proxy's callers list its C++ handler's side, one continuous hierarchy no
-- per-language server can produce). A CallHierarchyItem round-trips the node id
-- in `data`, so incoming/outgoing skip position re-resolution.
local function item_of(store, id)
    local n = store.node(id)
    if not navigable(n) or not SYMBOLKIND[n.kind] then return nil end
    return {
        name = n.name or id, kind = SYMBOLKIND[n.kind],
        uri = uri_of(store, n.file), range = lsp_range(n.range),
        selectionRange = lsp_range(n.range), data = { id = id },
    }
end

-- the graph node the cursor names: the call's target if on a usage, else the
-- def under it. Shared by callHierarchy prepare + cartograph/why.
local function symbol_at(store, file, line, char)
    local c = call_at(store, file, line, char)
    if c and c.to then return c.to end
    local n = node_at(store, file, line, char)
    return n and n.id or nil
end

M.handlers['textDocument/prepareCallHierarchy'] = function (store, params)
    local file = file_key(store, params.textDocument.uri)
    local id = symbol_at(store, file, params.position.line, params.position.character)
    local item = id and item_of(store, id)
    return item and { item } or vim.NIL
end

local function item_id(params) return params.item and params.item.data and params.item.data.id end

M.handlers['callHierarchy/incomingCalls'] = function (store, params)
    local id = item_id(params); if not id then return {} end
    local out = {}
    for _, caller in ipairs(store.topo():callers(id)) do
        local from = item_of(store, caller)
        if from then
            local ranges = {}
            for _, r in ipairs(store.occurrences(caller, id) or {}) do ranges[#ranges + 1] = lsp_range(r) end
            out[#out + 1] = { from = from, fromRanges = ranges }
        end
    end
    return out
end

M.handlers['callHierarchy/outgoingCalls'] = function (store, params)
    local id = item_id(params); if not id then return {} end
    local out = {}
    for _, callee in ipairs(store.topo():callees(id)) do
        local to = item_of(store, callee)
        if to then
            local ranges = {} -- the sites WITHIN `id` where it calls `to`
            for _, r in ipairs(store.occurrences(id, callee) or {}) do ranges[#ranges + 1] = lsp_range(r) end
            out[#out + 1] = { to = to, fromRanges = ranges }
        end
    end
    return out
end

-- ── cartograph/* — namespaced honesty/graph extensions (standard methods stay
-- strictly standard; these carry what no standard method can express) ────────
M.handlers['cartograph/why'] = function (store, params)
    local file = file_key(store, params.textDocument.uri)
    local p = params.position
    local c = call_at(store, file, p.line, p.character)
    if c then
        if c.to then
            return { kind = 'call', callee = callrec.callee(c),
                status = c.hedge and 'hedged' or 'resolved', target = c.to,
                tier = store.topo():tier(c.fn, c.to) or 'matched',
                hedge = c.hedge and c.hedge.rule or nil, prov = c.prov }
        elseif c.refused then
            return { kind = 'call', callee = callrec.callee(c), status = 'refused',
                rule = c.refused.rule,
                candidates = (c.refused.cands and #c.refused.cands) or c.refused.n or 0,
                witness = c.refused.witness }
        end
        return { kind = 'call', callee = callrec.callee(c), status = 'frontier' }
    end
    local n = node_at(store, file, p.line, p.character)
    if n then return { kind = 'def', name = n.name, node = n.id, exported = n.exported or false } end
    return vim.NIL
end

M.handlers['cartograph/graphInfo'] = function (store)
    local d = store.data or {}
    return {
        root = d.root, provider = d.provider,
        counts = { nodes = #(d.nodes or {}), edges = #(d.edges or {}), calls = #(d.calls or {}) },
        cacheVersion = require('cartograph.cache').VERSION,
    }
end

-- ── typeDefinition: the value's TYPE node (the receiver-typing payoff) ──────
-- The type of the thing under the cursor: a call -> its target's return type
-- (n.ret); a def -> its own return/declared type (n.ret/n.ctype). The type is
-- a NAME; resolve it to project node(s) via the NAME axis. A stdlib/builtin
-- type (String) has no node -> empty (honest), not a guess.
M.handlers['textDocument/typeDefinition'] = function (store, params)
    local file = file_key(store, params.textDocument.uri)
    local p = params.position
    local c = call_at(store, file, p.line, p.character)
    local tn
    if c and c.to then
        local n = store.node(c.to); tn = n and n.ret
    else
        local n = node_at(store, file, p.line, p.character)
        tn = n and (n.ret or n.ctype)
    end
    if not tn then return {} end
    local out = {}
    for _, id in ipairs(store.topo():named(tn)) do
        local loc = location(store, id); if loc then out[#out + 1] = loc end
    end
    return out
end

-- ── implementation: the concrete impls behind an abstract reference ─────────
-- Rides data.implements (iface -> child). On an interface CLASS -> its child
-- classes; on an interface METHOD (Iface::m) -> the same-named member on each
-- child. Empty where no implements data (honest — not every language dispatches
-- through declared interfaces).
-- the class of a member name: strip the trailing separator + member. [:.]+
-- so Java's '::' (two chars) doesn't leave a dangling colon ('Impl::label' ->
-- 'Impl', not 'Impl:'); works for '.' / ':' / '::'.
local function class_of(name) return name and name:match('^(.-)[:.]+[%w_]+$') or nil end

M.handlers['textDocument/implementation'] = function (store, params)
    local file = file_key(store, params.textDocument.uri)
    local p = params.position
    local id = (function ()
        local c = call_at(store, file, p.line, p.character)
        if c and c.to then return c.to end
        local n = node_at(store, file, p.line, p.character); return n and n.id
    end)()
    local n = id and store.node(id)
    if not n then return {} end
    local impls = store.data.implements or {}
    local cls = class_of(n.name)               -- 'Iface' for 'Iface::m', else nil
    local member = cls and n.name:match('[:%.]([%w_]+)$')
    local out, seen = {}, {}
    local function emit(nid)
        if seen[nid] then return end
        seen[nid] = true
        local loc = location(store, nid); if loc then out[#out + 1] = loc end
    end
    if cls then                                 -- an interface METHOD
        local children = {}
        for _, e in ipairs(impls) do if e.iface == cls then children[e.child] = true end end
        -- the same-named member on each child class (by_name is keyed by the
        -- FULL name, so match class + member — as workspace/symbol scans it)
        for name, ids in pairs(store.by_name or {}) do
            if children[class_of(name)] and name:match('[:%.]([%w_]+)$') == member then
                for _, mid in ipairs(ids) do emit(mid) end
            end
        end
    else                                        -- an interface CLASS (or plain node)
        for _, e in ipairs(impls) do
            if e.iface == n.name then
                for _, cid in ipairs(store.topo():named(e.child)) do emit(cid) end
            end
        end
    end
    return out
end

-- ── semanticTokens: TIER-COLORING — every resolved call site tinted by its
-- resolution trust (matched/inferred/typed/proven/stdlib/…), the modifier
-- bitmask carrying the tier. The uniform-honesty invariant, rendered: a theme
-- can wash name-matched ~ calls a different shade than proven ones. Delta-
-- encoded per the LSP wire (sorted by line, then char).
M.handlers['textDocument/semanticTokens/full'] = function (store, params)
    local file = file_key(store, params.textDocument.uri)
    local toks = {}
    for _, c in ipairs(store.topo():calls_of(file)) do
        if c.to and c.at then
            local line, char = atr.sl(c.at), atr.sc(c.at)
            local len = atr.ec(c.at) - char
            if atr.el(c.at) == line and len > 0 then -- single-line call-site span
                local t = store.topo():tier(c.fn, c.to) or 'matched'
                toks[#toks + 1] = { line = line, char = char, len = len, mod = TIER_BIT[t] or 0 }
            end
        end
    end
    table.sort(toks, function (a, b)
        if a.line ~= b.line then return a.line < b.line end
        return a.char < b.char
    end)
    local data, pl, pc = {}, 0, 0
    for _, t in ipairs(toks) do
        local dl = t.line - pl
        local dc = dl == 0 and (t.char - pc) or t.char
        data[#data + 1] = dl; data[#data + 1] = dc; data[#data + 1] = t.len
        data[#data + 1] = 0; data[#data + 1] = t.mod -- tokenType 0 = 'function'
        pl, pc = t.line, t.char
    end
    return { data = data }
end

-- ── diagnostics (T2 push only — T1 lets diag.lua publish natively, so a shared
-- handler would double-publish). A PURE helper the stdio host calls on
-- didOpen/didSave; memoized per graph generation so per-file filtering is cheap.
local LSP_SEV = { error = 1, warn = 2, info = 3, hint = 4 }
local _diag = { gen = nil, findings = nil }
--- LSP Diagnostic[] for one file (by uri), from the graph-aware lint.
function M.diagnostics(store, uri)
    if _diag.gen ~= store.generation then
        _diag = { gen = store.generation, findings = require('cartograph.lint').run(store) }
    end
    local abs = store.abs(file_key(store, uri))
    local out = {}
    for _, f in ipairs(_diag.findings) do
        if f.file == abs then
            local L = math.max((f.line or 1) - 1, 0)
            out[#out + 1] = {
                range = { start = { line = L, character = 0 }, ['end'] = { line = L, character = 0 } },
                severity = LSP_SEV[f.severity] or 2,
                source = 'cartograph', code = f.rule, message = f.message,
            }
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
