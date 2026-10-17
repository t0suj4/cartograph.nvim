-- every flowtype verdict on an ambiguous Lua call as a `ROW\t<key>\t<value>` line — a `join` instrument of
-- cartograph.experiment: the same tree under two conditions (CARTOGRAPH_FLOWTYPE_EXP), or two trees
-- params: root (default: the cwd), mode = closed | open (default closed), ctx = 0 | 1 (default 0)
-- key: function, line, column, member; value: kind, type, partial, sorted targets. Last line: `ROWS <n> solve <s> s exp <names>`
return { measure = function (_, params)
    params = params or {}
    local root = params.root or vim.fn.getcwd()
    local store = require 'cartograph.store'
    store.ingest(require('cartograph.providers.treesitter').extract(root))
    local callrec, at = require 'cartograph.callrec', require 'cartograph.at'
    local t0 = vim.uv.hrtime()
    local R = require('cartograph.flowtype').solve(store, { open = params.mode == 'open', ctx = params.ctx == '1' and nil or false })
    local secs = (vim.uv.hrtime() - t0) / 1e9
    local n = 0
    for _, c in ipairs(store.data.calls or {}) do
        local r = c.refused
        if type(r) == 'table' and r.rule == 'ambiguous' then
            local v = R.verdict(c)
            local tg = {}
            for _, t in ipairs(v and v.targets or {}) do tg[#tg + 1] = tostring(t) end
            table.sort(tg)
            io.write(('ROW\t%s:%s:%s:%s\t%s %s %s %s\n'):format(tostring(callrec.fn(c)), tostring(callrec.line(c)), tostring(c.at and at.sc(c.at) or 0),
                tostring(callrec.callee(c)), v and v.kind or 'nil', v and v.type or '-', v and v.partial and 'partial' or 'whole', table.concat(tg, ',')))
            n = n + 1
        end
    end
    local ex = {}
    for k, v in pairs(R.exp or {}) do ex[#ex + 1] = v == true and k or (k .. '=' .. tostring(v)) end
    table.sort(ex)
    io.write(('ROWS %d solve %.1f s exp %s\n'):format(n, secs, #ex > 0 and table.concat(ex, ',') or '-'))
    return { holds = true, why = ('%d rows'):format(n) }
end }
