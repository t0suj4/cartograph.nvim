-- agent.lua — THE AGENT VERB TABLE (T3 phases 1-2, CART-0144 / CART-0145). The PURE core the
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
-- ★ ONE THING 'resolution' DOES *NOT* PROMISE, and `cone` is what forced saying
-- so: that every ROW carries a rung. A cone member was reached through a CHAIN
-- of resolutions, so the ANSWER has an honest rung — the floor over every ref
-- edge inside the cone — but a per-ROW rung would have to be invented, because
-- cone.reachable is a set BFS that keeps no path. So cone's rows carry no
-- `tier`, and a mandatory note on every non-empty cone says that null means
-- UNKNOWN, not "no rung applies". A fourth basis value was the alternative; a
-- note that travels WITH THE ANSWER beats an enum a caller has to look up.
--
-- ── CAPABILITY, NOT SILENCE ─────────────────────────────────────────────────
-- A verb that needs the call graph declares `needs_calls`, and on a thin index
-- it REFUSES (rule `thin-index`) rather than serving an empty answer that reads
-- as an authoritative "none" ([[cartograph-thin-index]]). Unlike agentq's, this
-- refusal is REACHABLE through the documented interface — mcpserve --index-only
-- opens that state, and tests/mcpserve_spec.lua drives it over the wire
-- (CART-0580: a capability refusal a caller cannot reach is not a contract).
--
-- ── PHASE 2 ADDS TWO THINGS, AND THE ORDER BETWEEN THEM IS THE POINT ────────
-- 1 REFS IN THE ENVELOPE. Every node row now carries BOTH handles: `id`, the
--   session id that embeds line numbers and dies at the next edit, and `ref`,
--   the durable {file, kind, name, ordinal?, witness?} refs.lua already knows
--   how to resolve. Every verb that accepts an id accepts a ref too, and a ref
--   that no longer resolves REFUSES (rule `stale-ref`, carrying refs.lua's own
--   `why`) instead of landing on whatever now sits at that name. This lands
--   BEFORE the write verbs (CART-0146) deliberately: on the read side a stale
--   handle costs a wrong answer, on the write side it costs the wrong edit.
-- 2 THE ANALYSIS CATALOGUE — seven more verbs, each ONE DISPATCH ENTRY over a
--   function that already returns rows. What is NOT here, and why, is at the
--   tail of this file; that list is part of the deliverable.
--
-- ── PHASE 3 ADDS THE WRITE AXIS, AND ITS ORDER IS ALSO THE POINT (CART-0146) ─
-- plan → preview → journal → apply → undo, built and shippable in exactly that
-- sequence: the first two write nothing and are useful alone (propose a refactor,
-- show a human the diff, with no apply capability in existence), the journal is
-- read before it can be added to, and the byte-moving pair comes last. A second
-- CAPABILITY AXIS arrives with them — `mutates`, a fact about the HOST rather
-- than the graph, refused by rule `read-only` unless mcpserve was started with
-- --write. The write section below the catalogue holds the rest of the reasoning:
-- why a plan is a HANDLE and not a document, why a ref caveat that is a note on
-- the read side is a REFUSAL here, and what is deliberately not relaxed.

-- ── PHASE 4 IS ONE AXIS, NOT A PHASE: THE VERSION AXIS (CART-0595) ──────────
-- portability.lua's A-to-B diff is the strongest evidence this tool produces
-- about a port, and until now no agent could reach any of it — the tail of this
-- file listed portability among the verbs "skipped for scope". Three entries in
-- the catalogue close that: the target ROSTER (so a from/to pair is never
-- guessed at), the READ diff and the CALL diff. The READ one is the answer; the
-- CALL one is in the table because leaving it out would leave an agent no way to
-- ask the called-name question at all, and its summary says which it is. The
-- reasoning that shaped them sits above the verbs themselves.

local atr = require 'cartograph.at'
local tiers = require 'cartograph.tier'
local tsutil = require 'cartograph.spec.tsutil'

local M = {}
local NUL = vim.NIL

--- THE HOST'S WRITE PERMISSION (CART-0146), and why it is a property of the HOST
--- rather than of the graph. `needs_calls` asks a question about the CODE ("is
--- there a call graph to read"); this asks one about the PROCESS ("was this
--- server started with permission to edit the tree"). They are different axes and
--- they refuse with different rules, because an agent's correct response differs:
--- a thin index says re-open the root, a read-only host says the operator has not
--- granted writes and no argument will change that.
---
--- DEFAULT FALSE, deliberately. tools/mcpserve.lua shipped in phase 1 as a READ
--- surface, and every client already pointed at it would silently gain the power
--- to rewrite the tree the day these verbs landed. `--write` is the same shape as
--- `--index-only`: a documented mode that makes a capability refusal REACHABLE
--- (CART-0580), which is why tests/agentwrite_spec.lua can drive it over the wire.
M.WRITABLE = false
function M.set_writable(on) M.WRITABLE = on and true or false end

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
---
--- TWO HANDLES, AND THEY ARE NOT INTERCHANGEABLE (CART-0145). `id` is the
--- SESSION handle: it embeds line numbers, so the first edit above a function
--- invalidates it silently, and it is meaningless to any other process. `ref` is
--- the DURABLE one — {file, kind, name, ordinal?, witness?} — which survives
--- edits elsewhere, survives a body edit with a drift note, and follows a rename
--- by witness. Phase 1 shipped ONE field called `ref` that actually held the id;
--- carrying both under their true names is what lets a caller hold a handle
--- across a write, which is the whole reason phase 3 needs this first.
--- M.answer attaches `ref` (see attach_refs) so no verb can forget to.
local function noderow(store, id, extra)
    local n = store.node(id)
    if not n then return nil end
    local row = { id = id, ref = NUL, name = nn(n.name), kind = nn(n.kind),
        file = nn(n.file), line = nn(line_of(n)), exported = nn(n.exported) }
    -- ★★ WHAT HAS BEEN SAID ABOUT THIS NODE — AND WHAT NOBODY ASKED (CART-0762).
    -- `findings` alone would be a trap: an empty list reads as "clean" whether a
    -- census cleared this node or no census has ever run. `not_run` beside it is
    -- what makes the two distinguishable, so BOTH are always present — the same
    -- rule that makes a call verb REFUSE on an index-only graph rather than
    -- answering "none".
    local okf, F = pcall(require, 'cartograph.findings')
    if okf then
        local f = F.for_node(store, id)
        row.findings = f.findings
        row.not_run = f.not_run
        if #f.stale > 0 then row.findings_stale = f.stale end
    end
    for k, v in pairs(extra or {}) do row[k] = v end
    return row
end

--- THE DURABLE REF FOR A ROW, filled in ONE place. store.ref_of does the work
--- (siblings by file+kind+name, witness over df shape + params + callees); this
--- only decides when a ref is WORTH HANDING OUT. A ref with no file or no name
--- cannot be resolved back — refs.resolve matches on both — so emitting one
--- would be a handle that always refuses. NUL says "this row has no durable
--- handle", which is the truth for an anonymous or fileless node.
---
--- Attaching here rather than inside each verb has a second effect that matters:
--- it runs AFTER a clip, so the witness hash is paid only for rows a caller
--- actually receives, not for every match node_find considered.
local function attach_refs(store, rows)
    if type(rows) ~= 'table' then return end
    for _, r in ipairs(rows) do
        if type(r) == 'table' and type(r.id) == 'string'
            and (r.ref == nil or r.ref == NUL) then
            local okr, ref = pcall(store.ref_of, r.id)
            if okr and ref and ref.file and ref.name then r.ref = ref end
        end
    end
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
---
--- ★ AND THE CHOICE IS NOW PUBLISHED, not merely reasoned (CART-0581). Both
--- rules are correct and they are OPPOSITE, under one field name: `tier:
--- inferred` from agentq means "the best thing supporting this is a guess",
--- while the same string here means "at least one row is a guess, the rest may
--- be proven". A human notices the verbs differ; an agent has only the field.
--- So each verb declares `tier_headline` ∈ 'floor' | 'peak' beside its
--- `tier_basis`, graph_info publishes it in the same catalogue row, and agentq
--- emits `tier_headline = 'peak'` — a SUMMARY OVER ROWS IS A QUANTIFIER CHOICE,
--- and publishing the summary without its quantifier is the same defect class as
--- an empty list without its absence: the value is legible, its meaning is not.
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
    local doc
    if c and c.gen == gen and c.store == store then
        doc = c.doc
    else
        doc = build_graph(store)
        M._graph_cache = { gen = gen, store = store, doc = doc }
    end
    -- `writable` is stamped on EVERY call, never inside build_graph: it is a fact
    -- about the HOST, and the memo is keyed on the graph's generation, so freezing
    -- it there would publish whatever the flag happened to be at the first answer.
    doc.writable = M.WRITABLE
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

local function refuse(rule, reason, remedy, extra)
    local r = { rule = rule, reason = reason, remedy = nn(remedy) }
    for k, v in pairs(extra or {}) do r[k] = v end
    return { refusal = r }
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

-- Phase 1's five, then THE ANALYSIS CATALOGUE (CART-0145) in the ticket's own
-- frequency order: clones, cone, ladder, territory, then the honesty family.
-- Each is ONE DISPATCH ENTRY over a function that already exists and already
-- returns rows. THE RULE THAT DECIDED WHAT IS *NOT* HERE: where a capability
-- exists only as report() lines, it was LEFT OUT rather than scraped — a missing
-- verb is honest, a scraped one is a latent break. See the file's tail comment
-- for the list of what was skipped and why.
local ORDER = { 'graph_info', 'node_find', 'node_at', 'edges_callers', 'edges_callees',
    'why', 'lint_run',
    'clones_find', 'cone', 'ladder', 'territory', 'census', 'mentions', 'externals',
    -- THE VERSION AXIS (CART-0595), listed after the external surface because it
    -- is that surface scored twice: the roster first (there is no from/to to
    -- guess at), then the READ diff, then the CALL diff it must not be mistaken
    -- for.
    'portability_targets', 'portability_move', 'portability_move_calls',
    -- THE WRITE AXIS (CART-0146), listed in the order it may be TRUSTED in and
    -- was built in: propose, diff, read the history, then write, then reverse.
    'txn_plan_moveset', 'txn_plan_optimize', 'txn_plan_declare', 'txn_preview',
    'journal_list', 'journal_get',
    'txn_apply', 'txn_undo' }

local function v_graph_info(store)
    local rows = {}
    for _, name in ipairs(ORDER) do
        local v = M.VERBS[name]
        local available, why = true, nil
        if v.needs_calls and not M.has_calls(store) then
            available, why = false, 'this graph has no call graph (index-only) — the verb refuses rather than answering "none"'
        end
        -- THE WRITE PERMISSION IS A SECOND CAPABILITY AXIS (CART-0146), and it is
        -- reported the same way the first one is. `needs_calls` is about the
        -- GRAPH, `mutates` about the HOST — a verb can be unavailable for either
        -- reason and an agent's next move differs, so they never merge into one
        -- boolean.
        if v.mutates and not M.WRITABLE then
            available, why = false, 'this host was started read-only — the verb writes to the tree and refuses rather than doing it without permission'
        end
        rows[#rows + 1] = { verb = name, summary = v.summary,
            tier_basis = v.tier_basis, mutates = v.mutates or false,
            -- CART-0581: WHICH QUANTIFIER produced the headline `tier`. Without
            -- it, `tier: inferred` from a floor verb and from a peak verb are
            -- the same string carrying opposite claims.
            tier_headline = nn(v.tier_headline),
            needs_calls = v.needs_calls or false,
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

--- THE STALE-REF REFUSAL (CART-0145). refs.resolve already decides — and it
--- decides in three directions, which is why this is not a boolean:
---   nil + 'missing'      the definition is GONE from that file
---   nil + 'ambiguous: N' several same-named siblings and the witness could not
---                        tell them apart — a wrong pick here is silent damage
---   id  + a note         it resolved, WITH a caveat ('witness drifted (body
---                        changed)', "renamed? now 'x'", 'by ordinal') — an
---                        answer, not a refusal, so it rides as a note
--- Only the first two refuse, and the refusal carries refs.lua's `why` VERBATIM
--- in its own field rather than only inside prose, because a caller that must
--- branch on missing-vs-ambiguous should not have to parse a sentence.
local function stale_ref(ref, why)
    local ambiguous = why:sub(1, 9) == 'ambiguous'
    return refuse('stale-ref',
        ('the ref %s::%s (%s) does not resolve against this graph: %s')
            :format(tostring(ref.file), tostring(ref.name), tostring(ref.kind), why),
        ambiguous
            and 'several definitions in that file share the name and the witness could not separate them — pass `node` with an id from node_find, or add the `ordinal` field the ref carries when it is minted'
            or 'the definition is gone from that file, or moved to another one — call node_find with the name to see where it is now, and take a fresh `ref` from the row',
        { why = why })
end

--- the node an edges_* / why call is about: an explicit `node` id, a durable
--- `ref`, or the innermost function at file:line (agentq's addressing, kept
--- identical). Returns (node, refusal, note) — the note is the ref caveat.
local function subject_node(store, args)
    if args.ref ~= nil and args.ref ~= NUL then
        local id, why = store.resolve_ref(args.ref)
        if not id then return nil, stale_ref(args.ref, why or 'missing') end
        local n = store.node(id)
        if not n then return nil, stale_ref(args.ref, 'missing') end
        local note
        if why then
            note = { kind = 'ref-caveat', premise = 'ref-resolution',
                why = ('the ref resolved with a caveat — %s — so this answer is about the node it LANDED ON, not necessarily the one that was pinned'):format(why),
                evidence = { resolved_to = n.id, ref = args.ref } }
        end
        return n, nil, note
    end
    if args.node and args.node ~= '' then
        local n = store.node(args.node)
        if not n then
            return nil, refuse('unknown-node',
                ('no node with id %q is in this graph'):format(args.node),
                'pass an `id` from a node_find / node_at row of THIS graph generation, the durable `ref` from the same row, or address by file+line instead')
        end
        return n
    end
    if not (args.file and args.line) then
        return nil, refuse('no-address',
            'neither `node`, `ref` nor `file`+`line` was given, so there is nothing to answer about',
            'pass `node` (an id from node_find/node_at), `ref` (the durable handle from the same row) or `file` and `line`')
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

--- WHY A CALLER LIST IS EMPTY, as a named classifier rather than an inline
--- branch — because `cone` asks the SAME question. A cone over `usedby` is empty
--- exactly when the first hop is empty, so the premise that hides a caller of
--- the anchor is the premise that hides the whole cone: delegating is not code
--- reuse, it is the same fact. Returns (absence, absence_why, notes).
---
--- The classifier itself is the SHIPPED one. lint.alibi's blockers are the
--- measured premise set (CART-0143), and its reporting precedence — most
--- SPECIFIC first, not provably_dead's premise order — is why `refused` is
--- reportable at all.
local function callers_empty(store, n)
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
        return decided.absence,
            { premise = decided.kind, why = decided.why, evidence = nn(decided.evidence) },
            notes
    end
    return 'absent', {
        premise = 'no-ref-edge',
        -- ⚠ THIS CLAUSE LIST IS A CLAIM ABOUT WHAT WAS CHECKED, so it is written
        -- to be falsifiable rather than reassuring. The last clause was the one
        -- that was false (CART-0670): a refused call COULD be it, because the
        -- refusal record kept 8 of its candidates and the premise read only the
        -- 8. It now covers the elided tail, and SAYS it does — a reader who
        -- doubts this verdict knows exactly which of five things to go and test.
        why = 'no ref edge in this graph targets this node, and every premise that could hide one held: the file parsed, the name occurs only at its own definition, it never reaches a value position, no refused call lists it among its candidates, and no refused call spelling this name kept fewer candidates than it saw',
        evidence = NUL }, notes
end

--- the call sites made FROM a function, by OUTCOME — the evidence for both
--- halves of a callee answer, and the input to callees_empty.
--- ★ AND ONE OUTCOME THE ADJACENCY CANNOT SHOW, found driving the cone. A REF
--- EDGE FROM A NODE TO ITSELF IS DELIBERATELY LEFT OUT of store.uses/usedby
--- (store.lua's idx_edge: "self edges (recursion) carry occurrences only: they
--- must not inflate usedby/uses"), which is right for the dead-function lint and
--- for heat — recursion does not keep a function alive. But it means
--- band:callees() returns nothing for a purely self-recursive function, and the
--- honest classifier below would then report `no-call-sites`, whose stated
--- premise is "the extractor recorded no call at all inside this function body".
--- THAT IS FALSE: the call record exists, with `to` pointing at the function
--- itself. So self calls are counted here and reported as their own premise.
local function callee_sites(band, id)
    local refused, external, unresolved, self_calls = {}, {}, 0, 0
    for _, c in ipairs(band:sites(id)) do
        if c.to == id then self_calls = self_calls + 1
        elseif c.refused then
            refused[#refused + 1] = { file = c.file, line = (c.line or 0) + 1,
                callee = c.callee, rule = c.refused.rule,
                -- `n` is what the refusal SAW, `cands` is what it KEPT (capped at
                -- 8). Both, always — CART-0682: the absence machinery read the
                -- kept count and this verb read the true one, so one refusal had
                -- two published widths and nothing said which was which.
                candidates = c.refused.n or (c.refused.cands and #c.refused.cands) or 0,
                candidates_kept = c.refused.cands and #c.refused.cands or nil,
                truncated = tsutil.truncated(c.refused) or nil }
        elseif c.ext then
            external[#external + 1] = { file = c.file, line = (c.line or 0) + 1,
                callee = c.callee, why = c.ext.why }
        elseif not c.to then unresolved = unresolved + 1 end
    end
    local notes = {}
    if self_calls > 0 then
        notes[#notes + 1] = { kind = 'self-calls', premise = 'recursion',
            why = ('%d call site(s) in this function call the function ITSELF. A self ref edge is deliberately excluded from the reachability adjacency (it must not make a function look alive), so recursion never appears as a row here — it is reported only as this note'):format(self_calls),
            evidence = { self_calls = self_calls } }
    end
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
    return refused, external, unresolved, notes, self_calls
end

--- WHY A CALLEE LIST IS EMPTY. The site list decides, and it decides
--- SPECIFIC-FIRST. Returns (absence, absence_why); `cone` over `uses` delegates
--- here for the same reason it delegates to callers_empty.
local function callees_empty(n, refused, external, unresolved, self_calls)
    if n.unparsed then
        return 'frontier', { premise = 'unparsed',
            why = 'the source never parsed — it was landed by text search, so no call in this function was analysed',
            evidence = NUL }
    end
    if #refused > 0 then
        return 'refused', { premise = 'all-sites-refused',
            why = ('this function makes %d call(s), and every one was REFUSED — a rule declined to pick between candidates, so the callees are unknown, NOT absent'):format(#refused),
            evidence = { sites = refused } }
    end
    if #external > 0 or unresolved > 0 then
        return 'frontier', { premise = 'calls-leave-the-graph',
            why = ('this function makes %d call(s) that resolve outside this graph and %d the resolver never bound — something IS called here, it just has no node to point at')
                :format(#external, unresolved),
            evidence = { external = #external, unresolved = unresolved } }
    end
    if (self_calls or 0) > 0 then
        return 'absent', { premise = 'only-calls-itself',
            why = ('every one of this function\'s %d call site(s) calls the function ITSELF. The call was recorded and it resolved — there is simply no row to show, because a self edge is excluded from the reachability adjacency by design. This is NOT "it calls nothing".'):format(self_calls),
            evidence = { self_calls = self_calls } }
    end
    return 'absent', { premise = 'no-call-sites',
        why = 'the extractor recorded no call at all inside this function body, and the file parsed — it calls nothing',
        evidence = NUL }
end

local function v_edges_callers(store, args)
    local n, bad, refnote = subject_node(store, args)
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
        local notes = { refnote }
        local d = disputed_note(ts)
        if d then notes[#notes + 1] = d end
        return { subject = subject, result = rows, tier = floor_tier(ts), notes = notes }
    end
    local absence, why, notes = callers_empty(store, n)
    if refnote then table.insert(notes, 1, refnote) end
    return { subject = subject, result = {}, absence = absence, absence_why = why,
        notes = notes }
end

local function v_edges_callees(store, args)
    local n, bad, refnote = subject_node(store, args)
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
    local refused, external, unresolved, notes, self_calls = callee_sites(band, n.id)
    if refnote then table.insert(notes, 1, refnote) end
    if #rows > 0 then
        local d = disputed_note(ts)
        if d then notes[#notes + 1] = d end
        return { subject = subject, result = rows, tier = floor_tier(ts), notes = notes }
    end
    local absence, why = callees_empty(n, refused, external, unresolved, self_calls)
    return { subject = subject, result = {}, absence = absence, absence_why = why,
        notes = notes }
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

-- ════ THE ANALYSIS CATALOGUE (CART-0145 half B) ═════════════════════════════
-- Each verb below is ONE DISPATCH ENTRY over a function that already exists and
-- already returns rows. No analysis is written here, and nothing parses a
-- report() line — see the SKIPPED list at the tail of this file.

-- ── verb: clones_find ───────────────────────────────────────────────────────

local function v_clones_find(store, args)
    local clones = require 'cartograph.clones'
    local limit = math.floor(tonumber(args.limit) or 50)
    local want = args.kind
    local rows = {}
    if want ~= 'near' then
        for _, g in ipairs(clones.exact(store)) do
            local members = {}
            for _, m in ipairs(g) do members[#members + 1] = noderow(store, m.id) end
            rows[#rows + 1] = { kind = 'exact', shape = 'exact', copies = #g,
                distance = 0, rows_compared = nn(g.nrows), members = members,
                holes = {}, drift = {},
                action = ':CartographMerge folds an exact group into one definition' }
        end
    end
    if want ~= 'exact' then
        for _, p in ipairs(clones.near(store)) do
            local a = clones.analyze_pair(p)
            local holes = {}
            for _, h in ipairs(a.holes or {}) do
                holes[#holes + 1] = { kind = nn(h.kind), a = tostring(h.a), b = tostring(h.b) }
            end
            -- DRIFT is a QUESTION, not a finding: one copy hardcodes what the
            -- other reads. clones.analyze_pair already states what it checked
            -- (a literal facing a reference), and that wording rides along.
            local drift = {}
            for _, d in ipairs(a.drift or {}) do
                drift[#drift + 1] = { literal = tostring(d.lit), side = d.lit_side,
                    other = nn(d.other) }
            end
            rows[#rows + 1] = { kind = 'near', shape = a.kind, copies = 2,
                distance = p.dist, rows_compared = NUL,
                members = { noderow(store, p.a.id), noderow(store, p.b.id) },
                holes = holes, drift = drift,
                action = a.kind == 'structural'
                    and 'extract by hand — the two shapes diverged, so no parameter list recovers the difference'
                    or ':CartographExtractHelper factors the holes into parameters' }
        end
    end
    table.sort(rows, function (x, y)
        if x.distance ~= y.distance then return x.distance < y.distance end
        if #x.members ~= #y.members then return #x.members > #y.members end
        local xf, yf = tostring(x.members[1] and x.members[1].file),
            tostring(y.members[1] and y.members[1].file)
        if xf ~= yf then return xf < yf end
        return tostring(x.members[1] and x.members[1].line)
            < tostring(y.members[1] and y.members[1].line)
    end)
    local notes = {}
    -- A LOWER BOUND IS NOT A COUNT: clones.near_report says so in prose to a
    -- human; an agent gets it as a note it cannot skip past.
    notes[#notes + 1] = { kind = 'lower-bound', premise = 'alignment',
        why = 'near-clone detection is a LOWER BOUND — a pair differing only by local reordering, or by a for-loop binder, aligns out of range and is not reported. More clones may exist than are listed.',
        evidence = NUL }
    if #rows > limit then
        notes[#notes + 1] = { kind = 'clipped', why =
            ('%d clone group(s), %d returned — raise `limit` to see the rest'):format(#rows, limit),
            evidence = { groups = #rows, limit = limit } }
        for i = #rows, limit + 1, -1 do rows[i] = nil end
    end
    if #rows > 0 then return { result = rows, notes = notes } end

    -- EMPTY: "no clones" and "nothing was comparable" are OPPOSITE claims, and
    -- the comparison needs a per-function data-flow record to index at all.
    local dfa = require 'cartograph.df'
    local fns, modelled = 0, 0
    for _, n in ipairs((store.data or {}).nodes or {}) do
        if n.kind == 'function' or n.kind == 'method' then
            fns = fns + 1
            if dfa.present(n) then modelled = modelled + 1 end
        end
    end
    if fns == 0 then
        return { result = {}, absence = 'absent', absence_why = {
            premise = 'no-functions',
            why = 'this graph holds no function or method node at all, so there was nothing that could be a clone of anything',
            evidence = { functions = 0 } }, notes = notes }
    end
    if modelled == 0 then
        return { result = {}, absence = 'unavailable', absence_why = {
            premise = 'no-dataflow-records',
            why = ('%d function(s) are in this graph and NONE carries a data-flow record — the clone index is built from df row-keys, so nothing was compared. This is a property of the extraction, not of the code.'):format(fns),
            evidence = { functions = fns, with_dataflow = 0 } }, notes = notes }
    end
    local g = M.graph(store)
    if g.frontier.unparsed_files > 0 then
        return { result = {}, absence = 'frontier', absence_why = {
            premise = 'unparsed-files',
            why = ('%d of %d function(s) were comparable and no pair matched, but %d file(s) never parsed — no function in them was indexed'):format(modelled, fns, g.frontier.unparsed_files),
            evidence = { with_dataflow = modelled, functions = fns,
                unparsed_files = g.frontier.unparsed_files } }, notes = notes }
    end
    return { result = {}, absence = 'absent', absence_why = {
        premise = 'no-matching-pair',
        why = ('%d of %d function(s) carried a data-flow record and were indexed; no group shares a structure and no pair aligns within the edit-distance threshold'):format(modelled, fns),
        evidence = { with_dataflow = modelled, functions = fns } }, notes = notes }
end

-- ── verb: cone ──────────────────────────────────────────────────────────────

local function v_cone(store, args)
    local n, bad, refnote = subject_node(store, args)
    if not n then return bad end
    local subject = noderow(store, n.id)
    local dir = args.direction or 'out'
    local adj = (dir == 'out') and store.uses or store.usedby
    local set = require('cartograph.cone').reachable(n.id, adj)
    local ids = {}
    for id in pairs(set) do ids[#ids + 1] = id end
    local direct = {}
    for _, id in ipairs(adj[n.id] or {}) do direct[id] = true end
    local rows = {}
    for _, id in ipairs(ids) do
        local r = noderow(store, id, { direct = direct[id] or false })
        if r then rows[#rows + 1] = r end
    end
    table.sort(rows, function (x, y)
        if x.direct ~= y.direct then return x.direct end
        if tostring(x.file) ~= tostring(y.file) then return tostring(x.file) < tostring(y.file) end
        return tostring(x.line) < tostring(y.line)
    end)
    local notes = { refnote }
    if #rows > 0 then
        -- THE HEADLINE, AND EXACTLY WHAT IT QUANTIFIES OVER. A path floor would
        -- need the path, and cone.reachable is a set BFS that does not keep one
        -- — so the honest summary is the floor over EVERY ref edge inside the
        -- cone. That is weaker-or-equal to any particular path's floor, which
        -- makes it a sound lower bound rather than a claim about a route.
        local band = store.topo()
        local ts = {}
        for _, id in ipairs(ids) do
            for _, u in ipairs((dir == 'out' and store.usedby or store.uses)[id] or {}) do
                if set[u] or u == n.id then
                    local a, b = u, id
                    if dir == 'in' then a, b = id, u end
                    -- `or 'matched'` is edges_callers' own convention for an
                    -- edge whose tier the band does not carry, not a default
                    -- invented here — and it is what keeps ts non-empty
                    -- whenever rows are, so the rank check below cannot
                    -- misreport a real answer as an envelope bug.
                    ts[#ts + 1] = band:tier(a, b) or 'matched'
                end
            end
        end
        local d = disputed_note(ts)
        if d then notes[#notes + 1] = d end
        notes[#notes + 1] = { kind = 'headline-scope', premise = 'transitive-reach',
            why = ('the rows carry NO per-row rung: a cone member is reached through a CHAIN of resolutions and this verb does not keep the chain, so a null `tier` on a row means UNKNOWN, not "no rung applies". The headline is the floor over all %d ref edge(s) inside the cone — nothing here was reached by anything weaker.'):format(#ts),
            evidence = { edges = #ts, direction = dir } }
        return { subject = subject, result = rows, tier = floor_tier(ts), notes = notes }
    end

    -- EMPTY. A cone is empty exactly when the FIRST HOP is empty, so the premise
    -- that hides a neighbour is the premise that hides the whole cone: the
    -- edges_* classifiers answer this question, unchanged.
    -- NOTE THE ONE SHAPE THAT IS *NOT* SPECIAL-CASED HERE, because measuring it
    -- said not to: a purely self-recursive function. store.lua excludes a self
    -- ref edge from uses/usedby ON PURPOSE, so its first hop is EMPTY, not
    -- self-pointing — and the delegation below therefore reaches
    -- callees_empty's `only-calls-itself`, which is the same answer written
    -- once. A `self-reference-only` branch here would be a claim no caller
    -- could ever reach, which is exactly the defect CART-0580 named.
    if #ids > 0 then
        -- reached SOMETHING, and none of it had a node to render: the adjacency
        -- names ids this graph does not hold. A frontier, not an absence.
        return { subject = subject, result = {}, absence = 'frontier', absence_why = {
            premise = 'reached-ids-are-not-nodes',
            why = ('this node reaches %d id(s) through the %s adjacency and NONE of them resolves to a node in this graph — something was reached, it simply cannot be rendered'):format(#ids, dir),
            evidence = { reached = #ids, direction = dir } }, notes = notes }
    end
    notes[#notes + 1] = { kind = 'cone-is-first-hop', premise = 'delegation',
        why = ('an empty %s cone means an empty FIRST hop, so the absence below is the one %s reports for this node — not a separate judgement'):format(dir, dir == 'out' and 'edges_callees' or 'edges_callers'),
        evidence = NUL }
    if dir == 'in' then
        local absence, why, more = callers_empty(store, n)
        for _, x in ipairs(more) do notes[#notes + 1] = x end
        return { subject = subject, result = {}, absence = absence, absence_why = why,
            notes = notes }
    end
    local band = store.topo()
    local refused, external, unresolved, more, self_calls = callee_sites(band, n.id)
    for _, x in ipairs(more) do notes[#notes + 1] = x end
    local absence, why = callees_empty(n, refused, external, unresolved, self_calls)
    return { subject = subject, result = {}, absence = absence, absence_why = why,
        notes = notes }
end

-- ── verb: ladder ────────────────────────────────────────────────────────────

local function v_ladder(store, args)
    local ladder = require 'cartograph.ladder'
    local subject, n, refnote
    if (args.node and args.node ~= '') or (args.ref ~= nil and args.ref ~= NUL)
        or (args.file and args.line) then
        local badr
        n, badr, refnote = subject_node(store, args)
        if not n then return badr end
        subject = noderow(store, n.id)
    end
    local t = ladder.tally(store, n and n.id or nil)
    local rows = {}
    for _, rung in ipairs(ladder.RUNGS) do
        local c = t[rung] or 0
        if c > 0 then
            rows[#rows + 1] = { rung = rung, calls = c,
                share = math.floor((c / math.max(1, t.total)) * 1000 + 0.5) / 10 }
        end
    end
    local notes = { refnote }
    -- THE ROWS ARE COUNTS, NOT RESOLUTIONS, and they are counted in LADDER's
    -- vocabulary, which is not tier.lua's. Saying so is cheaper than an agent
    -- discovering it by comparing two verbs' strings.
    notes[#notes + 1] = { kind = 'rung-vocabulary', premise = 'ladder',
        why = "these rungs are ladder.lua's call-resolution vocabulary (confirmed/proven/linked/typed/inferred/dynamic/refused/frontier); `linked` is tier.lua's `matched`, and the two modules order linked-vs-typed differently (CART-0545). A row is a COUNT of call sites, never a resolution, so no row carries a tier.",
        evidence = { summary = ladder.summary(t), total = t.total,
            scope = n and 'function' or 'graph' } }
    if #rows > 0 then return { subject = nn(subject), result = rows, notes = notes } end

    if n then
        local band = store.topo()
        local refused, external, unresolved, more, self_calls = callee_sites(band, n.id)
        for _, x in ipairs(more) do notes[#notes + 1] = x end
        local absence, why = callees_empty(n, refused, external, unresolved, self_calls)
        return { subject = subject, result = {}, absence = absence, absence_why = why,
            notes = notes }
    end
    local g = M.graph(store)
    if g.frontier.unparsed_files > 0 then
        return { result = {}, absence = 'frontier', absence_why = {
            premise = 'unparsed-files',
            why = ('the extractor recorded no call anywhere in this graph, and %d file(s) never parsed — the distribution is empty because nothing was looked at, not because nothing calls anything'):format(g.frontier.unparsed_files),
            evidence = { unparsed_files = g.frontier.unparsed_files } }, notes = notes }
    end
    return { result = {}, absence = 'absent', absence_why = {
        premise = 'no-call-records',
        why = ('%d file(s) parsed and the extractor recorded no call at all — there is no resolution distribution because there is nothing to resolve'):format(g.counts.files),
        evidence = { files = g.counts.files } }, notes = notes }
end

-- ── verb: territory ─────────────────────────────────────────────────────────

local function v_territory(store)
    local t = store.territory()
    if not t then
        -- A MISSING PARTITION IS A CAPABILITY STATEMENT, NOT AN ABSENCE IN THE
        -- CODE. Reporting it as `unavailable` would put it in the same field an
        -- agent reads for facts about the tree, and it is a fact about us.
        return refuse('no-partition',
            'store.territory() produced no partition for this graph, so nothing was computed and nothing is claimed about which entry point owns what',
            'open a root first; graph_info reports whether this graph carries nodes at all')
    end
    local s = require('cartograph.territory').summary(t)
    local rows = {}
    for _, e in ipairs(t.entries) do
        local r = noderow(store, e, { class = 'entry', nodes = s.territories[e] or 0 })
        if r then rows[#rows + 1] = r end
    end
    table.sort(rows, function (x, y)
        if x.nodes ~= y.nodes then return x.nodes > y.nodes end
        return tostring(x.file) .. tostring(x.line) < tostring(y.file) .. tostring(y.line)
    end)
    local notes = {}
    -- ★ THE ONE THING THAT DECIDES WHETHER THIS ANSWER IS WORTH ANYTHING. With
    -- no declared entry points the partition falls back to APPARENT sources —
    -- functions nothing calls — which on a graph full of refused calls is a
    -- partition of the resolver's failures, not of the architecture.
    notes[#notes + 1] = { kind = 'entry-basis', premise = t.declared and 'declared' or 'apparent',
        why = t.declared
            and ('%d entry point(s) are DECLARED on the graph, so this partition is rooted in stated intent'):format(t.k)
            or ('no entry point is declared, so the roots are APPARENT — every function with no caller in this graph (%d of them). A refused or unresolved call leaves its target callerless, so an unresolved graph produces spurious roots and the partition is only as good as the resolution.'):format(t.k),
        evidence = { entries = t.k, declared = t.declared } }
    notes[#notes + 1] = { kind = 'shared-ground', premise = 'partition',
        why = ('%d node(s) are commons (reached by several entries), %d are core (reached by every entry), and %d are BORDERS — where a feature\'s path first meets more-shared ground, i.e. the natural API of a shared subsystem'):format(s.commons, s.core, s.borders),
        evidence = { commons = s.commons, core = s.core, borders = s.borders,
            entries = t.k } }
    if #rows > 0 then return { result = rows, notes = notes } end
    local g = M.graph(store)
    if g.frontier.unparsed_files > 0 then
        return { result = {}, absence = 'frontier', absence_why = {
            premise = 'unparsed-files',
            why = ('no entry point could be found and %d file(s) never parsed — no definition in them was extracted, so a root may be sitting in one of them'):format(g.frontier.unparsed_files),
            evidence = { unparsed_files = g.frontier.unparsed_files } }, notes = notes }
    end
    return { result = {}, absence = 'absent', absence_why = {
        premise = 'no-entry-points',
        why = 'no function or method is declared an entry point, and none is callerless either — every file parsed, so there is no root to partition from',
        evidence = NUL }, notes = notes }
end

-- ── verb: census ────────────────────────────────────────────────────────────

local function v_census(store)
    local c = require('cartograph.census').take(store.data or {})
    -- ONE ROW: the census IS the answer, the same way graph_info's rows describe
    -- the instrument. It cannot be empty, and `absences` says so by being empty.
    return { result = { c }, notes = { { kind = 'census-is-a-description',
        premise = 'instrument',
        why = 'these are counts over what was EXTRACTED. A rung with 0 calls means the resolver never landed one there; it does not mean the code has none. Read it beside graph.frontier, which says what was never looked at.',
        evidence = NUL } } }
end

-- ── verb: mentions ──────────────────────────────────────────────────────────

local function v_mentions(store, args)
    -- THE REFUSAL COMES FIRST, and mentions.lua is explicit about why: an empty
    -- mentioning() means EITHER "no file mentions this" OR "this graph has no
    -- mention index", and those are opposite claims. The thin index has none.
    if not store.has_mention_index() then
        return refuse('no-mention-index',
            'this graph carries no identifier mention index, so "no file mentions this name" would be a property of the extraction, not of the code (index_only skips the collect pass that builds it; some languages opt out with spec.name_index = false)',
            'reopen the root with a full extract, or ask edges_callers, which answers the stronger resolved-reference question')
    end
    local from
    if args.from and args.from ~= '' then
        local f, why, hits = resolve_file(store, args.from)
        if not f then return unknown_file(store, args.from, why, hits) end
        from = f
    end
    local ev = require('cartograph.mentions').evidence(store, args.name, from)
    local rows = {}
    for _, f in ipairs(ev.files) do
        rows[#rows + 1] = { file = f, resolved = ev.resolved[f] or false }
    end
    table.sort(rows, function (x, y) return x.file < y.file end)
    local defs = {}
    for _, d in ipairs(ev.defs) do
        defs[#defs + 1] = { id = d.id, kind = nn(d.kind), file = nn(d.file) }
    end
    local notes = {}
    -- THE CONTRACT, IN THE OUTPUT and not only in the module's header.
    notes[#notes + 1] = { kind = 'a-mention-is-not-a-reference', premise = 'altitude',
        why = 'a mention is an IDENTIFIER OCCURRENCE in a file. Nothing here claims the name refers to the same thing in two files, and files are reported rather than sites because the index is per (file, name) by construction — a per-line answer is not available at this altitude and is not invented.',
        evidence = { indexed_files = ev.indexed } }
    if from then
        notes[#notes + 1] = { kind = 'scope-confined', premise = 'resolution-scope',
            why = ev.confined
                and ('confined to the resolution scope of %s, because that is what the resolver does — a candidate in another scope is dropped by the id pass'):format(from)
                or ('%s was given, but this graph carries no scope partition, so the answer is CORPUS-WIDE and not the candidate set a resolver would consider'):format(from),
            evidence = { from = from, confined = ev.confined, scope = nn(ev.scope) } }
    end
    if #defs > 0 then
        notes[#notes + 1] = { kind = 'definitions-bearing-this-name', premise = 'ambiguity',
            why = ('%d definition(s) in this graph carry this name — name-level evidence is strong when there is one and weak when there are several, because nothing here says which one a mention means'):format(#defs),
            evidence = { defs = defs } }
    end
    if ev.has_calls then
        local nres = 0
        for _ in pairs(ev.resolved) do nres = nres + 1 end
        notes[#notes + 1] = { kind = 'resolved-subset', premise = 'residual',
            why = ('%d of %d mentioning file(s) hold a call by this name that RESOLVED to a definition; the residual mentions the name and resolves to nothing by it — that residual is the honest shape of name-level evidence'):format(nres, #rows),
            evidence = { resolved_files = nres, mentioning_files = #rows } }
    end
    if #rows > 0 then return { result = rows, notes = notes } end
    local g = M.graph(store)
    if g.frontier.unparsed_files > 0 then
        return { result = {}, absence = 'frontier', absence_why = {
            premise = 'unparsed-files',
            why = ('no indexed file mentions this name, but %d file(s) never parsed — the collect pass never read them, so they are not in the index at all'):format(g.frontier.unparsed_files),
            evidence = { unparsed_files = g.frontier.unparsed_files,
                indexed_files = ev.indexed } }, notes = notes }
    end
    return { result = {}, absence = 'absent', absence_why = {
        premise = 'name-not-in-any-index',
        why = ('the identifier does not occur in any of the %d indexed file(s)%s — this is the weakest question the graph answers, and it still says no'):format(
            ev.indexed, from and (' within ' .. from .. "'s resolution scope") or ''),
        evidence = { indexed_files = ev.indexed, from = nn(from) } }, notes = notes }
end

-- ── verb: externals ─────────────────────────────────────────────────────────

local function v_externals(store, args)
    local s = require('cartograph.externals').surface(store)
    local limit = math.floor(tonumber(args.limit) or 100)
    local rows = {}
    for base, b in pairs(s.bases) do
        local members, nmem = {}, 0
        for m, k in pairs(b.members or {}) do
            nmem = nmem + 1
            if #members < 8 then members[#members + 1] = { name = m, calls = k } end
        end
        table.sort(members, function (x, y) return x.calls > y.calls end)
        local files = {}
        for f in pairs(b.files or {}) do files[#files + 1] = f end
        table.sort(files)
        rows[#rows + 1] = { base = base, calls = b.calls, members = members,
            distinct_members = nmem, files = files, bare = b.bare or false,
            known = b.known or false }
    end
    table.sort(rows, function (x, y)
        if x.calls ~= y.calls then return x.calls > y.calls end
        return x.base < y.base
    end)
    local notes = {}
    notes[#notes + 1] = { kind = 'boundary-accounting', premise = 'disposition',
        why = ('of %d call(s): %d resolved inside, %d refused as ambiguous between internal candidates, %d blocked across a scope, %d landed on a stdlib tail, %d are the external surface, and %d point at a file this graph KNOWS and never read'):format(
            s.total, s.resolved, s.internal_multi, s.cross_scope, s.stdlib_tail,
            s.external, s.unread or 0),
        evidence = { total = s.total, resolved = s.resolved,
            internal_multi = s.internal_multi, cross_scope = s.cross_scope,
            stdlib_tail = s.stdlib_tail, external = s.external, unread = s.unread or 0 } }
    if (s.unread or 0) > 0 then
        notes[#notes + 1] = { kind = 'not-the-boundary', premise = 'unread-file',
            why = ('%d call(s) bind to a file this graph knows about and never parsed (a bundle, a missing grammar). They are SILENT, not external — counting them as the boundary would claim a dependency that is really our own unread code'):format(s.unread),
            evidence = { unread = s.unread } }
    end
    if #rows > limit then
        notes[#notes + 1] = { kind = 'clipped', why =
            ('%d base(s), %d returned — raise `limit` to see the rest'):format(#rows, limit),
            evidence = { bases = #rows, limit = limit } }
        for i = #rows, limit + 1, -1 do rows[i] = nil end
    end
    if #rows > 0 then return { result = rows, notes = notes } end
    local g = M.graph(store)
    if s.total == 0 then
        if g.frontier.unparsed_files > 0 then
            return { result = {}, absence = 'frontier', absence_why = {
                premise = 'unparsed-files',
                why = ('the extractor recorded no call at all, and %d file(s) never parsed — the external surface is empty because nothing was looked at'):format(g.frontier.unparsed_files),
                evidence = { unparsed_files = g.frontier.unparsed_files } }, notes = notes }
        end
        return { result = {}, absence = 'absent', absence_why = {
            premise = 'no-call-records',
            why = ('%d file(s) parsed and the extractor recorded no call — there is no boundary because nothing calls anything'):format(g.counts.files),
            evidence = { files = g.counts.files } }, notes = notes }
    end
    return { result = {}, absence = 'absent', absence_why = {
        premise = 'every-call-lands-inside',
        why = ('all %d call(s) resolved to a node in this graph or to a stdlib tail — nothing leaves it, so the external surface is genuinely empty'):format(s.total),
        evidence = { total = s.total, resolved = s.resolved } }, notes = notes }
end

-- ── verbs: THE VERSION AXIS (CART-0595) ─────────────────────────────────────
-- portability.lua produces the strongest evidence this tool has about a PORT —
-- not "this name is missing from the target", which can be a fact about a
-- partial artifact, but "the OLD environment held this name and the new one does
-- not", which is a fact about the two environments and survives both artifacts
-- being incomplete in the same way. Until now an agent could not reach any of
-- it: the tail of this file listed portability as skipped for scope.
--
-- ★ THE TWO SURFACES ARE NOT INTERCHANGEABLE, AND THAT IS WHY THERE ARE TWO
-- VERBS RATHER THAN ONE WITH A `surface` ARGUMENT. `portability_move` scores the
-- READ surface (externals.references — every dotted name a function reads and
-- this graph does not define). `portability_move_calls` scores the CALL-derived
-- requirement set. A name that is READ and never CALLED produces no call record
-- at all, so the call surface cannot see a rename of a data global — it answers
-- "0 lost" on exactly the move whose read surface answers with the worklist. An
-- agent that reaches for the wrong one concludes THERE IS NOTHING TO PORT, so
-- the summaries name the mechanism and the weak verb points at the strong one.
--
-- THEY ALSO DIFFER IN CAPABILITY, which is the structural reason a single verb
-- would be wrong. references() re-parses each function on demand (expr.of), so
-- the read diff answers on a THIN INDEX; requires() reads call records, so the
-- call diff must declare `needs_calls` and refuse there. One verb would either
-- refuse the read surface on a thin index for no reason, or hide the split from
-- graph_info's catalogue — and the catalogue is where an agent negotiates.
--
-- ★★ THE ABSENCE TAXONOMY IS THE WHOLE POINT HERE, and four outcomes that a
-- lesser envelope renders as one empty list:
--   absent       lost = 0. A REAL ANSWER: nothing this code reads was removed
--                between these two environments. The move costs nothing here.
--   frontier     no function's expressions were examined at all, so an empty
--                worklist is NO ANSWER rather than a clean bill of health.
--   unavailable  no profile of that name ships. An instrument gap, not a fact
--                about the code — and the shipped roster rides in the evidence.
--   REFUSED      the two profiles cannot be compared (different languages, an
--                INGREDIENT artifact, a profile that cannot adjudicate a dotted
--                name). portability already refuses clearly and its reason is
--                carried VERBATIM rather than being re-worded here, because the
--                sentence names the mechanism and a paraphrase would drift from
--                the one the human report prints.

--- The from/to pair, and the THREE ways it fails BEFORE any diff is attempted.
--- Returns true, or (nil, verb-result) carrying the right one of them.
---
--- WHY THE PROFILE LOOKUP HAPPENS HERE rather than being left to portability:
--- both diff functions report an unknown runtime as an error STRING, in the same
--- channel as "these two cannot be compared". Flattening them into one refusal
--- would render an instrument gap ("we ship no profile for 2.1") identically to
--- a wrong question ("these are different languages"), which is the one thing
--- this envelope exists to prevent.
local function version_pair(args)
    local port = require 'cartograph.portability'
    local pm = require 'cartograph.spec.profile'
    local missing = {}
    for _, rt in ipairs({ args.from, args.to }) do
        if not pm.load(rt) then missing[#missing + 1] = rt end
    end
    if #missing > 0 then
        local roster = port.runtimes()
        return nil, { result = {}, absence = 'unavailable', absence_why = {
            premise = 'no-such-profile',
            why = ('no environment profile named %s ships in this tree, so the move cannot be scored — this is a gap in the INSTRUMENT, not a statement that the port is clean. %d profile(s) ship: %s'):format(
                table.concat(vim.tbl_map(function (m) return ('%q'):format(m) end, missing), ' or '),
                #roster, table.concat(roster, ', ')),
            evidence = { missing = missing, shipped = roster } },
            notes = { { kind = 'ask-the-roster', premise = 'discovery',
                why = 'portability_targets lists every shipped profile with its language, its size and — for the ones that can be no target — WHY, so a from/to pair never has to be guessed at',
                evidence = NUL } } }
    end
    -- A DIFF OF A PROFILE WITH ITSELF is zero by construction, and zero by
    -- construction must not arrive wearing the same clothes as zero by
    -- measurement: `absent` here would read as "this move costs nothing".
    if args.from == args.to then
        return nil, refuse('same-profile',
            ('from and to are both %q, so every status change is zero BY CONSTRUCTION — that is arithmetic, not evidence about a port'):format(args.from),
            'pass two different profiles (portability_targets lists them); a version move is a pair like lua-factorio-11 -> lua-factorio')
    end
    return true
end

--- portability's own refusal, carried through UNFLATTENED. `reason` is its
--- sentence verbatim: it names the MECHANISM (signature-keyed, ingredient,
--- different languages) and the human report prints the same words, so a
--- paraphrase here would be a second copy free to drift from the first.
local function not_comparable(err, from, to)
    return refuse('profiles-not-comparable', err,
        'portability_targets reports which artifacts can answer a NAME question (`kinds.names`) and, for the rest, the mechanism that stops them — pick two that can, of the same language',
        { from = from, to = to })
end

--- The READ SURFACE, memoized on this graph's generation. references() re-parses
--- every function in the corpus (expr.of), so the move verb — which needs both
--- the diff and the coverage counts the diff does not return — would otherwise
--- pay for it twice per call and again on every repeat. Keyed the way M.graph's
--- memo is, on (store, generation), so an edit invalidates it.
local function refs_of(store)
    local gen = store.generation or 0
    local c = M._refs_cache
    if c and c.gen == gen and c.store == store then return c.refs end
    local refs = require('cartograph.externals').references(store)
    M._refs_cache = { gen = gen, store = store, refs = refs }
    return refs
end

--- The coverage note EVERY move answer carries, whatever the outcome. A diff is
--- a statement about the names that WERE examined, and the reader is entitled to
--- how many that was before believing an empty worklist.
local function move_notes(store, extra)
    local g = M.graph(store)
    local notes = extra or {}
    if g.frontier.unparsed_files > 0 then
        notes[#notes + 1] = { kind = 'not-everything-was-read', premise = 'unparsed-files',
            why = ('%d file(s) in this graph were never parsed (a bundle, a missing grammar, an unreadable file), so nothing they contain is in this diff either way'):format(g.frontier.unparsed_files),
            evidence = { unparsed_files = g.frontier.unparsed_files,
                examples = g.frontier.examples } }
    end
    return notes
end

local function v_portability_targets()
    local port = require 'cartograph.portability'
    local rows = {}
    for _, r in ipairs(port.target_roster()) do
        local k = r.kinds or { names = false, data = false }
        rows[#rows + 1] = { runtime = r.runtime, lang = nn(r.lang),
            size = r.size or 0, measure = nn(r.measure),
            names = k.names or false, data = k.data or false,
            reason = nn(r.reason) }
    end
    table.sort(rows, function (x, y)
        if x.names ~= y.names then return x.names end
        if x.lang ~= y.lang then return tostring(x.lang) < tostring(y.lang) end
        return x.runtime < y.runtime
    end)
    -- THE ROSTER IS A DESCRIPTION OF THE INSTRUMENT, like graph_info's and
    -- census's, and it is never empty: profiles ship with the plugin. What
    -- `targets()` would drop is kept here WITH ITS REASON, because five silently
    -- omitted artifacts is the absence-rendered-as-silence class — a caller must
    -- be able to tell "no profile covers this" from "five were skipped".
    return { result = rows, notes = { { kind = 'a-target-is-not-an-artifact',
        premise = 'capability',
        why = 'every shipped artifact is listed, including the ones that can answer no name question at all — `names` says whether it may be a from/to for portability_move, `data` whether it can answer a prototype question, and `reason` names the mechanism when it can be neither. An artifact that is no target is not a worthless file, it is the wrong key space for this question.',
        evidence = NUL } } }
end

local function v_portability_move(store, args)
    local port = require 'cartograph.portability'
    local pre, bad = version_pair(args)
    if not pre then return bad end
    local res, err = port.reference_diff(store, args.from, args.to)
    if not res then return not_comparable(err, args.from, args.to) end

    local refs = refs_of(store)
    local subject = { from = res.from, to = res.to, surface = 'reads',
        lost = #res.lost, gained = #res.gained, kept = res.kept,
        neither = res.neither, functions_examined = refs.analysed or 0 }
    local notes = move_notes(store, { { kind = 'this-is-the-read-surface',
        premise = 'surface',
        why = 'these are names a function READS and this graph does not define, scored under both profiles. The CALL surface is a different population and a weaker one for a version move: a name that is read and never invoked produces no call record, so portability_move_calls cannot see a data-global rename at all.',
        evidence = { analysed = refs.analysed or 0, unmodelled = refs.unmodelled or 0,
            withheld = refs.withheld or 0, names_scored = refs.total or 0 } } })
    if #res.gained > 0 then
        -- GAINED IS NOT LOST, and it is not silence either. It rides as a note
        -- rather than as a row because the RESULT of this verb is the port
        -- WORKLIST: a name the new environment adds is context for the move, not
        -- work in it, and mixing the two would mean an empty worklist could
        -- never be reported as such.
        local names = {}
        for i = 1, math.min(15, #res.gained) do
            names[#names + 1] = { name = res.gained[i].name, reads = res.gained[i].reads,
                now = res.gained[i].now, file = res.gained[i].file }
        end
        notes[#notes + 1] = { kind = 'gained', premise = 'direction',
            why = ('%d name(s) the NEW environment holds and the old did not — already-migrated code, or a name that moved here. Reverse `from` and `to` to make these the worklist.'):format(#res.gained),
            evidence = { gained = #res.gained, names = names } }
    end
    if (refs.withheld or 0) > 0 then
        notes[#notes + 1] = { kind = 'withheld', premise = 'binder',
            why = ('%d name(s) were WITHHELD from the read surface: their root is touched in only one function, where a loop-bound local is indistinguishable from a global until per-language binder nodes are specified'):format(refs.withheld),
            evidence = { withheld = refs.withheld } }
    end

    local rows = {}
    local cap = math.max(1, math.floor(tonumber(args.limit) or 100))
    local lost_set = res.lost -- the UNCLIPPED measurement; `rows` is the presentation
    for _, e in ipairs(res.lost) do
        rows[#rows + 1] = { name = e.name, reads = e.reads, was = nn(e.was),
            file = nn(e.file), files = e.files or {} }
    end
    if #rows > cap then
        notes[#notes + 1] = { kind = 'clipped',
            why = ('%d name(s) lost, %d returned — raise `limit` to see the rest'):format(#rows, cap),
            evidence = { lost = #rows, limit = cap } }
        for i = #rows, cap + 1, -1 do rows[i] = nil end
    end
    -- ★ THE ANSWER PATH IS CHOSEN BY THE MEASUREMENT, NOT THE PRESENTATION.
    -- `rows` has just been CLIPPED to `limit`. Branching on #rows made a real
    -- worklist render as `absence='absent'` — "the move loses nothing this code
    -- reads" — whenever the caller passed limit=0, while subject.lost still said
    -- 10. The envelope contradicted itself and the invariant did not catch it,
    -- because it checks that an empty result NAMES an absence, not that the
    -- absence is TRUE. Two guards, deliberately redundant: cap can never clip to
    -- nothing, and the branch reads the unclipped set so the two cannot diverge
    -- again if the clamp is ever removed.
    if #lost_set > 0 then return { subject = subject, result = rows, notes = notes } end

    -- NOTHING WAS EXAMINED is not the same claim as NOTHING WAS LOST. The read
    -- surface is built by re-parsing each function; if none was analysed there is
    -- no population to have lost anything FROM, and calling that `absent` would
    -- turn "no answer" into a clean bill of health.
    if (refs.analysed or 0) == 0 then
        local langs = {}
        for l, k in pairs(refs.unmodelled_langs or {}) do langs[#langs + 1] = ('%s (%d)'):format(l, k) end
        table.sort(langs)
        return { subject = subject, result = {}, absence = 'frontier', absence_why = {
            premise = 'no-function-examined',
            why = ('not one function\'s expressions were examined%s, so this empty worklist is NO ANSWER rather than a clean move — the diff had no read surface to score'):format(
                #langs > 0 and (' (%d not modelled: %s)'):format(refs.unmodelled or 0, table.concat(langs, ', ')) or ''),
            evidence = { analysed = 0, unmodelled = refs.unmodelled or 0,
                unmodelled_langs = langs,
                unparsed_files = M.graph(store).frontier.unparsed_files } },
            notes = notes }
    end
    if (refs.total or 0) == 0 then
        return { subject = subject, result = {}, absence = 'absent', absence_why = {
            premise = 'no-external-reads',
            why = ('%d function(s) were examined and none holds a qualified read of a name this graph does not define — there is no external read surface to move, so the move costs nothing HERE'):format(refs.analysed),
            evidence = { analysed = refs.analysed } }, notes = notes }
    end
    return { subject = subject, result = {}, absence = 'absent', absence_why = {
        premise = 'no-name-lost',
        why = ('%d name(s) were scored under both profiles and not one is present in %s and absent from %s — %d held by both, %d by neither, %d NEW in the target. This is a real answer: the move loses nothing this code reads.'):format(
            refs.total, res.from, res.to, res.kept, res.neither, #res.gained),
        evidence = { scored = refs.total, kept = res.kept, neither = res.neither,
            gained = #res.gained } }, notes = notes }
end

local function v_portability_move_calls(store, args)
    local port = require 'cartograph.portability'
    local pre, bad = version_pair(args)
    if not pre then return bad end
    local res, err = port.diff(store, args.from, args.to)
    if not res then return not_comparable(err, args.from, args.to) end

    local req = port.requires(store)
    local subject = { from = res.from, to = res.to, surface = 'calls',
        lost = #res.lost, gained = #res.gained, kept = res.kept,
        neither = res.neither, size_from = res.size_from, size_to = res.size_to }
    -- THE MANDATORY CAVEAT. It is not a hedge about precision: it is the
    -- population. This verb can be RIGHT and USELESS on a version move, and an
    -- agent reading `lost: 0` off it must be told which question it answered.
    local notes = move_notes(store, { { kind = 'this-is-the-call-surface',
        premise = 'surface',
        why = 'these are names this code CALLS and does not define. A name that is READ and never invoked produces no call record, so a renamed data global (the largest mechanical item in most version ports) is invisible here whatever this answer says. portability_move scores the READ surface and is the stronger question for a version move.',
        evidence = { requirement_names = req.total } } })
    notes[#notes + 1] = { kind = 'profile-weight', premise = 'artifact-size',
        why = ('the two profiles claim %d and %d symbols — a thin target inflates "lost", and a verdict against a small artifact is worth less than one against a large one'):format(
            res.size_from or 0, res.size_to or 0),
        evidence = { size_from = res.size_from or 0, size_to = res.size_to or 0 } }
    if #res.gained > 0 then
        local names = {}
        for i = 1, math.min(15, #res.gained) do
            names[#names + 1] = { name = res.gained[i].name, calls = res.gained[i].calls }
        end
        notes[#notes + 1] = { kind = 'gained', premise = 'direction',
            why = ('%d called name(s) the NEW environment holds and the old did not'):format(#res.gained),
            evidence = { gained = #res.gained, names = names } }
    end

    local rows = {}
    local cap = math.max(1, math.floor(tonumber(args.limit) or 100))
    local lost_set = res.lost -- the UNCLIPPED measurement; `rows` is the presentation
    for _, e in ipairs(res.lost) do
        rows[#rows + 1] = { name = e.name, calls = e.calls, was = nn(e.why),
            file = nn(e.file), files = e.files or {} }
    end
    if #rows > cap then
        notes[#notes + 1] = { kind = 'clipped',
            why = ('%d name(s) lost, %d returned — raise `limit` to see the rest'):format(#rows, cap),
            evidence = { lost = #rows, limit = cap } }
        for i = #rows, cap + 1, -1 do rows[i] = nil end
    end
    -- ★ THE ANSWER PATH IS CHOSEN BY THE MEASUREMENT, NOT THE PRESENTATION.
    -- `rows` has just been CLIPPED to `limit`. Branching on #rows made a real
    -- worklist render as `absence='absent'` — "the move loses nothing this code
    -- reads" — whenever the caller passed limit=0, while subject.lost still said
    -- 10. The envelope contradicted itself and the invariant did not catch it,
    -- because it checks that an empty result NAMES an absence, not that the
    -- absence is TRUE. Two guards, deliberately redundant: cap can never clip to
    -- nothing, and the branch reads the unclipped set so the two cannot diverge
    -- again if the clamp is ever removed.
    if #lost_set > 0 then return { subject = subject, result = rows, notes = notes } end
    if (req.total or 0) == 0 then
        return { subject = subject, result = {}, absence = 'absent', absence_why = {
            premise = 'no-external-call-surface',
            why = 'this graph records no call that leaves it, so there is no requirement set to move — every call resolved inside the corpus or to a stdlib tail',
            evidence = { requirement_names = 0 } }, notes = notes }
    end
    return { subject = subject, result = {}, absence = 'absent', absence_why = {
        premise = 'no-called-name-lost',
        why = ('%d called name(s) were scored under both profiles and not one is present in %s and absent from %s. READ THIS WITH ITS SURFACE: a 0 here is routine on a version move even when the port is large, because the names that change are read, never called — ask portability_move before concluding there is nothing to do.'):format(
            req.total, res.from, res.to),
        evidence = { requirement_names = req.total, kept = res.kept,
            neither = res.neither } }, notes = notes }
end

-- ── PHASE 3: THE WRITE AXIS (CART-0146) ─────────────────────────────────────
-- plan → preview → apply, plus the journal, over the two families the design
-- already called agent-shaped: moveapply (move / extract-module) and optapply
-- (cse / localize / hoist / pre).
--
-- ★ THE ORDER THE VERBS WERE BUILT IN IS THE ORDER THEY MAY BE TRUSTED IN, and
-- the ticket fixed it: plan and preview WRITE NOTHING, so they ship first and are
-- useful alone (propose a refactor, show a human the diff, no apply capability in
-- existence). journal.list/get come second — read the history before being able
-- to add to it. apply and undo come LAST.
--
-- ── WHY THERE IS A PLAN HANDLE AND NOT A PLAN DOCUMENT ──────────────────────
-- A plan carries `edit_of`, a CLOSURE (txn.lua's plan protocol, CART-0375). It
-- cannot cross a wire, and re-deriving it from a JSON copy would mean two
-- implementations of the same edit — the exact seam where a preview stops
-- describing the apply. So the plan STAYS IN THIS PROCESS and the caller holds an
-- opaque id. Three consequences, all deliberate:
--   * the handle is SESSION-scoped, like `id` and unlike `ref`. It dies with the
--     server and it dies with the generation it was planned against.
--   * `txn_preview` re-checks the generation ITSELF. txn.dryrun does not (only
--     txn.delta and txn.verify do), so a stale plan would otherwise diff today's
--     disk against yesterday's offsets and print a confident, wrong patch.
--   * the registry is CAPPED. A server that runs for a week must not accumulate
--     every plan anyone ever proposed; the oldest are dropped and an evicted id
--     refuses by name rather than resolving to something else.
--
-- ── A CAVEAT-RESOLVE IS AN ANSWER ON THE READ SIDE AND A REFUSAL ON THIS ONE ─
-- refs.resolve can land WITH a caveat: the witness drifted (the body changed),
-- the definition appears renamed, or it was matched by ordinal. Phase 2 rides
-- those as a `ref-caveat` NOTE, because a wrong answer is recoverable. Here they
-- REFUSE (rule `ref-caveat`), and the argument is not caution for its own sake —
-- txn.verify's ref rung ALREADY refuses on any resolve note (`if not rid or
-- rid ~= spec.id or note`). Planning on a caveat therefore builds a plan that can
-- only ever refuse at the last rung. Refusing at ADDRESS time surfaces the same
-- inherited decision at the point the caller can still do something about it.
--
-- ── WHAT IS *NOT* RELAXED ───────────────────────────────────────────────────
-- Nothing here re-implements the refusal ladder. `txn_apply` calls the FAMILY's
-- own apply — moveapply.apply / optapply.apply — so generation match, refs
-- resolving witness-clean, stamp CAS and no-dirty-buffers keep their single home
-- in txn.verify, and optapply's extra span-CAS and parse-clean rungs come along
-- for free. The families report their refusals as PROSE; that prose is carried
-- VERBATIM under one rule (`apply-refused`) and is never parsed back into a
-- taxonomy — scraping a message is the latent break phase 2 refused to ship.

local PLAN_CAP = 16
M._plans = {}
local plan_seq = 0

--- Hold a freshly built plan and hand back its opaque id.
local function stash_plan(store, plan, family)
    plan_seq = plan_seq + 1
    local id = ('plan-%d'):format(plan_seq)
    M._plans[id] = { id = id, seq = plan_seq, plan = plan, family = family,
        gen = plan.generation or store.generation or 0,
        root = (store.data or {}).root, previewed = false }
    local live = {}
    for _, e in pairs(M._plans) do live[#live + 1] = e end
    if #live > PLAN_CAP then
        table.sort(live, function (a, b) return a.seq < b.seq end)
        for i = 1, #live - PLAN_CAP do M._plans[live[i].id] = nil end
    end
    return id
end

--- Look a handle up. Returns (entry) or (nil, refusal). THE THREE WAYS A HANDLE
--- FAILS ARE THREE DIFFERENT RULES because the caller's next move differs: an
--- unknown id means re-plan from scratch, a stale one means the graph moved under
--- it, and a foreign one means this is not even the right project.
local function held_plan(store, id)
    local e = M._plans[id]
    if not e then
        return nil, refuse('unknown-plan',
            ('no plan %q is held by this host — a plan handle is SESSION-scoped (it dies with the server) and only the %d most recent are kept'):format(tostring(id), PLAN_CAP),
            'call txn_plan_moveset / txn_plan_optimize again and use the `plan` id from its `subject`')
    end
    if e.root ~= (store.data or {}).root then
        return nil, refuse('foreign-plan',
            ('plan %s was built against %s, and this host serves %s'):format(id, tostring(e.root), tostring((store.data or {}).root)),
            'plan against the graph you mean to edit')
    end
    if e.gen ~= (store.generation or 0) then
        return nil, refuse('stale-plan',
            ('plan %s was computed against generation %d and this graph is at %d — every line offset in it may have moved'):format(id, e.gen, store.generation or 0),
            'call the same txn_plan_* verb again against the current graph, preview the new plan, then apply that one')
    end
    return e
end

--- refs on the WRITE side. See the section comment: a caveat REFUSES here.
local function resolve_write_ref(store, ref)
    local id, why = store.resolve_ref(ref)
    if not id then return nil, stale_ref(ref, why or 'missing') end
    if why then
        return nil, refuse('ref-caveat',
            ('the ref %s::%s (%s) resolved only WITH A CAVEAT — %s — and a write is not planned on a handle that is merely probable: txn.verify refuses on the same caveat at apply time, so this plan could only ever fail at its last rung'):format(
                tostring(ref.file), tostring(ref.name), tostring(ref.kind), why),
            'take a fresh `ref` from a node_find / node_at row against the CURRENT graph and plan again; if you have checked the drift yourself, address by `node` id instead — passing an id asserts you looked',
            { why = why })
    end
    return id
end

--- the node a write verb is about. Identical addressing to subject_node except
--- for the caveat rule, which is the whole point of having a second function.
local function write_subject(store, args)
    if args.ref ~= nil and args.ref ~= NUL then
        local id, bad = resolve_write_ref(store, args.ref)
        if not id then return nil, bad end
        local n = store.node(id)
        if not n then return nil, stale_ref(args.ref, 'missing') end
        return n
    end
    return subject_node(store, args)
end

--- THE LEDGER, ON EVERY PLAN ANSWER (the ticket: "keep `declined` in every
--- result"). It rides as a NOTE rather than a new envelope field, because the
--- envelope is phase 1's contract and a per-verb field would make it per-verb.
--- The field is present even when it is EMPTY: a caller must never have to guess
--- whether nothing was declined or the ledger was simply not filled in.
---
--- THE TWO FAMILIES SPELL IT DIFFERENTLY AND THIS SAYS SO. optapply keeps a
--- `declined` list of {line, what, reason, class}; moveapply keeps `hazards`,
--- strings naming what it will NOT rewrite. Both are "the part of the job this
--- plan is not doing", and flattening one into the other would misreport which
--- question was asked.
local function ledger_notes(plan)
    local out = {}
    local dec = plan.declined
    out[#out + 1] = { kind = 'declined', premise = 'per-site refusal ledger',
        why = dec == nil
            and ('%s keeps no per-site `declined` ledger — what it will not rewrite rides in `hazards` (the note below). The field is present and empty so its absence is never ambiguous.'):format(tostring(plan.verb))
            or (#dec == 0
                and 'nothing was declined: every candidate this verb considered is in the plan'
                or ('%d site(s) were considered and DECLINED, each carrying the premise that stopped it'):format(#dec)),
        evidence = { declined = dec or {} } }
    if plan.hazards then
        out[#out + 1] = { kind = 'hazards', premise = 'disclosed-not-rewritten',
            why = #plan.hazards == 0
                and 'no hazard: the plan rewrites everything it found'
                or ('%d hazard(s) — what this plan does NOT rewrite and a human must handle'):format(#plan.hazards),
            evidence = { hazards = plan.hazards } }
    end
    return out
end

--- lines added / removed between two file texts (`false` = the file is created).
local function file_delta(before, after)
    local b = before == false and '' or (before or '')
    local a = after or b
    if b == a then return 0, 0 end
    local added, removed = 0, 0
    for _, h in ipairs(vim.diff(b, a, { result_type = 'indices' }) or {}) do
        removed = removed + h[2]
        added = added + h[4]
    end
    return added, removed
end

local function creates_list(plan)
    local out = {}
    for rel in pairs(plan.creates or {}) do out[#out + 1] = rel end
    table.sort(out)
    return out
end

local function sorted_keys(t)
    local out = {}
    for k in pairs(t or {}) do out[#out + 1] = k end
    table.sort(out)
    return out
end

-- ── verb: txn_plan_moveset ──────────────────────────────────────────────────

--- ★ THE SEED IS AN ARRAY, SO THE PHASE-2 GUARANTEE HAD TO BE EXTENDED
--- ELEMENT-WISE. "Every verb that accepts an id accepts a ref" is easy for a
--- single subject and easy to quietly drop for a list — and a list of symbols to
--- MOVE is the single place where landing on the wrong same-named sibling does
--- the most damage. Hence two typed arrays rather than one heterogeneous one:
--- `seed` of ids and `seed_refs` of refs, unioned. A JSON Schema for "string OR
--- object" is expressible but no longer publishable as one shape, and a
--- schema-driven client would have to guess which arm it holds.
local function v_txn_plan_moveset(store, args)
    local ids, seen = {}, {}
    for i, id in ipairs(args.seed or {}) do
        if type(id) ~= 'string' then
            return refuse('bad-seed',
                ('seed[%d] is a %s — the `seed` array holds node ids (strings)'):format(i, type(id)),
                'pass ids in `seed` and durable refs in `seed_refs`; the two are unioned')
        end
        if not store.node(id) then
            return refuse('unknown-node',
                ('seed[%d]: no node with id %q is in this graph'):format(i, id),
                'ids are SESSION handles and die at the next edit — take fresh ones from node_find, or pass durable refs in `seed_refs`')
        end
        if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
    end
    for i, ref in ipairs(args.seed_refs or {}) do
        if type(ref) ~= 'table' or type(ref.file) ~= 'string'
            or type(ref.name) ~= 'string' or type(ref.kind) ~= 'string' then
            return refuse('bad-seed',
                ('seed_refs[%d] is not a ref: {file, kind, name} must all be strings'):format(i),
                'copy the `ref` field of a node_find / node_at row verbatim — do not build one')
        end
        local id, bad = resolve_write_ref(store, ref)
        if not id then return bad end
        if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
    end
    if #ids == 0 then
        return refuse('no-address',
            'neither `seed` nor `seed_refs` named a symbol, so there is nothing to move',
            'pass at least one node id in `seed` or one durable ref in `seed_refs`')
    end
    local moveapply = require 'cartograph.moveapply'
    -- ★ ARM ONLY IF THIS HOST COULD EVER FIRE (CART-0583). Staging IS arming:
    -- apply's last rung compares the live move-set against plan.moves. A read-only
    -- host can never reach apply, so arming there buys nothing and COSTS a cockpit
    -- user their staged set — a verb the operator started read-only should not be
    -- reaching into session state at all. Unarmed plans still preview, because
    -- txn.dryrun reads the plan and never the staged set.
    local plan, why = moveapply.plan_moveset(store, ids, args.dest, { arm = M.WRITABLE })
    if not plan then
        return refuse('cannot-plan',
            ('no move-set plan could be built for %s: %s'):format(tostring(args.dest), tostring(why)),
            'the reason above is the verb\'s own; fix the premise it names and plan again')
    end
    local rows = {}
    for _, m in ipairs(plan.moves) do
        local row = noderow(store, m.id, { mode = m.mode,
            moves_lines = { first = m.lines.s + 1, last = m.lines.e + 1 } })
        rows[#rows + 1] = row or { id = m.id, name = m.name, file = m.file,
            mode = m.mode, ref = NUL }
    end
    local pid = stash_plan(store, plan, 'move')
    local notes = ledger_notes(plan)
    -- ★ THE STAGING SIDE EFFECT, DISCLOSED RATHER THAN HIDDEN. plan_moveset does
    -- not merely compute: it CLEARS the live move-set and re-stages its closure,
    -- because apply's last rung compares the plan against exactly that state
    -- (CART-0576). Two consequences a caller cannot see from the answer, so they
    -- ride with it: a cockpit user's staged set is gone, and planning a SECOND
    -- move-set makes the first held plan unapplyable (its stage-mismatch rung
    -- fires — a refusal, never a wrong write). And per CART-0576 note 3 a plan
    -- that refuses LATE clears the staging rather than restoring it; that defect
    -- is someone else's and is not touched here.
    if M.WRITABLE then
        notes[#notes + 1] = { kind = 'staged', premise = 'planning mutates the live move-set',
            why = ('planning re-staged %d symbol(s) as the live move-set and set the destination to %s — apply compares the plan against that state, so planning ANOTHER move-set on this host makes plan %s unapplyable (it refuses with a stage mismatch; it never writes the wrong thing)'):format(#plan.moves, tostring(plan.dest), pid),
            evidence = { staged = #plan.moves, dest = nn(plan.dest) } }
    else
        -- NOT the same claim as the one above, and they must not render alike: this
        -- host touched no session state at all, and the plan it produced can be
        -- previewed but never applied here.
        notes[#notes + 1] = { kind = 'unarmed', premise = 'read-only host: planning did not stage',
            why = ('this host is read-only, so planning left the live move-set untouched — plan %s can be previewed (txn_preview) but NOT applied here; start mcpserve with --write to arm and apply'):format(pid),
            evidence = { staged = 0, dest = nn(plan.dest) } }
    end
    return {
        subject = { plan = pid, verb = plan.verb, dest = nn(plan.dest),
            touched = plan.touched, creates = creates_list(plan),
            generation = plan.generation, previewed = false },
        result = rows, notes = notes,
    }
end

-- ── verb: txn_plan_optimize ─────────────────────────────────────────────────

local OPT_KIND = { cse = 'plan_cse', localize = 'plan_localize',
    hoist = 'plan_hoist', pre = 'plan_pre' }

--- ★ WHERE THE ABSENT/REFUSED SPLIT ON THE WRITE SIDE COMES FROM. A builder that
--- returns no plan means one of two opposite things — "this code offers no such
--- opportunity" (an ABSENCE, a fact about the source) and "the instrument could
--- not look here" (a REFUSAL, a fact about the tooling). They were previously
--- distinguishable only by reading the prose, so optapply's builders now return a
--- machine-readable `code` beside it and this branches on that, not on the words.
local function v_txn_plan_optimize(store, args)
    local n, bad = write_subject(store, args)
    if not n then return bad end
    local optapply = require 'cartograph.optapply'
    local opts = {}
    if args.target_line ~= nil then opts.line = math.floor(tonumber(args.target_line) or 0) end
    local node_row = noderow(store, n.id)
    local plan, why, code = optapply[OPT_KIND[args.kind]](store, n.id, opts)
    if not plan then
        if code == 'no-candidates' then
            return {
                subject = { plan = NUL, kind = args.kind, node = node_row,
                    verb = 'optimize-' .. args.kind },
                result = {}, absence = 'absent',
                absence_why = { premise = 'no-candidates',
                    why = ('%s: %s in %s — the analysis ran and the code offers no such opportunity'):format(args.kind, tostring(why), tostring(n.name)),
                    evidence = { node = n.id, code = code } },
                notes = { { kind = 'declined', premise = 'per-site refusal ledger',
                    why = 'no plan was built, so no site could be declined: the ledger is empty because there were no candidates, not because nothing was recorded',
                    evidence = { declined = {} } } },
            }
        end
        return refuse('cannot-plan',
            ('%s cannot be planned for %s: %s'):format(args.kind, tostring(n.name), tostring(why)),
            'this is a property of the INSTRUMENT, not of the code — the reason names which premise (an unknown node, a language with no spec, a source that would not parse)',
            { code = nn(code), node = n.id })
    end
    local notes = ledger_notes(plan)
    if #(plan.moves or {}) == 0 then
        -- candidates existed and EVERY ONE was declined. That is `refused`, and
        -- the ledger is its evidence rather than a note only.
        return {
            subject = { plan = NUL, kind = args.kind, node = node_row, verb = plan.verb },
            result = {}, absence = 'refused',
            absence_why = { premise = 'every-candidate-declined',
                why = ('%d candidate(s) were found in %s and every one was declined — this is a refusal by the verb\'s own soundness gates, NOT an absence of opportunities in the code'):format(#(plan.declined or {}), tostring(n.name)),
                evidence = { declined = plan.declined or {} } },
            notes = notes,
        }
    end
    local rows = {}
    for _, m in ipairs(plan.moves) do
        local row = { file = plan.rel }
        for k, v in pairs(m) do row[k] = v end
        rows[#rows + 1] = row
    end
    local pid = stash_plan(store, plan, 'optimize')
    return {
        subject = { plan = pid, kind = args.kind, verb = plan.verb, node = node_row,
            touched = plan.touched, generation = plan.generation, previewed = false },
        result = rows, notes = notes,
    }
end

--- ★★ THE VERB THE MEASUREMENT ASKED FOR (CART-0763 -> CART-0766 step D). A day
--- of real work was 15 commits, ZERO file moves, diffs `+158/-0` and `+130/-1`:
--- the work is INSERTION, and the write surface offered moving symbols and
--- hoisting loop-invariants. Zero of that day could have gone through the ladder
--- however reliable the ladder became — the binding constraint is
--- EDIT-VOCABULARY COVERAGE, not reliability.
---
--- ★ TWO INPUTS, ONE VERIFICATION. `member` is the text you wrote; `subs` fills
--- the container's own template holes. Both converge on "candidate text, spliced,
--- reparsed, matched against the members already there", so a caller choosing the
--- textual form gets exactly the checking the structural form gets.
local function v_txn_plan_declare(store, args)
    local n, bad = write_subject(store, args)
    if not n then return bad end
    local declare = require 'cartograph.declare'
    local subs
    if args.subs ~= nil and args.subs ~= NUL then
        subs = {}
        for k, v in pairs(args.subs) do subs[tostring(k)] = tostring(v) end
    end
    local member = (args.member ~= NUL) and args.member or nil
    if not member and not subs then
        return refuse('no-payload',
            'neither `member` nor `subs` was supplied, so there is nothing to add',
            'pass `member` with the source text you want inserted, or `subs` mapping the template\'s hole keys to their text — `node_declared` shows a container\'s holes')
    end
    local node_row = noderow(store, n.id)
    local plan, why = declare.plan(store, { node = n.id, member = member, subs = subs })
    if not plan then
        -- ⚠ A REFUSAL HERE IS USUALLY THE MOST INFORMATIVE ANSWER THE VERB GIVES,
        -- and it is not an ABSENCE: the container exists and was read. It says
        -- what the members actually look like, which is what a caller who guessed
        -- wrong needs. 54.9% of container literals with two or more members
        -- share no shape at all, so this is the DOMINANT reply, not the
        -- exceptional one.
        return refuse('does-not-fit',
            ('cannot add to %s: %s'):format(tostring(n.name), tostring(why)),
            'the reason describes the CONTAINER, not your syntax — read what its members have in common and supply one of that shape, or edit the file directly if it has no shape to match',
            { node = n.id, name = n.name })
    end
    local pid = stash_plan(store, plan, 'declare')
    return {
        subject = { plan = pid, verb = plan.verb, node = node_row,
            touched = plan.touched, generation = plan.generation, previewed = false },
        result = { { file = plan.shape.file, target = plan.target.name,
            member = plan.member } },
        notes = { { kind = 'guards', premise = 'what this plan will be checked against',
            why = 'the plan declares `parses` (the file still compiles) and `shape-preserved` (the inserted member still fits the container\'s element template, re-derived from the written text). Both run at apply and REFUSE rather than warn; neither claims the change is CORRECT.',
            evidence = { guards = plan.guards } } },
    }
end

-- ── verb: txn_preview ───────────────────────────────────────────────────────

--- ★ WHAT A GREEN PREVIEW DOES AND DOES NOT ASSERT (CART-0153 is the ticket that
--- owns this properly; this is the honest disclosure the write verbs need before
--- it lands). A preview is itself a PROJECTION, and a machine cannot see that a
--- diff was quietly partial. Two facts therefore ride on every preview: the bytes
--- come from THE SAME `plan.edit_of` the apply runs, so this is not a second
--- simulation that could drift from the first — and the apply still has four
--- late-bound rungs AFTER this diff, any of which may refuse.
local function preview_coverage_note()
    return { kind = 'preview-coverage', premise = 'the diff is a projection and has coverage',
        why = 'these bytes come from the SAME edit callback the apply runs (plan.edit_of), read off the CURRENT disk — a preview cannot drift from the apply because there is only one implementation. WHAT IT DOES NOT ASSERT: the apply runs four late-bound rungs after this diff (the graph generation still matches, every ref still resolves witness-clean, each file\'s stamp is unchanged, no buffer holds unsaved edits) and any of them may still refuse; and nothing here claims the result compiles, passes tests, or preserves behaviour.',
        evidence = { source = 'plan.edit_of',
            late_bound_rungs = { 'generation', 'refs-witness-clean', 'stamp-cas', 'no-dirty-buffers' } } }
end

local function v_txn_preview(store, args)
    local e, bad = held_plan(store, args.plan)
    if not e then return bad end
    local txn = require 'cartograph.txn'
    local before, after, err = txn.dryrun(store, e.plan)
    if not before then
        -- txn.dryrun reports its reason in the 2nd slot for a containment refusal
        -- and in the 3rd for the others; both are prose, carried verbatim
        local reason = err or (type(after) == 'string' and after) or 'the dry run produced nothing'
        return refuse('preview-refused',
            ('plan %s could not be dry-run: %s'):format(e.id, tostring(reason)),
            'the reason is the transaction layer\'s own; re-plan once its premise holds')
    end
    e.previewed = true
    local rows = {}
    for _, rel in ipairs(e.plan.touched) do
        local b, a = before[rel], after[rel]
        if a ~= nil then
            local added, removed = file_delta(b, a)
            if added + removed > 0 then
                rows[#rows + 1] = { file = rel, created = (b == false),
                    added = added, removed = removed,
                    diff = txn.difftext({ [rel] = b }, { [rel] = a }, { rel }) }
            end
        end
    end
    local notes = ledger_notes(e.plan)
    notes[#notes + 1] = preview_coverage_note()
    local subject = { plan = e.id, verb = e.plan.verb, touched = e.plan.touched,
        creates = creates_list(e.plan), generation = e.gen, previewed = true }
    if #rows == 0 then
        return { subject = subject, result = {}, absence = 'absent',
            absence_why = { premise = 'no-textual-change',
                why = ('plan %s ran over %d file(s) and every one came back byte-identical — the plan is well-formed and would write nothing'):format(e.id, #e.plan.touched),
                evidence = { touched = e.plan.touched } },
            notes = notes }
    end
    return { subject = subject, result = rows, notes = notes }
end

-- ── verb: journal_list ──────────────────────────────────────────────────────

--- METADATA ONLY, AND THAT IS A DESIGN DECISION, NOT A CLIP. A journal entry
--- holds every touched file's FULL before- and after-text — that is what makes
--- undo byte-exact — so listing them whole would put a copy of the working tree
--- on the wire for a question that asked "what happened here". journal_get serves
--- one entry's diff when a caller actually wants the bytes.
local function v_journal_list(store, args)
    local journal = require 'cartograph.journal'
    local root = (store.data or {}).root
    local entries = journal.list(root)
    local limit = math.floor(tonumber(args.limit) or 25)
    local want = args.status
    if want == '' then want = nil end
    local undo_target
    for _, e in ipairs(entries) do
        if e.status == 'applied' then undo_target = e.id break end
    end
    local rows, matched, clipped = {}, 0, 0
    for _, e in ipairs(entries) do
        if not want or e.status == want then
            matched = matched + 1
            if #rows < limit then
                rows[#rows + 1] = { id = e.id, ts = nn(e.ts),
                    when = os.date('%Y-%m-%dT%H:%M:%S', e.ts or 0),
                    verb = nn(e.verb), status = nn(e.status),
                    files = sorted_keys(e.files),
                    abort_reason = nn(e.abort_reason),
                    -- the ONE entry txn_undo would roll back, marked, so a caller
                    -- does not have to re-derive journal.last's rule
                    undoable = (e.id == undo_target) }
            else clipped = clipped + 1 end
        end
    end
    local notes = { { kind = 'metadata-only', premise = 'what these rows omit',
        why = 'these rows carry no file CONTENT: a journal entry holds the full before- and after-text of every file it touched (that is what makes undo byte-exact), and shipping it here would put a copy of the tree on the wire. Call journal_get with an `id` for one entry\'s diff.',
        evidence = { entries = #entries } } }
    if clipped > 0 then
        notes[#notes + 1] = { kind = 'clipped', premise = 'limit',
            why = ('%d further entr(ies) matched and were not returned (limit %d)'):format(clipped, limit),
            evidence = { matched = matched, limit = limit } }
    end
    if #rows == 0 then
        if want and #entries > 0 then
            return { result = {}, absence = 'absent',
                absence_why = { premise = 'no-entry-with-that-status',
                    why = ('%d journal entr(ies) exist for this root and none has status %q'):format(#entries, tostring(want)),
                    evidence = { entries = #entries, status = want } },
                notes = notes }
        end
        return { result = {}, absence = 'absent',
            absence_why = { premise = 'no-transactions',
                why = ('no transaction has ever been journalled for %s — the journal is empty, which is a fact about this root\'s history and not about the instrument'):format(tostring(root)),
                evidence = { root = nn(root) } },
            notes = notes }
    end
    return { result = rows, notes = notes }
end

-- ── verb: journal_get ───────────────────────────────────────────────────────

local function v_journal_get(store, args)
    local journal = require 'cartograph.journal'
    local root = (store.data or {}).root
    local all = journal.list(root)
    local target
    for _, e in ipairs(all) do
        if e.id == args.id then target = e break end
    end
    if not target then
        return refuse('unknown-entry',
            ('no journal entry %q for %s (%d entr(ies) recorded)'):format(tostring(args.id), tostring(root), #all),
            'call journal_list and use an `id` from one of its rows')
    end
    local txn = require 'cartograph.txn'
    local rows, nodiff = {}, {}
    for _, rel in ipairs(sorted_keys(target.files)) do
        local f = target.files[rel] or {}
        -- NOT `f.absent and false or f.before`: `x and false or y` is ALWAYS y in
        -- Lua, so a CREATED file's before-text came back nil and its diff was
        -- silently null — the one row a caller most wants to see. The journal's
        -- `false` means "this file did not exist", which is a value, not a flag.
        local b
        if f.absent then b = false else b = f.before end
        local row = { file = rel, created = f.absent or false,
            before_hash = nn(f.before_hash), after_hash = nn(f.after_hash),
            diff = NUL, added = NUL, removed = NUL }
        if f.after ~= nil and b ~= nil then
            row.diff = txn.difftext({ [rel] = b }, { [rel] = f.after }, { rel })
            row.added, row.removed = file_delta(b, f.after)
        else
            nodiff[#nodiff + 1] = rel
        end
        rows[#rows + 1] = row
    end
    local notes = {}
    if #nodiff > 0 then
        -- an entry with no after-content is not a broken record: `pending` and
        -- `aborted` entries exist precisely so a crash mid-apply leaves evidence.
        -- Saying WHICH of the two shapes this is beats a null with no explanation.
        notes[#notes + 1] = { kind = 'no-after-content', premise = 'the entry never committed',
            why = ('%d file(s) have no after-content, so no diff exists for them — the entry is %s (a pending or aborted entry keeps its BEFORE content, which is what a manual rollback needs), or it predates after-content records'):format(#nodiff, tostring(target.status)),
            evidence = { files = nodiff, status = nn(target.status) } }
    end
    local subject = { journal = target.id, verb = nn(target.verb),
        status = nn(target.status), ts = nn(target.ts),
        when = os.date('%Y-%m-%dT%H:%M:%S', target.ts or 0),
        -- the journal calls this field `plan`; it is surfaced as `desc` because
        -- on THIS surface `subject.plan` already means a live plan HANDLE, and
        -- two different things under one name is how a caller applies the wrong
        -- one. It is the apply's own description of what it did (refs, never
        -- ids — the journal's rule), kept verbatim.
        desc = nn(target.plan), abort_reason = nn(target.abort_reason) }
    if #rows == 0 then
        return { subject = subject, result = {}, absence = 'absent',
            absence_why = { premise = 'entry-touched-no-file',
                why = ('journal entry %s records no touched file'):format(target.id),
                evidence = { id = target.id } }, notes = notes }
    end
    return { subject = subject, result = rows, notes = notes }
end

-- ── verb: txn_apply ─────────────────────────────────────────────────────────

--- ★ APPLY WILL NOT WRITE A PLAN NOBODY HAS LOOKED AT. The design's flow is
--- declare → PREVIEW → hazard → confirm → apply, and on a machine transport the
--- preview step is the only thing standing between "an agent proposed an edit"
--- and "an agent made one". Requiring the same handle to have been through
--- txn_preview costs one call and turns the human-facing convention into an
--- enforced precondition. It is the ONLY precondition added here; the four
--- late-bound rungs are the family's and are untouched.
local function v_txn_apply(store, args)
    local e, bad = held_plan(store, args.plan)
    if not e then return bad end
    if not e.previewed then
        return refuse('unpreviewed',
            ('plan %s has never been diffed — txn_apply does not write bytes no caller has seen'):format(e.id),
            'call txn_preview with this same plan id, read the diff it returns, then call txn_apply again')
    end
    local entry, why
    if e.family == 'move' then
        entry, why = require('cartograph.moveapply').apply(store, e.plan)
    elseif e.family == 'declare' then
        entry, why = require('cartograph.declare').apply(store, e.plan)
    else
        local okA, ent_or_why = require('cartograph.optapply').apply(store, e.plan)
        if okA then entry = ent_or_why else why = tostring(ent_or_why) end
    end
    if not entry then
        return refuse('apply-refused',
            ('plan %s was NOT applied: %s'):format(e.id, tostring(why)),
            'nothing was written. The reason is the verb\'s own, from the late-bound ladder every apply runs (the graph generation still matches, every ref still resolves witness-clean, each file\'s stamp is unchanged, no buffer holds unsaved edits) — satisfy the premise it names and plan again',
            { plan = e.id, verb = e.plan.verb })
    end
    -- CONSUMED. An applied plan describes a tree that no longer exists; leaving
    -- the handle live would let a caller apply the same edit twice, and the
    -- second one would be caught by a stamp CAS rather than by its own name.
    M._plans[e.id] = nil
    local rows = {}
    for _, rel in ipairs(sorted_keys(entry.files)) do
        local f = entry.files[rel] or {}
        local b -- see journal_get: `f.absent and false or f.before` is a Lua trap
        if f.absent then b = false else b = f.before end
        local added, removed = file_delta(b, f.after)
        rows[#rows + 1] = { file = rel, created = f.absent or false,
            added = added, removed = removed }
    end
    local notes = ledger_notes(e.plan)
    notes[#notes + 1] = { kind = 'undo', premise = 'this write is reversible',
        why = ('journal entry %s holds every touched file\'s exact before-content; txn_undo restores them byte-for-byte, and refuses if any of them has changed since'):format(entry.id),
        evidence = { journal = entry.id } }
    return {
        subject = { plan = e.id, journal = entry.id, verb = nn(entry.verb),
            status = nn(entry.status), touched = sorted_keys(entry.files) },
        result = rows, notes = notes,
    }
end

-- ── verb: txn_undo ──────────────────────────────────────────────────────────

local function v_txn_undo(store)
    local journal = require 'cartograph.journal'
    local root = (store.data or {}).root
    local entry, why = journal.rollback(root)
    if not entry then
        return refuse('undo-refused',
            ('nothing was restored: %s'):format(tostring(why)),
            'the journal refuses a rollback that would clobber edits made since the apply — inspect the entry with journal_get, reconcile the drifted files yourself, and the entry stays available')
    end
    local touched = sorted_keys(entry.files)
    local notes = {}
    -- the graph must be re-read or every later answer describes bytes that are
    -- no longer on disk; a refusal here is reported, never swallowed
    local okr, rok, rwhy = pcall(require('cartograph.refresh').files, touched)
    if not okr or not rok then
        notes[#notes + 1] = { kind = 'stale-graph', premise = 'files restored, graph not re-read',
            why = ('the files are restored on disk but the graph refresh refused (%s) — every answer from this host now describes the PRE-undo bytes until the graph is re-read'):format(tostring(okr and rwhy or rok)),
            evidence = { files = touched } }
    end
    local rows = {}
    for _, rel in ipairs(touched) do
        local f = entry.files[rel] or {}
        rows[#rows + 1] = { file = rel,
            restored = f.absent and 'deleted' or 'before-content',
            -- an apply that CREATED the file undoes to its deletion, never to an
            -- empty husk (journal.lua's own rule, surfaced so a caller sees it)
            created_by_the_apply = f.absent or false }
    end
    if #rows == 0 then
        return { subject = { journal = entry.id, verb = nn(entry.verb) },
            result = {}, absence = 'absent',
            absence_why = { premise = 'entry-touched-no-file',
                why = ('journal entry %s was rolled back and recorded no touched file'):format(entry.id),
                evidence = { id = entry.id } }, notes = notes }
    end
    return {
        subject = { journal = entry.id, verb = nn(entry.verb),
            status = nn(entry.status), touched = touched },
        result = rows, notes = notes,
    }
end

-- ── THE VERB TABLE ──────────────────────────────────────────────────────────
-- `absences` lists the absence values a verb can actually produce. It is
-- documentation an agent can read, and it is a standing question to the next
-- implementer: a value listed here that no branch emits is CART-0580 again.

--- THE ADDRESSING ARGUMENTS, declared ONCE and shared by every verb that is
--- about a node. THREE WAYS IN, and they are not equivalent:
---   node  the SESSION id — exact, free, and dead the moment the file is edited
---   ref   the DURABLE handle from the same row — survives edits, survives a
---         rename by witness, and REFUSES (rule `stale-ref`) rather than landing
---         on the wrong node when it cannot tell same-named siblings apart
---   file+line  a position, resolved to the innermost enclosing function
--- Sharing the table is not just brevity: it is what guarantees a verb added
--- later cannot accidentally accept an id without also accepting a ref.
local ADDRESS = {
    { name = 'node', type = 'string', desc = 'an `id` from a node_find / node_at row (this graph generation only)' },
    { name = 'ref', type = 'object', shape = 'ref',
        desc = 'or the DURABLE `ref` from the same row — {file, kind, name, ordinal?, witness?}; a ref that no longer resolves REFUSES with rule `stale-ref` rather than guessing' },
    { name = 'file', type = 'string', desc = 'or address by position: path' },
    { name = 'line', type = 'integer', desc = 'or address by position: 1-based line inside a function' },
}

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
        tier_basis = 'resolution', tier_headline = 'floor', needs_calls = true,
        absences = { 'absent', 'refused', 'frontier' },
        args = ADDRESS,
        run = v_edges_callers,
    },
    edges_callees = {
        summary = 'what this calls — each row with its own resolution tier; refused and external sites ride as notes',
        tier_basis = 'resolution', tier_headline = 'floor', needs_calls = true,
        absences = { 'absent', 'refused', 'frontier' },
        args = ADDRESS,
        run = v_edges_callees,
    },
    why = {
        summary = 'the honesty record for what is at file:line — how a call resolved, or which rule refused it',
        -- `why` answers about ONE position, so its result is one row and floor
        -- and peak coincide. Declaring the floor anyway keeps the field total:
        -- an agent never has to special-case a missing quantifier.
        tier_basis = 'mixed', tier_headline = 'floor', needs_calls = true,
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

    -- ── the analysis catalogue ──────────────────────────────────────────────

    clones_find = {
        summary = 'duplicated code: exact structural clone GROUPS and near-clone PAIRS with the value holes that would become a shared helper\'s parameters',
        tier_basis = 'observation',
        absences = { 'absent', 'frontier', 'unavailable' },
        needs_calls = true,
        args = {
            { name = 'kind', type = 'string', enum = { 'exact', 'near' },
                desc = 'restrict to exact groups or near pairs (default: both)' },
            { name = 'limit', type = 'integer', desc = 'max groups (default 50); a clip is reported as a note' },
        },
        run = v_clones_find,
    },
    cone = {
        summary = 'everything reachable from a node, transitively — direction `out` (what it reaches) or `in` (what reaches it)',
        -- NOT 'observation' and NOT 'resolution'. A cone member was reached
        -- THROUGH resolutions, so a null row tier would be a lie if it meant
        -- "no rung applies"; but the path is not kept, so a per-row rung would
        -- be invented. The rows carry no tier, the HEADLINE is the floor over
        -- the cone's edge set, and a mandatory note says exactly that.
        tier_basis = 'resolution', tier_headline = 'floor', needs_calls = true,
        absences = { 'absent', 'refused', 'frontier' },
        args = (function ()
            local a = { { name = 'direction', type = 'string', enum = { 'out', 'in' },
                desc = "`out` = what this reaches (default); `in` = what reaches this" } }
            for _, x in ipairs(ADDRESS) do a[#a + 1] = x end
            return a
        end)(),
        run = v_cone,
    },
    ladder = {
        summary = 'the call-resolution distribution — how many call sites landed on each rung, for one function or the whole graph',
        tier_basis = 'observation', needs_calls = true,
        -- NOT 'refused', deliberately. A refused call site is itself a RUNG in
        -- this distribution, so a function whose every site was refused comes
        -- back with rows, never empty — and a value listed here that no branch
        -- can emit is the CART-0580 defect this field exists to prevent. The
        -- same argument retires the `calls-leave-the-graph` frontier: those
        -- sites land on the `dynamic` and `frontier` rungs. What is left is an
        -- unparsed source, and a graph with no call record at all.
        absences = { 'absent', 'frontier' },
        args = ADDRESS, -- all optional: no address = the whole graph
        run = v_ladder,
    },
    territory = {
        summary = 'the architecture by reachability: which entry point owns each node, plus commons, core and the borders between them',
        tier_basis = 'observation', needs_calls = true,
        -- NOT 'unavailable': the one branch that could produce it is a missing
        -- partition, which is a refusal (see v_territory).
        absences = { 'absent', 'frontier' },
        args = {},
        run = v_territory,
    },
    census = {
        summary = "the graph's epistemic state as counts: edges by trust tier, calls by disposition, refusals by rule, the outside-the-corpus buckets",
        tier_basis = 'observation', needs_calls = true,
        -- a census of the instrument, like graph_info: it is never empty
        absences = {},
        args = {},
        run = v_census,
    },
    mentions = {
        summary = 'which FILES mention an identifier — the weaker, name-level question that still answers when resolution refused',
        tier_basis = 'observation',
        absences = { 'absent', 'frontier' },
        args = {
            { name = 'name', type = 'string', required = true, desc = 'the identifier to look for' },
            { name = 'from', type = 'string', desc = 'the asking file — confines the answer to its resolution scope, which is what a resolver would consider' },
        },
        run = v_mentions,
    },
    externals = {
        summary = 'the external surface: every call base that leaves this graph, with its members, its files and how the boundary was decided',
        tier_basis = 'observation', needs_calls = true,
        absences = { 'absent', 'frontier' },
        args = {
            { name = 'limit', type = 'integer', desc = 'max bases (default 100); a clip is reported as a note' },
        },
        run = v_externals,
    },

    -- ── the version axis (CART-0595) ────────────────────────────────────────

    portability_targets = {
        summary = 'the environment profiles that ship, and what each can ANSWER — the from/to vocabulary for portability_move; an artifact that can be no target carries the mechanism that stops it',
        tier_basis = 'observation',
        -- a description of the INSTRUMENT, like graph_info and census: profiles
        -- ship with the plugin, so this roster is never empty and an absence
        -- value listed here would be one no branch could emit (CART-0580).
        absences = {},
        args = {},
        run = v_portability_targets,
    },
    portability_move = {
        summary = 'THE VERSION MOVE, over the READ surface: names this code reads that the OLD environment held and the NEW one does not — the port worklist. This is the strong one; a renamed data global (global.x -> storage.x) lives here and nowhere else',
        tier_basis = 'observation',
        -- NO `needs_calls`, and that is measured rather than assumed: the read
        -- surface is built by re-parsing each function on demand (expr.of), so
        -- this answers on a THIN INDEX. Declaring the capability would refuse a
        -- perfectly answerable question — the mirror of the CART-0580 defect.
        --
        -- `absent`      lost = 0. A REAL ANSWER: nothing read here was removed.
        -- `frontier`    no function was examined, so the empty worklist is no
        --               answer rather than a clean move.
        -- `unavailable` no profile of that name ships — an instrument gap.
        -- NOT 'refused': two profiles that cannot be compared is a REFUSAL of
        -- the verb (rule `profiles-not-comparable`), carrying portability's own
        -- sentence verbatim, never an empty result.
        absences = { 'absent', 'frontier', 'unavailable' },
        args = {
            { name = 'from', type = 'string', required = true,
                desc = 'the OLD environment profile (portability_targets lists them; a name that does not ship answers `unavailable`, never a clean 0)' },
            { name = 'to', type = 'string', required = true,
                desc = 'the NEW environment profile — same language as `from`, and both must be able to adjudicate a DOTTED name or the diff refuses' },
            { name = 'limit', type = 'integer', desc = 'max lost names (default 100); a clip is reported as a note' },
        },
        run = v_portability_move,
    },
    portability_move_calls = {
        summary = 'the same move over the CALL-derived requirement set — THE WEAKER QUESTION. A name that is READ and never invoked produces no call record, so a data-global rename is invisible here and this verb can answer "0 lost" on a large port. Ask portability_move first; use this only when you specifically mean CALLED names',
        -- requires() reads the call records, so unlike portability_move this one
        -- genuinely cannot answer on a thin index.
        tier_basis = 'observation', needs_calls = true,
        -- NOT 'frontier': the read verb's frontier is "no function examined",
        -- which has no counterpart here — a graph with no call records at all is
        -- already refused by `thin-index`, and one with calls that all land
        -- inside is an ANSWER (premise `no-external-call-surface`).
        absences = { 'absent', 'unavailable' },
        args = {
            { name = 'from', type = 'string', required = true,
                desc = 'the OLD environment profile (portability_targets lists them)' },
            { name = 'to', type = 'string', required = true, desc = 'the NEW environment profile' },
            { name = 'limit', type = 'integer', desc = 'max lost names (default 100); a clip is reported as a note' },
        },
        run = v_portability_move_calls,
    },

    -- ── the write axis (CART-0146) ──────────────────────────────────────────
    -- EVERY ONE OF THESE IS tier_basis='observation', AND THAT IS THE HONEST
    -- ANSWER RATHER THAN A DEFAULT. A plan's rows are PROPOSED EDITS read off the
    -- parse — a line, a span, a name — so no rung on tier.LADDER applies and
    -- `tier` is always null, meaning "this question has no rung". The write
    -- side's honesty is carried by two other things instead: the `declined` /
    -- `hazards` ledger on every plan answer, and the late-bound refusal ladder
    -- the apply runs. CART-0143's "a verb with no honest tier stays out of T3"
    -- fork does NOT fire here: these verbs have a tier_basis that fits, and it is
    -- the one that says a rung would be invented.

    txn_plan_moveset = {
        summary = 'PROPOSE moving symbols to another file (or into a new one — an existing dest is a MOVE, a path that does not exist yet is an EXTRACT-MODULE). Writes nothing: returns a plan handle for txn_preview',
        tier_basis = 'observation', needs_calls = true,
        -- never empty: the seed is caller-supplied and every way of having no
        -- symbol to move is a refusal (unknown id, stale ref, no address), so an
        -- absence value listed here would be one no branch can emit.
        absences = {},
        args = {
            { name = 'seed', type = 'array', items = 'string',
                desc = 'node ids to move (from a node_find / node_at row, this graph generation only)' },
            { name = 'seed_refs', type = 'array', items_shape = 'ref',
                desc = 'or the DURABLE refs from the same rows; unioned with `seed`. A ref that no longer resolves REFUSES (`stale-ref`), and one that resolves only WITH A CAVEAT also refuses (`ref-caveat`) — on the write side a probable handle is not good enough' },
            { name = 'dest', type = 'string', required = true,
                desc = 'destination path, relative to the graph root. An existing file = MOVE; a new path = EXTRACT-MODULE. A path escaping the root is refused' },
        },
        run = v_txn_plan_moveset,
    },
    txn_plan_optimize = {
        summary = 'PROPOSE an optimizer rewrite inside one function (cse | localize | hoist | pre). Writes nothing: returns a plan handle for txn_preview, plus the per-site `declined` ledger',
        tier_basis = 'observation', needs_calls = true,
        -- `absent`  the analysis ran and the code offers no candidate
        -- `refused` candidates existed and every one failed a soundness gate
        -- and NOT 'frontier'/'unavailable': an unparsable source or a language
        -- with no spec is a REFUSAL here (rule `cannot-plan`), because it is a
        -- property of the instrument that must not read as "nothing to do".
        absences = { 'absent', 'refused' },
        args = (function ()
            local a = {
                { name = 'kind', type = 'string', required = true,
                    enum = { 'cse', 'localize', 'hoist', 'pre' },
                    desc = 'cse = reuse a redundant computation; localize = bind an in-loop global to a local; hoist = lift a loop-invariant statement; pre = hoist a computation common to both arms of an exhaustive if/else' },
                { name = 'target_line', type = 'integer',
                    desc = 'target ONE finding or loop by its 1-based line (omit for every clean candidate in the function). NOT the same as `line`, which addresses the FUNCTION' },
            }
            for _, x in ipairs(ADDRESS) do a[#a + 1] = x end
            return a
        end)(),
        run = v_txn_plan_optimize,
    },
    txn_plan_declare = {
        summary = 'PROPOSE adding a member to a declared container (a table/array/object literal). Writes nothing: returns a plan handle for txn_preview',
        tier_basis = 'observation', needs_calls = false,
        -- never empty: the container is caller-supplied and every way of having
        -- nothing to add to is a REFUSAL (unknown symbol, no literal in its
        -- range, members that share no shape), so an absence listed here would
        -- be one no branch can emit
        absences = {},
        args = {
            { name = 'node', type = 'string',
                desc = 'the declared symbol whose value is the container (from a node_find / node_at row, this graph generation only)' },
            { name = 'ref', type = 'ref',
                desc = 'or the DURABLE ref from the same row; a ref that no longer resolves REFUSES (`stale-ref`), and one resolving only WITH A CAVEAT also refuses (`ref-caveat`) — on the write side a probable handle is not good enough' },
            { name = 'member', type = 'string',
                desc = 'TEXTUAL: the member source you want inserted, exactly as it should read (`subscript_list = true`). It is parsed and matched against the members already there, so a payload of the wrong shape REFUSES and names the divergence' },
            { name = 'subs', type = 'object',
                desc = 'STRUCTURAL: fill the container\'s template holes instead of writing the member yourself, mapping each hole key to its source TEXT. Cartograph renders from a real member, so indentation and quote style come from the file rather than from a guess' },
        },
        run = v_txn_plan_declare,
    },
    txn_preview = {
        summary = 'the exact diff a held plan would write, per file, and nothing written — the same edit callback the apply runs',
        tier_basis = 'observation',
        -- `absent` = a well-formed plan whose edits produce no textual change.
        absences = { 'absent' },
        args = {
            { name = 'plan', type = 'string', required = true,
                desc = 'a plan handle from a txn_plan_* answer\'s `subject.plan` (session-scoped: it dies with this host and with the graph generation it was planned against)' },
        },
        run = v_txn_preview,
    },
    journal_list = {
        summary = 'the transaction history for this root, newest first — metadata only (id, when, verb, status, files); journal_get serves the bytes',
        tier_basis = 'observation',
        absences = { 'absent' },
        args = {
            { name = 'limit', type = 'integer', desc = 'max entries (default 25); a clip is reported as a note' },
            { name = 'status', type = 'string',
                enum = { 'pending', 'applied', 'aborted', 'rolled_back' },
                desc = 'restrict to entries in this state' },
        },
        run = v_journal_list,
    },
    journal_get = {
        summary = 'one journal entry in full: its per-file diff, hashes and status — what a transaction actually did',
        tier_basis = 'observation',
        absences = { 'absent' },
        args = {
            { name = 'id', type = 'string', required = true, desc = 'an `id` from a journal_list row' },
        },
        run = v_journal_get,
    },
    txn_apply = {
        summary = 'WRITE a held plan to disk, journalled and reversible. Refuses unless the plan has been through txn_preview, and runs the full late-bound ladder before any byte moves',
        tier_basis = 'observation', needs_calls = true, mutates = true,
        -- never empty on success: an applied plan touched at least one file.
        absences = {},
        args = {
            { name = 'plan', type = 'string', required = true,
                desc = 'the same plan handle txn_preview was called with' },
        },
        run = v_txn_apply,
    },
    txn_undo = {
        summary = 'roll back the newest applied transaction, restoring every touched file byte-exact — and REFUSE the whole rollback if any of them has changed since',
        tier_basis = 'observation', mutates = true,
        absences = { 'absent' },
        args = {},
        run = v_txn_undo,
    },
}

M.ORDER = ORDER

--- the JSON Schema fragment for a durable ref, in ONE place: it is published
--- both as a scalar argument (`ref`) and as an array's items (`seed_refs`).
function M.ref_schema()
    return {
        properties = {
            file = { type = 'string', description = 'the file the definition was in when the ref was minted' },
            kind = { type = 'string', description = 'node kind (function, method, var, …)' },
            name = { type = 'string', description = 'the definition name' },
            ordinal = { type = 'integer', description = 'which same-named sibling, when there were several' },
            witness = { type = 'string', description = 'behaviour hash — follows a rename, and drifts when the body changes' },
        },
        required = { 'file', 'kind', 'name' },
    }
end

--- MCP inputSchema for a verb (JSON Schema draft-07 object).
function M.schema(verb)
    local v = M.VERBS[verb]
    if not v then return nil end
    local props, req = {}, {}
    for _, a in ipairs(v.args) do
        local p = { type = a.type, description = a.desc }
        if a.type == 'array' then p.items = { type = a.items or 'string' } end
        if a.enum then p.enum = a.enum end
        -- A REF IS A SHAPE, NOT A BLOB. Publishing its five fields is what lets
        -- a schema-driven client hand back the `ref` it was given, unedited,
        -- instead of reducing it to a string and inventing a parser for it.
        -- `items_shape` is the same fact one level down: a write verb's SEED is
        -- an array of refs, and an array whose items are an untyped object would
        -- undo exactly that guarantee for the case that matters most.
        if a.shape == 'ref' then
            for k, v2 in pairs(M.ref_schema()) do p[k] = v2 end
        elseif a.items_shape == 'ref' then
            p.items = M.ref_schema()
            p.items.type = 'object'
        end
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
            elseif a.type == 'object' and type(got) ~= 'table' then
                return ('%s.%s must be an object, got %s'):format(verb, a.name, type(got))
            end
            if a.enum and got ~= '' and not vim.tbl_contains(a.enum, got) then
                return ('%s.%s must be one of %s, got %q'):format(verb, a.name,
                    table.concat(a.enum, ' | '), tostring(got))
            end
            -- A MALFORMED REF IS A FAULT IN THE CALL, NOT A STALE HANDLE. Those
            -- must not render the same: `stale-ref` says "this graph moved on",
            -- and an agent's correct response is to re-address. A ref missing
            -- `name` never addressed anything, and re-addressing will not help.
            if a.shape == 'ref' and type(got) == 'table' then
                for _, k in ipairs({ 'file', 'kind', 'name' }) do
                    if type(got[k]) ~= 'string' then
                        return ('%s.%s is not a ref: `%s` must be a string. A ref is {file, kind, name, ordinal?, witness?} — copy the `ref` field of a node_find / node_at row verbatim, do not build one'):format(verb, a.name, k)
                    end
                end
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

    -- PERMISSION BEFORE CAPABILITY, and the order is the point (CART-0146). A
    -- read-only host refuses a write verb whatever the graph looks like, so
    -- asking about the call graph first would answer a question the caller is not
    -- allowed to reach — and `thin-index`'s remedy ("reopen the root without
    -- --index-only") would send them down a road that ends in this refusal anyway.
    if v.mutates and not M.WRITABLE then
        return refusal { rule = 'read-only',
            reason = ('%s writes to the tree, and this host was started without write permission — nothing was planned, diffed or written'):format(verb),
            remedy = 'start the host with --write (nvim --headless -u NONE -l tools/mcpserve.lua <root> --write). Planning and previewing need no permission: txn_plan_* and txn_preview answer on a read-only host, so a proposal and its diff can be produced and reviewed before anyone grants the power to apply it' }
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

    -- EVERY ROW THAT NAMES A NODE GETS ITS DURABLE HANDLE, here and nowhere else
    -- (CART-0145). One place means a verb added later cannot forget; after the
    -- verb ran means the witness hash is paid only for rows that survived a
    -- clip. `members` is walked because a clone group's rows ARE nodes.
    attach_refs(store, result)
    for _, r in ipairs(result) do
        if type(r) == 'table' then attach_refs(store, r.members) end
    end
    if type(res.subject) == 'table' then
        attach_refs(store, { res.subject })
        -- a write verb's subject is the PLAN, and the node it is about hangs one
        -- level in — so the durable handle reaches it too, and a caller can
        -- re-address the same function after the apply changed the ids
        if type(res.subject.node) == 'table' then attach_refs(store, { res.subject.node }) end
    end

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

-- ── WHAT IS DELIBERATELY NOT A VERB, AND WHY (CART-0145) ────────────────────
-- The ticket's rule: where a capability exists only as report() lines, LEAVE IT
-- OUT rather than parsing them. A missing verb is honest; a scraped one is a
-- latent break that ships green and fails the first time someone reflows a
-- string. The list is part of the deliverable, so it lives here rather than in a
-- commit message:
--
--   classify        THERE IS NO SUCH CAPABILITY. No :Cartograph* command, no
--                   module verb. The three `M.classify` functions in the tree
--                   (prologue, wraptriage, feedback) are private helpers of
--                   other analyses over unrelated domains, and clones has
--                   classify_blocks — a step inside the block-clone report, not
--                   a question anyone asks. Wrapping any of them would invent a
--                   verb rather than expose one.
--   trace           STRUCTURED and worth doing (trace.origins / .expand / .row
--                   return records, not lines) — skipped for scope, not for
--                   honesty. It needs an argument the other verbs do not have,
--                   a PARAMETER INDEX, and its rows are provenance chains whose
--                   absence taxonomy deserves its own sitting.
--   versionfloor    STRUCTURED (facts / group return records) and skipped for
--                   scope. It takes no profile pair, so it does not share the
--                   capability-negotiation surface the version axis needed; it
--                   is one dispatch entry plus its own absence taxonomy (a
--                   corpus whose language has no version SCALE must not report
--                   "no floor" as though the code used nothing new).
--   portability     THE VERSION AXIS IS NOW HERE (CART-0595) — portability_targets
--   audit/rank      / portability_move / portability_move_calls, above. This
--   manifest        paragraph used to say portability was skipped for scope, and
--                   leaving that standing after the verbs landed would be the
--                   exact defect CART-0595 is about: a stale caveat costs more
--                   than a missing feature, because it stops the next reader
--                   running a mechanism that is already here.
--                   STILL OUT, and for scope rather than honesty: the SINGLE-
--                   TARGET questions — audit ("will it run on X"), rank ("which
--                   shipped environment is tightest") and manifest ("who provides
--                   what"). They answer a different question from a MOVE and each
--                   needs its own absence taxonomy: an audit's empty finding list
--                   is genuinely ambiguous between "this profile provides
--                   everything" and "this artifact models almost nothing", which
--                   is a distinction the diff does not have to make and they do.
--
-- The distinction matters: `classify` is skipped because wrapping it would be a
-- fabrication, the rest because the sitting ran out. Only the first is a
-- statement about the code.
--
-- ── AND ON THE WRITE AXIS (CART-0146) ───────────────────────────────────────
--   txn_redo        journal.redo is shipped and :CartographRedo drives it. The
--                   ticket names apply + undo, and a redo verb is one dispatch
--                   entry away — left out for scope, not for honesty. Note that
--                   its refusal shape differs from undo's (it checks
--                   BEFORE-content, and refuses an entry that predates
--                   after-records), so it deserves its own spec rather than a
--                   copy of undo's.
--   clone-merge     clonemerge/cloneextract are a third apply family and ride the
--                   same txn substrate, so the plan handle and txn_preview /
--                   txn_apply already fit them unchanged. Only their PLAN verb is
--                   missing; adding it is one entry plus its absence taxonomy.
--   the `copy` set  moveapply's extract-module takes an opts.copy set (duplicate
--                   rather than move). Not exposed: it is an extract-only option
--                   that the MOVE branch refuses, so publishing it needs the
--                   verb-dependent-argument shape none of these schemas have yet,
--                   and a silently-ignored argument would be worse than none.
--   txn_clear       abandoning a staged transaction is a cockpit affordance
--                   (:CartographTxnClear) over store.set_txn, and these verbs do
--                   not use the store's staged-txn slot at all — the plan
--                   registry here is separate on purpose (see stash_plan). There
--                   is nothing for an agent to clear that dropping the handle
--                   does not already do.

return M
