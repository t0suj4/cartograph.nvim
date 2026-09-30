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
