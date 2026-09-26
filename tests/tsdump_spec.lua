-- tsdump: a parse with FIELD NAMES and ANONYMOUS TOKENS, and the diff between two builds of a grammar (the tool every
-- nvim 0.12 grammar ticket was settled with, as a throwaway, until it was one).

local tsdump = require 'cartograph.tsdump'

test('tsdump: prints fields, anonymous tokens and leaf text; --named drops the tokens', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local lines = tsdump.lines('local x = f(1)\n', 'lua')
    local text = table.concat(lines, '\n')
    ok(text:find('name: identifier [x]', 1, true), text)
    ok(text:find('"local"', 1, true), 'an anonymous keyword token is shown, quoted')
    ok(text:find('arguments: arguments', 1, true), 'a field label on a named child')
    local named = table.concat(tsdump.lines('local x = f(1)\n', 'lua', { anon = false }), '\n')
    ok(not named:find('"local"', 1, true), 'named-only drops anonymous tokens')
    eq('', tsdump.diff('local x = 1\n', 'lua', nil, nil), 'the same build: identical trees, empty diff')
end)

test('tsdump: an ERROR / MISSING parse is marked, never rendered as a clean tree', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local lines = tsdump.lines('local x = (\n', 'lua')
    eq('-- has_error', lines[1])
end)

test('tsdump: --vs diffs two parser builds of one grammar (nvim 0.11 bundled lua vs the current one)', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local old = vim.fn.expand('~/.local/share/bob/v0.11.5/lib/nvim/parser/lua.so')
    if not vim.uv.fs_stat(old) then skip 'no nvim 0.11 lua parser under bob' end
    local d = tsdump.diff('x = global.flag\n', 'lua', nil, old)
    ok(d:find('-        table: "global"', 1, true), d)
    ok(d:find('+        table: identifier [global]', 1, true), 'the 5.5 keyword against the pre-5.5 identifier')
    -- and the dialect VIEW turns the new build's reading back into an identifier (luadialect.lua)
    local v = table.concat(tsdump.lines('x = global.flag\n', 'lua', { view = true, dialect = '5.4' }), '\n')
    ok(v:find('table: identifier [global]', 1, true), 'text read from the original bytes: still `global`')
end)
