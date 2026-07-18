-- Ruby R4 inheritance + mixins: when a bare/self call keyed `C#m` / `C.m`
-- (R2/R3) MISSES because the method is inherited, walk C's ancestors — the
-- superclass chain, `include`/`prepend` modules (instance methods), and
-- `extend` modules (as singleton methods) — for the nearest UNIQUE definition.
-- HEDGED `~` (nearest static ancestor; full MRO + dynamic dispatch unmodeled),
-- unique-or-skip. Recovers the frontiers R2/R3 honestly declined.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'ruby')
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

local function find(calls, full) for _, c in ipairs(calls) do if c.full == full then return c end end end

test('R4 superclass: an inherited instance method resolves up the chain', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.rb', {
        'class Base',
        '  def shared; 1; end',
        'end',
        'class Derived < Base',
        '  def go; shared; end',      -- Derived#shared MISS → Base#shared
        'end',
    })
    local byname, calls = extract(root)
    local c = find(calls, 'Derived#shared')
    ok(c and c.to == byname['Base#shared'].id, 'Derived#shared resolved to Base#shared')
    ok(c and c.inferred, 'hedged (~)')
    vim.fn.delete(root, 'rf')
end)

test('R4 include: a mixin instance method resolves', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'b.rb', {
        'module Helpers',
        '  def helper; 1; end',
        'end',
        'class Service',
        '  include Helpers',
        '  def call; helper; end',    -- Service#helper MISS → Helpers#helper
        'end',
    })
    local byname, calls = extract(root)
    local c = find(calls, 'Service#helper')
    ok(c and c.to == byname['Helpers#helper'].id, 'Service#helper → Helpers#helper (include)')
    vim.fn.delete(root, 'rf')
end)

test('R4 extend: a module method becomes a singleton method', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'c.rb', {
        'module ClassMethods',
        '  def build_it; 1; end',
        'end',
        'class Widget',
        '  extend ClassMethods',
        '  def self.make; build_it; end',   -- Widget.build_it MISS → ClassMethods#build_it
        'end',
    })
    local byname, calls = extract(root)
    local c = find(calls, 'Widget.build_it')
    ok(c and c.to == byname['ClassMethods#build_it'].id,
        'Widget.build_it → ClassMethods#build_it (extend → singleton)')
    vim.fn.delete(root, 'rf')
end)

test('R4 transitive: a two-level superclass chain resolves', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'd.rb', {
        'class A',
        '  def deep; 1; end',
        'end',
        'class B < A',
        'end',
        'class C < B',
        '  def go; deep; end',        -- C#deep MISS → (B) → A#deep
        'end',
    })
    local byname, calls = extract(root)
    local c = find(calls, 'C#deep')
    ok(c and c.to == byname['A#deep'].id, 'C#deep resolved transitively to A#deep')
    vim.fn.delete(root, 'rf')
end)

test('R4 soundness: two mixins defining the same method → ambiguous, unresolved', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'e.rb', {
        'module M1',
        '  def clash; 1; end',
        'end',
        'module M2',
        '  def clash; 2; end',
        'end',
        'class Both',
        '  include M1',
        '  include M2',
        '  def go; clash; end',       -- ambiguous: M1#clash vs M2#clash → skip
        'end',
    })
    local _, calls = extract(root)
    local c = find(calls, 'Both#clash')
    ok(c and not c.to, 'ambiguous inherited method is left unresolved (honest)')
    vim.fn.delete(root, 'rf')
end)

test('R4 super: bare `super` resolves to the ancestor same-named method', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 's1.rb', {
        'class Base',
        '  def process(x); x; end',
        'end',
        'class Derived < Base',
        '  def process(x)',
        '    super',              -- → Base#process
        '  end',
        'end',
    })
    local byname, calls = extract(root)
    local c
    for _, x in ipairs(calls) do if x.callee == 'super' then c = x end end
    ok(c, '`super` captured as a call')
    ok(c and c.to == byname['Base#process'].id, 'super → Base#process (ancestor, not self)')
    ok(c and c.inferred, 'hedged (~)')
    vim.fn.delete(root, 'rf')
end)

test('R4 super: singleton `super` walks the superclass singleton chain', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 's2.rb', {
        'class Sub',
        '  def self.attach; 1; end',
        'end',
        'class Log < Sub',
        '  def self.attach',
        '    super(1)',           -- → Sub.attach (singleton)
        '  end',
        'end',
    })
    local byname, calls = extract(root)
    local c
    for _, x in ipairs(calls) do if x.callee == 'super' then c = x end end
    ok(c and c.to == byname['Sub.attach'].id, 'singleton super → Sub.attach')
    vim.fn.delete(root, 'rf')
end)

test('R4 super: an external ancestor leaves super an honest frontier', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 's3.rb', {
        'class Widget < ApplicationRecord',   -- ApplicationRecord not in corpus
        '  def save',
        '    super',
        '  end',
        'end',
    })
    local _, calls = extract(root)
    local c
    for _, x in ipairs(calls) do if x.callee == 'super' then c = x end end
    ok(c and not c.to, 'super to an external ancestor stays unresolved (honest)')
    vim.fn.delete(root, 'rf')
end)

test('R4: resolves across files (reopened ancestor)', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'base.rb', {
        'class Animal',
        '  def breathe; 1; end',
        'end',
    })
    write(root, 'dog.rb', {
        'class Dog < Animal',
        '  def act; breathe; end',    -- cross-file → Animal#breathe
        'end',
    })
    local byname, calls = extract(root)
    local c = find(calls, 'Dog#breathe')
    ok(c and c.to == byname['Animal#breathe'].id, 'cross-file superclass resolution')
    vim.fn.delete(root, 'rf')
end)
