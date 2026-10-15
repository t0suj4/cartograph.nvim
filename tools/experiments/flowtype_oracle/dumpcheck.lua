-- dumpcheck: print require('cartograph.flowcheck').check over a flowtype dump (CART-1710)
--   nvim --headless -u NONE --cmd 'set rtp^=.' -l tools/experiments/flowtype_oracle/dumpcheck.lua <dump.json> [max shown]
local fd = assert(io.open((assert(arg[1], 'usage: dumpcheck.lua <dump.json> [max]'))))
local D = vim.json.decode(fd:read('a'))
fd:close()
local r = require('cartograph.flowcheck').check(D, tonumber(arg[2] or 20))
print(('instructions %d, functions %d, sites %d; FAILED %d, excused (tainted / top destination) %d; unwritten vars %d %s'):format(
    r.ninst, r.functions, r.sites, r.failed, r.excused, r.unwritten, vim.inspect(r.unwritten_ex)))
local ks = {}
for k in pairs(r.counts) do ks[#ks + 1] = k end
table.sort(ks, function (a, b) return r.counts[a] > r.counts[b] end)
for _, k in ipairs(ks) do print(('  %6d  %s'):format(r.counts[k], k)) end
for _, f in ipairs(r.fails) do print('  ' .. f) end
