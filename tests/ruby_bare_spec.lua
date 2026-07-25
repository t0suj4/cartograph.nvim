-- Ruby "open ceiling" fix: bare no-paren calls (`save`, an attribute read)
-- parse as `identifier`, not `call`, so the calls query misses them —
-- scan_bare_calls surfaces the ones that are METHOD CALLS, applying ruby's
-- var-vs-call rule (a bare name is a local read iff a local of that name is
-- bound in the enclosing method: param, block/lambda param, rescue var,
-- for/pattern capture, or assignment LHS). Survivors key via R2 (Owner#m).
-- Soundness bar: NEVER emit a call for a local-variable read.

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

local function bare(calls, callee)
    for _, c in ipairs(calls) do if c.bare and c.callee == callee then return c end end
end

test('ceiling: a bare no-paren call is captured and resolves to the self method', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.rb', {
        'class Job',
        '  def run',
        '    perform',            -- bare no-paren call -> Job#perform
        '  end',
        '  def perform',
        '    1',
        '  end',
        'end',
    })
    local byname, calls = extract(root)
    local c = bare(calls, 'perform')
    ok(c, 'bare `perform` captured as a call')
    ok(c and c.to == byname['Job#perform'].id, 'resolved to Job#perform')
    vim.fn.delete(root, 'rf')
end)

test('ceiling: a bare call in expression position is captured', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'b.rb', {
        'class Calc',
        '  def total',
        '    subtotal + 1',       -- subtotal (in a binary) -> Calc#subtotal
        '  end',
        '  def subtotal',
        '    2',
        '  end',
        'end',
    })
    local byname, calls = extract(root)
    local c = bare(calls, 'subtotal')
    ok(c and c.to == byname['Calc#subtotal'].id, 'bare `subtotal` in `subtotal + 1` resolved')
    vim.fn.delete(root, 'rf')
end)

test('ceiling SOUNDNESS: a local variable read is NOT a call', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'c.rb', {
        'class C',
        '  def run',
        '    total = 1',          -- local binding
        '    total',              -- READ of the local, NOT a call
        '  end',
        '  def total',            -- a same-named method exists (the trap)
        '    9',
        '  end',
        'end',
    })
    local _, calls = extract(root)
    ok(not bare(calls, 'total'), 'the local `total` read was not captured as a call')
    vim.fn.delete(root, 'rf')
end)

test('ceiling SOUNDNESS: params and rescue variables are locals, not calls', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'd.rb', {
        'class C',
        '  def run(opts)',
        '    begin',
        '      work',
        '    rescue => err',
        '      opts',              -- param read, not a call
        '      err',               -- rescue var read, not a call
        '    end',
        '  end',
        '  def opts; end',         -- same-named methods (the trap)
        '  def err; end',
        'end',
    })
    local _, calls = extract(root)
    ok(not bare(calls, 'opts'), 'param `opts` not captured as a call')
    ok(not bare(calls, 'err'), 'rescue var `err` not captured as a call')
    vim.fn.delete(root, 'rf')
end)

test('ceiling SOUNDNESS: block params and for-vars are locals', function ()
    if not ready() then skip 'no ruby parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'e.rb', {
        'class C',
        '  def run',
        '    [1].each do |item|',
        '      item',              -- block param read, not a call
        '    end',
        '  end',
        '  def item; end',         -- same-named method (the trap)
        'end',
    })
    local _, calls = extract(root)
    ok(not bare(calls, 'item'), 'block param `item` not captured as a call')
    vim.fn.delete(root, 'rf')
end)
