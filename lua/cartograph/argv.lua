-- ARGV FOLD: argument shapes, eager-but-folded. The per-call argv is an
-- array of small tables ({k=,name=,v=,kw=,prefix=}) — measured at 69 MB
-- (server) / 197 MB (v8) resident, ~750k entry tables on v8. But argv is
-- HOT: trace.origins and the framework lints read it at query time, and
-- the df-eager lesson says paging it regresses tracing. So we FOLD, not
-- drop: one GLOBAL columnar store per graph (mutually-exclusive fields
-- collapse to few columns), each call an offset+count slice — the fat
-- entry tables gone, argv stays resident and instant.
--
-- The accessor is DUAL-MODE: it reads the folded columns when a call has
-- been folded (c._av set) and the raw c.argv/c.args tables otherwise. So
-- consumers migrate to the accessor with ZERO behavior change (raw path),
-- and fold() can later drop the raw tables with nothing to crash — the
-- API-first swap, exactly as the topology fold did with the Band.
--
-- Resolution-only fields (a.to/a.up — the callback upgrade) are NOT folded:
-- they are consumed during resolution/post-passes, before fold() runs, and
-- never read post-fold. Query-read fields (k, name, v, prefix, kw) are kept.

local M = {}

-- kind enum (the k column); 0 = absent slot
M.K = { lit = 1, concat = 2, ['local'] = 3, func = 4, callable = 5,
    expr = 6, spread = 7 }
M.KNAME = { [0] = nil, 'lit', 'concat', 'local', 'func', 'callable',
    'expr', 'spread' }

-- ── dual-mode accessor ───────────────────────────────────────────────────
-- number of args on call `c`
function M.n(c)
    if c._av then return c._avn end
    return c.argv and #c.argv or 0
end

-- the i-th argument as a view { k, name, v, prefix, kw } (1-based). From
-- the folded columns (materialized fresh — transient, cheap) or the raw
-- entry table. Fields absent in the fold read nil, matching raw.
function M.at(c, i)
    if c._av then
        local col, r = c._av, c._av0 + i
        local k = M.KNAME[col.k[r] or 0]
        if not k then return nil end
        return { k = k, name = col.name[r], v = col.v[r],
            prefix = col.prefix[r], kw = col.kw[r] }
    end
    return c.argv and c.argv[i]
end

-- the i-th arg's flat STRING value (the old c.args[i]: literal value or '')
function M.str(c, i)
    if c._av then return c._av.v[c._av0 + i] or '' end
    return (c.args and c.args[i]) or ''
end

-- ── the fold: raw argv/args tables → one columnar store, tables dropped ──
function M.fold(data)
    if data._argvcol then return 0 end -- already folded (idempotent)
    local col = { k = {}, name = {}, v = {}, prefix = {}, kw = {} }
    local n = 0
    for _, c in ipairs(data.calls or {}) do
        if c.argv and not c._av then
            local base = n
            for i, a in ipairs(c.argv) do
                n = n + 1
                col.k[n] = M.K[a.k] or 0
                col.name[n] = a.name
                col.v[n] = a.v or (c.args and c.args[i] ~= '' and c.args[i]) or nil
                col.prefix[n] = a.prefix
                col.kw[n] = a.kw
            end
            c._av, c._av0, c._avn = col, base, #c.argv
            c.argv, c.args = nil, nil -- the fat tables, gone
        end
    end
    data._argvcol = col
    return n
end

-- resident byte estimate of the folded store (5 columns, mixed scalar/ref)
function M.bytes(data)
    local col = data._argvcol
    if not col then return 0 end
    return #col.k * (1 + 8 * 4) -- k byte + 4 ref slots (name/v/prefix/kw)
end

return M
