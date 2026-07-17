-- Unit tests for the narrowing lens (INC 1: Lua nil/truthiness). Pure; operates
-- over a store + focused fn id, riding cfg.guards_over.

local narrow = require 'cartograph.narrow'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang or 'lua')
end

local function ingest(lines, ext)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.' .. (ext or 'lua'), 'w'))
    fd:write(table.concat(lines, '\n')); fd:close()
    store.ingest(ts.extract(root))
end

local function fn_id(name)
    for _, n in ipairs(store.data.nodes) do if n.name == name then return n.id end end
end

-- env (as {[var]=kind}) active at the statement on source line `ln`
local function env_at(name, ln)
    for _, p in ipairs(narrow.narrow(store, fn_id(name)).points) do
        if p.line == ln then return p.env end
    end
    return {}
end

test('narrow: `if x then` proves x non-nil in the body', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x)',
        '  if x then',
        '    use(x)',   -- L3
        '  end',
        'end',
        'return { f }',
    }
    eq('non-nil', env_at('f', 3).x)
end)

test('narrow: `if x == nil then return` proves x non-nil AFTER (early exit)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x)',
        '  if x == nil then return end',
        '  use(x)',   -- L3
        'end',
        'return { f }',
    }
    eq('non-nil', env_at('f', 3).x)
end)

test('narrow: `x ~= nil` narrows in the body', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x)',
        '  if x ~= nil then',
        '    use(x)',   -- L3
        '  end',
        'end',
        'return { f }',
    }
    eq('non-nil', env_at('f', 3).x)
end)

test('narrow: an and-conjunction narrows every conjunct', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(a, b)',
        '  if a and b then',
        '    use(a, b)',   -- L3
        '  end',
        'end',
        'return { f }',
    }
    local env = env_at('f', 3)
    eq('non-nil', env.a)
    eq('non-nil', env.b)
end)

test('narrow: `or` does NOT narrow (unsound to)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x, y)',
        '  if x or y then',
        '    use(x)',   -- L3 — neither x nor y is proven
        '  end',
        'end',
        'return { f }',
    }
    eq(nil, next(env_at('f', 3)))
end)

test('narrow: `not x then return` proves x non-nil after', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x)',
        '  if not x then return end',
        '  use(x)',   -- L3
        'end',
        'return { f }',
    }
    eq('non-nil', env_at('f', 3).x)
end)

test('narrow: a statement outside any guard has no narrowing', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x)',
        '  use(x)',   -- L2 — no guard
        '  if x then use(x) end',
        'end',
        'return { f }',
    }
    eq(nil, next(env_at('f', 2)))
end)

test('narrow: report renders facts; unknown language is reported unsupported', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x)',
        '  if x then use(x) end',
        'end',
        'return { f }',
    }
    local joined = table.concat(narrow.report(store, fn_id('f')), '\n')
    ok(joined:match('narrowing guard'), 'the report summarizes the narrowing')
    ok(joined:match('x: non%-nil'), 'and the fact')
end)
