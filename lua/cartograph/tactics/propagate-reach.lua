-- PROPAGATE-REACH (discovery, CART-1155): over a tree's near-clone families, how many sibling members can
-- txn_plan_propagate re-render? Each member is rendered for an IDENTITY change (its own values) on both paths, the
-- value path (its own text as donor) and the template path (the origin's text as donor). CLAIM: every sibling renders
-- on both. MEASURED on lua/cartograph (2026-09-28): value 12/50, template 4/50 — the claim fails, and CART-1155 is
-- the work that moves the numbers. `tools/toolbelt.lua run propagate-reach <dir>` re-measures any tree.
local atr = require 'cartograph.at'

local function member(n, mul)
    return ('function M.g%d(t)\n    local acc = 0\n    local seen = {}\n    for i = 1, #t do acc = acc + t[i] * %d end\n'
        .. '    local s = tostring(acc)\n    local u = string.upper(s)\n    seen[u] = true\n    local pad = string.rep("-", #u)\n'
        .. '    local out = pad .. u\n    return out .. "%d"\nend\n'):format(n, mul, n)
end

return {
    name = 'propagate-reach',
    kind = 'discovery',
    tags = { 'find', 'code' },
    measures = 'CART-1155',
    summary = 'how many near-clone siblings the propagate renderer can reach, per path (value / template), with the refusal reasons',
    params = {},
    measure = function (store)
        local clones = require 'cartograph.clones'
        local r = clones.families(store, {})
        local v = { families = 0, members = 0, value = 0, template = 0, reasons = {} }
        for _, fam in ipairs((r and r.families) or {}) do
            v.families = v.families + 1
            local nd = store.node(fam.members[1].id)
            local lines = nd and store.content(nd)
            local text
            if type(lines) == 'table' and nd.range then
                local out = {}
                for l = atr.sl(nd.range), atr.el(nd.range) do out[#out + 1] = lines[l + 1] end
                text = table.concat(out, '\n')
            end
            local P = text and clones.family_propagate(fam, 1, text, store)
            if P then
                P.new_template = P.new_template or fam.template
                for j = 2, #fam.members do
                    v.members = v.members + 1
                    for _, path in ipairs { 'value', 'template' } do
                        local ok, why = clones.family_member_text(fam, P, 1, text, j, store,
                            { holes = {}, template = path == 'template', values = fam.values[j] })
                        if ok then v[path] = v[path] + 1
                        else
                            local k = path .. ': ' .. tostring(why):gsub('%d+', 'N'):sub(1, 80)
                            v.reasons[k] = (v.reasons[k] or 0) + 1
                        end
                    end
                end
            end
        end
        return v
    end,
    claim = function (v)
        return v.value == v.members and v.template == v.members,
            ('%d family member(s): value path %d, template path %d'):format(v.members, v.value, v.template)
    end,
    examples = {
        {
            name = 'a family of three whose members differ only in holes: FULL reach on both paths',
            files = { ['fe.lua'] = 'local M = {}\n' .. member(1, 1) .. member(2, 2) .. member(3, 3) .. 'return M\n' },
            expect = { holds = true, check = function (v) return v.members == 2 and v.value == 2 and v.template == 2, vim.inspect(v) end },
        },
        {
            name = 'a sibling with a comment of its own: the template path refuses it (its surface differs), the value path does not',
            files = { ['fe.lua'] = 'local M = {}\n' .. member(1, 1) .. member(2, 2)
                .. member(3, 3):gsub('    local s = tostring', '    -- only g3 says this\n    local s = tostring') .. 'return M\n' },
            expect = { holds = false, check = function (v) return v.value == 2 and v.template == 1, vim.inspect(v) end },
        },
    },
}
