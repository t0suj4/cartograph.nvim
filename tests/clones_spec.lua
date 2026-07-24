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

-- ── block/window tier ───────────────────────────────────────────────────────

-- does any block group contain a member whose name matches `name`?
local function block_has(groups, name)
    for _, g in ipairs(groups) do
        for _, m in ipairs(g) do
            if m.name == name then return g end
        end
    end
    return nil
end

test('clones: a shared statement BLOCK inside two different functions is found', function ()
    -- two functions with distinct heads but an identical 5-statement middle+tail
    -- (the block-tier target the whole-function tier is blind to). Locals renamed
    -- (a/b/c → p/q/r; the param src → items) — the block still matches. The block
    -- uses only proper `local` declarations (real df-defs), not loop binders.
    local mid1 = '  local a = compute(src)\n  local b = a + offset\n'
        .. '  local c = wrap(b)\n  persist(c)\n  return c'
    local mid2 = '  local p = compute(items)\n  local q = p + offset\n'
        .. '  local r = wrap(q)\n  persist(r)\n  return r'
    local root = proj {
        ['a.lua'] = fn('alpha', 'src', '  log("alpha")\n' .. mid1),
        ['b.lua'] = fn('beta', 'items', '  banner()\n  setup(items)\n' .. mid2),
    }
    local groups = clones.blocks(store, { min_len = 4 })
    local g = block_has(groups, 'alpha')
    ok(g, 'the shared block is detected in alpha')
    ok(g and block_has(groups, 'beta') == g, 'alpha and beta share the same block group')
    ok(g and g.len >= 5, 'the block is reported at its full (>=5) length, not the seed length')
    vim.fn.delete(root, 'rf')
end)

test('clones: functions with no shared block yield no block group', function ()
    local root = proj {
        ['a.lua'] = fn('one', 'a', '  local x = a + 1\n  local y = x * 2\n  local z = y - 3\n  return z'),
        ['b.lua'] = fn('two', 'b', '  send(b)\n  flush()\n  local r = recv()\n  return decode(r)'),
    }
    ok(not block_has(clones.blocks(store, { min_len = 4 }), 'one'),
        'unrelated bodies share no block')
    ok(clones.blocks_report({})[1]:find('none'), 'empty block report says none')
    vim.fn.delete(root, 'rf')
end)

-- ── near-clone tier ──────────────────────────────────────────────────────────

-- the near-clone pair (if any) whose two members' names are exactly {n1, n2}
local function near_pair(pairs_, n1, n2)
    for _, p in ipairs(pairs_) do
        local nm = { [p.a.name] = true, [p.b.name] = true }
        if nm[n1] and nm[n2] then return p end
    end
    return nil
end

test('clones: two bodies differing by ONE statement are a near-clone (1 hole)', function ()
    -- identical but for a single substituted row (foo→bar) — distance 1, the rest template
    local body_a = '  local a = load(src)\n  local b = trim(a)\n  local c = foo(b)\n'
        .. '  local d = wrap(c)\n  persist(d)\n  return d'
    local body_b = '  local p = load(input)\n  local q = trim(p)\n  local r = bar(q)\n'
        .. '  local s = wrap(r)\n  persist(s)\n  return s'
    local root = proj {
        ['a.lua'] = fn('one', 'src', body_a),
        ['b.lua'] = fn('two', 'input', body_b),
    }
    local p = near_pair(clones.near(store, { max_dist = 2, min_rows = 5, min_shared = 2 }), 'one', 'two')
    ok(p, 'one and two are a near-clone')
    ok(p and p.dist == 1, 'exactly one edit (the foo→bar hole)')
    ok(p and p.shared >= 5, 'the rest is a shared template')
    vim.fn.delete(root, 'rf')
end)

test('clones: an exact clone is NOT reported as a near-clone (distance 0 excluded)', function ()
    local body = '  local a = load(src)\n  local b = trim(a)\n  local c = wrap(b)\n'
        .. '  persist(c)\n  return c'
    local root = proj {
        ['a.lua'] = fn('one', 'src', body),
        ['b.lua'] = fn('two', 'input', (body:gsub('src', 'input'))),
    }
    local near = clones.near(store, { max_dist = 2, min_rows = 5, min_shared = 2 })
    ok(not near_pair(near, 'one', 'two'), 'a distance-0 pair is an exact clone, not near')
    ok(clones.near_report({})[1]:find('none'), 'empty near report says none')
    vim.fn.delete(root, 'rf')
end)

test('clones: bodies too far apart are not near-clones', function ()
    local root = proj {
        ['a.lua'] = fn('one', 'a', '  local x = a + 1\n  local y = x * 2\n  local z = y - 3\n'
            .. '  local w = z / 4\n  return w'),
        ['b.lua'] = fn('two', 'b', '  send(b)\n  flush()\n  wait()\n  local r = recv()\n  return decode(r)'),
    }
    ok(not near_pair(clones.near(store, { max_dist = 2, min_rows = 4, min_shared = 1 }), 'one', 'two'),
        'unrelated bodies exceed max_dist → not a near-clone')
    vim.fn.delete(root, 'rf')
end)
