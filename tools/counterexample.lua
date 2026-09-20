-- counterexample — CONSTRUCT the input that violates a promise, instead of searching for it.
--
-- USER (CART-0990): "I wonder if we can generate valid code examples from cartograph that
-- will fail and expose our bugs aka exposing unknown promises we have made" — then, twice
-- sharper: "What I meant is white box fuzzing", and "Or direct counterexample generation".
--
--   nvim --headless -u NONE -l tools/counterexample.lua [--keep]
--
-- ★★★ EVERY REFUSAL IS A PROMISE. `return nil, "<reason>"` says: IN THIS CASE I WILL
-- REFUSE, AND THIS IS WHY. Counted in the write path: 160 of them. Nothing anywhere asks
-- whether an input exists that reaches any one. This asks, for the ones listed below, by
-- CONSTRUCTING the input from the property's negation — no search, no mutation loop, no
-- solver, because our properties are STRUCTURAL rather than numeric.
--
-- ★★ THE EVIDENCE THAT THE MOVE WORKS IS THAT IT WAS DONE BY HAND THREE TIMES IN ONE DAY.
-- Every fixture written for CART-0984/0985/0989 was exactly this: take the predicate,
-- negate it, write the smallest program satisfying the negation. `local SALT = 7` between
-- two copies; two members inside `return { … }`; `A.unify` off a body-local. Hand-written,
-- one at a time, and only ever for bugs already found. This writes them for properties
-- nobody has falsified yet — which is the "unknown promises" the user named.
--
-- THREE CLASSES OF OUTCOME, in increasing value:
--   CONFIRMED  the counterexample reached the promise and the promise fired. The property
--              is real AND falsifiable — which is the only way to know a guard has teeth.
--   BROKEN     the counterexample reached the promise and it did NOT fire. A bug.
--   UNREACHED  no counterexample could be built that reaches it. ⚠ THIS IS NOT THE SAME
--              AS "the promise is vacuous" — it means THIS GENERATOR could not get there,
--              and the honest report says so. A genuinely vacuous promise (CART-0985
--              shipped one: a guard no input could trigger, which passed the suite by
--              never running) looks identical from here, so UNREACHED is a prompt to go
--              and read the predicate, not a verdict on it.
--
-- ⚠⚠ WHAT THIS IS NOT, STATED PLAINLY: this crosses a FIXED DONOR TEMPLATE with an
-- adversarial VALUE TABLE. It is not open-ended synthesis. Adding a value or a donor
-- multiplies the cases, and combinations nobody chose do get tested — but the shapes it
-- can reach are the shapes someone listed, so it can only find bugs inside a taxonomy we
-- already have. The generator that uses REAL donors from the tree is the next step:
-- `clones.analyze_pair` already gives every hole its exact span, and `clones.render`
-- documents the substitution convention (0-based, end-exclusive, `line:sub(sc+1, ec)`).
--
-- ⚠ AND IT REPARSES EVERY COUNTEREXAMPLE BEFORE USING IT. `clones.render` refuses an
-- unverified render for this exact reason — "substituting into text is not a proof that
-- the result parses to the shape it was built from". A counterexample that does not parse
-- tests the parser, not the promise.

local here = debug.getinfo(1, 'S').source:sub(2)
local repo = vim.fn.fnamemodify(here, ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local keep, donors_only, emit_dir = false, false, nil
for i, a in ipairs(arg or {}) do
    if a == '--keep' then keep = true end
    if a == '--donors' then donors_only = true end
    if a == '--emit' then emit_dir = arg[i + 1] end
end

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'
local cx = require 'cartograph.cloneextract'
local at = require 'cartograph.at'
local foldrank = require 'cartograph.foldrank'

-- ── THE DONOR: two copies differing in ONE hole ─────────────────────────────
-- `%PRE%` is file-scope text, `%BODY%` sits inside both bodies, `%A%`/`%B%` are the
-- diverging hole. Everything else is identical, so the pair is a near-clone by
-- construction and the hole is the only place a property can be violated (dec/153).
local DONOR = [[
local M = {}
%PRE%
M.alpha = function (x)
  local y = prep(x)
  local z = norm(y)
%BODY%
  local w = enc(z, %A%)
  return w
end

M.beta = function (a)
  local b = prep(a)
  local c = norm(b)
%BODY%
  local d = enc(c, %B%)
  return d
end

return M
]]

-- the CONSTRUCTOR donor: the same pair, but the members are entries in a table
-- constructor, so a `local function` helper cannot legally sit beside them (CART-0985)
local DONOR_CTOR = [[
local M = {}
%PRE%
return {
  hooks = {
    alpha = function (x)
      local y = prep(x)
      local z = norm(y)
%BODY%
      local w = enc(z, %A%)
      return w
    end,
    beta = function (a)
      local b = prep(a)
      local c = norm(b)
%BODY%
      local d = enc(c, %B%)
      return d
    end,
  },
}
]]

--- name          what promise this negates
--- donor/pre/body/a/b   how the counterexample is built
--- expect        a substring the REFUSAL must contain, or nil to expect a PLAN
--- preserves     when a plan is expected, the claim it must carry (CART-0989)
local PROPERTIES = {
    { name = 'control: a literal hole is liftable',
      a = "'json'", b = "'yaml'", preserves = 'all' },

    { name = 'an impure hole is not movable to the call site',
      a = "require('cfg').alpha", b = "require('cfg').beta",
      preserves = 'unreviewed' },

    { name = 'a field base the call site cannot name is REFUSED (CART-0984)',
      pre = '', body = '  local A = loadcfg()',
      a = 'A.alpha', b = 'A.beta',
      expect = 'is a local of the body' },

    { name = 'a helper may not outrun a local it reads (CART-0985)',
      pre = '', body = '  local q = SALT + 1',
      a = "'json'", b = "'yaml'",
      inject_between = 'local SALT = 7',
      -- ⚠ MATCHED ON THE REFUSAL'S OWN WORDS, not on the word used in the commit message.
      -- My first expectation said "outrun" — which appears in the ticket and the comments
      -- and NOWHERE in the refusal — so the generator reported BROKEN for a promise that
      -- had fired correctly. A property table is only as honest as the string it matches:
      -- take it from the source, not from the prose about it.
      expect = 'must be inserted above' },

    { name = 'members in a CONSTRUCTOR get the helper hoisted out (CART-0985)',
      donor = DONOR_CTOR, a = "'json'", b = "'yaml'", preserves = 'all' },

    -- ⚠ THE HOLE ITSELF MUST BE GUARDED, not merely near a branch. My first attempt put
    -- `if z then … end` in the body, which made the pair STRUCTURAL — the verb refused
    -- before the guarded-literal question was ever asked, and the honest report was
    -- UNREACHED. A short-circuit AROUND THE HOLE keeps both sides the same shape and puts
    -- the value under a condition, which is what `guarded` actually means.
    { name = 'a guarded LITERAL is still safe (guarded AND pure)',
      wrap = true, a = "'json'", b = "'yaml'", preserves = 'all' },
}

local root = vim.fn.tempname() .. '-counterexample'
vim.fn.mkdir(root, 'p')

local function build(p)
    -- ⚠⚠ EVERY REPLACEMENT IS PARENTHESISED, AND THAT IS NOT STYLE. `s:gsub(…)` returns
    -- (string, COUNT); in final argument position BOTH are passed, so the outer gsub
    -- receives the count as its `n` limit — and a count of 0 means REPLACE NOTHING. The
    -- first run of this tool reported UNREACHED for all six properties because every
    -- placeholder survived substitution, which reads exactly like "the generator is too
    -- weak" and was "the generator did nothing". certificate.lua carries a note saying
    -- this gotcha "has now bitten three times in this arc". This was the fourth.
    local esc = function (s) return (tostring(s):gsub('%%', '%%%%')) end
    local src = (p.donor or DONOR)
    src = (src:gsub('%%PRE%%', esc(p.pre or '')))
    src = (src:gsub('%%BODY%%', esc(p.body or '')))
    local A, B = p.a, p.b
    if p.wrap then
        -- the hole sits behind a short-circuit: evaluated only sometimes, so lifting it
        -- to an argument makes it EAGER — safe iff the value is pure (dec/153)
        A, B = ('z and %s or nil'):format(A), ('c and %s or nil'):format(B)
    end
    src = (src:gsub('%%A%%', esc(A)))
    src = (src:gsub('%%B%%', esc(B)))
    if p.inject_between then
        -- bind it BETWEEN the two copies, which is the shape the insertion-scope guard
        -- exists for: the helper lands above the first copy and would outrun it
        src = src:gsub('\nM%.beta', '\n' .. p.inject_between .. '\n\nM.beta', 1)
    end
    return src
end

-- ⚠ A COUNTEREXAMPLE THAT DOES NOT PARSE TESTS THE PARSER, NOT THE PROMISE.
local function parses(src)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
    if not ok or not parser then return false end
    local okt, tree = pcall(function () return parser:parse()[1] end)
    return okt and tree and not tree:root():has_error()
end

local NEAR = { max_dist = 3, min_rows = 3, min_shared = 2 }
local rows, bad = {}, 0
for i, p in ipairs(PROPERTIES) do
    local src = build(p)
    local dir = root .. '/c' .. i
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(dir .. '/m.lua', 'w')); fd:write(src); fd:close()

    local verdict, detail
    if not parses(src) then
        verdict, detail = 'UNREACHED', 'the constructed counterexample does not parse'
    else
        local data = ts.extract(dir); data.root = data.root or dir
        store.ingest(data)
        local id
        for _, n in ipairs(store.data.nodes) do
            if n.name == 'M.alpha' or n.name == 'alpha' then id = n.id end
        end
        local pair = id and clones.near_of(store, id, NEAR)[1]
        if not pair then
            -- ★ the two copies stopped being a near-clone, so the verb is never asked
            -- and the promise is never reached BY THIS GENERATOR
            verdict, detail = 'UNREACHED', 'the two copies are no longer a near-clone pair'
        else
            local plan, why = cx.plan(store, pair, {})
            if p.expect then
                if plan then
                    verdict, detail = 'BROKEN', 'it PLANNED where the promise says refuse'
                elseif (why or ''):find(p.expect, 1, true) then
                    verdict, detail = 'CONFIRMED', why
                else
                    verdict, detail = 'BROKEN', ('refused for a DIFFERENT reason: %s')
                        :format(tostring(why))
                end
            else
                if not plan then
                    verdict, detail = 'UNREACHED', ('it refused instead: %s'):format(tostring(why))
                elseif plan.preserves ~= p.preserves then
                    verdict, detail = 'BROKEN', ('claims `%s`, expected `%s` — %s')
                        :format(tostring(plan.preserves), tostring(p.preserves),
                                tostring(plan.preserves_why))
                else
                    verdict, detail = 'CONFIRMED', ('planned, claiming `%s`'):format(plan.preserves)
                end
            end
        end
    end
    if verdict == 'BROKEN' then bad = bad + 1 end
    rows[#rows + 1] = { name = p.name, verdict = verdict, detail = detail,
        src = src, prop = p, observed = detail }
end

-- ══ PHASE 2: REAL DONORS ═══════════════════════════════════════════════════
--
-- ★★★ THE TEMPLATE ABOVE CAN ONLY FIND BUGS INSIDE A SHAPE SOMEBODY WROTE. This phase
-- takes near-clone pairs OFF OUR OWN TREE and substitutes an adversarial value at the
-- hole's REAL SPAN, so the surrounding code is whatever the tree actually contains —
-- the donor IS the context rather than an imitation of one, which is `clones.render`'s
-- whole argument for substituting into donor text instead of emitting from a template.
--
-- ★★ AND IT AIMS AT THE PATH THAT HAS NO COVERAGE. Measured (dec/153): 8 of the 9 lifted
-- holes on this tree are LITERALS, so the purity analysis those claims rest on is barely
-- exercised by our own code. Substituting a CALL into a real hole runs exactly the branch
-- that is otherwise never taken.
--
-- ⚠ ONLY VALUE-SUBSTITUTION PROPERTIES FIT HERE. A body-local base or a constructor
-- member is a STRUCTURAL change to the donor, not a hole value — those stay on the
-- synthetic template above, and saying so is the honest division rather than pretending
-- one generator covers both.
local DONOR_PROPS = {
    { name = 'two distinct literals stay neutral', a = "'aaa'", b = "'bbb'",
      preserves = 'all' },
    { name = 'a `require` in the hole is not movable', a = "require('cfgx').aa",
      b = "require('cfgx').bb", preserves = 'unreviewed' },
    -- ★★★ THE DISTINCTION THIS TOOL TAUGHT ME, AND IT NEARLY BECAME A FALSE BUG REPORT.
    -- My first version asserted `os.time()` / `os.clock()` in a hole must be `unreviewed`,
    -- and it reported BROKEN on four separate donors — which looks exactly like one root
    -- cause found four times. It was MY PREMISE that was wrong. What a `field` hole lifts
    -- is the ACCESS (`os.time`), not the call, so the call site receives the FUNCTION
    -- VALUE and the invocation stays in the helper body:
    --     return template_meet_extracted(a, b, opts, os.time, 'unify failed: ')
    -- Nothing moves, so `pure` is right. Verified by reading the PREVIEW rather than
    -- trusting the verdict — test the premise, not the consequence.
    -- ⇒ A CALL ONLY TRAVELS WHEN IT IS IN THE BASE, which is what the `require` row above
    -- constructs and what `find_bin`'s real `require('cartograph.config').clangd_bin`
    -- hole is. This row now asserts the true and subtler fact.
    { name = 'a field off a plain name lifts the FUNCTION, not the call',
      a = 'os.time', b = 'os.clock', preserves = 'all' },
}

--- substitute `text` at every span in `sites`, BOTTOM-UP.
--- ⚠ DESCENDING ORDER IS NOT AN OPTIMISATION. Replacing left-to-right shifts every later
--- span on the same line, and the second write then lands on stale columns — which is
--- CART-0984's duplicate-substitution bug exactly, and it ate a `then` when it happened
--- for real. The convention is `clones.render`'s, derived there rather than assumed:
--- 0-based, end-exclusive, `l:sub(1, sc) .. to .. l:sub(ec + 1)`.
local function splice(lines, sites, text)
    local s = {}
    for _, r in ipairs(sites or {}) do
        if at.sl(r) ~= at.el(r) then return nil, 'a multi-line hole span' end
        s[#s + 1] = r
    end
    if #s == 0 then return nil, 'the hole carries no span' end
    table.sort(s, function (x, y)
        if at.sl(x) ~= at.sl(y) then return at.sl(x) > at.sl(y) end
        return at.sc(x) > at.sc(y)
    end)
    for _, r in ipairs(s) do
        local l = lines[at.sl(r) + 1]
        if not l then return nil, 'a span outside the file' end
        lines[at.sl(r) + 1] = l:sub(1, at.sc(r)) .. text .. l:sub(at.ec(r) + 1)
    end
    return lines
end

local function real_donors()
    local data = ts.extract(repo .. '/lua'); data.root = data.root or (repo .. '/lua')
    store.ingest(data)
    local out, seen = {}, {}
    for _, p in ipairs(clones.near(store, { max_dist = 4 })) do
        if p.a and p.b and p.a.file == p.b.file
            and not p.a.file:find('^cartograph/algebra/') then
            local an = clones.analyze_pair(p, store)
            local h = (an.holes or {})[1]
            if an.kind == 'value' and h and not seen[p.a.file .. tostring(p.a.name)] then
                seen[p.a.file .. tostring(p.a.name)] = true
                out[#out + 1] = { file = p.a.file, a = p.a.name, b = p.b.name, hole = h }
            end
        end
    end
    return out
end

if true then
    local donors = real_donors()
    for _, d in ipairs(donors) do
        local src0 = {}
        for l in io.lines(repo .. '/lua/' .. d.file) do src0[#src0 + 1] = l end
        for _, dp in ipairs(DONOR_PROPS) do
            local lines = {}
            for i, l in ipairs(src0) do lines[i] = l end
            local okA, whyA = splice(lines, d.hole.sites_a, dp.a)
            local okB = okA and splice(lines, d.hole.sites_b, dp.b)
            local label = ('%s: %s'):format(d.file:gsub('^cartograph/', ''), dp.name)
            local verdict, detail
            if not okB then
                verdict, detail = 'UNREACHED', tostring(whyA or 'could not substitute')
            else
                local text = table.concat(lines, '\n')
                if not parses(text) then
                    verdict, detail = 'UNREACHED', 'the substituted donor does not parse'
                else
                    local dir = root .. '/d' .. #rows .. '_' .. #rows
                    vim.fn.mkdir(dir, 'p')
                    local fd = assert(io.open(dir .. '/m.lua', 'w'))
                    fd:write(text); fd:close()
                    local dat = ts.extract(dir); dat.root = dat.root or dir
                    store.ingest(dat)
                    local id
                    for _, n in ipairs(store.data.nodes) do
                        if n.name == d.a then id = n.id break end
                    end
                    local pair = id and clones.near_of(store, id, { max_dist = 4,
                        min_rows = 3, min_shared = 2 })[1]
                    if not pair then
                        verdict, detail = 'UNREACHED',
                            'the substituted copies are no longer a near-clone pair'
                    else
                        local plan, why = cx.plan(store, pair, {})
                        if not plan then
                            verdict, detail = 'UNREACHED', ('refused: %s'):format(tostring(why))
                        elseif plan.preserves ~= dp.preserves then
                            verdict, detail = 'BROKEN', ('claims `%s`, expected `%s` — %s')
                                :format(tostring(plan.preserves), tostring(dp.preserves),
                                        tostring(plan.preserves_why))
                        else
                            verdict, detail = 'CONFIRMED',
                                ('claims `%s`'):format(plan.preserves)
                        end
                    end
                end
            end
            if verdict == 'BROKEN' then bad = bad + 1 end
            rows[#rows + 1] = { name = label, verdict = verdict, detail = detail,
                donor = true }
        end
    end
end

-- ══ EMIT: TURN A CONFIRMED COUNTEREXAMPLE INTO A TEST ══════════════════════
--
-- CART-0991. The generated case carries a PRE-FILLED assertion — review is JUDGEMENT
-- ("is that refusal right?") rather than AUTHORSHIP ("write the assertion") — plus a
-- `PENDING(...)` that ERRORS, so inaction cannot turn a machine-written test into
-- coverage. PROMOTION IS DELETING ONE LINE and moving the file into `tests/`.
--
-- ★★★ THE REACH PROOF IS THE `CONFIRMED` VERDICT ITSELF. A generated test whose fixture
-- never reaches the refusal passes for the wrong reason, so the case must be PROVEN to
-- get there. For these it already is: CONFIRMED means this tool ran the verb on this
-- exact source and the promise FIRED. Only cases that reached their promise are emitted
-- — UNREACHED and BROKEN rows are not tests, they are findings.
--
-- ⚠ OUT OF THE SUITE BY CONSTRUCTION. The runner globs `tests/*_spec.lua`; these land in
-- a `generated/` subdirectory with a `_gen.lua` suffix, so bulk generation cannot break
-- the gate. Same fence `characterize` puts round its own specs, and for the same reason.
--
-- ⚠ SYNTHETIC PROPERTIES ONLY. A real-donor case embeds a 1000-line file; emitting those
-- would produce tests nobody can read, and the fixture is the half a reviewer must
-- actually check.
local function emit(dir)
    vim.fn.mkdir(dir, 'p')
    local n = 0
    for _, r in ipairs(rows) do
        if r.verdict == 'CONFIRMED' and r.src and r.prop then
            n = n + 1
            local p = r.prop
            local assertion
            if p.expect then
                assertion = ("    ok(not plan, 'it refuses rather than planning')\n"
                    .. "    ok(tostring(why):find(%q, 1, true), tostring(why))")
                    :format(p.expect)
            else
                assertion = ("    ok(plan, 'it plans: ' .. tostring(why))\n"
                    .. "    eq(%q, plan and plan.preserves, 'the behavioural claim')")
                    :format(p.preserves)
            end
            local body = ([[
-- GENERATED by tools/counterexample.lua — NOT REVIEWED.
-- property: %s
-- OBSERVED: %s
--
-- The assertion below is written from what the verb ACTUALLY DID, so reviewing it is a
-- judgement ("is that the right behaviour?") and not an authoring job. `PENDING` errors
-- until someone decides. TO PROMOTE: confirm the behaviour, delete the PENDING line,
-- give the test a name that says why the case matters, and move this file into tests/.
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'
local cx = require 'cartograph.cloneextract'

test('GENERATED (unreviewed): %s', function ()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write([==[
%s]==])
    fd:close()
    store.ingest(ts.extract(root))
    local id
    for _, nd in ipairs(store.data.nodes) do
        if nd.name == 'M.alpha' or nd.name == 'alpha' then id = nd.id end
    end
    local pair = id and clones.near_of(store, id,
        { max_dist = 3, min_rows = 3, min_shared = 2 })[1]
    ok(pair, 'the two copies are a near-clone pair')
    if not pair then return end
    -- ⚠ NOT `pair and cx.plan(…)`: AN `and` IS A VALUE, NOT A CALL, so it TRUNCATES to
    -- one return and `why` arrives nil. certificate.lua carries a note saying this
    -- gotcha had already bitten three times in this arc; the first version of THIS
    -- EMITTER made it four, identically in all six generated tests — one template, one
    -- wrong premise, six instances that look like six witnesses.
    local plan, why = cx.plan(store, pair, {})
%s
    vim.fn.delete(root, 'rf')
    PENDING('confirm the behaviour above is correct, then delete this line')
end)
]]):format(r.name, tostring(r.observed):gsub('\n', ' '):sub(1, 150), r.name,
            r.src, assertion)
            local slug = r.name:lower():gsub('[^%w]+', '_'):sub(1, 44)
            local fd2 = assert(io.open(('%s/%s_gen.lua'):format(dir, slug), 'w'))
            fd2:write(body); fd2:close()
        end
    end
    return n
end

print(('counterexample — %d propert%s\n'):format(#PROPERTIES, #PROPERTIES == 1 and 'y' or 'ies'))
for _, r in ipairs(rows) do
    print(('  %-9s %s'):format(r.verdict, r.name))
    print(('            %s'):format(tostring(r.detail):sub(1, 96)))
end
local n = { CONFIRMED = 0, BROKEN = 0, UNREACHED = 0 }
for _, r in ipairs(rows) do n[r.verdict] = n[r.verdict] + 1 end
print(('\nCONFIRMED %d · BROKEN %d · UNREACHED %d')
    :format(n.CONFIRMED, n.BROKEN, n.UNREACHED))
-- ⚠ UNREACHED IS NOT A FAILURE AND NOT A PASS. It is the prompt to go read the predicate
-- and decide whether the promise is vacuous or the generator is too weak.
if n.UNREACHED > 0 then
    print('⚠ an UNREACHED property is a prompt, not a verdict: either the promise cannot'
        .. ' fire (read the predicate — CART-0985 shipped exactly that) or this'
        .. ' generator cannot construct the input that reaches it.')
end
if emit_dir then
    local n = emit(emit_dir)
    print(('\nemitted %d generated test(s) to %s — each PENDING review, and OUTSIDE the'
        .. ' suite glob until promoted'):format(n, emit_dir))
end
if keep then print('trees kept at ' .. root) else vim.fn.delete(root, 'rf') end
print('\nCOUNTEREXAMPLE: ' .. (bad == 0 and 'no broken promise' or (bad .. ' BROKEN')))
os.exit(bad == 0 and 0 or 1)
