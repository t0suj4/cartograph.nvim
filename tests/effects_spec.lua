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
