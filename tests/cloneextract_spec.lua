-- The verified extract-helper transaction ([[cartograph-record-fold-arc]] prereq #4):
-- factor a value-parameterizable, same-file, body-safe near-clone pair into a shared
-- parameterized helper, with the txn contract + a parses-clean synthesis gate. These
-- tests exercise the happy path (correct synthesis, actually written & parsing) and the
-- refusal gates (the sound subset's constraints).

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'
local cx = require 'cartograph.cloneextract'

-- make a tree-sitter grammar available (JS is not built in); skip a test if absent
local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
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
local function pair_of(name)
    return clones.near_of(store, fn_id(name), NEAR)[1]
end
-- the cross-file fixtures are smaller (4-stmt bodies, one differing) — a looser gate
local function xpair(name)
    return clones.near_of(store, fn_id(name), { max_dist = 2, min_rows = 3, min_shared = 2 })[1]
end

test('extract-helper: a same-file value pair synthesizes a correct helper + wrappers', function ()
    local root = proj { ['m.lua'] =
        'local M = {}\n\nlocal function fmt_a(x)\n  local y = prep(x)\n  local z = norm(y)\n'
        .. '  local w = encode(z, \'json\')\n  local o = wrap(w)\n  return o\nend\n\n'
        .. 'local function fmt_b(a)\n  local b = prep(a)\n  local c = norm(b)\n'
        .. '  local d = encode(c, \'yaml\')\n  local e = wrap(d)\n  return e\nend\n\nreturn M\n' }
    local plan, why = cx.plan(store, pair_of('fmt_a'))
    ok(plan, 'a same-file value pair plans: ' .. tostring(why))
    if plan then
        local _, after = cx.preview(store, plan)
        local text = after[plan.a.file]
        -- the shared body moved into the helper with the literal lifted to a parameter
        ok(text:find('local function ' .. plan.helper .. '(x, hp1)', 1, true),
            'helper signature carries the original param + the hole param')
        ok(text:find('encode(z, hp1)', 1, true), 'the hole is parameterized in the helper body')
        -- both copies became tail-call wrappers passing their own filling
        ok(text:find(('return %s(x, \'json\')'):format(plan.helper), 1, true), 'fmt_a passes its filling')
        ok(text:find(('return %s(a, \'yaml\')'):format(plan.helper), 1, true), 'fmt_b passes its filling')
        -- and it parses
        local pr = vim.treesitter.get_string_parser(text, 'lua'):parse()[1]:root()
        ok(not pr:has_error(), 'the synthesized file parses clean')
    end
    vim.fn.delete(root, 'rf')
end)

test('extract-helper: a leaf recurring twice is parameterized at BOTH sites', function ()
    local root = proj { ['m.lua'] =
        'local M = {}\n\nlocal function g_a(x)\n  local a = start(x)\n  local b = tag(a, \'red\')\n'
        .. '  local c = mix(b)\n  local d = paint(c, \'red\')\n  local e = wrap(d)\n  return e\nend\n\n'
        .. 'local function g_b(y)\n  local a = start(y)\n  local b = tag(a, \'blue\')\n'
        .. '  local c = mix(b)\n  local d = paint(c, \'blue\')\n  local e = wrap(d)\n  return e\nend\n\nreturn M\n' }
    local plan = cx.plan(store, pair_of('g_a'))
    ok(plan, 'the multi-occurrence pair plans')
    if plan then
        local _, after = cx.preview(store, plan)
        local text = after[plan.a.file]
        -- both 'red' occurrences in g_a's body became hp1 (no bare 'red' left in the helper)
        local helper_body = text:match('local function ' .. plan.helper .. '.-\nend')
        ok(helper_body and helper_body:find('tag(a, hp1)', 1, true)
            and helper_body:find('paint(c, hp1)', 1, true),
            'both sites of the recurring leaf are parameterized')
        ok(helper_body and not helper_body:find('\'red\'', 1, true),
            'no un-parameterized occurrence remains')
        ok(text:find(('return %s(x, \'red\')'):format(plan.helper), 1, true),
            'the wrapper passes the filling once')
    end
    vim.fn.delete(root, 'rf')
end)

test('extract-helper: the write is journaled, parses, and both wrappers call the helper', function ()
    local root = proj { ['m.lua'] =
        'local M = {}\n\nlocal function fmt_a(x)\n  local y = prep(x)\n  local z = norm(y)\n'
        .. '  local w = encode(z, \'json\')\n  local o = wrap(w)\n  return o\nend\n\n'
        .. 'local function fmt_b(a)\n  local b = prep(a)\n  local c = norm(b)\n'
        .. '  local d = encode(c, \'yaml\')\n  local e = wrap(d)\n  return e\nend\n\nreturn M\n' }
    local plan = cx.plan(store, pair_of('fmt_a'))
    ok(plan, 'planned')
    if plan then
        store.set_txn(plan)
        local entry, why = cx.apply(store, plan)
        ok(entry, 'apply succeeds: ' .. tostring(why))
        local written = table.concat(vim.fn.readfile(root .. '/m.lua'), '\n')
        ok(written:find('local function ' .. plan.helper .. '(', 1, true), 'helper written to disk')
        eq(3, select(2, written:gsub(plan.helper .. '%(', '')), 'helper appears 3× (1 def + 2 calls)')
        local pr = vim.treesitter.get_string_parser(written, 'lua'):parse()[1]:root()
        ok(not pr:has_error(), 'the written file parses clean')
    end
    vim.fn.delete(root, 'rf')
end)

-- ── refusal gates (the sound subset) ─────────────────────────────────────────

test('extract-helper: a structural pair (inserted statement) is refused', function ()
    local root = proj { ['m.lua'] =
        'local M = {}\n\nlocal function p_a(x)\n  local y = prep(x)\n  local z = norm(y)\n'
        .. '  local w = wrap(z)\n  return w\nend\n\n'
        .. 'local function p_b(a)\n  local b = prep(a)\n  local c = norm(b)\n  validate(c)\n'
        .. '  local d = wrap(c)\n  return d\nend\n\nreturn M\n' }
    local pair = pair_of('p_a')
    if pair then
        local plan, why = cx.plan(store, pair)
        ok(not plan and why:find('value%-parameterizable'), 'a structural pair is refused')
    else ok(true, '(no pair — fine)') end
    vim.fn.delete(root, 'rf')
end)

-- ── cross-file extraction (new shared module + require wiring) ───────────────

local CF_A = 'local function find(x)\n  local base = cfg().alpha\n  local h = home(base)\n'
    .. '  local p = join(h, x)\n  return exists(p)\nend\nreturn find\n'
local CF_B = 'local function find(x)\n  local base = cfg().beta\n  local h = home(base)\n'
    .. '  local p = join(h, x)\n  return exists(p)\nend\nreturn find\n'

test('extract-helper: a cross-file pair extracts into a NEW shared module + requires', function ()
    local root = proj { ['a.lua'] = CF_A, ['b.lua'] = CF_B }
    local plan, why = cx.plan(store, xpair('find'), { dest = 'shared.lua' })
    ok(plan, 'cross-file plans with a dest: ' .. tostring(why))
    if plan then
        ok(plan.xfile and plan.create and plan.create.file == 'shared.lua', 'a new module is created')
        eq(3, #plan.touched, 'touches both callers + the new module')
        local _, after = cx.preview(store, plan)
        -- the module holds the shared body as a member, the field lifted to hp1
        local mod = after['shared.lua']
        ok(mod:find('function M.' .. plan.helper .. '(x, hp1)', 1, true), 'helper is a module member')
        ok(mod:find('local base = hp1', 1, true), 'the differing leaf became the parameter')
        ok(mod:find('return M', 1, true), 'the module returns its table')
        -- both callers require it and delegate their own filling
        for _, side in ipairs({ { f = 'a.lua', fill = 'alpha' }, { f = 'b.lua', fill = 'beta' } }) do
            ok(after[side.f]:find("require 'shared'", 1, true), side.f .. ' gains the require')
            ok(after[side.f]:find(('return %s(x, cfg().%s)'):format(plan.helper_call, side.fill), 1, true),
                side.f .. ' delegates with its filling')
        end
        -- the require-path guess rides as a hazard (honest)
        ok(#plan.hazards >= 1 and plan.hazards[1]:find('require path'), 'the require path is flagged to verify')
    end
    vim.fn.delete(root, 'rf')
end)

test('extract-helper: cross-file apply writes all three files, each parsing', function ()
    local root = proj { ['a.lua'] = CF_A, ['b.lua'] = CF_B }
    local plan = cx.plan(store, xpair('find'), { dest = 'shared.lua' })
    ok(plan, 'planned')
    if plan then
        store.set_txn(plan)
        local entry, why = cx.apply(store, plan)
        ok(entry, 'cross-file apply succeeds: ' .. tostring(why))
        for _, f in ipairs({ 'shared.lua', 'a.lua', 'b.lua' }) do
            local t = table.concat(vim.fn.readfile(root .. '/' .. f), '\n')
            local pr = vim.treesitter.get_string_parser(t, 'lua'):parse()[1]:root()
            ok(not pr:has_error(), f .. ' parses clean after the write')
        end
    end
    vim.fn.delete(root, 'rf')
end)

test('extract-helper: cross-file is refused when a body reads a file-local', function ()
    -- `find` reads `helper` which is a top-level local of a.lua → not movable cross-file
    local root = proj {
        ['a.lua'] = 'local function helper(z) return z end\n'
            .. 'local function find(x)\n  local base = cfg().alpha\n  local h = helper(base)\n'
            .. '  local p = join(h, x)\n  return exists(p)\nend\nreturn find\n',
        ['b.lua'] = 'local function helper(z) return z end\n'
            .. 'local function find(x)\n  local base = cfg().beta\n  local h = helper(base)\n'
            .. '  local p = join(h, x)\n  return exists(p)\nend\nreturn find\n',
    }
    local pair = xpair('find')
    if pair then
        local plan, why = cx.plan(store, pair, { dest = 'shared.lua' })
        ok(not plan and why:find('file%-local'), 'a file-local dependency blocks the cross-file move')
    else ok(true, '(no pair — fine)') end
    vim.fn.delete(root, 'rf')
end)

test('extract-helper: cross-file without a destination refuses asking for one', function ()
    local root = proj { ['a.lua'] = CF_A, ['b.lua'] = CF_B }
    local pair = xpair('find')
    if pair then
        local plan, why = cx.plan(store, pair) -- no dest
        ok(not plan and why:find('destination'), 'cross-file needs a destination module')
    else ok(true, '(no pair — fine)') end
    vim.fn.delete(root, 'rf')
end)

test('extract-helper: a self-recursive body is refused', function ()
    local root = proj { ['m.lua'] =
        'local M = {}\n\nlocal function r_a(n)\n  local y = base(n, \'x\')\n  local z = step(y)\n'
        .. '  local w = r_a(z)\n  return w\nend\n\n'
        .. 'local function r_b(n)\n  local y = base(n, \'y\')\n  local z = step(y)\n'
        .. '  local w = r_b(z)\n  return w\nend\n\nreturn M\n' }
    local pair = pair_of('r_a')
    if pair then
        local plan, why = cx.plan(store, pair)
        ok(not plan and why:find('recursive'), 'a self-recursive body is refused')
    else ok(true, '(no pair — fine)') end
    vim.fn.delete(root, 'rf')
end)

-- ── non-Lua (JavaScript) synthesis ───────────────────────────────────────────

local JS_A = 'function fmtA(x) {\n  const y = prep(x);\n  const z = norm(y);\n'
    .. '  const w = encode(z, \'json\');\n  const o = wrap(w);\n  return o;\n}\n'
local JS_B = 'function fmtB(a) {\n  const b = prep(a);\n  const c = norm(b);\n'
    .. '  const d = encode(c, \'yaml\');\n  const e = wrap(d);\n  return e;\n}\n'

test('extract-helper: a JavaScript same-file pair synthesizes JS-syntax helper + wrappers', function ()
    if not ready('javascript') then skip 'no javascript parser' end
    local root = proj { ['m.js'] = JS_A .. '\n' .. JS_B }
    local plan, why = cx.plan(store, xpair('fmtA'))
    ok(plan, 'a JS pair plans: ' .. tostring(why))
    if plan then
        eq('javascript', plan.lang, 'the plan carries the JS language')
        local _, after = cx.preview(store, plan)
        local text = after[plan.a.file]
        -- JS braces + semicolons, not Lua function...end
        ok(text:find('function ' .. plan.helper .. '(x, hp1) {', 1, true), 'JS helper opens with a brace')
        ok(text:find('const w = encode(z, hp1);', 1, true), 'the hole is parameterized in the JS body')
        ok(text:find(('return %s(x, \'json\');'):format(plan.helper), 1, true), 'fmtA delegates (JS semicolon)')
        ok(text:find(('return %s(a, \'yaml\');'):format(plan.helper), 1, true), 'fmtB delegates')
        local pr = vim.treesitter.get_string_parser(text, 'javascript'):parse()[1]:root()
        ok(not pr:has_error(), 'the synthesized JS parses clean')
    end
    vim.fn.delete(root, 'rf')
end)

test('extract-helper: a JavaScript apply writes a parsing file', function ()
    if not ready('javascript') then skip 'no javascript parser' end
    local root = proj { ['m.js'] = JS_A .. '\n' .. JS_B }
    local plan = cx.plan(store, xpair('fmtA'))
    ok(plan, 'planned')
    if plan then
        store.set_txn(plan)
        local entry, why = cx.apply(store, plan)
        ok(entry, 'JS apply succeeds: ' .. tostring(why))
        local written = table.concat(vim.fn.readfile(root .. '/m.js'), '\n')
        local pr = vim.treesitter.get_string_parser(written, 'javascript'):parse()[1]:root()
        ok(not pr:has_error(), 'the written JS parses clean')
        eq(3, select(2, written:gsub(plan.helper .. '%(', '')), 'helper appears 3× (def + 2 calls)')
    end
    vim.fn.delete(root, 'rf')
end)

test('extract-helper: cross-file JS is refused (no module wiring yet)', function ()
    if not ready('javascript') then skip 'no javascript parser' end
    local root = proj { ['a.js'] = JS_A, ['b.js'] = JS_B }
    -- fmtA/fmtB are in different files; JS has no module wiring → refuse
    local pa = clones.near_of(store, fn_id('fmtA'), { max_dist = 2, min_rows = 4, min_shared = 2 })[1]
    if pa then
        local plan, why = cx.plan(store, pa, { dest = 'shared.js' })
        ok(not plan and why:find('cross%-file'), 'cross-file JS is refused with a reason')
    else ok(true, '(no pair — fine)') end
    vim.fn.delete(root, 'rf')
end)

-- ── Factorio phase-awareness (cross-phase free-read gate) ────────────────────

-- a body differing only at a literal, reading `read_global` — parameterized as `phase`
local function fac_handle(lit, read_global)
    return ('local function handle(x)\n  local n = prep(x)\n  local z = norm(n)\n'
        .. '  %s(\'%s\')\n  return wrap(z)\nend\nreturn handle\n'):format(read_global, lit)
end
local function xpair_at(name, file)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and n.file == file then
            return clones.near_of(store, n.id, { max_dist = 2, min_rows = 3, min_shared = 2 })[1]
        end
    end
end

test('extract-helper: a CROSS-PHASE move reading a phase-bound global is refused', function ()
    -- rt.lua (runtime cone via control.lua) + dt.lua (data cone via data.lua): a near-clone
    -- reading `game` (runtime-only). A shared home spans both phases → not phase-safe.
    local root = proj {
        ['control.lua'] = "require('rt')\n",
        ['data.lua'] = "require('dt')\n",
        ['rt.lua'] = fac_handle('rt', 'game.print'),
        ['dt.lua'] = fac_handle('dt', 'game.print'),
    }
    local p = xpair_at('handle', 'rt.lua')
    ok(p, 'the cross-phase pair is found')
    if p then
        local plan, why = cx.plan(store, p, { dest = 'shared.lua' })
        ok(not plan and why:find('phase%-bound'), 'a phase-bound global blocks the cross-phase move: ' .. tostring(why))
        ok(why:find('game'), 'the offending global is named')
    end
    vim.fn.delete(root, 'rf')
end)

test('extract-helper: a phase-agnostic cross-phase move is allowed', function ()
    -- same cross-phase pair, but the body reads only pure globals (no game/data) → the
    -- shared-helper case that IS sound across phases (like SE's shared.lua)
    local root = proj {
        ['control.lua'] = "require('rt')\n",
        ['data.lua'] = "require('dt')\n",
        ['rt.lua'] = fac_handle('rt', 'log'),
        ['dt.lua'] = fac_handle('dt', 'log'),
    }
    local p = xpair_at('handle', 'rt.lua')
    ok(p, 'the pair is found')
    if p then
        local plan, why = cx.plan(store, p, { dest = 'shared.lua' })
        ok(plan, 'a pure body extracts across phases: ' .. tostring(why))
    end
    vim.fn.delete(root, 'rf')
end)

test('extract-helper: a SAME-PHASE cross-file move may read that phase global', function ()
    -- r1.lua + r2.lua both in the runtime cone → the shared home loads only at runtime,
    -- so a `game` read is fine
    local root = proj {
        ['control.lua'] = "require('r1')\nrequire('r2')\n",
        ['r1.lua'] = fac_handle('a', 'game.print'),
        ['r2.lua'] = fac_handle('b', 'game.print'),
    }
    local p = xpair_at('handle', 'r1.lua')
    ok(p, 'the same-phase pair is found')
    if p then
        local plan, why = cx.plan(store, p, { dest = 'shared.lua' })
        ok(plan, 'a runtime-only home may carry a runtime global: ' .. tostring(why))
    end
    vim.fn.delete(root, 'rf')
end)

--- ★★★ A VERB WITH A REFUSAL CHANNEL MUST NOT RAISE (CART-0372). `plan` refuses
--- 4080 of 4294 pairs on wow with precise reasons; raising on the 4295th loses
--- the whole survey to one input, which is what happened to the fold queue —
--- the first run printed a stack trace and none of the other 58 rows.
---
--- THE MECHANISM: the hole-validation loop iterates `side.s`, so it is VACUOUS
--- for an empty site list. `call_line` then indexes `p[sites_key][1]` and hands
--- nil to `at.sl`.
---
--- ⚠ FORCED, and honestly so: swept 5,055 pairs across three corpora (self 543
--- at max_dist 24, factorio 218, wow 4,294) and the precondition occurs ZERO
--- times today — the tree that produced the original witness has moved. But no
--- commit ever touched that indexing, so the path is unchanged and the defect
--- is LATENT, not fixed. Stubbing the analysis is the only way to reach it.
test('extract-helper: a hole with no site on one side REFUSES, it does not raise', function ()
    if not ready('lua') then return skip 'no lua parser' end
    local root = proj { ['m.lua'] =
        'local M = {}\n\nlocal function fmt_a(x)\n  local y = prep(x)\n  local z = norm(y)\n'
        .. '  local w = encode(z, \'json\')\n  local o = wrap(w)\n  return o\nend\n\n'
        .. 'local function fmt_b(a)\n  local b = prep(a)\n  local c = norm(b)\n'
        .. '  local d = encode(c, \'yaml\')\n  local e = wrap(d)\n  return e\nend\n\nreturn M\n' }
    local pair = pair_of('fmt_a')
    ok(pair ~= nil, 'the fixture yields a pair')
    -- CONTROL: it plans cleanly before the injection, or this passes for the
    -- wrong reason
    ok(cx.plan(store, pair), 'the pair plans before the analysis is stubbed')

    local saved = clones.analyze_pair
    clones.analyze_pair = function (p)
        local an = saved(p)
        if an and an.holes and an.holes[1] then an.holes[1].sites_b = {} end
        return an
    end
    local okc, plan, why = pcall(cx.plan, store, pair)
    clones.analyze_pair = saved

    ok(okc, 'plan RETURNS rather than raising: ' .. tostring(plan))
    eq(nil, plan)
    ok(tostring(why):find('no located site on one side'),
        'and names the reason: ' .. tostring(why))
    vim.fn.delete(root, 'rf')
end)

-- ── the FAMILY plan: one helper for N copies (CART-0888 / CART-0904) ─────────
--
-- Asking PAIRWISE over a component of N near-clones gives up to C(N,2)
-- proposals which DISAGREE — 84% of wow's components — and the clique proxy
-- agrees with the MDL partition on only 38%. The family is the unit a human
-- would extract; the pair is a sample of it.

local algx = require 'cartograph.algebra'
local function need_algebra()
    local okA, whyA = algx.available()
    if not okA then skip('algebra unavailable: ' .. tostring(whyA)) end
end

--- three same-file copies differing at one literal each
local function fam3_src()
    local function body(n)
        return ([[
local function pick%s(node)
  if not node then return nil end
  local acc = 0
  local seen = {}
  if node.t == 'K%s' then return node end
  for _, c in ipairs(node.kids) do
    if c.t == 'K%s' then return c end
  end
  seen[acc] = true
  return nil
end
]]):format(n, n, n)
    end
    return 'local M = {}\n\n' .. body(1) .. '\n' .. body(2) .. '\n' .. body(3) .. '\nreturn M\n'
end

local function family_of_fixture()
    local clones = require 'cartograph.clones'
    local r = clones.families(store, {})
    if not r then return nil end
    for _, f in ipairs(r.families) do
        if #f.members >= 2 and f.holes > 0 then return f end
    end
end

test('extract-family: one helper for N copies, each passing its own filling', function ()
    if not ready('lua') then return skip 'no lua parser' end
    need_algebra()
    local root = proj { ['m.lua'] = fam3_src() }
    local fam = family_of_fixture()
    if not fam then skip 'fixture yielded no family' end

    local plan, why = cx.plan_family(store, fam)
    ok(plan, 'the family plans: ' .. tostring(why))
    if plan then
        ok(#plan.members >= 2, 'it rewrites every member: ' .. #plan.members)
        eq(false, plan.xfile)
        local _, after = cx.preview(store, plan)
        local text = after[plan.touched[1]]

        -- ★ ONE helper, defined once, with a parameter per hole
        eq(1, select(2, text:gsub('function ' .. plan.helper .. '%(', '')))
        -- ★ EVERY member delegates, each with ITS OWN literal
        for _, k in ipairs { 'K1', 'K2', 'K3' } do
            ok(text:find(("'%s'"):format(k), 1, true),
                ('%s survives as an ARGUMENT at its own call site'):format(k))
        end
        -- ⚠ and the literals are GONE from the helper body — otherwise the
        -- helper is one member's code wearing a parameter list
        local hstart = text:find('function ' .. plan.helper, 1, true)
        local hend = text:find('\nend', hstart, true)
        local hbody = text:sub(hstart, hend)
        for _, k in ipairs { 'K1', 'K2', 'K3' } do
            ok(not hbody:find(k, 1, true),
                ('%s is parameterized inside the helper, not baked in'):format(k))
        end
        -- and it parses
        local pr = vim.treesitter.get_string_parser(text, 'lua'):parse()[1]:root()
        ok(not pr:has_error(), 'the extracted result parses clean')
    end
    vim.fn.delete(root, 'rf')
end)

--- ★★★ CROSS-FILE: the helper becomes a NEW SHARED MODULE, each file gains ONE
--- require, and every member delegates through the alias. The gates that make it
--- sound are N-way: a moved body may read only globals (a source-file local does
--- not exist at the new home), and on Factorio the module loads in the UNION of
--- every member's phases — which GROWS with N, so a family a pair could extract
--- may be refused.
test('extract-family: cross-file creates a shared module and one require per file', function ()
    if not ready('lua') then return skip 'no lua parser' end
    need_algebra()
    local src = fam3_src()
    local half = src:find('local function pick2')
    local root = proj {
        ['a.lua'] = src:sub(1, half - 1) .. 'return M\n',
        ['b.lua'] = 'local M = {}\n\n' .. src:sub(half) }
    local fam = family_of_fixture()
    if not fam then skip 'fixture yielded no family' end
    local files = {}
    for _, m in ipairs(fam.members) do files[m.file] = true end
    local nf = 0; for _ in pairs(files) do nf = nf + 1 end
    if nf < 2 then skip 'fixture family did not span files' end

    -- ⚠ WITHOUT A DESTINATION IT REFUSES, naming the count rather than picking a
    -- path: where a new module goes is the caller's decision, not the verb's
    local none, why = cx.plan_family(store, fam)
    eq(nil, none)
    ok(tostring(why):find('destination module path'), 'asks for a home: ' .. tostring(why))

    local plan, w2 = cx.plan_family(store, fam, { dest = 'lib/shared.lua' })
    ok(plan, 'with a destination it plans: ' .. tostring(w2))
    if plan then
        eq(true, plan.xfile)
        ok(plan.create and plan.create.file == 'lib/shared.lua', 'it creates the module')
        ok(plan.helper_call and plan.helper_call:find('%.'),
            'and members call it through an alias: ' .. tostring(plan.helper_call))
        ok(#plan.hazards > 0, 'the require path rides as a HAZARD to verify, not a claim')

        local _, after = cx.preview(store, plan)
        -- the module holds the helper exactly once
        local mod = after['lib/shared.lua']
        ok(mod and mod:find('function M%.' .. plan.helper), 'the module defines the helper')

        -- ⚠ ONE REQUIRE PER FILE, not one per member: a file holding two members
        -- must not gain the import twice
        for f in pairs(files) do
            local text = after[f]
            ok(text, 'the file was rewritten: ' .. f)
            eq(1, select(2, text:gsub("require%s*%(?%s*'lib%.shared'", '')),
                ('%s gains exactly one require'):format(f))
            local pr = vim.treesitter.get_string_parser(text, 'lua'):parse()[1]:root()
            ok(not pr:has_error(), f .. ' parses clean after the rewrite')
        end
        local pm = vim.treesitter.get_string_parser(mod, 'lua'):parse()[1]:root()
        ok(not pm:has_error(), 'and so does the new module')
    end
    vim.fn.delete(root, 'rf')
end)

--- ⚠ THE FREE-READ GATE IS N-WAY, AND ONE FAILURE IS THE WHOLE FAMILY'S. A
--- moved body may read only globals: a source-file LOCAL does not exist at the
--- new home. The helper is SHARED, so it has to be movable for every member —
--- with N members that is N chances to fail, not two.
test('extract-family: cross-file refuses when ANY member reads a file-local', function ()
    if not ready('lua') then return skip 'no lua parser' end
    need_algebra()
    local src = fam3_src()
    local half = src:find('local function pick2')
    -- ⚠ BOTH files declare `SENTINEL` and every body reads it, so the members
    -- stay CLONES (an extra differing row would push them past the distance gate
    -- and the fixture would yield no family at all — the first cut did exactly
    -- that and SKIPPED).
    local withlocal = src:gsub('seen%[acc%] = true', 'seen[acc] = SENTINEL')
    local h2 = withlocal:find('local function pick2')
    local root = proj {
        ['a.lua'] = 'local M = {}\nlocal SENTINEL = 7\n\n'
            .. withlocal:sub(#'local M = {}\n\n' + 1, h2 - 1) .. 'return M\n',
        ['b.lua'] = 'local M = {}\nlocal SENTINEL = 7\n\n' .. withlocal:sub(h2) }
    local fam = family_of_fixture()
    if not fam then skip 'fixture yielded no family' end
    local files = {}
    for _, m in ipairs(fam.members) do files[m.file] = true end
    local nf = 0; for _ in pairs(files) do nf = nf + 1 end
    if nf < 2 then skip 'fixture family did not span files' end

    local plan, why = cx.plan_family(store, fam, { dest = 'lib/shared.lua' })
    eq(nil, plan)
    ok(tostring(why):find('file%-local'), 'names the gate: ' .. tostring(why))
    ok(tostring(why):find('SENTINEL'), 'and WHICH local: ' .. tostring(why))
    vim.fn.delete(root, 'rf')
end)

test('extract-family: refuses a family with nothing to share', function ()
    if not ready('lua') then return skip 'no lua parser' end
    need_algebra()
    local a, w1 = cx.plan_family(store, { members = {} })
    eq(nil, a); ok(tostring(w1):find('two or more'), tostring(w1))
end)

--- ⚠ PARTIAL IS A CALLER'S CHOICE, NOT A DEFAULT. Extraction is sound when
--- incomplete — the helper exists, the admissible bodies delegate, a skipped
--- member keeps its own body, nothing dangles — but silently rewriting a subset
--- would hide that a member was left behind. Refuse and NAME them; extract only
--- when asked. (`clonemerge` refuses whole for a different reason: a partial
--- merge leaves dangling references. That argument does not transfer.)
test('extract-family: an inadmissible member refuses, and opts.partial takes the rest', function ()
    if not ready('lua') then return skip 'no lua parser' end
    need_algebra()
    local function body(n, indent)
        local i = indent and '  ' or ''
        return ([[
%slocal function pick%s(node)
%s  if not node then return nil end
%s  local acc = 0
%s  local seen = {}
%s  if node.t == 'K%s' then return node end
%s  for _, c in ipairs(node.kids) do
%s    if c.t == 'K%s' then return c end
%s  end
%s  seen[acc] = true
%s  return nil
%send
]]):format(i, n, i, i, i, i, n, i, i, n, i, i, i, i)
    end
    -- pick3 is NESTED inside `wrap`, so it is inadmissible; 1 and 2 are not
    local root = proj { ['m.lua'] = 'local M = {}\n\n' .. body(1) .. '\n' .. body(2)
        .. '\nlocal function wrap()\n' .. body(3, true) .. '  return pick3\nend\n\nreturn M\n' }
    local fam = family_of_fixture()
    if not fam then skip 'fixture yielded no family' end
    local clones = require 'cartograph.clones'
    local v = clones.family_admissibility(fam, store)
    if not v or v.n_admissible == v.n or v.n_admissible < 2 then
        skip 'fixture did not produce a mixed family'
    end

    -- without opts.partial: refuse, and NAME who is left out
    local plan, why = cx.plan_family(store, fam)
    eq(nil, plan)
    ok(tostring(why):find('not extractable'), 'names the shortfall: ' .. tostring(why))
    ok(tostring(why):find('partial'), 'and offers the opt-in: ' .. tostring(why))

    -- with it: extract the admissible subset, and SAY who was left
    local p2, w2 = cx.plan_family(store, fam, { partial = true })
    ok(p2, 'partial extracts the rest: ' .. tostring(w2))
    if p2 then
        eq(true, p2.partial)
        eq(v.n_admissible, #p2.members)
        ok(#p2.left > 0, 'and the plan records who was left behind')
        ok(p2.left[1].name and p2.left[1].reason, 'with a name and a reason')
        local _, after = cx.preview(store, p2)
        local pr = vim.treesitter.get_string_parser(after[p2.touched[1]], 'lua'):parse()[1]:root()
        ok(not pr:has_error(), 'a PARTIAL extraction still parses clean')
    end
    vim.fn.delete(root, 'rf')
end)

--- ★★★ THE REPARSE ORACLE GATES THE PLAN, NOT JUST THE DISPLAY. A hole at
--- STATEMENT position renders `if not f then p1 end` — which reads perfectly
--- reasonable and is not valid Lua, because a bare expression is not a statement
--- (CART-0894). The text renders fine and fails to READ BACK, so the oracle is
--- the only thing between it and a write.
---
--- ⚠ STUBBED, and honestly so. Three synthetic fixtures failed to reproduce the
--- shape: literals differing INSIDE a call are leaf holes; whole statements of
--- different arity are refused earlier by the co-walk; and a hole on the CALLEE
--- renders `p1(name)`, which is valid Lua and verifies. The real witness
--- (bravest-new-world) has the hole covering a whole call WITH its arguments.
--- Rather than contort a fixture until it happens to break, the gate is tested
--- directly — with a CONTROL, so it cannot pass by the family being unplannable
--- for some other reason.
test('extract-family: a body that does not read back is refused, not written', function ()
    if not ready('lua') then return skip 'no lua parser' end
    need_algebra()
    local root = proj { ['m.lua'] = fam3_src() }
    local fam = family_of_fixture()
    if not fam then skip 'fixture yielded no family' end

    local clones = require 'cartograph.clones'
    ok(cx.plan_family(store, fam), 'CONTROL: the family plans while it verifies')

    local saved = clones.family_verify
    clones.family_verify = function () return nil, 'the rendered helper did not reparse' end
    local plan, why = cx.plan_family(store, fam)
    clones.family_verify = saved

    eq(nil, plan)
    ok(tostring(why):find('does not verify'), 'the oracle refuses the plan: ' .. tostring(why))

    -- and the OTHER outcome: "cannot be verified" is a different fact, and for a
    -- WRITE it also refuses — the distinction lands in the message
    clones.family_verify = function ()
        return nil, 'not verifiable: the donor\'s own text does not reparse standalone',
            { verifiable = false }
    end
    local p2, w2 = cx.plan_family(store, fam)
    clones.family_verify = saved
    eq(nil, p2)
    ok(tostring(w2):find('cannot be VERIFIED'), 'named distinctly: ' .. tostring(w2))
    vim.fn.delete(root, 'rf')
end)

--- ★★★ THE PHASE GATE GETS STRICTER AS N GROWS, and that is the honest shape
--- rather than a limitation to apologise for. The shared home loads in the UNION
--- of every member's file's phases; a phase-bound global (`game` is runtime-only)
--- is safe only if every destination phase is that global's own. TWO files may
--- share a phase where THREE do not, so a family a PAIR could extract can be
--- refused — and the refusal names the union so the reader sees why.
test('extract-family: a cross-PHASE family reading a phase-bound global is refused', function ()
    if not ready('lua') then return skip 'no lua parser' end
    need_algebra()
    local function fam_handle(lit)
        return ('local function handle(x)\n  local n = prep(x)\n  local z = norm(n)\n'
            .. '  local q = tag(z)\n  game.print(\'%s\')\n  return wrap(q)\nend\n'
            .. 'return handle\n'):format(lit)
    end
    local root = proj {
        ['control.lua'] = "require('rt')\nrequire('rt2')\n",
        ['data.lua'] = "require('dt')\n",
        ['rt.lua'] = fam_handle('a'),
        ['rt2.lua'] = fam_handle('b'),
        ['dt.lua'] = fam_handle('c'),
    }
    local clones = require 'cartograph.clones'
    local id
    for _, n in ipairs(store.data.nodes) do
        if n.name == 'handle' and n.file == 'rt.lua' then id = n.id end
    end
    if not id then skip 'fixture yielded no handle' end
    local fam = clones.family_of(store, id, { max_dist = 2, min_rows = 3, min_shared = 2 })
    if not fam or #fam.members < 2 then skip 'fixture yielded no family' end

    local plan, why = cx.plan_family(store, fam, { dest = 'lib/shared.lua' })
    eq(nil, plan)
    ok(tostring(why):find('phase%-bound'), 'the phase gate fires: ' .. tostring(why))
    ok(tostring(why):find('game'), 'naming the global: ' .. tostring(why))
    -- ⚠ ASSERT ON THE UNION ITSELF, not on the words appearing anywhere. The
    -- message says "...global `game` (runtime phase) ... phases {data, runtime}",
    -- so searching the whole string for "runtime" passes even when the union was
    -- computed from ONE file — `game` put the word there. Mutation found that:
    -- taking the union from files[1] alone survived until this read the braces.
    local union = tostring(why):match('phases {([^}]*)}')
    ok(union, 'the refusal states the destination phase union: ' .. tostring(why))
    ok(union:find('data') and union:find('runtime'),
        'and it spans BOTH phases, computed over every member file: {' .. tostring(union) .. '}')
    vim.fn.delete(root, 'rf')
end)

-- ── a write TARGET is not a value (CART-0941) ───────────────────────────────
--
-- ★★★ THIS IS A CORRECTNESS REGRESSION TEST, NOT A REFUSAL TEST. Before it,
-- `plan` accepted the pair below and emitted `hp1 = alpha` where the source read
-- `self.alpha = alpha`: the helper assigned to its own parameter, NEITHER copy
-- set its field any more, and the argument passed was the field read BEFORE the
-- write. It parses, so the `parses` guard let it through. Measured on factorio:
-- 6 of 17 sampled value-parameterizable pairs carried a hole of this shape.

test('extract-helper: REFUSES a hole that IS the assignment target', function ()
    local body = [[
  local n = 0
  local seen = {}
  self.tag = 'shared'
  self.%s = v
  n = n + 1
  seen[n] = true
  if n > 0 then n = n - 1 end
  return n, seen]]
    local root = proj { ['w.lua'] = ('local M = {}\n\nlocal function wr_a(self, v)\n%s\nend\n\n'
        .. 'local function wr_b(self, v)\n%s\nend\n\nreturn M\n')
        :format(body:format('alpha'), body:format('beta')) }
    local p = pair_of('wr_a')
    ok(p ~= nil, 'the two copies are still a near pair')
    local plan, why = cx.plan(store, p)
    eq(nil, plan, 'and the extraction is refused')
    ok(tostring(why):find('assignment TARGET', 1, true),
        'the reason names the target: ' .. tostring(why))
    -- ⚠ AND IT NAMES THE DESTINATION KIND, because that is what says which rewrite
    -- is missing (`self[hp] = v`, an index write) rather than only that one is.
    ok(tostring(why):find('field destination', 1, true),
        'and the destination kind: ' .. tostring(why))
    vim.fn.delete(root, 'rf')
end)

test('extract-helper: a hole INSIDE a destination still plans — `target` is not `side`',
    function ()
        -- ★★★ THE NON-VACUITY GUARD FOR THE REFUSAL ABOVE. Every hole below a
        -- destination carries `side = 'lhs'`, so a refusal keyed on the SIDE would
        -- swallow this pair too — and it is perfectly extractable: the index KEY is
        -- already an expression, substituting it rewrites `self[hp1] = v`, and the
        -- write survives. If this test ever fails, the gate has become a blanket
        -- one and a whole class of correct extractions went with it.
        local body = [[
  local n = 0
  local seen = {}
  self.tag = 'shared'
  self[%s] = v
  n = n + 1
  seen[n] = true
  if n > 0 then n = n - 1 end
  return n, seen]]
        local root = proj { ['k.lua'] = ('local M = {}\n\nlocal function kw_a(self, v)\n%s\nend\n\n'
            .. 'local function kw_b(self, v)\n%s\nend\n\nreturn M\n')
            :format(body:format("'alpha'"), body:format("'beta'")) }
        local p = pair_of('kw_a')
        ok(p ~= nil, 'the two copies are a near pair')
        local a = clones.analyze_pair(p)
        eq('value', a.kind)
        eq(1, #a.holes, 'one hole — the differing key')
        eq('lhs', a.holes[1].side, 'it IS on the write side')
        eq('index', a.holes[1].dest, 'under an index destination')
        eq(nil, a.holes[1].target, 'but it is NOT the target itself')
        local plan, why = cx.plan(store, p)
        ok(plan, 'so the extraction still plans: ' .. tostring(why))
        if plan then
            local _, after = cx.preview(store, plan)
            local text = after[plan.a.file]
            ok(text:find('self[hp1] = v', 1, true),
                'and the write survives, with the KEY parameterized')
        end
        vim.fn.delete(root, 'rf')
    end)

test('extract-helper: on a two-level destination only the OUTER selector is the target',
    function ()
        -- ★★★ THE CASE I GOT WRONG IN PROSE FIRST. A nested destination has two
        -- selectors and the refusal must fire on exactly one of them: replacing the
        -- BASE (`self.c` -> `hp1`) leaves `hp1.c = v`, which still writes; replacing
        -- the OUTER selector leaves `hp1 = v`, which does not. The tuple matched is
        -- (kind, d1.n, d2.n) and only the destination's own divergence carries both.
        local body = [[
  local n = 0
  local seen = {}
  self.tag = 'shared'
  %s = v
  n = n + 1
  seen[n] = true
  if n > 0 then n = n - 1 end
  return n, seen]]
        local function build(la, lb)
            return proj { ['n.lua'] = ('local M = {}\n\nlocal function q_a(self, v)\n%s\nend\n\n'
                .. 'local function q_b(self, v)\n%s\nend\n\nreturn M\n')
                :format(body:format(la), body:format(lb)) }
        end

        local root = build('self.c.c', 'self.x.c')     -- the BASE varies
        local a = clones.analyze_pair(pair_of('q_a'))
        eq(nil, a.holes[1].target, 'a base divergence is NOT the target')
        local plan = cx.plan(store, pair_of('q_a'))
        ok(plan, 'so it plans')
        if plan then
            local _, after = cx.preview(store, plan)
            ok(after[plan.a.file]:find('hp1.c = v', 1, true),
                'and the write survives with the BASE parameterized')
        end
        vim.fn.delete(root, 'rf')

        root = build('self.b.c', 'self.b.d')           -- the SELECTOR varies
        a = clones.analyze_pair(pair_of('q_a'))
        eq(true, a.holes[1].target, 'an outer-selector divergence IS the target')
        local p2, why = cx.plan(store, pair_of('q_a'))
        eq(nil, p2, 'so it is refused: ' .. tostring(why))
        vim.fn.delete(root, 'rf')
    end)

-- ── THE CAPTURE LIFT (CART-0878) ────────────────────────────────────────────
-- A member NESTED in another function is inadmissible because its body reads that
-- function's locals. But those names are in scope AT THE CALL SITE — the replacement
-- lands in the member's BODY and the member itself stays where it is — so the capture
-- becomes a PARAMETER and each site passes its own. `family_admissibility` has computed
-- `liftable`/`lifts` since CART-0904; this is the apply half, and it is OPT-IN because
-- it changes the helper's signature.
local LIFT_SRC = table.concat({
    'local M = {}',
    'function M.alpha(items)',
    '  local cfg = { pad = 1 }',
    '  local function pick(list)',
    '    local out = {}',
    '    for _, it in ipairs(list) do',
    '      if #it > 2 then out[#out + 1] = it .. cfg.pad end',
    '    end',
    '    table.sort(out)',
    '    return out',
    '  end',
    '  return pick(items)',
    'end',
    'function M.beta(items)',
    '  local cfg = { pad = 9 }',
    '  local function choose(list)',
    '    local out = {}',
    '    for _, it in ipairs(list) do',
    '      if #it > 5 then out[#out + 1] = it .. cfg.pad end',
    '    end',
    '    table.sort(out)',
    '    return out',
    '  end',
    '  return choose(items)',
    'end',
    'return M',
}, '\n') .. '\n'

local function fam3(name)
    return clones.family_of(store, fn_id(name), { max_dist = 3 })
end

test('extract-helper: a captured enclosing local becomes a PARAMETER each site passes', function ()
    local root = proj { ['m.lua'] = LIFT_SRC }
    local fam = fam3('pick')
    local v = clones.family_admissibility(fam, store)
    eq(0, v.n_admissible, 'neither member is admissible as it stands — both are nested')
    eq(2, v.n_liftable, 'but both are LIFTABLE')
    eq('cfg', table.concat(v.lifts or {}, ','), 'and they agree on what to lift')

    local plan = assert(cx.plan_family(store, fam, { lift = true }))
    eq('cfg', table.concat(plan.lifted or {}, ','), 'the plan records the lift')
    local _, after = cx.preview(store, plan)
    local text = after['m.lua']
    -- the helper takes the member's OWN parameter, the template hole, then the capture
    ok(text:find('local function %w+_extracted%(list, p1, cfg%)'),
        'the signature is (own params, holes, lifted captures): ' .. text:sub(1, 400))
    -- ★ EACH SITE PASSES ITS OWN `cfg` — the point of the lift. Two enclosing
    -- functions, two different tables, one helper.
    local n = select(2, text:gsub('_extracted%(list, %d+, cfg%)', ''))
    eq(2, n, 'both call sites pass their own cfg: ' .. text)
    vim.fn.delete(root, 'rf')
end)

test('extract-helper: without `lift` the refusal NAMES the flag, not "not supported"', function ()
    -- ⚠ CART-0973's lesson on the same surface: a remedy a caller cannot follow is
    -- the mirror of a refusal it cannot reach. This used to read "not supported yet".
    local root = proj { ['m.lua'] = LIFT_SRC }
    local plan, why = cx.plan_family(store, fam3('pick'), {})
    eq(nil, plan)
    ok(tostring(why):find('`lift`', 1, true), 'the refusal names the argument: ' .. tostring(why))
    ok(tostring(why):find('cfg', 1, true), 'and what would be lifted: ' .. tostring(why))
    vim.fn.delete(root, 'rf')
end)

-- ⚠⚠ THE SOUNDNESS LINE. A Lua parameter is BY VALUE, so lifting a capture the body
-- ASSIGNS would update a copy and silently drop the write. A TABLE capture is
-- different — `cfg.pad = 1` mutates through the reference and survives — which is why
-- the gate is about assigning the NAME, not about touching the value.
test('extract-helper: a capture the body WRITES is never lifted', function ()
    local WRITES = LIFT_SRC
        :gsub('if #it > 2 then out%[#out %+ 1%] = it %.%. cfg%.pad end',
              'cfg = cfg + 1\n      if #it > 2 then out[#out + 1] = it .. cfg end')
        :gsub('if #it > 5 then out%[#out %+ 1%] = it %.%. cfg%.pad end',
              'cfg = cfg + 1\n      if #it > 5 then out[#out + 1] = it .. cfg end')
    local root = proj { ['m.lua'] = WRITES }
    local fam = fam3('pick')
    if fam and #(fam.members or {}) >= 2 then
        local v = clones.family_admissibility(fam, store)
        eq(0, v.n_liftable or 0, 'a write capture is not liftable')
        ok(tostring(v.lift_why):find('WRITES', 1, true),
            'and says why: ' .. tostring(v.lift_why))
        local plan, why = cx.plan_family(store, fam, { lift = true })
        eq(nil, plan, 'so `lift` does not force it')
        ok(tostring(why):find('cannot be lifted', 1, true) or tostring(why):find('extractable', 1, true),
            'refusing by name: ' .. tostring(why))
    end
    vim.fn.delete(root, 'rf')
end)

test('extract-helper: a lifted member\'s FILE-LOCAL reads still block a cross-file move', function ()
    -- ⚠⚠ THIS GATE WAS VACUOUS FOR EXACTLY THE MEMBERS THE LIFT ENABLES, and the
    -- preview is what caught it. `body_extractable` returns `{ok=false, nested=true}`
    -- and never reaches its read walk, so `mv.reads` was NIL for every lifted member
    -- and the free-read loop ran zero times. A lifted cross-file plan therefore passed
    -- a gate that had asked nothing — the witness (CART-0878's own `key_range`) would
    -- have been written into a new module reading `callrec`, a file-local `require`.
    -- It parses.
    local body = function (nm, fn, lit)
        return 'local helper = require "somewhere"\nlocal M = {}\n'
            .. ('function M.%s(items)\n  local cfg = { pad = 1 }\n'):format(nm)
            .. ('  local function %s(list)\n    local out = {}\n'):format(fn)
            .. '    for _, it in ipairs(list) do\n'
            .. ('      if #it > %s then out[#out + 1] = helper.f(it) .. cfg.pad end\n'):format(lit)
            .. '    end\n    table.sort(out)\n    return out\n  end\n'
            .. ('  return %s(items)\nend\nreturn M\n'):format(fn)
    end
    local root = proj { ['one.lua'] = body('alpha', 'pick', 2),
                        ['two.lua'] = body('beta', 'choose', 5) }
    local fam = fam3('pick')
    if fam and #(fam.members or {}) >= 2 then
        local v = clones.family_admissibility(fam, store)
        eq(2, v.n_liftable or 0, 'both are liftable')
        local plan, why = cx.plan_family(store, fam, { lift = true, dest = 'shared/pk.lua' })
        eq(nil, plan, 'but the helper body reads a file-local, so it cannot move')
        ok(tostring(why):find('file%-local'),
            'and the gate says which: ' .. tostring(why))
        ok(tostring(why):find('helper', 1, true), 'naming it: ' .. tostring(why))
    end
    vim.fn.delete(root, 'rf')
end)

-- ⚠⚠ A CAPTURE-FREE SIBLING CANNOT RIDE ALONG ONCE THERE IS SOMETHING TO LIFT, and the
-- analysis comment used to say it could. A helper has ONE signature: lifting `cfg` gives
-- it a parameter, and the capture-free member's call site would have to pass a name it
-- does not have. That is the SAME refusal as "members capture different sets" — the
-- empty set is a different set — and it did not fire only because the set table is
-- filled from members with a NON-EMPTY capture list.
-- ★ MEASURED before the fix: 11 liftable families on lua/cartograph are uniform and 1
-- is mixed (algebra/composition.lua:ren with algebra/eau.lua:resolve, lifts={rename}).
-- Small, and it would have become a WRONG EDIT the moment the apply path trusted
-- `liftable` — which is what this commit adds.
local MIXED_SRC = table.concat({
    'local M = {}',
    'function M.alpha(items)',
    '  local cfg = { pad = 1 }',
    '  local function pick(list)',
    '    local out = {}',
    '    for _, it in ipairs(list) do',
    '      if #it > 2 then out[#out + 1] = it .. cfg.pad end',
    '    end',
    '    table.sort(out)',
    '    return out',
    '  end',
    '  return pick(items)',
    'end',
    'function M.beta(items)',
    '  local function choose(list)',
    '    local out = {}',
    '    for _, it in ipairs(list) do',
    '      if #it > 5 then out[#out + 1] = it .. 7 end',
    '    end',
    '    table.sort(out)',
    '    return out',
    '  end',
    '  return choose(items)',
    'end',
    'return M',
}, '\n') .. '\n'

test('extract-helper: a CAPTURE-FREE member is not asked to pass a name it lacks', function ()
    local root = proj { ['m.lua'] = MIXED_SRC }
    local fam = clones.family_of(store, fn_id('pick'),
        { max_dist = 4, min_rows = 3, min_shared = 2 })
    ok(fam and #(fam.members or {}) == 2, 'the two nested members are one family')
    local v = clones.family_admissibility(fam, store)
    eq('cfg', table.concat(v.lifts or {}, ','), 'one member captures `cfg`')
    -- ★ ONE, not two: the capture-free sibling is excluded from `liftable`
    eq(1, v.n_liftable, 'only the CAPTURING member is liftable')
    ok(tostring(v.lift_why):find('capture nothing', 1, true),
        'and the reason names the asymmetry: ' .. tostring(v.lift_why))
    -- so the lift cannot proceed: a helper needs two members
    local plan, why = cx.plan_family(store, fam, { lift = true })
    eq(nil, plan)
    ok(tostring(why):find('capture nothing', 1, true),
        'the refusal carries it through: ' .. tostring(why))
    -- ⚠ AND IT DOES NOT OFFER A FLAG THE CALLER ALREADY PASSED — the mirror of
    -- CART-0973, which this branch reintroduced until the message was split.
    ok(not tostring(why):find('pass `lift`', 1, true),
        'no unfollowable remedy: ' .. tostring(why))
    vim.fn.delete(root, 'rf')
end)

-- ── A MEMBER IS NOT ALWAYS A STATEMENT (CART-0985) ──────────────────────────
--
-- ★★★ THE HELPER IS A STATEMENT AND THE MEMBERS NEED NOT BE. Both builders inserted it
-- beside the earlier copy, which is right only when that copy's definition sits at a
-- statement position. MEASURED on `lua/cartograph/spec/odin.lua` — whose whole body is
-- `return { … }`, so `body_of`/`params_of` are ENTRIES IN A TABLE CONSTRUCTOR — the
-- helper landed inside the constructor and the file stopped parsing: one `ERROR` node
-- spanning exactly the inserted lines.
--
-- ⚠ THE `parses` GUARD CAUGHT IT, so nothing was ever written. This fixture exists
-- because a guard catching a synthesis bug is a REFUSAL, and a verb that can only refuse
-- a whole family of real code is not finished. The fold is now performed, not declined.
local CTOR_MODULE =
    'local node_text = require("u").node_text\n\n'
    .. 'return {\n'
    .. '    hooks = {\n'
    .. '        body_of = function (def)\n'
    .. '            for c in def:iter_children() do\n'
    .. '                if c:named() and c:type() == "procedure" then\n'
    .. '                    for g in c:iter_children() do\n'
    .. '                        if g:named() and g:type() == "block" then return g end\n'
    .. '                    end\n'
    .. '                end\n'
    .. '            end\n'
    .. '            return nil\n'
    .. '        end,\n'
    .. '        params_of = function (def)\n'
    .. '            for c in def:iter_children() do\n'
    .. '                if c:named() and c:type() == "procedure" then\n'
    .. '                    for g in c:iter_children() do\n'
    .. '                        if g:named() and g:type() == "parameters" then return g end\n'
    .. '                    end\n'
    .. '                end\n'
    .. '            end\n'
    .. '            return nil\n'
    .. '        end,\n'
    .. '    },\n'
    .. '}\n'

test('extract-helper: members inside a TABLE CONSTRUCTOR get the helper HOISTED out', function ()
    if not ready('lua') then skip('no lua parser') end
    local root = proj { ['m.lua'] = CTOR_MODULE }
    local p = pair_of('body_of')
    ok(p, 'the two constructor members are a near-clone pair')
    local plan, why = cx.plan(store, p)
    ok(plan, 'and they PLAN — the members not being statements is not a refusal: '
        .. tostring(why))
    if plan then
        local _, after = cx.preview(store, plan)
        local text = after[plan.a.file]
        -- ★ THE POINT: the helper is a STATEMENT, so it must be outside the constructor.
        local hpos = text:find('local function ' .. plan.helper, 1, true)
        local rpos = text:find('\nreturn {', 1, true)
        ok(hpos and rpos, 'both the helper and the constructor are in the result')
        ok(hpos < rpos, 'the helper is hoisted ABOVE `return {`, not inserted inside it')
        -- ⚠ AND IT PARSES. This is the assertion the old behaviour failed: the result
        -- carried one ERROR node spanning exactly the inserted helper.
        local parser = vim.treesitter.get_string_parser(text, 'lua')
        ok(not parser:parse()[1]:root():has_error(),
            'the synthesized file parses:\n' .. text)
        -- and both members really were rewritten to call it
        local n = select(2, text:gsub(plan.helper .. '%(', ''))
        ok(n >= 3, 'the helper is defined once and called from both members (' .. n .. ')')
    end
    vim.fn.delete(root, 'rf')
end)

-- ⚠⚠ THE HELPER IS INSERTED ABOVE THE EARLIER COPY, SO IT MUST NOT OUTRUN WHAT IT READS.
-- A file-local bound BETWEEN the two copies, and read by the shared body, would be
-- undefined where the helper lands. This is NOT specific to hoisting — it was already
-- true of the plain "insert before the earlier copy" behaviour — which is why the guard
-- asks about the INSERTION LINE and not about the hoist.
-- ★ MY FIRST CUT ASKED ONLY ABOUT NAMES BOUND BETWEEN THE HOIST LINE AND THE MEMBER,
-- and that predicate is UNFIRABLE: the hoist target is the outermost statement
-- containing the member, so anything in between is inside that statement and is not a
-- file-scope binding. It passed this suite by never firing.
test('extract-helper: an insertion that would outrun a file-local it reads is REFUSED', function ()
    if not ready('lua') then skip('no lua parser') end
    local root = proj { ['m.lua'] =
        'local M = {}\n\n'
        .. 'M.alpha = function (x)\n  local y = prep(x)\n  local z = norm(y)\n'
        .. '  local w = enc(z, SALT, \'json\')\n  return w\nend\n\n'
        .. 'local SALT = 7\n\n'
        .. 'M.beta = function (a)\n  local b = prep(a)\n  local c = norm(b)\n'
        .. '  local d = enc(c, SALT, \'yaml\')\n  return d\nend\n\n'
        .. 'return M\n' }
    -- the looser gate this file already keeps for small bodies
    local p = xpair('M.alpha')
    ok(p, 'the two copies are a near-clone pair')
    local plan, why = cx.plan(store, p)
    ok(not plan, 'it refuses rather than inserting above the binding it reads')
    ok(why and why:find('SALT', 1, true),
        'and the refusal NAMES the local it would outrun: ' .. tostring(why))
    vim.fn.delete(root, 'rf')
end)

-- ── THE FOLD'S BEHAVIOURAL RADIUS, DECIDED BY ITS HOLES (CART-0989) ─────────
--
-- ★★★ USER: "I think we can narrow down the what inside the blast radius." The radius is
-- NOT the caller closure: measured on our own tree, the transitive callers of a 2-symbol
-- fold reach 725 symbols (17%). An extraction's text is identical except AT ITS HOLES,
-- so the holes are the only place a behavioural delta can enter — a conditionally
-- evaluated value becoming an eager argument, or an impure value's order moving.
test('extract-helper: an all-LITERAL fold is behaviour-neutral by construction', function ()
    if not ready('lua') then skip('no lua parser') end
    local root = proj { ['m.lua'] =
        'local M = {}\n\n'
        .. 'M.alpha = function (x)\n  local y = prep(x)\n  local z = norm(y)\n'
        .. '  local w = enc(z, \'json\')\n  return w\nend\n\n'
        .. 'M.beta = function (a)\n  local b = prep(a)\n  local c = norm(b)\n'
        .. '  local d = enc(c, \'yaml\')\n  return d\nend\n\nreturn M\n' }
    local p = xpair('M.alpha')
    ok(p, 'a near-clone pair')
    local an = clones.analyze_pair(p, store)
    local b = an.behaviour or {}
    eq(true, b.neutral, 'a literal-only fold cannot change behaviour: ' .. tostring(b.why))
    eq('empty', b.radius, 'so there is nothing to certify')
    -- ★ AND THE PURITY FACT REACHES THE HOLES THAT ARE ACTUALLY LIFTED. It was computed
    -- for STRUCT holes only; measured on our own tree, 0 of 9 lifted holes carried it.
    for _, h in ipairs(an.holes or {}) do
        eq('pure', h.moves, 'the lifted hole carries its purity verdict')
    end
    -- and it rides on the plan, so a caller need not recompute it
    local plan = cx.plan(store, p)
    ok(plan and plan.behaviour and plan.behaviour.neutral,
        'the plan carries the verdict')
    vim.fn.delete(root, 'rf')
end)

-- ⚠ THE OTHER HALF, AND IT MUST NOT BE A REFUSAL. A hole whose value has an EFFECT
-- cannot be lifted without moving that effect to the call site. That is REVIEWABLE, not
-- illegal — refusing it would discard a legal refactoring because we cannot prove
-- something about it, which is the opposite of saying what we know.
test('extract-helper: an IMPURE hole is reported for review, naming the hole', function ()
    if not ready('lua') then skip('no lua parser') end
    local root = proj { ['m.lua'] =
        'local M = {}\n\n'
        .. 'M.alpha = function (x)\n  local y = prep(x)\n  local z = norm(y)\n'
        .. '  local w = enc(z, require(\'cfg\').alpha)\n  return w\nend\n\n'
        .. 'M.beta = function (a)\n  local b = prep(a)\n  local c = norm(b)\n'
        .. '  local d = enc(c, require(\'cfg\').beta)\n  return d\nend\n\nreturn M\n' }
    local p = xpair('M.alpha')
    ok(p, 'a near-clone pair')
    local an = clones.analyze_pair(p, store)
    local b = an.behaviour or {}
    eq(false, b.neutral, 'lifting a `require` moves an effect to the call site')
    eq('members', b.radius, 'and the radius is the members, not the whole caller closure')
    ok((b.why or ''):find('not movable', 1, true), 'the reason says so: ' .. tostring(b.why))
    vim.fn.delete(root, 'rf')
end)
