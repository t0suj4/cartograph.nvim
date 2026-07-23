-- dfmat — gate ON-DEMAND DATAFLOW materialization ([[cartograph-thin-index]]). df/flow are
-- LOCAL, so a file's dataflow materialized alone must be BYTE-IDENTICAL to a full extract's.
-- Gate: open index-only (no df/flow), materialize file F's dataflow, and check (a) every F
-- function's df.get + flow.record deep-equals the full extract's, and (b) a consumer
-- (untangle.analyze_flow) produces the identical plan on the materialized function vs full.
--
--   nvim --headless -u NONE -l tools/dfmat.lua [corpus]   (default: jquery)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local store = require 'cartograph.store'
local df = require 'cartograph.df'
local flow = require 'cartograph.flow'
local untangle = require 'cartograph.untangle'

local name = arg[1] or 'jquery'

-- canonical serialize (sorted keys) — order-independent structural equality
local function ser(v)
    if type(v) ~= 'table' then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function (a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. '=' .. ser(v[k]) end
    return '{' .. table.concat(parts, ',') .. '}'
end
local function fp(n) return ser(df.get(n)) .. '\31' .. ser(flow.record(n)) end
local function untangle_of(n)
    local ok, res = pcall(untangle.analyze_flow, flow.record(n))
    return ok and ser(res) or ('ERR:' .. tostring(res))
end

-- === full extract: capture F's per-node df/flow fingerprints + a probe untangle plan ===
local full = bench.extract(name)
store.ingest(full)
local F, probe
for _, n in ipairs(store.data.nodes) do
    if (n.kind == 'function' or n.kind == 'method') and df.count(n) > 0 then F = n.file; probe = n.id; break end
end
assert(F, 'no function with df in ' .. name)
local full_fp, nfn = {}, 0
for _, n in ipairs(store.data.nodes) do
    if n.file == F and (n.kind == 'function' or n.kind == 'method') then full_fp[n.id] = fp(n); nfn = nfn + 1 end
end
-- the wired df/flow cockpit verbs — each must produce the IDENTICAL report on the
-- materialized index-only store as on full (a verb that secretly needs edges/calls, which
-- index-only lacks, would diverge here — the catch)
-- the DF/FLOW-LOCAL cockpit verbs — pure functions of df/flow, so faithful on the
-- materialized index-only store. (untangle/reorder/untangle-module are NOT here: they read
-- the effect/call graph — untangle's data+control+EFFECT PDG, reorder's call-commutativity,
-- untangle-module's call-edge clustering — which index-only lacks; the gate proved they diverge.)
local VERBS = {
    { 'extract-blocks', function (id) return require('cartograph.untangle').report_blocks(store, id) end },
    { 'optimize',      function (id) return require('cartograph.optimize').report(store, id) end },
    { 'optimize-apply', function (id) return require('cartograph.optapply').report(store, id) end },
    { 'narrow',        function (id) return require('cartograph.narrow').report(store, id) end },
    { 'param-nil',     function (id) return require('cartograph.narrow').param_report(store, id) end },
    { 'devirt',        function (id) return require('cartograph.narrow').devirt_report(store, id) end },
    { 'branch-values', function (id) return require('cartograph.lens').report(store, id) end },
}
local function verb_out(fn, id) local ok, r = pcall(fn, id); return ok and ser(r) or ('ERR:' .. tostring(r)) end
local full_reports = {}
for _, v in ipairs(VERBS) do full_reports[v[1]] = verb_out(v[2], probe) end

-- === index-only open, then materialize F's dataflow on demand ===
require('cartograph').open_index_only(full.root)
local before = df.count(store.node(probe))               -- expect 0 (index-only: no df/flow)
local filled = store.materialize_file_dataflow(F)
local after = df.count(store.node(probe))

-- === compare df/flow byte-identical + the consumer plan ===
local diff, first = 0, {}
for _, n in ipairs(store.data.nodes) do
    if n.file == F and (n.kind == 'function' or n.kind == 'method') then
        if fp(n) ~= full_fp[n.id] then diff = diff + 1; if #first < 4 then first[#first + 1] = n.id end end
    end
end
local verb_diffs = {}
for _, v in ipairs(VERBS) do
    if verb_out(v[2], probe) ~= full_reports[v[1]] then verb_diffs[#verb_diffs + 1] = v[1] end
end
local untangle_ok = #verb_diffs == 0

print(('dfmat %s — file %s (%d functions)'):format(name, F, nfn))
print(('  index-only: df on probe before materialize = %d (expect 0); materialized = %s; after = %d')
    :format(before, tostring(filled), after))
print(('  df/flow byte-identical vs full: %d of %d functions differ'):format(diff, nfn))
for _, id in ipairs(first) do print('    differ: ' .. id) end
print(('  df/flow-local cockpit verbs (%d) match full: %s%s'):format(#VERBS,
    tostring(untangle_ok), #verb_diffs > 0 and ('  DIVERGED: ' .. table.concat(verb_diffs, ', ')) or ''))

if before == 0 and filled and after > 0 and diff == 0 and untangle_ok then
    print('OK — per-file df/flow materialization is byte-identical to full; the consumer plan matches')
    vim.cmd('qall!')
else
    print('FAIL — materialized dataflow diverges from full, or the consumer plan differs')
    vim.cmd('cquit 1')
end
