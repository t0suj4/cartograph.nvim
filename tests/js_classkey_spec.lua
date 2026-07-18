-- JS/TS class-keying (pivot B1): ES6 methods carry their class — `class C { m(){} }`
-- extracts the method as `C.m` (the JS analog of lua `C:m`), SEPARATING the
-- module-function namespace from the class-method one that bare-keying conflated.
-- A method is a class member iff its parent is class_body: object-literal methods
-- stay bare. `.` separator lets a literal `Class.method()` reference exact-match.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang or 'javascript')
end

local function names(root)
    store.ingest(ts.extract(root))
    local by = {}
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'method' or n.kind == 'function' then
            by[n.name] = n
        end
    end
    return by
end

test('classkey: ES6 class method keyed C.m; object method stays bare', function ()
    if not ready() then skip 'no javascript parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/a.js', 'w'))
    fd:write(table.concat({
        'class Vec {',
        '  add(o) { return o }',       -- class member -> Vec.add
        '}',
        'const o = { add(x) { return x } };',  -- object method -> bare add
        'function add(z) { return z }',        -- module fn -> bare add
    }, '\n'))
    fd:close()
    local by = names(root)
    ok(by['Vec.add'], 'class method keyed as Vec.add')
    ok(by['add'], 'the module function / object method stays bare add')
    -- the class method is NOT double-counted as a bare `add` collision:
    -- Vec.add is its own node, distinct from the bare add
    eq('method', by['Vec.add'].kind)
    vim.fn.delete(root, 'rf')
end)

test('classkey: a literal Class.method() call EXACT-matches the class method', function ()
    if not ready() then skip 'no javascript parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/b.js', 'w'))
    fd:write(table.concat({
        'class MathU {',
        '  static clamp(v) { return v }',
        '}',
        'function use() { return MathU.clamp(3) }',  -- exact -> MathU.clamp
    }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local tgt
    for _, n in ipairs(store.data.nodes) do
        if n.name == 'MathU.clamp' then tgt = n.id end
    end
    ok(tgt, 'MathU.clamp extracted as a class-keyed method')
    local hit
    for _, c in ipairs(store.data.calls or {}) do
        if c.callee == 'clamp' or c.full == 'MathU.clamp' then hit = c end
    end
    ok(hit and hit.to == tgt, 'MathU.clamp() resolved to the class method by exact match')
    vim.fn.delete(root, 'rf')
end)

test('classkey: anonymous class expression borrows its binding variable name', function ()
    if not ready() then skip 'no javascript parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/c.js', 'w'))
    fd:write(table.concat({
        'const Widget = class {',
        '  render() { return 1 }',   -- -> Widget.render (name from the var)
        '};',
    }, '\n'))
    fd:close()
    local by = names(root)
    ok(by['Widget.render'], 'class-expression method keyed from the binding var: Widget.render')
    vim.fn.delete(root, 'rf')
end)

test('classkey: TS abstract class methods are class-keyed too', function ()
    if not ready('typescript') then skip 'no typescript parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/d.ts', 'w'))
    fd:write(table.concat({
        'abstract class Base {',
        '  run(n: number): number { return n }',   -- -> Base.run
        '}',
    }, '\n'))
    fd:close()
    local by = names(root)
    ok(by['Base.run'], 'abstract-class method keyed as Base.run')
    vim.fn.delete(root, 'rf')
end)
