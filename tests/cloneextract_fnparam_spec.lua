-- CART-0878: a divergence that reads the body's own locals becomes a FUNCTION
-- parameter. The helper applies it to the locals IT holds; each call site passes a
-- closure over its own version.
--
-- ★ WHY THIS IS SOUNDER THAN VALUE LIFTING, NOT LOOSER: lifting an expression to an
-- argument makes it run ALWAYS and run AT THE CALL, which is why the value path must
-- ask `guarded` and `moves`. A closure is not evaluated when it is passed — the
-- expression runs where it ran, as often as it ran.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'
local cx = require 'cartograph.cloneextract'

local function ready(lang)
    return pcall(vim.treesitter.language.add, lang)
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
-- every line the plan WRITES, in one blob — what the assertions read.
local function text(plan)
    local out = {}
    for _, fe in pairs(plan.files or {}) do
        for _, op in ipairs(fe.ops or {}) do
            for _, l in ipairs(op.new or {}) do out[#out + 1] = l end
        end
    end
    for _, l in ipairs((plan.create or {}).lines or {}) do out[#out + 1] = l end
    return table.concat(out, '\n')
end
-- the file as it would be AFTER, through the plan's own edit function
local function after_text(root, plan)
    local rel = next(plan.files or {})
    if not rel then return nil end
    local fd = io.open(root .. '/' .. rel, 'r')
    if not fd then return nil end
    local before = fd:read('*a'); fd:close()
    return cx.edits_for(plan)(rel, before)
end

-- the `at`-accessor seam, in miniature: one side reads a field, the other calls an
-- accessor on the same local. This is the shape CART-0876 measured on our own tree
-- (`c.line` against `callrec.line(c)`, one parameter at eight sites).
local ACCESSOR = 'local M = {}\n\n'
    .. 'local function span_a(node)\n  local lo = node.start\n  local hi = lo + 4\n'
    .. '  local mid = node.line\n  local out = { lo, hi, mid }\n  return out\nend\n\n'
    .. 'local function span_b(node)\n  local lo = node.start\n  local hi = lo + 4\n'
    .. '  local mid = rec.line(node)\n  local out = { lo, hi, mid }\n  return out\nend\n\n'
    .. 'return M\n'

test('fn-param: a divergence over a PARAMETER becomes a function parameter', function ()
    if not ready('lua') then return end
    proj { ['m.lua'] = ACCESSOR }
    local p = pair_of('span_a')
    ok(p, 'the accessor fixture is a near pair')
    if not p then return end
    local plan, why = cx.plan(store, p)
    ok(plan, 'it plans: ' .. tostring(why))
    if not plan then return end
    eq(1, plan.nfparams)
    local t = text(plan)
    -- the helper takes the closure and APPLIES it to the local it holds
    ok(t:match('fp1'), 'the helper binds a function parameter:\n' .. t)
    ok(t:match('fp1%(node%)'), 'and applies it to `node`:\n' .. t)
    -- each call site passes ITS OWN version
    ok(t:match('function %(node%) return node%.line end'), 'copy A passes its field read:\n' .. t)
    ok(t:match('function %(node%) return rec%.line%(node%) end'), 'copy B passes its accessor:\n' .. t)
end)

test('fn-param: the synthesized file PARSES, closures and all', function ()
    if not ready('lua') then return end
    local root = proj { ['m.lua'] = ACCESSOR }
    local p = pair_of('span_a')
    if not p then return end
    local plan = cx.plan(store, p)
    ok(plan, 'the accessor pair plans')
    if not plan then return end
    eq(1, plan.nfparams)
    local src = after_text(root, plan)
    ok(type(src) == 'string' and #src > 0, 'an after-text to parse')
    if type(src) ~= 'string' then return end
    -- ⚠ ASSERT THE FIXTURE REACHED THE THING UNDER TEST. A parse check on text that
    -- happens not to contain a closure is a test of nothing.
    ok(src:match('function %(node%)'), 'the after-text contains a closure argument')
    local tree = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]
    eq(false, tree:root():has_error())
end)

test('fn-param: a hole reading a BODY LOCAL is admitted — the helper holds it', function ()
    if not ready('lua') then return end
    -- ⚠ THE FIRST CUT OF THE GATE REFUSED THIS, reasoning that the call site must be
    -- able to name the argument. That is the VALUE parameter's question: the call site
    -- never names it, the helper does, and the closure binds it.
    proj { ['m.lua'] = 'local M = {}\n\n'
        .. 'local function kind_a(n)\n  local t = n.type\n  local base = t.name\n'
        .. '  local flag = base.lower\n  local out = { t, base, flag }\n  return out\nend\n\n'
        .. 'local function kind_b(n)\n  local t = n.type\n  local base = t.name\n'
        .. '  local flag = lower(base)\n  local out = { t, base, flag }\n  return out\nend\n\n'
        .. 'return M\n' }
    local p = pair_of('kind_a')
    ok(p, 'the body-local fixture is a near pair')
    if not p then return end
    local plan, why = cx.plan(store, p)
    ok(plan, 'a body-local dependency plans: ' .. tostring(why))
    if not plan then return end
    eq(1, plan.nfparams)
    local t = text(plan)
    ok(t:match('fp1%(base%)'), 'the helper applies it to the body local `base`:\n' .. t)
    ok(t:match('function %(base%) return base%.lower end'), 'copy A closes over nothing:\n' .. t)
end)

test('fn-param: the claim records that a closure does NOT widen the review radius', function ()
    if not ready('lua') then return end
    proj { ['m.lua'] = ACCESSOR }
    local p = pair_of('span_a')
    if not p then return end
    local plan = cx.plan(store, p)
    if not plan then return end
    ok(plan.preserves_why:match('not evaluated at the call'),
        'the reason names the mechanism: ' .. tostring(plan.preserves_why))
end)

-- ── the refusals, each reached by construction ──────────────────────────────

test('fn-param: refuses a divergence that depends on NO local — that is a value', function ()
    if not ready('lua') then return end
    -- both sides read `cfg`, a GLOBAL, so `local_deps` finds no dependency at all.
    -- A closure over nothing is a value with extra steps, and the value pass is where
    -- it belongs — so this refuses rather than synthesizing `function () return X end`.
    proj { ['m.lua'] = 'local M = {}\n\n'
        .. 'local function opt_a(n)\n  local t = n.type\n  local s = t.size\n'
        .. '  local v = cfg.mode\n  local out = { t, s, v }\n  return out\nend\n\n'
        .. 'local function opt_b(n)\n  local t = n.type\n  local s = t.size\n'
        .. '  local v = mode(cfg)\n  local out = { t, s, v }\n  return out\nend\n\n'
        .. 'return M\n' }
    local p = pair_of('opt_a')
    ok(p, 'the global-divergence fixture is a near pair')
    if not p then return end
    local plan, why = cx.plan(store, p)
    eq(nil, plan)
    ok(why:match('depends on no local'), tostring(why))
end)

test('fn-param: refuses a divergence that spans multiple lines, by name', function ()
    if not ready('lua') then return end
    proj { ['m.lua'] = 'local M = {}\n\n'
        .. 'local function msg_a(n)\n  local t = n.type\n  local s = t.size\n'
        .. '  local v = fmt(\n    t.name)\n  local out = { t, s, v }\n  return out\nend\n\n'
        .. 'local function msg_b(n)\n  local t = n.type\n  local s = t.size\n'
        .. '  local v = t.name\n  local out = { t, s, v }\n  return out\nend\n\n'
        .. 'return M\n' }
    local p = pair_of('msg_a')
    ok(p, 'the multi-line fixture is a near pair')
    if not p then return end
    local plan, why = cx.plan(store, p)
    eq(nil, plan)
    ok(why:match('spans multiple lines'), tostring(why))
end)

test('fn-param: refuses above the arity CEILING, and the message names the ceiling', function ()
    if not ready('lua') then return end
    -- ⚠ A CEILING, NOT A LAW — so the refusal has to say what the number is, or a
    -- reader cannot tell a limit from an impossibility.
    proj { ['m.lua'] = 'local M = {}\n\n'
        .. 'local function two_a(n, k)\n  local t = n.type\n  local s = t.size\n'
        .. '  local v = pick(t, k)\n  local out = { t, s, v }\n  return out\nend\n\n'
        .. 'local function two_b(n, k)\n  local t = n.type\n  local s = t.size\n'
        .. '  local v = other(k, t, 1)\n  local out = { t, s, v }\n  return out\nend\n\n'
        .. 'return M\n' }
    local p = pair_of('two_a')
    ok(p, 'the arity-2 fixture is a near pair')
    if not p then return end
    local plan, why = cx.plan(store, p)
    eq(nil, plan)
    ok(why:match('is a function of 2 locals'), tostring(why))
    ok(why:match('most this verb will synthesize'), 'and it names the ceiling: ' .. tostring(why))
end)

test('fn-param: ONE parameter, EVERY site — each applied to its own arguments', function ()
    if not ready('lua') then return end
    -- ★★★ THE SOUNDNESS PROPERTY Mer-S BUYS AND COULD SILENTLY LOSE. The merge exists
    -- because `key_range` is one accessor migration at EIGHT sites; substituting only
    -- the first would leave seven divergences reading copy A's expression while copy B
    -- passed copy B's closure. The value holes' own comment has warned about this since
    -- they were written — "a single-site dedup would leave later occurrences
    -- un-parameterized — unsound" — and the function parameters had no `ranges` list at
    -- all until this rung, only the FIRST occurrence's node kept for display.
    local root = proj { ['m.lua'] = 'local M = {}\n\n'
        .. 'local function pos_a(node)\n  local base = node.start\n  local w = base + 2\n'
        .. '  local lo = node.line\n  local s = lo + 1\n  local hi = node.line\n'
        .. '  local out = { base, w, lo, s, hi }\n  return out\nend\n\n'
        .. 'local function pos_b(node)\n  local base = node.start\n  local w = base + 2\n'
        .. '  local lo = rec.line(node)\n  local s = lo + 1\n  local hi = rec.line(node)\n'
        .. '  local out = { base, w, lo, s, hi }\n  return out\nend\n\n'
        .. 'return M\n' }
    local p = pair_of('pos_a')
    ok(p, 'the two-site fixture is a near pair')
    if not p then return end
    local plan, why = cx.plan(store, p)
    ok(plan, 'it plans: ' .. tostring(why))
    if not plan then return end
    eq(1, plan.nfparams)        -- ONE parameter…
    local src = after_text(root, plan)
    ok(type(src) == 'string', 'an after-text')
    if type(src) ~= 'string' then return end
    local n = select(2, src:gsub('fp1%(node%)', ''))
    eq(2, n)                    -- …applied at BOTH sites
    -- and exactly one closure per call site, not one per site
    eq(1, select(2, src:gsub('function %(node%) return node%.line end', '')))
    eq(1, select(2, src:gsub('function %(node%) return rec%.line%(node%) end', '')))
    eq(false, vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root():has_error())
end)
