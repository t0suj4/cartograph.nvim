-- patternjoin — spec.lua.pattern_degree JOINED against Lua's own matcher (CART-1057).
--
--   nvim --headless -u NONE -l tools/patternjoin.lua ['<pattern>' ...]
--
-- The degree is an UPPER bound on a search's growth in the subject's length (lua_patterns.lua).
-- The oracle is the matcher itself: each pattern is timed on backtracking-prone inputs at four sizes
-- and the growth exponent is the least-squares slope of log(time) on log(n).
-- ★ ONE-SIDED, and the report says so: a measured exponent ABOVE the degree refutes the bound; one
-- below it confirms nothing, because the adversarial input may be missing from the families. The
-- trim idiom `^%s*(.-)%s*$` needs a BRACKETED input (`x` + spaces + `x`): without that family it
-- measured 0.92 against its known 2.
-- ★ NO MAX-OF-NOISE: every family is SCREENED at two sizes and only the three worst are measured
-- properly (four sizes, median of three each). Taking the maximum over ~100 single-pair ratios
-- read an anchored single class (`^[%w_]+$`, linear by construction) as 1.53.
-- Times are os.clock (CPU of this process), so other work on the machine skews them less.
-- ★ Input characters: per class, one it ACCEPTS and one it REJECTS (a late failure is the worst case).

local REPO = (debug.getinfo(1, 'S').source:match('@(.*)/tools/[^/]+$')) or '.'
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
local P = require 'cartograph.spec.lua_patterns'

local SAMPLES = {
    'abc', '^abc', '%s*x', '^%s*x', '^(.-)%s*$', '^%s*(.-)%s*$', '^%d+%.%d+$', '(%w+)=(%w+)',
    '%b()', '^[%w_]+$', '.*,.*', '^([^=]+)=(.*)$', '%f[%w]foo', '^(.*)/', '([^/]+)$',
}

-- inputs from characters the pattern's classes accept, plus a few it may reject
local function families(pat)
    local items = P.items(pat)
    local alpha, seen = {}, {}
    -- per class: the first printable character it ACCEPTS and the first it REJECTS — a failing
    -- match is the worst case, and `([^/]+)$` fails late only on a `/` (without it: 0.00)
    for _, it in ipairs(items) do
        for _, want in ipairs({ true, false }) do
            for b = 32, 126 do
                local ch = string.char(b)
                local ok, hit = pcall(string.find, ch, '^' .. it.cls .. '$')
                local accepts = it.cls == '.' or (ok and hit ~= nil)
                if accepts == want then
                    if not seen[ch] then seen[ch] = true; alpha[#alpha + 1] = ch end
                    break
                end
            end
        end
    end
    for _, extra in ipairs({ ' ', 'a', '1', '=', ',', '(', 'x' }) do
        if not seen[extra] then seen[extra] = true; alpha[#alpha + 1] = extra end
    end
    local fam = {}
    for _, a in ipairs(alpha) do fam[#fam + 1] = function(n) return a:rep(n) end end
    for i = 1, #alpha do
        for j = 1, #alpha do
            if i ~= j then
                local a, b = alpha[i], alpha[j]
                if i < j then fam[#fam + 1] = function(n) return (a .. b):rep(math.floor(n / 2)) end end
                fam[#fam + 1] = function(n) return a:rep(n - 1) .. b end
                fam[#fam + 1] = function(n) return b .. a:rep(n - 2) .. b end -- BRACKETED
            end
        end
    end
    return fam
end

local function time(pat, s)
    local reps, t = 1, 0
    repeat
        local t0 = os.clock()
        for _ = 1, reps do local _ = string.find(s, pat) end
        t = os.clock() - t0
        reps = reps * 4
    until t > 0.02 or reps > 4 ^ 8
    return t / (reps / 4)
end
local function median3(pat, s)
    local a, b, c = time(pat, s), time(pat, s), time(pat, s)
    if a > b then a, b = b, a end
    if b > c then b = c end
    if a > b then b = a end
    return b
end
local function slope(pat, f, sizes)
    local xs, ys = {}, {}
    for _, n in ipairs(sizes) do
        local t = median3(pat, f(n))
        if t > 2e-5 then xs[#xs + 1] = math.log(n); ys[#ys + 1] = math.log(t) end
    end
    if #xs < 3 then return nil end
    local mx, my = 0, 0
    for i = 1, #xs do mx, my = mx + xs[i], my + ys[i] end
    mx, my = mx / #xs, my / #xs
    local num, den = 0, 0
    for i = 1, #xs do num = num + (xs[i] - mx) * (ys[i] - my); den = den + (xs[i] - mx) ^ 2 end
    return num / den
end

local pats = {}
for _, a in ipairs(arg) do pats[#pats + 1] = a end
if #pats == 0 then pats = SAMPLES end
local refuted, tight = 0, 0
for _, pat in ipairs(pats) do
    local d = P.degree(pat)
    local screened = {}
    for fi, f in ipairs(families(pat)) do
        local t1, t2 = time(pat, f(800)), time(pat, f(1600))
        if t1 > 1e-6 then screened[#screened + 1] = { fi = fi, f = f, e = math.log(t2 / t1) / math.log(2) } end
    end
    table.sort(screened, function(a, b) return a.e > b.e end)
    local best = 0
    for k = 1, math.min(3, #screened) do
        local e = slope(pat, screened[k].f, { 400, 800, 1600, 3200 })
        if e and e > best then best = e end
    end
    local over = best > d + 0.3
    if over then refuted = refuted + 1 end
    if math.abs(best - d) <= 0.3 then tight = tight + 1 end
    print(('%-20s degree %d  measured %.2f%s'):format(pat, d, best,
        over and '  ⚠ REFUTES THE BOUND' or (best < d - 0.7 and '  (overshoot, or the adversarial input is missing)' or '')))
end
print(('%d pattern(s): %d refute the bound, %d measured within 0.3 of it (one-sided: below is not a confirmation)')
    :format(#pats, refuted, tight))
