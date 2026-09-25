-- clone-merge's DELETE side (CART-0773). CART-0770 fixed the LIFT — a
-- definition's TEXT is not its CONTAINER, so one that is not at module level
-- cannot be moved out. Removal is the same operation backwards and had the same
-- hole: the deletion range is a definition, not necessarily a standalone
-- statement, so taking it out can leave its container unclosed. Measured: ~31
-- plans over two corpora, before-text confirmed clean on every one.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clonemerge = require 'cartograph.clonemerge'

local function ready()
    return pcall(vim.treesitter.language.add, 'lua')
end

local function ingest(src)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src); fd:close()
    store.ingest(ts.extract(root))
    return store
end

local function node_named(st, name)
    for _, n in ipairs(st.data.nodes) do
        if n.name == name and (n.kind == 'function' or n.kind == 'method') then return n end
    end
end

test('clonemerge: two top-level twins still merge (regression)', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(table.concat({
        'local function alpha(x)',
        '    local y = x + 1',
        '    return y',
        'end',
        'local function beta(x)',
        '    local y = x + 1',
        '    return y',
        'end',
        'return { alpha = alpha, beta = beta }',
    }, '\n'))
    local a = node_named(st, 'alpha')
    if not a then skip('no nodes') end
    local plan, why = clonemerge.plan(st, a.id)
    ok(plan, 'a top-level twin is removable: ' .. tostring(why))
end)

-- ★★ THE REGRESSION THAT DISTINGUISHES THE CORRECT PREDICATE FROM THE BLUNT ONE.
-- The first cut reused moveapply's `enclosing_syntax` as the DECISION — "is this
-- at module level" — and refused every twin inside a container. Measured on our
-- own tree it refused 50 merge plans of which only 16 would actually have broken:
-- precision 32%, where the same predicate on the MOVE side caught 368 for a cost
-- of 42. On the LIFT side a container is always fatal, because the text cannot
-- stand alone at the destination; on the DELETE side removing ONE WHOLE ELEMENT
-- of a list leaves a valid list. The operations are not the same predicate.
test('clonemerge: a twin inside a table constructor STILL MERGES when removal is clean', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(table.concat({
        'local T = {',
        '    alpha = function (x) local y = x + 1 return y end,',
        '    beta = function (x) local y = x + 1 return y end,',
        '}',
        'return T',
    }, '\n'))
    local a = node_named(st, 'T.alpha') or node_named(st, 'alpha')
    if not a then skip('table-field functions are not minted as nodes here') end
    local plan, why = clonemerge.plan(st, a.id)
    ok(plan, 'removing one whole element of a list leaves a valid list: ' .. tostring(why))
end)

-- and the case that actually breaks: the twin's range runs into the container's
-- closing delimiter, so removing its lines takes the brace with them
test('clonemerge: a removal that would leave the file unparseable is REFUSED', function ()
    if not ready() then skip('no lua parser') end
    -- ★ THE SHAPE IS TAKEN FROM THE CORPUS, NOT INVENTED. A first attempt used a
    -- multi-line body with `end }` on its own line and did not trip, so the
    -- fixture SKIPPED — and a skipped fixture guards nothing. The real witness,
    -- `tools/matrix.lua:502`, is the LAST element of a table whose closing brace
    -- shares ITS LINE, so the element's range covers the brace:
    --     500|         local shim = { data = data,
    --     501|             node = function (id) return index[id] end,
    --     502|             abs = function (f) return f end }        <- removed
    local st = ingest(table.concat({
        'local T = { data = 1,',
        '    alpha = function (x) local y = x + 1 return y end,',
        '    beta = function (x) local y = x + 1 return y end }',
        'return T',
    }, '\n'))
    -- ★ PLAN ON `alpha`, SO `beta` IS THE ONE REMOVED. Which side refuses depends
    -- on which is the SURVIVOR: the check is about the twin being DELETED, not
    -- the one being kept, and planning on `beta` merges cleanly because removing
    -- `alpha` (an interior line) leaves the table intact. A first version of this
    -- fixture planned on the wrong side and passed for the wrong reason.
    local a = node_named(st, 'T.alpha') or node_named(st, 'alpha')
    if not a then skip('table-field functions are not minted as nodes here') end
    local plan, why = clonemerge.plan(st, a.id)
    ok(not plan, 'the removal takes the closing brace with it, so it is refused')
    ok(why and why:find('unparseable'), 'refused for the right reason: ' .. tostring(why))
    -- ★ THE EXPLANATION, NOT THE DECISION: naming the container is what makes it
    -- actionable, and "does not parse" alone would not be.
    ok(why:find('inside'), 'and names the container: ' .. tostring(why))
end)

--- ★★★ THE STATEMENT-KIND GATE (CART-0892). `refs.witness` is df shape + params
--- + callees and `row_key` is `lhs=rhs;C:cond`: NEITHER encodes what kind of
--- statement a row is. So an `if` block and a `while` loop over the same body
--- are twins on BOTH identities, and this verb planned to DELETE one of them.
---
--- ⚠ Two independent derivations agreeing is not corroboration when both sit
--- downstream of a row model that never carried the kind. The standing law — a
--- write authorised by a derived fact must RE-DERIVE it — is SATISFIED here and
--- does not help: re-deriving a blind witness re-derives the blindness. And
--- `parses` cannot help either; the result parses fine. It is a SEMANTIC change.
test('clonemerge: an `if` and a `while` over the same body are NOT twins', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(table.concat({
        'local function ifver(t, n)',
        '    local acc = 0',
        '    local out = {}',
        '    if n > 0 then',
        '        acc = acc + n',
        '        n = n - 1',
        '    end',
        '    out[1] = acc',
        '    return out',
        'end',
        'local function whilever(t, n)',
        '    local acc = 0',
        '    local out = {}',
        '    while n > 0 do',
        '        acc = acc + n',
        '        n = n - 1',
        '    end',
        '    out[1] = acc',
        '    return out',
        'end',
        'return { ifver = ifver, whilever = whilever }',
    }, '\n'))
    local a = node_named(st, 'ifver')
    if not a then skip('no nodes') end

    local twins, _, rejected = clonemerge.twins(st, a.id)
    eq(0, #twins)
    ok((rejected or 0) > 0,
        'the witness MATCHED and the kind gate is what threw it out — otherwise '
        .. 'this test would pass for the wrong reason (no witness at all)')

    -- and the refusal NAMES which gate, because "no twin" and "a twin the kind
    -- check rejected" are different facts and the second is the interesting one
    local plan, why = clonemerge.plan(st, a.id)
    eq(nil, plan)
    ok(tostring(why):find('STATEMENT KINDS'), 'names the gate: ' .. tostring(why))
end)

--- BOTH SIDES: the gate must not refuse a genuine twin. Same bodies, same kinds.
test('clonemerge: identical statement kinds still merge', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(table.concat({
        'local function one(t, n)',
        '    local acc = 0',
        '    if n > 0 then acc = acc + n end',
        '    return acc',
        'end',
        'local function two(t, n)',
        '    local acc = 0',
        '    if n > 0 then acc = acc + n end',
        '    return acc',
        'end',
        'return { one = one, two = two }',
    }, '\n'))
    local a = node_named(st, 'one')
    if not a then skip('no nodes') end
    local plan, why = clonemerge.plan(st, a.id)
    ok(plan, 'a true twin still merges: ' .. tostring(why))
end)

--- ★★ ABSENCE IS NOT PERMISSION, and this branch guards a DELETION. A kind
--- sequence we cannot compute is not evidence the two functions agree — it is
--- no evidence at all — so an unreadable side must refuse the twin rather than
--- fall through to today's blind behaviour.
---
--- ⚠ FORCED, because the branch is unreachable from a lua fixture: measured on
--- our own tree, 0 of 8880 witness-matched pairs had an unreadable kind
--- sequence. It IS reachable for a language this layer has no spec for, which is
--- precisely where a silent fall-through would do its damage. Stubbing `expr.of`
--- is the only way to reach it without inventing a second language in a fixture;
--- the mutation "treat absence as permission" survives every other test here.
test('clonemerge: an UNREADABLE kind sequence refuses the twin', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(table.concat({
        'local function one(t, n)',
        '    local acc = 0',
        '    if n > 0 then acc = acc + n end',
        '    return acc',
        'end',
        'local function two(t, n)',
        '    local acc = 0',
        '    if n > 0 then acc = acc + n end',
        '    return acc',
        'end',
        'return { one = one, two = two }',
    }, '\n'))
    local a = node_named(st, 'one')
    if not a then skip('no nodes') end

    -- it merges while the kinds are readable (the control: otherwise this test
    -- would pass on a fixture that never had a twin)
    ok(clonemerge.plan(st, a.id), 'the twin is there to begin with')

    -- ⚠ STUB ONLY THE CANDIDATE LOOKUPS. Stubbing every call makes the SURVIVOR
    -- unreadable too, which trips its own earlier refusal and never reaches the
    -- branch under test — the first cut did exactly that and passed for the
    -- wrong reason.
    local expr = require 'cartograph.expr'
    local saved = expr.of
    expr.of = function (st2, qid)
        if qid == a.id then return saved(st2, qid) end
        return nil
    end
    local okc, twins, _, rejected = pcall(clonemerge.twins, st, a.id)
    expr.of = saved

    ok(okc, 'twins survives an unreadable candidate: ' .. tostring(twins))
    eq(0, #twins)
    ok((rejected or 0) > 0, 'and it was REFUSED, not silently allowed')
end)

--- ★★★ THE MINIMUM-BODY FLOOR (CART-0895). `refs.witness` is df shape + params
--- + callees; a ONE-ROW function has almost nothing for it to tell apart, so
--- one-liners collide wholesale. MEASURED on our own tree before the floor: 318
--- merge plans SUCCEEDED, 216 of them (68%) with a one-row survivor, and the
--- largest DELETED 50 FUNCTIONS including `M.argv_of`, `M.argn` and `get` from
--- three unrelated files.
---
--- ⚠ THE KIND GATE ABOVE DOES NOT CATCH THIS — a 1-row body has a 1-element kind
--- sequence, so all 216 pass it. Two blind spots in one verb; either alone
--- leaves the other. `clones.lua` already had the rule this verb was missing:
--- `INDEX_FLOOR = 2`, "a 0-1 stmt body can't be any tier's clone".
test('clonemerge: a one-row body is below the floor and refuses', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(table.concat({
        'local function alpha(x)',
        '    return x + 1',
        'end',
        'local function beta(x)',
        '    return x + 1',
        'end',
        'return { alpha = alpha, beta = beta }',
    }, '\n'))
    local a = node_named(st, 'alpha')
    if not a then skip('no nodes') end

    local twins, why = clonemerge.twins(st, a.id)
    eq(0, #twins)
    ok(tostring(why):find('floor'), 'names the floor: ' .. tostring(why))

    local plan, pwhy = clonemerge.plan(st, a.id)
    eq(nil, plan)
    ok(tostring(pwhy):find('floor'), 'and the plan refuses for that reason: ' .. tostring(pwhy))
end)

--- ⚠ UNREADABLE IS NOT "ZERO ROWS". Ordering the floor before the readability
--- check reported "a 0-row body is below the floor" — a claim about a body
--- nobody read. Absence gets its own refusal, and this pins which one fires.
test('clonemerge: an unreadable SURVIVOR refuses as unreadable, not as below-floor', function ()
    if not ready() then skip('no lua parser') end
    local st = ingest(table.concat({
        'local function alpha(x)',
        '    local y = x + 1',
        '    return y',
        'end',
        'local function beta(x)',
        '    local y = x + 1',
        '    return y',
        'end',
        'return { alpha = alpha, beta = beta }',
    }, '\n'))
    local a = node_named(st, 'alpha')
    if not a then skip('no nodes') end
    ok(clonemerge.plan(st, a.id), 'it merges while the body is readable')

    local expr = require 'cartograph.expr'
    local saved = expr.of
    expr.of = function () return nil end
    local twins, why = clonemerge.twins(st, a.id)
    expr.of = saved

    eq(0, #twins)
    ok(tostring(why):find('cannot be read'), 'names unreadability: ' .. tostring(why))
    ok(not tostring(why):find('floor'), 'and does NOT claim a row count it never saw')
end)
