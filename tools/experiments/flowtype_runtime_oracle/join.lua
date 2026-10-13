-- the RUNTIME ORACLE's join (CART-1672): every flowtype verdict on a Lua call scored against the suite's observed
-- (site -> callee) pairs (record.sh). A `string` / `typed` verdict says only an outside value is the receiver: an
-- in-tree same-named callee observed at the site makes it WRONG. An `exact` / `narrowed` verdict is WRONG when only
-- callees outside its targets ran there. `not-executed` = the suite never ran the site (no evidence either way).
--   nvim --headless -u NONE --cmd 'set rtp^=.' -l tools/experiments/flowtype_runtime_oracle/join.lua <tree> <calls.tsv> [open|closed] [ctx=0]
-- (promoted from a scratch join of 2026-10-10/11, the oracle behind CART-1651 / 1653's numbers)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local tree, tsv = arg[1], arg[2]
local mode, ctx = 'closed', true
for i = 3, #arg do if arg[i] == 'open' or arg[i] == 'closed' then mode = arg[i] elseif arg[i] == 'ctx=0' then ctx = false end end
local store = require 'cartograph.store'
local callrec = require 'cartograph.callrec'
local atr = require 'cartograph.at'
store.ingest(require('cartograph.providers.treesitter').extract(tree))
local data = store.data
local t0 = vim.uv.hrtime()
local R = require('cartograph.flowtype').solve(store, { open = mode == 'open', ctx = ctx and nil or false })
local secs = (vim.uv.hrtime() - t0) / 1e9
local seen, pairs_n = {}, 0
for ln in io.lines(tsv) do
  local k, ck = ln:match('^(.-)\t(.*)$')
  if k then local t = seen[k]; if not t then t = {}; seen[k] = t end; t[ck] = true; pairs_n = pairs_n + 1 end
end
local byline = {}
for _, nd in ipairs(data.nodes) do
  if (nd.kind == 'function' or nd.kind == 'method') and nd.range then byline[nd.file .. ':' .. (atr.sl(nd.range) + 1)] = nd.id end
end
local cnt, ex = {}, {}
local function bump(k, e) cnt[k] = (cnt[k] or 0) + 1; ex[k] = ex[k] or {}; if e and #ex[k] < 10 then ex[k][#ex[k] + 1] = e end end
for _, c in ipairs(data.calls) do
  local v = R.verdict(c)
  if v and c.at and (v.kind == 'string' or v.kind == 'typed') then
    -- (a TYPE verdict says the receiver is only an outside value: no in-tree callee of the name may run here)
    local key = callrec.file(c) .. ':' .. (atr.sl(c.at) + 1)
    local name = tostring(callrec.full(c) or callrec.callee(c))
    local member = name:match('[:.]([%w_]+)$') or name
    local fns = seen[key]
    local tag = v.kind .. (v.partial and '~' or '')
    if not fns then bump(tag .. ' not-executed')
    else
      local intree
      for ck in pairs(fns) do local id = byline[ck]; if id and id:match('[%.:]' .. member .. '@%d+$') then intree = id end end
      if intree then bump(tag .. ' WRONG', key .. ' ' .. name .. ' ' .. tostring(v.type) .. ' RAN ' .. intree)
      else bump(tag .. ' RIGHT (only outside callees ran)') end
    end
  end
  if v and c.at and (v.kind == 'exact' or v.kind == 'narrowed') then
    local key = callrec.file(c) .. ':' .. (atr.sl(c.at) + 1)
    local name = tostring(callrec.full(c) or callrec.callee(c))
    local member = name:match('[:.]([%w_]+)$') or name
    local fns = seen[key]
    if not fns then bump(v.kind .. (v.partial and '~' or '') .. ' not-executed')
    else
      local ran, want = {}, {}
      for _, t in ipairs(v.targets) do want[t] = true end
      for ck in pairs(fns) do
        local id = byline[ck]
        if id and id:match('[%.:]' .. member .. '@%d+$') then ran[id] = true end
      end
      local outside, inside = nil, false
      for id in pairs(ran) do if want[id] then inside = true else outside = id end end
      if outside and not inside then bump(v.kind .. (v.partial and '~' or '') .. ' WRONG', key .. ' ' .. name .. ' flow ' .. table.concat(v.targets, ',') .. ' RAN ' .. outside)
      elseif outside then bump(v.kind .. (v.partial and '~' or '') .. ' target ran + another (tail-call chain, or a missed target)', key .. ' ' .. name .. ' also ' .. outside)
      elseif inside then bump(v.kind .. (v.partial and '~' or '') .. ' RIGHT')
      else bump(v.kind .. ' executed, no same-named callee observed', key .. ' ' .. name) end
    end
  end
end
print('observed pairs', pairs_n)
local ks = {} for k in pairs(cnt) do ks[#ks + 1] = k end table.sort(ks)
for _, k in ipairs(ks) do print(('  %5d  %s'):format(cnt[k], k)) end
for _, k in ipairs(ks) do if k:match('WRONG') or k:match('another') then print(k); for _, e in ipairs(ex[k] or {}) do print('    ', e) end end end
local unknown = 0
for _, pr in ipairs(R.probes or {}) do if pr.kind == 'unknown' then unknown = unknown + 1 end end
print(('mode %s, context %s: solve %.1f s, %d unknown probes'):format(mode, ctx and 'on' or 'off', secs, unknown))
