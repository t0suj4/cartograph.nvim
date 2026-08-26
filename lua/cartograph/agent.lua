-- agent.lua — THE AGENT VERB TABLE (T3 phase 1, CART-0144). The PURE core the
-- MCP host (tools/mcpserve.lua) serves, exactly as lua/cartograph/lsp.lua is the
-- pure core tools/lspserve.lua serves: a table of handlers taking (store, args)
-- and returning a document. Nothing here reads stdin, writes stdout or knows
-- what JSON-RPC is — so the same verbs can ride any other transport later
-- (a CLI, a JSON mode, an in-process call from a command) without a rewrite.
--
-- ── THE ENVELOPE, inherited from tools/agentq.lua (CART-0143) ────────────────
-- Every answer is the SAME document, and agentq's field names are kept verbatim
-- so a caller written against phase 0 reads phase 1 unchanged:
--
--   { ok, verb, graph, subject, result, tier, absence, absence_why, notes,
--     refusal }
--
-- THE RULE THAT CARRIES THE WEIGHT, unchanged and non-negotiable:
--   AN EMPTY RESULT ALWAYS CARRIES AN ABSENCE. A bare `[]` is unrepresentable.
--   `absence` ∈ absent | refused | frontier | unavailable, and `absence_why`
--   NAMES THE PREMISE that failed, with its evidence. The four MUST render
--   differently: on this repo's own fold the 266 dead-code findings split
--   7 absent / 229 refused / 12 frontier / 18 unavailable, and only the 7
--   license a deletion. M.answer ENFORCES this for every verb (see the
--   invariant check at the bottom) so a future verb cannot ship a bare list.
--
-- ── THE ONE DEVIATION FROM PHASE 0, AND WHY ─────────────────────────────────
-- Phase 0 wrote: "a non-empty result carries `tier`". That held because alibi's
-- rows ARE resolutions — a caller edge has a rung on tier.LADDER. Four of the
-- verbs here have rows that are NOT resolutions: a node found by name, the node
-- containing a line, a lint finding, this graph's own counts. Nothing bound a
-- name to an entity, so no rung applies, and tier.lua is explicit that minting
-- one is a design decision, not an edit (the LADDER is full — fold.lua packs the
-- rank in 3 bits and an 8th rung decodes as no tier at all).
--
-- So each verb DECLARES its `tier_basis`, and graph_info reports it — which is
-- exactly what graph_info is for, "so the agent knows what it MAY conclude":
--   'resolution'  rows are name resolutions; a non-empty result carries a rung
--   'observation' rows are read directly off the parse; `tier` is ALWAYS null,
--                 and that null means "this question has no rung", not "unknown"
--   'mixed'       per answer (only `why`: a call answer resolves, a def answer
--                 does not — the SHIPPED handler already returns a def with no
--                 tier, which is why porting it as-is forces this distinction)
-- The protected side is untouched: `absence` is still mandatory on every empty
-- result of every verb. What changed is the other side of the axis.
--
-- ── CAPABILITY, NOT SILENCE ─────────────────────────────────────────────────
-- A verb that needs the call graph declares `needs_calls`, and on a thin index
-- it REFUSES (rule `thin-index`) rather than serving an empty answer that reads
-- as an authoritative "none" ([[cartograph-thin-index]]). Unlike agentq's, this
-- refusal is REACHABLE through the documented interface — mcpserve --index-only
-- opens that state, and tests/mcpserve_spec.lua drives it over the wire
-- (CART-0580: a capability refusal a caller cannot reach is not a contract).

local atr = require 'cartograph.at'
local tiers = require 'cartograph.tier'

local M = {}
local NUL = vim.NIL

-- ── small helpers ───────────────────────────────────────────────────────────

local function nn(v) if v == nil then return NUL end return v end

--- the store's file key for a caller-supplied path: exact, root-relative, or a
--- unique trailing /-segment (the same courtesy optapply.at extends). Returns
--- (key) or (nil, 'unknown'|'ambiguous', hits).
local function resolve_file(store, path)
    if not path or path == '' then return nil, 'unknown', {} end
    local root = store.data and store.data.root
    if root and path:sub(1, #root + 1) == root .. '/' then path = path:sub(#root + 2) end
    if store.by_file and store.by_file[path] then return path end
    local hits = {}
    for _, f in ipairs(store.files or {}) do
        if f == path then return f end
        if #f > #path and f:sub(-(#path + 1)) == '/' .. path then hits[#hits + 1] = f end
    end
    if #hits == 1 then return hits[1] end
    if #hits > 1 then return nil, 'ambiguous', hits end
    return nil, 'unknown', {}
end

local function line_of(n)
    return (n and n.range) and (atr.sl(n.range) + 1) or nil
end

--- one node, rendered. `extra` merges in verb-specific fields (tier, sites, …).
local function noderow(store, id, extra)
    local n = store.node(id)
    if not n then return nil end
    local row = { ref = id, name = nn(n.name), kind = nn(n.kind), file = nn(n.file),
        line = nn(line_of(n)), exported = nn(n.exported) }
    for k, v in pairs(extra or {}) do row[k] = v end
    return row
end

--- the module node for a file key. THE MODULE NODE'S ID IS THE FILE KEY, and
--- store.by_file deliberately does NOT contain it (store.lua's idx: `if n.kind
--- ~= 'module'`) — so by_file is the DEFINITIONS axis and this is the only way
--- to reach the file's own node. Both facts are load-bearing below.
local function module_of(store, file)
    local n = store.node(file)
    if n and n.kind == 'module' then return n end
    return nil
end

--- WEAKEST-RUNG headline over a list of per-row tiers, and the quantifier reason
--- it differs from agentq's. An alibi is EXISTENTIAL ("is there anything keeping
--- this alive"), so ONE strong witness decides and the strongest rung is the
--- honest headline. A caller/callee list is UNIVERSAL over its rows ("these all
--- call it"), so the answer AS PRESENTED is only as trustworthy as its shakiest
--- member — the floor. Every row still carries its own rung, so the headline is
--- a summary, never the thing to act on. ([[cartograph-witness-and-promise]])
local function floor_tier(list)
    local worst
    for _, t in ipairs(list) do
        local r, wr = tiers.rank(t), worst and tiers.rank(worst)
        if r and (not wr or r > wr) then worst = t end
    end
    return worst
end

--- the CART-0545 disclosure, in agentq's own words: tier.lua and ladder.lua
--- order this one pair differently, so a headline picked across it is disputed.
local function disputed_note(list)
    local has = {}
    for _, t in ipairs(list) do has[t] = true end
    if has.inferred and has.matched then
        return { kind = 'tier-order-disputed',
            why = "this answer's tier was picked across 'inferred' vs 'matched', the one pair tier.lua and ladder.lua order differently (CART-0545) — read the per-row evidence, not the headline rung" }
    end
end

-- ── the graph descriptor: capability + frontier, on EVERY answer ─────────────
-- Memoized per store generation: it rides on every document, and the call sweep
-- is O(calls).

local function build_graph(store)
    local d = store.data or {}
    local files, unparsed, unparsed_files = 0, 0, {}
    for _, n in ipairs(d.nodes or {}) do
        if n.kind == 'module' then
            files = files + 1
            if n.unparsed then
                unparsed = unparsed + 1
                if #unparsed_files < 8 then unparsed_files[#unparsed_files + 1] = n.file end
            end
        end
    end
    -- CALL OUTCOMES — the frontier, in the only terms that matter to a caller:
    -- how much of the call graph is a resolution, how much a refusal, how much
    -- left the graph. An agent reading "0 callers" needs this beside it.
    local calls = { total = 0, resolved = 0, hedged = 0, refused = 0, external = 0, unresolved = 0 }
    for _, c in ipairs(d.calls or {}) do
        calls.total = calls.total + 1
        if c.to then
            calls.resolved = calls.resolved + 1
            if c.hedge then calls.hedged = calls.hedged + 1 end
        elseif c.refused then calls.refused = calls.refused + 1
        elseif c.ext then calls.external = calls.external + 1
        else calls.unresolved = calls.unresolved + 1 end
    end
    local thin = store.is_index_only and store.is_index_only() or false
    return {
        root = nn(d.root), provider = nn(d.provider),
        index = thin and 'index-only' or 'full',
        generation = store.generation or 0,
        partial = nn(d.partial),
        counts = { nodes = #(d.nodes or {}), edges = #(d.edges or {}),
            calls = #(d.calls or {}), files = files },
        -- THE FRONTIER: what was NOT looked at, stated positively
        frontier = { unparsed_files = unparsed, examples = unparsed_files, calls = calls },
    }
end

function M.graph(store)
    local gen = store.generation or 0
    local c = M._graph_cache
    if c and c.gen == gen and c.store == store then return c.doc end
    local doc = build_graph(store)
    M._graph_cache = { gen = gen, store = store, doc = doc }
    return doc
end

--- Does this graph have a call graph at all? The CAPABILITY question, not the
--- provenance one (store.lua's own distinction): a fully materialized thin index
--- answers yes.
function M.has_calls(store)
    if store.is_index_only and store.is_index_only() then return false end
    return (store.data or {}).calls ~= nil
end

-- ── verb results ────────────────────────────────────────────────────────────
-- A verb returns ONE of:
--   { result = rows, tier?, absence?, absence_why?, notes?, subject? }
--   { refusal = { rule, reason, remedy } }
-- and M.answer normalizes, fills the nulls and enforces the invariant.

local function refuse(rule, reason, remedy)
    return { refusal = { rule = rule, reason = reason, remedy = nn(remedy) } }
end

local function unknown_file(store, path, why, hits)
    if why == 'ambiguous' then
        return refuse('ambiguous-file',
            ('%q matches %d files in this graph (%s…)'):format(path, #hits, table.concat(hits, ', ', 1, math.min(3, #hits))),
            'pass a longer path suffix, or the exact key graph_info/node_find reports')
    end
    return refuse('unknown-file',
        ('%q is not a file in this graph (%d files extracted)'):format(path, #(store.files or {})),
        'pass a path relative to the graph root, or any unique trailing /-segment of one; node_find reports the exact keys')
end

-- ── verb: graph_info ────────────────────────────────────────────────────────

local ORDER = { 'graph_info', 'node_find', 'node_at', 'edges_callers', 'edges_callees', 'why', 'lint_run' }

local function v_graph_info(store)
    local rows = {}
    for _, name in ipairs(ORDER) do
        local v = M.VERBS[name]
        local available, why = true, nil
        if v.needs_calls and not M.has_calls(store) then
            available, why = false, 'this graph has no call graph (index-only) — the verb refuses rather than answering "none"'
        end
        rows[#rows + 1] = { verb = name, summary = v.summary,
            tier_basis = v.tier_basis, needs_calls = v.needs_calls or false,
            available = available, unavailable_why = nn(why),
            absences = v.absences }
    end
    -- graph_info's own rows are a description of the instrument, never empty.
    return { result = rows }
end

-- ── verb: node_find ─────────────────────────────────────────────────────────

local function v_node_find(store, args)
    local q = args.query
    local want = args.kind
    local limit = tonumber(args.limit) or 100
    local lq = q:lower()
    local pat = '[.:]' .. lq:gsub('(%W)', '%%%1') .. '$'
    local rows = {}
    for name, ids in pairs(store.by_name or {}) do
        local ln = name:lower()
        local how
        if ln == lq then how = 'exact'
        elseif ln:match(pat) then how = 'tail'
        elseif ln:find(lq, 1, true) then how = 'substring' end
        if how then
            for _, id in ipairs(ids) do
                local n = store.node(id)
                if n and (not want or n.kind == want) then
                    rows[#rows + 1] = noderow(store, id, { match = how,
                        external = nn(n.external) })
                end
            end
        end
    end
    local rank = { exact = 1, tail = 2, substring = 3 }
    table.sort(rows, function (a, b)
        if a.match ~= b.match then return rank[a.match] < rank[b.match] end
        if a.file ~= b.file then return tostring(a.file) < tostring(b.file) end
        return tostring(a.line) < tostring(b.line)
    end)
    local notes = {}
    if #rows > limit then
        -- A CLIP IS A FACT, NOT A SILENCE: say how many were dropped.
        notes[#notes + 1] = { kind = 'clipped', why =
            ('%d matches, %d returned — raise `limit` to see the rest'):format(#rows, limit),
            evidence = { matches = #rows, limit = limit } }
        for i = #rows, limit + 1, -1 do rows[i] = nil end
    end
    if #rows > 0 then return { result = rows, notes = notes } end

    -- EMPTY: what could hide a definition of this name?
    local g = M.graph(store)
    local hits = (#q >= 2) and store.frontier_find(q) or {}
    if #hits > 0 then
        return { result = {}, absence = 'frontier', absence_why = {
            premise = 'name-in-unparsed-file',
            why = ('no node carries this name, but the text %q occurs in %d file(s) that never parsed — they were landed by text search, so nothing in them was analysed'):format(q, #hits),
            evidence = { sites = hits } } }
    end
    if #q < 2 and g.frontier.unparsed_files > 0 then
        return { result = {}, absence = 'frontier', absence_why = {
            premise = 'query-too-short-to-search-the-frontier',
            why = ('no node carries this name; %d file(s) never parsed and a query under 2 characters cannot be searched in their text, so those files were not checked at all'):format(g.frontier.unparsed_files),
            evidence = { unparsed_files = g.frontier.unparsed_files } } }
    end
    if g.partial == true then
        return { result = {}, absence = 'frontier', absence_why = {
            premise = 'partial-graph',
            why = 'no node carries this name, but this graph is a PARTIAL ingest — files are still arriving, so the name may simply not have landed yet',
            evidence = NUL } }
    end
    return { result = {}, absence = 'absent', absence_why = {
        premise = 'no-such-name',
        why = ('no node in this graph carries a name matching %q, every file parsed, and the unparsed frontier is empty — the name is not defined here'):format(q),
        evidence = { names_indexed = vim.tbl_count(store.by_name or {}) } } }
end

-- ── verb: node_at ───────────────────────────────────────────────────────────

local function v_node_at(store, args)
    local file, why, hits = resolve_file(store, args.file)
    if not file then return unknown_file(store, args.file, why, hits) end
    local line = math.floor(tonumber(args.line) or 0)
    local subject = { kind = 'position', file = file, line = line }
    local mod = module_of(store, file)
    if mod and mod.unparsed then
        return { subject = subject, result = {}, absence = 'frontier', absence_why = {
            premise = 'unparsed',
            why = 'this file never parsed — it was landed by text search, so no definition in it was analysed and nothing can be addressed by position',
            evidence = { file = file } } }
    end
    -- THE CONTAINMENT CHAIN, innermost first, over the DEFINITIONS axis — which
    -- excludes the module node (see module_of). That exclusion is what keeps this
    -- verb's empty answer reachable at all: a module spans the whole file, so
    -- including it would mean every in-range position matches and the `absent`
    -- branch below could never fire. An unreachable branch is a claim nobody can
    -- check (CART-0580), and tests/mcpserve_spec.lua fires this one on a comment.
    local defs = (store.by_file or {})[file] or {}
    local rows = {}
    for _, n in ipairs(defs) do
        if n.range then
            local sl, el = atr.sl(n.range) + 1, atr.el(n.range) + 1
            if sl <= line and line <= el then
                rows[#rows + 1] = { node = n, span = el - sl }
            end
        end
    end
    table.sort(rows, function (a, b) return a.span < b.span end)
    local out = {}
    for i, r in ipairs(rows) do
        out[i] = noderow(store, r.node.id, { start_line = atr.sl(r.node.range) + 1,
            end_line = atr.el(r.node.range) + 1, depth = i - 1 })
    end
    if #out > 0 then return { subject = subject, result = out } end
    return { subject = subject, result = {}, absence = 'absent', absence_why = {
        premise = 'no-definition-covers-the-line',
        why = ('%s parsed and %d definition(s) were extracted from it, none of which spans line %d — the line is outside every definition (a comment, an import, a blank or a top-level statement)')
            :format(file, #defs, line),
        evidence = { file = file, defs_in_file = #defs } } }
end

-- ── verbs: edges_callers / edges_callees ────────────────────────────────────

--- the node an edges_* / why call is about: an explicit `node` id, or the
--- innermost function at file:line (agentq's addressing, kept identical).
local function subject_node(store, args)
    if args.node and args.node ~= '' then
        local n = store.node(args.node)
        if not n then
            return nil, refuse('unknown-node',
                ('no node with id %q is in this graph'):format(args.node),
                'pass a `ref` from a node_find / node_at row of THIS graph generation, or address by file+line instead')
        end
        return n
    end
    if not (args.file and args.line) then
        return nil, refuse('no-address',
            'neither `node` nor `file`+`line` was given, so there is nothing to answer about',
            'pass `node` (a ref from node_find/node_at) or `file` and `line`')
    end
    local file, why, hits = resolve_file(store, args.file)
    if not file then return nil, unknown_file(store, args.file, why, hits) end
    local optapply = require 'cartograph.optapply'
    local id = optapply.at(store, file, math.floor(tonumber(args.line) or 0))
    if not id then
        return nil, refuse('no-subject',
            ('no function or method encloses %s:%s'):format(file, tostring(args.line)),
            'point at a line inside a function body; node_at reports what a position actually names')
    end
    return store.node(id)
end

--- BLOCKERS RELEVANT TO "COULD A CALLER BE HIDDEN". lint.alibi computes the
--- premises of deadness; only some of them bear on THIS question, and mixing the
--- rest in would answer a question the caller did not ask. In:
---   unparsed / name-occurs-again / unreadable  nothing (or not everything) in
---     this file was analysed, so a call site may exist unseen
---   refusal-shadow  a call site SPELLED this name and a rule declined to bind it
---   escapes  the name reaches a value position, so a dispatch table can call it
--- Out: `visibility-undeclared` and `not-a-function` are about whether DELETION
--- is licensed, not about whether a caller was missed — they ride as notes.
local CALLER_BLOCKERS = { unparsed = true, ['refusal-shadow'] = true, escapes = true,
    ['name-occurs-again'] = true, unreadable = true }

local function v_edges_callers(store, args)
    local n, bad = subject_node(store, args)
    if not n then return bad end
    local subject = noderow(store, n.id)
    local band = store.topo()
    local rows, ts = {}, {}
    for _, from in ipairs(band:callers(n.id)) do
        -- a ref edge's tier IS its resolution tier: read it, never re-derive
        local t = band:tier(from, n.id) or 'matched'
        ts[#ts + 1] = t
        rows[#rows + 1] = noderow(store, from, { tier = t,
            sites = #(store.occurrences(from, n.id) or {}) })
    end
    if #rows > 0 then
        local notes = {}
        local d = disputed_note(ts)
        if d then notes[#notes + 1] = d end
        return { subject = subject, result = rows, tier = floor_tier(ts), notes = notes }
    end

    -- EMPTY: reuse the SHIPPED classifier. lint.alibi's blockers are the
    -- measured premise set (CART-0143), and its reporting precedence — most
    -- SPECIFIC first, not provably_dead's premise order — is why `refused` is
    -- reportable at all.
    local verdict = require('cartograph.lint').alibi(store)(n)
    local notes, decided = {}, nil
    for _, b in ipairs(verdict.blockers) do
        if CALLER_BLOCKERS[b.kind] and not decided then
            decided = b
        else
            notes[#notes + 1] = { kind = decided and 'also-blocked' or 'not-about-callers',
                premise = b.kind, absence = b.absence, why = b.why, evidence = nn(b.evidence) }
        end
    end
    -- NO CALLERS IS NOT DEAD. An agent that asked for callers and got an empty
    -- list must not read it as a deletion licence: say what else keeps it alive.
    for _, a in ipairs(verdict.alibis) do
        if a.kind ~= 'callers' then
            notes[#notes + 1] = { kind = 'alive-otherwise', alibi = a.kind, tier = a.tier,
                why = a.why }
        end
    end
    if decided then
        return { subject = subject, result = {}, absence = decided.absence,
            absence_why = { premise = decided.kind, why = decided.why,
                evidence = nn(decided.evidence) }, notes = notes }
    end
    return { subject = subject, result = {}, absence = 'absent', absence_why = {
        premise = 'no-ref-edge',
        why = 'no ref edge in this graph targets this node, and every premise that could hide one held: the file parsed, the name occurs only at its own definition, it never reaches a value position, and no refused call could be it',
        evidence = NUL }, notes = notes }
end

local function v_edges_callees(store, args)
    local n, bad = subject_node(store, args)
    if not n then return bad end
    local subject = noderow(store, n.id)
    local band = store.topo()
    local rows, ts = {}, {}
    for _, to in ipairs(band:callees(n.id)) do
        local t = band:tier(n.id, to) or 'matched'
        ts[#ts + 1] = t
        rows[#rows + 1] = noderow(store, to, { tier = t,
            sites = #(store.occurrences(n.id, to) or {}) })
    end
    -- the call rows made FROM this function, with their OUTCOMES — the evidence
    -- for both halves of the answer
    local refused, external, unresolved = {}, {}, 0
    for _, c in ipairs(band:sites(n.id)) do
        if c.refused then
            refused[#refused + 1] = { file = c.file, line = (c.line or 0) + 1,
                callee = c.callee, rule = c.refused.rule,
                candidates = c.refused.n or (c.refused.cands and #c.refused.cands) or 0 }
        elseif c.ext then
            external[#external + 1] = { file = c.file, line = (c.line or 0) + 1,
                callee = c.callee, why = c.ext.why }
        elseif not c.to then unresolved = unresolved + 1 end
    end
    local notes = {}
    if #refused > 0 then
        notes[#notes + 1] = { kind = 'refused-sites', premise = 'refusal',
            why = ('%d call site(s) in this function were REFUSED — a rule declined to pick between candidates, so those callees are missing from this list'):format(#refused),
            evidence = { sites = refused } }
    end
    if #external > 0 then
        notes[#notes + 1] = { kind = 'external-sites', premise = 'boundary',
            why = ('%d call site(s) resolve OUTSIDE this graph — the callee exists, it just has no node here'):format(#external),
            evidence = { sites = external } }
    end
    if #rows > 0 then
        local d = disputed_note(ts)
        if d then notes[#notes + 1] = d end
        return { subject = subject, result = rows, tier = floor_tier(ts), notes = notes }
    end

    -- EMPTY: the site list decides, and it decides SPECIFIC-FIRST.
    if n.unparsed then
        return { subject = subject, result = {}, absence = 'frontier', absence_why = {
            premise = 'unparsed',
            why = 'the source never parsed — it was landed by text search, so no call in this function was analysed',
            evidence = NUL }, notes = notes }
    end
    if #refused > 0 then
        return { subject = subject, result = {}, absence = 'refused', absence_why = {
            premise = 'all-sites-refused',
            why = ('this function makes %d call(s), and every one was REFUSED — a rule declined to pick between candidates, so the callees are unknown, NOT absent'):format(#refused),
            evidence = { sites = refused } }, notes = notes }
    end
    if #external > 0 or unresolved > 0 then
        return { subject = subject, result = {}, absence = 'frontier', absence_why = {
            premise = 'calls-leave-the-graph',
            why = ('this function makes %d call(s) that resolve outside this graph and %d the resolver never bound — something IS called here, it just has no node to point at')
                :format(#external, unresolved),
            evidence = { external = #external, unresolved = unresolved } }, notes = notes }
    end
    return { subject = subject, result = {}, absence = 'absent', absence_why = {
        premise = 'no-call-sites',
        why = 'the extractor recorded no call at all inside this function body, and the file parsed — it calls nothing',
        evidence = NUL }, notes = notes }
end

-- ── verb: why (PORTED AS-IS from the shipped LSP handler) ───────────────────
-- lsp.handlers['cartograph/why'] is called, never reimplemented: this verb is
-- transport. It is also the verb that FORCED `tier_basis = 'mixed'` — its call
-- branch carries a rung, its def branch deliberately carries none.

local function v_why(store, args)
    local file, why, hits = resolve_file(store, args.file)
    if not file then return unknown_file(store, args.file, why, hits) end
    local line = math.floor(tonumber(args.line) or 0)
    local col = math.floor(tonumber(args.col) or 1)
    local subject = { kind = 'position', file = file, line = line, col = col }
    local lsp = require 'cartograph.lsp'
    -- the handler speaks LSP: 0-based line/character, and a uri. Our surface is
    -- 1-based (agentq's), so the conversion lives HERE, at the seam.
    local ans = lsp.handlers['cartograph/why'](store, {
        textDocument = { uri = vim.uri_from_fname(store.abs(file)) },
        position = { line = math.max(0, line - 1), character = math.max(0, col - 1) },
    })
    if ans == nil or ans == vim.NIL then
        local mod = module_of(store, file)
        if mod and mod.unparsed then
            return { subject = subject, result = {}, absence = 'frontier', absence_why = {
                premise = 'unparsed',
                why = 'this file never parsed — nothing at any position in it was analysed',
                evidence = NUL } }
        end
        return { subject = subject, result = {}, absence = 'frontier', absence_why = {
            premise = 'nothing-modelled-here',
            why = 'no call record and no definition covers this position. Either nothing is there (a comment, a blank, an operator) or the extractor does not model the construct that is — and from here those two are INDISTINGUISHABLE, so this is not a statement that the position is empty',
            evidence = { file = file, line = line, col = col } } }
    end
    local notes = {}
    if ans.status == 'refused' then
        notes[#notes + 1] = { kind = 'refusal-is-the-answer', premise = ans.rule,
            why = ('this call was REFUSED between %d candidate(s) — the answer is "a rule declined", NOT "it calls nothing"'):format(ans.candidates or 0) }
    elseif ans.status == 'frontier' then
        notes[#notes + 1] = { kind = 'frontier-is-the-answer',
            why = 'a call is recorded here and the resolver produced no target and no refusal — nothing was concluded about it' }
    end
    -- MIXED basis: a resolved call has a rung; a def has none, and that null is
    -- the shipped handler's own honesty, not a gap here.
    local tier = (ans.kind == 'call' and (ans.status == 'resolved' or ans.status == 'hedged'))
        and ans.tier or nil
    return { subject = subject, result = { ans }, tier = tier, notes = notes }
end

-- ── verb: lint_run ──────────────────────────────────────────────────────────

local function v_lint_run(store, args)
    local lint = require 'cartograph.lint'
    local meta = {}
    for _, r in ipairs(lint.rules) do meta[r.name] = r end
    local only
    if args.rules and #args.rules > 0 then
        only = {}
        for _, r in ipairs(args.rules) do
            if not meta[r] then
                return nil, ('unknown rule %q'):format(r) -- a usage fault: see M.answer
            end
            only[r] = true
        end
    end
    local file
    if args.file and args.file ~= '' then
        local f, why, hits = resolve_file(store, args.file)
        if not f then return unknown_file(store, args.file, why, hits) end
        file = f
    end
    local findings, declined = lint.run(store, only and { only = only } or nil)
    local rows = {}
    for _, f in ipairs(findings) do
        local rel = f.file
        if rel and store.data and store.data.root and rel:sub(1, #store.data.root + 1) == store.data.root .. '/' then
            rel = rel:sub(#store.data.root + 2)
        end
        if not file or rel == file then
            local r = meta[f.rule] or {}
            rows[#rows + 1] = { rule = f.rule, severity = nn(f.severity), file = nn(rel),
                line = nn(f.line), message = nn(f.message),
                -- WHAT THE FINDING IS WORTH, from the rule's own declaration:
                -- an `authoritative` witness is a bug; a `suggestive` one is a
                -- lead. Acting on them alike is the misread this field prevents.
                disposition = nn(r.disposition), quantifier = nn(r.quantifier) }
        end
    end
    local notes = {}
    for _, d in ipairs(declined or {}) do
        notes[#notes + 1] = { kind = 'rule-refused', premise = d.rule, why = d.why,
            evidence = { quantifier = nn(d.quantifier), closed_over = nn(d.closed_over) } }
    end
    local ran = 0
    for _, r in ipairs(lint.rules) do if not only or only[r.name] then ran = ran + 1 end end
    if #rows > 0 then return { result = rows, notes = notes } end

    local g = M.graph(store)
    if #(declined or {}) > 0 then
        return { result = {}, absence = 'refused', absence_why = {
            premise = 'rules-declined',
            why = ('no finding, and %d rule(s) DECLINED to run over this scope — an empty report is not a clean bill of health'):format(#declined),
            evidence = { declined = #declined } }, notes = notes }
    end
    if g.frontier.unparsed_files > 0 then
        return { result = {}, absence = 'frontier', absence_why = {
            premise = 'unparsed-files',
            why = ('%d rule(s) ran and found nothing, but %d file(s) never parsed — no rule looked inside them'):format(ran, g.frontier.unparsed_files),
            evidence = { unparsed_files = g.frontier.unparsed_files,
                examples = g.frontier.examples } }, notes = notes }
    end
    return { result = {}, absence = 'absent', absence_why = {
        premise = 'no-rule-fired',
        why = ('%d rule(s) ran over %d parsed file(s) and none fired%s'):format(
            ran, g.counts.files, file and (' in ' .. file) or ''),
        evidence = { rules = ran, files = g.counts.files, file = nn(file) } }, notes = notes }
end

-- ── THE VERB TABLE ──────────────────────────────────────────────────────────
-- `absences` lists the absence values a verb can actually produce. It is
-- documentation an agent can read, and it is a standing question to the next
-- implementer: a value listed here that no branch emits is CART-0580 again.

M.VERBS = {
    graph_info = {
        summary = 'this graph: provider, counts, capability per verb, and the frontier (what was NOT looked at)',
        tier_basis = 'observation', absences = {},
        args = {},
        run = v_graph_info,
    },
    node_find = {
        summary = 'find definitions by name (exact, tail — M.foo ~ foo — or substring); each row says HOW it matched',
        tier_basis = 'observation', absences = { 'absent', 'frontier' },
        args = {
            { name = 'query', type = 'string', required = true, desc = 'the name to look for' },
            { name = 'kind', type = 'string', desc = 'restrict to a node kind (function, method, class, variable, module)' },
            { name = 'limit', type = 'integer', desc = 'max rows (default 100); a clip is reported as a note' },
        },
        run = v_node_find,
    },
    node_at = {
        summary = 'the definitions containing file:line, innermost first — addressing a position',
        tier_basis = 'observation', absences = { 'absent', 'frontier' },
        args = {
            { name = 'file', type = 'string', required = true, desc = 'path relative to the graph root (a unique trailing /-segment also resolves)' },
            { name = 'line', type = 'integer', required = true, desc = '1-based line' },
        },
        run = v_node_at,
    },
    edges_callers = {
        summary = 'who calls this — each row with its own resolution tier',
        tier_basis = 'resolution', needs_calls = true,
        absences = { 'absent', 'refused', 'frontier' },
        args = {
            { name = 'node', type = 'string', desc = 'a `ref` from node_find / node_at' },
            { name = 'file', type = 'string', desc = 'or address by position: path' },
            { name = 'line', type = 'integer', desc = 'or address by position: 1-based line inside a function' },
        },
        run = v_edges_callers,
    },
    edges_callees = {
        summary = 'what this calls — each row with its own resolution tier; refused and external sites ride as notes',
        tier_basis = 'resolution', needs_calls = true,
        absences = { 'absent', 'refused', 'frontier' },
        args = {
            { name = 'node', type = 'string', desc = 'a `ref` from node_find / node_at' },
            { name = 'file', type = 'string', desc = 'or address by position: path' },
            { name = 'line', type = 'integer', desc = 'or address by position: 1-based line inside a function' },
        },
        run = v_edges_callees,
    },
    why = {
        summary = 'the honesty record for what is at file:line — how a call resolved, or which rule refused it',
        tier_basis = 'mixed', needs_calls = true,
        absences = { 'frontier' },
        args = {
            { name = 'file', type = 'string', required = true, desc = 'path relative to the graph root' },
            { name = 'line', type = 'integer', required = true, desc = '1-based line' },
            { name = 'col', type = 'integer', desc = '1-based column (default 1)' },
        },
        run = v_why,
    },
    lint_run = {
        summary = 'the graph-aware lint findings, each carrying its rule disposition (authoritative vs suggestive)',
        tier_basis = 'observation', needs_calls = true,
        absences = { 'absent', 'refused', 'frontier' },
        args = {
            { name = 'rules', type = 'array', items = 'string', desc = 'restrict to these rule names (default: all)' },
            { name = 'file', type = 'string', desc = 'restrict to findings in this file' },
        },
        run = v_lint_run,
    },
}

M.ORDER = ORDER

--- MCP inputSchema for a verb (JSON Schema draft-07 object).
function M.schema(verb)
    local v = M.VERBS[verb]
    if not v then return nil end
    local props, req = {}, {}
    for _, a in ipairs(v.args) do
        local p = { type = a.type, description = a.desc }
        if a.type == 'array' then p.items = { type = a.items or 'string' } end
        props[a.name] = p
        if a.required then req[#req + 1] = a.name end
    end
    return { type = 'object', required = req,
        properties = next(props) and props or vim.empty_dict() }
end

--- Validate args against the declared shape. Returns nil, or a usage message.
local function validate(verb, args)
    local v = M.VERBS[verb]
    local decl = {}
    for _, a in ipairs(v.args) do
        decl[a.name] = a
        if a.required and (args[a.name] == nil or args[a.name] == '') then
            return ('%s requires `%s` (%s)'):format(verb, a.name, a.desc)
        end
        local got = args[a.name]
        if got ~= nil then
            if a.type == 'integer' and not tonumber(got) then
                return ('%s.%s must be a number, got %s'):format(verb, a.name, type(got))
            elseif a.type == 'array' and type(got) ~= 'table' then
                return ('%s.%s must be an array, got %s'):format(verb, a.name, type(got))
            elseif a.type == 'string' and type(got) ~= 'string' then
                return ('%s.%s must be a string, got %s'):format(verb, a.name, type(got))
            end
        end
    end
    for k in pairs(args) do
        if not decl[k] then
            return ('%s has no argument `%s` (accepts: %s)'):format(verb, k,
                #v.args > 0 and table.concat(vim.tbl_map(function (a) return a.name end, v.args), ', ') or 'none')
        end
    end
    return nil
end

-- ── M.answer: the ONE place the envelope is assembled and enforced ──────────
--- Returns (doc, status) where status ∈ 'ok' | 'refusal' | 'usage' | 'error'.
--- The transport decides what each status looks like on ITS wire; nothing about
--- JSON-RPC, exit codes or content blocks is decided here.
function M.answer(store, verb, args)
    args = args or {}
    local v = M.VERBS[verb]
    if not v then
        return { ok = false, verb = nn(verb), error = { kind = 'usage',
            reason = ('unknown verb %q'):format(tostring(verb)), verbs = M.ORDER } }, 'usage'
    end
    local bad = validate(verb, args)
    if bad then
        return { ok = false, verb = verb,
            error = { kind = 'usage', reason = bad } }, 'usage'
    end

    local graph = M.graph(store)
    local function envelope(fields)
        local d = { ok = true, verb = verb, graph = graph, subject = NUL, result = NUL,
            tier = NUL, absence = NUL, absence_why = NUL, notes = {}, refusal = NUL }
        for k, val in pairs(fields) do d[k] = val end
        return d
    end
    local function refusal(r)
        local d = envelope { subject = nn(r.subject) }
        d.ok, d.refusal = false, r
        return d, 'refusal'
    end

    -- CAPABILITY, in ONE place. A verb that needs the call graph must never be
    -- allowed to answer "none" off a graph that has none.
    if v.needs_calls and not M.has_calls(store) then
        return refusal { rule = 'thin-index',
            reason = ('this graph is index-only (%d nodes, no call graph), so %s would report an absence that is a property of the INDEX, not of the code'):format(graph.counts.nodes, verb),
            remedy = 'reopen the root without --index-only (a full extract), or ask a verb graph_info reports as available' }
    end

    local okc, res, usage = pcall(v.run, store, args)
    if not okc then
        return { ok = false, verb = verb, graph = graph,
            error = { kind = 'analysis', reason = tostring(res) } }, 'error'
    end
    if res == nil then -- a verb may return (nil, usage-message)
        return { ok = false, verb = verb, graph = graph,
            error = { kind = 'usage', reason = tostring(usage) } }, 'usage'
    end
    if res.refusal then return refusal(res.refusal) end

    local result = res.result or {}
    local tier, absence, absence_why = res.tier, res.absence, res.absence_why
    local notes = res.notes or {}

    -- ── THE INVARIANT, ENFORCED (not merely documented) ────────────────────
    -- Exactly one side of the tier/absence axis exists at a time, and an empty
    -- result ALWAYS carries an absence. A verb that breaks this is a bug in
    -- THIS file, and it says so rather than emitting a bare list.
    if #result > 0 then
        if absence ~= nil then
            notes[#notes + 1] = { kind = 'envelope-bug',
                why = ('verb %s returned %d rows AND an absence (%s) — the absence was dropped; report this'):format(verb, #result, tostring(absence)) }
            absence, absence_why = nil, nil
        end
        if v.tier_basis == 'observation' then tier = nil end
        if v.tier_basis == 'resolution' and tiers.rank(tier) == nil then
            notes[#notes + 1] = { kind = 'envelope-bug',
                why = ('verb %s declares tier_basis=resolution but returned %s, which is not a tier.LADDER rung — treat the rows as untiered'):format(verb, tostring(tier)) }
            tier = nil
        end
    else
        tier = nil
        if absence == nil then
            absence = 'unavailable'
            absence_why = { premise = 'unclassified',
                why = ('verb %s returned an empty result and named no absence — the classifier and the verb disagree; treat this as a bug in agent.lua, not as a fact about the code'):format(verb),
                evidence = NUL }
        end
    end

    return envelope { subject = nn(res.subject), result = result, tier = nn(tier),
        absence = nn(absence), absence_why = nn(absence_why), notes = notes }, 'ok'
end

return M
