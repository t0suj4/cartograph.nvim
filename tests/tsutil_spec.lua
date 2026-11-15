-- tsutil.parent: node:parent(), memoized — the same answer as the uncached call, nil at the root, and never an entry
-- that belongs to another tree (an id is only unique among LIVE trees; a hit must equal the child it was stored for)
local tsutil = require 'cartograph.spec.tsutil'

local function root_of(src) return vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root() end

test('tsutil.parent: agrees with node:parent() at every node, twice (the second time from the memo); nil at the root', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    tsutil.parent_reset()
    local root = root_of('local function f(a) if a then return a.b[1] end end\nreturn { f = f }')
    local nodes = {}
    local function col(n) nodes[#nodes + 1] = n; for _, c in tsutil.inext, n, -1 do col(c) end end
    col(root)
    for pass = 1, 2 do
        local bad = 0
        for _, n in ipairs(nodes) do
            local want, got = n:parent(), tsutil.parent(n)
            if (want == nil) ~= (got == nil) or (want and want:id() ~= got:id()) then bad = bad + 1 end
        end
        eq(0, bad, 'pass ' .. pass .. ': every node\'s parent as node:parent() answers')
    end
    eq(nil, tsutil.parent(root), 'the root has none')
end)

test('tsutil.parent: a memo entry is never served for a node of ANOTHER tree, even under the same id', function ()
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    tsutil.parent_reset()
    local a = root_of('local x = 1')
    local na = a:named_child(0):named_child(0) -- (some inner node of tree A)
    -- forge the collision: an entry under B's node id that holds A's node — what a freed tree's reused id would leave
    local b = root_of('local y = 2')
    local nb = b:named_child(0):named_child(0)
    local idx = getmetatable(nb).__index
    local saved = idx.id
    idx.id = function (self) if self == nb or self == na then return 'same' end return saved(self) end
    tsutil.parent_reset()
    tsutil.parent(na) -- stored under 'same', for A's node
    local got = tsutil.parent(nb) -- B's node under the same id
    idx.id = saved
    ok(got and got:id() == nb:parent():id(), 'B\'s node got B\'s parent, not the entry stored for A\'s node')
end)

-- CART-1114: tsutil defined M.unparen TWICE and the narrower copy, assigned last, won — ruby's parenthesized_statements
-- was never peeled. One definition now, peeling a wrapper only when it holds exactly one non-comment named child.
test('tsutil.unparen: ONE definition peels ruby / c / c++ wrappers; a comment is skipped, a multi-child wrapper stays (CART-1114)', function ()
    for _, l in ipairs({ 'ruby', 'c', 'cpp' }) do
        if not pcall(vim.treesitter.language.add, l) then skip('no ' .. l .. ' parser') end
    end
    -- the condition of every if / while in `src`, unparened, as its node type
    local function conds(lang, src)
        local out = {}
        local function walk(n)
            if n:type() == 'if' or n:type() == 'while' or n:type() == 'if_statement' or n:type() == 'while_statement' then
                local u = tsutil.unparen(n:field('condition')[1])
                out[#out + 1] = u and u:type() or 'nil'
            end
            for _, c in tsutil.inamed, n, -1 do walk(c) end
        end
        walk(vim.treesitter.get_string_parser(src, lang):parse()[1]:root())
        return out
    end
    eq({ 'identifier', 'parenthesized_statements', 'true' },
        conds('ruby', 'if (a) then b end\nif (x = 1; x) then b end\nwhile (true) do end\n'))
    eq({ 'identifier', 'identifier' }, conds('c', 'void f(){ if ((x)) {} if (/*c*/ w) {} }'))
    eq({ 'identifier', 'condition_clause', 'identifier', 'identifier' },
        conds('cpp', 'void f(){ if (x) {} if (int y = g(); y) {} while (z) {} if (/*c*/ w) {} }'))
    local defs = 0
    for line in io.lines('lua/cartograph/spec/tsutil.lua') do
        if line:match('^%s*function%s+M%.unparen%s*%(') or line:match('^%s*M%.unparen%s*=') then defs = defs + 1 end
    end
    eq(1, defs, 'exactly one M.unparen definition in tsutil.lua')
end)
