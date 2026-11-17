-- CART-1077: a simple class name in Java is scoped LEXICALLY — the member type of the innermost enclosing class that
-- declares it. thrift nests a `_Fields` enum in every struct (574 in hive's ThriftHiveMetastore.java), so the key
-- `_Fields::findByThriftId` named 574 same-file methods and the same-file tier refused every such call (1,722 on
-- hive's standalone-metastore). A method node carries its class's nested path (node.cpath), a self / written call the
-- path of the class its key names (call.cpath), and the resolver takes the ONE same-file candidate on that path.

local ts = require 'cartograph.providers.treesitter'

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local function calls_at(data, file)
    local out = {}
    for _, c in ipairs(data.calls) do if c.file == file then out[c.line] = c end end
    return out
end

local T = table.concat({
    'package p;',                                                                        -- 0
    'public class T {',                                                                  -- 1
    '  public static class a_args {',                                                    -- 2
    '    public enum _Fields {',                                                         -- 3
    '      X;',                                                                          -- 4
    '      public static _Fields findByThriftId(int id) { return X; }',                  -- 5
    '      public static _Fields findOrThrow(int id) { return findByThriftId(id); }',    -- 6
    '    }',                                                                             -- 7
    '    public _Fields fieldForId(int id) { return _Fields.findByThriftId(id); }',      -- 8
    '  }',                                                                               -- 9
    '  public static class b_args {',                                                    -- 10
    '    public enum _Fields {',                                                         -- 11
    '      Y;',                                                                          -- 12
    '      public static _Fields findByThriftId(int id) { return Y; }',                  -- 13
    '    }',                                                                             -- 14
    '    public _Fields fieldForId(int id) { return _Fields.findByThriftId(id); }',      -- 15
    '  }',                                                                               -- 16
    '}',                                                                                 -- 17
}, '\n') .. '\n'

test('java path: a nested class name resolves to the member type of the innermost enclosing class (CART-1077)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['T.java'] = T })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'T.java')
    eq('T.java::_Fields::findByThriftId@5', c[8].to, 'a_args\'s own _Fields: ' .. vim.inspect(c[8].refused))
    eq('T.java::_Fields::findByThriftId@13', c[15].to, 'b_args\'s own _Fields')
    eq('T.java::_Fields::findByThriftId@5', c[6].to, 'implicit this inside a_args._Fields')
    eq('T.a_args._Fields', c[8].cpath)
    -- a relink re-resolves from the stored rows and reaches the same targets
    for _, k in ipairs { 6, 8, 15 } do c[k].to = nil end
    ts.relink(data)
    c = calls_at(data, 'T.java')
    eq({ 'T.java::_Fields::findByThriftId@5', 'T.java::_Fields::findByThriftId@5', 'T.java::_Fields::findByThriftId@13' },
        { c[6].to, c[8].to, c[15].to }, 'relink agrees with extract')
    vim.fn.delete(root, 'rf')
end)

test('java path: overloads on one path stay refused; an intermediate class with a supertype declines (CART-1077)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['U.java'] = table.concat({
        'package p;',                                                                     -- 0
        'public class U {',                                                               -- 1
        '  static class a { static class K { static int f(int x) { return x; } static int f(String s) { return 0; } }',
        '    int g() { return K.f(1); } }',                                               -- 3
        '  static class b { static class K { static int f(int x) { return x; } } }',        -- 4
        '  static class c { static class K { static int h() { return 1; } }',             -- 5
        '    static class In extends Base { int g() { return K.h(); } } }',               -- 6
        '  static class d { static class K { static int h() { return 2; } } }',           -- 7
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'U.java')
    eq(nil, c[3].to, 'two f on U.a.K: arity decides, not scope')
    eq('U.a.K', c[3].cpath, 'the path itself is found')
    eq(nil, c[6].to, 'In extends Base: an inherited K may shadow c.K')
    eq(nil, c[6].cpath, 'not decided lexically: an inherited K may shadow c.K')
    vim.fn.delete(root, 'rf')
end)

test('java path: a top-level call carries no path; a def carries one at every depth (CART-1077)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['V.java'] = 'package p;\npublic class V {\n  static int f() { return 1; }\n  int g() { return f(); }\n}\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'V.java')
    eq('V.java::V::f@2', c[3].to)
    eq(nil, c[3].cpath, 'top level: nothing to decide')
    for _, n in ipairs(data.nodes) do if n.kind == 'method' then eq('V', n.cpath, n.id) end end
    vim.fn.delete(root, 'rf')
end)

test('java path: a record\'s IMPLICIT canonical constructor is on the path beside a declared one — a full-arity new stays refused (CART-1077)', function ()
    if not parser_available('java') then skip 'no java parser' end
    -- minimised from elasticsearch libs MainTests.java: `new OutputRow(9 args)` took the declared 1-arg constructor
    local root = tree({ ['M.java'] = table.concat({
        'package p;',                                                         -- 0
        'public class M {',                                                   -- 1
        '  record Row(String a, String b) {',                                 -- 2
        '    Row(String[] r) { this(r[0], r[1]); }',                          -- 3
        '  }',                                                                -- 4
        '  static class Other { record Row(int x) {} }',                      -- 5
        '  Row make() { return new Row("x", "y"); }',                         -- 6
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'M.java')
    eq('M.Row', c[6].cpath)
    -- (two constructors on M.Row, the implicit canonical one minted: the PATH pick refuses, and the ARITY pass decides
    -- by its two components — CART-2121; it took the declared one-argument constructor before either existed)
    eq('M.java::Row::Row@2', c[6].to, 'two arguments: the canonical constructor')
    -- and a candidate the spec did not place blocks the pick rather than letting it choose around the node
    local seen
    for _, n in ipairs(data.nodes) do if n.id == 'M.java::Row::Row@2' then seen = n end end
    ok(seen and seen.cpath == 'M.Row', 'the minted canonical constructor carries the path')
    vim.fn.delete(root, 'rf')
end)

test('java path: a same-file candidate the spec did not place blocks the pick (CART-1077)', function ()
    local a = { id = 'F.java::K::m@3', file = 'F.java', cpath = 'F.a.K' }
    local b = { id = 'F.java::K::m@9', file = 'F.java', cpath = 'F.b.K' }
    local u = { id = 'F.java::K::m@12', file = 'F.java' } -- a mint that never learned its path
    local o = { id = 'G.java::K::m@1', file = 'G.java' }  -- another file's: not a same-file candidate
    eq(a, ts._path_pick({ a, b }, 'F.a.K', 'F.java', {}))
    eq(a, ts._path_pick({ a, b, o }, 'F.a.K', 'F.java', {}), 'another file\'s node is not this file\'s question')
    eq(nil, ts._path_pick({ a, b, u }, 'F.a.K', 'F.java', {}), 'it may be the one on the path')
    eq(nil, ts._path_pick({ a, b }, nil, 'F.java', {}))
end)

test('java path: a QUALIFIED spelling and an anonymous class body decline — B.Kay is not the Kay a bare lookup finds (CART-1077)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['Q.java'] = table.concat({
        'package p;',                                                                            -- 0
        'public class Q {',                                                                      -- 1
        '  static class A { static class Kay { Kay() {} static int f() { return 1; } }',             -- 2
        '    Object g() { return new B.Kay(); }',                                                  -- 3
        '    int h() { return B.Kay.f(); }',                                                       -- 4
        '    int i() { return Kay.f(); }',                                                         -- 5
        '    Runnable j() { return new Runnable() { public void run() { Kay.f(); } }; } }',        -- 6
        '  static class B { static class Kay { Kay() {} static int f() { return 2; } } }',           -- 7
        '  static class C { int m() { return 1; } Runnable r() { return new Runnable() { public void run() { m(); } }; } }', -- 8
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'Q.java')
    eq('Q.java::Kay::f@2', c[5].to, 'bare Kay inside A: A.Kay')
    eq('Q.B.Kay', c[3].cpath, 'new B.Kay(): B is a member of Q, so its head is decided')
    eq(nil, c[3].to and c[3].to:find('@2') and c[3].to or nil, 'never A\'s Kay: ' .. tostring(c[3].to))
    eq('Q.B.Kay', c[4].cpath, 'B.Kay.f(): the same')
    eq('Q.java::Kay::f@7', c[4].to, 'B\'s f')
    eq(nil, c[4].to and c[4].to:find('@2') and c[4].to or nil, 'never A\'s f: ' .. tostring(c[4].to))
    eq('', c[6].cpath, 'inside an anonymous class body the lookup is undecidable')
    eq('', c[8].cpath, 'implicit this inside an anonymous class body: the anonymous class may inherit m')
    vim.fn.delete(root, 'rf')
end)

test('java path: a qualified spelling whose HEAD an enclosing scope names is decided; another file\'s head is not (CART-2121)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['LR.java'] = table.concat({
        'package p;',                                                                        -- 0
        'public class LR {',                                                                 -- 1
        '  static class Bucket { Bucket(int a) {} Bucket(int a, int b) {} }',                -- 2
        '  static class Other { static class Bucket { Bucket(int a) {} } }',                 -- 3
        '  Object f() { return new LR.Bucket(1); }',                                         -- 4
        '  Object g() { return new Ext.Bucket(1); }',                                        -- 5
        '  Object h() { return new Other.Bucket(1); }',                                      -- 6
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'LR.java')
    eq('LR.Bucket', c[4].cpath, 'LR is the enclosing class: LR.Bucket')
    eq('LR.java::Bucket::Bucket@2', c[4].to, 'its one-argument constructor')
    eq('', c[5].cpath, 'Ext is no enclosing scope\'s name: another file\'s class')
    eq(nil, c[5].to, 'never this file\'s Bucket: ' .. tostring(c[5].to))
    eq('LR.Other.Bucket', c[6].cpath, 'Other is a member of LR')
    eq('LR.java::Bucket::Bucket@3', c[6].to)
    vim.fn.delete(root, 'rf')
end)

test('java path: a qualified head walks past a supertype clause — the enclosing class it names is decided (CART-2121)', function ()
    if not parser_available('java') then skip 'no java parser' end
    -- minimised from elasticsearch libs GeometrySimplifier.java:217: `new GeometrySimplifier.LinearRingSimplifier(..)`
    local root = tree({ ['GS.java'] = table.concat({
        'package p;',                                                                            -- 0
        'public class GS {',                                                                     -- 1
        '  static class Ring { Ring(int a) {} Ring(int a, int b) {} }',                          -- 2
        '  static class Poly extends Base { Object f() { return new GS.Ring(1); } }',            -- 3
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'GS.java')
    eq('GS.Ring', c[3].cpath, 'GS is the enclosing top-level class, past Poly\'s extends')
    eq('GS.java::Ring::Ring@2', c[3].to, 'and the count decides')
    vim.fn.delete(root, 'rf')
end)
