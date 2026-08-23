-- The write axis (rung 1, syntactic): use edges carry rw = 1 read / 2 write
-- / 3 both, the OR of the edge's occurrences. A mention is a write anywhere
-- on an assignment-target chain (base mutated, field assigned); bracket
-- KEYS are reads. Languages without a classifier ship NO rw — absent is
-- unknown, never a claimed "read".

local ts = require 'cartograph.providers.treesitter'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang)
end

-- rw of the use edge fn_name -> var_name, plus a missing-edge guard
local function rw_of(data, fn_name, var_name)
    local byid = {}
    for _, n in ipairs(data.nodes) do byid[n.id] = n end
    for _, e in ipairs(data.edges) do
        if e.kind == 'use' then
            local f, v = byid[e.from], byid[e.to]
            if f and v and f.name == fn_name and v.name == var_name then
                return e.rw, true
            end
        end
    end
    return nil, false
end

test('writes: lua use edges carry read/write/both', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = mkroot('m.lua', table.concat({
        'local state = {}',
        'local count = 0',
        'local function reader()',
        '    return state.x + count',
        'end',
        'local function writer()',
        '    state.x = 1',
        '    count = count + 1',
        'end',
        'local function pusher()',
        '    state[#state + 1] = "y"',
        'end',
        'return { reader = reader, writer = writer, pusher = pusher }',
    }, '\n'))
    local data = ts.extract(root)
    eq(1, rw_of(data, 'reader', 'state'), 'reader only reads state')
    eq(1, rw_of(data, 'reader', 'count'), 'reader only reads count')
    eq(2, rw_of(data, 'writer', 'state'), 'state.x = 1 mutates state: write')
    eq(3, rw_of(data, 'writer', 'count'), 'count = count + 1 reads AND writes')
    eq(3, rw_of(data, 'pusher', 'state'),
        'state[#state+1]: target base writes, the KEY #state reads')
end)

test('writes: php assignment forms, unset, foreach by-ref', function ()
    if not ready('php') then skip 'no php parser' end
    local root = mkroot('m.php', table.concat({
        '<?php',
        "$config = array('a' => 1);",
        '$total = 0;',
        '$queue = array();',
        '$items = array();',
        'function reader() { global $config; return $config["a"]; }',
        'function writer() {',
        '    global $config, $total;',
        '    $config["b"] = 2;',      -- subscript write
        '    $total += 1;',           -- augmented assignment
        '    $total++;',              -- update expression
        '    unset($config["a"]);',   -- unset
        '}',
        'function qpush() { $queue[] = "i"; }',  -- array push, write-only
        'function mapper() { foreach ($items as &$v) { $v = 1; } }',
    }, '\n'))
    local data = ts.extract(root)
    eq(1, rw_of(data, 'reader', 'config'), 'reader: global decl + subscript read')
    eq(3, rw_of(data, 'writer', 'config'),
        'writer: global decl reads, subscript-assign and unset write')
    eq(3, rw_of(data, 'writer', 'total'), 'global read; += and ++ write')
    eq(2, rw_of(data, 'qpush', 'queue'), '$queue[] = : push is a pure write')
    eq(2, rw_of(data, 'mapper', 'items'),
        'foreach by-ref writes the iterated array')
end)

test('writes: gw/gp/flds survive the fold, both Band backends agree', function ()
    local fold = require 'cartograph.fold'
    local band = require 'cartograph.band'
    local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
    local function node(id, kind)
        return { id = id, name = id, kind = kind or 'function',
            file = 'm.lua', range = R, order = 0 }
    end
    local DATA = {
        root = '/x',
        nodes = { node('m.lua', 'module'), node('a'), node('b'), node('c'),
            node('v', 'var') },
        edges = {
            { from = 'a', to = 'v', kind = 'use', at = { R }, rw = 2, gw = 3,
                flds = { x = 14, [''] = 1 } },        -- x: rw3+gw3, whole read
            { from = 'b', to = 'v', kind = 'use', at = { R }, rw = 3, gw = 2,
                gp = -2 },
            { from = 'c', to = 'v', kind = 'use', at = { R }, rw = 1 },
        },
        calls = {},
    }
    local store = require 'cartograph.store'
    store.ingest(DATA)
    local f = fold.build(store.data)
    local bs, bf = band.from_store(store), band.from_fold(f)
    for _, pair in ipairs({ { 'a', 3 }, { 'b', 2 }, { 'c', nil } }) do
        eq(pair[2], bs:gw(pair[1], 'v'), 'store gw of ' .. pair[1])
        eq(pair[2], bf:gw(pair[1], 'v'), 'fold gw of ' .. pair[1])
    end
    eq(-2, bs:gp('b', 'v'))
    eq(-2, bf:gp('b', 'v'), 'the param predicate survives the fold')
    eq(nil, bf:gp('a', 'v'), 'no gp where none was recorded')
    eq({ x = 14, [''] = 1 }, bs:flds('a', 'v'))
    eq({ x = 14, [''] = 1 }, bf:flds('a', 'v'),
        'per-field facts decode identically from the packed rows')
    eq(nil, bf:flds('c', 'v'))
    -- and the honesty tiers are undisturbed by the new bits
    local si, vi = f.it.get('a'), f.it.get('v')
    eq(nil, f:tier(si, vi, fold.PRED.use), 'tier is ref-only; use-row bits never read as a tier')
    eq('write', bf:rw('a', 'v'), '...and rw intact')
end)

test('writes: rw survives the fold, both Band backends agree', function ()
    local fold = require 'cartograph.fold'
    local band = require 'cartograph.band'
    local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
    local function node(id, kind)
        return { id = id, name = id, kind = kind or 'function',
            file = 'm.lua', range = R, order = 0 }
    end
    local DATA = {
        root = '/x',
        nodes = { node('m.lua', 'module'), node('r'), node('w'), node('b'),
            node('u'), node('v', 'var') },
        edges = {
            { from = 'r', to = 'v', kind = 'use', at = { R }, rw = 1 },
            { from = 'w', to = 'v', kind = 'use', at = { R }, rw = 2 },
            { from = 'b', to = 'v', kind = 'use', at = { R }, rw = 3 },
            { from = 'u', to = 'v', kind = 'use', at = { R } }, -- no classifier
        },
        calls = {},
    }
    local store = require 'cartograph.store'
    store.ingest(DATA)
    local f = fold.build(store.data)
    local bs, bf = band.from_store(store), band.from_fold(f)
    for id, want in pairs({ r = 'read', w = 'write', b = 'both' }) do
        eq(want, bs:rw(id, 'v'), 'store band rw of ' .. id)
        eq(want, bf:rw(id, 'v'), 'fold band rw of ' .. id)
    end
    eq(nil, bs:rw('u', 'v'), 'unclassified stays unknown (store)')
    eq(nil, bf:rw('u', 'v'), 'unclassified stays unknown (fold)')
    eq(nil, bs:rw('r', 'w'), 'no such use edge')
    -- rw rides the rule region WITHOUT disturbing the honesty tiers
    local s, o = f.it.get('b'), f.it.get('v')
    eq(nil, f:tier(s, o, fold.PRED.use), 'tier is ref-only; use-row rw bits never read as a tier')
end)

-- THE HONEST-ABSENCE INVARIANT: a language with no write classifier must leave
-- `rw` ABSENT, never default it to "read". Absence is what lets atlas say
-- `unclassified` instead of minting `const` over a pass that never ran — the
-- fabrication v147 shipped when it declared `is_write` without `write_gate`.
-- ★★ AND IT NO LONGER NAMES A LANGUAGE, deliberately. This test used JAVASCRIPT
-- until v156 gave it a classifier — the fourth stale assertion the write-axis arc
-- broke, because each one had encoded "language X has none" as the fact under test.
-- Trying RUBY next produced a SKIP ("no use edge in this fixture shape"), which is
-- worse than a failure: ruby's three corpora hold ONE var node in total, so it can
-- never demonstrate anything here, and a skip reads like a pass.
-- So the invariant is tested on the MECHANISM: take a language that HAS a
-- classifier, remove it for the duration, and require `rw` to be absent rather
-- than defaulted to "read". Coverage can now grow to every language without this
-- going stale or vacuous.
test('writes: no classifier -> rw stays ABSENT, not read', function ()
    if not ready('lua') then skip 'no lua parser' end
    local spec = ts.spec.lua
    local saved_w, saved_g = spec.is_write, spec.write_gate
    spec.is_write, spec.write_gate = nil, nil
    local ok_, res = pcall(function ()
        local root = mkroot('m.lua', table.concat({
            'local state = {}',
            'function writer() state.x = 1 end',
            'return { writer = writer }',
        }, '\n'))
        local data = ts.extract(root)
        local rw, found = rw_of(data, 'writer', 'state')
        return { rw = rw, found = found }
    end)
    spec.is_write, spec.write_gate = saved_w, saved_g -- restore before asserting
    ok(ok_, tostring(res))
    ok(res.found, 'the fixture yields a use edge (else this test proves nothing)')
    eq(nil, res.rw, 'no classifier: mode must be ABSENT, never a claimed read')
end)
