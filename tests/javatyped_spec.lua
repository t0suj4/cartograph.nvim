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
