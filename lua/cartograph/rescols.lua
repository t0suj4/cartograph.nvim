-- RESCOLS — the IN-RESOLUTION columnar call store (record-fold arc, the gitlab-
-- peak lever). callcols.lua is the POST-resolution resident store; this is its
-- pre-ingest twin, the representation that survives resolution (M.audit +
-- M.relink + the resolve passes) so the parallel parent never has to hold raw
-- call records at the merge peak. It composes:
--   * callcols over the call SCALARS, with the resolution-phase schema
--     (segment.CALL_SYN_RESOLVE / CALL_RES_RESOLVE) — `full` is MUTABLE here
--     because resolve_returns rewrites it (rtfull);
--   * argvcols for the argv sub-records (columnar, with the k/to/up overlay).
-- A composite row-handle serves `c.argv` from the argv store and every scalar
-- field from the columns/overlay/residual — a drop-in for a raw call record
-- through the whole resolution pipeline. Resolution writes that hit an IMMUTABLE
-- (parse-fixed) column ASSERT — the loud net that proves the partition complete.
--
-- FOUNDATION scope: this is the primitive + a parity gate (tools/rescolgate.lua)
-- proving resolution is behaviour-identical on records vs columns. The proxy is
-- the compat shim (heavy: one handle per call + per argv element); the live wiring
-- reads columns index-form (no handles) and is the follow-on that inherits this
-- proven partition — the callcols brick-3 lesson (proxy proves, index ships).

local callcols = require 'cartograph.callcols'
local argvcols = require 'cartograph.argvcols'
local segment = require 'cartograph.segment'

local M = {}

M.SYN = segment.CALL_SYN_RESOLVE
M.RES = segment.CALL_RES_RESOLVE

-- the call-scalar read/write rules are SHARED with callcols (proxy_index/
-- proxy_newindex over the same { cc, i, res, cov } backing); rescols only layers
-- the `argv` special-case (served from the argv store; never replaced wholesale).
local row_mt = {
    __index = function (self, key)
        local st = rawget(self, '__rc')
        if key == 'argv' then return argvcols.argv_of(st.av, st.i) end
        return callcols.proxy_index(st, key)
    end,
    __newindex = function (self, key, v)
        local st = rawget(self, '__rc')
        assert(key ~= 'argv', 'rescols: argv array replacement is unsupported')
        callcols.proxy_newindex(st, key, v)
    end,
}

-- a full drop-in view of a call-record list for the RESOLUTION phase. Returns
-- { cc, av, rows, residual, covered }: `rows` is behaviourally identical to the
-- raw calls through audit/relink, backed by columns + argv columns.
function M.view(calls)
    local cc = callcols.build(calls, M.SYN, M.RES)
    local cov = callcols.covered(cc)
    local av = argvcols.build(calls)
    local residual, rows = {}, {}
    for i = 1, #calls do
        local extra
        for key, v in pairs(calls[i]) do
            -- argv is served from the argv store; everything the columns/overlay
            -- don't cover rides the residual (mutable, faithful).
            if key ~= 'argv' and not cov[key] then extra = extra or {}; extra[key] = v end
        end
        residual[i] = extra
        rows[i] = setmetatable({ __rc = { cc = cc, av = av, i = i, res = extra, cov = cov } }, row_mt)
    end
    return { cc = cc, av = av, rows = rows, residual = residual, covered = cov }
end

-- reconstruct call i's full record (scalar columns + overlay + residual + argv)
function M.record(view, i)
    local out = callcols.record_resid(view.cc, i, view.residual[i])
    local argv = argvcols.materialize(view.av, i)
    if argv then out.argv = argv end
    return out
end

return M
