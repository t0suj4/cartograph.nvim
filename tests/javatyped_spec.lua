-- CART-1077: Java receivers whose type the code DECLARES resolve through that type, not a repo-wide name join.
-- Fixture: tests/fixtures/javatyped. Each call in Use.java names one rule.

local ts = require 'cartograph.providers.treesitter'

local FIX = vim.fn.getcwd() .. '/tests/fixtures/javatyped'
local memo
local function calls()
    if memo then return memo end
    local data = ts.extract(FIX)
    memo = {}
    for _, c in ipairs(data.calls) do
        if c.file == 'Use.java' then memo[(c.line + 1) .. ':' .. c.callee] = c end
    end
    return memo
end

test('javatyped: a for-each and a catch binder type their receiver (both names are also defined elsewhere)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local c = calls()
    eq('Item.java::Item::name@1', c['7:name'].to, 'for (Item it : xs) it.name()')
    eq('MyErr.java::MyErr::detail@1', c['14:detail'].to, 'catch (MyErr e) e.detail()')
end)

test('javatyped: a receiver of a NON-project class is external — no name match into the project', function ()
    if not parser_available('java') then skip 'no java parser' end
    local c = calls()
    local g = c['18:getScheme']
    eq(nil, g.to, 'p is a Proto (org.lib): Other::getScheme must not answer')
    eq('typed-receiver', g.ext and g.ext.why)
    local h = c['22:detail']
    eq(nil, h.to, 'org.lib.Helper.detail(1): a fully qualified library class')
    eq('typed-receiver', h.ext and h.ext.why)
end)

test('javatyped: an underscore class name is a static receiver (the existing same-file tier then picks this file\'s nested class)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local c = calls()
    eq('Use.java::_Fields::find@3', c['21:find'].to, 'Twin.java nests another _Fields.find')
end)

-- the two witnesses the elasticsearch `server` gate turned up (CART-1077)
local function calls2()
    local data = ts.extract(FIX)
    local out = {}
    for _, c in ipairs(data.calls) do
        if c.file == 'Use2.java' then out[(c.line + 1) .. ':' .. c.callee] = c end
    end
    return out
end

test('javatyped: an explicitly imported JDK class is not the project class of the same simple name', function ()
    if not parser_available('java') then skip 'no java parser' end
    local g = calls2()['6:getName']
    eq(nil, g.to, 'java.lang.reflect.Field is imported; p.Field::getName must not answer')
    eq('java.lang.reflect.Field::getName', g.full, 'qualified by the FULL imported name')
    -- getName is also a JDK vocabulary word, so the stdlib gate may refuse it first: either way, not a project call
    ok((g.ext and g.ext.why == 'typed-receiver') or (type(g.refused) == 'table' and g.refused.rule == 'vocab'),
        vim.inspect({ ext = g.ext, refused = g.refused }))
end)

test('javatyped: an ALL-CAPS segment is a static field, not a class — Ver.CURRENT.minimum() is not made external', function ()
    if not parser_available('java') then skip 'no java parser' end
    local m = calls2()['10:minimum']
    ok(not (m.ext and m.ext.why == 'typed-receiver'), 'CURRENT is a field of Ver, not a class named CURRENT')
end)

-- the project-wide field-type table: `var.f.m()` through f's DECLARED type (CART-1077, 57% of the remaining join on hive)
local function calls3()
    local data = ts.extract(FIX)
    local out = {}
    for _, c in ipairs(data.calls) do
        if c.file == 'Use3.java' then out[(c.line + 1) .. ':' .. c.callee] = c end
    end
    return out
end

test('javatyped: var.f.m() is typed by f\'s declared type, inherited fields included (both names exist elsewhere)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local c = calls3()
    eq('Item.java::Item::name@1', c['4:name'].to, 'h.item.name(): Holder.item is an Item')
    eq('Item.java::Item::name@1', c['5:name'].to, 's.item.name(): SubHolder inherits Holder.item')
end)

test('javatyped: an undeclared field falls back to the old name join (still refused as ambiguous, not dropped)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local c = calls3()['6:name']
    eq(nil, c.to)
    eq('ambiguous', type(c.refused) == 'table' and c.refused.rule or nil, 'Item::name and Other::name, as before')
end)

-- CART-0677: a TYPE VARIABLE named like a class (`<Session extends Flushable>`) typed `item.flush()` as the CLASS
-- Session's method — a class that cannot be the receiver under any instantiation, linked with no refusal. The declared
-- name now reads through the type parameters in scope: a bound's class, nothing for an unbounded one, and a static
-- nested class sees no outer type variable.
test('javatyped: a type variable is its BOUND, not the class of the same name; unbounded = no key; static nesting sees none (CART-0677)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = vim.fn.tempname()
    local function w(rel, t)
        vim.fn.mkdir(vim.fs.dirname(root .. '/' .. rel), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    w('src/p/Flushable.java', 'package p;\npublic interface Flushable { void flush(); }\n')
    w('src/p/Session.java', 'package p;\npublic class Session { public void flush() {} }\n')
    w('src/p/ShadowHolder.java', table.concat({
        'package p;',
        'public class ShadowHolder<Session extends Flushable> {',
        '    private Session item;',
        '    public void run() { this.item.flush(); }',          -- 4: the field
        '    public void run2(Session s) { s.flush(); }',        -- 5: a parameter
        '    public <Session> void run3(Session t) { t.flush(); }', -- 6: an UNBOUNDED type variable (Object) shadowing both
        '    static class Nested { void go(Session s) { s.flush(); } }', -- 7: no outer type variable here
        '    class Inner { void go(Session s) { s.flush(); } }',  -- 8: an inner class sees it
        '}', '' }, '\n'))
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local to = {}
    for _, c in ipairs(data.calls) do
        if c.file == 'src/p/ShadowHolder.java' then to[c.line + 1] = c.to or false end
    end
    local F, S = 'src/p/Flushable.java::Flushable::flush@1', 'src/p/Session.java::Session::flush@1'
    eq(F, to[4], 'this.item.flush(): the bound')
    eq(F, to[5], 's.flush() on a parameter of the type variable')
    ok(to[6] ~= S, 'an unbounded type variable is no key into the class Session: ' .. tostring(to[6]))
    eq(S, to[7], 'a static nested class: Session IS the class')
    eq(F, to[8], 'an inner class sees the outer type variable')
end)

-- CART-0676: a service locator overloaded ON ARITY — getBean(Class<T>) and getBean(Class<T>, String) — refused every
-- one-argument site as ambiguous, so the shipped class-literal return inference never ran (cross_db's top unresolved
-- callee). Overloads of ONE class are decided by the argument count; varargs and same-arity type overloads keep refusing.
test('javatyped: an ARITY overload of one class is decided by the argument count — varargs and type overloads still refuse (CART-0676)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = vim.fn.tempname()
    local function w(rel, t)
        vim.fn.mkdir(vim.fs.dirname(root .. '/' .. rel), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    w('src/p/Loc.java', table.concat({
        'package p;',
        'public class Loc {',
        '    public static <T> T getBean(Class<T> requiredType) { return null; }',
        '    public static <T> T getBean(Class<T> requiredType, String name) { return null; }',
        '    public static void log(String fmt, Object... args) { }',
        '    public static void log(String fmt) { }',
        '    public static void typed(String s) { }',
        '    public static void typed(int i) { }',
        '}', '' }, '\n'))
    w('src/p/Dao.java', 'package p;\npublic class Dao { public int fieldLength(String f) { return 1; } }\n')
    w('src/p/Use.java', table.concat({
        'package p;',
        'public class Use {',
        '    void f() {',
        '        Loc.getBean(String.class);',               -- 4: one argument -> the 1-arity overload
        '        Loc.getBean(String.class, "x");',          -- 5: two -> the 2-arity one
        '        Loc.log("a");',                            -- 6: fixed AND varargs accept 1 -> refused (the trap)
        '        Loc.log("a", 1, 2);',                      -- 7: only the varargs accepts 3
        '        Loc.typed("s");',                          -- 8: same arity, differ by TYPE -> refused
        '        Loc.getBean(Dao.class).fieldLength("c");', -- 9: the base resolves, so return inference types Dao
        '    }',
        '}', '' }, '\n'))
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local at = {}
    for _, c in ipairs(data.calls) do
        if c.file == 'src/p/Use.java' then at[(c.line + 1) .. ':' .. c.callee] = c end
    end
    eq('src/p/Loc.java::Loc::getBean@2', at['4:getBean'].to)
    eq('src/p/Loc.java::Loc::getBean@3', at['5:getBean'].to)
    eq(nil, at['6:log'].to, 'a fixed and a varargs overload both accept one argument: refused')
    eq('ambiguous', at['6:log'].refused and at['6:log'].refused.rule)
    eq('src/p/Loc.java::Loc::log@4', at['7:log'].to, 'only the varargs overload accepts three')
    eq(nil, at['8:typed'].to, 'same arity, differing by type: refused')
    eq('src/p/Loc.java::Loc::getBean@2', at['9:getBean'].to)
    eq('src/p/Dao.java::Dao::fieldLength@1', at['9:fieldLength'].to, 'and the class literal now types the chained call')
end)
