-- CART-1005: the inverse of an extraction, read off its record.
--
-- ★★★ THE ACCEPTANCE TEST IS A ROUND TRIP, NOT A SHAPE CHECK. `planundo_spec` already
-- pins that the record has the right fields; a field list is a claim about the RECORD, and
-- what needs proving is a claim about the TREE — extract, apply, invert, apply, and read
-- what came back. That is also what caught the record carrying half the correspondence:
-- every field was present and the arity was wrong.
--
-- ⚠ AND THE EXPECTATION IS NOT "THE ORIGINAL FILE". The helper wears the DONOR site's
-- local names, so the donor comes back byte-identical and the other site comes back
-- alpha-equivalent. A test asserting byte equality on both would be asserting something
-- the verb does not claim — see the module header.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'
local cx = require 'cartograph.cloneextract'
local txn = require 'cartograph.txn'
local inv = require 'cartograph.invert'

local function ready()
    return pcall(vim.treesitter.language.add, 'lua')
end
local function proj(src)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src); fd:close()
    store.ingest(ts.extract(root)); return root
end
local function fid(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name and n.name:match('[%w_]+$') == name
            and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end

-- two bodies differing in ONE literal, with DIFFERENT parameter names and DIFFERENT local
-- names — the shape that made the half-record visible
local PAIR = 'local M = {}\n\nlocal function fmt_a(x)\n  local y = prep(x)\n  local z = norm(y)\n'
    .. "  local w = encode(z, 'json')\n  local o = wrap(w)\n  return o\nend\n\n"
    .. 'local function fmt_b(a)\n  local b = prep(a)\n  local c = norm(b)\n'
    .. "  local d = encode(c, 'yaml')\n  local e = wrap(d)\n  return e\nend\n\nreturn M\n"

--- extract the pair and apply it; returns the journal entry (or nil)
local function folded(src, aname)
    local root = proj(src or PAIR)
    local p = clones.near_of(store, fid(aname or 'fmt_a'),
        { max_dist = 2, min_rows = 4, min_shared = 3 })[1]
    if not p then return nil, root, 'the fixture is not a near pair' end
    local plan, why = cx.plan(store, p)
    if not plan then return nil, root, 'it does not plan: ' .. tostring(why) end
    local entry, awhy = txn.apply(store, plan)
    if not entry then return nil, root, 'it does not apply: ' .. tostring(awhy) end
    return entry, root
end

test('★★★ the round trip: extract, invert, and the relation comes back', function ()
    if not ready() then return end
    local entry, root, bad = folded()
    ok(entry, tostring(bad))
    if not entry then return end

    local plan, why = inv.of(store, entry)
    ok(plan, 'the entry inverts: ' .. tostring(why))
    if not plan then return end
    eq('inline-helper', plan.verb)
    eq(2, plan.nsites)
    ok(plan.nsubs >= 4, 'every parameter occurrence at every site: ' .. tostring(plan.nsubs))
    eq(true, plan.removed_helper)

    local _, after, dwhy = inv.preview(store, plan)
    ok(after, 'it previews: ' .. tostring(dwhy))
    if not after then return end
    local got = after['m.lua']

    -- ★ THE HELPER IS GONE and nothing calls it
    eq(nil, got:match('fmt_a_extracted'))
    -- ★ THE DONOR COMES BACK BYTE-IDENTICAL: its names ARE the helper's names
    ok(got:match("local function fmt_a%(x%)\n  local y = prep%(x%)\n  local z = norm%(y%)\n"
        .. "  local w = encode%(z, 'json'%)"), 'donor restored exactly:\n' .. got)
    -- ★★★ AND THE OTHER SITE COMES BACK ALPHA-EQUIVALENT, WHICH IS WHAT IS CLAIMED.
    -- `fmt_b`'s parameter `a` survives (it is the site's own), its LOCALS do not.
    ok(got:match("local function fmt_b%(a%)\n  local y = prep%(a%)"),
        'the parameter is the site\'s, the locals are the helper\'s:\n' .. got)
    ok(got:match("encode%(z, 'yaml'%)"), 'and the divergence went back where it came from')

    -- ★★ AND EVERY NAME STILL MEANS WHAT IT MEANT (CART-1038): the splice declared where each
    -- byte came from, so every reference in the two new bodies pairs with its source — none
    -- is left unchecked, and none was re-pointed
    local row
    for _, r in ipairs(plan.guard_verdicts or {}) do
        if r.guard == 'bindings-preserved' then row = r end
    end
    ok(row, 'the plan declares the binding guard and the preview ran it')
    if not row then return end
    eq('pass', row.verdict)
    eq(nil, row.unchecked)
    ok(row.counts and row.counts.kept > 0, 'and it paired references: ' .. vim.inspect(row.counts))
end)

test('the inverse applies, and the tree is left without the abstraction', function ()
    if not ready() then return end
    local entry, root, bad = folded()
    ok(entry, tostring(bad))
    if not entry then return end
    local plan = inv.of(store, entry)
    if not plan then return end
    local e2, why = txn.apply(store, plan)
    ok(e2, 'the inverse applies: ' .. tostring(why))
    if not e2 then return end
    local text = txn.read_file(root, 'm.lua')
    eq(nil, text:match('fmt_a_extracted'))
    ok(text:match('local function fmt_a') and text:match('local function fmt_b'),
        'both sites are whole again:\n' .. text)
    -- ★ THE INVERSE'S OWN INVERSE: removing the helper is destructive, so it declares the
    -- other shape — and `journal.recover` resolves it without knowing which verb wrote it.
    eq('removed', e2.undo and e2.undo.kind)
    local back = require('cartograph.journal').recover(e2)
    ok(back, 'and the helper is recoverable from the bytes the entry kept')
    if back then
        ok(table.concat(back[1].lines, '\n'):match('fmt_a_extracted'), 'by name')
    end
end)

test('★★★ the claim is the forward claim, and DRIFT downgrades it rather than refusing',
    function ()
        if not ready() then return end
        local entry, root, bad = folded()
        ok(entry, tostring(bad))
        if not entry then return end
        eq('all', inv.of(store, entry).preserves)

        -- edit the helper: one more statement, which no extraction wrote
        local text = txn.read_file(root, 'm.lua')
        local edited = text:gsub('(  local o = wrap%(w%)\n)', '%1  o = tidy(o)\n', 1)
        ok(edited ~= text, 'the fixture edit landed')
        local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(edited); fd:close()
        store.ingest(ts.extract(root))

        local plan, why = inv.of(store, entry)
        -- ⚠ IT STILL PLANS. That is the whole design decision: a late inverse exists so a
        -- helper that IMPROVED can push the improvement back to its sites.
        ok(plan, 'a drifted helper still inverts: ' .. tostring(why))
        if not plan then return end
        eq('unreviewed', plan.preserves)
        ok(plan.preserves_why:match('edited since'), plan.preserves_why)
        -- ⚠ AND THE TWO `unreviewed`s ARE DIFFERENT SENTENCES. A FAMILY fold inherits
        -- `unreviewed` from a forward verb that could not establish its own radius, with
        -- the helper untouched and every site still delegating — the same word for a
        -- different gap, and a reviewer sent to the wrong one wastes the review.
        eq(nil, plan.preserves_why:match('FORWARD fold claimed'))
        local _, after = inv.preview(store, plan)
        ok(after and after['m.lua']:match('o = tidy%(o%)'), 'and the new statement reaches BOTH sites')
    end)

test('the helper stays when something outside the recorded sites calls it', function ()
    if not ready() then return end
    local entry, root, bad = folded()
    ok(entry, tostring(bad))
    if not entry then return end
    local text = txn.read_file(root, 'm.lua')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    -- ⚠ THE PARENTHESES ARE LOAD-BEARING. `gsub` returns (string, count) and `write`
    -- takes varargs, so the unparenthesised form appends the replacement COUNT to the
    -- file — which then fails to parse, and the refusal you get back is about the scope
    -- graph. Seventh sighting of this family in this arc.
    fd:write((text:gsub('\nreturn M\n',
        "\nlocal function third(q)\n  return fmt_a_extracted(q, 'toml')\nend\n\nreturn M\n")))
    fd:close()
    store.ingest(ts.extract(root))

    local plan, why = inv.of(store, entry)
    ok(plan, 'it still inverts the sites it recorded: ' .. tostring(why))
    if not plan then return end
    -- ★ INLINING THE RECORDED SITES IS STILL LEGAL; DELETING THE HELPER IS NOT, and the
    -- plan says which caller stopped it rather than reporting a bare `false`.
    eq(false, plan.removed_helper)
    ok(plan.kept_because and #plan.kept_because >= 1, 'it names the caller')
    local _, after = inv.preview(store, plan)
    ok(after and after['m.lua']:match('local function fmt_a_extracted'), 'the helper survives')
end)

test('★★★ a FAMILY fold inverts over N sites, and its `unreviewed` names the FOLD\'s gap',
    function ()
        if not ready() then return end
        local L = { 'local M = {}' }
        for _, t in ipairs({ { 'a', "'string'" }, { 'b', "'number'" }, { 'c', "'table'" } }) do
            L[#L + 1] = ('local function fam_%s(items)'):format(t[1])
            L[#L + 1] = '  local out = {}'
            L[#L + 1] = '  for _, it in ipairs(items) do'
            L[#L + 1] = ('    if type(it) == %s then out[#out + 1] = it end'):format(t[2])
            L[#L + 1] = '  end'
            L[#L + 1] = '  table.sort(out)'
            L[#L + 1] = '  return out'
            L[#L + 1] = 'end'
        end
        L[#L + 1] = 'return { fam_a, fam_b, fam_c, M }'
        proj(table.concat(L, '\n') .. '\n')
        local fam = clones.family_of(store, fid('fam_a'), {})
        ok(fam, 'the fixture is a family')
        if not fam then return end
        local plan, why = cx.plan_family(store, fam, {})
        ok(plan, 'it plans: ' .. tostring(why))
        if not plan then return end
        -- ★★★ THE FAMILY PLANNER DECLARED NO RECORD AT ALL until CART-1005, and it is the
        -- ONLY extraction verb on the MCP write axis — so that interface could not produce
        -- an invertible transaction. The record needed no new shape: `sites` was a list.
        eq('relation', plan.undo and plan.undo.kind)
        eq(3, #plan.undo.sites)
        local entry = txn.apply(store, plan)
        ok(entry, 'the family fold applies')
        if not entry then return end

        local ip, iwhy = inv.of(store, entry)
        ok(ip, 'the family fold inverts: ' .. tostring(iwhy))
        if not ip then return end
        eq(3, ip.nsites)
        eq(true, ip.removed_helper)
        -- ⚠ INHERITED, NOT EARNED, AND THE SENTENCE SAYS WHOSE GAP IT IS. `plan_family`
        -- claims `unreviewed` because family_admissibility carries no per-hole purity; the
        -- SPLICE here is established and the FOLD was not.
        eq('unreviewed', ip.preserves)
        ok(ip.preserves_why:match('FORWARD fold claimed'), ip.preserves_why)
        ok(ip.preserves_why:match('splice itself is established'), ip.preserves_why)
        local _, after = inv.preview(store, ip)
        ok(after and after['m.lua']:match("type%(it%) == 'table'"),
            'and every member gets its own filling back')
    end)

-- ── THE REFUSALS, EACH BY NAME ──────────────────────────────────────────────

test('invert refuses by name on the entry itself', function ()
    if not ready() then return end
    local r, w = inv.of(nil, nil); eq(nil, r); ok(w:match('not a journal entry'), w)
    r, w = inv.of(nil, { id = 'x' }); eq(nil, r); ok(w:match('carries no undo record'), w)
    r, w = inv.of(nil, { id = 'x', undo = { kind = 'removed' } })
    eq(nil, r); ok(w:match('not a relation') and w:match('journal.recover'), w)
    -- ★ A PENDING ENTRY IS NOT AN APPLIED ONE. Inverting a write that never landed would
    -- delete a helper the tree does not have.
    r, w = inv.of(nil, { id = 'x', status = 'pending',
        undo = { kind = 'relation', file = 'm.lua', params = {}, sites = {} } })
    eq(nil, r); ok(w:match('not applied'), w)
end)

test('★★★ a record that predates the full correspondence refuses, and says so', function ()
    if not ready() then return end
    local entry, root, bad = folded()
    ok(entry, tostring(bad))
    if not entry then return end
    -- exactly what yesterday's record looked like: the synthetic parameters only
    local short = vim.deepcopy(entry)
    table.remove(short.undo.params, 1)
    for _, s in ipairs(short.undo.sites) do table.remove(s.args, 1) end
    local r, w = inv.of(store, short)
    eq(nil, r)
    ok(w:match('takes 2 parameter') and w:match('describes 1'), w)
    ok(w:match('CART%-1005'), 'and it names the change that fixed it: ' .. w)
end)

test('a renamed or removed helper refuses, and a site that stopped delegating refuses',
    function ()
        if not ready() then return end
        local entry, root, bad = folded()
        ok(entry, tostring(bad))
        if not entry then return end

        local gone = vim.deepcopy(entry); gone.undo.helper = 'not_here_at_all'
        local r, w = inv.of(store, gone)
        eq(nil, r); ok(w:match('no longer defined'), w)

        -- ★★★ THE RECORDED ARGUMENTS ARE A WITNESS: change what the site passes and the
        -- record stops describing the tree, so the inverse refuses rather than putting
        -- back a body nobody asked for.
        local text = txn.read_file(root, 'm.lua')
        local fd = assert(io.open(root .. '/m.lua', 'w'))
        fd:write((text:gsub("fmt_a_extracted%(a, 'yaml'%)", "fmt_a_extracted(a, other())")))
        fd:close()
        store.ingest(ts.extract(root))
        local r2, w2 = inv.of(store, entry)
        eq(nil, r2); ok(w2:match('no longer delegates'), tostring(w2))
    end)

test('★★★ a HELPER name that means something else at the site fails the binding guard', function ()
    if not ready() then return end
    -- the helper reads the GLOBAL `prep`; a `local prep` declared after the helper and
    -- before the sites means the inlined `prep(...)` would read the local. No argument is
    -- involved, so the name-set capture check (arguments vs body binders) cannot see it.
    local entry, root, bad = folded()
    ok(entry, tostring(bad))
    if not entry then return end
    local text = txn.read_file(root, 'm.lua')
    local edited = text:gsub('\nlocal function fmt_a%(', "\nlocal prep = require('other')\n\nlocal function fmt_a(", 1)
    ok(edited ~= text, 'the fixture edit landed')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(edited); fd:close()
    store.ingest(ts.extract(root))

    local plan, why = inv.of(store, entry)
    ok(plan, 'it still PLANS — the check is on the result: ' .. tostring(why))
    if not plan then return end
    inv.preview(store, plan)
    local row
    for _, r in ipairs(plan.guard_verdicts or {}) do
        if r.guard == 'bindings-preserved' then row = r end
    end
    ok(row, 'the preview ran the binding guard')
    if not row then return end
    eq('fail', row.verdict)
    ok(row.why:match('`prep`') and row.why:match('moved there from'), row.why)
    -- ★ AND THE PREVIEW SURFACES SAY SO, before the apply does
    local lines = require('cartograph.planguards').lines(plan.guard_verdicts)
    ok(lines[1]:match('1 failed') and lines[1]:match('the apply will REFUSE'), lines[1])
    ok(table.concat(lines, '\n'):match('guard `bindings%-preserved` FAILS on m.lua'), table.concat(lines, '\n'))
    -- and the write refuses on it
    local e2, awhy = txn.apply(store, plan)
    eq(nil, e2)
    ok(tostring(awhy):match('bindings%-preserved'), tostring(awhy))
end)

test('★★★ a substitution that would CAPTURE refuses, naming both halves', function ()
    if not ready() then return end
    -- site B's parameter is `y`, and the helper's body (side A's) declares `local y`.
    -- Substituting `x -> y` would make `local y = prep(y)` read the binding it creates.
    local SRC = 'local M = {}\n\nlocal function fmt_a(x)\n  local y = prep(x)\n  local z = norm(y)\n'
        .. "  local w = encode(z, 'json')\n  local o = wrap(w)\n  return o\nend\n\n"
        .. 'local function fmt_b(y)\n  local b = prep(y)\n  local c = norm(b)\n'
        .. "  local d = encode(c, 'yaml')\n  local e = wrap(d)\n  return e\nend\n\nreturn M\n"
    local entry, root, bad = folded(SRC)
    ok(entry, tostring(bad))
    if not entry then return end
    local r, w = inv.of(store, entry)
    eq(nil, r)
    ok(w and w:match('would capture'), tostring(w))
    ok(w and w:match('`y`'), 'and it names the colliding name: ' .. tostring(w))
end)

test('★★★ a parameter REBOUND inside the helper refuses — the name stops meaning it',
    function ()
        if not ready() then return end
        -- `local x = prep(x)` is legal Lua and it is the whole difficulty: after that line
        -- every `x` is the LOCAL, not the parameter. `boundat.uses` matches occurrences BY
        -- NAME — it is an index, not a resolver — so substituting the argument at all of
        -- them would rewrite the ones that stopped referring to the parameter.
        local SRC = 'local M = {}\n\nlocal function fmt_a(x)\n  local x = prep(x)\n'
            .. "  local z = norm(x)\n  local w = encode(z, 'json')\n  local o = wrap(w)\n"
            .. '  return o\nend\n\nlocal function fmt_b(q)\n  local q = prep(q)\n'
            .. "  local c = norm(q)\n  local d = encode(c, 'yaml')\n  local e = wrap(d)\n"
            .. '  return e\nend\n\nreturn M\n'
        local entry, root, bad = folded(SRC)
        ok(entry, tostring(bad))
        if not entry then return end
        local r, w = inv.of(store, entry)
        eq(nil, r)
        ok(w and w:match('is rebound as'), tostring(w))
        ok(w and w:match('rewrite the wrong one'), tostring(w))
    end)

test('a function-parameter fold refuses as a beta-reduction, not as a substitution',
    function ()
        if not ready() then return end
        local fake = { id = 'x', status = 'applied', undo = { kind = 'relation',
            helper = 'h', file = 'm.lua', params = { 'p' }, nfparams = 1,
            sites = { { file = 'm.lua', name = 'one', args = { 'q' } } } } }
        local r, w = inv.of(store, fake)
        eq(nil, r); ok(w:match('beta%-reduction'), w)
    end)

test('a cross-file extraction refuses, naming what the inverse would also have to do',
    function ()
        if not ready() then return end
        local fake = { id = 'x', status = 'applied', undo = { kind = 'relation',
            helper = 'h', file = 'lib/h.lua', params = {}, nfparams = 0,
            sites = { { file = 'm.lua', name = 'one', args = {} } } } }
        local r, w = inv.of(store, fake)
        eq(nil, r)
        ok(w:match('remove the import'), w)
    end)

test('of_last finds the newest relation entry and does not fall back past it', function ()
    if not ready() then return end
    local entry, root, bad = folded()
    ok(entry, tostring(bad))
    if not entry then return end
    local plan, why = inv.of_last(store)
    ok(plan, 'it finds the fold just applied: ' .. tostring(why))
    if plan then eq(entry.id, plan.from_entry) end
end)
