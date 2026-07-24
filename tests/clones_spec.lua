-- Exact-structural clone detection ([[cartograph-record-fold-arc]] near-clone arc, EXACT
-- tier): two functions are clones iff their per-row canonical key sequences match. The key
-- is ALPHA-INVARIANT on locals (params ∪ df-defs → positional slots) but keeps callees /
-- globals / field names / operators / literals verbatim — so a rename is a clone, but a
-- different callee or operator is NOT. Rides the shipped expr-IR (cartograph.expr).

local clones = require 'cartograph.clones'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

-- extract a temp lua project from a { filename = source } table
local function proj(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for name, src in pairs(files) do
        local fd = assert(io.open(root .. '/' .. name, 'w')); fd:write(src); fd:close()
    end
    store.ingest(ts.extract(root))
    return root
end

-- the name-set of the clone group containing `name`, or nil if it is in no group
local function group_of(groups, name)
    for _, g in ipairs(groups) do
        for _, m in ipairs(g) do
            if m.name == name then
                local names = {}
                for _, x in ipairs(g) do names[x.name] = true end
                return names
            end
        end
    end
    return nil
end

-- a bare module-level `local function` keeps the node name simple (`f`, not `M.f`)
local function fn(name, params, body)
    return ('local function %s(%s)\n%s\nend\nreturn %s\n'):format(name, params, body, name)
end

test('clones: alpha-renamed identical bodies are one group', function ()
    local root = proj {
        ['a.lua'] = fn('sorted', 'set', '  local o = {}\n  for k in pairs(set) do o[#o + 1] = k end\n  table.sort(o)\n  return o'),
        ['b.lua'] = fn('keys', 's', '  local out = {}\n  for k in pairs(s) do out[#out + 1] = k end\n  table.sort(out)\n  return out'),
    }
    local g = group_of(clones.exact(store, { min_rows = 3 }), 'sorted')
    ok(g and g.keys, 'sorted and keys (locals `o`/`out`, `set`/`s` renamed) are clones')
    vim.fn.delete(root, 'rf')
end)

test('clones: a different CALLEE is not a clone (callees kept verbatim)', function ()
    -- up/up2 are a genuine clone (so the group is non-vacuous); dn differs only by callee
    local root = proj {
        ['a.lua'] = fn('up', 'x', '  local y = trim(x)\n  return upper(y)'),
        ['c.lua'] = fn('up2', 'w', '  local z = trim(w)\n  return upper(z)'),
        ['b.lua'] = fn('dn', 'x', '  local y = trim(x)\n  return lower(y)'),
    }
    local g = group_of(clones.exact(store, { min_rows = 2 }), 'up')
    ok(g and g.up2, 'up and up2 (alpha-renamed) ARE clones — the group is real')
    ok(not (g and g.dn), 'dn (calls lower, not upper) is excluded — the callee discriminates')
    vim.fn.delete(root, 'rf')
end)

test('clones: a different OPERATOR is not a clone', function ()
    local root = proj {
        ['a.lua'] = fn('add', 'a, b', '  local c = a + b\n  return c * 2'),
        ['c.lua'] = fn('add2', 'p, q', '  local r = p + q\n  return r * 2'),
        ['b.lua'] = fn('mul', 'a, b', '  local c = a * b\n  return c * 2'),
    }
    local g = group_of(clones.exact(store, { min_rows = 2 }), 'add')
    ok(g and g.add2, 'add and add2 (alpha-renamed) ARE clones — the group is real')
    ok(not (g and g.mul), 'mul (a*b) is excluded — the operator discriminates')
    vim.fn.delete(root, 'rf')
end)

test('clones: a unique function forms no group; report is honest on empty', function ()
    local root = proj {
        ['a.lua'] = fn('only', 'z', '  local q = z.field\n  return frobnicate(q, 7)'),
    }
    ok(not group_of(clones.exact(store, { min_rows = 2 }), 'only'), 'a lone function is in no clone group')
    ok(clones.report({})[1]:find('none'), 'empty report says none')
    vim.fn.delete(root, 'rf')
end)
