-- The schema validator: the closed schema as an executable registry.
local validate = require 'cartograph.validate'

local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function node(id, kind, extra)
    local n = { id = id, name = id, kind = kind or 'function',
        file = 'm.lua', range = R, order = 0 }
    for k, v in pairs(extra or {}) do n[k] = v end
    return n
end

test('validate: a clean graph is OK', function ()
    local r = validate.check({ pos_base = require('cartograph.at').BASE,
        nodes = { node('m.lua', 'module'), node('a') },
        edges = { { from = 'm.lua', to = 'a', kind = 'reg', at = { R } } },
        calls = { { callee = 'x', file = 'm.lua', line = 3 } } })
    ok(r.ok, 'clean')
    eq(2, r.checked.nodes)
end)

-- CART-2086 (user decision 2026-11-15): a graph DECLARES its position base or is rejected; a graph that predates the
-- declaration is stamped ONCE, explicitly and reported — never guessed silently.
test('validate: a graph without a declared position base is REJECTED; stamp_base stamps it once and says so (CART-2086)', function ()
    local function graph() return { nodes = { node('m.lua', 'module') }, edges = {}, calls = {} } end
    local g = graph()
    local r = validate.check(g)
    ok(not r.ok and r.violations.pos_base, 'no pos_base -> a pos_base violation')
    local msg = validate.stamp_base(g, 'a test dump')
    ok(msg and msg:find('STAMPED', 1, true) and msg:find('a test dump', 1, true), 'the stamp is REPORTED, naming the origin: ' .. tostring(msg))
    eq(true, g.pos_base_stamped.assumed, 'and the graph keeps the record that it was an assumption')
    ok(validate.check(g).ok, 'a stamped graph validates')
    eq(nil, validate.stamp_base(g, 'again'), 'ONCE: a graph that declares a base is never re-stamped')
    local bad = graph(); bad.pos_base = { line = 1, col = 0, unit = 'byte' }
    ok(validate.check(bad).violations.pos_base, 'a base that is not the storage base is rejected too')
end)

-- (CART-0717: a producer minted a node field the closed schema never learned, and `valid` stayed RED on self and zig —
-- the gate column nobody's sweep claimed. By 2026-11-06 it was FOUR unregistered facts: node fields `override`
-- (CART-0616) and `anon` (CART-1490), node kind `field` (CART-1575), call field `gp` (CART-1567). A fixture that MINTS
-- each, through the real extractor, so the next field a producer adds turns this red in the suite, not in a matrix)
test('validate: a real extraction minting override / anon / field / gp is schema-clean (CART-0717)', function ()
    if not parser_available('lua') then return skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(f, t) local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close() end
    put('a.lua', 'local M = {}\nfunction M.get() return 1 end\nreturn M\n')
    put('patch.lua', "local a = require 'a'\na.get = function () return 2 end\n")
    put('c.lua', table.concat({
        'local Cache = {}', 'Cache.__index = Cache',
        'function Cache:fill()', '    if self._v == nil then self._v = {} end', '    return self._v', 'end',
        'local function run(verbose, xs)', "    if verbose then log('x') end",
        '    table.sort(xs, function (p, q) return p < q end)', '    return xs', 'end',
        'return { Cache = Cache, run = run }', '' }, '\n'))
    local data = require('cartograph.providers.treesitter').extract(root)
    vim.fn.delete(root, 'rf')
    -- the fixture reaches all four (else the clean verdict below proves nothing)
    local seen = {}
    for _, n in ipairs(data.nodes) do
        if n.override then seen.override = true end
        if n.anon then seen.anon = true end
        if n.kind == 'field' then seen.field = true end
    end
    for _, c in ipairs(data.calls) do if c.gp then seen.gp = true end end
    eq({ anon = true, field = true, gp = true, override = true }, seen)
    local r = validate.check(data)
    ok(r.ok, 'schema-clean: ' .. vim.inspect(r.violations, { newline = ' ' }))
end)

test('validate: each violation class is caught', function ()
    local r = validate.check({
        nodes = { node('a'), node('a'),                  -- dup id
            node('b', 'gadget'),                          -- unknown kind
            node('c', 'var', { mystery = 1 }),            -- unknown field
            { id = 'd', name = 'd', kind = 'var', file = 'm.lua',
                order = 0, range = { start = { line = 5, char = 0 },
                    ['end'] = { line = 2, char = 0 } } } }, -- inverted range
        edges = { { from = 'a', to = 'ghost', kind = 'ref' },      -- dangling
            { from = 'a', to = 'c', kind = 'wormhole' },           -- unknown kind
            { from = 'a', to = 'c', kind = 'ref',
                at = { R, R, R }, atn = 2 } },                     -- atn < #at
        calls = { { callee = 'x', file = 'm.lua', line = 1,
            refused = {} },                                        -- rule-less refusal
            { callee = 'y', file = 'm.lua', line = 2, to = 'ghost' } }, -- dangling to
    })
    ok(not r.ok)
    for _, rule in ipairs({ 'node-dup-id', 'node-kind', 'node-field',
        'node-range', 'edge-dangling-to', 'edge-kind', 'edge-atn',
        'call-refusal-rule', 'call-dangling-to' }) do
        ok(r.violations[rule], rule .. ' caught')
    end
end)

-- CART-0887. The charter demands "a reified fact must say how it came to be"; until
-- now the schema could not carry it, and the manual said of accessor reads that they
-- are "shown, never minted as edges — the graph has nowhere to record where an edge
-- came from yet, and an edge that cannot say would launder one kind of claim as the
-- other". `origin` is the strength, `via` the channel — two fields because
-- characterize.lua learned from a shipped bug that "THE CHANNEL RECORDS HOW, THE TIER
-- RECORDS HOW STRONG".
test('validate: a derived fact with no `via` is the laundering the field exists to stop', function ()
    local base = { id = 'a.lua::f@1', name = 'f', kind = 'function',
        file = 'a.lua', range = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 1 } } }
    local function check(extra)
        local n = vim.tbl_extend('force', {}, base, extra or {})
        return validate.check({ nodes = { n }, edges = {}, calls = {}, root = '/x' })
    end
    -- ⚠ `check` returns { checked, ok, violations } and the rules live under
    -- `violations`, keyed by rule name. Two wrong guesses before reading it: a list
    -- of flags, then a top-level map. Both read as "the validation never fires" when
    -- it was firing correctly one level down — an accessor error, not a code one.
    local function flagged(res, tag)
        for rule in pairs((res or {}).violations or {}) do
            if tostring(rule):find(tag, 1, true) then return true end
        end
        return false
    end
    -- observed needs no via: the parse said so and the file is the witness
    ok(not flagged(check { origin = 'observed' }, 'origin'), 'observed alone is fine')
    -- derived without via is the laundering
    ok(flagged(check { origin = 'derived' }, 'origin-via'),
        'derived with no via is flagged')
    ok(not flagged(check { origin = 'derived', via = 'symfony' }, 'origin'),
        'derived WITH via is fine')
    -- and a value outside the three reads as "some other kind of fact" to consumers
    ok(flagged(check { origin = 'guessed', via = 'x' }, 'origin'),
        'an origin outside the three is flagged')
end)
