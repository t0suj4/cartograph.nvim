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

-- CART-0881 rung 2. "structural (needs a human)" covered TWO answers with different
-- owners: a pair whose only difference is inserted/deleted ROWS (a repetition hole and
-- nothing else) and a pair where one side WRAPS what the other has bare (a context
-- hole, typically shared across sites). Measured by the prototype algebra on
-- cartograph's own 59 near pairs: all 31 structural pairs HAVE a template; the split
-- was 11 rows-only against 20 carrying a wrapper. The signal was already computed in
-- `analyze_pair` and dropped on the floor -- struct holes never reached a caller.
test('clones: an inserted row and a wrapped expression are DIFFERENT structural shapes', function ()
    local base = '  local a = load(src)\n  local b = trim(a)\n  local c = wrap(b)\n'
    -- ROWS ONLY: identical but for one extra statement on side A
    local rows_a = base .. '  audit(c)\n  persist(c)\n  return c'
    local rows_b = base .. '  persist(c)\n  return c'
    -- A WRAPPER: same row count, but one side reads `c.line` where the other CALLS
    -- `line(c)` -- the accessor migration shape, a context hole around the same base
    local wrap_a = base .. '  local d = c.line\n  persist(d)\n  return d'
    local wrap_b = base .. '  local d = line(c)\n  persist(d)\n  return d'
    local root = proj {
        ['r1.lua'] = fn('rows_one', 'src', rows_a),
        ['r2.lua'] = fn('rows_two', 'src', rows_b),
        ['w1.lua'] = fn('wrap_one', 'src', wrap_a),
        ['w2.lua'] = fn('wrap_two', 'src', wrap_b),
    }
    local ps = clones.near(store, { max_dist = 3, min_rows = 4, min_shared = 2 })
    local rp = near_pair(ps, 'rows_one', 'rows_two')
    local wp = near_pair(ps, 'wrap_one', 'wrap_two')
    ok(rp and wp, 'both pairs are near-clones')
    local ra = rp and clones.analyze_pair(rp)
    local wa = wp and clones.analyze_pair(wp)
    ok(ra and ra.kind == 'structural' and ra.shape == 'rows',
        'an inserted row is shape=rows (got ' .. tostring(ra and ra.shape) .. ')')
    ok(wa and wa.kind == 'structural' and wa.shape ~= 'rows',
        'a wrapped expression is NOT shape=rows (got ' .. tostring(wa and wa.shape) .. ')')
    -- and the point of the split: the two do not render the same
    ok(ra and wa and ra.shape ~= wa.shape, 'the two structural shapes are distinguished')
    vim.fn.delete(root, 'rf')
end)

-- CART-0876. A hole reading locals is a FUNCTION of them, and that dependency list IS
-- the helper's argument list. `extract_proposal` used to answer every structural pair
-- with "extract by hand", discarding a signature it could derive: the struct holes
-- carry both diverging subterms, and the locals each reads are the arguments.
-- Measured on cartograph's own tree, 14 of 31 structural pairs carry such a hole —
-- the prototype's independent binder pass put it at fifteen once the row-misalignment
-- artefact (CART-0875) was discounted.
test('clones: a divergence reading a local is reported as a FUNCTION of the local', function ()
    -- the accessor-migration shape: one side reads `c.line`, the other CALLS `line(c)`.
    -- Different node kinds, so a struct hole — and both sides read the local `c`.
    local base = '  local a = load(src)\n  local c = trim(a)\n'
    local body_a = base .. '  local d = c.line\n  persist(d)\n  return d'
    local body_b = base .. '  local d = line(c)\n  persist(d)\n  return d'
    local root = proj {
        ['x1.lua'] = fn('acc_one', 'src', body_a),
        ['x2.lua'] = fn('acc_two', 'src', body_b),
    }
    local p = near_pair(clones.near(store, { max_dist = 3, min_rows = 4, min_shared = 2 }),
        'acc_one', 'acc_two')
    ok(p, 'acc_one and acc_two are a near-clone')
    local an = p and clones.analyze_pair(p)
    ok(an and #(an.structs or {}) > 0, 'the divergence is a struct hole')
    local dep
    for _, h in ipairs(an and an.structs or {}) do
        for _, d in ipairs(h.deps_a or {}) do if d == 'c' then dep = d end end
        for _, d in ipairs(h.deps_b or {}) do if d == 'c' then dep = d end end
    end
    ok(dep == 'c', 'the hole reports the local `c` as its dependency (got '
        .. tostring(dep) .. ')')
    -- and the proposal says so instead of only refusing
    local txt = table.concat(clones.extract_proposal(p, store), '\n')
    ok(txt:find('FUNCTION of (c)', 1, true), 'the proposal names it a FUNCTION of (c)')
    vim.fn.delete(root, 'rf')
end)

-- CART-0881. The wrapper verdict NAMES ITS EVIDENCE, because the two signals that
-- produce it are not the same claim. Measured over 319 structural pairs on two
-- corpora against the algebra's own context variable: a SELECTOR hole (field or
-- operator) had ZERO false positives, while a STRUCT hole alone carried ALL 21
-- over-reports. Rendering them identically is the fault `shape` was introduced to
-- fix, one level down.
test('clones: a wrapper verdict says whether a SELECTOR or only a SHAPE divergence found it', function ()
    local base = '  local a = load(src)\n  local b = trim(a)\n  local c = wrap(b)\n'
    -- SELECTOR: same base `c`, different field off it — X(base) with field:a(◦) / field:b(◦)
    local sel_a = base .. '  local d = c.alpha\n  audit(d)\n  persist(d)\n  return d'
    local sel_b = base .. '  local d = c.beta\n  persist(d)\n  return d'
    -- SHAPE ONLY: an arity difference, which is a hedge inside the list and encloses
    -- nothing — the exact shape of the measured over-reports (rec(n) vs rec(n, true))
    local shp_a = base .. '  local d = pick(c)\n  audit(d)\n  persist(d)\n  return d'
    local shp_b = base .. '  local d = pick(c, true)\n  persist(d)\n  return d'
    local root = proj {
        ['s1.lua'] = fn('sel_one', 'src', sel_a),
        ['s2.lua'] = fn('sel_two', 'src', sel_b),
        ['p1.lua'] = fn('shp_one', 'src', shp_a),
        ['p2.lua'] = fn('shp_two', 'src', shp_b),
    }
    local ps = clones.near(store, { max_dist = 3, min_rows = 4, min_shared = 2 })
    local sp = near_pair(ps, 'sel_one', 'sel_two')
    local pp = near_pair(ps, 'shp_one', 'shp_two')
    ok(sp and pp, 'both pairs are near-clones')
    local sa = sp and clones.analyze_pair(sp)
    local pa = pp and clones.analyze_pair(pp)
    ok(sa and sa.evidence == 'selector',
        'a field hole is SELECTOR evidence (got ' .. tostring(sa and sa.evidence) .. ')')
    ok(pa and pa.evidence == 'shape',
        'an arity difference alone is SHAPE evidence (got ' .. tostring(pa and pa.evidence) .. ')')
    -- and the point: the two do not render the same, so a reader can tell them apart
    ok(sa and pa and sa.evidence ~= pa.evidence, 'the two kinds of evidence are distinguished')
    vim.fn.delete(root, 'rf')
end)

-- ⚠ THE CASE THAT SEPARATES THE RIGHT RULE FROM THE PLAUSIBLE ONE. My first cut made a
-- STRUCT hole the only wrapper signal, and it classified 12 wrappers where the prototype
-- found 20. The rest are FIELD and OPERATOR holes, which are context variables too --
-- `X(base)` with `field:a(◦)` against `field:b(◦)`. A pair whose only wrapper evidence is
-- a field hole, alongside an inserted row, is exactly where the two rules disagree: the
-- struct-only rule calls it `rows` and loses the wrapper.
test('clones: a field hole beside an inserted row is a wrapper, not rows-only', function ()
    local base = '  local a = load(src)\n  local b = trim(a)\n  local c = wrap(b)\n'
    local a = base .. '  local d = c.alpha\n  audit(d)\n  persist(d)\n  return d'
    local b = base .. '  local d = c.beta\n  persist(d)\n  return d'
    local root = proj {
        ['m1.lua'] = fn('mix_one', 'src', a),
        ['m2.lua'] = fn('mix_two', 'src', b),
    }
    local p = near_pair(clones.near(store, { max_dist = 3, min_rows = 4, min_shared = 2 }),
        'mix_one', 'mix_two')
    ok(p, 'mix_one and mix_two are a near-clone')
    local an = p and clones.analyze_pair(p)
    ok(an and an.insdel > 0, 'it really does carry an inserted row')
    ok(an and an.struct == 0, 'and NO struct hole — the field hole is the only wrapper evidence')
    ok(an and an.shape ~= 'rows',
        'so it is not rows-only (got ' .. tostring(an and an.shape) .. ')')
    vim.fn.delete(root, 'rf')
end)

-- CART-0875. THE ALIGNER'S TIE-BREAK. When one side INSERTS a row next to a row that
-- also differs, two alignments cost exactly the same, and the backtrace used to take
-- `sub` unconditionally -- pairing two rows that have nothing to do with each other.
-- Measured on cartograph's own tree: `param (field): n.file <=> vim.log.levels.WARN`
-- on 7 of the 59 near pairs, which is a parameter an extract verb would have believed.
-- ⚠ NOTHING PINNED THIS, and the whole suite stayed green through it: the defect is in
-- WHICH rows get paired, not in how many, so every count was right.
test('clones: an inserted row next to a differing row does not pair unrelated rows', function ()
    -- a[3] and b[3] are the same notify with a different message; a[4] is A's insertion.
    -- The tie is sub(a3,b3)+del(a4) against del(a3)+sub(a4,b3) -- same cost, and only the
    -- first pairs the two notifies.
    local body_a = '  local n = focus(store)\n  if not n then return end\n'
        .. '  notify(\'focus a function first\', levels.WARN)\n'
        .. '  mat_df(store, n.file)\n  scratch(narrow(store, n))\n  return n'
    local body_b = '  local n = focus(store)\n  if not n then return end\n'
        .. '  notify(\'focus a method first\', levels.WARN)\n'
        .. '  scratch(fieldlink(store, n))\n  return n'
    local root = proj {
        ['a.lua'] = fn('cmd_a', 'store', body_a),
        ['b.lua'] = fn('cmd_b', 'store', body_b),
    }
    local p = near_pair(clones.near(store, { max_dist = 3, min_rows = 4, min_shared = 2 }),
        'cmd_a', 'cmd_b')
    ok(p, 'cmd_a and cmd_b are a near-clone')
    local holes = p and clones.analyze_pair(p).holes or {}
    local paired_message, nonsense = false, nil
    for _, h in ipairs(holes) do
        local a, b = tostring(h.a), tostring(h.b)
        if a:find('function first', 1, true) and b:find('method first', 1, true) then
            paired_message = true
        end
        -- the defect's signature: the INSERTED row's field against the notify's field
        if (a == 'file' and b == 'WARN') or (a == 'WARN' and b == 'file') then
            nonsense = a .. ' <=> ' .. b
        end
    end
    ok(not nonsense, 'no hole pairs the inserted row with the notify (' ..
        tostring(nonsense) .. ')')
    ok(paired_message, 'the two notify messages are the parameter')
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

-- ⚠ 70.6% of the containers in our own lua tree (1731 of 2452 with n>=2) are
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

-- ── near-clone FAMILIES (clones.families, CART-0888) ────────────────────────
--
-- `near` returns PAIRS; a family is the unit a human would actually extract.
-- These guard the two decisions that make `families` more than a grouping:
-- the split is decided by MDL and NOT by graph shape, and an absent algebra is
-- a NAMED refusal rather than a fall-back to the cheap proxy that over-splits.

local alg = require 'cartograph.algebra'

local function need_alg()
    local ok, why = alg.available()
    if not ok then skip('algebra unavailable: ' .. tostring(why)) end
end

--- three bodies that differ only in one literal each: one family, not three pairs
local function fam3()
    -- ⚠ SIZED FOR THE DEFAULT POPULATION ON PURPOSE. A shorter body is refused
    -- by `near`'s own min_rows and the test would then be measuring the fixture,
    -- not the verb -- and would pass vacuously with zero families if the
    -- assertions were relaxed to match.
    local function body(n)
        return ([[
function M.f%s(t)
    local acc = 0
    local seen = {}
    for i = 1, #t do acc = acc + t[i] * %s end
    local s = tostring(acc)
    local u = string.upper(s)
    seen[u] = true
    local pad = string.rep("-", #u)
    local out = pad .. u
    return out .. "%s"
end
]]):format(n, n, n)
    end
    return proj { ['a.lua'] = 'local M = {}\n' .. body(1) .. body(2) .. body(3) .. 'return M\n' }
end

test('families: one component of near-clones is ONE family, not N pairs', function ()
    need_alg()
    fam3()
    local r, why = clones.families(store, {})
    ok(r ~= nil, 'families computed: ' .. tostring(why))
    eq(1, #r.families)
    local f = r.families[1]
    eq(3, #f.members)
    ok(not f.collapsed, 'the family template is not a bare hole')
    ok(f.fixed > 0, 'it shares fixed structure: ' .. tostring(f.fixed))
    ok(f.holes > 0, 'and it has holes where the members differ')
end)

--- ★ THE POPULATION RIDES WITH THE ANSWER. A family count that does not carry
--- `near`'s admission filter and the MDL constants is not a property of the
--- corpus — it is a property of a gate nobody can see.
test('families: the answer carries the constants it was measured under', function ()
    need_alg()
    fam3()
    local r = clones.families(store, {})
    eq(2, r.population.max_dist)
    eq(6, r.population.min_rows)
    eq(1, r.population.min_fixed)
    ok(r.components >= 1, 'components counted')
    eq(0, r.skipped)
end)

--- ★★ ABSENCE IS A NAMED ANSWER. Falling back to the clique proxy would hand
--- back MORE families, which reads as a FINER answer rather than as a missing
--- instrument — the exact shape this codebase treats as unsound.
test('families: an absent algebra REFUSES, it does not fall back', function ()
    need_alg()
    fam3()
    local cfg = require 'cartograph.config'
    local saved = cfg.algebra
    cfg.algebra = false
    local r, why = clones.families(store, {})
    cfg.algebra = saved
    eq(nil, r)
    ok(tostring(why):find('algebra unavailable'), 'and names the reason: ' .. tostring(why))
end)

--- ★★★ THE ADMISSIBILITY FLOOR IS WHAT STOPS MDL SAYING "ANYTHING IS ONE
--- FAMILY". Without `min_fixed`, unrelated instances merge under a BARE HOLE
--- because that pays one family cost instead of N — and the retraction law
--- cannot catch it, because a bare hole retracts to every instance trivially.
--- That is why this asserts on the TEMPLATE, not on the partition succeeding.
test('families: unrelated instances do NOT merge under a bare hole', function ()
    need_alg()
    local A = alg.load()
    local unrelated = {
        A.node('alpha', A.name('p'), A.name('q')),
        A.node('beta', A.lit('number:7')),
        A.node('gamma', A.name('z'), A.name('w'), A.name('v')),
    }
    local part = A.partition(unrelated)
    for _, f in ipairs(part.families) do
        if #f.members > 1 then
            ok(alg.fixed_nodes(f.template.body) >= 1,
                'a multi-member family shares at least one fixed node')
            ok(not alg.is_collapsed(f.template),
                'and is never a bare hole holding unrelated members together')
        end
    end
end)

--- ★★★ ONE PROPOSAL PER FAMILY (the `generalize` half, CART-0888). The pair-wise
--- `extract_proposal` yields up to C(N,2) proposals over one component and they
--- disagree; a family carries ONE template and one valuation per member.
test('family_proposal: one helper for N copies, with a call site per member', function ()
    need_alg()
    fam3()
    local r = clones.families(store, {})
    eq(1, #r.families)
    local L = clones.family_proposal(r.families[1], store)
    local txt = table.concat(L, '\n')
    ok(txt:find('ONE helper for 3 copies'), 'proposes one helper:\n' .. txt)
    -- one call-site line per member per parameter, not one proposal per pair
    local sites = select(2, txt:gsub('      M%.f%d  =', ''))
    ok(sites >= 3, 'at least one call site per member, got ' .. sites)
    ok(txt:find('at '), 'and each carries a span')
end)

--- ★★ DETERMINISM: the hole map is iterated with `pairs`, which really did come
--- out `h5 h4 h2 h1 h3`. A proposal whose parameters are numbered differently on
--- each run cannot be diffed or reviewed, so the order is pinned.
test('family_proposal: parameter numbering is stable across runs', function ()
    need_alg()
    fam3()
    local r = clones.families(store, {})
    local a = table.concat(clones.family_proposal(r.families[1], store), '\n')
    local b = table.concat(clones.family_proposal(r.families[1], store), '\n')
    eq(a, b)
    ok(a:find('p1:'), 'parameters are numbered from p1')
end)

--- ★★★ THE ALPHA-COLLAPSE BOUNDARY. The adapter maps EVERY local to one symbol,
--- so the term cannot say WHICH local a hole holds. Reading the source at the
--- hole's span recovers the NAME AT THAT USE — but two members showing a local
--- at one hole MAY BE READING UNRELATED VARIABLES, and the proposal must not
--- imply otherwise.
---
--- ⚠ THE FIXTURE HAS TO PUT A LOCAL OPPOSITE A NON-LOCAL. Two bodies differing
--- only in a local NAME are alpha-equivalent — `near` returns them at distance 0
--- and never admits them — so a hole containing a local only arises where one
--- member reads a local and another reads a field or global. That is exactly the
--- shape seen in the real corpus, and building the fixture the obvious way
--- instead yields no family and a test that SKIPS, proving nothing.
test('family_proposal: a collapsed local is NAMED per site, and claimed of nothing', function ()
    need_alg()
    proj { ['b.lua'] = [[
local M = {}
CFG = { limit = 0 }
function M.g1(t)
    local acc = 0
    local seen = {}
    for i = 1, #t do acc = acc + t[i] end
    local s = tostring(acc)
    local u = string.upper(s)
    seen[u] = true
    local pad = string.rep("-", #u)
    return pad .. u
end
function M.g2(t)
    local acc = 0
    local seen = {}
    for i = 1, #t do CFG.limit = CFG.limit + t[i] end
    local s = tostring(CFG.limit)
    local u = string.upper(s)
    seen[u] = true
    local pad = string.rep("-", #u)
    return pad .. u
end
return M
]] }
    local r = clones.families(store, {})
    if not r or #r.families == 0 then skip 'fixture yielded no family' end
    local f = r.families[1]
    local txt = table.concat(clones.family_proposal(f, store), '\n')

    -- the sentinel NEVER reaches the reader, whatever the family turned out to be
    ok(not txt:find('\1local'), 'the collapse sentinel is never printed raw:\n' .. txt)
    if f.holes > 0 then
        -- every parameter line names a real token read from the member's source
        ok(txt:find('at [^\n]*b%.lua:%d+:%d+'), 'each call site carries a span:\n' .. txt)
        ok(txt:find('does not claim the copies read the SAME variable'),
            'and the alpha-collapse boundary rides with the answer:\n' .. txt)
    end
end)

--- ★ A ZERO-HOLE FAMILY OF TWO IS A MERGE, NOT AN EXTRACTION — sending the
--- reader to "extract a helper" there is the wrong command.
--- ⚠ AND A SINGLETON IS NEITHER. `partition` gives a one-member family a
--- hole-free template BY CONSTRUCTION, so it lands in the same branch; calling
--- that "1 copies are IDENTICAL after alpha-renaming" is nonsense a reader would
--- believe. Both are asserted here because the first cut conflated them.
test('family_proposal: a singleton is not "identical copies", and two of them are', function ()
    need_alg()
    fam3()
    local r = clones.families(store, {})
    local m = r.families[1].members[1]

    local lone = { members = { m }, template = { body = { k = 'seq' }, holes = {} },
        values = { {} }, dl = 0, holes = 0, fixed = 0 }
    local txt1 = table.concat(clones.family_proposal(lone, store), '\n')
    ok(txt1:find('joined NO family'), 'a singleton reports as unmerged: ' .. txt1)
    ok(not txt1:find('IDENTICAL'), 'and never as identical copies')

    local two = { members = { m, m }, template = { body = { k = 'seq' }, holes = {} },
        values = { {}, {} }, dl = 0, holes = 0, fixed = 0 }
    local txt2 = table.concat(clones.family_proposal(two, store), '\n')
    ok(txt2:find('CartographMerge'), 'two hole-free members route to merge: ' .. txt2)
    -- ⚠ AND IT MUST NOT CERTIFY THE EQUIVALENCE IT DID NOT CHECK. `near` admitted
    -- these at row-distance 1-2, so the ROW KEYS differ while the TERMS do not --
    -- the term model is coarser (expr.children drops nil slots, CART-0882). The
    -- line points at merge; merge does its own check.
    ok(txt2:find('re%-checks') or txt2:find('coarser'),
        'the proposal defers the equivalence check rather than claiming it: ' .. txt2)
    ok(not txt2:find('IDENTICAL after alpha'), 'and does not overclaim identity')
end)

--- ★ THE FOCUSED QUERY MUST AGREE WITH THE BATCH ONE, or the interactive command
--- and the report answer different questions. `families` partitions every
--- component (9 s on factorio); `family_of` grows only the focus's component
--- over the cached index (0.003 s). Measured equal on the real corpus; pinned
--- here on a fixture so a divergence fails rather than being noticed later.
test('family_of: the focused query returns the same family as the batch verb', function ()
    need_alg()
    fam3()
    local batch = clones.families(store, {})
    eq(1, #batch.families)
    local want = batch.families[1]
    local got, why = clones.family_of(store, want.members[1].id, {})
    ok(got ~= nil, 'focused query found a family: ' .. tostring(why))
    eq(#want.members, #got.members)
    eq(want.holes, got.holes)
    eq(want.dl, got.dl)
end)

--- ⚠ A BOUNDED BFS MUST REFUSE, NOT TRUNCATE. A component cut off at an
--- arbitrary prefix would partition into confident, WRONG families — the answer
--- would look fine and describe a set the user never asked about.
test('family_of: an over-large component refuses instead of truncating', function ()
    need_alg()
    fam3()
    local id = clones.families(store, {}).families[1].members[1].id
    local got, why = clones.family_of(store, id, { max_family = 2 })
    eq(nil, got)
    ok(tostring(why):find('larger than max_family'), 'and names the bound: ' .. tostring(why))
end)

--- absence stays a named answer on the focused path too
test('family_of: an absent algebra refuses by name', function ()
    need_alg()
    fam3()
    local id = clones.families(store, {}).families[1].members[1].id
    local cfg = require 'cartograph.config'
    local saved = cfg.algebra
    cfg.algebra = false
    local got, why = clones.family_of(store, id, {})
    cfg.algebra = saved
    eq(nil, got)
    ok(tostring(why):find('algebra unavailable'), 'names the reason: ' .. tostring(why))
end)

-- ── TERM → TEXT: rendering a family's helper body (CART-0893) ───────────────
--
-- The algebra's missing side. A term cannot be printed — it collapses locals and
-- carries no statement kind — so the text comes from the DONOR and the term only
-- says where to cut. These pin the three things that makes true or false:
-- the span survives anti-unification, the hull closes a synthetic `seq`, and
-- every case where the cut is not known REFUSES rather than rendering.

test('family_helper_text: the donor\'s surface survives, the holes become parameters', function ()
    need_alg()
    fam3()
    local r = clones.families(store, {})
    local f = r.families[1]
    if f.holes == 0 then skip 'fixture family has no holes' end
    local text, why = clones.family_helper_text(f, store)
    ok(text ~= nil, 'rendered: ' .. tostring(why))

    -- surface OUTSIDE the holes comes from the donor for free — that is the
    -- whole reason this substitutes instead of emitting
    ok(text:find('local acc = 0', 1, true), 'shared body text survived:\n' .. text)
    ok(text:find('p1', 1, true), 'and a hole was replaced by its parameter:\n' .. text)
    -- ⚠ BOTH SIDES. A renderer that never substituted would also keep the shared
    -- text, so assert the donor's OWN varying literal is gone from at least one
    -- of the positions the family said varies.
    local donor_lit = '* 1'
    ok(not text:find(donor_lit, 1, true),
        'the donor\'s varying literal was replaced, not carried:\n' .. text)
end)

--- ★ THE P-NUMBERS ARE ONE NUMBERING, and `sorted_holes` is why. The proposal
--- lists `p1..pN` and the rendered text writes `p1..pN`; if the two sorted the
--- hole map differently (and `pairs` really did come out `h5 h4 h2 h1 h3`) then
--- every parameter in the listing would name a different position than the text.
test('family_helper_text: parameter names agree with the proposal listing', function ()
    need_alg()
    -- ⚠ FIVE varying literals, and `max_dist` raised to admit them. `fam3` was
    -- the first fixture here and it yields TWO holes — with two keys `pairs`
    -- order and sorted order COINCIDE, so numbering the parameters in `pairs`
    -- order passed this test unchanged. A guard that cannot distinguish the two
    -- orders is not testing the sort. `family_proposal`'s own comment records
    -- the map coming out `h5 h4 h2 h1 h3`, which is the case that must be caught.
    -- ⚠ SIZED FOR `min_rows`, WHICH COUNTS *MATCHED* ROWS. A first cut put the
    -- five varying rows in a nine-row body, leaving four matching rows — under
    -- the floor of 6, so `near` admitted NOTHING and the test SKIPPED, proving
    -- nothing at all. The shared rows have to outnumber the floor on their own.
    local function body(n, a, b, c, d, e)
        return ([[
function M.r%s(t)
    local acc = %s
    local seen = {}
    local keep = {}
    for i = 1, #t do acc = acc + t[i] * %s end
    local s = tostring(acc) .. "%s"
    local u = string.upper(s) .. "%s"
    seen[u] = true
    keep[#keep + 1] = u
    local pad = string.rep("-", #u)
    local low = string.lower(u)
    local n2 = #low + #pad
    local tag = low .. tostring(n2)
    return pad .. u .. tag .. "%s"
end
]]):format(n, a, b, c, d, e)
    end
    proj { ['e.lua'] = 'local M = {}\n' .. body(1, 11, 12, 13, 14, 15)
        .. body(2, 21, 22, 23, 24, 25) .. 'return M\n' }
    local r = clones.families(store, { max_dist = 8 })
    if not r or #r.families == 0 then skip 'fixture yielded no family' end
    local f = r.families[1]
    -- the fixture must actually produce the ordering problem, or the guard below
    -- is measuring nothing -- so this is an assertion, not a skip
    ok(f.holes >= 4, ('the fixture yields enough holes to order, got %d'):format(f.holes))
    local text = clones.family_helper_text(f, store)
    if not text then skip 'family did not render' end
    local at = require 'cartograph.at'
    local tmpl = clones.family_template(f, store)
    ok(tmpl ~= nil, 'the render-shaped template is available')

    -- ⚠ PRESENCE IS NOT CORRESPONDENCE, and the first cut of this test only
    -- checked that `p1..pN` appeared on both sides. Numbering the parameters in
    -- `pairs` order instead of `sorted_holes` order STILL PASSED THAT: both
    -- lists contain the same names, just against different positions. What has
    -- to agree is the POSITION each name stands for, so the donor's span for
    -- `pN` in the listing must be the span `pN` was written at in the body.
    local at_of = {}
    do
        local cur
        for _, line in ipairs(clones.family_proposal(f, store)) do
            local p = line:match('^%s*(p%d+):%s*$')
            if p then cur = p
            elseif cur then
                local l, c = line:match('at [^%s]+:(%d+):(%d+)%s*$')
                if l then at_of[cur] = l .. ':' .. c; cur = nil end   -- donor is member 1
            end
        end
    end
    -- the numbering itself, asserted directly: `pN` is assigned along
    -- `sorted_holes`, so the order is strictly ascending by numeric suffix
    for i = 2, #tmpl.order do
        local a = tonumber(tmpl.order[i - 1]:match('%d+'))
        local b = tonumber(tmpl.order[i]:match('%d+'))
        ok(a and b and a < b, ('parameters are numbered in hole order, got %s then %s')
            :format(tmpl.order[i - 1], tmpl.order[i]))
    end

    local checked = 0
    for _, v in pairs(tmpl.varying) do
        local want = ('%d:%d'):format(at.sl(v.at) + 1, at.sc(v.at) + 1)
        ok(at_of[v.param] ~= nil, v.param .. ' appears in the listing')
        eq(want, at_of[v.param])
        ok(text:find(v.param, 1, true), v.param .. ' appears in the rendered body:\n' .. text)
        checked = checked + 1
    end
    ok(checked > 0, 'at least one parameter was compared')
end)

--- ★★ THE HULL, PINNED BOTH SIDES. `term`/`row_term` wrap lhs/rhs lists in a
--- synthetic `seq` that is not a source node and carries no span of its own; its
--- extent is its kids' extent. MEASURED before it was built — 7 of 9 spanless
--- hole values on our own lua tree, and 18 of 18 on factorio-mods, were `seq`,
--- of which 6 were EMPTY (no kids, so nothing to hull from).
---
--- ⚠ Tested on the primitive directly. An earlier attempt drove it through a
--- fabricated family and mutated `fam.values` — which the renderer stopped
--- reading when the spans moved to a co-walk of the donor's own term, so the
--- test passed while exercising nothing.
test('term_extent: a spanless seq takes its kids\' hull; a partial one refuses', function ()
    local at = require 'cartograph.at'
    local rng = function (sl, sc, el, ec)
        return { start = { line = sl, char = sc }, ['end'] = { line = el, char = ec } }
    end
    local a = { k = 'lit', v = 1, at = rng(3, 10, 3, 14) }
    local b = { k = 'lit', v = 2, at = rng(3, 20, 4, 6) }

    -- its own span wins, untouched
    eq(3, at.sl(clones.term_extent(a)))
    eq(14, at.ec(clones.term_extent(a)))

    -- POSITIVE: the hull spans from the first kid's start to the last kid's end
    local hull = clones.term_extent { k = 'seq', kids = { a, b } }
    ok(hull ~= nil, 'a seq over spanned kids is hulled')
    eq(3, at.sl(hull)); eq(10, at.sc(hull))
    eq(4, at.el(hull)); eq(6, at.ec(hull))

    -- and it does not depend on the kids being in source order
    local rev = clones.term_extent { k = 'seq', kids = { b, a } }
    eq(3, at.sl(rev)); eq(10, at.sc(rev)); eq(4, at.el(rev)); eq(6, at.ec(rev))

    -- NEGATIVE: one spanless kid and the extent is NOT guessed
    eq(nil, clones.term_extent { k = 'seq', kids = { a, { k = 'name', n = 'x' } } })
    -- NEGATIVE: nothing to hull from at all
    eq(nil, clones.term_extent { k = 'seq', kids = {} })
    eq(nil, clones.term_extent(nil))
end)

--- ⚠ A `row~` IS A STATEMENT THE ADAPTER COULD NOT BUILD. Rendering the donor's
--- text would hard-code the donor's version of a statement nothing compared —
--- and unlike the proposal, which prints a warning beside a list, a block of
--- text reads as finished.
test('family_helper_text: an unbuildable statement refuses the whole render', function ()
    need_alg()
    fam3()
    local r = clones.families(store, {})
    local f = r.families[1]
    if f.holes == 0 then skip 'fixture family has no holes' end
    ok(clones.family_helper_text(f, store) ~= nil, 'it renders before the injection')
    local kids = f.template.body.kids
    kids[#kids + 1] = { k = 'row~' }
    local got, why = clones.family_helper_text(f, store)
    eq(nil, got)
    ok(tostring(why):find('row~'), 'names the unbuildable statement: ' .. tostring(why))
    kids[#kids] = nil
end)

--- A hole-free family is a MERGE; a family of one joined nothing. Neither has a
--- parameter to write, and both must say which they are.
test('family_template: nothing to parameterize refuses by its own reason', function ()
    need_alg()
    fam3()
    local r = clones.families(store, {})
    local f = r.families[1]

    local one = { members = { f.members[1] }, template = f.template, values = f.values }
    local got, why = clones.family_template(one, store)
    eq(nil, got)
    ok(tostring(why):find('one%-member'), 'a singleton says so: ' .. tostring(why))

    local none = { members = f.members, template = { body = f.template.body, holes = {} },
        values = f.values }
    local got2, why2 = clones.family_template(none, store)
    eq(nil, got2)
    ok(tostring(why2):find('merge'), 'a hole-free family points at merge: ' .. tostring(why2))
end)

--- ★★★ A HOLE IS NOT A POSITION. `values[i][h]` holds ONE value per hole, but the
--- template body may mention that hole several times; substituting only the
--- recorded one leaves the donor's literal standing everywhere else, and the
--- result is a helper that is wrong for every caller but the donor.
---
--- MEASURED when this was found: 8 of 25 holes (32%) on our own tree occur more
--- than once, up to 4 times. The real witness was `ansible.lua` — `map_of` and
--- `seq_of` differ in FOUR places, the template has TWO holes, and the first
--- render parameterized the outer `if` while leaving `'block_mapping'`
--- hard-coded inside the loop.
test('family_helper_text: EVERY occurrence of a hole is substituted, not the first', function ()
    need_alg()
    proj { ['c.lua'] = [[
local M = {}
function M.pick_a(node)
    if not node then return nil end
    local acc = 0
    local seen = {}
    if node.t == 'AAA' or node.t == 'BBB' then return node end
    for _, c in ipairs(node.kids) do
        if c.t == 'AAA' or c.t == 'BBB' then return c end
    end
    seen[acc] = true
    return nil
end
function M.pick_c(node)
    if not node then return nil end
    local acc = 0
    local seen = {}
    if node.t == 'CCC' or node.t == 'DDD' then return node end
    for _, c in ipairs(node.kids) do
        if c.t == 'CCC' or c.t == 'DDD' then return c end
    end
    seen[acc] = true
    return nil
end
return M
]] }
    local r = clones.families(store, {})
    if not r or #r.families == 0 then skip 'fixture yielded no family' end
    local f = r.families[1]
    if f.holes == 0 then skip 'fixture family has no holes' end
    local text, why = clones.family_helper_text(f, store)
    ok(text ~= nil, 'rendered: ' .. tostring(why))

    -- the donor's literals appear TWICE each in its source; not one may survive
    local donor = f.members[1]
    local lits = donor.name:find('pick_a') and { 'AAA', 'BBB' } or { 'CCC', 'DDD' }
    for _, lit in ipairs(lits) do
        ok(not text:find(lit, 1, true),
            ('%s still stands in the rendered body — an occurrence was missed:\n%s')
            :format(lit, text))
    end
    ok(text:find('p1', 1, true), 'and the parameter took its place:\n' .. text)
end)

--- ⚠ THE FALSE COLLISION. `row_term` mirrors `row_key`, which writes a
--- conditional row as `lhs=rhs;C:cond` — the CONDITION IS ENCODED TWICE. So one
--- hole legitimately reports two occurrences at ONE span, and treating that as a
--- conflict refuses every conditional in the corpus. Only two DIFFERENT
--- parameters sharing a span is a real collision.
test('family_template: one parameter twice at one span is dropped, not refused', function ()
    need_alg()
    proj { ['d.lua'] = [[
local M = {}
function M.q1(node)
    local acc = 0
    local seen = {}
    if node.t == 'XX' then return node end
    local s = tostring(acc)
    local u = string.upper(s)
    seen[u] = true
    return u
end
function M.q2(node)
    local acc = 0
    local seen = {}
    if node.t == 'YY' then return node end
    local s = tostring(acc)
    local u = string.upper(s)
    seen[u] = true
    return u
end
return M
]] }
    local r = clones.families(store, {})
    if not r or #r.families == 0 then skip 'fixture yielded no family' end
    local f = r.families[1]
    if f.holes == 0 then skip 'fixture family has no holes' end
    local tmpl, why = clones.family_template(f, store)
    ok(tmpl ~= nil, 'a varying condition does not read as a span collision: ' .. tostring(why))
    -- and the span really is claimed once, by one parameter
    local nkeys = 0
    for _ in pairs(tmpl.varying) do nkeys = nkeys + 1 end
    ok(nkeys > 0, 'the condition span is claimed')
end)

--- ⚠ A FABRICATED FAMILY REACHES `family_template` DIRECTLY, and the shipped
--- verbs' "absent algebra refuses by name" contract has to hold there too. The
--- renderer rebuilds the donor's term itself (`alg.fn_term`), so without the
--- check an absent algebra surfaces as a traceback out of `family_proposal`
--- rather than as an answer. Unreachable through the commands today — a family
--- record only exists if the algebra loaded — and reachable from a spec, which
--- is exactly how a future caller will reach it.
test('family_template: an absent algebra refuses by name, like every other verb', function ()
    need_alg()
    fam3()
    local r = clones.families(store, {})
    local f = r.families[1]
    ok(clones.family_template(f, store) ~= nil, 'it answers while the algebra is present')

    local cfg = require 'cartograph.config'
    local saved = cfg.algebra
    cfg.algebra = false
    local got, why = clones.family_template(f, store)
    local got2, why2 = clones.family_helper_text(f, store)
    cfg.algebra = saved

    eq(nil, got)
    ok(tostring(why):find('algebra unavailable'), 'names the reason: ' .. tostring(why))
    eq(nil, got2)
    ok(tostring(why2):find('algebra unavailable'), 'and so does the text verb: ' .. tostring(why2))
end)

--- ★ THE REAL COLLISION, as opposed to the false one above. Two DIFFERENT
--- parameters landing on ONE donor span means one substitution overwrites the
--- other and the loser vanishes silently. Dropping a duplicate of the SAME
--- parameter is safe; this is not, and the two share a branch.
---
--- ⚠ CONSTRUCTED, because the corpus does not offer it: a conditional row
--- encodes its condition TWICE at one span (`lhs=rhs;C:cond`), so renaming the
--- second occurrence to a fresh hole puts two distinct parameters on that one
--- span — exactly the shape that must refuse. Found by mutation: removing the
--- collision check broke no test until this existed.
test('family_template: two DIFFERENT parameters on one span is refused', function ()
    need_alg()
    proj { ['f.lua'] = [[
local M = {}
function M.s1(node)
    local acc = 0
    local seen = {}
    if node.t == 'XX' then return node end
    local s = tostring(acc)
    local u = string.upper(s)
    seen[u] = true
    return u
end
function M.s2(node)
    local acc = 0
    local seen = {}
    if node.t == 'YY' then return node end
    local s = tostring(acc)
    local u = string.upper(s)
    seen[u] = true
    return u
end
return M
]] }
    local r = clones.families(store, {})
    if not r or #r.families == 0 then skip 'fixture yielded no family' end
    local f = r.families[1]
    if f.holes == 0 then skip 'fixture family has no holes' end
    ok(clones.family_template(f, store) ~= nil, 'it answers before the rename')

    -- find a hole mentioned twice, and rename its SECOND occurrence
    local counts, target = {}, nil
    local function scan(t)
        if t == nil then return end
        if t.k == 'hole' then
            counts[t.h] = (counts[t.h] or 0) + 1
            if counts[t.h] == 2 and not target then target = t end
        end
        for _, k in ipairs(t.kids or {}) do scan(k) end
    end
    scan(f.template.body)
    if not target then skip 'no hole occurs twice in this template' end

    local was = target.h
    target.h = 'h99'
    f.template.holes['h99'] = f.template.holes[was]
    local got, why = clones.family_template(f, store)
    target.h = was
    f.template.holes['h99'] = nil

    eq(nil, got)
    ok(tostring(why):find('share one span'),
        'names the collision rather than letting one win: ' .. tostring(why))
end)

--- ★★★ THE IDENTITY RENDER, a -> a. Substitute every hole with the DONOR'S OWN
--- text and the result must be the donor's source, byte for byte. There is no
--- expected value to calibrate — the answer IS the input, the same property the
--- transliteration round-trip oracle rests on.
---
--- MEASURED as a sweep when it landed: 9 of 9 renderable families on this repo
--- and 15 of 15 on factorio-mods reproduce their donor exactly. Mutating the
--- splice order or dropping the donor's column offset from the rebase are both
--- caught by it.
---
--- ⚠ AND THE LIMIT, because this test would otherwise be read as proving more
--- than it does: replacing a span with the text OF that span is identity for ANY
--- span inside the donor, so it CANNOT see a hole pointing at the wrong place.
--- What it does exercise is everything with an offset in it — the rebase into
--- donor coordinates, the rightmost-first ordering when two holes share a line,
--- the nested-span subsumption, and the donor slice. Span correctness needs the
--- reparse oracle that does not exist yet (CART-0893).
test('family_helper_text: the identity render reproduces the donor byte for byte', function ()
    need_alg()
    local at = require 'cartograph.at'
    local function donor_text(tmpl)
        local nd = store.node(tmpl.donor.id)
        local lines = store.content(nd)
        local sl, el, sc, ec = at.sl(tmpl.donor.at), at.el(tmpl.donor.at),
            at.sc(tmpl.donor.at), at.ec(tmpl.donor.at)
        local out = {}
        for i = sl, el do out[#out + 1] = lines[i + 1] end
        out[1] = out[1]:sub(sc + 1)
        out[#out] = out[#out]:sub(1, ec - (el == sl and sc or 0))
        return table.concat(out, '\n')
    end

    fam3()
    local r = clones.families(store, {})
    local f = r.families[1]
    local t1 = clones.family_template(f, store)
    ok(t1 ~= nil, 'the template is available')
    local id1, why1 = clones.family_helper_text(f, store, { identity = true })
    ok(id1 ~= nil, 'the identity render succeeds: ' .. tostring(why1))
    eq(donor_text(t1), id1)
    -- and it is NOT the parameterized render, or the oracle compares a render
    -- to itself and holds vacuously
    local p1 = clones.family_helper_text(f, store)
    ok(p1 ~= id1, 'the parameterized render really does differ from the donor')

    -- ⚠ AND ONE WITH A HOLE MENTIONED TWICE, where two replacements land on one
    -- line and the rightmost-first rule is what keeps the columns valid.
    proj { ['g.lua'] = [[
local M = {}
function M.pa(node)
    if not node then return nil end
    local acc = 0
    local seen = {}
    if node.t == 'AAA' or node.t == 'BBB' then return node end
    for _, c in ipairs(node.kids) do
        if c.t == 'AAA' or c.t == 'BBB' then return c end
    end
    seen[acc] = true
    return nil
end
function M.pc(node)
    if not node then return nil end
    local acc = 0
    local seen = {}
    if node.t == 'CCC' or node.t == 'DDD' then return node end
    for _, c in ipairs(node.kids) do
        if c.t == 'CCC' or c.t == 'DDD' then return c end
    end
    seen[acc] = true
    return nil
end
return M
]] }
    local r2 = clones.families(store, {})
    ok(r2 and #r2.families > 0, 'the repeated-hole fixture yields a family')
    local f2 = r2.families[1]
    local t2 = clones.family_template(f2, store)
    ok(t2 ~= nil, 'and it adapts')
    local id2, why2 = clones.family_helper_text(f2, store, { identity = true })
    ok(id2 ~= nil, 'the identity render succeeds with repeated holes: ' .. tostring(why2))
    eq(donor_text(t2), id2)
end)

-- ── the reparse oracle (CART-0893) ──────────────────────────────────────────
--
-- Render the helper, READ IT BACK, and require it to be the template it was
-- built from with each parameter at its own hole. Step C checked by step B —
-- `M.render`'s own discipline, lifted to function altitude.

test('expr.of_text: a function in a STRING harvests like one in the tree', function ()
    if not ready() then return skip 'no lua parser' end
    local eo, why = expr.of_text([[
local function f(t)
    local acc = 0
    acc = acc + #t
    return acc
end
]], 'lua')
    ok(eo ~= nil, 'a standalone function parses: ' .. tostring(why))
    ok(eo.fl and #(eo.fl.stmts or {}) >= 3, 'and yields its statement rows')

    -- the refusals, each by name
    local a, w1 = expr.of_text('local function f( +++ ', 'lua')
    eq(nil, a); ok(tostring(w1):find('parse'), 'a broken text says so: ' .. tostring(w1))
    local b, w2 = expr.of_text('local x = 1', 'lua')
    eq(nil, b); ok(tostring(w2):find('no function'), 'text with no function: ' .. tostring(w2))
    local c, w3 = expr.of_text('whatever', 'not-a-language')
    eq(nil, c); ok(tostring(w3):find('spec'), 'an unsupported language: ' .. tostring(w3))
end)

test('family_verify: a rendered helper reparses to its own template', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    fam3()
    local r = clones.families(store, {})
    local f = r.families[1]
    if f.holes == 0 then skip 'fixture family has no holes' end
    local good, why, d = clones.family_verify(f, store)
    ok(good, 'the render verifies: ' .. tostring(why))
    ok(d and d.rows and d.rows > 0, 'and reports what it read back')
end)

--- ★★★ THE CONTROL IS WHAT KEEPS THIS HONEST. A donor whose span is an
--- ANONYMOUS function is an EXPRESSION, and a chunk containing only one is a
--- syntax error — so its own text does not reparse and the oracle cannot speak
--- either way. MEASURED before the control existed: 4 of 9 rendered helpers on
--- our own tree "did not reparse", every one of them for that reason and NONE
--- because the render was wrong. Reported as defects that is a 44% false alarm.
test('family_verify: an anonymous-function donor is NOT VERIFIABLE, not a defect', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    proj { ['h.lua'] = [[
local M = {}
M.wrap1 = function (name, ps, body, ind)
    local out = { ind .. "A" }
    local seen = {}
    for _, l in ipairs(body) do out[#out + 1] = l end
    seen[name] = ps
    out[#out + 1] = ind .. "B"
    out[#out + 1] = ''
    return out
end
M.wrap2 = function (name, ps, body, ind)
    local out = { ind .. "C" }
    local seen = {}
    for _, l in ipairs(body) do out[#out + 1] = l end
    seen[name] = ps
    out[#out + 1] = ind .. "D"
    out[#out + 1] = ''
    return out
end
return M
]] }
    local r = clones.families(store, {})
    if not r or #r.families == 0 then skip 'fixture yielded no family' end
    local f = r.families[1]
    if f.holes == 0 then skip 'fixture family has no holes' end
    local good, why, d = clones.family_verify(f, store)
    eq(nil, good)
    ok(tostring(why):find('not verifiable'), 'it says NOT VERIFIABLE: ' .. tostring(why))
    ok(d and d.verifiable == false,
        'and flags it as a frame problem, so a caller can tell it from a failure')
    -- ⚠ BOTH SIDES: the render itself still succeeded. "Cannot be checked" must
    -- not be reported as "is wrong".
    ok(clones.family_helper_text(f, store) ~= nil, 'the render itself is fine')
end)

--- AND THE DEFECT SIDE: a substitution that breaks the grammar must be caught,
--- which is the whole reason the oracle exists. `M.render`'s BRACKET BUG was
--- 5.3% of renders at container altitude and every one looked well-formed.
test('family_verify: a substitution that breaks the grammar is caught', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    fam3()
    local r = clones.families(store, {})
    local f = r.families[1]
    if f.holes == 0 then skip 'fixture family has no holes' end
    local h = (clones.family_template(f, store) or {}).order[1]
    ok(h ~= nil, 'the family has a hole to substitute at')

    local good, why = clones.family_verify(f, store, { subs = { [h] = ')' } })
    eq(nil, good)
    ok(tostring(why):find('did not reparse'),
        'the oracle refuses text the grammar rejects: ' .. tostring(why))
    -- and it is NOT reported as a frame problem — the donor parses fine
    ok(not tostring(why):find('not verifiable'),
        'a real defect is distinguished from an unverifiable frame')
end)

--- ★★★ THE COMPARISON ITSELF, which the grammar test above does NOT reach: a
--- substitution that PARSES CLEANLY but is a different TERM. Found by mutation
--- — removing the `A.eq` entirely broke no test, because every negative until
--- now failed at the parse gate instead.
test('family_verify: a render that parses but is a DIFFERENT term is caught', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    fam3()
    local r = clones.families(store, {})
    local f = r.families[1]
    if f.holes == 0 then skip 'fixture family has no holes' end
    local h = (clones.family_template(f, store) or {}).order[1]
    ok(h ~= nil, 'the family has a hole to substitute at')

    -- `a + b` is valid Lua and reparses to a BINARY NODE where the template says
    -- one position: the text is well-formed and the shape is not what was asked.
    local good, why = clones.family_verify(f, store, { subs = { [h] = 'a + b' } })
    eq(nil, good)
    ok(tostring(why):find('DIFFERENT term'), 'the term comparison fires: ' .. tostring(why))
    ok(not tostring(why):find('did not reparse'),
        'and it is NOT the parse gate — the text was perfectly valid')
end)

--- A METHOD donor is harvested with `method = true` (the implicit receiver), and
--- the reparse must use the SAME config or it compares one text under two specs.
test('family_verify: a method donor verifies under the method config', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    proj { ['m.lua'] = [[
local M = {}
function M:m1(t)
    local acc = self.base
    local seen = {}
    for i = 1, #t do acc = acc + t[i] * 3 end
    local s = tostring(acc)
    local u = string.upper(s) .. self.tag
    seen[u] = true
    local pad = string.rep("-", #u)
    return pad .. u
end
function M:m2(t)
    local acc = self.base
    local seen = {}
    for i = 1, #t do acc = acc + t[i] * 7 end
    local s = tostring(acc)
    local u = string.upper(s) .. self.tag
    seen[u] = true
    local pad = string.rep("-", #u)
    return pad .. u
end
return M
]] }
    local r = clones.families(store, {})
    if not r or #r.families == 0 then skip 'fixture yielded no family' end
    local f = r.families[1]
    if f.holes == 0 then skip 'fixture family has no holes' end
    local good, why = clones.family_verify(f, store)
    ok(good, 'a method donor round-trips: ' .. tostring(why))
end)

-- ── the MEET: unify two templates (CART-0879 item 1) ────────────────────────
--
-- `M.match` is ONE-SIDED — a template against a payload — so "do these two
-- claims OVERLAP" had no operation. These pin the adapter that gets
-- cartograph's OTHER template shape into the algebra, and the defining law of
-- the meet itself.

local function container_of_src(src)
    local root = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    local function find(n)
        if n:type() == 'table_constructor' then return n end
        for c in n:iter_children() do
            if c:named() then local r = find(c); if r then return r end end
        end
    end
    return expr.build(find(root), src, 'lua')
end
local function tmpl_of(src)
    return clones.template_of(clones.element_template(container_of_src(src)))
end

test('template_of: the varying position becomes a hole, the rest stays fixed', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local alg = require 'cartograph.algebra'
    local A = alg.load()
    local t, why = tmpl_of("local X = { f(1, z), f(2, z) }")
    ok(t ~= nil, 'the container adapts: ' .. tostring(why))
    local shown = A.show(t.body)
    ok(shown:find('?'), 'it has a hole where the members differ: ' .. shown)
    ok(shown:find('f', 1, true) and shown:find('z', 1, true),
        'and the AGREEING parts are still fixed, not holes: ' .. shown)
    -- BOTH SIDES: the hole is at the varying arg, so the literal must be gone
    ok(not shown:find('num:1'), 'the donor\'s own varying value is not baked in: ' .. shown)
end)

test('template_of: refuses by name where a template is not warranted', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local a, w1 = tmpl_of("local X = { 'a' }")
    eq(nil, a); ok(tostring(w1):find('single member'), tostring(w1))
    local b, w2 = tmpl_of("local X = { 'a', f(1,2,3) }")
    eq(nil, b); ok(tostring(w2):find('do not share a shape'), tostring(w2))
    local c, w3 = clones.template_of({ donor = false })
    eq(nil, c); ok(tostring(w3):find('not an element template'), tostring(w3))
end)

--- ★★★ THE DEFINING LAW, asserted with the prototype's own subsumption check
--- rather than a hand-computed expectation: the meet is an INSTANCE OF BOTH.
--- A wrong meet that happens to look plausible passes an eyeball and fails this.
test('template_meet: the meet is an instance of both templates', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local alg = require 'cartograph.algebra'
    local A = alg.load()
    local T1 = tmpl_of("local X = { f(1, z), f(2, z) }")      -- (call f ?h z)
    local T2 = tmpl_of("local Y = { f(3, 3), f(3, 4) }")      -- (call f 3 ?h)
    ok(T1 and T2, 'both containers adapt')

    local m, why = clones.template_meet(T1, T2)
    ok(m ~= nil, 'they overlap: ' .. tostring(why))
    ok(A.instance_of(m.template, T1), 'the meet is below the LEFT template')
    ok(A.instance_of(m.template, T2), 'the meet is below the RIGHT template')
    -- and it is genuinely lower than at least one of them — otherwise "meet"
    -- would be satisfied by handing back an input
    ok(not A.instance_of(T1, m.template) or not A.instance_of(T2, m.template),
        'the meet is strictly below at least one side: ' .. A.show(m.template.body))
end)

--- AND THE OTHER SIDE: templates whose FIXED parts disagree have NO meet, and
--- the refusal names the clash rather than returning an empty template.
test('template_meet: a clash in the fixed part is a named refusal', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local head, w1 = clones.template_meet(
        tmpl_of("local X = { f(1, z), f(2, z) }"),
        tmpl_of("local Y = { g(1, z), g(2, z) }"))
    eq(nil, head); ok(tostring(w1):find('f') and tostring(w1):find('g'),
        'names the clashing symbols: ' .. tostring(w1))

    local fixed, w2 = clones.template_meet(
        tmpl_of("local X = { f(1, z), f(2, z) }"),
        tmpl_of("local Y = { f(9, w), f(8, w) }"))
    eq(nil, fixed); ok(tostring(w2):find('z') and tostring(w2):find('w'),
        'a disagreeing FIXED argument is a clash, not a hole: ' .. tostring(w2))
end)

--- ★★ SUBSUMPTION, which is `M.render`'s rule and not a new one. `varying` keeps
--- BOTH a field hole and its base's holes deliberately; only the OUTERMOST may
--- become a hole here. Without the pruning the walk stops at the outer span and
--- never reaches the inner one, so the position count comes up short and the
--- whole container is refused — a nested divergence would silently stop having
--- a template.
test('template_of: nested varying spans yield ONE hole, not a refusal', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local alg = require 'cartograph.algebra'
    local A = alg.load()
    -- ⚠ THE FIXTURE MUST ACTUALLY NEST. `{ a.b.c, a.b.d }` yields ONE varying
    -- span (the whole member) and exercises nothing — the first cut used it and
    -- the mutation "drop subsumption" survived. Varying the BASE as well as the
    -- field gives two spans, one inside the other.
    local et = clones.element_template(container_of_src("local X = { a.b.c, x.b.d }"))
    local nv = 0; for _ in pairs(et.varying) do nv = nv + 1 end
    ok(nv >= 2, 'the fixture yields nested spans to prune, got ' .. nv)

    local t, why = clones.template_of(et)
    ok(t ~= nil, 'a nested field divergence still adapts: ' .. tostring(why))
    local n = 0
    local function count(x)
        if x.k == 'hole' then n = n + 1; return end
        for _, c in ipairs(x.kids or {}) do count(c) end
    end
    count(t.body)
    eq(1, n)
    ok(A.show(t.body):find('?'), 'and it is a hole: ' .. A.show(t.body))
end)

--- ⚠ A VARYING POSITION WITH NO NODE IN THE TERM IS A REFUSAL, NOT A SMALLER
--- TEMPLATE. The adapter drops expression kinds it does not model (CART-0882),
--- and a template missing a position its members demonstrably vary at claims
--- agreement where none was checked. Fabricated, because the reachable corpus
--- shapes all locate: the guard is for the kind the adapter stops modelling
--- NEXT, which is exactly when nobody is looking.
test('template_of: a varying span the term cannot locate refuses', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local et = clones.element_template(container_of_src("local X = { f(1, z), f(2, z) }"))
    ok(clones.template_of(et) ~= nil, 'it adapts before the injection')

    et.varying['999:0-999:9'] = { kind = 'value', at = {
        start = { line = 999, char = 0 }, ['end'] = { line = 999, char = 9 } } }
    local t, why = clones.template_of(et)
    eq(nil, t)
    ok(tostring(why):find('no node in the term'), 'names it: ' .. tostring(why))
end)

--- And an UNKEYED hole — one `element_template` itself could not give a span —
--- cannot be placed in a term at all. `M.match` refuses on a non-zero count for
--- the same reason; this is that refusal one layer along.
test('template_of: an unkeyed hole refuses rather than placing it somewhere', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local et = clones.element_template(container_of_src("local X = { f(1, z), f(2, z) }"))
    et.unkeyed = 1
    local t, why = clones.template_of(et)
    eq(nil, t)
    ok(tostring(why):find('no source span'), 'names it: ' .. tostring(why))
end)

--- ★★★ THE OTHER HALF OF THE LATTICE. `template_meet` is the greatest template
--- BELOW two; this is the least ABOVE. The consumer is a refusal that becomes an
--- answer: `M.match` says a payload does not instantiate a template and stops,
--- and `join(T, payload)` says what T would have to BECOME to admit it.
test('template_join: a match refusal becomes a named widening', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local alg = require 'cartograph.algebra'
    local A = alg.load()
    local et = clones.element_template(container_of_src("local X = { f(1, z), f(2, z) }"))
    local T = clones.template_of(et)
    ok(T ~= nil, 'the container adapts')

    -- the payload `f(7, q)` differs in a FIXED position, so match refuses
    local payload = container_of_src("local Y = { f(7, q) }").kids[1]
    local m = clones.match(et, payload)
    eq(false, m.ok)

    -- ...and the join says exactly what would have to give
    local j, why = clones.template_join(T, payload)
    ok(j ~= nil, 'the join exists: ' .. tostring(why))
    eq(1, #(j.new or {}))
    local shown = A.show(j.template.body)
    ok(select(2, shown:gsub('%?', '')) == 2,
        'the fixed argument became a second hole: ' .. shown)
    ok(A.instance_of(T, j.template), 'and the widening is ABOVE the original')
end)

--- ⚠ ADOPTION: a payload the template ALREADY admits must leave it UNCHANGED.
--- A join that widened on every newcomer would erode a claim one payload at a
--- time, which is the failure `adjoin` is named for.
test('template_join: a payload that already fits changes nothing', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local alg = require 'cartograph.algebra'
    local A = alg.load()
    local T = clones.template_of(
        clones.element_template(container_of_src("local X = { f(1, z), f(2, z) }")))
    local payload = container_of_src("local Y = { f(7, z) }").kids[1]

    local j, why = clones.template_join(T, payload)
    ok(j ~= nil, 'it joins: ' .. tostring(why))
    eq(0, #(j.new or {}))
    eq(0, #(j.split or {}))
    eq(A.show(T.body), A.show(j.template.body))

    -- ★ AND THE HOLE NAMES SURVIVE, which is the whole reason this is `join` and
    -- not `generalize`: a re-derivation renames, and every stored value keyed by
    -- the old name is orphaned.
    ok(#(j.kept or {}) > 0, 'holes are KEPT by name, so stored values follow')
    local names = {}
    for _, h in ipairs(A.hole_names(j.template)) do names[h] = true end
    for _, h in ipairs(A.hole_names(T)) do
        ok(names[h], ('hole %s kept its name through the join'):format(h))
    end
end)

--- The law, dual to the meet's and asserted the same way: ABOVE both inputs.
test('template_join: the join is above both templates', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local alg = require 'cartograph.algebra'
    local A = alg.load()
    local T1 = clones.template_of(
        clones.element_template(container_of_src("local X = { f(1, z), f(2, z) }")))
    local T2 = clones.template_of(
        clones.element_template(container_of_src("local Y = { g(1, z), g(2, z) }")))

    local j, why = clones.template_join(T1, T2)
    ok(j ~= nil, 'two templates join: ' .. tostring(why))
    ok(A.instance_of(T1, j.template), 'above the LEFT template')
    ok(A.instance_of(T2, j.template), 'above the RIGHT template')
    -- and strictly above at least one, or "join" would be satisfied by handing
    -- back an input
    ok(not A.instance_of(j.template, T1) or not A.instance_of(j.template, T2),
        'strictly above at least one: ' .. A.show(j.template.body))
    -- the clashing head is what gave way, and the AGREEING argument did not
    ok(A.show(j.template.body):find('z', 1, true),
        'the part both agreed on is still fixed: ' .. A.show(j.template.body))
end)

--- THREE INPUT SHAPES reach these verbs and the normaliser is SHARED with
--- `template_meet` — two copies of a shape test is how the two verbs start
--- disagreeing about what they accept.
test('template_join/meet: template, element_template and payload all normalise', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local et = clones.element_template(container_of_src("local X = { f(1, z), f(2, z) }"))
    local T = clones.template_of(et)
    local payload = container_of_src("local Y = { f(7, z) }").kids[1]

    ok(clones.template_join(T, payload), 'prototype template + expr payload')
    ok(clones.template_join(et, payload), 'element_template + expr payload')
    ok(clones.template_join(et, T), 'element_template + prototype template')
    ok(clones.template_meet(et, T), 'and the meet takes the same shapes')

    local bad, why = clones.template_join(T, { nope = true })
    eq(nil, bad)
    ok(tostring(why):find('neither a template'), 'a fourth shape refuses by name: ' .. tostring(why))
end)

-- ── editing a family's template, and carrying its values ────────────────────
--
-- `templates.lua` exists because "a template you cannot point at cannot be
-- CORRECTED". What was missing is the operation that corrects one AND says who
-- falls out. The dropped list is the answer, not an error path.

--- a 3-member family whose members differ at two literal positions
local function fam_edit_fixture()
    local function body(n)
        return ([[
function M.g%s(t)
    local acc = 0
    local seen = {}
    for i = 1, #t do acc = acc + t[i] * %s end
    local s = tostring(acc)
    local u = string.upper(s)
    seen[u] = true
    local pad = string.rep("-", #u)
    local out = pad .. u
    return out .. "%s"
end
]]):format(n, n, n)
    end
    proj { ['fe.lua'] = 'local M = {}\n' .. body(1) .. body(2) .. body(3) .. 'return M\n' }
    local r = clones.families(store, {})
    return r and r.families[1]
end

test('family_edit: a PIN narrows the template and NAMES who falls out', function ()
    need_alg()
    local f = fam_edit_fixture()
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end
    eq(3, #f.members)

    local h = (clones.family_template(f, store) or {}).order[1]
    ok(h ~= nil, 'the family has a hole to pin')
    local res, why = clones.family_edit(f, { edit = 'pin', h = h, value = f.values[1][h] })
    ok(res ~= nil, 'the pin applies: ' .. tostring(why))

    eq('down', res.direction)
    eq(1, #res.kept)
    eq(2, #res.dropped)
    -- ★ the dropped entries are USABLE: a name, a file and a reason, not indices
    for _, d in ipairs(res.dropped) do
        ok(d.name and d.file, 'a dropped member carries where it is')
        ok(tostring(d.why):find('differs'), 'and why it fell out: ' .. tostring(d.why))
    end
end)

--- ★★★ THE LAW `migrate` EXISTS FOR: a kept member's MIGRATED values must
--- instantiate the EDITED template to the SAME instance the original values
--- instantiated the original template to. An edit that quietly changed what a
--- member means would keep it in `kept` and pass every count-based assertion.
test('family_edit: a kept member still means the same thing', function ()
    need_alg()
    local alg = require 'cartograph.algebra'
    local A = alg.load()
    local f = fam_edit_fixture()
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end
    local h = (clones.family_template(f, store) or {}).order[1]

    local before = A.instantiate(f.template, f.values[1])
    ok(before and before.ok, 'the original values instantiate the original template')

    local res = clones.family_edit(f, { edit = 'pin', h = h, value = f.values[1][h] })
    ok(res ~= nil, 'the pin applies')
    for _, i in ipairs(res.kept) do
        local after = A.instantiate(res.template, res.values[i])
        ok(after and after.ok, ('member %d still instantiates the edited template'):format(i))
        ok(A.eq(after.term, A.instantiate(f.template, f.values[i]).term),
            ('member %d means the same after the edit as before'):format(i))
    end
end)

--- AND THE OTHER DIRECTION. `dig` moves UP — a fixed subtree becomes a hole —
--- so the template admits MORE and nobody may fall out. A verb that reported
--- the same shape for both directions would be describing its own control flow,
--- not the edit.
test('family_edit: an UP edit drops nobody', function ()
    need_alg()
    local f = fam_edit_fixture()
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end

    -- a path to some FIXED node in the body
    local path
    local function find(t, p)
        if path then return end
        if t.k ~= 'hole' and #p > 0 and #(t.kids or {}) == 0 then path = p; return end
        for i, c in ipairs(t.kids or {}) do
            local q = {}; for _, x in ipairs(p) do q[#q + 1] = x end; q[#q + 1] = i
            find(c, q)
        end
    end
    find(f.template.body, {})
    ok(path ~= nil, 'the template has a fixed subtree to dig')

    local res, why = clones.family_edit(f, { edit = 'dig', path = path, h = 'dug1' })
    ok(res ~= nil, 'the dig applies: ' .. tostring(why))
    eq('up', res.direction)
    eq(0, #res.dropped)
    eq(3, #res.kept)
end)

test('family_edit: refuses an unknown edit and a missing hole by name', function ()
    need_alg()
    local f = fam_edit_fixture()
    if not f then skip 'fixture yielded no family' end

    local a, w1 = clones.family_edit(f, { edit = 'wat' })
    eq(nil, a); ok(tostring(w1):find('unknown edit'), tostring(w1))
    local b, w2 = clones.family_edit(f, { edit = 'open', h = 'nope' })
    eq(nil, b); ok(tostring(w2):find('no hole'), tostring(w2))
    local c, w3 = clones.family_edit(f, { edit = 'pin', h = 'h1' })
    eq(nil, c); ok(tostring(w3):find('needs a value'), tostring(w3))
    local d, w4 = clones.family_edit({ template = false }, { edit = 'pin' })
    eq(nil, d); ok(tostring(w4):find('not a family'), tostring(w4))
end)

--- ★★★ THE JOURNAL IS COMPLETE FOR THE WRONG HALF (CART-0896). The template
--- journals its edits and `A.replay_edit` replays them, so `open` restores what
--- `pin` SUPPLIED. But `migrate` ends by RE-DERIVING domains over the SURVIVING
--- members, and a re-derivation is not a move in the order — so it is not in the
--- log and nothing undoes it.
---
--- This is a characterization test of a BOUNDARY, not of a defect: it is here
--- because the behaviour is surprising, the refusal it produces says "pinned"
--- about a hole nobody pinned, and a future change to the summary policy would
--- otherwise move it silently.
test('family_edit: a pin closes holes it never touched, and `open` cannot undo that', function ()
    need_alg()
    local alg = require 'cartograph.algebra'
    local A = alg.load()
    local f = fam_edit_fixture()
    if not f or f.holes < 2 then skip 'fixture needs two holes' end

    local hs = {}
    for h in pairs(f.template.holes) do hs[#hs + 1] = h end
    table.sort(hs)
    local pinned_hole, other = hs[1], hs[2]

    -- BEFORE: neither hole is closed
    ok(not f.template.holes[other].was, 'the other hole was never pinned')

    local res = clones.family_edit(f,
        { edit = 'pin', h = pinned_hole, value = f.values[1][pinned_hole] })
    ok(res ~= nil and #res.dropped > 0, 'the pin drops members')

    -- ★ the UNEDITED hole is now closed too, because one survivor means one
    -- value per column
    local d1 = A.show_domain(res.template.holes[pinned_hole].domain)
    local d2 = A.show_domain(res.template.holes[other].domain)
    ok(d1:find('"'), ('the pinned hole is closed: %s'):format(d1))
    ok(d2:find('"'), ('and so is the UNEDITED one: %s'):format(d2))
    ok(not res.template.holes[other].was,
        'yet it carries no `was` marker — no edit narrowed it, a re-derivation did')

    -- ★★ so re-opening the pin does NOT re-admit a dropped member, and the
    -- refusal names the OTHER hole
    local reopened = A.open_hole(res.template, pinned_hole)
    ok(reopened ~= nil, 'the pin re-opens')
    local dropped = res.dropped[1]
    local inst = A.instantiate(f.template, f.values[dropped.i])
    ok(A.match(f.template, inst.term).ok,
        'CONTROL: the ORIGINAL template matches its own member')
    local m = A.match(reopened, inst.term)
    eq(false, m.ok)
    ok(tostring(m.refusal and m.refusal.why):find(other),
        ('refused on the hole no edit touched (%s): %s'):format(other,
            tostring(m.refusal and m.refusal.why)))
end)

--- ★★★ ADOPTION CLOSES CART-0896's LOOP. `migrate` carries the family it is
--- given and never adopts, so a member dropped by a narrowing edit could not get
--- back in — "adoption is a match, not a migration". This is that match.
test('family_adopt: a newcomer that already fits leaves the template UNCHANGED', function ()
    need_alg()
    local alg = require 'cartograph.algebra'
    local A = alg.load()
    local f = fam_edit_fixture()
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end

    local before = A.show(f.template.body)
    local r, why = clones.family_adopt(f, f.members[2])
    ok(r ~= nil, 'a member of the family is adoptable: ' .. tostring(why))
    eq(true, r.adopted)
    eq(0, r.widened)
    eq(before, A.show(r.template.body))
    -- ⚠ and it is ADOPTION, not re-derivation: `generalize` over the members
    -- plus the newcomer would rename every hole and orphan every stored value
    for _, h in ipairs(A.hole_names(f.template)) do
        ok(r.template.holes[h], ('hole %s kept its name through the adoption'):format(h))
    end
end)

--- ★★ A NEWCOMER IS AN OBSERVATION AND MAY NOT OVERRULE A PREMISE. It may widen
--- a DERIVED domain — the family simply turns out broader than the members seen
--- so far — and it may not override a SUPPLIED one, because a pin is a premise
--- and an observation does not get to overturn it by arriving.
test('family_adopt: it refuses to override a SUPPLIED domain, and names both routes', function ()
    need_alg()
    local f = fam_edit_fixture()
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end
    local hs = {}
    for h in pairs(f.template.holes) do hs[#hs + 1] = h end
    table.sort(hs)
    local h = hs[1]

    local pinned = clones.family_edit(f, { edit = 'pin', h = h, value = f.values[1][h] })
    ok(pinned and #pinned.dropped > 0, 'the pin drops someone to re-adopt')
    local d = pinned.dropped[1]
    local narrowed = { members = { f.members[1] }, template = pinned.template,
        values = { pinned.values[1] } }

    local r, why = clones.family_adopt(narrowed, f.members[d.i])
    eq(nil, r)
    ok(tostring(why):find('supplied domain'), 'names the premise: ' .. tostring(why))
    ok(tostring(why):find(h, 1, true), 'and which hole: ' .. tostring(why))
    ok(tostring(why):find('force'), 'and offers the override: ' .. tostring(why))

    -- FORCE is the other route, and it works
    local forced = clones.family_adopt(narrowed, f.members[d.i], { force = true })
    ok(forced ~= nil, 'force overrides the premise explicitly')
    eq(2, #forced.values)
end)

--- THE RECOVERY LOOP END TO END: pin drops a member, opening the pin restores
--- the premise, and adoption brings it back. This is what `family_edit` had no
--- answer for before (CART-0896).
test('family_adopt: pin, open, adopt brings a dropped member back', function ()
    need_alg()
    local alg = require 'cartograph.algebra'
    local A = alg.load()
    local f = fam_edit_fixture()
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end
    local hs = {}
    for h in pairs(f.template.holes) do hs[#hs + 1] = h end
    table.sort(hs)
    local h = hs[1]

    local pinned = clones.family_edit(f, { edit = 'pin', h = h, value = f.values[1][h] })
    local d = pinned.dropped[1]
    ok(d ~= nil, 'a member was dropped')

    local opened = A.open_hole(pinned.template, h)
    ok(opened ~= nil, 'the pin re-opens')
    local fam = { members = { f.members[1] }, template = opened, values = { pinned.values[1] } }

    local r, why = clones.family_adopt(fam, f.members[d.i])
    ok(r ~= nil, 'the dropped member is adopted back: ' .. tostring(why))
    eq(2, #r.values)
    eq(false, r.adopted)        -- it had to WIDEN to take it back
    ok(r.widened > 0, 'and the widening is reported, not silent')
end)

test('family_adopt: payload shapes, and a refusal for anything else', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local f = fam_edit_fixture()
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end

    ok(clones.family_adopt(f, f.members[1]), 'a member record (.exprs) adopts')
    local a, w1 = clones.family_adopt(f, { nope = true })
    eq(nil, a); ok(tostring(w1):find('neither a member record'), tostring(w1))
    local b, w2 = clones.family_adopt(f, 'not a table')
    eq(nil, b); ok(tostring(w2):find('not a member record'), tostring(w2))
    local c, w3 = clones.family_adopt({ template = false }, f.members[1])
    eq(nil, c); ok(tostring(w3):find('not a family'), tostring(w3))
end)

-- ── the per-member verdict ──────────────────────────────────────────────────
--
-- USER: "refuse-whole is too coarse when interactive." The N-way prereqs are
-- the pair verb's applied to every member, and one failure sank the family.
-- MEASURED before building this: of the 22 families a refuse-whole plan rejects
-- on wow, 7 are "all but 1" — the biggest losing 25 of 26 extractions to one
-- member. This verb does not decide; it reports and lets the caller choose.

test('family_admissibility: a clean family is fully admissible, with a param count', function ()
    need_alg()
    local f = fam_edit_fixture()
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end
    local v, why = clones.family_admissibility(f, store)
    ok(v ~= nil, 'the verdict computes: ' .. tostring(why))
    eq(3, v.n)
    eq(3, v.n_admissible)
    eq(0, #v.refused)
    ok(v.params ~= nil, 'and the family has an agreed parameter count')
    ok(v.body ~= nil, 'the helper body renders')
    eq(false, v.xfile)
end)

--- ★★★ THE REFUSAL IS PER MEMBER, WITH ITS REASON AND — when it is a capture —
--- THE NAME. A name every member captures is a PARAMETER, not a blocker
--- (CART-0904), and reporting only `nested` hides exactly that.
test('family_admissibility: a nested member is refused BY NAME and names what it captures', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    proj { ['cb.lua'] = [[
local M = {}
local function outer(live)
    local function cb1(t)
        local acc = 0
        local seen = {}
        for i = 1, #t do acc = acc + t[i] * 1 end
        local s = tostring(acc)
        seen[s] = live
        local pad = string.rep("-", #s)
        return pad .. s
    end
    local function cb2(t)
        local acc = 0
        local seen = {}
        for i = 1, #t do acc = acc + t[i] * 2 end
        local s = tostring(acc)
        seen[s] = live
        local pad = string.rep("-", #s)
        return pad .. s
    end
    return cb1, cb2
end
M.outer = outer
return M
]] }
    local r = clones.families(store, {})
    if not r or #r.families == 0 then skip 'fixture yielded no family' end
    local f
    for _, x in ipairs(r.families) do if #x.members >= 2 and x.holes > 0 then f = x end end
    if not f then skip 'no multi-member family with holes' end

    local v = clones.family_admissibility(f, store)
    ok(v ~= nil, 'the verdict computes')
    ok(#v.refused > 0, 'the nested members are refused')
    for _, m in ipairs(v.refused) do
        ok(m.name and m.file, 'a refusal carries where it is')
        -- ⚠ A SPECIFIC reason. `ok(m.reason)` passes for the string "refused",
        -- and the mutation that replaced every reason with it survived.
        ok(tostring(m.reason):find('nested') or tostring(m.reason):find('parameter')
            or tostring(m.reason):find('vararg') or tostring(m.reason):find('recurs'),
            'and a reason that says WHICH gate: ' .. tostring(m.reason))
        if m.nested then
            ok(m.captures, 'a nested member names WHAT it captures: ' .. tostring(m.captures))
        end
    end
    -- ⚠ THE BODY GATE IS REPORTED SEPARATELY, and asserting "body or body_why"
    -- passes for a hardcoded body — that mutation survived. Inject a `row~` so
    -- the body genuinely cannot render, and require the REASON to come back.
    ok(v.body ~= nil, 'the body renders for this family')
    local kids = f.template.body.kids
    kids[#kids + 1] = { k = 'row~' }
    local v2 = clones.family_admissibility(f, store)
    kids[#kids] = nil
    ok(v2 ~= nil, 'the verdict still computes when the body cannot render')
    eq(nil, v2.body)
    ok(tostring(v2.body_why):find('row~'),
        'and the family-level gate says why: ' .. tostring(v2.body_why))
end)

--- ⚠ THE PARAMETER COUNT IS A MAJORITY, NOT MEMBER 1's. The pair verb compares
--- two and refuses on disagreement; with N there is a MODE, and taking the first
--- member's count makes the verdict depend on an ordering nobody chose.
--- ⚠ THE FIXTURE MUST PUT THE ODD MEMBER FIRST, or the test cannot tell a
--- majority from member 1's count. The first cut re-derived the majority from
--- the same data and asserted they matched — circular, and the mutation "take
--- member 1's count" survived it.
test('family_admissibility: the odd-arity member is refused, not the majority', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local function body(n, extra)
        return ([[
function M.a%s(t%s)
    local acc = 0
    local seen = {}
    for i = 1, #t do acc = acc + t[i] * %s end
    local s = tostring(acc)
    local u = string.upper(s)
    seen[u] = true
    local pad = string.rep("-", #u)
    return pad .. u
end
]]):format(n, extra, n)
    end
    -- member 1 takes TWO parameters; members 2 and 3 take one. The majority is 1.
    proj { ['arity.lua'] = 'local M = {}\n'
        .. body(1, ', extra') .. body(2, '') .. body(3, '') .. 'return M\n' }
    local r = clones.families(store, {})
    if not r or #r.families == 0 then skip 'fixture yielded no family' end
    local f
    for _, x in ipairs(r.families) do if #x.members >= 3 and x.holes > 0 then f = x end end
    if not f then skip 'no 3-member family with holes' end

    local v = clones.family_admissibility(f, store)
    ok(v ~= nil, 'the verdict computes')
    eq(1, v.params)
    ok(#v.refused >= 1, 'the odd-arity member is refused')
    local found
    for _, m in ipairs(v.refused) do
        if tostring(m.reason):find('parameter') then found = m end
    end
    ok(found ~= nil, 'and refused FOR its arity, naming both counts: '
        .. tostring(found and found.reason))
    ok(tostring(found.reason):find('2') and tostring(found.reason):find('1'),
        'the message carries the member count and the family count: ' .. tostring(found.reason))
end)

test('family_admissibility: family-level refusals come back as a reason, not a verdict', function ()
    need_alg()
    local f = fam_edit_fixture()
    if not f then skip 'no family' end
    local a, w1 = clones.family_admissibility({ members = { f.members[1] } }, store)
    eq(nil, a); ok(tostring(w1):find('one%-member'), tostring(w1))
    local b, w2 = clones.family_admissibility({ nope = true }, store)
    eq(nil, b); ok(tostring(w2):find('not a family'), tostring(w2))
end)

-- ── the capture lift (CART-0904) ────────────────────────────────────────────
--
-- A name every member captures is a PARAMETER, not a blocker: the family already
-- agrees on it, which is the same evidence a hole rests on. `hoistclosure`'s own
-- refusal says so — "parameterize it first (extract-helper)" — and the two verbs
-- are inverses. This is the side that can act.
--
-- ⚠ IT IS A SEPARATE VERDICT, NOT A PROMOTION: a lifted member is extractable
-- only if the captures become parameters, which changes the helper's signature.

local function nested_family(src)
    proj { ['nf.lua'] = src }
    local r = clones.families(store, {})
    if not r then return nil end
    for _, f in ipairs(r.families) do
        if #f.members >= 2 and f.holes > 0 then return f end
    end
end

test('family_admissibility: a uniformly captured set is LIFTABLE, and named', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local f = nested_family([[
local M = {}
local function outer(live, tag)
    local function cb1(t)
        local acc = 0
        local seen = {}
        for i = 1, #t do acc = acc + t[i] * 1 end
        local s = tostring(acc) .. tag
        seen[s] = live
        local pad = string.rep("-", #s)
        return pad .. s
    end
    local function cb2(t)
        local acc = 0
        local seen = {}
        for i = 1, #t do acc = acc + t[i] * 2 end
        local s = tostring(acc) .. tag
        seen[s] = live
        local pad = string.rep("-", #s)
        return pad .. s
    end
    return cb1, cb2
end
M.outer = outer
return M
]])
    if not f then skip 'fixture yielded no family' end
    local v = clones.family_admissibility(f, store)
    ok(v ~= nil, 'the verdict computes')

    -- ★ liftable, NOT admissible — the distinction is the point
    eq(0, v.n_admissible)
    ok(v.n_liftable >= 2, 'the nested members are liftable: ' .. tostring(v.n_liftable))
    ok(v.lifts ~= nil, 'and the lift names its parameters')
    local names = table.concat(v.lifts, ',')
    ok(names:find('live') and names:find('tag'),
        'BOTH captured names, not just the first: ' .. names)
    eq(nil, v.lift_why)
end)

--- ⚠ A WRITE CAPTURE IS NEVER LIFTED. Lua parameters are by VALUE, so a lifted
--- write updates a copy and the closure stops working. Measured on wow: 2 of 25
--- families with a nested member contain one.
test('family_admissibility: a WRITE capture refuses the lift by name', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local f = nested_family([[
local M = {}
local function outer()
    local count = 0
    local function cb1(t)
        local seen = {}
        local keep = {}
        count = count + 1
        local s = tostring(count) .. "1"
        seen[s] = true
        keep[#keep + 1] = s
        local u = string.upper(s)
        local pad = string.rep("-", #u)
        local low = string.lower(u)
        return pad .. u .. low
    end
    local function cb2(t)
        local seen = {}
        local keep = {}
        count = count + 2
        local s = tostring(count) .. "2"
        seen[s] = true
        keep[#keep + 1] = s
        local u = string.upper(s)
        local pad = string.rep("-", #u)
        local low = string.lower(u)
        return pad .. u .. low
    end
    return cb1, cb2
end
M.outer = outer
return M
]])
    if not f then skip 'fixture yielded no family' end
    local v = clones.family_admissibility(f, store)
    ok(v ~= nil, 'the verdict computes')
    eq(0, v.n_liftable)
    eq(nil, v.lifts)
    ok(tostring(v.lift_why):find('WRITES'), 'names the write: ' .. tostring(v.lift_why))
    ok(tostring(v.lift_why):find('count'), 'and which local: ' .. tostring(v.lift_why))
end)

--- ⚠ AND DIFFERENT SETS CANNOT SHARE ONE SIGNATURE. A member cannot pass a name
--- it does not have in scope. 5 of 25 on wow.
test('family_admissibility: members capturing DIFFERENT sets refuse the lift', function ()
    need_alg()
    if not ready() then return skip 'no lua parser' end
    local f = nested_family([[
local M = {}
local function outer(alpha, beta)
    local function cb1(t)
        local acc = 0
        local seen = {}
        for i = 1, #t do acc = acc + t[i] * 1 end
        local s = tostring(acc) .. alpha
        seen[s] = true
        local pad = string.rep("-", #s)
        return pad .. s
    end
    local function cb2(t)
        local acc = 0
        local seen = {}
        for i = 1, #t do acc = acc + t[i] * 2 end
        local s = tostring(acc) .. beta
        seen[s] = true
        local pad = string.rep("-", #s)
        return pad .. s
    end
    return cb1, cb2
end
M.outer = outer
return M
]])
    if not f then skip 'fixture yielded no family' end
    local v = clones.family_admissibility(f, store)
    ok(v ~= nil, 'the verdict computes')
    eq(0, v.n_liftable)
    eq(nil, v.lifts)
    ok(tostring(v.lift_why):find('different sets'),
        'names the disagreement: ' .. tostring(v.lift_why))
end)

-- ── classify / propagate: an edit on ONE member, clustered ──────────────────
--
-- ★★★ THE DESIGN SENTENCE IS THE USER'S (PROPAGATE.md): an edit lands on one
-- instance; whether the abstraction applies elsewhere is an OPERATOR DECISION;
-- the machinery clusters the impact and shows previews so the decisions are per
-- CLUSTER, not per member. So these tests assert the CLUSTERING and the KIND,
-- never that anything was written -- `propagate` writes nothing by construction
-- and hands back a commit closure instead.

local function fam_prop_text(n, mul, tail, upper)
    return ([[
function M.g%s(t)
    local acc = 0
    local seen = {}
    for i = 1, #t do acc = acc + t[i] * %s end
    local s = tostring(acc)
    local u = string.%s(s)
    seen[u] = true
    local pad = string.rep("-", #u)
    local out = pad .. u
    return out .. "%s"
end
]]):format(n, mul, upper or 'upper', tail)
end

test('family_propagate: an UNCHANGED member classifies as `none`', function ()
    need_alg()
    local f = fam_edit_fixture()
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end
    local r, why = clones.family_propagate(f, 1, fam_prop_text(1, 1, 1), store)
    ok(r ~= nil, 'classified: ' .. tostring(why))
    eq('none', r.kind)
    -- ⚠ AND `none` MUST NOT CARRY CLUSTERS. Reporting an empty cluster set reads
    -- as "nothing to propagate to", which is a different claim from "there is
    -- nothing to propagate".
    eq(nil, r.template)
    eq(nil, r.holes)
end)

test('family_propagate: a VALUE edit clusters the family by what each member holds', function ()
    need_alg()
    local f = fam_edit_fixture()
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end
    -- every site of the varying literal moves to the SAME new value: the store
    -- law holds, so this is a value edit and not a straddle
    local r, why = clones.family_propagate(f, 1, fam_prop_text(1, 9, 9), store)
    ok(r ~= nil, 'classified: ' .. tostring(why))
    ok(r.kind == 'value' or r.kind == 'mixed',
        'a value-only edit is `value` (or `mixed` if the name moved too): ' .. tostring(r.kind))
    ok(r.holes and #r.holes > 0, 'it names the changed hole(s)')
    local h = r.holes[1]
    ok(h.class ~= nil, 'and the VALUE CLASS -- who already held the old value')
    ok(h.others ~= nil, 'and the others, grouped by what they hold')
    -- the commit closure is carried OUT, not called: nothing is written here
    -- ⚠ A HOLE CARRIES A PREVIEW; THE COMMIT IS ONE AND SCOPED (member / class /
    -- all / a list). Asserting a per-hole commit is what showed that committing
    -- one hole for one member is not a decision the design offers.
    ok(type(h.preview) == 'function', 'each hole carries a preview')
    ok(type(r.commit.values) == 'function', 'and ONE scoped commit for the value part')

    -- ⚠ EACH EDIT'S HOLE COUNT IS THE CLAIM, not merely that holes exist: a
    -- one-hole edit must report ONE. The first cut read `P.holes` instead of
    -- `P.values.holes` and answered nil for all three -- "a value edit changed no
    -- holes", which is coherent-looking and impossible.
    local one = clones.family_propagate(f, 1, fam_prop_text(1, 9, 1), store)
    eq(1, #one.holes, 'an edit to ONE hole reports one')
    eq(2, #r.holes, 'and an edit to both reports two')
end)

test('family_propagate: a FIXED-part edit propagates by migrate, grouping refusals', function ()
    need_alg()
    local f = fam_edit_fixture()
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end
    -- `string.upper` -> `string.lower` is in the FIXED part: every hole is kept
    local r, why = clones.family_propagate(f, 1, fam_prop_text(1, 1, 1, 'lower'), store)
    ok(r ~= nil, 'classified: ' .. tostring(why))
    ok(r.kind == 'template' or r.kind == 'mixed', 'a fixed-part change: ' .. tostring(r.kind))
    ok(r.template ~= nil, 'the template part is present')
    ok(#r.template.clean > 0, 'members survive the migration')
    -- ★ REFUSALS ARE GROUPED BY REASON, which is the clustering the design is
    -- for: a list of N refusals is a list; three reasons over N members is a
    -- decision.
    for _, g in ipairs(r.template.refused or {}) do
        ok(g.why and g.members, 'each refusal group carries a reason and its members')
    end
    ok(type(r.commit.template) == 'function', 'and a commit closure, uncalled')
end)

test('family_propagate: unparseable text is a NAMED refusal, not a classification', function ()
    need_alg()
    local f = fam_edit_fixture()
    if not f then skip 'no family' end
    local r, why = clones.family_propagate(f, 1, 'function M.g1(t) return', store)
    eq(nil, r)
    ok(tostring(why):find('does not parse', 1, true), 'names the parse failure: ' .. tostring(why))
    local r2, why2 = clones.family_propagate(f, 99, fam_prop_text(1, 1, 1), store)
    eq(nil, r2)
    ok(tostring(why2):find('not in this family', 1, true), 'and a bad member index: ' .. tostring(why2))
end)

--- ★★★ THE STRADDLE, AND IT NEEDS A NON-LINEAR HOLE. An edit that crosses a hole
--- boundary cannot propagate: the abstraction has to move first. The only kind
--- that carries a PROPOSAL rather than a hint is the STORE-LAW straddle — one
--- site of a shared hole changed while its other sites did not — because only
--- that one converges (split the changed sites, migrate, classify again).
--- ⚠ A fixture with one site per hole cannot produce it, which is why the three
--- tests above never reached this branch: removing the early return left the
--- suite green because `propagate` guards the same case itself.
test('family_propagate: one site of a SHARED hole is a straddle with a proposal', function ()
    need_alg()
    -- the literal appears TWICE per member, so anti-unification gives ONE hole
    -- with TWO sites (Plotkin's rule: equal values in equal positions unify)
    -- ⚠ AND IT MUST BE LONG ENOUGH TO BE A FAMILY. The first cut had six rows
    -- and `families` returned nothing, so the test SKIPPED — a straddle test
    -- that never runs is the same as no test, and it announced itself only as a
    -- skip line nobody reads.
    local function two(n, s1, s2)
        return ([[
function M.h%s(t)
    local a = t[1] * %s
    local b = t[2] * %s
    local c = a + b
    local d = c * 2
    local e = d + 1
    local g = e * 3
    local h = g - 4
    local k = h + 5
    return k
end
]]):format(n, s1 or n, s2 or n)
    end
    proj { ['st.lua'] = 'local M = {}\n' .. two(1) .. two(2) .. two(3) .. 'return M\n' }
    local r = clones.families(store, {})
    local f = r and r.families[1]
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end

    -- change ONE of the two sites: the store law breaks
    local res, why = clones.family_propagate(f, 1, two(1, 9, 1), store)
    ok(res ~= nil, 'classified: ' .. tostring(why))
    eq('straddle', res.kind)
    -- ★ AND A STRADDLE CARRIES NO CLUSTERS, because there is nothing to propagate
    -- until the abstraction moves. Reporting an empty cluster set would read as
    -- "propagates to nobody", a different and wrong claim.
    eq(nil, res.template)
    eq(nil, res.holes)
    -- ★ THE STORE-LAW STRADDLE IS THE ONE THAT CARRIES A PROPOSAL, because it is
    -- the only one that converges. The others carry a HINT, which is weaker, and
    -- the prototype distinguishes them by name.
    ok(res.proposal ~= nil, 'it carries a PROPOSAL, not merely a hint')
    ok(tostring(res.why):find('store law', 1, true),
        'and names the law that broke: ' .. tostring(res.why))
end)

-- ── the virtual-step ladder ────────────────────────────────────────────────
--
-- ★★★ `family_edit` APPLIES ONE EDIT; `family_steps` FOLDS A LOG, and the state
-- AFTER EACH STEP is the thing a composition needs and nothing else produces.
-- These assert the LADDER: that rung k is computed against rung k-1, that the
-- surviving set only shrinks, and that a refusal stops the fold instead of
-- skipping a step.

test('family_steps: a two-edit log yields the state after EACH step', function ()
    need_alg()
    local f = fam_edit_fixture()
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end
    local tmpl = clones.family_template(f, store)
    local h = tmpl and tmpl.order[1]
    ok(h ~= nil, 'the family has a hole')

    -- pin, then open: down then back up, which the edit order allows
    local steps, why = clones.family_steps(f,
        { { op = 'pin', h = h, value = f.values[1][h] }, { op = 'open', h = h } })
    ok(steps ~= nil, 'the fold ran: ' .. tostring(why))
    eq(2, #steps)
    eq(1, steps[1].i)
    eq(2, steps[2].i)
    ok(steps[1].template ~= nil and steps[2].template ~= nil, 'each rung carries a template')

    -- ★ RUNG 2 IS COMPUTED AGAINST RUNG 1, not against the family. A pin drops
    -- every member holding another value; re-opening cannot bring them back
    -- ("adoption is a match, not a migration"), so the survivors only shrink.
    ok(#steps[2].kept <= #steps[1].kept, 'the surviving set never grows')
    ok(#steps[1].kept < #f.members, 'and the pin really did drop somebody')
end)

test('family_steps: a REFUSED step is a rung, and it stops the fold', function ()
    need_alg()
    local f = fam_edit_fixture()
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end
    local h = (clones.family_template(f, store) or {}).order[1]
    local steps = assert(clones.family_steps(f, {
        { op = 'pin', h = h, value = f.values[1][h] },
        { op = 'nonsuch', h = h },                      -- replay_edit refuses
        { op = 'open', h = h },                         -- must NOT be reached
    }))
    eq(2, #steps, 'the ladder stops at the refusal')
    eq(true, steps[2].refused)
    ok(tostring(steps[2].why):find('nonsuch', 1, true), 'naming the op: ' .. tostring(steps[2].why))
    eq(nil, steps[2].template, 'a refused rung carries no state')
    -- ⚠ AND THE RUNGS BEFORE IT STAND. Discarding them would lose a real result
    -- because a later step failed.
    ok(steps[1].template ~= nil, 'the rungs before the refusal are kept')
end)

test('family_steps: the inputs are NOT mutated — nothing is written', function ()
    need_alg()
    local f = fam_edit_fixture()
    if not f or f.holes == 0 then skip 'fixture yielded no family with holes' end
    local h = (clones.family_template(f, store) or {}).order[1]
    local before_holes, before_members = f.holes, #f.members
    local before_edits = #(f.template.edits or {})
    assert(clones.family_steps(f, { { op = 'pin', h = h, value = f.values[1][h] } }))
    eq(before_holes, f.holes)
    eq(before_members, #f.members)
    -- ★ THE LOG IS THE TELL: every edit APPENDS to `T.edits`, so a fold that
    -- mutated the family's own template would show up here and nowhere else.
    eq(before_edits, #(f.template.edits or {}))
end)

test('family_steps: a malformed log is a named refusal, not a partial ladder', function ()
    need_alg()
    local f = fam_edit_fixture()
    if not f then skip 'no family' end
    local s1, w1 = clones.family_steps(f, {})
    eq(nil, s1); ok(tostring(w1):find('no edits', 1, true), tostring(w1))
    local s2, w2 = clones.family_steps(f, { { h = 'h1' } })   -- no `op` field
    eq(nil, s2)
    ok(tostring(w2):find('not a recorded edit', 1, true), tostring(w2))
end)
