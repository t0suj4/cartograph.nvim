-- flowanat — decompose what the BULK of flow/df actually is (the wall-leap follow-up,
-- [[cartograph-thin-index.md]]). flow/df are 69-90% of a node's bytes and the detail the
-- index defers; this attributes them by SUB-FIELD (per-statement) so we know what we're
-- deferring — and whether even the detail could be lighter/derived.
--   flow stmt: l/c (pos) · kind/t (stmt+node-type str) · parent/pol (CFG tree) · def/use
--     (var-name lists) · expr (the per-statement EXPRESSION IR) · label
--   df stmt: l · def/use (var names) · dep (dependency edges) + df.inputs
--
--   nvim --headless -u NONE -l tools/flowanat.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'

local name = arg[1]
if not name then print('usage: flowanat <corpus>'); os.exit(2) end
local data = bench.extract(name)

local function bytes(v)
    local t = type(v)
    if t == 'string' then return #v
    elseif t == 'number' then return 8
    elseif t == 'boolean' then return 1
    elseif t == 'table' then
        local s = 8 -- table overhead
        for k, x in pairs(v) do s = s + bytes(x) + (type(k) == 'string' and #k or 4) end
        return s
    else return 4 end
end

local flow_f, df_f = {}, {}   -- field -> bytes
local nstmt_flow, nstmt_df, nfn = 0, 0, 0
local flow_total, df_total = 0, 0

local function acc(tbl, field, v) tbl[field] = (tbl[field] or 0) + bytes(v) end

for _, n in ipairs(data.nodes or {}) do
    if n.flow and n.flow.stmts then
        nfn = nfn + 1
        for _, st in ipairs(n.flow.stmts) do
            nstmt_flow = nstmt_flow + 1
            for k, v in pairs(st) do acc(flow_f, k, v); flow_total = flow_total + bytes(v) + #tostring(k) end
        end
    end
    if n.df and n.df.stmts then
        for _, st in ipairs(n.df.stmts) do
            nstmt_df = nstmt_df + 1
            for k, v in pairs(st) do acc(df_f, k, v); df_total = df_total + bytes(v) + #tostring(k) end
        end
    end
end

local function report(label, fields, total, nst)
    print(('  %s — %.1f MB over %d stmts (%.0f B/stmt)')
        :format(label, total / 1048576, nst, nst > 0 and total / nst or 0))
    local ks = {}; for k in pairs(fields) do ks[#ks + 1] = k end
    table.sort(ks, function (a, b) return fields[a] > fields[b] end)
    for _, k in ipairs(ks) do
        print(('      %-10s %7.1f MB  %5.1f%%'):format(k, fields[k] / 1048576,
            total > 0 and 100 * fields[k] / total or 0))
    end
end

print(('flowanat %s — %d fns with flow'):format(name, nfn))
report('flow.stmts', flow_f, flow_total, nstmt_flow)
report('df.stmts', df_f, df_total, nstmt_df)
vim.cmd('qall!')
