-- RENAME-FIELD (write, CART-1175): rename a record's field at the reads `<base>.<field>` and the table-constructor keys
-- in the files that DEFINE the record — never a syntactic rename. An occupied target is a DECISION (`name-occupied`):
-- accepted, the occupant moves to a placeholder `<to>__1` and choosing its real name is left as a deferred decision.
-- Comment/string mentions are a counted frontier, never rewritten. REPLAYED on CART-1160 step 7 (the tree at
-- 2203d17^): the same 3 reads + 3 keys the hand rename changed, `L.scopes` untouched, and `binders` stopped as occupied
-- — the collision that cost 19 failures by hand.
local T = require('cartograph.tactic').T

return {
    name = 'rename-field',
    kind = 'write',
    tags = { 'code' },
    summary = 'rename a record field: base = the base spelling (spec), field -> to, define = the files whose constructors define the record (a,b), accept = name-occupied to move an occupant to a placeholder',
    params = { base = 'string', field = 'string', to = 'string', define = 'list?', accept = 'string?' },
    build = function (p)
        return T.step('rename-field', { base = p.base, field = p.field, to = p.to, define = p.define },
            p.accept == 'name-occupied' and { 'name-occupied' } or nil)
    end,
    examples = {
        {
            name = 'the record\'s read and its defining key move; another record\'s same-named field stays',
            files = { ['s.lua'] = 'return { scopes = { 1 } }\n',
                ['r.lua'] = 'local M = {}\nfunction M.f(spec, L) return spec.scopes, L.scopes end\nreturn M\n' },
            params = { base = 'spec', field = 'scopes', to = 'lexical', define = { 's.lua' } },
            expect = { status = 'done', applied = 1, check = function (root)
                local r = io.open(root .. '/r.lua'):read('a')
                return r:find('return spec.lexical, L.scopes', 1, true) ~= nil and io.open(root .. '/s.lua'):read('a'):find('lexical = { 1 }', 1, true) ~= nil, r
            end },
        },
        {
            name = 'an occupied target STOPS on the decision; nothing is written',
            files = { ['s.lua'] = 'return { scopes = { 1 }, lexical = 2 }\n',
                ['r.lua'] = 'local M = {}\nfunction M.f(spec) return spec.scopes end\nreturn M\n' },
            params = { base = 'spec', field = 'scopes', to = 'lexical', define = { 's.lua' } },
            expect = { status = 'stopped', applied = 0 },
        },
    },
}
