-- pinverdict — a pin's movement as a VERDICT, not a count (CART-0446).
--
-- ★ THE COUNT WAS THE WRONG INSTRUMENT, three times in one day (USER 2026-08-19: "a way to diff these properties
-- meaningfully"): v8's `missing:declaration` ROSE 156 while `both:declaration` FELL 156 — flat in count, strictly
-- better in KIND (two-sided -> one-sided); a residual went 15 -> 17 after a fix; a call went `unresolved` -> `refused`.
-- Each was argued in prose because "N classes moved" had nowhere to say which way.
--
-- For a DISAGREEMENT census (expr, dfparity: every class counts a disagreement), a class that FELL is STRENGTHENED,
-- one that ROSE is WEAKENED, and a `both:T` fall matched by a one-sided `missing:T` / `extra:T` / `binder:T` rise of
-- the same row type is LATERAL — the same rows, a different kind. ★ ONLY WEAKENED IS A REGRESSION. The verdict does
-- not change a cell's colour: a moved pin still has to be re-pinned (a strengthened pin left in place would let a
-- later regression back up to it pass silently), but the reviewer is told WHICH WAY before reading a single row.
local M = {}

local ONESIDED = { 'missing', 'extra', 'binder' }

--- Classify the movement from `expected` (the pin) to `cats` (this run). `total` is derived and ignored.
--- `pair` = true pairs `both:T` with the one-sided classes of the same T (the expr census's axis:type keys).
--- -> { verdict = 'SAME'|'LATERAL'|'STRENGTHENED'|'WEAKENED', strengthened = { {k, from, to} … },
---      weakened = { … }, lateral = { {from_k, to_k, n} … } }
function M.classify(cats, expected, pair)
    local d = {}
    local keys = {}
    for k in pairs(cats or {}) do if k ~= 'total' then keys[k] = true end end
    for k in pairs(expected or {}) do if k ~= 'total' then keys[k] = true end end
    for k in pairs(keys) do
        local a, b = (expected or {})[k] or 0, (cats or {})[k] or 0
        if a ~= b then d[k] = b - a end
    end
    local lateral = {}
    if pair then
        local both = {}
        for k in pairs(d) do local ty = k:match('^both:(.+)$'); if ty then both[#both + 1] = ty end end
        table.sort(both)
        for _, ty in ipairs(both) do
            local fall = -d['both:' .. ty]
            if fall > 0 then
                for _, ax in ipairs(ONESIDED) do
                    local k = ax .. ':' .. ty
                    local rise = d[k] or 0
                    if fall > 0 and rise > 0 then
                        local n = math.min(fall, rise)
                        lateral[#lateral + 1] = { 'both:' .. ty, k, n }
                        fall = fall - n
                        d[k] = rise - n
                        d['both:' .. ty] = d['both:' .. ty] + n
                    end
                end
            end
        end
    end
    local st, wk = {}, {}
    local ks = {}
    for k in pairs(d) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do
        local a = (expected or {})[k] or 0
        if d[k] < 0 then st[#st + 1] = { k, a, (cats or {})[k] or 0 }
        elseif d[k] > 0 then wk[#wk + 1] = { k, a, (cats or {})[k] or 0 } end
    end
    local v = #wk > 0 and 'WEAKENED' or #st > 0 and 'STRENGTHENED' or #lateral > 0 and 'LATERAL' or 'SAME'
    return { verdict = v, strengthened = st, weakened = wk, lateral = lateral }
end

--- One line a reviewer reads first: the verdict, then what drove it.
function M.line(r)
    if r.verdict == 'SAME' then return 'verdict: SAME' end
    local parts = {}
    local function list(t, tag)
        local xs = {}
        for _, e in ipairs(t) do xs[#xs + 1] = ('%s %d→%d'):format(e[1], e[2], e[3]) end
        if #xs > 0 then parts[#parts + 1] = tag .. ' ' .. table.concat(xs, ', ') end
    end
    list(r.weakened, 'WEAKENED')
    list(r.strengthened, 'strengthened')
    if #r.lateral > 0 then
        local xs = {}
        for _, e in ipairs(r.lateral) do xs[#xs + 1] = ('%s→%s ×%d'):format(e[1], e[2], e[3]) end
        parts[#parts + 1] = 'lateral ' .. table.concat(xs, ', ')
    end
    local why = r.verdict == 'WEAKENED' and ' — a REGRESSION' or ' — no regression: re-pin'
    return ('verdict: %s%s · %s'):format(r.verdict, why, table.concat(parts, ' · '))
end

return M
