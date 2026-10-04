-- LEARN-FROM-EXAMPLE (write): make a TACTIC from ONE example, into the analysed PROJECT (`.cartograph/tactics/`).
-- USER (2026-09-28): "Why can't it be a tactic?" · "it can be created project-local and then promoted". Learning is
-- itself a tactic: the rule `before -> after` demonstrates is generalized (cartograph.byexample), rendered as an entry
-- whose FIRST EXAMPLE IS THE DEMONSTRATION, checked against that example on a scratch copy, and only then CREATED —
-- a journaled write, so it can be undone. Compose it: `seq(use('learn-from-example', {...}), use(name, {scope}))`.
-- Promote it into every session's toolbelt with `promote-tactic`.
local T = require('cartograph.tactic').T

return {
    name = 'learn-from-example',
    kind = 'write',
    tags = { 'toolbelt' },
    summary = 'learn a tactic from ONE example into the project (.cartograph/tactics/<name>.lua), born with the example as its test: name, before, after (strings; @file reads one)',
    params = { name = 'string', before = 'string', after = 'string', summary = 'string?' },
    build = function (p) return T.step('learn-tactic', { name = p.name, before = p.before, after = p.after, summary = p.summary }) end,
    examples = {
        {
            name = 'learn `x == nil -> not x` as `nil-check`: the new project tactic exists and reproduces its demonstration',
            files = { ['m.lua'] = 'local M = {}\nreturn M\n' },
            params = { name = 'nil-check', before = 'if x == nil then return 0 end', after = 'if not x then return 0 end' },
            expect = { status = 'done', applied = 1, check = function (root)
                local tb = require 'cartograph.toolbelt'
                local e, why = tb.load('nil-check', nil, root)
                if not e then return false, 'the learned tactic is not discovered: ' .. tostring(why) end
                if e.scope ~= 'project' then return false, 'it should be a PROJECT tactic, is ' .. tostring(e.scope) end
                return tb.example(e, e.examples[1])
            end },
        },
        {
            name = 'a rule that would rewrite its own output is refused — and no file is written',
            files = { ['m.lua'] = 'local M = {}\nreturn M\n' },
            params = { name = 'loops', before = 'return x', after = 'return x + 0' },
            expect = { status = 'failed', applied = 0, check = function (root)
                return vim.fn.filereadable(root .. '/.cartograph/tactics/loops.lua') == 0, 'a refused tactic left a file'
            end },
        },
    },
}
