-- JS/TS class inheritance (pivot B2): `class C extends B` → data.extends
-- child→parent (js super_query on class_heritage; ts on the extends_clause;
-- dotted `ns.Base` → the bare tail). resolve_super consumes it: an inherited
-- static call `C.s()` and `super.m()` (receiver = the enclosing class's parent)
-- walk the chain to the nearest ancestor defining the method — sound
-- (nearest-ancestor, unique-or-refuse), the prerequisite for B3 this-typing.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang or 'javascript')
end

local function extract(src, ext)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/f.' .. (ext or 'js'), 'w'))
    fd:write(src); fd:close()
    store.ingest(ts.extract(root))
    return root
end

local function name_of(id)
    for _, n in ipairs(store.data.nodes) do if n.id == id then return n.name end end
end

test('extends: JS class_heritage → data.extends child→parent', function ()
    if not ready() then skip 'no javascript parser' end
    local root = extract(table.concat({
        'class B { m() {} }',
        'class C extends B { n() {} }',
        'class D extends ns.Base { p() {} }',   -- dotted → parent tail `Base`
    }, '\n'))
    local ext = {}
    for _, e in ipairs(store.data.extends or {}) do ext[e.child] = e.parent end
    eq('B', ext['C'], 'C extends B')
    eq('Base', ext['D'], 'dotted ns.Base captured as bare Base')
    vim.fn.delete(root, 'rf')
end)

test('extends: super.m() resolves to the nearest ancestor method', function ()
    if not ready() then skip 'no javascript parser' end
    local root = extract(table.concat({
        'class Base { copy() { return 1 } }',
        'class Mid extends Base { other() {} }',   -- does NOT define copy
        'class Leaf extends Mid { copy() { return super.copy() } }',
    }, '\n'))
    local call
    for _, c in ipairs(store.data.calls or {}) do
        if c.full == 'super.copy' then call = c end
    end
    ok(call and call.to, 'super.copy() resolved')
    -- Leaf's parent is Mid (no copy) → walk to Base.copy (nearest ancestor)
    eq('Base.copy', name_of(call.to), 'super.copy → Base.copy up the chain')
    ok(call.inferred, 'wears the ~ inferred tier')
    vim.fn.delete(root, 'rf')
end)

test('extends: inherited static call C.s() resolves up the chain', function ()
    if not ready() then skip 'no javascript parser' end
    local root = extract(table.concat({
        'class B { static make() { return 1 } }',
        'class C extends B { use() { return C.make() } }',
    }, '\n'))
    local call
    for _, c in ipairs(store.data.calls or {}) do
        if c.full == 'C.make' then call = c end
    end
    ok(call and call.to and name_of(call.to) == 'B.make',
        'C.make() → inherited B.make')
    vim.fn.delete(root, 'rf')
end)

test('extends: TS extends_clause (with generics) → data.extends', function ()
    if not ready('typescript') then skip 'no typescript parser' end
    local root = extract(table.concat({
        'class Base<T> { run(): void {} }',
        'export class Widget extends Base<number> { go(): void { super.run() } }',
    }, '\n'), 'ts')
    local ext = {}
    for _, e in ipairs(store.data.extends or {}) do ext[e.child] = e.parent end
    eq('Base', ext['Widget'], 'TS Widget extends Base (generic args stripped)')
    local call
    for _, c in ipairs(store.data.calls or {}) do
        if c.full == 'super.run' then call = c end
    end
    ok(call and call.to and name_of(call.to) == 'Base.run', 'TS super.run → Base.run')
    vim.fn.delete(root, 'rf')
end)
