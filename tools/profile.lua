-- P0 EXTRACTION PROFILER ([[cartograph-perf-cut]]): where does a corpus's
-- cold-extraction wall go? Flips treesitter.M.PROFILE, extracts each named
-- corpus, and prints the per-phase breakdown (nanosecond accumulators in
-- data.prof) sorted by cost, with the UNMEASURED remainder as `other` =
-- total − Σ(phases). Measure-first for P2 (which hot phase to optimize).
--
--   nvim --headless -u NONE -l tools/profile.lua <corpus>...
--
-- Phases (see treesitter.lua padd() sites): parse, extract_defs (incl.
-- flow.build, ALSO reported on its own line), extract_calls, collect_mentions,
-- resolve (the resolver block), constfold, total. `flow.build` is a SUBSET of
-- extract_defs, so it is listed separately and NOT double-counted in `other`.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
-- tools run from the repo root (cwd); put the plugin's lua/ on package.path
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
local ts = require 'cartograph.providers.treesitter'

local function ms(ns) return ns / 1e6 end

local corpora = {}
for _, a in ipairs(arg) do corpora[#corpora + 1] = a end
if #corpora == 0 then
    print('usage: nvim --headless -u NONE -l tools/profile.lua <corpus>...')
    os.exit(2)
end

-- extract_defs contains flow.build; keep flow.build off the summed-phase
-- total so `other` stays honest (it is a sub-phase, reported for insight).
local SUBPHASE = { ['flow.build'] = true }
local ORDER = { 'parse', 'extract_defs', 'flow.build', 'extract_calls',
    'collect_mentions', 'resolve', 'constfold' }

ts.PROFILE = true
for _, name in ipairs(corpora) do
    local ok, data = pcall(function () return (bench.extract(name)) end)
    if not ok then
        print(('%-10s ERROR %s'):format(name, tostring(data)))
    else
        local p = data.prof or {}
        local total = p.total or 0
        io.write(('\n== %s ==  total %.0f ms  (%d files, %d nodes)\n'):format(
            name, ms(total), #(data.stamps and vim.tbl_keys(data.stamps) or {}),
            #(data.nodes or {})))
        local summed = 0
        for _, k in ipairs(ORDER) do
            local v = p[k]
            if v then
                if not SUBPHASE[k] then summed = summed + v end
                io.write(('  %-18s %8.0f ms  %5.1f%%%s\n'):format(k, ms(v),
                    total > 0 and v / total * 100 or 0,
                    SUBPHASE[k] and '  (⊂ extract_defs)' or ''))
            end
        end
        local other = total - summed
        io.write(('  %-18s %8.0f ms  %5.1f%%  (unmeasured: id-pass, list_files, df/ingest, …)\n')
            :format('other', ms(other), total > 0 and other / total * 100 or 0))
    end
end
os.exit(0)
