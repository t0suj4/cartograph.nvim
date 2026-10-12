-- EVERY FLOWTYPE VERDICT over a tree, as rows a `join` instrument compares across two trees: `ROW\t<file>:<line>
-- <callee>\t<kind> [<targets, sorted>]` per call flowtype decides, plus `ROW\tctx <fn id>\tselected` per function the
-- first (keepsat) pass selects for context instances. The gate for a change to the solve that must not move an answer
-- (CART-1659: 1836 rows equal on the 428-file corpus for 4b385d7). Pair with graphrows.lua / lintrows.lua.
--   nvim --headless -u NONE -l tools/toolbelt.lua run @tools/experiments/instruments/verdictrows.lua - dir=<abs dir>
return { measure = function (_, params)
    local dir = params and params.dir or (vim.fn.getcwd() .. '/lua')
    local store = require 'cartograph.store'
    store.ingest(require('cartograph.providers.treesitter').extract(dir))
    local ft, callrec = require 'cartograph.flowtype', require 'cartograph.callrec'
    local R = ft.solve(store, {})
    local rows = {}
    for _, c in ipairs(store.data.calls) do
        local v = R.verdict(c)
        if v then
            local t = {}
            for _, x in ipairs(v.targets or {}) do t[#t + 1] = tostring(x) end
            table.sort(t)
            rows[#rows + 1] = ('ROW\t%s:%s %s\t%s [%s]'):format(tostring(callrec.file(c)), tostring(c.line or c.l or ''),
                tostring(callrec.full(c) or callrec.callee(c)), v.kind, table.concat(t, ','))
        end
    end
    local R1 = ft.solve(store, { keepsat = true, ctx = false })
    for id in pairs(R1.ctxfns or {}) do rows[#rows + 1] = ('ROW\tctx %s\tselected'):format(tostring(id)) end
    table.sort(rows)
    for _, r in ipairs(rows) do io.write(r, '\n') end
    io.write(('VERDICTS %d rows\n'):format(#rows))
    return {}
end }
