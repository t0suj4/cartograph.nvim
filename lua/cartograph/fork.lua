-- FORK A CHARACTERIZATION (CART-0283, user: "we could probably support a fork, then the user
-- could observe both states … like displaying side by side selected downstream code").
--
-- WHY FORKING BEATS CHOOSING. A condition on an unknown has no right answer to pick — it has
-- TWO BEHAVIOURS, and describing one is describing half. So do not resolve the undecidable:
-- REPRESENT THE SET, which is what [[cartograph-invocation-dependent-definition]] says for a
-- name defined divergently per invocation. A forked characterization is that idea for a VALUE,
-- and a user assertion is the profile that collapses it when they want it collapsed.
--
-- BOTH STATES ARE `claim` TIER — each rests on an asserted premise — and NEITHER may be
-- presented as "the behaviour". The DELIVERABLE IS THE DIFF between them: `f.size > 0` rendered
-- as "these lines run / these lines run" is the clearest possible statement of what that
-- condition DOES, and better than any prose we could write about it.
--
-- AND FORKING BUYS A LINT NOBODY ASKED FOR. If the two states are OBSERVATIONALLY IDENTICAL —
-- same return tuple, same effect log — the condition does not affect observable behaviour: a
-- guard that guards nothing. BEHAVIOURAL rather than structural, so it catches what
-- narrow.redundant cannot. Hedged, always: it says nothing about paths this fork did not
-- explore, and identical-under-THESE-inputs is not identical-in-general.
--
-- ── THE COMBINATORIAL EXPLOSION IS REAL BUT RARE, AND THAT IS MEASURED ───────
-- Forkable conditions per function (a guard hinging on a param or a param-derived value):
--
--                 0 forks   <=1      <=2      <=3      <=4     worst
--   self  3403     55.0%    73.3%    83.3%    88.8%    91.9%   M.extract 45  (3.5e13 states)
--   nio    217     83.4%    92.2%    96.3%    98.6%    99.1%   process.run 7
--   desyn 1900     58.2%    75.3%    83.1%    87.2%    90.5%   AddStats 89
--
-- OVER HALF OF ALL FUNCTIONS HAVE NOTHING TO FORK, and ~90% sit at four or fewer conditions —
-- 16 states, trivially enumerable. So for most of the corpus THE SMART THING IS TO BE DUMB:
-- enumerate to a stated bound, no heuristic and no search. The blow-up lives in ~10%, and for
-- those the answer is not a cleverer search — it is `scan`, below, plus BROWSING one axis at a
-- time ([[cartograph-navigation-model]]: nobody should ever be shown 2^45 of anything).
--
-- SO `scan` IS THE REDUCER, and it is linear where the product is exponential: fork each
-- condition INDEPENDENTLY (2n runs, not 2^n) and keep only the ones whose states differ. That
-- turns n into k = the behaviourally LIVE conditions, and it is the only reduction here that
-- MEASURES rather than assumes, because it runs the code. The lint and the reducer are the same
-- pass — a condition that changes nothing is both a finding and one fewer axis.
--
-- Use headless ([[cartograph-apply-for-agent]]):
--   local fork = require 'cartograph.fork'
--   local f, why = fork.at(store, fn_id, 'condition:L7', { fills = {…} })
--   for _, l in ipairs(fork.report(f)) do print(l) end
--   local s = fork.scan(store, fn_id, { fills = {…} })   -- which conditions MATTER

local M = {}
local ch = require 'cartograph.characterize'
local ro = require 'cartograph.runoracle'

-- How many conditions `scan` will fork before it stops, and it STOPS OUT LOUD. A silent cap
-- reads as "we explored everything", which is this codebase's recurring defect class.
M.SCAN_CAP = 8

--- One STATE of a fork: a fresh plan, the condition asserted to `want`, every base fill applied,
--- and the oracle observed by running. Returns (state, nil) or (nil, why).
--- A FRESH PLAN PER STATE, never a shared one: an assertion MUTATES a plan, so two states over
--- one plan would be one state overwritten twice.
local function state_of(store, fn_id, cond_id, want, opts)
    local plan, why = ch.plan(store, fn_id, opts and opts.plan_opts)
    if not plan then return nil, why end
    if opts and opts.fills then
        local n, ferr = ch.fill(plan, opts.fills)
        if not n then return nil, ferr end
    end
    local okA, aerr = ch.assert_condition(store, plan, cond_id, want)
    if not okA then return nil, aerr end
    local okR, rerr = ro.fill_oracle(store, plan, opts)
    if not okR then return nil, rerr end
    local a = plan.asserted[#plan.asserted]
    local ret, eff
    for _, h in ipairs(plan.holes) do
        if h.kind == 'oracle' then ret = h end
        if h.kind == 'effects' then eff = h end
    end
    return {
        want = want, premise = a.text, selects = a.selects,
        leaf = a.leaf, value = a.value,
        ret = ret and ret.raw_value or nil, retn = ret and ret.n or nil,
        effects = eff and eff.value or nil,
        plan = plan,
    }
end

--- FORK one condition: both states, and the verdict on whether it decides anything observable.
--- Returns (fork, nil) or (nil, why).
function M.at(store, fn_id, cond_id, opts)
    local t, twhy = state_of(store, fn_id, cond_id, true, opts)
    if not t then return nil, ('asserting %s TRUE: %s'):format(cond_id, tostring(twhy)) end
    local f, fwhy = state_of(store, fn_id, cond_id, false, opts)
    if not f then return nil, ('asserting %s FALSE: %s'):format(cond_id, tostring(fwhy)) end
    -- WHAT DIFFERS IS THE DELIVERABLE, so it is computed rather than left to a reader.
    local diff = {}
    if t.ret ~= f.ret or t.retn ~= f.retn then
        diff[#diff + 1] = ('returns %s vs %s'):format(tostring(t.ret), tostring(f.ret))
    end
    if (t.effects or '') ~= (f.effects or '') then
        diff[#diff + 1] = ('effects %s vs %s'):format(tostring(t.effects), tostring(f.effects))
    end
    return {
        condition = cond_id, fn = t.plan.fn, file = t.plan.file,
        states = { t, f }, differs = diff, live = #diff > 0,
    }
end

--- FORK EVERY CONDITION INDEPENDENTLY — the reducer and the lint in one pass. Returns
--- { live = {…}, inert = {…}, refused = {…}, scanned, total, skipped }. 2n runs, not 2^n.
function M.scan(store, fn_id, opts)
    local node = store.node(fn_id)
    if not node then return nil, 'no such function' end
    local conds = ch.conditions(store, node, store.content(node))
    local cap = (opts and opts.cap) or M.SCAN_CAP
    local out = { live = {}, inert = {}, refused = {}, total = #conds, scanned = 0,
        skipped = math.max(0, #conds - cap) }
    for i = 1, math.min(cap, #conds) do
        local c = conds[i]
        out.scanned = out.scanned + 1
        local f, why = M.at(store, fn_id, c.id, opts)
        if not f then
            out.refused[#out.refused + 1] = { id = c.id, text = c.text, why = why }
        elseif f.live then
            out.live[#out.live + 1] = f
        else
            out.inert[#out.inert + 1] = f
        end
    end
    return out
end

--- The fork as report ROWS — (lines, at). NOT a side-by-side pane: the fork is DATA, and a
--- two-column view is ONE RENDERING of it. There is no two-column primitive in this codebase
--- today, so building one must not gate the data ([[cartograph-apply-for-agent]]: headless verb
--- first, panes later). When a pane arrives it should label each column by its PREMISE (never
--- left/right — an unlabelled two-column view is a puzzle) and COLLAPSE the rows identical in
--- both, so what remains on screen is exactly what the condition decides.
function M.report(fork)
    local L, A = {}, {}
    local function add(s, a) L[#L + 1] = s; A[#A + 1] = a end
    add(('fork %s — %s (%s)'):format(fork.condition, fork.fn, fork.file),
        { file = fork.file })
    add(('  `%s`'):format(fork.states[1].premise or '?'), nil)
    add('', nil)
    for _, st in ipairs(fork.states) do
        add(('  ASSERTED %-5s  %s = %-10s %s'):format(tostring(st.want), st.leaf,
            st.value, st.selects), nil)
        add(('     returns  %s'):format(tostring(st.ret)), nil)
        if st.effects then add(('     effects  %s'):format(st.effects), nil) end
    end
    add('', nil)
    if fork.live then
        add(('  THIS CONDITION DECIDES: %s'):format(table.concat(fork.differs, '; ')), nil)
    else
        -- THE LINT, and it is hedged in the same breath: this is evidence, never a verdict.
        add('  OBSERVATIONALLY IDENTICAL — under these inputs the condition changes neither', nil)
        add('  the return nor the effects: a guard that guards nothing. HEDGED: it says nothing', nil)
        add('  about paths this fork did not explore, and identical-under-these-inputs is not', nil)
        add('  identical-in-general.', nil)
    end
    add('', nil)
    add('  both states are CLAIM tier — each rests on an asserted premise, and neither is'
        .. ' "the behaviour"', nil)
    return L, A
end

--- The scan as report rows: which conditions MATTER, which do not, and what was not scanned.
function M.scan_report(scan)
    local L, A = {}, {}
    local function add(s, a) L[#L + 1] = s; A[#A + 1] = a end
    add(('fork scan — %d forkable condition(s), %d scanned'):format(scan.total, scan.scanned),
        nil)
    add('  each condition forked INDEPENDENTLY (2n runs, not 2^n): the ones whose two states', nil)
    add('  differ observably are the only axes worth combining.', nil)
    add('', nil)
    add(('  LIVE (%d) — these decide something observable:'):format(#scan.live), nil)
    for _, f in ipairs(scan.live) do
        add(('    %-16s %s'):format(f.condition, table.concat(f.differs, '; ')),
            { file = f.file })
    end
    if #scan.inert > 0 then
        add('', nil)
        add(('  INERT (%d) — same return AND same effects either way, so they are not axes:')
            :format(#scan.inert), nil)
        for _, f in ipairs(scan.inert) do
            add(('    %-16s `%s`'):format(f.condition,
                tostring(f.states[1].premise)), { file = f.file })
        end
        add('    (hedged: under THESE inputs only — a guard that guards nothing here may', nil)
        add('     guard something under other inputs)', nil)
    end
    if #scan.refused > 0 then
        add('', nil)
        add(('  NOT FORKABLE (%d) — no value could be derived for the assertion:')
            :format(#scan.refused), nil)
        for _, r in ipairs(scan.refused) do
            add(('    %-16s %s'):format(r.id, (r.why or ''):gsub('\n.*', '')), nil)
        end
    end
    -- SAY WHAT WAS NOT SCANNED. A silent cap reads as "we explored everything".
    if scan.skipped > 0 then
        add('', nil)
        add(('  %d condition(s) NOT SCANNED (cap %d) — raise it with opts.cap, and note that'):
            format(scan.skipped, M.SCAN_CAP), nil)
        add('  the product of the live ones is what a full fork would enumerate.', nil)
    end
    -- AND THE REDUCTION, stated as a number: n -> k is the whole point of the pass.
    add('', nil)
    add(('  REDUCTION: %d condition(s) -> %d live axis/axes (%d states if combined, versus'
        .. ' %d for the unreduced product)'):format(scan.scanned, #scan.live,
        2 ^ #scan.live, 2 ^ scan.scanned), nil)
    return L, A
end

return M
