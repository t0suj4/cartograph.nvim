-- callmatrix — the ACCESS-MODEL micro-matrix (record-fold arc, brick 3,
-- [[cartograph-record-fold-arc]], [[cartograph-revisit-killed-optimizations]]).
-- The encoding matrix chose the REPRESENTATION (ffi/packed u32 columns); this
-- chooses the ACCESS MODEL over that representation, empirically, the same
-- measure-first way — so the fork "transparent proxy vs index-based" is decided
-- by numbers, not a guess.
--
-- Three models, each reading the hot syntactic/resolution fields over every call:
--   record  data.calls[i].file            the status quo (Lua record tables)
--   proxy   callcols.row(cc,i).file       the transparent drop-in (metatable
--                                          __index → callcols.get → column read);
--                                          ZERO consumer churn (the compat path)
--   index   callcols.get(cc,'file',i)     direct column read, no proxy dispatch;
--                                          the full win, but every consumer loop
--                                          must be rewritten to the index form
-- Metrics: READ SPEED (the deciding number — a hot analysis reads calls millions
-- of times) and RESIDENT (corroboration — the encoding matrix's ~4.4× column win).
-- Decision rule (printed): if proxy is within ~1.5× of index, the transparent
-- proxy wins (no churn); else hot loops warrant the index rewrite.
--
--   nvim --headless -u NONE -l tools/callmatrix.lua <corpus>

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/callmatrix%.lua$')
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local callcols = require 'cartograph.callcols'

local name = arg and arg[1] or 'self'
local data = bench.extract(name)
local calls = data.calls or {}
local n = #calls
if n == 0 then print('callmatrix: no calls in ' .. name); os.exit(2) end

local HOT = { 'file', 'callee', 'fn', 'to', 'line', 'method' } -- typical read set

local function kb()
    if rawget(_G, 'jit') and jit.flush then jit.flush() end
    collectgarbage(); collectgarbage()
    return collectgarbage('count')
end
local uv = vim.uv or vim.loop
local function hrt() return uv.hrtime() end

-- ── RESIDENT (marginal build cost, each representation ISOLATED) ──────────
-- Dropping data.calls in place frees almost nothing — the store indexes
-- (calls_by_fn/calls_to/…) still reference the same record tables (the shared-
-- reference trap tools/resident.lua warns of). So build all three FRESH from
-- the same data, each referenced only locally → an honest apples-to-apples KB.
local function fresh_records()
    local out = {}
    for i = 1, n do
        local t = {}
        for k, v in pairs(calls[i]) do t[k] = v end
        out[i] = t
    end
    return out
end
local b_r = kb()
local recs = fresh_records()
local rec_kb = kb() - b_r
local b0 = kb()
local cc = callcols.build(calls)
local col_kb = kb() - b0
local b1 = kb()
local view = callcols.view(calls)
local view_kb = kb() - b1
assert(#recs == n) -- hold the record copy alive across the measures above

-- ── READ SPEED (ns per field read, over the hot set) ─────────────────────
-- reps chosen so each model does ~1e7 field reads regardless of corpus size
local reads_target = 1e7
local reps = math.max(1, math.floor(reads_target / (n * #HOT)))
local total_reads = reps * n * #HOT

local function bench_record()
    local acc = 0
    for _ = 1, reps do
        for i = 1, n do
            local c = calls[i]
            for _, f in ipairs(HOT) do if c[f] then acc = acc + 1 end end
        end
    end
    return acc
end

local function bench_proxy()
    local acc, rows = 0, view.rows
    for _ = 1, reps do
        for i = 1, n do
            local c = rows[i]
            for _, f in ipairs(HOT) do if c[f] then acc = acc + 1 end end
        end
    end
    return acc
end

local function bench_index()
    local acc = 0
    for _ = 1, reps do
        for i = 1, n do
            for _, f in ipairs(HOT) do if callcols.get(cc, f, i) then acc = acc + 1 end end
        end
    end
    return acc
end

local function timed(fn)
    fn() -- warm the JIT
    local t = hrt()
    local acc = fn()
    return (hrt() - t), acc
end

local t_rec, a_rec = timed(bench_record)
local t_prx, a_prx = timed(bench_proxy)
local t_idx, a_idx = timed(bench_index)

-- ── report ────────────────────────────────────────────────────────────────
local function nsper(t) return t / total_reads end
print(('callmatrix %s — %d calls, %d hot fields, %d reads/model')
    :format(name, n, #HOT, total_reads))
print(('  (read checksums: record=%d proxy=%d index=%d %s)')
    :format(a_rec, a_prx, a_idx, (a_rec == a_prx and a_prx == a_idx) and 'MATCH' or 'MISMATCH!'))
print('')
print('  model    resident(KB)   read(ns/field)   vs index')
local function row(label, res_kb, t)
    print(('  %-7s  %10.0f   %14.2f   %6.2fx'):format(label, res_kb, nsper(t), t / t_idx))
end
row('record', rec_kb, t_rec)
row('proxy', view_kb, t_prx)
row('index', col_kb, t_idx)
print('')
print(('  columns are %.1fx smaller than record tables (%.0f → %.0f KB)')
    :format(rec_kb / math.max(col_kb, 1), rec_kb, col_kb))

-- the decision rule
local proxy_ratio = t_prx / t_idx
print('')
if a_rec ~= a_prx or a_prx ~= a_idx then
    print('  ⚠ read checksums DIVERGE — a model is not faithful; investigate before deciding')
elseif proxy_ratio <= 1.5 then
    print(('  DECISION: proxy is %.2fx index (≤1.5x) → the TRANSPARENT PROXY wins —')
        :format(proxy_ratio))
    print('            flip the flag, zero consumer churn; index-specialize only if a')
    print('            profile later fingers a specific hot loop.')
else
    print(('  DECISION: proxy is %.2fx index (>1.5x) → hot loops warrant the INDEX form —')
        :format(proxy_ratio))
    print('            rewrite the hottest consumer loops (census/ladder/resolve) to')
    print('            callcols.get(cc,f,i); leave cold consumers on the proxy.')
end
vim.cmd('qall!')
