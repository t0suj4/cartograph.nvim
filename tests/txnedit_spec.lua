-- txn.edit_file's splice contract (CART-0767). The doc line says
-- `reps = {{at, to}} (at = token range)`, and a token range IS single-line — so
-- every shipped caller is safe. NOTHING ENFORCED IT, and the next verb to pass a
-- NODE range would have inherited a silent corruption.

local txn = require 'cartograph.txn'

local FOUR = 'line one\nline two\nline three\nline four\n'

test('txnedit: a single-line replacement still splices (regression)', function ()
    local at = { start = { line = 1, char = 5 }, ['end'] = { line = 1, char = 8 } }
    local out = txn.edit_file(FOUR, nil, { { at = at, to = 'TWO' } }, nil)
    eq('line one\nline TWO\nline three\nline four\n', out)
end)

test('txnedit: two replacements on ONE line apply rightmost-first', function ()
    local a1 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 4 } }
    local a2 = { start = { line = 0, char = 5 }, ['end'] = { line = 0, char = 8 } }
    local out = txn.edit_file(FOUR, nil,
        { { at = a1, to = 'LLLLLLLL' }, { at = a2, to = 'X' } }, nil)
    eq('LLLLLLLL X', vim.split(out, '\n', { plain = true })[1],
        'the left splice must not shift the right one out from under it')
end)

-- ★★ THE BUG, AND IT WAS NOT EVEN OBVIOUSLY BROKEN. The splice takes the START
-- line and then its tail from the END COLUMN — on that same line. Measured on
-- this fixture, replacing (0,5)..(2,4):
--     want   'line REPLACED three'   (four lines collapse to two)
--     got    'line REPLACED one'     (and lines 2-4 untouched)
-- Plausible text, silently wrong, no error. TWO verbs had already declined a
-- multi-line case by name rather than risk it (moveapply's last-member check and
-- `declare`'s), which is a rule held up by two comments instead of by code.
test('txnedit: a MULTI-LINE replacement REFUSES instead of corrupting', function ()
    local at = { start = { line = 0, char = 5 }, ['end'] = { line = 2, char = 4 } }
    local raised, err = pcall(txn.edit_file, FOUR, nil, { { at = at, to = 'REPLACED' } }, nil)
    eq(false, raised, "it must not silently produce text")
    ok(tostring(err):find('spanning lines 1..3'),
        'and names the span it refused: ' .. tostring(err))
end)

-- a raise from an edit callback is THIS PLAN refusing to be built, not a crash to
-- throw past the caller. The scorer already pcall'd for exactly this reason
-- (CART-0372); the two paths that actually build the text did not.
test('txnedit: dryrun turns a raising edit callback into a NAMED refusal', function ()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write('local x = 1\n'); fd:close()
    local store = { data = { root = root }, generation = 1 }
    -- a protocol-COMPLETE plan: a preview refuses exactly what an apply would (txn.stage), so an incomplete one
    -- would be refused for its missing fields before the callback ever ran
    local plan = { verb = 'test', touched = { 'm.lua' }, guards = {}, desc = 'test', preserves = 'none',
        edit_of = function () error('deliberate', 0) end }
    local before, after, why = txn.dryrun(store, plan)
    eq(nil, before)
    ok(why and why:find('could not be built'), tostring(why))
    ok(why:find('m.lua'), 'and names the file: ' .. tostring(why))
end)

-- ★★★ ONE STAGING (CART-1153): `execute` used to re-implement dryrun's body, and the copies drifted — the preview
-- ACCEPTED a plan declaring no guards and a plan that changes nothing, both of which the apply refused, so a preview
-- (or a compose chain) could succeed on a plan the write would refuse. Every refusal before the write is now one
-- function's, so preview and apply refuse the same plans with the same words and class.
test('txnedit: preview and apply refuse the SAME plans, by the same reason and class', function ()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write('local x = 1\n'); fd:close()
    local store = { data = { root = root }, generation = 1 }
    local function complete()
        return { verb = 'test', touched = { 'm.lua' }, guards = {}, desc = 'test', preserves = 'none',
            edit_of = function (_, b) return b .. '-- edited\n' end }
    end
    local cases = {
        { 'no guards', function (p) p.guards = nil end, 'declares no guards', 'unbuilt' },
        { 'no desc', function (p) p.desc = nil end, 'carries no description', 'unbuilt' },
        { 'no claim', function (p) p.preserves = nil end, 'declares no behavioural claim', 'unbuilt' },
        { 'a no-op', function (p) p.edit_of = function (_, b) return b end end, 'would change nothing', 'empty' },
        { 'an escape', function (p) p.touched = { '../escape.lua' } end, 'outside the project', 'ill-posed' },
    }
    for _, c in ipairs(cases) do
        local p = complete(); c[2](p)
        local s, swhy, sclass = txn.stage(store, p)
        eq(nil, s, c[1] .. ': the preview refuses')
        ok(tostring(swhy):find(c[3], 1, true), c[1] .. ': by name: ' .. tostring(swhy))
        eq(c[4], sclass, c[1] .. ': and class')
        local e, ewhy, eclass = txn.execute(store, p)
        eq(nil, e, c[1] .. ': the apply refuses too')
        eq(swhy, ewhy, c[1] .. ': with the same words')
        eq(sclass, eclass, c[1] .. ': and the same class')
    end
    -- and the complete plan stages, with its verdicts
    local s = txn.stage(store, complete())
    ok(s and s.after['m.lua']:find('edited', 1, true), 'a complete plan stages')
    local fd2 = assert(io.open(root .. '/m.lua')); eq('local x = 1\n', fd2:read('a')); fd2:close()
    vim.fn.delete(root, 'rf')
end)
