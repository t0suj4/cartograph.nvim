-- CART-1067: ANON_AT (a callback argument's position -> the function node it became) is scoped to ONE
-- file. It was module-level and never cleared, so the editor session and the MCP server kept every
-- callback position of every extraction for the life of the process.

local ts = require 'cartograph.providers.treesitter'

local FIX = vim.fn.getcwd() .. '/tests/fixtures/anonat'

local function has_lua()
    return pcall(vim.treesitter.language.add, 'lua')
end

local function resolved(data)
    local by_file = {}
    for _, c in ipairs(data.calls or {}) do
        for _, a in ipairs(c.argv or {}) do
            if a.k == 'func' and a.to then by_file[c.file] = (by_file[c.file] or 0) + 1 end
        end
    end
    return by_file
end

test('anon_at: every file still links its callback arguments, and the table holds ONE file\'s positions after', function ()
    if not has_lua() then skip 'no lua parser' end
    local data = ts.extract(FIX)
    local got = resolved(data)
    eq(2, got['a.lua'], 'pcall(function) and vim.tbl_map(function, xs) in a.lua')
    eq(1, got['b.lua'], 'pcall(function) in b.lua')
    ok(ts._anon_at_count() <= 2, 'only the last file extracted: ' .. ts._anon_at_count())
end)

test('anon_at: a later extraction of OTHER files does not keep the first one\'s positions', function ()
    if not has_lua() then skip 'no lua parser' end
    ts.extract(FIX)
    -- re-extracting the SAME files rewrites the same keys and proves nothing: a different tree
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, 'p')
    vim.fn.writefile({ 'local M = {}', 'function M.once() return pcall(function() return 1 end) end', 'return M' }, d .. '/c.lua')
    local got = resolved(ts.extract(d))
    eq(1, got['c.lua'])
    eq(1, ts._anon_at_count(), 'only c.lua\'s one callback')
    vim.fn.delete(d, 'rf')
end)

-- CART-1056: elang_for is memoized PER FILE (the resolver asked it once per call x candidate pair: 32% of samples on
-- hive). The memo must never hold a stale `.h` answer: set_h_lang resets it.
test('elang memo: a .h file follows set_h_lang, never a stale per-file answer', function ()
    local was = ts.h_lang()
    ts.set_h_lang('c')
    eq('c', ts.lang_of('x/stale.h'))
    ts.set_h_lang('cpp')
    eq('cpp', ts.lang_of('x/stale.h'), 'the per-file memo was reset with the .h decision')
    ts.set_h_lang(was)
end)
