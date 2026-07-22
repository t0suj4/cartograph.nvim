-- CALLCOLS PARITY — the faithfulness gate for the resident columnar call-store
-- (record-fold arc, brick 3, [[cartograph-record-fold-arc]]). The cache round-
-- trip proves the WIRE form (segment) is byte-faithful; this proves the RESIDENT
-- form (callcols) is a behaviour-faithful DROP-IN for `data.calls`. It is the
-- resident analog of the graphdiff-empty cache invariant — the safe gate that
-- must go GREEN before the live swap replaces `data.calls`, so a half-migrated
-- owner can never strand the store silently.
--
-- The contract (an INVARIANT, not a pinned census — 0 mismatches always):
--   * COLUMN faithfulness  callcols.record(cc,i) == calls[i] over the covered
--                          (schema union) fields — the pure column readback;
--   * PROXY faithfulness   callcols.view(calls).rows[i][k] == calls[i][k] for
--                          EVERY record field k (covered → column, else residual)
--                          — the compat row-handle is a perfect drop-in.
-- Plus the honest COVERAGE disclosure (no silent caps): which fields the columns
-- carry vs which ride the residual, with per-field row counts — the work-list of
-- what brick 3 still owes a column (detail tables argv/at/refused + lang marks).
--
-- Pure over an already-extracted `data`; the CLI wrapper is tools/callgate.lua.
--   local cp = dofile('tools/callparity.lua')
--   local r = cp.check(data);  for _, l in ipairs(cp.report(r)) do print(l) end
--   -- r.mismatches == {} is the gate; r.residual is the coverage disclosure

local callcols = require 'cartograph.callcols'
local segment = require 'cartograph.segment'
local colparity = require 'cartograph.colparity'

local M = {}

-- flag fields round-trip as truthiness, not identity (a record may store explicit
-- `method = false`; a column's false↔nil is the same value consumers test with
-- `if callrec.<flag>(c)`). The veq/feq rules are the shared colparity core.
local FLAG = {}
for _, f in ipairs(segment.CALL_SYNTACTIC.flags or {}) do FLAG[f] = true end
for _, f in ipairs(segment.CALL_RESOLUTION.flags or {}) do FLAG[f] = true end
local feq = colparity.mkfeq(FLAG)

--- Run the parity check over already-extracted `data`. Returns
--- { n, mismatches = { {i, field, kind} }, residual = { [field] = rows },
---   covered = { [field] = rows }, resfields = n_distinct_residual_fields }.
--- No calls → a trivially-green result (n=0).
function M.check(data)
    local calls = data.calls or {}
    local n = #calls
    local view = callcols.view(calls)
    local cc, cov = view.cc, view.covered
    local mismatches = {}
    local residual, covered = {}, {}

    local function bad(i, field, kind)
        mismatches[#mismatches + 1] = { i = i, field = field, kind = kind }
    end

    for i = 1, n do
        local rec, proxy = calls[i], view.rows[i]
        -- 1. column readback == record, over covered fields
        local rebuilt = callcols.record(cc, i)
        for f in pairs(cov) do
            if not feq(f, rebuilt[f], rec[f]) then bad(i, f, 'column') end
        end
        -- 2. proxy round-trips EVERY record field (covered or residual)
        for k, v in pairs(rec) do
            if not feq(k, proxy[k], v) then bad(i, k, 'proxy') end
            if cov[k] then covered[k] = (covered[k] or 0) + 1
            else residual[k] = (residual[k] or 0) + 1 end
        end
    end

    local resfields = 0
    for _ in pairs(residual) do resfields = resfields + 1 end
    return { n = n, mismatches = mismatches, residual = residual,
        covered = covered, resfields = resfields }
end

--- Render a check result as report lines. The gate is `#r.mismatches == 0`;
--- the coverage block is the honest disclosure of what still rides the residual.
function M.report(r)
    local L = { ('callcols parity: %d call(s) · %d mismatch(es) · %d residual field(s)')
        :format(r.n, #r.mismatches, r.resfields) }
    -- coverage disclosure (sorted, columns first then residual)
    local function block(tbl, title)
        local keys = {}
        for k in pairs(tbl) do keys[#keys + 1] = k end
        if #keys == 0 then return end
        table.sort(keys, function (a, b) return tbl[a] > tbl[b] or (tbl[a] == tbl[b] and a < b) end)
        L[#L + 1] = title
        for _, k in ipairs(keys) do L[#L + 1] = ('    %-14s %d'):format(k, tbl[k]) end
    end
    block(r.covered, '  columnar (folded into u32 columns):')
    block(r.residual, '  residual (not yet columnar — brick-3 work-list):')
    if #r.mismatches > 0 then
        L[#L + 1] = ''
        L[#L + 1] = ('  MISMATCHES (first %d):'):format(math.min(#r.mismatches, 30))
        for i = 1, math.min(#r.mismatches, 30) do
            local m = r.mismatches[i]
            L[#L + 1] = ('    call #%d field %q (%s readback)'):format(m.i, m.field, m.kind)
        end
    end
    return L
end

return M
