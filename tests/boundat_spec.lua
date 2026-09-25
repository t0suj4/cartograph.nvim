-- CART-1001: what is bound AT A LINE. USER: "Maybe the algebra's scope could help."
--
-- ★★★ THE POINT IS THAT A FLAT SET CANNOT ANSWER THIS. Lua's `local` is the algebra's
-- SEQUENTIAL LET — the right-hand side in the scope before the binding, a new scope
-- after it — so the chunk scope of a long file declares nothing and what is bound is a
-- property OF A POSITION. `va.params`, `file_locals` and a function's `locals` set are
-- all lists, and a list cannot say "bound here and not three lines up".

local B = require 'cartograph.boundat'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'
local cx = require 'cartograph.cloneextract'

local function ready()
    return pcall(vim.treesitter.language.add, 'lua')
end

local SRC = table.concat({
    "local at = require 'cartograph.at'",     -- 0
    'local M = {}',                           -- 1
    '',                                       -- 2
    'local function contains(outer, inner)',  -- 3
    '  local lo = at.sl(outer)',              -- 4
    '  local hp1 = lo + 1',                   -- 5
    '  return hp1 <= inner',                  -- 6
    'end',                                    -- 7
    '',                                       -- 8
    'local function other(p)',                -- 9
    '  local zed = p + 1',                    -- 10
    '  return zed',                           -- 11
    'end',                                    -- 12
    'return M',                               -- 13
}, '\n') .. '\n'

test('★★★ the same name is bound at one line and free at another', function ()
    if not ready() then return end
    local h, why = B.of(SRC, 'p.lua')
    ok(h, 'the scope graph builds: ' .. tostring(why))
    if not h then return end
    ok(h.nrefs > 0, 'and it located references in the source')
    eq(true, (B.is_bound(h, 6, 'hp1')))    -- inside `contains`, after its declaration
    eq(false, (B.is_bound(h, 11, 'hp1')))  -- inside `other`, where it never existed
    -- and the mirror: `zed` is declared at 10, so it is free at 6
    eq(false, (B.is_bound(h, 6, 'zed')))
    eq(true, (B.is_bound(h, 11, 'zed')))
end)

test('the answer is a CLASS, not a boolean — shadowing a library name is legal', function ()
    if not ready() then return end
    local h = B.of(SRC, 'p.lua')
    if not h then return end
    local _, lex = B.is_bound(h, 6, 'lo');    eq('lexical', lex)
    local _, mod = B.is_bound(h, 6, 'at');    eq('module', mod)
    local _, lib = B.is_bound(h, 6, 'table'); eq('library', lib)
    -- ⚠ so `fresh` may hand back a library name: shadowing `table` inside a helper is
    -- legal Lua, and refusing it would make this stricter than the language.
    eq('table', B.fresh(h, 6, 'table'))
end)

test('fresh() steps past a bound name and past names the caller is about to mint', function ()
    if not ready() then return end
    local h = B.of(SRC, 'p.lua')
    if not h then return end
    eq('hp1', B.fresh(h, 11, 'hp1'))                       -- free in `other`
    eq('hp12', B.fresh(h, 6, 'hp1'))                       -- taken in `contains`
    -- ⚠ NAMES NOT YET ON DISK. A caller minting hp1..hpN must not hand out one twice,
    -- and the graph cannot know about a name that has not been written.
    eq('hp13', B.fresh(h, 6, 'hp1', { hp12 = true }))
end)

test('★★ the RANGE form: a body local shadows a parameter, so the range decides', function ()
    if not ready() then return end
    local h = B.of(SRC, 'p.lua')
    if not h then return end
    -- asked at the function's FIRST line alone, `hp1` looks free…
    eq(false, (B.is_bound(h, 3, 'hp1')))
    -- …but a parameter is in scope for the WHOLE body, and line 5 binds it
    eq(true, (B.is_bound(h, 3, 'hp1', 7)))
    eq('hp12', B.fresh(h, 3, 'hp1', nil, 7))
end)

test('it refuses by name where it cannot answer', function ()
    if not ready() then return end
    local h, why = B.of(42, 'p.lua')
    eq(nil, h)
    ok(why:match('not source text'), tostring(why))
    local h2, why2 = B.of('local x = = =\n', 'p.lua')
    -- an unreadable source is an ANSWER, not a default: a caller that got `nil` here
    -- must not mint a name as though nothing were bound.
    if not h2 then ok(why2 and #why2 > 0, 'and it says why: ' .. tostring(why2)) end
end)

test('★★★ the consumer: a donor already using `hp1` FRESHENS instead of refusing', function ()
    if not ready() then return end
    -- ⚠ THE WITNESS IS OURS. `top_sequence_extracted` — a function the extractor itself
    -- generated — is the only one in the tree with a parameter named `hp1`, so the verb
    -- refused its own output. This fixture is that shape.
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local M = {}\n\n'
        .. 'local function fmt_a(x, hp1)\n  local y = prep(x)\n  local z = norm(y)\n'
        .. "  local w = encode(z, 'json')\n  local o = wrap(w, hp1)\n  return o\nend\n\n"
        .. 'local function fmt_b(a, hp1)\n  local b = prep(a)\n  local c = norm(b)\n'
        .. "  local d = encode(c, 'yaml')\n  local e = wrap(d, hp1)\n  return e\nend\n\nreturn M\n")
    fd:close()
    store.ingest(ts.extract(root))
    local id
    for _, n in ipairs(store.data.nodes) do
        if n.name and n.name:match('fmt_a') and n.kind == 'function' then id = n.id end
    end
    local p = id and clones.near_of(store, id, { max_dist = 2, min_rows = 4, min_shared = 3 })[1]
    ok(p, 'the fixture is a near pair')
    if not p then return end
    local plan, why = cx.plan(store, p)
    ok(plan, 'it plans rather than refusing over a name: ' .. tostring(why))
    if not plan then return end
    -- the minted parameter stepped past the donor's own `hp1`
    local txt = {}
    for _, fe in pairs(plan.files or {}) do
        for _, op in ipairs(fe.ops or {}) do
            for _, l in ipairs(op.new or {}) do txt[#txt + 1] = l end
        end
    end
    local blob = table.concat(txt, '\n')
    ok(blob:match('hp12'), 'the helper binds a freshened name:\n' .. blob)
end)

test('★★★ binds_in: TERM-PATH CONTAINMENT sees the body locals the scope route cannot', function ()
    if not ready() then return end
    local h = B.of(SRC, 'p.lua')
    if not h then return end
    -- `contains` spans lines 3..7 and binds `lo` and `hp1` in its body
    eq(true,  (B.binds_in(h, 3, 'lo')))
    eq(true,  (B.binds_in(h, 3, 'hp1')))
    eq(true,  (B.binds_in(h, 3, 'outer')))   -- a parameter
    eq(false, (B.binds_in(h, 3, 'zed')))     -- belongs to `other`
    -- and the mirror, from the other function
    eq(true,  (B.binds_in(h, 9, 'zed')))
    eq(false, (B.binds_in(h, 9, 'hp1')))
    -- ⚠ AN UPVALUE IS NOT A BODY BINDING. `at` is a file-local the body READS; it is not
    -- declared inside, so containment says false — which is the right answer for
    -- "may I name a parameter `at`" only together with the caller's own free-name check.
    eq(false, (B.binds_in(h, 3, 'at')))
end)

test('fn_path refuses rather than answering "nothing is bound"', function ()
    if not ready() then return end
    local h = B.of(SRC, 'p.lua')
    if not h then return end
    -- ⚠ THE DIRECTION MATTERS: a wrong "nothing is bound" MINTS A COLLIDING NAME, so the
    -- construction checks that the path it derives contains the function's own
    -- parameters and refuses by name when it does not.
    local path, why = B.fn_path(h, 0)
    eq(nil, path)
    ok(why and why:match('no function declaration'), tostring(why))
end)

test('fresh_by_path steps past a body local, not just a parameter', function ()
    if not ready() then return end
    local h = B.of(SRC, 'p.lua')
    if not h then return end
    -- `hp1` is a BODY LOCAL of `contains` — invisible to a parameter list and to the
    -- function's entry scope, and exactly what this construction exists to catch.
    eq('hp12', B.fresh_by_path(h, 3, 'hp1'))
    eq('hp1',  B.fresh_by_path(h, 9, 'hp1'))
end)
