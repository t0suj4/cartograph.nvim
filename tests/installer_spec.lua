-- THE INSTALLER FAMILY (CART-1493): a part file `return function (M, SHARED) … end`, installed by a host's
-- `require('part')(M, PARTS)`, writes the HOST'S table — the algebra's sixteen parts and core. `M.node` in a part is the
-- family's one `M.node`, not every `M.node` in the tree. Pinned both ways: a part installed by TWO hosts joins no family
-- (which table it writes is the run's), so its call stays refused.

local ts = require 'cartograph.providers.treesitter'

local FILES = {
    ['host.lua'] = table.concat({ 'local M = {}', 'function M.node(x) return x end', 'local function key(p) return p end',
        'local PARTS = { key = key, other = M }', "require('part')(M, PARTS)",
        "require('part2')(M)", 'function M.both(x) return x end', 'return M', '' }, '\n'),
    -- (a rival bare `key` elsewhere: by name alone a part's `key()` would be ambiguous)
    ['rivalkey.lua'] = 'local function key(p) return -p end\nreturn key\n',
    ['part2.lua'] = table.concat({ 'return function (M)', '  function M.call(x) return M.both(x) end', 'end', '' }, '\n'),
    ['rival.lua'] = table.concat({ 'local M = {}', 'function M.node(x) return -x end', 'function M.twin(x) return x end', 'return M', '' }, '\n'),
    ['part.lua'] = table.concat({ 'return function (M, SHARED)', '  local key = SHARED.key', '  function M.use(x) return M.node(x) end',
        '  function M.k(p) return key(p) end',
        '  function M.both(x) return x end', 'end', '' }, '\n'),
    ['shared.lua'] = table.concat({ 'return function (T)', '  function T.go(x) return T.twin(x) end', 'end', '' }, '\n'),
    ['h1.lua'] = table.concat({ 'local A = {}', 'function A.twin(x) return x end', "require('shared')(A)", 'return A', '' }, '\n'),
    ['h2.lua'] = table.concat({ 'local B = {}', 'function B.twin(x) return x end', "require('shared')(B)", 'return B', '' }, '\n'),
}

local function calls()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, src in pairs(FILES) do local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close() end
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local cv = require('cartograph.callview').of(data)
    local by = {}
    for i = 1, cv.n do
        local r = cv.get(i, 'refused')
        by[tostring(cv.get(i, 'file')) .. ' ' .. tostring(cv.get(i, 'full') or cv.get(i, 'callee'))] =
            { to = cv.get(i, 'to'), inferred = cv.get(i, 'inferred'), refused = type(r) == 'table' and r.rule or r }
    end
    return by
end

test('installer family: `M.node` in a part installed by `require(\'part\')(M, …)` is the HOST\'s M.node — not the rival module\'s (CART-1493)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local by = calls()
    eq('host.lua::M.node@1', by['part.lua M.node'].to)
    eq(true, by['part.lua M.node'].inferred, 'hedged ~, like a module alias')
    -- (two members define M.both — the host and the part: whichever runs last owns the field, so no pick)
    eq(nil, by['part2.lua M.both'].to, 'a member defined twice in the family is not picked')
end)

test('installer family: a part\'s `local key = SHARED.key` is the host\'s `PARTS = { key = key }` local — the bare `key()` reaches host.lua\'s key, not the rival file\'s (CART-1497)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local by = calls()
    eq('host.lua::key@2', by['part.lua key'].to)
end)

test('installer family: a part installed by TWO hosts joins no family — its `T.twin` stays refused (CART-1493)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local by = calls()
    eq(nil, by['shared.lua T.twin'].to)
end)