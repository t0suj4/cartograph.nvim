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
-- ⚠ THE KEY IS THE RECORD'S WHOLE CONTENT, derived from the record, never a list of fields: a field left out makes two
-- different refusals ONE. The listed key (rule, n, witness, row, cands) silently dropped the higher-order rule's
-- `owner`/`param` (CART-1495: every call through a parameter read as a call through the FIRST one's — the matcher's
-- `k` became a CPS walker's in another file) and erlvariants' `macro`. A table-valued field other than `cands` keys by
-- identity: it shares only with itself.
local function key_of(r)
    local ks = {}
    for f in pairs(r) do if f ~= 'cands' then ks[#ks + 1] = f end end
    table.sort(ks)
    local parts = {}
    for i, f in ipairs(ks) do parts[i] = f .. '=' .. tostring(r[f]) end
    return table.concat(parts, '\31') .. '\31' .. (r.cands and table.concat(r.cands, '\30') or '')
end
M._key_of = key_of

function M.intern(data)
    local pool = {}
    local shared = 0
    for _, c in ipairs(data.calls or {}) do
        local r = c.refused
        if r then
            local k = key_of(r)
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
