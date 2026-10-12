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
