-- bandlinkgate — the F1 RECALL DIFF (federation). Proves the cross-band linkage
-- resolver (bandlink) reproduces whole-graph resolution WITHOUT a whole-graph index:
-- for every cross-band resolution the whole graph found, does per-band + const->band
-- linkage recover the SAME target? Verdicts:
--   MATCH — linkage found the same def whole-graph did (recall recovered), split by
--           path: const (owner-qualified exact) + ancestor (inherited/reopened hop)
--   MISS  — whole-graph resolved it, linkage didn't (an honest frontier under
--           federation — reconstruct selectively; the residual is the bare bucket)
--   WRONG — linkage resolved to a DIFFERENT def (SOUNDNESS violation — MUST be 0)
-- WRONG>0 fails the gate. MISS is the recall residual (reported, not a failure — it's
-- reconstructable per the invariant). const path + ancestor hop both run here.
--
--   nvim --headless -u NONE -l tools/bandlinkgate.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ports = require 'cartograph.ports'
local bandlink = require 'cartograph.bandlink'
local ts = require 'cartograph.providers.treesitter'

local name = arg[1]
if not name then print('usage: bandlinkgate <corpus>'); os.exit(2) end
local data = bench.extract(name)
local band_of = ports.default_band_of(3)
local surf = ports.surface(data, band_of)
local idx = bandlink.indexes(data, band_of)
local chains = bandlink.chains(data) -- ruby ruby_anc adjacency + extends super map

local node_index = {}
for _, n in ipairs(data.nodes or {}) do node_index[n.id] = n end

local match, miss, wrong, wrong_ex = 0, 0, 0, {}
local by_path = {} -- MATCH split by resolution path (const / ancestor)
local miss_why = {}
for _, c in ipairs(data.calls or {}) do
    if c.to and c.file then
        local t = node_index[c.to]
        if t and t.file and not t.external then
            local sb, tb = band_of(c.file), band_of(t.file)
            if sb ~= tb then -- a whole-graph cross-band resolution = the ground truth
                local key = c.full or c.callee
                local got, why = bandlink.resolve(key, surf.const_index, idx, chains, ts.lang_of(c.file), ts.lang_of)
                if got == c.to then
                    match = match + 1
                    by_path[why] = (by_path[why] or 0) + 1
                elseif got == nil then
                    miss = miss + 1
                    miss_why[why] = (miss_why[why] or 0) + 1
                else
                    wrong = wrong + 1
                    if #wrong_ex < 8 then
                        wrong_ex[#wrong_ex + 1] = ('%s: linkage→%s vs whole→%s'):format(tostring(key), got, c.to)
                    end
                end
            end
        end
    end
end

local total = match + miss + wrong
print(('bandlinkgate %s — %d cross-band resolutions (ground truth)'):format(name, total))
print(('  MATCH %d (%.1f%%) · MISS %d (%.1f%%) · WRONG %d')
    :format(match, total > 0 and 100 * match / total or 0,
        miss, total > 0 and 100 * miss / total or 0, wrong))
do
    local ks = {}; for k in pairs(by_path) do ks[#ks + 1] = k end
    table.sort(ks, function (a, b) return by_path[a] > by_path[b] end)
    local parts = {}
    for _, k in ipairs(ks) do parts[#parts + 1] = ('%s %d'):format(k, by_path[k]) end
    if #parts > 0 then print('  match by path: ' .. table.concat(parts, ' · ')) end
end
do
    local ks = {}; for k in pairs(miss_why) do ks[#ks + 1] = k end
    table.sort(ks, function (a, b) return miss_why[a] > miss_why[b] end)
    local parts = {}
    for _, k in ipairs(ks) do parts[#parts + 1] = ('%s %d'):format(k, miss_why[k]) end
    if #parts > 0 then print('  miss by reason: ' .. table.concat(parts, ' · ')) end
end
for _, e in ipairs(wrong_ex) do print('  WRONG ' .. e) end

if wrong > 0 then
    print('FAIL: linkage picked a different target than whole-graph (soundness)')
    vim.cmd('cquit 1')
else
    print('OK — linkage never mis-links; MISS is the honest reconstructable residual')
    vim.cmd('qall!')
end
