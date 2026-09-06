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
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
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
        '    return x + 1',
        'end',
        'local function beta(x)',
        '    return x + 1',
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
        '    alpha = function (x) return x + 1 end,',
        '    beta = function (x) return x + 1 end,',
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
        '    alpha = function (x) return x + 1 end,',
        '    beta = function (x) return x + 1 end }',
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
