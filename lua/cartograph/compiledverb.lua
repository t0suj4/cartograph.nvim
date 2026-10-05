-- cartograph.compiledverb — COMPILED ALGEBRA VERBS (CART-1339): an algebra verb specialized by mix to its STATIC
-- argument (the first Futamura projection, cartograph.mixalg), used in place of the interpreted verb only once it is
-- ACCEPTED, and cached.
--
-- WHY (CART-1337, measured 2026-10-03): the CART-1158 scan — byexample's rewrite over lua/cartograph, 31.5 s — spends
-- ~79% in algebra verbs with the rule's template STATIC, 46% of it A.match recomputing M.sites(T) for every position.
--
-- ★ ACCEPTANCE IS A SAMPLE LAW, per template, before first use: the compiled matcher must equal A.match on BOUNDARY
-- subjects built from the template itself — its instances with every hole filled by '', 0, 'x' (an empty and a one-
-- element hedge for a repetition hole), its own body (holes and all), and degenerate terms (a lit, an empty seq, the
-- head with no kids). A population replay alone (S3's 231,451 subjects) carries no adversarial sample by design. Any
-- difference REFUSES by name and the caller keeps the interpreted verb. The equality is the algebra's OWN result,
-- compared whole (values, sites, steps, provenance), not just `ok`.
-- ★ CACHED twice: per template OBJECT for the process, and per template VALUE on disk (stampcache blob, keyed by the
-- value hash and the source of everything that compiles it: the algebra tree, mix, mixalg) — a changed algebra or
-- specializer is a miss, never a stale matcher. CARTOGRAPH_COMPILED=0 turns compilation off (the interpreted oracle).
-- ★ SERVED DEOPTIMIZABLE (CART-1459): the function returned runs the compiled code under a pcall and, when it raises,
-- runs the ORIGINAL — so an error a caller sees is the algebra's own (its message, its source), never the residual's
-- generated names and lines; a compiled matcher that raises where the original answers has DIVERGED: answered right,
-- recorded in M.divergences, and refused from then on (in the process and on disk). Cost: +3.7% per call, measured.
local M = {}

local A_ = nil
local function A() A_ = A_ or require('cartograph.algebra').load(); return A_ end

local memo = setmetatable({}, { __mode = 'k' })
local memo_none = setmetatable({}, { __mode = 'k' }) -- (refusal = 'none' matchers: another contract, another memo)
--- how many matchers were served, by how ('memo' | 'disk' | 'compiled') and how many were REFUSED — the consumer's
--- tests read it to know the compiled path was actually taken (an equivalence test alone passes with it switched off)
M.stats = { memo = 0, disk = 0, compiled = 0, refused = 0, remembered = 0, deopt = 0, diverged = 0, speculated = 0, unspeculated = 0 }
-- ★ THE ASSUMPTION compiled matchers SPECULATE on (CART-1463): a subject's nodes are not KEYED — algebraread never sets
-- `align`, so on code the keyed machinery (a quarter of every residual) folds away; a keyed subject deoptimizes
M.ASSUME = { align = { value = nil } }
-- ★ REFUSALS WITHOUT DETAILS, OPT-IN (CART-1465): `CV.match(T, { refusal = 'none' })` compiles with match's
-- env.lazy_refusal — a refusal is `{ ok = false, values = {}, sites = {}, steps }` with NO `refusal` record. Building
-- its `at` and `why` was 45% of matching when 99.9% of the calls refuse; a caller that reads only `ok` (and `values`
-- on success — byexample's rewrite, template-sites) opts in and asks A.match for a reason when it wants one. Serving
-- the details LAZILY instead (a metatable per refusal) kept only -8%, and was dropped.
M.NO_REFUSAL = { lazy_refusal = true }
--- the runtime DIVERGENCES of this process (capped): { template, subject, error } — a compiled matcher raised where
--- the original answered (a mix bug, located by its template and subject)
M.divergences = {}

--- ★ DEOPTIMIZATION (CART-1459): the matcher SERVED is the compiled one under a pcall; when it raises, the ORIGINAL runs
--- instead — A.match is pure, so running it again is safe. If the original raises too, THAT is the error the caller
--- sees: its own message and traceback, in the algebra's source, never the residual's generated names and lines. If
--- the original ANSWERS, the compiled matcher DIVERGED — a mix bug: recorded (M.divergences), the right answer
--- returned, and the compiled matcher RETIRED (on_diverge: every later call runs the original). -> the served function
function M.deopt(T, f, on_diverge)
    local retired, calls, speculated = false, 0, 0
    return function (I)
        if retired then return A().match(T, I) end
        calls = calls + 1
        local okc, got = pcall(f, I)
        if okc then return got end
        -- (a failed ASSUMPTION is no divergence: the original answers, as planned. A matcher whose assumption fails on
        -- most of its subjects — keyed data, when it was compiled for code — gives way to the original for good)
        if got == require('cartograph.mixalg').DEOPT then
            M.stats.speculated = M.stats.speculated + 1
            speculated = speculated + 1
            if speculated > 16 and speculated * 2 > calls then retired = true; M.stats.unspeculated = M.stats.unspeculated + 1 end
            return A().match(T, I)
        end
        M.stats.deopt = M.stats.deopt + 1
        local want = A().match(T, I) -- (raises the ORIGINAL's error when the subject is one the original refuses to read)
        retired = true
        M.stats.diverged = M.stats.diverged + 1
        local d = { template = A().show(T.body), subject = A().show(I), error = tostring(got) }
        if #M.divergences < 100 then M.divergences[#M.divergences + 1] = d end
        if on_diverge then on_diverge(d) end
        return want
    end
end
-- the refusals of this process by key (template value + loaded code), so an EQUAL template from another object hits too
local refused_by_value = {}

--- boundary subjects for template T (see the header)
function M.samples(T)
    local a = A()
    local out = {}
    local H = a.sites(T)
    for _, b in ipairs({ a.lit(''), a.lit(0), a.lit('x') }) do
        local V = {}
        for h, e in pairs(H) do
            if e.rep then V[h] = (b.v == '' and a.seq({})) or a.seq({ b }) else V[h] = b end
        end
        local r = a.instantiate(T, V)
        if r.ok then out[#out + 1] = r.term end
    end
    out[#out + 1] = T.body
    out[#out + 1] = a.lit(0)
    out[#out + 1] = a.seq({})
    out[#out + 1] = { k = T.body.k, kids = {} }
    return out
end

--- does the compiled matcher f equal A.match(T, ·) on every subject? -> ok | false, why
function M.accept(T, f, subjects, no_refusal)
    local a = A()
    for i, I in ipairs(subjects) do
        local okc, got = pcall(f, I)
        local want = a.match(T, I)
        -- (no_refusal: a refusal's DETAILS are not part of the contract — compared without them)
        if no_refusal and not want.ok then want = vim.deepcopy(want); want.refusal = nil end
        if no_refusal and okc and type(got) == 'table' and not got.ok and got.refusal ~= nil then -- (a deopt: the original's)
            got = vim.deepcopy(got); got.refusal = nil
        end
        if not okc and got == require('cartograph.mixalg').DEOPT then okc, got = true, want end -- (a failed assumption: served by the original)
        if not okc then return false, ('subject %d: the compiled matcher raised: %s'):format(i, tostring(got)) end
        if not vim.deep_equal(got, want) then return false, ('subject %d (%s): the compiled matcher differs from A.match'):format(i, a.show(I)) end
    end
    return true
end

local function source_stamp()
    local SC = require 'cartograph.stampcache'
    local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:gsub('^@', ''), ':p:h')
    -- (the code this process RUNS: pinned at the first ask — CART-1431 — so a matcher is never filed under the key of an
    -- edit the process has not loaded)
    local tree = SC.loaded_tree(here .. '/algebra')
    return SC.key({ 'match', tostring(tree), tostring(SC.loaded(here .. '/mix.lua')), tostring(SC.loaded(here .. '/mixalg.lua')),
        tostring(SC.loaded(here .. '/mixterm.lua')) })
end

--- match specialized to template T -> f(I) equal to A.match(T, I), and how it was obtained ('memo' | 'disk' |
--- 'compiled') | nil, why (disabled, refused by mix, or REJECTED by the sample law: the caller keeps A.match).
--- opts.subjects: more subjects for the acceptance (a consumer's own sample)
function M.match(T, opts)
    opts = opts or {}
    if os.getenv('CARTOGRAPH_COMPILED') == '0' then return nil, 'disabled (CARTOGRAPH_COMPILED=0)' end
    local none = opts.refusal == 'none'
    local memo = none and memo_none or memo -- (one memo per mode: the two serve different contracts)
    local MA = require 'cartograph.mixalg'
    local SC = require 'cartograph.stampcache'
    local vh = SC.value(T)
    -- (a CHECKED memo — CART-1403: keyed by the template object, served only while the template's VALUE is the one it
    -- was compiled for; an in-place edit of its body or a hole's domain recompiles instead of serving a stale matcher)
    if memo[T] and memo[T].vh == vh then
        if memo[T].refused then M.stats.remembered = M.stats.remembered + 1; return nil, memo[T].refused end
        M.stats.memo = M.stats.memo + 1; return memo[T].f, 'memo'
    end
    local assume = opts.speculate ~= false and M.ASSUME or nil
    local env = none and M.NO_REFUSAL or nil
    local key = vh and SC.key({ source_stamp(), vh, assume and 'assume:align' or 'exact', none and 'refusal:none' or 'refusal:full' })
    -- ★ A REFUSAL IS REMEMBERED LIKE A SUCCESS (CART-1436): mix's refusal is a fact about the template VALUE and the loaded
    -- code, under the same key. Unremembered, every call paid it again — a two-hole template from byexample ran mix to
    -- its 5M-step unfold budget (110 s) and byexample.rewrite asks once per FILE: a 16-site TSM plan ran past 15 min.
    -- (The sample law's rejection is not remembered: the caller's subjects enter it.)
    if key and refused_by_value[key] then
        memo[T] = { vh = vh, refused = refused_by_value[key] }
        M.stats.remembered = M.stats.remembered + 1
        return nil, refused_by_value[key]
    end
    -- (opts.compile: an injected COMPILER — a test's fake — is never read from nor written to the disk cache)
    local store = key and not opts.compile and SC.blob('compiledverb')
    local f, how, srcmap
    if store then
        local hit, found = store.get(key)
        if found and type(hit) == 'table' and hit.text then f, how, srcmap = MA.load_match(hit.text, hit.pool), 'disk', hit.map end
        if found and type(hit) == 'table' and hit.refused then
            refused_by_value[key] = hit.refused
            memo[T] = { vh = vh, refused = hit.refused }
            M.stats.remembered = M.stats.remembered + 1
            return nil, hit.refused
        end
    end
    local text, pool
    if not f then
        local okc, g, t, _, p, mp = pcall(opts.compile or MA.compile_match, T, { assume = assume, env = env })
        if not okc then
            M.stats.refused = M.stats.refused + 1
            local why = 'mix refused to compile the matcher: ' .. require('cartograph.mix').describe(g)
            if key then refused_by_value[key] = why end
            memo[T] = { vh = vh, refused = why }
            if store then store.put(key, { refused = why }) end
            return nil, why
        end
        f, text, pool, how, srcmap = g, t, p, 'compiled', mp
    end
    -- (a DIVERGED matcher is refused from then on, like mix's own refusal: in this process and on disk)
    local served = M.deopt(T, f, function (d)
        d.error = require('cartograph.mix').translate(d.error, srcmap) -- (in the ALGEBRA's terms: CART-1459's source map)
        local why = 'DIVERGED at run time: ' .. d.error
        memo[T] = { vh = vh, refused = why }
        if key then refused_by_value[key] = why end
        if store then store.put(key, { refused = why }) end
    end)
    -- (the sample law judges what is SERVED; under refusal = 'none' a refusal's DETAILS are not part of the contract)
    local subjects = M.samples(T)
    for _, s in ipairs(opts.subjects or {}) do subjects[#subjects + 1] = s end
    local ok, why = M.accept(T, served, subjects, none)
    if not ok then M.stats.refused = M.stats.refused + 1; return nil, 'REJECTED by the sample law: ' .. why end
    M.stats[how] = M.stats[how] + 1
    if how == 'compiled' and store then store.put(key, { text = text, pool = pool, map = srcmap }) end -- (a pool that is not plain data is refused by put: no disk copy, still correct)
    memo[T] = { f = served, vh = vh }
    return served, how
end

return M
