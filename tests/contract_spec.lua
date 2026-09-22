-- The spec contract: the closed slot registry ([[cartograph-spec-layering]]).
-- The load-bearing test is CLOSED-CONTRACT COMPLETENESS — every field the real
-- specs use must be registered, so a new language can't grow the singleton tail
-- without naming the slot (or quarantining it in QUIRKS).

local contract = require 'cartograph.spec.contract'

test('contract: audit classifies fields by group + flags unknowns', function ()
    local mini = {
        toy = { exts = 1, functions = 1, calls = 1, is_method = 1, -- CORE
            scope = 1,           -- SCOPE&KEY
            resolve_import = 1,  -- IMPORTS
            frobnicate = 1 },    -- not in the registry → unknown
    }
    local a = contract.audit(mini)
    ok(a.toy.filled['CORE'], 'CORE filled')
    ok(a.toy.filled['SCOPE&KEY'], 'SCOPE&KEY filled')
    ok(a.toy.filled['IMPORTS'], 'IMPORTS filled')
    ok(not a.toy.filled['TYPES'], 'TYPES empty')
    eq({ 'frobnicate' }, a.toy.unknown)
    ok(a.toy.slots['calls'] and not a.toy.slots['frobnicate'],
        'known slot recorded, unknown not')
end)

test('contract: every group name in SLOTS is a declared GROUP', function ()
    local declared = {}
    for _, g in ipairs(contract.GROUPS) do declared[g.name] = true end
    for field, g in pairs(contract.SLOTS) do
        ok(declared[g], ('slot %s → undeclared group %s'):format(field, g))
    end
end)

-- ★ the enforcement: the CLOSED CONTRACT over the real specs. If this fails, a
-- spec field is unregistered — add it to contract.SLOTS (a real cross-language
-- slot) or quarantine it in QUIRKS with a generalization note.
test('contract: the real specs introduce NO unregistered field (closed)', function ()
    local spec = require('cartograph.providers.treesitter').spec
    local a = contract.audit(spec)
    local offenders = {}
    for lang, rec in pairs(a) do
        if #rec.unknown > 0 then
            offenders[#offenders + 1] = ('%s: %s'):format(lang,
                table.concat(rec.unknown, ', '))
        end
    end
    eq({}, offenders, 'unregistered spec fields (closed-contract violation)')
end)

test('contract: CORE is filled for every language', function ()
    local spec = require('cartograph.providers.treesitter').spec
    local a = contract.audit(spec)
    local missing = {}
    for lang, rec in pairs(a) do
        if not rec.filled['CORE'] then missing[#missing + 1] = lang end
    end
    eq({}, missing, 'languages missing CORE capability')
end)

test('contract: matrix_report renders a row per language + the ladder header', function ()
    local spec = require('cartograph.providers.treesitter').spec
    local lines = table.concat(contract.matrix_report(spec), '\n')
    ok(lines:find('capability matrix'), 'has title')
    ok(lines:find('CORE') and lines:find('QUIRKS'), 'has ladder header')
    ok(lines:find('\nlua%s'), 'has a lua row')
    ok(not lines:find('UNREGISTERED'), 'no closed-contract violation in the report')
end)

-- CART-1022: the gaps the work list had. `matrix_report` is group-granular, the contract
-- knew nothing of the algebra layer, and "deliberately absent" lived only in prose.

test('contract: gaps are FIELD-level and priced against peers, not counted raw', function ()
    -- the most-owed field is named LAST alphabetically on purpose: with ranking disabled
    -- the tiebreak would put `c` first and the assertion could not tell the two apart
    local spec = { lua = { a = 1, zz = 1, c = 1 }, go = { a = 1 }, rust = { a = 1, zz = 1 } }
    local SAVE = contract.SLOTS
    contract.SLOTS = { a = 'CORE', zz = 'CORE', c = 'CORE', d = 'CORE' }
    local g = contract.gaps(spec, 'go')
    contract.SLOTS = SAVE
    -- ★★★ THE PEER COUNT IS THE POINT. `zz` is declared by 2 of the other 2 specs and go
    -- lacks it: real. `c` by 1 of 2. `d` by nobody — an unfilled slot that is not work.
    local byfield = {}
    for _, u in ipairs(g.CORE.unfilled) do byfield[u.field] = u.n end
    eq(2, byfield.zz)
    eq(1, byfield.c)
    eq(0, byfield.d)
    -- and they are RANKED, so the first thing read is the most owed
    eq('zz', g.CORE.unfilled[1].field)
end)

test('★★★ contract: a raw unfilled count is NOT a work list — lua proves it', function ()
    local ts = require 'cartograph.providers.treesitter'
    local g = contract.gaps(ts.spec, 'lua')
    local raw, owed = 0, 0
    for _, grp in ipairs(contract.GROUPS) do
        for _, u in ipairs(g[grp.name].unfilled) do
            raw = raw + 1
            if u.n * 2 >= (g.nlangs - 1) then owed = owed + 1 end
        end
    end
    -- ⚠ THE REFERENCE IMPLEMENTATION OMITS DOZENS OF REGISTERED FIELDS, because most slots
    -- are optional by design. A report that called those a work list would say the most
    -- complete language in the tree has the most to do.
    ok(raw > 40, 'lua omits many registered fields: ' .. raw)
    ok(owed * 4 < raw, ('and almost none are OWED: %d of %d'):format(owed, raw))
end)

test('contract: an INAPPLICABLE field is a decision with a reason, not a todo', function ()
    for field, langs in pairs(contract.INAPPLICABLE) do
        ok(contract.SLOTS[field], field .. ' is a registered slot')
        for lang, reason in pairs(langs) do
            ok(type(reason) == 'string' and #reason > 20,
                ('%s/%s must carry a REASON, not a flag'):format(field, lang))
        end
    end
    local ts = require 'cartograph.providers.treesitter'
    local g = contract.gaps(ts.spec, 'go')
    -- go's module_scaffold is declared inapplicable, so it must NOT appear as unfilled
    ok(g.IMPORTS.inapplicable.module_scaffold, 'it is recorded as a decision')
    for _, u in ipairs(g.IMPORTS.unfilled) do
        eq(nil, u.field == 'module_scaffold' and 'leaked into unfilled' or nil)
    end
end)

test('★★★ contract: the PREREQUISITES it does not own are named', function ()
    ok(#contract.PREREQS >= 2, 'the algebra-layer prerequisites are declared')
    for _, p in ipairs(contract.PREREQS) do
        ok(p.name and p.where and p.unlocks and p.test, p.name .. ' says where it lives')
        -- ⚠ NOT SLOTS. A prerequisite is not a spec field and must never be auditable as
        -- one, or a language could "fill" it by declaring a key.
        eq(nil, contract.SLOTS[p.name])
    end
    local ts = require 'cartograph.providers.treesitter'
    local rep = table.concat(contract.gap_report(ts.spec, 'go'), '\n')
    ok(rep:match('reader grammar%s+ABSENT'), 'go lacks the reader grammar:\n' .. rep)
    local lrep = table.concat(contract.gap_report(ts.spec, 'lua'), '\n')
    ok(lrep:match('reader grammar%s+PRESENT'), 'lua has it — the control')
end)
