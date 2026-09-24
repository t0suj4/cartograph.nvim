-- P0 EXTRACTION PROFILER ([[cartograph-perf-cut]]): where does a corpus's
-- cold-extraction wall go? Flips treesitter.M.PROFILE, extracts each named
-- corpus, and prints the per-phase breakdown (nanosecond accumulators in
-- data.prof) sorted by cost, with the UNMEASURED remainder as `other` =
-- total − Σ(phases). Measure-first for P2 (which hot phase to optimize).
--
--   nvim --headless -u NONE -l tools/profile.lua <corpus|dir>... [--top N]
--   + PER FILE (CART-1056): the N slowest inputs and each language's ms per KB.
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

local corpora, TOP = {}, 10
do
    local i = 1
    while i <= #arg do
        if arg[i] == '--top' then TOP = tonumber(arg[i + 1]); i = i + 1 else corpora[#corpora + 1] = arg[i] end
        i = i + 1
    end
end
if #corpora == 0 then
    print('usage: nvim --headless -u NONE -l tools/profile.lua <corpus>...')
    os.exit(2)
end

-- extract_defs contains flow.build; keep flow.build off the summed-phase
-- total so `other` stays honest (it is a sub-phase, reported for insight).
local SUBPHASE = { ['flow.build'] = true, ['flow.coarse'] = true }
local ORDER = { 'parse', 'list_files', 'extract_defs', 'flow.build', 'flow.coarse',
    'extract_calls', 'collect_mentions', 'resolve_setup', 'resolve', 'constfold' }

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
        -- PER FILE (CART-1056): the slowest inputs, and the rate per language, so a
        -- pathological FILE and a pathological LANGUAGE read apart. ms/KB is the tell.
        local files, byext, root = {}, {}, data.root or name
        for f, ns in pairs(p.files or {}) do
            local st = vim.uv.fs_stat(root .. '/' .. f)
            local kb = st and st.size / 1024 or 0
            files[#files + 1] = { f = f, ns = ns, kb = kb }
            local e = f:match('%.([%w]+)$') or '(none)'
            local b = byext[e] or { ns = 0, kb = 0, n = 0 }
            b.ns, b.kb, b.n = b.ns + ns, b.kb + kb, b.n + 1
            byext[e] = b
        end
        table.sort(files, function(a, b) return a.ns > b.ns end)
        if #files > 0 then
            local ek = vim.tbl_keys(byext)
            table.sort(ek, function(a, b) return byext[a].ns > byext[b].ns end)
            io.write('  per language (files / KB / ms / ms per KB):\n')
            for _, e in ipairs(ek) do
                local b = byext[e]
                io.write(('    .%-6s %6d %9.0f %9.0f  %6.2f\n'):format(e, b.n, b.kb, ms(b.ns), b.kb > 0 and ms(b.ns) / b.kb or 0))
            end
            io.write(('  slowest files (of %d):\n'):format(#files))
            for j = 1, math.min(TOP, #files) do
                local x = files[j]
                io.write(('    %8.0f ms %8.0f KB  %6.2f ms/KB  %s\n'):format(ms(x.ns), x.kb, x.kb > 0 and ms(x.ns) / x.kb or 0, x.f))
            end
        end
    end
end
os.exit(0)
