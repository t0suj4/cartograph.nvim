-- EVERY STOP NAMES ITS CLASS (CART-1152 step 1). A tactic — a composition of write verbs — may stop only on a genuine
-- DECISION; every other stop is a failure it can route: an unbuilt capability, a missing fact an oracle supplies, a
-- request with a nearest valid form, a stale plan, an empty answer. That routing is only possible if a stop SAYS which
-- it is, so the class rides on both kinds of stop:
--
--   a REFUSAL   `return nil, why, <class>` — a literal from hazard.CLASSES, a code hazard.CODE_CLASS maps, a forwarded
--               `<x>_class or '<class>'` (a pass-through keeps its source's class, and its own default when the
--               source names none), or a payload table carrying `class = '<class>'`
--   a HAZARD    residue a plan leaves: a hazard.new(…, class) row, or a table row with a `class` field
--
-- THE POPULATION IS DERIVED, NOT LISTED: the write kernel (txn) and every module that requires it or cartograph.hazard
-- (the write verbs and the helpers that build their plans). A helper outside it (planguards, holes, optimize) is
-- covered where its answer enters the population: the pass-through there forwards its class or supplies a default. The hand census of step 0 missed six such modules and 76 stops; a
-- listed population would have fenced its own blind spot. ONE module is exempt by shape of its answers, not by name
-- alone: agent.lua returns ENVELOPES (`nil, refuse(…)`), and its class rides in `refusal.class` (pinned in agentwrite_spec).
-- A `return nil, true|false` is a VALUE tuple, not a stop, and is skipped by shape.

local hazard = require 'cartograph.hazard'
local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local function read(path)
    local fd = assert(io.open(path)); local s = fd:read('a'); fd:close(); return s
end

local function population()
    local out = {}
    for _, path in ipairs(vim.fn.globpath(repo .. '/lua/cartograph', '**/*.lua', false, true)) do
        local src = read(path)
        local rel = path:sub(#repo + 2)
        -- ⚠ THE KERNEL IS ITS OWN ANCHOR: txn.lua does not require itself, and a population of txn's CLIENTS alone
        -- silently dropped its 24 stops (caught by a class tally with no `environment` row)
        if rel ~= 'lua/cartograph/agent.lua' and (rel == 'lua/cartograph/txn.lua'
            or src:find("require[ (]*'cartograph%.txn'") or src:find("require[ (]*'cartograph%.hazard'")) then
            out[#out + 1] = { rel = rel, src = src }
        end
    end
    table.sort(out, function (a, b) return a.rel < b.rel end)
    return out
end

local function text(n, src) return vim.treesitter.get_node_text(n, src) end
local function strlit(n, src)
    if n and n:type() == 'string' then return (text(n, src):match("^'(.*)'$") or text(n, src):match('^"(.*)"$')) end
end
local function is_class(s) return s ~= nil and hazard.CLASSES[s] ~= nil end

-- does this third value name a class?
local function names_class(n, src)
    local s = strlit(n, src)
    if s then return is_class(s) or is_class(hazard.CODE_CLASS[s]) end
    local t = n:type()
    if t == 'binary_expression' then
        -- `x_class or '<class>'` (and `why and 'frontier' or 'empty'`): the fallback is a class
        local op = n:child(1)
        return op and text(op, src) == 'or' and is_class(strlit(n:named_child(n:named_child_count() - 1), src))
    end
    if t == 'table_constructor' then
        for f in n:iter_children() do
            if f:type() == 'field' and text(f, src):match('^class%s*=') then
                local v = f:field('value')[1]
                -- a helper's row validates its caller's class at run time: `class = hazard.class(c)`
                return is_class(strlit(v, src)) or (v:type() == 'function_call' and text(v, src):match('%.class%(') ~= nil)
            end
        end
    end
    return false
end

local function walk(n, fn)
    fn(n)
    for c in n:iter_children() do walk(c, fn) end
end

--- every stop in `src` that names no class: { line, text }
local function unclassed_refusals(src)
    local root = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    local bad, seen = {}, 0
    walk(root, function (n)
        if n:type() ~= 'return_statement' then return end
        local el = n:named_child(0)
        if not (el and el:type() == 'expression_list' and el:named_child(0):type() == 'nil'
            and el:named_child_count() >= 2) then return end
        local second = el:named_child(1):type()
        if second == 'true' or second == 'false' then return end -- a value tuple, not a stop
        -- `nil, nil, why, nil, class`: txn.dryrun's (before, after, why, virtual) projection of txn.stage, which names
        -- the class (CART-1153) — the stop itself is fenced where stage returns it
        if second == 'nil' then return end
        seen = seen + 1
        local third = el:named_child(2)
        if not (third and names_class(third, src)) then
            bad[#bad + 1] = ('L%d %s'):format(n:start() + 1, text(n, src):gsub('%s+', ' '):sub(1, 90))
        end
    end)
    return bad, seen
end

--- every hazard append in `src` that names no class
local function unclassed_hazards(src)
    local root = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    local bad, seen = {}, 0
    local function check(v, at)
        seen = seen + 1
        local t = text(v, src)
        local ok
        if v:type() == 'function_call' and t:match('%.new%(') then
            local args = v:field('arguments')[1]
            -- the fifth argument: a class literal, or a forwarded one (`h.class`) that hazard.new validates
            local c = args and args:named_child_count() == 5 and args:named_child(4)
            ok = c and (names_class(c, src) or (c:type() ~= 'nil' and c:type() ~= 'string'))
        elseif v:type() == 'table_constructor' then
            ok = names_class(v, src)
        end
        if not ok then bad[#bad + 1] = ('L%d %s'):format(at + 1, t:gsub('%s+', ' '):sub(1, 90)) end
    end
    walk(root, function (n)
        local t = n:type()
        if t == 'assignment_statement' then
            local lhs = n:named_child(0)
            local lt = lhs and text(lhs, src) or ''
            if lt:match('hazards%[#[%w_.]*hazards %+ 1%]$') then
                check(n:named_child(1):named_child(0), n:start())
            end
        elseif t == 'function_call' and text(n, src):match('^table%.insert%([%w_.]*hazards,') then
            local args = n:field('arguments')[1]
            check(args:named_child(args:named_child_count() - 1), n:start())
        elseif t == 'field' and text(n, src):match('^hazards%s*=%s*{') then
            local tc = n:field('value')[1]
            for i = 0, tc:named_child_count() - 1 do
                local f = tc:named_child(i)
                check(f:named_child(0) or f, n:start())
            end
        end
    end)
    return bad, seen
end

--- functions whose refusals MIX the two arities — `nil, why[, class]` and `nil, nil, why` (a (before, after, why)
--- contract). txn.dryrun did: one line answered `nil, cwhy`, handing its reason back as `after`. The class fence skips
--- the second shape, so it cannot see a mix; this can.
local function mixed_arity(src)
    local root = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    local bad = {}
    local function scan(fn)
        local two, three = false, false
        local function go(n)
            local t = n:type()
            if n ~= fn and (t == 'function_declaration' or t == 'function_definition') then return end
            if t == 'return_statement' then
                local el = n:named_child(0)
                if el and el:type() == 'expression_list' and el:named_child(0):type() == 'nil'
                    and el:named_child_count() >= 2 then
                    local second = el:named_child(1):type()
                    if second == 'nil' then three = true
                    elseif second ~= 'true' and second ~= 'false' then two = true end
                end
            end
            for c in n:iter_children() do go(c) end
        end
        go(fn)
        if two and three then bad[#bad + 1] = ('L%d'):format(fn:start() + 1) end
    end
    walk(root, function (n)
        local t = n:type()
        if t == 'function_declaration' or t == 'function_definition' then scan(n) end
    end)
    return bad
end

test('stopclass: one function, one refusal arity', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local bad = {}
    for _, m in ipairs(population()) do
        for _, x in ipairs(mixed_arity(m.src)) do bad[#bad + 1] = m.rel .. ' ' .. x end
    end
    eq({}, bad, 'a reason lands in the same slot on every refusal of a function')
    eq({ 'L1' }, mixed_arity("local function f(x)\n  if x then return nil, 'a' end\n  return nil, nil, 'b'\nend\n"),
        'and a mix is caught')
end)

test('stopclass: every refusal in a write module names its class', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local pop = population()
    ok(#pop >= 20, 'the derived population is the write modules, not an empty glob: ' .. #pop)
    local bad, total = {}, 0
    for _, m in ipairs(pop) do
        local b, n = unclassed_refusals(m.src)
        total = total + n
        for _, x in ipairs(b) do bad[#bad + 1] = m.rel .. ' ' .. x end
    end
    io.write(('  [stopclass] %d modules, %d stops\n'):format(#pop, total))
    ok(total >= 250, 'the census counted the stops it fences (a zero here is a broken reader): ' .. total)
    eq({}, bad, 'each stop says what a tactic does on meeting it (hazard.CLASSES)')
end)

test('stopclass: every hazard a plan appends names its class', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local bad, total = {}, 0
    for _, path in ipairs(vim.fn.globpath(repo .. '/lua/cartograph', '**/*.lua', false, true)) do
        local b, n = unclassed_hazards(read(path))
        total = total + n
        for _, x in ipairs(b) do bad[#bad + 1] = path:sub(#repo + 2) .. ' ' .. x end
    end
    io.write(('  [stopclass] %d hazard appends\n'):format(total))
    ok(total >= 25, 'the hazard appends were found (a zero is a broken reader): ' .. total)
    eq({}, bad, 'residue names its class too')
end)

test('stopclass: the fence is not vacuous — an unclassified stop and a bad class are both caught', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local src = table.concat({
        'local function f(x)',
        "  if not x then return nil, 'no x' end",                 -- unclassified
        "  if x == 1 then return nil, 'one', 'bogus' end",        -- not a class
        "  if x == 2 then return nil, 'two', 'ill-posed' end",    -- a class
        "  if x == 3 then return nil, 'three', 'no-candidates' end", -- a code the map classifies
        "  if x == 4 then return nil, why, why_class or 'frontier' end",
        "  if x == 5 then return nil, 'five', { captures = 'c', class = 'decision' } end",
        '  if x == 6 then return nil, true end',                    -- a value tuple
        'end',
        'local hazards = {}',
        "hazards[#hazards + 1] = 'bare'",
        "hazards[#hazards + 1] = require('cartograph.hazard').new('k', 'r', nil, nil, 'decision')",
        "hazards[#hazards + 1] = { reason = 'r', class = 'frontier' }",
        "hazards[#hazards + 1] = { reason = 'r' }",
        '' }, '\n')
    local bad, seen = unclassed_refusals(src)
    eq(6, seen, 'the value tuple is not a stop')
    eq(2, #bad, 'the bare stop and the bogus class: ' .. table.concat(bad, ' | '))
    local hb, hn = unclassed_hazards(src)
    eq(4, hn); eq(2, #hb, 'the bare string and the classless row: ' .. table.concat(hb, ' | '))
end)

test('stopclass: a hazard row refuses a class outside the vocabulary, and survives JSON', function ()
    local okc = pcall(hazard.new, 'k', 'r', nil, nil, 'maybe')
    eq(false, okc, 'a misspelt class is an error at the site, not a silent unclassified stop')
    local h = hazard.new('surface', 'the surface shrinks', nil, nil, 'decision')
    -- ⚠ the row's __len makes the encoder read it as an ARRAY: raw, it encodes as `[]`
    eq('[[]]', vim.json.encode({ h }), 'the defect plain() exists for')
    eq({ { text = 'the surface shrinks', kind = 'surface', class = 'decision' } },
        vim.json.decode(vim.json.encode(hazard.plain({ h }))), 'the wire form keeps the sentence and the class')
end)

test('stopclass: an optapply refusal reaches the agent with its class', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local optapply = require 'cartograph.optapply'
    for code, class in pairs(optapply.CODE_CLASS) do
        ok(hazard.CLASSES[class], code .. ' maps to a class: ' .. tostring(class))
    end
    local store = require 'cartograph.store'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write('local M = {}\nfunction M.f() return 1 end\nreturn M\n'); fd:close()
    store.ingest(require('cartograph.providers.treesitter').extract(root))
    local plan, why, code = optapply.plan_cse(store, 'no/such.lua::node@1', {})
    eq(nil, plan)
    eq('no-node', code, 'the code stays in the third slot: ' .. tostring(why))
    eq('ill-posed', optapply.CODE_CLASS[code])
    vim.fn.delete(root, 'rf')
end)

test('stopclass: a dry run refusing to write outside the project says WHY in its why slot (not as `after`)', function ()
    local txn = require 'cartograph.txn'
    local store = { data = { root = vim.fn.tempname() }, generation = 1 }
    local plan = { verb = 'probe', touched = { '../escape.lua' }, edit = function (_, b) return b end }
    local before, after, why = txn.dryrun(store, plan, function (_, b) return b end)
    eq(nil, before)
    eq(nil, after, 'the reason used to come back HERE, a string where a file table belongs')
    ok(type(why) == 'string' and why:find('outside the project', 1, true), 'the containment reason: ' .. tostring(why))
end)
