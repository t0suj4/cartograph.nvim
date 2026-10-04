-- PROMOTE-TACTIC (write): copy a PROJECT tactic into the BUILT-IN toolbelt, so every session has it. The graph is the
-- PROJECT; when the built-in directory lies outside it, the write is CROSS-WORLD (CART-1160 step 5): journaled in the
-- toolbelt's own world, and the `promote` decision is also the grant to write there. ★ ALWAYS A DECISION: a promoted
-- tactic is in every session's toolbelt, so the run STOPS on `promote` until confirm = yes. It is checked first: the
-- entry must pass its own examples, and an existing built-in with that name is never overwritten.
local T = require('cartograph.tactic').T

-- a minimal project tactic, for the examples: a discovery that counts the functions in a graph
local SMALL = [[
return {
    name = 'count-functions', kind = 'discovery', summary = 'how many functions the graph holds', params = {},
    measure = function (store) local n = 0; for _, x in ipairs(store.data.nodes or {}) do if x.kind == 'function' then n = n + 1 end end; return n end,
    claim = function (n) return n > 0, n .. ' function(s)' end,
    examples = { { name = 'one function', files = { ['a.lua'] = 'local function f() end\nreturn f\n' }, expect = { holds = true } } },
}
]]
local function params(confirm)
    return function (store)
        return { name = 'count-functions', from = store.data.root, into = store.data.root .. '/builtin', confirm = confirm }
    end
end

return {
    name = 'promote-tactic',
    kind = 'write',
    tags = { 'toolbelt' },
    summary = 'promote a PROJECT tactic into the built-in toolbelt (every session gets it): name, from = the project root; stops on the `promote` decision until confirm = yes',
    params = { name = 'string', from = 'string', into = 'string?', confirm = 'string?' },
    build = function (p)
        return T.step('promote-tactic', { name = p.name, from = p.from, into = p.into }, p.confirm == 'yes' and { 'promote' } or nil)
    end,
    examples = {
        {
            name = 'without confirm = yes it STOPS on the promote decision, and writes nothing',
            files = { ['.cartograph/tactics/count-functions.lua'] = SMALL },
            params = params(nil),
            expect = { status = 'stopped', applied = 0, check = function (root)
                return vim.fn.filereadable(root .. '/builtin/count-functions.lua') == 0, 'promoted without a decision'
            end },
        },
        {
            name = 'confirmed, the tactic is copied byte for byte into the built-in directory',
            files = { ['.cartograph/tactics/count-functions.lua'] = SMALL },
            params = params('yes'),
            expect = { status = 'done', applied = 1, check = function (root)
                local fd = io.open(root .. '/builtin/count-functions.lua'); if not fd then return false, 'not promoted' end
                local s = fd:read('a'); fd:close()
                return s == SMALL, 'the promoted copy differs from the project tactic'
            end },
        },
    },
}
