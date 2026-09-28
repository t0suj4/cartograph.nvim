-- A TACTIC FROM AN EXAMPLE (cartograph.byexample + toolbelt.learn). One before -> after is generalized into a rewrite
-- RULE for the region that changed (lossless reader, diff_regions, the carried-over subterms as holes) and applied
-- wherever it matches. MEASURED on lua/cartograph for `x == nil -> not x`: function-granular transplant reached 1 of
-- 111 functions; the rule matches 492 sites in 106 files.
local BX = require 'cartograph.byexample'
local tb = require 'cartograph.toolbelt'
local store = require 'cartograph.store'
local tactic = require 'cartograph.tactic'

local function ready()
    return pcall(vim.treesitter.get_string_parser, '', 'lua') and require('cartograph.algebra').available()
end

local SRC = table.concat({
    'local M = {}',
    'function M.g(y)',
    '  if y == nil then return 1 end',
    '  if t[k] == nil then return false end',
    '  if y==nil then return 2 end',
    '  return y ~= nil and 1 or 0',
    'end',
    'return M', '' }, '\n')

test('byexample: one example is generalized into a RULE — the carried-over subterm becomes a hole, the constant stays', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local rules, why = BX.learn('if x == nil then return 0 end', 'if not x then return 0 end')
    ok(rules, tostring(why))
    eq(1, #rules); eq('x == nil', rules[1].lhs_text); eq('not x', rules[1].rhs_text); eq(1, rules[1].holes)
end)

test('byexample: the rule rewrites every match with the TARGET\'s own operands, and nothing outside them', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local rules = assert(BX.learn('if x == nil then return 0 end', 'if not x then return 0 end'))
    local out, n = BX.rewrite(rules, SRC)
    eq(2, n, 'y == nil and t[k] == nil')
    ok(out:find('if not y then return 1 end', 1, true) and out:find('if not t[k] then return false end', 1, true), out)
    ok(out:find('if y==nil then return 2 end', 1, true), 'FIRST CUT: matching is trivia-sensitive — the unspaced form is left')
    ok(out:find('return y ~= nil and 1 or 0', 1, true), 'a different operator is a different pattern')
    -- byte-identical outside the two rewritten spans
    eq(SRC:gsub('if y == nil then', 'if not y then'):gsub('if t%[k%] == nil', 'if not t[k]'), out)
end)

test('byexample: an example with no edit, and a rule that would match its own output, are refused by name', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local r, why = BX.learn('return x', 'return x')
    eq(nil, r); ok(why:find('no edit', 1, true), why)
    -- `x` -> `x + 0`: the whole region is the carried-over x, so the rule is `?1 -> ?1 + 0` — it matches its own output
    local s, swhy = BX.learn('return x', 'return x + 0')
    eq(nil, s); ok(swhy:find('matches its own output', 1, true), swhy)
end)

local root
local function project(files)
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close() end
    store.ingest(require('cartograph.providers.treesitter').extract(root))
end
local function read(rel) local fd = assert(io.open(root .. '/' .. rel)); local s = fd:read('a'); fd:close(); return s end

test('byexample: WHERE a rule applies is a decision — it stops listing the matches; with a scope it plans them', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { ['a.lua'] = SRC, ['b.lua'] = 'local B = {}\nfunction B.h(q)\n  if q == nil then return 3 end\n  return q\nend\nreturn B\n' }
    local ex = { before = 'if x == nil then return 0 end', after = 'if not x then return 0 end' }
    local p, why, class = BX.plan(store, ex)
    eq(nil, p); eq('decision', class); ok(why:find('3 site(s) in 2 file(s)', 1, true), why)
    local r = tactic.run(store, tactic.T.step('rewrite-by-example', { before = ex.before, after = ex.after, scope = 'b.lua' }), { apply = true })
    eq('done', r.status, tostring(r.why))
    ok(read('b.lua'):find('if not q then return 3 end', 1, true)); eq(SRC, read('a.lua'), 'a.lua was outside the scope')
    -- ★ AN EXAMPLE IS A CLAIM, NOT A PROOF: the demonstrated rewrite changes B.h(false) — the plan says so (preserves none)
    local B = dofile(root .. '/b.lua')
    eq(3, B.h(nil)); eq(3, B.h(false), 'false was returned before; the example changed that, as it demonstrated')
end)

test('learn-from-example: learning is ITSELF a tactic — into the PROJECT, journaled, born with its own test, never overwriting', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { ['m.lua'] = 'local M = {}\nreturn M\n' }
    local ex = { name = 'nil-check', before = 'if x == nil then return 0 end', after = 'if not x then return 0 end' }
    local r = tb.run(store, 'learn-from-example', ex, { apply = true })
    eq('done', r.status, tostring(r.why)); eq(1, r.applied)
    local e = assert(tb.load('nil-check', nil, root))
    eq('project', e.scope); ok(e.summary:find('x == nil -> not x', 1, true), e.summary)
    eq(2, #e.examples, 'the demonstration, and the scope decision')
    -- the store is the CALLER's after learning: validation ran in a separate process, not over the singleton
    eq(root, store.data.root)
    -- re-run: the same file is the goal met; a different one is never overwritten
    eq(0, tb.run(store, 'learn-from-example', ex, { apply = true }).applied)
    local other = tb.run(store, 'learn-from-example', { name = 'nil-check', before = 'if x == 0 then return end', after = 'if x <= 0 then return end' }, { apply = true })
    eq('failed', other.status); ok(other.why:find('never overwrites', 1, true), other.why)
    -- and it COMPOSES: learn, then use what was learned, in one tactic
    project { ['a.lua'] = 'local A = {}\nfunction A.f(q)\n  if q == nil then return 3 end\nend\nreturn A\n' }
    local T = tactic.T
    local both = tactic.run(store, T.seq(T.use('learn-from-example', ex), T.use('nil-check', { scope = 'all' })), { apply = true })
    eq('done', both.status, tostring(both.why))
    ok(read('a.lua'):find('if not q then return 3 end', 1, true), read('a.lua'))
end)

test('the toolbelt spans TWO roots: a project tactic named like a built-in one is refused unless it is the promoted copy', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { ['m.lua'] = 'local M = {}\nreturn M\n' }
    vim.fn.mkdir(root .. '/.cartograph/tactics', 'p')
    local builtin = tb.files()['family-premise']
    local fd = assert(io.open(builtin)); local same = fd:read('a'); fd:close()
    local w = assert(io.open(root .. '/.cartograph/tactics/family-premise.lua', 'w')); w:write(same); w:close()
    local entries, broken, promoted = tb.list(nil, root)
    ok(promoted['family-premise'], 'an identical copy is a promoted one'); eq(nil, broken['family-premise'])
    w = assert(io.open(root .. '/.cartograph/tactics/family-premise.lua', 'w')); w:write(same .. '\n-- edited\n'); w:close()
    _, broken = tb.list(nil, root)
    ok(broken['family-premise'] and broken['family-premise']:find('BUILT-IN', 1, true), vim.inspect(broken))
    ok(#entries >= 4)
end)

test('toolbelt: OVERRIDING a built-in tactic is the user\'s explicit choice, pinned by content hash in THEIR scoped config', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { ['m.lua'] = 'local M = {}\nreturn M\n' }
    local config = require 'cartograph.config'
    local saved = config.scoped
    vim.fn.mkdir(root .. '/.cartograph/tactics', 'p')
    local builtin = tb.files()['family-premise']
    local fd = assert(io.open(builtin)); local same = fd:read('a'); fd:close()
    local mine = root .. '/.cartograph/tactics/family-premise.lua'
    local function put(text) local w = assert(io.open(mine, 'w')); w:write(text); w:close() end
    local function sha(text) return 'sha256:' .. vim.fn.sha256(text) end
    put(same .. '\n-- my variant\n')
    -- unchosen: a DECISION, and the refusal hands over the exact entry for THIS pair — nothing writes it
    local e, why, class = tb.load('family-premise', nil, root)
    eq(nil, e); eq('decision', class)
    ok(why:find(sha(same .. '\n-- my variant\n'), 1, true) and why:find(sha(same), 1, true), 'both hashes in the offered entry: ' .. why)
    ok(why:find('tactic_overrides', 1, true), why)
    local ok_run = pcall(function ()
        -- chosen, for this root: the project file runs, and says what it replaced
        config.scoped = { [root] = { tactic_overrides = { ['family-premise'] = { use = sha(same .. '\n-- my variant\n'), over = sha(same) } } } }
        local got = assert(tb.load('family-premise', nil, root))
        eq(mine, got.path); eq(builtin, got.overrides); eq('project', got.scope)
        local _, broken, _, overridden = tb.list(nil, root)
        eq(nil, broken['family-premise']); eq(mine, overridden['family-premise'].path)
        -- the project file changes: the choice was about the OLD text, so it lapses and says which side moved
        put(same .. '\n-- my variant, edited\n')
        local _, why2, class2 = tb.load('family-premise', nil, root)
        eq('decision', class2); ok(why2:find('no longer holds', 1, true) and why2:find('the project file', 1, true), why2)
        -- a pin whose BUILT-IN side is stale lapses too
        put(same .. '\n-- my variant\n')
        config.scoped = { [root] = { tactic_overrides = { ['family-premise'] = { use = sha(same .. '\n-- my variant\n'), over = sha('an older built-in') } } } }
        local _, why3 = tb.load('family-premise', nil, root)
        ok(why3:find('the built-in it overrides', 1, true), why3)
        -- a choice made for ANOTHER root does not reach this one
        config.scoped = { ['/somewhere/else'] = { tactic_overrides = { ['family-premise'] = { use = sha(same .. '\n-- my variant\n'), over = sha(same) } } } }
        eq(nil, (tb.load('family-premise', nil, root)))
    end)
    config.scoped = saved
    ok(ok_run)
end)

test('byexample: BEYOND LUA — a rule learned and applied in javascript and python through the audited lossless reader', function ()
    local function has(l) return pcall(vim.treesitter.get_string_parser, '', l) end
    if not (has('javascript') and has('python') and require('cartograph.algebra').available()) then skip 'no javascript/python parser or algebra' end
    local js = assert(BX.learn('if (x == null) { return 0; }', 'if (x === null) { return 0; }', 'javascript'))
    eq('x == null', js[1].lhs_text); eq(1, js[1].holes)
    local out, n = BX.rewrite(js, 'function f(a) {\n  if (a == null) { return 1; }\n  return a == 2;\n}\n', 'javascript')
    eq(1, n); eq('function f(a) {\n  if (a === null) { return 1; }\n  return a == 2;\n}\n', out, 'the constant `null` is the pattern; `a == 2` is not it')
    local py = assert(BX.learn('if x == None:\n    return 0\n', 'if x is None:\n    return 0\n', 'python'))
    local pout, pn = BX.rewrite(py, 'def f(y):\n    if y == None:\n        return 0\n    return y\n', 'python')
    eq(1, pn); eq('def f(y):\n    if y is None:\n        return 0\n    return y\n', pout)
end)

test('byexample: a STATEMENT INSERTION applies — every hole the right side uses is bound by the left (CART-1173)', function ()
    if not ready() then skip 'no lua parser or algebra' end
    -- MEASURED before the fix: learned with 4 holes, then 0 sites on an IDENTICAL body — the statement holes on the left
    -- swallowed the identifier the inserted line needs, so instantiation failed at every site, silently
    local rules = assert(BX.learn('local function f()\n  local a = 1\n  return a\nend',
        'local function f()\n  local a = 1\n  a = a + 1\n  return a\nend'))
    eq(1, #rules); eq(1, rules[1].holes, 'one hole: the identifier the insertion reuses')
    local same, n1 = BX.rewrite(rules, 'local function g()\n  local a = 1\n  return a\nend\n')
    eq(1, n1); eq('local function g()\n  local a = 1\n  a = a + 1\n  return a\nend\n', same)
    local renamed, n2 = BX.rewrite(rules, 'local function h()\n  local q = 1\n  return q\nend\n')
    eq(1, n2); eq('local function h()\n  local q = 1\n  q = q + 1\n  return q\nend\n', renamed, 'the inserted line uses the TARGET\'s name')
end)

test('byexample: a CONSTANT the example keeps stays part of the pattern, and overlapping matches rewrite once', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local rules = assert(BX.learn('if x == 0 then return end', 'if x <= 0 then return end'))
    eq('x == 0', rules[1].lhs_text)
    local out, n = BX.rewrite(rules, 'if y == 0 then return end\nif y == 5 then return end\n')
    eq(1, n, 'y == 5 is not the demonstrated comparison with 0')
    ok(out:find('if y <= 0 then', 1, true) and out:find('if y == 5 then', 1, true), out)
    -- the outer match covers the inner one: one rewrite, with the inner expression as its operand
    local nil_rules = assert(BX.learn('if x == nil then return 0 end', 'if not x then return 0 end'))
    local o2, n2 = BX.rewrite(nil_rules, 'if (y == nil) == nil then return end\n')
    eq(1, n2); eq('if not (y == nil) then return end\n', o2)
end)

test('byexample: a file in scope the lossless reader cannot read is NAMED as not looked at, never counted as "no match"', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { ['a.lua'] = 'local A = {}\nfunction A.f(q)\n  if q == nil then return 3 end\nend\nreturn A\n',
        ['broken.lua'] = 'local B = {\nfunction B.g(\n' }
    local p = assert(BX.plan(store, { before = 'if x == nil then return 0 end', after = 'if not x then return 0 end', scope = 'a.lua,broken.lua' }))
    local h = require('cartograph.hazard').plain(p.hazards)
    eq('unread', h[1] and h[1].kind); eq('frontier', h[1].class); ok(h[1].text:find('broken.lua', 1, true), h[1].text)
end)

test('learn-from-example: an example that shows its own rule is TOO GENERAL fails its demonstration — and is not written', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { ['m.lua'] = 'local M = {}\nreturn M\n' }
    -- the pattern occurs twice and only the second was edited: the learned rule rewrites both, so on BEFORE it does
    -- not produce AFTER — the example itself says the rule is wrong
    local r = tb.run(store, 'learn-from-example', { name = 'too-general',
        before = 'local a = x == nil\nif x == nil then return 0 end', after = 'local a = x == nil\nif not x then return 0 end' }, { apply = true })
    eq('failed', r.status); ok(r.why:find('fails its own examples', 1, true), r.why)
    eq(0, vim.fn.filereadable(root .. '/.cartograph/tactics/too-general.lua'), 'not written')
end)
