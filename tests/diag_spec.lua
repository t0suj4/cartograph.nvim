-- the in-buffer diagnostic surface (diag.lua): multi-producer keys COEXIST
-- (lint signs + escalation signs on the same buffer) and clear is per-key.

local diag = require 'cartograph.diag'

test('diag: keyed producers coexist; publish/clear are per-key', function ()
    diag.clear() -- start clean

    diag.publish({ { file = '/x/a.lua', line = 3, severity = 'warn', message = 'lint-1' } }, 'lint')
    diag.publish({ { file = '/x/a.lua', line = 5, severity = 'error', message = 'esc-1' } }, 'escalate')

    ok(diag.groups.lint and diag.groups.lint.held['/x/a.lua'], 'lint held for the file')
    ok(diag.groups.escalate and diag.groups.escalate.held['/x/a.lua'], 'escalate held for the file')
    eq(1, #diag.groups.lint.held['/x/a.lua'], 'one lint finding')
    eq(1, #diag.groups.escalate.held['/x/a.lua'], 'one escalate finding')
    -- distinct namespaces (the whole point — no clobber)
    ok(diag.groups.lint.ns ~= diag.groups.escalate.ns, 'distinct namespaces per key')

    -- re-publishing lint REPLACES only lint; escalate untouched
    diag.publish({}, 'lint')
    ok(not next(diag.groups.lint.held), 'lint replaced (now empty)')
    ok(diag.groups.escalate.held['/x/a.lua'], 'escalate survived the lint re-publish')

    -- per-key clear
    diag.clear('escalate')
    ok(not next(diag.groups.escalate.held), 'escalate cleared')

    -- severity + line mapping (1-based line -> 0-based lnum)
    diag.publish({ { file = '/x/b.lua', line = 10, severity = 'hint', message = 'm' } }, 'lint')
    local d = diag.groups.lint.held['/x/b.lua'][1]
    eq(9, d.lnum, '1-based line 10 -> 0-based lnum 9')
    eq(vim.diagnostic.severity.HINT, d.severity, 'hint severity mapped')

    -- the return is the count PUBLISHED, not the count submitted: a finding
    -- with no file has nowhere to land, so it is skipped AND not counted
    -- (callers print this number as "N finding(s) on in-buffer signs").
    local n = diag.publish({
        { file = '/x/c.lua', line = 1, severity = 'warn', message = 'filed' },
        { line = 2, severity = 'warn', message = 'no file' },
    }, 'lint')
    eq(1, n, 'file-less finding is dropped and not counted')
    eq(1, #diag.groups.lint.held['/x/c.lua'], 'only the filed one is held')

    diag.clear()
end)
