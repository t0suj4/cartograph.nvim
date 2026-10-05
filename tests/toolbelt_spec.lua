-- THE TOOLBELT (CART-1152 follow-on): every tactic in lua/cartograph/tactics/ is discovered — no central list — and
-- every one of its EXAMPLES runs here. An example is the entry's usage documentation, so running it is what keeps the
-- documentation true: a tactic whose example stops working fails this spec by name. TOTAL BY CONSTRUCTION: a new
-- file in tactics/ is picked up with nothing to register.
local tb = require 'cartograph.toolbelt'

local function ready()
    return pcall(vim.treesitter.get_string_parser, '', 'lua') and require('cartograph.algebra').available()
end

test('toolbelt: every entry loads, and every example of every entry holds', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local entries, broken = tb.list()
    eq({}, broken, 'no entry is malformed')
    ok(#entries >= 4, 'the toolbelt is discovered from its directory, not an empty glob: ' .. #entries)
    local kinds, bad, n, skipped = {}, {}, 0, {}
    for _, e in ipairs(entries) do
        kinds[e.kind] = true
        for _, ex in ipairs(e.examples) do
            n = n + 1
            local okx, why, res = tb.example(e, ex)
            if not okx then bad[#bad + 1] = ('%s — %s: %s'):format(e.name, ex.name, tostring(why))
            elseif res and res.skipped then skipped[#skipped + 1] = ('%s — %s: %s'):format(e.name, ex.name, res.skipped) end
        end
    end
    ok(kinds.write and kinds.discovery, 'both kinds are present')
    io.write(('  [toolbelt] %d entries, %d examples, %d skipped%s\n'):format(#entries, n, #skipped, #skipped > 0 and (' (' .. table.concat(skipped, '; ') .. ')') or ''))
    eq({}, bad, 'each example is the usage AND the test')
end)

test('toolbelt THROWAWAY: an entry from a source anywhere — no file, no examples, no params declared, no claim — runs by the same machinery', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local d = tb.throwaway('return { measure = function (store, p) return { x = p.x } end }', 'probe')
    eq({ 'discovery', 'throwaway:probe', true }, { d.kind, d.name, d.throwaway })
    local okd, why, res = tb.example(d, { name = 'value', files = { ['a.lua'] = 'return 1\n' }, params = { x = 'anything' },
        expect = { check = function (v) return v.x == 'anything', vim.inspect(v) end } })
    ok(okd, tostring(why))
    eq(nil, res.holds, 'no claim: the value alone')
    local c = tb.throwaway('return { measure = function () return 3 end, claim = function (v) return v > 2, "three" end }', 'c')
    local okc, cwhy, cres = tb.example(c, { name = 'claim', files = { ['a.lua'] = 'return 1\n' }, expect = { holds = true } })
    ok(okc, tostring(cwhy))
    eq('three', cres.why)
    -- a WRITE throwaway goes through tactic.run: the edit verb, the journal, a real write under apply
    local w = tb.throwaway([[
        local T = require('cartograph.tactic').T
        return { build = function (p) return T.step('edit', { file = 'm.lua', before = 'M.x = 1', after = 'M.x = ' .. p.v }) end }
    ]], 'w')
    local okw, wwhy = tb.example(w, { name = 'write', files = { ['m.lua'] = 'local M = {}\nM.x = 1\nreturn M\n' }, params = { v = '7' },
        expect = { status = 'done', applied = 1, check = function (root)
            local s = io.open(root .. '/m.lua'):read('a'); return s:find('M.x = 7', 1, true) ~= nil, s end } })
    ok(okw, tostring(wwhy))
    -- declaring params is still honoured; a source that is no entry is refused by name
    local p = tb.throwaway('return { params = { x = "string" }, measure = function (s, q) return q.x end }', 'p')
    local okp, pwhy = tb.example(p, { name = 'undeclared', files = { ['a.lua'] = 'return 1\n' }, params = { y = '1' }, expect = {} })
    ok(not okp and tostring(pwhy):find('takes no param `y`', 1, true), tostring(pwhy))
    local _, bwhy = tb.throwaway('return { 1 }', 'bad')
    ok(tostring(bwhy):find('build(params)', 1, true), tostring(bwhy))
end)

test('toolbelt: a malformed entry is refused BY NAME, and a failing example is reported, not passed', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local d = vim.fn.tempname(); vim.fn.mkdir(d, 'p')
    local function put(name, text) local fd = assert(io.open(d .. '/' .. name .. '.lua', 'w')); fd:write(text); fd:close() end
    put('no-examples', "return { name = 'no-examples', kind = 'discovery', summary = 's', examples = {}, measure = function () return 1 end, claim = function () return true end }")
    put('misnamed', "return { name = 'other', kind = 'write', summary = 's', examples = { {} }, build = function () end }")
    put('wrong', [[return { name = 'wrong', kind = 'discovery', summary = 's', examples = { { name = 'claims too much', expect = { holds = true } } },
        measure = function () return 0 end, claim = function (v) return v > 0, 'v = ' .. v end }]])
    local entries, broken = tb.list(d)
    ok(broken['no-examples'] and broken['no-examples']:find('at least one example', 1, true), tostring(broken['no-examples']))
    ok(broken.misnamed and broken.misnamed:find('named by its FILE', 1, true), tostring(broken.misnamed))
    eq(1, #entries)
    local okx, why = tb.example(entries[1], entries[1].examples[1])
    eq(false, okx, 'an example whose expectation is false FAILS')
    ok(tostring(why):find('expected the claim to hold', 1, true), tostring(why))
end)

-- ── the shared fixture: a near-clone family of three ─────────────────────────────────────────────────────────────
local store = require 'cartograph.store'
local tactic = require 'cartograph.tactic'
local function member(n, mul, tail)
    return ('function M.g%d(t)\n    local acc = 0\n    local seen = {}\n    for i = 1, #t do acc = acc + t[i] * %d end\n'
        .. '    local s = tostring(acc)\n    local u = string.upper(s)\n    seen[u] = true\n    local pad = string.rep("-", #u)\n'
        .. '    local out = pad .. u\n    return out .. "%s"\nend\n'):format(n, mul, tail)
end
local FAMILY = 'local M = {}\n' .. member(1, 1, 1) .. member(2, 2, 2) .. member(3, 3, 3) .. 'return M\n'
local root
local function project(files)
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, text in pairs(files) do local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close() end
    store.ingest(require('cartograph.providers.treesitter').extract(root))
end
local function disk() local fd = assert(io.open(root .. '/fe.lua')); local s = fd:read('a'); fd:close(); return s end

test('toolbelt: params are COERCED by their declaration — a ref from file::name, text from @path, and a miss says did-you-mean', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { ['fe.lua'] = FAMILY }
    local e = assert(tb.load('align-family'))
    local tf = vim.fn.tempname(); vim.fn.writefile(vim.split(member(1, 9, 1), '\n', { plain = true }), tf)
    local p, why = tb.coerce(store, e, { ref = 'fe.lua::M.g1', text = '@' .. tf, scope = 'all' })
    ok(p, tostring(why))
    eq('M.g1', p.ref.name, 'the ref resolved from file::name'); ok(p.text:find('* 9', 1, true), 'the text read from @path')
    -- the file's bytes EXACTLY: writefile ends the file with a newline, and it survives (stripping it made every file
    -- created through the edit verb lose its final newline)
    local exact = vim.fn.tempname()
    local wf = assert(io.open(exact, 'wb')); wf:write('return 1\n'); wf:close()
    eq('return 1\n', (tb.coerce(store, e, { ref = 'fe.lua::M.g1', text = '@' .. exact })).text,
        'the final newline of the @path file is kept, byte for byte')
    local _, miss = tb.coerce(store, e, { ref = 'fe.lua::M.g4', text = 'x' })
    ok(miss and miss:find('did you mean', 1, true) and miss:find('M.g1', 1, true), tostring(miss))
    local _, extra, cls = tb.coerce(store, e, { ref = 'fe.lua::M.g1', text = 'x', colour = 'red' })
    eq('ill-posed', cls); ok(extra:find('takes no param `colour`', 1, true), extra)
    local _, need = tb.coerce(store, e, { text = 'x' })
    ok(need and need:find('needs param `ref`', 1, true), tostring(need))
    local fp = assert(tb.load('family-premise'))
    eq({ 'a.lua', 'b.lua' }, (tb.coerce(store, fp, { files = 'a.lua,b.lua' })).files, 'a list from a,b')
    -- a TERM param (CART-1342) is a table with `k` or `body`; a string is refused by name
    local cf = assert(tb.load('checked-fill'))
    local A = require('cartograph.algebra').load()
    local T = A.template(A.node('f', A.hole('a')))
    ok((tb.coerce(store, cf, { template = T, hole = 'a', value = A.lit(1) })), 'a template and a term pass')
    local _, notterm = tb.coerce(store, cf, { template = 'f(?a)', hole = 'a', value = A.lit(1) })
    ok(notterm and notterm:find('must be an algebra term', 1, true), tostring(notterm))
    -- a param of a type the list does not name is refused by name — it used to pass the value through unchecked
    local odd = { name = 'odd', params = { n = 'number' } }
    local _, unknown, ucls = tb.coerce(store, odd, { n = 3 })
    eq('ill-posed', ucls); ok(unknown and unknown:find('unknown type `number`', 1, true), tostring(unknown))
end)

test('toolbelt: T.use composes a NAMED tactic — a discovery gates the step after it, and a failed premise stops by name', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { ['fe.lua'] = FAMILY }
    local T = tactic.T
    local text = member(1, 9, 1):gsub('\n$', '')
    local term = T.seq(T.use('family-premise', { files = { 'fe.lua' } }),
        T.use('align-family', { ref = 'fe.lua::M.g1', text = text, scope = 'all' }))
    local r = tactic.run(store, term, { apply = true })
    eq('done', r.status, tostring(r.why)); eq(1, r.applied)
    ok(disk():find('* 9', 1, true), 'the used write tactic wrote')
    local premise
    for _, h in ipairs(r.residue) do if h.kind == 'premise' then premise = h end end
    ok(premise and premise.text:find('family-premise', 1, true), 'the gate left its reason as residue')
    -- a premise that FAILS: no family in a file set that has none
    project { ['fe.lua'] = FAMILY, ['x.lua'] = 'local X = {}\nfunction X.f(a) return a end\nreturn X\n' }
    local before = disk()
    local g = tactic.run(store, T.seq(T.use('family-premise', { files = { 'x.lua' } }),
        T.use('align-family', { ref = 'fe.lua::M.g1', text = text, scope = 'all' })), { apply = true })
    eq('failed', g.status); eq('ill-posed', g.class); ok(g.why:find('does not hold', 1, true), g.why)
    eq(before, disk(), 'the step after a failed premise never ran')
end)

test('toolbelt: T.bind hands a discovery\'s VALUE to the next term — measured, then rewritten from the measurement (CART-1444)', function ()
    if not ready() then skip 'no lua parser or algebra' end
    local SRC = 'local M = {}\nM.runs = 0\nfunction M.slow(t) M.runs = M.runs + 1 return #t end\nfunction M.work(xs) local s = 0 for _, x in ipairs(xs) do s = s + M.slow(x) end return s end\nreturn M\n'
    project { ['bindm.lua'] = SRC }
    local function disk() local fd = assert(io.open(root .. '/bindm.lua')); local s = fd:read('a'); fd:close(); return s end
    local T = tactic.T
    -- (the module is loaded by the WRAPPER, from the graph's root: a fresh copy per project, never one left from before)
    package.loaded.bindm = nil
    local WORK = 'return function () local m = require "bindm"; local t = { 1, 2 }; local xs = {}; for i = 1, 50 do xs[i] = t end; m.work(xs) end'
    local seen
    local term = T.bind('memo-advisor', { targets = 'bindm.slow', workload = WORK }, function (v)
        seen = v.rows[1]
        return T.use('memoize', { ref = 'bindm.lua::M.slow', residence = v.rows[1].keys == 'identity' and 'weak' or 'strong' })
    end)
    local r = tactic.run(store, term, { apply = true })
    package.loaded.bindm = nil
    eq('done', r.status, tostring(r.why)); eq(1, r.applied)
    eq(50, seen.calls); eq('identity', seen.keys)
    ok(disk():find("__mode = 'k'", 1, true), 'the residence came from the measured key kind')
    -- a body that leaves the choice open STOPS as a decision; a claim that fails never reaches the body
    project { ['bindm.lua'] = SRC }
    local d = tactic.run(store, T.bind('memo-advisor', { targets = 'bindm.slow', workload = WORK }, function ()
        return nil, 'which residence?', 'decision' end), { apply = true })
    package.loaded.bindm = nil
    eq('stopped', d.status, tostring(d.why)); eq('decision', d.class)
    local reached = false
    local f = tactic.run(store, T.bind('memo-advisor', { targets = 'bindm.slow', workload = 'return function () end' }, function ()
        reached = true; return T.use('memoize', { ref = 'bindm.lua::M.slow', residence = 'weak' }) end), { apply = true })
    eq('failed', f.status); ok(not reached, 'the body ran after a failed claim'); eq(SRC, disk())
    local w = tactic.run(store, T.bind('memoize', { ref = 'bindm.lua::M.slow' }, function () return T.seq() end), { apply = true })
    eq('ill-posed', w.class); ok(w.why:find('needs a DISCOVERY', 1, true), w.why)
end)

test('toolbelt: a cycle of uses refuses by name, and an unknown entry or a bad param fails at its own step', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { ['fe.lua'] = FAMILY }
    local d = vim.fn.tempname(); vim.fn.mkdir(d, 'p')
    local fd = assert(io.open(d .. '/loop.lua', 'w'))
    fd:write("local T = require('cartograph.tactic').T\nreturn { name = 'loop', kind = 'write', summary = 's', params = {}, "
        .. "examples = { { name = 'x' } }, build = function () return T.use('loop') end }\n"); fd:close()
    local c = tactic.run(store, tactic.T.use('loop'), { apply = true, toolbelt_dir = d })
    eq('failed', c.status); ok(c.why:find('uses itself', 1, true), c.why)
    local u = tactic.run(store, tactic.T.use('no-such-tactic'), { apply = true })
    eq('ill-posed', u.class); ok(u.why:find('no tactic', 1, true), u.why)
    local b = tactic.run(store, tactic.T.use('align-family', { ref = 'fe.lua::M.g9', text = 'x' }), { apply = true })
    eq('ill-posed', b.class); ok(b.why:find('did you mean', 1, true), b.why)
end)

test('toolbelt: over MCP — the catalogue lists every entry; a discovery re-measures; a write PREVIEWS, and apply needs a writable host', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { ['fe.lua'] = FAMILY }
    local agent = require 'cartograph.agent'
    agent.set_writable(false)
    local l = agent.answer(store, 'toolbelt_list', {})
    local names = {}
    for _, r in ipairs(l.result) do names[r.name] = r end
    ok(names['align-family'] and names['witness-shape-collision'], 'listed from the directory')
    ok(#names['align-family'].examples >= 2, 'each row carries its examples: the usage')
    local d = agent.answer(store, 'toolbelt_run', { name = 'family-premise', params = { files = { 'fe.lua' } } })
    eq(true, d.result[1].holds, vim.inspect(d.result))
    local text = member(1, 9, 1):gsub('\n$', '')
    local pv = agent.answer(store, 'toolbelt_run', { name = 'align-family', params = { ref = 'fe.lua::M.g1', text = text, scope = 'all' } })
    eq('previewed', pv.result[1].status, vim.inspect(pv.result)); eq(FAMILY, disk(), 'a preview writes nothing')
    -- the preview is the WHOLE tactic's effect, as a diff per file (CART-1160 step 3)
    eq(1, pv.result[1].worlds); eq('fe.lua', pv.result[1].preview[1] and pv.result[1].preview[1].file)
    local _, nines = pv.result[1].preview[1].diff:gsub('%+[^\n]*%* 9', '')
    eq(3, nines, 'every member\'s new line is in the diff')
    local ro = agent.answer(store, 'toolbelt_run', { name = 'align-family', apply = true, params = { ref = 'fe.lua::M.g1', text = text, scope = 'all' } })
    eq('read-only-host', ro.refusal and ro.refusal.rule)
    agent.set_writable(true)
    local w = agent.answer(store, 'toolbelt_run', { name = 'align-family', apply = true, params = { ref = 'fe.lua::M.g1', text = text, scope = 'all' } })
    agent.set_writable(false)
    eq('done', w.result[1].status, vim.inspect(w.result)); ok(disk():find('* 9', 1, true))
end)

test('toolbelt: running an example from a LIVE session leaves that session\'s graph exactly as it was (CART-1160)', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project { ['fe.lua'] = '\n\n\n' .. FAMILY }
    local at = require 'cartograph.at'
    local function g1_line() for _, n in ipairs(store.data.nodes) do if n.name == 'M.g1' then return at.sl(n.range) end end end
    local before_root, before_gen, before_line = store.data.root, store.generation, g1_line()
    local e = assert(tb.load('witness-shape-collision'))
    ok((tb.example(e, e.examples[1])), 'the example ran')
    eq(before_root, store.data.root); eq(before_gen, store.generation)
    eq(before_line, g1_line(), 'a folded range still reads through the caller\'s own columns')
end)

-- ── LOOKUP: a tactic is a binder in the `tactics` scope (CART-1446, under CART-1447) ─────────────────────────────────
local function tactic_src(name, extra)
    return ([[
return {
    name = %q, kind = 'discovery', summary = 'a probe', params = {},%s
    measure = function () return 1 end,
    claim = function () return true, 'one' end,
    examples = { { name = 'runs', files = { ['a.lua'] = 'return 1\n' }, expect = { holds = true } } },
}
]]):format(name, extra or '')
end
local function put_tactic(name, text)
    vim.fn.mkdir(root .. '/.cartograph/tactics', 'p')
    local fd = assert(io.open(root .. '/.cartograph/tactics/' .. name .. '.lua', 'w')); fd:write(text); fd:close()
end

test('toolbelt LOOKUP: a name resolves to its binding and the CHAIN of what it shadows — a project tactic named like a built-in is shown shadowed-undecided, not hidden', function ()
    project { ['m.lua'] = 'local M = {}\nreturn M\n' }
    local rows = tb.find('spec-fails', { root = root })
    eq(1, #rows); eq(1, #rows[1].chain); ok(rows[1].chain[1].chosen and rows[1].chain[1].scope == 'built-in', vim.inspect(rows[1].chain))
    put_tactic('spec-fails', tactic_src('spec-fails'))
    local again = tb.find('spec-fails', { root = root })
    eq(1, #again); ok(again[1].broken, 'the name is undecided: ' .. vim.inspect(again[1]))
    eq(2, #again[1].chain, 'both bindings are in the chain')
    local project_b = again[1].chain[2]
    eq('project', project_b.scope); ok(project_b.why:find('shadowed, undecided', 1, true), project_b.why)
end)

test('toolbelt LOOKUP: the USER mount sits between the built-in and the project — its own tactic runs everywhere, its copy of a built-in is a decision (CART-1448)', function ()
    project { ['m.lua'] = 'local M = {}\nreturn M\n' }
    local saved = tb.user_dir
    local ud = vim.fn.tempname(); vim.fn.mkdir(ud, 'p')
    tb.user_dir = function () return ud end
    local okp, err = pcall(function ()
        local fd = assert(io.open(ud .. '/mine.lua', 'w')); fd:write(tactic_src('mine')); fd:close()
        local e = assert(tb.load('mine', nil, root))
        eq('user', e.scope)
        local rows = tb.find('mine', { root = root })
        eq('user', rows[1].chain[1].scope)
        -- a USER copy of a built-in that differs: undecided, both in the chain (built-in first, user after)
        fd = assert(io.open(ud .. '/spec-fails.lua', 'w')); fd:write(tactic_src('spec-fails')); fd:close()
        local sf = tb.find('spec-fails', { root = root })
        ok(sf[1].broken, vim.inspect(sf[1]))
        eq('built-in', sf[1].chain[1].scope); eq('user', sf[1].chain[2].scope)
        -- and a PROJECT copy of the user's tactic is shadowed by it the same way
        put_tactic('mine', tactic_src('mine', "\n    tags = { 'zz' },"))
        local m2 = tb.find('mine', { root = root })
        eq('user', m2[1].chain[1].scope); eq('project', m2[1].chain[2].scope)
    end)
    tb.user_dir = saved
    if not okp then error(err, 0) end
end)

test('toolbelt LOOKUP: T.use of a TAG resolves at the subject — one applicable runs, several are a decision, none is refused with the reasons (CART-1448)', function ()
    project { ['m.lua'] = 'local M = {}\nreturn M\n' }
    local d = vim.fn.tempname(); vim.fn.mkdir(d, 'p')
    local function put(name, extra) local fd = assert(io.open(d .. '/' .. name .. '.lua', 'w')); fd:write(tactic_src(name, extra)); fd:close() end
    put('here', "\n    tags = { 'zz' },")
    put('elsewhere', "\n    tags = { 'zz' },\n    applies = function () return false, 'not a C tree' end,")
    local T = tactic.T
    local one = tactic.run(store, T.use({ tag = 'zz' }), { apply = true, toolbelt_dir = d })
    eq('done', one.status, tostring(one.why))
    local premise
    for _, h in ipairs(one.residue) do if h.kind == 'premise' then premise = h.text end end
    ok(premise and premise:find('`here`', 1, true), 'the applicable one ran: ' .. tostring(premise))
    put('also', "\n    tags = { 'zz' },")
    local two = tactic.run(store, T.use({ tag = 'zz' }), { apply = true, toolbelt_dir = d })
    eq('stopped', two.status); eq('decision', two.class); ok(two.why:find('also, here', 1, true), two.why)
    local none = tactic.run(store, T.use({ tag = 'qq' }), { apply = true, toolbelt_dir = d })
    eq('ill-posed', none.class); ok(none.why:find('no tactic tagged `qq`', 1, true), none.why)
    local why_not = tactic.run(store, T.use({ tag = 'zz', kind = 'write' }), { apply = true, toolbelt_dir = d })
    ok(why_not.why:find('elsewhere (not a C tree)', 1, true), why_not.why)
end)

test('toolbelt LOOKUP: tags — DECLARED on the entry, DERIVED (act = a write), and added by a SCOPE in the user\'s config, each with its source; at another subject the scope\'s tags do not reach', function ()
    project { ['m.lua'] = 'local M = {}\nreturn M\n' }
    local config = require 'cartograph.config'
    local saved = config.scoped
    local okp, err = pcall(function ()
        local function tags(name, at)
            local r = tb.find(name, { root = root, at = at })[1]
            local out = {}
            for _, t in ipairs(r.tags) do out[t.tag] = t.source end
            return out, r
        end
        eq('declared', tags('spec-fails').accept)
        eq('derived', tags('edit').act, 'a write is `act` without saying so')
        config.scoped = { [root] = { tactic_tags = { ['spec-fails'] = { 'release-gate' } } } }
        local t, r = tags('spec-fails', root)
        eq('scope', t['release-gate'])
        local src
        for _, x in ipairs(r.tags) do if x.tag == 'release-gate' then src = x end end
        ok(src and src.scope, 'the deciding scope is named: ' .. vim.inspect(src))
        local by_tag = tb.find({ tag = 'release-gate' }, { root = root, at = root })
        eq(1, #by_tag); eq('spec-fails', by_tag[1].name)
        eq(0, #tb.find({ tag = 'release-gate' }, { root = root, at = '/somewhere/else' }), 'another subject: the scope does not hold there')
    end)
    config.scoped = saved
    ok(okp, tostring(err))
end)

test('toolbelt LOOKUP: a malformed tag is refused BY NAME; an entry that does not apply at a subject is RETURNED, marked, with its reason; a tag only one entry carries is flagged as a likely misspelling', function ()
    project { ['m.lua'] = 'local M = {}\nreturn M\n' }
    put_tactic('bad-tag', tactic_src('bad-tag', "\n    tags = { 'Release Gate' },"))
    local _, broken = tb.list(nil, root)
    ok(broken['bad-tag'] and broken['bad-tag']:find('not a lowercase word', 1, true), tostring(broken['bad-tag']))
    os.remove(root .. '/.cartograph/tactics/bad-tag.lua')
    put_tactic('c-only', tactic_src('c-only', "\n    tags = { 'optimise' },\n    applies = function (at) return at:match('%.c$') ~= nil, 'C sources only' end,"))
    local rows = tb.find('c-only', { root = root, at = root .. '/m.lua' })
    eq(1, #rows); eq(false, rows[1].applicable); eq('C sources only', rows[1].why_not)
    eq(true, tb.find('c-only', { root = root, at = root .. '/x.c' })[1].applicable)
    local counts, singles = tb.tag_census(nil, root)
    eq(1, counts.optimise); ok(vim.tbl_contains(singles, 'optimise'), 'singletons: ' .. table.concat(singles, ','))
    ok(not vim.tbl_contains(singles, 'optimize'), 'a tag two entries carry is not flagged')
end)
