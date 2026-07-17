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

-- ── INC 2: redundant-check elimination ──────────────────────────────────────

-- redundant checks of a fn as { line -> {always} }
local function redundant(name)
    local out = {}
    for _, c in ipairs(narrow.redundant(store, fn_id(name)).checks) do
        out[c.line] = { always = c.always }
    end
    return out
end

test('narrow: re-testing a proven fact is redundant (always true)', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- non-nil determines `x ~= nil` (always true). NOTE `if x` would NOT be redundant
    -- here: x is non-nil but could be `false` — truthy is stronger than non-nil.
    ingest {
        'local function f(x)',
        '  if x ~= nil then',
        '    if x ~= nil then',   -- L3: x already non-nil -> always true
        '      use(x)',
        '    end',
        '  end',
        'end',
        'return { f }',
    }
    local r = redundant('f')
    ok(r[3], 'the inner `if x ~= nil` is redundant')
    eq(true, r[3].always)
end)

test('narrow: `if x` is NOT redundant under x~=nil (x could be false)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x)',
        '  if x ~= nil then',
        '    if x then use(x) end',   -- L3: non-nil does NOT prove truthy
        '  end',
        'end',
        'return { f }',
    }
    eq(nil, next(redundant('f')))
end)

test('narrow: a contradicting check is redundant (dead branch)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x)',
        '  if x ~= nil then',
        '    if x == nil then',   -- L3: contradicts -> always false, dead then
        '      bad()',
        '    end',
        '  end',
        'end',
        'return { f }',
    }
    local r = redundant('f')
    ok(r[3], 'the `if x == nil` is redundant')
    eq(false, r[3].always)
end)

test('narrow: a check on an unproven var is NOT redundant', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x, y)',
        '  if x ~= nil then',
        '    if y then use(y) end',   -- L3: y unknown -> not redundant
        '  end',
        'end',
        'return { f }',
    }
    eq(nil, next(redundant('f')))
end)

test('narrow: a check outside the proving guard is NOT redundant', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x)',
        '  if x ~= nil then use(x) end',
        '  if x then use(x) end',   -- L3: outside the first guard -> not redundant
        'end',
        'return { f }',
    }
    eq(nil, next(redundant('f')))
end)

test('narrow: report surfaces redundant checks', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x)',
        '  if x ~= nil then',
        '    if x ~= nil then use(x) end',
        '  end',
        'end',
        'return { f }',
    }
    local joined = table.concat(narrow.report(store, fn_id('f')), '\n')
    ok(joined:match('redundant check'), 'the report has a redundant-check section')
    ok(joined:match('always true'), 'and the verdict')
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

-- ── field-path narrowing (narrow v2) ─────────────────────────────────────────
test('narrow v2: `if opts.subdirs then` narrows the field path', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(opts)',
        '  if opts.subdirs then',
        '    use(opts.subdirs)',   -- L3
        '  end',
        'end',
        'return { f }',
    }
    eq('non-nil', env_at('f', 3)['opts.subdirs'])
end)

test('narrow v2: discriminant `x.kind == "A"` narrows the path to a value', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x)',
        '  if x.kind == "A" then',
        '    local v = x.value',   -- L3 — reads a sibling field, does not stale x.kind
        '  end',
        'end',
        'return { f }',
    }
    eq('eq:s:A', env_at('f', 3)['x.kind'])
end)

test('narrow v2: a field-write on the root STALES the path (sound kill)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(opts)',
        '  if opts.mode then',
        '    opts.mode = nil',      -- field-write → opts unstable
        '    use(opts.mode)',   -- L4 — must NOT be narrowed
        '  end',
        'end',
        'return { f }',
    }
    eq(nil, env_at('f', 4)['opts.mode'])
end)

test('narrow v2: passing the root to a call STALES the path (call may mutate)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(opts)',
        '  if opts.mode then',
        '    mutate(opts)',         -- opts escapes → unstable
        '    use(opts.mode)',   -- L4 — must NOT be narrowed
        '  end',
        'end',
        'return { f }',
    }
    eq(nil, env_at('f', 4)['opts.mode'])
end)

test('narrow v2: aliasing the root STALES the path (invisible mutation)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(opts)',
        '  if opts.mode then',
        '    local y = opts',       -- alias → later y.mode=… invisible to opts.mode
        '    use(opts.mode)',   -- L4 — must NOT be narrowed
        '  end',
        'end',
        'return { f }',
    }
    eq(nil, env_at('f', 4)['opts.mode'])
end)

test('narrow v2: a bare var passed to a call is STILL narrowed (call-immune)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x)',
        '  if x then',
        '    use(x)',              -- call receives x, but cannot nil a caller local
        '    other(x)',   -- L4 — x still non-nil
        '  end',
        'end',
        'return { f }',
    }
    eq('non-nil', env_at('f', 4).x)
end)

test('narrow v2: redundant discriminant re-test on a field path (dead / always)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x)',
        '  if x.kind == "A" then',
        '    if x.kind == "B" then return 1 end',   -- L3 dead (A ~= B)
        '    if x.kind == "A" then return 2 end',   -- L4 always-true
        '  end',
        'end',
        'return { f }',
    }
    local r = redundant('f')
    eq(false, r[3] and r[3].always)   -- dead
    eq(true, r[4] and r[4].always)    -- always-true
end)

-- ── devirtualization report (narrow v2, the type-fact consumer) ──────────────
local function devirt(name) return narrow.devirt(store, fn_id(name)) end

test('devirt: a string-narrowed receiver certifies `s:m()` → string.m', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(s)',
        '  if type(s) == "string" then',
        '    return s:upper()',
        '  end',
        'end',
        'return { f }',
    }
    local r = devirt('f')
    eq(1, r.summary.certified)
    eq('certified', r.sites[1].status)
    eq('string.upper', r.sites[1].target)
end)

test('devirt: an early-exit type guard certifies the fall-through dispatch', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(s)',
        '  if type(s) ~= "string" then return end',
        '  return s:match("%d+")',
        'end',
        'return { f }',
    }
    eq('string.match', devirt('f').sites[1].target)
end)

test('devirt: a truthy-only receiver is NOT a devirt site (type unknown)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(s)',
        '  if s then return s:upper() end',   -- non-nil says nothing about the method
        'end',
        'return { f }',
    }
    local r = devirt('f')
    eq(0, r.summary.typed)
    eq(1, r.summary.method_calls)
end)

test('devirt: a table-narrowed receiver is a CANDIDATE (blocked on the VM)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(t)',
        '  if type(t) == "table" then return t:method() end',
        'end',
        'return { f }',
    }
    local r = devirt('f')
    eq(0, r.summary.certified)
    eq(1, r.summary.candidate)
    eq('candidate', r.sites[1].status)
end)

-- ── parameter-nilability (Rung 2, the lua-ls disagreement oracle) ─────────────
-- verdict for param `pn` of fn `name`, plus its conflict flag
local function pnil(name, pn)
    for _, p in ipairs(narrow.param_nilability(store, fn_id(name)).params) do
        if p.name == pn then return p end
    end
end

test('paramnil: an unguarded deref infers a required (non-nil) parameter', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(p) return p.x end',      -- required
        'local function g(a, b) return a + b end',  -- both required (arithmetic)
        'return { f, g }',
    }
    eq('required', pnil('f', 'p').verdict)
    eq('required', pnil('g', 'a').verdict)
    eq('required', pnil('g', 'b').verdict)
end)

test('paramnil: a guarded / short-circuited / reassigned param is not required', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(p) if p then return p.x end end',   -- optional (guarded)
        'local function g(p) return p and p.x end',            -- optional (short-circuit)
        'local function h(p) if p == nil then bad() end return p.x end', -- optional (nil-tested, correlated)
        'local function i(p) p = p or {} return p.x end',      -- unknown (reassigned)
        'return { f, g, h, i }',
    }
    eq('optional', pnil('f', 'p').verdict)
    eq('optional', pnil('g', 'p').verdict)
    eq('optional', pnil('h', 'p').verdict)  -- the correlated-guard soundness case
    eq('unknown', pnil('i', 'p').verdict)
end)

test('paramnil: assert(p) enforces required', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest { 'local function f(p) assert(p) return p.x end', 'return { f }' }
    eq('required', pnil('f', 'p').verdict)
end)

test('paramnil: DISAGREEMENT — required deref of a param annotated optional (`?`)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        '---@param p? table',
        'local function f(p) return p.x end',    -- required vs @optional → conflict
        '---@param q table',
        'local function g(q) return q.x end',    -- required vs @non-nil → agree
        'return { f, g }',
    }
    local pf = pnil('f', 'p')
    eq('required', pf.verdict); eq('optional', pf.annotated); ok(pf.conflict, 'conflict flagged')
    local pg = pnil('g', 'q')
    eq('non-nil', pg.annotated); ok(not pg.conflict, 'agreement is not a conflict')
end)

test('paramnil: a complex `{…}?` annotation is not mis-read (no false conflict)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        '---@param opts { a:string }?',
        'local function f(opts) if opts then return opts.a end end',
        'return { f }',
    }
    local p = pnil('f', 'opts')
    eq('optional', p.verdict)
    ok(not p.conflict, 'a complex optional type is either parsed optional or skipped — never a false conflict')
end)

-- ── narrow v2: type-test narrowing (the devirtualization seed) ────────────────
test('narrow: type(x)==\'T\' narrows x to that type; `or` does not', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(a, c)',
        '  if type(a) == "string" then',
        '    use(a)',                       -- L3: a is type:string
        '  end',
        '  if type(a) == "table" or c then',
        '    use(a)',                       -- L6: `or` → not narrowed
        '  end',
        '  if type(a) ~= "number" then return end',
        '  step(a)',                        -- L9: early-exit → a is type:number
        'end', 'return { f }',
    }
    eq('type:string', env_at('f', 3).a)
    eq(nil, env_at('f', 6).a)
    eq('type:number', env_at('f', 9).a)
end)

test('narrow: redundant + dead type-checks; a type implies non-nil', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x, z)',
        '  if type(x) == "table" then',
        '    if type(x) == "table" then a() end',  -- L3 redundant (always true)
        '    if type(x) == "number" then b() end', -- L4 contradiction (dead)
        '    if x == nil then c() end',             -- L5 dead (type ⟹ non-nil)
        '    if type(z) == "number" then d() end',  -- L6 different var → NOT flagged
        '  end',
        'end', 'return { f }',
    }
    local checks = {}
    for _, c in ipairs(narrow.redundant(store, fn_id('f')).checks) do checks[c.line] = c.always end
    eq(true, checks[3])   -- always-true
    eq(false, checks[4])  -- dead
    eq(false, checks[5])  -- dead (type implies non-nil)
    eq(nil, checks[6])    -- undetermined (different var) → not a check
end)

test('narrow: a shadowed `type` disables type-test narrowing (soundness)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function g(x, type)',            -- `type` is a PARAM → not the builtin
        '  if type(x) == "string" then',
        '    use(x)',                            -- must NOT narrow (type is shadowed)
        '  end',
        'end', 'return { g }',
    }
    eq(nil, env_at('g', 3).x)
end)
