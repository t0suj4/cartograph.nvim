-- ratchet — the honesty TREND meter. dogfood is a snapshot; this appends the
-- key numbers (resolution %, serving-consistency %, seam breaches, lint total)
-- to a local log per run and prints the DELTA vs last. The charter is a
-- ratchet ([[cartograph-charter]]); this makes progress provable and a
-- regression loud ("resolved -0.3%"). Log is LOCAL (~/.cache), never committed.
--
--   nvim --headless -u NONE -l tools/ratchet.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local dogfood = require 'cartograph.dogfood'

require('cartograph.config').seams = { dogfood.BAND_SEAM }
local root = repo .. '/lua'
local data = ts.extract(root)
data.root = data.root or root
store.ingest(data)
local m = dogfood.metrics(store)

-- local, per-repo log (not committed; a trend, not state)
local dir = vim.fn.expand('~/.cache/cartograph-tools')
vim.fn.mkdir(dir, 'p')
local logf = dir .. '/ratchet.jsonl'

local prev
do
    local fd = io.open(logf, 'r')
    if fd then
        local last
        for l in fd:lines() do if l:match('%S') then last = l end end
        fd:close()
        if last then local ok, e = pcall(vim.json.decode, last); if ok then prev = e.m end end
    end
end

local rev = 'unknown'
do
    local p = io.popen('git -C ' .. repo .. ' rev-parse --short HEAD 2>/dev/null')
    if p then rev = (p:read('l') or 'unknown'); p:close() end
end

local function pct(x) return ('%.1f%%'):format(x) end
local function delta(now, was, unit, invert)
    if not was then return '' end
    local d = now - was
    if math.abs(d) < 1e-9 then return '  (=)' end
    -- invert: for lint/seam, DOWN is good
    local good = invert and d < 0 or (not invert and d > 0)
    local arrow = good and '▲' or '▼'
    return ('  %s %+.1f%s'):format(arrow, d, unit or '')
end

print('cartograph ratchet — ' .. rev)
print(('  resolved   %s%s'):format(pct(m.resolved_pct), delta(m.resolved_pct, prev and prev.resolved_pct, '%%')))
print(('  serving    %s%s'):format(pct(m.serving_pct), delta(m.serving_pct, prev and prev.serving_pct, '%%')))
print(('  seam-guard %d%s'):format(m.seam, delta(m.seam, prev and prev.seam, '', true)))
print(('  lint total %d%s'):format(m.lint_total, delta(m.lint_total, prev and prev.lint_total, '', true)))
print(('  calls %d · resolved %d · refused %d · outside %d'):format(m.calls, m.resolved, m.refused, m.outside))
if not prev then print('  (first run — no delta; logged as the baseline)') end

-- append (os.time is fine in a real nvim tool run)
local fd = assert(io.open(logf, 'a'))
fd:write(vim.json.encode({ t = os.time(), rev = rev, m = m }) .. '\n')
fd:close()
print('  logged -> ' .. logf)
