-- annotate: attach prose to a definition (CART-0780). The verb CART-0763's own
-- metric asked for, re-run over 24 commits: comment prose is 1171 of 2334 added
-- lua/ lines (50.2%) against the table-member case `declare` was built for (106,
-- 4.5%). The diagnosis "the work is INSERTION" was right; the specialisation was
-- eleven times too narrow.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local txn = require 'cartograph.txn'
local annotate = require 'cartograph.annotate'
local pg = require 'cartograph.planguards'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

local function ingest(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, src in pairs(files) do
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close()
    end
    store.ingest(ts.extract(root))
    return store, root
end

local function fn_id(st, name)
    for _, n in ipairs(st.data.nodes) do
        if n.name == name and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end

local WITH_COMMENT = '-- a module\nlocal function helper(x)\n    return x + 1\nend\nreturn helper\n'

local function after_of(st, plan)
    local _, after = txn.dryrun(st, plan, annotate.edits_for(plan))
    return after and after['m.lua']
end

test('annotate: prose is attached above the definition, at its indentation', function ()
    if not ready() then return skip('no lua parser') end
    local st = ingest({ ['m.lua'] = WITH_COMMENT })
    local id = fn_id(st, 'helper')
    if not id then return skip('no node') end
    local plan, why = annotate.plan(st, { node = id, text = 'what it does\nand why' })
    ok(plan, 'planned: ' .. tostring(why))
    local out = after_of(st, plan)
    ok(out:find('-- what it does\n-- and why\n', 1, true), 'both lines, prefixed: ' .. out)
    ok(out:find('local function helper', 1, true), 'and the code survives')
end)

-- ★★ THE PREFIX IS SLICED FROM A REAL COMMENT, NEVER DECLARED. A per-language
-- table of `--` / `//` / `#` is wrong the first time it meets a docblock or a
-- block comment, and every language needs an entry before the verb works there.
test('annotate: the comment prefix comes from the file, not from a table', function ()
    if not ready() then return skip('no lua parser') end
    -- a file whose only comment style is a doubled dash with no space
    local st = ingest({ ['m.lua'] = '--sparse\nlocal function f() return 1 end\nreturn f\n' })
    local id = fn_id(st, 'f')
    if not id then return skip('no node') end
    local plan = annotate.plan(st, { node = id, text = 'note' })
    ok(plan, 'planned')
    ok(after_of(st, plan):find('-- note', 1, true), 'the sliced prefix is used')
end)

-- ★ THE DONOR IS THE PROJECT, NOT ONLY THE FILE — measured: files holding a
-- definition that also hold a comment are 100% on our tree, 93.8% on desynced
-- and only 59.9% on grocy. File-only slicing would refuse 40% of grocy.
test('annotate: a file with NO comment borrows the style, and discloses it', function ()
    if not ready() then return skip('no lua parser') end
    local st = ingest({
        ['m.lua'] = 'local function bare() return 1 end\nreturn bare\n',
        ['other.lua'] = '-- style lives here\nlocal function o() return 2 end\nreturn o\n',
    })
    local id = fn_id(st, 'bare')
    if not id then return skip('no node') end
    local plan, why = annotate.plan(st, { node = id, text = 'note' })
    ok(plan, 'planned: ' .. tostring(why))
    ok(plan.donor and plan.donor ~= 'm.lua', 'the donor is another file: ' .. tostring(plan.donor))
    ok(#plan.hazards > 0 and plan.hazards[1]:find('style'),
        'and the borrowing is DISCLOSED rather than silent: ' .. tostring(plan.hazards[1]))
end)

-- ★★★ THE GUARD `parses` CANNOT PROVIDE — tested on its OWN terms, because the
-- verb can no longer produce the hazard. A first version of this test fed the
-- verb `'oops --[['` and asserted the guard caught it; the guard returned PASS,
-- and it was RIGHT: in lua `-- oops --[[` is an ordinary line comment, since a
-- long comment needs `--[[` at the comment's start. The escape is designed out —
-- the prefix is VALIDATED and every line is prefixed — so `comment-inert` is a
-- backstop here rather than the primary barrier.
-- ⚠ AND A GUARD THAT CANNOT BE MADE TO FIRE IS A GUARD NOBODY HAS TESTED. So it
-- is driven directly with an after-text whose CODE changed, which is the claim it
-- actually makes and the one a future prefix or language could break.
test('annotate: comment-inert FAILS when the code changed, not just the comments', function ()
    if not ready() then return skip('no lua parser') end
    local st = ingest({ ['m.lua'] = WITH_COMMENT })
    local plan = { touched = { 'm.lua' } }
    local before = { ['m.lua'] = WITH_COMMENT }
    -- comments differ AND the code is identical: inert
    local inert = { ['m.lua'] = '-- a DIFFERENT comment\nlocal function helper(x)\n    return x + 1\nend\nreturn helper\n' }
    eq(pg.PASS, pg.GUARDS['comment-inert'](st, plan, before, inert)[1].verdict,
        'changing only prose is inert')
    -- one token of code changed, everything else identical: NOT inert
    local moved = { ['m.lua'] = '-- a module\nlocal function helper(x)\n    return x + 2\nend\nreturn helper\n' }
    local rows = pg.GUARDS['comment-inert'](st, plan, before, moved)
    eq(pg.FAIL, rows[1].verdict, 'a changed literal is caught: ' .. tostring(rows[1].why))
end)

-- ★★ AND THIS IS WHAT ACTUALLY PROTECTS THE VERB: the candidate list is
-- DELIBERATELY PERMISSIVE and the discrimination happens by TRYING THE REAL EDIT.
-- `^(%p+)` slices `--[[` from a one-line block comment quite happily; what
-- rejects it is that the actual prose block, at the actual insertion point,
-- changes the code. A first cut validated a ONE-LINE PROBE at LINE 1 instead and
-- ACCEPTED `--[[`, because the existing comment's `]]` closed it — inert by
-- accident of position. A PROBE IS NOT THE EDIT.
test('annotate: a bad prefix is OFFERED as a candidate and rejected by the trial', function ()
    if not ready() then return skip('no lua parser') end
    local st = ingest({
        ['m.lua'] = '--[[ the only comment here ]]\nlocal function b() return 1 end\nreturn b\n',
        ['other.lua'] = '-- an honest line comment\nlocal function o() return 2 end\nreturn o\n',
    })
    local id = fn_id(st, 'b')
    if not id then return skip('no node') end
    local cands = annotate.prefix_candidates(st, 'm.lua', 'lua')
    local offered = {}
    for _, c in ipairs(cands) do offered[c.prefix] = true end
    ok(offered['--[['], 'the block opener IS offered — the list does not pre-judge')
    local plan = annotate.plan(st, { node = id, text = 'note' })
    ok(plan and plan.prefix == '--', 'and the trial picks a prefix that is inert: '
        .. tostring(plan and plan.prefix))
end)

test('annotate: an honest annotation passes BOTH guards', function ()
    if not ready() then return skip('no lua parser') end
    local st = ingest({ ['m.lua'] = WITH_COMMENT })
    local id = fn_id(st, 'helper')
    if not id then return skip('no node') end
    local plan = annotate.plan(st, { node = id, text = 'plain prose' })
    local before, after = txn.dryrun(st, plan, annotate.edits_for(plan))
    local _, failed = pg.run(st, plan, before, after)
    eq(nil, failed, failed and failed.why or '')
    eq('parses', plan.guards[1]); eq('comment-inert', plan.guards[2])
end)

test('annotate: no prose is a refusal by name', function ()
    if not ready() then return skip('no lua parser') end
    local st = ingest({ ['m.lua'] = WITH_COMMENT })
    local id = fn_id(st, 'helper')
    if not id then return skip('no node') end
    local plan, why = annotate.plan(st, { node = id, text = '   ' })
    eq(nil, plan)
    ok(why:find('no prose'), tostring(why))
end)

-- ★ AND THE VALIDATOR MUST BE REACHED, not merely correct. A first pass tested
-- `prefix_comments_out` directly, so disabling its CALL SITE broke nothing —
-- the same "guard proven in isolation, its use unguarded" gap that a corpus
-- oracle caught in `declare`. This drives it through `plan`: a file whose only
-- comment is a one-line BLOCK comment yields the candidate prefix `--[[`, which
-- would open a long comment and swallow the file. Validated, it is rejected and
-- the style is borrowed instead.
test('annotate: a one-line BLOCK comment is not accepted as a line prefix', function ()
    if not ready() then return skip('no lua parser') end
    local st = ingest({
        ['m.lua'] = '--[[ the only comment here ]]\nlocal function b() return 1 end\nreturn b\n',
        ['other.lua'] = '-- an honest line comment\nlocal function o() return 2 end\nreturn o\n',
    })
    local id = fn_id(st, 'b')
    if not id then return skip('no node') end
    local plan, why = annotate.plan(st, { node = id, text = 'note' })
    ok(plan, 'planned: ' .. tostring(why))
    eq('other.lua', plan.donor,
        'the block comment was refused as a prefix, so the style came from elsewhere')
    ok(after_of(st, plan):find('-- note', 1, true), 'and the borrowed prefix is used')
end)

-- ⚠⚠ A SHEBANG IS A COMMENT TO THE GRAMMAR AND A KERNEL DIRECTIVE TO THE OS.
-- MEASURED: ruby, python and bash all parse `#!/usr/bin/env x` as a `comment`
-- node — `is_comment` returns TRUE — while LUA ALONE gives it its own
-- `hash_bang_line`. So it is offered as a style donor and `^(%p+)` runs across
-- all three characters to yield `#!/`. The trap is that `#!/ note` is STILL A
-- VALID COMMENT, so the inertness trial ACCEPTS it: neither guard can see the
-- problem, because the code is unchanged and every comment is a comment.
--
-- ★★ THESE TWO TESTS ARE IN PYTHON ON PURPOSE. A first version wrote them in lua
-- and BOTH PASSED WITH THE GUARDS REMOVED — lua is the one language where the
-- hazard does not exist, so the fixtures proved nothing. Testing in the
-- convenient language instead of the affected one is how a guard ships untested.
local function py_ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'python')
end

test('annotate: a shebang is never taken as a comment style (python)', function ()
    if not py_ready() then return skip('no python parser') end
    local st = ingest({
        ['m.py'] = '#!/usr/bin/env python\ndef f():\n    return 1\n',
        ['other.py'] = '# an honest comment\ndef o():\n    return 2\n',
    })
    local offered = {}
    for _, c in ipairs(annotate.prefix_candidates(st, 'm.py', 'python')) do
        offered[c.prefix] = c.donor
    end
    eq(nil, offered['#!/'], 'the shebang is not offered as a donor')
    eq('other.py', offered['#'], 'so the style is borrowed from a real comment')
end)

-- ★ THIS ONE GUARDS A NEIGHBOUR'S INVARIANT, NOT THIS VERB'S CODE, and that is
-- why it survives every break of `annotate`. A clamp WAS written here and
-- measured DEAD: `attach_above` already declines any adhered block reaching the
-- TOP OF THE FILE — a rule written for license notices — so a walk that would
-- reach a line-1 shebang is refused before it gets there. The clamp went; the
-- test stays, because the day that rule is refactored for an unrelated reason,
-- this is what notices the shebang consequence.
test('annotate: prose never lands above a shebang (python)', function ()
    if not py_ready() then return skip('no python parser') end
    local st = ingest({
        ['m.py'] = '#!/usr/bin/env python\n# doc\ndef f():\n    return 1\n',
        ['other.py'] = '# an honest comment\ndef o():\n    return 2\n',
    })
    local id = fn_id(st, 'f')
    if not id then return skip('no python function node') end
    local plan, why = annotate.plan(st, { node = id, text = 'note' })
    ok(plan, 'planned: ' .. tostring(why))
    local _, after = txn.dryrun(st, plan, annotate.edits_for(plan))
    local out = after['m.py']
    eq('#!/usr/bin/env python', vim.split(out, '\n', { plain = true })[1],
        'the shebang is still line 1: ' .. out)
    ok(out:find('# note', 1, true), 'and the prose landed somewhere')
end)
