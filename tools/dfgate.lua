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
if not name then print('usage: dfgate <corpus> [--show [<class>]] [--force]'); os.exit(2) end

-- A LIVING CORPUS CANNOT HOLD THIS CENSUS. The gate fails on any class-count delta, and
-- a corpus that changes under the pin moves it every cut — `self`'s pin was recalibrated
-- ~30 times before it was retired (see dfparity.EXPECTED), so a delta there never meant
-- a regression. CART-0024 diagnosed it and the tool kept running it anyway.
-- DERIVED, NOT HARDCODED: tools/corpora.lua already marks the difference — a PINNED
-- corpus declares `rev`, a living one does not — so this covers `bnw` too, and any living
-- corpus added later, with no edit here. Same guard as tools/f2gate.lua.
-- `--force` still runs it: the census is informative even when it is not a verdict, which
-- is how the granularity residual documented in dfparity's header was identified.
local forced = false
for i = 1, #(arg or {}) do if arg[i] == '--force' then forced = true end end
if not forced then
    local okc, c = pcall(bench.corpus, name)
    if okc and type(c) == 'table' and not c.rev then
        print(('dfgate: SKIPPED %s — a LIVING corpus (no pinned rev) cannot hold a'
            .. ' pinned census.'):format(name))
        print('  It re-analyses its own new source every cut, so a census delta is growth,'
            .. ' not drift.')
        print('  Run a pinned corpus for the verdict, or --force for the numbers'
            .. ' (tools/guards.lua prints self\'s census as context).')
        os.exit(0)
    end
end
-- --show [<class>]: the fix-side EXPLORER — dump the divergence instances of a
-- class with source (Tool 1), instead of gating. No class → list the classes.
local show = (arg[2] == '--show') and (arg[3] or true) or nil

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

-- legacy_df: build the INDEPENDENT dfreg df (df-strangler step 6) so the
-- census compares flow.coarse against a real, separately-built df — production
-- df IS flow.coarse now, so a plain extract would make the oracle circular.
local data = bench.extract(name, { legacy_df = true })

if show then -- EXPLORER mode: dump divergence instances of a class, don't gate
    local r = dfp.check(data, type(show) == 'string' and { [show] = true } or nil)
    print(('dfgate %s --show %s'):format(name, tostring(show)))
    print('  census: ' .. dfp.census(r.cats))
    print('')
    if type(show) == 'string' then
        for _, l in ipairs(dfp.show_instances(r.instances[show] or {}, show, tonumber(arg[4]) or 40)) do print(l) end
    else
        print('  pass a class name to --show to dump its instances, e.g.:')
        print('    df-over-collects | flow-over-collects | binding-as-use | receiver |')
        print('    df-empty-name | OTHER | disjoint | partition-mismatch | line-skew')
    end
    os.exit(0)
end

local r = dfp.check(data)
print(('dfgate %-6s fns=%d stmts=%d%s  flow-invariant-errors=%d')
    :format(name, r.nfn, r.nstmt,
        (r.nskip or 0) > 0 and (' unpaired=' .. r.nskip) or '', r.ferr))
print('  divergences: ' .. dfp.census(r.cats))

local failed = false
if r.ferr > 0 then
    print(('FAIL: %d flow-invariant errors (successors/liveness/reaching threw)'):format(r.ferr))
    failed = true
end

local expected = dfp.EXPECTED[name]
if expected == nil then
    -- A LIVING corpus reaching here was FORCED, so do not invite a pin: one was removed
    -- from `self` on purpose after ~30 recalibrations. The census is context; the CFG
    -- invariant sweep above is the part that can still fail, and it did its job either way.
    local okc, c = pcall(bench.corpus, name)
    if okc and type(c) == 'table' and not c.rev then
        print('LIVING CORPUS — census printed as CONTEXT, not a verdict. Do NOT add'
            .. ' EXPECTED[' .. name .. ']: it would move on every cut.')
        print('  (flow-invariant errors above ARE still a real failure signal.)')
        os.exit(failed and 1 or 0)
    end
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
