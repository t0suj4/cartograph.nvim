-- EDIT (write): the GROUND edit as a named tactic (CART-1182) — `before` -> `after` at the one site of `file` where
-- `before` occurs, through the journal, previewed by default. before = '' creates the file. Idempotent: a re-run whose
-- file already holds the result is EMPTY; a file that is neither the pre- nor the post-state is refused by name.
-- The CLI form every hand edit of 2026-09-28 would have been:
--   nvim --headless -u NONE -l tools/toolbelt.lua run edit - file=<rel> before=@<file> after=@<file> apply=1
local T = require('cartograph.tactic').T

return {
    name = 'edit',
    kind = 'write',
    summary = 'the ground edit: file = the key, before = the text at the one site (\'\' creates), after = its replacement; exact-once, idempotent, journaled',
    params = { file = 'string', before = 'string', after = 'string' },
    build = function (p) return T.step('edit', { file = p.file, before = p.before, after = p.after }) end,
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
            name = 'a markdown file: no parser, so the guard makes NO CLAIM — and the edit still applies',
            files = { ['notes.md'] = '# Notes\n\n- one\n' },
            params = { file = 'notes.md', before = '- one\n', after = '- one\n- two\n' },
            expect = { status = 'done', applied = 1, check = function (root)
                local s = io.open(root .. '/notes.md'):read('a')
                return s == '# Notes\n\n- one\n- two\n', s
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
