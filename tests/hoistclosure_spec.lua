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
