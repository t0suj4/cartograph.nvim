-- A TYPED RECEIVER'S CALLS ARE ITS TYPE'S (CART-1621, local type inference — the rung that paid). The member-evidence
-- pass (typed_receiver, CART-1570) types a receiver from the methods called on it; its UNRESOLVED calls carry that
-- type too (they are external either way), and effects read the type's contract: a file handle's write / close are
-- the world (file.* -> io), a tree-sitter node's methods read its tree (TSNode.* -> pure). Before, each such call was
-- "unresolved" — a hedge on every function holding a file or a node.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local effects = require 'cartograph.effects'

local function tree(files)
    local root = vim.fn.tempname()
    for rel, src in pairs(files) do
        vim.fn.mkdir((root .. '/' .. rel):match('^(.*)/[^/]+$'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close()
    end
    return root
end

test('typed receiver: a file handle and a tree-sitter node type their unresolved calls, and effects read the type', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['plugin/x.lua'] = '-- (the nvim-plugin shape: the nvim profile, with the base luajit one)\n',
        ['lua/x/m.lua'] = table.concat({
            'local M = {}',
            'function M.save(path, text)',
            '  local fd = io.open(path, "w")',
            '  fd:write(text)',
            '  fd:close()',
            'end',
            'function M.up(n)',
            '  return n:named_child_count(), n:parent()',
            'end',
            'return M',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    vim.fn.delete(root, 'rf')
    local cv = require('cartograph.callview').of(store.data)
    local ty = {}
    for i = 1, cv.n do
        local e = cv.get(i, 'ext')
        ty[tostring(cv.get(i, 'full') or cv.get(i, 'callee'))] = type(e) == 'table' and e.type or false
    end
    eq('file', ty['fd:write'], 'write: a member only file declares')
    eq('file', ty['fd:close'], 'close: no project def — the group\'s type stamps it too')
    eq('TSNode', ty['n:parent'], 'parent: unresolved, typed by its group (n:named_child_count is TSNode\'s alone)')
    local by = {}
    for _, n in ipairs(store.data.nodes) do by[n.name] = n end
    eq('io', effects.purity(store, by['M.save'].id), 'file.write / file.close: the world, exactly')
    eq('pure', effects.purity(store, by['M.up'].id), 'TSNode methods read the tree: no hedge')
end)

-- ⚠ ONE NAME'S BARE DECLARATION IS NOT ANOTHER'S (found while indexing local_all's reassignment scan, CART-1621): any
-- `local x` with no value, of ANY name, in the declaring scope had failed every string typing there
test('string typing: a bare `local other` in the scope does not untype `s`', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['m.lua'] = 'local function f(y)\n  local other\n  local s = "x" .. y\n  return s:upper(), other\nend\nreturn f\n' })
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local fulls = {}
    for _, c in ipairs(data.calls) do fulls[#fulls + 1] = tostring(c.full or c.callee) end
    ok(vim.tbl_contains(fulls, 'string.upper'), 's is only ever a string: ' .. table.concat(fulls, ' '))
end)

-- (CART-1887: A TYPED RECEIVER WITHDRAWS A RESOLVED WRONG JOIN TOO. `c:named()` had already joined BY NAME (inferred)
-- to a project class's `Band:named` — the pass only typed calls left unresolved, so the edge stayed: 634 such on our
-- tree, every one a tree-sitter node's method landing in band.lua or a test's mock. The group's other member
-- (named_child_count, TSNode's alone) types c; the joined call is withdrawn — no call target, no ref edge. A receiver
-- the profile does NOT type (`bd:named("k")`: TSNode and Band both fit) keeps its join)
test('typed receiver: an inferred name-join on a typed receiver is withdrawn, call and ref edge (CART-1887)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['plugin/x.lua'] = '-- (the nvim-plugin shape)\n',
        ['lua/x/band.lua'] = table.concat({
            'local Band = {}',
            'Band.__index = Band',
            'function Band:named(name) return { name } end',
            'return Band' }, '\n'),
        ['lua/x/m.lua'] = table.concat({
            'local M = {}',
            'function M.kids(c)',
            '  if c:named() then return c:named_child_count() end',
            'end',
            'function M.real(bd)',
            '  return bd:named("k")',
            'end',
            'return M' }, '\n'),
    })
    store.ingest(ts.extract(root))
    vim.fn.delete(root, 'rf')
    local cv = require('cartograph.callview').of(store.data)
    local row = {}
    for i = 1, cv.n do
        local e = cv.get(i, 'ext')
        row[tostring(cv.get(i, 'full') or cv.get(i, 'callee'))] = { to = cv.get(i, 'to'), ty = type(e) == 'table' and e.type or nil }
    end
    eq(nil, row['c:named'].to, 'the wrong join withdrawn')
    eq('TSNode', row['c:named'].ty, 'and typed: a TSNode method')
    eq('lua/x/band.lua::Band:named@2', row['bd:named'].to, 'an untyped receiver keeps its join')
    local from = {}
    for _, e in ipairs(store.data.edges) do
        if e.kind == 'ref' and e.to == 'lua/x/band.lua::Band:named@2' then from[#from + 1] = e.from end
    end
    table.sort(from)
    eq({ 'lua/x/m.lua::M.real@4' }, from, 'Band:named\'s only caller is M.real: the withdrawn edge is gone')
end)

test('typed receiver: an incremental refresh withdraws the same join, call and edge (CART-1887)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local M_SRC = table.concat({
        'local M = {}',
        'function M.kids(c)',
        '  if c:named() then return c:named_child_count() end',
        'end',
        'function M.real(bd)',
        '  return bd:named("k")',
        'end',
        'return M' }, '\n')
    local root = tree({
        ['plugin/x.lua'] = '-- (the nvim-plugin shape)\n',
        ['lua/x/band.lua'] = 'local Band = {}\nBand.__index = Band\nfunction Band:named(name) return { name } end\nreturn Band',
        ['lua/x/m.lua'] = M_SRC,
    })
    store.ingest(ts.extract(root))
    local fd = assert(io.open(root .. '/lua/x/m.lua', 'w')); fd:write((M_SRC:gsub('"k"', '"j"'))); fd:close()
    assert(require('cartograph.refresh').files({ 'lua/x/m.lua' }, { incremental = true }))
    vim.fn.delete(root, 'rf')
    local cv = require('cartograph.callview').of(store.data)
    local to = {}
    for i = 1, cv.n do to[tostring(cv.get(i, 'full') or cv.get(i, 'callee'))] = cv.get(i, 'to') or false end
    eq(false, to['c:named'], 'withdrawn after the refresh too')
    local from = {}
    for _, e in ipairs(store.data.edges) do
        if e.kind == 'ref' and e.to == 'lua/x/band.lua::Band:named@2' then from[#from + 1] = e.from end
    end
    eq({ 'lua/x/m.lua::M.real@4' }, from, 'and no edge from M.kids')
end)
