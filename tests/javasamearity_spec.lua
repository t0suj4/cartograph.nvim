-- CART-2121: the ARITY pass (CART-0676) read only `ambiguous` refusals, so overloads of ONE class in the caller's own
-- file — refused `samefile` — were never decided by their argument count: 5,422 calls on hive's metastore, 3,492 of
-- them thrift constructors (`new drop_role_result()` beside the full and the copy constructor). A samefile refusal is
-- read when its candidates are overloads of one class: every one on one nested-class path (node.cpath, CART-1077), the
-- call's own when it names one. And a record's IMPLICIT canonical constructor carries its components as parameters —
-- it had none, so the pass counted it 0 and sent `new E(Set.of(..))` to a declared one-argument constructor.

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
    for _, c in ipairs(data.calls) do
        if c.file == file then out[c.line] = out[c.line] or {}; table.insert(out[c.line], c) end
    end
    return out
end

local A = table.concat({
    'package p;',                                                                        -- 0
    'public class A {',                                                                  -- 1
    '  static class x_result {',                                                         -- 2
    '    x_result() {}',                                                                 -- 3
    '    x_result(int a) {}',                                                            -- 4
    '    x_result(x_result o) {}',                                                       -- 5
    '  }',                                                                               -- 6
    '  static class Proc {',                                                             -- 7
    '    Object f() { return new x_result(); }',                                         -- 8
    '    Object g() { return new x_result(1); }',                                        -- 9
    '  }',                                                                               -- 10
    '  int k(int a) { return a; }',                                                      -- 11
    '  int k(int a, int b) { return k(a) + b; }',                                        -- 12
    '  int v(String... xs) { return 0; }',                                               -- 13
    '  int v(int a) { return v(); }',                                                    -- 14
    '  int u(int a, String... xs) { return a; }',                                        -- 15
    '  int u(int a, int b) { return u(a, "x", "y"); }',                                  -- 16
    '}',
}, '\n') .. '\n'

test('same-file arity: a samefile refusal over one class\'s overloads is decided by the argument count (CART-2121)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['A.java'] = A })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'A.java')
    eq('A.java::x_result::x_result@3', c[8][1].to, 'new x_result(): the no-argument constructor')
    eq(nil, c[9][1].to, 'x_result(int) and x_result(x_result) share the count: the TYPE decides, refused')
    eq('samefile', c[9][1].refused and c[9][1].refused.rule)
    eq('A.java::A::k@11', c[12][1].to, 'k(a): the one-parameter overload')
    eq('A.java::A::v@13', c[14][1].to, 'v(): only the varargs overload accepts no argument')
    eq('A.java::A::u@15', c[16][1].to, 'u(a, x, y): three arguments, only the varargs overload (prefix 1) accepts them')
    -- relink reaches the same answers from the stored rows
    -- (relink's index is build_index's STUBS: they must carry the varargs mark, or u's prefix reads as a fixed count)
    c[8][1].to, c[12][1].to, c[14][1].to, c[16][1].to = nil, nil, nil, nil
    ts.relink(data)
    c = calls_at(data, 'A.java')
    eq({ 'A.java::x_result::x_result@3', 'A.java::A::k@11', 'A.java::A::v@13', 'A.java::A::u@15' },
        { c[8][1].to, c[12][1].to, c[14][1].to, c[16][1].to })
    -- and the FEDERATED relink, which resolves off build_symtab's light stubs (config.federated_resolve)
    local config = require 'cartograph.config'
    local was = config.federated_resolve
    config.federated_resolve = true
    c[8][1].to, c[12][1].to, c[14][1].to, c[16][1].to = nil, nil, nil, nil
    local okr, err = pcall(ts.relink, data)
    config.federated_resolve = was
    assert(okr, err)
    c = calls_at(data, 'A.java')
    eq({ 'A.java::x_result::x_result@3', 'A.java::A::k@11', 'A.java::A::v@13', 'A.java::A::u@15' },
        { c[8][1].to, c[12][1].to, c[14][1].to, c[16][1].to }, 'the stubs carry the varargs mark')
    vim.fn.delete(root, 'rf')
end)

test('same-file arity: overloads of two same-named nested classes are not one class — a parameter of simple type K and one of qualified type a.K both name a.K (CART-2121, CART-2123)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['N.java'] = table.concat({
        'package p;',                                                                                   -- 0
        'public class N {',                                                                             -- 1
        '  static class a { static class K { int f(int x) { return x; } } int h(K k) { return k.f(1); } }', -- 2
        '  static class b { static class K { int f(int x, int y) { return y; } } }',                    -- 3
        '  int g(a.K k) { return k.f(1); }',                                                            -- 4
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'N.java')
    local h = c[2] and c[2][1]
    -- (a PARAMETER of simple type K inside a: its lexical class, a.K — CART-2123; it was left undecided before)
    eq('N.a.K', h.cpath, 'K inside a: a.K')
    eq('N.java::K::f@2', h.to, 'a.K\'s f(int), never b.K\'s by count: ' .. tostring(h.to))
    eq('N.a.K', c[4][1].cpath, 'a.K: a is a member of N')
    eq('N.java::K::f@2', c[4][1].to, 'a.K\'s f(int)')
    vim.fn.delete(root, 'rf')
end)

test('same-file arity: a record\'s implicit canonical constructor counts its components (CART-2121)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({
        ['R.java'] = table.concat({
            'package p;',                                                     -- 0
            'public class R {',                                               -- 1
            '  record Row(String a, String b) { Row(String[] r) { this(r[0], r[1]); } }', -- 2
            '  Object h() { return new Row("p", "q"); }',                     -- 3
            '  Object i() { return new Row(new String[0]); }',                -- 4
            '}',
        }, '\n') .. '\n',
        -- minimised from elasticsearch libs WriteSystemPropertiesEntitlement: canonical (Set) and declared (List) share a count
        ['E.java'] = 'package p;\nimport java.util.*;\npublic record E(Set<String> p) {\n  public E(List<String> l) { this(Set.copyOf(l)); }\n}\n',
        ['U.java'] = 'package p;\nimport java.util.*;\npublic class U {\n  Object u() { return new E(Set.of("x")); }\n}\n',
    })
    local data = ts.extract(root); data.root = root
    local r = calls_at(data, 'R.java')
    local canon
    for _, n in ipairs(data.nodes) do if n.file == 'R.java' and n.synth and n.name == 'Row::Row' then canon = n end end
    ok(canon, 'the minted canonical constructor')
    eq({ 'a', 'b' }, canon.params, 'its parameters are the components')
    eq(canon.id, r[3][1].to, 'two arguments: the canonical constructor')
    eq('R.java::Row::Row@2', r[4][1].to:gsub('~%d+$', ''), 'one argument: the declared one')
    ok(r[4][1].to ~= canon.id)
    local u = calls_at(data, 'U.java')
    eq(nil, u[3][1].to, 'E(Set) and E(List) take one argument each: the type decides, refused — it had linked to E(List)')
    vim.fn.delete(root, 'rf')
end)

test('same-file arity: a synthesized candidate with no parameter list has no count, so the call is refused (CART-2121)', function ()
    local rows = { { file = 'S.java', full = 'S::m', argv = { {} }, line = 3,
        refused = { rule = 'ambiguous', cands = { 'S.java::S::m@1', 'S.java::S::m@2' }, n = 2 } } }
    local cv = { n = 1, get = function (i, k) return rows[i][k] end, set = function (i, k, v) rows[i][k] = v end }
    local idx = {
        ['S.java::S::m@1'] = { id = 'S.java::S::m@1', name = 'S::m', file = 'S.java', params = { 'a' } },
        ['S.java::S::m@2'] = { id = 'S.java::S::m@2', name = 'S::m', file = 'S.java', synth = true },
    }
    eq(0, ts._resolve_arity(cv, idx, function () end))
    eq(nil, rows[1].to, 'the synthesized one may take this count too')
    idx['S.java::S::m@2'].params = { 'a', 'b' }
    eq(1, ts._resolve_arity(cv, idx, function () end))
    eq('S.java::S::m@1', rows[1].to)
end)

test('same-file arity: overloads on ANOTHER class\'s path are not the call\'s — its own K inherits f (CART-2121)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['W.java'] = table.concat({
        'package p;',                                                                              -- 0
        'public class W {',                                                                        -- 1
        '  static class a { static class K extends Base {}',                                       -- 2
        '    int g() { return K.f(1); } }',                                                        -- 3
        '  static class b { static class K { static int f(int x) { return x; } static int f(int x, int y) { return y; } } }', -- 4
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'W.java')
    eq('W.a.K', c[3][1].cpath, 'the call names a\'s K')
    eq(nil, c[3][1].to, 'b.K\'s f(int) is not what a.K.f(1) calls: ' .. tostring(c[3][1].to))
    vim.fn.delete(root, 'rf')
end)

test('same-file arity: an anonymous or enum-constant body\'s member is not the named class\'s overload (CART-2121)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['O.java'] = table.concat({
        'package p;',                                                                               -- 0
        'public class O extends Base {',                                                            -- 1
        '  void close(boolean force) {}',                                                           -- 2
        '  Object h() { return new java.io.Closeable() { public void close() {} }; }',              -- 3
        '  void g() { close(); }',                                                                  -- 4
        '  enum E { A { int v() { return 1; } }, B; int v() { return 0; } int w() { return v(); } }', -- 5
        '  void m(int a) {} void m(int a, int b) {}',                                               -- 6
        '  Runnable r() { return new Runnable() { public void run() { m(1); } }; }',                -- 7
        '  static class Kay { static int f(int x) { return x; } static int f(int x, int y) { return y; } }', -- 8
        '  int q() { return Z.Kay.f(1); }',                                                         -- 9
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'O.java')
    local anon
    for _, n in ipairs(data.nodes) do if n.id == 'O.java::O::close@3' then anon = n end end
    eq('', anon and anon.cpath, 'an anonymous body\'s member is on no named path')
    eq(nil, c[4][1].to, 'close() is Base.close() or O.close(boolean) by type, never the anonymous close(): ' .. tostring(c[4][1].to))
    local ev
    for _, n in ipairs(data.nodes) do if n.name == 'E::v' and n.cpath == 'O.E' then ev = n end end
    ok(ev, 'E\'s own v() is on O.E')
    eq(ev.id, c[5][1].to, 'v() in E reaches E.v(), never constant A\'s override (an anonymous subclass of E)')
    local m7
    for _, x in ipairs(c[7]) do if x.callee == 'm' then m7 = x end end
    eq('', m7.cpath, 'a this-call inside an anonymous body is UNDECIDABLE, not unplaced')
    eq('samefile', m7.refused and m7.refused.rule, 'the anonymous class may inherit m: ' .. tostring(m7.to))
    eq('', c[9][1].cpath, 'a qualified spelling is undecidable')
    eq(nil, c[9][1].to, 'Z.Kay is not this file\'s Kay: ' .. tostring(c[9][1].to))
    vim.fn.delete(root, 'rf')
end)

test('same-file arity: a varargs record component makes the canonical constructor variadic (CART-2121)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['VR.java'] = table.concat({
        'package p;',                                                            -- 0
        'public class VR {',                                                     -- 1
        '  record Names(String... xs) { Names(int n) { this(new String[n]); } }', -- 2
        '  Object a() { return new Names(); }',                                  -- 3
        '  Object b() { return new Names("x", "y"); }',                          -- 4
        '  Object c() { return new Names(3); }',                                 -- 5
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'VR.java')
    local canon
    for _, n in ipairs(data.nodes) do if n.synth and n.name == 'Names::Names' then canon = n end end
    ok(canon and canon.variadic, 'the canonical constructor is variadic')
    eq(canon.id, c[3][1].to, 'no argument: only the varargs one accepts it')
    eq(canon.id, c[4][1].to, 'two arguments: the varargs one')
    eq(nil, c[5][1].to, 'one argument: Names(int) and the varargs one both accept it — the trap, refused')
    vim.fn.delete(root, 'rf')
end)

test('same-file arity: an anonymous body\'s member is no candidate of a call outside that body (CART-2121)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['P.java'] = table.concat({
        'package p;',                                                                                  -- 0
        'public class P {',                                                                            -- 1
        '  Object h() { return new java.io.Closeable() { public void close() {} }; }',                 -- 2
        '  void close(boolean f) {} void close(int a, int b) {}',                                      -- 3
        '  void g() { close(); }',                                                                     -- 4
        '  static class In {',                                                                         -- 5
        '    Object h() { return new java.io.Closeable() { public void shut() {} }; }',                -- 6
        '    void shut(int a) {} void shut(int a, int b) {}',                                          -- 7
        '    void g() { shut(1); }',                                                                   -- 8
        '  }',                                                                                         -- 9
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'P.java')
    eq(nil, c[4][1].to, 'no overload of P takes no argument, and the anonymous close() is no member of P')
    eq('P.In', c[8][1].cpath)
    eq('P.java::In::shut@7', c[8][1].to, 'In\'s own shut(int): an anonymous subclass\'s shut() is no overload of In\'s')
    vim.fn.delete(root, 'rf')
end)

test('same-file arity: a call inside an anonymous body never picks ANOTHER anonymous body\'s member (CART-2121)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['Q2.java'] = table.concat({
        'package p;',                                                                                   -- 0
        'public class Q2 {',                                                                            -- 1
        '  Object a() { return new Runnable() { public void run() { go(1); } }; }',                     -- 2
        '  Object b() { return new Runnable() { public void run() {} void go(int x) {} }; }',           -- 3
        '  void go(String s, int y) {} void go() {}',                                                   -- 4
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'Q2.java')
    local call
    for _, x in ipairs(c[2]) do if x.callee == 'go' then call = x end end
    eq('', call.cpath, 'inside an anonymous body: undecidable')
    eq(nil, call.to, 'the other body\'s go(int) is no member of this one: ' .. tostring(call.to))
    vim.fn.delete(root, 'rf')
end)

test('same-file arity: a same-file candidate the spec did not place (no path) refuses the call (CART-2121)', function ()
    local rows = { { file = 'S.java', full = 'K::m', argv = { {} }, line = 9, cpath = 'S.K',
        refused = { rule = 'samefile', cands = { 'S.java::K::m@1', 'S.java::K::m@2' }, n = 2 } } }
    local cv = { n = 1, get = function (i, k) return rows[i][k] end, set = function (i, k, v) rows[i][k] = v end }
    local idx = {
        ['S.java::K::m@1'] = { id = 'S.java::K::m@1', name = 'K::m', file = 'S.java', cpath = 'S.K', params = { 'a' } },
        ['S.java::K::m@2'] = { id = 'S.java::K::m@2', name = 'K::m', file = 'S.java', params = { 'a', 'b' } }, -- a mint without its path
    }
    eq(0, ts._resolve_arity(cv, idx, function () end))
    eq(nil, rows[1].to, 'it may be on S.K')
    idx['S.java::K::m@2'].cpath = 'S.Other.K'
    eq(1, ts._resolve_arity(cv, idx, function () end))
    eq('S.java::K::m@1', rows[1].to, 'placed on another path: not this class\'s overload')
end)

test('same-file arity: a call typed through a VARIABLE of a nested class skips the anonymous members inside it (CART-2121)', function ()
    if not parser_available('java') then skip 'no java parser' end
    -- minimised from elasticsearch libs LongLongSwissHash: SmallCore holds an anonymous iterator with its own key1()
    local root = tree({ ['H.java'] = table.concat({
        'package p;',                                                                                           -- 0
        'public class H {',                                                                                     -- 1
        '  static class Small {',                                                                               -- 2
        '    Object it() { return new Object() { long key1() { return 0; } }; }',                               -- 3
        '    long key1(int offset) { return offset; }',                                                         -- 4
        '  }',                                                                                                  -- 5
        '  static class Big { long key1(long o) { return o; } }',                                               -- 6
        '  Small small; long k(int o) { return small.key1(o); }',                                               -- 7
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'H.java')
    eq('H.java::Small::key1@4', c[7][1].to, 'Small\'s own key1(int): ' .. vim.inspect(c[7][1].refused))
    vim.fn.delete(root, 'rf')
end)

test('same-file arity: a VARIABLE whose declared type is spelled qualified names that class, not this file\'s namesake (CART-2121)', function ()
    if not parser_available('java') then skip 'no java parser' end
    -- minimised from elasticsearch server ProjectMetadata.java:1243: `ImmutableOpenMap.Builder<..> indices; indices.get(name)`
    local root = tree({ ['PM.java'] = table.concat({
        'package p;',                                                                                   -- 0
        'public class PM {',                                                                            -- 1
        '  public static class Builder {',                                                              -- 2
        '    private final ImmutableOpenMap.Builder<String, Object> indices = null;',                   -- 3
        '    public Object get(String index) { return indices.get(index); }',                           -- 4
        '    public Object get(String a, String b) { return null; }',                                   -- 5
        '    PM.Builder self; Object s(String n) { return self.get(n); }',                              -- 6
        '  }',                                                                                          -- 7
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'PM.java')
    eq('', c[4][1].cpath, 'ImmutableOpenMap is no enclosing scope\'s name: another file\'s Builder')
    eq(nil, c[4][1].to, 'never PM.Builder.get: ' .. tostring(c[4][1].to))
    eq('PM.Builder', c[6][1].cpath, 'PM.Builder: the enclosing class\'s member')
    eq('PM.java::Builder::get@4', c[6][1].to, 'and the count decides')
    vim.fn.delete(root, 'rf')
end)

test('same-file arity: a receiver CREATED from a qualified class, `new Z.Kay().f(1)`, is another file\'s Kay (CART-2121)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['Y.java'] = table.concat({
        'package p;',                                                                          -- 0
        'public class Y {',                                                                    -- 1
        '  static class Kay { int f(int x) { return x; } int f(int x, int y) { return y; } }',  -- 2
        '  int a() { return new Z.Kay().f(1); }',                                              -- 3
        '  int b() { return new Y.Kay().f(1); }',                                              -- 4
        '  int c() { return new Kay().f(1); }',                                                -- 5
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'Y.java')
    local function f(line) for _, x in ipairs(c[line]) do if x.callee == 'f' then return x end end end
    eq('', f(3).cpath, 'Z is no enclosing scope\'s name')
    eq(nil, f(3).to, 'never this file\'s Kay.f: ' .. tostring(f(3).to))
    eq('Y.Kay', f(4).cpath); eq('Y.java::Kay::f@2', f(4).to)
    eq('Y.Kay', f(5).cpath); eq('Y.java::Kay::f@2', f(5).to)
    vim.fn.delete(root, 'rf')
end)
