-- Ruby R5 (rescoped, ADDITIVE) constructor/receiver typing: `x = C.new; x.foo`
-- resolves `x.foo` to `C#foo` (own or inherited). Unlike the reverted exact-only
-- R5, this is ADDITIVE — it keeps `full` bare (the file-local heuristic is
-- untouched) and only resolves calls the heuristic left UNRESOLVED. So the test
-- pattern uses a name defined on TWO classes (heuristic → ambiguous → unresolved)
-- and shows ctor-typing DISAMBIGUATE via the receiver's `.new` type. Single-
-- assignment gated (a rebind → ambiguous → skip). HEDGED ~.

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

-- the x.foo call (identifier receiver): callee foo, c.recv set
local function recvcall(calls, recv, callee)
    for _, c in ipairs(calls) do
        if c.recv == recv and c.callee == callee then return c end
    end
end

test('R5: ctor type disambiguates where the file-local heuristic is ambiguous', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.rb', {
        'class Apple',
        '  def peel; 1; end',       -- Apple#peel
        'end',
        'class Banana',
        '  def peel; 2; end',       -- Banana#peel — `peel` is now ambiguous
        'end',
        'def prep',
        '  fruit = Apple.new',
        '  fruit.peel',             -- heuristic ambiguous → R5: fruit is Apple → Apple#peel
        'end',
    })
    local byname, calls = extract(root)
    local c = recvcall(calls, 'fruit', 'peel')
    ok(c, 'the x.foo call captured its receiver (c.recv)')
    ok(c and c.to == byname['Apple#peel'].id, 'fruit.peel → Apple#peel (ctor-typed, disambiguated)')
    ok(c and c.inferred, 'hedged (~)')
    vim.fn.delete(root, 'rf')
end)

test('R5: ctor-typed receiver resolves an INHERITED method', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'b.rb', {
        'class Vehicle',
        '  def start; 1; end',      -- Vehicle#start
        'end',
        'class Boat',
        '  def start; 2; end',      -- another start → ambiguous
        'end',
        'class Car < Vehicle',
        'end',
        'def go',
        '  c = Car.new',
        '  c.start',                -- R5: c is Car → chase → Vehicle#start
        'end',
    })
    local byname, calls = extract(root)
    local c = recvcall(calls, 'c', 'start')
    ok(c and c.to == byname['Vehicle#start'].id, 'c.start → Vehicle#start (ctor + ancestor)')
    vim.fn.delete(root, 'rf')
end)

test('R5 soundness: a rebound local is ambiguous → not ctor-resolved', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'c.rb', {
        'class Cat',
        '  def speak; 1; end',
        'end',
        'class Dog',
        '  def speak; 2; end',
        'end',
        'def noise',
        '  a = Cat.new',
        '  a = Dog.new',            -- rebound → type ambiguous
        '  a.speak',                -- must NOT ctor-resolve (n>1)
        'end',
    })
    local _, calls = extract(root)
    local c = recvcall(calls, 'a', 'speak')
    ok(c and not c.to, 'rebound receiver is not ctor-typed (single-assignment gate)')
    vim.fn.delete(root, 'rf')
end)

test('R5b: an instance variable typed by `@x = C.new` resolves', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'iv.rb', {
        'class Engine',
        '  def rev; 1; end',        -- Engine#rev
        'end',
        'class Motor',
        '  def rev; 2; end',        -- ambiguous `rev`
        'end',
        'class Dashboard',
        '  def initialize',
        '    @engine = Engine.new',
        '  end',
        '  def redline',
        '    @engine.rev',          -- R5b: @engine is Engine → Engine#rev
        '  end',
        'end',
    })
    local byname, calls = extract(root)
    local c = recvcall(calls, '@engine', 'rev')
    ok(c, 'the @ivar.foo call captured its receiver')
    ok(c and c.to == byname['Engine#rev'].id, '@engine.rev → Engine#rev (ivar ctor-typed)')
    vim.fn.delete(root, 'rf')
end)

test('R5: resolves across files (class defined elsewhere)', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'model.rb', {
        'class Account',
        '  def freeze!; 1; end',
        'end',
    })
    write(root, 'other.rb', {
        'class Ledger',
        '  def freeze!; 2; end',    -- ambiguous freeze! across files
        'end',
    })
    write(root, 'svc.rb', {
        'def run',
        '  acct = Account.new',
        '  acct.freeze!',           -- R5: acct is Account → Account#freeze! (cross-file)
        'end',
    })
    local byname, calls = extract(root)
    local c = recvcall(calls, 'acct', 'freeze!')
    ok(c and c.to == byname['Account#freeze!'].id, 'acct.freeze! → Account#freeze! cross-file')
    vim.fn.delete(root, 'rf')
end)
