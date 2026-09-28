-- A DEPLOYMENT PLAN (CART-0154) over the local deployment world: release (an immutable content-addressed value, a
-- cross-world create journaled IN THE TARGET) -> switch (COMPENSABLE) -> the health PREMISE. The oracle is the target
-- directory itself: after a failed health check under rollback it is byte-for-byte what it was — CURRENT back, the
-- release gone — and a healthy deploy is idempotent.
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local tb = require 'cartograph.toolbelt'
local D = require 'cartograph.deploy'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') end

local src, target
local function put(root, rel, s) local d = (root .. '/' .. rel):match('^(.*)/[^/]*$'); vim.fn.mkdir(d, 'p'); local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(s); fd:close() end
local function snap(root)
    local out = {}
    for name, ty in vim.fs.dir(root, { depth = 20 }) do if ty == 'file' then local fd = io.open(root .. '/' .. name); out[name] = fd:read('a'); fd:close() end end
    return vim.inspect(out)
end
local function fresh(health)
    src = vim.fn.tempname(); vim.fn.mkdir(src, 'p')
    put(src, 'app/index.txt', 'v2\n'); put(src, 'app/health', health .. '\n'); put(src, 'm.lua', 'return 1\n')
    store.ingest(ts.extract(src))
    target = vim.fn.tempname() .. '-deploy'
    put(target, 'releases/v1/health', 'ok\n'); put(target, 'CURRENT', 'v1\n')
end
local function deploy(opts) return tb.run(store, 'deploy', { from = 'app', target = target, approve = 'yes' }, opts) end

test('deploy: a healthy release deploys; the content id names it; re-deploying the same source is EMPTY', function ()
    if not ready() then skip 'no lua parser' end
    fresh('ok')
    local _, id = D.content_id(src .. '/app')
    local r = deploy({ apply = true })
    eq('done', r.status, tostring(r.why)); eq(id, D.current(target))
    eq('v2\n', io.open(target .. '/releases/' .. id .. '/index.txt'):read('a'))
    local again = deploy({ apply = true })
    eq('done', again.status, tostring(again.why)); eq(0, again.applied, 'the same content is the same release: nothing to do')
end)

test('deploy: a FAILED health check under rollback COMPENSATES the switch and UNDOES the release — the target is as it was', function ()
    if not ready() then skip 'no lua parser' end
    fresh('failing')
    local before = snap(target)
    local r = deploy({ apply = true, on_stop = 'rollback' })
    eq('failed', r.status); ok(tostring(r.why):find('deploy-health', 1, true), tostring(r.why))
    eq(2, r.rolled_back, tostring(r.rollback_refused or r.rollback_failed))
    eq('v1', D.current(target), 'CURRENT is back on the previous release')
    eq(before, snap(target), 'byte for byte: the new release is gone too (the target world\'s own journal)')
end)

test('deploy: without approval the plan stops at the FIRST gate, before the target world is touched', function ()
    if not ready() then skip 'no lua parser' end
    fresh('ok')
    local before = snap(target)
    local r = tb.run(store, 'deploy', { from = 'app', target = target }, { apply = true })
    eq('stopped', r.status); eq('target-write', r.options and r.options[1] and r.options[1].kind)
    eq(before, snap(target))
end)