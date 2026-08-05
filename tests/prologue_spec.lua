-- RE-EMIT A RECONSTRUCTION'S PROLOGUE BINDINGS (CART-0296).
--
-- The claim is not "the hole gets a value" — it is that the value is the FILE'S OWN SOURCE,
-- that a declaration which would PERFORM something is refused, and that the spec runs. A
-- re-emitted declaration is the one supply mechanism here that involves no choice at all,
-- which is why it happens automatically; that makes getting the refusal line right the whole
-- of its safety.

local ch = require 'cartograph.characterize'
local prologue = require 'cartograph.prologue'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

-- A SCRIPT: no `return M`, so nothing can be walked from a module table and every subject is
-- reconstructed. That is the population this exists for (measured: 420 of 560 such holes).
local SRC = table.concat({
    "local LIMIT = 10",                                  -- a literal
    "local NAMES = { a = 1, b = 2 }",                    -- a table
    "local WIDE = {",                                    -- a MULTI-LINE table
    "    x = 1,",
    "    y = 2,",
    "}",
    -- NO `require` IN THE FIXTURE ITSELF: `load_premise` scans the whole file for
    -- module-level requires, so one this graph cannot align would raise a LOAD hole on every
    -- subject in the file — correct behaviour, and it would drown the property under test.
    -- The require case is covered as a unit below.
    "local DANGER = os.time()",                          -- a CALL: must be REFUSED
    "local function double(n) return n * 2 end",          -- a DECLARATION
    "",
    "local function clamp(v)",
    "    if v > LIMIT then return LIMIT end",
    "    return v",
    "end",
    "",
    "local function widen(k)",
    "    return NAMES[k], WIDE.x",
    "end",
    "",
    "local function twice(n) return double(n) end",
    "",
    "local function risky(n) return n + DANGER end",
    "",
    "print(clamp(1), widen('a'), twice(2), risky(1))",
}, '\n') .. '\n'

local root
local function proj()
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/s.lua', 'w')); fd:write(SRC); fd:close()
    local data = ts.extract(root)
    data.root = data.root or root
    store.ingest(data)
    return root
end
local function cleanup() if root then vim.fn.delete(root, 'rf'); root = nil end end
local function id_of(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end
local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end
local function fixture(plan, name)
    for _, h in ipairs(plan.holes) do
        if h.kind == 'fixture' and h.name == name then return h end
    end
end

test('prologue: a same-file LITERAL is supplied from its own declaration', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('clamp')))
    eq('reconstructed', plan.subject.kind, 'a script local is reconstructed')
    local h = assert(fixture(plan, 'LIMIT'), 'LIMIT is a fixture hole')
    -- AUTOMATIC, unlike every other value-supplying step here: re-emitting the file's own
    -- declaration involves no choice, so it is not behind a command.
    ok(h.decl and h.decl:find('local LIMIT = 10', 1, true),
        'the declaration itself is carried: ' .. tostring(h.decl))
    eq('literal', h.decl_kind)
    eq('derived', h.filled_tier, 'we re-derived the binding; we did not observe it')
    cleanup()
end)

test('prologue: a MULTI-LINE table is grown until it compiles', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('widen')))
    local h = assert(fixture(plan, 'WIDE'))
    -- counting braces here would be a parser, and a bad one; compiling is the test
    ok(h.decl and h.decl:find('y = 2', 1, true),
        'the whole constructor, not its first line: ' .. tostring(h.decl))
    eq('table', h.decl_kind)
    cleanup()
end)

test('prologue: a REQUIRE is re-emitted as a require, not stubbed', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('widen')))
    local text = prologue.classify("local at = require 'cartograph.at'")
    eq('require', text, 'a bare require is safe to re-emit')
    -- the spec already carries the aligned package.path as a derived premise, so the real
    -- module loads — a stub would be a hypothesis where a real value is available
    eq(nil, (prologue.classify('local db = connect()')),
        'but a call is NOT safe')
    cleanup()
end)

test('prologue: a declaration that would PERFORM something is REFUSED by name', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- `local DANGER = os.time()` — re-emitting it would CALL os.time at spec load. This is
    -- the whole safety line of an automatic mechanism, so it is asserted, not assumed.
    local plan = assert(ch.plan(store, id_of('risky')))
    local h = assert(fixture(plan, 'DANGER'))
    eq(nil, h.decl, 'not supplied')
    local kind, why = prologue.classify('local DANGER = os.time()')
    eq(nil, kind)
    ok(why and why:find('PERFORM', 1, true), 'and it says why: ' .. tostring(why))
    cleanup()
end)

test('prologue: a same-file FUNCTION is supplied as its declaration', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('twice')))
    local h = assert(fixture(plan, 'double'))
    eq('function', h.decl_kind)
    -- THE REASON RE-EMISSION BEATS EVALUATION: a function value has no literal form, so a
    -- serializer could never supply this one. Source can.
    ok(h.decl:find('function double', 1, true), 'the declaration: ' .. tostring(h.decl))
    cleanup()
end)

test('GATE: the supplied spec RUNS, and the premise names the source', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('clamp')))
    ch.fill(plan, { ['input:v'] = { value = '3', basis = 'a small number', by = 'agent' } })
    local ro = require 'cartograph.runoracle'
    local okr, why = ro.fill_oracle(store, plan)
    ok(okr, 'the run no longer refuses on a valueless fixture: ' .. tostring(why))
    local src = table.concat(ch.emit(plan), '\n')
    ok(src:find('local LIMIT = 10', 1, true), 'the declaration is in the spec')
    ok(src:find('same source', 1, true) or src:find('re%-emitted'),
        'and the premise says where it came from')
    local ran, err = pcall(assert(load(src, 'p')))
    ok(ran, 'and the spec PASSES: ' .. tostring(err))
    cleanup()
end)
