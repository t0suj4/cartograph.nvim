-- CART-0127: config.lints — a project's own lint rules, run beside the built-in ones. A rule the user cannot add is a
-- core change, and a project's conventions are exactly where a graph-aware lint pays. An invalid rule, a name a
-- built-in owns, a run() that raises and a finding with no position are each REPORTED in run()'s second return, and
-- every other rule still runs.

local ts     = require 'cartograph.providers.treesitter'
local store  = require 'cartograph.store'
local lint   = require 'cartograph.lint'
local agent  = require 'cartograph.agent'
local config = require 'cartograph.config'

local function with_lints(lints, f)
    local was = config.lints
    config.lints = lints
    local ok, err = pcall(f)
    config.lints = was
    assert(ok, err)
end
local function setup_tree()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local M = {}\nfunction M.a() return raw_query("x") end\nfunction M.b() return build("y") end\nreturn M\n')
    fd:close()
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    return root
end
-- the README's example rule, verbatim in substance: it must work against a real store
local NO_RAW = { name = 'no-raw-db', quantifier = 'witness', severity = 'warn',
    run = function (st)
        local out = {}
        for _, c in ipairs(st.data.calls) do
            if c.callee == 'raw_query' then
                out[#out + 1] = { file = c.file, line = c.line + 1, message = 'use the query builder' }
            end
        end
        return out
    end }
local function of_rule(findings, name)
    local out = {}
    for _, f in ipairs(findings) do if f.rule == name then out[#out + 1] = f end end
    return out
end
local function whys(refused)
    local out = {}
    for _, r in ipairs(refused) do if r.user then out[#out + 1] = r.why end end
    table.sort(out)
    return out
end

test('config.lints: a user rule runs beside the built-ins, its finding stamped with its name and severity (CART-0127)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = setup_tree()
    with_lints({ NO_RAW }, function ()
        local findings, refused = lint.run(store)
        local mine = of_rule(findings, 'no-raw-db')
        eq(1, #mine, vim.inspect(mine))
        eq({ 'm.lua', 2, 'warn', 'use the query builder' }, { mine[1].file, mine[1].line, mine[1].severity, mine[1].message })
        eq({}, whys(refused))
        -- `only` selects it like a built-in
        eq(1, #lint.run(store, { only = { ['no-raw-db'] = true } }))
        -- the agent surface reaches it, with its declared disposition
        local a = agent.answer(store, 'lint_run', { rules = { 'no-raw-db' } })
        eq(1, #(a.result or {}), vim.inspect(a))
        eq('suggestive', a.result[1].disposition)
        eq('witness', a.result[1].quantifier)
    end)
    -- and without config.lints, nothing of it is left behind
    eq(0, #of_rule((lint.run(store)), 'no-raw-db'))
    eq(lint.rules, (lint.all_rules()), 'no user rules: the built-in table itself')
    vim.fn.delete(root, 'rf')
end)

test('config.lints: an undeclared quantifier is a PROMISE, refused under a scope; a witness runs there (CART-0127)', function ()
    local p = lint.user_rules
    with_lints({ { name = 'u-promise', run = function () return {} end },
                 { name = 'u-witness', quantifier = 'witness', run = function () return {} end } }, function ()
        local rules = p()
        eq('promise', rules[1].quantifier, 'the default is the cautious one')
        eq('suggestive', rules[1].disposition)
        eq('warn', rules[1].severity)
        local clip = {}
        for _, n in ipairs(lint.clippable('file')) do clip[n] = true end
        eq(nil, clip['u-promise'], 'an absence over an unstated space cannot be clipped to a file')
        eq(true, clip['u-witness'])
    end)
end)

test('config.lints: every bad rule is SAID and the rest still run (CART-0127)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = setup_tree()
    local builtin = lint.rules[1].name
    with_lints({
        NO_RAW,
        { name = builtin, run = function () return {} end },
        { run = function () return {} end },
        { name = 'no-run' },
        { name = 'bad-sev', severity = 'fatal', run = function () return {} end },
        { name = 'bad-q', quantifier = 'maybe', run = function () return {} end },
        { name = 'bad-co', closed_over = 'module', run = function () return {} end },
        { name = 'bad-disp', disposition = 'certain', run = function () return {} end },
        { name = 'dup', quantifier = 'witness', run = function () return {} end },
        { name = 'dup', quantifier = 'witness', run = function () return {} end },
        { name = 'raises', quantifier = 'witness', run = function () error('boom') end },
        { name = 'not-a-list', quantifier = 'witness', run = function () return 7 end },
        { name = 'no-pos', quantifier = 'witness', run = function ()
            return { { file = 'm.lua', line = 1, message = 'kept' }, { message = 'no position' }, 'junk' } end },
    }, function ()
        local findings, refused = lint.run(store)
        eq(1, #of_rule(findings, 'no-raw-db'), 'the good rule still ran')
        eq(1, #of_rule(findings, 'no-pos'), 'the positioned finding is kept')
        local w = whys(refused)
        local want = {
            'config.lints: ' .. builtin .. ' has the name of a built-in rule, so their findings could not be told apart',
            'config.lints: bad-co has closed_over "module": fn, file or corpus',
            'config.lints: bad-disp has disposition "certain": authoritative, suggestive, calibration or annotation',
            'config.lints: bad-q has quantifier "maybe": witness or promise',
            'config.lints: bad-sev has severity "fatal": one of error, warn, info, hint',
            'config.lints: config.lints[3] has no name',
            'config.lints: dup is declared twice',
            'config.lints: no-pos returned 2 finding(s) without a file and a numeric line; they were dropped',
            'config.lints: no-run has no run(store) function',
            'config.lints: not-a-list returned a number, not a list of findings',
        }
        local raised
        for i = #w, 1, -1 do if w[i]:find('raises raised:', 1, true) then raised = table.remove(w, i) end end
        ok(raised and raised:find('boom', 1, true), 'the error itself is in the refusal: ' .. tostring(raised))
        table.sort(want)
        eq(want, w)
        -- the agent: a bad rule is a name you may ask for, and the answer is its refusal
        local a = agent.answer(store, 'lint_run', { rules = { 'raises' } })
        ok(a, 'not an unknown-rule usage fault')
        local seen
        for _, n in ipairs(a.notes or {}) do if n.kind == 'rule-refused' and n.premise == 'raises' then seen = n end end
        ok(seen and seen.evidence.user, vim.inspect(a))
    end)
    with_lints('nope', function ()
        local _, refused = lint.run(store)
        eq({ 'config.lints must be a list of rules, not a string' }, whys(refused))
    end)
    vim.fn.delete(root, 'rf')
end)
