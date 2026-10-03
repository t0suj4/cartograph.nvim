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
local M = {}

local A_ = nil
local function A() A_ = A_ or require('cartograph.algebra').load(); return A_ end

local memo = setmetatable({}, { __mode = 'k' })
--- how many matchers were served, by how ('memo' | 'disk' | 'compiled') and how many were REFUSED — the consumer's
--- tests read it to know the compiled path was actually taken (an equivalence test alone passes with it switched off)
M.stats = { memo = 0, disk = 0, compiled = 0, refused = 0 }

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
function M.accept(T, f, subjects)
    local a = A()
    for i, I in ipairs(subjects) do
        local okc, got = pcall(f, I)
        local want = a.match(T, I)
        if not okc then return false, ('subject %d: the compiled matcher raised: %s'):format(i, tostring(got)) end
        if not vim.deep_equal(got, want) then return false, ('subject %d (%s): the compiled matcher differs from A.match'):format(i, a.show(I)) end
    end
    return true
end

local function source_stamp()
    local SC = require 'cartograph.stampcache'
    local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:gsub('^@', ''), ':p:h')
    local tree = SC.tree(here .. '/algebra')
    return SC.key({ 'match', tostring(tree), tostring(SC.file(here .. '/mix.lua')), tostring(SC.file(here .. '/mixalg.lua')),
        tostring(SC.file(here .. '/mixterm.lua')) })
end

--- match specialized to template T -> f(I) equal to A.match(T, I), and how it was obtained ('memo' | 'disk' |
--- 'compiled') | nil, why (disabled, refused by mix, or REJECTED by the sample law: the caller keeps A.match).
--- opts.subjects: more subjects for the acceptance (a consumer's own sample)
function M.match(T, opts)
    opts = opts or {}
    if os.getenv('CARTOGRAPH_COMPILED') == '0' then return nil, 'disabled (CARTOGRAPH_COMPILED=0)' end
    if memo[T] then M.stats.memo = M.stats.memo + 1; return memo[T].f, 'memo' end
    local MA = require 'cartograph.mixalg'
    local SC = require 'cartograph.stampcache'
    local vh = SC.value(T)
    local key = vh and SC.key({ source_stamp(), vh })
    local store = key and SC.blob('compiledverb')
    local f, how
    if store then
        local hit, found = store.get(key)
        if found and type(hit) == 'table' and hit.text then f, how = MA.load_match(hit.text, hit.pool), 'disk' end
    end
    local text, pool
    if not f then
        local okc, g, t, _, p = pcall(MA.compile_match, T)
        if not okc then
            M.stats.refused = M.stats.refused + 1
            return nil, 'mix refused to compile the matcher: ' .. (type(g) == 'table' and tostring(g.refusal) or tostring(g))
        end
        f, text, pool, how = g, t, p, 'compiled'
    end
    local subjects = M.samples(T)
    for _, s in ipairs(opts.subjects or {}) do subjects[#subjects + 1] = s end
    local ok, why = M.accept(T, f, subjects)
    if not ok then M.stats.refused = M.stats.refused + 1; return nil, 'REJECTED by the sample law: ' .. why end
    M.stats[how] = M.stats[how] + 1
    if how == 'compiled' and store then store.put(key, { text = text, pool = pool }) end -- (a pool that is not plain data is refused by put: no disk copy, still correct)
    memo[T] = { f = f }
    -- (a memo keyed by the template OBJECT is sound only while the template is a value: under CARTOGRAPH_FREEZE=1 its
    -- body is marked observed, so an in-place edit of it afterwards refuses by name — CART-1403)
    if A().FREEZE then A().content_id(T.body) end
    return f, how
end

return M
