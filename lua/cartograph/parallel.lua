-- Parallel extraction: worker processes parse file batches pulled from a
-- PRIORITY queue while the editor stays responsive and the browser fills
-- in as chunks arrive. The queue serves the user's attention, not the
-- filesystem's order: open buffers first (current buffer at the head),
-- then most-recently-modified, then the rest — and descending into a
-- file still in the queue extracts it in-process RIGHT NOW (demand),
-- with arrival-dedup so its queued copy is skipped.
--
-- Semantics are IDENTICAL to sequential extraction, by construction:
--
--   phase 1 (parallel) — workers parse batches with the id pass skipped;
--   audit (parent)     — every cross-file HYPOTHESIS a worker made
--                        (name-matched, indirect-literal, traced) is
--                        nulled: unique-in-batch is not unique-globally;
--   relink (parent)    — the global resolver re-derives those links
--                        against the full node set, full-fidelity ranges;
--   phase 2 (parallel) — workers run the id pass (use edges, dispatch
--                        refs, cbarg marks) against PARENT-built global
--                        indexes.
--
-- Same-file resolutions are never touched — a file lives in exactly one
-- batch, so file-scope decisions are already global truth.

local M = {}

M.BATCH = 48 -- nominal — still the heuristic for how many workers to spawn
-- Slices are shaped by PARSE COST (≈ file bytes), not count: a loaded session's
-- files span thousands-fold in size, so equal-count slices are wildly unequal
-- work. The byte budget ramps MIN..MAX (from MIN for fast first paint — see
-- M.extract); COUNT_CAP bounds a slice of many tiny files so priority order and
-- first-paint granularity are kept.
M.MIN_BYTES, M.MAX_BYTES, M.COUNT_CAP = 8 * 1024, 256 * 1024, 128

local function plugin_root()
    local src = debug.getinfo(1, 'S').source:sub(2)
    return vim.fn.fnamemodify(src, ':h:h:h')
end

local function worker_rtp()
    local out = { plugin_root() }
    for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
        if p:find('nvim%-treesitter') then out[#out + 1] = p end
    end
    return out
end

function M.default_workers()
    local n = (vim.uv.available_parallelism and vim.uv.available_parallelism()) or 4
    return math.max(2, math.min(8, n - 1))
end

--- Carve the next slice from `ordered` starting at `from`: consecutive files
--- (priority order preserved) until the cumulative parse-cost proxy (bytes)
--- reaches `budget` or the count hits `cap` — so each slice is ~equal WORK, not
--- equal count. Always ≥1 file, so a lone oversized file is its own slice.
--- Returns (slice, next_from). Pure; exposed for tests.
function M.slice(ordered, size, from, budget, cap)
    local b, bytes, i = {}, 0, from
    while i <= #ordered and #b < cap do
        b[#b + 1] = ordered[i]
        bytes = bytes + (size[ordered[i]] or 0)
        i = i + 1
        if bytes >= budget then break end
    end
    return b, i
end

--- Percentile summary of a list of durations (ms). Nearest-rank percentiles —
--- P99 is the stall you feel at the tail, not an average that hides it. Pure;
--- exposed for tests. Returns { n, mean, p50, p90, p95, p99, max }.
function M.summarize(list)
    local n = #list
    if n == 0 then return { n = 0 } end
    local s = {}
    for i, v in ipairs(list) do s[i] = v end
    table.sort(s)
    local sum = 0
    for _, v in ipairs(s) do sum = sum + v end
    local function pct(p) return s[math.max(1, math.ceil(p / 100 * n))] end
    return { n = n, mean = sum / n, p50 = pct(50), p90 = pct(90),
        p95 = pct(95), p99 = pct(99), max = s[n] }
end

--- Pure priority order: current buffer first, then other open buffers
--- (in ctx order), then by modification time, newest first. ctx =
--- { current?, bufs = {rel,...}, mtime = fn(rel) -> secs }.
function M.order(files, ctx)
    local bufpos = {}
    for i, b in ipairs(ctx.bufs or {}) do
        if not bufpos[b] then bufpos[b] = i end
    end
    local mt = {}
    for _, f in ipairs(files) do
        mt[f] = ctx.mtime and ctx.mtime(f) or 0
    end
    local sorted = {}
    for _, f in ipairs(files) do sorted[#sorted + 1] = f end
    table.sort(sorted, function (a, b)
        local ca, cb = a == ctx.current, b == ctx.current
        if ca ~= cb then return ca end
        local ba, bb = bufpos[a], bufpos[b]
        if (ba ~= nil) ~= (bb ~= nil) then return ba ~= nil end
        if ba and bb and ba ~= bb then return ba < bb end
        if mt[a] ~= mt[b] then return mt[a] > mt[b] end
        return a < b
    end)
    return sorted
end

-- the editor's actual attention, for M.order: current buffer, then the
-- persisted WORKING SET (declared intent outranks incidentally-open
-- buffers), then other loaded buffers. A multi-root corpus (self://,
-- abs given) has no single root to match buffers against, so ordering
-- falls to mtime + name; `abs` resolves the labelled keys for mtime.
local function attention(root, abs)
    local ctx = { bufs = {} }
    local function rel(buf)
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= '' and name:sub(1, #root + 1) == root .. '/' then
            return name:sub(#root + 2)
        end
    end
    if not abs then
        ctx.current = rel(vim.api.nvim_get_current_buf())
        for _, f in ipairs(require('cartograph.store').ws_peek(root)) do
            ctx.bufs[#ctx.bufs + 1] = f
        end
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b) then
                local r = rel(b)
                if r then ctx.bufs[#ctx.bufs + 1] = r end
            end
        end
    end
    ctx.mtime = function (f)
        local st = vim.uv.fs_stat(abs and abs(f) or (root .. '/' .. f))
        return st and st.mtime.sec or 0
    end
    return ctx
end

local function spawn(job, cb)
    local jf = vim.fn.tempname() .. '.job.json'
    job.out = vim.fn.tempname() .. '.chunk.json'
    local fd = assert(io.open(jf, 'w'))
    fd:write(vim.json.encode(job))
    fd:close()
    local worker = plugin_root() .. '/lua/cartograph/worker.lua'
    vim.system({ vim.v.progpath, '-u', 'NONE', '-i', 'NONE', '--headless',
        '-l', worker, jf }, {}, function (res)
        vim.schedule(function ()
            local chunk
            if res.code == 0 then
                local cfd = io.open(job.out, 'rb')
                if cfd then
                    local cache = require('cartograph.cache')
                    local raw = cfd:read('a')
                    chunk = cache.decode(raw)
                    if chunk then
                        -- wire size (worker→parent IPC volume) — the fold-emit strategy's
                        -- other axis alongside the merge peak
                        chunk._wire_bytes = #raw
                        -- merge_callstore folds calls straight from the segment
                        -- (rescols.add_segment in merge_chunk), so LEAVE callseg/calltab
                        -- on the chunk — never materialize the record array here. Otherwise
                        -- the record path needs the calls, so unpack now.
                        if not require('cartograph.config').merge_callstore then
                            cache.unpack_calls(chunk) -- segment → calls
                        end
                    end
                    cfd:close()
                end
            end
            vim.fn.delete(jf)
            vim.fn.delete(job.out)
            cb(chunk, res)
        end)
    end)
end

-- id of an edge endpoint -> its file (ids embed the file as the prefix)
local function file_of(id)
    return id:match('^(.-)::') or id
end

-- pull a worker's self-reported footprint off its chunk (metrics are
-- telemetry, never graph data) and record it with the parent-measured
-- turnaround, so spawn overhead = dt - wall is a number per slice
local function take_metrics(s, chunk, dt_ms)
    if chunk and chunk._wire_bytes then -- IPC volume (worker→parent), any chunk
        s.ipc_bytes = (s.ipc_bytes or 0) + chunk._wire_bytes
        chunk._wire_bytes = nil
    end
    local m = chunk and chunk._metrics
    if not m then return end
    chunk._metrics = nil
    m.dt_ms = dt_ms
    s.wmetrics[#s.wmetrics + 1] = m
end

-- fold a phase-1 chunk into the session, skipping files that already
-- arrived (a demanded file's queued copy lands later and must not
-- duplicate); marks the chunk's files as arrived
local function merge_chunk(s, chunk)
    -- worker fold-emit ([[cartograph-thin-index]] multi-store collect): a folded chunk ships
    -- its df/flow store ONCE (chunk._dfcol/_flowcol) with nodes detached; re-hang the store
    -- on each node so df/flow reads resolve, then collect (the store rides on the nodes'
    -- refs). No-op for raw chunks (demand/fallback carry no store).
    if chunk._dfcol then require('cartograph.df').attach(chunk) end
    if chunk._flowcol then require('cartograph.flow').attach(chunk) end
    local acc, seen = s.acc, s.arrived
    for _, n in ipairs(chunk.nodes or {}) do
        if not seen[n.file] then acc.nodes[#acc.nodes + 1] = n end
    end
    for _, e in ipairs(chunk.edges or {}) do
        if not seen[file_of(e.from)] then acc.edges[#acc.edges + 1] = e end
    end
    -- step 2-live: fold this chunk's calls into the columnar accumulator (its own
    -- per-file dedup matches the `seen` check) and let the record tables be freed;
    -- else the record path appends into acc.calls
    if s.callacc then
        -- worker chunks arrive with the wire SEGMENT (callseg) still on them (spawn left it
        -- for merge_callstore) → fold straight into columns, no record array. Demand/fallback
        -- chunks are raw ts.extract output (chunk.calls, no callseg) → the record add().
        if chunk.callseg then s.callacc.add_segment(chunk.callseg, chunk.calltab)
        else s.callacc.add(chunk.calls or {}) end
    else
        for _, c in ipairs(chunk.calls or {}) do
            if not seen[c.file] then acc.calls[#acc.calls + 1] = c end
        end
    end
    -- OO extends pairs (for transitive parent::m resolution in relink):
    -- deduped by defining file, same as the rest of the slice's data
    acc.extends = acc.extends or {}
    for _, x in ipairs(chunk.extends or {}) do
        if not seen[x.file] then acc.extends[#acc.extends + 1] = x end
    end
    -- the OTHER resolution side-tables relink's passes consume — every one
    -- added since extends was wired had been DROPPED here, so the parallel
    -- graph silently resolved java method-refs a tier lower and lost F1
    -- interface→impl redirects entirely (the matrix's par column caught it).
    -- implements: file-tagged list, deduped like extends
    acc.implements = acc.implements or {}
    for _, x in ipairs(chunk.implements or {}) do
        if not seen[x.file] then acc.implements[#acc.implements + 1] = x end
    end
    -- beans: class -> bean-name map (file-less). Extraction is a pure
    -- function of content, so a demanded file's duplicate chunk overlays
    -- the same values; conflicting SAME-class beans across different files
    -- would be arrival-ordered — pathological (dup class names w/ distinct
    -- @Service names), accepted and left to the par gate to surface
    acc.beans = acc.beans or {}
    for cls, bn in pairs(chunk.beans or {}) do acc.beans[cls] = bn end
    -- ruby_anc: inheritance/mixin ancestor edges (R4), file-tagged list, deduped
    -- like extends — relink's resolve_ruby_ancestors consumes them
    acc.ruby_anc = acc.ruby_anc or {}
    for _, x in ipairs(chunk.ruby_anc or {}) do
        if not seen[x.file] then acc.ruby_anc[#acc.ruby_anc + 1] = x end
    end
    -- fieldtypes (zig struct field types): file-tagged list, deduped like
    -- extends — relink's resolve_field_chain builds the typename→field→type map
    acc.fieldtypes = acc.fieldtypes or {}
    for _, x in ipairs(chunk.fieldtypes or {}) do
        if not seen[x.file] then acc.fieldtypes[#acc.fieldtypes + 1] = x end
    end
    -- ruby_ctor (R5 ctor bindings): keyed BY FILE, per-file overlay
    acc.ruby_ctor = acc.ruby_ctor or {}
    for f, fb in pairs(chunk.ruby_ctor or {}) do
        if not seen[f] then acc.ruby_ctor[f] = fb end
    end
    -- ctorbinds / smtclasses: keyed BY FILE — per-file overlay, seen-guarded
    acc.ctorbinds = acc.ctorbinds or {}
    for f, fb in pairs(chunk.ctorbinds or {}) do
        if not seen[f] then acc.ctorbinds[f] = fb end
    end
    -- fieldalias (CART-0237): `local f = mod.field` per (file, local) — per-file overlay
    acc.fieldalias = acc.fieldalias or {}
    for f, fb in pairs(chunk.fieldalias or {}) do
        if not seen[f] then acc.fieldalias[f] = fb end
    end
    acc.smtclasses = acc.smtclasses or {}
    for f, fs in pairs(chunk.smtclasses or {}) do
        if not seen[f] then acc.smtclasses[f] = fs end
    end
    -- std-alias name→path maps (zig): keyed BY FILE — the parent's relink reads
    -- them so the std-alias disposition + node-minting run globally, matching
    -- inline ([[cartograph-stdlib-profile]] resolution face)
    acc.stdaliases = acc.stdaliases or {}
    for f, m in pairs(chunk.stdaliases or {}) do
        if not seen[f] then acc.stdaliases[f] = m end
    end
    local new = {}
    for f, v in pairs(chunk.stamps or {}) do
        if not seen[f] then acc.stamps[f] = v end
        new[f] = true
    end
    for f, r in pairs(chunk.fn_ranges or {}) do
        if not seen[f] then acc.fn_ranges[f] = r end
        new[f] = true
    end
    -- mention buffers (fusion Stage B): phase 2 reduces these in-parent
    -- instead of spawning re-parse workers
    for f, b in pairs(chunk.mentions or {}) do
        if not seen[f] then acc.mentions[f] = b end
        new[f] = true
    end
    for _, l in ipairs(chunk.no_parser or {}) do acc._no_parser[l] = true end
    for f in pairs(new) do seen[f] = true end
end

--- Null every cross-file hypothesis a batch made: the resolution that
--- justified it saw only the batch's names. Same-file links stay; relink
--- re-derives the rest against the global node set. Pure; exposed for
--- the equivalence test.
function M.audit(data)
    local kill, dropped = {}, 0
    -- the global dispatch core (mirrors the resolvers' cbarg pre-scan):
    -- a worker's SAME-FILE priority hit assumed its target was not
    -- dispatched, but dispatch testimony (a module-level arg naming the
    -- fn) can live in ANOTHER slice — recompute over the merged graph
    -- and reopen resolutions into marked targets (the parity gate caught
    -- the tier flip). Over-reopening is safe: relink re-derives.
    local fname = {}
    for _, n in ipairs(data.nodes or {}) do
        -- mirror the resolvers' candidate criterion (exact[]/lookups):
        -- torn defs and prototype declarations never index, so they must
        -- not break uniqueness here either — a C header's `log` prototype
        -- must not hide the dispatch mark on the one real `log` (v8 parity)
        if (n.kind == 'function' or n.kind == 'method')
            and not n.torn and not n.decl then
            fname[n.name] = fname[n.name] == nil and n or false
        end
    end
    -- CALL ACCESS is representation-neutral (callview): INDEX-FORM over the
    -- columnar store when the parent holds one (data._callstore, the record-fold
    -- peak path — no record tables, no proxies), else raw records (the default).
    -- The body below is written once against these accessors; rescols' immutable-
    -- assert guards a write to a parse-fixed field. [[cartograph-record-fold-arc]]
    local cv = require('cartograph.callview').of(data)
    local cn, cget, cset, argn, aget, aset = cv.n, cv.get, cv.set, cv.argn, cv.aget, cv.aset
    local dispatched = {}
    for i = 1, cn do
        if not cget(i, 'fn') then
            for j = 1, argn(i) do
                local ak, an = aget(i, j, 'k'), aget(i, j, 'name')
                if (ak == 'local' or aget(i, j, 'up')) and an then
                    local u = fname[an]
                    if u then dispatched[u.id] = true end
                end
            end
        end
    end
    for i = 1, cn do
        -- ANY resolution that leaned on uniqueness (name-match inferred,
        -- indirect literal, traced literal) is a batch-scoped hypothesis —
        -- even a SAME-FILE one, because the tail fallback and the
        -- unique-candidate branch count candidates globally. Null them
        -- all; relink re-derives with global indexes. The only survivors
        -- are same-file PRIORITY hits (plain calls, inferred=false) into
        -- UNDISPATCHED targets: those decisions never looked past their
        -- own file.
        local cto = cget(i, 'to')
        if cto and (cget(i, 'inferred') or cget(i, 'indirect')
            or type(cget(i, 'traced')) == 'string' or dispatched[cto]) then
            local cfn = cget(i, 'fn')
            if cfn then kill[cfn .. '\31' .. cto] = true end
            cset(i, 'to', nil)
            cset(i, 'inferred', nil)
            -- c.rt STAYS (file-scoped chain provenance the relink rounds
            -- re-derive from) — but the ROUNDS' side-writes do not: a kept
            -- tinf is a stale tier verdict, and a kept rounds-synthesized
            -- full (rtfull) changes relink's question from the bare
            -- stdlib-gated callee to a qualified name — the generic pass
            -- then minted same-file/unique edges inline never had, varying
            -- with slice boundaries (the par gate's nondeterminism)
            cset(i, 'tinf', nil)
            if cget(i, 'rtfull') then cset(i, 'full', nil); cset(i, 'rtfull', nil) end
            dropped = dropped + 1
        end
        for j = 1, argn(i) do
            if aget(i, j, 'up') then -- a resolution-pass upgrade: relink re-derives
                -- it, and the edge the upgrade added dies with it
                local cfn, ato = cget(i, 'fn'), aget(i, j, 'to')
                if cfn and ato then kill[cfn .. '\31' .. ato] = true end
                aset(i, j, 'k', 'local'); aset(i, j, 'to', nil); aset(i, j, 'up', nil)
            end
        end
    end
    -- a killed (from, to) pair may also carry occurrences of NON-audited
    -- calls (a plain call to the same target): reopen those too, so
    -- relink rebuilds the pair's edge with every occurrence
    for i = 1, cn do
        local cto, cfn = cget(i, 'to'), cget(i, 'fn')
        if cto and cfn and kill[cfn .. '\31' .. cto] then cset(i, 'to', nil) end
    end
    local edges = {}
    for _, e in ipairs(data.edges) do
        -- 'reg' edges present at audit are phase-1 argv-upgrade
        -- hypotheses (load-time callback passed as data): slice-local,
        -- so drop them — relink re-derives against the global set, and
        -- the id-pass (phase 2) mints the data-reference registrations
        if e.kind == 'reg' then
            -- dropped
        elseif not (e.kind == 'ref' and kill[e.from .. '\31' .. e.to]) then
            edges[#edges + 1] = e
        end
    end
    data.edges = edges
    return dropped
end

--- The user descended into a file still in the queue: extract it NOW,
--- in-process, and merge. Its queued copy dedups on arrival. Returns
--- true if this call did the work.
function M.demand(file)
    local s = M._session
    if not (s and s.phase == 1) or s.arrived[file] then return false end
    local ts = require 'cartograph.providers.treesitter'
    -- h_lang EXPLICITLY (CART-0410): `files` here is ONE file, and what `.h` means is a
    -- property of the whole tree. s.fileset would answer correctly today, but only
    -- because it happens to be the parent's full list — stating it is what keeps a
    -- future narrowing of fileset from silently re-deciding the language.
    local chunk = ts.extract(s.root,
        { files = { file }, fileset = s.fileset, skip_idpass = true,
            abs = s.abs, packs = s.packs, profile = s.profile,
            h_lang = s.h_lang, transport = s.transport })
    merge_chunk(s, chunk)
    s.arrived[file] = true -- even if unreadable: don't retry per descend
    if s.on_chunk then s.on_chunk(s.done, s.total, s.acc) end
    return true
end

--- Parallel extract. o = { workers?, on_chunk(done, total, acc)?,
--- on_note(msg)?, on_done(data) }. Asynchronous: returns immediately,
--- on_done fires on the main loop with the finished graph.
function M.extract(root, o)
    local ts = require 'cartograph.providers.treesitter'
    -- WHERE BYTES COME FROM. Two forms are needed because workers are separate
    -- processes: `tstack` is live (in-parent walks/extracts) and `tspec` is the
    -- DECLARATIVE half that survives vim.json.encode into a jobfile, which the
    -- worker rebuilds. Threaded exactly like o.packs.
    local tstack = o.transport
    if tstack and not tstack.read then
        tstack = require('cartograph.transport').build(tstack)
    end
    local tspec = tstack and tstack.spec or nil
    -- a multi-root corpus (self://loaded) supplies its OWN roster + a
    -- label→dir map; `abs` resolves the labelled keys. A plain directory
    -- root walks itself as before.
    local files, minified, abs
    if o.roots then
        files, minified = o.files, {}
        local roots = o.roots
        abs = function (file)
            local label, rest = file:match('^([^/]+)/(.*)$')
            local base = roots[label]
            if base == nil then return '/' .. (rest or file) end
            return require('cartograph.transport').join(base, rest or file)
        end
    else
        root = vim.fn.fnamemodify(vim.fn.expand(root), ':p'):gsub('/+$', '')
        files, minified = ts.list_files(root, nil, tstack)
    end
    -- S2 ([[cartograph-repo-shapes]]): default packs from the project shape ONCE
    -- here (not per worker) when none were given — every worker + the parent relink
    -- then shares one explicit list, no divergence. Explicit o.packs (incl. {})
    -- DISPOSES. A multi-root (self://) corpus has no single shape root → skip.
    if o.packs == nil and not o.roots then
        o.packs = require('cartograph.shapes').packs_for(root)
    end
    -- ★ DECIDED ONCE IN THE PARENT, FROM THE FULL LIST (CART-0410), for the same
    -- reason packs and profile are: a worker sees a BATCH, and a batch of headers
    -- contains no C++ source, so a worker deriving this itself would answer C for a
    -- C++ repo and produce a chunk parsed against a different grammar than its
    -- siblings. Rides to every worker as one explicit value.
    o.h_lang = o.h_lang or ts.h_lang_for(files)
    -- ★ AND THE PARENT MUST ADOPT IT TOO, not merely ship it. In the parallel path the
    -- parent never calls ts.extract — workers do — so its own H_LANG stayed at the
    -- default while the chunks came back parsed as C++. RELINK RUNS HERE, and its
    -- never-cross-language gate asks elang_for(file) per node: headers answered `c`
    -- against `cpp` definitions, and the families did not match. MEASURED on 7kaa
    -- before this line existed: nodes agreed with inline exactly (9024 == 9024, so the
    -- threading was working) while refs came out 8073 against inline's 9229. A
    -- divergence that shows up ONLY in refs is a resolution-side reader that was never
    -- told, and node equality is what makes it look fine.
    ts.set_h_lang(o.h_lang)

    local nw = math.min(o.workers or M.default_workers(),
        math.max(1, math.ceil(#files / M.BATCH)))
    if nw < 2 then
        o.on_done(ts.extract(root, { files = files, abs = abs, packs = o.packs,
            profile = o.profile, h_lang = o.h_lang, transport = tstack }))
        return
    end
    local rtp = worker_rtp()

    -- the queue: priority-ordered files, handed out in ADAPTIVELY-sized slices
    -- (see next_slice/adapt below) — no pre-slicing, so the size can react to
    -- measured worker turnaround.
    local ordered = M.order(files, attention(root, abs))

    local acc = { schema = 1, root = root, provider = o.provider or 'treesitter',
        roots = o.roots, packs = o.packs, -- so the parent's relink applies them
        -- the profile OVERRIDE rides to every worker exactly like packs (CART-0217):
        -- one explicit value decided in the parent, so no worker re-derives it and
        -- none can disagree about which environment it is resolving against
        profile = o.profile,
        h_lang = o.h_lang, -- the merged graph carries it, as the inline build does
        capabilities = { calls = true, litdata = true, df = 'lite' },
        nodes = {}, edges = {}, calls = {}, stamps = {}, fn_ranges = {},
        mentions = {}, _no_parser = {} }
    local s = { root = root, fileset = files, acc = acc, arrived = {}, abs = abs,
        on_chunk = o.on_chunk, done = 0, total = #ordered, phase = 1,
        packs = o.packs, profile = o.profile, h_lang = o.h_lang,
        transport = tstack, wmetrics = {} }
    M._session = s

    -- record-fold PEAK arc, step 2-live (gated CARTOGRAPH_MERGECOLS): fold each
    -- worker chunk's calls into the columnar rescols store as it arrives + drop
    -- the chunk's records, so the parent never holds the full call-record array at
    -- the merge peak. finalize() reorders to the fileset (canonical) order —
    -- exactly what canonicalize() does for the record path. Batch/headless path
    -- only (progressive fast-paint reads records, so it's disabled here); the
    -- record consumers downstream (ingest / gate) materialize the store back.
    do
        local okcfg, cfg = pcall(require, 'cartograph.config')
        if okcfg and cfg.merge_callstore then
            local fidx = {}
            for i, f in ipairs(files) do fidx[f] = i end
            s.callacc = require('cartograph.rescols').accumulator({ fileorder = fidx })
        end
        -- worker fold-emit: workers fold their own df/flow + ship the store once (the parent
        -- collects, multi-store). Threaded into each parse job below. finish_phase1's
        -- df/flow.fold then folds only the RAW stragglers (fallback/demand), leaving
        -- worker-folded nodes on their per-chunk stores (the M.fold guard tweak).
        s.foldstore = okcfg and cfg.merge_worker_fold or nil
    end

    -- responsiveness telemetry: every synchronous main-loop block during the
    -- streaming open (a chunk merge, a progressive re-ingest) is recorded, so
    -- smoothness is a NUMBER (P90/P95/P99), not a vibe. Reported at completion
    -- when setup{ profile = true }; always stashed on acc._stalls for tools.
    local okc0, cfg0 = pcall(require, 'cartograph.config')
    local profiling = okc0 and cfg0.profile == true
    local stalls = {}

    -- Adaptive coalescing of the streaming re-ingest. Worker chunks merge
    -- cheaply as they arrive (an append); the PROGRESSIVE re-ingest is the
    -- main-loop cost — O(nodes), 100ms+ on a big graph — so instead of running
    -- it on every batch it fires on a timer whose interval tracks its OWN last
    -- measured duration: re-ingest is held to ~a quarter of wall-clock, so the
    -- editor stays responsive. Early (few nodes, cheap) → frequent, smooth
    -- streaming; late (many nodes, dear) → the interval auto-widens. A demand
    -- extract (user descended a queued file) still refreshes immediately.
    local COAL_MIN, COAL_MAX, COAL_FRAC = 40, 500, 0.25
    -- yield to the user: hold the re-ingest for QUIET_MS after any keystroke so
    -- their input stays instant, but never starve the stream past MAX_HOLD
    local QUIET_MS, MAX_HOLD = 80, 1200
    local ingest_ms, pending, dirty = 0, false, false
    local last_input, hold_start = 0, nil
    -- a keystroke is HUMAN input — vim.on_key fires for typed/fed keys, not for
    -- our own programmatic buffer edits — so it's a clean "user is busy" signal
    if o.on_chunk then
        local okk, id = pcall(vim.on_key, function () last_input = vim.uv.hrtime() end)
        s.keywatch = okk and id or nil
    end
    local schedule_progressive
    local function run_progressive()
        -- step 2-live: the accumulator can't be read mid-stream (finalize-once), so
        -- the progressive fast-paint is off under CARTOGRAPH_MERGECOLS (batch path)
        if s.phase ~= 1 or not dirty or not o.on_chunk or s.callacc then return end
        dirty = false
        local t0 = vim.uv.hrtime()
        o.on_chunk(s.done, s.total, acc)
        ingest_ms = (vim.uv.hrtime() - t0) / 1e6
        stalls[#stalls + 1] = ingest_ms
    end
    function schedule_progressive(quick)
        if pending or not o.on_chunk then return end
        pending = true
        local interval = quick and QUIET_MS
            or math.max(COAL_MIN, math.min(COAL_MAX, ingest_ms / COAL_FRAC))
        vim.defer_fn(function ()
            pending = false
            local since_key = (vim.uv.hrtime() - last_input) / 1e6
            local held = hold_start and ((vim.uv.hrtime() - hold_start) / 1e6) or 0
            -- a key landed within QUIET_MS and we haven't held too long: defer
            -- the (main-loop-blocking) re-ingest, re-check soon (quick)
            local holding = dirty and since_key < QUIET_MS and held < MAX_HOLD
            if holding then
                hold_start = hold_start or vim.uv.hrtime()
            else
                hold_start = nil
                run_progressive()
            end
            if dirty then schedule_progressive(holding) end
        end, math.floor(interval))
    end
    s.schedule = schedule_progressive

    local function finalize()
        local okc, cfg = pcall(require, 'cartograph.config')
        if #minified > 0 and not (okc and cfg.unparsed == false) then
            acc.unparsed = minified
            for _, f in ipairs(minified) do
                acc.nodes[#acc.nodes + 1] = { id = f, name = f, kind = 'module',
                    file = f, unparsed = true, order = -1,
                    range = { start = { line = 0, char = 0 },
                        ['end'] = { line = 0, char = 0 } } }
            end
        end
        acc.no_parser = next(acc._no_parser) and vim.tbl_keys(acc._no_parser) or nil
        acc._no_parser = nil
        acc.fn_ranges = nil
        acc.mentions = nil
        if s.keywatch then pcall(vim.on_key, nil, s.keywatch) end -- stop listening
        M._last_stalls = M.summarize(stalls) -- on the module, not acc (cache)
        -- worker footprint envelope: peak RSS (per-process high-water),
        -- in-process work time, and spawn overhead (parent dt - worker wall)
        -- — the numbers that size a worker onto a small remote box
        do
            local hwm, wall, spawnov = {}, {}, {}
            for _, m in ipairs(s.wmetrics) do
                if m.hwm_kb then hwm[#hwm + 1] = m.hwm_kb / 1024 end
                if m.wall_ms then
                    wall[#wall + 1] = m.wall_ms
                    if m.dt_ms then spawnov[#spawnov + 1] = m.dt_ms - m.wall_ms end
                end
            end
            M._last_workers = { n = #s.wmetrics, hwm_mb = M.summarize(hwm),
                wall_ms = M.summarize(wall), spawn_ms = M.summarize(spawnov) }
        end
        if profiling and M._last_workers.n > 0 then
            local w = M._last_workers
            vim.notify(('cartograph: workers — n=%d peak MB p50=%.0f max=%.0f'
                .. ' · work ms p50=%.0f · spawn overhead ms p50=%.0f')
                :format(w.n, w.hwm_mb.p50 or 0, w.hwm_mb.max or 0,
                    w.wall_ms.p50 or 0, w.spawn_ms.p50 or 0), vim.log.levels.INFO)
        end
        if profiling and M._last_stalls.n > 0 then
            local p = M._last_stalls
            vim.notify(('cartograph: streaming stalls (ms) — n=%d p50=%.0f'
                .. ' p90=%.0f p95=%.0f p99=%.0f max=%.0f')
                :format(p.n, p.p50, p.p90, p.p95, p.p99, p.max), vim.log.levels.INFO)
        end
        M._session = nil
        o.on_done(acc)
    end

    local function phase2()
        -- fusion Stage B: phase-1 workers shipped packed mention buffers
        -- with their chunks, so the id pass is a pure REDUCE against the
        -- parent-built global lookups — no re-parse worker fleet.
        s.phase = 2
        local L = ts.lookups(acc.nodes, root)
        L.fn_ranges = acc.fn_ranges
        ts.merge_idpass(acc, ts.mention_reduce(files, acc.mentions, L))
        finalize()
    end

    -- Chunks merge in ARRIVAL order (worker completion is racy), so before
    -- any global pass runs, restore the CANONICAL order: the fileset list —
    -- the same order the inline extract walks. Within a file items keep
    -- their extraction order (a file lives in one chunk, contiguously), so
    -- the sorted arrays match inline's. Without this, relink's input order
    -- varies run to run and any order-sensitive choice inside resolution
    -- flips with it — three pristine gate runs produced two different edge
    -- sets before this existed (the matrix's par column caught it).
    local function canonicalize()
        local fidx = {}
        for i, f in ipairs(files) do fidx[f] = i end
        local function reorder(list, fileof)
            local dec = {}
            for i, v in ipairs(list) do
                dec[i] = { fidx[fileof(v)] or math.huge, i, v }
            end
            table.sort(dec, function (a, b)
                if a[1] ~= b[1] then return a[1] < b[1] end
                return a[2] < b[2] -- stable: preserve within-file order
            end)
            for i, d in ipairs(dec) do list[i] = d[3] end
        end
        reorder(acc.nodes, function (n) return n.file end)
        reorder(acc.edges, function (e) return file_of(e.from) end)
        -- step 2-live: the columnar accumulator reorders to the fileset order at
        -- finalize (finish_phase1), so acc.calls isn't the source of truth here
        if not s.callacc then reorder(acc.calls, function (c) return c.file end) end
        reorder(acc.extends or {}, function (x) return x.file end)
        reorder(acc.implements or {}, function (x) return x.file end)
        reorder(acc.fieldtypes or {}, function (x) return x.file end)
    end

    local failed = {}
    local function finish_phase1()
        for _, fb in ipairs(failed) do -- sequential fallback, honest
            merge_chunk(s, ts.extract(root, { files = fb,
                fileset = files, skip_idpass = true, abs = abs, packs = o.packs,
                profile = o.profile, h_lang = o.h_lang,
                transport = tstack }))
        end
        canonicalize()
        -- step 2-live: finalize the columnar store (fileset-ordered) → audit +
        -- relink run INDEX-FORM over it (1b), never materializing the records
        if s.callacc then acc._callstore = s.callacc.finalize() end
        M.audit(acc)
        ts.relink(acc)
        phase2()
        -- ★ phase2 mints the data-reference registrations LAST, so the reg
        -- collapse (CART-0627) is owed here rather than inside relink: two passes
        -- register the same pair at two anchors, and until this ran the parallel
        -- graph carried both while the inline one carried one — six red `par`
        -- cells (CART-0623).
        ts.dedupe_reg(acc.edges)
        -- fat-record migration P3: workers send FAT df/flow (per-chunk cols can't merge);
        -- the PARENT folds the merged graph so the returned acc is off fat records (matching
        -- inline extract's fold-at-production). Serializable folded cols (P3a); idempotent at ingest.
        require('cartograph.df').fold(acc)
        require('cartograph.flow').fold(acc)
        acc._ipc_bytes = s.ipc_bytes or 0 -- total worker→parent wire volume (telemetry)
    end
    -- parse cost ≈ file size; one cheap stat pass so slices can be shaped by
    -- WORK, not count (sizes span thousands-fold across a loaded session)
    local size = {}
    for _, f in ipairs(ordered) do
        local st = vim.uv.fs_stat(abs and abs(f) or (root .. '/' .. f))
        size[f] = st and st.size or 0
    end
    -- Adaptive slice size: start with a SMALL byte budget so the first worker
    -- returns quickly (fast first paint), grow it toward a turnaround sweet
    -- spot to amortize the ~150ms per-process startup, and cap the COUNT at an
    -- even share of what's left so no lane idles while another chews the tail.
    local cursor, inflight, budget = 1, 0, M.MIN_BYTES
    local function next_slice()
        if cursor > #ordered then return nil end
        local remaining = #ordered - cursor + 1
        local cap = math.min(M.COUNT_CAP, math.max(1, math.ceil(remaining / nw)))
        local b, nxt = M.slice(ordered, size, cursor, budget, cap)
        cursor = nxt
        return b
    end
    local function adapt(dt_ms)
        -- keep worker turnaround in a responsive throughput window: too fast =>
        -- startup dominated the slice, grow the budget; too slow => shrink
        if dt_ms < 250 then budget = math.min(M.MAX_BYTES, budget * 2)
        elseif dt_ms > 600 then budget = math.max(M.MIN_BYTES, math.floor(budget / 2)) end
    end
    -- work-pulling: each lane takes the next adaptive slice when it finishes
    -- (priority order preserved; demand dedups on arrival)
    local function pull()
        local b = next_slice()
        if not b then return false end
        inflight = inflight + 1
        local t0 = vim.uv.hrtime()
        spawn({ phase = 'parse', root = root, files = b,
            fileset = files, rtp = rtp, roots = o.roots, packs = o.packs,
            profile = o.profile,
            h_lang = o.h_lang, -- the parent's whole-tree answer (CART-0410)
            transport = tspec, -- the serialisable half; the worker rebuilds it
            foldstore = s.foldstore }, -- worker folds df/flow + ships the store once
            function (chunk, res)
            local cb0 = vim.uv.hrtime()
            inflight = inflight - 1
            if chunk then
                take_metrics(s, chunk, (cb0 - t0) / 1e6)
                merge_chunk(s, chunk)
            else
                failed[#failed + 1] = b
                if o.on_note then
                    o.on_note(('batch failed (exit %d) — re-extracting %d '
                        .. 'files in-process'):format(res.code, #b))
                end
            end
            s.done = s.done + #b
            adapt((vim.uv.hrtime() - t0) / 1e6)
            dirty = true
            schedule_progressive() -- coalesced; not a re-ingest per batch
            stalls[#stalls + 1] = (vim.uv.hrtime() - cb0) / 1e6 -- this block's cost
            -- keep this lane busy; phase 1 ends when the queue is drained
            -- and nothing is still in flight
            if not pull() and cursor > #ordered and inflight == 0 then
                finish_phase1()
            end
        end)
        return true
    end
    -- let the caller repoint at `acc` for incremental streaming (ingest_step)
    -- before the first chunk lands
    if o.on_start then o.on_start(acc) end
    for _ = 1, nw do if not pull() then break end end
end

return M
