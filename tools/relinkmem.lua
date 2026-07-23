-- relinkmem — decompose the INTERMEDIATE (transient) relink structures (federation /
-- the peak arc, [[cartograph-band-federation]]). peakattr decomposed the RESIDENT graph
-- (596 MB server), but the merge peak is ~1.19 GB → ~594 MB is INTERMEDIATE structures
-- built during relink that nothing has looked inside. This attributes that half: the
-- index maps (exact/tail/node_index), the ref/reg dedup maps (STRING-keyed — from.."\31"
-- ..to, ~137k fresh long strings, prime suspect), and the string-key GARBAGE the
-- concatenation throws off (spikes VmHWM even though GC frees it).
--
--   nvim --headless -u NONE -l tools/relinkmem.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ts = require 'cartograph.providers.treesitter'

local name = arg[1]
if not name then print('usage: relinkmem <corpus>'); os.exit(2) end
local data = bench.extract(name)
if data._callstore then data.calls = require('cartograph.rescols').materialize(data._callstore) end

local function mb() collectgarbage('collect'); collectgarbage('collect'); return collectgarbage('count') / 1024 end
local function kb() return collectgarbage('count') / 1024 end

local base = mb()

-- 1. THE INDEX (build_index — exact/tail/node_index over all nodes)
local index = ts.build_index(data.nodes)
local after_index = mb()

-- 2. THE REF/REG DEDUP MAPS (relink's line ~5546 — string-keyed by from.."\31"..to)
local peak_during = base -- track the allocation high-water incl. concat garbage
local refEdge, regEdge = {}, {}
local nref, nreg, keybytes = 0, 0, 0
for _, e in ipairs(data.edges or {}) do
    if e.kind == 'ref' then
        local k = e.from .. '\31' .. e.to
        refEdge[k] = e; nref = nref + 1; keybytes = keybytes + #k
    elseif e.kind == 'reg' then
        local k = e.from .. '\31' .. e.to
        regEdge[k] = e; nreg = nreg + 1; keybytes = keybytes + #k
    end
    if (nref + nreg) % 20000 == 0 then local c = kb(); if c > peak_during then peak_during = c end end
end
local after_ref = mb()

-- id-string length profile (why the keys are heavy)
local idsum, idn, idmax = 0, 0, 0
for _, n in ipairs(data.nodes or {}) do
    if n.id then idsum = idsum + #n.id; idn = idn + 1; if #n.id > idmax then idmax = #n.id end end
end

print(('relinkmem %s — %d nodes · %d edges (%d ref / %d reg)')
    :format(name, #(data.nodes or {}), #(data.edges or {}), nref, nreg))
print(('  resident graph baseline:        %.1f MB'):format(base))
print(('  + build_index (exact/tail/nidx): %.1f MB'):format(after_index - base))
print(('  + ref/reg dedup maps (retained): %.1f MB   (%d string keys, %.1f MB of key chars)')
    :format(after_ref - after_index, nref + nreg, keybytes / 1048576))
print(('  concat GARBAGE high-water seen during ref-map build: ~%.1f MB above settled')
    :format(math.max(0, peak_during - (after_index))))
print(('  id-string profile: mean %.0f chars · max %d (the dedup key = from+to = ~%.0f chars each)')
    :format(idn > 0 and idsum / idn or 0, idmax, idn > 0 and 2 * idsum / idn or 0))
-- keep the structures live THROUGH the measurements above (else the collect in mb() frees
-- them and the deltas read 0) + a real read so they aren't dead-stripped
local kept = 0
for _ in pairs(index.exact) do kept = kept + 1 end
for _ in pairs(refEdge) do kept = kept + 1 end
for _ in pairs(regEdge) do kept = kept + 1 end
print(('  (kept %d live map entries through measurement)'):format(kept))
vim.cmd('qall!')
