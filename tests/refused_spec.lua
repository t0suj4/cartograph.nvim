-- Refused-record interning: identical refusals share one record; distinct
-- ones stay distinct; reads are unchanged; clearing a call's refusal never
-- affects its sharers (field replacement, not record mutation).

local refused = require 'cartograph.refused'

local function mk()
    return { calls = {
        { callee = 'a', refused = { rule = 'ambiguous', cands = { 'x', 'y' }, n = 2 } },
        { callee = 'b', refused = { rule = 'ambiguous', cands = { 'x', 'y' }, n = 2 } },
        { callee = 'c', refused = { rule = 'ambiguous', cands = { 'x', 'z' }, n = 2 } },
        { callee = 'd', refused = { rule = 'vocab' } },
        { callee = 'e', refused = { rule = 'vocab' } },
        { callee = 'f', refused = { rule = 'aperture', witness = 'm.lua:3' } },
        { callee = 'g' }, -- resolved: no refusal
    } }
end

test('refused: identical refusals intern to one shared record', function ()
    local data = mk()
    local shared = refused.intern(data)
    eq(2, shared, 'b shares a, e shares d')
    local c = data.calls
    ok(c[1].refused == c[2].refused, 'same cands + rule: one record')
    ok(c[1].refused ~= c[3].refused, 'different cands stay distinct')
    ok(c[4].refused == c[5].refused, 'rule-only refusals share too')
    ok(c[6].refused.witness == 'm.lua:3', 'witness reads unchanged')
    eq({ 'x', 'y' }, c[2].refused.cands, 'reads identical through the share')
    eq(0, refused.intern(data), 'idempotent: nothing left to share')
end)

test('refused: clearing one call leaves its sharers intact', function ()
    local data = mk()
    refused.intern(data)
    data.calls[1].refused = nil -- an oracle resolved it
    ok(data.calls[2].refused and data.calls[2].refused.rule == 'ambiguous',
        'the shared record survives on the sibling')
end)
