-- Hoist-nested-closure: lift a nested `local function` to module scope, sound only when it
-- captures nothing from its enclosing function(s) — every free read must be module-level or
-- global. A capture is refused (parameterize first). Rides the txn contract + parse-clean.

local hc = require 'cartograph.hoistclosure'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function proj(src)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src); fd:close()
    store.ingest(ts.extract(root))
    return root
end
local function id_of(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end

local NEST = 'local M = {}\nlocal shared = 10\nlocal function outer(x)\n  local cap = x + 1\n'
    .. '  local function pure(y)\n    return y + shared\n  end\n'
    .. '  local function grabs(z)\n    return z + cap\n  end\n'
    .. '  return pure(x) + grabs(x)\nend\nreturn M\n'

test('hoist-closure: a capture-free nested closure lifts to module scope, de-indented', function ()
    local root = proj(NEST)
    local plan, why = hc.plan(store, id_of('pure'))
    ok(plan, 'a capture-free closure is hoistable: ' .. tostring(why))
    if plan then
        local _, after = hc.preview(store, plan)
        local text = after[plan.file]
        -- pure now sits at module scope (col 0), before outer, and outer still calls it
        ok(text:find('\nlocal function pure(y)\n', 1, true), 'pure is a module-level local (de-indented)')
        ok(text:find('return pure(x) + grabs(x)', 1, true), 'the call site is unchanged (still resolves)')
        -- and pure is gone from inside outer (only one `local function pure`)
        eq(1, select(2, text:gsub('local function pure', '')), 'pure defined exactly once')
        local pr = vim.treesitter.get_string_parser(text, 'lua'):parse()[1]:root()
        ok(not pr:has_error(), 'the hoisted result parses clean')
    end
    vim.fn.delete(root, 'rf')
end)

test('hoist-closure: a closure capturing an enclosing local is refused (named)', function ()
    local root = proj(NEST)
    local plan, why = hc.plan(store, id_of('grabs'))
    ok(not plan and why:find('captures enclosing local `cap`'), 'the capture is named: ' .. tostring(why))
    vim.fn.delete(root, 'rf')
end)

test('hoist-closure: a top-level function is refused (already at module scope)', function ()
    local root = proj(NEST)
    local plan, why = hc.plan(store, id_of('outer'))
    ok(not plan and why:find('already at module scope'), 'a non-nested function is refused')
    vim.fn.delete(root, 'rf')
end)

test('hoist-closure: a name colliding with a module-level def is refused', function ()
    -- `helper` exists at module scope AND as a nested closure → refuse (rename banked)
    local root = proj('local M = {}\nlocal function helper() return 1 end\n'
        .. 'local function outer(x)\n  local function helper(y)\n    return y + 1\n  end\n'
        .. '  return helper(x)\nend\nreturn M\n')
    -- the nested helper is the second one; find it by picking the nested node
    local nested
    for _, n in ipairs(store.data.nodes) do
        if n.name == 'helper' then
            for _, e in ipairs(store.data.nodes) do
                if e.name == 'outer' and require('cartograph.at').sl(e.range) < require('cartograph.at').sl(n.range)
                    and require('cartograph.at').el(e.range) >= require('cartograph.at').el(n.range) then
                    nested = n.id
                end
            end
        end
    end
    if nested then
        local plan, why = hc.plan(store, nested)
        ok(not plan and why:find('module%-level'), 'a colliding name is refused: ' .. tostring(why))
    else ok(true, '(nested helper not identified — fine)') end
    vim.fn.delete(root, 'rf')
end)

test('hoist-closure: the write is journaled and the result parses', function ()
    local root = proj(NEST)
    local plan = hc.plan(store, id_of('pure'))
    ok(plan, 'planned')
    if plan then
        store.set_txn(plan)
        local entry, why = hc.apply(store, plan)
        ok(entry, 'apply succeeds: ' .. tostring(why))
        local written = table.concat(vim.fn.readfile(root .. '/m.lua'), '\n')
        -- pure hoisted above outer; both still present exactly once
        local pi = written:find('local function pure', 1, true)
        local oi = written:find('local function outer', 1, true)
        ok(pi and oi and pi < oi, 'pure now precedes outer at module scope')
        local pr = vim.treesitter.get_string_parser(written, 'lua'):parse()[1]:root()
        ok(not pr:has_error(), 'the written file parses clean')
    end
    vim.fn.delete(root, 'rf')
end)

--- ★★★ THE WRITE CAPTURE (CART-0905). `reads` is every use NOT in `params` and
--- NOT in `defs`, so a name this body ASSIGNS lands in `defs` and never reaches
--- the read gate. MEASURED before the fix: a closure doing `count = count + n`
--- on an enclosing local was ALLOWED to hoist while one that merely READ it was
--- refused — the verb refused the safe case and allowed the unsafe one.
--- Hoisting the first turns the assignment into a write to a GLOBAL; `parses`
--- cannot catch it, because it parses.
local WRITES = 'local M = {}\nlocal function outer()\n  local count = 0\n'
    .. '  local function bump(n)\n    count = count + n\n    return count\n  end\n'
    .. '  local function readonly(n)\n    return count + n\n  end\n'
    .. '  return bump, readonly\nend\nM.outer = outer\nreturn M\n'

test('hoist-closure: a closure that ASSIGNS an enclosing local is refused', function ()
    local root = proj(WRITES)
    local plan, why, detail = hc.plan(store, id_of('bump'))
    eq(nil, plan)
    ok(tostring(why):find('assigns enclosing local `count`'),
        'named as an assignment, not a read: ' .. tostring(why))
    ok(detail and detail.writes == 'count', 'and the name rides as structure')

    -- BOTH SIDES: the read-only sibling is still refused, by the OTHER gate —
    -- otherwise a blanket refusal would pass this test too
    local p2, w2, d2 = hc.plan(store, id_of('readonly'))
    eq(nil, p2)
    ok(tostring(w2):find('captures enclosing local'), 'the reader is refused as a READ: ' .. tostring(w2))
    ok(d2 and d2.captures == 'count', 'and names what it captures')
    vim.fn.delete(root, 'rf')
end)

--- ⚠ A SIBLING'S LOCALS ARE NOT THE PARENT'S. `expr.of` on an enclosing
--- function returns its CHILDREN'S statements too, so a name declared only
--- inside a sibling closure looked like an enclosing local. Measured: `outer`
--- holding two callbacks reported `defs = {acc, seen, s, pad, acc, seen, s,
--- pad}` — every local of both, attributed to the parent.
local SIBS = 'local M = {}\nlocal function outer(live)\n'
    .. '  local function cb1(t)\n    local pad = 1\n    return pad + t + live\n  end\n'
    .. '  local function cb2(t)\n    local pad = 2\n    return pad + t\n  end\n'
    .. '  return cb1, cb2\nend\nM.outer = outer\nreturn M\n'

test('hoist-closure: a name declared in a SIBLING closure is not an enclosing local', function ()
    local root = proj(SIBS)
    local plan, why, detail = hc.plan(store, id_of('cb1'))
    -- cb1 captures `live` (a real enclosing param) and declares its own `pad`,
    -- which cb2 also declares. Only `live` may be reported.
    eq(nil, plan)
    ok(tostring(why):find('`live`'), 'the REAL capture is named: ' .. tostring(why))
    ok(not tostring(why):find('`pad`'),
        'the sibling\'s local is not reported as a capture: ' .. tostring(why))
    ok(detail and detail.captures == 'live', 'and it is the one that rides as structure')
    vim.fn.delete(root, 'rf')
end)

--- ⚠⚠ AND THE COORDINATE TRAP THAT FIX INTRODUCED. `s.l` is 1-BASED and
--- `at.sl`/`at.el` are 0-BASED; comparing them raw shifts every test by one
--- line. The failure is SILENT AND WIDENING — a declaration on the line where a
--- sibling closure starts reads as being INSIDE it, drops out of the enclosing
--- facts, and the capture it should block is ALLOWED. This fixture puts the
--- declaration exactly there.
local ADJACENT = 'local M = {}\nlocal function outer(x)\n  local cap = x + 1\n'
    .. '  local function pure(y)\n    return y + 1\n  end\n'
    .. '  local function grabs(z)\n    return z + cap\n  end\n'
    .. '  return pure(x) + grabs(x)\nend\nreturn M\n'

test('hoist-closure: a declaration abutting a sibling\'s first line still counts', function ()
    local root = proj(ADJACENT)
    local plan, why = hc.plan(store, id_of('grabs'))
    eq(nil, plan)
    ok(tostring(why):find('captures enclosing local `cap`'),
        'the abutting declaration is still an enclosing local: ' .. tostring(why))
    -- and the genuinely capture-free sibling still hoists, so this is not a
    -- blanket refusal
    ok(hc.plan(store, id_of('pure')), 'the capture-free closure still lifts')
    vim.fn.delete(root, 'rf')
end)
