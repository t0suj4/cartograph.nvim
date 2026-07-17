-- The GENERATED-CODE fuzz bed: synthesize a corpus with a seeded generator,
-- then let the matrix's invariant columns judge it.
--
--   nvim --headless -u NONE -l tools/gen.lua <lua|java|js> [--seed N]
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
--   js:   HOISTED forward calls, fn-value consts (`const g = f; g()`),
--         higher-order callbacks, arrows, classes with this-chains,
--         let/var SCOPE REGIMES (block vs hoisted — flow's regime seam),
--         ESM + one CommonJS module, template literals — plus an EXTRA
--         MINIFIED one-line module (min.js): same-line entities, the v32
--         (l,c) column spill's reason to exist.
-- Weights are a starting point — seed new idioms from corpus censuses, not
-- imagination (generator bias is the known risk).

local SELF = debug.getinfo(1, 'S').source:sub(2)
local here = SELF:match('^(.*)/gen%.lua$')

local function say(s) io.stdout:write(s .. '\n') end

local M = { GEN_VERSION = 5 } -- v5: +lua STRING-KEYED REGISTRY idiom (stage-3
-- resolve_registry: LibStub:NewLibrary(CONST_KEY) register + LibStub("lit")
-- retrieve, keyed want='registry' — also exercises const-fold of the register
-- key). lua output changes (new sites); java/js byte-identical to v4 (additive).
-- v4: +JS generator (hoisting, fn-value
-- consts, let/var regimes, arrows, classes, ESM + one CommonJS module, and
-- an EXTRA minified one-line module — the (l,c) column-spill's home turf).
-- lua/java output byte-identical to v3 (additive language; paths bump per
-- the discipline, calibrations carry). v3: ANSWER KEY — deliberate keyed
-- call sites + per-site expectations recorded during emission (M.answers
-- regenerates in-memory; the matrix's `key` column verifies outcomes).
-- v2: +java, library form. v1: lua CLI.

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

local function gen_lua_module(k, _, fname, ans)
    local B, indent, emitted = {}, 0, 0
    local function w(line) B[#B + 1] = string.rep('    ', indent) .. line end
    -- an EXPECTATION for the call on the line just written: the answer key.
    -- want='to' → must resolve to target (node name) at tier; want='refused'
    -- → must refuse with rule. Recorded during emission, so the key is a
    -- pure function of (GEN_VERSION, seed) — regenerated, never persisted.
    local function expect(callee, a)
        a.file, a.line, a.callee = fname, #B, callee
        ans[#ans + 1] = a
    end
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
            w(('local use%d = m%d.fa%d(1)'):format(j, j, j))
            expect(('fa%d'):format(j), { want = 'to',
                target = ('fa%d'):format(j), tier = '~' })
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
        expect('get', { want = 'to', target = ('C%d:get'):format(k),
            tier = '~' }) -- V1 self:member via call-site join
        indent = indent - 1
        w('end')
        -- class usage lives INSIDE a fn: V2 ctor-typing resolves
        -- in-function locals; at module top level (c.fn nil) it does not
        -- fire and the honest outcome is refusal — a gap the key
        -- formalized, kept OUT of the keyed sites deliberately
        w(('local function usec%d()'):format(k)); emitted = emitted + 1
        indent = indent + 1
        w(('local obj%d = C%d.new(%d)'):format(k, k, rnd(9)))
        expect('new', { want = 'to', target = ('C%d.new'):format(k),
            tier = 'plain' })
        w(('return obj%d:calc(2)'):format(k))
        expect('calc', { want = 'to', target = ('C%d:calc'):format(k),
            tier = '~' }) -- V2 ctor-typed local, inferred
        indent = indent - 1
        w('end')
        ctx.calls[#ctx.calls + 1] = ('usec%d'):format(k)
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

    -- STRING-KEYED REGISTRY (stage 3, v52) + const-fold of the register key
    -- (v50): a library is registered under a same-file CONST key (must fold for
    -- the register index to see it), retrieved by a literal LibStub("...") — the
    -- retrieval resolves (c.registry) to the registered table. Same module =
    -- same scope, so it fires regardless of the corpus's scope model.
    if chance(75) then
        local lk = ('MyLib-%d'):format(k)
        w(('local MJR%d = "%s"'):format(k, lk)) -- the key as a same-file const
        w(('local Lib%d = LibStub:NewLibrary(MJR%d, 1)'):format(k, k)) -- register w/ const key
        w(('function Lib%d:doit() return %d end'):format(k, rnd(9))); emitted = emitted + 1
        w(('local function useLib%d()'):format(k)); emitted = emitted + 1
        indent = indent + 1
        w(('local got%d = LibStub("%s")'):format(k, lk)) -- retrieve w/ literal key
        expect('LibStub', { want = 'registry', target = ('Lib%d'):format(k) })
        w(('return got%d'):format(k))
        indent = indent - 1
        w('end')
        exports[#exports + 1] = ('useLib%d'):format(k)
    end

    -- the PROBE fn: one deliberate line per honesty-ladder rung, keyed
    w(('local function probe%d(ph)'):format(k)); emitted = emitted + 1
    indent = indent + 1
    w('ph(1)')
    expect('ph', { want = 'refused', rule = 'higher-order' }) -- v46 param callable
    if hasfwd then
        w(('fwd%d(2)'):format(k))
        expect(('fwd%d'):format(k), { want = 'to',
            target = ('fwd%d'):format(k), tier = 'plain' }) -- forward decl
    end
    w(('return %s(3)'):format(exports[1]))
    expect(exports[1], { want = 'to', target = exports[1], tier = 'plain' })
    indent = indent - 1
    w('end')
    exports[#exports + 1] = ('probe%d'):format(k)

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

local function gen_java_module(k, exports, fname, ans)
    local B, indent, emitted = {}, 0, 0
    local function w(line) B[#B + 1] = string.rep('    ', indent) .. line end
    local function expect(callee, a) -- see the lua twin: the answer key
        a.file, a.line, a.callee = fname, #B, callee
        ans[#ans + 1] = a
    end
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
        expect('builder', { want = 'to',
            target = ('Thing%d::builder'):format(k), tier = 'plain' })
        expect('value', { want = 'to',
            target = ('Builder%d::value'):format(k), tier = 'tinf' })
        expect('build', { want = 'to',
            target = ('Builder%d::build'):format(k), tier = 'tinf' })
        w('int tx = t.getX();')
        expect('getX', { want = 'to',
            target = ('Thing%d::getX'):format(k), tier = 'plain' })
        ctx.ints[#ctx.ints + 1] = 'tx'
    end
    if hasiface then
        w('int ib = api.compute(n);')
        expect('compute', { want = 'to', -- THE F1 bean redirect
            target = ('Api%dImpl::compute'):format(k), tier = '~' })
        ctx.ints[#ctx.ints + 1] = 'ib'
        w('String lb = api.label("x");')
        expect('label', { want = 'to',
            target = ('Api%dImpl::label'):format(k), tier = '~' })
    end
    if hasenum then
        w(('boolean ok = State%d.OK.done();'):format(k))
        -- enum-CONSTANT receiver typing is not built: `State.OK.done()`
        -- refuses among the corpus's State*::done — the sound current
        -- rung, formalized here; an upgrade edits this expectation
        expect('done', { want = 'refused', rule = 'ambiguous' })
        w('if (ok) {')
        indent = indent + 1
        stmts(subctx(ctx), 1, rnd(2))
        indent = indent - 1
        w('}')
    end
    if overloaded then
        w(('int ov = helper%d(n, %d);'):format(k, rnd(9))) -- deliberate ambiguity site
        expect(('helper%d'):format(k), { want = 'refused', rule = 'samefile' })
        ctx.ints[#ctx.ints + 1] = 'ov'
    else
        w(('int hh = helper%d(n);'):format(k))
        expect(('helper%d'):format(k), { want = 'to',
            target = ('M%d::helper%d'):format(k, k), tier = 'plain' })
        ctx.ints[#ctx.ints + 1] = 'hh'
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

    -- cross-file: earlier modules' statics + instance entries. The
    -- generator KNOWS whether module j OVERLOADED its helper, so the
    -- expectation is conditional — refusal for the overloaded ones,
    -- resolution otherwise: intent a count gate could never express
    if k > 1 and chance(70) then
        local j = rnd(k - 1)
        w('')
        w(('public static int cross%d(int n) {'):format(k)); emitted = emitted + 1
        indent = indent + 1
        w(('return M%d.helper%d(n) + new M%d().run%d(n);'):format(j, j, j, j))
        if exports[j] and exports[j].overloaded then
            expect(('helper%d'):format(j),
                { want = 'refused', rule = 'ambiguous' })
        else
            expect(('helper%d'):format(j), { want = 'to',
                target = ('M%d::helper%d'):format(j, j), tier = 'plain' })
        end
        expect(('run%d'):format(j), { want = 'to', -- `new M<j>()` receiver
            target = ('M%d::run%d'):format(j, j), tier = '~' }) -- typed by inference
        indent = indent - 1
        w('}')
    end

    indent = indent - 1
    w('}')
    exports[k] = { overloaded = overloaded }
    return table.concat(B, '\n') .. '\n', emitted
end


-- ══ the js generator ══════════════════════════════════════════════════════
-- The JS sharp edges: HOISTING (a call textually before its function
-- declaration resolves — js-only forward-decl shape), fn-value consts
-- (`const g = f; g()` — the resolve-or-refuse class), let/var SCOPE
-- REGIMES (flow's per-language regime seam: let dies with its block, var
-- hoists), arrows, classes with this-chains, ESM everywhere + ONE
-- CommonJS module (v22's require class). min.js rides as an EXTRA file
-- (see js_min below).

local function gen_js_module(k, exports, fname, ans)
    local B, indent, emitted = {}, 0, 0
    local function w(line) B[#B + 1] = string.rep('    ', indent) .. line end
    local function expect(callee, a) -- the answer key, see the lua twin
        a.file, a.line, a.callee = fname, #B, callee
        ans[#ans + 1] = a
    end
    local uniq = 0
    local function fresh(base)
        uniq = uniq + 1
        return ('%s%d'):format(base or pick(NAMES), uniq)
    end

    local function expr(ctx, d)
        local r = rnd(10)
        if d <= 0 or r <= 3 then return tostring(rnd(100)) end
        if r == 4 then return ("'s%d'"):format(rnd(50)) end
        if r == 5 and #ctx.vars > 0 then
            return ('`t${%s}`'):format(pick(ctx.vars)) -- template literal
        end
        if r == 6 and #ctx.vars > 0 then return pick(ctx.vars) end
        if r == 7 then
            return expr(ctx, d - 1) .. pick({ ' + ', ' - ', ' * ' })
                .. expr(ctx, d - 1)
        end
        if r == 8 and #ctx.calls > 0 then
            return pick(ctx.calls) .. '(' .. expr(ctx, d - 1) .. ')'
        end
        if r == 9 then
            return '{ a: ' .. expr(ctx, d - 1) .. ', b: ' .. expr(ctx, d - 1) .. ' }'
        end
        return '[' .. expr(ctx, d - 1) .. ']'
    end
    local function cond(ctx)
        local r = rnd(3)
        if r == 1 and #ctx.vars > 0 then return pick(ctx.vars) end
        if r == 2 then return expr(ctx, 1) .. ' < ' .. expr(ctx, 1) end
        return '!(' .. expr(ctx, 1) .. ')'
    end
    local function subctx(ctx)
        local c = { vars = {}, calls = {} }
        for _, v in ipairs(ctx.vars) do c.vars[#c.vars + 1] = v end
        for _, v in ipairs(ctx.calls) do c.calls[#c.calls + 1] = v end
        return c
    end

    local body
    local function stmt(ctx, d)
        local r = rnd(10)
        if r <= 3 then -- const decl; js redeclaring const in the same block
            -- is a (parse-fine) semantic error, so always a fresh name
            local nm = fresh()
            w(('const %s = %s'):format(nm, expr(ctx, 2)))
            ctx.vars[#ctx.vars + 1] = nm
        elseif r <= 5 and #ctx.calls > 0 then
            w(('%s(%s)'):format(pick(ctx.calls), expr(ctx, 1)))
        elseif r == 6 and d > 0 then
            w(('if (%s) {'):format(cond(ctx)))
            indent = indent + 1; body(subctx(ctx), d - 1, rnd(3)); indent = indent - 1
            if chance(50) then
                w('} else {')
                indent = indent + 1; body(subctx(ctx), d - 1, rnd(2)); indent = indent - 1
            end
            w('}')
        elseif r == 7 and d > 0 then -- for..let (block regime)
            local iv = fresh('i')
            w(('for (let %s = 0; %s < %d; %s++) {'):format(iv, iv, rnd(9), iv))
            indent = indent + 1
            local c = subctx(ctx)
            c.vars[#c.vars + 1] = iv
            body(c, d - 1, rnd(2))
            indent = indent - 1
            w('}')
        elseif r == 8 and d > 0 then -- let/var REGIME block: let dies with
            -- the block, var hoists out — flow's per-language regime seam
            local lv, vv = fresh('l'), fresh('v')
            w('{')
            indent = indent + 1
            w(('let %s = %s'):format(lv, expr(ctx, 1)))
            w(('var %s = %s'):format(vv, expr(ctx, 1)))
            body(subctx(ctx), d - 1, rnd(2))
            indent = indent - 1
            w('}')
            ctx.vars[#ctx.vars + 1] = vv -- the var IS visible after; let is not
        else -- arrow closure bound to a const, then callable
            local nm = fresh('h')
            w(('const %s = (a) => {'):format(nm))
            indent = indent + 1; body(subctx(ctx), 0, rnd(2)); indent = indent - 1
            w('}')
            ctx.calls[#ctx.calls + 1] = nm
        end
    end
    body = function (ctx, d, n)
        for _ = 1, n do stmt(ctx, d) end
        if chance(40) then w(('return %s'):format(expr(ctx, 1))) end
    end
    local function fnbody(ctx, params)
        indent = indent + 1
        for _, p in ipairs(params) do ctx.vars[#ctx.vars + 1] = p end
        body(ctx, 2, 2 + rnd(3))
        indent = indent - 1
    end

    -- ── module layout ────────────────────────────────────────────────────
    -- ESM everywhere except the LAST module, which is the CommonJS one
    local cjs = exports.ncjs == k
    w(('// generated module m%d (seed-deterministic; do not edit)'):format(k))
    local ctx = { vars = {}, calls = {} }

    -- imports of earlier modules + a deliberate keyed call
    for j = 1, k - 1 do
        if chance(35) then
            if cjs then
                w(("const q%d = require('./m%d.js')"):format(j, j))
                w(('const use%d = q%d.fa%d(1)'):format(j, j, j))
            else
                w(("import { fa%d } from './m%d.js'"):format(j, j))
                w(('const use%d = fa%d(1)'):format(j, j, j))
            end
            expect(('fa%d'):format(j), { want = 'to',
                target = ('fa%d'):format(j), tier = '~' }) -- adjudicated below
            ctx.calls[#ctx.calls + 1] = ('fa%d'):format(j)
        end
    end

    -- HOISTING: the call line sits ABOVE the declaration it names — the
    -- js-native forward-decl shape (resolves same-file, no decl needed)
    w(('function early%d(n) {'):format(k)); emitted = emitted + 1
    indent = indent + 1
    w(('return late%d(n) + 1'):format(k))
    expect(('late%d'):format(k), { want = 'to',
        target = ('late%d'):format(k), tier = 'plain' })
    indent = indent - 1
    w('}')
    w(('function late%d(n) {'):format(k)); emitted = emitted + 1
    indent = indent + 1; w('return n * 2'); indent = indent - 1
    w('}')
    ctx.calls[#ctx.calls + 1] = ('early%d'):format(k)

    -- a class with a this-chain. JS RECEIVER TYPING IS NOT BUILT (no V1/V2
    -- analog — the wow residual's sibling): this.getv() and obj.calc() refuse
    -- among the corpus-wide candidates — the sound CURRENT RUNG, encoded;
    -- a js receiver-typing cut upgrades these expectations as reviewed edits
    if chance(60) then
        w(('class C%d {'):format(k))
        indent = indent + 1
        w('constructor(x) { this.x = x }')
        w('getv() { return this.x }'); emitted = emitted + 1
        w('calc(n) {'); emitted = emitted + 1
        indent = indent + 1
        w('return this.getv() + n')
        expect('getv', { want = 'refused', rule = 'ambiguous' })
        indent = indent - 1
        w('}')
        indent = indent - 1
        w('}')
        w(('function usec%d() {'):format(k)); emitted = emitted + 1
        indent = indent + 1
        w(('const obj = new C%d(3)'):format(k))
        w('return obj.calc(2)')
        expect('calc', { want = 'refused', rule = 'ambiguous' })
        indent = indent - 1
        w('}')
        ctx.calls[#ctx.calls + 1] = ('usec%d'):format(k)
    end

    -- named functions (the exports), params sometimes CALLED (higher-order)
    local nf = 1 + rnd(2)
    local names = {}
    for i = 1, nf do
        local fnm = ('f%s%d'):format(i == 1 and 'a' or ('%c'):format(96 + i), k)
        local params = {}
        for p = 1, rnd(2) do params[p] = fresh('p') end
        w(('function %s(%s) {'):format(fnm, table.concat(params, ', ')))
        emitted = emitted + 1
        local fctx = subctx(ctx)
        fnbody(fctx, params)
        w('}')
        ctx.calls[#ctx.calls + 1] = fnm
        names[#names + 1] = fnm
    end

    -- the PROBE fn: keyed honesty-ladder sites
    w(('function probe%d(ph) {'):format(k)); emitted = emitted + 1
    indent = indent + 1
    w('ph(1)')
    expect('ph', { want = 'refused', rule = 'higher-order' })
    w(('const ali%d = %s'):format(k, names[1]))
    w(('const av%d = ali%d(2)'):format(k, k))
    expect(('ali%d'):format(k), { want = 'refused', rule = 'fn-value' })
    w(('const arr%d = (a) => a + 1'):format(k))
    w(('return arr%d(3) + av%d'):format(k, k))
    expect(('arr%d'):format(k), { want = 'to',
        target = ('arr%d'):format(k), tier = 'plain' }) -- assigned arrow = a def
    indent = indent - 1
    w('}')
    emitted = emitted + 1 -- the assigned arrow arr<k> extracts as a fn too

    -- exports
    local ex = {}
    for _, nm in ipairs(names) do ex[#ex + 1] = nm end
    ex[#ex + 1] = ('probe%d'):format(k)
    ex[#ex + 1] = ('early%d'):format(k)
    if cjs then
        w(('module.exports = { %s }'):format(table.concat(ex, ', ')))
    else
        w(('export { %s }'):format(table.concat(ex, ', ')))
    end

    return table.concat(B, '\n') .. '\n', emitted
end

-- min.js: the whole module on ONE line — same-line entities are exactly
-- what the v32 (l,c) column spill exists for (minified/generated blobs);
-- extraction, flow rows, fold and navigation must all survive it
local function js_min(ans)
    local src = 'function qone(a){return a+1}function qtwo(a){return qone(a)*2}'
        .. 'function q3(a){return qtwo(a)+1}const qr=q3(5)\n'
    -- positive same-line resolutions (the (l,c) spill's home turf)
    ans[#ans + 1] = { file = 'min.js', line = 1, callee = 'qone',
        want = 'to', target = 'qone', tier = 'plain' }
    ans[#ans + 1] = { file = 'min.js', line = 1, callee = 'qtwo',
        want = 'to', target = 'qtwo', tier = 'plain' }
    -- q3 is 2 chars ON PURPOSE: it used to document resolve()'s #name<3
    -- SILENT skip (want='silent'); v48 fixed the gate — short names now
    -- resolve through the SAME-FILE tier (cross-file stays noise-gated) —
    -- so this is the reviewed key UPGRADE the design promised: the gap
    -- site became a positive spec line the moment the gap closed.
    ans[#ans + 1] = { file = 'min.js', line = 1, callee = 'q3',
        want = 'to', target = 'q3', tier = 'plain' }
    return 'min.js', src, 3
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

-- ══ ANALYSIS ground-truth: narrowing scenarios (syn-analysis INC 1) ══════════
-- Each scenario emits a fn with a guard + a use and records the EXPECTED narrow
-- env at the use line: fact='non-nil' (MUST narrow) or fact=false (must NOT — the
-- false-positive net: `or`, no-guard, use-before-a-following-guard). A separate
-- in-memory corpus from the resolution generators (M.answers/matrix untouched);
-- deterministic per seed. Consumed by tools/syngate.lua.
local function gen_lua_narrow(k, akey)
    local B, fname = {}, ('n%d.lua'):format(k)
    local function w(line) B[#B + 1] = line; return #B end
    local function key(var, fact, line)
        akey[#akey + 1] = { lens = 'narrow', file = fname, line = line, var = var, fact = fact }
    end
    local scen = {
        function (nm, a) -- + truthiness
            w(('local function %s(%s)'):format(nm, a)); w(('  if %s then'):format(a))
            local ln = w(('    use(%s)'):format(a)); w('  end'); w('end'); key(a, 'non-nil', ln)
        end,
        function (nm, a) -- + x ~= nil
            w(('local function %s(%s)'):format(nm, a)); w(('  if %s ~= nil then'):format(a))
            local ln = w(('    use(%s)'):format(a)); w('  end'); w('end'); key(a, 'non-nil', ln)
        end,
        function (nm, a) -- + early-exit `x == nil then return`
            w(('local function %s(%s)'):format(nm, a)); w(('  if %s == nil then return end'):format(a))
            local ln = w(('  use(%s)'):format(a)); w('end'); key(a, 'non-nil', ln)
        end,
        function (nm, a, b) -- + and-conjunction narrows both
            w(('local function %s(%s, %s)'):format(nm, a, b)); w(('  if %s and %s then'):format(a, b))
            local ln = w(('    use(%s, %s)'):format(a, b)); w('  end'); w('end')
            key(a, 'non-nil', ln); key(b, 'non-nil', ln)
        end,
        function (nm, a, b) -- − `or` does NOT narrow
            w(('local function %s(%s, %s)'):format(nm, a, b)); w(('  if %s or %s then'):format(a, b))
            local ln = w(('    use(%s)'):format(a)); w('  end'); w('end'); key(a, false, ln)
        end,
        function (nm, a) -- − no guard
            w(('local function %s(%s)'):format(nm, a))
            local ln = w(('  use(%s)'):format(a)); w('end'); key(a, false, ln)
        end,
        function (nm, a) -- − use BEFORE a following guard (not dominated); after IS
            w(('local function %s(%s)'):format(nm, a))
            local ln = w(('  step(%s)'):format(a)); w(('  if %s == nil then return end'):format(a))
            local ln2 = w(('  use(%s)'):format(a)); w('end')
            key(a, false, ln); key(a, 'non-nil', ln2)
        end,
    }
    local names = {}
    for i = 1, 6 + rnd(6) do
        local a, b = pick(NAMES), pick(NAMES)
        while b == a do b = pick(NAMES) end
        local nm = ('s%d'):format(i)
        scen[rnd(#scen)](nm, a, b); names[#names + 1] = nm; w('')
    end
    w(('return { %s }'):format(table.concat(names, ', ')))
    local src = table.concat(B, '\n') .. '\n'
    assert_valid(src, 'lua', fname)
    return fname, src
end

-- LICM ground-truth (syn-analysis INC 2): each fn = a loop with a MARKED row;
-- key {hoistable=true} (a clean `*` hoist) or false (must NOT be — the
-- false-positive classes: loop var / accumulator / allocation / allocating call /
-- table-index read). One instance of every scenario per file (seeded base name).
local function gen_lua_licm(k, akey)
    local B, fname = {}, ('l%d.lua'):format(k)
    local function w(s) B[#B + 1] = s; return #B end
    local function key(line, hoistable)
        akey[#akey + 1] = { lens = 'licm', file = fname, line = line, hoistable = hoistable }
    end
    local base = pick(NAMES)
    w(('local function la(xs, %s)'):format(base)); w('  for _, x in ipairs(xs) do')
    key(w(('    local ka = %s + 1'):format(base)), true) -- + pure pre-loop scalar
    w('    use(ka, x)'); w('  end'); w('end')
    w(('local function lb(xs, %s)'):format(base)); w('  for _, x in ipairs(xs) do')
    key(w(('    local sb = string.format("d", %s)'):format(base)), true) -- + pure module call
    w('    use(sb, x)'); w('  end'); w('end')
    w('local function lc(xs)'); w('  for _, x in ipairs(xs) do')
    key(w('    local yc = x + 1'), false) -- − loop var
    w('    use(yc)'); w('  end'); w('end')
    w('local function ld(xs)'); w('  local td = 0'); w('  for _, x in ipairs(xs) do')
    key(w('    td = td + x'), false) -- − accumulator (rmw + reassignment)
    w('  end'); w('  return td'); w('end')
    w('local function le(xs)'); w('  for _, x in ipairs(xs) do')
    key(w('    local ae = {}'), false) -- − allocation (fresh identity)
    w('    ae[1] = x'); w('  end'); w('end')
    w(('local function lf(xs, %s)'):format(base)); w('  for _, x in ipairs(xs) do')
    key(w(('    local cf = vim.deepcopy(%s)'):format(base)), false) -- − allocating call
    w('    use(cf, x)'); w('  end'); w('end')
    w('local function lg(xs, tg)'); w('  for _, x in ipairs(xs) do')
    key(w('    local vg = tg[1]'), false) -- − table-index read (invariant~ not clean *)
    w('    use(vg, x)'); w('  end'); w('end')
    w('return { la, lb, lc, ld, le, lf, lg }')
    local src = table.concat(B, '\n') .. '\n'
    assert_valid(src, 'lua', fname)
    return fname, src
end

-- CSE ground-truth (syn-analysis INC 2): key {reuses=<first line>} (a redundant
-- pair) or false (must NOT — operand redefined between / allocating call /
-- different expression).
local function gen_lua_cse(k, akey)
    local B, fname = {}, ('c%d.lua'):format(k)
    local function w(s) B[#B + 1] = s; return #B end
    local function key(line, reuses)
        akey[#akey + 1] = { lens = 'cse', file = fname, line = line, reuses = reuses }
    end
    w('local function ca(x, y)')
    local l1 = w('  local aa = x + y')
    key(w('  local ba = x + y'), l1) -- + redundant pair
    w('  return aa, ba'); w('end')
    w('local function cb(x, y)'); w('  local ab = x + y'); w('  x = 99')
    key(w('  local bb = x + y'), false) -- − operand redefined between
    w('  return ab, bb'); w('end')
    w('local function cc(base)'); w('  local ac = vim.deepcopy(base)')
    key(w('  local bc = vim.deepcopy(base)'), false) -- − allocating call
    w('  return ac, bc'); w('end')
    w('local function cd(x, y)'); w('  local ad = x + y')
    key(w('  local bd = x - y'), false) -- − different expression
    w('  return ad, bd'); w('end')
    w('return { ca, cb, cc, cd }')
    local src = table.concat(B, '\n') .. '\n'
    assert_valid(src, 'lua', fname)
    return fname, src
end

-- REDUNDANT-CHECK ground-truth (syn-analysis INC 2, narrow lint): key {want=true}
-- (always-true), {want=false} (dead then), or {want='none'} (must NOT flag). The
-- NEGATIVES are the three soundness traps dogfooding found: truthy≠non-nil,
-- conjunction-under-early-exit, reassignment-between.
local function gen_lua_redundant(k, akey)
    local B, fname = {}, ('r%d.lua'):format(k)
    local function w(s) B[#B + 1] = s; return #B end
    local function key(line, want) akey[#akey + 1] = { lens = 'redundant', file = fname, line = line, want = want } end
    w('local function ra(x)'); w('  if x ~= nil then')
    key(w('    if x ~= nil then use(x) end'), true) -- + always true
    w('  end'); w('end')
    w('local function rb(x)'); w('  if x ~= nil then')
    key(w('    if x == nil then bad() end'), false) -- + dead then
    w('  end'); w('end')
    w('local function rc(x)'); w('  if x ~= nil then')
    key(w('    if x then use(x) end'), 'none') -- − truthy≠non-nil (x could be false)
    w('  end'); w('end')
    w('local function rd(a)'); w('  if not a and cond() then return end')
    key(w('  if a then use(a) end'), 'none') -- − ¬(not a ∧ cond) proves nothing
    w('end')
    w('local function re(x)'); w('  if x ~= nil then'); w('    x = f()')
    key(w('    if x ~= nil then use(x) end'), 'none') -- − reassigned between
    w('  end'); w('end')
    w('local function rf(x, y)'); w('  if x ~= nil then')
    key(w('    if y ~= nil then use(y) end'), 'none') -- − unproven var
    w('  end'); w('end')
    w('return { ra, rb, rc, rd, re, rf }')
    local src = table.concat(B, '\n') .. '\n'
    assert_valid(src, 'lua', fname)
    return fname, src
end

--- ANALYSIS ground-truth corpus. Returns { files = {name→src}, order, key } where
--- each key carries `lens` ('narrow'|'licm'|'cse') + the per-line expectation:
--- narrow {var, fact='non-nil'|false}; licm {hoistable=bool}; cse {reuses=<line>|false}.
--- NEGATIVES (fact/hoistable false, reuses false) are the false-positive net.
--- tools/syngate.lua runs the lenses and diffs. Deterministic per (lang, nfiles, seed).
function M.analysis(lang, nfiles, seed)
    assert(lang == 'lua', 'gen.analysis: INC 1-2 are lua-only')
    srand(seed or 1)
    local out = { files = {}, order = {}, key = {} }
    local function add(fname, src) out.files[fname] = src; out.order[#out.order + 1] = fname end
    for i = 1, (nfiles or 12) do add(gen_lua_narrow(i, out.key)) end
    for i = 1, 4 do add(gen_lua_licm(i, out.key)) end
    for i = 1, 4 do add(gen_lua_cse(i, out.key)) end
    for i = 1, 4 do add(gen_lua_redundant(i, out.key)) end
    return out
end

local LANGS = {
    lua = { gen = gen_lua_module,
        fname = function (k) return ('m%d.lua'):format(k) end },
    java = { gen = gen_java_module,
        fname = function (k) return ('M%d.java'):format(k) end },
    js = { gen = gen_js_module, extra = js_min, cjs_last = true,
        tslang = 'javascript', -- the grammar name (CLI name stays js)
        fname = function (k) return ('m%d.js'):format(k) end },
}

--- Build a corpus IN MEMORY: { files = {name→src}, emitted, answers }.
--- The single source both generate() (writes) and answers() (key) share.
local function build(lang, nfiles, seed)
    local L = assert(LANGS[lang], 'gen: no generator for ' .. tostring(lang))
    srand(seed or 1)
    local out = { files = {}, order = {}, emitted = 0, answers = {} }
    local exports = {}
    if L.cjs_last then exports.ncjs = nfiles end -- the one CommonJS module
    for k = 1, nfiles do
        local fname = L.fname(k)
        local src, emitted = L.gen(k, exports, fname, out.answers)
        out.files[fname] = src
        out.order[k] = fname
        out.emitted = out.emitted + emitted
    end
    if L.extra then -- a deliberate extra file (js: the minified module)
        local fname, src, emitted = L.extra(out.answers)
        out.files[fname] = src
        out.order[#out.order + 1] = fname
        out.emitted = out.emitted + emitted
    end
    return out
end

--- The ANSWER KEY alone (no writes): per-call intended outcomes at the
--- deliberate sites — { file, line (1-based), callee, want='to'|'refused',
--- target?, tier='plain'|'~'|'tinf', rule? }. Deterministic per
--- (GEN_VERSION, lang, seed, files); the matrix's `key` column consumes it.
function M.answers(lang, nfiles, seed)
    return build(lang, nfiles, seed).answers
end

--- Generate a corpus into dir; returns the emitted named-fn count.
--- Deterministic for a given (GEN_VERSION, lang, seed, nfiles).
function M.generate(lang, dir, nfiles, seed)
    if lang ~= 'lua' then
        -- non-lua validity needs the tree-sitter grammar on the rtp
        dofile(here .. '/bench.lua').bootstrap()
    end
    local out = build(lang, nfiles, seed)
    vim.fn.mkdir(dir, 'p')
    local parselang = LANGS[lang].tslang or lang
    for _, fname in ipairs(out.order) do
        local src = out.files[fname]
        assert_valid(src, parselang, fname)
        local fd = assert(io.open(dir .. '/' .. fname, 'w'))
        fd:write(src)
        fd:close()
    end
    return out.emitted
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
    say('usage: nvim --headless -u NONE -l tools/gen.lua <lua|java|js> [--seed N]'
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
