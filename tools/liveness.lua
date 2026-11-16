-- liveness — ORACLE x CORPUS: did each oracle SPEAK, and over how much? (CART-1927)
--
-- "Every oracle states its POPULATION and whether it SPOKE. … One collector renders ORACLE x CORPUS x
-- spoke/declined/silent … A SILENT ORACLE MARKS EXACTLY WHERE BUGS WOULD NOT BECOME OBVIOUS" (CART-0626). The matrix
-- grid says OK / FAIL / ~ / --, and never how much an OK looked at, so an oracle that ran over nothing (CART-0622,
-- CART-0624: instruments that stopped reporting without saying so) was a green cell. Each matrix cell now carries
-- `p = { n, unit }` — the line the oracle owes — and this is the one collector over them (not a peer tool):
--   spoke     a verdict (OK / FAIL / ~) over a population > 0 — its range, with the unit
--   declined  `--`, grouped by the reason the cell gave ("(no reason given)" is itself listed)
--   SILENT    a verdict over a population of 0: it looked at nothing and still answered
--   UNSTATED  a verdict that owed a population and gave none
--   FLAT      the same population on 3+ corpora whose own sizes differ 2x+: a number that does not move when the input
--             grows has not been exercised
-- SILENT / UNSTATED / FLAT are SOFT failures. `mem` is a measurement of the run, not an oracle over a population.
-- FIRST RUN found two dead instruments the grid showed as normal: `fold` declining on every corpus since flow is
-- folded at production (CART-2105), and `xlang` FAILing on every row that also ran `par` (fixed in the same commit).

local M = {}

M.EXEMPT = { mem = true }

--- rows: the matrix's completed row results ({ corpus, items, cells = { [col] = { s, d, p } } }); cols: column order.
--- -> table: col -> { spoke = { { corpus, n, unit, items } }, declined = { why -> { corpus } }, dorder, silent, unstated }
function M.collect(rows, cols)
    local live = {}
    for _, res in ipairs(rows) do
        for _, col in ipairs(cols) do
            local cr = res.cells and res.cells[col]
            if cr and not M.EXEMPT[col] and cr.s ~= 'SAVED' and cr.s ~= 'NOBASE' then
                local L = live[col]
                if not L then L = { spoke = {}, declined = {}, dorder = {}, silent = {}, unstated = {} }; live[col] = L end
                if cr.s == '--' then
                    local why = (type(cr.d) == 'table' and cr.d[1]) or '(no reason given)'
                    if not L.declined[why] then L.declined[why] = {}; L.dorder[#L.dorder + 1] = why end
                    table.insert(L.declined[why], res.corpus)
                elseif type(cr.p) ~= 'table' or type(cr.p.n) ~= 'number' then
                    L.unstated[#L.unstated + 1] = res.corpus
                elseif cr.p.n == 0 then
                    L.silent[#L.silent + 1] = res.corpus
                else
                    L.spoke[#L.spoke + 1] = { corpus = res.corpus, n = cr.p.n, unit = cr.p.unit, items = res.items }
                end
            end
        end
    end
    return live
end

--- the FLAT verdict for one oracle's spoken entries -> (n, unit, items_lo, items_hi) | nil
function M.flat(spoke)
    if #spoke < 3 then return nil end
    local n = spoke[1].n
    for _, e in ipairs(spoke) do if e.n ~= n then return nil end end
    local lo, hi = math.huge, 0
    for _, e in ipairs(spoke) do
        if e.items then lo = math.min(lo, e.items); hi = math.max(hi, e.items) end
    end
    if lo > 0 and hi > 0 and hi >= 2 * lo then return n, spoke[1].unit, lo, hi end
    return nil
end

--- -> lines, soft (true when any oracle is SILENT, UNSTATED or FLAT)
function M.render(rows, cols)
    local live, soft = M.collect(rows, cols), false
    local out = { 'oracle liveness — what each oracle LOOKED AT (spoke / declined / SILENT / UNSTATED / FLAT):' }
    for _, col in ipairs(cols) do
        local L = live[col]
        if L then
            local parts = {}
            if #L.spoke > 0 then
                local lo, hi = math.huge, 0
                for _, e in ipairs(L.spoke) do lo = math.min(lo, e.n); hi = math.max(hi, e.n) end
                parts[#parts + 1] = ('spoke %d (%s %s)'):format(#L.spoke, lo == hi and tostring(lo) or (lo .. '..' .. hi),
                    tostring(L.spoke[1].unit))
                local fn, fu, ilo, ihi = M.flat(L.spoke)
                if fn then
                    parts[#parts + 1] = ('FLAT: %d %s on every corpus while they range %d..%d items'):format(fn, tostring(fu), ilo, ihi)
                    soft = true
                end
            end
            for _, why in ipairs(L.dorder) do
                parts[#parts + 1] = ('declined %d [%s]'):format(#L.declined[why], why)
            end
            if #L.silent > 0 then parts[#parts + 1] = 'SILENT: ' .. table.concat(L.silent, ' '); soft = true end
            if #L.unstated > 0 then parts[#parts + 1] = 'UNSTATED: ' .. table.concat(L.unstated, ' '); soft = true end
            out[#out + 1] = ('  %-8s %s'):format(col, table.concat(parts, ' · '))
        end
    end
    return out, soft
end

return M
