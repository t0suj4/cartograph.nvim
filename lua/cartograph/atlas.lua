-- The STATE ATLAS: every module var classified by its use-edge facts —
-- the write axis (rw), guard summaries (gw) and param predicates (gp)
-- composed into a state-discipline map ([[cartograph-write-axis]]):
--
--   const          no function writes it (init-time writes are not use
--                  edges, so 'const' means constant AFTER load)
--   dead           written, never read — dead state (or dynamic access
--                  the graph can't see: the ~ hedge, always spoken)
--   set-once       every write edge is all-set-once (gw=3): init-shaped
--                  state, writes COMMUTE
--   single-writer  one owning fn writes, others only read — an ownership
--                  invariant worth knowing when it breaks
--   multi-writer   contended state: the reorder/race attention list
--   unclassified   some use edge carries no rw (a language without the
--                  write classifier) — unknown, never guessed
--
-- Pure consumer: no extraction change, every fact already in the graph.

local M = {}

M.LABELS = { 'const', 'dead', 'set-once', 'single-writer', 'multi-writer',
    'unclassified' }

--- Classify one var by its use edges. Returns
--- { label, nr, nw, writers = {fn ids}, gw = min guard tier of writes }.
function M.classify(store, id)
    local nr, nw, unk, gwmin = 0, 0, false, nil
    local writers = {}
    for _, u in ipairs(store.var_usedby[id] or {}) do
        local rw = u.rw
        if not rw then
            unk = true
        else
            if rw == 1 or rw == 3 then nr = nr + 1 end
            if rw >= 2 then
                nw = nw + 1
                writers[nw] = u.from
                local g = u.gw or 1
                if not gwmin or g < gwmin then gwmin = g end
            end
        end
    end
    local label
    if unk then label = 'unclassified'
    elseif nw == 0 then label = 'const'
    elseif nr == 0 then label = 'dead'
    elseif gwmin == 3 then label = 'set-once'
    elseif nw == 1 then label = 'single-writer'
    else label = 'multi-writer' end
    return { label = label, nr = nr, nw = nw, writers = writers, gw = gwmin }
end

--- The whole graph's census: counts per label + the var lists.
--- Synthetic/browse-only vars (sql entities, C interface types) excluded,
--- mirroring the resolver's own var vocabulary.
function M.census(store)
    local counts, vars = {}, {}
    for _, l in ipairs(M.LABELS) do counts[l] = 0; vars[l] = {} end
    local total = 0
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'var' and not n.sql and not n.ctype
            and n.id:sub(1, 5) ~= 'sql::' then
            total = total + 1
            local c = M.classify(store, n.id)
            counts[c.label] = counts[c.label] + 1
            table.insert(vars[c.label], { id = n.id, name = n.name,
                file = n.file, nr = c.nr, nw = c.nw })
        end
    end
    return { total = total, counts = counts, vars = vars }
end

return M
