-- WITNESS-SHAPE-COLLISION (discovery, CART-1154): a durable ref's witness is a SHAPE hash (refs.witness: parameter
-- count, per-statement def/use/dependency counts, callee names), so functions with DIFFERENT bodies can share one —
-- `return x * 2` and `return x + 1` do. That is how a stale ref resolved to a neighbour ("renamed? now 'M.keep'").
-- CLAIM: no two functions with different source share a witness. It FAILS today; the example pins that, and flips —
-- the fence goes red — the day CART-1154 makes the witness body-sensitive, which is the moment to update it.
local atr = require 'cartograph.at'

local function body_text(store, n)
    local lines = store.content(n)
    if type(lines) ~= 'table' or not n.range then return nil end
    local out = {}
    for l = atr.sl(n.range), atr.el(n.range) do out[#out + 1] = lines[l + 1] end
    -- the NAME is not part of the body a witness describes
    return (table.concat(out, '\n'):gsub(vim.pesc(n.name), '<name>', 1))
end

return {
    name = 'witness-shape-collision',
    kind = 'discovery',
    measures = 'CART-1154',
    summary = 'functions whose witness collides although their bodies differ (the witness is a shape hash)',
    params = {},
    measure = function (store)
        local by = {}
        for _, n in ipairs(store.data.nodes or {}) do
            if n.kind == 'function' or n.kind == 'method' then
                local w = (store.ref_of(n.id) or {}).witness
                local b = w and body_text(store, n)
                if b then by[w] = by[w] or {}; table.insert(by[w], { name = n.file .. '::' .. n.name, body = b }) end
            end
        end
        local pairs_, sample = 0, {}
        for _, group in pairs(by) do
            for i = 1, #group do for j = i + 1, #group do
                if group[i].body ~= group[j].body then
                    pairs_ = pairs_ + 1
                    if #sample < 5 then sample[#sample + 1] = group[i].name .. ' ~ ' .. group[j].name end
                end
            end end
        end
        return { pairs = pairs_, sample = sample }
    end,
    claim = function (v)
        return v.pairs == 0, ('%d pair(s) of functions share a witness with different bodies: %s'):format(v.pairs, table.concat(v.sample, ', '))
    end,
    examples = {
        {
            name = 'x * 2 and x + 1 share a witness: the claim FAILS (the defect CART-1154 fixes)',
            files = { ['r.lua'] = 'local M = {}\nfunction M.dbl(x) return x * 2 end\nfunction M.keep(x) return x + 1 end\nreturn M\n' },
            expect = { holds = false, check = function (v) return v.pairs == 1, 'pairs = ' .. v.pairs end },
        },
        {
            name = 'different SHAPES do not collide: a two-statement body beside a one-statement one',
            files = { ['r.lua'] = 'local M = {}\nfunction M.two(x)\n  local y = x + 1\n  return y\nend\nfunction M.one(x) return x end\nreturn M\n' },
            expect = { holds = true },
        },
    },
}
