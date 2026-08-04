-- INVARIANTS THAT ATTACK THEMSELVES (CART-0285). The load-bearing test is the first one: a base run
-- that makes four wrong invariants look true, and an attack that kills all four. A propose-only
-- tool would have shipped those four as knowledge.

local inv = require 'cartograph.invariant'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local SRC = table.concat({
    'local M = {}',                                   -- 1
    -- one branch makes it look like a passthrough that never returns nil. Both are wrong.
    'function M.lookup(k)',                           -- 2
    '    if k == "known" then return k end',           -- 3
    '    return nil',                                 -- 4
    'end',                                            -- 5
    -- genuinely constant, whichever way the guard goes
    'function M.always(x)',                           -- 6
    '    if x > 0 then return "yes" end',              -- 7
    '    return "yes"',                               -- 8
    'end',                                            -- 9
    -- nothing to vary: no forkable condition at all
    'function M.flat(a) return a + 1 end',            -- 10
    'return M',                                       -- 11
}, '\n') .. '\n'

local root
local function proj()
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(SRC); fd:close()
    local d = ts.extract(root); d.root = d.root or root
    store.ingest(d)
end
local function cleanup() if root then vim.fn.delete(root, 'rf'); root = nil end end
local function id_of(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and n.kind == 'function' then return n.id end
    end
end
local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end
local function ids(list)
    local t = {}
    for _, r in ipairs(list) do t[#t + 1] = r.id end
    table.sort(t)
    return t
end

test('THE POINT: the attack refutes invariants a single run made look true', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- ONE run with k="known" returns "known", which supports FOUR wrong candidates at once:
    -- constant-return, return-type=string, never-nil, and passthrough. Every one is an artefact of
    -- the branch that run happened to take.
    local r = assert(inv.survey(store, id_of('M.lookup'),
        { fills = { ['input:k'] = { value = '"known"', basis = 'the happy path', by = 'agent' } } }))
    local killed = ids(r.refuted)
    for _, want in ipairs({ 'constant-return', 'never-nil', 'passthrough', 'return-type' }) do
        ok(vim.tbl_contains(killed, want), want .. ' must be REFUTED, got: '
            .. table.concat(killed, ' '))
    end
    -- and each refutation carries the counterexample that killed it, so the row is actionable
    for _, row in ipairs(r.refuted) do
        ok(row.why:find('refuted under', 1, true), row.why)
        ok(row.counterexample, 'with the observation that did it')
    end
    -- THE ATTACK WAS DERIVED, not random: it came from the function's own condition
    ok(#r.attacks >= 2, 'both sides of the guard were explored')
    -- arity survives, correctly — `return nil` is still one value
    ok(vim.tbl_contains(ids(r.survived), 'return-arity'), 'return-arity holds either way')
    cleanup()
end)

test('invariants: a real invariant SURVIVES the same attack', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- the discriminating half: if the attack killed everything it would be useless
    local r = assert(inv.survey(store, id_of('M.always'),
        { fills = { ['input:x'] = { value = '5', basis = 'a positive', by = 'agent' } } }))
    eq(0, #r.refuted, 'nothing is refuted')
    local kept = ids(r.survived)
    ok(vim.tbl_contains(kept, 'constant-return'), 'it really does always return "yes"')
    for _, row in ipairs(r.survived) do
        ok(row.support > 1, 'and support counts more than the base run: ' .. row.id)
        eq(row.total, row.support, 'having held over every observation')
    end
    cleanup()
end)

test('invariants: NO OPINION is not support — an unreadable value abstains', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- `no-effects` cannot opine without an effect log (none of these functions is sandboxed), and
    -- abstaining is not the same as holding. The difference between "checked and true" and "could
    -- not check" is the row's whole value.
    local r = assert(inv.survey(store, id_of('M.always'),
        { fills = { ['input:x'] = { value = '5', basis = 'x', by = 'agent' } } }))
    eq(nil, vim.tbl_contains(ids(r.survived), 'no-effects') and true or nil,
        'no-effects must NOT be reported as holding when there was no log to read')
    eq(nil, vim.tbl_contains(ids(r.refuted), 'no-effects') and true or nil,
        'nor as refuted')
    cleanup()
end)

test('invariants: when nothing can be varied, the report SAYS so', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- M.flat has no forkable condition, so every candidate rests on ONE input set — the weakest
    -- evidence this tool can produce, and "unrefuted" there must not read as "true".
    local r = assert(inv.survey(store, id_of('M.flat'),
        { fills = { ['input:a'] = { value = '1', basis = 'x', by = 'agent' } } }))
    eq(0, r.conditions, 'nothing to fork')
    eq(0, #r.attacks, 'so no attack was made')
    local text = table.concat(inv.report(r), '\n')
    ok(text:find('no forkable condition', 1, true), 'and the report says it')
    ok(text:find('ONE input set', 1, true),
        'naming the weakness rather than printing a bare support count: ' .. text:sub(-200))
    ok(text:find('NOT proven', 1, true), 'and never claiming proof')
    cleanup()
end)
