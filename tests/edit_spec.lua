-- THE GROUND EDIT (CART-1182, the floor): before -> after at one site, IDEMPOTENT by classifying the current state
-- against BOTH images. The oracle is the disk after each run and the run's own status: a re-run is empty and writes
-- nothing; a text that is neither the pre- nor the post-state is refused by name, never guessed at.
local E = require 'cartograph.edit'
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local tactic = require 'cartograph.tactic'
local T = tactic.T

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') end

test('edit.classify: pending / done / drifted — and CONTAINMENT decides which image is the witness', function ()
    -- a plain replace
    eq('pending', (E.classify('a = 1\nb = 2\n', 'a = 1', 'a = 9')))
    eq('done', (E.classify('a = 9\nb = 2\n', 'a = 1', 'a = 9')))
    -- APPEND: `before` survives inside `after`; judged by `after` first, or the re-run would insert again
    eq('pending', (E.classify('x\nz\n', 'x\n', 'x\ny\n')))
    eq('done', (E.classify('x\ny\nz\n', 'x\n', 'x\ny\n')), 'the appended state is DONE, although `before` is still there')
    -- DELETE-PART: `after` is present in both states; judged by `before`
    eq('pending', (E.classify('x\ny\n', 'x\ny\n', 'x\n')))
    eq('done', (E.classify('x\n', 'x\ny\n', 'x\n')))
    -- a pure delete
    eq('pending', (E.classify('keep\ndrop\n', 'drop\n', '')))
    eq('done', (E.classify('keep\n', 'drop\n', '')))
    -- CREATE
    eq('pending', (E.classify(nil, '', 'new\n')))
    eq('done', (E.classify('new\n', '', 'new\n')))
    local s, why = E.classify('other\n', '', 'new\n'); eq('drifted', s); ok(why:find('never overwrites', 1, true), why)
    -- DRIFTED, each by name
    local s1, w1 = E.classify('a = 1\na = 1\n', 'a = 1', 'a = 9'); eq('drifted', s1); ok(w1:find('2 times', 1, true), w1)
    local s2, w2 = E.classify('q = 0\n', 'a = 1', 'a = 9'); eq('drifted', s2); ok(w2:find('neither', 1, true), w2)
    -- ★ a COINCIDENTAL result elsewhere is not "done": both occur -> drifted, asking for context
    local s3, w3 = E.classify('a = 1\n-- a = 9 in the docs\n', 'a = 1', 'a = 9'); eq('drifted', s3); ok(w3:find('coincidental', 1, true), w3)
    local s4 = E.classify(nil, 'a = 1', 'a = 9'); eq('drifted', s4)
end)

test('edit.classify with a COUNT (CART-1486): exactly n sites pending, all n replaced, the result done — for a replacement, an insert and a deletion; a count off either way is drifted by its number', function ()
    local function check(text, before, after)
        eq('pending', E.classify(text, before, after, 2))
        local out = E.apply_to(text, before, after, 2)
        eq('done', (E.classify(out, before, after, 2)), out)
        eq(out, E.apply_to(out, before, after, 2), 'applying again changes nothing')
        local s1, w1 = E.classify(text, before, after, 3)
        eq('drifted', s1); ok(w1:find('count = 3 expected', 1, true), w1)
        local s2 = E.classify(text, before, after, 1)
        eq('drifted', s2)
        return out
    end
    eq('a = 2\nb = 2\n', check('a = 1\nb = 1\n', '= 1', '= 2'))
    eq('f(x) -- seam\ng(x) -- seam\n', check('f(x)\ng(x)\n', '(x)', '(x) -- seam'))
    eq('f\ng\n', check('f(x)\ng(x)\n', '(x)', ''))
end)

test('edit through the runner: applied once, the RE-RUN is empty and writes nothing; a drifted file is refused by name', function ()
    if not ready() then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(t) local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(t); fd:close() end
    local function get() return io.open(root .. '/m.lua'):read('a') end
    put('local M = {}\nM.x = 1\nreturn M\n')
    store.ingest(ts.extract(root))
    local term = T.step('edit', { file = 'm.lua', before = 'M.x = 1\n', after = 'M.x = 1\nM.y = 2\n' })
    local r1 = tactic.run(store, term, { apply = true })
    eq('done', r1.status, tostring(r1.why)); eq(1, r1.applied)
    eq('local M = {}\nM.x = 1\nM.y = 2\nreturn M\n', get())
    local r2 = tactic.run(store, term, { apply = true })
    eq('done', r2.status); eq(0, r2.applied, 'an APPEND re-run is empty — the insert is not repeated')
    eq('local M = {}\nM.x = 1\nM.y = 2\nreturn M\n', get())
    -- someone changed the site: neither image is there -> stale, by name, nothing written
    put('local M = {}\nM.x = 5\nreturn M\n')
    local r3 = tactic.run(store, T.step('edit', { file = 'm.lua', before = 'M.x = 1', after = 'M.x = 2' }), { apply = true })
    eq('failed', r3.status); eq('stale', r3.class); ok(tostring(r3.why):find('neither', 1, true), tostring(r3.why))
    eq('local M = {}\nM.x = 5\nreturn M\n', get())
end)

test('edit: a DRY run previews through an overlay world (nothing on disk), and CREATE makes a new file once', function ()
    if not ready() then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/a.lua', 'w')); fd:write('return 1\n'); fd:close()
    store.ingest(ts.extract(root))
    local chain = T.seq(T.step('edit', { file = 'a.lua', before = 'return 1', after = 'return 2' }),
        T.step('edit', { file = 'b.lua', before = '', after = 'return 3\n' }))
    local dry = tactic.run(store, chain, { apply = false })
    eq('previewed', dry.status, tostring(dry.why)); eq(2, dry.worlds)
    eq('return 2\n', dry.preview['a.lua']); eq('return 3\n', dry.preview['b.lua'])
    eq('return 1\n', io.open(root .. '/a.lua'):read('a')); eq(nil, io.open(root .. '/b.lua'))
    local done = tactic.run(store, chain, { apply = true })
    eq('done', done.status, tostring(done.why)); eq(2, done.applied)
    eq('return 3\n', io.open(root .. '/b.lua'):read('a'))
    eq(0, tactic.run(store, chain, { apply = true }).applied, 'the whole chain re-runs empty')
end)
