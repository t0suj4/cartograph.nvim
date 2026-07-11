-- REFUSED-RECORD INTERNING: the frontier detail, deduplicated. A refusal
-- ({rule, cands?, n?, witness?, row?}) is immutable once resolution ends —
-- resolution CLEARS c.refused (field replacement), never mutates the
-- record — and ambiguous names refuse identically at every call site, so
-- the same record repeats massively (server: 87k refusals, 10.7k unique,
-- 8.1x). Interning by content key shares one record per distinct refusal:
-- ~19 MB on server, ZERO reader migration (the shape is unchanged, the
-- browser keeps full candidate detail), and c.refused = nil still works
-- per call. Same ingest slot as the argv/df/at folds; idempotent; fresh
-- refusals (refresh) intern into the same pool on re-ingest.

local M = {}

-- The pool is LOCAL to one pass (no pinning of records whose refusals a
-- later oracle resolves away); each ingest re-derives it in ~ms and a
-- re-run after refresh dedups fresh refusals into that run's pool.
function M.intern(data)
    local pool = {}
    local shared = 0
    for _, c in ipairs(data.calls or {}) do
        local r = c.refused
        if r then
            local k = (r.rule or '') .. '\31' .. (r.n or '') .. '\31'
                .. (r.witness or '') .. '\31' .. (r.row or '') .. '\31'
                .. (r.cands and table.concat(r.cands, '\30') or '')
            local hit = pool[k]
            if hit then
                if hit ~= r then
                    c.refused = hit
                    shared = shared + 1
                end
            else
                pool[k] = r
            end
        end
    end
    return shared
end

return M
