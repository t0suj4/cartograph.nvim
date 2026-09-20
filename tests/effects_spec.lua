-- Golden test for the extractor's load-time `effects` detection. Runs the real
-- `--graph` CLI on tests/fixtures/effects and asserts the effects flag per file.
-- This is the layer where the _ENV-chain bug lived (a global write misread as
-- internal), so it exercises real Lua through lua-ls's parser, not a stand-in.
--
-- Self-skips when the graph CLI isn't installed (the CLI is kept as a durable
-- but inactive pkgit patch, so it may be absent in a clean environment).

local store = require 'cartograph.store'

local BIN = vim.fn.expand '~/.local/lib/lua-language-server/bin/lua-language-server'
local CLI = vim.fn.expand '~/.local/lib/lua-language-server/script/cli/graph.lua'

local function q(s) return "'" .. s .. "'" end

test('extractor: load-time effects are detected per module', function ()
    if vim.fn.executable(BIN) == 0 or vim.fn.filereadable(CLI) == 0 then
        skip 'graph CLI not installed'
    end

    local dir = vim.fn.getcwd() .. '/tests/fixtures/effects'
    local out = vim.fn.tempname()
    local cmd = table.concat({
        q(BIN), '--graph=' .. q(dir), '--graphout=' .. q(out),
        '--logpath=' .. q(out .. 'log'), '>/dev/null 2>&1',
    }, ' ')
    os.execute(cmd)

    local jsonpath = out .. '.json'
    ok(vim.fn.filereadable(jsonpath) == 1, 'graph CLI produced ' .. jsonpath)
    store.load(jsonpath)

    local expected = {
        ['pure.lua']          = false, -- only locals + return
        ['global_field.lua']  = true,  -- table.x = ... (the _ENV-chain case)
        ['global_assign.lua'] = true,  -- global = ...
        ['barecall.lua']      = true,  -- bare call statement
        ['value_require.lua'] = false, -- value require, no bare call, no globals
    }
    for file, want in pairs(expected) do
        local m = store.by_id[file]
        ok(m ~= nil, 'module node present for ' .. file)
        eq(want, m.effects, 'effects flag for ' .. file)
    end
end)

-- ── THE LANGUAGE GATE ON LITERAL TRUTHINESS (CART-0304) ─────────────────────
-- `truthy_of` modelled lua in an `if` and let PHP be the FALL-THROUGH, so every
-- language `lang_of` cannot name was given php's falsiness. Ruby is the sharpest
-- witness: `0` is TRUTHY there and falsy in php, so a guarded write reached with
-- a literal 0 was reported as 'skips' — a hard claim that the write does not
-- happen, about a write that does.
--
-- ⚠ AND IT WAS LATENT, WHICH IS WHY THE TEST DRIVES `verdict` DIRECTLY. `gp` rides
-- a var_uses edge and the write classifier populates those for lua alone today
-- (measured: self 21763 uses / 7 gp, ruby 0, jquery 0), so no corpus can reach the
-- wrong arm and no gate would ever have gone red. A unit test on the function is
-- the ONLY thing that can hold this until the write axis reaches a second
-- language — which is exactly when the defect would have shipped an answer.
--
-- PINNED ON BOTH SIDES. A test that only asserted ruby would pass against a
-- truthy_of that returned nil for EVERYTHING, which would throw away the two
-- languages the discharge exists for; so php's 'skips' and lua's fall-through
-- are asserted in the same test.
test('effects: literal truthiness is claimed only for the languages it models', function ()
    local effects = require 'cartograph.effects'
    -- the guarded-write use: writes, and only when param 1 is truthy
    local u = { rw = 2, gp = 1 }
    -- the call site: one scalar argument, the literal 0
    local c = { argv = { { k = 'scalar', v = '0' } } }

    eq('may-write', effects.verdict(u, c, 'app/models/thing.rb'),
        'ruby: 0 is TRUTHY there and this module does not model ruby — unknown, not skips')
    eq('may-write', effects.verdict(u, c, 'src/thing.js'),
        'javascript is not modelled either, and gets the same unknown')
    eq('skips', effects.verdict(u, c, 'src/Thing.php'),
        'php IS modelled: 0 is falsy, so the guarded write provably does not fire')
    -- lua: '0' is truthy, so the predicate PASSES and the verdict falls through to
    -- the gw tier rather than returning 'skips' — the discharge still happens
    ok(effects.verdict(u, c, 'lua/thing.lua') ~= 'skips',
        'lua IS modelled: 0 is truthy, so the write is not ruled out')
end)

-- and the string arm has the same shape and the same hole
test('effects: a string literal is judged only where the language is modelled', function ()
    local effects = require 'cartograph.effects'
    local u = { rw = 2, gp = 1 }
    local c = { argv = { { k = 'lit', v = '0' } } }
    eq('may-write', effects.verdict(u, c, 'app/models/thing.rb'),
        "ruby: the string '0' is truthy there, and unmodelled here")
    eq('skips', effects.verdict(u, c, 'src/Thing.php'),
        "php IS modelled: '0' is one of its falsy strings")
end)
