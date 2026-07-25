-- SCOPE-CONFINED CANDIDATES (store.mentioning_in / scope_axis / scopes) — step 3
-- of index-and-reduce. A demand query resolving a mention in file F does not need
-- every file mentioning N, only those in F's scope: that is the cut the id pass
-- already applies after gathering candidates (`L.scopes[u.file] ~= L.scopes[file]`
-- -> drop), moved into the lookup so the discarded ones are never loaded.
--
-- So the property under test is EQUALITY, not filtering: confinement must keep
-- exactly what the reduce would keep. Losing a candidate is the dangerous
-- direction — it reads as "nothing else mentions this" — so it gets its own test.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang)
end

local function put(root, rel, text)
    local dir = root .. '/' .. (rel:match('^(.*)/[^/]*$') or '')
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(root .. '/' .. rel, 'w'))
    fd:write(text)
    fd:close()
end

-- two ruby files, whose scope IS the file (ruby's spec returns `file`), so every
-- candidate set confines to exactly one file. `shared_helper` is mentioned in both.
local function ruby_corpus()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    put(root, 'alpha.rb', table.concat({
        'def shared_helper(x)',
        '  x + 1',
        'end',
        'def alpha_only(x)',
        '  shared_helper(x)',
        'end',
    }, '\n'))
    put(root, 'beta.rb', table.concat({
        'def shared_helper(y)',
        '  y * 2',
        'end',
        'def beta_only(y)',
        '  shared_helper(y)',
        'end',
    }, '\n'))
    return root
end

test('scope confinement: keeps exactly what the direct scope filter keeps', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    store.ingest(ts.extract(ruby_corpus()))
    local px = store.postings()
    ok(px.n_files >= 2, 'both files indexed (' .. px.n_files .. ')')

    local n = 0
    for nme in pairs(px.post) do
        for _, f in ipairs(store.mentioning(nme)) do
            n = n + 1
            eq(table.concat(store.mentioning_in_scan(nme, f), ','),
                table.concat(store.mentioning_in(nme, f), ','))
        end
    end
    ok(n > 0, 'checked ' .. n .. ' (name, file) pairs')
end)

test('scope confinement: ruby scope IS the file, so candidates collapse to one', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    store.ingest(ts.extract(ruby_corpus()))
    local scopes = store.scopes()
    ok(scopes, 'ruby produced a scope map')
    eq('alpha.rb', scopes['alpha.rb']) -- ruby: scope = the file itself

    -- shared_helper is mentioned in BOTH files unconfined...
    local all = store.mentioning('shared_helper')
    eq(2, #all)
    -- ...and in exactly ONE once confined to the asking file
    eq('alpha.rb', table.concat(store.mentioning_in('shared_helper', 'alpha.rb'), ','))
    eq('beta.rb', table.concat(store.mentioning_in('shared_helper', 'beta.rb'), ','))
end)

test('scope confinement: never LOSES a candidate the reduce would keep', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    store.ingest(ts.extract(ruby_corpus()))
    local scopes = store.scopes() or {}
    for nme in pairs(store.postings().post) do
        for _, f in ipairs(store.mentioning(nme)) do
            local kept = {}
            for _, g in ipairs(store.mentioning_in(nme, f)) do kept[g] = true end
            for _, g in ipairs(store.mentioning(nme)) do
                if scopes[g] == scopes[f] then
                    ok(kept[g], ('%s: %s kept for a mention in %s'):format(nme, g, f))
                end
            end
        end
    end
end)

test('scope confinement: an UNPARTITIONED corpus confines nothing, and says so', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- lua's scope is the .TOC addon partition; with no .toc dirs every file lands
    -- in ONE bucket, so confinement is a no-op here rather than a reduction. The
    -- point of the test is that it is a no-op and NOT a loss.
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    put(root, 'one.lua', 'local function thing() return 1 end\nreturn { thing = thing }')
    put(root, 'two.lua', 'local M = require("one")\nreturn { go = function () return M.thing() end }')
    store.ingest(ts.extract(root))
    for nme in pairs(store.postings().post) do
        for _, f in ipairs(store.mentioning(nme)) do
            eq(table.concat(store.mentioning(nme), ','),
                table.concat(store.mentioning_in(nme, f), ','))
        end
    end
end)

test('scope confinement: a file with no indexed mentions still resolves its scope', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    store.ingest(ts.extract(ruby_corpus()))
    -- a path absent from the postings index: mentioning_in must fall back to the
    -- scope MAP rather than silently treating it as the no-scope bucket
    local out = store.mentioning_in('shared_helper', 'not/in/the/index.rb')
    eq(0, #out) -- its scope is shared by no indexed file, so no candidate survives
    -- and an indexed file still answers normally afterwards (no cache poisoning)
    eq('alpha.rb', table.concat(store.mentioning_in('shared_helper', 'alpha.rb'), ','))
end)

test('scope confinement: the axis is band-transient (scopes cache included)', function ()
    ok(store.BAND_TRANSIENT._scopes, '_scopes is band-transient')
    ok(store.BAND_TRANSIENT._scopes_gen, '_scopes_gen is band-transient')
end)

test('scope_axis: interned ids, bounded by the DISTINCT scope count', function ()
    -- pure: its own postings, its own scope map, no store state
    local px = store.build_postings {
        ['a/x.rb'] = '\31alpha\31shared\31',
        ['a/y.rb'] = '\31shared\31',
        ['b/z.rb'] = '\31shared\31beta\31',
    }
    store.scope_axis(px, { ['a/x.rb'] = 'a', ['a/y.rb'] = 'a', ['b/z.rb'] = 'b' })
    eq(2, px.n_scopes) -- two distinct scopes, so ids are 1 and 2
    eq(px.fscope[px.index['a/x.rb']], px.fscope[px.index['a/y.rb']])
    ok(px.fscope[px.index['a/x.rb']] ~= px.fscope[px.index['b/z.rb']], 'a and b differ')

    -- a nil scope interns to 0, and two no-scope files must compare EQUAL, because
    -- the reduce does not drop when both sides are nil
    local py = store.build_postings { ['p.txt'] = '\31n\31', ['q.txt'] = '\31n\31' }
    store.scope_axis(py, { other = 'x' })
    eq(0, py.fscope[py.index['p.txt']])
    eq(0, py.fscope[py.index['q.txt']])
end)
