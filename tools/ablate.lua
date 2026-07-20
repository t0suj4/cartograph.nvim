-- ablate — "does this resolution pass earn its keep?" The measure-first
-- discipline as a DECISION tool ([[cartograph-charter]]; the B2-generics
-- de-fund at ~2.4% was this call, made by hand). RESOLVE_PASSES is exposed
-- "for ablation" and run_resolve_passes iterates that same table — so we drop
-- one pass, re-extract, and measure the NET resolution loss (everything that
-- depended on it, directly or transitively). NET is the decision input by_prov
-- can't give: by_prov is GROSS ("module_alias resolved 116"), but some of those
-- would be caught by a later pass — NET is the marginal value. GROSS − NET =
-- redundancy (another pass covers it). NET ≈ 0 = a candidate to question.
--
--   nvim --headless -u NONE -l tools/ablate.lua [<corpus-name>|<dir>]

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts = require 'cartograph.providers.treesitter'
local census = require 'cartograph.census'

-- corpus: a registry name (its root) or a dir; default our own engine
local arg1 = arg[1]
local root = repo .. '/lua'
if arg1 then
    local ok, corpora = pcall(dofile, repo .. '/tools/corpora.lua')
    if ok and corpora[arg1] and corpora[arg1].root then root = corpora[arg1].root
    else root = arg1 end
end

local RP = ts.RESOLVE_PASSES
local full = {}
for i, p in ipairs(RP) do full[i] = p end

-- rebuild RP in place (same object run_resolve_passes closes over) = full minus
-- `skip` (nil skip = the whole list)
local function set_passes(skip)
    for i = #RP, 1, -1 do RP[i] = nil end
    for _, p in ipairs(full) do if p ~= skip then RP[#RP + 1] = p end end
end

local function n_resolved(data)
    local n = 0
    for _, c in ipairs(data.calls or {}) do if c.to then n = n + 1 end end
    return n
end

-- baseline: the full pipeline
set_passes(nil)
local base_data = ts.extract(root)
local base = n_resolved(base_data)
local gross = census.take(base_data).calls.by_prov or {} -- pass -> first-resolved count

-- per-pass ablation
local rows = {}
for _, p in ipairs(full) do
    set_passes(p)
    local data = ts.extract(root)
    rows[#rows + 1] = { name = p.name, net = base - n_resolved(data), gross = gross[p.name] or 0 }
end
set_passes(nil) -- restore

table.sort(rows, function (a, b) return a.net > b.net end)

print(('ablate %s — %d resolved calls (full pipeline)'):format(root:gsub('.*/', ''), base))
print(('  base (exact/name-match, pre-pass): %d'):format(gross.base or 0))
print('  pass                net    gross   redundancy')
for _, r in ipairs(rows) do
    local red = r.gross - r.net
    local flag = r.net == 0 and '  ← 0 on this corpus' or (red > 0 and ('  (%d also-caught)'):format(red) or '')
    print(('  %-18s %5d %8d %s'):format(r.name, r.net, r.gross, flag))
end
print('  NET = marginal (drops if the pass is removed) · GROSS = first-resolved credit')
print('  a low NET on every representative corpus = a de-fund candidate')
