-- Ruby R1 constant-receiver keying: `Foo.bar` / `A::B.baz` name a SINGLETON
-- (class/module) method of the receiver constant, so the call keys to
-- `Receiver.method` and exact-matches the singleton def. Two supporting
-- facts verified here: (1) a `def m` inside `class << self` is keyed as a
-- SINGLETON `Owner.m` (not instance `Owner#m`); (2) receiver evidence is
-- exact-or-nothing — `Foo.bar` never tail-collides onto an unrelated `X#bar`
-- (arc trap #1). identifier/self/ivar receivers are R2/R5, left bare.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'ruby')
end

local function write(root, name, lines)
    local fd = assert(io.open(root .. '/' .. name, 'w'))
    fd:write(table.concat(lines, '\n'))
    fd:close()
end

local function extract(root)
    store.ingest(ts.extract(root))
    local byname, byid, calls = {}, {}, {}
    for _, n in ipairs(store.data.nodes) do byname[n.name] = n; byid[n.id] = n end
    for _, c in ipairs(store.data.calls or {}) do calls[#calls + 1] = c end
    return byname, byid, calls
end

test('R1: def self.m keyed Owner.m; Owner.m() exact-matches it', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.rb', {
        'class Registry',
        '  def self.lookup(k)',   -- singleton -> Registry.lookup
        '    k',
        '  end',
        'end',
        'def use',
        '  Registry.lookup(1)',   -- exact -> Registry.lookup
        'end',
    })
    local byname, byid, calls = extract(root)
    ok(byname['Registry.lookup'], 'def self.lookup keyed Registry.lookup')
    local hit
    for _, c in ipairs(calls) do
        if c.full == 'Registry.lookup' then hit = c end
    end
    ok(hit, 'Registry.lookup() keyed with the constant receiver')
    ok(hit and hit.to == byname['Registry.lookup'].id,
        'resolved to the singleton def by exact match')
    vim.fn.delete(root, 'rf')
end)

test('R1: `class << self` method is keyed as a singleton Owner.m', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'b.rb', {
        'module ForkTracker',
        '  class << self',
        '    def after_fork_callback',   -- singleton via class<<self
        '      1',
        '    end',
        '  end',
        'end',
        'def run',
        '  ForkTracker.after_fork_callback',
        'end',
    })
    local byname, _, calls = extract(root)
    ok(byname['ForkTracker.after_fork_callback'],
        'class<<self method keyed with `.` (singleton), not `#`')
    ok(not byname['ForkTracker#after_fork_callback'],
        'NOT mis-keyed as an instance method')
    local hit
    for _, c in ipairs(calls) do
        if c.full == 'ForkTracker.after_fork_callback' then hit = c end
    end
    ok(hit and hit.to == byname['ForkTracker.after_fork_callback'].id,
        'the class-method call resolves to the class<<self def')
    vim.fn.delete(root, 'rf')
end)

test('R1: A::B.baz keys on the tail constant B', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'c.rb', {
        'module A',
        '  class B',
        '    def self.baz',   -- -> B.baz (defs key by innermost class name)
        '      1',
        '    end',
        '  end',
        'end',
        'def go',
        '  A::B.baz',
        'end',
    })
    local byname, _, calls = extract(root)
    ok(byname['B.baz'], 'nested singleton keyed by innermost class name B.baz')
    local hit
    for _, c in ipairs(calls) do
        if c.full == 'B.baz' then hit = c end
    end
    ok(hit and hit.to == byname['B.baz'].id,
        'A::B.baz resolves via the tail constant key B.baz')
    vim.fn.delete(root, 'rf')
end)

test('R1 soundness: Foo.bar does NOT tail-collide onto an unrelated X#bar', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- Inflector.camelize called inside String#camelize: the OLD promiscuous
    -- tail match wrongly bound it to the enclosing String#camelize. R1 keys
    -- Inflector.camelize; there is no such def, so it stays an honest
    -- frontier — NOT resolved to String#camelize.
    write(root, 'd.rb', {
        'class String',
        '  def camelize',
        '    Inflector.camelize(self)',   -- must NOT resolve to String#camelize
        '  end',
        'end',
    })
    local byname, _, calls = extract(root)
    ok(byname['String#camelize'], 'the instance def exists as String#camelize')
    local call
    for _, c in ipairs(calls) do
        if c.full == 'Inflector.camelize' then call = c end
    end
    ok(call, 'Inflector.camelize keyed with the constant receiver')
    ok(not (call and call.to), 'not resolved — an honest frontier, no wrong tail-match')
    vim.fn.delete(root, 'rf')
end)

test('R1: a stdlib constant call (File.read) stays an honest frontier', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'e.rb', {
        'class ConfigurationFile',
        '  def read',
        '    File.read(path)',   -- File is stdlib: must not bind to #read
        '  end',
        'end',
    })
    local _, _, calls = extract(root)
    local call
    for _, c in ipairs(calls) do
        if c.full == 'File.read' then call = c end
    end
    ok(call, 'File.read keyed with the constant receiver')
    ok(not (call and call.to), 'File.read not bound to the enclosing #read')
    vim.fn.delete(root, 'rf')
end)
