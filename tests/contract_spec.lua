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
