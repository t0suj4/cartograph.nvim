-- EDIT (write): the GROUND edit as a named tactic (CART-1182) — `before` -> `after` at the one site of `file` where
-- `before` occurs, through the journal, previewed by default. before = '' creates the file. Idempotent: a re-run whose
-- file already holds the result is EMPTY; a file that is neither the pre- nor the post-state is refused by name.
-- The CLI form every hand edit of 2026-09-28 would have been:
--   nvim --headless -u NONE -l tools/toolbelt.lua run edit - file=<rel> before=@<file> after=@<file> apply=1
local T = require('cartograph.tactic').T

return {
    name = 'edit',
    kind = 'write',
    tags = { 'code' },
    summary = 'the ground edit: file = the key, before = the text at the one site (\'\' creates), after = its replacement; exact-once, idempotent, journaled; count = N: the text occurs at exactly N sites and every one is replaced',
    params = { file = 'string', before = 'string', after = 'string', count = 'string?' },
    build = function (p) return T.step('edit', { file = p.file, before = p.before, after = p.after, count = p.count }) end,
    examples = {
        {
            name = 'one site edited through the journal; the re-run is empty',
            files = { ['m.lua'] = 'local M = {}\nM.x = 1\nreturn M\n' },
            params = { file = 'm.lua', before = 'M.x = 1', after = 'M.x = 2' },
            expect = { status = 'done', applied = 1, check = function (root)
                local s = io.open(root .. '/m.lua'):read('a')
                return s == 'local M = {}\nM.x = 2\nreturn M\n', s
            end },
        },
        {
            -- (pinned because a probe with a NON-empty `before` on a missing file was read as "the verb cannot create":
            -- CART-1203, filed on that misreading and closed invalid)
            name = 'before = \'\' CREATES a file that does not exist, under the same parse guard; the re-run is empty',
            files = { ['m.lua'] = 'return 1\n' },
            params = { file = 'new/n.lua', before = '', after = 'local N = {}\nreturn N\n' },
            expect = { status = 'done', applied = 1, check = function (root)
                local fd = io.open(root .. '/new/n.lua')
                local s = fd and fd:read('a')
                return s == 'local N = {}\nreturn N\n', tostring(s)
            end },
        },
        {
            name = 'a markdown file: no parser, so the guard makes NO CLAIM — and the edit still applies',
            files = { ['notes.md'] = '# Notes\n\n- one\n' },
            params = { file = 'notes.md', before = '- one\n', after = '- one\n- two\n' },
            expect = { status = 'done', applied = 1, check = function (root)
                local s = io.open(root .. '/notes.md'):read('a')
                return s == '# Notes\n\n- one\n- two\n', s
            end },
        },
        {
            -- (CART-1486: the same lines twice in one file — treesitter.lua's link and relink — were hand-patched)
            name = 'count = 2: the text occurs at exactly two sites and BOTH are replaced; the re-run is empty',
            files = { ['m.lua'] = 'local function a() local x = 1; return x end\nlocal function b() local x = 1; return x end\nreturn a() + b()\n' },
            params = { file = 'm.lua', before = 'local x = 1', after = 'local x = 2', count = '2' },
            expect = { status = 'done', applied = 1, check = function (root)
                local s = io.open(root .. '/m.lua'):read('a')
                return s == 'local function a() local x = 2; return x end\nlocal function b() local x = 2; return x end\nreturn a() + b()\n', s
            end },
        },
        {
            name = 'count = 2 on an INSERT (the result contains the text): both sites, each once',
            files = { ['m.lua'] = 'local function a(x) return x end\nlocal function b(x) return x end\nreturn a(1) + b(2)\n' },
            params = { file = 'm.lua', before = 'return x end', after = 'x = x + 1; return x end', count = '2' },
            expect = { status = 'done', applied = 1, check = function (root)
                local s = io.open(root .. '/m.lua'):read('a')
                return s == 'local function a(x) x = x + 1; return x end\nlocal function b(x) x = x + 1; return x end\nreturn a(1) + b(2)\n', s
            end },
        },
        {
            name = 'a count that does not match the sites is REFUSED by name — nothing is written',
            files = { ['m.lua'] = 'local function a() local x = 1; return x end\nlocal function b() local x = 1; return x end\nreturn a() + b()\n' },
            params = { file = 'm.lua', before = 'local x = 1', after = 'local x = 2', count = '3' },
            expect = { applied = 0, check = function (root, r)
                local s = io.open(root .. '/m.lua'):read('a')
                return s:find('local x = 2', 1, true) == nil, s
            end },
        },
        {
            name = 'an edit that would break the syntax is refused by the parse guard: nothing is written',
            files = { ['m.lua'] = 'local M = {}\nreturn M\n' },
            params = { file = 'm.lua', before = 'return M', after = 'return (M' },
            expect = { status = 'failed', applied = 0, check = function (root)
                return io.open(root .. '/m.lua'):read('a') == 'local M = {}\nreturn M\n', 'the file was written'
            end },
        },
    },
}
