-- CART-0403: a name in a NON-READ field is no variable read. lua's table constructor KEY (`{ k = 2 }`) and java's
-- annotation name (`@SuppressWarnings`) were counted as reads by du; a bracketed `{ [a] = 3 }` key is an expression
-- and is read. spec.nonread_fields names the field, flow.nonread_child decides (the bracket token), and BOTH df builders
-- ask it — the production one (flow) and the legacy one dfparity compares against — so they agree by construction.

local ts   = require 'cartograph.providers.treesitter'
local flow = require 'cartograph.flow'
local df   = require 'cartograph.df'

local function tree(rel, text)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    return root
end
local function uses(data, line, legacy)
    for _, n in ipairs(data.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            local rows = legacy and df.stmts(n) or flow.rows(n) or {}
            for _, r in ipairs(rows) do
                if r.l == line then local u = vim.deepcopy(r.use or {}); table.sort(u); return u end
            end
        end
    end
end

test('nonread: a lua constructor key is no read, a bracketed key is — on flow and on the legacy df (CART-0403)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree('m.lua', 'local function f(a)\n  local t = { 95, k = 2, [a] = 3, [k2] = k3 }\n  return t\nend\nreturn f\n')
    eq({ 'a', 'k2', 'k3' }, uses(ts.extract(root), 2), 'flow')
    eq({ 'a', 'k2', 'k3' }, uses(ts.extract(root, { legacy_df = true }), 2, true), 'the legacy df agrees')
    vim.fn.delete(root, 'rf')
end)

test('nonread: a java annotation name is no read, its argument is (CART-0403)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree('A.java', table.concat({
        'class A {',
        '  int f(int x) {',
        '    @SuppressWarnings(K) int y = x;',
        '    @Deprecated int z = y;',
        '    return z;',
        '  }',
        '}', '' }, '\n'))
    eq({ 'K', 'x' }, uses(ts.extract(root), 3), 'flow: the annotation argument K is read, its name is not')
    eq({ 'y' }, uses(ts.extract(root), 4), 'a marker annotation')
    eq({ 'K', 'x' }, uses(ts.extract(root, { legacy_df = true }), 3, true), 'the legacy df agrees')
    vim.fn.delete(root, 'rf')
end)
