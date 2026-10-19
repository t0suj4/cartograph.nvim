-- A CUT: the node set an analysis was pointed at, plus the granularity it was cut
-- at (CART-0514, step 3 of [[cartograph-scope-boundaries]]).
--
-- ★★ WHY IT IS NOT CALLED `scope`, AND THE NAME COST ME A SHIPPED MODULE.
-- `cartograph.scope` is ALREADY TAKEN by the per-file LEXICAL scope model
-- (`spec.lexical_scopes`, then named `spec.scopes`: which node types open a scope, binders, shadow chains) -- and I
-- wrote this file over it. The collision is the exact one recorded that morning in
-- [[cartograph-scope-model]]: `spec.scopes` (plural, lexical binders) and
-- `spec.scope` (singular, a file's resolution boundary) differed by one letter and
-- meant unrelated things, "expect to be asked about one and reach for the other".
-- (Renamed 2026-09-28, CART-1160 step 7: the plural is now `spec.lexical_scopes`.)
-- Reaching for the other is what happened. So the third thing gets a third name: a
-- CUT is neither of those two -- it is what an ENTRY POINT supplies to an
-- ANALYSIS, and the verb is what an entry point does to the graph.
--
-- THE CLAIM THIS FILE TESTS. cartograph has ~10 scope-shaped mechanisms
-- (spec.scope, spec.lexical_scopes, the working set, bands, the corpus root, narrow,
-- apertures, repo shapes, index_only, the move-set's `travels`) that differ only
-- in ORIGIN and each hand-roll their own boundary behaviour. The design says scope
-- is not a new axis but a PIPELINE STAGE THAT ALREADY EXISTS —
--
--     subject → altitude (node set) → band → lens → overlay → surface
--
-- — where the altitude stage already emits the node set, and the only gap is that
-- this pipeline feeds RENDERING and never feeds ANALYSIS. If that is right, then
-- constructing a scope from the browser's current frame is a lookup rather than a
-- computation. It is: `of_frame` below is twenty lines and reads the same
-- `altitudes` registry the pane navigates with.
--
-- WHAT A SCOPE IS NOT: a rule filter. `lint.run`'s `opts.only` chooses WHICH RULES
-- RUN; a scope chooses WHAT THEY RUN OVER. Conflating them is the confusion this
-- design dissolves, and two of the six lint entry points pass `only` today.
--
-- GRANULARITY IS RECORDED, not inferred later, because it is what CART-0512 needs:
-- a promise whose denominator is CLOSED inside the scope (a function's own
-- parameter list, a guard search within one function) is clip-legal after all, and
-- deciding that needs to know whether the cut was at `fn`, `file` or wider.

local atr = require 'cartograph.at'
local altitudes = require 'cartograph.panes.altitudes'

local M = {}

-- ★★ A CUT IS ITS MEMBERS; EXTENTS ARE ANCHORS (user, 2026-10-20: "cut.lua's extents are too specific and probably
-- won't survive outside files or buffers"; the rule it applies is 2026-09-26's, [[derive-never-list]]: "a scope is
-- ANY node set — a path prefix is one anchor kind"). A cut was `spans = { {file, sl, el} }`: a node with no file —
-- a Java bean keyed by class name — could not be cut at all (of_node returned nil, and a working set holding one
-- silently lost it), and nothing could ask about a subject that is not a line in a file. Now:
--   members   the node ids the cut was made from — what it IS;
--   anchors   where its members live, DERIVED per anchor KIND (M.ANCHORS): `text` = { doc, sl, el }, a document's
--             line range, the doc a file path or a buffer's name — one kind among those a provider may register
--             (a resource path, a URI, a JSON pointer);
--   unlocated the members no kind could anchor: kept and NAMED, never dropped.
-- Membership is asked of a SUBJECT (M.has): a node — by identity, then through its own anchors — or an anchor.

--- The granularity ladder, coarsest last. A scope CONTAINS another when its own
--- granularity is at least as coarse and its spans cover it.
M.GRAINS = { node = 1, fn = 2, region = 2, file = 3, set = 4, corpus = 5 }

-- ★ `var` IS ITS OWN GRAIN, not `fn`. A var-cut's span is the variable's own
-- extent -- often a single line -- so calling it `fn` would tell lint.CLOSURE the
-- cut holds a whole function when it holds one binding, and a promise closed over
-- a function would clip inside it and FABRICATE. `node` is unlisted in CLOSURE, so
-- no promise ever clips there: the wrong answer in this direction invents findings,
-- the wrong answer in the other only loses them.
local KIND_GRAIN = { ['function'] = 'fn', method = 'fn', region = 'region',
    tbl = 'region', module = 'file', var = 'node' }

--- A document's identity as cuts compare it: relative to the world's root (rules report absolute and relative paths
--- alike — normalising here beats asking 33 rules to agree)
function M.doc(store, d)
    if type(d) ~= 'string' then return d end
    local root = store and store.data and store.data.root
    if root and d:sub(1, #root + 1) == root .. '/' then return d:sub(#root + 2) end
    return d
end

--- THE ANCHOR KINDS: `of(store, node)` -> the node's anchors of this kind (a list, maybe empty); `covers(store, a,
--- subject)` -> does anchor a hold the subject anchor (of the same kind)? A provider registers its own kind here.
M.ANCHORS = {
    text = {
        of = function (store, n)
            if not (n.file and n.range) then return {} end
            return { { kind = 'text', doc = M.doc(store, n.file), sl = atr.sl(n.range), el = atr.el(n.range) } }
        end,
        covers = function (store, a, s)
            if M.doc(store, a.doc) ~= M.doc(store, s.doc) then return false end
            local sl, el = s.sl or s.line, s.el or s.line
            return sl ~= nil and sl >= a.sl and el <= a.el
        end,
    },
}
local KINDS = { 'text' } -- (in a fixed order: anchors are listed deterministically)

--- every anchor of a node, over every registered kind
function M.anchors_of(store, n)
    local out = {}
    local kinds = {}
    for _, k in ipairs(KINDS) do kinds[#kinds + 1] = k end
    for k in pairs(M.ANCHORS) do if not vim.tbl_contains(KINDS, k) then kinds[#kinds + 1] = k end end
    for _, k in ipairs(kinds) do for _, a in ipairs(M.ANCHORS[k].of(store, n) or {}) do out[#out + 1] = a end end
    return out
end

--- A scope over one node's own extent.
--- @return table { grain, label, members = { id }, anchors, unlocated }
function M.of_node(store, id)
    local n = id and store.node(id)
    if not n then return nil end
    if n.kind == 'module' and n.file then return M.of_file(store, n.file) end
    local anchors = M.anchors_of(store, n)
    return {
        grain = KIND_GRAIN[n.kind] or 'fn',
        label = ('%s %s'):format(KIND_GRAIN[n.kind] or 'node', n.name or id),
        members = { id }, anchors = anchors, unlocated = #anchors == 0 and { id } or {},
    }
end

--- A scope over a whole file. `el = math.huge` rather than the module node's own
--- end line: a module range can stop short of the file (a container region, an
--- unparsed tail), and a scope that silently excludes the last function would
--- under-report while LOOKING complete. Its member is the file's module node when the graph has one.
function M.of_file(store, file)
    if not file then return nil end
    local members = {}
    for _, n in ipairs(store and store.by_file and store.by_file[file] or {}) do
        if n.kind == 'module' then members[#members + 1] = n.id end
    end
    return { grain = 'file', label = 'file ' .. file, members = members, unlocated = {},
        anchors = { { kind = 'text', doc = M.doc(store, file), sl = 0, el = math.huge } } }
end

--- A scope over an explicit node SET (the working set, a move-set, an axis's
--- members). Grain is `set`: the members need not nest, so nothing finer can be
--- claimed about the cut.
function M.of_nodes(store, ids, label)
    local members, anchors, unlocated = {}, {}, {}
    for _, id in ipairs(ids or {}) do
        local one = M.of_node(store, id)
        if one then
            for _, m in ipairs(one.members) do members[#members + 1] = m end
            for _, a in ipairs(one.anchors) do anchors[#anchors + 1] = a end
            for _, u in ipairs(one.unlocated) do unlocated[#unlocated + 1] = u end
        end
    end
    if #members == 0 then return nil end
    return { grain = 'set', label = label or ('set of %d'):format(#members),
        members = members, anchors = anchors, unlocated = unlocated }
end

--- THE SCOPE OF THE BROWSER'S CURRENT FRAME — the whole point of the exercise.
--- `symbols.view.level` plus the key `altitudes.key_of` reads out of the same view
--- table the pane navigates with; no new state, no new bookkeeping. An altitude
--- that is a ROOT (`files`, `ws`, `protos`) has no subject to cut at, so it yields
--- nil and the caller falls back to the corpus — which is honest: standing at the
--- file tree, "here" IS everything.
function M.of_frame(store, level, key)
    if not level or not key then return nil end
    if level == 'file' then return M.of_file(store, key) end
    -- ★ THE WORKING SET IS A CUT (CART-0520). It is the one "root" altitude with a
    -- subject after all -- a user-declared node set is exactly what an entry point
    -- supplies, and `of_nodes` existed with no caller until this line. Standing at
    -- `ws`, `:CartographLint!` runs over the symbols you marked. Grain is `set`,
    -- which lint.CLOSURE does not list, so promise rules still refuse: an
    -- arbitrary union of nodes holds nobody's whole search space.
    if level == 'ws' then
        local ids = {}
        for _, n in ipairs(store.ws_list and store.ws_list() or {}) do
            if n and n.id then ids[#ids + 1] = n.id end
        end
        return M.of_nodes(store, ids, ('working set (%d)'):format(#ids))
    end
    if level == 'files' or level == 'protos' then return nil end
    -- a relation/data altitude's key is not a node id; its SUBJECT is, and the
    -- containment registry already knows how to get there
    if store.node(key) then return M.of_node(store, key) end
    local e = altitudes.of(level)
    if e and e.up then
        local lvl2, key2 = e.up(key, store)
        if lvl2 and key2 and lvl2 ~= level then return M.of_frame(store, lvl2, key2) end
    end
    return nil
end

--- Is a SUBJECT inside this cut? A subject is a node id, `{ node = id }`, or an anchor `{ kind, … }`. A node is in when
--- it is a member, or when one of its anchors lies in one of the cut's anchors of the same kind; an anchor when it lies
--- in one. No cut holds everything.
function M.has(store, sc, subj)
    if not sc then return true end
    if type(subj) == 'string' then subj = { node = subj } end
    local cands = {}
    if subj.node then
        for _, m in ipairs(sc.members or {}) do if m == subj.node then return true end end
        local n = store.node(subj.node)
        cands = n and M.anchors_of(store, n) or {}
    else cands = { subj } end
    for _, s in ipairs(cands) do
        local kind = M.ANCHORS[s.kind]
        if kind then
            for _, a in ipairs(sc.anchors or {}) do
                if a.kind == s.kind and kind.covers(store, a, s) then return true end
            end
        end
    end
    return false
end

--- Is a finding at `file`:`line` inside this scope? `line` is 1-BASED (findings are), text anchors 0-based (node
--- ranges are). The text kind's adapter, kept for the callers that locate by file and line.
function M.contains(store, sc, file, line)
    if not sc then return true end
    if not file then return false end
    return M.has(store, sc, { kind = 'text', doc = file, line = (tonumber(line) or 1) - 1 })
end

--- The documents a cut can hold a text subject in (a pass that walks files walks only these), sorted.
function M.docs(sc)
    local seen, out = {}, {}
    for _, a in ipairs(sc and sc.anchors or {}) do
        if a.kind == 'text' and a.doc and not seen[a.doc] then seen[a.doc] = true; out[#out + 1] = a.doc end
    end
    table.sort(out)
    return out
end

return M
