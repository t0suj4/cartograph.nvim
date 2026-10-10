-- score cartograph.flowtype's Go walker against the type checker: nvim -l goscore.lua <root> <oracle tsv>
local root, otsv = arg[1], arg[2]
local store = require 'cartograph.store'
local t0 = vim.uv.hrtime()
store.ingest(require('cartograph.providers.treesitter').extract(root))
local t1 = vim.uv.hrtime()
local R = require('cartograph.flowtype').of(store, { open = false, exclude = arg[3] ~= 'tests' and '_test%.go$' or nil })
local t2 = vim.uv.hrtime()
local fl = {}
for _, p in ipairs(R.probes) do fl[p.file .. '\t' .. p.line .. '\t' .. p.col .. '\t' .. p.member] = p end
local function declpos(id)
  local f, l = tostring(id):match('^(.-)::.-@(%d+)$')
  return f, tonumber(l)
end
local cnt, ex = {}, {}
local function bump(k, sample) cnt[k] = (cnt[k] or 0) + 1; ex[k] = ex[k] or {}; if #ex[k] < 5 and sample then ex[k][#ex[k] + 1] = sample end end
for ln in io.lines(otsv) do
  local file, line, col, m, kind, rty, df, dl, impl = ln:match('^([^\t]*)\t(%d+)\t(%d+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(%-?%d+)\t?(.*)$')
  if file then
    local scope = (df:match('^EXTERNAL') and 'ext' or 'tree') .. '/' .. kind
    local p = fl[file .. '\t' .. line .. '\t' .. col .. '\t' .. m]
    local v
    if not p then v = 'no-probe'
    elseif p.kind == 'none' or p.kind == 'unknown' then v = p.kind
    elseif kind == 'interface' then
      -- (the checker's answer for an interface call is the INTERFACE's method; flow names CONCRETE methods: each must
      -- be an implementer's — the implementers the checker lists)
      local iset, ni = {}, 0
      for x in (impl or ''):gmatch('[^,]+') do iset[x] = true; ni = ni + 1 end
      local out = 0
      for _, id in ipairs(p.targets) do local f2, l2 = declpos(id); if not iset[(f2 or '?') .. ':' .. tostring(l2)] then out = out + 1 end end
      if out > 0 then v = 'OUTSIDE-IMPLEMENTERS'
      elseif p.kind == 'exact' then v = (ni == 1) and 'impl-exact-only-one' or 'impl-exact-of-several'
      else v = (#p.targets == ni) and 'impl-set-all' or 'impl-set-narrowed' end
    else
      local hit = false
      for _, id in ipairs(p.targets) do local f2, l2 = declpos(id); if f2 == df and l2 == tonumber(dl) then hit = true end end
      if p.kind == 'exact' then v = hit and 'EXACT-RIGHT' or 'EXACT-WRONG'
      else v = hit and ('set-contains(' .. #p.targets .. ')') or 'SET-MISSES' end
    end
    local vv = v:gsub('%(%d+%)', '')
    bump(scope .. ' ' .. vv, (vv == 'EXACT-WRONG' or vv == 'SET-MISSES' or vv == 'no-probe' or vv == 'OUTSIDE-IMPLEMENTERS') and (file .. ':' .. (line + 1) .. ' ' .. m .. ' truth ' .. df .. ':' .. (dl + 1) .. ' flow ' .. (p and table.concat(p.targets, ',') or '-')) or nil)
  end
end
print(('extract %.1f s, flow %.1f s; flow probes %d; %s'):format((t1 - t0) / 1e9, (t2 - t1) / 1e9, #R.probes, vim.inspect(R.stats, { newline = ' ' }):sub(1, 200)))
local ks = {} for k in pairs(cnt) do ks[#ks + 1] = k end table.sort(ks)
for _, k in ipairs(ks) do print(('  %6d  %s'):format(cnt[k], k)) end
for _, k in ipairs(ks) do if #ex[k] > 0 then print(k); for _, e in ipairs(ex[k]) do print('     ', e) end end end
