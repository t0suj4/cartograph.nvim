-- The dead-biter brush: parse an ASCII grid into corpse cells, reconcile a
-- minimal delta (corpses can't mutate -> a kind change is destroy+create), and
-- drive the full loop over a fake io. Pure; no live server.

local brush = require 'cartograph.brush'

local A = { anchor = { x = 0, y = 0 }, dx = 1, dy = 1 }

test('char_to_kind: blanks empty, letters ink, digits pick a shade', function ()
    eq(nil, brush.char_to_kind(' '))
    eq(nil, brush.char_to_kind('.'))
    eq('small-biter-corpse', brush.char_to_kind('#'))            -- default ink
    eq('small-biter-corpse', brush.char_to_kind('1'))            -- shade 1
    eq('big-biter-corpse', brush.char_to_kind('3'))              -- shade 3
    eq('behemoth-biter-corpse', brush.char_to_kind('9'))         -- clamped to last
    eq('medium-biter-corpse', brush.char_to_kind('X', 'medium-biter-corpse')) -- custom ink
end)

test('parse: ink cells at grid positions, blanks skipped', function ()
    -- row1 "#." -> corpse at (0,0); row2 ".#" -> corpse at (1,1)
    local cells = brush.parse('#.\n.#', A)
    eq(2, #cells)
    eq({ x = 0, y = 0, kind = 'small-biter-corpse' }, cells[1])
    eq({ x = 1, y = 1, kind = 'small-biter-corpse' }, cells[2])
end)

test('parse: digits map to the shade ramp', function ()
    local cells = brush.parse('13', A)
    eq('small-biter-corpse', cells[1].kind)
    eq('big-biter-corpse', cells[2].kind)
end)

test('parse: accepts a list of lines and caps to the canvas', function ()
    local cells = brush.parse({ '##', '##' }, { anchor = { x = 0, y = 0 }, max_rows = 1 })
    eq(2, #cells) -- only row 1's two cells
end)

test('reconcile: empty world -> all creates, steady -> no-op', function ()
    local want = brush.parse('##', A)
    eq(2, #brush.reconcile(want, {}).create)
    local world = { { x = 0, y = 0, kind = 'small-biter-corpse' },
        { x = 1, y = 0, kind = 'small-biter-corpse' } }
    ok(brush.is_noop(brush.reconcile(want, world)), 'matching world writes nothing')
end)

test('reconcile: a kind change is destroy + create (corpses cannot mutate)', function ()
    local want = { { x = 0, y = 0, kind = 'big-biter-corpse' } }
    local world = { { x = 0, y = 0, kind = 'small-biter-corpse' } }
    local d = brush.reconcile(want, world)
    eq({ { x = 0, y = 0 } }, d.destroy)
    eq({ { x = 0, y = 0, kind = 'big-biter-corpse' } }, d.create)
end)

test('reconcile: an erased cell is destroyed', function ()
    local want = { { x = 0, y = 0, kind = 'small-biter-corpse' } }
    local world = { { x = 0, y = 0, kind = 'small-biter-corpse' },
        { x = 5, y = 5, kind = 'small-biter-corpse' } }
    local d = brush.reconcile(want, world)
    eq(0, #d.create)
    eq({ { x = 5, y = 5 } }, d.destroy)
end)

test('project: paints an empty canvas then read-back verifies', function ()
    local n = 0
    local painted = { { x = 0, y = 0, kind = 'small-biter-corpse' } }
    local io = function (lua)
        if lua:find('find_entities_filtered') and not lua:find('create_entity') then
            n = n + 1
            return n == 1 and {} or painted -- first read empty, verify sees it placed
        end
        return 'ok'
    end
    local d = brush.project(io, '#', A)
    eq(1, #d.create)
    eq(true, d.verified)
    ok(brush.is_noop(d.drift), 'the corpse landed')
end)

test('project: read-back reports drift when a corpse did not land (or decayed)', function ()
    local io = function (lua)
        if lua:find('find_entities_filtered') and not lua:find('create_entity') then
            return {} -- always empty: nothing persisted (the decay/failed case)
        end
        return 'ok'
    end
    local d = brush.project(io, '#', A)
    eq(false, d.verified)
    eq(1, brush.delta_count(d.drift))
end)
