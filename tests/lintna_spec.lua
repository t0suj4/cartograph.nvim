-- CART-0228: a lint rule can say it did NOT APPLY. Its empty list used to be the same `{}` whether it looked and found
-- nothing or never looked (no Lua file for swallowed-type, no manifest for load-order, no seam declared, not an
-- ansible tree). run() may return M.not_applicable(why) beside its findings; lint.run hands those back as its third
-- return, the agent names them in one note and counts only the rules that looked, and a selection where no rule
-- applies is `unavailable`, not `absent`.

local ts     = require 'cartograph.providers.treesitter'
local store  = require 'cartograph.store'
local lint   = require 'cartograph.lint'
local agent  = require 'cartograph.agent'
local config = require 'cartograph.config'

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    return root
end
local PY = { ['a.py'] = 'def f(x):\n    return g(x)\n\ndef g(y):\n    return y\n' }

test('lint not-applicable: the gated rules say why, and a rule that looked is not among them (CART-0228)', function ()
    if not parser_available('python') then skip 'no python parser' end
    local root = tree(PY)
    local was = config.seams
    config.seams = nil
    local _, _, na = lint.run(store)
    config.seams = was
    eq('not-applicable', na['swallowed-type'] and na['swallowed-type'].status)
    eq('no Lua file: the repair this rule offers is a lua-ls annotation', na['swallowed-type'].why)
    eq('no load-order manifest (a WoW .toc) in this tree', na['load-order'] and na['load-order'].why)
    eq('no representation seam is declared (config.seams)', na['seam-guard'] and na['seam-guard'].why)
    eq('not an ansible tree', na['ansible-audit'] and na['ansible-audit'].why)
    eq('not an ansible tree', na['ansible-vars'] and na['ansible-vars'].why)
    eq('no database schema is linked (config.db)', na['db-audit'] and na['db-audit'].why)
    eq('no register_listener call anywhere: not a listener project', na['listener-audit'] and na['listener-audit'].why)
    eq(nil, na['dead-function'], 'a rule that looked is not marked')
    eq(nil, na['silent-drop'], 'this graph HAS calls: silent-drop looked')
    -- a declared seam makes seam-guard apply
    config.seams = { { name = 'x', patterns = { 'zzz_never' }, owners = {} } }
    local _, _, na2 = lint.run(store, { only = { ['seam-guard'] = true } })
    config.seams = was
    eq(nil, na2['seam-guard'], 'declared: it looked')
    vim.fn.delete(root, 'rf')
end)

test('lint not-applicable: the agent names them in one note, counts only the rules that looked, and an all-inapplicable selection is unavailable (CART-0228)', function ()
    if not parser_available('python') then skip 'no python parser' end
    local root = tree(PY)
    local a = agent.answer(store, 'lint_run', {})
    local note
    for _, n in ipairs(a.notes or {}) do if n.kind == 'rules-not-applicable' then note = n end end
    ok(note, vim.inspect(a.notes))
    eq('not an ansible tree', note.evidence.rules['ansible-audit'])
    local b = agent.answer(store, 'lint_run', { rules = { 'ansible-audit', 'ansible-vars' } })
    eq('unavailable', b.absence, vim.inspect(b))
    eq('rules-not-applicable', b.absence_why.premise)
    ok(b.absence_why.why:find('ansible-audit (not an ansible tree)', 1, true), b.absence_why.why)
    -- a selection where one rule looked: an ordinary answer, with the other one named
    local c = agent.answer(store, 'lint_run', { rules = { 'ansible-audit', 'call-cycle' } })
    eq('absent', c.absence, vim.inspect(c))
    eq(1, c.absence_why.evidence.rules, 'only call-cycle looked')
    eq(1, c.absence_why.evidence.not_applicable)
    vim.fn.delete(root, 'rf')
end)

test('lint not-applicable: a user rule may say it too; a stray second value or a non-empty list is not the mark (CART-0228)', function ()
    if not parser_available('python') then skip 'no python parser' end
    local root = tree(PY)
    local was = config.lints
    config.lints = {
        { name = 'u-na', quantifier = 'witness', run = function () return {}, lint.not_applicable('no django here') end },
        { name = 'u-stray', quantifier = 'witness', run = function () return {}, { why = 'unmarked' } end },
        { name = 'u-found', quantifier = 'witness', run = function ()
            return { { file = 'a.py', line = 1, message = 'x' } }, lint.not_applicable('contradiction') end },
    }
    local ok_, err = pcall(function ()
        local findings, refused, na = lint.run(store)
        eq({ status = 'not-applicable', why = 'no django here' }, na['u-na'])
        eq(nil, na['u-stray'], 'only a value made by not_applicable counts')
        eq(nil, na['u-found'], 'a rule that FOUND something did apply')
        local n = 0
        for _, f in ipairs(findings) do if f.rule == 'u-found' then n = n + 1 end end
        eq(1, n)
        for _, r in ipairs(refused) do ok(not r.user, 'no user rule refused: ' .. tostring(r.why)) end
    end)
    config.lints = was
    assert(ok_, err)
    vim.fn.delete(root, 'rf')
end)
