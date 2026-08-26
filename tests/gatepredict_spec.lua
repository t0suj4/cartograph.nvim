-- The gate predictor's claim is a PROMISE: refutable only, never confirmable.
-- These tests fence the three things that would let it lie.
--
--   1. it must SUBTRACT ONLY, and never on the strength of a corpus's NAME
--   2. `all` (refusing to subtract) and `none` (nothing can move) must not
--      render the same, because they produce OPPOSITE verdicts
--   3. every language the registry knows must be REACHABLE by the mapping —
--      an unmapped language means corpora get ruled out on no evidence

local gp = require 'cartograph.gatepredict'
local ts = require 'cartograph.providers.treesitter'

local function registry()
    local dialect
    local ok, tok = pcall(require, 'cartograph.providers.tokens')
    if ok then dialect = tok.ext_dialect end
    local known = {}
    for lang in pairs(ts.spec) do known[lang] = true end
    for _, d in pairs(dialect or {}) do known[d] = true end
    local pl = { treesitter = {}, tokens = {} }
    for lang in pairs(ts.spec) do pl.treesitter[lang] = true end
    for _, d in pairs(dialect or {}) do pl.tokens[d] = true end
    return known, pl, dialect
end

test('gatepredict: a scoped diff subtracts, an engine diff REFUSES to', function ()
    local known, pl = registry()
    local scoped = gp.touched({ 'lua/cartograph/spec/ruby.lua' }, known, pl)
    eq('langs', scoped.scope)
    ok(scoped.langs.ruby, 'a ruby spec change reaches ruby')

    local engine = gp.touched({ 'lua/cartograph/store.lua' }, known, pl)
    eq('all', engine.scope, 'an engine file bounds nothing')

    local nothing = gp.touched({ 'README.md' }, known, pl)
    eq('none', nothing.scope, 'a doc change cannot move any corpus')
end)

test('gatepredict: `all` and `none` produce OPPOSITE verdicts, not similar ones', function ()
    -- both carry an empty-ish language set; collapsing them inverts the answer.
    local inv = { alpha = { langs = { ruby = 3 }, provider = 'treesitter' } }
    local all = gp.predict(inv, { scope = 'all', langs = {}, why = {} })
    local none = gp.predict(inv, { scope = 'none', langs = {}, providers = {}, why = {} })
    eq(0, #all.immovable, 'scope=all must rule out NOTHING')
    eq(1, #all.movable)
    eq(1, #none.immovable, 'scope=none must rule out EVERYTHING')
    eq(0, #none.movable)
end)

test('gatepredict: a corpus is judged by its CONTENTS, never by its name', function ()
    local known, pl = registry()
    local touched = gp.touched({ 'lua/cartograph/spec/cpp.lua' }, known, pl)
    -- `libs` is the real case: declared `lang = 'java'` in corpora.lua, and it
    -- carries 34 .cpp + 63 .h files. Name-matching rules it out; contents do not.
    local inv = {
        libs = { langs = { java = 905, cpp = 34, c = 6 }, provider = 'treesitter' },
        rails = { langs = { ruby = 369 }, provider = 'treesitter' },
    }
    local pred = gp.predict(inv, touched)
    local imm = {}
    for _, e in ipairs(pred.immovable) do imm[e.corpus] = true end
    ok(not imm.libs, 'a java-NAMED corpus carrying cpp must stay in play')
    ok(imm.rails, 'a corpus with no cpp at all is ruled out')
end)

test('gatepredict: the PROVIDER axis rules out a corpus that has the language', function ()
    local known, pl = registry()
    local touched = gp.touched({ 'lua/cartograph/spec/ruby.lua' }, known, pl)
    -- bwipp really does carry 2 .rb files, and is still immovable by a ruby SPEC
    -- change: bench.lua dispatches ONE provider per corpus and bwipp uses
    -- `tokens`, which never consults M.spec. Language alone would keep it.
    local inv = {
        bwipp = { langs = { ruby = 2, postscript = 15 }, provider = 'tokens' },
        rails = { langs = { ruby = 369 }, provider = 'treesitter' },
    }
    local pred = gp.predict(inv, touched)
    local imm = {}
    for _, e in ipairs(pred.immovable) do imm[e.corpus] = true end
    ok(imm.bwipp, 'a tokens-provider corpus is out of a spec change\'s reach')
    ok(not imm.rails, 'the treesitter corpus with ruby stays in play')
end)

test('gatepredict: `.h` stays ambiguous — it must not collapse to one language', function ()
    local _, _, dialect = registry()
    local el = gp.ext_langs(ts.spec, dialect)
    local h = {}
    for _, l in ipairs(el.h or {}) do h[l] = true end
    ok(h.c and h.cpp, '.h resolves by repo shape at extract time, so statically it is both')
end)

test('gatepredict: THE FENCE — every registry language is reachable by the mapping', function ()
    local known, pl = registry()
    local root = repo('lua/cartograph')
    local present = {}
    for _, sub in ipairs({ 'spec', 'providers' }) do
        for _, f in ipairs(vim.fn.globpath(root .. '/' .. sub, '**/*', false, true)) do
            present[#present + 1] = f:gsub('.*/(lua/cartograph/.*)$', '%1')
        end
    end
    local gaps = gp.registry_gaps(known, present, pl)
    eq(0, #gaps, 'unmapped language(s): ' .. table.concat(gaps, ',')
        .. ' — a change to one would be invisible and corpora would be ruled out on no evidence')
end)

test('gatepredict: a spec change reaches the languages DERIVED from it', function ()
    local known, pl = registry()
    local t = gp.touched({ 'lua/cartograph/spec/javascript.lua' }, known, pl)
    ok(t.langs.javascript, 'the spec\'s own language')
    -- typescript and tsx are COPIES of the javascript table (treesitter.lua ~702),
    -- so editing javascript.lua reaches all three and a ts-only corpus is NOT safe.
    ok(t.langs.typescript, 'typescript is copied from javascript')
    ok(t.langs.tsx, 'tsx is copied from typescript')
end)

test('gatepredict: a COMPOUND extension counts as its language, not as its tail', function ()
    local _, _, dialect = registry()
    local el = gp.ext_langs(ts.spec, dialect)
    -- the token provider declares postscript as { ps, ['ps.src'] }, and
    -- postscriptbarcode holds 125 files named *.ps.src. Matching only the final
    -- dot-segment files them as an unclaimed `src`, UNDERCOUNTING postscript —
    -- and undercounting is the unsound direction for a subtractive claim: a
    -- corpus holding nothing but .ps.src would be ruled out of a postscript
    -- change altogether.
    local ext, claimed = gp.ext_of('/x/src/kix.ps.src', el)
    eq('ps.src', ext, 'longest CLAIMED suffix wins')
    ok(claimed, 'and it is claimed')
    local plain, pclaimed = gp.ext_of('/x/a/b.rb', el)
    eq('rb', plain)
    ok(pclaimed)
    -- an extension nothing claims still gets a name, for the unclaimed bucket
    local un, uclaimed = gp.ext_of('/x/notes.qqzz', el)
    eq('qqzz', un, 'falls back to the final segment so the bucket can report it')
    ok(not uclaimed, 'but is reported as unclaimed')
end)
