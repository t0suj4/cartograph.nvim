-- Zig language support (v1): the procedural+struct+method family. A `fn` is
-- free or a struct member; `const T = struct { fn m() }` keys the member `T.m`;
-- calls resolve free functions and struct methods. Receiver typing (`x.m()` →
-- T.m) and @import module binding are a banked arc, not v1.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'zig')
end

local function write(root, name, lines)
    local fd = assert(io.open(root .. '/' .. name, 'w'))
    fd:write(table.concat(lines, '\n')); fd:close()
end

local function extract(root)
    store.ingest(ts.extract(root))
    local byname, calls = {}, {}
    for _, n in ipairs(store.data.nodes) do byname[n.name] = n end
    for _, c in ipairs(store.data.calls or {}) do calls[#calls + 1] = c end
    return byname, calls
end

test('zig: free fn and struct-member fn (keyed T.method)', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.zig', {
        'const Vec = struct {',
        '    x: u32,',
        '    pub fn init(v: u32) Vec {',   -- member → Vec.init
        '        return Vec{ .x = v };',
        '    }',
        '};',
        'fn helper() void {}',              -- free fn → helper
    })
    local by = extract(root)
    ok(by['Vec.init'], 'struct member keyed Vec.init')
    eq('method', by['Vec.init'].kind)
    ok(by['helper'], 'free fn stays bare helper')
    eq('function', by['helper'].kind)
    vim.fn.delete(root, 'rf')
end)

test('zig: a free call resolves to its function', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'b.zig', {
        'fn doThing() void {}',
        'pub fn main() void {',
        '    doThing();',                   -- → doThing
        '}',
    })
    local by, calls = extract(root)
    local hit
    for _, c in ipairs(calls) do if c.callee == 'doThing' then hit = c end end
    ok(hit and hit.to == by['doThing'].id, 'doThing() resolved to the free fn')
    vim.fn.delete(root, 'rf')
end)

test('zig-R5: a pointer-receiver method is keyed by its receiver type', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'foo.zig', {
        'const Foo = @This();',
        'pub fn greet(self: *Foo) void {}',    -- first param *Foo → Foo.greet
        'pub fn run(self: *Foo) void {',
        '    self.greet();',                    -- self:*Foo → keyed Foo.greet
        '}',
    })
    local by, calls = extract(root)
    ok(by['Foo.greet'], 'pointer-receiver method keyed Foo.greet')
    local hit
    for _, c in ipairs(calls) do if c.callee == 'greet' then hit = c end end
    ok(hit and hit.to == by['Foo.greet'].id,
        'self.greet() (self:*Foo) resolved to Foo.greet')
    vim.fn.delete(root, 'rf')
end)

test('zig value-recv dual-key: a pointer caller finds a value-receiver method', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'baz.zig', {
        'const Baz = @This();',
        'pub fn size(self: Baz) u32 { return 0; }',   -- VALUE receiver → bare `size`
        'pub fn run(self: *Baz) u32 {',
        '    return self.size();',                      -- self:*Baz keys Baz.size (exact-only)
        '}',
    })
    local by, calls = extract(root)
    ok(by['size'], 'value-receiver method keeps its bare name `size`')
    local hit
    for _, c in ipairs(calls) do if c.callee == 'size' then hit = c end end
    ok(hit and hit.to == by['size'].id,
        'self.size() (self:*Baz) resolves to the value-recv method via the dual key')
    vim.fn.delete(root, 'rf')
end)

test('zig value-recv dual-key: a value arg is NOT a receiver (constructor trap)', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'w.zig', {
        'const Allocator = @This();',
        'pub fn build(gpa: Allocator) void {}',        -- gpa is an ARG, not a `self`/`allocator`
        'pub fn use() void {',
        '    Allocator.build();',                       -- PascalCase recv keys Allocator.build
        '}',
    })
    local _, calls = extract(root)
    local hit
    for _, c in ipairs(calls) do if c.callee == 'build' then hit = c end end
    ok(hit and not hit.to,
        'build(gpa: Allocator) is NOT dual-keyed Allocator.build — gpa is an arg')
    vim.fn.delete(root, 'rf')
end)

test('zig-R5: a PascalCase receiver keys the call by the type itself', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'pt.zig', {
        'const Point = struct {',
        '    pub fn make() Point { return .{}; }',  -- const-struct → Point.make
        '};',
        'pub fn build() void {',
        '    _ = Point.make();',                     -- Point receiver → Point.make
        '}',
    })
    local by, calls = extract(root)
    ok(by['Point.make'], 'struct member keyed Point.make')
    local hit
    for _, c in ipairs(calls) do if c.callee == 'make' then hit = c end end
    ok(hit and hit.to == by['Point.make'].id,
        'Point.make() resolved to the type method')
    vim.fn.delete(root, 'rf')
end)

test('zig @import: a PascalCase alias resolves the member to the imported file', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'foo.zig', { 'pub fn make() void {}' })
    write(root, 'main.zig', {
        'const Foo = @import("foo.zig");',
        'pub fn run() void {',
        '    Foo.make();',                       -- Foo bound to foo.zig → make
        '}',
    })
    local by, calls = extract(root)
    local hit
    for _, c in ipairs(calls) do if c.callee == 'make' then hit = c end end
    ok(hit and hit.to == by['make'].id,
        'Foo.make() resolved to foo.zig::make via the @import bind')
    vim.fn.delete(root, 'rf')
end)

test('zig @import: a lowercase alias resolves too (receiver preserved)', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'util.zig', { 'pub fn helper() void {}' })
    write(root, 'app.zig', {
        'const util = @import("util.zig");',
        'pub fn go() void {',
        '    util.helper();',                    -- lowercase alias → util.zig
        '}',
    })
    local by, calls = extract(root)
    local hit
    for _, c in ipairs(calls) do if c.callee == 'helper' then hit = c end end
    ok(hit and hit.to == by['helper'].id,
        'util.helper() resolved to util.zig::helper via the lowercase @import bind')
    vim.fn.delete(root, 'rf')
end)

test('zig chain: root.Type.method() resolves cross-file via the chain post-pass', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'lib.zig', {
        'pub const Thing = struct {',
        '    pub fn run(self: Thing) void { _ = self; }',
        '};',
        'pub const Other = struct {',
        '    pub fn run(self: Other) void { _ = self; }',   -- same method, DIFFERENT type
        '};',
    })
    write(root, 'main.zig', {
        'const lib = @import("lib.zig");',
        'pub fn go(t: lib.Thing) void {',
        '    lib.Thing.run(t);',   -- chain: bare `run` is ambiguous, `Thing.run` is unique
        '}',
    })
    local by, calls = extract(root)
    local hit
    for _, c in ipairs(calls) do if c.callee == 'run' then hit = c end end
    ok(hit and hit.to == by['Thing.run'].id,
        'lib.Thing.run(t) resolved to lib.zig::Thing.run via the chain type')
    vim.fn.delete(root, 'rf')
end)

test('zig chain: an instance chain (lowercase penult) carries no chainty', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'inst.zig', {
        'pub fn go(x: anytype) void {',
        '    x.data.process();',   -- lowercase penult `data` → field, not a type
        '}',
    })
    local _, calls = extract(root)
    local hit
    for _, c in ipairs(calls) do if c.callee == 'process' then hit = c end end
    ok(hit and not hit.chainty,
        'x.data.process() (lowercase penult) is left for field-typing — no chainty')
    vim.fn.delete(root, 'rf')
end)

test('zig field chain: root.field.method() resolves via the field type, file-bound', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'thing.zig', { 'pub fn go(x: u32) void { _ = x; }' })
    write(root, 'other.zig', { 'pub fn go(x: u32) void { _ = x; }' }) -- collide: bare `go` ambiguous
    write(root, 'owner.zig', {
        'const Thing = @import("thing.zig");',
        'const Owner = struct {',
        '    t: Thing,',
        '    pub fn use(self: *Owner) void {',
        '        self.t.go(1);', -- chain: Owner.t (Thing → thing.zig) . go
        '    }',
        '};',
    })
    local _, calls = extract(root)
    local go_thing
    for _, n in ipairs(store.data.nodes) do
        if n.name == 'go' and n.file:match('thing%.zig$') then go_thing = n end
    end
    local hit
    for _, c in ipairs(calls) do if c.callee == 'go' then hit = c end end
    ok(hit and go_thing and hit.to == go_thing.id,
        'self.t.go() resolved to thing.zig::go via the field type + @import bind (not other.zig)')
    vim.fn.delete(root, 'rf')
end)

test('zig local typing: const x = param.field; x.method() resolves via the field type', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'sema.zig', { 'pub fn typeOf(x: u32) void { _ = x; }' })
    write(root, 'other.zig', { 'pub fn typeOf(x: u32) void { _ = x; }' }) -- collide → bare ambiguous
    write(root, 'use.zig', {
        'const Sema = @import("sema.zig");',
        'const Analysis = struct {',
        '    sema: Sema,',
        '    pub fn run(self: *Analysis) void {',
        '        const s = self.sema;', -- local s : Sema (from param self's field)
        '        s.typeOf(1);',         -- s.typeOf() → Sema.typeOf@sema.zig (not other.zig)
        '    }',
        '};',
    })
    local _, calls = extract(root)
    local tgt
    for _, n in ipairs(store.data.nodes) do
        if n.name == 'typeOf' and n.file:match('sema%.zig$') then tgt = n end
    end
    local hit
    for _, c in ipairs(calls) do if c.callee == 'typeOf' then hit = c end end
    ok(hit and tgt and hit.to == tgt.id,
        'const s = self.sema; s.typeOf() resolved to sema.zig::typeOf via local field typing')
    vim.fn.delete(root, 'rf')
end)

test('zig: pub fn is exported, plain fn is not', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'c.zig', {
        'pub fn api() void {}',
        'fn internal() void {}',
    })
    local by = extract(root)
    ok(by['api'] and by['api'].exported == true, 'pub fn api → exported')
    ok(by['internal'] and by['internal'].exported == false, 'plain fn → not exported')
    vim.fn.delete(root, 'rf')
end)

local function why_of(calls, callee)
    for _, c in ipairs(calls) do
        if c.callee == callee then return c.ext and c.ext.why, c end
    end
end

test('zig std-alias: bare `const assert = std.debug.assert; assert()` → std-alias face', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.zig', {
        'const std = @import("std");',
        'const assert = std.debug.assert;',   -- fn alias
        'const mem = std.mem;',               -- namespace alias
        'pub fn go(x: []const u8, y: []const u8) void {',
        '    assert(x.len == y.len);',         -- bare std-alias call
        '    _ = mem.eql(u8, x, y);',          -- namespace-alias receiver call
        '}',
    })
    local _, calls = extract(root)
    eq(why_of(calls, 'assert'), 'std-alias')
    eq(why_of(calls, 'eql'), 'std-alias')
    vim.fn.delete(root, 'rf')
end)

test('zig std-alias: the binding is AUTHORITATIVE over a same-named project def', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- a project fn named `assert` exists in another file; the call site aliases
    -- std's assert, so the const binding shadows it — the call must NOT resolve
    -- to the project def, it is disposed std-alias.
    write(root, 'other.zig', { 'pub fn assert(b: bool) void { _ = b; }' })
    write(root, 'use.zig', {
        'const std = @import("std");',
        'const assert = std.debug.assert;',
        'pub fn go(b: bool) void { assert(b); }',
    })
    local _, calls = extract(root)
    local why, c = why_of(calls, 'assert')
    eq(why, 'std-alias')
    ok(c and not c.to, 'std-aliased call did not resolve to the project assert')
    vim.fn.delete(root, 'rf')
end)

test('zig std-alias: a NON-std alias root is NOT disposed (soundness)', function ()
    if not ready() then skip 'no zig parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- `foo` is a project @import, not std → foo.bar() must stay a normal
    -- (module-alias) resolution, never the std-alias face.
    write(root, 'foo.zig', { 'pub fn bar() void {}' })
    write(root, 'main.zig', {
        'const std = @import("std");',
        'const foo = @import("foo.zig");',
        'pub fn go() void { foo.bar(); }',
    })
    local _, calls = extract(root)
    ok(why_of(calls, 'bar') ~= 'std-alias',
        'project module-alias receiver is not mislabeled std-alias')
    vim.fn.delete(root, 'rf')
end)
