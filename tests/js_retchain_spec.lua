-- THE DETERMINING CALL OF A CHAINED CALL (CART-0808). `spec.local_ret` hands
-- resolve_returns the POSITION of the call whose return value this call is
-- invoked on, and resolve_returns looks that position up in an index keyed by
-- each call's `at` START. Three things were wrong at once and each one alone
-- measured zero, which is why they are pinned together here.

local jsspec = require 'cartograph.spec.javascript'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'javascript')
end

--- the first call_expression whose source text starts with `prefix`. Both helpers
--- select by TEXT: a chained call CONTAINS its determining call, so document
--- order picks the wrong one of the pair whichever end you take it from.
local function call_node(src, prefix)
    local parser = vim.treesitter.get_string_parser(src, 'javascript')
    local root = parser:parse()[1]:root()
    local hit
    local function walk(n)
        if not hit and n:type() == 'call_expression'
            and vim.startswith(vim.treesitter.get_node_text(n, src), prefix) then
            hit = n
        end
        for ch in n:iter_children() do if ch:named() then walk(ch) end end
    end
    walk(root)
    return hit
end

--- local_ret for the CHAINED call named by `prefix`
local function rt_of(src, prefix)
    local n = call_node(src, prefix)
    return n and jsspec.local_ret(n, src)
end

--- the (row, col) a call's `at` starts at — pos_of(call) — so a test can assert
--- that local_ret names a position the call index will actually hold. Found by
--- its SOURCE TEXT, because a chained expression nests the determining call
--- INSIDE the chained one and document order alone picks the wrong member.
local function call_start(src, prefix)
    local hit = call_node(src, prefix)
    if not hit then return nil end
    local r, c = hit:start()
    return { r = r, c = c }
end

test('retchain: rt names the CALL position, not the callee name', function ()
    if not ready() then skip 'no javascript parser' end
    -- ⚠ THE BUG THIS PINS: `sinon.createSandbox` begins six columns after the
    -- call does, and the index resolve_returns reads is keyed by the call. rt was
    -- set on thousands of calls and every lookup missed.
    local src = 'function f() {\n  const s = sinon.createSandbox();\n  s.restore();\n}\n'
    eq(call_start(src, 'sinon.createSandbox('), rt_of(src, 's.restore('))
end)

test('retchain: the MODULE BODY is a scope', function ()
    if not ready() then skip 'no javascript parser' end
    -- a top-level binding had no enclosing function, so it was never recorded —
    -- and a test file's sandbox is declared exactly there
    local src = 'const s = sinon.createSandbox();\nfunction t() {\n  s.restore();\n}\n'
    eq(call_start(src, 'sinon.createSandbox('), rt_of(src, 's.restore('))
end)

test('retchain: a receiver that IS a call needs no binding at all', function ()
    if not ready() then skip 'no javascript parser' end
    -- the DIRECT chain, and the largest shape by far: 789 `.returns` and 870
    -- `.resolves` sites on ghost hang off `sinon.stub(obj, 'm')`
    local src = "function f() {\n  sinon.stub(o, 'm').resolves(v);\n}\n"
    local rt = rt_of(src, "sinon.stub(o, 'm').resolves(")
    ok(rt ~= nil, 'a call receiver names its own position')
    eq(call_start(src, 'sinon.stub('), rt)
end)

test('retchain: await is unwrapped on both routes', function ()
    if not ready() then skip 'no javascript parser' end
    local direct = 'async function f() {\n  (await g()).h();\n}\n'
    eq(call_start(direct, 'g()'), rt_of(direct, '(await g()).h('))
    local bound = 'async function f() {\n  const r = await g();\n  r.h();\n}\n'
    eq(call_start(bound, 'g()'), rt_of(bound, 'r.h('))
end)

test('retchain: a REBOUND local is ambiguous and names nothing', function ()
    if not ready() then skip 'no javascript parser' end
    -- set-once only: the second binding may carry a different type, and a wrong
    -- rt propagates through the fixpoint rather than merely failing
    local src = 'function f() {\n  let s = a();\n  let s = b();\n  s.restore();\n}\n'
    eq(nil, rt_of(src, 's.restore('))
end)

test('retchain: a call is NOT owned by the callback it passes', function ()
    if not ready() then skip 'no javascript parser' end
    -- ⚠ THE OWNERSHIP DEFECT CART-0813 EXPOSED. `fn_at` picks the innermost
    -- function CONTAINING a call, and a LINE-granular test says a callback opening
    -- on its caller's line contains that call — so `f(function(){...})` was
    -- attributed to its own argument. It was invisible while lua closures were not
    -- nodes; it produced seven self-loops on bravest-new-world the moment they
    -- were, and it had been silently mis-attributing JS callbacks all along.
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/a.js', 'w'))
    fd:write('function outer() {\n  wrap(function () { inner(); });\n}\n'
        .. 'function inner() {}\nfunction wrap(f) { f(); }\n')
    fd:close()
    local data = ts.extract(root)
    local byid, wrapcall = {}, nil
    for _, n in ipairs(data.nodes) do byid[n.id] = n end
    for _, c in ipairs(data.calls or {}) do
        if (c.callee or '') == 'wrap' then wrapcall = c end
    end
    ok(wrapcall ~= nil, 'the registration call is in the graph')
    local owner = wrapcall.fn and byid[wrapcall.fn]
    ok(owner ~= nil, 'and it has an owner')
    eq('outer', owner.name, 'the ENCLOSING function, never the callback argument')
    vim.fn.delete(root, 'rf')
end)
