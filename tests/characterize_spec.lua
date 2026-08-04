-- CHARACTERIZE (CART-0262): one function → a runnable SPEC WITH HOLES.
--
-- THE TWO GATES ARE TESTED BY RUNNING THE EMITTED SPEC, not by inspecting its text.
-- That distinction is the whole point: "an unfilled hole must FAIL" is a claim about
-- EXECUTION, and a test that greps for the word HOLE would pass against a spec whose
-- holes are commented out. So these load the emitted chunk and call it.
--
-- The other thing pinned here is the FILL PROTOCOL, which is the agent's half: a fill
-- needs a BASIS, the tier records who supplied the value, and the ORACLE is never
-- fillable by prediction — a predicted expected value makes a test that passes because
-- the prediction matched the prediction, and it looks exactly like a real one.

local ch = require 'cartograph.characterize'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

-- M.add: annotated, reads a same-file const (a `derived` fixture → satisfied by the
-- module load). M.join: calls table.concat (a stdlib dependency → satisfied by the
-- runtime). helper: file-local, so a spec cannot reach it at all.
local SRC = table.concat({
    'local M = {}',                                   -- 1
    'local LIMIT = 10',                               -- 2
    '',                                               -- 3
    '--- Add and clamp.',                             -- 4
    '---@param a number',                             -- 5
    '---@param b number',                             -- 6
    'function M.add(a, b)',                           -- 7
    '    local s = a + b',                            -- 8
    '    if s > LIMIT then return LIMIT end',         -- 9
    '    return s',                                   -- 10
    'end',                                            -- 11
    '',                                               -- 12
    'function M.join(parts)',                         -- 13
    '    return table.concat(parts, ",")',            -- 14
    'end',                                            -- 15
    '',                                               -- 16
    'local function helper(x) return x * 2 end',      -- 17
    '',                                               -- 18
    'function M.viaAbsent(v)',                        -- 19
    '    return AbsentLib.transform(v)',              -- 20
    'end',                                            -- 21
    '',                                               -- 22
    'return M',                                       -- 23
}, '\n') .. '\n'

local root
local function proj(src)
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src or SRC); fd:close()
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
local function holes_by_id(plan)
    local t = {}
    for _, h in ipairs(plan.holes) do t[h.id] = h end
    return t
end
local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

test('characterize: what the ENVIRONMENT supplies is not a hole, and says which', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan, why = ch.plan(store, id_of('M.add'))
    ok(plan, 'an exported function is characterizable: ' .. tostring(why))
    local h = holes_by_id(plan)

    -- a same-file definition is answered by LOADING the module, so it is satisfied
    -- rather than held against emittability — but the mechanism is NAMED, because "no
    -- hole" and "a hole the environment fills" are different claims
    ok(h['fixture:LIMIT'], 'the const read is still a ROW')
    ok(h['fixture:LIMIT'].satisfied_by:find('loading the module', 1, true),
        'satisfied by the module load: ' .. tostring(h['fixture:LIMIT'].satisfied_by))
    ok(#plan.premises > 0, 'and it is DISCLOSED as a premise, not dropped')

    -- the annotated params are holes at CLAIM tier: a docblock declares a TYPE, never a
    -- value, and CART-0240 established that docblocks lie
    eq('claim', h['input:a'].tier)
    eq(nil, h['input:a'].value, 'a declared type does not fill the hole')

    -- and the oracle is a hole no static tier can fill
    ok(h['oracle:<return>'], 'a value-returning fn has an oracle hole')
    eq(nil, h['oracle:<return>'].tier, 'which is FRONTIER by construction')
    cleanup()
end)

test('characterize: a stdlib call is satisfied by the RUNTIME the spec runs in',
    function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('M.join')))
    local h = holes_by_id(plan)
    -- table.concat needs no injection: the spec runs in a Lua interpreter that has it.
    -- This is what CART-0266's signatures bought — the hole is not merely SIGNED, it is
    -- ANSWERED, because the environment carries the thing itself.
    ok(h['dependency:concat'], 'the absent-from-corpus callee is a row')
    ok(h['dependency:concat'].satisfied_by
        and h['dependency:concat'].satisfied_by:find('runtime', 1, true),
        'satisfied by the runtime: ' .. tostring(h['dependency:concat'].satisfied_by))

    -- while a NON-stdlib absent callee is a real hole: we cannot inject what we cannot
    -- name, and a spec that called it would die with "attempt to index nil", which
    -- reads as a broken tool rather than as the missing premise it is
    local p2 = assert(ch.plan(store, id_of('M.viaAbsent')))
    local h2 = holes_by_id(p2)
    ok(h2['dependency:transform'], 'an unknown absent callee is a row')
    eq(nil, h2['dependency:transform'].satisfied_by, 'and nothing supplies it')
    cleanup()
end)

test('characterize: a file-local function is a REACH hole, not a silent failure',
    function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('helper')))
    eq('file-local', plan.subject.kind)
    local h = holes_by_id(plan)
    ok(h['reach:helper'], 'the reach is a hole ROW, so it is COUNTED')
    ok(h['reach:helper'].why:find('file%-local'), 'with the reason')
    -- it must be counted: a spec that cannot call its subject is not a spec, and
    -- reporting "2 unfilled" for a function whose real answer is 3 understates the one
    -- hole that makes the others moot
    ok(plan.unfilled >= 3, 'and it counts toward unfilled: ' .. tostring(plan.unfilled))
    cleanup()
end)

test('GATE 1: an emitted spec with an unfilled hole ERRORS when run', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('M.add')))
    ok(plan.unfilled > 0, 'this plan has holes')
    local text = table.concat(ch.emit(plan), '\n')
    local chunk, lerr = loadstring(text, 'spec')
    ok(chunk, 'the emitted spec is valid Lua: ' .. tostring(lerr))
    -- RUN IT. This is the gate, and it cannot be checked any other way: a suite that
    -- goes green because its assertions are missing is absence-rendered-as-silence at
    -- its most dangerous, since it LOOKS like coverage.
    local okrun, err = pcall(chunk)
    eq(false, okrun, 'a spec with an unfilled hole must FAIL, never pass')
    ok(tostring(err):find('HOLE:', 1, true),
        'and the failure names it as a hole: ' .. tostring(err))
    ok(tostring(err):find('input:a', 1, true), 'by id, so it is addressable')
    cleanup()
end)

test('GATE 2: a path inside the push fence is REFUSED', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- the suite globs tests/*_spec.lua, and a characterization spec is SUPPOSED to fail
    -- when behaviour changes: landing one in the fence would block every legitimate
    -- refactor. Enforced in plan(), which every entry point passes through.
    for _, bad in ipairs({ 'tests/gen_spec.lua', 'tests/x.lua', 'elsewhere/foo_spec.lua' }) do
        local p, why = ch.plan(store, id_of('M.add'), { path = bad })
        eq(nil, p, bad .. ' must be refused')
        ok(why:find('push fence', 1, true), 'with the reason: ' .. tostring(why))
    end
    -- and the default path is outside it
    local okp = assert(ch.plan(store, id_of('M.add')))
    eq(nil, okp.path:match('^tests/'), 'the default lands outside tests/')
    ok(okp.path:find('_char%.lua$'), 'under its own suffix: ' .. okp.path)
    cleanup()
end)

test('characterize.fill: a fill needs a BASIS, and the tier records WHO', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('M.add')))

    -- NO BASIS IS A REFUSAL. A value with no stated basis is a guess wearing an
    -- answer's clothes, and once in the spec it is indistinguishable from an observed
    -- literal — which is the fabrication this whole arc exists to prevent.
    local n, err = ch.fill(plan, { ['input:a'] = { value = '3' } })
    eq(nil, n, 'a basisless fill is refused')
    ok(err:find('BASIS', 1, true), 'and says why: ' .. tostring(err))

    local n2, err2 = ch.fill(plan, { ['input:nope'] = { value = '1', basis = 'x' } })
    eq(nil, n2, 'an unknown hole id is refused')
    ok(err2:find('no hole', 1, true), tostring(err2))

    eq(1, ch.fill(plan, { ['input:a'] = { value = '3', basis = 'inside LIMIT',
        by = 'agent' } }))
    local h = holes_by_id(plan)
    eq('agent-supplied', h['input:a'].filled_tier,
        'an agent-supplied value gets its OWN tier — without it, a guess is byte-'
        .. 'identical to an observed call-site literal')
    eq('inside LIMIT', h['input:a'].basis, 'and the basis travels with it')
    cleanup()
end)

test('characterize.fill: the ORACLE is never fillable by PREDICTION', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('M.add')))
    -- A predicted expected value produces a test that passes because the prediction
    -- matched the prediction, and it is indistinguishable from a real characterization
    -- test — worse than no test at all. Two channels are legitimate: RUNNING it
    -- (CART-0263, a recorded behaviour) or a declared SPEC.
    local n, err = ch.fill(plan, { ['oracle:<return>'] = { value = '7',
        basis = 'it looks like 7', by = 'agent' } })
    eq(nil, n, 'prediction is refused')
    ok(err:find('never by prediction', 1, true), tostring(err))

    eq(1, ch.fill(plan, { ['oracle:<return>'] = { value = '7',
        basis = 'observed by running the subject', by = 'run' } }))
    eq('measured', holes_by_id(plan)['oracle:<return>'].filled_tier,
        'a RUN is measured evidence, and is labelled as such')
    cleanup()
end)

test('characterize: a FILLED spec passes, and CATCHES a behaviour change', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('M.add')))
    assert(ch.fill(plan, {
        ['input:a'] = { value = '3', basis = 'inside LIMIT', by = 'agent' },
        ['input:b'] = { value = '4', basis = 'inside LIMIT', by = 'agent' },
        ['oracle:<return>'] = { value = '7', basis = 'ran it', by = 'run' },
    }))
    eq(0, plan.unfilled, 'nothing is left open')
    local text = table.concat(ch.emit(plan), '\n')
    local okrun, err = pcall(assert(loadstring(text, 'spec')))
    ok(okrun, 'a fully filled spec passes against unchanged behaviour: ' .. tostring(err))

    -- NOW CHANGE THE SUBJECT. This is the arc's whole purpose: neutrality.lua certifies
    -- a refactor changed nothing by hashing the df shape, which is a PROXY; this is the
    -- same check with a real assertion.
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write((SRC:gsub('local s = a %+ b', 'local s = a + b + 1'))); fd:close()
    local okrun2, err2 = pcall(assert(loadstring(text, 'spec')))
    eq(false, okrun2, 'and it FAILS once the behaviour moves')
    ok(tostring(err2):find('CHANGED', 1, true),
        'naming the change, not a hole: ' .. tostring(err2))
    cleanup()
end)

test('characterize: emit is DETERMINISTIC (no timestamp, no path churn)', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('M.add')))
    eq(table.concat(ch.emit(plan), '\n'), table.concat(ch.emit(plan), '\n'),
        'two emissions of one plan are identical — a spec that changed on every run'
        .. ' would show as a diff in every review')
    cleanup()
end)

test('characterize: the write goes through TXN (journal + CAS + a load gate)', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('M.add')))
    eq(true, plan.creates[plan.path], 'a new file is declared a CREATE')
    -- STAGED, not written
    eq(0, vim.fn.filereadable(root .. '/' .. plan.path))
    local _, after = ch.preview(store, plan)
    ok(after and after[plan.path], 'the dry run carries the spec text')
    local entry, err = ch.apply(store, plan)
    ok(entry, 'the apply commits: ' .. tostring(err))
    eq(1, vim.fn.filereadable(root .. '/' .. plan.path), 'and the file exists')
    -- the emitted file is the same bytes the preview showed (one implementation)
    local fd = assert(io.open(root .. '/' .. plan.path)); local disk = fd:read('a'); fd:close()
    eq(after[plan.path], disk)
    cleanup()
end)

test('characterize: the module LOAD is a premise — derived, or a HOLE, never a crash',
    function ()
    if not ready() then skip('no lua parser') end
    -- FOUND BY DRIVING THE VERB on a real module rather than a fixture. The fixture
    -- required nothing, so `dofile` worked; every real module opens with
    -- `require 'cartograph.annot'`, and a bare dofile dies with "module not found" —
    -- which reads as a broken TOOL when the truth is a missing PREMISE.
    root = vim.fn.tempname(); vim.fn.mkdir(root .. '/pkg', 'p')
    local fd = assert(io.open(root .. '/pkg/dep.lua', 'w'))
    fd:write('local D = {}\nfunction D.two() return 2 end\nreturn D\n'); fd:close()
    fd = assert(io.open(root .. '/pkg/main.lua', 'w'))
    fd:write(table.concat({
        "local dep = require 'pkg.dep'",
        'local M = {}',
        'function M.twice(x) return x * dep.two() end',
        'return M',
    }, '\n') .. '\n'); fd:close()
    local data = ts.extract(root); data.root = data.root or root; store.ingest(data)

    local plan = assert(ch.plan(store, id_of('M.twice')))
    -- the require ALIGNS (`pkg.dep` → pkg/dep.lua), so the package root is derived and
    -- the spec supplies it. Nothing is guessed: the alignment IS the derivation.
    ok(#plan.package_path > 0, 'a package.path premise is derived')
    ok(plan.package_path[1]:find('package.path', 1, true), plan.package_path[1])
    eq(nil, holes_by_id(plan)['load:pkg/main.lua'], 'and there is no load hole')
    -- and the emitted spec must actually LOAD, which is the only test that matters here
    assert(ch.fill(plan, {
        ['input:x'] = { value = '3', basis = 'any number', by = 'agent' },
        ['oracle:<return>'] = { value = '6', basis = 'ran it', by = 'run' } }))
    local okrun, err = pcall(assert(loadstring(table.concat(ch.emit(plan), '\n'), 's')))
    ok(okrun, 'the spec loads its subject THROUGH the derived path: ' .. tostring(err))
    cleanup()

    -- NOW THE OTHER HALF: a require nothing in the graph can align to. The spec must
    -- carry a HOLE for the load, not die inside its own preamble.
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    fd = assert(io.open(root .. '/lonely.lua', 'w'))
    fd:write(table.concat({
        "local far = require 'nowhere.at.all'",
        'local M = {}',
        'function M.go(x) return far.f(x) end',
        'return M',
    }, '\n') .. '\n'); fd:close()
    local d2 = ts.extract(root); d2.root = d2.root or root; store.ingest(d2)
    local p2 = assert(ch.plan(store, id_of('M.go')))
    local h2 = holes_by_id(p2)
    ok(h2['load:lonely.lua'], 'an unalignable require is a LOAD hole')
    ok(h2['load:lonely.lua'].why:find('nowhere.at.all', 1, true),
        'naming the module it could not align: ' .. tostring(h2['load:lonely.lua'].why))
    -- and it fires BEFORE the dofile, so the reader sees the missing premise rather
    -- than Lua's message about a module it never heard of
    local text = table.concat(ch.emit(p2), '\n')
    ok(text:find('HOLE("load:', 1, true), 'the spec holds a load hole')
    local _, err2 = pcall(assert(loadstring(text, 's')))
    ok(tostring(err2):find('load:lonely%.lua'),
        'and running it reports THAT, not "module not found": ' .. tostring(err2))
    cleanup()
end)
