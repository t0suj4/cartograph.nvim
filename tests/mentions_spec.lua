-- MENTIONS (cartograph.mentions) — the name-level evidence surface, and the first
-- CONSUMER of the mention postings. Three steps of index built nothing anyone
-- could reach; this is the verb that reaches it.
--
-- What the tests defend is the honesty contract, because that is the whole risk
-- here: a list of files that mention a name is easy to mistake for references.
--   · on the THIN INDEX the resolved subset must read UNAVAILABLE, not zero —
--     "0 of 5 resolved" on a graph with no call graph is a fabricated negative,
--     the exact thing lsp.lua declines referencesProvider to avoid.
--   · the report must say how many defs share the spelling, since that is what
--     decides whether name-level evidence means anything.
--   · the resolved subset must be a SUBSET of the mentions, never a separate set.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local mentions = require 'cartograph.mentions'

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

-- `shared_thing` is DEFINED in one file and CALLED from another, plus mentioned as
-- a plain variable in a third — so the resolved subset is a strict subset.
local function corpus()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    put(root, 'def.lua', table.concat({
        'local function shared_thing(x) return x + 1 end',
        'return { shared_thing = shared_thing }',
    }, '\n'))
    put(root, 'caller.lua', table.concat({
        'local d = require("def")',
        'local function go(n) return d.shared_thing(n) end',
        'return { go = go }',
    }, '\n'))
    put(root, 'namer.lua', table.concat({
        'local shared_thing = 7',   -- the NAME, with no call by it
        'return { v = shared_thing }',
    }, '\n'))
    return root
end

local function joined(lines) return table.concat(lines, '\n') end

test('mentions: reports the files mentioning a name', function ()
    if not ready('lua') then skip 'no lua parser' end
    store.ingest(ts.extract(corpus()))
    local e = mentions.evidence(store, 'shared_thing', nil)
    ok(#e.files >= 2, 'at least the definer and a user mention it (' .. #e.files .. ')')
    local seen = {}
    for _, f in ipairs(e.files) do seen[f] = true end
    ok(seen['def.lua'], 'def.lua mentions it')
end)

test('mentions: the resolved subset is a SUBSET of the mentions', function ()
    if not ready('lua') then skip 'no lua parser' end
    store.ingest(ts.extract(corpus()))
    local e = mentions.evidence(store, 'shared_thing', nil)
    ok(e.has_calls, 'a full extract carries a call graph')
    local inset = {}
    for _, f in ipairs(e.files) do inset[f] = true end
    for f in pairs(e.resolved) do
        ok(inset[f], f .. ' is resolved AND present in the mention list')
    end
end)

test('mentions: on the THIN INDEX it REFUSES — there is no mention index to read', function ()
    if not ready('lua') then skip 'no lua parser' end
    store.ingest(ts.index_only(corpus()))
    ok(store.is_index_only(), 'the graph is the thin index')
    -- index_only sets defs_only, which skips the collect pass that records each
    -- file's identifier set. So the index is ABSENT, and an empty mention list
    -- would be indistinguishable from "nothing mentions this name".
    ok(not store.has_mention_index(), 'the thin index carries no mention index')

    local lines = mentions.report(store, 'shared_thing', nil)
    local text = joined(lines)
    ok(text:find('REFUSED', 1, true), 'the report refuses')
    ok(text:find('thin index', 1, true), 'and names the reason')
    -- no line may carry the ANSWER header shape (`mentions: 'x' — N files`), which
    -- is what a count-as-answer would look like. Checking for the string "0 file"
    -- would instead match the refusal's own prose explaining why zero is wrong.
    for _, l in ipairs(lines) do
        ok(not l:match("^mentions: '.*' %- %d+ file"),
            'no line presents a file COUNT as the answer: ' .. l)
    end
end)

test('mentions: a graph WITH a mention index reports the resolved subset\'s absence honestly', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- the other half of the pair: an index EXISTS, so mentions are reportable; the
    -- distinction being defended is index-absent (refuse) vs calls-absent (report
    -- the mentions, mark the resolved subset unavailable)
    store.ingest(ts.extract(corpus()))
    ok(store.has_mention_index(), 'a full extract carries the mention index')
    local text = joined(mentions.report(store, 'shared_thing', nil))
    ok(not text:find('REFUSED', 1, true), 'it does not refuse here')
    ok(text:find('RESOLVED SUBSET', 1, true), 'the resolved subset is reported')
end)

test('mentions: names how many defs share the spelling', function ()
    if not ready('lua') then skip 'no lua parser' end
    store.ingest(ts.extract(corpus()))
    local text = joined(mentions.report(store, 'shared_thing', nil))
    ok(text:find('DEFS bearing this name', 1, true), 'the def count is stated')
    -- a name with NO def in the graph must say so rather than imply a def
    local none = joined(mentions.report(store, 'totally_absent_name', nil))
    ok(none:find('none in the graph', 1, true), 'no-def case is explicit')
end)

test('mentions: states plainly that a mention is not a reference', function ()
    if not ready('lua') then skip 'no lua parser' end
    store.ingest(ts.extract(corpus()))
    local text = joined(mentions.report(store, 'shared_thing', nil))
    ok(text:find('not a resolved reference', 1, true), 'the contract is in the output')
    ok(text:find('no per%-line answer'), 'the per-file altitude is disclosed')
end)

test('mentions: an empty name is refused, not silently answered', function ()
    if not ready('lua') then skip 'no lua parser' end
    store.ingest(ts.extract(corpus()))
    ok(joined(mentions.report(store, '', nil)):find('no name given', 1, true),
        'an empty name is refused')
    ok(joined(mentions.report(store, nil, nil)):find('no name given', 1, true),
        'a nil name is refused')
end)

test('mentions: an asking file confines the answer to its scope', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    -- ruby's scope IS the file, so confining to one file must drop the other
    put(root, 'one.rb', "def shared_helper(x)\n  x\nend\ndef a(x)\n  shared_helper(x)\nend")
    put(root, 'two.rb', "def shared_helper(y)\n  y\nend\ndef b(y)\n  shared_helper(y)\nend")
    store.ingest(ts.extract(root))

    local wide = mentions.evidence(store, 'shared_helper', nil)
    local narrow = mentions.evidence(store, 'shared_helper', 'one.rb')
    ok(not wide.confined, 'no asking file = not confined')
    ok(narrow.confined, 'an asking file confines')
    ok(#narrow.files < #wide.files,
        ('confined %d < corpus-wide %d'):format(#narrow.files, #wide.files))
    eq('one.rb', table.concat(narrow.files, ','))
    ok(joined(mentions.report(store, 'shared_helper', 'one.rb'))
        :find('scope-confined', 1, true), 'the confinement is disclosed')
end)
