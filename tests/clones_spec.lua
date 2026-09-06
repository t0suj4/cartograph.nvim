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

-- CART-0353. The ROW tier: a literal duplicating a module constant, in a statement written
-- elsewhere using the name. Neither half is sufficient alone, so both are pinned.
test('clones: a literal that IS a module constant, where a twin statement reads it, is row-drift', function ()
    -- the shape from our own fold.lua: RULE_SHIFT = 2, one site divides by the name and
    -- another by a bare 2.
    local root = proj {
        ['a.lua'] = 'local SHIFT = 2\n'
            .. 'local function good(f, r) local rank = math.floor(f[r] / SHIFT) % 8 return rank end\n'
            .. 'local function bad(f, r) local rank = math.floor(f[r] / 2) % 8 return rank end\n'
            .. 'return { good, bad }\n',
    }
    local d = clones.row_drift(store, { min_other = 1 })
    ok(#d == 1, 'exactly one finding')
    ok(d[1] and d[1].name == 'SHIFT', 'it names the constant being bypassed')
    ok(d[1] and d[1].value == 2, 'and the value they share')
    ok(d[1] and d[1].lit_line == 3, 'and points at the HARDCODED site, not the correct one')
    ok(clones.row_drift_report(d)[1]:find('1 literal', 1, true), 'the report counts it')
    vim.fn.delete(root, 'rf')
end)

test('clones: row-drift needs BOTH halves — a matching row alone, or an equal value alone, is not enough', function ()
    -- (a) the statements match with one leaf blanked, but the literal is NOT the constant's
    -- value: `0` against QUIET (=80) is a deliberate difference, not a stale copy.
    local root = proj {
        ['a.lua'] = 'local QUIET = 80\n'
            .. 'local function one(s) return defer(s, QUIET) end\n'
            .. 'local function two(s) return defer(s, 0) end\n'
            .. 'return { one, two }\n',
    }
    ok(#clones.row_drift(store, { min_other = 1 }) == 0, 'an unequal value is not drift')
    vim.fn.delete(root, 'rf')

    -- (b) the literal equals a module constant, but NO other statement reads it there —
    -- otherwise every `2` in a file that happens to define `SHIFT = 2` would be a finding.
    local root2 = proj {
        ['b.lua'] = 'local SHIFT = 2\n'
            .. 'local function one(f, r) local x = math.floor(f[r] / 2) % 8 return x end\n'
            .. 'local function two(f, r) local y = math.ceil(f[r] * 2) + 8 return y end\n'
            .. 'return { one, two }\n',
    }
    ok(#clones.row_drift(store, { min_other = 1 }) == 0, 'an equal value with no twin statement is not drift')
    vim.fn.delete(root2, 'rf')
end)

-- CART-0355. The census said the table-of-constants idiom holds 3.1x more constants than
-- bare scalars on this tree, so the row tier must see a CONSTRUCTOR FIELD as one blankable
-- position — otherwise `C.SHIFT` (a field CHAIN) never shares a key with a bare literal.
test('clones: a literal that IS a table-of-constants field, where a twin reads it, is row-drift', function ()
    local root = proj {
        ['a.lua'] = 'local C = { SHIFT = 2, NAME = "x" }\n'
            .. 'local function good(f, r) local rank = math.floor(f[r] / C.SHIFT) % 8 return rank end\n'
            .. 'local function bad(f, r) local rank = math.floor(f[r] / 2) % 8 return rank end\n'
            .. 'return { good, bad }\n',
    }
    local d = clones.row_drift(store, { min_other = 1 })
    ok(#d == 1, 'exactly one finding')
    ok(d[1] and d[1].name == 'C.SHIFT', 'it names the DOTTED path, not just the field')
    ok(d[1] and d[1].value == 2, 'and the value they share')
    ok(d[1] and d[1].lit_line == 3, 'and points at the hardcoded site')
    vim.fn.delete(root, 'rf')
end)

test('clones: the build-up form T.F = v is a constant too, and a boolean one never is', function ()
    -- (a) `M.WIDTH = 64` written at module scope is the same idiom as the constructor.
    local root = proj {
        ['a.lua'] = 'local M = {}\nM.WIDTH = 64\n'
            .. 'local function good(b) local x = pad(b, M.WIDTH) return x end\n'
            .. 'local function bad(b) local y = pad(b, 64) return y end\nreturn M\n',
    }
    local d = clones.row_drift(store, { min_other = 1 })
    ok(#d == 1 and d[1].name == 'M.WIDTH', 'a build-up assignment is indexed as a constant')
    vim.fn.delete(root, 'rf')

    -- (b) a BOOLEAN field is a set-membership flag, not a value a literal can be a stale
    -- copy of — every `true` in the tree would match it, so the tier must not offer it.
    local root2 = proj {
        ['b.lua'] = 'local F = { ON = true }\n'
            .. 'local function good(s) local x = mark(s, F.ON) return x end\n'
            .. 'local function bad(s) local y = mark(s, true) return y end\nreturn F\n',
    }
    ok(#clones.row_drift(store, { min_other = 1 }) == 0, 'a boolean constant is not offered as drift')
    vim.fn.delete(root2, 'rf')
end)

test('constfold: a rebound table field is poisoned, and a data table is over the cap', function ()
    local constfold = require 'cartograph.constfold'
    local big = {}
    for i = 1, 40 do big[#big + 1] = ('K%d = %d'):format(i, i) end
    local root = proj {
        ['a.lua'] = 'local C = { SHIFT = 2 }\nC.SHIFT = 3\n'
            .. 'local D = { KEEP = 7 }\n'
            .. 'local BIG = { ' .. table.concat(big, ', ') .. ' }\n'
            .. 'local function f() return C, D, BIG end\nreturn f\n',
    }
    local idx = constfold.literal_index(store, { max_fields = 20 })
    local file
    for f in pairs(idx) do if f:find('a%.lua') then file = f end end
    local cd = file and idx[file] or {}
    ok(cd['C.SHIFT'] == nil, 'a field rebound at module scope is POISONED, not its first value')
    ok(cd['D.KEEP'] == 7, 'an untouched field is indexed under its dotted path')
    ok(cd['BIG.K1'] == nil, 'a 40-entry data table is over the cap and indexed not at all')
    ok(cd['BIG.K40'] == nil, 'not even its last field')
    vim.fn.delete(root, 'rf')
end)

test('constfold: the analysis-time literal index carries numbers, and poisons a rebind', function ()
    local constfold = require 'cartograph.constfold'
    local root = proj {
        ['a.lua'] = 'local N = 2\nlocal S = "hi"\nlocal B = true\nlocal R = 1\nR = 9\n'
            .. 'local C = compute()\nlocal function f() return N, S, B, R, C end\nreturn f\n',
    }
    local idx = constfold.literal_index(store)
    local file
    for f in pairs(idx) do if f:find('a%.lua') then file = f end end
    local cd = file and idx[file] or {}
    ok(cd.N == 2, 'a NUMBER is indexed (the extraction-time index is string-only)')
    ok(cd.S == 'hi', 'a string arrives with its quotes stripped, via expr.eval')
    ok(cd.B == true, 'a boolean is indexed')
    ok(cd.C == nil, 'a call-valued binding is absent — it is not a constant')
    ok(cd.R == nil, 'a name rebound at module scope is POISONED, not reported as its first value')
    vim.fn.delete(root, 'rf')
end)

-- CART-0349. One copy hardcodes what the other reads — the divergent row of a near-clone
-- is either the helper's parameter or a stale copy, and we only ever said the first.
local function drift_of(n1, n2, opts)
    local p = near_pair(clones.near(store, opts or { max_dist = 2, min_rows = 4, min_shared = 2 }), n1, n2)
    return p and clones.analyze_pair(p).drift or nil
end

test('clones: a literal facing a READ in an otherwise identical row is reported as possible drift', function ()
    -- the real shape, from this repo's own 51e3c4a: one copy hardcoded 'q' for the close
    -- key while its twin read it from config, so a user remap silently did not apply.
    local function body(keyexpr)
        return ('  local h = open(b)\n  local n = norm(h)\n  bind(\'n\', %s, b)\n'
            .. '  log(n)\n  return n'):format(keyexpr)
    end
    local root = proj {
        ['a.lua'] = fn('one', 'b', body('cfg.close')),
        ['b.lua'] = fn('two', 'b', body("'q'")),
    }
    local d = drift_of('one', 'two')
    ok(d and #d == 1, 'the hardcoded key is reported')
    -- the quotes are part of `lit` ON PURPOSE. A str literal's `v` is raw source text,
    -- which normally wants reading through expr.eval — but this value is for DISPLAY,
    -- and "hardcodes 'q'" tells the reader it is a string where "hardcodes q" does not.
    ok(d and d[1] and d[1].lit == "'q'", 'it names the literal that was hardcoded')
    ok(d and d[1] and d[1].other == 'field', 'and what the other copy read instead')
    vim.fn.delete(root, 'rf')
end)

test('clones: a nil literal is NOT drift, and neither is a row that diverges twice', function ()
    -- nil is the ABSENCE of a value, so it is never the constant a name would have
    -- supplied: `return nil` against `return e` is one path yielding nothing.
    local root = proj {
        ['a.lua'] = fn('one', 'b', '  local h = open(b)\n  local n = norm(h)\n  local r = pick(h)\n  log(n)\n  return r'),
        ['b.lua'] = fn('two', 'b', '  local h = open(b)\n  local n = norm(h)\n  local r = nil\n  log(n)\n  return r'),
    }
    local d = drift_of('one', 'two')
    ok(not d or #d == 0, 'a nil literal is not a hardcoded constant')
    vim.fn.delete(root, 'rf')

    -- and two different assignments that merely rhyme are not one drifted statement:
    -- `info.isTitle = 1` vs `info.text = CLOSE` (Altoholic) diverges at the FIELD too.
    local root2 = proj {
        ['c.lua'] = fn('three', 'b', '  local i = mk(b)\n  local n = norm(i)\n  i.isTitle = 1\n  log(n)\n  return i'),
        ['d.lua'] = fn('four', 'b', '  local i = mk(b)\n  local n = norm(i)\n  i.text = CLOSE\n  log(n)\n  return i'),
    }
    local d2 = drift_of('three', 'four')
    ok(not d2 or #d2 == 0, 'a row diverging in TWO places is not the same statement')
    vim.fn.delete(root2, 'rf')
end)

test('clones: tied near-clone pairs report a rank BAND, and the tie is broken deterministically', function ()
    -- CART-0348. The near order ranks on (shared, dist) ONLY, and on this repo's own
    -- history that leaves wide ties — the answer-key pair came back at rank 13 on one
    -- run and 14 on the next, same input, because table.sort is not stable. Two things
    -- are pinned here: the report must not claim a point rank it never computed, and
    -- the residual order must at least be a FUNCTION of the input.
    local function body(f, tail)
        return ('  local y = %s(x)\n  local z = norm(y)\n  local w = pad(z)\n  %s(w)\n  return w')
            :format(f, tail)
    end
    local root = proj {
        -- two independent pairs, each 1 edit / 4 shared → they TIE with each other
        ['a.lua'] = fn('one', 'x', body('trim', 'log')),
        ['b.lua'] = fn('two', 'x', body('trim', 'warn')),
        ['c.lua'] = fn('three', 'x', body('fetch', 'emit')),
        ['d.lua'] = fn('four', 'x', body('fetch', 'push')),
    }
    local ps = clones.near(store, { max_dist = 2, min_rows = 4, min_shared = 2 })
    ok(near_pair(ps, 'one', 'two') and near_pair(ps, 'three', 'four'), 'both pairs found')
    local L = table.concat(clones.near_report(ps, store), '\n')
    ok(L:find('#1-2 of ', 1, true), 'the tied pairs print a RANGE, not a made-up point rank')

    -- and the tie itself resolves on the pair's location, so the order is reproducible
    local first
    for _, p in ipairs(ps) do
        if not first and (p.a.name == 'one' or p.a.name == 'three'
            or p.b.name == 'one' or p.b.name == 'three') then first = p end
    end
    ok(first and (first.a.file:find('a%.lua') or first.b.file:find('a%.lua')),
        'a.lua/b.lua sorts before c.lua/d.lua — the residual order is a function of the input')
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

test('clones: relative-local naming survives an inserted local (insertion-stable)', function ()
    -- `two` inserts `local extra = tap(q)` mid-body; under function-global slot numbering
    -- every later local drifts and the pair inflates past max_dist. Relative-local
    -- alignment counts it as ONE edit (the inserted row) and still finds the near-clone.
    local body_a = '  local a = load(src)\n  local b = trim(a)\n  local c = wrap(b)\n'
        .. '  local d = mark(c)\n  persist(d)\n  return d'
    local body_b = '  local a = load(src)\n  local extra = tap(a)\n  local b = trim(a)\n'
        .. '  local c = wrap(b)\n  local d = mark(c)\n  persist(d)\n  return d'
    local root = proj {
        ['a.lua'] = fn('one', 'src', body_a),
        ['b.lua'] = fn('two', 'src', body_b),
    }
    local p = near_pair(clones.near(store, { max_dist = 2, min_rows = 5, min_shared = 2 }), 'one', 'two')
    ok(p, 'the inserted-local near-clone is found (not lost to slot drift)')
    ok(p and p.dist <= 2, 'the distance reflects the single insertion, not cascaded drift')
    vim.fn.delete(root, 'rf')
end)

test('clones: relative alignment stays sound — inconsistent locals are not a clone', function ()
    -- same coarse shape, but the roles of the two locals are SWAPPED between copies
    -- (a↔b). Locals-abstracted these look identical; the bijection-consistency guard
    -- must reject the match (no consistent renaming), so they are NOT a near-clone.
    local body_a = '  local a = src\n  local b = other\n  push(a)\n  push(b)\n  push(a)\n  return b'
    local body_b = '  local a = src\n  local b = other\n  push(b)\n  push(a)\n  push(b)\n  return a'
    local root = proj {
        ['a.lua'] = fn('one', 'src', body_a),
        ['b.lua'] = fn('two', 'src', body_b),
    }
    -- distance-0 (exact) is excluded anyway; the point is the guard doesn't fabricate a
    -- spurious distance-0 "clone" out of an inconsistent local bijection
    local p = near_pair(clones.near(store, { max_dist = 3, min_rows = 4, min_shared = 1 }), 'one', 'two')
    ok(not p or p.dist >= 1, 'a role-swap is never reported as a zero-edit clone')
    vim.fn.delete(root, 'rf')
end)

-- ── anti-unification: refine holes into parameters, propose the helper ───────

test('clones: anti-unification classifies a leaf-value hole as a parameter', function ()
    -- one/two differ only at the callee foo⇄bar (both globals) → value-parameterizable
    local body_a = '  local a = load(src)\n  local b = trim(a)\n  local c = foo(b)\n'
        .. '  local d = wrap(c)\n  persist(d)\n  return d'
    local body_b = '  local p = load(input)\n  local q = trim(p)\n  local r = bar(q)\n'
        .. '  local s = wrap(r)\n  persist(s)\n  return s'
    local root = proj {
        ['a.lua'] = fn('one', 'src', body_a),
        ['b.lua'] = fn('two', 'input', body_b),
    }
    local p = near_pair(clones.near(store, { max_dist = 2, min_rows = 5, min_shared = 2 }), 'one', 'two')
    ok(p, 'the pair is found')
    local a = p and clones.analyze_pair(p)
    ok(a and a.kind == 'value', 'a leaf-only divergence is value-parameterizable')
    ok(a and #a.holes == 1 and a.holes[1].kind == 'name', 'one name parameter')
    ok(a and ((a.holes[1].a == 'foo' and a.holes[1].b == 'bar')
        or (a.holes[1].a == 'bar' and a.holes[1].b == 'foo')), 'the parameter is foo ⇄ bar')
    -- the proposal names it
    local prop = clones.extract_proposal(p)
    ok(prop[1]:find('extraction proposal'), 'a value pair yields an extraction proposal')
    -- the hole carries the source SPAN of the diverging leaf in each copy (from the
    -- expr-IR ranges) — the exact substitution site a future extract transaction rewrites
    local at = require 'cartograph.at'
    local h = a.holes[1]
    ok(h.at_a and h.at_b, 'the hole carries a range in each copy')
    local function span(f_id, r)
        local n = store.node(f_id)
        local lines = store.content(n)
        return (lines[at.sl(r) + 1] or ''):sub(at.sc(r) + 1, at.ec(r))
    end
    local ida, idb
    for _, nn in ipairs(store.data.nodes) do
        if nn.name == 'one' then ida = nn.id elseif nn.name == 'two' then idb = nn.id end
    end
    local sa, sb = span(ida, h.at_a), span(idb, h.at_b)
    ok((sa == 'foo' and sb == 'bar') or (sa == 'bar' and sb == 'foo'),
        'the hole ranges span exactly the diverging tokens (foo / bar), got ' .. sa .. ' / ' .. sb)
    vim.fn.delete(root, 'rf')
end)

test('clones: an inserted statement makes the pair structural (needs a human)', function ()
    -- identical body, but `two` inserts an extra statement → an ins edit → structural
    local body_a = '  local a = load(src)\n  local b = trim(a)\n  local c = wrap(b)\n'
        .. '  persist(c)\n  return c'
    local body_b = '  local p = load(input)\n  local q = trim(p)\n  validate(q)\n'
        .. '  local r = wrap(q)\n  persist(r)\n  return r'
    local root = proj {
        ['a.lua'] = fn('one', 'src', body_a),
        ['b.lua'] = fn('two', 'input', body_b),
    }
    local p = near_pair(clones.near(store, { max_dist = 2, min_rows = 5, min_shared = 2 }), 'one', 'two')
    ok(p, 'the pair is found (within max_dist)')
    local a = p and clones.analyze_pair(p)
    ok(a and a.kind == 'structural', 'an inserted statement is not a clean value-parameterization')
    ok(a and a.insdel >= 1, 'the insert is accounted')
    ok(clones.extract_proposal(p)[1]:find('structurally'), 'the proposal declines with a reason')
    vim.fn.delete(root, 'rf')
end)

-- ── body-extractability verdict (untangle.body_extractable, prereq #3) ───────

local function fn_id(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end

test('clones: a top-level clean body is extractable', function ()
    local root = proj { ['a.lua'] = fn('clean', 'x', '  local y = trim(x)\n  return upper(y)') }
    local v = require('cartograph.untangle').body_extractable(store, fn_id('clean'))
    ok(v.ok, 'a top-level fn with only module/global free reads is liftable')
    vim.fn.delete(root, 'rf')
end)

test('clones: a NESTED body is not extractable (upvalue capture risk)', function ()
    local root = proj { ['a.lua'] =
        'local function outer(a)\n  local cap = a * 2\n'
        .. '  local function inner(b)\n    local y = trim(b)\n    return y + cap\n  end\n'
        .. '  return inner\nend\nreturn outer\n' }
    local v = require('cartograph.untangle').body_extractable(store, fn_id('inner'))
    ok(not v.ok and v.nested, 'a nested function is flagged (may capture enclosing upvalues)')
    vim.fn.delete(root, 'rf')
end)

test('clones: a vararg body is not extractable (would need ... forwarded)', function ()
    local root = proj { ['a.lua'] = fn('va', '...', '  local n = select("#", ...)\n  return n + 1') }
    local v = require('cartograph.untangle').body_extractable(store, fn_id('va'))
    ok(not v.ok and v.vararg, 'a body using ... is flagged')
    vim.fn.delete(root, 'rf')
end)

test('clones: a self-recursive body is not extractable (helper name differs)', function ()
    local root = proj { ['a.lua'] =
        fn('fac', 'n', '  if n <= 1 then return 1 end\n  return n * fac(n - 1)') }
    local v = require('cartograph.untangle').body_extractable(store, fn_id('fac'))
    ok(not v.ok and v.recursive, 'a self-recursive body is flagged')
    vim.fn.delete(root, 'rf')
end)

-- ── in-buffer findings surface (M.findings — the interactive diagnostic list) ──

test('clones: findings place a value hole at its exact substitution column', function ()
    -- one/two are a value near-clone differing at foo⇄bar; the hole finding must sit
    -- at foo/bar's column so ]d / the quickfix jump straight to the rewrite site
    local body_a = '  local a = load(src)\n  local b = trim(a)\n  local c = foo(b)\n'
        .. '  local d = wrap(c)\n  persist(d)\n  return d'
    local body_b = '  local p = load(input)\n  local q = trim(p)\n  local r = bar(q)\n'
        .. '  local s = wrap(r)\n  persist(s)\n  return s'
    local root = proj {
        ['a.lua'] = fn('one', 'src', body_a),
        ['b.lua'] = fn('two', 'input', body_b),
    }
    local at = require 'cartograph.at'
    local hole
    for _, f in ipairs(clones.findings(store, { min_rows = 5 })) do
        if f.message:find('clone hole') then hole = f; break end
    end
    ok(hole, 'a value near-clone produces a hole finding')
    ok(hole and hole.col, 'the hole finding carries a column (the jump target)')
    -- the finding sits on the row that calls foo/bar, at foo/bar's column
    if hole then
        local abs = hole.file:sub(1, 1) == '/' and hole.file or store.abs(hole.file)
        local line = vim.fn.readfile(abs)[hole.line]
        local tok = line:sub(hole.col, hole.col + 2)
        ok(tok == 'foo' or tok == 'bar', 'the sign lands on the diverging token, got «' .. tok .. '»')
    end
    vim.fn.delete(root, 'rf')
end)

test('clones: findings mark an exact clone as a merge target', function ()
    local body = '  local a = load(x)\n  local b = trim(a)\n  local c = wrap(b)\n  return c'
    local root = proj {
        ['a.lua'] = fn('one', 'x', body),
        ['b.lua'] = fn('two', 'y', (body:gsub('%(x%)', '(y)'))),
    }
    local hit
    for _, f in ipairs(clones.findings(store, { min_rows = 3 })) do
        if f.message:find('exact clone') then hit = f; break end
    end
    ok(hit, 'an exact clone yields a finding')
    ok(hit and hit.message:find('CartographMerge'), 'it points at the merge action')
    vim.fn.delete(root, 'rf')
end)

test('clones: block groups tier by EXTRACTABILITY, not by length', function ()
    -- CART-0341. blocks_report tiered on `len >= 10` because length was the only signal
    -- the block tier had — and length is the wrong axis: this repo's own extraction
    -- commits are 5-25 duplicated lines per site, at or under any such floor. Measured
    -- on the whole repo, extractability removes 501 of 586 groups (86%) by itself: a
    -- block carrying a return, or nested in a loop, is not a candidate at ANY similarity.
    proj { ['a.lua'] = table.concat({
            'local M = {}',
            'function M.one(t)',
            '  local a = t.x',      -- a 3-statement run, extractable, narrow
            '  local b = a + 1',
            '  return b',
            'end',
            'function M.two(t)',
            '  local a = t.x',
            '  local b = a + 1',
            '  return b',
            'end',
            'return M',
    }, '\n') .. '\n' }
    local groups = clones.classify_blocks(store, clones.blocks(store, { min_len = 2 }))
    ok(#groups > 0, 'a block group was found')
    for _, g in ipairs(groups) do
        ok(g.extract ~= nil, 'every group is classified')
        ok(g.nfiles ~= nil, 'and carries its file spread')
        -- a group that cannot be extracted must SAY why rather than be silently ranked
        if not g.extract.ok then ok(g.extract.reason, 'a refusal names its reason') end
    end
    local L = clones.blocks_report(groups)
    ok(L[1]:find('span MORE THAN ONE FILE', 1, true), 'the header leads with spread: ' .. L[1])
    ok(not L[1]:find('solid', 1, true), 'and no longer with a length floor: ' .. L[1])
end)

-- CART-0371. THE FOLD QUEUE: join discovery to PLANNING and rank by what the fold COSTS.
-- The tiers rank by size, which answers "what is biggest"; under an intent to fold the
-- question is "what should I fold next", and only the plan knows.
test('foldrank: ranks by the plan\'s own arithmetic, and a refusal is a counted ROW', function ()
    local fr = require 'cartograph.foldrank'

    -- CART-0375: the scorer is txn.delta, derived from the (before, after) TEXT the apply
    -- would write — the ONE shape every verb shares. Score a real plan end to end.
    proj { ['m.lua'] =
        'local M = {}\n\nlocal function fmt_a(x)\n  local y = prep(x)\n  local z = norm(y)\n'
        .. '  local w = encode(z, \'json\')\n  local o = wrap(w)\n  return o\nend\n\n'
        .. 'local function fmt_b(a)\n  local b = prep(a)\n  local c = norm(b)\n'
        .. '  local d = encode(c, \'yaml\')\n  local e = wrap(d)\n  return e\nend\n\nreturn M\n' }
    local NEARQ = { max_dist = 2, min_rows = 4, min_shared = 3 }
    local rows, refused = fr.rank(store, NEARQ)
    ok(#rows > 0, 'the pair plans, so it is a scored row')
    local r = rows[1]
    eq(r.added - r.removed, r.net, 'net is the two halves, not an independent guess')
    -- ★ THE FENCE AGAINST THE OLD DEFECT is that the halves are NON-ZERO. Measured, this
    -- fold is exactly break-even (+7/-7): folding two five-row copies into a parameterized
    -- helper pays for itself and no more, which is a real answer and worth stating. The bug
    -- this replaces also produced net 0 — but with added = removed = 0, because it did not
    -- recognise the plan at all. A break-even fold and an unrecognised one are the same
    -- headline and opposite facts, so the halves are what must be asserted.
    ok(r.added > 0 and r.removed > 0,
        ('a scored fold MOVED lines (+%d/-%d) — a silent 0/0 is the unrecognised-shape bug')
            :format(r.added, r.removed))

    -- and the number is the TEXT's, so it must agree with the diff of what apply writes
    local cx = require 'cartograph.cloneextract'
    local pair = clones.near(store, NEARQ)[1]
    local plan = cx.plan(store, pair)
    local before, after = cx.preview(store, plan)
    local nb, na = 0, 0
    for _, rel in ipairs(plan.touched) do
        nb = nb + #vim.split(before[rel] == false and '' or before[rel], '\n', { plain = true })
        na = na + #vim.split(after[rel], '\n', { plain = true })
    end
    local added, removed, net = require('cartograph.txn').delta(store, plan)
    eq(na - nb, net, 'the predicted net IS the line-count difference of the written text')
    eq(added - removed, net)

    -- ★ AND A PLAN IT CANNOT SCORE REFUSES, rather than scoring 0. This is the defect that
    -- made the queue lie: a foreign plan shape read as a zero-cost fold, so 247 clonemerge
    -- plans would have printed "247 folds, net 0" — a work list that looks complete.
    local a2, why = require('cartograph.txn').delta(store, { verb = 'invented', touched = {} })
    eq(nil, a2, 'a plan with no edit_of is UNSCORABLE, not free')
    ok(tostring(why):find('plan protocol', 1, true), 'and it says why: ' .. tostring(why))

    -- the report states the TOTAL prediction, which is what makes a campaign checkable
    local L = fr.report({ { a = 'x', b = 'y', helper = 'h', net = -3, added = 13,
        removed = 16, nparams = 1, hazards = 0, file = 'f.lua' } },
        { ['not value-parameterizable'] = 7 },
        { { a = 'u', b = 'v', why = 'the edit callback RAISED' } })
    ok(L[1]:find('-3', 1, true), 'the headline carries the predicted net: ' .. L[1])
    local joined = table.concat(L, '\n')
    ok(joined:find('REFUSED', 1, true) and joined:find('7', 1, true),
        'and the refusals are COUNTED, not dropped — they are most of the work')
    ok(joined:find('UNSCORED', 1, true) and joined:find('RAISED', 1, true),
        'an unpriceable plan is its OWN category, in neither total')
    ok(refused ~= nil, 'rank still reports the refusal tally')
end)

-- CART-0375. THE PLAN PROTOCOL: every write verb's plan carries its own edit callback, so a
-- caller holding a plan can run it without knowing which module built it. That is the whole
-- prerequisite for a campaign driver, and the fence that keeps it true is this test.
test('plan protocol: every write verb stamps plan.edit_of', function ()
    local txn = require 'cartograph.txn'
    for _, mod in ipairs { 'cloneextract', 'clonemerge', 'extractapply', 'hoistclosure',
                           'moveapply', 'optapply', 'reorder', 'characterize' } do
        local m = require('cartograph.' .. mod)
        eq('function', type(m.edits_for),
            mod .. ' must expose edits_for under the protocol\'s ONE spelling')
        -- and it is a pure function of the plan: constructing it must not need a store
        local ok_, ef = pcall(m.edits_for, { touched = {} })
        ok(ok_ and type(ef) == 'function',
            mod .. '.edits_for must build from the plan alone (it is called at PLAN time now)')
    end
    -- the ladder refuses a plan that never joined, by name
    local _, why = txn.execute(store, { verb = 'nope', touched = {} }, 'x')
    ok(tostring(why):find('plan protocol', 1, true),
        'and the ladder refuses an unstamped plan rather than calling a nil: ' .. tostring(why))
end)


-- ★ AN EMBEDDED ASSIGNMENT CRASHED EVERY CLONE TIER, and no lua corpus could
-- ever have caught it: LUA HAS NO ASSIGNMENT EXPRESSION. `t` is the tree-sitter
-- type STRING on every expression kind except `assign`, where the schema uses it
-- for the assignment TARGET — a node — so the canonicalizers' fallthrough did
-- `'?' .. e.t` and raised "attempt to concatenate a table value" on the first
-- `while( $row = fetch() )` it met. Measured present in php, c and javascript.
-- Three tiers, three copies of the same fallthrough, so this asserts all three.
test('clones: an embedded assignment keys instead of crashing (php/c/js)', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'php') then skip 'no php parser' end
    local clones = require 'cartograph.clones'
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/a.php', 'w'))
    fd:write('<?php\nfunction fetch_all( $r ) {\n  $out = array();\n'
        .. '  while( $row = db_fetch( $r ) ) { $out[] = $row; }\n  return $out;\n}\n'
        -- a second body with the SAME shape: the tiers must also still WORK,
        -- not merely survive — a fix that keyed everything to '?' would pass a
        -- crash test and report every function as a clone of every other
        .. 'function load_all( $q ) {\n  $acc = array();\n'
        .. '  while( $rec = db_fetch( $q ) ) { $acc[] = $rec; }\n  return $acc;\n}\n'
        .. 'function unrelated( $x ) {\n  $y = $x + 1;\n  $z = $y * 2;\n'
        .. '  return $z - 3;\n}\n')
    fd:close()
    local data = ts.extract(root); store.ingest(data)
    for _, tier in ipairs({ 'exact', 'blocks', 'near' }) do
        local ok_, err = pcall(clones[tier], store, {})
        ok(ok_, tier .. ' does not crash: ' .. tostring(err))
    end
    ok(pcall(clones.findings, store, {}), 'and neither does the findings surface')
    -- the two while-loop bodies are alpha-equivalent, the third is not
    local groups = clones.exact(store, { min_rows = 3 })
    local found
    for _, g in ipairs(groups) do
        if #g >= 2 then
            local names = {}
            for _, m in ipairs(g) do names[m.name] = true end
            if names.fetch_all and names.load_all then found = g end
        end
    end
    ok(found, 'the two same-shaped bodies group as clones')
    eq(2, found and #found, 'and the unrelated one is NOT in the group')
    vim.fn.delete(root, 'rf')
end)

-- CART-0732. The divergence census answers "which hole kind should we add
-- next?" with evidence instead of a guess: it classifies every divergence the
-- two named kinds (value hole / struct hole) cannot take.
--
-- THE GUARD IS THAT IT STAYS SILENT ON WHAT IS ALREADY NAMED. A pair whose only
-- divergence is a clean VALUE hole must contribute nothing — if it did, the
-- census would be re-reporting the case the anti-unifier already handles, and
-- every feature count would be inflated by the population the template language
-- covers today. That is the same trap as java-marker-annotation's @Deprecated
-- row: a classifier that fires on everything has stopped discriminating.
test('clones: the divergence census names the residue and stays silent on value holes', function ()
    -- two functions differing ONLY in a literal: a clean value hole, six rows so
    -- the pair clears min_rows, and nothing structural anywhere.
    proj({ ['v.lua'] = [[
local function alpha(t)
  local a = t.one
  local b = t.two
  local c = a + b
  local d = c * 2
  local e = d - 1
  return e
end
local function beta(t)
  local a = t.one
  local b = t.two
  local c = a + b
  local d = c * 3
  local e = d - 1
  return e
end
return { alpha, beta }
]] })
    local clean = clones.divergence_census(store, { max_dist = 32, below = 0, min_rows = 2 })
    eq(0, clean.divergences,
        'a pure VALUE-hole pair contributes NO unnamed divergence — the census must not '
        .. 're-report what anti_unify already parameterizes')

    -- now a pair whose divergence is a CALL facing an inlined expression: the
    -- extract/inline relation, which no named hole kind covers.
    proj({ ['w.lua'] = [[
local function helper(x, y) return x and y end
local function gamma(t)
  local a = t.one
  local b = t.two
  local c = helper(a, b)
  local d = c
  local e = d
  return e
end
local function delta(t)
  local a = t.one
  local b = t.two
  local c = a and b and a
  local d = c
  local e = d
  return e
end
return { gamma, delta, helper }
]] })
    -- min_rows below near's reporting default keeps the fixture small; the
    -- pair matches 5 rows and diverges in exactly one place.
    local res = clones.divergence_census(store, { max_dist = 32, below = 0, min_rows = 2 })
    ok(res.divergences > 0, 'an inlined-vs-called divergence IS reported as unnamed')
    local named = false
    for k in pairs(res.features) do
        if k == 'call-vs-expr' or k == 'containment' or k == 'leaf-vs-tree' then named = true end
    end
    ok(named, 'and it carries a FEATURE that names the shape, not just a count')
    -- rows, not strings: the caller formats (CART-0698 / interactive reports)
    eq('table', type(res.features), 'the census returns ROWS, not rendered text')
    eq('table', type(res.kindpairs), 'kind pairs come back as data too')
end)

-- CART-0742 item 4. THE OPTIONAL-ARGUMENT HOLE. CART-0729/0730 concluded the
-- template language was missing REPETITION and RECURSION holes; this is a third
-- thing neither named — the callee agrees and only the argument LIST length
-- differs, which is add-parameter/remove-parameter seen from outside.
--
-- ★★ THE TWO TAGS ARE THE WHOLE POINT, AND THE WITNESSES DECIDED WHICH IS THE
-- RELATION. `arity` alone says "same callee, different count", and on real
-- corpora most of that is an OVERLOAD:
--     arena.allocate(n * Integer.BYTES) ⇄ arena.allocate(ADDRESS.byteSize()*k, …)
-- — one more argument and nothing in common. `arity(appended)` additionally
-- requires the shorter list to be an alpha-canon PREFIX of the longer, which is
-- the actual optional argument:
--     assertScoresEquals(a, b) ⇄ assertScoresEquals(a, b, delta)
-- Only the strong form is in DC_RELATION. Measured: the strong form is 36% of
-- the class on java, 4% on C++, 0% on php — so promoting bare `arity` would
-- have inflated `explained` with pairs no refactoring relates, which is exactly
-- the `call-vs-expr` error CART-0742 item 2 had just finished correcting.
test('clones: an optional argument is `arity(appended)`; an overload is only `arity`', function ()
    -- THE STRONG FORM: same callee, and the two-argument call's arguments are a
    -- prefix of the three-argument call's.
    proj({ ['ap.lua'] = [[
local function sink(p, q, r) return p end
local function alpha(t)
  local a = t.one
  local b = t.two
  local c = sink(a, b)
  local d = c
  local e = d
  return e
end
local function beta(t)
  local a = t.one
  local b = t.two
  local c = sink(a, b, t.three)
  local d = c
  local e = d
  return e
end
return { alpha, beta, sink }
]] })
    local strong = clones.divergence_census(store, { max_dist = 32, below = 0, min_rows = 2 })
    ok((strong.features['arity'] or 0) > 0, 'same callee + different arg count is `arity`')
    ok((strong.features['arity(appended)'] or 0) > 0,
        '...and an APPENDED argument earns the strong tag too')

    -- THE WEAK FORM: same callee, one more argument, and the arguments SHARE
    -- NOTHING. This is an overload, not a refactoring, and it must NOT be
    -- promoted — the tag is the honest weaker statement.
    --
    -- ⚠ THE ARGUMENTS HERE ARE `t.one` / `t.two` AND NOT TWO LOCALS, AND THAT IS
    -- LOAD-BEARING. rcanon ALPHA-RENAMES a local to `L`, so `sink(a)` against
    -- `sink(b, x)` is an APPENDED prefix — `L` really does equal `L` — and the
    -- first version of this fixture asserted otherwise and failed, correctly.
    -- Two distinct field selectors are the cheapest arguments rcanon can tell
    -- apart. The same caveat qualifies the strong tag on real corpora: a prefix
    -- of bare locals is a weak match and a prefix holding names, literals or
    -- calls is a strong one, and the tag does not distinguish them.
    --
    -- ⚠ AND THE SECOND ARGUMENT IS A LITERAL, NOT A THIRD FIELD, FOR A SEPARATE
    -- REASON. `sink(t.two, t.three)` reports NOTHING: its argument list is
    -- HOMOGENEOUS, so `walk` calls it a repetition hole and never reaches
    -- `record` at all. That is the taxonomy working — the census only names what
    -- the existing holes cannot — and it took a second failing fixture to see
    -- it, which is worth more than the assertion it was written for.
    proj({ ['ov.lua'] = [[
local function sink(p, q, r) return p end
local function gamma(t)
  local a = t.one
  local b = t.two
  local c = sink(t.one)
  local d = c
  local e = d
  return e
end
local function delta(t)
  local a = t.one
  local b = t.two
  local c = sink(t.two, 42)
  local d = c
  local e = d
  return e
end
return { gamma, delta, sink }
]] })
    local weak = clones.divergence_census(store, { max_dist = 32, below = 0, min_rows = 2 })
    ok((weak.features['arity'] or 0) > 0, 'an overload is still `arity` — the count really does differ')
    eq(nil, weak.features['arity(appended)'],
        '...but NOT `arity(appended)`: nothing was appended, the arguments disagree at position 1')

    -- ★ THE DISCRIMINATION ARM. A different callee with a different arity is
    -- NOT an arity finding — without this the predicate fires on every pair of
    -- unrelated calls and has stopped discriminating, which is the trap the
    -- value-hole test above exists to guard.
    proj({ ['dc.lua'] = [[
local function sink(p, q, r) return p end
local function other(p, q, r) return q end
local function eps(t)
  local a = t.one
  local b = t.two
  local c = sink(a)
  local d = c
  local e = d
  return e
end
local function zeta(t)
  local a = t.one
  local b = t.two
  local c = other(a, b)
  local d = c
  local e = d
  return e
end
return { eps, zeta, sink, other }
]] })
    local diff = clones.divergence_census(store, { max_dist = 32, below = 0, min_rows = 2 })
    eq(nil, diff.features['arity'],
        'a DIFFERENT callee with a different arity is not an arity finding')
end)

-- CART-0766. THE ELEMENT TEMPLATE — what a container's members have in common
-- and where they differ. The first half of the insert verb's disambiguation, and
-- useful before any write verb exists: "what shape are this table's members" is
-- the question instrumentcensus had to answer by hand.
--
-- ★★ THERE IS NO NEW REPRESENTATION. A template IS (a DONOR member, the holes
-- across all members) — `anti_unify` already records every divergence WITH ITS
-- SOURCE SPAN, so the donor's text plus the hole spans is a complete
-- substitution recipe and rendering never emits source from the IR.
local expr = require 'cartograph.expr'
local function ready() return pcall(vim.treesitter.language.add, 'lua') end

local function container_of(src)
    local root = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    local function find(n)
        if n:type() == 'table_constructor' then return n end
        for c in n:iter_children() do
            if c:named() then local r = find(c); if r then return r end end
        end
    end
    return expr.build(find(root), src, 'lua')
end

test('clones: an element template is a donor plus located holes', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(container_of("local T = { 'x', 'y', 'z' }"))
    eq(3, t.n)
    eq(true, t.alignable, 'three string literals share a shape')
    ok(#t.holes >= 2, 'and differ at the value')
    ok(t.donor, 'a donor member is handed back — it is the render source')
    -- ★ THE SPAN IS THE WHOLE POINT: substituting at the donor's hole span is
    -- what lets an insert render without emitting source from the IR.
    ok(t.holes[1].at_a, 'the hole carries its source span')
end)

-- ⚠ `alignable = false` IS AN ANSWER, not a failure. Measured at 6-31% of
-- containers depending on language, so a caller must be told the members share
-- no shape rather than handed a template built from one arbitrary member.
test('clones: a heterogeneous container reports alignable=false, not a guess', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(container_of("local T = { a = 1, b = { x = 2 } }"))
    eq(false, t.alignable, 'a literal and a nested table share no shape')
    ok(t.donor, 'the donor is still returned, so a caller can SEE what it compared')
end)

-- ★ ONE MEMBER IS A SHAPE, NOT A TEMPLATE. `holes` is empty either way, so the
-- two cases would render alike unless the answer says which it is.
test('clones: a single-member container says it is not yet a template', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(container_of("local T = { only = true }"))
    eq(1, t.n)
    eq(true, t.alignable)
    eq(0, #t.holes)
    ok(t.why and t.why:find('not yet a template'), 'and says so: ' .. tostring(t.why))
end)

-- ★★ THE KEYED CASE IS THE ONE THE INSERT VERB ACTUALLY NEEDS — SOLE_WRAP, LIT,
-- RADIX_BY_NODE and every spec slot are keyed tables. Its holes had NO SPAN
-- until CART-0754: an unbracketed key was the one node built without going
-- through `build`, the wrapper that stamps `.at`. A ticket filed P3 that morning
-- turned out to be on this feature's critical path.
test('clones: a KEYED container yields holes with spans (the CART-0754 dependency)', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(
        container_of("local T = { argument = true, condition_clause = true }"))
    eq(true, t.alignable, 'two `name = true` pairs share a shape')
    ok(#t.holes >= 1, 'and differ at the KEY')
    ok(t.holes[1].at_a, 'the key hole carries a source span — without it no insert can render')
    eq('argument', t.holes[1].a, 'and names the donor side')
end)

-- ── match: the dual of anti-unification (CART-0766 step B) ───────────────────
-- `anti_unify` GENERALISES two instances into a skeleton plus holes; `match`
-- SPECIALISES — does this payload fit the skeleton, and what does each hole bind
-- to. Same traversal, opposite direction, reusing it rather than copying it.
--
-- ★★ THE DISCRIMINATING RULE, and everything below is a test of it: a divergence
-- at a position the members ALREADY VARY AT is a BINDING; the same divergence
-- anywhere else is a MISMATCH. Without that split every divergence binds, the
-- template matches everything, and a template that matches everything
-- disambiguates nothing.

-- one member of a container, which is what a caller proposes to insert
local function member_of(src, i)
    local c = container_of(src)
    return c.kids[i or 1]
end

test('clones: a payload that varies WHERE THE MEMBERS VARY matches, and binds', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(
        container_of("local T = { argument = true, condition_clause = true }"))
    local m = clones.match(t, member_of("local P = { subscript_list = true }"))
    eq(true, m.ok, 'the key is exactly where these members disagree')
    eq(0, m.distance)
    ok(#m.bindings >= 1, 'and the divergence comes back as a BINDING, not a failure')
    eq('argument', m.bindings[1].from, 'from the donor…')
    eq('subscript_list', m.bindings[1].to, '…to the payload')
    ok(m.bindings[1].at, 'with the donor span — the site a render substitutes at')
    eq(true, m.bindings[1].site, 'and that span IS writable (not an enclosing one)')
end)

-- ★★ THE CASE THAT WOULD PASS UNDER A LOOSE MATCH AND MUST NOT. Both members
-- spell the key `name`, so a payload spelling it `nome` diverges at a position
-- where every member AGREES. Structurally it is the same kind of hole as the one
-- above — a `lit` — and only the varying-set tells them apart.
test('clones: a payload differing where the members AGREE is refused', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(
        container_of("local T = { { name = 'a', v = 1 }, { name = 'b', v = 2 } }"))
    eq(true, t.alignable)
    local m = clones.match(t, member_of("local P = { { nome = 'c', v = 3 } }"))
    eq(false, m.ok, 'a misspelled key is not an instantiation')
    ok(#m.refusal.mismatches >= 1, 'and it is reported as a MISMATCH, located')
    local mm
    for _, x in ipairs(m.refusal.mismatches) do if x.expected == 'name' then mm = x end end
    ok(mm, 'naming the agreed value the payload failed to supply')
    eq('nome', mm.got, 'and what came instead')
    ok(mm.at, 'at the donor span')
end)

test('clones: a bare payload against structured members refuses with leaf-vs-tree', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(
        container_of("local T = { { name = 'a', v = 1 }, { name = 'b', v = 2 } }"))
    local m = clones.match(t, member_of("local P = { 'c' }"))
    eq(false, m.ok)
    local names = {}
    for _, r in ipairs(m.refusal.features.rows) do names[r.feature] = true end
    ok(names['leaf-vs-tree'], 'the census vocabulary names it — the one feature every corpus supports')
end)

-- ★ THIS POPULATION'S OWN ANALOGUE OF `arity`. The census's `arity` is defined on
-- two CALLS and measured 0.0% on four corpora of five; two nested TABLES with
-- different member counts measured 1.8%. A redefinition, not a transfer.
test('clones: a payload with a different member count reports table-arity', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(
        container_of("local T = { { a = 1, b = 2 }, { a = 3, b = 4 } }"))
    local m = clones.match(t, member_of("local P = { { a = 5, b = 6, c = 7 } }"))
    eq(false, m.ok)
    local names = {}
    for _, r in ipairs(m.refusal.features.rows) do names[r.feature] = true end
    ok(names['table-arity'], 'three fields where members have two')
    -- ★ AND THE PREMISE IS A LOOKUP, NOT A SYNTHESIS: the surplus key is a set
    -- difference over literal keys, so it is exact or it is absent.
    ok(m.refusal.premise, 'the refusal carries what would close the gap')
    eq('c', m.refusal.premise.surplus[1], 'the key the members do not have')
end)

test('clones: a NAME where the members hold literals classifies, it does not bind', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(container_of("local T = { 'x', 'y' }"))
    local m = clones.match(t, member_of("local P = { z }"))
    eq(false, m.ok, 'a name is not a literal, however much the position varies')
    local names = {}
    for _, r in ipairs(m.refusal.features.rows) do names[r.feature] = true end
    ok(names['drift(lit/name)'], 'and CART-0349s class names it')
end)

-- ⚠⚠ THE ORDER IS PER-LANGUAGE AND THE FEATURE SET IS SHARED. `containment` was
-- ranked LAST from our own lua tree at 0.6% and is 29.1% on java; `size-skew` is
-- 31% on php against ~10% on lua. One corpus's ranking is a property of that
-- corpus, so the SAME refusal must come back ordered differently.
test('clones: the refusal vocabulary is ranked by the TARGET language', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(
        container_of("local T = { { name = 'a', v = 1 }, { name = 'b', v = 2 } }"))
    local payload = "local P = { 'c' }"
    local as_lua = clones.match(t, member_of(payload), { lang = 'lua' })
    local as_php = clones.match(t, member_of(payload), { lang = 'php' })
    eq('leaf-vs-tree', as_lua.refusal.features.rows[1].feature, 'lua leads with leaf-vs-tree')
    eq('size-skew', as_php.refusal.features.rows[1].feature, 'php leads with size-skew')
    -- ⚠ AND NEITHER IS EXHAUSTIVE: five corpora, four languages.
    eq('ranked-open', as_lua.refusal.features.complete)
end)

test('clones: an unmeasured language is told the order came from a default', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(
        container_of("local T = { { name = 'a', v = 1 }, { name = 'b', v = 2 } }"))
    local m = clones.match(t, member_of("local P = { 'c' }"), { lang = 'ruby' })
    ok(m.refusal.features.scope:find('unmeasured'),
        'and says so rather than passing a default off as a measurement: '
        .. m.refusal.features.scope)
end)

-- ⚠ 54.9% of the container LITERALS in our own lua tree (459 of 836 with n>=2) are
-- non-alignable. "What shape should a new member take" HAS NO ANSWER there, and
-- matching against an arbitrary first member would answer a question nobody
-- asked.
test('clones: match refuses a non-alignable template up front', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(container_of("local T = { a = 1, b = { x = 2 } }"))
    local m = clones.match(t, member_of("local P = { c = 3 }"))
    eq(false, m.ok)
    ok(m.refusal.why:find('do not share a shape'), m.refusal.why)
end)

-- ★ n == 1 MATCHES ONLY ON ZERO HOLES, because `varying` is empty and everything
-- that differs is therefore a mismatch. That is the right strictness; the caller
-- still has to be able to tell it from a shape five members confirmed.
test('clones: a single-member template matches only an identical payload, and says it is weak', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(container_of("local T = { only = true }"))
    local same = clones.match(t, member_of("local P = { only = true }"))
    eq(true, same.ok)
    eq('template from a single member', same.weak, 'weak evidence, not a confirmed shape')
    local other = clones.match(t, member_of("local P = { other = true }"))
    eq(false, other.ok, 'with no varying position, any divergence is a mismatch')
end)

-- ★★ AN OPERATOR HOLE IS THE ONE KIND WHOSE SPAN IS NOT A WRITE SITE, and giving
-- it a span at all is a change with SIBLING SURFACES. It carried none until
-- CART-0766 step B — the IR gives `un`/`bin` a range and the operator no node of
-- its own — which made it the only value hole `match` could not key. Located, it
-- also newly satisfies two `at_a`-predicated readers (`near_report`'s location
-- line and `M.findings`' hint row), so a previously SILENT divergence becomes a
-- located one. That is an improvement and it is deliberate; this test is what
-- keeps it from being silent. Measured at the time: zero value-kind near pairs on
-- desynced/grocy/jquery, so no shipped report output moved — but "nothing has hit
-- it" is a statement about today.
test('clones: an operator hole is LOCATED but marked not-a-write-site', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(container_of("local T = { a + b, a - b }"))
    eq(true, t.alignable, 'two binary expressions over the same operands align')
    local op
    for _, h in ipairs(t.holes) do if h.kind == 'operator' then op = h end end
    ok(op, 'the operator divergence is a hole')
    eq('+', op.a); eq('-', op.b)
    ok(op.at_a, 'and it is LOCATED — it was not, and could not be keyed')
    eq(true, op.at_encloses,
        'but the span is the ENCLOSING expression, so a render must not write there')
end)

test('clones: an operator BINDS where the members vary, with site = false', function ()
    if not ready() then return skip 'no lua parser' end
    local t = clones.element_template(container_of("local T = { a + b, a - b }"))
    local m = clones.match(t, member_of("local P = { a * b }"))
    eq(true, m.ok, 'a third operator over the same operands instantiates the template')
    local b
    for _, x in ipairs(m.bindings) do if x.hole == 'operator' then b = x end end
    ok(b, 'and comes back as a binding')
    eq('*', b.to)
    eq(false, b.site,
        'flagged NOT a substitution site — step C must refuse rather than overwrite '
        .. 'the operands along with the operator')
end)

-- ── render: substitute into the DONOR'S TEXT (CART-0766 step C) ──────────────
-- The IR is LOSSY ABOUT SURFACE, so instantiating a template by EMITTING from it
-- is the transliteration problem — quote style, indentation, trailing comma, all
-- guessed. Substituting into a real member's own source guesses none of them: the
-- donor IS the surrounding style rather than an imitation of it.

-- reparse a rendered member by wrapping it back into a container
local function reparse_member(text)
    local src = 'local T = { ' .. text .. ' }'
    local okp, p = pcall(vim.treesitter.get_string_parser, src, 'lua')
    if not okp or not p then return nil end
    local c = container_of(src)
    return c and c.kids and c.kids[1]
end
local VERIFY = { verify = reparse_member }

test('clones: a rendered member round-trips through a reparse', function ()
    if not ready() then return skip 'no lua parser' end
    local src = "local T = { alpha = 'AA', beta = 'BB' }"
    local t = clones.element_template(container_of(src))
    local p = container_of("local P = { gamma = 'CC' }").kids[1]
    local m = clones.match(t, p, { lang = 'lua' })
    eq(true, m.ok)
    local subs = assert(clones.subs_of(t, m, "local P = { gamma = 'CC' }", src))
    local out, why, detail = clones.render(t, subs, src, VERIFY)
    ok(out, 'rendered: ' .. tostring(why))
    eq("gamma = 'CC'", out)
    eq(true, detail.verified)
end)

-- ★★ THE REPLACEMENT IS SLICED FROM SOURCE, NOT TAKEN FROM THE BINDING — and the
-- witness is NUMERIC, which is not where this was first looked for. A string
-- literal's `v` DOES carry its quotes, so a string fixture passes either way and
-- proves nothing (the break that should have failed did not, which is what sent
-- me to read the builder rather than trust the claim). A NUMBER is normalised:
-- `0x1F` is stored as `31`. Splicing the value would render `31` where the source
-- wrote `0x1F` — a real corruption of intent for a flag or a mask, and across
-- languages worse than cosmetic: go's `0755` is octal 493, rust's is decimal 755.
test('clones: a hex literal renders as WRITTEN, not as its normalised value', function ()
    if not ready() then return skip 'no lua parser' end
    local src = "local T = { a = 1, b = 2 }"
    local psrc = 'local P = { c = 0x1F }'
    local t = clones.element_template(container_of(src))
    local m = clones.match(t, container_of(psrc).kids[1], { lang = 'lua' })
    eq(true, m.ok)
    local subs = assert(clones.subs_of(t, m, psrc, src))
    eq('c = 0x1F', clones.render(t, subs, src, VERIFY),
        'the IR stores 31; only the payload SOURCE knows it was written 0x1F')
end)

-- and the string case still holds, for the style the quotes carry
test('clones: a string-valued hole keeps the payload\'s own quote style', function ()
    if not ready() then return skip 'no lua parser' end
    local src = "local T = { a = 'AA', b = 'BB' }"
    local psrc = 'local P = { c = "CC" }'
    local t = clones.element_template(container_of(src))
    local m = clones.match(t, container_of(psrc).kids[1], { lang = 'lua' })
    eq(true, m.ok)
    local subs = assert(clones.subs_of(t, m, psrc, src))
    eq('c = "CC"', clones.render(t, subs, src, VERIFY))
end)

-- ★★★ THE BRACKET BUG — the reason verification is not optional polish. Our own
-- tree is full of `{ start = {...}, ['end'] = {...} }`, because `end` is a lua
-- keyword. The IR records BOTH as a `lit` str key, so they anti-unify as one
-- shape with one hole and `match` says ok — and the render then produces
-- `'end' = {...}`, which is not valid Lua at all: the brackets belong to neither
-- span. 63 of 1184 renders on our own tree were this, every one of them
-- well-formed as a STRING. Special-casing lua keys would leave the same class
-- open in every other language; reparsing closes all of it.
test('clones: a render that reparses to a DIFFERENT shape is refused', function ()
    if not ready() then return skip 'no lua parser' end
    local src = "local T = { start = { line = 0 }, ['end'] = { line = 9 } }"
    local c = container_of(src)
    local t = clones.element_template(c)
    eq(true, t.alignable, 'the IR erases bracketedness, so these DO share a shape')
    local m = clones.match(t, c.kids[2], { lang = 'lua' })
    eq(true, m.ok, 'and the match succeeds — nothing before the reparse can tell')
    local subs = assert(clones.subs_of(t, m, src, src))
    local raw = clones.render(t, subs, src, { unverified = true })
    eq("'end' = { line = 9 }", raw, 'the unverified render IS the broken text')
    local out, why = clones.render(t, subs, src, VERIFY)
    eq(nil, out, 'and verification refuses it')
    ok(why:find('reparse') or why:find('DIFFERENT shape'), why)
end)

test('clones: render refuses without a verifier, rather than trusting the caller', function ()
    if not ready() then return skip 'no lua parser' end
    local src = "local T = { a = 1, b = 2 }"
    local t = clones.element_template(container_of(src))
    local out, why = clones.render(t, {}, src)
    eq(nil, out)
    ok(why:find('verify'), why)
end)

-- ★★ A "MAP OF WHAT DIFFERS" IS NOT A "MAP OF WHAT TO WRITE". A match's BINDINGS
-- are where THIS payload differs from the donor; a template's VARYING set is
-- where ANY member does. Where a payload happens to AGREE with the donor the hole
-- still has to be filled — with the donor's own text. Getting this wrong refused
-- 37 of 1184 otherwise-valid instantiations, and the refusal read as a caller bug.
test('clones: subs_of is TOTAL over the varying set, not just over the bindings', function ()
    if not ready() then return skip 'no lua parser' end
    -- three members: the KEY varies across all of them, the VALUE only at `c`
    local src = "local T = { a = 1, b = 1, c = 9 }"
    local psrc = "local P = { d = 1 }"
    local t = clones.element_template(container_of(src))
    local m = clones.match(t, container_of(psrc).kids[1], { lang = 'lua' })
    eq(true, m.ok)
    local subs = assert(clones.subs_of(t, m, psrc, src))
    local n = 0
    for _ in pairs(subs) do n = n + 1 end
    local v = 0
    for _ in pairs(t.varying) do v = v + 1 end
    eq(v, n, 'every varying position is filled, including the one the payload agrees at')
    eq('d = 1', clones.render(t, subs, src, VERIFY))
end)

test('clones: render refuses an unfilled hole rather than keeping the donor value', function ()
    if not ready() then return skip 'no lua parser' end
    -- a KEYED container: the varying position IS the key, so carrying the donor's
    -- value through would emit a DUPLICATE KEY the caller never asked for
    local src = "local T = { a = 1, b = 2 }"
    local t = clones.element_template(container_of(src))
    local out, why, detail = clones.render(t, {}, src, VERIFY)
    eq(nil, out)
    ok(why:find('unfilled'), why)
    ok(detail.unfilled and #detail.unfilled > 0, 'and names them')
end)

test('clones: subs_of refuses an operator binding by name', function ()
    if not ready() then return skip 'no lua parser' end
    local src = "local T = { a + b, a - b }"
    local psrc = "local P = { a * b }"
    local t = clones.element_template(container_of(src))
    local m = clones.match(t, container_of(psrc).kids[1], { lang = 'lua' })
    eq(true, m.ok)
    local subs, why = clones.subs_of(t, m, psrc, src)
    eq(nil, subs)
    ok(why:find('operator'), why)
end)

-- ★ TWO HOLES ON ONE LINE, WITH DIFFERENT LENGTHS. Applied left to right the
-- first splice shifts the second's columns and corrupts it, which is why the
-- reps sort rightmost-first — the same rule and the same reason `txn.edit_file`
-- carries. Equal-length substitutions would pass either way and hide it.
test('clones: two holes on one line render rightmost-first', function ()
    if not ready() then return skip 'no lua parser' end
    local src = "local T = { a = 1, bb = 22 }"
    local psrc = "local P = { ccc = 333 }"
    local t = clones.element_template(container_of(src))
    local m = clones.match(t, container_of(psrc).kids[1], { lang = 'lua' })
    eq(true, m.ok)
    local subs = assert(clones.subs_of(t, m, psrc, src))
    eq('ccc = 333', clones.render(t, subs, src, VERIFY))
end)
