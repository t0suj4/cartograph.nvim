-- JS/TS `this.member()` typing (pivot B3): `this` inside a class method is the
-- instance; type it LEXICALLY to the enclosing class (from the B1 `C.member` key)
-- and resolve member through the B2 extends chain. ~-tier (JS this can be rebound;
-- virtual dispatch). Gated to a genuine object (owner owns >=2 methods) + unique
-- chain hit; a nested non-method fn's `this` (no class owner) is skipped.

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

test('this: own-class this.member() resolves to C.member (~)', function ()
    if not ready() then skip 'no javascript parser' end
    local root = extract(table.concat({
        'class Vec {',
        '  add(o) { return this.clone() }',   -- this.clone -> Vec.clone
        '  clone() { return new Vec() }',
        '}',
        -- a DIFFERENT class with a same-named clone() — the ambiguity B3 breaks
        'class Box { clone() {} size() {} }',
    }, '\n'))
    local c = call_full('this.clone')
    ok(c and c.to, 'this.clone() resolved')
    eq('Vec.clone', name_of(c.to), 'typed to the enclosing class Vec, not Box')
    ok(c.inferred, '~ tier')
    vim.fn.delete(root, 'rf')
end)

test('this: inherited this.member() walks the extends chain', function ()
    if not ready() then skip 'no javascript parser' end
    local root = extract(table.concat({
        'class Base { setup() { return 1 } helper() {} }',
        'class Panel extends Base {',
        '  render() { return this.setup() }',   -- inherited -> Base.setup
        '  draw() {}',
        '}',
    }, '\n'))
    local c = call_full('this.setup')
    ok(c and c.to and name_of(c.to) == 'Base.setup',
        'this.setup() → inherited Base.setup up the chain')
    vim.fn.delete(root, 'rf')
end)

test('this: nested non-method this is NOT typed (owner underivable)', function ()
    if not ready() then skip 'no javascript parser' end
    -- `refresh` is AMBIGUOUS (two classes define it) so the main resolver refuses
    -- → only B3 could resolve it. Inside a NESTED function `this` is not Svc's, so
    -- B3 must skip (c.fn is `inner`, not a `C.member` → no class owner).
    local root = extract(table.concat({
        'class Svc {',
        '  refresh() {}',
        '  draw() {}',
        '  run() {',
        '    function inner() { return this.refresh() }',  -- inner: not a class method
        '    return inner',
        '  }',
        '}',
        'class Other { refresh() {} paint() {} }',  -- makes `refresh` ambiguous
    }, '\n'))
    local c = call_full('this.refresh')
    ok(c, 'this.refresh() call extracted')
    ok(not c.to, 'this.refresh() inside a nested function is left unresolved (B3 skips)')
    vim.fn.delete(root, 'rf')
end)

test('this: TS this.member() types through the class too', function ()
    if not ready('typescript') then skip 'no typescript parser' end
    local root = extract(table.concat({
        'class Store {',
        '  get(): number { return this.compute() }',  -- this.compute -> Store.compute
        '  compute(): number { return 1 }',
        '}',
    }, '\n'), 'ts')
    local c = call_full('this.compute')
    ok(c and c.to and name_of(c.to) == 'Store.compute', 'TS this.compute → Store.compute')
    vim.fn.delete(root, 'rf')
end)
