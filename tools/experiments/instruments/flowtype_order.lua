-- the ORDER TEST (CART-1697): the same tree solved under the default worklist order and asc / lifo / fifo; how many
-- ambiguous-call verdicts move. A schedule-free solve moves none. The other experiments come from the environment
-- (CARTOGRAPH_FLOWTYPE_EXP), so `CARTOGRAPH_FLOWTYPE_EXP=spread,no-sinf` measures that variant's order dependence.
-- params: root (default: the cwd), mode = closed | open (default closed). Output: `ORDER asc <n> lifo <n> fifo <n>`,
-- then `MOVED\t<order>\t<key>\t<default value> => <value>` for the first `show` (default 20) moved rows per order
return { measure = function (_, params)
    params = params or {}
    local root = params.root or vim.fn.getcwd()
    local store = require 'cartograph.store'
    store.ingest(require('cartograph.providers.treesitter').extract(root))
    local callrec, at = require 'cartograph.callrec', require 'cartograph.at'
    local FT = require 'cartograph.flowtype'
    local function rows(order)
        local R = FT.solve(store, { open = params.mode == 'open', ctx = false, order = order })
        local out = {}
        for _, c in ipairs(store.data.calls or {}) do
            local r = c.refused
            if type(r) == 'table' and r.rule == 'ambiguous' then
                local v = R.verdict(c)
                local tg = {}
                for _, t in ipairs(v and v.targets or {}) do tg[#tg + 1] = tostring(t) end
                table.sort(tg)
                out[('%s:%s:%s:%s'):format(tostring(callrec.fn(c)), tostring(callrec.line(c)), tostring(c.at and at.sc(c.at) or 0), tostring(callrec.callee(c)))] =
                    ('%s %s %s %s'):format(v and v.kind or 'nil', v and v.type or '-', v and v.partial and 'partial' or 'whole', table.concat(tg, ','))
            end
        end
        return out
    end
    local base = rows(nil)
    local show = tonumber(params.show or 20)
    local counts, moved = {}, {}
    for _, o in ipairs({ 'asc', 'lifo', 'fifo' }) do
        local r = rows(o)
        local n = 0
        for k, v in pairs(base) do
            if r[k] ~= v then n = n + 1; if n <= show then moved[#moved + 1] = ('MOVED\t%s\t%s\t%s => %s'):format(o, k, v, tostring(r[k])) end end
        end
        counts[#counts + 1] = o .. ' ' .. n
    end
    io.write('ORDER ' .. table.concat(counts, ' ') .. '\n')
    for _, l in ipairs(moved) do io.write(l, '\n') end
    local total = 0
    for c in table.concat(counts, ' '):gmatch('%d+') do total = total + tonumber(c) end
    return { holds = total == 0, why = 'moved: ' .. table.concat(counts, ', ') }
end }
