-- Ruby R2 implicit-self keying: a bare call (no receiver) or explicit `self.m`
-- inside a method dispatches on `self` → the enclosing class/module. In an
-- INSTANCE method body self is an instance → `Owner#m`; in a singleton
-- context (`def self.x` / `class << self`) self is the class → `Owner.m`; at
-- pure class-body level a bare call is class-level DSL (R3), left bare.
-- Corpus-wide (classes reopen), HEDGED `~` (dynamic dispatch can hit a
-- subclass override), and exact-or-nothing — an inherited method (mixin /
-- superclass) is an honest frontier (R4), never a tail-guess.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'ruby')
end

local function extract(root)
    store.ingest(ts.extract(root))
    local byname, calls = {}, {}
    for _, n in ipairs(store.data.nodes) do byname[n.name] = n end
    for _, c in ipairs(store.data.calls or {}) do calls[#calls + 1] = c end
    return byname, calls
end

local function find(calls, full)
    for _, c in ipairs(calls) do if c.full == full then return c end end
end

test('R2: bare call in an instance method keys Owner#m and resolves (hedged)', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.rb', {
        'class Worker',
        '  def run',
        '    perform(1)',      -- bare -> Worker#perform
        '  end',
        '  def perform(n)',
        '    n',
        '  end',
        'end',
    })
    local byname, calls = extract(root)
    ok(byname['Worker#perform'], 'instance def keyed Worker#perform')
    local c = find(calls, 'Worker#perform')
    ok(c and c.to == byname['Worker#perform'].id, 'bare perform() resolved to Worker#perform')
    ok(c and c.hedge, 'the edge is hedged (~): dynamic dispatch can override')
    vim.fn.delete(root, 'rf')
end)

test('R2: bare call resolves across files (class reopening)', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'def.rb', {
        'class Account',
        '  def normalize',
        '    1',
        '  end',
        'end',
    })
    write(root, 'use.rb', {
        'class Account',       -- reopened in another file
        '  def save',
        '    normalize()',     -- bare -> Account#normalize (cross-file)
        '  end',
        'end',
    })
    local byname, calls = extract(root)
    local c = find(calls, 'Account#normalize')
    ok(c and c.to == byname['Account#normalize'].id,
        'bare call resolves to the reopened class def in another file')
    vim.fn.delete(root, 'rf')
end)

test('R2: explicit self.m in an instance method keys Owner#m', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'b.rb', {
        'class Node',
        '  def visit',
        '    self.render',       -- explicit self -> Node#render
        '  end',
        '  def render',
        '    1',
        '  end',
        'end',
    })
    local byname, calls = extract(root)
    local c = find(calls, 'Node#render')
    ok(c and c.to == byname['Node#render'].id, 'self.render resolved to Node#render')
    vim.fn.delete(root, 'rf')
end)

test('R2: bare call in `def self.x` keys the singleton Owner.m', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'c.rb', {
        'class Builder',
        '  def self.create',
        '    prepare(1)',        -- singleton self -> Builder.prepare
        '  end',
        '  def self.prepare(n)',
        '    n',
        '  end',
        'end',
    })
    local byname, calls = extract(root)
    ok(byname['Builder.prepare'], 'singleton def keyed Builder.prepare')
    local c = find(calls, 'Builder.prepare')
    ok(c and c.to == byname['Builder.prepare'].id,
        'bare call in def self.create resolved to the singleton Builder.prepare')
    vim.fn.delete(root, 'rf')
end)

test('R2: a class-body-level bare call is NOT keyed (DSL = R3)', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'd.rb', {
        'class Post',
        '  validates(:title)',   -- class-body DSL: NOT Post#validates
        '  def validates(x)',    -- a same-named instance method must NOT capture it
        '    x',
        '  end',
        'end',
    })
    local _, calls = extract(root)
    local c = find(calls, 'Post#validates')
    ok(not c, 'the class-body call was not keyed as an instance self-call')
    vim.fn.delete(root, 'rf')
end)

test('R2→R4: an inherited (mixin) method keys to the enclosing class, then R4 resolves it', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'e.rb', {
        'module Helpers',
        '  def guard(x)',        -- defined on the mixin, keyed Helpers#guard
        '    x',
        '  end',
        'end',
        'class Service',
        '  include Helpers',
        '  def call',
        '    guard(1)',          -- keyed Service#guard by R2; RESOLVED by R4 (mixin)
        '  end',
        'end',
    })
    local byname, calls = extract(root)
    ok(byname['Helpers#guard'], 'the mixin def exists as Helpers#guard')
    local c = find(calls, 'Service#guard')
    ok(c, 'R2 keyed the call to the enclosing class Service#guard')
    -- R2 alone left this an honest frontier; R4 now walks the include chain
    ok(c and c.to == byname['Helpers#guard'].id,
        'R4 resolves the inherited mixin method Service#guard → Helpers#guard')
    vim.fn.delete(root, 'rf')
end)
