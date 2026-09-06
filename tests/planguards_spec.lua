-- planguards: the obligations a write plan DECLARES and the driver RUNS
-- (CART-0769). A guard is not a verb — a verb is something a caller chooses to
-- call, so a guard that is a verb is a guard a caller can skip, and the safety
-- property moves back into the caller's discipline. The precedent is `edit_of`
-- (CART-0375): a caller holding a plan could not run it without knowing which
-- module built it, and the same sentence was true of guards until now.

local pg = require 'cartograph.planguards'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local txn = require 'cartograph.txn'
local moveapply = require 'cartograph.moveapply'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

local function verdicts_by_file(rows)
    local m = {}
    for _, r in ipairs(rows) do m[r.file or '?'] = r end
    return m
end

test('planguards: a clean edit PASSES', function ()
    if not ready() then skip('no lua parser') end
    local rows = pg.GUARDS.parses(nil, nil,
        { ['a.lua'] = 'local x = 1\n' }, { ['a.lua'] = 'local x = 2\n' })
    eq(1, #rows)
    eq(pg.PASS, rows[1].verdict)
end)

test('planguards: an edit that breaks the file FAILS, naming the file', function ()
    if not ready() then skip('no lua parser') end
    local rows = pg.GUARDS.parses(nil, nil,
        { ['a.lua'] = 'local x = 1\n' }, { ['a.lua'] = 'local x = \n' })
    eq(pg.FAIL, rows[1].verdict)
    eq('a.lua', rows[1].file)
    rows[1].guard = 'parses'
    ok(pg.refusal(rows[1]):find('a.lua'),
        'the refusal names the guard AND the file — "it failed" is not actionable')
end)

-- ★★ THE THIRD VALUE IS THE ONE THAT MAKES THIS HONEST, and nothing else tests
-- it: "I did not check" must not render the same as "I checked and it was fine".
-- A `.vue`/`.svelte` file's parse_lang is `javascript` because the graph parses
-- its <script> BLOCKS, but the whole file has never been javascript. MEASURED on
-- this repo's own fixtures: the three shipped `parses_clean` copies all answer
-- REFUSE on App.vue / Board.svelte / Leaf.vue BEFORE ANY EDIT, so a verb editing
-- an SFC is permanently blocked by its own gate.
test('planguards: a file that did not parse BEFORE yields NO-CLAIM, not pass and not fail', function ()
    if not ready() then skip('no lua parser') end
    local sfc_before = '<template>\n  <em>{{ x }}</em>\n</template>\n<script>\nvar a = 1\n</script>\n'
    local sfc_after = '<template>\n  <em>{{ x }}</em>\n</template>\n<script>\nvar a = 2\n</script>\n'
    local rows = pg.GUARDS.parses(nil, nil,
        { ['C.vue'] = sfc_before }, { ['C.vue'] = sfc_after })
    local r = rows[1]
    eq(pg.NO_CLAIM, r.verdict,
        'not PASS (which would be a lie) and not FAIL (which would block every '
        .. 'SFC edit forever): ' .. tostring(r.verdict))
    ok(r.why and #r.why > 0, 'and it SAYS why it did not look: ' .. tostring(r.why))
    -- ⚠ TWO DIFFERENT ROUTES REACH NO-CLAIM HERE and the test accepts both,
    -- because which one fires is a property of the ENVIRONMENT, not of the
    -- guard: with a javascript parser present the file fails to parse BEFORE
    -- the edit (the container-format route); without one the guard cannot look
    -- at all. Both are honest and neither may render as PASS — that is the
    -- whole point of the third value. Pinning only one would make this test
    -- pass or fail on which parsers happen to be installed.
    ok(r.why:find('BEFORE the edit') or r.why:find('unavailable'),
        'by a named route, not a shrug: ' .. r.why)
end)

-- the delta form also means the guard never blocks an edit to an already-broken
-- file — additive, the same argument as moveapply's enclosing_syntax
test('planguards: an already-broken file is NO-CLAIM, so a repair is not blocked', function ()
    if not ready() then skip('no lua parser') end
    local rows = pg.GUARDS.parses(nil, nil,
        { ['a.lua'] = 'local x = \n' }, { ['a.lua'] = 'local x = \n' })
    eq(pg.NO_CLAIM, rows[1].verdict)
end)

test('planguards: a CREATED file must stand on its own', function ()
    if not ready() then skip('no lua parser') end
    local bad = pg.GUARDS.parses(nil, nil, { ['n.lua'] = false }, { ['n.lua'] = 'local x = \n' })
    eq(pg.FAIL, bad[1].verdict, 'no before-text means there is nothing to excuse it')
    local good = pg.GUARDS.parses(nil, nil, { ['n.lua'] = false }, { ['n.lua'] = 'local x = 1\n' })
    eq(pg.PASS, good[1].verdict)
end)

test('planguards: a plan naming an unregistered guard FAILS rather than skipping it', function ()
    local rows, failed = pg.run(nil, { verb = 'x', guards = { 'no-such-guard' } }, {}, {})
    ok(failed, 'a declared obligation nobody can meet is a refusal, not a pass')
    eq(pg.FAIL, rows[1].verdict)
end)

-- ── enforcement, through the real driver ────────────────────────────────────

local function ingest_files(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        local dir = (root .. '/' .. rel):match('^(.*)/[^/]*$')
        if dir then vim.fn.mkdir(dir, 'p') end
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    store.ingest(ts.extract(root))
    return store
end

local SRC = 'local function helper(x)\n    return x + 1\nend\nreturn { helper = helper }\n'

local function planned()
    local st = ingest_files({ ['m.lua'] = SRC })
    local h
    for _, n in ipairs(st.data.nodes) do
        if n.name == 'helper' and n.kind == 'function' then h = n end
    end
    if not h then return nil end
    return st, moveapply.plan_extract_ids(st, { h.id }, 'sub/h.lua')
end

-- ⚠ A MISSING GUARD LOOKED IDENTICAL TO A GUARD THAT PASSED, which is exactly
-- how moveapply and clonemerge came to write unparseable files while five
-- sibling verbs checked (CART-0770/0773). Silence is not "no obligations".
test('planguards: txn.execute REFUSES a plan that declares no guards', function ()
    if not ready() then skip('no lua parser') end
    local st, plan = planned()
    if not plan then skip('could not plan') end
    plan.guards = nil
    local entry, why = txn.execute(st, plan, 'test')
    eq(nil, entry)
    ok(why and why:find('declares no guards'), tostring(why))
end)

test('planguards: txn.execute REFUSES when a guard fails, and writes nothing', function ()
    if not ready() then skip('no lua parser') end
    local st, plan = planned()
    if not plan then skip('could not plan') end
    -- an edit callback that produces text the grammar rejects
    local entry, why = txn.execute(st, plan, 'test', function () return 'local x = \n' end)
    eq(nil, entry)
    ok(why and why:find('guard `parses` failed'), tostring(why))
    ok(why:find('%.lua'), 'and names the file: ' .. tostring(why))
end)

-- the preview COMPUTES the guards and does NOT refuse on them: seeing the broken
-- text is how you find out why, and `execute` is where the write happens
test('planguards: dryrun ATTACHES verdicts without refusing', function ()
    if not ready() then skip('no lua parser') end
    local st, plan = planned()
    if not plan then skip('could not plan') end
    local before, after = txn.dryrun(st, plan)
    ok(before and after, 'the preview still previews')
    ok(plan.guard_verdicts and #plan.guard_verdicts > 0, 'and carries what was checked')
    local m = verdicts_by_file(plan.guard_verdicts)
    ok(m['sub/h.lua'] or m['m.lua'], 'per FILE, not one verdict for the plan')
end)
