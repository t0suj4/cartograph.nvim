-- CART-0419: an IN-TREE named import (`import {N1, N2 as N3} from './a'`) or destructured require
-- (`const {N2: Q} = require('./c')`) binds each local to a MEMBER of the target; the import edge records it
-- (`members`), and a bare call through the local resolves to that member's def. A parameter of the same name shadows
-- it. On ghost core: 768 calls resolved (716 had been refused ambiguous, 52 silent), 0 redirected.

local ts = require 'cartograph.providers.treesitter'

local FILES = {
    ['a.js'] = 'export function N2() { return 1 }\nexport function N1() { return 2 }\n',
    ['c.js'] = 'function N2() { return 3 }\nmodule.exports = { N2 }\n',
    ['d.js'] = 'export function N1() { return 9 }\n', -- a second N1: the name join alone is ambiguous
    ['b.js'] = table.concat({
        "import {N1, N2 as N3} from './a'",             -- 0
        "const {N2: Q} = require('./c')",               -- 1
        'function f() { return N1() + N3() + Q() }',   -- 2
        'function g(N1) { return N1() }',               -- 3 a parameter shadows the import
        '', }, '\n'),
}
local function tree()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(FILES) do
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local function check(data, how)
    local got = {}
    for _, c in ipairs(data.calls) do if c.file == 'b.js' then got[c.line .. ' ' .. c.callee] = c end end
    eq('a.js::N1@1', got['2 N1'].to, how .. ': N1 is a.js\'s, never d.js\'s')
    eq('a.js::N2@0', got['2 N3'].to, how .. ': N3 is a.js\'s N2')
    eq('c.js::N2@0', got['2 Q'].to, how .. ': Q is c.js\'s N2')
    eq(nil, got['2 N1'].inferred, how .. ': the import line names it')
    ok(got['3 N1'].to ~= 'a.js::N1@1', how .. ': a parameter shadows the import: ' .. tostring(got['3 N1'].to))
end

test('import member: a named / destructured in-tree import binds its members, and a bare call reaches them (CART-0419)', function ()
    if not parser_available('javascript') then skip 'no javascript parser' end
    local root = tree()
    local data = ts.extract(root); data.root = root
    local mem
    for _, e in ipairs(data.edges) do if e.kind == 'import' and e.to == 'a.js' then mem = e.members end end
    eq({ N1 = 'N1', N3 = 'N2' }, mem, 'the edge records the members')
    check(data, 'extract')
    for _, c in ipairs(data.calls) do c.to = nil; c.refused = nil; c.prov = nil; c.inferred = nil end
    ts.relink(data)
    check(data, 'relink')
    vim.fn.delete(root, 'rf')
end)

test('import member: parallel extraction agrees (CART-0419)', function ()
    if not parser_available('javascript') then skip 'no javascript parser' end
    local root = tree()
    local done
    require('cartograph.parallel').extract(root, { workers = 2, on_done = function (d) done = d end })
    vim.wait(120000, function () return done ~= nil end, 50)
    ok(done, 'parallel finished')
    check(done, 'parallel')
    vim.fn.delete(root, 'rf')
end)
