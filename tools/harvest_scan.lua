-- harvest_scan — the disagreement harvest AT SCALE ([[cartograph-goal-vm-linker]]).
-- Over a root of projects (each a subdir with a lua-ls `.luals-graph.json` dump —
-- generate with `lua-language-server --graph=<dir>`), extract each with cartograph,
-- diff resolved CALL targets against the dump, and AGGREGATE: the corpus-wide
-- agreement rate (the north-star metric) + a deduped CONFLICT roster (the bug
-- product — each a real disagreement to triage as our bug or lua-ls's).
--
--   nvim --headless -u NONE -l tools/harvest_scan.lua <root> [maxdirs]
--
local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local ts = require 'cartograph.providers.treesitter'

local root = arg[1]
local maxdirs = tonumber(arg[2]) or 9999
if not root then print('usage: harvest_scan <root> [maxdirs]'); os.exit(2) end

-- projects with a dump
local dumps = vim.fn.glob(root .. '/*/.luals-graph.json', false, true)
local function key(c) return (c.file or '?') .. '\31' .. tostring(c.line) .. '\31' .. (c.callee or c.full or '?') end

local T = { both = 0, agree = 0, conflict = 0, cg_only = 0, ls_only = 0, projects = 0, failed = 0 }
local roster = {} -- "addon\31member" -> { n, sample = {site, cg, ls} }
for i, dumpf in ipairs(dumps) do
    if i > maxdirs then break end
    local dir = vim.fn.fnamemodify(dumpf, ':h')
    local name = vim.fn.fnamemodify(dir, ':t')
    local ok, ls = pcall(function ()
        local fd = io.open(dumpf); local j = vim.json.decode(fd:read('a')); fd:close(); return j
    end)
    local okc, cg = pcall(ts.extract, dir)
    if not (ok and okc and ls and cg) then T.failed = T.failed + 1
    else
        T.projects = T.projects + 1
        local lsto = {}
        for _, c in ipairs(ls.calls or {}) do if c.to then lsto[key(c)] = c.to end end
        local cgto = {}
        for _, c in ipairs(cg.calls or {}) do
            if c.to then
                cgto[key(c)] = true
                local lt = lsto[key(c)]
                if lt then
                    T.both = T.both + 1
                    if lt == c.to then T.agree = T.agree + 1
                    else
                        T.conflict = T.conflict + 1
                        local m = (c.callee or c.full or '?')
                        local rk = name .. '\31' .. m
                        local e = roster[rk]
                        if not e then e = { n = 0, name = name, member = m,
                            site = (c.file or '?') .. ':' .. tostring(c.line), cg = c.to, ls = lt }; roster[rk] = e end
                        e.n = e.n + 1
                    end
                else T.cg_only = T.cg_only + 1 end
            end
        end
        for k in pairs(lsto) do if not cgto[k] then T.ls_only = T.ls_only + 1 end end
    end
end

print(('harvest_scan %s — %d projects (%d dump-less/failed skipped)')
    :format(vim.fn.fnamemodify(root, ':t'), T.projects, T.failed))
print(('calls resolved by BOTH: %d — %d agree, %d CONFLICT  (%.3f%% agreement)')
    :format(T.both, T.agree, T.conflict, 100 * T.agree / math.max(1, T.both)))
print(('coverage: cartograph-only=%d  lua-ls-only=%d  (reach gaps, not conflicts)')
    :format(T.cg_only, T.ls_only))
local rk = {}
for _, e in pairs(roster) do rk[#rk + 1] = e end
table.sort(rk, function (a, b) return a.n > b.n end)
print(('\nCONFLICT roster — %d distinct (addon, member) classes:'):format(#rk))
for _, e in ipairs(rk) do
    print(('  [%s] %s ×%d   %s\n      cartograph → %s\n      lua-ls     → %s')
        :format(e.name, e.member, e.n, e.site, e.cg, e.ls))
end
