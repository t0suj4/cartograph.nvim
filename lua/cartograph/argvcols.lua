-- ARGVCOLS — the IN-RESOLUTION columnar argv store (record-fold arc, the
-- resolution-on-columns foundation). argv is the FAT residual the resident call
-- store (callcols) leaves raw — ~197MB of little entry tables on v8 — so the
-- gitlab-peak lever needs argv to survive resolution as COLUMNS, not tables.
-- Resolution mutates argv elements in exactly one shape (a.k/a.to/a.up, the
-- callback-mirror upgrade, in place, never a length change), so a fixed-size
-- columnar store with a small mutable overlay carries it faithfully.
--
-- IMPLEMENTATION: flatten every call's argv elements into ONE record list and
-- reuse callcols over it (the same pooled u32 columns + mutable overlay + proxy).
-- An element of ANY kind (lit/local/func/call/field/param/…) round-trips: the
-- columnar fields (name/v/prefix immutable, k/to/up mutable) ride columns/overlay,
-- everything else (kw/l/kind-specific i/callee/path) rides the element residual.
-- Each call maps to a slice of element row-handles; `c.argv` yields that slice
-- (a stable array, so in-place mutations persist), matching a raw argv read.

local callcols = require 'cartograph.callcols'

local M = {}

-- immutable element columns (resolution only READS these); k/to are mutable
-- strings and up a mutable flag (the callback-mirror upgrade writes them). kw/l
-- and any kind-specific fields ride the element residual (faithful round-trip,
-- and ints-as-residual sidesteps the 0-vs-absent column ambiguity).
M.ARGV_SYN = { strs = { 'name', 'v', 'prefix' } }
M.ARGV_RES = { strs = { 'k', 'to' }, flags = { 'up' } }

-- build the store over a call-record list. Returns { av, argof, hadargv } where
-- av = the callcols view over the flattened elements, argof[i] = the stable
-- row-handle array for call i's argv (nil if the call has no argv field).
function M.build(calls)
    local elems, off, cnt, hadargv = {}, {}, {}, {}
    local k = 0
    for i = 1, #calls do
        local argv = calls[i].argv
        hadargv[i] = argv ~= nil
        off[i] = k
        local c = argv and #argv or 0
        cnt[i] = c
        for j = 1, c do k = k + 1; elems[k] = argv[j] end
    end
    local av = callcols.view(elems, M.ARGV_SYN, M.ARGV_RES)
    local argof = {}
    for i = 1, #calls do
        if hadargv[i] then
            local a = {}
            for j = 1, cnt[i] do a[j] = av.rows[off[i] + j] end
            argof[i] = a
        end
    end
    return { av = av, argof = argof, hadargv = hadargv, off = off, cnt = cnt }
end

-- the stable element-handle array for call i (what a `c.argv` read returns), or
-- nil when the call had no argv field — matching the raw record exactly.
function M.argv_of(store, i) return store.argof[i] end

-- reconstruct call i's argv as a plain raw array (element tables), for a full
-- materialize / parity check. nil when the call had no argv.
function M.materialize(store, i)
    if not store.hadargv[i] then return nil end
    local av, base, n = store.av, store.off[i], store.cnt[i]
    local out = {}
    for j = 1, n do
        local r = base + j
        local e = callcols.record(av.cc, r)
        local resid = av.residual[r]
        if resid then for f, v in pairs(resid) do e[f] = v end end
        out[j] = e
    end
    return out
end

return M
