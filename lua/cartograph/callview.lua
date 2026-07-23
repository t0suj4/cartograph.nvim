-- CALLVIEW — a representation-neutral CALL accessor for the RESOLUTION phase (the
-- record-fold PEAK arc's substrate). Resolution (M.audit, M.relink, the resolve
-- passes) reads/writes calls through ONE cv so it runs INDEX-FORM over the
-- columnar store (data._callstore, a rescols view — no proxies, no record tables:
-- the peak path) when the parent holds one, else over raw records (the default).
-- This is the inline accessor prologue audit proved, extracted so relink + the 13
-- passes share it instead of each re-deriving it.
--
--   local cv = callview.of(data)
--   for i = 1, cv.n do local to = cv.get(i, 'to'); cv.set(i, 'inferred', true) end
--   for j = 1, cv.argn(i) do local k = cv.aget(i, j, 'k'); cv.aset(i, j, 'up', nil) end
--
-- get/set cover call fields (columnar covered → columns/overlay, else residual);
-- argn/aget/aset cover argv elements. rescols' immutable-column assert guards a
-- write to a parse-fixed field. The store path is byte-identical to records
-- (tools/rescolgate.lua gates audit+relink over both).

local M = {}

function M.of(data)
    local store = data._callstore
    if store then
        local callcols = require 'cartograph.callcols'
        local argvcols = require 'cartograph.argvcols'
        local cc, cov, resid, av = store.cc, store.covered, store.residual, store.av
        return {
            n = cc.n,
            get = function (i, f)
                if cov[f] then return callcols.get(cc, f, i) end
                -- `r[f]` directly (not `r and r[f] or nil`) so a residual FALSE
                -- survives — the shared proxy_index rule, index-form
                local r = resid[i]; if r then return r[f] end
            end,
            -- mirror callcols.proxy_newindex: a mutable resolution field routes to
            -- its column/overlay; a write to a covered IMMUTABLE (syntactic) column
            -- is a resolver-partition bug (assert); anything else rides the residual
            -- (refused/ext/stdpath/registry — tables/ids the schema doesn't cover)
            set = function (i, f, v)
                if cc.resf[f] then callcols.set(cc, f, i, v); return end
                assert(not cov[f], 'callview: write to immutable syntactic field: ' .. tostring(f))
                local r = resid[i]; if not r then r = {}; resid[i] = r end
                r[f] = v
            end,
            argn = function (i) return argvcols.argn(av, i) end,
            aget = function (i, j, f) return argvcols.aget(av, i, j, f) end,
            aset = function (i, j, f, v) argvcols.aset(av, i, j, f, v) end,
        }
    end
    local calls = data.calls or {}
    return {
        n = #calls,
        get = function (i, f) return calls[i][f] end,
        set = function (i, f, v) calls[i][f] = v end,
        argn = function (i) local a = calls[i].argv; return a and #a or 0 end,
        aget = function (i, j, f) return calls[i].argv[j][f] end,
        aset = function (i, j, f, v) calls[i].argv[j][f] = v end,
    }
end

return M
