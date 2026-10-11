-- RESHAPE (write, CART-1656): change a record family's representation at exactly the accesses flowtype says it reaches
-- — positional -> named: `{ a, b }` -> `{ x = a, y = b }` and `t[1]` -> `t.x`, under any spelling. A use as an array, of
-- its keys or a computed key is a frontier; an unnamed position or a shared access a decision (cartograph.reshape).
local T = require('cartograph.tactic').T

local PT = table.concat({
    'local M = {}',
    'function M.pt(a, b) return { a, b } end',
    'function M.len(p) return p[1] + p[2] end',
    'return M', '' }, '\n')
local USE = table.concat({
    "local P = require 'pt'",
    'local q = P.pt(1, 2)',
    'q[1] = 5',
    'local pair = { 7, 8 }',
    'return P.len(q), pair[1]', '' }, '\n')

return {
    name = 'reshape',
    kind = 'write',
    tags = { 'code' },
    summary = 'change a record family\'s representation by provenance: family = its table constructors (file:LINE,…), positional = 1=x,2=y,… makes positions names — in the constructors and at every constant index the family reaches; a use as an array or of its keys refuses (world = closed|open)',
    params = { family = 'list', positional = 'list', world = 'string?' },
    build = function (p)
        return T.step('reshape', { family = p.family, positional = p.positional, world = p.world })
    end,
    examples = {
        {
            name = 'positional -> named: the constructor, a read through a parameter in another file, a write — another { 7, 8 } stays',
            files = { ['pt.lua'] = PT, ['use.lua'] = USE },
            params = { family = { 'pt.lua:2' }, positional = { '1=x', '2=y' } },
            expect = { status = 'done', applied = 1, check = function (root)
                local a, b = io.open(root .. '/pt.lua'):read('a'), io.open(root .. '/use.lua'):read('a')
                return a:find('return { x = a, y = b }', 1, true) ~= nil and a:find('return p.x + p.y', 1, true) ~= nil
                    and b:find('q.x = 5', 1, true) ~= nil and b:find('pair[1]', 1, true) ~= nil, a .. b
            end },
        },
        {
            name = 'a use AS AN ARRAY (#q) cannot keep its meaning: refused, nothing is written',
            files = { ['pt.lua'] = PT, ['use.lua'] = USE:gsub('pair%[1%]', 'pair[1], #q') },
            params = { family = { 'pt.lua:2' }, positional = { '1=x', '2=y' } },
            expect = { status = 'failed', applied = 0, check = function (_, res) return res.class == 'frontier', tostring(res.why) end },
        },
        {
            name = 'a target name the family already uses stops on the decision (name-occupied)',
            files = { ['pt.lua'] = PT:gsub('{ a, b }', '{ a, b, x = 3 }'), ['use.lua'] = USE },
            params = { family = { 'pt.lua:2' }, positional = { '1=x', '2=y' } },
            expect = { status = 'stopped', applied = 0 },
        },
        {
            name = 'an __index FUNCTION on the family computes what an index reads — refused',
            files = { ['e.lua'] = 'local function pt(a, b) return setmetatable({ a, b }, { __index = function () return 0 end }) end\nlocal p = pt(1, 2)\nreturn p[1] + p[3]\n' },
            params = { family = { 'e.lua:1' }, positional = { '1=x', '2=y' } },
            expect = { status = 'failed', applied = 0, check = function (_, res) return res.class == 'frontier', tostring(res.why) end },
        },
        {
            name = 'a position the mapping does not name stops on the decision',
            files = { ['pt.lua'] = PT, ['use.lua'] = USE },
            params = { family = { 'pt.lua:2' }, positional = { '1=x' } },
            expect = { status = 'stopped', applied = 0 },
        },
    },
}
