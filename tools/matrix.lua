-- The MATRIX runner: corpus × invariant, one command, one grid.
--
--   nvim --headless -u NONE -l tools/matrix.lua [<corpus>...] [--quick]
--        [--cols a,b,c] [--save] [--jobs N] [--mem-mb M] [--timeout S]
--        [--file <lua-pattern>]
--
-- Every "these two computations must agree" claim the repo makes, swept
-- across the corpus registry in ONE run — the push-time sweep that used to
-- be 21 hand-fed gate/dfgate invocations. The economics: the expensive step
-- per corpus is the EXTRACT; every invariant column below is a cheap read
-- over that one extraction (only `par` pays for a second, parallel one). So
-- a full row costs about what `gate <corpus>` alone used to.
--
-- Columns (each an independent oracle; a red cell = a bug on ONE side):
--   counts  census refs/nodes == corpora.lua expected (the drift tripwire)
--   valid   validate.check — the closed schema as an executable registry
--   mem     inline peak RSS within the corpus budget (2x-regression tripwire)
--   dfpar   coarse(flow)==df census + flow CFG invariants (tools/dfparity);
--           gated where EXPECTED is calibrated, reported (~) elsewhere —
--           this widens dfgate's 11-corpus coverage to the whole registry
--   fold    flow.fold round-trip: sampled per-fn row/param signatures are
--           bit-identical through the columnar fold; fold is idempotent
--   silent  the uniform-honesty invariant: silent-local gap == 0 (the
--           silent-drop lint swept per corpus, not just on self)
--   cache   cold==warm: cache.save → cache.load (redirected to a scratch
--           dir) reproduces the graph per-item (msgpack/shard fidelity)
--   struct  per-item graphdiff vs the saved baseline snapshot (gate.lua's
--           diff half; --save re-baselines exactly like gate --save)
--   par     inline==parallel: a second, worker-pipeline extraction diffs
--           empty against the inline one (the previously UNSWEPT oracle —
--           gate --parallel existed but nothing ran it systematically)
--
-- Cell states: OK · FAIL · ~ (ran, report-only/uncalibrated) · -- (n/a)
--   · SAVED (--save) · NOBASE (no baseline yet). Row states: SKIP (pinned
--   corpus moved/dirty — mirror of gate's exit-2) · ERR (row crashed).
-- Exit: 1 any FAIL/ERR · 2 clean but SKIP/NOBASE present · 0 all green.
--
-- Each corpus runs in a FRESH child process (this file re-invoked with
-- --row) — the same isolation discipline as one gate.lua run per corpus:
-- no cross-corpus module state, and a per-row crash costs one row, not
-- the sweep. The child prints one '@@MATRIX <json>' line; everything the
-- orchestrator renders comes from that. Rows run in a BOUNDED PARALLEL POOL
-- (--jobs N, default 4): the sweep wall drops from Σ to ≈ Σ/JOBS + longest,
-- making the full external sweep (v8 included) runnable in one command. The
-- bound is for MEMORY — scale extracts peak multiple GB, so ≈JOBS run at once.

local SELF = debug.getinfo(1, 'S').source:sub(2)
local here = SELF:match('^(.*)/matrix%.lua$')

-- headless print() writes to STDERR; the row protocol and the grid must ride
-- stdout (vim.system captures them per stream), so write it explicitly
local function say(s) io.stdout:write(s .. '\n') end

local COLS = { 'counts', 'valid', 'mem', 'rows', 'expr', 'dfpar', 'fold', 'silent',
    'cache', 'key', 'struct', 'par' }
-- the minutes-tier corpora (scale extracts); everything else is seconds
local HEAVY = { server = true, v8 = true, sylius = true, ghost = true,
    blesh = true, gforth = true, openfirmware = true, bwipp = true,
    zig = true, odin = true }

-- ── args ────────────────────────────────────────────────────────────────
local names, opts = {}, { save = false, row = false, quick = false, cols = nil }
do
    local i = 1
    while i <= #(arg or {}) do
        local a = arg[i]
        if a == '--row' then opts.row = true
        elseif a == '--save' then opts.save = true
        elseif a == '--quick' then opts.quick = true
        elseif a == '--jobs' then
            i = i + 1
            opts.jobs = tonumber(arg[i])
        elseif a == '--mem-mb' then
            i = i + 1
            opts.mem_mb = tonumber(arg[i])
        elseif a == '--timeout' then
            i = i + 1
            opts.timeout = tonumber(arg[i])
        elseif a == '--par-dump' then
            i = i + 1
            opts.pardump = arg[i]
        elseif a == '--file' then
            i = i + 1
            opts.file = arg[i]
        elseif a == '--cols' then
            i = i + 1
            opts.cols = {}
            for c in (arg[i] or ''):gmatch('[^,]+') do opts.cols[c] = true end
        else
            names[#names + 1] = a
        end
        i = i + 1
    end
end
-- ── --file: SCOPE EVERY COLUMN AT ONCE (CART-0429) ────────────────────────────────────
--
-- ★ WHY IT LIVES HERE AND NOT IN THE CENSUS TOOLS. I filed this as "--file on rowcensus /
-- ctrlcensus / dfparity" and the premise was wrong: rowcensus and dfparity have NO CLI at
-- all — they are libraries matrix drives — and ctrlcensus is a standalone script with its
-- own extraction whose `--files N` is a CAP, not a filter. THE TOOL THAT OWNS THEIR EXTRACT
-- IS THIS ONE, so one flag here scopes every column instead of four flags scoping one each.
--
-- ★★ AND A SCOPED ROW IS NOT A GATE. Every baseline in this file is a CORPUS-WIDE claim:
-- `expected` refs/nodes, `budget_mb`, the rows/expr/dfpar EXPECTED pins, the saved struct
-- baseline. Comparing a two-file extract against any of them produces a red cell that means
-- nothing, which is worse than no cell — so:
--   REPORTED, NOT GATED (`~`): rows, expr, dfpar — the census still PRINTS, which is the
--     whole point of a scoped run, it just stops pretending to be a verdict. `~` already
--     means exactly this here ("ran, census not yet calibrated").
--   NOT APPLICABLE (`--`): counts, mem, key, struct — nothing meaningful survives scoping,
--     and `par` because bench.extract_parallel would re-extract the WHOLE corpus and
--     compare it against a subset, i.e. a guaranteed false FAIL.
--   STILL GATED: valid, fold, silent, cache — INTRINSIC checks. Referential integrity,
--     fold round-trip, silent-local and cold==warm are properties of whatever graph they
--     are handed, so a subset is a perfectly good subject for them.
local SCOPE_UNGATED = { rows = true, expr = true, dfpar = true }
local SCOPE_NA = { counts = true, mem = true, key = true, struct = true, par = true }
local SCOPE_NOTE = { 'SCOPED (--file): a corpus-wide baseline cannot judge a subset' }

-- `--file` also SKIPS the not-applicable columns rather than merely refusing their verdict:
-- `par` would otherwise re-extract the WHOLE corpus to compare against a subset, paying the
-- most expensive column in the file for a cell that cannot mean anything.
local function wanted(col)
    if opts.file and SCOPE_NA[col] then return false end
    return not opts.cols or opts.cols[col]
end

-- ── row mode: one corpus, all columns, one JSON line ────────────────────

-- the canonical row/param signature — exactly the fields flow.fold stores,
-- readable off both a raw record row and a folded row_view: byte-equality
-- of these strings IS the round-trip contract (mirrors flow_spec's check)
local function fnsig(rec)
    if not rec then return '' end
    local parts = { table.concat(rec.params or {}, ',') }
    for _, s in ipairs(rec.stmts or {}) do
        parts[#parts + 1] = table.concat({
            s.l or 0, s.c or 0, s.parent or 0, s.kind or '', s.pol or '',
            s.t or '', s.regime or '', tostring(s.const), tostring(s.suspend),
            s.label or '', table.concat(s.def or {}, ','),
            table.concat(s.use or {}, ',') }, '|')
    end
    return table.concat(parts, '\n')
end

-- --par-dump <path>: the PRISTINE-process half of the `par` column — run ONLY
-- the parallel pipeline and dump its slim projection. Isolation is the point:
-- running parallel inside the row process (after its inline extract) was
-- observed to change which edges resolve — allocation history shifts a
-- pairs()-order-dependent choice somewhere in resolution. The claim gated
-- here is "a fresh parallel run == a fresh inline run", each in its own
-- process, exactly how gate.lua --parallel measures it.
if opts.pardump then
    local bench = dofile(here .. '/bench.lua')
    local snapshot = dofile(here .. '/snapshot.lua')
    local okp, pdata = pcall(function ()
        return (bench.extract_parallel(names[1]))
    end)
    if okp then
        local fd = assert(io.open(opts.pardump, 'wb'))
        fd:write(vim.mpack.encode(snapshot.slim(pdata)))
        fd:close()
        say('@@PAR OK')
    else
        say('@@PAR ERR ' .. tostring(pdata):gsub('\n', ' '))
    end
    os.exit(0)
end

local function run_row(name)
    local bench = dofile(here .. '/bench.lua')
    local snapshot = dofile(here .. '/snapshot.lua')
    bench.bootstrap()
    local gd = require 'cartograph.graphdiff'

    local corpus = bench.corpus(name)
    local now = corpus.git and corpus.git.rev
    -- corpus identity BEFORE the extract (mirror gate.lua): a moved/dirty
    -- pinned checkout answers no question — any diff would be corpus drift
    if corpus.rev then
        if not bench.same_rev(corpus.rev, now) then
            return { corpus = name, skip = ('pinned @ %s but checkout @ %s')
                :format(corpus.rev, now or '?') }
        end
        if corpus.git.dirty then
            return { corpus = name, skip = ('checkout @ %s has uncommitted'
                .. ' changes'):format(now) }
        end
    end

    local cells = {}
    local parse -- the expr column's parse-cache reuse (see the `expr` column below)
    -- ★ ONE CHOKEPOINT FOR THE SCOPED VERDICT. Every column reports through `cell`, so the
    -- downgrade lives here rather than in eight column bodies — there is no way to add a
    -- ninth baseline-comparing column that forgets to honour `--file`, because it cannot
    -- report without passing through this function. The DETAIL is kept: a `~` row still
    -- prints its census, which is the entire point of scoping.
    local function cell(col, s, d)
        if opts.file and SCOPE_UNGATED[col] and (s == 'OK' or s == 'FAIL') then s = '~' end
        cells[col] = { s = s, d = d }
    end
    if opts.file then
        for col in pairs(SCOPE_NA) do
            if not opts.cols or opts.cols[col] then cells[col] = { s = '--', d = SCOPE_NOTE } end
        end
    end

    -- ★ THE MATRIX IS A GATE, SO IT IS EXPLICITLY COLD (CART-0429). bench honours
    -- $CARTOGRAPH_BENCH_WARM so a dev loop can reuse a cache; a sweep that produces
    -- PASS/FAIL must never inherit that from the environment. ★ AND THE `cache` COLUMN
    -- BELOW WOULD GO CIRCULAR IF IT DID — it exists to prove warm == cold, which it cannot
    -- do while reading the warm graph as its own baseline.
    local xopts = { cold = true }
    if opts.file then
        local corpus0 = bench.corpus(name)
        local all = require('cartograph.providers.treesitter')
            .list_files(corpus0.root, corpus0.subdirs)
        local keep = {}
        for _, f in ipairs(all or {}) do
            if f:match(opts.file) then keep[#keep + 1] = f end
        end
        if #keep == 0 then
            return { corpus = name, err = ('--file %q matched none of %d files (it is a LUA'
                .. ' PATTERN, not a glob)'):format(opts.file, #(all or {})) }
        end
        xopts.files = keep
    end
    local data, stats = bench.extract(name, xopts)
    local c = require('cartograph.census').take(data)

    -- GRACEFUL DEGRADE (perf-cut P1 follow-on): a corpus whose extract alone
    -- budgets ≳ 40% of this machine's RAM cannot safely DOUBLE-HOLD — the dfpar
    -- legacy re-extract and the cache warm-load each transiently hold a 2nd
    -- full copy alongside the inline `data` (~2× the ~5GB v8 extract ≈ 10GB,
    -- over an 11GB ceiling → the OOM that ERR'd v8's row). Skip those two
    -- columns with an honest note rather than OOM-killing the whole row; a
    -- bigger machine (RAM scales the threshold) or --mem-mb headroom runs them.
    -- 0.4 so v8 (budget 7500 on ~15 GB) triggers with margin; server (3000)
    -- does not. v8's dfpar is uncalibrated (~) anyway, so the only real loss is
    -- v8's cold==warm parity here.
    local ram_mb = (vim.uv.get_total_memory() or (8 * 2 ^ 30)) / 2 ^ 20
    local no_double_hold = corpus.budget_mb and corpus.budget_mb >= ram_mb * 0.4
    local DH_NOTE = { 'skipped: extract too large to double-hold on this RAM'
        .. ' (see --mem-mb / a bigger machine)' }

    if wanted('counts') then
        local expected = corpus.expected
        if not expected then
            cell('counts', '--')
        else
            local refs = c.edges.by_kind.ref or 0
            local okref = not expected.refs or refs == expected.refs
            local oknode = not expected.nodes or c.nodes.total == expected.nodes
            cell('counts', (okref and oknode) and 'OK' or 'FAIL',
                (okref and oknode) and nil or {
                    ('refs %d expected %s · nodes %d expected %s'):format(
                        refs, tostring(expected.refs), c.nodes.total,
                        tostring(expected.nodes)) })
        end
    end

    if wanted('valid') then
        local validate = require 'cartograph.validate'
        local vr = validate.check(data)
        cell('valid', vr.ok and 'OK' or 'FAIL',
            vr.ok and nil or { validate.report(vr) })
    end

    if wanted('mem') then
        if corpus.budget_mb and stats.peak then
            local mb = stats.peak / 2^20
            cell('mem', mb <= corpus.budget_mb and 'OK' or 'FAIL',
                { ('peak %.0f MB budget %d MB'):format(mb, corpus.budget_mb) })
        else
            cell('mem', '--')
        end
    end

    -- ★ THE FINE ROW MODEL (CART-0389). No other column can see it: struct gates
    -- nodes/edges/calls and opening a control form mints neither; dfpar gates the COARSE
    -- projection, which groups a control row together with its body and so reads the same
    -- whether the loop opened or not. Measured, 2522 rows and 988 opened control structures
    -- could appear and vanish with every existing column green. Runs on the SHARED production
    -- `data` -- flow rows are already there, so this costs a walk, not an extract.
    if wanted('rows') then
        local rc = dofile(here .. '/rowcensus.lua')
        local r = rc.check(data)
        if r.fns == 0 then
            cell('rows', '--') -- no flow-bearing functions (token provider)
        else
            local d = { ('fns=%d · %s'):format(r.fns, rc.census(r.cats)) }
            if rc.EXPECTED[name] then
                local diffs = rc.diff(r.cats, rc.EXPECTED[name])
                for _, l in ipairs(diffs) do d[#d + 1] = l end
                cell('rows', #diffs == 0 and 'OK' or 'FAIL', d)
            else
                cell('rows', '~', d) -- ran, census not yet calibrated
            end
        end
    end

    -- ★ THE EXPRESSION IR (CART-0395), and the argument is CART-0389's one column over.
    -- `expr.gate` is a real two-implementation oracle — `expr.reads(row)` vs `use ∪ rmw`,
    -- derived independently over the same node — and NOTHING RAN IT ON A REAL CORPUS.
    -- syngate calls it over a generated LUA corpus, iterating `kind == 'function'`, and
    -- prints a clean zero that was read as a statement about the IR rather than about lua
    -- functions. Pointed anywhere else it fires: elasticsearch 3128, activesupport 450, and
    -- 88 across the three SYNTHETIC corpora this matrix already pins.
    -- PINNED, NOT ASSERTED ZERO, for rowcensus's reason: four open defect classes cannot
    -- block the number from being visible. The review question is directional — a count that
    -- ROSE is a new disagreement; a class that GOES is a fix.
    if wanted('expr') then
        local ec = dofile(here .. '/exprcensus.lua')
        -- a SHIM store over the shared production `data` — expr.of needs node lookup and
        -- file content, not a second ingest (which would double the peak the mem column
        -- measures). One-file line cache: extract emits nodes file by file.
        local nidx = {}
        for _, nn in ipairs(data.nodes or {}) do nidx[nn.id] = nn end
        local cf, cl
        local shim = { data = data, node = function (id) return nidx[id] end,
            content = function (n)
                if not (n and n.file) then return nil end
                if n.file ~= cf then
                    cf = n.file
                    local p = corpus.root .. '/' .. n.file
                    cl = vim.fn.filereadable(p) == 1 and vim.fn.readfile(p) or nil
                end
                return cl
            end }
        local okc, r = pcall(ec.check, shim)
        -- ★★ A CRASH IS NOT AN ABSENCE (CART-0423). Both branches below used to emit the
        -- same neutral `--`, so a census that RAISED read exactly like a Forth corpus that
        -- honestly has no expressions — and a reader scanning the column for red saw
        -- neither. A raise is a FAILURE of this column and must be red; an empty subject
        -- set is a fact about the corpus and must SAY SO rather than render as a bare dash.
        -- The same conflation one layer up is what hid four timed-out corpora for a whole
        -- sweep: a harness that cannot report its own failure manufactures silence.
        if not okc then
            cell('expr', 'FAIL', { 'census RAISED: ' .. tostring(r):gsub('^.*/', '') })
        elseif (r.fns + r.methods) == 0 then
            cell('expr', '--', { ('no expression-bearing subjects (fns=%d methods=%d) —'
                .. ' this corpus cannot gate the expression IR'):format(r.fns, r.methods) })
        else
            -- INSTANCES and DISTINCT ROWS are different numbers and the pin is on the first
            -- (CART-0410): M.check iterates functions, so a row reachable from several
            -- function nodes is counted once per node — 25.8× on cpp's missing:declaration,
            -- 1.0× on binder:if_statement. Reporting only the inflated one is what let a
            -- ranking artifact be read as "the single biggest gap" for a week.
            local dist = ec.distinct(r.instances)
            parse = r.parse
            local d = { ('fns=%d methods=%d · %s'):format(r.fns, r.methods,
                ec.census_distinct(r.cats, dist)) }
            if ec.EXPECTED[name] then
                local diffs = ec.diff(r.cats, ec.EXPECTED[name])
                for _, l in ipairs(diffs) do d[#d + 1] = l end
                cell('expr', #diffs == 0 and 'OK' or 'FAIL', d)
            else
                cell('expr', '~', d) -- ran, census not yet calibrated
            end
        end
    end

    -- dfpar runs on a SEPARATE legacy_df extract (df-strangler step 6): the
    -- shared `data` above is production, whose df IS flow.coarse — comparing it
    -- to flow.coarse would be circular. legacy_df builds the INDEPENDENT dfreg
    -- df (double walk, oracle-only), exactly like dfgate. Kept out of `data` so
    -- the mem column still measures the real single-walk production peak.
    if wanted('dfpar') and no_double_hold then
        cell('dfpar', '--', DH_NOTE)
    elseif wanted('dfpar') then
        local dfp = dofile(here .. '/dfparity.lua')
        -- ★ THE SECOND EXTRACT MUST INHERIT THE SCOPE TOO. dfpar re-extracts with the legacy
        -- df path, and leaving `files` off here made a scoped run report the WHOLE corpus in
        -- this column (fns=8381 beside a 433-node graph) and pay zig's full 107s extract for
        -- it. One flag, every extract in the row — a scope that reaches all but one call
        -- site is a scope that silently lies in exactly one column.
        local ldata = bench.extract(name,
            { legacy_df = true, cold = true, files = xopts.files })
        local r = dfp.check(ldata)
        if r.nfn == 0 then
            cell('dfpar', '--') -- no df-bearing functions (token provider)
        else
            -- `unpaired` is printed BESIDE the compared count on purpose (CART-0381):
            -- "0 divergences" must never be readable as "we compared nothing".
            local d = { ('fns=%d stmts=%d%s ferr=%d · %s'):format(
                r.nfn, r.nstmt, (r.nskip or 0) > 0 and (' unpaired=' .. r.nskip) or '',
                r.ferr, dfp.census(r.cats)) }
            if r.ferr > 0 then
                cell('dfpar', 'FAIL', d)
            elseif dfp.EXPECTED[name] then
                local diffs = dfp.diff(r.cats, dfp.EXPECTED[name])
                for _, l in ipairs(diffs) do d[#d + 1] = l end
                cell('dfpar', #diffs == 0 and 'OK' or 'FAIL', d)
            else
                cell('dfpar', '~', d) -- ran clean, census not yet calibrated
            end
        end
    end

    -- cold==warm through the REAL cache module, redirected to a scratch dir
    -- so the sweep never touches (or trusts) the user's live cache. MUST run
    -- before the fold column: shards encode the RAW flow records — folding
    -- happens after ingest in the real lifecycle too (folded nodes carry
    -- closure-backed _flow accessors the codec rightly refuses)
    if wanted('cache') and no_double_hold then
        cell('cache', '--', DH_NOTE)
    elseif wanted('cache') then
        if not data.stamps then
            cell('cache', '--') -- unstamped source: cache never persists it
        else
            local cache = require 'cartograph.cache'
            local realpath = cache.path
            local scratch = vim.fn.tempname() .. '.matrixcache'
            local base = vim.fn.stdpath('cache') .. '/cartograph'
            cache.path = function (root)
                local p, nroot = realpath(root)
                vim.fn.mkdir(scratch, 'p')
                return scratch .. p:sub(#base + 1), nroot
            end
            local okc, warm = pcall(function ()
                cache.save(data)
                return (cache.load(data.root))
            end)
            cache.path = realpath
            vim.fn.delete(scratch, 'rf')
            if not okc or not warm then
                cell('cache', 'FAIL', { 'cache save/load failed: '
                    .. tostring(warm) })
            else
                -- VALIDATE THE WARM GRAPH TOO (CART-0247). validate.check already enforces
                -- referential integrity — edge-dangling-from/to and call-dangling-to — but
                -- the `valid` column above runs it on the COLD extract, and nothing ran it
                -- on the artifact the cache produces. That is how CART-0245 shipped a warm
                -- zig graph carrying 4122 edges into nodes that were never saved while
                -- `valid` stayed green: the check existed, the graph it needed to see did
                -- not reach it. MEASURED before adding this: 0 dangling endpoints on the
                -- cold graph of all 35 registry corpora, and the check costs 0-205 ms
                -- (v8 the worst, against a 178s extract) — so the invariant is real, it is
                -- already written down, and it only needed running here.
                local vw = require('cartograph.validate').check(warm)
                local cs, ws = snapshot.slim(data), snapshot.slim(warm)
                local det, d = gd.detail(cs, ws, { a = 'cold', b = 'warm', limit = 5 })
                det = det or {}
                if not vw.ok then
                    -- validate.report returns ONE string (the `valid` cell above wraps it
                    -- in a table for the same reason), not a list of lines
                    det[#det + 1] = 'WARM GRAPH INVALID: '
                        .. require('cartograph.validate').report(vw)
                end
                local good = gd.empty(d) and vw.ok
                cell('cache', good and 'OK' or 'FAIL', good and nil or det)
            end
        end
    end

    if wanted('fold') then
        local flow = require 'cartograph.flow'
        local bearing = {}
        for _, n in ipairs(data.nodes or {}) do
            if n.flow and n.flow.stmts then bearing[#bearing + 1] = n end
        end
        if #bearing == 0 then
            cell('fold', '--')
        else
            -- deterministic sample (cap ~2000 fns): copying EVERY raw row
            -- pre-fold would transiently double flow's memory on the scale
            -- corpora; the sample is the round-trip check at corpus breadth
            local step = math.max(1, math.floor(#bearing / 2000))
            local picked, pre = {}, {}
            for i = 1, #bearing, step do
                picked[#picked + 1] = bearing[i]
                pre[bearing[i]] = fnsig(flow.record(bearing[i]))
            end
            flow.fold(data)
            local again = flow.fold(data) -- idempotence: second fold no-ops
            local bad = {}
            for _, n in ipairs(picked) do
                if fnsig(flow.record(n)) ~= pre[n] then bad[#bad + 1] = n.id end
            end
            if again ~= 0 then
                cell('fold', 'FAIL', { ('fold not idempotent: second call'
                    .. ' folded %d rows'):format(again) })
            elseif #bad > 0 then
                local d = { ('%d/%d sampled fns changed through the fold')
                    :format(#bad, #picked) }
                for i = 1, math.min(#bad, 5) do d[#d + 1] = bad[i] end
                cell('fold', 'FAIL', d)
            else
                cell('fold', 'OK',
                    { ('%d fns sampled (of %d)'):format(#picked, #bearing) })
            end
        end
    end

    -- the silent-drop lint needs a store shape; a shim over the raw data
    -- reuses the REAL rule (no reimplemented logic to drift)
    if wanted('silent') then
        local index = {}
        for _, n in ipairs(data.nodes or {}) do index[n.id] = n end
        local shim = { data = data,
            node = function (id) return index[id] end,
            abs = function (f) return f end }
        local findings = require('cartograph.lint').run(shim,
            { only = { ['silent-drop'] = true } })
        if #findings == 0 then
            cell('silent', 'OK')
        else
            local d = { ('%d silent-local gaps'):format(#findings) }
            for i = 1, math.min(#findings, 5) do
                d[#d + 1] = ('%s:%d %s'):format(findings[i].file,
                    findings[i].line, findings[i].message)
            end
            cell('silent', 'FAIL', d)
        end
    end

    -- the ANSWER KEY (synthetic corpora only): the generator's per-call
    -- intended outcomes, regenerated in-memory (deterministic) and checked
    -- against the extracted graph. The SEMANTIC gate: every other column
    -- asks "did the answer change" — this one asks "is the answer RIGHT".
    -- A key edit is a REVIEWED claim ("the new resolution is correct
    -- because…"), not count acceptance.
    if wanted('key') then
        if not corpus.synthetic then
            cell('key', '--')
        else
            local gen = dofile(here .. '/gen.lua')
            local ans = gen.answers(corpus.synthetic.lang,
                corpus.synthetic.files, corpus.synthetic.seed)
            local cidx = {}
            for _, cc in ipairs(data.calls or {}) do
                cidx[(cc.file or '') .. '\31' .. ((cc.line or -1) + 1)
                    .. '\31' .. (cc.callee or '')] = cc
            end
            local nidx = {}
            for _, nn in ipairs(data.nodes or {}) do nidx[nn.id] = nn end
            local bad = {}
            for _, a in ipairs(ans) do
                local cc = cidx[a.file .. '\31' .. a.line .. '\31' .. a.callee]
                local why
                if not cc then
                    why = 'no call extracted at keyed site'
                elseif a.want == 'to' then
                    local tn = cc.to and nidx[cc.to] and nidx[cc.to].name
                    local tier = cc.tinf and 'tinf' or cc.inferred and '~'
                        or 'plain'
                    if not cc.to then
                        why = ('expected → %s, got %s'):format(a.target,
                            cc.refused and ('refused ' .. tostring(cc.refused.rule))
                            or 'UNRESOLVED (silent)')
                    elseif tn ~= a.target then
                        why = ('expected → %s, got → %s'):format(
                            a.target, tostring(tn))
                    elseif a.tier and tier ~= a.tier then
                        why = ('right target, tier %s ≠ expected %s')
                            :format(tier, a.tier)
                    end
                elseif a.want == 'silent' then
                    -- a DOCUMENTED honesty gap, encoded as the current rung
                    -- (e.g. resolve()'s #name<3 silent skip): this site must
                    -- stay silent until the gap is FIXED — then it fails
                    -- loudly and the key upgrade is the reviewed claim
                    if cc.to then
                        why = ('expected SILENT (documented gap), got → %s')
                            :format(nidx[cc.to] and nidx[cc.to].name or cc.to)
                    elseif cc.refused then
                        why = ('expected SILENT (documented gap), got refusal %s')
                            :format(tostring(cc.refused.rule))
                    end
                elseif a.want == 'refused' then
                    if cc.to then
                        why = ('expected refusal %s, got → %s'):format(
                            tostring(a.rule),
                            nidx[cc.to] and nidx[cc.to].name or cc.to)
                    elseif not cc.refused then
                        why = ('expected refusal %s, got SILENT')
                            :format(tostring(a.rule))
                    elseif a.rule and cc.refused.rule ~= a.rule then
                        why = ('refusal rule %s ≠ expected %s'):format(
                            tostring(cc.refused.rule), a.rule)
                    end
                elseif a.want == 'registry' then
                    -- string-keyed registry (stage 3): the retrieval resolves,
                    -- via c.registry, to the registered table (a var node)
                    local rn = cc.registry and nidx[cc.registry]
                        and nidx[cc.registry].name
                    if not cc.registry then
                        why = ('expected registry → %s, got %s'):format(a.target,
                            cc.to and ('call → ' ..
                                (nidx[cc.to] and nidx[cc.to].name or cc.to))
                            or 'nothing')
                    elseif rn ~= a.target then
                        why = ('expected registry → %s, got → %s'):format(
                            a.target, tostring(rn))
                    end
                end
                if why then
                    bad[#bad + 1] = ('%s:%d %s — %s'):format(
                        a.file, a.line, a.callee, why)
                end
            end
            cell('key', #bad == 0 and 'OK' or 'FAIL',
                #bad > 0 and bad
                or { ('%d keyed sites verified'):format(#ans) })
        end
    end

    local slim = snapshot.slim(data)

    if wanted('struct') then
        if opts.save then
            snapshot.save(name, data, { corpus = name, corpus_rev = now,
                corpus_dirty = corpus.git and corpus.git.dirty or nil })
            cell('struct', 'SAVED')
        else
            local base, meta = snapshot.load(name)
            if not base then
                cell('struct', 'NOBASE', { tostring(meta) })
            else
                local det, d = gd.detail(base, slim,
                    { a = 'baseline', b = 'current', decides = 'b', limit = 5 })
                -- MIRROR gate.lua's three cases (CART-0219). Only pinned-and-clean or
                -- UNPINNED corpora reach here (a moved/dirty pinned checkout returned a
                -- skip above), and an unpinned corpus can fail to certify it held still
                -- three ways: identity UNRECORDABLE on either side (same_rev(nil,nil) is
                -- false, so "unknown" was being reported as drift), REV DRIFT, or a DIRTY
                -- tree (a rev names a commit, not a working tree). In those cases the
                -- diff is CONTEXT and the cell is `~` — matrix's own convention for
                -- reported-not-gated — never FAIL.
                -- A PINNED corpus never goes advisory: its rev and cleanliness were
                -- verified above, so a diff there is always the extractor.
                local unknown = not (meta.corpus_rev and now)
                local drifted = not unknown and not bench.same_rev(meta.corpus_rev, now)
                local dirty = (meta.corpus_dirty and true or false)
                    or (corpus.git and corpus.git.dirty and true or false)
                local advisory = (not corpus.rev) and (unknown or drifted or dirty)
                -- ★ THE TOOL SIDE, and here it changes a LABEL that was wrong
                -- (CART-0502). Every branch below asks whether the CORPUS moved,
                -- and when the answer is no the detail line concludes 'extractor
                -- drift' — which is a LIE when the baseline predates an
                -- extraction VERSION bump: the diff is then a MIXTURE of that
                -- change and yours, and 17 of 37 baselines were in exactly that
                -- state. The verdict is untouched (a pinned diff still FAILS);
                -- only the sentence naming the cause is corrected, because
                -- 'extractor drift' sends the reader to the wrong commit.
                local stale, tooldirty, projstale = snapshot.tool_verdict(meta)
                stale = projstale or stale -- a stale PROJECTION explains more
                if det then
                    table.insert(det, 1, unknown
                        and ('corpus identity UNRECORDABLE (baseline %s, now %s) —'
                            .. ' diff is CONTEXT'):format(meta.corpus_rev or '?', now or '?')
                        or (drifted
                            and ('corpus rev drift (baseline @ %s, now @ %s) — may be'
                                .. ' corpus change, not extractor')
                                :format(meta.corpus_rev or '?', now or '?')
                            or (dirty
                                and 'corpus has UNCOMMITTED changes — diff is CONTEXT'
                                or stale or 'extractor drift')))
                    if tooldirty then table.insert(det, 2, tooldirty) end
                end
                cell('struct', gd.empty(d) and 'OK' or (advisory and '~' or 'FAIL'), det)
            end
        end
    end

    -- the second extraction, in a PRISTINE child process (--par-dump above
    -- explains why in-process would measure a different claim); free the
    -- inline data (the slim is all the diff needs) while the child runs
    if wanted('par') then
        if (corpus.provider or 'treesitter') ~= 'treesitter' then
            cell('par', '--') -- no parallel pipeline for the token provider
        else
            data = nil
            collectgarbage(); collectgarbage()
            local tmp = vim.fn.tempname() .. '.parslim'
            local proc = vim.system({ vim.v.progpath, '--headless', '-u',
                'NONE', '-l', SELF, name, '--par-dump', tmp },
                { text = true }):wait(3600 * 1000)
            local pslim
            local fd = io.open(tmp, 'rb')
            if fd then
                local blob = fd:read('a'); fd:close()
                local okd, t = pcall(vim.mpack.decode, blob)
                if okd then pslim = t end
            end
            vim.fn.delete(tmp)
            if not pslim then
                cell('par', 'FAIL', { 'parallel child failed: '
                    .. ((proc.stdout or '') .. (proc.stderr or '')):sub(-300) })
            else
                local det, d = gd.detail(slim, pslim,
                    { a = 'sequential', b = 'parallel', limit = 5 })
                cell('par', gd.empty(d) and 'OK' or 'FAIL', det)
            end
        end
    end

    return { corpus = name, cells = cells, wall = stats.wall, parse = parse,
        -- extraction-floor facts for generated-corpus callers (tools/gen.lua):
        -- a syntax-error wipeout would leave every invariant vacuously green
        fns = (c.nodes.by_kind['function'] or 0)
            + (c.nodes.by_kind.method or 0),
        unparsed = c.nodes.unparsed,
        info = ('nodes %d · edges %d · refs %d · refused %d'):format(
            c.nodes.total, c.edges.total, c.edges.by_kind.ref or 0,
            c.calls.refused) }
end

if opts.row then
    local okr, res = pcall(run_row, names[1])
    if not okr then res = { corpus = names[1], err = tostring(res) } end
    say('@@MATRIX ' .. vim.json.encode(res))
    os.exit(0) -- verdicts travel in the JSON; the exit code is the parent's
end

-- ── orchestrator ────────────────────────────────────────────────────────
local reg = dofile(here .. '/corpora.lua')

if #names == 0 then
    -- default roster: every corpus with PINNED EXPECTED COUNTS — the push-time
    -- sweep. Quick tier first so a systematic breakage surfaces in seconds, not
    -- after server.
    --
    -- `self` used to be special-cased in here on a snapshot-only baseline, and it
    -- could not work: self IS this repo, so every commit changes the corpus and
    -- invalidates the baseline by construction. It went red by DRIFT rather than
    -- by regression — the worst kind of gate, because the only way to green it is
    -- to re-save, which blesses whatever drifted unread. Still a fine corpus to
    -- name EXPLICITLY (observe/callmatrix/rescolmatrix do); just not a gate.
    -- Self-analysis is gated instead by tools/dogfood.lua, which asserts
    -- RATCHETS (counts that may not rise) — the shape of invariant a LIVING
    -- corpus can actually hold.
    local quick, heavy = {}, {}
    for k, v in pairs(reg) do
        if v.expected then
            table.insert(HEAVY[k] and heavy or quick, k)
        end
    end
    table.sort(quick); table.sort(heavy)
    vim.list_extend(names, quick)
    if not opts.quick then vim.list_extend(names, heavy) end
end
for _, n in ipairs(names) do
    -- a literal directory is a row too (bench.corpus accepts it): ad-hoc
    -- roots and GENERATED corpora (tools/gen.lua) sweep like any corpus
    if not reg[n] and vim.fn.isdirectory(n) ~= 1 then
        say(('matrix: unknown corpus %q (see tools/corpora.lua, or pass a'
            .. ' directory)'):format(n))
        os.exit(2)
    end
end

local colnames = {}
for _, col in ipairs(COLS) do
    if wanted(col) then colnames[#colnames + 1] = col end
end
local JOBS = math.max(1, opts.jobs or 4) -- bounded parallel pool (see below)

-- ── PER-ROW DEADLINE (CART-0429) ────────────────────────────────────────────────────────
--
-- ★ THE ONLY CLOCK IN THIS FILE USED TO BE THE POOL'S. `vim.wait` bounded the WHOLE sweep
-- at four hours and no individual row had a deadline, so a wedged corpus could not produce
-- a timeout — it stalled the sweep, and then rendered, four hours later, as "no process was
-- started", which is simply FALSE about a process that had been started and was still
-- running. Nothing downstream could name a death that nothing upstream could inflict.
--
-- This is the half of the CART-0423 verification harness (sweep4.sh) worth folding in. The
-- other half — an rc column — is NOT folded, because this file's naming is already the
-- better one: a shell reading `$?` through `timeout` cannot see a signal at all, while the
-- ERR branch below reads `proc.signal` FIRST. A grid column printing `0` on thirty green
-- rows would be vestigial; the surface for a row's status here is ERR + wall.
--
-- ★ THE NUMBER IS THE FOLDED HARNESS'S, AND IT IS A MEASUREMENT. 2400 s is the deadline all
-- 37 corpora ran under in that sweep without one trip, against a largest MEASURED row of
-- 174.4 s (v8, five columns) — roughly 14× margin, which is the point: a deadline exists to
-- catch a WEDGE, and one tight enough to fire on a slow-but-live row would be a false FAIL
-- on the biggest corpus, i.e. the wrong-population trap one more time. `--timeout S`
-- overrides it and `--timeout 0` disables it.
--
-- ★★ AND `vim.system{timeout=}` IS NOT A DEADLINE — IT IS A REQUEST. MEASURED, and it cost
-- two wrong cuts of this change to find out. It sends SIGTERM and does NOT escalate, and an
-- `nvim --headless -l` child DOES NOT DIE ON TERM: a child given a 2 s timeout ran its full
-- 20 s of work, printed its output, and exited on its own — while the parent reported
-- `code = 124`. My first cut passed `timeout` and trusted `code == 124` to name the death,
-- so `matrix zig --timeout 5` printed `timeout 5s/row` in its own header and then a green
-- 118.8 s row. It probed clean beforehand only because the probe's child was `sleep`, which
-- dies on TERM; the real child is the one that doesn't.
--
-- ★★ AND 124 IS THE PARENT'S INTENT, NOT THE CHILD'S FATE. It is set when the timer fires
-- whether or not the kill landed — so the one field the first cut chose as its discriminator
-- reads identically for "killed at the deadline" and "ignored the deadline and finished
-- fine". A harness must not infer from an exit code what it already KNOWS: `timedout` below
-- is set by the code that does the killing, which is the only witness that cannot be wrong.
--
-- So the escalation is OWNED here: TERM at the deadline, SIGKILL after GRACE. Verified on
-- the same TERM-surviving child — 4.00 s instead of 20, `code = 0 signal = 9`, empty stdout.
-- ★ Note that signature: a hard-killed row arrives as code 0, which is precisely the
-- laundering the ERR branch below already warns about, and precisely what an OOM kill looks
-- like. GRACE is pure margin (10 s against a 2400 s deadline, 240×); it exists so a row that
-- is merely SLOW rather than wedged can still shut down and flush, and the measured cost of
-- not escalating at all is that the deadline does nothing whatsoever.
local TIMEOUT = opts.timeout or 2400
local GRACE = 10 -- seconds between the TERM and the SIGKILL
say(('matrix: %d corpora × %s%s  [jobs %d%s]'):format(#names,
    table.concat(colnames, ','), opts.save and '  [--save]' or '', JOBS,
    TIMEOUT > 0 and (', timeout %ds/row'):format(TIMEOUT) or ', NO row deadline'))

local W = 14 -- corpus column width
local head = { ('%-' .. W .. 's %7s'):format('corpus', 'wall') }
for _, col in ipairs(colnames) do head[#head + 1] = ('%-6s'):format(col) end
say(table.concat(head, ' '))

-- BOUNDED PARALLEL POOL (perf-cut P1): the rows are already isolated child
-- processes, so run up to JOBS of them at once instead of one-at-a-time — the
-- sweep wall drops from Σ to ≈ (Σ / JOBS) + longest-single. BOUNDED because the
-- scale corpora are MEMORY-heavy (v8 ~3.8 GB inline peak) and unbounded spawn
-- OOMs/SIGTERMs; JOBS keeps ≈JOBS concurrent extracts. Tunable via --jobs on a
-- bigger/smaller machine. Live per-corpus completion prints to STDERR; the grid
-- renders in roster order once all rows land (deterministic output).
local function build_cmd(name)
    local cmd = { vim.v.progpath, '--headless', '-u', 'NONE', '-l', SELF,
        name, '--row' }
    if opts.save then cmd[#cmd + 1] = '--save' end
    -- ★ THE ROW RUNS IN A CHILD, SO EVERY FLAG THAT CHANGES THE ROW MUST BE FORWARDED.
    -- Omitting this made `--file` a silent no-op: the parent trimmed the column list and
    -- printed a scoped-looking header while the child extracted the WHOLE corpus and
    -- compared it against the full pins — 410s, `nodes 9768`, and an `expr OK` that was a
    -- verdict about zig rather than about the one file asked for. A flag the parent
    -- understands and the child does not is worse than an unimplemented flag.
    if opts.file then
        cmd[#cmd + 1] = '--file'
        cmd[#cmd + 1] = opts.file
    end
    if opts.cols then
        cmd[#cmd + 1] = '--cols'
        cmd[#cmd + 1] = table.concat(colnames, ',')
    end
    return cmd
end

-- launch HEAVY (long-pole) corpora first — longest-processing-time-first keeps
-- the makespan ≈ the slowest single row instead of stranding v8 in the tail.
-- (render order stays the roster order below; results are keyed by name.)
local pending = {}
for _, n in ipairs(names) do if HEAVY[n] then pending[#pending + 1] = n end end
for _, n in ipairs(names) do if not HEAVY[n] then pending[#pending + 1] = n end end

-- MEMORY-AWARE admission: the scale extracts peak multiple GB (v8's par/dfpar
-- phase ~10 GB), so a flat JOBS count is NOT safe — two big corpora overlapping
-- exhausts RAM and silently loses their rows (observed: server+v8 both ERR'd at
-- jobs=4 flat, yet each passes solo). So gate on a memory budget too: admit a
-- corpus only if the in-flight budget_mb sum leaves room; the biggest always
-- runs via the running==0 escape. budget_mb (corpora.lua's ~2x-peak figure) is
-- the relative weight. At 0.5×RAM the biggest (v8, budget 7500) runs SOLO — its
-- real par/dfpar peak (~10 GB) is close to the machine ceiling, so nothing may
-- share with it — while server(3000)+mids still co-run and v8/server never
-- overlap (the pair that OOM'd). --mem-mb overrides.
local total_mb = (vim.uv.get_total_memory() or (8 * 2 ^ 30)) / 2 ^ 20
local MEM_BUDGET = opts.mem_mb or math.floor(total_mb * 0.5)
local function weight(name) return (reg[name] and reg[name].budget_mb) or 500 end

local procs = {} -- name -> raw vim.SystemCompleted (parsed after the pool drains)
-- ★ `procs` IS SET IN on_exit, so its absence means "did not FINISH", not "did not START".
-- Conflating those is what printed "no process was started" for a row that was running at
-- that very moment. `launched` is the field that tells them apart.
local launched, timedout, hardkill, timers = {}, {}, {}, {}
local running, finished, inflight_mb = 0, 0, 0
local function launch(name)
    running = running + 1
    launched[name] = true
    inflight_mb = inflight_mb + weight(name)
    -- on_exit runs in a fast context: only stash the raw result + a stderr tick
    -- (pure io/Lua, no vim API); all parsing/rendering happens after the wait
    local obj = vim.system(build_cmd(name), { text = true }, function (proc)
        procs[name] = proc
        running = running - 1
        inflight_mb = inflight_mb - weight(name)
        finished = finished + 1
        for _, t in ipairs(timers[name] or {}) do
            if not t:is_closing() then t:stop(); t:close() end
        end
        timers[name] = nil
        io.stderr:write(('  [%d/%d] %s\n'):format(finished, #names, name))
    end)
    if TIMEOUT <= 0 then return end
    timers[name] = {}
    -- uv timers, not vim.system's `timeout`, for the reason argued above. Both steps are
    -- guarded on `procs[name]`: a row that finished normally is never signalled, and the
    -- handles are closed from on_exit so a completed row leaves nothing armed.
    local function at(sec, fn)
        local t = assert(vim.uv.new_timer())
        table.insert(timers[name], t)
        t:start(sec * 1000, 0, function ()
            if not t:is_closing() then t:stop(); t:close() end
            if procs[name] then return end
            fn()
        end)
    end
    at(TIMEOUT, function ()
        timedout[name] = true
        pcall(function () obj:kill(15) end)
    end)
    at(TIMEOUT + GRACE, function ()
        hardkill[name] = true
        pcall(function () obj:kill(9) end)
    end)
end
-- pump: keep the pool full under BOTH the job count and the memory budget,
-- scanning past a corpus that doesn't fit so it never head-of-line-blocks a
-- smaller one behind it. Relaunches from the wait callback as slots/RAM free.
-- ★ THE ROW DEADLINE MUST BE THE BINDING CLOCK, so the pool's wait is DERIVED from it
-- rather than left at a flat four hours. 31 rows at jobs 4, each hitting a 2400 s deadline,
-- is ~5.2 h of makespan: a flat 4 h would expire FIRST and truncate live rows into exactly
-- the stall the deadline was added to remove — the pool cutting in ahead of the per-row
-- clock is the same bug wearing the other clock's coat.
local POOL_WAIT = math.max(3600 * 1000 * 4,
    TIMEOUT > 0 and (math.ceil(#names / JOBS) + 1) * TIMEOUT * 1000 or 0)
vim.wait(POOL_WAIT, function ()
    while running < JOBS and #pending > 0 do
        local pick
        if running == 0 then
            pick = 1 -- always run at least one, even if it alone exceeds budget
        else
            for i, name in ipairs(pending) do
                if inflight_mb + weight(name) <= MEM_BUDGET then pick = i; break end
            end
        end
        if not pick then break end -- nothing fits now; wait for a slot to free
        launch(table.remove(pending, pick))
    end
    return finished >= #names
end, 25)

local anyfail, anysoft = false, false
local details = {}
local parselines = {} -- the folded census log (see below the grid)
for _, name in ipairs(names) do
    io.stdout:write(('%-' .. W .. 's '):format(name)); io.stdout:flush()
    local proc = procs[name]
    local res
    for line in ((proc and proc.stdout) or ''):gmatch('[^\n]+') do
        local j = line:match('^@@MATRIX (.+)$')
        if j then
            local okj, t = pcall(vim.json.decode, j)
            if okj then res = t end
        end
    end
    if not res then
        -- ★ "row process failed (code 0)" IS A SELF-CONTRADICTION, and it was the printed
        -- text for the case that matters most (CART-0423): the child EXITED CLEANLY and
        -- emitted no @@MATRIX line. That is a REPORTING failure, not a crash, and it reads
        -- completely differently — a crash has a stack, this has a silence. Name the three
        -- states apart, and say the code is a SIGNAL when it looks like one, because a
        -- 137 that prints as "137" is one lookup away from being understood and a 137 that
        -- prints as "failed" is not.
        local code, sig = proc and proc.code, proc and proc.signal
        local why
        -- ★★ `code` ALONE LAUNDERS A KILL INTO A CLEAN EXIT. A row child SIGKILLed by the
        -- OOM killer or a deadline arrives here with signal=9 and code=0, so the first
        -- version of this branch printed "exited 0 but emitted no @@MATRIX line — a
        -- REPORTING failure, not a crash" for a process that had been SHOT. That sentence
        -- was true about what the parent SAW and false about what happened.
        -- ★ Read the SIGNAL first, always: it is the only field that distinguishes "the
        -- child chose to stop" from "the child was stopped". Third layer in this one
        -- ticket to lose a death on the way to a reader — after `$?` through a pipe and a
        -- sweep harness with no rc column — and the lesson each time is the same: BEFORE
        -- improving how a status is printed, check that the status is TRUE, or the better
        -- message just states the wrong thing more clearly.
        -- ★ THE DEADLINE BRANCH GOES ABOVE THE SIGNAL BRANCH, and it reads OUR OWN FLAG
        -- rather than the child's exit status. A row we hard-killed arrives as code 0 /
        -- signal 9 — identical to an OOM kill — so the signal-first branch below, correct
        -- for everything else, would report a deadline as "KILLED by signal 9 — a timeout
        -- or an OOM looks like this". It does. And here we are the ones who know which.
        if not proc then
            why = launched[name]
                and ('the row was LAUNCHED and was STILL RUNNING when the pool deadline'
                    .. ' expired — it was not killed and no result was ever collected')
                or ('the row was NEVER LAUNCHED — it was still queued when the pool'
                    .. ' deadline expired')
        elseif timedout[name] then
            why = ('the row hit its %ds DEADLINE (--timeout) and was %s — it did not FAIL,'
                .. ' it never finished (code %s, signal %s)'):format(TIMEOUT,
                    hardkill[name] and ('SIGKILLed %ds later, having ignored the TERM')
                        :format(GRACE) or 'terminated',
                    tostring(code), tostring(sig))
        elseif type(sig) == 'number' and sig ~= 0 then
            why = ('the row process was KILLED by signal %d — a timeout or an OOM looks'
                .. ' like this, and it is NOT a clean exit however `code` reads'):format(sig)
        elseif type(code) == 'number' and code > 128 then
            why = ('the row process was KILLED by signal %d (exit %d)'):format(code - 128, code)
        elseif code == 0 then
            why = 'the row process exited 0 (signal 0) but emitted no @@MATRIX line — it'
                .. ' really did run and say nothing, which is a REPORTING failure'
        else why = ('the row process exited %s'):format(tostring(code)) end
        res = { corpus = name, err = why .. (proc and proc.stderr and #proc.stderr > 0
            and ': ' .. proc.stderr:sub(-400) or '') }
    end

    -- ★ THE EDGE THE OWNED ESCALATION CREATES: the deadline fired, TERM was sent, and the
    -- row finished and REPORTED inside the grace window anyway. Its numbers are a completed
    -- row's and are fine — but it overran a limit this run declared, and a green cell would
    -- be the only trace. Say it, and make the run soft-fail so the exit code carries it.
    if timedout[name] and res and not res.err then
        details[#details + 1] = { name, { ('★ the %ds DEADLINE fired for this row, which then'
            .. ' finished and reported inside the %ds grace window — the cells below are a'
            .. ' COMPLETED row\'s, but it overran the limit this run declared')
            :format(TIMEOUT, GRACE) } }
        anysoft = true
    end

    if res.skip then
        io.stdout:write(('%7s SKIP: %s\n'):format('', res.skip))
        anysoft = true
    elseif res.err then
        io.stdout:write(('%7s ERR\n'):format(''))
        details[#details + 1] = { name, { res.err } }
        anyfail = true
    else
        local line = { ('%6.1fs'):format(res.wall or 0) }
        local rowdet = {}
        for _, col in ipairs(colnames) do
            local cellr = res.cells[col]
            local s = cellr and cellr.s or '?'
            line[#line + 1] = ('%-6s'):format(s)
            if s == 'FAIL' or s == '?' then anyfail = true end
            if s == 'NOBASE' or s == '~' then anysoft = true end
            if cellr and cellr.d and s ~= 'OK' and s ~= '--' then
                rowdet[#rowdet + 1] = col .. ':'
                for _, l in ipairs(cellr.d) do
                    rowdet[#rowdet + 1] = '  ' .. l
                end
            end
        end
        io.stdout:write(table.concat(line, ' ') .. '\n')
        if res.parse then parselines[#parselines + 1] = { name, res.parse } end
        if #rowdet > 0 then
            if res.info then rowdet[#rowdet + 1] = res.info end
            details[#details + 1] = { name, rowdet }
        end
    end
end

for _, d in ipairs(details) do
    say('')
    say(d[1] .. ':')
    for _, l in ipairs(d[2]) do say('  ' .. l) end
end

-- ── the parse-cache reuse log (CART-0429) ───────────────────────────────────────────────
--
-- The second half of the folded harness. ★ IT PRINTS UNCONDITIONALLY, AND THAT IS THE FOLD:
-- the details section above suppresses a cell's detail when the cell is OK, so hanging this
-- off the `expr` column's detail lines would have hidden it on exactly the green rows the
-- old harness showed it on — a fold that only reports when something else is already red is
-- a drop wearing a fold's name.
--
-- ★ REPORTED, NOT GATED, and deliberately: `miss` IS the parse count, so the by-file walk's
-- claim is that it tracks the FILE count — but a miss also happens once per SUBJECT in a
-- file that fails to parse (`expr.parse_root` counts the miss before its pcall and caches
-- nothing on failure). The same two numbers therefore mean "the grouping regressed" and
-- "this corpus has an unparseable file", so a threshold here would be an invention. What
-- makes it worth printing at all is that the census output is IDENTICAL under both — the
-- performance defect that cost four corpora their census for months is invisible to every
-- verdict in this grid, and visible in this one line.
if #parselines > 0 then
    say('')
    say('parse cache (expr column) — `miss` IS the parse count; the by-file walk\'s claim'
        .. ' is that it tracks FILES:')
    for _, e in ipairs(parselines) do
        local pp = e[2]
        say(('  %-' .. W .. 's %7d hit %6d miss over %5d file(s)  %5.1f%% reuse%s'):format(
            e[1], pp.hit or 0, pp.miss or 0, pp.files or 0,
            100 * (pp.hit or 0) / math.max(1, (pp.hit or 0) + (pp.miss or 0)),
            (pp.nofile or 0) > 0
                and (' · %d subject(s) with no file'):format(pp.nofile) or ''))
    end
end

say('')
say('MATRIX: ' .. (anyfail and 'FAIL' or anysoft and 'PASS (with notes)' or 'PASS'))
os.exit(anyfail and 1 or (anysoft and 2 or 0))
