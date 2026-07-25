-- ON-DEMAND CALL MATERIALIZATION (store.materialize_file_calls) — the calls half of
-- index-and-reduce. df/flow are local, so materialize_file_dataflow is byte-faithful;
-- calls need RESOLUTION, which is where cross-file evidence lives, so this one has to
-- earn its fidelity rather than assume it.
--
-- What the tests defend:
--   · a materialized file's calls RESOLVE, against the thin index's (complete) def
--     index — the whole point;
--   · the index_only MARKER SURVIVES, because one file's calls is not a call graph
--     and whole-graph verbs must keep refusing;
--   · the file's DATAFLOW is materialized too — resolution reads it, and omitting it
--     silently lost `fn-value` refusals (measured on ruby, 5 of 473 sites);
--   · resolution comes from RELINK against the resident index, never from the
--     one-file batch, whose own view is a horizontal slice.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local callrec = require 'cartograph.callrec'

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

-- caller.lua calls a function DEFINED IN ANOTHER FILE, so resolving it requires the
-- cross-file def index — the thing a one-file extract cannot have and the resident
-- thin index does.
local function corpus()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    put(root, 'lib.lua', table.concat({
        'local function target_fn(x) return x + 1 end',
        'return { target_fn = target_fn }',
    }, '\n'))
    put(root, 'caller.lua', table.concat({
        'local lib = require("lib")',
        'local function go(n) return lib.target_fn(n) end',
        'return { go = go }',
    }, '\n'))
    return root
end

local function calls_in(file)
    local out = {}
    for _, c in ipairs((store.data or {}).calls or {}) do
        if callrec.file(c) == file then out[#out + 1] = c end
    end
    return out
end

test('demand calls: the thin index starts with none, and materializing adds the file\'s', function ()
    if not ready('lua') then skip 'no lua parser' end
    store.ingest(ts.index_only(corpus()))
    eq(0, #((store.data or {}).calls or {}))
    ok(store.materialize_file_calls('caller.lua'), 'materialized')
    ok(#calls_in('caller.lua') > 0, 'caller.lua now has calls')
    eq(0, #calls_in('lib.lua')) -- only the asked-for file
end)

test('demand calls: resolve CROSS-FILE, against the resident def index', function ()
    if not ready('lua') then skip 'no lua parser' end
    store.ingest(ts.index_only(corpus()))
    store.materialize_file_calls('caller.lua')
    -- the call is to a def in ANOTHER file; a one-file extract could not resolve it,
    -- so a resolved target proves the resident (complete) index was used
    local found
    for _, c in ipairs(calls_in('caller.lua')) do
        if callrec.callee(c) == 'target_fn' then found = c end
    end
    ok(found, 'the cross-file call site is present')
    ok(found.to, 'and it RESOLVED (' .. tostring(found.to) .. ')')
    ok(tostring(found.to):find('lib.lua', 1, true),
        'to a def in the other file: ' .. tostring(found.to))
end)

test('demand calls: the index_only marker SURVIVES — one file is not a call graph', function ()
    if not ready('lua') then skip 'no lua parser' end
    store.ingest(ts.index_only(corpus()))
    store.materialize_file_calls('caller.lua')
    ok(store.is_index_only(),
        'still the thin index, so whole-graph verbs keep refusing')
    eq('caller.lua', table.concat(store.calls_materialized(), ','))
end)

test('demand calls: the file\'s DATAFLOW is materialized too (resolution reads it)', function ()
    if not ready('lua') then skip 'no lua parser' end
    store.ingest(ts.index_only(corpus()))
    -- before: the thin index carries no df/flow
    local function has_df()
        for _, n in ipairs(store.data.nodes or {}) do
            if n.file == 'caller.lua' and (n.df or n._df or n.flow or n._flow) then
                return true
            end
        end
        return false
    end
    ok(not has_df(), 'thin index has no dataflow for caller.lua')
    store.materialize_file_calls('caller.lua')
    ok(has_df(), 'materializing calls materialized the dataflow as well')
end)

test('demand calls: idempotent, and a no-op on a graph that already has them', function ()
    if not ready('lua') then skip 'no lua parser' end
    store.ingest(ts.index_only(corpus()))
    ok(store.materialize_file_calls('caller.lua'), 'first call materializes')
    local n = #calls_in('caller.lua')
    ok(not store.materialize_file_calls('caller.lua'), 'second is a no-op')
    eq(n, #calls_in('caller.lua')) -- no duplicated sites

    -- a FULL graph already has them: nothing to do, nothing duplicated
    store.ingest(ts.extract(corpus()))
    local before = #calls_in('caller.lua')
    ok(not store.materialize_file_calls('caller.lua'), 'no-op on a full graph')
    eq(before, #calls_in('caller.lua'))
end)

test('demand calls: sites match a full extract\'s for that file', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = corpus()
    local full = ts.extract(root)
    local want = {}
    for _, c in ipairs(full.calls or {}) do
        if callrec.file(c) == 'caller.lua' then
            want[('%s|%s|%s'):format(tostring(callrec.fn(c)),
                tostring(callrec.callee(c)), tostring(callrec.line(c)))] = c.to or true
        end
    end
    store.ingest(ts.index_only(root))
    store.materialize_file_calls('caller.lua')
    local n = 0
    for _, c in ipairs(calls_in('caller.lua')) do
        local k = ('%s|%s|%s'):format(tostring(callrec.fn(c)),
            tostring(callrec.callee(c)), tostring(callrec.line(c)))
        ok(want[k] ~= nil, 'site present in the full extract too: ' .. k)
        eq(want[k], c.to or true) -- same disposition
        n = n + 1
    end
    ok(n > 0, 'compared ' .. n .. ' sites')
end)
