-- THE CLOSURE IN THE EXPRESSION IR: opaque allocation, or descended subtree?
--
-- ★★★ ONE TABLE USED TO ANSWER TWO QUESTIONS (CART-0928). `ALLOCFN` was ORed in
-- FRONT of the language-owned stop set, so it decided BOTH "is this a walk
-- boundary" and "is this an allocation" — and a language could not withdraw any of
-- its five names. Now the boundary is the language's (`flow_stop` + attached
-- blocks) and ALLOCFN answers only the value question.
--
-- ⚠ THE TWO SETS COINCIDE ON EVERY SHIPPED SPEC, so the "allocation but NOT a
-- boundary" branch is unreachable in production and these tests are the only thing
-- that exercises it. That is a reason to pin it harder, not softer: the consumer
-- half was a SILENT NO-OP when first written — `children`/`expr_reads` had no `fn`
-- case, so a descended closure carried `kids` that nothing walked, and every read
-- inside it vanished with the suite green.

local expr = require 'cartograph.expr'
local ts   = require 'cartograph.providers.treesitter'

local function has_parser(lang)
    return pcall(vim.treesitter.get_string_parser, '', lang)
end

--- ★ THE BOUNDARY PATH, which is every closure on every language today. `{k='fn'}`
--- carries NO kids and is a LEAF to every walk — the alignment `expr.gate` is built
--- on, since du does not descend a closure either.
test('expr fn: a lua closure is an OPAQUE allocation, and its names stay inside',
    function ()
        if not has_parser('lua') then skip 'no lua parser' end
        local eo = expr.of_text(
            'local function outer(a)\n' ..
            '    local cb = function (p) return DEEP + p + a end\n' ..
            '    return cb\n' ..
            'end\n', 'lua')
        ok(eo, 'the fixture parsed')
        local decl
        for _, s in ipairs(eo.fl.stmts or {}) do
            if s.t == 'variable_declaration' then decl = s end
        end
        ok(decl, 'found the declaration row')
        eq({}, expr.reads(decl.expr),
            'the closure body is NOT this row s business')
        eq(0, #expr.gate(eo.fl, 'lua'), 'and du agrees — that is the whole invariant')
    end)

--- ★★★ THE CONSUMER HALF, pinned on a HAND-BUILT node so it does not depend on any
--- spec reaching the new branch. This is the half that was silently dead: every one
--- of these four walkers enumerates kinds explicitly, and `fn` was in none of them.
test('expr fn: a DESCENDED closure exposes its reads to every walker', function ()
    local inner = { k = 'name', n = 'INNER' }
    local dotted = { k = 'field', n = 'member', b = { k = 'name', n = 'mod' } }
    local fn = { k = 'fn', kids = { inner, dotted } }
    local row = { rhs = { fn }, lhs = {}, use = {}, rmw = {} }

    -- expr_reads, via M.reads — the path `expr.gate` compares against du
    eq({ 'INNER', 'mod' }, expr.reads(row), 'reads sees through a descended closure')
    -- M.names — the lint / eval environment
    local names = expr.names(row)
    table.sort(names)
    eq({ 'INNER', 'mod' }, names, 'names sees through it too')
    -- dotted_reads — the EXTERNAL SURFACE
    eq({ 'mod.member' }, expr.dotted_reads(fn), 'and so does the external surface')
    -- children/walk — is_pure and allocates are built on this
    eq(2, #expr.children(fn), 'the walk descends both kids')
end)

--- ★★ THE ALLOCATION FACT MUST SURVIVE THE DESCENT. This is the trap the ticket's
--- rejected option ("just drop function_definition from ALLOCFN") falls into: lose
--- `k='fn'` and `is_pure` calls `function () end` PURE, which opens every
--- key-equality lint to folding two DISTINCT closures together.
test('expr fn: descending does not cost the allocation claim', function ()
    local opaque   = { k = 'fn' }
    local descended = { k = 'fn', kids = { { k = 'name', n = 'INNER' } } }
    for _, e in ipairs({ opaque, descended }) do
        ok(not expr.is_pure(e), 'a closure is never pure')
        ok(expr.allocates(e), 'a closure always allocates')
        eq('Fn', expr.key(e), 'and keys as an opaque allocation either way')
    end
end)

--- ★★★ THE END-TO-END HALF: does `build` actually PRODUCE the descended node when
--- a language withdraws the type? Everything above would pass for a dispatch that
--- never reaches the new branch.
--- ⚠ IT RUNS IN A CHILD NVIM, and the first version of this test is why. The stop
--- set is memoised per language inside the module, so a spec mutation is invisible to
--- an already-loaded copy — and clearing `package.loaded` to force a fresh one LEAKED:
--- pilots_spec passed alone (15 / 0) and FAILED when this file ran before it, because
--- other modules still held the first instance. A child process is the only honest
--- isolation for a module-level cache, and it is the pattern treesitter_spec's
--- plugin-startup test already uses.
test('expr fn: withdrawing the type makes build DESCEND, params included', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local repo = vim.fn.getcwd()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    local script = vim.fn.tempname() .. '.lua'
    local fd = assert(io.open(script, 'w'))
    fd:write(([[
vim.opt.rtp:prepend('%s')
if vim.fn.isdirectory('%s') == 1 then vim.opt.rtp:append('%s') end
local ts = require 'cartograph.providers.treesitter'
-- WITHDRAWN BEFORE expr IS EVER REQUIRED, so its memo is built from the new spec
ts.spec.lua.fn_unminted = { function_definition = true }
local expr = require 'cartograph.expr'
local eo = assert(expr.of_text(
    'local function outer(a)\n'
    .. '    local cb = function (p) return DEEP + p + a end\n'
    .. '    return cb\n'
    .. 'end\n', 'lua'), 'fixture parsed')
for _, st in ipairs(eo.fl.stmts or {}) do
    if st.t == 'variable_declaration' then
        print('READS=' .. table.concat(expr.reads(st.expr), ','))
    end
end
]]):format(repo, tsdir, tsdir))
    fd:close()
    local out = vim.system({ 'nvim', '--headless', '-u', 'NONE', '-l', script }):wait()
    vim.fn.delete(script)
    local blob = tostring(out.stdout) .. tostring(out.stderr)
    -- ★ `p` IS THE CLOSURE'S OWN PARAMETER, and it belongs here. du counts it as a
    -- read of the ENCLOSING row because the mention pass is a textual sweep attributing
    -- to the innermost MINTED function (CART-0926) — measured, not assumed. A body-only
    -- descent yields DEEP,a and this pins against exactly that.
    eq('READS=DEEP,a,p', blob:match('READS=[^\r\n]*') or blob,
        'the descended closure contributes its whole subtree, parameter included')
end)

--- ★★★ THE TRIPWIRE. The branch above is unreachable in production only while
--- ALLOCFN stays a SUBSET of every language's boundary set. When that stops being
--- true the change stops being inert, and the corpus pins need re-measuring.
--- ⚠ THIS GOING RED IS NOT A BUG — it means a spec became the first real user.
--- Re-run exprcensus / dfgate, repin, and name the language here.
test('expr fn: ALLOCFN is a subset of every shipped boundary set (inertness pin)',
    function ()
        local flow = require 'cartograph.flow'
        local ALLOCFN = { 'function_definition', 'function_declaration',
            'anonymous_function', 'arrow_function', 'lambda_expression' }
        local escapes, n = {}, 0
        for lang, s in pairs(ts.spec) do
            if type(s) == 'table' then
                n = n + 1
                local stop = ts.flow_stop(lang)
                local blocks = flow.classes(s).blocks or {}
                for _, t in ipairs(ALLOCFN) do
                    if not stop[t] and not blocks[t] then
                        escapes[#escapes + 1] = lang .. '.' .. t
                    end
                end
            end
        end
        ok(n >= 10, 'the sweep actually saw the specs: ' .. n .. ' languages')
        eq({}, escapes, 'an ALLOCFN type is no longer a boundary somewhere — re-measure')
    end)
