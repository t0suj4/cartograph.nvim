-- TS-analyzer disagreement harvest: cartograph's ts.extract vs the TypeScript
-- compiler API's resolution (tsresolve.mjs dump), keyed (file, line, callee).
-- A both-resolved-DIFFERENT-target = a real bug on ONE side (the north-star).
--   nvim -l tools/harvest_ts.lua <corpus-root> <tsdump.json>
local here = debug.getinfo(1,'S').source:sub(2):match('^(.*)/[^/]+$')
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local prov = require 'cartograph.providers.treesitter'
local root, dumpf = arg[1], arg[2]

local fh = io.open(dumpf,'r'); local ts = vim.json.decode(fh:read('*a')); fh:close()
local data = prov.extract(root)
local nidx = {}; for _,n in ipairs(data.nodes) do nidx[n.id]=n end

-- cartograph call index: (file,line,callee) -> call
local cidx = {}
for _, c in ipairs(data.calls or {}) do
  if c.callee then cidx[(c.file or '')..'\31'..(c.line or -1)..'\31'..c.callee] = c end
end

local function cg_target(c) -- {file,line} or nil
  if not c or not c.to then return nil end
  local n = nidx[c.to]; if not n or not n.range then return nil end
  return { file = n.file, line = n.range.start.line, name = n.name }
end

local T = { agree=0, disagree=0, tsc_only=0, cg_only=0, paired=0, unpaired=0, both_ext=0 }
local samples = {}
for _, tc in ipairs(ts.calls or {}) do
  -- try exact line, then +/-1 (line-convention tolerance)
  local c
  for _, dl in ipairs({0,-1,1}) do
    c = cidx[(tc.file)..'\31'..(tc.line+dl)..'\31'..tc.callee]; if c then break end
  end
  if not c then T.unpaired = T.unpaired + 1; goto cont end
  T.paired = T.paired + 1
  local tsc_defs = tc.defs or {}
  local cg = cg_target(c)
  if #tsc_defs == 0 and not cg then T.both_ext = T.both_ext + 1
  elseif #tsc_defs == 0 and cg then T.cg_only = T.cg_only + 1
  elseif #tsc_defs > 0 and not cg then T.tsc_only = T.tsc_only + 1
  else
    -- both resolved: agree if cg target matches ANY tsc def (file + line +/-1)
    local hit = false
    for _, d in ipairs(tsc_defs) do
      if d.file == cg.file and math.abs(d.line - cg.line) <= 1 then hit = true; break end
    end
    if hit then T.agree = T.agree + 1
    else T.disagree = T.disagree + 1
      -- classify which side is likely wrong (LOCAL-SHADOW: tsc→a def in the
      -- CALL's own file, cg→a FOREIGN file = cg over-reached to a global while a
      -- local of that name shadows it — Promise reject/resolve params, useState
      -- setters. SAME-FILE-DIFF-LINE: both one file, cg picked the wrong
      -- same-named def / an overload.)
      local cls
      if tsc_defs[1].file == tc.file and cg.file ~= tc.file then cls = 'local-shadow'
      elseif cg.file == tsc_defs[1].file then cls = 'same-file-diff-line'
      else cls = 'other' end
      T[cls] = (T[cls] or 0) + 1
      local bkt = samples[cls]; if not bkt then bkt = {}; samples[cls] = bkt end
      if #bkt < 8 then bkt[#bkt+1] =
        ('%s:%d %s | cg->%s@%d  tsc->%s@%d'):format(tc.file, tc.line, tc.callee,
          cg.file:match('[^/]+$'), cg.line, tsc_defs[1].file:match('[^/]+$'), tsc_defs[1].line) end
    end
  end
  ::cont::
end
local both = T.agree + T.disagree
print(('paired %d / unpaired %d (tsc calls %d)'):format(T.paired, T.unpaired, #ts.calls))
print(('both-resolved: %d  AGREE %d (%.3f%%)  DISAGREE %d'):format(both, T.agree, both>0 and 100*T.agree/both or 0, T.disagree))
print(('  disagreement classes: local-shadow %d  same-file-diff-line %d  other %d'):format(
  T['local-shadow'] or 0, T['same-file-diff-line'] or 0, T.other or 0))
print(('coverage: tsc-only(cg gap) %d  cg-only(tsc external) %d  both-external %d'):format(T.tsc_only, T.cg_only, T.both_ext))
for _, cls in ipairs({'local-shadow','same-file-diff-line','other'}) do
  print('--- '..cls..' samples ---')
  for _,s in ipairs(samples[cls] or {}) do print('  '..s) end
end
