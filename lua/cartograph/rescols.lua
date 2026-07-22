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

-- ── STREAMING ACCUMULATOR (record-fold step 2 — the parent-merge peak lever) ──
-- The parent folds each worker chunk's calls into COLUMNS as it arrives and drops
-- the chunk's records, so it never materializes the full record array at the merge
-- peak (the finish-time view was measured +50% because records+columns coexist;
-- this never builds the records). Composes callcols.new_colacc (call scalars, argv
-- served separately so skip_argv) + argvcols.new_acc, with merge_chunk's per-file
-- dedup (a demanded file's duplicate chunk is skipped) and canonicalize's reorder
-- (chunks arrive racy → finalize sorts rows to fileset order, so the store matches
-- the inline/records path by construction). finalize() returns a store shaped like
-- rescols.view's { cc, av, residual, covered } — a drop-in for callview.of (index-
-- form resolution) and M.record. opts.fileorder = file -> canonical rank.
--
--   local acc = rescols.accumulator({ fileorder = fidx })
--   acc.add(chunk.calls)  -- per chunk; the records can then be dropped
--   local store = acc.finalize(); data._callstore = store
function M.accumulator(opts)
    local fileorder = opts and opts.fileorder
    local cacc = callcols.new_colacc(M.SYN, M.RES, { residual = true, skip_argv = true })
    local aacc = argvcols.new_acc()
    local files, seen, n = {}, {}, 0
    local self = {}
    function self.add(calls)
        for _, rec in ipairs(calls or {}) do
            if not seen[rec.file] then
                n = n + 1
                files[n] = rec.file
                cacc.add(rec)
                aacc.add(rec)
            end
        end
        -- mark files arrived AFTER the batch (a file lives in one chunk
        -- contiguously — all its calls are added before it counts as seen),
        -- exactly like parallel.merge_chunk's per-file `seen`
        for _, rec in ipairs(calls or {}) do seen[rec.file] = true end
    end
    function self.finalize()
        local perm
        if fileorder then
            perm = {}
            for i = 1, n do perm[i] = i end
            table.sort(perm, function (a, b)
                local fa = fileorder[files[a]] or math.huge
                local fb = fileorder[files[b]] or math.huge
                if fa ~= fb then return fa < fb end
                return a < b -- stable: preserve within-file (arrival) order
            end)
        end
        local cc, residual = cacc.finalize(perm)
        local av = aacc.finalize(perm)
        return { cc = cc, av = av, residual = residual, covered = callcols.covered(cc) }
    end
    return self
end

-- reconstruct call i's full record (scalar columns + overlay + residual + argv)
function M.record(view, i)
    local out = callcols.record_resid(view.cc, i, view.residual[i])
    local argv = argvcols.materialize(view.av, i)
    if argv then out.argv = argv end
    return out
end

return M
