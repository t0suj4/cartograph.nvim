-- inamed-loop: a tactic LEARNED FROM AN EXAMPLE (toolbelt.learn, 2026-10-12). The rule is re-derived from BEFORE -> AFTER
-- each run (cartograph.byexample): for _, c in tsutil.inext, n, -1 do if c:named() then walk(c) end end -> for _, c in tsutil.inamed, n, -1 do walk(c) end. The example is a CLAIM, not a proof — the specs are the oracle.
local T = require('cartograph.tactic').T
local BEFORE = [[
for _, c in tsutil.inext, n, -1 do if c:named() then walk(c) end end
]]
local AFTER = [[
for _, c in tsutil.inamed, n, -1 do walk(c) end
]]
local function read(root, rel) local fd = io.open(root .. "/" .. rel); if not fd then return nil end; local s = fd:read("a"); fd:close(); return s end
return {
    name = "inamed-loop",
    kind = 'write',
    summary = "rewrite by example: for _, c in tsutil.inext, n, -1 do if c:named() then walk(c) end end -> for _, c in tsutil.inamed, n, -1 do walk(c) end (scope = all | a,b)",
    params = { scope = 'string?' },
    build = function (p) return T.step('rewrite-by-example', { before = BEFORE, after = AFTER, scope = p.scope }) end,
    examples = {
        {
            name = 'the demonstration itself: run on BEFORE with scope = all, it produces AFTER',
            files = { ['example.lua'] = BEFORE .. '\n' },
            params = { scope = 'all' },
            expect = { status = 'done', applied = 1, check = function (root)
                return read(root, 'example.lua') == AFTER .. '\n', 'the demonstration did not reproduce AFTER'
            end },
        },
        {
            name = 'without a scope it STOPS to ask where — the matches are inferred',
            files = { ['example.lua'] = BEFORE .. '\n' },
            expect = { status = 'stopped', applied = 0 },
        },
    },
}
