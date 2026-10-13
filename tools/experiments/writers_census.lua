-- WRITERS CENSUS (CART-1670): the arguments a call hands to a parameter its callee MUTATES (effects' pwx), resolved by
-- flowtype's points-to (opts.argprobes): does the write land in MODULE STATE (every object reaching the argument is
-- reachable from a module root — a file's top-scope locals, a global, a module's return — through fields), never in
-- it, or unknown (a partial / saturated port, no port)?
--   nvim --headless -u NONE --cmd 'set rtp^=.' -l tools/experiments/writers_census.lua <abs dir> [open|closed] [opaque|var|param|fresh]
-- `opaque` (the default) is effects' blind spot — an argument it cannot name hedges its caller; `var` is the CONTROL:
-- the arguments effects already names as module vars must come out as module state, or the reachability is wrong.
-- MEASURED 2026-10-13 on lua/cartograph (closed / open): of 888 opaque positions, 194 / 172 MODULE STATE only (writers
-- the atlas and the summaries do not see), 386 / 304 never module state (a removable hedge), 199 / 340 unknown;
-- control: 11 of 11 resolved var arguments are module state.
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local store = require 'cartograph.store'
store.ingest(require('cartograph.providers.treesitter').extract(arg[1]))
local E = require 'cartograph.effects'
local callrec = require 'cartograph.callrec'
local argv = require 'cartograph.argv'
local want = arg[3] or 'opaque'
local R = require('cartograph.flowtype').solve(store, { argprobes = true, open = arg[2] ~= 'closed' })
local state = R.state_objs()
print('module-state objects: ' .. vim.tbl_count(state))
local sums = E.summaries(store)
local tally, ex = {}, {}
local function bump(k, e) tally[k] = (tally[k] or 0) + 1; ex[k] = ex[k] or {}; if #ex[k] < 3 then ex[k][#ex[k] + 1] = e end end
for _, fnn in ipairs(store.data.nodes) do
    for _, c in ipairs(store.topo():sites(fnn.id)) do
        local to = callrec.to(c)
        local cs = to and sums[to]
        if cs and cs.pwx then
            for pi in pairs(cs.pwx) do
                if E._arg_target(store, c, pi, fnn) == want then
                    local a = argv.at(c, pi)
                    local where = ('%s:%d %s(#%d %s)'):format(callrec.file(c) or '?', callrec.line(c) or 0, (store.node(to) or {}).name or '?', pi, a and tostring(a.name or a.k) or '-')
                    local keys, ids = R.arg_objs(c, pi)
                    if not keys then bump('unknown: ' .. tostring(ids), where)
                    elseif #ids == 0 then bump('no object reaches it', where)
                    else
                        local ins = 0
                        for _, o in ipairs(ids) do if state[o] then ins = ins + 1 end end
                        if ins == #ids then bump('MODULE STATE only', where)
                        elseif ins > 0 then bump('module state + local objects', where)
                        else bump('never module state', where) end
                    end
                end
            end
        end
    end
end
local ks = vim.tbl_keys(tally); table.sort(ks, function (a, b) return tally[a] > tally[b] end)
for _, k in ipairs(ks) do print(('%5d  %-28s %s'):format(tally[k], k, table.concat(ex[k], ' | '))) end
