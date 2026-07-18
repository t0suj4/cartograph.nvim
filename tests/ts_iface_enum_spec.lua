-- TS interfaces & enums (pivot A1-tail): interface/enum declarations extract as
-- browse-only TYPE nodes (kind='var' + ctype), like a C struct/enum, plus their
-- members. PURELY ADDITIVE — ctype excludes them from value resolution (var_named
-- gate) and interface method sigs are decl=true (excluded from the global index),
-- so no resolution edge changes; this is faithful representation, not linking.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'typescript')
end

local function nodesByName(root)
    store.ingest(ts.extract(root))
    local by = {}
    for _, n in ipairs(store.data.nodes) do by[n.name] = n end
    return by
end

local function write(root, src)
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/t.ts', 'w')); fd:write(src); fd:close()
end

test('ts: interface → type node + property/method-sig members', function ()
    if not ready() then skip 'no typescript parser' end
    local root = vim.fn.tempname()
    write(root, 'export interface Opts { n: number; label?: string; run(a: number): void }')
    local by = nodesByName(root)
    ok(by['Opts'], 'interface type node')
    eq('var', by['Opts'].kind); eq('interface', by['Opts'].ctype)
    ok(by['Opts.n'] and by['Opts.n'].ctype == 'field', 'property signature Opts.n (browse-only field)')
    ok(by['Opts.label'], 'optional property Opts.label')
    ok(by['Opts.run'], 'method signature Opts.run')
    eq('method', by['Opts.run'].kind)
    ok(by['Opts.run'].decl, 'interface method sig is decl=true (not a call target)')
    vim.fn.delete(root, 'rf')
end)

test('ts: enum → type node + members (bare, valued, string, const)', function ()
    if not ready() then skip 'no typescript parser' end
    local root = vim.fn.tempname()
    write(root, table.concat({
        'export enum Color { Red, Green = 5, Blue }',
        'const enum Dir { Up, Down }',
        'enum Named { A = "a", B = "b" }',
    }, '\n'))
    local by = nodesByName(root)
    for _, e in ipairs({ 'Color', 'Dir', 'Named' }) do
        ok(by[e] and by[e].ctype == 'enum', e .. ' enum type node')
    end
    for _, m in ipairs({ 'Color.Red', 'Color.Green', 'Color.Blue',
        'Dir.Up', 'Dir.Down', 'Named.A', 'Named.B' }) do
        ok(by[m] and by[m].ctype == 'enumMember', m .. ' member node')
    end
    vim.fn.delete(root, 'rf')
end)

test('ts: interface/enum nodes are browse-only — excluded from the resolution index', function ()
    if not ready() then skip 'no typescript parser' end
    local root = vim.fn.tempname()
    write(root, table.concat({
        'export interface Store { computeTotal(): number }',
        'enum E { X }',
        -- a real function sharing the interface method's name — its call must
        -- NOT be ambiguated by the interface signature (which is decl / unindexed)
        'function computeTotal(): number { return 1 }',
        'function use() { return computeTotal() }',
    }, '\n'))
    store.ingest(ts.extract(root))
    local call
    for _, c in ipairs(store.data.calls or {}) do
        if c.callee == 'computeTotal' then call = c end
    end
    ok(call, 'computeTotal() call extracted')
    -- resolves to the real function, not refused-ambiguous against Store.computeTotal
    local target
    for _, n in ipairs(store.data.nodes) do if n.id == call.to then target = n end end
    ok(target and target.name == 'computeTotal' and target.kind == 'function',
        'computeTotal() → the real function (interface sig did not ambiguate it)')
    vim.fn.delete(root, 'rf')
end)
