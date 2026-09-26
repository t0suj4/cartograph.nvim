-- CART-1077: a method returning its OWN type variable is typed by its RETURN FLOW, not its bound.
-- Fixture: tests/fixtures/javaretflow. Gen.read calls one chain per rule; Decoy.java defines every tail name again, so the
-- name join those chains used to pay would be ambiguous.

local ts = require 'cartograph.providers.treesitter'

local FIX = vim.fn.getcwd() .. '/tests/fixtures/javaretflow'
local memo
local function calls()
    if memo then return memo end
    local data = ts.extract(FIX)
    memo = {}
    for _, c in ipairs(data.calls) do
        if c.file == 'Gen.java' then memo[(c.line + 1) .. ':' .. c.callee] = c end
    end
    return memo
end

test('javaretflow: final factory fields + a ternary + declared getScheme returns -> exactly the two scheme classes', function ()
    if not parser_available('java') then skip 'no java parser' end
    local c = calls()['11:read']
    eq(nil, c.to, 'two runtime classes: still dynamic dispatch')
    eq('ambiguous', c.refused and c.refused.rule)
    eq({ 'Gen.java::GenStandardScheme::read@21', 'Gen.java::GenTupleScheme::read@27' }, c.refused.cands)
    eq(2, c.refused.n, 'the set is complete, and Decoy::read / Gen::read are not in it')
    eq(true, c.rt and c.rt.tv, 'the head is a type-variable method with a flow: the first pass skipped the name join')
end)

test('javaretflow: one class comes back -> the chain resolves (a cast and a declared method return)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local c = calls()['12:run']
    eq('Only.java::Only::run@3', c.to)
    eq(true, c.tinf, 'the type-inferred tier')
end)

test('javaretflow: a DECLARED type includes its project subclasses (Sub overrides run)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local c = calls()['13:run']
    eq(nil, c.to)
    eq({ 'Base.java::Base::run@3', 'Sub.java::Sub::run@3' }, c.refused and c.refused.cands)
end)

test('javaretflow: a flow that leaves the project settles nothing and the skipped name join runs', function ()
    if not parser_available('java') then skip 'no java parser' end
    local c = calls()['14:read']
    eq(true, c.rt and c.rt.tv, 'flagged: the flow reads, it only fails against the graph (LibKid inherits getScheme)')
    eq(nil, c.to)
    ok(c.refused and c.refused.n and c.refused.n >= 3, 'the old repo-wide candidate set: ' .. vim.inspect(c.refused))
end)

test('javaretflow: a class in the set that INHERITS the method from a library class leaves a hole -> no claim', function ()
    if not parser_available('java') then skip 'no java parser' end
    local c = calls()['15:read']
    eq(true, c.rt and c.rt.tv)
    eq(nil, c.to, 'Partial::read is the library StandardScheme\'s: nothing in the project answers for it')
    ok(c.refused and c.refused.n and c.refused.n >= 3, 'the name join ran instead: ' .. vim.inspect(c.refused))
end)
