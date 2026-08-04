-- ASSERTED CONDITIONS (CART-0282, user: "we can let user force assert it true which would have
-- ripple effect on the info we know").
--
-- An input hole says "choose a value" and gives you no way to choose one. What a person actually
-- knows is the CONDITION — "the file is non-empty", "the mode is fast" — so these pin the
-- inversion that turns an asserted PREDICATE into a derived VALUE, and above all that THE RUN
-- ACTUALLY TAKES THE ASSERTED BRANCH. Everything else is bookkeeping; that is the claim.

local ch = require 'cartograph.characterize'
local ro = require 'cartograph.runoracle'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local SRC = table.concat({
    'local M = {}',                                   -- 1
    'function M.clamp(n)',                            -- 2
    '    if n > 10 then return "big" end',             -- 3
    '    return "small"',                             -- 4
    'end',                                            -- 5
    'function M.pick(mode)',                          -- 6
    '    if mode == "fast" then return 1 end',         -- 7
    '    return 2',                                   -- 8
    'end',                                            -- 9
    'function M.opt(x)',                              -- 10
    '    if x then return "on" end',                   -- 11
    '    return "off"',                                -- 12
    'end',                                             -- 13
    'function M.hard(a, b)',                            -- 14
    '    if a > b then return a end',                   -- 15
    '    return b',                                     -- 16
    'end',                                              -- 17
    'return M',                                          -- 18
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
local function planned(name) return assert(ch.plan(store, id_of(name))) end
local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end
local function ret(plan)
    for _, h in ipairs(plan.holes) do if h.kind == 'oracle' then return h.raw_value end end
end

test('conditions: a forkable guard is a ROW, addressed by line', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = planned('M.pick')
    eq(1, #plan.conditions, 'one guard hinges on a parameter')
    local c = plan.conditions[1]
    eq('condition:L7', c.id, 'addressed by the line it is ON — `st.l` is 1-based, and the first'
        .. ' cut added one and pointed at the line BELOW, which reads as precise and is wrong')
    eq('mode', c.leaf)
    eq('input:mode', c.leaf_hole, 'and it names the hole it would fill')
    ok(c.text:find('if mode ==', 1, true), 'carrying the source: ' .. tostring(c.text))
    cleanup()
end)

test('assert: the RUN TAKES THE ASSERTED BRANCH — both ways', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- THE WHOLE CLAIM. Assert true and the true branch runs; assert false and the false branch
    -- runs. Anything less and an "assertion" is decoration.
    local t = planned('M.pick')
    assert(ch.assert_condition(store, t, 'condition:L7', true))
    assert(ro.fill_oracle(store, t))
    eq('1', ret(t), 'asserted TRUE -> the true branch: ' .. tostring(ret(t)))

    local f = planned('M.pick')
    assert(ch.assert_condition(store, f, 'condition:L7', false))
    assert(ro.fill_oracle(store, f))
    eq('2', ret(f), 'asserted FALSE -> the false branch: ' .. tostring(ret(f)))

    -- and the two specs differ ONLY in the assertion, which is what makes them a description
    -- of the function rather than of one path (the fork CART-0283 builds on)
    ok(ret(t) ~= ret(f), 'the condition DECIDES something observable')
    cleanup()
end)

test('assert: the inversion covers a closed set and REFUSES outside it', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- numeric comparison
    local a = planned('M.clamp')
    assert(ch.assert_condition(store, a, 'condition:L3', true))
    assert(ro.fill_oracle(store, a))
    eq('"big"', ret(a), 'n > 10 asserted true')
    local b = planned('M.clamp')
    assert(ch.assert_condition(store, b, 'condition:L3', false))
    assert(ro.fill_oracle(store, b))
    eq('"small"', ret(b), 'and asserted false')

    -- bare truthiness
    local c = planned('M.opt')
    assert(ch.assert_condition(store, c, 'condition:L11', true))
    assert(ro.fill_oracle(store, c))
    eq('"on"', ret(c))

    -- OUTSIDE THE SET: two parameters compared with each other. No solver (CART-0256 measured
    -- that conjunctions in real code are tiny, so this is inversion of a closed set, not
    -- satisfiability) — so it REFUSES BY NAME rather than guessing, because a value satisfying
    -- a condition we only half-understood looks derived and is a guess.
    local d = planned('M.hard')
    local n, why = ch.assert_condition(store, d, 'condition:L15', true)
    eq(nil, n, 'comparing two unknowns is refused')
    ok(why:find('not a number literal', 1, true), 'with the reason: ' .. tostring(why))
    ok(why:find('if a > b', 1, true), 'and the condition it could not invert, quoted right')
    cleanup()
end)

test('assert: a string literal is used VERBATIM, quotes and all', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- A literal's `v` in the expression IR is already Lua SOURCE — a str lit's v is `"fast"`,
    -- seven characters. The first cut ran %q over it and produced `"\"fast\""`, a different
    -- string that of course failed the comparison: the assertion said TRUE and the run took the
    -- FALSE branch. Measured, not assumed, and this pins it.
    local p = planned('M.pick')
    assert(ch.assert_condition(store, p, 'condition:L7', true))
    for _, h in ipairs(p.holes) do
        if h.id == 'input:mode' then eq('"fast"', h.value) end
    end
    cleanup()
end)

test('assert: the premise is CLAIM, the observation stays MEASURED', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local p = planned('M.clamp')
    assert(ch.assert_condition(store, p, 'condition:L3', true))
    local input
    for _, h in ipairs(p.holes) do if h.id == 'input:n' then input = h end end
    eq('claim', input.filled_tier, 'the ASSERTION is declared, so the value it derives is a claim')
    eq('asserted', input.by, 'with the channel recording how')
    ok(input.basis:find('ASSERTED', 1, true) and input.basis:find('derived from it', 1, true),
        'and a basis naming both halves: ' .. tostring(input.basis))

    -- AND THE ORACLE STAYS MEASURED, deliberately. The weakest-link rule weakens an observation
    -- made through a FICTION (a sandboxed run, where the value came from our own fake). An
    -- asserted input is not a fiction: n = 11 is a real value and the run really returned "big",
    -- so the PAIR was observed. What the assertion weakens is GENERALITY, not the observation —
    -- conflating those would tier every measurement by the reason someone picked its input.
    assert(ro.fill_oracle(store, p))
    for _, h in ipairs(p.holes) do
        if h.kind == 'oracle' then eq('measured', h.filled_tier) end
    end
    cleanup()
end)

test('assert: the report SHOWS what is assertable and what was asserted', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local p = planned('M.pick')
    local before = table.concat(ch.report(p), '\n')
    ok(before:find('forkable condition', 1, true),
        'an unasserted condition is OFFERED — an input hole that says only "choose a value"'
        .. ' hides that a CONDITION is what the value is for')
    ok(before:find('condition:L7', 1, true), 'by id, so it is addressable')

    assert(ch.assert_condition(store, p, 'condition:L7', true))
    local after = table.concat(ch.report(p), '\n')
    ok(after:find('ASSERTED true', 1, true), 'and once asserted it is disclosed')
    ok(after:find('selects the TRUE branch', 1, true),
        'WITH THE BRANCH IT SELECTED: a spec that quietly picked a side reads as'
        .. ' characterizing the function when it characterized one path')
    eq(nil, after:find('forkable condition', 1, true), 'and it leaves the offer list')
    cleanup()
end)
