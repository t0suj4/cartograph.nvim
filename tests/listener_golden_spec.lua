-- Golden test for the listener audit over the WHOLE pipeline: run the real
-- --graph CLI (which now emits the call inventory) on a fixture with deliberate
-- wiretap bugs, then lint. Self-skips if the CLI isn't installed.

local store = require 'cartograph.store'
local lint  = require 'cartograph.lint'

local BIN = vim.fn.expand '~/.local/lib/lua-language-server/bin/lua-language-server'
local CLI = vim.fn.expand '~/.local/lib/lua-language-server/script/cli/graph.lua'
local function q(s) return "'" .. s .. "'" end

test('listener-audit: catches the wiretap bugs end-to-end (extract -> lint)', function ()
    if vim.fn.executable(BIN) == 0 or vim.fn.filereadable(CLI) == 0 then
        skip 'graph CLI not installed'
    end
    local dir = vim.fn.getcwd() .. '/tests/fixtures/listener'
    local out = vim.fn.tempname()
    os.execute(table.concat({
        q(BIN), '--graph=' .. q(dir), '--graphout=' .. q(out),
        '--logpath=' .. q(out .. 'log'), '>/dev/null 2>&1',
    }, ' '))
    store.load(out .. '.json')

    local findings = lint.run(store, { only = { ['listener-audit'] = true } })
    local blob = ''
    for _, f in ipairs(findings) do blob = blob .. f.message .. '\n' end

    ok(blob:match("subscribe to 'on_tikc'"),        'typo subscribe to unregistered name')
    ok(blob:match("'on_build' is registered but never subscribed"), 'dead registration')
    ok(blob:match("'on_tick' is subscribed but never unsubscribed"), 'leak')
    ok(blob:match("on_lazy.*registered inside a function"),          'lazy registration')
end)
