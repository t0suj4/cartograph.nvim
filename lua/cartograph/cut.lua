-- A CUT: the node set an analysis was pointed at, plus the granularity it was cut
-- at (CART-0514, step 3 of [[cartograph-scope-boundaries]]).
--
-- ★★ WHY IT IS NOT CALLED `scope`, AND THE NAME COST ME A SHIPPED MODULE.
-- `cartograph.scope` is ALREADY TAKEN by the per-file LEXICAL scope model
-- (`spec.scopes`: which node types open a scope, binders, shadow chains) -- and I
-- wrote this file over it. The collision is the exact one recorded that morning in
-- [[cartograph-scope-model]]: `spec.scopes` (plural, lexical binders) and
-- `spec.scope` (singular, a file's resolution boundary) differ by one letter and
-- mean unrelated things, "expect to be asked about one and reach for the other".
-- Reaching for the other is what happened. So the third thing gets a third name: a
-- CUT is neither of those two -- it is what an ENTRY POINT supplies to an
-- ANALYSIS, and the verb is what an entry point does to the graph.
--
-- THE CLAIM THIS FILE TESTS. cartograph has ~10 scope-shaped mechanisms
-- (spec.scope, spec.scopes, the working set, bands, the corpus root, narrow,
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

--- A scope over one node's own extent.
--- @return table { grain, label, spans = { {file, sl, el} } }  (0-based lines)
function M.of_node(store, id)
    local n = id and store.node(id)
    if not n or not n.file then return nil end
    if n.kind == 'module' then return M.of_file(store, n.file) end
    return {
        grain = KIND_GRAIN[n.kind] or 'fn',
        label = ('%s %s'):format(KIND_GRAIN[n.kind] or 'node', n.name or id),
        spans = { { file = n.file, sl = atr.sl(n.range), el = atr.el(n.range) } },
    }
end

--- A scope over a whole file. `el = math.huge` rather than the module node's own
--- end line: a module range can stop short of the file (a container region, an
--- unparsed tail), and a scope that silently excludes the last function would
--- under-report while LOOKING complete.
function M.of_file(_, file)
    if not file then return nil end
    return { grain = 'file', label = 'file ' .. file,
        spans = { { file = file, sl = 0, el = math.huge } } }
end

--- A scope over an explicit node SET (the working set, a move-set, an axis's
--- members). Grain is `set`: the members need not nest, so nothing finer can be
--- claimed about the cut.
function M.of_nodes(store, ids, label)
    local spans = {}
    for _, id in ipairs(ids or {}) do
        local one = M.of_node(store, id)
        for _, s in ipairs(one and one.spans or {}) do spans[#spans + 1] = s end
    end
    if #spans == 0 then return nil end
    return { grain = 'set', label = label or ('set of %d'):format(#spans),
        spans = spans }
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

--- Is a finding inside this scope? `line` is 1-BASED (findings are), spans are
--- 0-based (node ranges are), and `file` may be absolute or relative because the
--- rules are not consistent about it — normalising here rather than asking 33
--- rules to agree is the cheap correct move.
function M.contains(store, sc, file, line)
    if not sc then return true end
    if not file then return false end
    local rel = file
    local root = store.data and store.data.root
    if root and rel:sub(1, #root) == root then
        rel = rel:sub(#root + 2)
    end
    local l0 = (tonumber(line) or 1) - 1
    for _, s in ipairs(sc.spans) do
        if s.file == rel and l0 >= s.sl and l0 <= s.el then return true end
    end
    return false
end

return M
