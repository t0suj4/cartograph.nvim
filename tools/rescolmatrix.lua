-- rescolmatrix — the RESOLUTION-STORE comparison matrix (record-fold arc, the
-- gitlab-peak lever; [[cartograph-record-fold-arc]]). callmatrix decided the
-- ACCESS model for the resident post-resolution store; this compares the
-- REPRESENTATIONS for the IN-RESOLUTION store (rescols) across corpus SIZES, so
-- the scale questions are answered by one reproducible command instead of
-- scattered one-offs. Corpora × dimensions:
--   RESIDENT   raw records+argv  vs  u32 columns  vs  u16* columns (projection:
--              str-rank columns fit u16 since pools are <65536 — the banked
--              width lever; int/range VALUE columns stay 4B). ratios vs raw.
--   GROWTH     distinct pool strings + pool% of the columnar store — the pool is
--              the SUB-LINEAR part (Zipf), rank columns are the LINEAR bulk.
--   TIME       (--time) audit+relink over records vs the rescols proxy, ms — the
--              shim cost (superseded by the index-form the live wiring reads).
-- Each corpus is extracted fresh and its reps built ISOLATED (gc-delta), like
-- callmatrix. Numbers are marginal build cost, apples-to-apples.
--
--   nvim --headless -u NONE -l tools/rescolmatrix.lua [corpus ...] [--time]

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/rescolmatrix%.lua$')
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local callcols = require 'cartograph.callcols'
local segment = require 'cartograph.segment'
local argvcols = require 'cartograph.argvcols'

local corpora, do_time = {}, false
for _, a in ipairs(arg or {}) do
    if a == '--time' then do_time = true else corpora[#corpora + 1] = a end
end
if #corpora == 0 then corpora = { 'jquery', 'ruby', 'self', 'libs' } end

-- str-rank field counts (each = one rank column, 4B→2B under u16)
local N_CALL_STR = #segment.CALL_SYN_RESOLVE.strs + #segment.CALL_RES_RESOLVE.strs
local N_ARGV_STR = #argvcols.ARGV_SYN.strs + #argvcols.ARGV_RES.strs

local function kb()
    if rawget(_G, 'jit') and jit.flush then jit.flush() end
    collectgarbage(); collectgarbage()
    return collectgarbage('count')
end
local uv = vim.uv or vim.loop

local function fresh_records(calls, n)
    local out = {}
    for i = 1, n do
        local t = {}
        for k, v in pairs(calls[i]) do
            if k == 'argv' and type(v) == 'table' then
                local a = {}
                for j = 1, #v do local e = {}; for k2, v2 in pairs(v[j]) do e[k2] = v2 end; a[j] = e end
                t.argv = a
            else t[k] = v end
        end
        out[i] = t
    end
    return out
end

local function pool_bytes(cc)
    local b, c = 0, 0
    for _, s in ipairs(cc.pool or {}) do c = c + 1; b = b + #s end
    return c, b
end

local rows = {}
for _, name in ipairs(corpora) do
    local ok = pcall(bench.corpus, name)
    if not ok then rows[#rows + 1] = { name = name, err = true } goto cont end
    local data = bench.extract(name)
    local calls = data.calls or {}
    local n = #calls
    local elems, k = {}, 0
    for i = 1, n do local a = calls[i].argv; for j = 1, (a and #a or 0) do k = k + 1; elems[k] = a[j] end end
    local nargv = #elems

    -- RESIDENT (isolated builds)
    local b_r = kb(); local recs = fresh_records(calls, n); local raw_kb = kb() - b_r
    local b_c = kb()
    local ccall = callcols.build(calls, segment.CALL_SYN_RESOLVE, segment.CALL_RES_RESOLVE)
    local cargv = callcols.build(elems, argvcols.ARGV_SYN, argvcols.ARGV_RES)
    local u32_kb = kb() - b_c
    assert(#recs == n and ccall.n == n and cargv.n == nargv) -- hold alive across measures

    -- u16 projection: every str rank column drops 4B→2B (2B saved per rank slot)
    local u16_kb = u32_kb - ((n * N_CALL_STR + nargv * N_ARGV_STR) * 2) / 1024

    -- GROWTH: pool distinct + pool bytes → pool share of the columnar store
    local cp, cpb = pool_bytes(ccall); local ap, apb = pool_bytes(cargv)
    local pool_kb = (cpb + apb) / 1024

    local row = { name = name, n = n, nargv = nargv, raw = raw_kb, u32 = u32_kb,
        u16 = u16_kb, pool = cp + ap, poolpct = 100 * pool_kb / math.max(u32_kb, 1) }

    if do_time then
        recs = nil; collectgarbage()
        local d1 = bench.extract(name); collectgarbage()
        local t = uv.hrtime()
        require('cartograph.parallel').audit(d1); require('cartograph.providers.treesitter').relink(d1)
        row.rec_ms = (uv.hrtime() - t) / 1e6
        d1 = nil; collectgarbage()
        local d2 = bench.extract(name)
        local rescols = require 'cartograph.rescols'
        local v = rescols.view(d2.calls); d2.calls = v.rows
        collectgarbage()
        t = uv.hrtime()
        require('cartograph.parallel').audit(d2); require('cartograph.providers.treesitter').relink(d2)
        row.prx_ms = (uv.hrtime() - t) / 1e6
    end
    rows[#rows + 1] = row
    ::cont::
end

-- ── render ──────────────────────────────────────────────────────────────────
print('rescolmatrix — in-resolution store: raw records+argv vs columns, by corpus size')
print('')
local hdr = ('  %-8s %8s %8s | %9s %9s %9s | %5s %5s | %8s %5s')
    :format('corpus', 'calls', 'argv', 'raw KB', 'u32 KB', 'u16* KB', 'u32x', 'u16*x', 'pool#', 'pool%')
print(hdr); print(('  '):rep(1) .. ('-'):rep(#hdr - 2))
for _, r in ipairs(rows) do
    if r.err then print(('  %-8s  (unknown corpus)'):format(r.name))
    else
        print(('  %-8s %8d %8d | %9.0f %9.0f %9.0f | %4.1fx %4.1fx | %8d %4.0f%%'):format(
            r.name, r.n, r.nargv, r.raw, r.u32, r.u16, r.raw / r.u32, r.raw / r.u16, r.pool, r.poolpct))
    end
end
if do_time then
    print('')
    print(('  %-8s %12s %12s %8s'):format('corpus', 'rec ms', 'proxy ms', 'proxyx'))
    print('  ' .. ('-'):rep(42))
    for _, r in ipairs(rows) do
        if r.rec_ms then
            print(('  %-8s %12.1f %12.1f %7.1fx'):format(r.name, r.rec_ms, r.prx_ms, r.prx_ms / r.rec_ms))
        end
    end
end
print('')
print('  u16* = projection (str-rank columns at 2B; pools <65536 so ranks fit — the')
print('         banked width lever). u32 is the built store; pool is the SUB-LINEAR part,')
print('         rank columns the LINEAR bulk (resident grows ~linearly, ~constant ratio).')
vim.cmd('qall!')
