-- CART-1030 / CART-1017: which references did an edit re-point.
--
-- ★★★ THE FAILURE THIS GUARDS: a template edit that renames `changed` in the kernel renamed
-- ONE of three occurrences in each of seven real members, and all seven still PARSED. A
-- parse check cannot see a binding change; this compares the binding before and after.

local RB = require 'cartograph.rebind'

local function ready()
    local okl = pcall(vim.treesitter.language.add, 'lua')
    if not okl then skip('no lua tree-sitter parser') end
end

local BASE = table.concat({
    'local changed = true',                                     -- 1
    'local t = {}',                                             -- 2
    'while changed do',                                         -- 3
    '  changed = false',                                        -- 4
    '  for i = 1, #t do if t[i] then changed = true end end',   -- 5
    '  print(t.x)',                                             -- 6
    'end', '' }, '\n')

local function kinds(list)
    local n = {}
    for _, r in ipairs(list) do n[r.kind] = (n[r.kind] or 0) + 1 end
    return n
end

test('no edit: every reference is kept and nothing is refused (the known-nonzero counter)', function ()
    ready()
    local v, why = RB.check(BASE, BASE)
    ok(v, tostring(why))
    eq(true, v.ok)
    ok(v.counts.kept >= 8, 'the index found the references: ' .. v.counts.kept)
    eq(0, v.counts.substituted + v.counts.introduced + v.counts.removed)
end)

test('★★★ the kernel-rename shape: one of three uses renamed -> UNBOUND, naming the two left behind', function ()
    ready()
    local v = RB.check(BASE, (BASE:gsub('  changed = false', '  dirty = false')))
    eq(false, v.ok)
    eq(1, #v.refusals)
    local r = v.refusals[1]
    eq('unbound', r.kind); eq('changed', r.name); eq('dirty', r.to); eq(4, r.line)
    eq(2, r.siblings_kept)
    ok(r.why:find('local `changed` of line 1', 1, true), r.why)
end)

test('renaming the declaration and every use is consistent: RENAMED, not refused', function ()
    ready()
    local v = RB.check(BASE, (BASE:gsub('%f[%w_]changed%f[^%w_]', 'dirty')))
    eq(true, v.ok)
    eq(3, kinds(v.reports).renamed)
end)

test('every use renamed but the declaration kept is still UNBOUND — the declaration keeps the old name', function ()
    ready()
    local after = BASE:gsub('while changed', 'while dirty'):gsub('  changed = false', '  dirty = false')
        :gsub('then changed', 'then dirty')
    local v = RB.check(BASE, after)
    eq(false, v.ok)
    eq(3, kinds(v.refusals).unbound)
    ok(v.refusals[1].why:find('the declaration keeps the old name', 1, true), v.refusals[1].why)
end)

test('★★★ CAPTURE: an inserted local re-points references the edit never touched', function ()
    ready()
    local v = RB.check(BASE, (BASE:gsub('  changed = false\n', '  changed = false\n  local t = nil\n')))
    eq(false, v.ok)
    eq(3, kinds(v.refusals).captured) -- `#t`, `t[i]`, and `t` in print(t.x)
    eq('t', v.refusals[1].name)
end)

test('CAPTURE of a library name: shadowing `print` above its use', function ()
    ready()
    local v = RB.check(BASE, (BASE:gsub('local t = {}', 'local t = {}\nlocal print = nil')))
    eq(false, v.ok)
    eq(1, #v.refusals)
    eq('captured', v.refusals[1].kind); eq('print', v.refusals[1].name)
end)

test('changing which global is called is what an edit is FOR: RETARGETED, reported, not refused', function ()
    ready()
    local v = RB.check(BASE, (BASE:gsub('print', 'log')))
    eq(true, v.ok)
    eq(1, kinds(v.reports).retargeted)
end)

test('a local retargeted to a global on purpose: refused by default, the refusal names allow_unbound, which lifts it', function ()
    ready()
    local before = 'local log = print\nlog(1)\n'
    local after = 'local log = print\nprint(1)\n'
    local v = RB.check(before, after)
    eq(false, v.ok); eq('unbound', v.refusals[1].kind)
    ok(v.refusals[1].why:find('allow_unbound', 1, true), v.refusals[1].why)
    local v2 = RB.check(before, after, { allow_unbound = true })
    eq(true, v2.ok)
    eq('retargeted', v2.reports[1].kind)
end)

test('an inserted statement reports its new free names and refuses nothing', function ()
    ready()
    local v = RB.check(BASE, (BASE:gsub('  changed = false\n', '  changed = false\n  iter = iter + 1\n')))
    eq(true, v.ok)
    eq(2, v.counts.introduced)
    eq(true, v.reports[1].free)
end)

test('a field is not a name: `t.x` -> `t.y` changes no binding', function ()
    ready()
    local v = RB.check(BASE, (BASE:gsub('t%.x', 't.y')))
    eq(true, v.ok)
    eq(0, #v.reports)
end)

test('a line inserted ABOVE shifts every offset and still pairs every reference', function ()
    ready()
    local v = RB.check(BASE, '-- a comment\n' .. BASE)
    eq(true, v.ok)
    eq(0, v.counts.introduced + v.counts.substituted + v.counts.removed)
end)

test('★★ two same-named locals in ONE edited line pair by POSITION, not by name order', function ()
    ready()
    -- deleting the inner `print(x)` leaves the outer one; pairing by name order matched the
    -- surviving outer `x` with the deleted inner one and called the deletion a capture
    local before = 'local x = 1\ndo local x = 2 print(x) end print(x)\n'
    local v = RB.check(before, 'local x = 1\ndo local x = 2 end print(x)\n')
    eq(true, v.ok)
    eq(2, v.counts.removed) -- the deleted `print` and `x`
    -- and the mirror: a real capture on the same line is still seen
    local v2 = RB.check('local x = 1\ndo print(x) end\n', 'local x = 1\ndo local x = 2 print(x) end\n')
    eq(false, v2.ok)
    eq('captured', v2.refusals[1].kind)
end)

test('★★ `function M.f` puts a declaration and the reference `M` at ONE offset — both are paired', function ()
    ready()
    -- 1526 of 164880 occurrences in this repo share an offset this way; keyed by offset alone the
    -- ref was dropped inside a hunk, and a capture of `M` on an edited line went unseen
    local v = RB.check('local M = {}\nfunction M.f() return 1 end\n',
        'local M = {}\nlocal M = nil function M.f() return 1 end\n')
    eq(false, v.ok)
    eq('captured', v.refusals[1].kind); eq('M', v.refusals[1].name)
end)

test('check_splice is check on the spliced text', function ()
    ready()
    local s = BASE:find('  changed = false', 1, true) - 1
    local v = RB.check_splice(BASE, s, s + #'  changed = false', '  dirty = false')
    eq(false, v.ok); eq('unbound', v.refusals[1].kind)
end)

test('another language is an honest absence, not "nothing re-pointed"', function ()
    local v, why = RB.check('x = 1', 'x = 2', { lang = 'python' })
    eq(nil, v)
    ok(why:find('Lua-only', 1, true), why)
end)
