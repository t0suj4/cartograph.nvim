-- FORKING A CHARACTERIZATION (CART-0283, user: "we could probably support a fork, then the user
-- could observe both states").
--
-- A condition on an unknown has no right answer to pick — it has TWO behaviours, and describing
-- one is describing half. So these pin that both states are produced, that NEITHER is presented
-- as the behaviour, that what DIFFERS is computed rather than left to a reader, and the two
-- things that make it usable: the LINT (a guard that guards nothing) and the REDUCER (fork each
-- condition independently, 2n runs instead of 2^n).

local fork = require 'cartograph.fork'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local SRC = table.concat({
    'local M = {}',                                   -- 1
    'function M.pick(mode)',                          -- 2
    '    if mode == "fast" then return 1 end',         -- 3
    '    return 2',                                   -- 4
    'end',                                            -- 5
    'function M.pointless(n)',                        -- 6
    '    if n > 5 then return "same" end',            -- 7
    '    return "same"',                              -- 8
    'end',                                            -- 9
    'function M.mixed(a)',                            -- 10
    '    local out = "x"',                            -- 11
    '    if a > 1 then out = "big" end',              -- 12
    '    if a > 100 then out = out end',              -- 13
    '    return out',                                 -- 14
    'end',                                            -- 15
    'function M.hard(a, b)',                          -- 16
    '    if a > b then return a end',                 -- 17
    '    return b',                                   -- 18
    'end',                                            -- 19
    'return M',                                       -- 20
}, '\n') .. '\n'

local root
local function proj()
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(SRC); fd:close()
    local data = ts.extract(root); data.root = data.root or root
    store.ingest(data)
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

test('fork: BOTH states, and what differs is COMPUTED', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local f, why = fork.at(store, id_of('M.pick'), 'condition:L3')
    ok(f, 'the fork runs both ways: ' .. tostring(why))
    eq(2, #f.states)
    -- each state carries its own PREMISE and its own observation
    eq(true, f.states[1].want); eq(false, f.states[2].want)
    eq('1', f.states[1].ret, 'the true branch returns 1')
    eq('2', f.states[2].ret, 'the false branch returns 2')
    -- WHAT DIFFERS IS THE DELIVERABLE, so the tool computes it
    eq(true, f.live)
    ok(f.differs[1]:find('1 vs 2', 1, true), 'named: ' .. tostring(f.differs[1]))

    -- A FRESH PLAN PER STATE, never a shared one: an assertion MUTATES a plan, so two states
    -- over one plan would be one state overwritten twice.
    ok(f.states[1].plan ~= f.states[2].plan, 'the states do not share a plan')

    local text = table.concat(fork.report(f), '\n')
    ok(text:find('THIS CONDITION DECIDES', 1, true), text:sub(1, 60))
    ok(text:find('neither is "the behaviour"', 1, true),
        'and NEITHER state is presented as the behaviour')
    cleanup()
end)

test('fork: two identical states are a GUARD THAT GUARDS NOTHING', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- The lint nobody asked for, and it falls out of forking: same return AND same effects
    -- either way means the condition does not affect observable behaviour. BEHAVIOURAL, so it
    -- catches what a structural redundancy check cannot.
    local f = assert(fork.at(store, id_of('M.pointless'), 'condition:L7'))
    eq(false, f.live, 'the condition decides nothing')
    eq(0, #f.differs)
    eq(f.states[1].ret, f.states[2].ret)
    local text = table.concat(fork.report(f), '\n')
    ok(text:find('OBSERVATIONALLY IDENTICAL', 1, true), text)
    -- AND IT IS HEDGED IN THE SAME BREATH, because it is evidence and not a verdict: it says
    -- nothing about paths this fork did not explore.
    ok(text:find('HEDGED', 1, true), 'hedged to these inputs')
    ok(text:find('not', 1, true) and text:find('identical%-in%-general'),
        'and says what it does NOT prove')
    cleanup()
end)

test('fork.scan: the REDUCER turns n conditions into k live axes', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- 2n runs, not 2^n. This is the only reduction in the design that MEASURES rather than
    -- assumes, because it runs the code.
    local s = assert(fork.scan(store, id_of('M.mixed')))
    eq(2, s.total, 'two forkable conditions')
    eq(2, s.scanned)
    eq(1, #s.live, 'one decides something')
    eq(1, #s.inert, 'and one does not')
    ok(s.live[1].differs[1]:find('big', 1, true), tostring(s.live[1].differs[1]))
    local text = table.concat(fork.scan_report(s), '\n')
    ok(text:find('REDUCTION: 2 condition', 1, true), 'the reduction is stated as a number')
    ok(text:find('versus 4', 1, true), 'against the unreduced product: ' .. text:sub(-90))
    cleanup()
end)

test('fork.scan: the cap is STATED, never silent', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- A silent cap reads as "we explored everything", which is this codebase's recurring defect
    -- class. Cap of 1 over a 2-condition function must SAY it skipped one.
    local s = assert(fork.scan(store, id_of('M.mixed'), { cap = 1 }))
    eq(1, s.scanned); eq(1, s.skipped)
    local text = table.concat(fork.scan_report(s), '\n')
    ok(text:find('NOT SCANNED', 1, true), 'and the report says so: ' .. text:sub(-120))
    cleanup()
end)

test('fork: an un-invertible condition is REFUSED, and the scan carries on', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- comparing two unknowns cannot be asserted (no solver — CART-0256 measured conjunctions as
    -- tiny, so this is inversion of a closed set), and the refusal must not abort the scan: one
    -- condition we cannot fork says nothing about the others.
    local f, why = fork.at(store, id_of('M.hard'), 'condition:L17')
    eq(nil, f, 'the fork is refused')
    ok(why:find('not a number literal', 1, true), tostring(why))
    local s = assert(fork.scan(store, id_of('M.hard')))
    eq(1, #s.refused, 'the scan records it as NOT FORKABLE')
    ok(table.concat(fork.scan_report(s), '\n'):find('NOT FORKABLE', 1, true))
    cleanup()
end)
