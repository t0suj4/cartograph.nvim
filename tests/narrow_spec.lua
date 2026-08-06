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

-- ── RUBY (CART-0300) ────────────────────────────────────────────────────────
-- The vocab was sized by a CENSUS of 6494 real guard conditions before it was
-- written, and the census overturned the obvious design: `x.nil?` is the RAREST
-- form (1.8%), while presence predicates and plain method dispatch dominate. A
-- nil-centred port of the lua vocab would have measured as nearly dead.

local function rb(lines) ingest(lines, 'rb') end

test('narrow ruby: `return unless p` leaves p narrowed AFTER it', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- the rails guard-clause idiom, and the reason cfg needed the INVERTED set
    rb {
        'class K',
        '  def f(p)',
        '    return unless p',
        '    use(p)',        -- L4
        '  end',
        'end',
    }
    eq('non-nil', env_at('K#f', 4).p)
end)

test('narrow ruby: present? narrows, blank? narrows its ELSE, nil? inverts', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    rb {
        'class K',
        '  def f(a, b, c)',
        '    if a.present?',
        '      use(a)',      -- L4
        '    end',
        '    if b.blank?',
        '      noop(b)',     -- L7  — blank? holding proves nothing positive
        '    else',
        '      use(b)',      -- L9  — ¬blank? ⇒ present ⇒ truthy
        '    end',
        '    unless c.nil?',
        '      use(c)',      -- L12 — `unless x.nil?` body: NOT nil? ⇒ non-nil
        '    end',
        '  end',
        'end',
    }
    eq('non-nil', env_at('K#f', 4).a)
    eq('non-nil', env_at('K#f', 9).b)
    eq('non-nil', env_at('K#f', 12).c)
    -- L7 stands on `b.blank?` being TRUE, which says b is nil-or-empty: the only
    -- thing we know is that b answered the call, and blank? is a method NilClass
    -- HAS under ActiveSupport, so not even that. No fact.
    eq(nil, env_at('K#f', 7).b)
end)

test('narrow ruby: ★ dispatching ANY method proves the receiver non-nil, BOTH ways', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- The rung the census found largest (47-55% of all facts) and the only
    -- polarity-INDEPENDENT one here: `nil.empty?` raises NoMethodError, so if
    -- execution got past the condition at all, x was not nil — in the then AND the
    -- else. Nothing in the lua vocab works like this.
    rb {
        'class K',
        '  def f(x)',
        '    if x.empty?',
        '      a(x)',        -- L4
        '    else',
        '      b(x)',        -- L6
        '    end',
        '  end',
        'end',
    }
    eq('non-nil', env_at('K#f', 4).x)
    eq('non-nil', env_at('K#f', 6).x, 'the ELSE branch too — the call happened either way')
end)

test('narrow ruby: safe navigation and NilClass methods prove NOTHING', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- `&.` exists precisely to permit nil, and nil really does answer to_s/class/
    -- nil?/present?, so dispatching one of those is not evidence. Both are the
    -- soundness edge of the rung above: get either wrong and the biggest rung
    -- becomes the biggest source of false facts.
    rb {
        'class K',
        '  def f(x, y)',
        '    if x&.valid?',
        '      use(x)',      -- L4 — must NOT narrow
        '    end',
        '    if y.to_s == "q"',
        '      use(y)',      -- L7 — must NOT narrow: nil.to_s is legal
        '    end',
        '  end',
        'end',
    }
    eq(nil, env_at('K#f', 4).x)
    eq(nil, env_at('K#f', 7).y)
end)

test('narrow ruby: is_a? gives a type, == a discriminant, x.y.z gives NO path', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    rb {
        'class K',
        '  def f(x, y, z)',
        '    if x.is_a?(Numeric)',
        '      use(x)',      -- L4
        '    end',
        '    if y == :draft',
        '      use(y)',      -- L7
        '    end',
        '    if z.owner.active?',
        '      use(z)',      -- L10 — z non-nil (it answered .owner), but NOT z.owner
        '    end',
        '    if z.to_s.empty?',
        '      use(z)',      -- L13 — NO fact: nil answers to_s, so z may be nil
        '    end',
        '  end',
        'end',
    }
    eq('type:Numeric', env_at('K#f', 4).x)
    eq('eq:sym:draft', env_at('K#f', 7).y)
    -- ★ NO FIELD PATHS IN RUBY. In lua `z.owner` is a table read, stable until
    -- written, so lua narrows it under a staling gate. In ruby it is a METHOD
    -- DISPATCH that may answer differently on each call, and nothing syntactic
    -- distinguishes an attr_reader from a computation — so depth-≥1 is refused.
    eq(nil, env_at('K#f', 10)['z.owner'])
    eq('non-nil', env_at('K#f', 10).z, 'but the chain ROOT is still proven non-nil')
    -- and the method judged is the one dispatched ON THE ROOT, not the outermost
    eq(nil, env_at('K#f', 13).z, 'z.to_s.empty? proves nothing: nil answers to_s')
end)

test('narrow ruby: a REASSIGNED variable is not narrowed (the mutated_of gate)', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- ★ THE SOUNDNESS PIN. mutated_of matched the single literal
    -- 'assignment_statement' — LUA's node type. Ruby's is `assignment`, so wiring
    -- ruby into EXT_LANG made it return EMPTY for every ruby function: 6168
    -- assignments' worth of staling silently absent on discourse alone, and this
    -- test's narrowing would be reported as if the rebind never happened.
    rb {
        'class K',
        '  def f(p)',
        '    return unless p',
        '    p = fetch()',
        '    use(p)',        -- L5 — the guard is STALE, no fact
        '  end',
        'end',
    }
    eq(nil, env_at('K#f', 5).p)
end)

test('narrow ruby: the OTHER three verbs refuse ruby by name, not by silence', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- redundant/devirt/param_nilability still find their SUBJECTS with lua node
    -- types, and landing vocab.ruby was enough on its own to let them past the old
    -- `vocab[lang]` check — after which they would walk a ruby tree, match nothing
    -- and return an empty list, which reads as "nothing to report" rather than
    -- "not wired up". Refusing by name keeps the absence legible.
    rb {
        'class K',
        '  def f(x)',
        '    if x',
        '      use(x)',
        '    end',
        '  end',
        'end',
    }
    local id = fn_id('K#f')
    eq(nil, narrow.narrow(store, id).unsupported, 'the LENS serves ruby')
    eq(true, narrow.redundant(store, id).unsupported)
    eq(true, narrow.devirt(store, id).unsupported)
    eq(true, narrow.param_nilability(store, id).unsupported)
end)
