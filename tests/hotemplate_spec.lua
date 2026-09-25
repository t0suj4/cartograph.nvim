-- CART-0698 / the hoau absorption. A HIGHER-ORDER template: every hole carries
-- the locals it is computed from, so the result names a helper SIGNATURE — how
-- many VALUE parameters and how many FUNCTION parameters — instead of a hole
-- count. These specs weigh toward the distinction that is new (a dependent hole
-- is NOT a value parameter) and toward the refusals, because a refusal here is
-- an answer about the pair and every one of them is a promise.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'
local ho = require 'cartograph.hotemplate'
local T = require 'cartograph.templates'

local function ready()
    return pcall(vim.treesitter.language.add, 'lua')
end

local function proj(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for name, src in pairs(files) do
        local fd = assert(io.open(root .. '/' .. name, 'w')); fd:write(src); fd:close()
    end
    store.ingest(ts.extract(root))
    return root
end
local function fn_id(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end
local NEAR = { max_dist = 2, min_rows = 4, min_shared = 3 }
local function pair_of(name) return clones.near_of(store, fn_id(name), NEAR)[1] end

local function holes_of(t, kind)
    local out = {}
    for _, h in ipairs(t.holes) do if h.kind == kind then out[#out + 1] = h end end
    return out
end

-- two bodies differing only in a LITERAL: the hole depends on nothing, so it is
-- a value the caller can supply
local VALUE_PAIR = 'local M = {}\n\nlocal function fmt_a(x)\n  local y = prep(x)\n'
    .. '  local z = norm(y)\n  local w = encode(z, \'json\')\n  local o = wrap(w)\n  return o\nend\n\n'
    .. 'local function fmt_b(a)\n  local b = prep(a)\n  local c = norm(b)\n'
    .. '  local d = encode(c, \'yaml\')\n  local e = wrap(d)\n  return e\nend\n\nreturn M\n'

-- ★ the case the first-order reading cannot state: the differing subterm is an
-- expression over the function's OWN local `y`, so it is not a value at all
local DEP_PAIR = 'local M = {}\n\nlocal function alpha(x)\n  local y = prep(x)\n'
    .. '  local z = norm(y)\n  local w = wrap(y)\n  local o = fin(w)\n  return o\nend\n\n'
    .. 'local function beta(x)\n  local y = prep(x)\n  local z = norm(y)\n'
    .. '  local w = wrap(y, true)\n  local o = fin(w)\n  return o\nend\n\nreturn M\n'

test('higher-order template: a literal difference is a VALUE parameter', function ()
    if not ready() then return end
    proj { ['m.lua'] = VALUE_PAIR }
    local p = pair_of('fmt_a')
    ok(p, 'the value fixture is a near pair')
    if not p then return end
    local t, why = ho.of_pair(store, p)
    ok(t, 'a value pair has a higher-order template: ' .. tostring(why))
    if not t then return end
    ok(t.signature.value >= 1, 'at least one value parameter')
    eq(0, t.signature.fn)
    eq(0, #holes_of(t, 'dep'))
    -- ⚠ ASSERTED, NOT ASSUMED: the law is what tells an encoder bug from an
    -- algebra bug, and a template that does not rebuild describes nothing.
    ok(t.rebuild, 'the template rebuilds both sides')
    ok(t.pattern, 'the lgg is a higher-order pattern')
end)

test('higher-order template: a difference OVER A LOCAL is a FUNCTION parameter', function ()
    if not ready() then return end
    proj { ['m.lua'] = DEP_PAIR }
    local p = pair_of('alpha')
    ok(p, 'the dependent fixture is a near pair')
    if not p then return end
    local t, why = ho.of_pair(store, p)
    ok(t, 'a dependent pair has a higher-order template: ' .. tostring(why))
    if not t then return end
    -- ★★★ THE WHOLE POINT OF THE ABSORPTION IN ONE ASSERTION. `wrap(y)` against
    -- `wrap(y, true)` differs in a term that MENTIONS the body-local `y`; a
    -- value parameter cannot carry it, because the call site has no `y`.
    ok(t.signature.fn >= 1, 'at least one function parameter')
    local deps = holes_of(t, 'dep')
    ok(#deps >= 1, 'at least one dependent hole')
    local names = {}
    for _, h in ipairs(deps) do for _, y in ipairs(h.ys) do names[y] = true end end
    ok(names['y'], 'the dependency is named, and it is the body-local `y`')
    ok(t.rebuild, 'the template rebuilds both sides')
end)

test('higher-order template: the signature reads as a helper signature', function ()
    if not ready() then return end
    proj { ['m.lua'] = DEP_PAIR }
    local p = pair_of('alpha')
    if not p then return end
    local t = ho.of_pair(store, p)
    if not t then return end
    ok(ho.signature_text(t):match('function param'), 'the text names function parameters')
    ok(ho.signature_text(t):match('arities'), 'and their arities')
end)

-- ── the refusals. Each one is a promise; each is reached by construction ────

test('higher-order template: refuses without a store, BY NAME', function ()
    if not ready() then return end
    proj { ['m.lua'] = VALUE_PAIR }
    local p = pair_of('fmt_a')
    if not p then return end
    local t, why = ho.of_pair(nil, p)
    eq(nil, t)
    -- ⚠ THE REASON MATTERS MORE THAN THE REFUSAL: without `expr.of` neither side
    -- has binders, every hole reads CLOSED, and the answer is a confident
    -- "all value parameters" that is wrong.
    ok(why and why:match('store is required'), 'it says a store is required: ' .. tostring(why))
    ok(why and why:match('closed'), 'and why that matters: ' .. tostring(why))
end)

test('higher-order template: refuses a non-pair BY NAME', function ()
    if not ready() then return end
    proj { ['m.lua'] = VALUE_PAIR }
    local t, why = ho.of_pair(store, {})
    eq(nil, t)
    ok(why and why:match('not a near pair'), tostring(why))
end)

test('higher-order template: refuses a pair with NO ALIGNED ROWS, by name', function ()
    if not ready() then return end
    proj { ['m.lua'] = VALUE_PAIR }
    local p = pair_of('fmt_a')
    if not p then return end
    -- ★ CONSTRUCTED FROM THE GUARD'S NEGATION (CART-0990's discipline): keep the
    -- real sides and replace the ops with insertions only, which is a real state
    -- — two functions can be near neighbours entirely through ins/del.
    local ins = { a = p.a, b = p.b, ops = { { op = 'ins', i = 1, j = 1 } } }
    local t, why = ho.of_pair(store, ins)
    eq(nil, t)
    ok(why and why:match('no aligned rows'), tostring(why))
end)

-- ── identity: the template becomes a thing you can hold ─────────────────────

test('higher-order template: records, and the stored body is NOT hollow', function ()
    if not ready() then return end
    proj { ['m.lua'] = DEP_PAIR }
    local p = pair_of('alpha')
    if not p then return end
    local t = ho.of_pair(store, p)
    if not t then return end
    local st = { generation = 1 }
    local id, err = T.record(st, 'higher_order', t, { why = 'spec' })
    ok(id, 'the shape is registered: ' .. tostring(err))
    if not id then return end
    local body = T.body(st, id)
    ok(body, 'the handle resolves')
    -- ⚠ `copy_body` IS A WHITELIST. A shape whose fields it does not name comes
    -- back EMPTY and `record` still succeeds — a uniform zero that reads like a
    -- clean answer. This asserts the fields survived the copy.
    ok(body.signature, 'the signature survived copy_body')
    eq(t.signature.fn, body.signature.fn)
    ok(body.holes and #body.holes > 0, 'the holes survived copy_body')
    ok(body.result, 'the lgg term survived copy_body')
    local rows = T.list(st)
    eq(1, #rows)
    -- and `M.list` counts them, rather than reporting the `varying`-map zero
    ok(rows[1].holes > 0, 'list reports the hole count, not a degenerate zero')
end)

test('higher-order template: is declared NOT matchable, and apply says why', function ()
    if not ready() then return end
    eq(false, T.SHAPES.higher_order.matchable)
    proj { ['m.lua'] = DEP_PAIR }
    local p = pair_of('alpha')
    if not p then return end
    local t = ho.of_pair(store, p)
    if not t then return end
    local st = { generation = 1 }
    local id = T.record(st, 'higher_order', t, { why = 'spec' })
    if not id then return end
    local r, why = T.apply(st, id, {})
    eq(nil, r)
    -- the vocabulary gap is the REASON, not "unsupported": `match` binds values
    ok(why and why:match('dependent hole'), tostring(why))
end)

-- ★★★ THE GUARD THE PROTOTYPE CENSUS FOUND, AND ITS OWN TEST.
-- `ho_loop_binders` takes a ROW, not an expression. Handing the row straight to
-- `expr.walk` (which dispatches on `.k`, and a row has none) traverses nothing
-- and returns an empty list WITHOUT ERRORING — so a loop variable never joins
-- `locals`, encodes as a free name, and the hole over it reads CLOSED. A value
-- parameter where a function parameter was needed, and the answer stays
-- well-formed the whole way. It was caught by joining against an independently
-- written encoder, not by the suite; this is the test the suite was missing.
local LOOP_PAIR = 'local M = {}\n\nlocal function loop_a(xs)\n  local acc = {}\n'
    .. '  for i, v in ipairs(xs) do\n    acc[i] = norm(v)\n  end\n  local o = fin(acc)\n  return o\nend\n\n'
    .. 'local function loop_b(ys)\n  local acc = {}\n  for i, v in ipairs(ys) do\n'
    .. '    acc[i] = norm(v, true)\n  end\n  local o = fin(acc)\n  return o\nend\n\nreturn M\n'

test('higher-order template: a LOOP BINDER is a binder, so a hole over it depends on it', function ()
    if not ready() then return end
    proj { ['m.lua'] = LOOP_PAIR }
    local p = pair_of('loop_a')
    ok(p, 'the loop fixture is a near pair')
    if not p then return end
    local t, why = ho.of_pair(store, p)
    ok(t, 'a loop pair has a higher-order template: ' .. tostring(why))
    if not t then return end
    local names = {}
    for _, h in ipairs(t.holes) do
        if h.kind ~= 'closed' and h.kind ~= 'rename' then
            for _, y in ipairs(h.ys) do names[y] = true end
        end
    end
    ok(names['v'], 'the loop variable `v` is named as a dependency, not lost to a free name')
    ok(t.signature.fn >= 1, 'so the helper needs a function parameter')
end)

test('higher-order template: refuses when the algebra is disabled, and says so', function ()
    if not ready() then return end
    proj { ['m.lua'] = VALUE_PAIR }
    local p = pair_of('fmt_a')
    if not p then return end
    -- the house way of exercising an `unavailable` rung: `algebra.load` re-reads
    -- this setting on every call precisely so the refusal stays testable in a
    -- process that has already loaded the algebra.
    local cfg = require 'cartograph.config'
    local was = cfg.algebra
    cfg.algebra = false
    local t, why = ho.of_pair(store, p)
    cfg.algebra = was
    eq(nil, t)
    ok(why and why:match('algebra is unavailable'), tostring(why))
end)
