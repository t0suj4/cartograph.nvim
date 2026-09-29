-- A GRAMMAR DERIVED FROM A CORPUS, EVERY TREE UP TO A SIZE (cartograph.grammargen), and the BOUNDED-EXHAUSTIVE
-- differential of the Lua→JS transliteration over it (cartograph.luajs.gencheck, CART-1206).
-- The grammar half is pinned on hand-written corpora (exact productions, count == enumeration, the two widenings);
-- the differential half is pinned as a POSITIVE CONTROL: the generator must SEE the bugs it exists for — a program
-- population that finds nothing is indistinguishable from a blind generator until a mutation shows it catching.
local GG = require 'cartograph.grammargen'
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') end
local function set(l) local s = {} for _, k in ipairs(l) do s[k] = true end return s end
local function each_text(F, k, n)
    local out = {}
    F.each(k, n, function (t) out[#out + 1] = GG.print(t) end)
    return out
end

test('grammargen: productions are READ OFF the corpus; COUNT equals ENUMERATION; a one-text leaf is a zero-slot production (bare `return`)', function ()
    if not ready() then skip 'no lua parser' end
    -- `,` is a repeated separator only where some list holds it TWICE (a one-`,` corpus has no evidence of repetition)
    local G = GG.derive({ { 'a', 'return x' }, { 'b', 'return' }, { 'c', 'do return 1, y, z end' } }, 'lua')
    eq(3, G.files)
    local rp = {}
    for _, p in ipairs(G.kinds.return_statement.prods) do rp[#rp + 1] = #p.slots end
    table.sort(rp)
    eq({ 0, 1 }, rp, 'return <list> and bare return')
    local F = GG.fragment(G, { kinds = set { 'chunk', 'return_statement', 'expression_list', 'do_statement', 'block' },
        atoms = { identifier = { 'x' }, number = { '1' } } })
    for n = 1, 6 do eq(F.count('chunk', n), #each_text(F, 'chunk', n), 'size ' .. n) end
    local all = {}
    for n = 1, 6 do for _, s in ipairs(each_text(F, 'chunk', n)) do all[#all + 1] = s end end
    ok(vim.tbl_contains(all, 'return'), vim.inspect(all))
    ok(vim.tbl_contains(all, 'return 1 , 1 , 1'), 'the run lends a number to every list position: ' .. vim.inspect(all))
    ok(not vim.tbl_contains(all, 'return x , x'), 'only list LENGTHS the corpus wrote (1 and 3): ' .. vim.inspect(all))
    for _, s in ipairs(all) do
        ok(not vim.treesitter.get_string_parser(s, 'lua'):parse()[1]:root():has_error(), 'every tree prints as parseable text: ' .. s)
    end
    eq({ 'if_statement' }, GG.fragment(G, { kinds = set { 'chunk', 'if_statement' } }).dead(), 'a selected kind with no production is NAMED')
end)

test('grammargen: a REPEATED run admits every kind seen anywhere in it; ALTERNATIVES (one token apart) share their slots; a fixed slot stays positional', function ()
    if not ready() then skip 'no lua parser' end
    -- the corpus writes `goto` only LAST and a label only FIRST; blocks of two lengths make the run a repetition
    local G = GG.derive({ { 'a', 'do ::l:: f() end do f() goto l end do f() f() f() end' }, { 'b', 'return a + b, a < 1' } }, 'lua')
    local F = GG.fragment(G, { kinds = set { 'block', 'goto_statement', 'label_statement' }, atoms = { identifier = { 'l' } } })
    ok(vim.tbl_contains(each_text(F, 'block', 5), 'goto l :: l ::'), 'goto BEFORE a label: ' .. vim.inspect(each_text(F, 'block', 5)))
    -- `a < 1` put a number on the RIGHT of `<` only; the alternation lends it to the right of `+`, position by position
    local F2 = GG.fragment(G, { kinds = set { 'binary_expression' }, atoms = { identifier = { 'a' }, number = { '1' } } })
    eq({ 'a + a', 'a + 1', 'a < a', 'a < 1' }, each_text(F2, 'binary_expression', 3))
    -- an `if` condition is not a run: a block never lands there
    local G3 = GG.derive({ { 'a', 'if x then y() end if x then y() z() end' } }, 'lua')
    local F3 = GG.fragment(G3, { kinds = set { 'if_statement', 'block' }, atoms = { identifier = { 'x' }, function_call = { 'y()' } } })
    for n = 1, 6 do
        for _, s in ipairs(each_text(F3, 'if_statement', n)) do ok(s:match('^if [xy()]+ then'), 'the condition slot stays an expression: ' .. s) end
    end
end)

test('grammargen: an ATOM\'s `#` is its occurrence number, a grammar TOKEN `#` is the length operator', function ()
    eq('p(1) # p(2)', GG.print({ { atom = 'p(#)' }, '#', { atom = 'p(#)' } }))
end)

-- the differential: one derivation of the repository's own Lua, shared by the cases below
local G_
local function repo_grammar()
    if G_ then return G_ end
    local files = vim.fs.find(function (n) return n:match('%.lua$') end, { path = REPO .. '/lua', type = 'file', limit = math.huge })
    table.sort(files) -- readdir order differs between machines, and batch composition follows it
    local src = {}
    for _, f in ipairs(files) do local fd = io.open(f); src[#src + 1] = { f, fd:read('a') }; fd:close() end
    G_ = GG.derive(src, 'lua')
    return G_
end

test('luajs gencheck: every CONTROL program to size 6 (derived from lua/) agrees with Lua under node — and the funnel shows every stage populated, gotos and backward loops included', function ()
    if not ready() or vim.fn.executable('node') ~= 1 then skip 'no lua parser / node' end
    local GC = require 'cartograph.luajs.gencheck'
    local res = assert(GC.run({ G = repo_grammar(), name = 'control', fragment = GC.FRAGMENTS.control, max = 6,
        dir = vim.fn.tempname(), repo = REPO }))
    local lines = {}
    for _, d in ipairs(res.diverged) do lines[#lines + 1] = ('[%s] %s\n  lua: %s\n  js:  %s'):format(d.class, d.text, d.lua, d.js) end
    eq(0, res.total.diverged, table.concat(lines, '\n'))
    -- the PREMISE: the comparison was not empty, and it held the constructs the claim is about
    ok(res.total.compared > 1000, 'compared ' .. res.total.compared)
    ok((res.tokens['goto'] or 0) > 0 and (res.tokens['::'] or 0) > 0, vim.inspect(res.tokens))
    ok((res.tokens['repeat'] or 0) > 0 and (res.tokens['while'] or 0) > 0 and (res.tokens['elseif'] or 0) > 0, vim.inspect(res.tokens))
end)

test('luajs gencheck: every VALUES program to size 6 agrees with Lua under node (0/1/2/n values through calls, lists, tables, varargs)', function ()
    if not ready() or vim.fn.executable('node') ~= 1 then skip 'no lua parser / node' end
    local GC = require 'cartograph.luajs.gencheck'
    local res = assert(GC.run({ G = repo_grammar(), name = 'values', fragment = GC.FRAGMENTS.values, max = 6,
        dir = vim.fn.tempname(), repo = REPO }))
    local lines = {}
    for _, d in ipairs(res.diverged) do
        -- ONLY the known gap is forgiven: the variable NAME LuaJIT puts in a message ("local 'f0' ", CART-1207). The
        -- Lua text with exactly that phrase stripped must equal the JS text — any other message change still fails
        local lua_ = (d.lua or ''):gsub("(attempt to %a+ )%a+ '[^']*' %(", '%1(')
        local plain = lua_:gsub('%(a (%a+) value%)', 'a %1 value')
        if not (d.class == 'message' and (plain == d.js or lua_ == d.js)) then
            lines[#lines + 1] = ('[%s] %s\n  lua: %s\n  js:  %s'):format(d.class, d.text, d.lua, d.js)
        end
    end
    eq('', table.concat(lines, '\n'))
    ok(res.total.compared > 500 and (res.tokens['...'] or 0) > 0 and (res.tokens['{'] or 0) > 0, vim.inspect(res.tokens))
end)
