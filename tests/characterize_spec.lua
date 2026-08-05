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
-- runtime).
--
-- AND THREE DIFFERENT KINDS OF `local function` (CART-0286), because they used to share
-- one refusal and their ceilings are opposite:
--   scale   file-level, MENTIONED by an exported fn → an UPVALUE of it, so reachable
--   row     NESTED inside M.rows → does not exist until M.rows runs, so reachable by
--           NOTHING, ever
--   helper  file-level and mentioned by nobody → dead, or reached only through a
--           module-level table this derivation deliberately does not follow
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
    -- MULTI-LINE ON PURPOSE: with the body on its own lines, a spec that embedded a COPY of
    -- the declaration is distinguishable from one that re-reads the file (CART-0289).
    'local function helper(x)',                        -- 17
    '    local doubled = x * 2',
    '    return doubled',
    'end',
    '',                                               -- 18
    'function M.viaAbsent(v)',                        -- 19
    '    return AbsentLib.transform(v)',              -- 20
    'end',                                            -- 21
    '',                                               -- 22
    -- SHARES ITS LINE with the statement that builds it, so whole-line extraction would
    -- drag `local BOXED = setmetatable({}, {` and ` })` along: the one shape that still
    -- refuses outright (CART-0289), and the real case that exposed it.
    'local BOXED = setmetatable({}, { __tostring = function () return "b" end })',
    'local function scale(x) return x * 3 end',       -- 23
    '',                                               -- 24
    'function M.scaled(v)',                           -- 25
    '    return scale(v)',                            -- 26
    'end',                                            -- 27
    '',                                               -- 28
    'function M.rows(n)',                             -- 29
    '    local function row(i) return i .. "!" end',  -- 30
    '    local out = {}',                             -- 31
    '    for i = 1, n do out[i] = row(i) end',        -- 32
    '    return table.concat(out, ",")',              -- 33
    'end',                                            -- 34
    '',                                               -- 35
    'return M',                                       -- 36
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

test('reach: a declaration sharing its line REFUSES — the wall that is really a wall',
    function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- `__tostring` lives inside `local BOXED = setmetatable({}, { … })`, so the lines it
    -- sits on are not its own. This is the one shape reconstruction cannot take, and it is
    -- the case that caught a plan/run disagreement: the whole line COMPILES (it is a valid
    -- statement) while binding something else entirely, so "it compiles" was never enough.
    local plan = assert(ch.plan(store, id_of('__tostring')))
    eq('file-local', plan.subject.kind)
    local h = holes_by_id(plan)
    ok(h['reach:__tostring'], 'the reach is a hole ROW, so it is COUNTED')
    ok(h['reach:__tostring'].why:find('shares its line with other code', 1, true),
        'and says exactly what is in the way: ' .. tostring(h['reach:__tostring'].why))
    eq(nil, h['reach:__tostring'].tier, 'no tier, so it BLOCKS')
    cleanup()
end)

test('reach: an unmentioned file-level local is RECONSTRUCTED from its own source',
    function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- Nothing exported mentions `helper`, so the upvalue walk has nothing to walk from —
    -- and that was reported as unreachable, which was a claim about the MECHANISM dressed
    -- up as a claim about the code (CART-0289).
    local plan = assert(ch.plan(store, id_of('helper')))
    eq('reconstructed', plan.subject.kind)
    local h = holes_by_id(plan)
    eq('derived', h['reach:helper'].tier, 'DERIVED: we compiled it, we did not observe it')
    eq(nil, h['reach:helper'].blocking, 'so it does not block')
    ok(h['reach:helper'].satisfied_by
        and h['reach:helper'].satisfied_by:find('RECOMPILING', 1, true),
        'and the mechanism is named: ' .. tostring(h['reach:helper'].satisfied_by))
    cleanup()
end)

test('reach: a NESTED closure is reconstructed, and the premise names its host', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('row')))
    eq('reconstructed', plan.subject.kind)
    eq('M.rows', plan.subject.host)
    local h = holes_by_id(plan)
    eq('derived', h['reach:row'].tier)
    -- THE PREMISE MUST SAY WHOSE CAPTURED STATE IS MISSING. A nested closure's free names
    -- are the enclosing function's locals, and a reconstruction supplies them itself — so
    -- "not what `M.rows` would have built" is the whole disclosure, not a flourish.
    ok(plan.subject.why:find('NOT what `M.rows` would have built', 1, true),
        'names the host whose state is NOT reproduced: ' .. tostring(plan.subject.why))
    cleanup()
end)

test('reach: a reconstruction RE-READS the file — never an embedded snapshot', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('helper')))
    ch.fill(plan, { ['input:x'] = { value = '5', basis = 'a number', by = 'agent' } })
    local src = table.concat(ch.emit(plan), '\n')
    -- THE PROPERTY THAT MATTERS MOST HERE: a spec carrying a COPY of the declaration would
    -- keep passing after the function was edited, reporting "unchanged" about source it no
    -- longer describes. So the spec must open the file, and must NOT contain the body.
    ok(src:find('io.open(path', 1, true), 'the spec opens the file at run time')
    ok(not src:find('local doubled = x * 2', 1, true),
        'and does NOT embed the declaration body, which would pass forever after an edit')
    -- anchored on the SIGNATURE, not on a line NUMBER that goes stale the moment anything
    -- above it moves — and not on the whole line, which for a one-liner is the body too
    ok(src:find('local function helper(x)', 1, true),
        'anchored on the declaration signature')
    cleanup()
end)

test('reach: editing a reconstructed body reports CHANGED, not "subject gone"', function ()
    if not ready() then skip('no lua parser') end
    local dir = proj()
    local plan = assert(ch.plan(store, id_of('helper')))
    ch.fill(plan, { ['input:x'] = { value = '5', basis = 'a number', by = 'agent' } })
    local ro = require 'cartograph.runoracle'
    ok(ro.fill_oracle(store, plan), 'oracle observed by running')
    local src = table.concat(ch.emit(plan), '\n')
    -- the spec returns nothing, so its SUCCESS is "it did not error"
    local okbefore, beforeerr = pcall(assert(load(src, 'before')))
    ok(okbefore, 'the spec passes against the current source: ' .. tostring(beforeerr))

    -- NOW EDIT THE BODY. This is the property the whole re-read design exists for: the spec
    -- must notice, and it must notice as a BEHAVIOUR CHANGE rather than by losing track of
    -- its subject. Anchoring on the signature is what makes the difference — the anchor
    -- still matches, the new body is recompiled, and the assertion fires.
    local path = dir .. '/m.lua'
    local fd = assert(io.open(path, 'r')); local text = fd:read('*a'); fd:close()
    text = text:gsub('local doubled = x %* 2', 'local doubled = x * 99')
    fd = assert(io.open(path, 'w')); fd:write(text); fd:close()

    local f = assert(load(src, 'after'))
    local okrun, err = pcall(f)
    eq(false, okrun, 'the spec FAILS after the edit')
    ok(tostring(err):find('CHANGED', 1, true),
        'and it fails as a behaviour change, not as a missing subject: ' .. tostring(err))
    cleanup()
end)

test('reach: reconstruction and the plan agree on the WRAP rule, by construction',
    function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('helper')))
    eq('none', plan.subject.wrap, 'a `local function` statement binds its own name')
    -- ONE SOURCE, TWO CONSUMERS: the plan checks the reconstruction compiles by running
    -- this rule, and the spec rebuilds the closure by running the SAME BYTES. Two
    -- hand-written copies of a three-branch rule is the parity bug this codebase has
    -- already paid for twice.
    local src = table.concat(ch.emit(plan), '\n')
    ok(src:find(ch.WRAP_SRC, 1, true), 'the spec carries WRAP_SRC verbatim')
    cleanup()
end)

test('reach: a file-level local is an UPVALUE of its caller — DERIVED, and it RUNS',
    function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('scale')))
    eq('upvalue', plan.subject.kind)
    eq('M.scaled', plan.subject.carrier)
    local h = holes_by_id(plan)
    -- DERIVED, not measured: OUR analysis says an exported fn closes over it. The
    -- runtime is the one that OBSERVES it, and that is the other channel.
    eq('derived', h['reach:scale'].tier)
    eq(nil, h['reach:scale'].blocking, 'so it does not block')
    ok(h['reach:scale'].satisfied_by
        and h['reach:scale'].satisfied_by:find('UPVALUE walk', 1, true),
        'and the mechanism is NAMED as a premise: '
        .. tostring(h['reach:scale'].satisfied_by))

    -- AND THE PREMISE IS LOUD IN THE SPEC ITSELF, because a subject reached past the
    -- public surface is one the module never promised.
    ch.fill(plan, { ['input:x'] = { value = '4', basis = 'a small number',
        by = 'agent' } })
    local src = table.concat(ch.emit(plan), '\n')
    ok(src:find('PAST the module', 1, true), 'the spec SAYS it reached past the surface')

    -- THE CLAIM IS ABOUT EXECUTION, so it is tested by executing: an unfilled oracle
    -- must still be the only thing standing between this spec and green.
    local ro = require 'cartograph.runoracle'
    local okr, why = ro.fill_oracle(store, plan)
    ok(okr, 'the RUN reaches the subject through the walk: ' .. tostring(why))
    eq(0, plan.unfilled, 'nothing left unfilled')
    local f = assert(load(table.concat(ch.emit(plan), '\n'), 'up_char'))
    local ran, err = pcall(f)
    ok(ran, 'the emitted spec PASSES against the real function object: ' .. tostring(err))
    cleanup()
end)

test('reach: the upvalue walk checks IDENTITY, not just the name', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = assert(ch.plan(store, id_of('scale')))
    local src = table.concat(ch.emit(plan), '\n')
    -- A name match would accept an impostor: `local sort = table.sort` beside a `local
    -- function sort` would hand back the wrong function and the spec would characterize
    -- something else entirely while reading as a success.
    ok(src:find('linedefined == wantline', 1, true), 'the walk compares the def LINE')
    ok(src:find('short_src', 1, true), 'and the source file')
    ok(src:find('lua/m%.lua') or src:find('m%.lua'), 'against the subject\'s own file')
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
