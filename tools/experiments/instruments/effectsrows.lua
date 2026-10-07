-- the EFFECTS FIXPOINT's answer per function, as rows a `join` instrument compares across two trees, and its time for
-- an `ab`: `ROW\t<fn id>\t<purity> | <the summary's signature>` over the Lua tree `dir` (default: lua/cartograph of
-- the cwd — pass an ABSOLUTE dir so both trees' code reads the SAME source), then `summaries N ms` and the join's
-- stats. The CART-1544 reuse was accepted on this join against the whole-pass fixpoint.
return { measure = function (_, params)
    local dir = params and params.dir or (vim.fn.getcwd() .. '/lua/cartograph')
    local store = require 'cartograph.store'
    store.ingest(require('cartograph.providers.treesitter').extract(dir))
    local E = require 'cartograph.effects'
    local t0 = vim.uv.hrtime()
    local sums = E.summaries(store)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    local function keys(t)
        local ks = {}
        for k, v in pairs(t or {}) do ks[#ks + 1] = tostring(k) .. '=' .. tostring(v == true or (type(v) == 'table' and '') or v) end
        table.sort(ks)
        return table.concat(ks, ',')
    end
    for _, n in ipairs(store.data.nodes) do
        local s = sums[n.id]
        if s then
            io.write('ROW\t', n.id, '\t', tostring(E.purity(store, n.id)), ' | ', table.concat({ s.nk, tostring(s.over), tostring(s.mh),
                tostring(s.nd), tostring(s.jp), s.h and s.h[1] or '', keys(s.w), keys(s.gpk), keys(s.pwx), keys(s.cpo) }, ' '), '\n')
        end
    end
    io.write(('summaries %.1f ms %s\n'):format(ms, vim.inspect(E.join_stats or {}):gsub('%s+', ' ')))
    return {}
end }
