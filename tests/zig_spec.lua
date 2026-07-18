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
