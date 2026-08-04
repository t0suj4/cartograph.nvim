-- THE BEFORE/AFTER CERTIFICATE (CART-0264, step 3 of the CART-0260 arc) — neutrality with
-- REAL ASSERTIONS instead of a proxy.
--
-- WHAT IT REPLACES, AND WHY THAT MATTERS. neutrality.lua certifies a refactor by hashing each
-- function's BEHAVIOUR WITNESS (df shape + param count + callee names) and diffing the hashes.
-- That is a genuine and useful check, and it is a PROXY: it proves a body was not TOUCHED, which
-- is why it certifies a MOVE and correctly drifts on an extract-helper (A legitimately becomes a
-- tail-call wrapper). It cannot say whether BEHAVIOUR survived a body that changed on purpose —
-- and that is the case you most want certified, because it is the refactor you are least sure of.
--
-- So: RUN the touched symbols before, RUN them after, and compare what they actually did. The
-- arc built the pieces for exactly this (characterize → assert → run), and the write axis was
-- always its first customer.
--
-- ── THE HONESTY THAT MAKES IT USEFUL RATHER THAN REASSURING ──────────────────
-- A HASH ALWAYS COMPUTES. A run does not: a symbol with an unfilled hole cannot be characterized,
-- so it CANNOT be certified by assertion. The certificate therefore has TWO TIERS and states the
-- split:
--     ASSERTED   the symbol was run before and after; its return and effect log agree. MEASURED.
--     WITNESSED  it could not be run, so only the witness hash covers it — the old proxy, kept
--                because it is better than nothing, and LABELLED because it is weaker.
--     CHANGED    it ran both times and DISAGREED. The finding.
-- A certificate that quietly reported "all neutral" while half its symbols were only hashed would
-- be worse than the proxy alone, since it would carry the proxy's coverage and imply the
-- assertion's strength.
--
-- KEYED BY NAME, NOT BY ID. An apply re-extracts, so function IDs change — and a MOVE changes the
-- file too. `check` re-resolves each symbol by name in the new graph, re-plans it, and replays the
-- RECORDED INPUTS rather than re-running the old spec text (whose dofile path may no longer hold
-- the symbol at all).
--
-- Use headless ([[cartograph-apply-for-agent]]):
--   local cert = require 'cartograph.certificate'
--   local c = cert.take(store, { ids = {…}, fills = {…} })   -- BEFORE the apply
--   … stage and :CartographApply …
--   local r = cert.check(store, c)                            -- AFTER
--   for _, l in ipairs(cert.report(r)) do print(l) end

local M = {}
local ch = require 'cartograph.characterize'
local ro = require 'cartograph.runoracle'

-- The taken certificate, per root, session-scoped — the same posture as neutrality's baseline
-- (`M._snap`), so the two verbs behave alike: take before, check after, in one session.
M._held = {}

--- Characterize and RUN one symbol, returning the entry to record. `fills` are the base input
--- fills; `asserts` is a list of { id, want } applied in order.
local function observe(store, fn_id, opts, used)
    local plan, why = ch.plan(store, fn_id)
    if not plan then return nil, why end
    -- FILLS ARE A SHARED POOL, FILTERED PER PLAN. A certificate covers several symbols, and
    -- ch.fill REFUSES an id the plan does not have (correctly — a typo must not pass silently),
    -- so handing one bag to every symbol failed all of them. Each takes what it recognises.
    -- AND A FILL THAT MATCHED NOTHING ANYWHERE IS REPORTED (see `take`): filtering per plan is
    -- ergonomic, filtering without accounting is how a mistyped id does nothing quietly.
    if opts and opts.fills then
        local mine = {}
        local have = {}
        for _, h in ipairs(plan.holes) do have[h.id] = true end
        for id, f in pairs(opts.fills) do
            if have[id] then mine[id] = f; if used then used[id] = true end end
        end
        if next(mine) then
            local n, ferr = ch.fill(plan, mine)
            if not n then return nil, ferr end
        end
    end
    for _, a in ipairs((opts and opts.asserts) or {}) do
        local n, aerr = ch.assert_condition(store, plan, a.id, a.want)
        if not n then return nil, aerr end
    end
    local okr, rerr = ro.fill_oracle(store, plan, opts)
    if not okr then return nil, rerr end
    local ret, eff
    for _, h in ipairs(plan.holes) do
        if h.kind == 'oracle' then ret = h end
        if h.kind == 'effects' then eff = h end
    end
    -- THE INPUTS ARE PART OF THE OBSERVATION, not a detail: an "after" run with different inputs
    -- is not a comparison, it is two unrelated facts. So they are recorded and replayed.
    --
    -- POSITIONALLY, AND THAT CORRECTION MATTERS. Keyed by NAME, a certificate cannot replay
    -- through a PARAMETER RENAME — which is the most behaviour-neutral refactor there is, so the
    -- check failed exactly where it should have succeeded (measured: M.add(a,b) -> M.add(x,y)
    -- reported "input:x is still a hole"). A function's inputs are POSITIONAL and the names are
    -- incidental, so position is what survives. A changed ARITY is a different thing entirely —
    -- a signature change — and is reported as one rather than silently mis-mapped.
    local byname = {}
    for _, h in ipairs(plan.holes) do
        if h.kind == 'input' and h.value then byname[h.name] = h end
    end
    local positional, others = {}, {}
    for i, pname in ipairs(plan.params or {}) do
        local h = byname[pname]
        positional[i] = h and { value = h.raw_value or h.value, by = h.by } or nil
    end
    for _, h in ipairs(plan.holes) do
        if h.value and h.kind ~= 'oracle' and h.kind ~= 'effects' and h.kind ~= 'input' then
            others[h.id] = { value = h.raw_value or h.value, by = h.by,
                basis = h.basis or 'replayed from the certificate' }
        end
    end
    return {
        name = plan.fn, file = plan.file,
        ret = ret and ret.raw_value or nil, retn = ret and ret.n or nil,
        effects = eff and eff.value or nil,
        tier = (ret and ret.filled_tier) or (eff and eff.filled_tier) or nil,
        positional = positional, arity = #(plan.params or {}), others = others,
        asserts = (opts and opts.asserts) or nil,
    }
end

--- Replay a recorded entry's inputs onto a NEW plan, by POSITION. Returns (fills, nil) or
--- (nil, why) — and an arity change is a refusal with its own name, because a signature change
--- is not a behaviour comparison at all.
local function replay_fills(plan, e)
    local now = #(plan.params or {})
    if e.arity and now ~= e.arity then
        return nil, ('the SIGNATURE changed: %d parameter(s) before, %d now — a behaviour'
            .. ' comparison across an arity change would be comparing two different'
            .. ' functions'):format(e.arity, now)
    end
    local fills = {}
    for i, pname in ipairs(plan.params or {}) do
        local rec = e.positional and e.positional[i]
        if rec then
            fills['input:' .. pname] = { value = rec.value, by = rec.by or 'agent',
                basis = ('replayed from the certificate (parameter %d)'):format(i) }
        end
    end
    for id, f in pairs(e.others or {}) do fills[id] = f end
    return fills
end

--- TAKE the certificate: observe every symbol, and record WHY each one that could not be observed
--- could not be. Returns { root, entries = {…}, uncertifiable = {…}, witnesses = <neutrality map> }.
--- `opts.ids` names the symbols; `opts.staged` takes them from a staged plan instead.
function M.take(store, opts)
    opts = opts or {}
    local ids = opts.ids or {}
    if opts.staged then
        if opts.staged.fn_id then ids = { opts.staged.fn_id } end
        for _, m in ipairs(opts.staged.moves or {}) do
            if m.id then ids[#ids + 1] = m.id end
        end
    end
    local cert = { root = store.data.root, entries = {}, uncertifiable = {} }
    local used = {}
    for _, id in ipairs(ids) do
        local node = store.node(id)
        local e, why = observe(store, id, opts, used)
        if e then
            cert.entries[#cert.entries + 1] = e
        else
            cert.uncertifiable[#cert.uncertifiable + 1] = {
                name = node and node.name or tostring(id),
                file = node and node.file, why = why }
        end
    end
    -- THE PROXY IS KEPT FOR EXACTLY THE SYMBOLS THE ASSERTION COULD NOT REACH. It is weaker, and
    -- the report says which tier covered what — a certificate that borrowed the proxy's coverage
    -- while implying the assertion's strength would be worse than the proxy alone.
    -- A FILL NOBODY WANTED is almost always a mistyped id, and a silent no-op there would let a
    -- certificate be taken with an input the caller believes they supplied.
    for id in pairs(opts.fills or {}) do
        if not used[id] then
            cert.unused = cert.unused or {}
            cert.unused[#cert.unused + 1] = id
        end
    end
    cert.witnesses = require('cartograph.neutrality').witnesses(store)
    return cert
end

--- CHECK the certificate against the CURRENT graph. Returns
--- { neutral = {…}, changed = {…}, lost = {…}, witnessed = <compare>, entries, root }.
function M.check(store, cert)
    if not (cert and cert.entries) then return nil, 'not a certificate' end
    -- RE-RESOLVE BY NAME: an apply re-extracts and every id has moved.
    local byname = {}
    for _, n in ipairs(store.data.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and n.name then
            byname[n.name] = byname[n.name] or n.id
        end
    end
    local out = { neutral = {}, changed = {}, lost = {}, root = store.data.root }
    for _, e in ipairs(cert.entries) do
        local id = byname[e.name]
        if not id then
            -- GONE is not neutral and not changed: the symbol the certificate describes is not
            -- there, which for a MOVE may be expected and for anything else is the finding.
            out.lost[#out.lost + 1] = { name = e.name, why = 'no function of that name in the'
                .. ' new graph (a rename or a deletion — the certificate cannot follow either)' }
        else
            local plan2 = ch.plan(store, id)
            -- `plan2 and replay_fills(...)` would TRUNCATE to one value and lose the reason —
            -- the same multi-value gotcha that has now bitten three times in this arc (the
            -- subject's returns, a fake's returns, and here). An `and` is a value, not a call.
            local fills, ferr
            if plan2 then fills, ferr = replay_fills(plan2, e) end
            local now, why
            if fills then
                now, why = observe(store, id, { fills = fills, asserts = e.asserts }, nil)
            else
                why = ferr or 'could not re-plan the symbol'
            end
            if not now then
                out.lost[#out.lost + 1] = { name = e.name,
                    why = 'could not be re-observed: ' .. tostring(why) }
            elseif now.ret == e.ret and now.retn == e.retn
                and (now.effects or '') == (e.effects or '') then
                out.neutral[#out.neutral + 1] = { name = e.name, ret = e.ret,
                    effects = e.effects, tier = e.tier, file = now.file }
            else
                local d = {}
                if now.ret ~= e.ret or now.retn ~= e.retn then
                    d[#d + 1] = ('returns %s -> %s'):format(tostring(e.ret), tostring(now.ret))
                end
                if (now.effects or '') ~= (e.effects or '') then
                    d[#d + 1] = ('effects %s -> %s'):format(tostring(e.effects),
                        tostring(now.effects))
                end
                out.changed[#out.changed + 1] = { name = e.name, file = now.file, differs = d }
            end
        end
    end
    -- and the PROXY over everything, including the symbols the assertion never reached
    if cert.witnesses then
        local neu = require 'cartograph.neutrality'
        out.witnessed = neu.compare(cert.witnesses, neu.witnesses(store))
    end
    out.uncertifiable = cert.uncertifiable
    out.unused = cert.unused
    return out
end

--- HOLD a certificate for this root, and CHECK the held one. Mirrors
--- neutrality.snapshot/check deliberately: the pair is the same shape, so a reader who knows
--- one knows the other.
function M.hold(store, opts)
    local c = M.take(store, opts)
    M._held[store.data.root] = c
    return c
end

function M.check_held(store)
    local c = M._held[store.data.root]
    if not c then
        return nil, 'no certificate — take one BEFORE the refactor (:CartographCertify)'
    end
    return M.check(store, c)
end

--- The result as report ROWS — (lines, at).
function M.report(res)
    local L, A = {}, {}
    local function add(s, a) L[#L + 1] = s; A[#A + 1] = a end
    local n_ass = #res.neutral + #res.changed
    add(('behaviour certificate — %d symbol(s) certified BY ASSERTION, %d only by WITNESS')
        :format(n_ass, #(res.uncertifiable or {})), nil)
    add('  an assertion RAN the symbol before and after; a witness only hashes its shape, so it', nil)
    add('  proves a body was not TOUCHED and cannot speak for one that changed on purpose.', nil)
    add('', nil)
    if #res.changed > 0 then
        add(('  CHANGED (%d) — ran both times and DISAGREED. This is the finding:')
            :format(#res.changed), nil)
        for _, c in ipairs(res.changed) do
            add(('    %-28s %s'):format(c.name, table.concat(c.differs, '; ')),
                { file = c.file })
        end
        add('', nil)
    end
    if #res.neutral > 0 then
        add(('  NEUTRAL BY ASSERTION (%d) — same return, same effects, both observed:')
            :format(#res.neutral), nil)
        for _, c in ipairs(res.neutral) do
            add(('    %-28s %s [%s]'):format(c.name, tostring(c.ret), tostring(c.tier)),
                { file = c.file })
        end
        add('', nil)
    end
    if #res.lost > 0 then
        add(('  NOT RE-OBSERVED (%d) — neither neutral nor changed, and that distinction'):format(#res.lost), nil)
        add('  matters: the certificate cannot follow a rename or a deletion.', nil)
        for _, c in ipairs(res.lost) do
            add(('    %-28s %s'):format(c.name, c.why), nil)
        end
        add('', nil)
    end
    -- THE COVERAGE GAP, ALWAYS PRINTED. A hash always computes and a run does not, so a
    -- certificate that did not say which symbols it could only hash would carry the proxy's
    -- coverage while implying the assertion's strength.
    if #(res.uncertifiable or {}) > 0 then
        add(('  ONLY WITNESSED (%d) — could not be characterized, so only the shape hash covers'):
            format(#res.uncertifiable), nil)
        add('  them. Weaker evidence, and named rather than counted as neutral:', nil)
        for _, u in ipairs(res.uncertifiable) do
            add(('    %-28s %s'):format(u.name, (u.why or ''):gsub('\n.*', '')),
                { file = u.file })
        end
        add('', nil)
    end
    if #(res.unused or {}) > 0 then
        add(('  FILLS THAT MATCHED NOTHING (%d): %s — almost always a mistyped hole id, and'):
            format(#res.unused, table.concat(res.unused, ', ')), nil)
        add('  a silent no-op here would let a certificate be taken with an input the caller', nil)
        add('  believes they supplied.', nil)
        add('', nil)
    end
    if res.witnessed then
        local w = res.witnessed
        add(('  WITNESS PROXY over the whole graph: %d neutral, %d drifted, %d removed,'
            .. ' %d added, %d renamed'):format(#w.neutral, #w.drifted, #w.removed, #w.added,
            #w.renamed), nil)
        add('  (a drift here is expected for any refactor that changes a body on purpose —'
            .. ' that is precisely what the assertions above are for)', nil)
    end
    return L, A
end

return M
