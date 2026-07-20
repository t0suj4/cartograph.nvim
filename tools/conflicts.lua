-- conflicts — triage the cartograph-vs-lua-ls DISAGREEMENTS with source
-- context. dumpcompare/lspparity find them; the charter bar is "a disagreement
-- is a real bug on ONE side" ([[cartograph-goal-vm-linker]]) — this makes
-- acting on one cheap: per conflict, the call site + BOTH candidate defs with
-- their source lines, and cartograph's TIER (a ~ inferred conflict is more
-- suspect than a proven one). Turns the 99.6% into found-and-fixed.
--
--   nvim --headless -u NONE -l tools/conflicts.lua <addon-dir> [--dump=<path>]

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local addon = arg[1]
local dumparg
for i = 2, #arg do if arg[i]:match('^%-%-dump=') then dumparg = arg[i]:gsub('^%-%-dump=', '') end end
if not addon then print('usage: conflicts <addon-dir> [--dump=<path>]'); os.exit(2) end

local data = ts.extract(addon)
data.root = data.root or addon
store.ingest(data)
local band = store.topo()

local dumpf = dumparg or (addon .. '/.luals-graph.json')
local fd = io.open(dumpf)
if not fd then print('no lua-ls dump: ' .. dumpf); os.exit(2) end
local ls = vim.json.decode(fd:read('a')); fd:close()

local function key(c) return (c.file or '?') .. '\31' .. tostring(c.line) .. '\31' .. (c.callee or c.full or '?') end
local lsto = {}
for _, c in ipairs(ls.calls or {}) do if c.to then lsto[key(c)] = c.to end end

-- one line of a source file (1-based), trimmed; cached per file
local filecache = {}
local function srcline(file, line1)
    if not file or not line1 then return nil end
    local lines = filecache[file]
    if lines == nil then
        local h = io.open(addon .. '/' .. file); lines = false
        if h then lines = {}; for l in h:lines() do lines[#lines + 1] = l end; h:close() end
        filecache[file] = lines
    end
    return lines and lines[line1] and (lines[line1]:gsub('^%s+', ''):gsub('%s+$', '')) or nil
end

-- id "file::name@line" -> file, name, line(1-based, as emitted)
local function loc_of(id)
    local file, name, line = id:match('^(.-)::(.+)@(%d+)$')
    if file then return file, name, tonumber(line) end
    return nil, id
end

local conflicts = {}
for _, c in ipairs(data.calls or {}) do
    if c.to then
        local lt = lsto[key(c)]
        if lt and lt ~= c.to then conflicts[#conflicts + 1] = { c = c, cg = c.to, ls = lt } end
    end
end

print(('conflicts %s — %d disagreement(s) where both resolve'):format(addon, #conflicts))
for _, x in ipairs(conflicts) do
    local c = x.c
    local tier = band:tier(c.fn, c.to) or 'matched'
    local cgf, cgn, cgl = loc_of(x.cg)
    local lsf, lsn, lsl = loc_of(x.ls)
    print('')
    print(('  %s:%d  %s()   [cartograph tier: %s]'):format(c.file or '?', (c.line or 0) + 1, c.callee or '?', tier))
    print(('    call:      %s'):format(srcline(c.file, (c.line or 0) + 1) or '?'))
    -- ids embed 0-based lines (cartograph's convention); source is 1-based
    print(('    cartograph → %s  (%s:%s)'):format(cgn or x.cg, cgf or '?', cgl and cgl + 1 or '?'))
    if cgf then print(('      def:     %s'):format(srcline(cgf, cgl and cgl + 1) or '?')) end
    print(('    lua-ls     → %s  (%s:%s)'):format(lsn or x.ls, lsf or '?', lsl and lsl + 1 or '?'))
    if lsf then print(('      def:     %s'):format(srcline(lsf, lsl and lsl + 1) or '?')) end
end
if #conflicts == 0 then print('  (none — full agreement on the resolved overlap)') end
