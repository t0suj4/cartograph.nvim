-- dumpcompare — the OFFLINE disagreement harvest ([[cartograph-goal-vm-linker]] the
-- success bar). The lua-ls graph-cli patch (0002-graph-cli.patch) emits a
-- `.luals-graph.json` in cartograph's OWN neutral schema (same node-id format
-- file::name@line), so lua-ls's resolution is directly diffable against cartograph's
-- extraction of the same corpus — a one-time GRAPH-vs-GRAPH comparison that sidesteps
-- lua-ls's live headless indexing wall (Skada: the live per-site harvest timed out;
-- the dump compares in seconds). Where BOTH engines resolve a call, they either AGREE
-- (confidence) or CONFLICT — and a conflict is a real bug on ONE side (spot-check to
-- triage which). Absence on one side is NOT a conflict (only-cartograph / only-lua-ls
-- are reported separately; each is a coverage gap, not a defect).
--
--   nvim --headless -u NONE -l tools/dumpcompare.lua <addon-dir> [--show]
--
local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local ts = require 'cartograph.providers.treesitter'

local addon = arg[1]
local show = arg[2] == '--show'
if not addon then print('usage: dumpcompare <addon-dir> [--show]'); os.exit(2) end
local dumpf = addon .. '/.luals-graph.json'
local fd = io.open(dumpf)
if not fd then print('no dump: ' .. dumpf .. ' (needs the lua-ls graph-cli patch)'); os.exit(2) end
local ls = vim.json.decode(fd:read('a')); fd:close()
local cg = ts.extract(addon)

-- a call site is identified across the two graphs by (file, line, callee) — both
-- graphs carry these verbatim; the RESOLUTION being compared is `.to` (a node id).
local function key(c) return (c.file or '?') .. '\31' .. tostring(c.line) .. '\31' .. (c.callee or c.full or '?') end
local lsto = {}
for _, c in ipairs(ls.calls or {}) do if c.to then lsto[key(c)] = c.to end end

local both, agree, conflict, cg_only = 0, 0, 0, 0
local conflicts = {}
for _, c in ipairs(cg.calls or {}) do
    if c.to then
        local lt = lsto[key(c)]
        if lt then
            both = both + 1
            if lt == c.to then agree = agree + 1
            else
                conflict = conflict + 1
                conflicts[#conflicts + 1] = { site = key(c):gsub('\31', ':'), cg = c.to, ls = lt }
            end
        else
            cg_only = cg_only + 1
        end
    end
end
-- lua-ls resolved a site cartograph left unresolved (a cartograph coverage gap)
local cgto = {}
for _, c in ipairs(cg.calls or {}) do if c.to then cgto[key(c)] = true end end
local ls_only = 0
for k in pairs(lsto) do if not cgto[k] then ls_only = ls_only + 1 end end

local name = addon:gsub('/*$', ''):gsub('.*/', '')
print(('dumpcompare %s: %d calls resolved by BOTH — %d agree, %d CONFLICT (%.2f%% agreement)')
    :format(name, both, agree, conflict, 100 * agree / math.max(1, both)))
print(('  coverage: cartograph-only=%d  lua-ls-only=%d  (not conflicts — resolver reach gaps)')
    :format(cg_only, ls_only))
table.sort(conflicts, function (a, b) return a.site < b.site end)
local n = show and #conflicts or math.min(20, #conflicts)
for i = 1, n do
    local c = conflicts[i]
    print(('  CONFLICT %s\n    cartograph → %s\n    lua-ls     → %s'):format(c.site, c.cg, c.ls))
end
if not show and #conflicts > n then print(('  … +%d more (--show for all)'):format(#conflicts - n)) end
