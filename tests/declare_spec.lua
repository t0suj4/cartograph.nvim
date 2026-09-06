-- declare: add a member to a declared container (CART-0766 step D).
-- CART-0763 measured why this verb and not another: a day's real work was 15
-- commits, ZERO file moves, diffs shaped +158/-0 and +130/-1. The work is
-- INSERTION, and the shipped verbs modelled moving symbols and hoisting
-- loop-invariants — so none of it could have gone through the write ladder
-- however reliable that ladder became.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local txn = require 'cartograph.txn'
local declare = require 'cartograph.declare'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

local function ingest(src)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src); fd:close()
    store.ingest(ts.extract(root))
    return store
end

local function var_named(st, name)
    for _, n in ipairs(st.data.nodes) do
        if n.name == name and n.kind == 'var' then return n end
    end
end

-- the resulting file text, without writing anything
local function after_text(st, plan)
    local _, after = txn.dryrun(st, plan, declare.edits_for(plan))
    return after and after['m.lua']
end

local COMPACT = "local SOLE_WRAP = { argument = true, condition_clause = true }\nreturn SOLE_WRAP\n"

test('declare: a TEXTUAL insert places the member and keeps the file parsing', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(COMPACT)
    local v = var_named(st, 'SOLE_WRAP')
    if not v then skip('no var node') end
    local plan, why = declare.plan(st, { node = v.id, member = 'subscript_list = true' })
    ok(plan, 'planned: ' .. tostring(why))
    local out = after_text(st, plan)
    ok(out:find('subscript_list = true', 1, true), 'the member is there: ' .. tostring(out))
    ok(out:find('condition_clause = true, subscript_list = true', 1, true),
        'placed after the LAST member, before the closing brace: ' .. out)
end)

-- ★★ THE SEPARATOR IS SLICED FROM BETWEEN THE FIRST TWO MEMBERS, never guessed.
-- The obvious idea — copy the donor's whole LINE — was killed by measurement:
-- one-member-per-line is 87% of php containers and only 12% of lua's, so a
-- layout rule would be wrong for whichever language it was not written for.
test('declare: the separator comes from the source, so both layouts work', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(table.concat({
        'local T = {',
        '    alpha = true,',
        '    beta = true,',
        '}',
        'return T',
    }, '\n'))
    local v = var_named(st, 'T')
    if not v then skip('no var node') end
    local plan, why = declare.plan(st, { node = v.id, member = 'gamma = true' })
    ok(plan, 'planned: ' .. tostring(why))
    local out = after_text(st, plan)
    ok(out:find('    beta = true,\n    gamma = true', 1, true),
        'one-per-line keeps its newline AND its indentation: ' .. out)
end)

test('declare: a STRUCTURAL insert fills the template holes from the donor', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(COMPACT)
    local v = var_named(st, 'SOLE_WRAP')
    if not v then skip('no var node') end
    local clones = require 'cartograph.clones'
    local text = txn.read_file(st.data.root, 'm.lua')
    -- the container's own template, whose holes are the varying positions
    local root_node = vim.treesitter.get_string_parser(text, 'lua'):parse()[1]:root()
    local expr = require 'cartograph.expr'
    local function find(n)
        if n:type() == 'table_constructor' then return n end
        for c in n:iter_children() do if c:named() then local r = find(c); if r then return r end end end
    end
    local t = clones.element_template(expr.build(find(root_node), text, 'lua'))
    local subs = {}
    for key in pairs(t.varying) do subs[key] = 'subscript_list' end
    local plan, why = declare.plan(st, { node = v.id, subs = subs })
    ok(plan, 'planned: ' .. tostring(why))
    ok(after_text(st, plan):find('subscript_list', 1, true), 'the hole was filled')
end)

-- ★ THE REFUSAL IS THE USEFUL ANSWER, and step B's machinery is what makes it
-- specific: a payload that does not fit comes back with the divergence named.
test('declare: a member of the wrong shape is REFUSED', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(COMPACT)
    local v = var_named(st, 'SOLE_WRAP')
    if not v then skip('no var node') end
    local plan, why = declare.plan(st, { node = v.id, member = "'a bare string'" })
    eq(nil, plan)
    ok(why and why:find('does not fit the ones already there'), tostring(why))
    -- ★ AND IT NAMES THE DIVERGENCE, which is what step B's calibrated vocabulary
    -- was for. The first cut rebuilt the template from the POST-insert container,
    -- so the bad member poisoned the template judging it and the answer came back
    -- "the members no longer share a shape" — true, and useless.
    ok(why:find('leaf%-vs%-tree') or why:find('size%-skew') or why:find('drift'),
        'the refusal carries a ranked feature, not just a verdict: ' .. why)
end)

-- ⚠ THE DOMINANT ANSWER: 70.6% of containers with 2+ members on our own tree
-- share NO shape, so this message matters more than the success path's.
test('declare: a container whose members share no shape is REFUSED, saying so', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest("local M = { a = 1, b = { x = 2 } }\nreturn M\n")
    local v = var_named(st, 'M')
    if not v then skip('no var node') end
    local plan, why = declare.plan(st, { node = v.id, member = 'c = 3' })
    eq(nil, plan)
    ok(why and why:find('do not share a shape'), tostring(why))
end)

test('declare: a single-member container is REFUSED — no template AND no separator', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest("local M = { only = true }\nreturn M\n")
    local v = var_named(st, 'M')
    if not v then skip('no var node') end
    local plan, why = declare.plan(st, { node = v.id, member = 'other = true' })
    eq(nil, plan)
    ok(why and why:find('separator'), tostring(why))
end)

-- ★★ THE LAW AS A DECLARED GUARD (CART-0769 inc 2): the write was authorised by
-- "this payload matches the container's element template", so after the write it
-- RE-DERIVES that fact. It is NOT step C's snippet check — a valid member with
-- the wrong separator passes that and fails this.
test('declare: the plan declares BOTH rungs, and shape-preserved re-derives', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(COMPACT)
    local v = var_named(st, 'SOLE_WRAP')
    if not v then skip('no var node') end
    local plan = declare.plan(st, { node = v.id, member = 'subscript_list = true' })
    if not plan then skip('could not plan') end
    eq('parses', plan.guards[1])
    eq('shape-preserved', plan.guards[2])
    ok(plan.shape and plan.shape.container_sl and plan.shape.container_sc,
        'and carries the POSITION to re-derive from — a line is ambiguous when containers nest')

    local pg = require 'cartograph.planguards'
    local before, after = txn.dryrun(st, plan, declare.edits_for(plan))
    local _, failed = pg.run(st, plan, before, after)
    eq(nil, failed, 'the real insert survives its own guard')

    -- and a shape-BREAKING after-text must fail it
    local broken = { ['m.lua'] = "local SOLE_WRAP = { argument = true, condition_clause = true, 'a bare string' }\nreturn SOLE_WRAP\n" }
    local rows = pg.GUARDS['shape-preserved'](st, plan, before, broken)
    eq(pg.FAIL, rows[1].verdict,
        'a member that parses but does not fit the container is caught: ' .. tostring(rows[1].why))
end)

-- ★★ THE CONTAINER IS ADDRESSED BY EXACT POSITION, NOT BY LINE, and this fixture
-- exists because REVERT-AND-RERUN FOUND IT MISSING: weakening the check to the
-- line alone broke nothing in the suite while the corpus oracle had caught it
-- immediately. A guard proven only by a corpus run is not guarded in CI.
-- Containers NEST and one line can begin two of them, so a line-addressed search
-- returns the OUTERMOST and judges a container that was never edited — which is
-- how one root cause surfaced as three unrelated-looking failure classes.
test('declare: verify addresses the container by POSITION, not by line', function ()
    if not ready() then skip('no lua parser') end
    -- two containers start on line 0: the outer at col 10, the inner at col 12
    local text = 'local T = { { a = 1, b = 2, c = 3 }, { a = 4, b = 5 } }\nreturn T\n'
    local ok_inner, why = declare.verify(text, 'lua', 0, 12)
    eq(true, ok_inner, 'the INNER container is well-shaped: ' .. tostring(why))
    -- and the OUTER genuinely is not, which is what makes the two distinguishable:
    -- its last member has fewer fields than the first
    local ok_outer = declare.verify(text, 'lua', 0, 10)
    eq(false, ok_outer, 'so resolving to the wrong one cannot pass by accident')
end)
