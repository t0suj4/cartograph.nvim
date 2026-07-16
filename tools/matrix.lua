-- The MATRIX runner: corpus × invariant, one command, one grid.
--
--   nvim --headless -u NONE -l tools/matrix.lua [<corpus>...] [--quick]
--        [--cols a,b,c] [--save]
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
-- orchestrator renders comes from that.

local SELF = debug.getinfo(1, 'S').source:sub(2)
local here = SELF:match('^(.*)/matrix%.lua$')

-- headless print() writes to STDERR; the row protocol and the grid must ride
-- stdout (vim.system captures them per stream), so write it explicitly
local function say(s) io.stdout:write(s .. '\n') end

local COLS = { 'counts', 'valid', 'mem', 'dfpar', 'fold', 'silent',
    'cache', 'key', 'struct', 'par' }
-- the minutes-tier corpora (scale extracts); everything else is seconds
local HEAVY = { server = true, v8 = true, sylius = true, ghost = true,
    blesh = true, gforth = true, openfirmware = true, bwipp = true }

-- ── args ────────────────────────────────────────────────────────────────
local names, opts = {}, { save = false, row = false, quick = false, cols = nil }
do
    local i = 1
    while i <= #(arg or {}) do
        local a = arg[i]
        if a == '--row' then opts.row = true
        elseif a == '--save' then opts.save = true
        elseif a == '--quick' then opts.quick = true
        elseif a == '--par-dump' then
            i = i + 1
            opts.pardump = arg[i]
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
local function wanted(col) return not opts.cols or opts.cols[col] end

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
    local function cell(col, s, d) cells[col] = { s = s, d = d } end

    local data, stats = bench.extract(name)
    local c = require('cartograph.census').take(data)

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

    -- dfpar runs on the RAW records (pre-fold), exactly like dfgate's
    -- bench.extract path — same data the 11 calibrated censuses were pinned on
    if wanted('dfpar') then
        local dfp = dofile(here .. '/dfparity.lua')
        local r = dfp.check(data)
        if r.nfn == 0 then
            cell('dfpar', '--') -- no df-bearing functions (token provider)
        else
            local d = { ('fns=%d stmts=%d ferr=%d · %s'):format(
                r.nfn, r.nstmt, r.ferr, dfp.census(r.cats)) }
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
    if wanted('cache') then
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
                local d = gd.diff(snapshot.slim(data), snapshot.slim(warm))
                cell('cache', gd.empty(d) and 'OK' or 'FAIL',
                    gd.empty(d) and nil or gd.report(d, { limit = 10 }))
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
                local d = gd.diff(base, slim)
                local det = gd.empty(d) and nil or gd.report(d, { limit = 10 })
                if det and not bench.same_rev(meta.corpus_rev, now) then
                    table.insert(det, 1, ('corpus rev drift (baseline @ %s,'
                        .. ' now @ %s) — may be corpus change, not extractor')
                        :format(meta.corpus_rev or '?', now or '?'))
                end
                cell('struct', gd.empty(d) and 'OK' or 'FAIL', det)
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
                local d = gd.diff(slim, pslim)
                cell('par', gd.empty(d) and 'OK' or 'FAIL',
                    gd.empty(d) and nil or gd.report(d, { limit = 10 }))
            end
        end
    end

    return { corpus = name, cells = cells, wall = stats.wall,
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
    -- default roster: every corpus with pinned expected counts, plus self
    -- (snapshot-only baseline) — the push-time sweep. Quick tier first so
    -- a systematic breakage surfaces in seconds, not after server.
    local quick, heavy = {}, {}
    for k, v in pairs(reg) do
        if v.expected or k == 'self' then
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
say(('matrix: %d corpora × %s%s'):format(#names,
    table.concat(colnames, ','), opts.save and '  [--save]' or ''))

local W = 14 -- corpus column width
local head = { ('%-' .. W .. 's %7s'):format('corpus', 'wall') }
for _, col in ipairs(colnames) do head[#head + 1] = ('%-6s'):format(col) end
say(table.concat(head, ' '))

local anyfail, anysoft = false, false
local details = {}
for _, name in ipairs(names) do
    io.stdout:write(('%-' .. W .. 's '):format(name)); io.stdout:flush()
    local cmd = { vim.v.progpath, '--headless', '-u', 'NONE', '-l', SELF,
        name, '--row' }
    if opts.save then cmd[#cmd + 1] = '--save' end
    if opts.cols then
        cmd[#cmd + 1] = '--cols'
        cmd[#cmd + 1] = table.concat(colnames, ',')
    end
    local proc = vim.system(cmd, { text = true }):wait(3600 * 1000)
    local res
    for line in (proc.stdout or ''):gmatch('[^\n]+') do
        local j = line:match('^@@MATRIX (.+)$')
        if j then
            local okj, t = pcall(vim.json.decode, j)
            if okj then res = t end
        end
    end
    if not res then
        res = { corpus = name, err = ('row process failed (code %s)%s')
            :format(tostring(proc.code),
                proc.stderr and #proc.stderr > 0
                    and ': ' .. proc.stderr:sub(-400) or '') }
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

say('')
say('MATRIX: ' .. (anyfail and 'FAIL' or anysoft and 'PASS (with notes)' or 'PASS'))
os.exit(anyfail and 1 or (anysoft and 2 or 0))
