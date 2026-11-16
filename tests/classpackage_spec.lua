-- CART-2074: a java `Class::m` call whose class name exists in two packages resolved to neither — `u.foo()` with `U u`
-- in package b, where a.U and b.U both declare foo(), was refused ambiguous. Java decides which `U` the simple name
-- means: the single-type IMPORT, else the SAME PACKAGE's top-level class. elasticsearch libs: 6 calls refused ->
-- resolved, 0 others moved (ConsoleUtil, FastMath x2 by package; an imported nested Descriptor, an imported
-- MainInstrumentationProvider).

local ts = require 'cartograph.providers.treesitter'

local function calls(files)
    local root = vim.fn.tempname()
    for rel, t in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local out = {}
    for _, c in ipairs(data.calls) do
        if c.callee == 'foo' or c.callee == 'U' then
            out[c.file .. ':' .. (c.line + 1)] = c.to or ('refused ' .. tostring(c.refused and c.refused.rule))
        end
    end
    return out
end

local U = { ['a/U.java'] = 'package a;\npublic class U { public void foo() {} }\n',
    ['b/U.java'] = 'package b;\npublic class U { public void foo() {} }\n' }

test('class by package: the same package\'s class, an imported one, and none when neither decides (CART-2074)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local got = calls(vim.tbl_extend('error', U, {
        ['b/Use.java'] = 'package b;\npublic class Use {\n  void run(U u) { u.foo(); }\n}\n',
        ['c/Imp.java'] = 'package c;\nimport a.U;\npublic class Imp {\n  void run(U u) { u.foo(); }\n}\n',
        ['d/None.java'] = 'package d;\nimport a.*;\nimport b.*;\npublic class None {\n  void run(U u) { u.foo(); }\n}\n' }))
    eq('b/U.java::U::foo@1', got['b/Use.java:3'], 'the same package')
    eq('a/U.java::U::foo@1', got['c/Imp.java:4'], 'the single-type import, over nothing else')
    eq('refused ambiguous', got['d/None.java:5'], 'two on-demand imports decide nothing')
end)

test('class by package: an import wins over the same package; a NESTED class of a sibling is never picked by package (CART-2074)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local got = calls(vim.tbl_extend('error', U, {
        ['b/Shadow.java'] = 'package b;\nimport a.U;\npublic class Shadow {\n  void run(U u) { u.foo(); }\n}\n',
        ['e/Outer.java'] = 'package e;\npublic class Outer {\n  public static class U { public void foo() {} }\n}\n',
        ['e/Use2.java'] = 'package e;\npublic class Use2 {\n  void run(U u) { u.foo(); }\n}\n' }))
    eq('a/U.java::U::foo@1', got['b/Shadow.java:4'], 'a single-type import shadows the package\'s own U')
    eq('refused ambiguous', got['e/Use2.java:3'], 'Outer.U is not visible as `U` from a sibling file of its package')
end)
