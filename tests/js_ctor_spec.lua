-- JS/TS ctor-typing V2: `const o = new C(...)` binds o to class C, so `o.member`
-- resolves to C.member walking C's extends chain (resolve_local_ctor CUT 3: the
-- callee IS the class). `new C()` constructs exactly a C instance → sound. Gated
-- to a single binding (n==1); a rebound local hedges.

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
local function call_full(full)
    for _, c in ipairs(store.data.calls or {}) do if c.full == full then return c end end
end

test('ctor: const o = new C(); o.m() resolves to C.m (~)', function ()
    if not ready() then skip 'no javascript parser' end
    local root = extract(table.concat({
        'class C { calc(n) { return n } tick() {} }',
        'function use() { const obj = new C(3); return obj.calc(2) }',
        'class Other { calc() {} extra() {} }',  -- makes `calc` ambiguous
    }, '\n'))
    local c = call_full('obj.calc')
    ok(c and c.to, 'obj.calc() resolved')
    eq('C.calc', name_of(c.to), 'typed to C (obj = new C), not Other')
    ok(c.inferred, '~ tier')
    vim.fn.delete(root, 'rf')
end)

test('ctor: instance method call walks the extends chain', function ()
    if not ready() then skip 'no javascript parser' end
    local root = extract(table.concat({
        'class Base { setup() { return 1 } base2() {} }',
        'class Panel extends Base { draw() {} paint() {} }',
        'function mk() { const p = new Panel(); return p.setup() }',  -- inherited → Base.setup
    }, '\n'))
    local c = call_full('p.setup')
    ok(c and c.to and name_of(c.to) == 'Base.setup',
        'p.setup() → inherited Base.setup up the chain')
    vim.fn.delete(root, 'rf')
end)

test('ctor: a REBOUND local hedges (n>1, not single-assignment)', function ()
    if not ready() then skip 'no javascript parser' end
    local root = extract(table.concat({
        'class A { run() {} step() {} }',
        'class B { run() {} go() {} }',
        'function f(flag) {',
        '  let x = new A();',
        '  x = new B();',       -- rebound → type indeterminate → hedge
        '  return x.run();',
        '}',
    }, '\n'))
    local c = call_full('x.run')
    ok(c and not c.to, 'x.run() left unresolved when x is rebound (sound hedge)')
    vim.fn.delete(root, 'rf')
end)

test('ctor: TS const o = new C() types the same way', function ()
    if not ready('typescript') then skip 'no typescript parser' end
    local root = extract(table.concat({
        'class Svc { fetchIt(): number { return 1 } save(): void {} }',
        'function use(): number { const s = new Svc(); return s.fetchIt() }',
        'class Repo { fetchIt(): void {} load(): void {} }',  -- ambiguous fetchIt
    }, '\n'), 'ts')
    local c = call_full('s.fetchIt')
    ok(c and c.to and name_of(c.to) == 'Svc.fetchIt', 'TS s.fetchIt → Svc.fetchIt')
    vim.fn.delete(root, 'rf')
end)
