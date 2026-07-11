-- The range fold: nested {start,end} tables -> four coordinate columns,
-- values become indexes, at.lua's dual-mode accessors read both. The
-- c.at<->e.at ALIASING (addref shares range tables) must fold to one
-- index — table-identity interning is the whole trick.

local atr = require 'cartograph.at'

local function R(sl, sc, el, ec)
    return { start = { line = sl, char = sc }, ['end'] = { line = el, char = ec } }
end

local function coords(r)
    return { atr.sl(r), atr.sc(r), atr.el(r), atr.ec(r), atr.oneline(r) }
end

test('at fold: accessors read folded and raw identically', function ()
    local shared = R(5, 2, 5, 9)              -- aliased: c.at AND e.at[1]
    local solo = R(7, 0, 8, 3)                -- multi-line, edge-only
    local nrange = R(1, 0, 20, 0)             -- a node range
    local data = {
        nodes = { { id = 'f', range = nrange } },
        calls = { { callee = 'g', at = shared } },
        edges = { { from = 'f', to = 'g', kind = 'ref', at = { shared, solo } } },
    }
    local before = { coords(shared), coords(solo), coords(nrange) }
    local n = atr.fold(data)
    eq(3, n, 'three UNIQUE ranges interned (the alias folded once)')
    local c, e, nd = data.calls[1], data.edges[1], data.nodes[1]
    ok(type(c.at) == 'number' and type(nd.range) == 'number', 'values are indexes')
    eq(c.at, e.at[1], 'c.at and its e.at alias share ONE index')
    eq(before[1], coords(c.at), 'call range reads identically')
    eq(before[2], coords(e.at[2]), 'edge-only range reads identically')
    eq(before[3], coords(nd.range), 'node range reads identically')
    eq(false, atr.oneline(e.at[2]), 'multi-line stays multi-line')
    eq(0, atr.fold(data), 'idempotent')
end)

test('at fold: post-fold arrivals stay raw, read through the same seam', function ()
    local data = { nodes = {}, calls = { { callee = 'g', at = R(1, 1, 1, 4) } },
        edges = {} }
    atr.fold(data)
    local fresh = R(9, 0, 9, 5) -- oracle caller / refresh / literal highlight
    data.edges[1] = { from = 'a', to = 'b', kind = 'ref', at = { fresh } }
    eq(9, atr.sl(data.edges[1].at[1]), 'raw table read via dual mode')
    eq(1, atr.sl(data.calls[1].at), 'folded neighbor unaffected')
end)

test('at fold: real extract parity through store.ingest', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local shared = 0',
        'local function a() return shared end',
        'local function b() a() a() return shared end',
        'return { a = a, b = b }',
    }, '\n'))
    fd:close()
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'

    -- snapshot every range through the accessors, raw
    local raw = ts.extract(root)
    local function snap(data)
        local out = {}
        for _, n in ipairs(data.nodes) do out[#out + 1] = coords(n.range) end
        for _, c in ipairs(data.calls) do
            if c.at then out[#out + 1] = coords(c.at) end
        end
        for _, e in ipairs(data.edges) do
            for _, r in ipairs(type(e.at) == 'table' and e.at or {}) do
                out[#out + 1] = coords(r)
            end
        end
        return out
    end
    local before = snap(raw)
    store.ingest(ts.extract(root)) -- ingest folds (df + at)
    local after = snap(store.data)
    eq(before, after, 'every range reads identically through ingest+fold')
    ok(type(store.data.nodes[1].range) == 'number', 'node ranges folded')
    local occ_ok = true
    for _, tos in pairs(store.uses) do
        for _, to in ipairs(tos) do occ_ok = occ_ok and to ~= nil end
    end
    ok(occ_ok, 'indexes intact')
end)
