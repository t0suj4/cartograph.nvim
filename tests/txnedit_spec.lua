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
    local plan = { verb = 'test', touched = { 'm.lua' }, guards = {},
        edit_of = function () error('deliberate', 0) end }
    local before, after, why = txn.dryrun(store, plan)
    eq(nil, before)
    ok(why and why:find('could not be built'), tostring(why))
    ok(why:find('m.lua'), 'and names the file: ' .. tostring(why))
end)
