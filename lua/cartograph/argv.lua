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
-- a.to (the callback upgrade's resolved target) IS query-read — xlang's
-- find_handler reads it on refresh re-attach — so it's folded too. a.up
-- (the upgrade marker) is resolution/merge-only (audit/relink, all pre-fold)
-- and is dropped. Query-read fields: k, name, v, prefix, kw, to, l.

local M = {}

-- kind enum (the k column); 0 = absent slot
-- ★ `macro` (9) is APPENDED, never inserted: the numbers are stored in the
-- columnar fold, so reordering them would silently reinterpret every persisted
-- graph. A macro argument is neither a literal nor a local — its VALUE may be
-- unknowable (erlang's `?NS_MAM_2` expands in a library that is not in the tree)
-- while its NAME is right there in the syntax, and a named key can be linked,
-- counted and refused where an opaque `expr` can do none of those (CART-0812).
M.K = { lit = 1, concat = 2, ['local'] = 3, func = 4, callable = 5,
    expr = 6, spread = 7, scalar = 8, macro = 9 }
M.KNAME = { [0] = nil, 'lit', 'concat', 'local', 'func', 'callable',
    'expr', 'spread', 'scalar', 'macro' }

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
        if i < 1 or i > c._avn then return nil end -- out of range, like raw
        local col, r = c._av, c._av0 + i
        return { k = M.KNAME[col.k[r] or 0], name = col.name[r], v = col.v[r],
            prefix = col.prefix[r], kw = col.kw[r], to = col.to[r], l = col.l[r] }
    end
    return c.argv and c.argv[i]
end

-- the i-th arg's flat STRING value (the old c.args[i]: literal value or '')
function M.str(c, i)
    if c._av then return c._av.v[c._av0 + i] or '' end
    return (c.args and c.args[i]) or ''
end

-- ── the fold: raw argv/args tables → one columnar store, tables dropped ──
-- the fields a folded entry can carry (columns). The neutral-schema argv is
-- OPEN — trace/other providers emit richer kinds (param/call/field) with
-- extra fields (i/callee/path/…) the columnar store doesn't model. An entry
-- outside this shape keeps its CALL raw (the accessor's dual mode serves the
-- mix); the fold still collapses the tree-sitter majority (the 197MB win).
local FOLDABLE = { k = true, name = true, v = true, prefix = true,
    kw = true, to = true, l = true, up = true } -- up is read pre-fold, ignored
local function simple(a)
    if not M.K[a.k] then return false end -- unknown kind (param/call/field/…)
    for f in pairs(a) do if not FOLDABLE[f] then return false end end
    return true
end

function M.fold(data)
    if data._argvcol then return 0 end -- already folded (idempotent)
    local col = { k = {}, name = {}, v = {}, prefix = {}, kw = {}, to = {}, l = {} }
    local n = 0
    for _, c in ipairs(data.calls or {}) do
        if c.argv and not c._av then
            local foldable = true
            for _, a in ipairs(c.argv) do
                if not simple(a) then foldable = false; break end
            end
            if foldable then
                local base = n
                for i, a in ipairs(c.argv) do
                    n = n + 1
                    col.k[n] = M.K[a.k]
                    col.name[n] = a.name
                    col.v[n] = a.v or (c.args and c.args[i] ~= '' and c.args[i]) or nil
                    col.prefix[n] = a.prefix
                    col.kw[n] = a.kw
                    col.to[n] = a.to
                    col.l[n] = a.l
                end
                c._av, c._av0, c._avn = col, base, #c.argv
                c.argv, c.args = nil, nil -- the fat tables, gone
            end
        end
    end
    data._argvcol = col
    return n
end

-- resident byte estimate of the folded store (5 columns, mixed scalar/ref)
function M.bytes(data)
    local col = data._argvcol
    if not col then return 0 end
    return #col.k * (1 + 8 * 6) -- k byte + 6 ref slots (name/v/prefix/kw/to/l)
end

return M
