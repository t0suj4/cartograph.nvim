-- ladderparity — proves ladder.report (tally + narrowable) is IDENTICAL with the resident
-- callcols store OFF (raw records) vs ON (columns), after migrating ladder to callview
-- index-form ([[cartograph-thin-index]] "move consumers to columns"). Same corpus, two
-- ingests (config.callcols_store false/true), diff the report lines.
--
--   nvim --headless -u NONE -l tools/ladderparity.lua [corpus]   (default: ruby)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local store = require 'cartograph.store'
local config = require 'cartograph.config'
local ladder = require 'cartograph.ladder'

local name = arg[1] or 'ruby'

local function report_with(callcols)
    local data = bench.extract(name) -- fresh extract (ingest consumes/folds it)
    config.callcols_store = callcols
    store.ingest(data)
    config.callcols_store = false -- restore
    return ladder.report(store)
end

local off = report_with(false)
local on = report_with(true)

local diff, first = 0, {}
local maxn = math.max(#off, #on)
for i = 1, maxn do
    if off[i] ~= on[i] then
        diff = diff + 1
        if #first < 6 then first[#first + 1] = ('L%d: OFF=%q ON=%q'):format(i, tostring(off[i]), tostring(on[i])) end
    end
end

print(('ladderparity %s — %d report lines (callcols off) vs %d (on)'):format(name, #off, #on))
if diff == 0 then
    print('OK — ladder.report is IDENTICAL across record vs columnar (migration parity-clean)')
    vim.cmd('qall!')
else
    print(('FAIL — %d line(s) differ:'):format(diff))
    for _, s in ipairs(first) do print('  ' .. s) end
    vim.cmd('cquit 1')
end
