-- MODULE-LEVEL CODE HAS AN OWNER (cache v107).
--
-- Reported as "this function has a body but I don't know how to get into it", on a
-- top-level `return function() … end`. The navigation complaint was a SYMPTOM: the
-- call inside it resolved fine — target found, call.to set — and the edge was then
-- dropped because `fn_at` found no enclosing function, so `from` was nil. Measured
-- on Von-Neumann: 69 region nodes over 2045 source lines, contributing 0 of 110
-- call edges, and `createScript` reading as 0 callers AND 0 registrants.
--
-- The asymmetry that made it a defect rather than a design: the bare-NAME path
-- already kept its top-level evidence, as a registration from the module
-- ("referenced from top-level DATA"). So the WEAKER evidence was retained while an
-- actual CALL was discarded.
--
-- What this spec fences:
--   * the edge exists, and its owner is the REGION
--   * `call.fn` still means "a function" — consumers read it as one, so it stays nil
--   * only a STATEMENT-RUN region owns code. A container region (a vue/svelte
--     `template`) must not, or extract and relink disagree: extract indexes the runs
--     it minted, relink rebuilds from node_index which holds every region. That
--     divergence is a parallel-vs-sequential graph split, which is why `stmtrun`
--     exists and why it is a declared node field.
--   * scheme: `#:export (step limit)` inside a declaration form is DATA, but a
--     keyword-valued CALL anywhere else is still a call. The first blanket version
--     of that rule lost `#:on-error (repl-option-ref repl 'on-error)` from guile.

local store = require 'cartograph.store'
local ts    = require 'cartograph.providers.treesitter'

local function project(name, src)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/' .. name, 'w'))
    fd:write(src); fd:close()
    local data = ts.extract(root, {})
    store.ingest(data)
    return data, root
end

local function idof(data, nm)
    for _, n in ipairs(data.nodes) do if n.name == nm then return n.id end end
end

local function callers_of(data, nm)
    local out = {}
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'ref' and e.to == idof(data, nm) then out[#out + 1] = e.from end
    end
    return out
end


test('toplevel: a bare module-level call gets an edge, owned by the region',
    function ()
    local data = project('m.lua', table.concat({
        'local function target() end',
        '',
        'target()',
        '',
        'return target',
    }, '\n'))
    local cs = callers_of(data, 'target')
    eq(1, #cs, 'the top-level call produced exactly one edge')
    local owner = store.node(cs[1])
    ok(owner, 'its owner is a real node: ' .. tostring(cs[1]))
    eq('region', owner.kind, 'and it is the enclosing region')
    ok(owner.stmtrun, 'a statement-run region, marked as one')
end)

test('toplevel: a call inside a top-level anonymous function is owned too',
    function ()
    -- the reported shape: a module factory returning an anonymous function
    local data = project('m.lua', table.concat({
        'local function target() end',
        '',
        'return function()',
        '\treturn target()',
        'end',
    }, '\n'))
    local cs = callers_of(data, 'target')
    eq(1, #cs)
    eq('region', (store.node(cs[1]) or {}).kind)
end)

test('toplevel: a call inside a NAMED function is unchanged — still owned by the fn',
    function ()
    local data = project('m.lua', table.concat({
        'local function target() end',
        'local function named() target() end',
        'return named',
    }, '\n'))
    local cs = callers_of(data, 'target')
    eq(1, #cs)
    eq('function', (store.node(cs[1]) or {}).kind)
    eq(idof(data, 'named'), cs[1])
end)

test('toplevel: call.fn stays nil at module level — it means "a function"',
    function ()
    -- consumers read call.fn as a function id (band:sites, the fn view). The v107
    -- change adds an EDGE; it must not quietly widen what call.fn denotes.
    local data = project('m.lua', table.concat({
        'local function target() end',
        'target()',
        'return target',
    }, '\n'))
    local seen = false
    for _, c in ipairs(data.calls or {}) do
        if c.callee == 'target' then
            seen = true
            eq(nil, c.fn, 'a module-level call has no enclosing FUNCTION')
            ok(c.to, 'though it resolved: the target was known all along')
        end
    end
    ok(seen, 'the call record is there')
end)

test('toplevel: every region that owns an edge is a stmtrun, never a container',
    function ()
    -- the parity guard. A container region (vue/svelte `template`) is minted by a
    -- different pass and is not in extract's index; relink rebuilds from node_index,
    -- which holds every region, so an unmarked container would be attributed in one
    -- path and not the other.
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local function target() end\ntarget()\nreturn target\n'); fd:close()
    local data = ts.extract(root, {})
    store.ingest(data)
    local owners = {}
    for _, e in ipairs(data.edges or {}) do
        local n = e.from and store.node(e.from)
        if n and n.kind == 'region' then owners[#owners + 1] = n end
    end
    ok(#owners > 0, 'something is owned by a region here')
    for _, n in ipairs(owners) do
        ok(n.stmtrun, ('region %s owns an edge without the stmtrun mark'):format(n.id))
    end
end)

test('toplevel: stmtrun is a DECLARED node field, so the schema still validates',
    function ()
    local validate = require 'cartograph.validate'
    ok(validate.NODE_FIELDS.stmtrun,
        'an undeclared field fails the closed-schema check on every region')
    local data = project('m.lua', 'local function t() end\nt()\nreturn t\n')
    local res = validate.check and validate.check(data) or nil
    if res then
        eq(0, #(res.violations or res or {}), vim.inspect(res))
    end
end)


-- ── scheme: code and data look alike ─────────────────────────────────────────
--
-- These SKIP without a scheme parser rather than pass: a fixture that extracts
-- nothing satisfies "0 callers" trivially, and the first version of the #:export
-- test did exactly that. The keyword-VALUE protection is additionally fenced by the
-- guile gate, which reported 0 edges removed once the rule was scoped to
-- declaration forms (the blanket version removed one).

local function scheme_project(name, src)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/demo', 'p')
    local fd = assert(io.open(root .. '/demo/' .. name, 'w'))
    fd:write(src); fd:close()
    local data = ts.extract(root)
    if #(data.nodes or {}) == 0 then skip 'no scheme parser here' end
    store.ingest(data)
    return data
end

test('scheme: an #:export list in a declaration form is DATA, not a call',
    function ()
    local data = scheme_project('u.scm', table.concat({
        '(define-module (demo u)',
        '  #:export (step limit))',
        '',
        '(define limit 42)',
        '',
        '(define (step x)',
        '  (* x 2))',
    }, '\n'))
    ok(idof(data, 'step'), 'the fixture really extracted')
    eq(0, #callers_of(data, 'step'),
        'the export list must not make `step` its own caller')
end)

test('scheme: a keyword-VALUED call outside a declaration form is still a call',
    function ()
    -- the guile shape the blanket rule silently dropped:
    -- `#:on-error (repl-option-ref repl 'on-error)`
    local data = scheme_project('r.scm', table.concat({
        '(define-module (demo r))',
        '(define (opt-ref x) x)',
        '(define (run-it)',
        "  (start #:on-error (opt-ref 1)))",
    }, '\n'))
    ok(idof(data, 'opt-ref'), 'the fixture really extracted')
    eq(1, #callers_of(data, 'opt-ref'),
        'a keyword VALUE is an expression, and this one is a call')
end)
