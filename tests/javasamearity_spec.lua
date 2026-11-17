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
    -- relink reaches the same answers from the stored rows
    c[8][1].to, c[12][1].to, c[14][1].to = nil, nil, nil
    ts.relink(data)
    c = calls_at(data, 'A.java')
    eq({ 'A.java::x_result::x_result@3', 'A.java::A::k@11', 'A.java::A::v@13' }, { c[8][1].to, c[12][1].to, c[14][1].to })
    vim.fn.delete(root, 'rf')
end)

test('same-file arity: overloads of two same-named nested classes are not one class — a binder-typed call stays refused (CART-2121)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = tree({ ['N.java'] = table.concat({
        'package p;',                                                               -- 0
        'public class N {',                                                         -- 1
        '  static class a { static class K { int f(int x) { return x; } } }',        -- 2
        '  static class b { static class K { int f(int x, int y) { return y; } } }', -- 3
        '  int g(a.K k) { return k.f(1); }',                                         -- 4
        '}',
    }, '\n') .. '\n' })
    local data = ts.extract(root); data.root = root
    local c = calls_at(data, 'N.java')
    local call = c[4] and c[4][1]
    ok(call, 'the call row')
    eq(nil, call.to, 'one f per class, two classes: a count would choose the class: ' .. tostring(call.to))
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
