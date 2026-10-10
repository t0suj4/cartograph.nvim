-- a `variants` declaration (CART-1645): flowtype's answers under four worklist orders, each in its own process —
-- claim FLAGGED: an answer that moves with the order must be `partial` in the baseline (CART-1643), and the stack
-- order is the CONTROL that must move (it did: 268 of 7,917 arktype answers).
--   nvim --headless -u NONE -l tools/toolbelt.lua run variants - decl=@tools/experiments/flowtype_oracle/schedule.lua root=<tree>
return function (params)
    return {
        claim = 'flagged',
        variants = { 'desc', 'asc', 'lifo', 'fifo' },
        control = params.control or 'lifo',
        repeat_ = 2,
        rows = function (order, p)
            local store = require 'cartograph.store'
            store.ingest(require('cartograph.providers.treesitter').extract(p.root))
            local R = require('cartograph.flowtype').solve(store, { open = p.open == 'true', order = order })
            local out = {}
            for _, pr in ipairs(R.probes) do
                out[pr.file .. ':' .. pr.line .. ':' .. pr.col .. ':' .. pr.member] = { pr.kind .. ' ' .. table.concat(pr.targets, ','), flag = pr.partial }
            end
            -- (Lua's answers are VERDICTS on the graph's ambiguous calls)
            local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
            for _, c in ipairs(store.data.calls) do
                local v = R.verdict(c)
                if v and c.at then
                    out['V ' .. callrec.file(c) .. ':' .. atr.sl(c.at) .. ':' .. atr.sc(c.at)] =
                        { v.kind .. ' ' .. table.concat(v.targets or { v.type or '' }, ','), flag = v.partial }
                end
            end
            return out
        end,
    }
end
