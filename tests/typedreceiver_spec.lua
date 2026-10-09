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
