-- JS/TS pre-ES6 prototype methods (pivot B4): `X.prototype.m = function` is
-- captured (a structural query gated on the middle property == "prototype") and
-- keyed `X.m` — the same shape B1 gives ES6 methods, so `this.m()` inside a
-- prototype method resolves through B3, and resolve_super walks it. Only genuine
-- prototype assignments match: `obj.member = function` (no .prototype.) is NOT a
-- class method and stays uncaptured (never a false class seed).

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

local function byname()
    local by = {}
    for _, n in ipairs(store.data.nodes) do by[n.name] = n end
    return by
end
local function name_of(id)
    for _, n in ipairs(store.data.nodes) do if n.id == id then return n.name end end
end

test('proto: X.prototype.m = function → keyed X.m', function ()
    if not ready() then skip 'no javascript parser' end
    local root = extract(table.concat({
        'function Foo() {}',
        'Foo.prototype.bar = function(a) { return a };',
        'Foo.prototype.qux = () => 1;',          -- arrow form
        'App.View.prototype.render = function() {};',  -- namespaced owner → App.View.render
        'obj.notproto = function() {};',         -- NOT a prototype method
    }, '\n'))
    local by = byname()
    ok(by['Foo.bar'], 'Foo.prototype.bar → Foo.bar')
    ok(by['Foo.qux'], 'arrow prototype method Foo.qux')
    ok(by['App.View.render'], 'namespaced App.View.prototype.render → App.View.render')
    -- `obj.notproto = function(){}` IS captured now (a member-target function literal
    -- is a real definition — see js_memberdef_spec), but the property this test guards
    -- is unchanged and is the one that matters here: it is not a CLASS METHOD. It keeps
    -- its receiver in the name, stays `kind = function`, and mints no bare class key,
    -- so it can never seed a false class.
    ok(by['obj.notproto'], 'a member-target literal is captured under its own name')
    eq('function', by['obj.notproto'].kind)
    ok(not by['notproto'],
        'a non-prototype member assignment is NOT collapsed to a class key')
    vim.fn.delete(root, 'rf')
end)

test('proto: this.m() inside a prototype method resolves via B3', function ()
    if not ready() then skip 'no javascript parser' end
    local root = extract(table.concat({
        'function Vec() {}',
        'Vec.prototype.len = function() { return 1 };',
        'Vec.prototype.norm = function() { return this.len() };',  -- this.len -> Vec.len
        -- an unrelated same-named len keeps the plain resolver from getting it
        'function Str() {}',
        'Str.prototype.len = function() { return 0 };',
    }, '\n'))
    local c
    for _, cc in ipairs(store.data.calls or {}) do if cc.full == 'this.len' then c = cc end end
    ok(c and c.to, 'this.len() resolved')
    eq('Vec.len', name_of(c.to), 'typed to the enclosing prototype class Vec')
    ok(c.inferred, '~ tier')
    vim.fn.delete(root, 'rf')
end)

test('proto: TS prototype methods key the same way', function ()
    if not ready('typescript') then skip 'no typescript parser' end
    local root = extract(
        'function W() {}\nW.prototype.draw = function(): void {};', 'ts')
    ok(byname()['W.draw'], 'TS W.prototype.draw → W.draw')
    vim.fn.delete(root, 'rf')
end)
