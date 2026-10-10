-- a `variants` declaration (CART-1645): flowtype at its cap and at a BIGGER one, each in its own process — claim
-- FLAGGED: an answer that is not `partial` at CAP 64 must be the same at the bigger cap (CART-1643: 0 of 283 arktype,
-- 0 of 445 lua/cartograph moved), and the bigger cap is the CONTROL — it must move the partial ones (192 / 150 did).
--   nvim --headless -u NONE -l tools/toolbelt.lua run variants - decl=@tools/experiments/flowtype_oracle/cap.lua root=<tree> [args=cap=256]
return function (params)
    local big = tonumber(params.cap or 256)
    return {
        claim = 'flagged',
        variants = { 64, big },
        control = tostring(big),
        rows = function (cap, p)
            local FT = require 'cartograph.flowtype'
            FT.CAP = cap
            local store = require 'cartograph.store'
            store.ingest(require('cartograph.providers.treesitter').extract(p.root))
            local R = FT.solve(store, { open = p.open == 'true' })
            local out = {}
            for _, pr in ipairs(R.probes) do
                -- (a `none` is no claim at the small cap: what the bigger one adds there is not a contradiction)
                if pr.kind ~= 'none' or pr.partial then
                    out[pr.file .. ':' .. pr.line .. ':' .. pr.col .. ':' .. pr.member] = { pr.kind .. ' ' .. table.concat(pr.targets, ','), flag = pr.partial }
                end
            end
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
