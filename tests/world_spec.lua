-- WORLDS AS VALUES (CART-1160 step 3): an OVERLAY world is a base world plus edits that exist only in memory, and its
-- graph is derived WITHOUT touching the base. Research (Glean's stacked databases): the hard case is a fact derived from
-- an edited unit — here a resolved call edge from an UNCHANGED caller into an EDITED callee — which must be hidden and
-- re-derived, never left dangling. The acceptance test (CodeNib): the overlay graph EQUALS a fresh rebuild of the
-- edited world, row by row, and the base graph is byte-for-byte what it was.
local world = require 'cartograph.world'
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local at = require 'cartograph.at'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') end

local A = "local B = require 'b'\nlocal A = {}\nfunction A.use1(x) return B.f(x) end\nfunction A.use2(x) return B.h(x) end\nreturn A\n"
local B0 = 'local B = {}\nfunction B.f(x) return x + 1 end\nreturn B\n'
local EDITS = {
    rename = 'local B = {}\nfunction B.g(x) return x + 1 end\nreturn B\n',
    shift = 'local B = {}\n\n\n\n\nfunction B.f(x) return x + 1 end\nreturn B\n',
    add = 'local B = {}\nfunction B.f(x) return x + 1 end\nfunction B.h(x) return x * 2 end\nreturn B\n',
}

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, t in pairs(files) do local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close() end
    return root
end
local function disk(root, rel) local fd = io.open(root .. '/' .. rel); if not fd then return nil end; local s = fd:read('a'); fd:close(); return s end

--- the rows of the ACTIVE graph that a stale edge would show in: a.lua's call dispositions and every edge touching b.lua
local function rows()
    local out, name_of = {}, {}
    for _, n in ipairs(store.data.nodes) do name_of[n.id] = ('%s@%s:%d'):format(n.name, n.file, at.sl(n.range)) end
    for _, c in ipairs(store.data.calls or {}) do
        if c.file == 'a.lua' or (c.fn and tostring(c.fn):match('^a%.lua')) then
            out[#out + 1] = ('call %s -> %s'):format(tostring(c.callee), c.to and (name_of[c.to] or ('DANGLING ' .. c.to)) or 'unresolved')
        end
    end
    for _, e in ipairs(store.data.edges or {}) do
        local f, t = name_of[e.from] or ('DANGLING ' .. tostring(e.from)), name_of[e.to] or ('DANGLING ' .. tostring(e.to))
        if f:find('b.lua', 1, true) or t:find('b.lua', 1, true) then out[#out + 1] = ('edge %s -> %s (%s)'):format(f, t, tostring(e.kind)) end
    end
    table.sort(out)
    return out
end

--- the whole base graph, deeply printed: any write into a table the overlay's shallow copy SHARES shows up here
local function fingerprint(data)
    return vim.inspect(data, { process = function (item) if type(item) == 'function' then return nil end return item end })
end

test('world.edit: an OVERLAY graph equals a rebuild of the edited world, and the BASE is exactly what it was', function ()
    if not ready() then skip 'no lua parser' end
    for _, case in ipairs { 'rename', 'shift', 'add' } do
        local root = tree { ['a.lua'] = A, ['b.lua'] = B0 }
        store.ingest(ts.extract(root))
        local base = store.data
        local base_rows, base_print = rows(), fingerprint(base)
        local over, why = world.edit(base, { ['b.lua'] = EDITS[case] })
        ok(over, case .. ': ' .. tostring(why))
        eq(true, over.virtual, case .. ': an overlay graph says it is virtual')
        local over_rows = store.scoped(over, rows)
        -- the oracle: the edited world, written out and extracted from scratch
        local rebuilt_rows = store.scoped(ts.extract(tree { ['a.lua'] = A, ['b.lua'] = EDITS[case] }), rows)
        eq(rebuilt_rows, over_rows, case .. ': the overlay graph equals a rebuild')
        ok(vim.inspect(over_rows) ~= vim.inspect(base_rows), case .. ': and the edit is visible (the comparison can see a difference)')
        -- the base, untouched: the lens, the graph (deeply), and the disk
        eq(base, store.data, case .. ': the caller\'s graph is still the lens')
        eq(base_rows, rows(), case .. ': its rows')
        eq(base_print, fingerprint(base), case .. ': the base graph, deeply — nothing wrote into a shared table')
        eq(B0, disk(root, 'b.lua'), case .. ': and the overlay never wrote the disk')
    end
end)

test('world.edit: an overlay can stack — an edit on top of an overlay sees the lower edit', function ()
    if not ready() then skip 'no lua parser' end
    local root = tree { ['a.lua'] = A, ['b.lua'] = B0 }
    store.ingest(ts.extract(root))
    local base = store.data
    local one = assert(world.edit(base, { ['b.lua'] = EDITS.add }))
    local two = assert(world.edit(one, { ['a.lua'] = A:gsub('B%.h%(x%)', 'B.f(x + 1)') }))
    local got = store.scoped(two, rows)
    local want = store.scoped(ts.extract(tree { ['a.lua'] = A:gsub('B%.h%(x%)', 'B.f(x + 1)'), ['b.lua'] = EDITS.add }), rows)
    eq(want, got, 'two stacked edits equal a rebuild of both')
    -- ★ and the LOWER overlay's TEXT is still what the upper world reads: the rows alone cannot see it (b.lua's nodes are
    -- carried over from the lower graph), a planner reading b.lua in the upper world can
    local txt = store.scoped(two, function () return require('cartograph.txn').read_file(store.data.root, 'b.lua') end)
    eq(EDITS.add, txt, 'the upper world reads the lower overlay\'s b.lua, not the disk\'s')
    eq(B0, disk(root, 'b.lua')); eq(A, disk(root, 'a.lua'))
end)

test('a VIRTUAL graph is never applied: a plan made against an overlay refuses to write the disk', function ()
    if not ready() then skip 'no lua parser' end
    local root = tree { ['a.lua'] = A, ['b.lua'] = B0 }
    store.ingest(ts.extract(root))
    local over = assert(world.edit(store.data, { ['b.lua'] = EDITS.add }))
    local r, why, class = store.scoped(over, function ()
        -- planning reads THROUGH the overlay: the planner sees B.h, which exists only in memory
        local txn = require 'cartograph.txn'
        eq(EDITS.add, txn.read_file(store.data.root, 'b.lua'), 'a planner reads the overlay text, not the disk')
        local plan = txn.protocol({ verb = 'probe', guards = {}, refspecs = {}, touched = { 'b.lua' }, generation = store.generation,
            stamps = { ['b.lua'] = txn.disk_stamp(store.data.root, 'b.lua') }, desc = 'probe', preserves = 'none' },
            function () return function (_, before) return before .. '-- x\n' end end)
        return txn.apply(store, plan)
    end)
    eq(nil, r); eq('ill-posed', class); ok(tostring(why):find('VIRTUAL', 1, true), tostring(why))
    eq(B0, disk(root, 'b.lua'), 'the disk is untouched')
end)
