-- SYNTHESIZE AN INPUT FROM BODY USAGE (CART-0290).
--
-- The claim under test is not "we produce a value" — it is that the value is DERIVED from
-- what the body requires, that its TIER says who chose it, and that the spec SAYS the path
-- was our choice. A synthesized input that reads like observed evidence would be the most
-- expensive kind of wrong in this arc: it would look exactly like coverage.

local ch = require 'cartograph.characterize'
local synth = require 'cartograph.synth'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local SRC = table.concat({
    'local M = {}',
    -- one shape per parameter, so each derivation rule has a subject
    'function M.fields(p) return p.name, p.size end',   -- table with two named fields
    'function M.method(s) return s:upper() end',        -- a STRING method name
    'function M.custom(o) return o:render() end',       -- not a string method -> table
    'function M.arith(n) return n + 1 end',             -- number
    'function M.cat(s) return "x" .. s end',            -- string
    'function M.callit(f) return f() end',              -- function
    'function M.count(t) return #t end',                -- table (# answers on a real table)
    'function M.passthru(v) return v end',              -- UNCONSTRAINED: any value runs
    'function M.nested(c) return c.opts.mode end',      -- a table INSIDE a table
    -- THE CASE THAT MOTIVATED ACCESS-PATH SHAPES (CART-0297): the field, not the parameter,
    -- is what gets iterated. 143 of 196 bad-argument raises were exactly this.
    'function M.iter(p) local n = 0 for _, x in ipairs(p.items) do n = n + 1 end return n end',
    'function M.deepnum(o) return #o.list + o.count end',
    'function M.modulo(v) return v % 3 end',            -- `%` must not reach a format string
    'function M.both(x) return x.k + (x * 2) end',      -- CONFLICT: table and number
    -- TYPE GUARDS (CART-0328). These bodies never index or call the parameter — the
    -- guard is the ONLY evidence, which is exactly where `usage` used to return `any`
    -- and `basis` went on to claim nothing in the body inspects it.
    'function M.guard(g) if type(g) == "table" then return 1 end return 0 end',
    'function M.guardfn(h) if type(h) == "function" then return 1 end return 0 end',
    -- EXCLUSION, which must NOT fill: it says only what `k` is NOT
    'function M.notfn(k) if type(k) ~= "function" then return 0 end return 1 end',
    -- an UNREPRESENTABLE guard: `boolean` has no kind in M.KINDS, so it is left alone
    -- rather than approximated by a nearby representable one
    'function M.guardbool(b) if type(b) == "boolean" then return 1 end return 0 end',
    -- a plain equality: pins no shape, but the body still TESTS the parameter
    'function M.tag(t) if t == "on" then return 1 end return 0 end',
    'return M',
}, '\n') .. '\n'

local root
local function proj()
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(SRC); fd:close()
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
local function shape(fn, p)
    return assert(synth.shape_of(store, id_of(fn), p))
end

test('synth: the BODY pins the shape, and the field names come free', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local sh = shape('M.fields', 'p')
    eq('table', sh.kind)
    ok(sh.fields.name and sh.fields.size, 'both accessed fields are known')
    local v = assert(synth.value(sh, 'p'))
    -- a MINIMAL value of that shape: the fields exist, their contents are opaque because
    -- nothing in the body inspects them
    ok(v:find('name =', 1, true) and v:find('size =', 1, true), 'both fields present: ' .. v)
    ok(assert(loadstring('return ' .. v))(), 'and it is a real Lua value')
    cleanup()
end)

test('synth: every operator that constrains a parameter is read', function ()
    if not ready() then skip('no lua parser') end
    proj()
    eq('number', shape('M.arith', 'n').kind, 'p + 1 -> number')
    eq('string', shape('M.cat', 's').kind, '"x" .. p -> string')
    eq('function', shape('M.callit', 'f').kind, 'p() -> function')
    eq('table', shape('M.count', 't').kind, '#p -> table')
    -- `#p` on a REAL TABLE answers correctly, unlike on a sandbox sentinel where __len never
    -- fires under 5.1 semantics — so synthesis is strictly safer here than a proxy is.
    eq('0', synth.value(shape('M.count', 't'), 't'):gsub('%s', '') == '{}' and '0' or '?',
        '{} gives #t == 0 honestly')
    cleanup()
end)

test('synth: a method NAME decides the string/table ambiguity, and says so', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- `s:upper()` needs only "something with an upper", but `upper` is a string method, so a
    -- string is the reading. `o:render()` is not, so a table carrying a function field is —
    -- the safer side, because it cannot later satisfy a string operation by accident.
    eq('string', shape('M.method', 's').kind)
    eq('table', shape('M.custom', 'o').kind)
    local v = assert(synth.value(shape('M.custom', 'o'), 'o'))
    ok(v:find('render = function', 1, true), 'the method is stubbed: ' .. v)
    cleanup()
end)

test('synth: a nested access synthesizes a nested value', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local sh = shape('M.nested', 'c')
    eq('table', sh.kind)
    ok(sh.fields.opts, 'the outer field is known')
    local v = assert(synth.value(sh, 'c'))
    ok(assert(loadstring('return ' .. v))(), 'it loads')
    cleanup()
end)

test('synth: an UNCONSTRAINED parameter is `claim`, not `derived`', function ()
    if not ready() then skip('no lua parser') end
    proj()
    eq('any', shape('M.passthru', 'v').kind)
    local plan = assert(ch.plan(store, id_of('M.passthru')))
    local n = assert(synth.fill(store, plan))
    eq(1, n)
    for _, h in ipairs(plan.holes) do
        if h.kind == 'input' then
            -- THE WHOLE POINT OF THE TIER SPLIT: "the code told us the shape" and "we picked
            -- something harmless" are different strengths and must not share a word.
            eq('claim', h.filled_tier, 'unconstrained -> claim')
            eq('synthesized', h.by, 'and the CHANNEL records that we chose it')
            ok(h.basis:find('ANY value runs', 1, true), 'the basis admits it: ' .. h.basis)
        end
    end
    cleanup()
end)

test('synth: a shape-derived parameter is `derived`, and the basis cites the usage',
    function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('M.fields')))
    assert(synth.fill(store, plan))
    for _, h in ipairs(plan.holes) do
        if h.kind == 'input' then
            eq('derived', h.filled_tier)
            ok(h.basis:find('p.name', 1, true) or h.basis:find('p.size', 1, true),
                'the basis names the usages, so a reader can DISAGREE: ' .. h.basis)
        end
    end
    cleanup()
end)

test('synth: a parameter used as TWO types is REFUSED, never resolved', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local sh = shape('M.both', 'x')
    eq('conflict', sh.kind)
    local v, why = synth.value(sh, 'x')
    eq(nil, v, 'no value')
    ok(why and why:find('more than one type', 1, true), 'and the reason: ' .. tostring(why))
    -- and it comes back as a REFUSAL from fill, not as a silent skip
    local plan = assert(ch.plan(store, id_of('M.both')))
    local n, ref = synth.fill(store, plan)
    eq(0, n, 'nothing filled')
    eq(1, #ref, 'one refusal reported')
    eq('x', ref[1].name)
    cleanup()
end)

test('GATE: a synthesized spec RUNS, and SAYS the path was our choice', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('M.fields')))
    assert(synth.fill(store, plan))
    local ro = require 'cartograph.runoracle'
    ok(ro.fill_oracle(store, plan), 'the oracle is observed by RUNNING the real subject')
    eq(0, plan.unfilled, 'nothing left unfilled')
    local src = table.concat(ch.emit(plan), '\n')

    -- THE DISCLOSURE IS NOT OPTIONAL. A minimal value picks a path; a reader who takes this
    -- spec for "what the function does" has been misled by our SILENCE, not by a wrong
    -- value. So the warning is asserted as strictly as the run itself.
    ok(src:find('WERE SYNTHESIZED BY US', 1, true), 'the spec says we chose the inputs')
    ok(src:find('characterizes ONE', 1, true), 'and that it covers one path')
    ok(src:find('CharacterizeFork', 1, true), 'and points at the branches it did not take')

    local okrun, err = pcall(assert(load(src, 'synth')))
    ok(okrun, 'and it PASSES against the real function: ' .. tostring(err))
    cleanup()
end)

test('synth: fill never touches a hole that already has real evidence', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('M.arith')))
    ch.fill(plan, { ['input:n'] = { value = '7', basis = 'the caller passes 7',
        by = 'observed', tier = 'measured' } })
    local n = assert(synth.fill(store, plan))
    eq(0, n, 'a filled hole is left alone')
    for _, h in ipairs(plan.holes) do
        if h.kind == 'input' then
            eq('7', h.value, 'the measured value survives')
            eq('measured', h.filled_tier, 'at its own tier')
        end
    end
    cleanup()
end)

test('synth: a FIELD gets its shape from how the FIELD is used, not just the parameter',
    function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- `ipairs(p.items)` makes `items` a TABLE. Before access-path shapes, the field was
    -- created and never derived, so it was filled with the opaque string `"<synth:items>"` and
    -- iterating it raised — 143 of 196 bad-argument raises in the verified run.
    local sh = shape('M.iter', 'p')
    eq('table', sh.kind)
    ok(sh.fields.items, 'the field is known')
    eq('table', sh.fields.items.kind, 'AND its type is derived: ' .. tostring(sh.fields.items.kind))
    local v = assert(synth.value(sh, 'p'))
    ok(v:find('items = {', 1, true), 'so the value is iterable: ' .. v)
    -- the property is about RUNNING, so it is tested by running
    local f = assert(loadstring('local p = ' .. v .. '\nlocal n = 0\n'
        .. 'for _, x in ipairs(p.items) do n = n + 1 end\nreturn n'))
    eq(0, f(), 'and iterating it does not raise')
    cleanup()
end)

test('synth: sibling fields get DIFFERENT shapes from their own usage', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local sh = shape('M.deepnum', 'o')
    eq('table', sh.fields.list.kind, '#o.list -> table')
    eq('number', sh.fields.count.kind, 'o.count + x -> number')
    local v = assert(synth.value(sh, 'o'))
    ok(v:find('count = 0', 1, true) and v:find('list = {', 1, true), v)
    cleanup()
end)

test('synth: the modulo operator does not reach a format string', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- `'%s ' .. op .. ' x'` with op='%' makes format read `% ` as a conversion spec and
    -- crashes mid-sweep. The operator is DATA, and this pins that it stays data.
    local sh = shape('M.modulo', 'v')
    eq('number', sh.kind)
    ok(#sh.why > 0 and sh.why[1]:find('%%'), 'the note survives: ' .. tostring(sh.why[1]))
    cleanup()
end)

test('synth: a type() guard NAMES the shape, and only `==` may fill from one', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- `==` is membership: the body says what `g` IS, so a value of that shape runs the
    -- guarded path rather than the fallthrough an arbitrary sentinel would take.
    local g = shape('M.guard', 'g')
    eq('table', g.kind, 'type(g) == "table"')
    eq('{ }', assert(synth.value(g, 'g')))
    eq('function', shape('M.guardfn', 'h').kind, 'type(h) == "function"')

    -- ★ EXCLUSION MUST NOT FILL. `type(k) ~= "function"` says only what k is NOT. The
    -- reading that makes it a function needs GUARD DOMINANCE (the early exit means the
    -- rest runs only when it IS one), which narrow.lua computes and this walker cannot
    -- see. Filling here would be a guess wearing evidence's clothes.
    eq('any', shape('M.notfn', 'k').kind, '~= is exclusion, not membership')

    -- an unrepresentable type is left alone, never approximated
    eq('any', shape('M.guardbool', 'b').kind, 'boolean has no kind in M.KINDS')
    cleanup()
end)

test('synth: basis may not claim non-inspection it did not check', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- THE DEFECT (CART-0328): every `any` shape used to open "nothing in the body
    -- inspects `p`" — a statement about the WHOLE body, from a walker that only looked
    -- for SHAPE requirements. Measured false for 70 of 1092 sentinel fills.
    for _, c in ipairs({ { 'M.tag', 't' }, { 'M.notfn', 'k' }, { 'M.guardbool', 'b' } }) do
        local sh = shape(c[1], c[2])
        eq('any', sh.kind, c[1] .. ': no shape follows from a test')
        ok(sh.inspected, c[1] .. ': the body TESTS ' .. c[2])
        local b = synth.basis(sh, c[2])
        ok(not b:find('nothing in the body inspects', 1, true),
            c[1] .. ': must not claim non-inspection — ' .. b)
        ok(b:find('TESTS it', 1, true), c[1] .. ': must say the choice picks a path — ' .. b)
    end

    -- and the genuinely uninspected case keeps the strong sentence, or the fix would
    -- have cost the signal instead of correcting it
    local pv = shape('M.passthru', 'v')
    eq('any', pv.kind)
    ok(not pv.inspected, 'passthru never tests v')
    ok(synth.basis(pv, 'v'):find('nothing in the body inspects', 1, true))
    cleanup()
end)
