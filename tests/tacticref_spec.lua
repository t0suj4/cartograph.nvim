-- CART-1989: a ref an AGENT builds and hands to a tactic over toolbelt_run gets the same honesty as a ref handed to an
-- agent verb since CART-0718 — node_find's tail rule (`slow` ~ `M.slow`) instead of exact-or-"does not resolve". Both
-- forms are pinned: the `file::name` STRING (toolbelt.coerce) and the ref TABLE (store.ref_param, in each tactic). Both
-- sides of the rule are pinned too: a READ resolves a unique tail; a WRITE refuses it NAMING the qualified ref (the
-- agent's write-side ref-caveat rule); several tails refuse as UNDERQUALIFIED with every candidate; an exact ref is
-- unchanged; a name that is nowhere is still stale, and says it CHECKED.
local store = require 'cartograph.store'
local agent = require 'cartograph.agent'
local tb = require 'cartograph.toolbelt'

local function ready()
    return pcall(vim.treesitter.get_string_parser, '', 'lua') and require('cartograph.algebra').available()
end

local SRC = table.concat({
    'local M = {}',
    'function M.slow(t) return #t end',
    'function M.pair(a, b) return a + b end',
    'local H = {}',
    'function H.pair(a, b) return a - b end',
    'return M', '' }, '\n')
local function project()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/tr.lua', 'w')); fd:write(SRC); fd:close()
    store.ingest(require('cartograph.providers.treesitter').extract(root))
    return root
end
local function ref(name) return { file = 'tr.lua', kind = 'function', name = name } end
local function run(name, params)
    local r = agent.answer(store, 'toolbelt_run', { name = name, params = params })
    local res = type(r.result) == 'table' and r.result[1] or {}
    -- (the step's own sentence when the tactic failed; the whole envelope otherwise, so an exact run reads as no refusal)
    return res.status == 'failed' and tostring(res.why) or vim.inspect(r)
end

test('tacticref: a WRITE tactic given an underqualified ref TABLE refuses naming the qualified ref, not "does not resolve"', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project()
    local m = run('memoize', { ref = ref('slow'), residence = 'weak' })
    ok(m:find('tail-match', 1, true) and m:find('name = "M.slow"', 1, true), m)
    ok(not m:find('does not resolve (', 1, true), 'not the old exact-only miss: ' .. m)
    local e = run('edit-in', { ref = ref('slow'), before = '#t', after = '#t + 0' })
    ok(e:find('tail-match', 1, true) and e:find('M.slow', 1, true), e)
    -- a write tactic whose ref rides into a recipe step (align-family -> propagate -> compose's one_ref)
    local f = run('align-family', { ref = ref('slow'), text = 'function M.slow(t) return #t + 0 end' })
    ok(f:find('tail-match', 1, true) and f:find('name = "M.slow"', 1, true), f)
    -- several tails: UNDERQUALIFIED, every candidate named
    local a = run('memoize', { ref = ref('pair'), residence = 'weak' })
    ok(a:find('ambiguous-tail', 1, true) and a:find('UNDERQUALIFIED', 1, true)
        and a:find('M.pair', 1, true) and a:find('H.pair', 1, true), a)
    -- exact: unchanged — no ref refusal at all
    local x = run('memoize', { ref = ref('M.slow'), residence = 'weak' })
    ok(not x:find('does not resolve', 1, true) and not x:find('CAVEAT', 1, true) and not x:find('"failed"', 1, true), x)
    -- nowhere: still stale, and the sentence says the graph was searched
    local g = run('memoize', { ref = ref('nothere'), residence = 'weak' })
    ok(g:find('anywhere in this graph', 1, true), g)
end)

test('tacticref: the file::name STRING form — a write names the qualified ref, a discovery resolves a unique tail', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project()
    local _, w, cls = tb.coerce(store, assert(tb.load('memoize')), { ref = 'tr.lua::slow' })
    eq('ill-posed', cls)
    ok(w and w:find('UNDERQUALIFIED', 1, true) and w:find('tr.lua::M.slow', 1, true), tostring(w))
    local _, a = tb.coerce(store, assert(tb.load('memoize')), { ref = 'tr.lua::pair' })
    ok(a and a:find('2 definitions', 1, true) and a:find('tr.lua::H.pair', 1, true) and a:find('tr.lua::M.pair', 1, true), tostring(a))
    local p, why = tb.coerce(store, assert(tb.load('binding-times')), { ref = 'tr.lua::slow' })
    ok(p, tostring(why)); eq('M.slow', p.ref.name, 'a discovery resolves the unique tail')
    local _, ap = tb.coerce(store, assert(tb.load('binding-times')), { ref = 'tr.lua::pair' })
    ok(ap and ap:find('UNDERQUALIFIED', 1, true), 'a discovery still refuses an AMBIGUOUS tail: ' .. tostring(ap))
    local px = tb.coerce(store, assert(tb.load('memoize')), { ref = 'tr.lua::M.slow' })
    eq('M.slow', px and px.ref.name, 'exact is unchanged')
end)

test('tacticref: a READ (mixfn.lower_ref) lowers a unique-tail ref TABLE and carries the caveat; the agent verbs share the resolver', function ()
    if not ready() then skip 'no lua parser or algebra' end
    project()
    local F = require 'cartograph.mixfn'
    local prog, params, _, how = F.lower_ref(store, ref('slow'))
    ok(prog, tostring(params))
    ok(how.ref_caveat and how.ref_caveat:find('tail-match', 1, true), vim.inspect(how))
    local px, _, _, hx = F.lower_ref(store, ref('M.slow'))
    ok(px and hx.ref_caveat == nil, 'exact: no caveat')
    local pn, why = F.lower_ref(store, ref('pair'))
    ok(not pn and why:find('UNDERQUALIFIED', 1, true), tostring(why))
    -- one decision, two wrappers: the store-level rule and the agent's tail rule are the same function
    eq(require('cartograph.refs').tail_match, agent.tail_match)
    local id, cav, tail = store.resolve_caller_ref(ref('slow'))
    ok(id and tail and cav:find('M.slow', 1, true), tostring(cav))
end)
