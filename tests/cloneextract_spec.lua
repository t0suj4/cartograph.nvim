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
