-- Ruby R3 attr_* def-emitters: `attr_accessor :foo` DEFINES accessor methods
-- with no `def` keyword. Emit them as real method nodes (`Owner#foo` reader,
-- `Owner#foo=` writer) so calls resolve. attr_reader → reader only, attr_writer
-- → writer only; inside `class << self` they are singleton accessors
-- (`Owner.foo`). An explicit `def foo` overrides the generated accessor (ruby:
-- def beats attr_accessor) — the synth node is shadowed, no false ambiguity.

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

test('R3: attr_accessor emits reader Owner#foo and writer Owner#foo=', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.rb', {
        'class User',
        '  attr_accessor :name',
        '  attr_reader :id',
        '  attr_writer :secret',
        'end',
    })
    local byname = extract(root)
    ok(byname['User#name'] and byname['User#name'].synth, 'reader User#name (synth)')
    ok(byname['User#name='] and byname['User#name='].synth, 'writer User#name=')
    ok(byname['User#id'], 'attr_reader emits the reader')
    ok(not byname['User#id='], 'attr_reader emits NO writer')
    ok(byname['User#secret='], 'attr_writer emits the writer')
    ok(not byname['User#secret'], 'attr_writer emits NO reader')
    vim.fn.delete(root, 'rf')
end)

test('R3: a bare read of an attr resolves to the emitted accessor', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'b.rb', {
        'class Post',
        '  attr_reader :title',
        '  def describe',
        '    title',              -- bare read -> Post#title (via the ceiling + R3)
        '  end',
        'end',
    })
    local byname, calls = extract(root)
    local c
    for _, x in ipairs(calls) do if x.bare and x.callee == 'title' then c = x end end
    ok(c, 'bare `title` captured as a call')
    ok(c and c.to == byname['Post#title'].id, 'resolved to the emitted Post#title accessor')
    vim.fn.delete(root, 'rf')
end)

test('R3: attr_accessor inside `class << self` emits singleton accessors', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'c.rb', {
        'class Config',
        '  class << self',
        '    attr_accessor :root',
        '  end',
        'end',
    })
    local byname = extract(root)
    ok(byname['Config.root'], 'singleton reader Config.root (dot, not hash)')
    ok(byname['Config.root='], 'singleton writer Config.root=')
    ok(not byname['Config#root'], 'NOT an instance accessor')
    vim.fn.delete(root, 'rf')
end)

test('R3: an explicit def overrides attr_accessor (no false ambiguity)', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'd.rb', {
        'class Widget',
        '  attr_accessor :size',   -- synth Widget#size
        '  def size',              -- explicit def overrides it
        '    @size * 2',
        '  end',
        '  def render',
        '    size',                -- must resolve to the explicit def, not ambiguous
        '  end',
        'end',
    })
    local byname, calls = extract(root)
    local explicit
    for _, n in ipairs(store.data.nodes) do
        if n.name == 'Widget#size' and not n.synth then explicit = n end
    end
    ok(explicit, 'the explicit def Widget#size exists')
    local c
    for _, x in ipairs(calls) do if x.bare and x.callee == 'size' then c = x end end
    ok(c and c.to == explicit.id,
        'bare `size` resolves to the explicit def (synth accessor shadowed)')
    vim.fn.delete(root, 'rf')
end)
