-- INVARIANTS THAT ATTACK THEMSELVES (CART-0285, user: "I think we could detect wrong invariants
-- that way").
--
-- THE DELIVERABLE IS THE REFUTATION, NOT THE SURVIVOR. The obvious tool proposes invariants from
-- observed runs and worries about the wrong ones; this one PROPOSES AND THEN ATTACKS ITS OWN
-- PROPOSALS, because an invariant is never verified — only UNFALSIFIED SO FAR. So the most
-- valuable rows it prints are the candidates it KILLED: those are the wrong invariants a
-- propose-only tool would have shipped as knowledge.
--
-- WHY THE ATTACK IS TARGETED RATHER THAN RANDOM, and this is the whole reason it works here: an
-- invariant inferred from runs that all took the SAME BRANCH is wrong exactly along the axis the
-- evidence never varied. The fork knows which axis that is (it enumerates the function's forkable
-- conditions), and the assertion inverter can CONSTRUCT an input that takes the other side. So the
-- counterexample is DERIVED from the function's own control flow — the invariant proposes, the
-- inverter attacks, the run decides, and none of the three steps guesses.
--
-- ── THE HONESTY THAT DECIDES WHETHER THIS IS USEFUL OR DANGEROUS ─────────────
-- A CANDIDATE IS A CLAIM WITH A SUPPORT COUNT, NEVER A FACT. "held over 5 runs" is not a property
-- of a function, and promoting it by repetition is the fabrication this whole arc exists to
-- prevent, one level up. Every row carries its support, its attacks, and its tier (`derived` — our
-- own analysis produced it).
--
-- AND AN INVARIANT THAT SURVIVED BECAUSE WE COULD NOT ATTACK IT IS NOT ONE THAT SURVIVED BECAUSE
-- NOTHING COULD REFUTE IT. Every survivor records WHY the attack stopped — no unexplored
-- condition, a predicate we cannot invert, the budget — because "unrefuted" will otherwise be read
-- as "true". A fence that gives up must say so.
--
-- Use headless ([[cartograph-apply-for-agent]]):
--   local inv = require 'cartograph.invariant'
--   local r, why = inv.survey(store, fn_id, { fills = {…} })
--   for _, l in ipairs(inv.report(r)) do print(l) end

local M = {}
local ch = require 'cartograph.characterize'
local ro = require 'cartograph.runoracle'

-- How many forkable conditions the attack will explore. Stated, not silent: the report says what
-- it did not try, because an unexplored axis is exactly where a wrong invariant hides.
M.ATTACK_CAP = 4

--- The literal TYPE of a recorded value, from its Lua source. `nil` means we cannot tell, which is
--- different from `'nil'` (the value nil) and must not collapse into it.
local function tyof(src)
    if src == nil then return nil end
    if src == 'nil' then return 'nil' end
    if src == 'true' or src == 'false' then return 'boolean' end
    if src:match('^%-?%d+$') or src:match('^%-?%d*%.%d+$') then return 'number' end
    if src:match('^".*"$') or src:match("^'.*'$") then return 'string' end
    if src:match('^{') then return 'table' end
    return nil
end

--- One RUN of a function under a given premise: (observation, nil) or (nil, why).
--- observation = { inputs = {positional source}, ret, retn, effects, premise }
function M.observe(store, fn_id, opts)
    local plan, why = ch.plan(store, fn_id)
    if not plan then return nil, why end
    if opts and opts.fills then
        local mine, have = {}, {}
        for _, h in ipairs(plan.holes) do have[h.id] = true end
        for id, f in pairs(opts.fills) do if have[id] then mine[id] = f end end
        if next(mine) then
            local n, ferr = ch.fill(plan, mine)
            if not n then return nil, ferr end
        end
    end
    local premise
    if opts and opts.assert_id then
        local n, aerr = ch.assert_condition(store, plan, opts.assert_id, opts.assert_want)
        if not n then return nil, aerr end
        local a = plan.asserted[#plan.asserted]
        premise = ('%s is %s'):format(a.text, tostring(a.want))
    end
    local okr, rerr = ro.fill_oracle(store, plan, opts)
    if not okr then return nil, rerr end
    local ret, eff
    for _, h in ipairs(plan.holes) do
        if h.kind == 'oracle' then ret = h end
        if h.kind == 'effects' then eff = h end
    end
    local inputs = {}
    local byname = {}
    for _, h in ipairs(plan.holes) do
        if h.kind == 'input' then byname[h.name] = h end
    end
    for i, p in ipairs(plan.params or {}) do
        local h = byname[p]
        inputs[i] = h and (h.raw_value or h.value) or nil
    end
    return { inputs = inputs, params = plan.params or {},
        ret = ret and ret.raw_value or nil, retn = ret and ret.n or nil,
        effects = eff and eff.value or nil, premise = premise or 'the base run' }
end

-- ── THE TEMPLATES: a CLOSED vocabulary, and its boundary is honest ──────────
-- A template library IS a vocabulary, so this finds properties nobody thought to check HERE — not
-- properties nobody has ever thought of. What finds THOSE is a disagreement between two
-- computations (see the module header of tools/answerkey and CART-0285's notes); this is the
-- weaker, enumerable half, and it says so.
--
-- Each template answers: does this hold over ALL observations, and what refutes it. `nil` from
-- `holds` means NO OPINION (we cannot read the values), which is neither support nor refutation —
-- the difference between "checked and true" and "could not check" is the row's whole value.
M.TEMPLATES = {
    {
        id = 'constant-return',
        describe = function (o) return ('always returns %s'):format(tostring(o.ret)) end,
        holds = function (o, first)
            if o.ret == nil or first.ret == nil then return nil end
            return o.ret == first.ret
        end,
    },
    {
        id = 'return-type',
        describe = function (o) return ('always returns a %s'):format(tostring(tyof(o.ret))) end,
        holds = function (o, first)
            local a, b = tyof(o.ret), tyof(first.ret)
            if not (a and b) then return nil end
            return a == b
        end,
    },
    {
        id = 'return-arity',
        describe = function (o) return ('always returns %d value(s)'):format(o.retn or 0) end,
        holds = function (o, first)
            if not (o.retn and first.retn) then return nil end
            return o.retn == first.retn
        end,
    },
    {
        id = 'never-nil',
        describe = function () return 'never returns nil' end,
        holds = function (o) if o.ret == nil then return nil end return o.ret ~= 'nil' end,
    },
    {
        id = 'passthrough',
        -- the return EQUALS one of the arguments, positionally — the identity shape, and the one
        -- most likely to be an accident of a single run
        describe = function (o, st)
            return ('returns argument %d (`%s`) unchanged'):format(st.i,
                tostring(o.params[st.i]))
        end,
        setup = function (first)
            for i, v in ipairs(first.inputs) do
                if v ~= nil and v == first.ret then return { i = i } end
            end
            return nil
        end,
        holds = function (o, first, st)
            local v = o.inputs[st.i]
            if v == nil or o.ret == nil then return nil end
            return v == o.ret
        end,
    },
    {
        id = 'no-effects',
        describe = function () return 'observed to perform no effects' end,
        holds = function (o)
            if o.effects == nil then return nil end
            return o.effects == '""' or o.effects == ''
        end,
    },
}

--- PROPOSE over a set of observations, then classify each candidate by what the LATER ones did to
--- it. Returns { survived = {…}, refuted = {…} } where a refuted row carries the counterexample —
--- and the refuted rows are the point of the exercise.
function M.judge(obs)
    local first = obs[1]
    local survived, refuted = {}, {}
    for _, t in ipairs(M.TEMPLATES) do
        -- `t.setup and t.setup(first) or {}` turned "this template DECLINED" into "it applies with
        -- empty state", because `or {}` cannot tell a nil RESULT from a missing FUNCTION — and the
        -- describe() that followed then formatted a nil index. Third `and`/`or` truthiness trap in
        -- this arc; the idiom is only safe when nil and false mean the same thing to the caller,
        -- and here they emphatically do not.
        local st = {}
        if t.setup then st = t.setup(first) end   -- nil = the template does not apply here
        if st then
            local support, verdict = 0, nil
            for i = 1, #obs do
                local h = t.holds(obs[i], first, st)
                if h == true then support = support + 1
                elseif h == false then
                    verdict = verdict or { at = i, obs = obs[i] }
                end
                -- h == nil: NO OPINION. Not support, not refutation.
            end
            local row = { id = t.id, text = t.describe(first, st), support = support,
                total = #obs }
            if verdict then
                row.counterexample = verdict.obs
                row.why = ('refuted under `%s`: returned %s'):format(
                    tostring(verdict.obs.premise), tostring(verdict.obs.ret))
                refuted[#refuted + 1] = row
            elseif support > 0 then
                survived[#survived + 1] = row
            end
        end
    end
    return { survived = survived, refuted = refuted }
end

--- THE WHOLE LOOP: run the base case, then ATTACK along every axis the base run did not vary —
--- each forkable condition, both ways — and judge the candidates against everything observed.
--- Returns (result, nil) or (nil, why).
function M.survey(store, fn_id, opts)
    opts = opts or {}
    local base, why = M.observe(store, fn_id, opts)
    if not base then return nil, why end
    local obs = { base }
    local node = store.node(fn_id)
    local conds = ch.conditions(store, node, store.content(node))
    local attacks, failed = {}, {}
    local cap = opts.cap or M.ATTACK_CAP
    for i = 1, math.min(cap, #conds) do
        local c = conds[i]
        for _, want in ipairs({ true, false }) do
            local o, awhy = M.observe(store, fn_id,
                { fills = opts.fills, assert_id = c.id, assert_want = want, force = opts.force })
            if o then
                obs[#obs + 1] = o
                attacks[#attacks + 1] = { id = c.id, want = want }
            else
                -- WHY THE ATTACK COULD NOT BE MADE, kept per axis: an invariant that survived
                -- because we could not attack it is not one nothing could refute.
                failed[#failed + 1] = { id = c.id, want = want,
                    why = tostring(awhy):gsub('\n.*', '') }
            end
        end
    end
    local res = M.judge(obs)
    res.fn, res.file = base and node.name, node.file
    res.observations, res.attacks, res.failed = obs, attacks, failed
    res.conditions, res.skipped = #conds, math.max(0, #conds - cap)
    return res
end

--- The survey as report ROWS — (lines, at). The refuted rows come FIRST, because they are the
--- finding: a wrong invariant caught is worth more than a right one restated.
function M.report(res)
    local L, A = {}, {}
    local function add(s, a) L[#L + 1] = s; A[#A + 1] = a end
    add(('invariants — %s (%s), %d run(s) over %d attack(s)'):format(tostring(res.fn),
        tostring(res.file), #res.observations, #res.attacks), { file = res.file })
    add('  candidates come from a CLOSED template vocabulary, so this finds what nobody thought to', nil)
    add('  check HERE — not what nobody has thought of. Each is a CLAIM with a support count.', nil)
    add('', nil)
    if #res.refuted > 0 then
        add(('  REFUTED (%d) — a wrong invariant caught, which is the point of attacking:')
            :format(#res.refuted), nil)
        for _, r in ipairs(res.refuted) do
            add(('    %-16s %s'):format(r.id, r.text), nil)
            add(('        %s'):format(r.why), nil)
        end
        add('', nil)
    end
    if #res.survived > 0 then
        add(('  UNREFUTED (%d) — held over every run we could make. NOT proven:'):format(
            #res.survived), nil)
        for _, r in ipairs(res.survived) do
            add(('    %-16s %-44s support %d/%d [derived]'):format(r.id, r.text, r.support,
                r.total), nil)
        end
        add('', nil)
    end
    -- WHY THE ATTACK STOPPED, always. Otherwise "unrefuted" reads as "true".
    add(('  ATTACK COVERAGE: %d condition(s) forkable, %d explored, %d not attempted')
        :format(res.conditions, #res.attacks, res.skipped), nil)
    if #res.failed > 0 then
        add(('  %d attack(s) COULD NOT BE MADE, and an invariant that survived because we could'):
            format(#res.failed), nil)
        add('  not attack it is not one that nothing could refute:', nil)
        local seen = {}
        for _, f in ipairs(res.failed) do
            local k = f.why
            if not seen[k] then
                seen[k] = true
                add(('    %s'):format(k), nil)
            end
        end
    end
    if res.conditions == 0 then
        add('  no forkable condition here, so nothing could be varied: every row above rests on', nil)
        add('  ONE input set, which is the weakest evidence this tool can produce.', nil)
    end
    return L, A
end

return M
