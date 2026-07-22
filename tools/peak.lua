-- peak — "is this corpus LOCKED by scale?" The measurement resident.lua can't
-- give: peak ALLOCATION demand (VmHWM), the axis a corpus is locked out on
-- (elasticsearch-30k killed @12GB; [[cartograph-record-fold-arc]]). Two peaks,
-- because they are two different walls:
--   INLINE   — the monolithic whole-resident extract (the naive path; OOMs on
--              a big repo — that's the lock).
--   PARALLEL — the worker pipeline; its peak is the PARENT MERGE high-water
--              (workers peak in their own processes). This is the wall STEP 5
--              (workers ship FOLDED segments, parent CONCATs columns → never
--              materializes raw) is meant to knock down.
-- Verdict = peak vs box RAM: fits, or LOCKED. Per-file rate → extrapolate to
-- gitlab-scale (the acceptance target).
--
--   nvim --headless -u NONE -l tools/peak.lua <corpus|dir> [--inline] [--parallel]

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local bench = require 'bench'

local target = arg[1]
local only_inline, only_parallel = false, false
for i = 2, #arg do
    if arg[i] == '--inline' then only_inline = true
    elseif arg[i] == '--parallel' then only_parallel = true end
end
if not target then print('usage: peak <corpus|dir> [--inline] [--parallel]'); os.exit(2) end
local do_inline = not only_parallel
local do_parallel = not only_inline

-- box RAM (the lock threshold)
local box_gb
do
    local f = io.open('/proc/meminfo')
    if f then local t = f:read('a'); f:close(); local kb = t:match('MemTotal:%s*(%d+)'); box_gb = kb and tonumber(kb) / 1048576 end
end

local function nfiles(data)
    local s, c = {}, 0
    for _, n in ipairs(data.nodes or {}) do
        if n.file and not s[n.file] then s[n.file] = true; c = c + 1 end
    end
    return c
end
local function gb(bytes) return bytes / 1e9 end

print(('peak %s%s'):format(target:gsub('.*/', ''),
    box_gb and (' — box RAM %.1f GB'):format(box_gb) or ''))

local files, ncalls
local function run(label, fn, note)
    local ok, data, stats = pcall(fn)
    if not ok then
        -- an OOM kills the process outright (uncatchable); a caught error is
        -- something else — report it, don't pretend it fit
        print(('  %-9s FAILED: %s'):format(label, tostring(data):gsub('%s+', ' '):sub(1, 80)))
        return
    end
    ncalls = data._callstore and data._callstore.cc.n or #(data.calls or {})
    files = nfiles(data)
    local bound = stats.peak_is_window and '' or ' (lifetime bound)'
    print(('  %-9s peak %6.2f GB%s   wall %5.1fs   %s'):format(
        label, gb(stats.peak), bound, stats.wall, note))
    return stats
end

if do_inline then run('INLINE', function () return bench.extract(target) end,
    'monolithic whole-resident (the naive path)') end
local pstats
if do_parallel then pstats = run('PARALLEL', function () return bench.extract_parallel(target) end,
    'parent-MERGE high-water — the step-5 target') end

-- verdict + extrapolation from the parallel (merge) peak: it's the path meant
-- to scale, so it decides "locked or not" and the gitlab extrapolation
if pstats and files and files > 0 then
    local per_file_mb = pstats.peak / files / 1e6
    print(('  ── %d files · %s calls · %.2f MB/file at the merge peak ──'):format(
        files, ncalls and tostring(ncalls) or '?', per_file_mb))
    if box_gb then
        local fits = gb(pstats.peak) < box_gb
        print(('  VERDICT: %s (merge peak %.2f GB vs box %.1f GB)'):format(
            fits and 'FITS' or '★ LOCKED', gb(pstats.peak), box_gb))
    end
    -- gitlab ≈ 30,399 .rb (the acceptance wall). Density-dependent — run a
    -- corpus of the TARGET language for a faithful estimate (a call-dense lua
    -- tree overshoots a ruby one).
    local ext = per_file_mb * 30399 / 1024
    print(('  extrapolate → gitlab (30,399 files, at THIS corpus\'s density) ≈ %.1f GB merge peak%s'):format(
        ext, box_gb and (ext > box_gb and '  ★ exceeds box → step-5 territory' or '') or ''))
elseif not do_parallel then
    print('  (inline only — run without --inline for the merge-peak wall + verdict)')
end
