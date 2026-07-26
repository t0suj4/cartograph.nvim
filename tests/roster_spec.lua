-- THE ROSTER REPORT: what an install holds, and which of its problems are real.
--
-- The roster already knew all of this and threw it away. Two claims are worth
-- testing rather than eyeballing, because both were WRONG in the first version and
-- the real mods directory looked fine either way:
--
--   1. ENABLEMENT DECIDES WHETHER A FINDING COUNTS. First run reported 26 conflicts
--      on a healthy install — every pair present-and-disabled, which is the normal
--      state of a mods dir (186 of 197 disabled). `enablement.affects = 'honesty'`
--      is what licenses using it this way: the finding is kept and marked LATENT,
--      never dropped.
--   2. AN OPTIONAL DEPENDENCY IS NOT A MISSING ONE. Optionals outnumber required
--      misses on the real corpus, so folding them together would make every install
--      look broken.
--
-- The parser tests are here because the syntax is the one place a silent
-- mis-parse turns into a confident wrong verdict: `! foo` read as a requirement
-- inverts the answer.

local roster = require 'cartograph.roster'

-- ── dependency syntax ────────────────────────────────────────────────────────

test('roster: every declared dependency prefix parses to its kind', function ()
    local function k(s) return roster.parse_dep(s).kind end
    eq('required', k('other-mod'))
    eq('required', k('~ other-mod'))       -- required, load order not fixed
    eq('optional', k('? other-mod'))
    eq('optional', k('(?) other-mod'))     -- hidden optional
    eq('incompatible', k('! other-mod'))
    -- the LONGEST prefix wins: '(?)' must not read as a bare '(' plus a name
    eq('other-mod', roster.parse_dep('(?) other-mod').name)
    eq('other-mod', roster.parse_dep('! other-mod').name)
end)

test('roster: a version constraint is split from the name, or absent', function ()
    local d = roster.parse_dep('? Krastorio2 >= 1.3.20')
    eq('optional', d.kind); eq('Krastorio2', d.name)
    eq('>=', d.op); eq('1.3.20', d.version)
    local p = roster.parse_dep('space-exploration')
    eq('space-exploration', p.name); eq(nil, p.op)
    -- a name with spaces is real (`A Sea Block Config`) and must survive
    eq('A Sea Block Config', roster.parse_dep('A Sea Block Config >=0.5.1').name)
end)

test('roster: an unparseable dependency is REPORTED, never dropped', function ()
    eq('unparsed', roster.parse_dep('   ').kind)
    eq('unparsed', roster.parse_dep(42).kind)
end)

-- A constraint this cannot evaluate must answer NEITHER satisfied nor violated:
-- reporting a wrong version is worse than reporting no opinion.
test('roster: version satisfaction is three-valued', function ()
    eq(true, roster.satisfies('1.3.0', '>=', '1.2.0'))
    eq(true, roster.satisfies('1.2.0', '>=', '1.2.0'))
    eq(false, roster.satisfies('1.0.0', '>=', '1.2.0'))
    eq(false, roster.satisfies('1.0.0', '=', '1.0.1'))
    eq(true, roster.satisfies('2.0', '>', '1.9'))
    eq(nil, roster.satisfies('1.0.0', '>=', 'x.y'), 'non-numeric: no opinion')
    eq(nil, roster.satisfies('1.0.0', '>>>', '1'), 'undeclared operator: no opinion')
    eq(nil, roster.satisfies('1.0.0', nil, nil), 'no constraint at all')
end)

-- ── the audit over a fixture install ─────────────────────────────────────────

-- Unpacked packages only: the zip path is covered by ecosystem_spec, and what is
-- under test here is the VERDICT layer, which does not care how bytes arrived.
local function install()
    local d = vim.fn.tempname()
    local function w(rel, text)
        local dir = rel:match('^(.*)/[^/]*$')
        if dir then vim.fn.mkdir(d .. '/' .. dir, 'p') end
        local fd = assert(io.open(d .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    local function pkg(name, version, deps, enabled)
        w(('mods/%s/info.json'):format(name), vim.json.encode {
            name = name, version = version, factorio_version = '2.0',
            dependencies = deps,
        })
        w(('mods/%s/control.lua'):format(name), 'return {}\n')
        return { name = name, enabled = enabled }
    end
    local list = {}
    -- LOADS, and every kind of dependency verdict hangs off it
    list[#list + 1] = pkg('Live', '1.0.0', {
        'base >= 2.0.0',            -- provided by the INSTALL, not the mods dir
        'Helper >= 1.0.0',          -- present, satisfied
        'TooOld >= 3.0.0',          -- present at the WRONG version
        'Gone',                     -- required, absent  -> ACTIVE finding
        '? Nice',                   -- optional, absent  -> not a fault
        '! Foe',                    -- present AND loads -> ACTIVE conflict
        '! Sleeper',                -- present, disabled -> LATENT conflict
        '   ',                      -- unparseable       -> reported
    }, true)
    list[#list + 1] = pkg('Helper', '1.4.0', nil, true)
    list[#list + 1] = pkg('TooOld', '1.0.0', nil, true)
    list[#list + 1] = pkg('Foe', '1.0.0', nil, true)
    list[#list + 1] = pkg('Sleeper', '1.0.0', nil, false)
    -- DOES NOT LOAD: its unmet requirement is true and harmless -> LATENT
    list[#list + 1] = pkg('Dormant', '1.0.0', { 'AlsoGone' }, false)
    w('mods/mod-list.json', vim.json.encode { mods = list })
    return d
end

test('roster audit: enablement decides which findings are ACTIVE', function ()
    local d = install()
    local A, why = roster.audit('lua-factorio', { dir = d .. '/mods' })
    ok(A ~= nil, 'audit ran: ' .. tostring(why))
    eq(6, #A.packages)
    eq(4, A.enabled); eq(2, A.disabled); eq(0, A.unlisted)

    -- the required miss from a LOADING package is active; the one from a dormant
    -- package is the same fact with a different consequence
    local act, lat = {}, {}
    for _, m in ipairs(A.deps.missing) do
        if m.active == false then lat[#lat + 1] = m.name else act[#act + 1] = m.name end
    end
    eq({ 'Gone' }, act)
    eq({ 'AlsoGone' }, lat, 'a dormant package keeps its finding, marked latent')

    -- conflicts: both-load is a fault, disabled-side is not
    local cact, clat = {}, {}
    for _, c in ipairs(A.deps.conflicts) do
        if c.active then cact[#cact + 1] = c.name else clat[#clat + 1] = c.name end
    end
    eq({ 'Foe' }, cact)
    eq({ 'Sleeper' }, clat)
    vim.fn.delete(d, 'rf')
end)

test('roster audit: optional-absent, wrong-version and builtin are separate buckets',
    function ()
    local d = install()
    local A = roster.audit('lua-factorio', { dir = d .. '/mods' })
    -- an absent OPTIONAL is never a missing requirement
    eq(1, #A.deps.missing_optional)
    eq('Nice', A.deps.missing_optional[1].name)
    for _, m in ipairs(A.deps.missing) do
        ok(m.name ~= 'Nice', 'an optional never lands in missing')
    end
    -- present, but the constraint fails
    eq(1, #A.deps.version_bad)
    eq('TooOld', A.deps.version_bad[1].name)
    eq('1.0.0', A.deps.version_bad[1].have)
    -- `base` is declared a builtin of the INSTALL: counted apart, because whether it
    -- is really there depends on a root the mods dir cannot answer for
    eq(1, A.deps.builtin)
    for _, m in ipairs(A.deps.missing) do
        ok(m.name ~= 'base', 'a builtin is not reported missing')
    end
    eq(1, #A.deps.unparsed)
    vim.fn.delete(d, 'rf')
end)

-- The rule `filename_hint` carries is "always CONFIRM against the manifest". That
-- rule is only credible if the disagreement is measured, so the report measures
-- BOTH cheap guesses — and they do not fail together, which is the point: on the
-- real corpus the hint agrees 195/195 while the inner directory disagrees 112/195.
test('roster audit: both cheap guesses at identity are scored separately', function ()
    local d = install()
    local A = roster.audit('lua-factorio', { dir = d .. '/mods' })
    -- no archives in this fixture, so neither guess is exercised
    eq(0, A.hint.checked); eq(0, A.inner.checked)
    vim.fn.delete(d, 'rf')
end)

test('roster report: an install with no live faults says so, and stays honest'
    .. ' about the install root', function ()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d .. '/mods/Solo', 'p')
    local fd = assert(io.open(d .. '/mods/Solo/info.json', 'w'))
    fd:write('{"name":"Solo","version":"1.0.0","factorio_version":"2.0"}'); fd:close()
    local L = table.concat(roster.report('lua-factorio', { dir = d .. '/mods' }), '\n')
    ok(L:match('1 package%(s%)') ~= nil, 'counts the package: ' .. L)
    ok(L:match('nothing required is missing') ~= nil, 'clean install reads clean')
    -- ROOTS honesty: with no override the install root is not found, and the spec
    -- says it is NOT DERIVABLE — a different statement from "the search failed"
    ok(L:match('NOT DERIVABLE') ~= nil, 'the spec\'s own claim is what is reported')
    -- enablement wording comes from the spec, not from this module
    ok(L:match('affects HONESTY, never resolution') ~= nil, 'the licensed wording')
    ok(L:match('not listed') ~= nil, 'no mod-list.json: load state UNKNOWN')
    vim.fn.delete(d, 'rf')
end)

test('roster report: a missing package directory REFUSES rather than reporting zero',
    function ()
    local L = roster.report('lua-factorio', { dir = '/nonexistent/mods/dir' })
    eq(1, #L)
    ok(L[1]:match('^roster: ') ~= nil, 'it says why: ' .. L[1])
    ok(L[1]:match('not a directory') ~= nil, L[1])
end)

test('roster report: an unknown ecosystem is refused by name', function ()
    local L = roster.report('lua-nosuch', {})
    ok(L[1]:match('no ecosystem spec') ~= nil, L[1])
end)

-- lua-wow declares identity and a boundary but no `forms`, and a directory full of
-- addons is exactly where "0 packages" would be believed. Before this it CRASHED on
-- eco.roots with a dir given, and returned an empty roster without one.
test('roster: an ecosystem with no package FORMS refuses, naming what it lacks',
    function ()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d .. '/Bagnon', 'p')
    local fd = assert(io.open(d .. '/Bagnon/Bagnon.toc', 'w'))
    fd:write('## Title: Bagnon\n'); fd:close()
    for _, eco in ipairs({ 'lua-wow', 'lua-nvim' }) do
        local L = roster.report(eco, { dir = d })
        eq(1, #L, eco .. ' refuses in one line')
        ok(L[1]:match('declares no package `forms`') ~= nil, L[1])
        -- and it is a REFUSAL, not a report of an empty install
        ok(L[1]:match('0 package') == nil, 'never reports zero: ' .. L[1])
    end
    -- the roster itself refuses, so no caller can accidentally get the empty answer
    local r, why = require('cartograph.spec.ecosystem').roster('lua-wow', { dir = d })
    eq(nil, r); ok(why:match('no package `forms`') ~= nil, tostring(why))
    vim.fn.delete(d, 'rf')
end)
