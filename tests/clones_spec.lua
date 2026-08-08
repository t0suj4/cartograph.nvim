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
