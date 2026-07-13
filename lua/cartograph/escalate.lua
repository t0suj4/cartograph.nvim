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

local M = {}

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

-- snapshot the resolution of every escalation CANDIDATE — a lua hedge (`~`) or
-- a refusal, not already escalated — keyed by the call object (which the oracle
-- mutates in place, so the same object holds the post-state).
function M.snapshot(data)
    local snap = {}
    for _, c in ipairs(data.calls or {}) do
        if c.file and c.file:match('%.lua$') and not c.dynamic and not c.escalated then
            if (c.to and c.inferred) or not c.to then
                snap[c] = { to = c.to, inferred = c.inferred }
            end
        end
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

-- run the full escalation SYNC: snapshot → run the lua-ls oracle (targets the
-- hedges/refusals, applies the reconcile in place) → diff. Returns findings
-- (with .stats, .saturated) or (nil, why). The oracle mutates `data` — the
-- confirmations upgrade the live graph, which is the point.
function M.run(data, opts)
    local sat = M.saturated(data)
    local snap = M.snapshot(data)
    local stats, why = require('cartograph.providers.luals').enrich(data, opts)
    if not stats then return nil, why end
    local f = M.diff(snap, sat)
    f.stats = stats
    f.saturated = vim.tbl_count(sat)
    return f
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

return M
