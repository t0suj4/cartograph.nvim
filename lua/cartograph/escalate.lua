-- Escalation-on-hedge — the eager-audit TRIGGER for expensive analysis
-- ([[cartograph-interactive-analysis]]). After the cheap resolvers reach a
-- fixpoint, a HEDGE-SATURATED function (every resolved call edge is `~`, none
-- proven) is the signal that spending the expensive tier will pay off. Escalate
-- its hedges to the lua-ls oracle and RECONCILE the answers:
--   confirmed  ~B → proven B          the oracle agreed — the hedge is promoted
--   conflict   ~B → C   (C ≠ B)       a real bug on ONE side — THE product
--   refuted    ~B → nil               oracle: no such target — our guess wrong
--   recovered  refused → resolved     oracle got what static refused (a win)
--   stale      unchanged ~            oracle silent → mark, don't re-fire
--
-- The oracle run (providers/luals.enrich) already maps answers→nodes and
-- applies the upgrade/refute IN PLACE, returning only counts. escalate
-- SNAPSHOTS the resolution before and DIFFS after, so the reconcile surfaces as
-- FINDINGS (the conflicts especially — the lua-ls-disagreement bug product,
-- [[cartograph-goal-vm-linker]]) instead of a silent overwrite. The hedge set
-- is the work-list; per-function saturation is the priority lens.

local atr = require 'cartograph.at'
local callrec = require 'cartograph.callrec'
local M = {}

-- ANTI-THRASH CACHE (generation-keyed). c.escalated marks a hedge the oracle
-- left untouched so it never re-fires — but it lives on the call OBJECT, which
-- a re-ingest rebuilds (losing the mark) even when the graph GENERATION is
-- unchanged (store.ingest_incremental does not bump it). So the marks are also
-- kept here keyed by a stable call key; a run at the same generation re-seeds
-- them, a generation bump (a real edit — content changed, worth retrying)
-- resets the set. Pure escalation over a bare `data` (no generation) skips the
-- cache entirely and relies on the live c.escalated field alone.
local cache = { gen = nil, keys = {} }

-- a stable identity for a call across re-ingests: site + name.
local function keyof(c)
    return (c.file or '?') .. '\31' .. tostring(c.line) .. '\31'
        .. (c.callee or c.full or '?')
end

-- hedge-saturated functions: ≥1 outgoing call, ZERO proven, ≥1 hedge (`~`).
-- Returns sat = { [fn_id] = {p,h,rf} } (the trigger set) and the full per-fn
-- table (for reporting the other regimes).
function M.saturated(data)
    local per = {}
    for _, c in ipairs(data.calls or {}) do
        if c.fn then
            local r = per[c.fn]
            if not r then r = { p = 0, h = 0, rf = 0 }; per[c.fn] = r end
            if c.to then
                if c.inferred or c.tinf then r.h = r.h + 1 else r.p = r.p + 1 end
            else
                r.rf = r.rf + 1
            end
        end
    end
    local sat = {}
    for fn, r in pairs(per) do
        if r.p == 0 and r.h > 0 then sat[fn] = r end
    end
    return sat, per
end

-- the WORK-LIST: the escalation trigger made concrete. A candidate is a lua
-- hedge (`~`) or refusal that is NOT already escalated and NOT dynamic. When
-- `sat` is given (the default escalation regime) the list is DEMAND-SCOPED to
-- calls inside hedge-saturated functions — the oracle spends only where the
-- signal fired. Pass sat=nil to widen to the whole graph (general enrichment).
function M.worklist(data, sat)
    local work = {}
    for _, c in ipairs(data.calls or {}) do
        if callrec.file(c) and callrec.file(c):match('%.lua$') and not c.dynamic and not c.escalated
            and (not sat or (c.fn and sat[c.fn])) then
            if (c.to and c.inferred) or not c.to then
                work[#work + 1] = c
            end
        end
    end
    return work
end

-- snapshot the resolution of every work-list call, keyed by the call object
-- (which the oracle mutates in place, so the same object holds the post-state).
function M.snapshot(work)
    local snap = {}
    for _, c in ipairs(work) do
        snap[c] = { to = c.to, inferred = c.inferred }
    end
    return snap
end

-- diff the post-oracle graph against the pre-oracle snapshot → findings. The
-- snapshot's KEYS are the live call objects the oracle mutated in place, so
-- their current state IS the post-oracle graph — no separate data needed.
-- `sat` (optional) flags findings inside hedge-saturated fns as priority (★).
-- A hedge the oracle left untouched is marked `c.escalated` so it never
-- re-fires (anti-thrash: the policy drains monotonically to proven-or-refused).
function M.diff(snap, sat)
    sat = sat or {}
    local out = { confirmed = {}, conflict = {}, refuted = {}, recovered = {}, stale = 0 }
    for c, before in pairs(snap) do
        local pri = (c.fn and sat[c.fn]) and true or nil
        if before.to and before.inferred then          -- was a hedge (~B)
            if c.to == before.to and not c.inferred then
                out.confirmed[#out.confirmed + 1] = { c = c, to = c.to, pri = pri }
            elseif c.to and c.to ~= before.to then
                out.conflict[#out.conflict + 1] = { c = c, was = before.to, now = c.to, pri = pri }
            elseif not c.to then
                out.refuted[#out.refuted + 1] = { c = c, was = before.to, pri = pri }
            else                                         -- unchanged ~ : oracle silent
                c.escalated = true
                out.stale = out.stale + 1
            end
        elseif not before.to then                        -- was refused
            if c.to then
                out.recovered[#out.recovered + 1] = { c = c, to = c.to, pri = pri }
            end
        end
    end
    return out
end

-- seed c.escalated from the generation cache (so the anti-thrash mark survives
-- a re-ingest), compute the trigger set, build the work-list + snapshot.
-- opts.generation drives the cache; opts.all widens to the whole graph.
local function prepare(data, opts)
    local gen = opts.generation
    if gen ~= nil then
        if cache.gen ~= gen then cache = { gen = gen, keys = {} } end
        if next(cache.keys) then
            for _, c in ipairs(data.calls or {}) do
                if cache.keys[keyof(c)] then c.escalated = true end
            end
        end
    end
    local sat = opts.all and nil or M.saturated(data)
    local work = M.worklist(data, sat)
    return sat, work, M.snapshot(work)
end

-- diff after the oracle ran; persist newly-stale keys into the cache so a later
-- run at the same generation won't re-ask them.
local function commit(snap, sat, work, stats)
    local f = M.diff(snap, sat or {})
    f.stats = stats
    f.saturated = sat and vim.tbl_count(sat) or 0
    if cache.gen ~= nil then
        for _, c in ipairs(work) do
            if c.escalated then cache.keys[keyof(c)] = true end
        end
    end
    return f
end

-- shared oracle opts (the demand-scope + tuning knobs threaded to the provider)
local function oracle_opts(work, opts)
    return { bin = opts.bin, timeout = opts.timeout, load_wait = opts.load_wait,
        concurrency = opts.concurrency, init_timeout = opts.init_timeout,
        deadline = opts.deadline, calls = work }
end

-- run the full escalation SYNC: snapshot → run the lua-ls oracle over the
-- work-list (applies the reconcile in place) → diff. Returns findings (with
-- .stats, .saturated) or (nil, why). The oracle mutates `data` — the
-- confirmations upgrade the live graph, which is the point.
function M.run(data, opts)
    opts = opts or {}
    local sat, work, snap = prepare(data, opts)
    if #work == 0 then return nil, 'no hedge-saturated work-list to escalate' end
    local stats, why = require('cartograph.providers.luals')
        .enrich(data, oracle_opts(work, opts))
    if not stats then return nil, why end
    return commit(snap, sat, work, stats)
end

-- run the escalation ASYNC (non-blocking): same reconcile, but lua-ls's
-- workspace load never freezes the editor. Calls on_done(findings|nil, why?)
-- on the main loop; its job is to render + redraw the upgraded graph.
function M.run_async(data, opts, on_done)
    opts = opts or {}
    local sat, work, snap = prepare(data, opts)
    if #work == 0 then
        if on_done then on_done(nil, 'no hedge-saturated work-list to escalate') end
        return
    end
    require('cartograph.providers.luals').enrich_async(data, oracle_opts(work, opts),
        function (stats, why)
            if not stats then
                if on_done then on_done(nil, why) end
                return
            end
            if on_done then on_done(commit(snap, sat, work, stats)) end
        end)
end

-- render findings as report lines. `name(id)` maps a node id → display name.
function M.report(f, name)
    name = name or function (id) return tostring(id) end
    local function site(c)
        return ('%s:%d %s'):format((c.file or '?'):match('[^/]+$') or '?',
            (c.line or 0) + 1, c.callee or c.full or '?')
    end
    local L = {
        ('escalation: %d confirmed · %d recovered · %d refuted · %d CONFLICT'
            .. '  (%d hedge-saturated fns · %d stale)')
            :format(#f.confirmed, #f.recovered, #f.refuted, #f.conflict,
                f.saturated or 0, f.stale),
    }
    if f.stats then
        L[#L + 1] = ('  oracle: asked %d, answered %d, upgraded %d, cleared %d')
            :format(f.stats.asked or 0, f.stats.answered or 0,
                f.stats.upgraded or 0, f.stats.cleared or 0)
    end
    local function block(items, title, fmt)
        if #items == 0 then return end
        table.sort(items, function (a, b) return site(a.c) < site(b.c) end)
        L[#L + 1] = ''
        L[#L + 1] = title:format(#items)
        for _, x in ipairs(items) do L[#L + 1] = fmt(x) end
    end
    block(f.conflict, 'CONFLICTS (%d) — static vs lua-ls disagree; a bug on ONE side:',
        function (x) return ('  %s%s  static→%s  luals→%s')
            :format(x.pri and '★ ' or '  ', site(x.c), name(x.was), name(x.now)) end)
    block(f.refuted, 'REFUTED (%d) — our name-match wrong; lua-ls found no such target:',
        function (x) return ('  %s%s  was→%s')
            :format(x.pri and '★ ' or '  ', site(x.c), name(x.was)) end)
    block(f.recovered, 'RECOVERED (%d) — lua-ls resolved what static refused:',
        function (x) return ('  %s%s  →%s')
            :format(x.pri and '★ ' or '  ', site(x.c), name(x.to)) end)
    return L
end

-- convert findings to the generic in-buffer diagnostic shape ([[diag]]). Only
-- the PROBLEM regimes surface as signs: a CONFLICT is an ERROR (a bug on one
-- side — the disagreement product), a REFUTED name-match is a WARN (our
-- resolver over-reached). Confirmed/recovered are wins, not signs. `abs`
-- absolutises a relative file; `name` maps a node id → display name.
function M.diagnostics(f, abs, name)
    abs = abs or function (x) return x end
    name = name or function (id) return tostring(id) end
    local out = {}
    local function col(c) return c.at and atr.sc(c.at) + 1 or 1 end
    for _, x in ipairs(f.conflict) do
        out[#out + 1] = { file = abs(x.c.file), line = (x.c.line or 0) + 1,
            col = col(x.c), severity = 'error', source = 'cartograph/escalate',
            message = ('escalation CONFLICT: static → %s, but lua-ls → %s'
                .. ' — a bug on ONE side'):format(name(x.was), name(x.now)) }
    end
    for _, x in ipairs(f.refuted) do
        out[#out + 1] = { file = abs(x.c.file), line = (x.c.line or 0) + 1,
            col = col(x.c), severity = 'warn', source = 'cartograph/escalate',
            message = ('escalation: name-match to %s refuted by lua-ls'
                .. ' (no such target) — resolver over-reach'):format(name(x.was)) }
    end
    return out
end

return M
