-- gaps — the single-project RESOLUTION work-list: the unresolved callees ranked
-- by frequency, annotated with the disposition GATE that placed each outside
-- (census.disp). The deferred-analyzer economics made a tool ("write the
-- analyzer with 400 hits, not 3", [[cartograph-charter]]) — but scoped to THIS
-- project and grouped by why, so you can tell a resolvable gap (unknown / vocab
-- / same-file) from a genuine external (no-def / stdlib). Complements
-- specaudit's cross-corpus GAP candidates (which finds where the next PACK is).
--
--   nvim --headless -u NONE -l tools/gaps.lua <root> [--top=N]

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local census = require 'cartograph.census'

local root = arg[1]
local top = 30
for i = 2, #arg do local n = arg[i]:match('^%-%-top=(%d+)$'); if n then top = tonumber(n) end end
if not root then print('usage: gaps <root> [--top=N]'); os.exit(2) end

local data = ts.extract(root)
data.root = data.root or root
store.ingest(data)

-- group every NON-resolved, NON-dynamic call by callee; track the gate + a site
local by_callee = {}
for _, c in ipairs(data.calls or {}) do
    if not c.to and not c.dynamic then
        local name = c.callee or c.full
        if name then
            local disp, why = census.disp(c)
            local g = by_callee[name]
            if not g then g = { n = 0, disp = disp, why = why or '?',
                site = ('%s:%d'):format(c.file or '?', (c.line or 0) + 1) }; by_callee[name] = g end
            g.n = g.n + 1
        end
    end
end

local ranked = {}
for name, g in pairs(by_callee) do ranked[#ranked + 1] = { name = name, g = g } end
table.sort(ranked, function (a, b) return a.g.n > b.g.n end)

-- 'unknown'/'vocab'/'exact-key'/'short'/'prefix' = our reach (a rung/pack could
-- catch these); 'no-def' = genuinely absent. Flag the reachable ones with ►.
local REACHABLE = { unknown = true, vocab = true, ['exact-key'] = true, short = true, prefix = true }

print(('gaps %s — top %d unresolved callees (resolution work-list)'):format(root, top))
print('  ► = likely our reach (a rung/pack could catch it) · else external/absent')
local shown = 0
for _, r in ipairs(ranked) do
    if shown >= top then break end
    shown = shown + 1
    local mark = REACHABLE[r.g.why] and '►' or ' '
    print(('  %s %5d  %-28s %-10s e.g. %s'):format(mark, r.g.n, r.name:sub(1, 28), r.g.why, r.g.site))
end
local total = 0; for _, r in ipairs(ranked) do total = total + r.g.n end
print(('  … %d distinct callees, %d unresolved calls total'):format(#ranked, total))
