-- The df / flow PARITY GATE (per-corpus CLI).
--   nvim --headless -u NONE -l tools/dfgate.lua <corpus>
--
-- The structure gate (tools/gate.lua) diffs a SLIM snapshot that deliberately
-- DROPS df (snapshot.lua), so a def/use drift between flow.du and df's
-- collect_mentions — e.g. a per-language declarator fix landed on ONE side —
-- slips right past it. This gate closes that hole: coarse(flow) must reproduce
-- df's per-statement def/use, and flow's CFG (successors/liveness/reaching)
-- must run clean. The check core lives in tools/dfparity.lua (shared with the
-- dogfood run, tools/guards.lua, which checks the SELF corpus inline).
--
-- No baseline stored — coarse(flow)==df is an INVARIANT; the only pinned data
-- is a per-corpus labelled census (dfparity.EXPECTED), diffed on every run.
-- Exit 1 on any flow-invariant error or census delta; exit 2 if uncalibrated /
-- not applicable.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/dfgate%.lua$')
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local dfp = dofile(here .. '/dfparity.lua')

local name = arg and arg[1]
if not name then print('usage: dfgate <corpus>'); os.exit(2) end

-- corpus identity (mirror gate.lua): a moved/dirty pinned checkout makes the
-- oracle meaningless
local corpus = bench.corpus(name)
if not corpus then print('unknown corpus: ' .. name); os.exit(2) end
local now = corpus.git and corpus.git.rev
if corpus.rev and not bench.same_rev(corpus.rev, now) then
    print(('DFGATE NOT APPLICABLE: %s pinned @ %s but checkout @ %s')
        :format(name, corpus.rev, now or '?'))
    os.exit(2)
end

local data = bench.extract(name)
local r = dfp.check(data)
print(('dfgate %-6s fns=%d stmts=%d  flow-invariant-errors=%d')
    :format(name, r.nfn, r.nstmt, r.ferr))
print('  divergences: ' .. dfp.census(r.cats))

local failed = false
if r.ferr > 0 then
    print(('FAIL: %d flow-invariant errors (successors/liveness/reaching threw)'):format(r.ferr))
    failed = true
end

local expected = dfp.EXPECTED[name]
if expected == nil then
    print('NOT CALIBRATED: add EXPECTED[' .. name .. '] to tools/dfparity.lua after reviewing the census above')
    os.exit(failed and 1 or 2)
end
local diffs = dfp.diff(r.cats, expected)
if #diffs > 0 then
    print('FAIL: coarse(flow)==df census moved (flow.du vs df drift — review, then recalibrate EXPECTED):')
    for _, d in ipairs(diffs) do print('    ' .. d) end
    failed = true
end
print('DFGATE: ' .. (failed and 'FAIL' or 'PASS'))
os.exit(failed and 1 or 0)
