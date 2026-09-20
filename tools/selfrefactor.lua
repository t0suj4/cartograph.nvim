-- selfrefactor — CARTOGRAPH REFACTORS CARTOGRAPH, AS A TEST THAT PASSES OR DOES NOT.
--
-- CART-0878 ORDER (3): "automate, at which point self-refactoring is a test that passes
-- or does not." The ticket's acceptance criterion, run end to end without a human in it:
--
--   APPLY an extraction  ->  RE-ANALYZE  ->  the finding must MOVE
--                                        ->  the near-clone count is MONOTONE DOWN
--                                        ->  the suite stays GREEN
--
--   nvim --headless -u NONE -l tools/selfrefactor.lua [--dir D] [--n N]
--                                                     [--max-dist N] [--no-suite]
--
-- Exits 0 only if every rung held. Anything else is a FAIL with the rung named.
--
-- ★★★ IT NEVER WRITES THE REAL TREE. The repo is copied to a scratch directory and the
-- whole loop runs there, because the thing under test is a verb that EDITS SOURCE and
-- the source it would edit is its own. A loop that mutates the tree it is being judged
-- from cannot be re-run, and its second run measures the first one's damage.
--
-- ⚠⚠ THE VENDORED ALGEBRA IS EXCLUDED, AND NOT AS AN OPTIMISATION.
-- `lua/cartograph/algebra/**` is a vendored copy of the USER'S OWN prototype tree
-- (~/tools/templates). It is read, never written. The fold queue ranks it happily —
-- three of the seven plannable pairs on this tree live in it — so a loop that took its
-- top row by price would "self-refactor" by rewriting someone else's source.
--
-- ⚠ WHAT THIS DOES NOT CLAIM, and the ticket is explicit about it. ORDER (1) (hand-write
-- the two named clusters' helpers to calibrate the preference) and ORDER (2) (dependency
-- lists in extract_proposal) are NOT done, and CART-0876 still blocks them. So this
-- automates the loop over THE SHAPES THAT ALREADY APPLY — value-parameterizable pairs —
-- and not the two clusters the ticket names, which need n-ary generalization with a
-- cost. On this tree that is 7 plannable pairs against 17 refused, and the refusals are
-- most of the work. A green run here means THE LOOP CLOSES, not that the hard cases do.
--
-- ★★★ ITS FIRST REAL RUN WAS RED, AND THAT IS THE DELIVERABLE WORKING (2026-09-20).
-- The top-ranked fold on our own tree — `M.template_meet <-> M.template_join`, net -4 —
-- passed `discover`, `moved` and `monotone`, and BROKE SIX TESTS. `cloneextract` lifted
-- a value hole whose argument text is `A.unify`, where `A` is bound INSIDE the body it
-- extracted from; at the call site that is a global read and it raises. Filed CART-0984.
-- Every declared guard was green: the result parses, the helper exists, both call sites
-- exist. THE SUITE RUNG IS THE ONLY ONE THAT COULD HAVE SEEN IT, which is the argument
-- for this harness existing rather than trusting the analysis.
--
-- ⚠ IT TAKES THE TOP-RANKED FOLD AND DOES NOT SHOP FOR A PASSING ONE. A mode that
-- walked down the queue until something survived would report PASS on exactly the tree
-- that just wrote broken code — it would hide the defect it exists to find. The queue's
-- job is to say what to fold NEXT; if its #1 does not survive, the queue is wrong and
-- this must say so.
--
-- ⚠ AND THE SEMANTICS GUARD IS THE VERB'S, NOT THIS FILE'S. The extraction's own
-- admissibility analysis decides what may be lifted; this harness does not re-judge it.
-- What it adds is the rung the verb cannot check about itself: that the tree still
-- passes its own tests afterwards.

local here = debug.getinfo(1, 'S').source:sub(2)
local repo = vim.fn.fnamemodify(here, ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local want_n, max_dist, run_suite = 1, 2, true
local i = 1
while arg and arg[i] do
    if arg[i] == '--dir' then i = i + 1; work = arg[i]
    elseif arg[i] == '--n' then i = i + 1; want_n = tonumber(arg[i]) or want_n
    elseif arg[i] == '--max-dist' then i = i + 1; max_dist = tonumber(arg[i]) or max_dist
    elseif arg[i] == '--no-suite' then run_suite = false
    end
    i = i + 1
end

-- ── the rung ledger: every check is a named row, PASS or FAIL ───────────────
-- ★ A RUNG THAT DID NOT RUN IS NOT A RUNG THAT PASSED. Each one is recorded when it is
-- decided, so a loop that stops early reports the rungs it never reached as absent
-- rather than leaving a reader to infer them from a missing line.
local rungs = {}
local function rung(name, ok, detail)
    rungs[#rungs + 1] = { name = name, ok = ok and true or false, detail = detail }
    print(('  %-22s %s%s'):format(name, ok and 'PASS' or 'FAIL',
        detail and ('  ' .. detail) or ''))
    return ok
end
-- the work tree is named on EVERY exit, because a failing loop's whole value is the
-- tree you can go and look at
local work
local function die(name, detail)
    rung(name, false, detail)
    if work then print('work tree kept at ' .. work) end
    print('\nSELFREFACTOR: FAIL')
    os.exit(1)
end

-- ── 1. the copy ─────────────────────────────────────────────────────────────
if not work then work = vim.fn.tempname() .. '-selfrefactor' end
print(('selfrefactor — %s\n  work %s'):format(repo, work))
vim.fn.mkdir(work, 'p')
-- `.` and no `.git`: the loop needs lua/ tests/ tools/ to run the suite, and copying a
-- 100 MB object store to edit two functions is waste, not safety.
local cp = vim.fn.system({ 'bash', '-c',
    ('cd %s && tar --exclude=./.git -cf - . | (cd %s && tar -xf -)')
        :format(vim.fn.shellescape(repo), vim.fn.shellescape(work)) })
if vim.v.shell_error ~= 0 then die('copy', cp) end

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'
local foldrank = require 'cartograph.foldrank'
local ce = require 'cartograph.cloneextract'
local txn = require 'cartograph.txn'

local LUA = work .. '/lua'
-- ⚠ RE-READ FROM DISK, NEVER TRUST THE SPLICE. `apply` splices its result into the live
-- graph, which is right for an editor and wrong for this measurement: the question is
-- what a FRESH reader finds in the bytes on disk, and a spliced graph can only tell us
-- what the writer believed it wrote.
local function reload()
    local data = ts.extract(LUA)
    data.root = data.root or LUA
    store.ingest(data)
end

local VENDORED = 'cartograph/algebra/'
local function vendored(row)
    local p = row.pair or {}
    for _, side in ipairs({ p.a, p.b }) do
        if side and side.file and side.file:sub(1, #VENDORED) == VENDORED then return true end
    end
    return false
end

local function key_of(row) return tostring(row.a) .. ' <-> ' .. tostring(row.b) end

reload()
local before_pairs = #clones.near(store, { max_dist = max_dist })
rung('discover', before_pairs > 0, ('%d near-clone pair(s) at distance <= %d')
    :format(before_pairs, max_dist))
if before_pairs == 0 then
    -- ★ AN EMPTY QUEUE IS NOT A PASS. It means this harness measured nothing, and
    -- reporting that as success is how a loop rots into a no-op nobody notices.
    die('candidates', 'nothing to fold — the loop measured nothing')
end

-- ── 2..N. fold, one at a time, re-deriving the queue each round ─────────────
local applied, log = 0, {}
local prev_pairs = before_pairs
for round = 1, want_n do
    local rows = foldrank.rank(store, { max_dist = max_dist })
    local pick
    for _, r in ipairs(rows) do
        -- net < 0 is the whole point: a fold that ADDS lines may still be right, but it
        -- is a judgement call and this loop makes none.
        if r.net < 0 and not vendored(r) and r.pair then pick = r; break end
    end
    if not pick then
        if round == 1 then die('candidates',
            'no non-vendored pair with net < 0 — nothing this loop may act on') end
        print(('  (round %d: queue exhausted of shrinking non-vendored folds)'):format(round))
        break
    end
    local want_gone = key_of(pick)
    print(('\nround %d — fold %s  net %+d  in %s')
        :format(round, want_gone, pick.net, tostring(pick.file)))

    -- ⚠ RE-PLAN FROM THE PAIR. The row was priced against the graph as it stood; if an
    -- earlier round applied, that generation is gone and a held plan would be refused
    -- by `txn.verify` — correctly. The PAIR is what survives a generation bump.
    local plan, why = ce.plan(store, pick.pair, {})
    if not plan then die('plan', tostring(why)) end
    local bef, _, dwhy = txn.dryrun(store, plan)
    if not bef then die('preview', tostring(dwhy)) end
    local entry, awhy = txn.apply(store, plan)
    if not entry then die('apply', tostring(awhy)) end
    applied = applied + 1
    log[#log + 1] = { key = want_gone, net = pick.net, helper = plan.helper }

    -- ── the finding must MOVE, measured on a FRESH read ─────────────────────
    reload()
    local now_pairs = #clones.near(store, { max_dist = max_dist })
    local still_there = false
    for _, r in ipairs(foldrank.rank(store, { max_dist = max_dist })) do
        if key_of(r) == want_gone then still_there = true end
    end
    if not rung('moved', not still_there, want_gone .. ' is gone from the re-read queue') then
        die('moved', 'the pair the fold targeted is STILL in the queue after applying it')
    end
    -- ★ MONOTONE, AND STRICTLY. An extraction that removes one duplication while
    -- creating another would hold "the finding moved" and still be a loop that spins.
    if not rung('monotone', now_pairs < prev_pairs,
        ('near pairs %d -> %d'):format(prev_pairs, now_pairs)) then
        die('monotone', 'the fold did not reduce the near-clone count')
    end
    prev_pairs = now_pairs
end

-- ── the suite, in the copy, against the edited source ───────────────────────
-- ★★ THIS IS THE RUNG THE VERB CANNOT CHECK ABOUT ITSELF. Every guard the plan declares
-- asks whether the EDIT was well-formed; none of them asks whether the PROGRAM still
-- works. The suite does, and it is the only rung here that can fail for a reason the
-- analysis had no way to see.
if run_suite then
    local out = vim.fn.system({ 'bash', work .. '/tests/run.sh' })
    -- ⚠ READ THE SUMMARY LINE, NOT A MARKER GREP. The runner loses newlines and glues a
    -- FAIL onto the previous line, so counting '^  FAIL' UNDERCOUNTS — and a false zero
    -- here would report a broken tree as green.
    local passed, failed = out:match('(%d+) passed, (%d+) failed')
    if not failed then die('suite', 'could not read the suite summary line') end
    if tonumber(failed) ~= 0 then
        rung('suite', false, ('%s passed, %s failed'):format(passed, failed))
        -- ★ NAME THE BROKEN TESTS. "6 failed" sends you to run the suite again; the
        -- names say whether the fold broke THE FUNCTIONS IT FOLDED (the interesting
        -- case — the extraction is unsound) or something far away (the edit had a
        -- reach the analysis did not model). On the first real run it was the former.
        local seen = 0
        for name in out:gmatch('FAIL%s+([^\n]-)%s%s') do
            if seen < 12 then print('      broken: ' .. name) end
            seen = seen + 1
        end
        die('suite', 'the edited tree does not pass its own tests')
    end
    rung('suite', true, ('%s passed, %s failed'):format(passed, failed))
else
    rung('suite', true, 'SKIPPED (--no-suite) — this run does not claim the tree works')
end

print(('\n%d fold(s) applied:'):format(applied))
for _, l in ipairs(log) do
    print(('  %-44s net %+d  -> %s'):format(l.key, l.net, tostring(l.helper)))
end
print(('near-clone pairs %d -> %d'):format(before_pairs, prev_pairs))
print('work tree kept at ' .. work)

local bad = 0
for _, r in ipairs(rungs) do if not r.ok then bad = bad + 1 end end
print('\nSELFREFACTOR: ' .. (bad == 0 and 'PASS' or 'FAIL'))
os.exit(bad == 0 and 0 or 1)
