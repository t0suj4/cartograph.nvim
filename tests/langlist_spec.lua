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

test('the PROFILE TYPES A RECEIVER: a member only TSNode has makes `n` a TSNode, so `n:type()` is TSNode#type, not a join over the project\'s own `type` methods; no unique member, or two naming different types, types nothing (CART-1570)', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    -- (an nvim-PLUGIN layout: the shape that activates the nvim profile — it is no environment to override with)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/plugin', 'p'); vim.fn.mkdir(root .. '/lua', 'p')
    local function put(rel, text) local f = assert(io.open(root .. '/' .. rel, 'w')); f:write(text); f:close() end
    put('plugin/x.lua', '')
    put('lua/ir.lua', 'local S = {}\nlocal Mod, P = {}, {}\nfunction Mod:type() S.t = 1 end\nfunction P:type() return 2 end\n'
        .. 'function Mod:frob() end\nfunction P:frob() end\nfunction Mod:child_count() return 0 end\n'
        .. 'local Band, Client = {}, {}\nfunction Band:named() return true end\nfunction Client:close() S.c = 1 end\nfunction Client:call() end\n'
        .. 'local Other = {}\nfunction Other:close() end\nfunction Other:call() end\nreturn { Mod, P, Band, Client, Other }')
    put('lua/m.lua', table.concat({
        'local function typed(n)',
        '    local c = n:named_child(0)',   -- only TSNode declares named_child, and no Lua file here defines it
        '    return c, n:type(), n:frob()', -- (frob: no member of TSNode — its join stands)
        'end',
        'local function owned(z)',
        '    local k = z:child_count()',    -- TSNode's only — but THIS project defines a child_count: no evidence
        '    return k, z:type()',
        'end',
        'local function duck(w)',
        '    if w:named() then return w:type() end', -- no member unique to TSNode (Band defines named) — but only TSNode has BOTH
        'end',
        'local function proj(k)',
        '    k:call()',                    -- a PROJECT class fits (Client has close and call) …
        '    return k:close()',             -- … and so does Other: no single fit, and a project fit would not answer anyway
        'end',
        'local function fh(path)',
        '    local f = io.open(path, "w")',
        '    f:write("x")',
        '    return f:close()',             -- the BASE profile\'s file has write AND close; no project class has both
        'end',
        'local function untyped(x)',
        '    return x:type()',              -- nothing else called on x
        'end',
        'local function torn(y)',
        '    local a = y:named_child(0)',   -- TSNode's …
        '    local b = y:included_ranges()', -- … and TSTree's: two types, no answer
        '    return a, b, y:type()',
        'end',
        'return { typed, owned, duck, proj, fh, untyped, torn }' }, '\n'))
    local data = ts.extract(root)
    eq('nvim', data.profile, 'the plugin shape activates the nvim profile')
    vim.fn.delete(root, 'rf')
    local got = {}
    for _, c in ipairs(data.calls) do
        if c.file == 'lua/m.lua' and (c.callee == 'type' or c.callee == 'frob' or c.callee == 'close') then got[tostring(c.full)] = c end
    end
    eq('typed-receiver', got['n:type'] and got['n:type'].ext and got['n:type'].ext.why, vim.inspect(got['n:type']))
    eq('TSNode', got['n:type'].ext.type)
    eq(nil, got['n:type'].refused)
    eq('ambiguous', got['x:type'] and got['x:type'].refused and got['x:type'].refused.rule, 'no evidence: the join stands')
    eq('ambiguous', got['y:type'] and got['y:type'].refused and got['y:type'].refused.rule, 'two types: no answer')
    eq('ambiguous', got['z:type'] and got['z:type'].refused and got['z:type'].refused.rule, 'a member the project defines is no evidence')
    eq('ambiguous', got['n:frob'] and got['n:frob'].refused and got['n:frob'].refused.rule, 'a typed receiver keeps the join of a member its type lacks')
    eq('TSNode', got['w:type'] and got['w:type'].ext and got['w:type'].ext.type, 'STRUCTURE: the one type with named AND type')
    eq('ambiguous', got['k:close'] and got['k:close'].refused and got['k:close'].refused.rule, 'two project classes fit: the join stands')
    eq('file', got['f:close'] and got['f:close'].ext and got['f:close'].ext.type, 'the base profile types a file handle: ' .. vim.inspect(got['f:close']))
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
