-- RENAME-FIELD (write, CART-1175): rename a record's field at the reads `<base>.<field>` and the table-constructor keys
-- in the files that DEFINE the record — never a syntactic rename. An occupied target is a DECISION (`name-occupied`):
-- accepted, the occupant moves to a placeholder `<to>__1` and choosing its real name is left as a deferred decision.
-- Comment/string mentions are a counted frontier, never rewritten. REPLAYED on CART-1160 step 7 (the tree at
-- 2203d17^): the same 3 reads + 3 keys the hand rename changed, `L.scopes` untouched, and `binders` stopped as occupied
-- — the collision that cost 19 failures by hand.
local T = require('cartograph.tactic').T

local FAM_A = table.concat({
    'local M = {}',
    'function M.mk(n) return { name = n, size = 1 } end',
    'function M.label(r) return r.name end',
    "function M.big(r) return r['size'] > 1 end",
    'return M', '' }, '\n')
local FAM_B = table.concat({
    "local A = require 'a'",
    "local other = { name = 'b' }",
    "local function go() local rec = A.mk('x'); rec.size = 3; return A.label(rec), A.big(rec), other.name end",
    'return go', '' }, '\n')

return {
    name = 'rename-field',
    kind = 'write',
    tags = { 'code' },
    summary = 'rename a record field: base = the base spelling (spec), field -> to, define = the files whose constructors define the record (a,b), accept = name-occupied to move an occupant to a placeholder; OR family = the constructors (file:LINE,…) — by provenance: every access flowtype says those tables reach, under any spelling (world = closed|open)',
    params = { base = 'string?', field = 'string', to = 'string', define = 'list?', accept = 'string?', family = 'list?', world = 'string?' },
    build = function (p)
        if p.family then return T.step('rename-field', { family = p.family, field = p.field, to = p.to, world = p.world }) end
        return T.step('rename-field', { base = p.base, field = p.field, to = p.to, define = p.define },
            p.accept == 'name-occupied' and { 'name-occupied' } or nil)
    end,
    examples = {
        {
            name = 'by provenance: the family\'s key, a read under ANOTHER spelling and a string key move; another table\'s same-named field stays',
            files = { ['a.lua'] = FAM_A, ['b.lua'] = FAM_B },
            params = { family = { 'a.lua:2' }, field = 'name', to = 'title' },
            expect = { status = 'done', applied = 1, check = function (root)
                local a, b = io.open(root .. '/a.lua'):read('a'), io.open(root .. '/b.lua'):read('a')
                return a:find('{ title = n, size = 1 }', 1, true) ~= nil and a:find('return r.title end', 1, true) ~= nil
                    and b:find("local other = { name = 'b' }", 1, true) ~= nil and b:find('other.name', 1, true) ~= nil, a .. b
            end },
        },
        {
            name = 'by provenance: file:LINE names the OUTERMOST constructor — a nested table on the same line keeps its own same-named field',
            files = { ['a.lua'] = 'local M = {}\nfunction M.mk(n) return { name = n, meta = { name = "inner" } } end\nfunction M.label(r) return r.name, r.meta.name end\nreturn M\n',
                ['b.lua'] = "local A = require 'a'\nreturn A.label(A.mk('x'))\n" },
            params = { family = { 'a.lua:2' }, field = 'name', to = 'title' },
            expect = { status = 'done', applied = 1, check = function (root)
                local a = io.open(root .. '/a.lua'):read('a')
                return a:find('{ title = n, meta = { name = "inner" } }', 1, true) ~= nil and a:find('return r.title, r.meta.name end', 1, true) ~= nil, a
            end },
        },
        {
            name = 'by provenance: a module\'s FUNCTION field — its declaration `function M.label` and the call `A.label(rec)` in another file',
            files = { ['a.lua'] = FAM_A, ['b.lua'] = FAM_B },
            params = { family = { 'a.lua:1' }, field = 'label', to = 'tag' },
            expect = { status = 'done', applied = 1, check = function (root)
                local a, b = io.open(root .. '/a.lua'):read('a'), io.open(root .. '/b.lua'):read('a')
                return a:find('function M.tag(r)', 1, true) ~= nil and b:find('A.tag(rec)', 1, true) ~= nil, a .. b
            end },
        },
        {
            name = 'by provenance: an access the family SHARES with another table stops — widen the family; nothing is written',
            files = { ['a.lua'] = FAM_A, ['b.lua'] = FAM_B:gsub('A.label%(rec%)', 'A.label(rec), A.label(other)') },
            params = { family = { 'a.lua:2' }, field = 'name', to = 'title' },
            expect = { status = 'stopped', applied = 0 },
        },
        {
            name = 'by provenance: a computed key that cannot be a string (`rec[A]`, a table) names no field — the rename proceeds',
            files = { ['a.lua'] = FAM_A, ['b.lua'] = FAM_B:gsub('rec.size = 3;', 'rec.size = 3; rec[A] = true;') },
            params = { family = { 'a.lua:2' }, field = 'name', to = 'title' },
            expect = { status = 'done', applied = 1 },
        },
        {
            name = 'by provenance: a computed key the family reaches cannot be proven — refused, nothing is written',
            files = { ['a.lua'] = FAM_A:gsub('return M\n$', 'function M.get(r, k) return r[k] end\nreturn M\n'),
                ['b.lua'] = FAM_B:gsub('A.big%(rec%)', 'A.big(rec), A.get(rec, "name")') },
            params = { family = { 'a.lua:2' }, field = 'name', to = 'title' },
            expect = { status = 'failed', applied = 0, check = function (_, res) return res.class == 'frontier', tostring(res.class) .. ' ' .. tostring(res.why) end },
        },
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
