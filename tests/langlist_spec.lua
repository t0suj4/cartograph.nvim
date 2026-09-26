-- the name join's language-partitioned candidate lists (M._lang_list, CART-1056): same members and order as filtering
-- per candidate, and never stale when the list grows or a `.h` file changes language.

local ts = require 'cartograph.providers.treesitter'

test('langlist: keeps only the asked language, in list order', function ()
    local list = { { id = 1, file = 'a/X.java' }, { id = 2, file = 'b/x.php' }, { id = 3, file = 'c/Y.java' } }
    local out = ts._lang_list(list, 'java')
    eq({ 1, 3 }, vim.tbl_map(function (n) return n.id end, out))
    eq({ 2 }, vim.tbl_map(function (n) return n.id end, ts._lang_list(list, 'php')))
end)

test('langlist: a list that GREW is filtered again (a minted node appended after the first call)', function ()
    local list = { { id = 1, file = 'a/X.java' } }
    eq(1, #ts._lang_list(list, 'java'))
    list[#list + 1] = { id = 2, file = 'b/Z.java' }
    eq(2, #ts._lang_list(list, 'java'), 'a cached answer for the shorter list would drop the new node')
end)

test('langlist: set_h_lang invalidates it (a .h file is C or C++ by the tree, not the extension)', function ()
    local prev = ts.h_lang()
    local list = { { id = 1, file = 'inc/a.h' } }
    ts.set_h_lang('c')
    eq(1, #ts._lang_list(list, 'c'))
    eq(0, #ts._lang_list(list, 'cpp'))
    ts.set_h_lang('cpp')
    eq(0, #ts._lang_list(list, 'c'), 'the C answer must not survive the switch')
    eq(1, #ts._lang_list(list, 'cpp'))
    ts.set_h_lang(prev)
end)
