-- THE TRANSLATION CONFORMANCE SUITE (CART-1711, flowpath PLAN.md Phase T item T4). The Lean checker validates flowtype's
-- solve against the IR flowtype emits, so it cannot see a value route the translation leaves out: completeness is
-- TESTED, here. One fixture per value route (tests/fixtures/routes/: the Lean model's R1-R20 that move values, the
-- routes of CART-1699 / 1705 / 1707 / 1708) — classes A and B with a method m, a function whose parameter p gets `a`
-- by an ordinary call and `b` by the route. Each fixture is
--   RUN on every Lua version its header claims (`-- route: … | versions: 51 54 jit nvim`), its runtime copy
--     instrumented to say which of A.m / B.m ran (_harness.lua) — B.m must run, or the fixture does not exercise its
--     route (an interpreter missing here skips that version, by name);
--   ANALYSED in every worklist order, closed and open: a WHOLE answer for p:m() the run falsifies — exact, not
--     partial, without a method that ran — fails the suite. With no runtime (versions: none — code outside the tree,
--     which no run here has), the answer must not be a whole exact A.m;
--   DUMPED (CART-1710): the route's IR is closed against the solve but for a named class, and complete.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local flowtype = require 'cartograph.flowtype'

local DIR = 'tests/fixtures/routes'
local LUA = { ['51'] = 'lua5.1', ['54'] = 'lua5.4', jit = 'luajit', nvim = vim.v.progpath }

local function run(ver, file)
    local exe = LUA[ver]
    if vim.fn.executable(exe) ~= 1 then return nil, exe .. ' is not installed' end
    local cmd = ver == 'nvim' and { exe, '--headless', '-u', 'NONE', '-l', DIR .. '/_harness.lua', file }
        or { exe, DIR .. '/_harness.lua', file }
    local r = vim.system(cmd, { text = true, timeout = 20000 }):wait()
    local ran = ((r.stdout or '') .. (r.stderr or '')):match('RAN ([^\n]*)')
    if not ran then return nil, ('%s gave no report: %s'):format(ver, (r.stderr or ''):sub(1, 200)) end
    return { A = ran:find('^A') ~= nil, B = ran:match('^A?B') ~= nil, err = ran:match('ERR (.*)') }
end

local names = {}
for name, t in vim.fs.dir(DIR) do
    if t == 'file' and name:match('%.lua$') and not name:match('^_') then names[#names + 1] = name end
end
table.sort(names)

for _, name in ipairs(names) do
    local file = DIR .. '/' .. name
    local first = io.open(file):read('*l')
    local route, versions = first:match('^%-%- route: (.-) | versions: (.*)$')
    test(('routes: %s — %s'):format(name:gsub('%.lua$', ''), route or '?'), function ()
        if not parser_available('lua') then skip 'no lua parser' end
        ok(route and versions, 'the header names the route and its versions: ' .. first)
        -- the run
        local ran, skipped = { A = false, B = false }, {}
        if versions ~= 'none' then
            for ver in versions:gmatch('%S+') do
                local r, why = run(ver, file)
                if not r then skipped[#skipped + 1] = why
                else
                    ok(r.B, ('%s on %s: B.m never ran — the fixture does not exercise its route (%s)'):format(name, ver, tostring(r.err)))
                    ran.A, ran.B = ran.A or r.A, ran.B or r.B
                end
            end
        end
        -- the analysis
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, 'p')
        vim.fn.writefile(vim.fn.readfile(file), root .. '/m.lua')
        store.ingest(ts.extract(root))
        local callrec = require 'cartograph.callrec'
        local call
        for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'p:m' then call = c end end
        ok(call and call.refused, 'p:m() is ambiguous')
        -- (every worklist ORDER: which of two paths carries a route is the schedule's choice, and a path only one order
        -- takes is pinned by that order)
        for _, open in ipairs { false, true } do
            for _, order in ipairs { 'desc', 'asc', 'lifo', 'fifo' } do
                local v = flowtype.solve(store, { open = open, order = order }).verdict(call)
                if v and v.kind == 'exact' and not v.partial then
                    local has = {}
                    for _, t in ipairs(v.targets) do has[tostring(t):match('::(%a)%.m@') or ''] = true end
                    local where = ('%s %s %s'):format(name, open and 'open' or 'closed', order)
                    if versions == 'none' then ok(has.B, where .. ': a whole exact A.m where unknown code may pass b: ' .. vim.inspect(v)) end
                    ok(not (ran.B and not has.B), where .. ': a WHOLE answer the run falsifies (B.m ran): ' .. vim.inspect(v))
                    ok(not (ran.A and not has.A), where .. ': a WHOLE answer the run falsifies (A.m ran): ' .. vim.inspect(v))
                end
            end
        end
        -- the dump (CART-1710): the IR of the route closed against the solve but for a NAMED class — a divergence, a
        -- contract, a place the Lean model is coarser than Lua — and complete (every variable that holds something written)
        local c = require('cartograph.flowcheck').check(vim.json.decode(flowtype.solve(store, { open = false, dump = true }).dump), 3)
        for k, n in pairs(c.counts) do
            ok(k:find('^divergence:') or k:find('contract:', 1, true) or k:find('(model)', 1, true),
                ('%s: the dump is not closed — %d × %s: %s'):format(name, n, k, table.concat(c.fails, ' | ')))
        end
        eq(0, c.unwritten, name .. ': a variable the IR never writes: ' .. vim.inspect(c.unwritten_ex))
        vim.fn.delete(root, 'rf')
        if #skipped > 0 then print(('  (%s: %s)'):format(name, table.concat(skipped, '; '))) end
    end)
end
