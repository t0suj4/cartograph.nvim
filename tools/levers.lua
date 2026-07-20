-- levers — "where's the biggest resolution win on THIS corpus?" The
-- D-measurement ([[cartograph-resolution-ceiling]]: local-inference ~26%, std
-- ~50%, B2 ~2.4%) was a hand analysis; this makes it a one-command, per-corpus
-- decision. It decomposes the UNRESOLVED calls by the census gate that stopped
-- each, groups the gates into strategic LEVERS, and ranks them by the
-- resolution points each would add if realized — so "what to work on next" is
-- data. (ablate.lua answers "is an existing pass worth keeping"; this answers
-- "which NEW capability buys the most".)
--
--   nvim --headless -u NONE -l tools/levers.lua [<corpus-name>|<dir>]

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts = require 'cartograph.providers.treesitter'
local census = require 'cartograph.census'

local arg1 = arg[1]
local root = repo .. '/lua'
if arg1 then
    local ok, corpora = pcall(dofile, repo .. '/tools/corpora.lua')
    if ok and corpora[arg1] and corpora[arg1].root then root = corpora[arg1].root else root = arg1 end
end

-- gate (census `why` / dynamic) -> the LEVER that would catch it, and whether
-- it's statically reachable at all (dynamic = honest frontier, not a lever)
local LEVER = {
    ['no-def']    = { lever = 'stdlib-profile (external)', note = 'domain-dependent — the A4 lever' },
    ['vocab']     = { lever = 'pack / vocabulary', note = 'specaudit finds the pack' },
    ['exact-key'] = { lever = 'pack / vocabulary', note = 'string-key registry (greenspun)' },
    ['unknown']   = { lever = 'indirect / dispatch', note = 'VM / runtime tier' },
    ['prefix']    = { lever = 'name-match reach', note = 'prefix-gated' },
    ['short']     = { lever = 'name-match reach', note = 'short-name-gated' },
}

local data = ts.extract(root)
local c = census.take(data)
local total, resolved = c.calls.total, c.calls.resolved

-- fold the gate breakdown into levers
local by_lever, notes = {}, {}
for why, n in pairs(c.calls.outside.by_why or {}) do
    local L = LEVER[why]
    local name = L and L.lever or ('other (' .. why .. ')')
    by_lever[name] = (by_lever[name] or 0) + n
    if L then notes[name] = L.note end
end
local dynamic = (c.calls.outside.by_disp or {}).dynamic or 0

local ranked = {}
for name, n in pairs(by_lever) do ranked[#ranked + 1] = { name = name, n = n } end
table.sort(ranked, function (a, b) return a.n > b.n end)

local function pct(x) return total > 0 and (x * 100 / total) or 0 end
local reachable = 0
for _, r in ipairs(ranked) do reachable = reachable + r.n end

print(('levers %s — resolution %.1f%% (%d/%d calls)'):format(root:gsub('.*/', ''), pct(resolved), resolved, total))
print(('  reachable ceiling (every lever but dynamic realized): %.1f%%  (+%.1f pts)'):format(
    pct(resolved + reachable), pct(reachable)))
print('')
print('  lever                        calls   +pts   note')
for _, r in ipairs(ranked) do
    print(('  %-26s %6d  %+5.1f   %s'):format(r.name, r.n, pct(r.n), notes[r.name] or ''))
end
if dynamic > 0 then
    print(('  %-26s %6d  %s'):format('── dynamic (opaque)', dynamic, '  honest frontier — not statically resolvable'))
end
print('  ranked by resolution points a fully-realized lever would add')
