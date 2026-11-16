-- CART-1951 (the BNW 2.1 port bot): `ports` listed 502 external call sites with file and line, and the break sites were
-- among them with NO VERDICT, so turning the list into "what to change" took a second pass by hand. portability_sites
-- is that join: every external call SITE with the move's verdict for its name — lost / moved (with the new form) / kept /
-- gained / not-adjudicable (with the reason). Measured on bravest-new-world (lua-factorio-11 -> lua-factorio): 675 sites
-- = externals.surface's 675, and the distinct names per verdict equal portability.diff's (kept 34, gained 1, neither 165).

local agent = require 'cartograph.agent'
local store = require 'cartograph.store'
local ts    = require 'cartograph.providers.treesitter'
local port  = require 'cartograph.portability'

local FROM, TO = 'lua-factorio-11', 'lua-factorio'
local function setup()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/control.lua', 'w'))
    fd:write(table.concat({
        'local M = {}',
        'function M.tick(player)',
        '  game.print("hi")',                               -- 3: kept
        '  local j = game.table_to_json({})',               -- 4: moved -> helpers.table_to_json (a member move)
        '  local p = game.get_filtered_entity_prototypes({})', -- 5: lost
        '  helpers.write_file("x", "y")',                   -- 6: gained (already-migrated)
        '  player.teleport({0, 0})',                        -- 7: a method on an object — not adjudicable
        '  game.print("é"); game.print("again")',           -- 8: two sites of one name, the second after a 2-byte char
        '  shared()',                                       -- 9: REFUSED (ambiguous: a.lua and b.lua): not a site
        'end',
        'return M', '' }, '\n'))
    fd:close()
    for _, f in ipairs { 'a', 'b' } do
        fd = assert(io.open(root .. '/' .. f .. '.lua', 'w')); fd:write('function shared() return 1 end\n'); fd:close()
    end
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    return root
end
local function ask(extra)
    return agent.answer(store, 'portability_sites', vim.tbl_extend('force', { from = FROM, to = TO }, extra or {}))
end
local function at(a, line, col)
    for _, r in ipairs(a.result or {}) do if r.line == line and (not col or r.col == col) then return r end end
end

test('portability_sites: every external call site carries its name\'s verdict — lost, moved with the new form, kept, gained, not-adjudicable with the reason (CART-1951)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = setup()
    local a = ask()
    eq(true, a.ok, vim.inspect(a.refusal))
    eq({ 'control.lua', 3, 3, 'game.print', 'kept' }, { at(a, 3).file, at(a, 3).line, at(a, 3).col, at(a, 3).name, at(a, 3).verdict })
    local mv = at(a, 4)
    eq('moved', mv.verdict); eq('helpers.table_to_json', mv.to); eq('member-move', mv.basis)
    eq('lost', at(a, 5).verdict); ok(at(a, 5).reason ~= vim.NIL, 'a lost site says why')
    eq('gained', at(a, 6).verdict)
    local na = at(a, 7)
    eq('not-adjudicable', na.verdict); ok(type(na.reason) == 'string' and na.reason:match('^receiver'), 'the receiver mechanism: ' .. tostring(na.reason))
    eq('player.teleport', na.full); eq('M.tick', na.fn:match('M%.tick') and 'M.tick')
    -- two sites of one name: both rows, the second's column in CHARACTERS (after `é`, 2 bytes)
    local line8 = '  game.print("é"); game.print("again")'
    local second = line8:find('game.print("again")', 1, true)
    ok(at(a, 8, 3) and at(a, 8, second - 1), 'one row per SITE, the second at its character column: ' .. vim.inspect(a.result))
    eq(7, a.subject.sites)
    eq({ lost = 1, moved = 1, kept = 1, gained = 1, ['not-adjudicable'] = 1 }, a.subject.names)
    eq({ lost = 1, moved = 1, kept = 3, gained = 1, ['not-adjudicable'] = 1 }, a.subject.by_site)
    local granular
    for _, n in ipairs(a.notes) do if n.kind == 'verdict-is-the-names' then granular = n end end
    ok(granular and vim.tbl_contains(granular.evidence.not_measured, 'signature-changed'), 'kept is the NAME kept: a signature change is not measured, and it says so')
    vim.fn.delete(root, 'rf')
end)

test('portability_sites: its population IS the external surface, and its names per verdict ARE the move diff\'s (CART-1951)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = setup()
    local a = ask({ limit = 1000 })
    eq(require('cartograph.externals').surface(store).external, a.subject.sites, 'one classifier for both')
    eq(nil, at(a, 9), 'a refused call is not on the external surface (it is the graph\'s own ambiguity, not the environment\'s)')
    local d = assert(port.diff(store, FROM, TO))
    eq(#d.lost + #d.lualib_lost, a.subject.names.lost + a.subject.names.moved)
    eq(d.kept, a.subject.names.kept); eq(#d.gained, a.subject.names.gained)
    eq(d.neither - #d.lualib_lost, a.subject.names['not-adjudicable'])
    vim.fn.delete(root, 'rf')
end)

test('portability_sites: narrowed by file and verdict, clipped with a note, absent with the premise that holds (CART-1951)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = setup()
    local k = ask({ verdict = 'kept' })
    eq(3, #k.result); eq(7, k.subject.sites, 'the subject counts the whole population, not the narrowed rows')
    local c = ask({ limit = 2 })
    eq(2, #c.result)
    local clip
    for _, n in ipairs(c.notes) do if n.kind == 'clipped' then clip = n end end
    ok(clip and clip.evidence.total == 7, 'the clip says how many there were')
    local lost = ask({ file = 'control.lua', verdict = 'lost' })
    eq(1, #lost.result); eq(5, lost.result[1].line)
    -- a tree whose every call lands inside: no external site at all
    local fd = assert(io.open(root .. '/x.lua', 'w')); fd:write('local function f() end\nf()\n'); fd:close()
    vim.fn.delete(root .. '/control.lua')
    local d2 = ts.extract(root); d2.root = root
    store.ingest(d2)
    local empty = ask()
    eq('absent', empty.absence); eq('no-external-site', empty.absence_why.premise)
    ok(not pcall(function () assert(ask({ verdict = 'broken' }).ok) end), 'an unknown verdict is a usage error, never an empty answer')
    vim.fn.delete(root, 'rf')
end)

test('portability_sites: the move verbs\' gates — a same-profile pair is refused, a missing profile is unavailable (CART-1951)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = setup()
    local same = agent.answer(store, 'portability_sites', { from = TO, to = TO })
    eq('same-profile', same.refusal.rule)
    local miss = agent.answer(store, 'portability_sites', { from = FROM, to = 'lua-factorio-99' })
    eq('unavailable', miss.absence); eq('no-such-profile', miss.absence_why.premise)
    vim.fn.delete(root, 'rf')
end)

test('portability_sites: a name NEITHER profile holds that the target\'s data-stage lualib removed is LOST, as the calls verb counts it (CART-1951)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = setup()
    -- the audits stubbed (the lualib verdict needs distilled lualib artifacts; portability_spec drives the real one):
    -- one name each way the mapping decides
    local real = port.audits
    port.audits = function ()
        local function e(name, provided, reason) return { name = name, provided = provided, reason = reason, calls = 1 } end
        return { runtime = FROM, entries = { e('game.print', true), e('game.get_filtered_entity_prototypes', false, 'lualib-removed'),
                e('player.teleport', false, 'receiver-ambiguous') } },
            { runtime = TO, entries = { e('game.print', true), e('game.get_filtered_entity_prototypes', false, 'lualib-removed'),
                e('player.teleport', false, 'receiver-ambiguous') } }
    end
    local okc, a = pcall(ask)
    port.audits = real
    assert(okc, a)
    eq('lost', at(a, 5).verdict); eq('lualib-removed', at(a, 5).reason)
    eq('not-adjudicable', at(a, 7).verdict)
    vim.fn.delete(root, 'rf')
end)
