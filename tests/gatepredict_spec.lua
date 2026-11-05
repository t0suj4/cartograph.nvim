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

-- ── OUTPUT-NEUTRAL edits (CART-0622) ────────────────────────────────────────
-- Every extraction change ships with a cache.lua VERSION bump, and cache.lua is an engine file, so the predictor was
-- disarmed on exactly the commits it exists for: 76 of 84 scored commits read scope=all, cache.lua in 66 of them.
-- The rule is by CONSTRUCT, never by file: comment text is output-neutral anywhere, and the NUMBER assigned to
-- cache.lua's `M.VERSION` is (it keys caches and stamps an advisory epoch; extraction never reads it). Decided on the
-- PARSE: a `--` line inside a long string is code, and a file that does not parse is never neutral.

local CACHE = 'lua/cartograph/cache.lua'
local BEFORE = 'local M = {}\n-- the cache\nM.VERSION = 156 -- v156: a thing\nfunction M.f(x) return x + 1 end\nreturn M\n'

test('gatepredict (CART-0622): a VERSION bump and comment edits are OUTPUT-NEUTRAL, by construct', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local bump = BEFORE:gsub('M.VERSION = 156 %-%- v156: a thing', 'M.VERSION = 157 -- v157: another. v156: a thing')
    ok(gp.neutral(CACHE, BEFORE, bump), 'a VERSION bump with its comment is neutral')
    local comment = BEFORE:gsub('%-%- the cache', '-- the cache, now documented\n-- over two lines')
    ok(gp.neutral('lua/cartograph/store.lua', BEFORE, comment), 'a comment-only edit is neutral in ANY engine file')
end)

test('gatepredict (CART-0622): anything else stays an engine change — the rule is never "cache.lua is safe"', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local bumped_and_code = BEFORE:gsub('M.VERSION = 156', 'M.VERSION = 157'):gsub('x %+ 1', 'x + 2')
    eq(nil, gp.neutral(CACHE, BEFORE, bumped_and_code), 'a code change beside the bump is not neutral')
    eq(nil, gp.neutral('lua/cartograph/other.lua', BEFORE, (BEFORE:gsub('M.VERSION = 156', 'M.VERSION = 157'))),
        'VERSION is neutral only in cache.lua: elsewhere it may be read')
    eq(nil, gp.neutral(CACHE, BEFORE, (BEFORE:gsub('M.VERSION = 156', 'M.VERSION = os.time()'))),
        'a VERSION that is not a number literal is code')
    local S1 = 'local Q = [[\n-- a\n]]\nreturn Q\n'
    eq(nil, gp.neutral(CACHE, S1, (S1:gsub('%-%- a', '-- b'))), 'a `--` line inside a long string is CODE')
    eq(nil, gp.neutral(CACHE, BEFORE, BEFORE .. 'function (\n'), 'a file that does not parse is never neutral')
    -- ... even when error recovery still finds its comments and only they differ (an unclosed table: has_error, and
    -- the comment-stripped tokens are identical)
    eq(nil, gp.neutral(CACHE, 'local t = { 1, -- x\n 2 \nreturn t\n', 'local t = { 1, -- y\n 2 \nreturn t\n'),
        'a side with a parse error is never neutral, whatever its comments')
    -- the construct is the assignment TO M.VERSION: another number in cache.lua is code
    local WITH_LIMIT = BEFORE:gsub('return M', 'M.LIMIT = 8\nreturn M')
    eq(nil, gp.neutral(CACHE, WITH_LIMIT, (WITH_LIMIT:gsub('M.LIMIT = 8', 'M.LIMIT = 9'))),
        'a number assigned to anything but M.VERSION is code')
end)

test('gatepredict (CART-0622): a neutral file no longer forces scope=all — the other files set it', function ()
    local known, pl = registry()
    local neutral = { [CACHE] = 'VERSION bump' }
    local t = gp.touched({ CACHE, 'lua/cartograph/spec/lua.lua' }, known, pl, neutral)
    eq('langs', t.scope, 'cache.lua + a lua spec change: the spec sets the scope')
    ok(t.langs.lua, 'lua is reached')
    ok(t.why[CACHE]:find('output%-neutral'), t.why[CACHE])
    eq('none', gp.touched({ CACHE }, known, pl, neutral).scope, 'a bump alone moves nothing')
    eq('all', gp.touched({ CACHE }, known, pl).scope, 'without the neutral verdict, cache.lua still refuses to subtract')
end)
