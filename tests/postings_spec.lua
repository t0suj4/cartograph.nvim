-- THE MENTION POSTINGS (store.build_postings / postings / mentioning) — step 1 of
-- index-and-reduce. data.names is file -> identifier set; the postings invert it to
-- name -> files, so "which files mention N" is a lookup instead of a scan over
-- every file's name string.
--
-- The gate is DIFFERENTIAL: store.mentioning (postings) must equal
-- store.mentioning_scan (the linear scan it replaced) — and it runs over a REAL
-- extract, not a hand-built names table. A hand-built table can only falsify what
-- the spec itself imagined; the producer's actual framing, repeats and sort order
-- are exactly where an inversion goes wrong.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

local function put(root, rel, text)
    local dir = root .. '/' .. (rel:match('^(.*)/[^/]*$') or '')
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(root .. '/' .. rel, 'w'))
    fd:write(text)
    fd:close()
end

-- a corpus where names are DELIBERATELY shared across files and REPEATED within
-- one: `helper` is called three times in a.lua (one file, three occurrences) and
-- once in b.lua, so a naive inversion posts a.lua three times.
local function corpus()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    put(root, 'a.lua', table.concat({
        'local function helper(x) return x + 1 end',
        'local function only_in_a() return 0 end',
        'local function run(n)',
        '  local p = helper(n)',
        '  local q = helper(p)',
        '  return helper(q) + only_in_a()',
        'end',
        'return { run = run, helper = helper }',
    }, '\n'))
    put(root, 'b.lua', table.concat({
        'local a = require("a")',
        'local function twice(n) return a.helper(n) end',
        'local function only_in_b() return twice(1) end',
        'return { only_in_b = only_in_b }',
    }, '\n'))
    put(root, 'c.lua', table.concat({
        'local function unrelated() return 42 end',
        'return { unrelated = unrelated }',
    }, '\n'))
    return root
end

local function sorted_keys(t)
    local ks = {}
    for k in pairs(t) do ks[#ks + 1] = k end
    table.sort(ks)
    return ks
end

test('postings: equal the linear scan they replace, for every name in a real extract', function ()
    if not ready() then skip 'no lua parser' end
    store.ingest(ts.extract(corpus()))
    local px = store.postings()
    local n = 0
    for _, nme in ipairs(sorted_keys(px.post)) do
        n = n + 1
        eq(table.concat(store.mentioning_scan(nme), ','),
            table.concat(store.mentioning(nme), ','))
    end
    ok(n > 0, 'the corpus produced a mention index to check (' .. n .. ' names)')
end)

test('postings: each file\'s name list is a SET — the producer interns, so no repeats', function ()
    if not ready() then skip 'no lua parser' end
    store.ingest(ts.extract(corpus()))
    -- helper is CALLED three times in a.lua, yet listed once: the id pass interns
    -- each name into a per-file pool (treesitter `nidx`) and the occurrences share
    -- the slot. Pinned because build_postings' dedupe is deliberately defensive
    -- rather than relying on this — if interning ever goes, this says so first.
    local n_files = 0
    for f, s in pairs(store.data.names or {}) do
        n_files = n_files + 1
        local seen = {}
        for nme in s:gmatch('[^\31]+') do
            ok(not seen[nme], ('%s lists %s once'):format(f, nme))
            seen[nme] = true
        end
    end
    ok(n_files > 1, 'checked a multi-file index (' .. n_files .. ' files)')

    -- and the posting list a caller sees carries each file at most once
    local files, seen = store.mentioning('helper'), {}
    for _, f in ipairs(files) do
        ok(not seen[f], 'file ' .. f .. ' appears once in helper\'s posting list')
        seen[f] = true
    end
    ok(seen['a.lua'], 'a.lua is in helper\'s posting list')
end)

test('postings: file lists come back ascending, matching the scan\'s sort', function ()
    if not ready() then skip 'no lua parser' end
    store.ingest(ts.extract(corpus()))
    for nme in pairs(store.postings().post) do
        local files = store.mentioning(nme)
        for i = 2, #files do
            ok(files[i - 1] < files[i],
                ('%s: %s before %s'):format(nme, files[i - 1], files[i]))
        end
    end
end)

test('postings: an unmentioned name yields the empty list, like the scan', function ()
    if not ready() then skip 'no lua parser' end
    store.ingest(ts.extract(corpus()))
    eq(0, #store.mentioning('no_such_identifier_anywhere'))
    eq(0, #store.mentioning_scan('no_such_identifier_anywhere'))
    eq(0, #store.mentioning(''))
end)

test('postings: rebuilt on the next ingest, never served stale', function ()
    if not ready() then skip 'no lua parser' end
    store.ingest(ts.extract(corpus()))
    ok(#store.mentioning('only_in_a') > 0, 'only_in_a is mentioned in the first graph')
    local gen = store.generation

    -- a DIFFERENT corpus: the old postings would still answer for only_in_a
    local root2 = vim.fn.tempname()
    vim.fn.mkdir(root2, 'p')
    put(root2, 'z.lua', 'local function fresh_name() return 1 end\nreturn { fresh_name = fresh_name }')
    store.ingest(ts.extract(root2))
    ok(store.generation ~= gen, 'ingest bumped the generation')
    eq(0, #store.mentioning('only_in_a'))
    eq(table.concat(store.mentioning_scan('fresh_name'), ','),
        table.concat(store.mentioning('fresh_name'), ','))
end)

test('postings: build_postings is pure — no store state, indices into its own files', function ()
    local px = store.build_postings {
        ['z.lua'] = '\31alpha\31beta\31',
        ['a.lua'] = '\31beta\31beta\31gamma\31',
    }
    eq(2, px.n_files)
    eq('a.lua,z.lua', table.concat(px.files, ','))      -- sorted, so lists ascend
    eq('z.lua', px.files[px.post['alpha'][1]])
    eq(1, #px.post['alpha'])
    eq(2, #px.post['beta'])                             -- both files
    eq('a.lua,z.lua', table.concat({ px.files[px.post['beta'][1]],
        px.files[px.post['beta'][2]] }, ','))
    eq(1, #px.post['gamma'])
    eq(nil, px.post['']) -- the `\31` framing never yields an empty name
end)

test('postings: registered BAND_TRANSIENT — a band swap must not serve another band\'s index', function ()
    -- per-band generations can COLLIDE, so a carried-over postings cache would be
    -- silently stale for the incoming band (the same hazard as _topo/_fold)
    ok(store.BAND_TRANSIENT._post, '_post is band-transient')
    ok(store.BAND_TRANSIENT._post_gen, '_post_gen is band-transient')
end)
