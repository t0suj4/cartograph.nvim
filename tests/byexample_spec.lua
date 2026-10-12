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
    eq(3, n, 'y == nil, t[k] == nil and the unspaced y==nil')
    ok(out:find('if not y then return 1 end', 1, true) and out:find('if not t[k] then return false end', 1, true), out)
    -- (CART-1664: the unspaced form is matched on STRUCTURE — an expression rule's output is parsed back IN ITS FILE;
    -- read alone, `not y` was no statement and every expression-level site was refused)
    ok(out:find('if not y then return 2 end', 1, true), 'spacing-independent: ' .. out)
    ok(out:find('return y ~= nil and 1 or 0', 1, true), 'a different operator is a different pattern')
    -- byte-identical outside the three rewritten spans
    eq(SRC:gsub('if y == nil then', 'if not y then'):gsub('if t%[k%] == nil', 'if not t[k]'):gsub('if y==nil then', 'if not y then'), out)
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
    eq(nil, p); eq('decision', class); ok(why:find('4 site(s) in 2 file(s)', 1, true), why)
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

test('byexample: a STRUCTURAL MOVE is ONE rule — regions that exchange a carried subterm are merged at their common ancestor (CART-1435)', function ()
    if not ready() then skip 'no lua parser or algebra' end
    -- the receiver moving into the arguments: three differing regions, `iconText` leaving the first for the third
    local moved = assert(BX.learn('iconText:SetFont(TSMAPI.Design:GetContentFont("normal"))',
        'TSMAPI.Design:SetContentFont(iconText, "normal")', 'lua'))
    eq(1, #moved, 'one rule, not `iconText -> TSMAPI.Design` among three')
    eq('iconText:SetFont(TSMAPI.Design:GetContentFont("normal"))', moved[1].lhs_text)
    -- the same move, small enough to apply: the method's receiver becomes the function's first argument; the name
    -- `obj` elsewhere is left alone (under the old learning, `obj -> show` was a rule of its own)
    local move = assert(BX.learn('obj:Show(a)', 'show(obj, a)', 'lua'))
    eq(1, #move)
    local out, n = BX.rewrite(move, 'local r = w:Show(z)\nlocal obj = 1\n', 'lua')
    eq('local r = show(w, z)\nlocal obj = 1\n', out); eq(1, n)
    -- a swap's two argument regions report bare LITERALS; lifted to their identifiers they carry each other's name and
    -- merge — and the callee `f -> g`, a sibling edit in the SAME statement that carries nothing, merges with them
    -- (CART-1664: one statement, one edit): the rule is the whole demonstrated edit, `f(?1, ?2) -> g(?2, ?1)` — never
    -- three token rules (`a -> b`, `b -> a`, `f -> g`) that would rewrite every `a` and `b`
    local swap = assert(BX.learn('f(a, b)', 'g(b, a)', 'lua'))
    eq(1, #swap, 'one rule')
    local sout, sn = BX.rewrite(swap, 'local r = f(x, y)\nlocal a, b = 1, 2\n', 'lua')
    eq('local r = g(y, x)\nlocal a, b = 1, 2\n', sout); eq(1, sn)
end)

test('byexample: a region with NO CONSTANT is no evidence — lifted until it holds one, so a binder-list edit stays with its loop (CART-1452)', function ()
    if not ready() then skip 'no lua parser or algebra' end
    -- `c -> _, c` alone (everything in it carried over) matched every one-name list: `local M = {}` became `local _, M`
    local rules = assert(BX.learn('for c in node:iter_children() do g(c) end', 'for _, c in tsutil.inext, node, -1 do g(c) end', 'lua'))
    eq(1, #rules, 'one rule for the loop header, not a binder-list rule beside it')
    eq('c in node:iter_children()', rules[1].lhs_text)
    local src = 'local M = {}\nfor x in n:iter_children() do if x:named() then f(x) end end\nfor k, v in pairs(t) do end\n'
    local out, n = BX.rewrite(rules, src, 'lua')
    eq('local M = {}\nfor _, x in tsutil.inext, n, -1 do if x:named() then f(x) end end\nfor k, v in pairs(t) do end\n', out)
    eq(1, n)
    -- (WHITESPACE is no constant: inserting `x()` between two carried statements makes the block `?1 ?2` — any
    -- two-statement block, an if's body included — so it is lifted to the function that holds it)
    local ins = assert(BX.learn('local function f()\n  a()\n  b()\nend', 'local function f()\n  a()\n  x()\n  b()\nend', 'lua'))
    eq(1, #ins)
    local src2 = 'if c then\n  a()\n  b()\nend\n'
    local out2, n2 = BX.rewrite(ins, src2, 'lua')
    eq(src2, out2, 'an if body is no function'); eq(0, n2)
end)

test('byexample: a CONSTANT the example keeps stays part of the pattern, and overlapping matches rewrite once', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local rules = assert(BX.learn('if x == 0 then return end', 'if x <= 0 then return end'))
    eq('x == 0', rules[1].lhs_text)
    local out, n = BX.rewrite(rules, 'if y == 0 then return end\nif y == 5 then return end\n')
    eq(1, n, 'y == 5 is not the demonstrated comparison with 0')
    ok(out:find('if y <= 0 then', 1, true) and out:find('if y == 5 then', 1, true), out)
    -- the outer match covers the inner one in ONE pass, and the next pass takes the inner one: a rewrite reaches its
    -- FIXPOINT (CART-1664), so running it again finds nothing — one pass had left `y == nil` for a rerun to rewrite
    local nil_rules = assert(BX.learn('if x == nil then return 0 end', 'if not x then return 0 end'))
    local o2, n2 = BX.rewrite(nil_rules, 'if (y == nil) == nil then return end\n')
    eq(2, n2); eq('if not (not y) then return end\n', o2)
    local _, n3 = BX.rewrite(nil_rules, o2)
    eq(0, n3, 'a rerun is empty')
end)

test('byexample: a file in scope the lossless reader cannot read is NAMED as not looked at, never counted as "no match" — unless its TEXT already rules a match out', function ()
    if not ready() then skip 'no lua parser or algebra' end
    -- broken.lua carries the rule's fixed tokens (`==`, `nil`), so the prefilter cannot rule it out: it must be READ,
    -- and it cannot be — named as unread. notokens.lua is just as broken but lacks a fixed token: no instance of the
    -- rule can be in its text (the prefilter's sound condition), so it is counted as PREFILTERED, not as unread
    project { ['a.lua'] = 'local A = {}\nfunction A.f(q)\n  if q == nil then return 3 end\nend\nreturn A\n',
        ['broken.lua'] = 'local B = {\nfunction B.g(q) if q == nil then\n', ['notokens.lua'] = 'local C = {\nfunction C.h(\n' }
    local p = assert(BX.plan(store, { before = 'if x == nil then return 0 end', after = 'if not x then return 0 end', scope = 'a.lua,broken.lua,notokens.lua' }))
    local h = require('cartograph.hazard').plain(p.hazards)
    eq('unread', h[1] and h[1].kind); eq('frontier', h[1].class); ok(h[1].text:find('broken.lua', 1, true), h[1].text)
    ok(not h[1].text:find('notokens.lua', 1, true), h[1].text)
    eq(1, p.prefiltered, 'notokens.lua ruled out by its text')
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

test('byexample: ONE STATEMENT, ONE EDIT and a moved SOLE STATEMENT is a sequence — the named-children loop refactor (CART-1664)', function ()
    if not ready() then skip 'no lua parser or algebra' end
    -- two regions (inext -> inamed, the check removed) in ONE statement: one rule, not two that are each wrong alone;
    -- the loop variable used twice is one hole; the body, moved out of the `if`, binds a sequence of any length
    local rules = assert(BX.learn('for _, c in tsutil.inext, n, -1 do if c:named() then walk(c) end end',
        'for _, c in tsutil.inamed, n, -1 do walk(c) end', 'lua'))
    eq(1, #rules, 'one rule')
    local src = table.concat({
        'for _, x in tsutil.inext, m, -1 do if x:named() then local t = x:type(); seen[t] = true end end',
        'for _, x in tsutil.inext, m, -1 do if x:named() then f(x) else g(x) end end',
        'for _, x in tsutil.inext, m, -1 do f(x) end',
        'if x:named() then f(x) end', '' }, '\n')
    local out, n = BX.rewrite(rules, src, 'lua')
    eq(1, n, 'only the loop whose whole body is the check')
    eq(table.concat({
        'for _, x in tsutil.inamed, m, -1 do local t = x:type(); seen[t] = true end',
        'for _, x in tsutil.inext, m, -1 do if x:named() then f(x) else g(x) end end',
        'for _, x in tsutil.inext, m, -1 do f(x) end',
        'if x:named() then f(x) end', '' }, '\n'), out)
end)

test('byexample: a body CARRIED UNCHANGED stands for any body — `if a then f(x) end -> if b then f(x) end` rewrites the condition whatever the body (CART-1664)', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local rules = assert(BX.learn('if a then f(x) end', 'if b then f(x) end', 'lua'))
    local out, n = BX.rewrite(rules, 'if a then g(); h(1) end\nif c then f(x) end\n', 'lua')
    eq(1, n); eq('if b then g(); h(1) end\nif c then f(x) end\n', out)
end)

test('byexample: a sole child pairs as a sequence only with a parent of the SAME kind — an argument list is no body (CART-1664)', function ()
    if not ready() then skip 'no lua parser or algebra' end
    -- (paired across kinds, the sequence would carry the argument list's parentheses into the block: `do (h(y)) end`)
    local rules = assert(BX.learn('g(f(x))', 'do f(x) end', 'lua'))
    local out, n = BX.rewrite(rules, 'g(h(y))\n', 'lua')
    eq(1, n); eq('do h(y) end\n', out)
end)

-- ── SPACING-INDEPENDENT MATCHING (CART-1664) ─────────────────────────────────────────────────────────────────────
local LOOP_B = 'for _, c in tsutil.inext, n, -1 do if c:named() then walk(c) end end'
local LOOP_A = 'for _, c in tsutil.inamed, n, -1 do walk(c) end'

test('byexample: a ONE-LINE example rewrites MULTI-LINE targets — kept tokens keep their spacing, the moved body is dedented (CART-1664)', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local rules = assert(BX.learn(LOOP_B, LOOP_A, 'lua'))
    local src = table.concat({
        'local function a(n)',
        '    for _, x in tsutil.inext, n, -1 do',
        '        if x:named() then',
        '            local t = x:type()',
        '            seen[t] = true',
        '        end',
        '    end',
        'end',
        'local function b(vl)',
        '    for _, v in tsutil.inext, vl, -1 do',
        '        if v:named() then i = i + 1; g(v) end',
        '    end',
        'end', '' }, '\n')
    local out, n = BX.rewrite(rules, src, 'lua')
    eq(2, n)
    eq(table.concat({
        'local function a(n)',
        '    for _, x in tsutil.inamed, n, -1 do',
        '        local t = x:type()',
        '        seen[t] = true',
        '    end',
        'end',
        'local function b(vl)',
        '    for _, v in tsutil.inamed, vl, -1 do',
        '        i = i + 1; g(v)',
        '    end',
        'end', '' }, '\n'), out)
    local _, again = BX.rewrite(rules, out, 'lua')
    eq(0, again, 'a rerun is empty')
end)

test('byexample: a COMMENT beside a deleted token refuses the site by name — it may describe the deleted code (CART-1664)', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local rules = assert(BX.learn(LOOP_B, LOOP_A, 'lua'))
    local src = 'for _, x in tsutil.inext, n, -1 do\n    if x:named() then -- the named ones\n        f(x)\n    end\nend\n'
    local out, n, refused = BX.rewrite(rules, src, 'lua')
    eq(0, n); eq(src, out)
    ok(refused[1] and refused[1].why:find('comment beside a deleted token', 1, true), vim.inspect(refused))
end)

test('byexample: an example that differs ONLY in spacing is refused — a spacing-free rule would match everything (CART-1664)', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local r, why = BX.learn('local x = f(a,b)', 'local x = f(a, b)', 'lua')
    eq(nil, r); ok(tostring(why):find('only in spacing', 1, true), tostring(why))
end)

test('byexample: PYTHON — the moved body is re-indented and the program answers the same (whitespace-significant, checked by parse-back) (CART-1664)', function ()
    if not ready() or not parser_available('python') then skip 'no python parser' end
    if vim.fn.executable('python3') == 0 then skip 'no python3' end
    local rules = assert(BX.learn('for c in every(xs):\n    if c.ok:\n        use(c)\n', 'for c in oks(xs):\n    use(c)\n', 'python'))
    local pre = 'def every(xs): return list(xs)\ndef oks(xs): return [x for x in xs if x.ok]\nclass I:\n    def __init__(s, n, ok): s.n, s.ok = n, ok\n'
    local src = pre .. 'def total(items):\n    acc = []\n    for it in every(items):\n        if it.ok:\n            v = it.n * 2\n            acc.append(v)\n    return acc\n'
    local out, n = BX.rewrite(rules, src, 'python')
    eq(1, n)
    ok(out:find('    for it in oks(items):\n        v = it.n * 2\n        acc.append(v)\n    return acc', 1, true), out)
    local tail = 'print(total([I(1, True), I(2, False), I(3, True)]))\n'
    local function run(code)
        local f = vim.fn.tempname() .. '.py'
        vim.fn.writefile(vim.split(code .. tail, '\n'), f)
        local r = vim.system({ 'python3', f }, { text = true }):wait()
        vim.fn.delete(f)
        return r.stdout
    end
    eq(run(src), run(out), 'before and after answer the same')
end)

test('byexample: PYTHON — a moved body holding a TRIPLE-QUOTED string: the code dedents, the string keeps its bytes, the program answers the same (CART-1664)', function ()
    if not ready() or not parser_available('python') then skip 'no python parser' end
    if vim.fn.executable('python3') == 0 then skip 'no python3' end
    local rules = assert(BX.learn('for c in every(xs):\n    if c.ok:\n        use(c)\n', 'for c in oks(xs):\n    use(c)\n', 'python'))
    local pre = 'def every(xs): return list(xs)\ndef oks(xs): return [x for x in xs if x.ok]\nclass I:\n    def __init__(s, n, ok): s.n, s.ok = n, ok\n'
    local src = pre .. 'def total(items):\n    acc = []\n    for it in every(items):\n        if it.ok:\n            v = """\n        head\n            %d\n"""\n            acc.append(v % it.n)\n    return acc\n'
    local out, n = BX.rewrite(rules, src, 'python')
    eq(1, n)
    ok(out:find('    for it in oks(items):\n        v = """\n        head\n            %d\n"""\n        acc.append(v % it.n)\n', 1, true), out)
    local tail = 'print(total([I(1, True), I(2, False), I(3, True)]))\n'
    local function run(code)
        local f = vim.fn.tempname() .. '.py'
        vim.fn.writefile(vim.split(code .. tail, '\n'), f)
        local r = vim.system({ 'python3', f }, { text = true }):wait()
        vim.fn.delete(f)
        return r.stdout
    end
    local a, b = run(src), run(out)
    ok(a:find('head', 1, true), 'the original runs: ' .. a)
    eq(a, b, 'before and after answer the same')
end)

-- PHP: braces, heredocs and nowdocs (CART-1664). The rule: unwrap an `if` inside a loop, learned with php's `name`
-- kind (read as `name_`) as the holes it is
local PHP_RULE = { '<?php\nforeach (every($xs) as $c) {\n    if ($c->ok) {\n        use_it($c);\n    }\n}\n', '<?php\nforeach (oks($xs) as $c) {\n    use_it($c);\n}\n' }
local PHP_PRE = '<?php\nclass I { public $n; public $ok; function __construct($n, $ok) { $this->n = $n; $this->ok = $ok; } }\nfunction every($xs) { return $xs; }\nfunction oks($xs) { return array_values(array_filter($xs, fn($x) => $x->ok)); }\n'
local function php_run(code)
    local f = vim.fn.tempname() .. '.php'
    vim.fn.writefile(vim.split(code .. 'echo json_encode(total([new I(1, true), new I(2, false), new I(3, true)])), "\\n";\n', '\n'), f)
    local r = vim.system({ 'php', f }, { text = true }):wait()
    vim.fn.delete(f)
    return r.stdout
end

test('byexample: PHP — the holes are php\'s names, and the loop keeps ITS brace: the body moves up a level, the inner `}` goes (CART-1664)', function ()
    if not ready() or not parser_available('php') then skip 'no php parser' end
    local rules = assert(BX.learn(PHP_RULE[1], PHP_RULE[2], 'php'))
    eq(2, rules[1].holes, 'php reads `name` as `name_`; with the escape mapped back its names are holes (there were 0)')
    -- the target laid out EXACTLY as the example: instantiating moved the body at its old depth and kept the inner `}`
    local out, n = BX.rewrite(rules, '<?php\nforeach (every($items) as $it) {\n    if ($it->ok) {\n        $x = 1;\n        f($x);\n    }\n}\n', 'php')
    eq(1, n)
    eq('<?php\nforeach (oks($items) as $it) {\n    $x = 1;\n    f($x);\n}\n', out)
end)

test('byexample: PHP — a moved body holding a HEREDOC and a NOWDOC: parsed back IN ITS FILE (a fragment is inline HTML), the program answers the same (CART-1664)', function ()
    if not ready() or not parser_available('php') then skip 'no php parser' end
    if vim.fn.executable('php') == 0 then skip 'no php' end
    local rules = assert(BX.learn(PHP_RULE[1], PHP_RULE[2], 'php'))
    local body = 'function total($items) {\n    $acc = [];\n    foreach (every($items) as $it) {\n        if ($it->ok) {\n            $a = <<<EOT\n        old {$it->n}\n          deeper\nEOT;\n            $c = <<<\'NOW\'\n            now $it->n\n          NOW;\n            $acc[] = $a . "|" . $c;\n        }\n    }\n    return $acc;\n}\n'
    local out, n = BX.rewrite(rules, PHP_PRE .. body, 'php')
    eq(1, n)
    ok(out:find('foreach (oks($items) as $it) {', 1, true), out)
    ok(out:find('            $a = <<<EOT\n        old {$it->n}\n          deeper\nEOT;\n', 1, true), 'the heredoc keeps every byte (its marker at column 0 holds the body at its depth): ' .. out)
    local a, b = php_run(PHP_PRE .. body), php_run(out)
    ok(a:find('deeper', 1, true), 'the original runs: ' .. a)
    eq(a, b, 'before and after answer the same')
end)

test('byexample: PHP — a re-indent that would change a FLEXIBLE heredoc\'s text is not taken: every carried value must read back the same (CART-1664)', function ()
    if not ready() or not parser_available('php') then skip 'no php parser' end
    local rules = assert(BX.learn(PHP_RULE[1], PHP_RULE[2], 'php'))
    -- (php's heredoc lines are separated by whitespace GAPS: no token spans the line, so only comparing the carried
    -- values sees the re-indent reach into the string — the right side's holes match anything)
    local heredoc = '            $b = <<<EOT\n              flexible {$it->n}\n              EOT;\n'
    local src = PHP_PRE .. 'function total($items) {\n    $acc = [];\n    foreach (every($items) as $it) {\n        if ($it->ok) {\n' .. heredoc .. '            $acc[] = $b;\n        }\n    }\n    return $acc;\n}\n'
    local out, n = BX.rewrite(rules, src, 'php')
    eq(1, n)
    ok(out:find('foreach (oks($items) as $it) {\n' .. heredoc, 1, true), 'the body keeps its depth, the heredoc its bytes: ' .. out)
    if vim.fn.executable('php') == 1 then eq(php_run(src), php_run(out), 'before and after answer the same') end
end)

test('byexample: RUBY — a carried call keeps its own `(` `)`: a token is keyed by its parent, not its whole ancestry (CART-1664)', function ()
    if not ready() or not parser_available('ruby') then skip 'no ruby parser' end
    local rules = assert(BX.learn('every(xs).each do |c|\n  if c.ok\n    use(c)\n  end\nend\n', 'oks(xs).each do |c|\n  use(c)\nend\n', 'ruby'))
    local out, n = BX.rewrite(rules, 'def t(items)\n  every(items).each do |it|\n    if it.ok\n      f(it)\n    end\n  end\nend\n', 'ruby')
    eq(1, n)
    eq('def t(items)\n  oks(items).each do |it|\n    f(it)\n  end\nend\n', out)
end)

test('byexample: a moved body holding a LONG STRING is re-indented around it — the string\'s continuation lines are its value, like a heredoc\'s (CART-1664)', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local rules = assert(BX.learn(LOOP_B, LOOP_A, 'lua'))
    local src = 'for _, x in tsutil.inext, n, -1 do\n    if x:named() then\n        local s = [[\n        keep me\n        ]]\n        f(x, s)\n    end\nend\n'
    local out, n = BX.rewrite(rules, src, 'lua')
    eq(1, n)
    eq('for _, x in tsutil.inamed, n, -1 do\n    local s = [[\n        keep me\n        ]]\n    f(x, s)\nend\n', out, 'the code lines dedented, the string\'s lines kept')
    local before_s = src:match('%[%[(.-)%]%]')
    eq(before_s, out:match('%[%[(.-)%]%]'), 'the long string\'s value is unchanged')
end)
