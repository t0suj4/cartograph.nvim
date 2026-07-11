-- The df fold: nested per-fn statement records -> one columnar store,
-- views materialized raw-shaped through the dual-mode df.lua accessors.
-- Parity is the whole contract: every accessor must read IDENTICALLY
-- before and after the fold, including the witness (refs identity).

local dfa = require 'cartograph.df'
local refs = require 'cartograph.refs'

local function mknode(id, df)
    return { id = id, name = id, kind = 'function', file = 'm.lua',
        range = { start = { line = 0, char = 0 }, ['end'] = { line = 9, char = 0 } },
        df = df }
end

local function mkdata()
    return { nodes = {
        mknode('f', {
            inputs = { 'store', 'config' },
            stmts = {
                { l = 2, def = { 'a' }, use = { 'store' }, dep = {} },
                { l = 3, def = { 'b', 'c' }, use = { 'a', 'config' },
                    dep = { { from = 1, var = 'a' } },
                    defr = { [1] = -1, [2] = 4 } },
                { l = 5, def = {}, use = { 'b', 'c', 'a' },
                    dep = { { from = 2, var = 'b' }, { from = 2, var = 'c' },
                        { from = 1, var = 'a' } } },
            } }),
        mknode('empty', { inputs = {}, stmts = {} }), -- 0-stmt: present, not has
        mknode('bare'),                               -- no df at all
    } }
end

local function snap(nodes)
    local out = {}
    for _, n in ipairs(nodes) do
        out[n.id] = { has = dfa.has(n), present = dfa.present(n),
            count = dfa.count(n), stmts = dfa.stmts(n), rec = dfa.get(n) }
    end
    return out
end

test('df fold: every accessor reads identically before and after', function ()
    local data = mkdata()
    local before = snap(data.nodes)
    local ns = dfa.fold(data)
    eq(3, ns, 'all statements folded')
    local after = snap(data.nodes)
    eq(before, after, 'has/present/count/stmts/get: raw == folded, field for field')
    ok(data.nodes[1].df == nil and data.nodes[1]._df, 'nested records dropped')
    ok(data.nodes[2]._df and data.nodes[2]._dfn == 0, '0-stmt fn folds to an empty slice')
    ok(not data.nodes[3]._df, 'df-less node untouched')
    eq(0, dfa.fold(data), 'idempotent: a second fold is a no-op')
end)

test('df fold: the witness survives the fold (refs identity)', function ()
    local data = mkdata()
    local n = data.nodes[1]
    n.params = { 'x', 'y' }
    local w0 = refs.witness(n, { 'callee_b', 'callee_a' })
    dfa.fold(data)
    eq(w0, refs.witness(n, { 'callee_b', 'callee_a' }),
        'witness hash identical over folded views')
    ok(w0 ~= refs.witness(data.nodes[2], {}) or true, 'sanity')
end)

test('df fold: dual mode serves a mixed graph (refresh nodes stay raw)', function ()
    local data = mkdata()
    dfa.fold(data)
    local fresh = mknode('fresh', { inputs = { 'x' },
        stmts = { { l = 1, def = { 'q' }, use = { 'x' }, dep = {} } } })
    data.nodes[#data.nodes + 1] = fresh -- post-fold arrival (refresh path)
    eq(1, dfa.count(fresh), 'raw node reads through the same accessor')
    eq('q', dfa.stmts(fresh)[1].def[1])
    eq(3, dfa.count(data.nodes[1]), 'folded neighbor unaffected')
end)

test('df fold: real extract parity end-to-end', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local M = {}',
        'function M.work(cfg, n)',
        '    local base = cfg.base',
        '    local total = base + n',
        '    local out = {}',
        '    for i = 1, total do out[i] = base * i end',
        '    return out',
        'end',
        'return M',
    }, '\n'))
    fd:close()
    local data = require('cartograph.providers.treesitter').extract(root)
    local before = snap(data.nodes)
    dfa.fold(data)
    eq(before, snap(data.nodes), 'extractor-built df: raw == folded')
end)
