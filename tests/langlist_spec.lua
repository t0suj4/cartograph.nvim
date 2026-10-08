-- the name join's language-partitioned candidate lists (M._lang_list, CART-1056): same members and order as filtering
-- per candidate, and never stale when the list grows; C and C++ are one linkage family (CART-1079).

local ts = require 'cartograph.providers.treesitter'

test('langlist: keeps only the asked language, in list order', function ()
    local list = { { id = 1, file = 'a/X.java' }, { id = 2, file = 'b/x.php' }, { id = 3, file = 'c/Y.java' } }
    local out = ts._lang_list(list, 'java')
    eq({ 1, 3 }, vim.tbl_map(function (n) return n.id end, out))
    eq({ 2 }, vim.tbl_map(function (n) return n.id end, ts._lang_list(list, 'php')))
end)

test('langlist: a call whose only candidates are in ANOTHER language has none — not `blocked` on them (CART-1568)', function ()
    for _, l in ipairs({ 'lua', 'javascript' }) do
        if not pcall(vim.treesitter.language.add, l) then skip('no ' .. l .. ' parser') end
    end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local function put(rel, text) local f = assert(io.open(root .. '/' .. rel, 'w')); f:write(text); f:close() end
    put('m.lua', table.concat({
        'local function f(s, n)',
        '    local a = s:sub(1)',          -- a TAIL match: STRING.sub in the JS file
        '    local b = n:named_child(0)',  -- the same, NODE.named_child
        '    return a, b, helper()',       -- an EXACT match: the JS function helper
        'end',
        'return f' }, '\n'))
    put('pack.js', 'const STRING = {}; STRING.sub = function (s) { return s }\nconst NODE = {}; NODE.named_child = function (i) { return i }\nfunction helper() { return 1 }\n')
    local function check(calls, how)
        local seen = 0
        for _, c in ipairs(calls) do
            if tostring(c.file):match('%.lua$') and (c.callee == 'sub' or c.callee == 'named_child' or c.callee == 'helper') then
                seen = seen + 1
                eq(nil, c.to, how .. ': ' .. c.callee .. ' never links into JS')
                eq(nil, c.refused, how .. ': ' .. c.callee .. ' is no refusal on a JS candidate: ' .. vim.inspect(c.refused))
            end
        end
        eq(3, seen, how .. ': the three Lua calls')
    end
    local data = ts.extract(root)
    check(data.calls, 'extraction')
    -- (the RELINK path has its own copy of the resolver, CART-1485: an incremental refresh must answer the same)
    local store = require 'cartograph.store'
    store.ingest(data)
    put('m.lua', (io.open(root .. '/m.lua'):read('a'):gsub('s:sub%(1%)', 's:sub(2)')))
    assert(require('cartograph.refresh').files({ 'm.lua' }, { incremental = true }))
    check(store.data.calls, 'refresh')
    vim.fn.delete(root, 'rf')
end)

test('langlist: a list that GREW is filtered again (a minted node appended after the first call)', function ()
    local list = { { id = 1, file = 'a/X.java' } }
    eq(1, #ts._lang_list(list, 'java'))
    list[#list + 1] = { id = 2, file = 'b/Z.java' }
    eq(2, #ts._lang_list(list, 'java'), 'a cached answer for the shorter list would drop the new node')
end)

test('langlist: C and C++ share one list (the linkage family); a .h file is in it whichever way set_h_lang reads it', function ()
    local prev = ts.h_lang()
    local list = { { id = 1, file = 'inc/a.h' }, { id = 2, file = 'src/b.c' }, { id = 3, file = 'src/c.cpp' },
        { id = 4, file = 'X.java' } }
    for _, h in ipairs({ 'c', 'cpp' }) do
        ts.set_h_lang(h)
        eq({ 1, 2, 3 }, vim.tbl_map(function (n) return n.id end, ts._lang_list(list, 'c')), 'h_lang ' .. h)
        eq({ 1, 2, 3 }, vim.tbl_map(function (n) return n.id end, ts._lang_list(list, 'cpp')), 'h_lang ' .. h)
    end
    ts.set_h_lang(prev)
end)
