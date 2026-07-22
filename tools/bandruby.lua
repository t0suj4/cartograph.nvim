-- bandruby — F1 Ruby-linkage scoping (merging-strategies / federation). Ruby is
-- the gitlab regime AND the one import-linkage doesn't cover (few require edges;
-- it crosses bands via CONSTANT/autoload resolution). Ruby resolution is also NOT
-- 100% (~12% on activerecord), so the honest question isn't just "of resolved
-- cross-band, what mechanism" but "how big is the resolved-cross-band bucket vs ALL
-- calls" (the rest are unresolved FRONTIERS — reconstructable by the invariant, not
-- federation's risk). For the resolved cross-band calls, decompose by c.prov (which
-- pass linked it) + callee SHAPE (::-path / Foo#m / Foo.m / receiver / bare) so we
-- know what the constant->band linkage must capture.
--
--   nvim --headless -u NONE -l tools/bandruby.lua <ruby-corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'

local name = arg[1] or 'ruby'
local data = bench.extract(name)
local node_index = {}
for _, n in ipairs(data.nodes or {}) do node_index[n.id] = n end

local DEPTH = 3
local function band(file)
    local parts, i = {}, 0
    for seg in file:gmatch('[^/]+') do i = i + 1; if i > DEPTH then break end; parts[i] = seg end
    if #parts >= 1 and file:sub(-#parts[#parts]) == parts[#parts] and i <= DEPTH then parts[#parts] = nil end
    return table.concat(parts, '/')
end

local function shape(c)
    local f = c.full
    if f and f:find('::', 1, true) then return 'const-path (::)' end
    if f and f:find('#', 1, true) then return 'Foo#method' end
    if f and f:find('.', 1, true) then return 'Foo.method' end
    if c.recv then return 'receiver' end
    return 'bare'
end

local total, resolved, xband = 0, 0, 0
local byprov, byshape = {}, {}
local function bump(t, k) t[k] = (t[k] or 0) + 1 end
for _, c in ipairs(data.calls or {}) do
    total = total + 1
    if c.to then
        resolved = resolved + 1
        local tgt = node_index[c.to]
        if tgt and tgt.file and not tgt.external and band(c.file) ~= band(tgt.file) then
            xband = xband + 1
            bump(byprov, c.prov or '(base/none)')
            bump(byshape, shape(c))
        end
    end
end

print(('bandruby %s (band depth %d) — %d calls · %d resolved (%.1f%%) · %d cross-band resolved (%.2f%% of ALL)')
    :format(name, DEPTH, total, resolved, total > 0 and 100 * resolved / total or 0,
        xband, total > 0 and 100 * xband / total or 0))
local function dump(title, t)
    local keys = {}; for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function (a, b) return t[a] > t[b] end)
    print('  ' .. title .. ':')
    for _, k in ipairs(keys) do
        print(('    %-18s %5d (%.1f%% of cross-band)'):format(k, t[k], xband > 0 and 100 * t[k] / xband or 0))
    end
end
dump('by prov (which pass linked it)', byprov)
dump('by callee shape', byshape)

-- REOPENING SCATTER: a method-owning constant (class/module) → the set of bands its
-- methods are defined in. Ruby reopens classes across files → the constant->band map
-- may be a FAT set. Distribution decides the map density + union cost.
local ownerbands = {}
for _, n in ipairs(data.nodes or {}) do
    if (n.kind == 'function' or n.kind == 'method') and n.name and n.file then
        local owner = n.name:match('^(.+)[#.][%w_?!=]+$')
        if owner then
            ownerbands[owner] = ownerbands[owner] or {}
            ownerbands[owner][band(n.file)] = true
        end
    end
end
local dist, multi, maxb, nowners = {}, 0, 0, 0
for _, bs in pairs(ownerbands) do
    local c = 0; for _ in pairs(bs) do c = c + 1 end
    nowners = nowners + 1
    dist[c] = (dist[c] or 0) + 1
    if c > 1 then multi = multi + 1 end
    if c > maxb then maxb = c end
end
print(('  reopening scatter — %d method-owning constants · %d span >1 band (%.1f%%) · max %d bands')
    :format(nowners, multi, nowners > 0 and 100 * multi / nowners or 0, maxb))
for c = 1, math.min(maxb, 5) do
    if dist[c] then print(('    in %d band(s): %d constants'):format(c, dist[c])) end
end
vim.cmd('qall!')
