-- treewalk: several visitors, ONE walk — each node materialized once, the ancestor stack handed down, a visitor's prune
-- its own, leave after the children, an iterative walk that a deep tree cannot overflow
local tw = require 'cartograph.treewalk'

local function root_of(src)
    return vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
end
local SRC = table.concat({
    'local function f(a) local g = function (b) return a + b end; return g(a) end',
    'local t = { k = 1, f(2) }',
    'return t',
}, '\n')

test('treewalk: two visitors share ONE walk — every named node handed over once, each node materialized once', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local root = root_of(SRC)
    -- the oracle: an independent recursive walk counting named nodes and identifiers
    local named, idents = 0, 0
    local function count(n)
        named = named + 1
        if n:type() == 'identifier' then idents = idents + 1 end
        for i = 0, n:named_child_count() - 1 do count(n:named_child(i)) end
    end
    count(root)
    local seen_any, seen_id = 0, 0
    local idx = getmetatable(root).__index
    local real, calls = idx.named_child, 0
    idx.named_child = function (self, i) calls = calls + 1; return real(self, i) end
    local okk, err = pcall(tw.walk, root, {
        { any = function () seen_any = seen_any + 1 end },
        { enter = { identifier = function () seen_id = seen_id + 1 end } },
    })
    idx.named_child = real
    ok(okk, tostring(err))
    eq(named, seen_any, 'the any-visitor saw every named node')
    eq(idents, seen_id, 'the typed visitor saw every identifier')
    eq(named - 1, calls, 'each node below the root materialized ONCE, for both visitors')
end)

test('treewalk: the ancestor stack is the path from the root; leave runs after the children, nested', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local root = root_of(SRC)
    local bad, log = 0, {}
    tw.solo(root, {
        any = function (n, _, anc, d)
            if anc[d] ~= n then bad = bad + 1 end
            -- (the parent node:parent() would return: an array read here)
            if d > 1 and anc[d - 1]:id() ~= n:parent():id() then bad = bad + 1 end
            if d == 1 and anc[1] ~= root then bad = bad + 1 end
        end,
        enter = { function_declaration = function () log[#log + 1] = '+decl' end,
            function_definition = function () log[#log + 1] = '+def' end },
        leave = { function_declaration = function () log[#log + 1] = '-decl' end,
            function_definition = function () log[#log + 1] = '-def' end },
    })
    eq(0, bad, 'anc[d] is the node, anc[d - 1] its parent, anc[1] the root')
    eq('+decl +def -def -decl', table.concat(log, ' '), 'the inner function opens and closes inside the outer one')
end)

test('treewalk: a prune is the visitor\'s own — the others still see the subtree; tokens = true visits anonymous nodes', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local root = root_of(SRC)
    local inside, all, left = 0, 0, 0
    tw.walk(root, {
        { enter = { function_declaration = function () return false end, identifier = function () inside = inside + 1 end },
            leave = { function_declaration = function () left = left + 1 end } },
        { enter = { identifier = function () all = all + 1 end } },
    })
    ok(all > inside, 'the pruning visitor saw fewer identifiers (' .. inside .. ') than the other (' .. all .. ')')
    eq(0, left, 'no leave for the node the visitor pruned at')
    -- every identifier outside the function: `t` twice, the key `k`, `f` in the call
    eq(4, inside, 'the pruner still sees the rest of the file')
    local toks = 0
    tw.solo(root, { tokens = true, any = function (n) if not n:named() then toks = toks + 1 end end })
    ok(toks > 0, 'anonymous children visited with tokens = true: ' .. toks)
    local none = 0
    tw.solo(root, { any = function (n) if not n:named() then none = none + 1 end end })
    eq(0, none, 'and not by default')
end)

test('treewalk: a 5000-deep tree is walked without overflowing (iterative, CART-1082)', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local src = 'return ' .. string.rep('(', 5000) .. '1' .. string.rep(')', 5000)
    local root = root_of(src)
    local deepest = 0
    local okk, err = pcall(tw.solo, root, { any = function (_, _, _, d) if d > deepest then deepest = d end end })
    ok(okk, tostring(err))
    ok(deepest > 5000, 'reached the bottom: depth ' .. deepest)
end)
