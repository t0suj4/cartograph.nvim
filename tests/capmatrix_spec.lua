-- THE DERIVED CAPABILITY MATRIX (lua/cartograph/capmatrix.lua, CART-0693), and its
-- PROJECTING work list (`tools/specaudit.lua --capabilities`).
--
-- ★ THE DERIVATION IS THE THING TO FENCE. The pass/dispatch table is READ from the
-- provider's source; if a refactor renames `capn` or reshapes a comparison, the
-- derivation silently returns fewer captures, the dead-kernel list silently empties
-- and the matrix silently loses rows — a fence that never fires. So the first test
-- pins the derived table against the running provider, capture by capture.
-- ★ AND THE ACCEPTANCE CASE IS A KNOWN ANSWER: CART-0692 (iface_query unfilled for
-- typescript/tsx while their grammar has the clause) was found by hand; the
-- projecting list must re-find it, at the top.

local cm = require 'cartograph.capmatrix'

local function provider_src()
    local fd = assert(io.open(repo('lua/cartograph/providers/treesitter.lua'), 'r'))
    local s = fd:read('*a'); fd:close()
    return s
end

local function set(list) local s = {} for _, x in ipairs(list) do s[x] = true end return s end
local function keys(t) local o = {} for k in pairs(t) do o[#o + 1] = k end table.sort(o) return o end

test('capmatrix: the pass table is derived from the provider, capture by capture', function ()
    local passes = cm.passes(provider_src())
    local by = {}
    for _, p in ipairs(passes) do by[table.concat(p.slots, '+')] = p end
    local defs
    for k, p in pairs(by) do if k:find('^functions%+') then defs = p end end
    ok(defs, 'the concatenated defs pass is found: ' .. vim.inspect(keys(by)))
    eq({ 'adef', 'cctor', 'child', 'cvar', 'def', 'name', 'parent', 'rdef', 'smtclass',
        'value', 'vdecl', 'vdef', 'vname' }, keys(defs.captures), 'the defs dispatch')
    ok(defs.catchall, 'and its catch-all (an unknown capture becomes a CATEGORY)')
    ok(set(defs.slots).super_query and set(defs.slots).fields, 'its slots come from the concat list')
    eq({ 'bind', 'path' }, keys(by.import_query.captures), 'import_query')
    eq({ 'ichild', 'idecl', 'iface' }, keys(by.iface_query.captures), 'iface_query')
    eq({ 'rcls' }, keys(by.reg_read_query.captures), 'reg_read_query (captures[id] form)')
    eq({ 'call', 'name' }, keys(by.calls.captures), 'calls')
    ok(by.aperture_query and by.aperture_query.catchall, 'aperture: every capture is a rule name')
end)

-- a synthetic provider + specs: the matrix logic, with every external fact supplied
local SRC = table.concat({
    "combined = table.concat({ spec.functions or '', spec.extra or '' }, '\\n')",
    'local q = parse_query(lang, combined)',
    "if capn == 'def' then elseif capn == 'name' then elseif capn == 'zz' then",
    "elseif capn:sub(1, 1) ~= '_' then catn = n end",
    'q = parse_query(lang, spec.linker)',
    "if cn == 'lhs' then elseif cn == 'rhs' then end",
}, '\n')

local SPECS = {
    alpha = { functions = '(alpha_decl name: (identifier) @name) @def',
        linker = '(alpha_impl (identifier) @lhs (beta_ref) @rhs)',
        extra = '(alpha_macro) @macro',
        stray = '(alpha_decl) @x' },
    beta = { functions = '(beta_decl name: (identifier) @name) @def' },
    gamma = { functions = '(gamma_decl (identifier) @name) @def' },
}
local GRAMMAR = {
    alpha = set({ 'alpha_decl', 'alpha_impl', 'beta_ref', 'alpha_macro', 'identifier' }),
    beta = set({ 'beta_decl', 'alpha_impl', 'beta_ref', 'identifier' }),
    gamma = set({ 'gamma_decl', 'identifier' }),
}
local OPTS = {
    captures = function (_, q)
        local out = {}
        for c in q:gmatch('@([%w_]+)') do out[#out + 1] = c end
        return out
    end,
    provides = function (lang) return GRAMMAR[lang] end,
}

test('capmatrix: a dispatched capture nobody binds is DEAD; an unknown one is a CATEGORY', function ()
    local R = cm.derive(SPECS, cm.passes(SRC), OPTS)
    eq(1, #R.dead, vim.inspect(R.dead))
    eq('zz', R.dead[1].capture, 'the dispatch names @zz and no spec binds it')
    ok(R.category.alpha.macro, '@macro is alpha\'s node category, not dead')
    ok(not R.bound_by.macro, 'and it is not in the dispatched matrix')
    eq({ 'alpha', 'beta', 'gamma' }, keys(R.bound_by.name), '@name is bound by all three')
    eq({ 'stray' }, R.unconsumed.alpha, 'a query-shaped field no pass parses is reported')
end)

test('capmatrix: a type in MORE than half the grammars is not distinctive', function ()
    -- three grammars: the cut is floor(3/2) = 1, so alpha_impl and beta_ref (in alpha
    -- AND beta) are ordinary here, the donor vocabulary has no distinctive type, and
    -- nothing projects — even though beta's grammar has every type linker names
    local R = cm.derive(SPECS, cm.passes(SRC), OPTS)
    local ps = cm.project_slots(R)
    local hit = {}
    for _, c in ipairs(ps) do hit[c.slot .. ' ' .. c.lang] = c end
    ok(not hit['linker beta'], 'no distinctive type, no candidate: ' .. vim.inspect(ps))
    ok(not hit['linker gamma'], 'gamma has only `identifier` of the donor\'s vocabulary')
end)

test('capmatrix: a donor vocabulary of ubiquitous types is never a candidate', function ()
    -- four grammars so the distinctive cut is 2: alpha_impl/beta_ref (in 2) qualify,
    -- identifier (in 4) does not
    local specs = vim.deepcopy(SPECS)
    specs.delta = { functions = '(delta_decl (identifier) @name) @def' }
    local grammar = vim.deepcopy(GRAMMAR)
    grammar.delta = set({ 'delta_decl', 'identifier' })
    local opts = { captures = OPTS.captures, provides = function (l) return grammar[l] end }
    local R = cm.derive(specs, cm.passes(SRC), opts)
    local hit = {}
    for _, c in ipairs(cm.project_slots(R)) do hit[c.slot .. ' ' .. c.lang] = c end
    ok(hit['linker beta'], 'beta has the donor\'s distinctive alpha_impl + beta_ref: ' .. vim.inspect(hit))
    eq(2, hit['linker beta'].cv.dk, 'both distinctive types present')
    ok(not hit['linker delta'] and not hit['linker gamma'],
        'identifier alone never makes a candidate')
    local pc = cm.project_captures(R)
    local cap = {}
    for _, c in ipairs(pc) do cap['@' .. c.capture .. ' ' .. c.lang] = true end
    ok(cap['@lhs beta'] and cap['@rhs beta'], 'the single-language captures project to beta too')
end)

test('capmatrix: top-level patterns keep their trailing captures', function ()
    local ps = cm.patterns('(a (b) @x) @y\n; (c) @z\n[(d) (e)] @w "(f)"')
    eq({ '(a (b) @x) @y', '[(d) (e)] @w' }, ps, 'comments and strings are not patterns')
end)

test('capmatrix: the acceptance case — CART-0692 tops the projecting list', function ()
    for _, l in ipairs({ 'java', 'typescript', 'tsx' }) do
        if not parser_available(l) then skip('no ' .. l .. ' parser') end
    end
    local ts = require 'cartograph.providers.treesitter'
    local R = cm.derive(ts.spec, cm.passes(provider_src()), cm.live_opts())
    local ps = cm.project_slots(R)
    local top, all = {}, {}
    for i, c in ipairs(ps) do
        all[c.slot .. ' ' .. c.lang] = true
        if i <= 2 then top[c.slot .. ' ' .. c.lang] = c.donor end
    end
    for _, l in ipairs({ 'typescript', 'tsx' }) do
        if ts.spec[l].iface_query then
            -- CART-0692 FIXED: the instrument must stop listing it, not keep a stale row
            ok(not all['iface_query ' .. l], l .. ' fills iface_query now and is no candidate')
        else
            eq('java', top['iface_query ' .. l], l .. ' leaves iface_query empty: ' .. vim.inspect(top))
        end
    end
    eq(0, #R.dead, 'no dispatched capture is dead today')
end)
