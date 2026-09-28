-- ALIGN-FAMILY (write): an edit made to ONE member of a near-clone family, carried to the members you choose.
-- The first real goal of CART-1152 was this tactic on spec_for (retained / redundancy). The scope is the operator's:
-- without one the run STOPS on the `propagate-scope` decision before anything is written.
local T = require('cartograph.tactic').T

local function member(n, mul, tail)
    return ('function M.g%d(t)\n    local acc = 0\n    local seen = {}\n    for i = 1, #t do acc = acc + t[i] * %d end\n'
        .. '    local s = tostring(acc)\n    local u = string.upper(s)\n    seen[u] = true\n    local pad = string.rep("-", #u)\n'
        .. '    local out = pad .. u\n    return out .. "%s"\nend\n'):format(n, mul, tail)
end
local FAMILY = 'local M = {}\n' .. member(1, 1, 1) .. member(2, 2, 2) .. member(3, 3, 3) .. 'return M\n'
local function ref_of(store, name)
    for _, n in ipairs(store.data.nodes) do if n.name == name then return store.ref_of(n.id) end end
end
local function call(root, fn, arg)
    local M = dofile(root .. '/fe.lua')
    return M[fn](arg)
end

return {
    name = 'align-family',
    kind = 'write',
    summary = 'carry an edit made to ONE near-clone to its family: ref = the member, text = its new source, scope = member | class | all | clean',
    params = { ref = 'ref', text = 'string', scope = 'string?' },
    build = function (p) return T.step('propagate', { ref = p.ref, text = p.text, scope = p.scope }) end,
    examples = {
        {
            name = 'a VALUE edit to g1 with scope = all: every member multiplies by 9, each keeps its own tail',
            files = { ['fe.lua'] = FAMILY },
            params = function (store) return { ref = ref_of(store, 'M.g1'), text = member(1, 9, 1):gsub('\n$', ''), scope = 'all' } end,
            expect = { status = 'done', applied = 1, check = function (root)
                local got = { call(root, 'g1', { 1, 2 }), call(root, 'g2', { 1, 2 }), call(root, 'g3', { 1, 2 }) }
                return got[1] == '--271' and got[2] == '--272' and got[3] == '--273', table.concat(got, ' ')
            end },
        },
        {
            name = 'no scope: the run STOPS on the scope decision and writes nothing',
            files = { ['fe.lua'] = FAMILY },
            params = function (store) return { ref = ref_of(store, 'M.g1'), text = member(1, 9, 1):gsub('\n$', '') } end,
            expect = { status = 'stopped', applied = 0, check = function (root)
                local fd = io.open(root .. '/fe.lua'); local s = fd:read('a'); fd:close()
                return s == FAMILY, 'the file changed although the run stopped'
            end },
        },
    },
}
