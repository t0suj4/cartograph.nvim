-- perfscan — every shipped PERFORMANCE lens over every function of a tree, with its DENOMINATOR.
--
--   nvim --headless -u NONE -l tools/perfscan.lua <root> [--files <lua pattern>] [--out <file>]
--
-- The lenses are per-function (`optimize.licm` / `optimize.cse` / `exprlint.lint`), plus the
-- interprocedural `loopcost` (CART-1057: input-sized loop nesting across calls); nothing ran
-- them over a codebase, so "does cartograph point at the hot spot?" had no answer. This prints
-- the findings per rule and per file, and the TOTAL, because a lens that flags 200 sites has not
-- named a hot spot by flagging it (the precision is findings-at-the-hot-spot / findings).
-- ★ Written 2026-09-24 as the BLIND half of "can cartograph narrow down a performance issue"
-- (CART-1056): its output is recorded BEFORE the profile is read.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
local store = require 'cartograph.store'
local optimize = require 'cartograph.optimize'
local exprlint = require 'cartograph.exprlint'

local root, pat, outp
local i = 1
while i <= #arg do
    if arg[i] == '--files' then pat = arg[i + 1]; i = i + 1
    elseif arg[i] == '--out' then outp = arg[i + 1]; i = i + 1
    else root = arg[i] end
    i = i + 1
end
assert(root, 'usage: perfscan.lua <root> [--files <pattern>] [--out <file>]')

local data = bench.extract((vim.fn.fnamemodify(root, ':p'):gsub('/$', '')))
store.ingest(data)

local fns, per_rule, per_file, rows = 0, {}, {}, {}
local unsupported = 0
local function hit(file, line, rule, msg)
    per_rule[rule] = (per_rule[rule] or 0) + 1
    per_file[file] = (per_file[file] or 0) + 1
    rows[#rows + 1] = ('%s:%d\t%s\t%s'):format(file, line or 0, rule, msg or '')
end
for _, n in ipairs(data.nodes) do
    if (n.kind == 'function' or n.kind == 'method') and n.file and (not pat or n.file:match(pat)) then
        fns = fns + 1
        local ok, L = pcall(optimize.licm, store, n.id)
        if ok and L then
            for _, lp in pairs(L.loops or {}) do
                for r in pairs(lp.hoistable or {}) do
                    hit(n.file, L.rows[r] and L.rows[r].l, 'licm-hoistable', n.name)
                end
            end
        end
        local okc, C = pcall(optimize.cse, store, n.id)
        if okc and C then
            for _, rd in ipairs(C.redundant or {}) do
                hit(n.file, C.rows[rd.second] and C.rows[rd.second].l, 'cse-redundant', rd.expr)
            end
        end
        local oke, E = pcall(exprlint.lint, store, n.id)
        if oke and E then
            if E.unsupported then unsupported = unsupported + 1 end
            for _, f in ipairs(E.findings or {}) do hit(n.file, f.line, f.rule, n.name) end
        end
    end
end

-- the interprocedural shape (CART-1057): input-sized loop nesting across calls
local loopcost = require 'cartograph.loopcost'
local t_lc = vim.uv.hrtime()
local LC = loopcost.analyze(store, data, { files = pat })
t_lc = (vim.uv.hrtime() - t_lc) / 1e9
local lc_rule = { ['hidden-shared'] = 'loop-scan-shared', hidden = 'loop-nesting-hidden', visible = 'loop-nesting-visible',
    possible = 'loop-nesting-possible' }
for rank, f in ipairs(LC.findings) do
    hit(f.file, f.line, lc_rule[f.kind], ('#%d depth %s  %s'):format(rank, loopcost.depth_text(f), loopcost.chain(f)))
end

local total = #rows
print(('perfscan %s%s: %d function(s) (%d unsupported by the expression IR), %d finding(s)')
    :format(root, pat and (' [' .. pat .. ']') or '', fns, unsupported, total))
print(('  loopcost: %.1fs over %d function(s); %d loop(s), %d input-sized; %d call(s) inside input loops: callee via graph %d, via lexical scope %d, refused %d')
    :format(t_lc, LC.stats.analysed, LC.stats.loops, LC.stats.input_loops, LC.stats.calls_in_input_loops,
        LC.stats.followed_graph, LC.stats.followed_lexical, LC.stats.refused))
do
    local hc = {}
    for cl, n in pairs(LC.stats.holes or {}) do hc[#hc + 1] = cl .. ' ' .. n end
    table.sort(hc)
    print(('  loopcost: calls inside input loops priced as costed builtins %d; holes by class: %s')
        :format(LC.stats.costed or 0, table.concat(hc, ', ')))
    print('  THE UNKNOWNS WORK LIST (a hole, by how many `possible` findings it would decide):')
    for j = 1, math.min(15, #LC.worklist) do
        local w = LC.worklist[j]
        print(('    %5d  %-32s [%s]'):format(w.findings, w.name, w.class))
    end
end
local rk = vim.tbl_keys(per_rule); table.sort(rk, function(a, b) return per_rule[a] > per_rule[b] end)
for _, k in ipairs(rk) do print(('  %-28s %d'):format(k, per_rule[k])) end
local fk = vim.tbl_keys(per_file); table.sort(fk, function(a, b) return per_file[a] > per_file[b] end)
print('  by file:')
for j = 1, math.min(10, #fk) do print(('    %5d  %s'):format(per_file[fk[j]], fk[j])) end
if outp then
    table.sort(rows)
    local f = assert(io.open(outp, 'w')); f:write(table.concat(rows, '\n'), '\n'); f:close()
    print('  rows -> ' .. outp)
end
