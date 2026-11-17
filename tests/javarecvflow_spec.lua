-- CART-2122: chains whose receiver the source itself decides, which fell to the repo-wide name join. Measured on hive's
-- thrift api (one extraction of gen-javabean, 368 files): 908 `getClass().getName().compareTo(..)` (911 candidates
-- each) and 908 `(cond ? STANDARD_SCHEME_FACTORY : TUPLE_SCHEME_FACTORY).getScheme()` (1,816 each).
--  · getClass() is FINAL on Object and Class is a FINAL class: the name getters return java.lang.String, so the call is
--    keyed `java.lang.String::compareTo` — no project method, external by the typed-receiver rule.
--  · a parenthesized / ternary / cast receiver carries its terms (final fields' `new` initializers, `new X()`, a cast)
--    as a FLOW the return rounds evaluate, as a type-variable head's return flow is: one target resolves, several are
--    refused over exactly the dispatch set.

local ts = require 'cartograph.providers.treesitter'

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local function call(data, file, line, callee)
    for _, c in ipairs(data.calls) do
        if c.file == file and c.line == line and c.callee == callee then return c end
    end
end

local FILES = {
    ['S.java'] = table.concat({
        'package p;',                                                                                   -- 0
        'public class S implements Comparable<S> {',                                                    -- 1
        '  private static final SchemeFactory STANDARD = new SStandardFactory();',                      -- 2
        '  private static final SchemeFactory TUPLE = new STupleFactory();',                            -- 3
        '  public int compareTo(S other) { return getClass().getName().compareTo(other.getClass().getName()); }', -- 4
        '  Object scheme(boolean std) { return (std ? STANDARD : TUPLE).getScheme(); }',               -- 5
        '  Object one() { return (true ? STANDARD : STANDARD).getScheme(); }',                         -- 6
        '  boolean same(Object o) { return getClass().getName().equals(o.toString()); }',               -- 7
        '  static class SStandardFactory implements SchemeFactory { public Object getScheme() { return 1; } }', -- 8
        '  static class STupleFactory implements SchemeFactory { public Object getScheme() { return 2; } }',    -- 9
        '}',
    }, '\n') .. '\n',
    ['Other.java'] = 'package p;\npublic class Other { public Object getScheme() { return 0; } public int compareTo(Object o) { return 0; } }\n',
    ['C.java'] = table.concat({
        'package p;',                                                                                   -- 0
        'public class C {',                                                                             -- 1
        '  Object a(Object x) { return ((Base) x).name(); }',                                           -- 2
        '  Object b(Object x) { return ((Leaf) x).name(); }',                                           -- 3
        '  Object c() { return (new Leaf()).name(); }',                                                 -- 4
        '  Object d(Object x) { return ((Proj) x).other(); }',                                          -- 5
        '}',
    }, '\n') .. '\n',
    ['Base.java'] = 'package p;\npublic class Base { public Object name() { return "b"; } }\n',
    ['Leaf.java'] = 'package p;\npublic final class Leaf extends Base { }\n',
    ['Over.java'] = 'package p;\npublic class Over extends Base { public Object name() { return "o"; } }\n',
    ['Z.java'] = 'package p;\npublic class Z { public Object name() { return "z"; } }\n',
    -- Proj's other() is inherited from a LIBRARY class: the flow cannot settle, and the call gets the name join it skipped
    ['Proj.java'] = 'package p;\npublic class Proj extends org.lib.LibBase { }\n',
    ['Q1.java'] = 'package p;\npublic class Q1 { public Object other() { return 1; } }\n',
    ['Q2.java'] = 'package p;\npublic class Q2 { public Object other() { return 2; } }\n',
}

local function check(data, how)
    local cmp = call(data, 'S.java', 4, 'compareTo')
    eq('java.lang.String::compareTo', cmp.full, how .. ': keyed by the JDK class final methods decide')
    eq(nil, cmp.to, how .. ': never a project compareTo: ' .. tostring(cmp.to))
    local sc = call(data, 'S.java', 5, 'getScheme')
    eq(nil, sc.to, how)
    eq('ambiguous', sc.refused and sc.refused.rule, how)
    eq(2, sc.refused and (sc.refused.n or #sc.refused.cands), how .. ': exactly the two factories, not every getScheme')
    eq('S.java::SStandardFactory::getScheme@8', call(data, 'S.java', 6, 'getScheme').to, how .. ': one factory: resolved')
    local eqc = call(data, 'S.java', 7, 'equals')
    ok(eqc.full ~= 'java.lang.String::equals', how .. ': a stdlib-vocabulary name stays bare (the vocabulary gate would refuse a full key)')
    -- a cast: the class or any project subclass overriding the method
    local a = call(data, 'C.java', 2, 'name')
    eq(nil, a.to, how .. ': Base is overridden by Over: dynamic dispatch, refused')
    eq('ambiguous', a.refused and a.refused.rule, how)
    eq(2, a.refused and (a.refused.n or #a.refused.cands), how .. ': Base.name and Over.name, never Z.name')
    eq('Base.java::Base::name@1', call(data, 'C.java', 3, 'name').to, how .. ': Leaf is final and inherits Base.name')
    eq('Base.java::Base::name@1', call(data, 'C.java', 4, 'name').to, how .. ': (new Leaf()) exactly')
    local d = call(data, 'C.java', 5, 'other')
    ok(d.to or d.refused or d.ext, how .. ': an unsettled flow falls back to the name join, never left undecided: ' .. vim.inspect(d))
end

test('java receiver flow: a final-method JDK chain, a ternary of final fields, a cast (CART-2122)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree(FILES)
    local data = ts.extract(root); data.root = root
    check(data, 'extract')
    for _, c in ipairs(data.calls) do
        if c.rt and c.rt.flow then c.to = nil; c.refused = nil; c.prov = nil end
    end
    ts.relink(data)
    check(data, 'relink')
    vim.fn.delete(root, 'rf')
end)
