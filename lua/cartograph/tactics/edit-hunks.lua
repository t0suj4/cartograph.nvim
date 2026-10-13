-- EDIT-HUNKS (write): a change of N hunks to one file as ONE run — every `<dir>/N.b -> <dir>/N.a` pair (in N order) a
-- ground edit, composed with T.seq: one process, one journaled run, ALL-OR-NOTHING — a hunk that is neither the pre- nor
-- the post-state stops the sequence by name, and `on_stop = 'rollback'` UNDOES the hunks already applied (each is a
-- journaled write; forward recovery, not atomicity — tactic.lua). The form every hand edit of a multi-hunk
-- change takes — one process per hunk cost ~3 s each, this ~0.1 s for the lot (2026-10-13).
--   nvim --headless -u NONE -l tools/toolbelt.lua run edit-hunks - file=<rel> dir=<abs dir of N.b / N.a> apply=1
-- (an EMPTY N.b creates the file, as the edit verb does; a hunk file holds the text exactly — `printf '%s'` for one
-- line, a trailing newline is part of the anchor)
local T = require('cartograph.tactic').T

local function read(p) local fd = assert(io.open(p)); local s = fd:read('a'); fd:close(); return s end

return {
    name = 'edit-hunks',
    kind = 'write',
    tags = { 'code' },
    summary = 'N ground edits to one file as one run: dir holds N.b (the text at the site, exact-once; empty creates) and N.a (its replacement), applied in N order through the edit verb (T.seq): idempotent, journaled, a drifted hunk stops the rest',
    params = { file = 'string', dir = 'string' },
    on_stop = 'rollback',
    build = function (p)
        local names = vim.fn.glob(p.dir .. '/*.b', false, true)
        table.sort(names, function (x, y) return tonumber(x:match('(%d+)%.b$')) < tonumber(y:match('(%d+)%.b$')) end)
        local steps = {}
        for _, b in ipairs(names) do
            steps[#steps + 1] = T.step('edit', { file = p.file, before = read(b), after = read((b:gsub('%.b$', '.a'))) })
        end
        return T.seq(unpack(steps))
    end,
    examples = (function ()
        local function hunks(pairs_)
            local d = vim.fn.tempname()
            vim.fn.mkdir(d, 'p')
            for i, h in ipairs(pairs_) do
                local fb = assert(io.open(d .. '/' .. i .. '.b', 'w')); fb:write(h[1]); fb:close()
                local fa = assert(io.open(d .. '/' .. i .. '.a', 'w')); fa:write(h[2]); fa:close()
            end
            return d
        end
        return {
            {
                name = 'two hunks applied in N order in one run',
                files = { ['m.lua'] = 'local M = {}\nM.a = 1\nM.b = 2\nreturn M\n' },
                params = function () return { file = 'm.lua', dir = hunks({ { 'M.a = 1', 'M.a = 10' }, { 'M.b = 2', 'M.b = 20' } }) } end,
                expect = { status = 'done', check = function (root)
                    local s = io.open(root .. '/m.lua'):read('a')
                    return s == 'local M = {}\nM.a = 10\nM.b = 20\nreturn M\n', s
                end },
            },
            {
                name = 'a hunk whose text is not in the file stops the sequence by name — nothing after it is applied',
                files = { ['m.lua'] = 'local M = {}\nM.a = 1\nreturn M\n' },
                params = function () return { file = 'm.lua', dir = hunks({ { 'M.zzz = 1', 'M.zzz = 2' }, { 'M.a = 1', 'M.a = 3' } }) } end,
                expect = { status = 'failed', check = function (root)
                    local s = io.open(root .. '/m.lua'):read('a')
                    return s == 'local M = {}\nM.a = 1\nreturn M\n', s
                end },
            },
            {
                -- (an example's world is a LENS that drops a failed run's staged writes, so this holds with or without
                -- the rollback; on DISK the first hunk WAS left applied until on_stop = 'rollback' — checked
                -- 2026-10-13 through the CLI: applied 1 -> 0, the file as it was)
                name = 'the SECOND hunk drifted: the file is left as it was, the first hunk included',
                files = { ['m.lua'] = 'local M = {}\nM.a = 1\nreturn M\n' },
                params = function () return { file = 'm.lua', dir = hunks({ { 'M.a = 1', 'M.a = 10' }, { 'M.zzz = 1', 'M.zzz = 2' } }) } end,
                expect = { check = function (root)
                    local s = io.open(root .. '/m.lua'):read('a')
                    return s == 'local M = {}\nM.a = 1\nreturn M\n', 'not rolled back: ' .. s
                end },
            },
        }
    end)(),
}
