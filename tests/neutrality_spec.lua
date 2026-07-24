-- Refactor-neutrality checker: diff per-function behavior witnesses (df shape + params
-- + callees, file/line-independent) between a baseline and the current graph. A pure MOVE
-- keeps the witness → neutral; a body rewrite drifts; a rename is recovered by witness.

local N = require 'cartograph.neutrality'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ingest(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for name, src in pairs(files) do
        local fd = assert(io.open(root .. '/' .. name, 'w')); fd:write(src); fd:close()
    end
    store.ingest(ts.extract(root))
    return root
end
-- rewrite the SAME root's files then re-ingest (a refactor in place)
local function rewrite(root, files)
    for _, f in ipairs(vim.fn.readdir(root)) do vim.fn.delete(root .. '/' .. f) end
    for name, src in pairs(files) do
        local fd = assert(io.open(root .. '/' .. name, 'w')); fd:write(src); fd:close()
    end
    store.ingest(ts.extract(root))
end

local FOO = 'local function foo(x)\n  local y = trim(x)\n  local z = upper(y)\n  return z\nend\n'

test('neutrality: a function MOVED to another file is neutral (witness preserved)', function ()
    local root = ingest { ['a.lua'] = FOO .. 'return foo\n', ['b.lua'] = 'return 1\n' }
    N.snapshot(store)
    -- move foo verbatim from a.lua to b.lua
    rewrite(root, { ['a.lua'] = 'return 1\n', ['b.lua'] = FOO .. 'return foo\n' })
    local cmp = N.check(store)
    ok(vim.tbl_contains(cmp.neutral, 'foo'), 'a verbatim move keeps foo neutral')
    eq(0, #cmp.drifted, 'nothing drifted')
    vim.fn.delete(root, 'rf')
end)

test('neutrality: a body REWRITE drifts (a rewrite, not a move)', function ()
    local root = ingest { ['a.lua'] = FOO .. 'return foo\n' }
    N.snapshot(store)
    -- change foo's body (extra statement + different callee)
    rewrite(root, { ['a.lua'] =
        'local function foo(x)\n  local y = trim(x)\n  local w = validate(y)\n'
        .. '  local z = lower(w)\n  return z\nend\nreturn foo\n' })
    local cmp = N.check(store)
    local drifted = {}
    for _, d in ipairs(cmp.drifted) do drifted[d.name] = true end
    ok(drifted.foo, 'a body change drifts foo')
    ok(not vim.tbl_contains(cmp.neutral, 'foo'), 'foo is not neutral')
    vim.fn.delete(root, 'rf')
end)

test('neutrality: a RENAME with an unchanged body is recovered', function ()
    local root = ingest { ['a.lua'] = FOO .. 'return foo\n' }
    N.snapshot(store)
    -- rename foo → foo2, body identical (witness preserved)
    rewrite(root, { ['a.lua'] = (FOO:gsub('foo', 'foo2')) .. 'return foo2\n' })
    local cmp = N.check(store)
    local r = cmp.renamed[1]
    ok(r and r.from == 'foo' and r.to == 'foo2', 'foo → foo2 recovered by witness')
    eq(0, #cmp.drifted, 'a rename is not a drift')
    vim.fn.delete(root, 'rf')
end)

test('neutrality: check without a baseline refuses honestly', function ()
    local root = ingest { ['a.lua'] = FOO }
    N._snap[store.data.root] = nil -- ensure no baseline
    local cmp, why = N.check(store)
    ok(not cmp and why:find('baseline'), 'no baseline → a clear refusal')
    vim.fn.delete(root, 'rf')
end)

test('neutrality: an unchanged graph is entirely neutral; report certifies it', function ()
    local root = ingest { ['a.lua'] = FOO .. 'local function g(a)\n  return foo(a)\nend\nreturn g\n' }
    N.snapshot(store)
    local cmp = N.check(store) -- no change
    eq(0, #cmp.drifted); eq(0, #cmp.removed)
    ok(N.report(cmp)[1]:find('0 DRIFTED'), 'the report headline shows zero drift')
    ok(vim.tbl_contains(N.report(cmp), '✓ every surviving function is behavior-neutral (certified move)'),
        'a clean run is certified')
    vim.fn.delete(root, 'rf')
end)
