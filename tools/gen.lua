-- The GENERATED-CODE fuzz bed: synthesize a corpus with a seeded generator,
-- then let the matrix's invariant columns judge it.
--
--   nvim --headless -u NONE -l tools/gen.lua <lua|java> [--seed N]
--        [--files K] [--out DIR] [--check] [--runs R] [--keep]
--
-- Every other gate tests against HISTORY (a baseline = what the extractor
-- said yesterday) or against OURSELVES (two of our pipelines agreeing).
-- Generated code is the third oracle kind: truth by construction — the
-- generator knows what it emitted, and the invariants must hold on code
-- nobody hand-picked. The columns do the judging (tools/matrix.lua accepts
-- a literal directory as a row): valid (closed schema), dfpar ferr==0 (CFG
-- fixpoints never throw), fold round-trip, cache cold==warm, par
-- inline==parallel, and above all silent==0 — any generated program where a
-- bound callable resolves to nothing-with-no-refusal is a fresh honesty bug.
--
-- ALSO A LIBRARY: `dofile('tools/gen.lua')` returns { GEN_VERSION,
-- generate(lang, dir, nfiles, seed) } — tools/bench.lua materializes the
-- SYNTHETIC corpora registered in tools/corpora.lua through it (a synthetic
-- corpus's identity is (GEN_VERSION, lang, seed, files); its root path
-- embeds g<version>-s<seed>, so a generator change = new paths + a
-- recalibration, the same discipline as expected counts).
-- GEN_VERSION discipline: ANY change to emitted output bumps it.
--
-- The generator's own floor: every emitted file must PARSE CLEAN under its
-- tree-sitter grammar (lua additionally load()-compiles), and --check adds
-- an extraction floor (emitted named fns <= extracted, unparsed==0) so a
-- parse wipeout can't pass vacuously.
--
-- Deterministic: same seed → same corpus, byte for byte (own Park-Miller
-- LCG, no math.random). A failing --check seed KEEPS its directory as the
-- repro artifact and prints it; a passing one is deleted unless --keep.
--
-- The idiom mix is deliberately the RESOLUTION-LADDER bestiary.
--   lua:  forward declarations, fn-value aliases, params called
--         (higher-order), shadows, short names (the old #name<3 blind
--         spot), setmetatable classes with self chains, cross-module
--         require + alias.member, goto-continue, closures, multi-assign.
--   java: interfaces + @Service impls (F1 bean redirects — locally
--         untestable before this: local Java corpora are non-Spring),
--         builder chains (return-type rounds), nested classes + enums with
--         methods (the State::completed shape from the parallel-fix
--         adjudication), method references, overloads (ambiguity
--         refusals), cross-file statics + instance calls.
-- Weights are a starting point — seed new idioms from corpus censuses, not
-- imagination (generator bias is the known risk).

local SELF = debug.getinfo(1, 'S').source:sub(2)
local here = SELF:match('^(.*)/gen%.lua$')

local function say(s) io.stdout:write(s .. '\n') end

local M = { GEN_VERSION = 2 } -- v2: +java generator, library form (v1 = lua-only CLI)

-- ── seeded randomness (Park-Miller; exact in doubles) ───────────────────
local S = 1
local function srand(seed)
    S = seed % 2147483647
    if S <= 0 then S = S + 2147483646 end
end
local function rnd(n) S = (S * 16807) % 2147483647 return (S % n) + 1 end
local function chance(pct) return rnd(100) <= pct end
local function pick(t) return t[rnd(#t)] end

-- ══ the lua generator ════════════════════════════════════════════════════
-- name pool: deliberate SHORT names (nm/go/cb — the length-gate blind spot)
-- and deliberate collisions (shadowing pressure)
local NAMES = { 'nm', 'go', 'cb', 'db', 'acc', 'res', 'tmp', 'flag', 'item',
    'count', 'value', 'handler', 'worker', 'store', 'alpha', 'beta', 'gamma' }

local function gen_lua_module(k)
    local B, indent, emitted = {}, 0, 0
    local function w(line) B[#B + 1] = string.rep('    ', indent) .. line end
    local uniq = 0
    local function fresh(base)
        uniq = uniq + 1
        return ('%s%d'):format(base or pick(NAMES), uniq)
    end

    -- ctx: vars = value names in scope; calls = callable EXPRESSIONS
    local function expr(ctx, d)
        local r = rnd(10)
        if d <= 0 or r <= 3 then return tostring(rnd(100)) end
        if r == 4 then return ("'s%d'"):format(rnd(50)) end
        if r <= 6 and #ctx.vars > 0 then return pick(ctx.vars) end
        if r == 7 then
            return expr(ctx, d - 1) .. pick({ ' + ', ' - ', ' * ' })
                .. expr(ctx, d - 1)
        end
        if r == 8 and #ctx.calls > 0 then
            return pick(ctx.calls) .. '(' .. expr(ctx, d - 1) .. ')'
        end
        if r == 9 then
            return '{ ' .. expr(ctx, d - 1) .. ', k = ' .. expr(ctx, d - 1) .. ' }'
        end
        return '(' .. expr(ctx, d - 1) .. ')'
    end
    local function cond(ctx)
        local r = rnd(3)
        if r == 1 and #ctx.vars > 0 then return pick(ctx.vars) end
        if r == 2 then return expr(ctx, 1) .. ' < ' .. expr(ctx, 1) end
        return 'not (' .. expr(ctx, 1) .. ')'
    end
    local function subctx(ctx)
        local c = { vars = {}, calls = {}, inloop = ctx.inloop }
        for _, v in ipairs(ctx.vars) do c.vars[#c.vars + 1] = v end
        for _, v in ipairs(ctx.calls) do c.calls[#c.calls + 1] = v end
        return c
    end

    local body
    local function stmt(ctx, d)
        local r = rnd(12)
        if r <= 3 then -- local decl; sometimes a deliberate SHADOW
            local nm = chance(25) and #ctx.vars > 0 and pick(ctx.vars)
                or fresh()
            w(('local %s = %s'):format(nm, expr(ctx, 2)))
            ctx.vars[#ctx.vars + 1] = nm
        elseif r <= 5 and #ctx.calls > 0 then -- call statement
            w(('%s(%s)'):format(pick(ctx.calls), expr(ctx, 1)))
        elseif r == 6 and d > 0 then -- if / elseif / else
            w(('if %s then'):format(cond(ctx)))
            indent = indent + 1; body(subctx(ctx), d - 1, rnd(3)); indent = indent - 1
            if chance(40) then
                w(('elseif %s then'):format(cond(ctx)))
                indent = indent + 1; body(subctx(ctx), d - 1, rnd(2)); indent = indent - 1
            end
            if chance(50) then
                w('else')
                indent = indent + 1; body(subctx(ctx), d - 1, rnd(2)); indent = indent - 1
            end
            w('end')
        elseif r == 7 and d > 0 then -- while, maybe break
            w(('while %s do'):format(cond(ctx)))
            indent = indent + 1
            local c = subctx(ctx); c.inloop = true
            -- noret: `break` must be the block's LAST statement and nothing
            -- may follow a `return` — the load() contract caught exactly this
            body(c, d - 1, rnd(3), true)
            if chance(50) then w('break') end
            indent = indent - 1
            w('end')
        elseif r == 8 and d > 0 then -- numeric for, maybe goto-continue
            local iv = fresh('i')
            w(('for %s = 1, %d do'):format(iv, rnd(10)))
            indent = indent + 1
            local c = subctx(ctx); c.inloop = true
            c.vars[#c.vars + 1] = iv
            local usegoto = chance(35)
            if usegoto then w(('if %s then goto cont%d end'):format(cond(c), k)) end
            body(c, d - 1, rnd(2), usegoto) -- a label may not follow `return`
            if usegoto then w(('::cont%d::'):format(k)) end
            indent = indent - 1
            w('end')
        elseif r == 9 and d > 0 then -- repeat..until
            w('repeat')
            indent = indent + 1; body(subctx(ctx), d - 1, rnd(2)); indent = indent - 1
            w(('until %s'):format(cond(ctx)))
        elseif r == 10 and d > 0 then -- do..end shadow block
            w('do')
            indent = indent + 1
            local c = subctx(ctx)
            local nm = #c.vars > 0 and pick(c.vars) or fresh()
            w(('local %s = %s'):format(nm, expr(c, 1)))
            body(c, d - 1, rnd(2))
            indent = indent - 1
            w('end')
        elseif r == 11 then -- closure bound to a local, then called
            local nm = fresh('h')
            w(('local %s = function (a)'):format(nm))
            indent = indent + 1; body(subctx(ctx), 0, rnd(2)); indent = indent - 1
            w('end')
            ctx.calls[#ctx.calls + 1] = nm
        else -- multi-assign
            local a, b = fresh(), fresh()
            w(('local %s, %s = %s, %s'):format(a, b, expr(ctx, 1), expr(ctx, 1)))
            ctx.vars[#ctx.vars + 1] = a
            ctx.vars[#ctx.vars + 1] = b
        end
    end
    body = function (ctx, d, n, noret)
        for _ = 1, n do stmt(ctx, d) end
        if not noret and chance(40) then
            w(('return %s'):format(expr(ctx, 1)))
        end
    end
    local function fnbody(ctx, params)
        indent = indent + 1
        for _, p in ipairs(params) do ctx.vars[#ctx.vars + 1] = p end
        body(ctx, 2, 2 + rnd(4))
        indent = indent - 1
    end

    -- ── module layout ────────────────────────────────────────────────────
    w(('-- generated module m%d (seed-deterministic; do not edit)'):format(k))
    local ctx = { vars = {}, calls = {}, inloop = false }
    local exports = {}

    -- imports of earlier modules → alias.member callables
    for j = 1, k - 1 do
        if chance(35) then
            w(("local m%d = require('m%d')"):format(j, j))
            ctx.calls[#ctx.calls + 1] = ('m%d.fa%d'):format(j, j)
        end
    end

    -- a setmetatable class with a self chain (V0/V1 machinery)
    if chance(60) then
        w(('local C%d = {}'):format(k))
        w(('C%d.__index = C%d'):format(k, k))
        w(('function C%d.new(x)'):format(k)); emitted = emitted + 1
        indent = indent + 1
        w(('local o = setmetatable({}, C%d)'):format(k))
        w('o.x = x')
        w('return o')
        indent = indent - 1
        w('end')
        w(('function C%d:get()'):format(k)); emitted = emitted + 1
        indent = indent + 1; w('return self.x'); indent = indent - 1
        w('end')
        w(('function C%d:calc(n)'):format(k)); emitted = emitted + 1
        indent = indent + 1
        w('return self:get() + n')
        indent = indent - 1
        w('end')
        w(('local obj%d = C%d.new(%d)'):format(k, k, rnd(9)))
        ctx.calls[#ctx.calls + 1] = ('obj%d:calc'):format(k)
    end

    -- a FORWARD DECLARATION assigned later, called later still (the v46
    -- resolve-or-refuse class — a silent drop here is the honesty oracle)
    local hasfwd = chance(60)
    if hasfwd then w(('local fwd%d'):format(k)) end

    -- named functions; params sometimes CALLED (higher-order → must refuse)
    local nf = 1 + rnd(3)
    for i = 1, nf do
        local fname = ('f%s%d'):format(i == 1 and 'a' or ('%c'):format(96 + i), k)
        local params = {}
        for p = 1, rnd(2) do params[p] = fresh('p') end
        w(('local function %s(%s)'):format(fname, table.concat(params, ', ')))
        emitted = emitted + 1
        local fctx = subctx(ctx)
        if #params > 0 and chance(35) then
            fctx.calls[#fctx.calls + 1] = params[1] -- call the param
        end
        if hasfwd and chance(50) then
            fctx.calls[#fctx.calls + 1] = ('fwd%d'):format(k)
        end
        fnbody(fctx, params)
        w('end')
        ctx.calls[#ctx.calls + 1] = fname
        exports[#exports + 1] = fname
    end

    -- the forward decl's late assignment + a FN-VALUE alias of a named fn
    if hasfwd then
        w(('fwd%d = function (n)'):format(k))
        indent = indent + 1; w('return n + 1'); indent = indent - 1
        w('end')
    end
    if chance(60) and #exports > 0 then
        w(('local ali%d = %s'):format(k, exports[1]))
        w(('local function fz%d()'):format(k)); emitted = emitted + 1
        indent = indent + 1
        w(('return ali%d(%d)'):format(k, rnd(9))) -- fn-value call: resolve or refuse
        indent = indent - 1
        w('end')
        exports[#exports + 1] = ('fz%d'):format(k)
    end

    -- top-level load-time statement, sometimes
    if chance(40) and #ctx.calls > 0 then
        w(('local boot%d = %s(%d)'):format(k, pick(ctx.calls), rnd(9)))
    end

    -- export table: fa<k> is the cross-module callable others import
    local ex = { ('fa%d = %s'):format(k, exports[1] or 'nil') }
    for i = 2, #exports do ex[#ex + 1] = ('%s = %s'):format(exports[i], exports[i]) end
    w('return { ' .. table.concat(ex, ', ') .. ' }')

    return table.concat(B, '\n') .. '\n', emitted
end

-- ══ the java generator ═══════════════════════════════════════════════════
-- The idioms this week proved bug-prone: @Service impls (F1 bean redirect,
-- previously untestable on local corpora), builder chains (return-type
-- rounds — the rtfull leak's home), nested enums with methods (the
-- State::completed same-file shape), method refs, overloads (ambiguity).
-- Everything int/String-typed: declared types are what the rt rounds read;
-- runtime semantics never execute.

local function gen_java_module(k, exports)
    local B, indent, emitted = {}, 0, 0
    local function w(line) B[#B + 1] = string.rep('    ', indent) .. line end
    local uniq = 0
    local function fresh(base)
        uniq = uniq + 1
        return ('%s%d'):format(base, uniq)
    end

    -- ctx.ints = int-typed names in scope; ctx.icalls = int-returning
    -- callables { expr, nargs } invocable from static context
    local function iexpr(ctx, d)
        local r = rnd(8)
        if d <= 0 or r <= 3 then return tostring(rnd(99)) end
        if r <= 5 and #ctx.ints > 0 then return pick(ctx.ints) end
        if r == 6 then return iexpr(ctx, d - 1) .. ' + ' .. iexpr(ctx, d - 1) end
        if #ctx.icalls > 0 then
            local c = pick(ctx.icalls)
            local args = {}
            for i = 1, c.nargs do args[i] = iexpr(ctx, 0) end
            return c.expr .. '(' .. table.concat(args, ', ') .. ')'
        end
        return '(' .. iexpr(ctx, d - 1) .. ')'
    end
    local function cond(ctx)
        return iexpr(ctx, 1) .. pick({ ' < ', ' > ' }) .. iexpr(ctx, 1)
    end
    local function subctx(ctx)
        local c = { ints = {}, icalls = {} }
        for _, v in ipairs(ctx.ints) do c.ints[#c.ints + 1] = v end
        for _, v in ipairs(ctx.icalls) do c.icalls[#c.icalls + 1] = v end
        return c
    end
    local function stmts(ctx, d, n)
        for _ = 1, n do
            local r = rnd(8)
            if r <= 3 then
                local nm = fresh('v')
                w(('int %s = %s;'):format(nm, iexpr(ctx, 2)))
                ctx.ints[#ctx.ints + 1] = nm
            elseif r <= 4 and #ctx.icalls > 0 then
                local c = pick(ctx.icalls)
                local args = {}
                for i = 1, c.nargs do args[i] = iexpr(ctx, 1) end
                w(('%s(%s);'):format(c.expr, table.concat(args, ', ')))
            elseif r <= 6 and d > 0 then
                w(('if (%s) {'):format(cond(ctx)))
                indent = indent + 1; stmts(subctx(ctx), d - 1, rnd(2)); indent = indent - 1
                if chance(40) then
                    w('} else {')
                    indent = indent + 1; stmts(subctx(ctx), d - 1, rnd(2)); indent = indent - 1
                end
                w('}')
            elseif r == 7 and d > 0 then
                local iv = fresh('i')
                w(('for (int %s = 0; %s < %d; %s++) {'):format(iv, iv, rnd(9), iv))
                indent = indent + 1
                local c = subctx(ctx)
                c.ints[#c.ints + 1] = iv
                stmts(c, d - 1, rnd(2))
                indent = indent - 1
                w('}')
            else
                local nm = fresh('s')
                w(('String %s = "s%d";'):format(nm, rnd(50)))
            end
        end
    end

    w(('// generated module M%d (seed-deterministic; do not edit)'):format(k))
    w('package syn;')
    w('')
    w(('public class M%d {'):format(k))
    indent = indent + 1

    local hasiface = chance(65)
    if hasiface then
        -- interface + its UNIQUE @Service impl: the F1 bean redirect —
        -- api.compute(...) below must land on Api<k>Impl::compute
        w(('public interface Api%d {'):format(k))
        indent = indent + 1
        w('int compute(int n);'); emitted = emitted + 1
        w('String label(String s);'); emitted = emitted + 1
        indent = indent - 1
        w('}')
        w('')
        w('@Service')
        w(('public static class Api%dImpl implements Api%d {'):format(k, k))
        indent = indent + 1
        w('public int compute(int n) {'); emitted = emitted + 1
        indent = indent + 1
        local c = { ints = { 'n' }, icalls = {} }
        stmts(c, 1, rnd(2))
        w(('return %s;'):format(iexpr(c, 1)))
        indent = indent - 1
        w('}')
        w('public String label(String s) {'); emitted = emitted + 1
        indent = indent + 1; w('return s;'); indent = indent - 1
        w('}')
        indent = indent - 1
        w('}')
        w('')
    end

    local hasenum = chance(50)
    if hasenum then
        -- nested enum with a method: bare/qualified calls to it are the
        -- State::completed shape the parallel-fix adjudication settled
        w(('public enum State%d {'):format(k))
        indent = indent + 1
        w('OK, BAD;')
        w('public boolean done() {'); emitted = emitted + 1
        indent = indent + 1; w('return this == OK;'); indent = indent - 1
        w('}')
        indent = indent - 1
        w('}')
        w('')
    end

    local hasthing = chance(65)
    if hasthing then
        -- builder chain: Thing<k>.builder().value(n).build() — the
        -- return-type rounds' bread and butter (and the rtfull leak's home)
        -- Builder<k> is per-module UNIQUE so the chain SETTLES (the
        -- positive rt-rounds path — where the rtfull leak lived); a shared
        -- bare `Builder` name would collide corpus-wide and refuse, which
        -- real corpora already cover (elasticsearch's dozens of Builders)
        w(('public static class Thing%d {'):format(k))
        indent = indent + 1
        w('int x;')
        w(('public static Builder%d builder() {'):format(k)); emitted = emitted + 1
        indent = indent + 1; w(('return new Builder%d();'):format(k)); indent = indent - 1
        w('}')
        w('public int getX() {'); emitted = emitted + 1
        indent = indent + 1; w('return x;'); indent = indent - 1
        w('}')
        w(('public static class Builder%d {'):format(k))
        indent = indent + 1
        w('int v;')
        w(('public Builder%d value(int n) {'):format(k)); emitted = emitted + 1
        indent = indent + 1; w('this.v = n;'); w('return this;'); indent = indent - 1
        w('}')
        w(('public Thing%d build() {'):format(k)); emitted = emitted + 1
        indent = indent + 1; w(('return new Thing%d();'):format(k)); indent = indent - 1
        w('}')
        indent = indent - 1
        w('}')
        indent = indent - 1
        w('}')
        w('')
    end

    if hasiface then w(('private Api%d api;'):format(k)) end
    w('')

    -- the always-there static helper (same-file bare resolution), with an
    -- OVERLOAD sometimes: two same-file candidates = the samefile refusal
    w(('public static int helper%d(int n) {'):format(k)); emitted = emitted + 1
    indent = indent + 1
    local hctx = { ints = { 'n' }, icalls = {} }
    stmts(hctx, 1, rnd(3))
    w(('return %s;'):format(iexpr(hctx, 1)))
    indent = indent - 1
    w('}')
    local overloaded = chance(30)
    if overloaded then
        w(('public static int helper%d(int n, int m) {'):format(k))
        emitted = emitted + 1
        indent = indent + 1; w('return n + m;'); indent = indent - 1
        w('}')
    end
    w('')

    -- the instance entry: exercises every idiom present in this module
    w(('public int run%d(int n) {'):format(k)); emitted = emitted + 1
    indent = indent + 1
    local ctx = { ints = { 'n' }, icalls = {} }
    if not overloaded then
        -- an overloaded helper refuses (ambiguous) — keep it out of the
        -- random pool so the refusal sites stay the DELIBERATE ones below
        ctx.icalls[#ctx.icalls + 1] = { expr = ('helper%d'):format(k), nargs = 1 }
    end
    if hasthing then
        w(('Thing%d t = Thing%d.builder().value(n).build();'):format(k, k))
        w('int tx = t.getX();')
        ctx.ints[#ctx.ints + 1] = 'tx'
    end
    if hasiface then
        w('int ib = api.compute(n);')
        ctx.ints[#ctx.ints + 1] = 'ib'
        w('String lb = api.label("x");')
    end
    if hasenum then
        w(('boolean ok = State%d.OK.done();'):format(k))
        w('if (ok) {')
        indent = indent + 1
        stmts(subctx(ctx), 1, rnd(2))
        indent = indent - 1
        w('}')
    end
    if overloaded then
        w(('int ov = helper%d(n, %d);'):format(k, rnd(9))) -- deliberate ambiguity site
        ctx.ints[#ctx.ints + 1] = 'ov'
    end
    if chance(40) then
        -- method reference (parses without semantic backing)
        w(('java.util.function.IntUnaryOperator f%d = M%d::helper%d;')
            :format(k, k, k))
    end
    stmts(ctx, 2, 1 + rnd(3))
    w(('return %s;'):format(iexpr(ctx, 1)))
    indent = indent - 1
    w('}')

    -- cross-file: earlier modules' statics + instance entries
    if k > 1 and chance(70) then
        local j = rnd(k - 1)
        w('')
        w(('public static int cross%d(int n) {'):format(k)); emitted = emitted + 1
        indent = indent + 1
        w(('return M%d.helper%d(n) + new M%d().run%d(n);'):format(j, j, j, j))
        indent = indent - 1
        w('}')
    end

    indent = indent - 1
    w('}')
    exports[k] = true
    return table.concat(B, '\n') .. '\n', emitted
end

-- ══ validity + generation ════════════════════════════════════════════════

-- the generator's contract with itself: emitted source parses CLEAN under
-- the same grammar extraction will use (lua additionally load()-compiles —
-- that stricter check caught the generator's own first bug)
local function assert_valid(src, lang, what)
    if lang == 'lua' then
        local chunk, err = (loadstring or load)(src)
        assert(chunk, ('gen: emitted INVALID lua for %s: %s'):format(what, err))
        return
    end
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    assert(ok, ('gen: no %s parser on the rtp (bootstrap first): %s')
        :format(lang, tostring(parser)))
    local root = parser:parse()[1]:root()
    assert(not root:has_error(),
        ('gen: emitted %s with PARSE ERRORS for %s'):format(lang, what))
end

local LANGS = {
    lua = { gen = function (k, _) return gen_lua_module(k) end,
        fname = function (k) return ('m%d.lua'):format(k) end },
    java = { gen = gen_java_module,
        fname = function (k) return ('M%d.java'):format(k) end },
}

--- Generate a corpus into dir; returns the emitted named-fn count.
--- Deterministic for a given (GEN_VERSION, lang, seed, nfiles).
function M.generate(lang, dir, nfiles, seed)
    local L = assert(LANGS[lang], 'gen: no generator for ' .. tostring(lang))
    if lang ~= 'lua' then
        -- non-lua validity needs the tree-sitter grammar on the rtp
        dofile(here .. '/bench.lua').bootstrap()
    end
    srand(seed or 1)
    vim.fn.mkdir(dir, 'p')
    local total, exports = 0, {}
    for k = 1, nfiles do
        local src, emitted = L.gen(k, exports)
        assert_valid(src, lang, L.fname(k))
        local fd = assert(io.open(dir .. '/' .. L.fname(k), 'w'))
        fd:write(src)
        fd:close()
        total = total + emitted
    end
    return total
end

-- ══ CLI ═══════════════════════════════════════════════════════════════════
-- (dofile'd as a library — e.g. by bench.corpus materializing a synthetic
-- corpus — this block is skipped and M is returned)
if not (arg and arg[0] and tostring(arg[0]):match('gen%.lua$')) then
    return M
end

local opts = { lang = nil, seed = 1, files = 6, out = nil,
    check = false, runs = 1, keep = false }
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == '--seed' then i = i + 1; opts.seed = tonumber(arg[i]) or 1
        elseif a == '--files' then i = i + 1; opts.files = tonumber(arg[i]) or 6
        elseif a == '--out' then i = i + 1; opts.out = arg[i]
        elseif a == '--runs' then i = i + 1; opts.runs = tonumber(arg[i]) or 1
        elseif a == '--check' then opts.check = true
        elseif a == '--keep' then opts.keep = true
        else opts.lang = a end
        i = i + 1
    end
end

if not LANGS[opts.lang or ''] then
    say('usage: nvim --headless -u NONE -l tools/gen.lua <lua|java> [--seed N]'
        .. ' [--files K] [--out DIR] [--check] [--runs R] [--keep]')
    os.exit(2)
end

if not opts.check then
    local dir = opts.out or (vim.fn.tempname() .. '.gen')
    local emitted = M.generate(opts.lang, dir, opts.files, opts.seed)
    say(('gen: %s seed %d → %s (%d files, %d named fns)')
        :format(opts.lang, opts.seed, dir, opts.files, emitted))
    os.exit(0)
end

-- --check: one matrix row per seed; the invariant columns are the oracle.
-- NOBASE/'~'/'--' are expected on an ad-hoc dir (no baseline, no calibrated
-- census) — only FAIL/ERR/floor-miss fails a seed.
local failed = 0
for r = 0, opts.runs - 1 do
    local seed = opts.seed + r
    local dir = (opts.out and opts.runs == 1) and opts.out
        or (vim.fn.tempname() .. ('.gen%d'):format(seed))
    local emitted = M.generate(opts.lang, dir, opts.files, seed)
    local proc = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE',
        '-l', here .. '/matrix.lua', dir, '--row' }, { text = true })
        :wait(600 * 1000)
    local res
    for line in (proc.stdout or ''):gmatch('[^\n]+') do
        local j = line:match('^@@MATRIX (.+)$')
        if j then
            local okj, t = pcall(vim.json.decode, j)
            if okj then res = t end
        end
    end
    local bad = {}
    if not res or res.err then
        bad[#bad + 1] = 'row crashed: ' .. (res and res.err or 'no result')
    else
        for col, cellr in pairs(res.cells or {}) do
            if cellr.s == 'FAIL' then
                bad[#bad + 1] = col .. ' FAIL'
                for _, l in ipairs(cellr.d or {}) do bad[#bad + 1] = '  ' .. l end
            end
        end
        if (res.unparsed or 0) > 0 then
            bad[#bad + 1] = ('floor: %d unparsed files'):format(res.unparsed)
        end
        if (res.fns or 0) < emitted then
            bad[#bad + 1] = ('floor: extracted %d named fns < %d emitted')
                :format(res.fns or 0, emitted)
        end
    end
    if #bad == 0 then
        say(('seed %-6d OK    (%d fns emitted, %d extracted)')
            :format(seed, emitted, res.fns or 0))
        if not opts.keep then vim.fn.delete(dir, 'rf') end
    else
        failed = failed + 1
        say(('seed %-6d FAIL  → repro kept at %s'):format(seed, dir))
        for _, l in ipairs(bad) do say('  ' .. l) end
    end
end
say(('GEN: %s (%d/%d seeds)'):format(failed == 0 and 'PASS' or 'FAIL',
    opts.runs - failed, opts.runs))
os.exit(failed == 0 and 0 or 1)
