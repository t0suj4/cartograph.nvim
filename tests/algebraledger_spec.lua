-- The absorption ledger's own guards (CART-0889 follow-on). What it measures is
-- cheap to get wrong in ONE direction — undercounting reads as "less absorbed
-- than we are", which is the flattering answer for a gap-finding tool and so the
-- one nobody questions. Both bugs found while building it were undercounts.

local led = dofile(vim.fn.getcwd() .. '/tools/algebraledger.lua')

--- ★★★ THE BINDING SHAPES, which is where both bugs were. Three are already in
--- the tree and a fourth will appear; the ledger counts `A.<arrow>` uses, so a
--- shape it does not recognise contributes ZERO and is indistinguishable from a
--- file that uses nothing.
test('algebraledger: every binding shape in the tree is recognised', function ()
    local cases = {
        ['direct']        = 'local A = alg.load()\nA.partition(x)\n',
        ['with a reason'] = 'local A, why = alg.load()\nA.partition(x)\n',
        ['assert-wrapped']= "local A = assert(alg.load(), 'nope')\nA.partition(x)\n",
        ['through a helper'] =
            'local function need()\n    return alg.load()\nend\nlocal A = need()\nA.partition(x)\n',
    }
    for name, src in pairs(cases) do
        local vars = led._bindings(src)
        ok(vars.A, ('the %s binding is recognised'):format(name))
    end
    -- BOTH SIDES: a file that never loads the algebra binds nothing, or every
    -- local in the tree would count as an algebra handle
    local none = led._bindings('local A = something_else()\nA.partition(x)\n')
    ok(not none.A, 'an unrelated local is not treated as an algebra binding')
end)

--- The export list and its grouping are DERIVED from the prototype's own source,
--- so a stale hand-written table cannot creep back in. This pins that the parse
--- actually finds arrows and attributes them to the right section.
test('algebraledger: exports are attributed to the prototype\'s own sections', function ()
    local alg = require 'cartograph.algebra'
    local path = alg.path()
    local fd = path and io.open(path, 'r')
    if not fd then skip('prototype not present') end
    local src = fd:read('*a'); fd:close()

    local sect, order, of = led.exports(src)
    ok(#order > 10, 'the prototype has many sections, got ' .. #order)
    ok(of.transplant, '`transplant` is found as an export')
    ok(tostring(of.transplant):find('transplant'),
        'and lands in the transplant section, not the preamble: ' .. tostring(of.transplant))
    ok(of.partition and tostring(of.partition):find('MDL'),
        '`partition` lands in the MDL section: ' .. tostring(of.partition))
    -- a term constructor and an operator must not share a section, or the
    -- "6 of 159" framing the grouping exists to prevent comes back
    ok(of.lit ~= of.transplant, 'constructors and operators are grouped apart')
    ok(#sect[of.lit] > 1, 'the terms section holds several constructors')
end)
