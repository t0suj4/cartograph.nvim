-- idxprofile — PROFILE-GUIDED index-a-scan (CART-1057): run a workload with one module's candidate
-- scans PROBED, and price each site's CPU-for-memory trade.
--
--   nvim --headless -u NONE -l tools/idxprofile.lua <module> <file.lua> <workload.lua> [--ratio N]
--
-- <module> is the require name the workload loads (`cartograph.characterize`); <file.lua> its source.
-- The instrumented source is installed as package.preload[<module>] in THIS fresh process before the
-- workload runs, so every caller gets the probed copy (a module already loaded elsewhere would keep
-- its captured locals — which is why this is a separate process). Prints per site: calls, element
-- touches the scan costs, touches the index would cost, bucket entries it would hold, and the verdict.

local REPO = (debug.getinfo(1, 'S').source:match('@(.*)/tools/[^/]+$')) or '.'
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local I = require 'cartograph.idxrewrite'

local mod, file, workload, ratio = arg[1], arg[2], arg[3], 4
for i = 4, #arg do if arg[i] == '--ratio' then ratio = tonumber(arg[i + 1]) end end
assert(mod and file and workload, 'usage: idxprofile.lua <module> <file.lua> <workload.lua> [--ratio N]')
local src = table.concat(vim.fn.readfile(file), '\n')
local probed, sites = I.instrument(src)
package.loaded[mod] = nil
package.preload[mod] = function() return assert(loadstring(probed, '@' .. file))() end
local t0 = os.clock()
dofile(workload)
local prof = rawget(_G, '__cg_idx_profile') or {}
print(('idxprofile %s: %d candidate site(s), workload %.2fs CPU'):format(file, #sites, os.clock() - t0))
for _, s in ipairs(sites) do
    local apply, d = I.decide(prof[s.line], { ratio = ratio })
    print(('  %s:%d  ipairs(%s) .%s == %s  %s'):format(file, s.line, s.E, s.F, s.K,
        d.calls and ('calls %d  scan %d  index %d  (x%.1f)  memory %d bucket entries over %d list(s)  -> %s'):format(
            d.calls, d.scan, d.index, d.ratio, d.memory, d.distinct, apply and 'APPLY' or 'keep')
        or ('-> keep: ' .. d.why)))
end
