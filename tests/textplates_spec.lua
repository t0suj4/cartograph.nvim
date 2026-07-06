-- Unit tests for the Factorio text-plates PROJECTION surface. The core
-- (encode / layout / reconcile / project) is pure, so every test runs with
-- NO live server — the wire is exercised through a fake `io` that records
-- the lua it was handed and returns canned world state. This encodes the
-- "render a node list" and "update on change / minimal delta" acceptance
-- criteria of the true-test target in CI terms.

local tp = require 'cartograph.textplates'

-- ── the calibrated glyph table ──────────────────────────────────────────────

test('encode: CARTOGRAPH matches the live-verified variations', function ()
    -- the exact indices proven in-world (A=3 offset; C=5,R=20,T=22,O=17,...)
    eq({ 5, 3, 20, 22, 17, 9, 20, 3, 18, 10 }, tp.encode('CARTOGRAPH'))
end)

test('encode: lowercase folds to the uppercase glyphs', function ()
    eq(tp.encode('CARTOGRAPH'), tp.encode('cartograph'))
end)

test('encode: space is the blank plate (variation 1)', function ()
    eq({ 1 }, tp.encode(' '))
    eq(tp.V_SPACE, tp.char_to_variation(' '))
end)

test('encode: digits map to 29..38', function ()
    eq({ 29, 30, 31, 38 }, tp.encode('0129'))
end)

test('encode: punctuation and the underscore transliteration', function ()
    -- store.lua -> S T O R E . L U A ; '_' has no plate -> minus (57)
    eq({ 21, 22, 17, 20, 7, 68, 14, 23, 3 }, tp.encode('store.lua'))
    eq(57, tp.char_to_variation('_'))   -- underscore -> minus glyph
    eq(57, tp.char_to_variation('-'))
    eq(60, tp.char_to_variation('/'))
    eq(66, tp.char_to_variation(':'))
end)

test('encode: unknown glyphs fall back to blank (row keeps its width)', function ()
    eq({ 1 }, tp.encode('\t'))
end)

-- ── layout ──────────────────────────────────────────────────────────────────

test('layout: one row per label, one plate per char, at the pitch', function ()
    local plates = tp.layout({ 'AB', 'C' }, { anchor = { x = 0, y = 0 }, dx = 3, dy = 3 })
    eq(3, #plates)
    eq({ x = 0, y = 0, v = 3, row = 1, col = 1 }, plates[1]) -- A
    eq({ x = 3, y = 0, v = 4, row = 1, col = 2 }, plates[2]) -- B
    eq({ x = 0, y = 3, v = 5, row = 2, col = 1 }, plates[3]) -- C (row 2)
end)

test('layout: over-long labels truncate to max_cols', function ()
    local plates = tp.layout({ 'ABCDE' }, { anchor = { x = 0, y = 0 }, max_cols = 3 })
    eq(3, #plates)
end)

test('entity_name: size/material -> prototype', function ()
    eq('textplate-large-gold', tp.entity_name({}))                      -- default
    eq('textplate-small-uranium', tp.entity_name({ size = 'small', material = 'uranium' }))
end)

-- ── reconcile: the minimal-delta / update-on-change contract ─────────────────

local function desired(...) -- helper: plates from bare {x,y,v} triples
    local out = {}
    for _, t in ipairs({ ... }) do out[#out + 1] = { x = t[1], y = t[2], v = t[3] } end
    return out
end

test('reconcile: empty world -> everything is a create', function ()
    local d = tp.reconcile(desired({ 0, 0, 5 }, { 3, 0, 3 }), {})
    eq(2, #d.create)
    eq(0, #d.revary)
    eq(0, #d.destroy)
end)

test('reconcile: steady state is a no-op (writes nothing)', function ()
    local want = desired({ 0, 0, 5 }, { 3, 0, 3 })
    local world = { { x = 0, y = 0, v = 5, u = 11 }, { x = 3, y = 0, v = 3, u = 12 } }
    local d = tp.reconcile(want, world)
    ok(tp.is_noop(d), 'identical world should reconcile to nothing')
end)

test('reconcile: a changed glyph is a revary in place (keeps unit_number)', function ()
    local want = desired({ 0, 0, 6 }) -- was 5, now 6
    local world = { { x = 0, y = 0, v = 5, u = 42 } }
    local d = tp.reconcile(want, world)
    eq(0, #d.create)
    eq(0, #d.destroy)
    eq({ { x = 0, y = 0, v = 6, u = 42 } }, d.revary)
end)

test('reconcile: a dropped cell is a destroy by unit_number', function ()
    local want = desired({ 0, 0, 5 })
    local world = { { x = 0, y = 0, v = 5, u = 1 }, { x = 3, y = 0, v = 9, u = 2 } }
    local d = tp.reconcile(want, world)
    ok(tp.is_noop({ create = d.create, revary = d.revary, destroy = {} }),
        'the surviving cell must not be rewritten')
    eq({ { x = 3, y = 0, u = 2 } }, d.destroy)
end)

test('reconcile: shortening a label destroys the tail, keeps the head', function ()
    -- "AB" -> "A": cell (3,0) goes away, (0,0) stays untouched
    local before = tp.layout({ 'AB' }, { anchor = { x = 0, y = 0 } })
    local world = {}
    for i, p in ipairs(before) do world[i] = { x = p.x, y = p.y, v = p.v, u = i } end
    local after = tp.layout({ 'A' }, { anchor = { x = 0, y = 0 } })
    local d = tp.reconcile(after, world)
    eq(0, #d.create)
    eq(0, #d.revary)
    eq(1, #d.destroy)
    eq(2, d.destroy[1].u) -- the 'B' plate
end)

-- ── project: the full observe -> reconcile -> apply loop over a fake wire ────

test('project: first paint reads the world then writes creates', function ()
    local calls = {}
    local io = function (lua)
        calls[#calls + 1] = lua
        if lua:find('find_entities_filtered') and lua:find('graphics_variation') and not lua:find('create_entity') then
            return {} -- read: empty world
        end
        return 'ok' -- apply
    end
    local d = tp.project(io, { 'AB' }, { anchor = { x = 0, y = 0 }, surface = 'nauvis' })
    eq(2, #d.create)
    eq(2, #calls)                       -- one read, one apply
    ok(calls[1]:find('find_entities_filtered'), 'first call observes the world')
    ok(calls[2]:find('create_entity'), 'second call writes the delta')
    ok(calls[1]:find('nauvis'), 'surface is threaded to the wire')
end)

-- ── the live wire: mcp_io envelope + project over a fake MCP client ─────────

-- a fake cartograph.mcp client: records tool calls, returns the FactoMCP
-- envelope { result = <text> } for run_lua (reads carry canned world JSON)
local function fake_client(world_json)
    return {
        alive = true, calls = {},
        call = function (self, tool, args)
            self.calls[#self.calls + 1] = { tool = tool, code = args.code }
            if args.code:find('find_entities_filtered') and not args.code:find('create_entity') then
                return { result = world_json or '[]' } -- a read
            end
            return { result = 'ok' }                    -- an apply
        end,
    }
end

test('mcp_io: unwraps FactoMCP { result = "<json>" } and decodes it', function ()
    local c = fake_client('[{"x":0,"y":0,"v":5,"u":7}]')
    local io = tp.mcp_io(c)
    local got = io('… find_entities_filtered … graphics_variation …')
    eq({ { x = 0, y = 0, v = 5, u = 7 } }, got)
end)

test('mcp_io: a non-JSON result (apply "ok") comes back as-is', function ()
    local c = fake_client()
    eq('ok', tp.mcp_io(c)('s.create_entity{...}'))
end)

test('project: drives end-to-end through mcp_io over a fake client', function ()
    local c = fake_client('[]') -- empty world -> everything is a create
    local io = tp.mcp_io(c)
    local d = tp.project(io, { 'AB' }, { anchor = { x = 0, y = 0 } })
    eq(2, #d.create)
    eq('run_lua', c.calls[1].tool)         -- reached the tool
    ok(c.calls[1].code:find('find_entities_filtered'), 'first call reads')
    ok(c.calls[2].code:find('create_entity'), 'second call writes')
end)

test('canvas_bbox: spans the full max_cols×max_rows the projection owns', function ()
    local b = tp.canvas_bbox({ anchor = { x = 0, y = 0 }, dx = 3, dy = 3, max_cols = 40, max_rows = 32 })
    ok(b[2][1] >= 40 * 3, 'width spans max_cols')
    ok(b[2][2] >= 32 * 3, 'height spans max_rows')
end)

test('project: reads the whole canvas so a shrunk list reclaims far rows', function ()
    -- regression: reading only the tight desired bbox orphaned rows that the
    -- new (shorter) list vacated — they fell outside the read and survived.
    local read
    local io = function (lua)
        if lua:find('find_entities_filtered') and not lua:find('create_entity') then
            read = lua; return {}
        end
        return 'ok'
    end
    tp.project(io, { 'A' }, { anchor = { x = 0, y = 0 }, max_rows = 32, dy = 3 })
    -- canvas bottom = 0 + 32*3 + 1 = 97; a desired-bbox read (1 row) would stop near 3
    ok(read and read:find('97'), 'the read extends to the bottom of the canvas')
end)

test('connect: errors clearly when no factorio server is configured', function ()
    local client, err = tp.connect({}) -- no cmd
    eq(nil, client)
    ok(err:find('no factorio MCP server'), 'names the missing config')
end)

test('layout: max_rows caps how many rows reach the world', function ()
    local plates = tp.layout({ 'A', 'B', 'C', 'D' }, { anchor = { x = 0, y = 0 }, max_rows = 2 })
    eq(2, #plates) -- only A and B (one plate each)
end)

test('project: a steady world skips the apply call entirely', function ()
    local want = tp.layout({ 'AB' }, { anchor = { x = 0, y = 0 } })
    local world = {}
    for i, p in ipairs(want) do world[i] = { x = p.x, y = p.y, v = p.v, u = i } end
    local applied = false
    local io = function (lua)
        if lua:find('create_entity') or lua:find('%.destroy%(%)') or lua:find('graphics_variation=') then
            applied = true
            return 'ok'
        end
        return world -- the read
    end
    local d = tp.project(io, { 'AB' }, { anchor = { x = 0, y = 0 } })
    ok(tp.is_noop(d), 'no change -> empty delta')
    ok(not applied, 'a no-op delta must not touch the world')
end)
