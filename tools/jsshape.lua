-- jsshape — WHAT SHAPE IS EACH TABLE? The census of cartograph.tblshape's judgement (the evidence for the
-- "objects/arrays by shape" representation of the JS transliteration, CART-1197; user decision 2026-09-29):
--
--   nvim --headless -u NONE -l tools/jsshape.lua <dir> [--show CLASS]
--
-- Per table constructor: one BOUND by `local x = {…}` is judged by every scope-resolved use of that binding, an
-- unbound one by its own entries (the rules live in lua/cartograph/tblshape.lua — ONE copy, shared with the emitter).
-- ★ CONTROL: the number of constructors found beside the number judged, so a lost population shows.
local dir = vim.fn.fnamemodify(assert(arg[1], 'usage: jsshape.lua <dir> [--show CLASS]'), ':p'):gsub('/$', '')
local show
for i = 2, #arg do if arg[i] == '--show' then show = arg[i + 1] end end
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local T = require 'cartograph.tblshape'

local files = vim.fs.find(function (name) return name:match('%.lua$') end, { path = dir, type = 'file', limit = math.huge })
table.sort(files)
local classes, free_classes, ctx_total = {}, {}, {}
local bound_n, free_n, found_n, noscope = 0, 0, 0, 0
local examples = {}
for _, path in ipairs(files) do
    local fd = io.open(path); local src = fd:read('a'); fd:close()
    local rel = path:sub(#dir + 2)
    local recs, why = T.of(src, rel)
    if why then noscope = noscope + 1 end
    local starts = {}
    for off in pairs(recs) do starts[#starts + 1] = off end
    table.sort(starts)
    for _, off in ipairs(starts) do
        local r = recs[off]
        found_n = found_n + 1
        if r.bound then
            bound_n = bound_n + 1
            classes[r.class] = (classes[r.class] or 0) + 1
            for k, n in pairs(r.uses or {}) do ctx_total[k] = (ctx_total[k] or 0) + n end
            if show and r.class:find(show, 1, true) then
                local line = select(2, src:sub(1, off):gsub('\n', '')) + 1
                examples[#examples + 1] = ('%s:%d  %s  %s'):format(rel, line, r.name, vim.inspect(r.ev, { newline = '', indent = '' }))
            end
        else
            free_n = free_n + 1
            free_classes[r.class] = (free_classes[r.class] or 0) + 1
        end
    end
end

local function dump(title, t, total)
    io.write(title, '\n')
    local rows = {}
    for k, n in pairs(t) do rows[#rows + 1] = { k = k, n = n } end
    table.sort(rows, function (a, b) if a.n ~= b.n then return a.n > b.n end return a.k < b.k end)
    for _, r in ipairs(rows) do io.write(('  %7d  %5.1f%%  %s\n'):format(r.n, total > 0 and 100 * r.n / total or 0, r.k)) end
end
io.write(('jsshape over %s: %d file(s) (%d without a scope graph); %d constructors found, %d bound to a local, %d not\n')
    :format(dir, #files, noscope, found_n, bound_n, free_n))
dump('BOUND (judged by every use of the binding):', classes, bound_n)
dump('NOT BOUND (judged by the constructor\'s own entries):', free_classes, free_n)
local ctot = 0
for _, n in pairs(ctx_total) do ctot = ctot + n end
dump(('USES of bound tables, by context (%d):'):format(ctot), ctx_total, ctot)
if show then io.write('\nexamples of ', show, ':\n'); for i = 1, math.min(40, #examples) do io.write('  ', examples[i], '\n') end end
