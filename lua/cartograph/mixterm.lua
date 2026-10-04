-- cartograph.mixterm — THE LENS between mix's IR and the algebra's terms (CART-1341). USER (2026-10-03), choosing the
-- route: "Adapter lens" — mix keeps its IR (612 field reads, CART-1341 step 4's census) and the algebra sees it through
-- this adapter, the way `cartograph.algebra.term` sees the expression IR through `expr.children`.
--
-- ★ THE SCHEMA IS THE ONE DECLARATION: per IR kind, its fields in order, each with a ROLE —
--   node    a subterm                       list    a list of subterms -> a `seq`
--   lit     a scalar (an operator, a name, a constant, a variable id) -> a `lit` kid, so A.eq / match / join SEE it
--   lits    a list of scalars -> a `seq` of lits          carry   bookkeeping (lambda.freeset): rides along as a field
--   clauses an if's { cond, body } records -> `clause` nodes      fields  a table's { key, val } -> `field` nodes
-- An absent field is the node `none`. The fence (tests/mixterm_spec.lua) holds every constructor site of mix.lua to it
-- (derived from mix.lua's own syntax), and the ORACLE is the round trip: of_term(to_term(x)) == x on real IR.
-- ⚠ The algebra's A.eq compares only k / v / n / kids, so anything SEMANTIC must be a kid — an operator or a constant
-- carried as a plain field would make `a + b` equal `a - b` to the algebra.
-- No metatables, varargs or loops beyond for: mix calls this, and mix stays inside S.
local M = {}

local NODE, LIST, LIT, LITS, CARRY, CLAUSES, FIELDS = 'node', 'list', 'lit', 'lits', 'carry', 'clauses', 'fields'

M.SCHEMA = {
    assign = { { 'target', NODE }, { 'e', NODE }, { 'at', CARRY } },
    assignm = { { 'targets', LIST }, { 'es', LIST }, { 'at', CARRY } },
    bin = { { 'o', LIT }, { 'l', NODE }, { 'r', NODE } },
    bool = { { 'v', LIT } },
    ['break'] = { { 'at', CARRY } },
    call = { { 'fn', LIT }, { 'args', LIST } },
    callstmt = { { 'e', NODE }, { 'at', CARRY } },
    callv = { { 'f', NODE }, { 'args', LIST } },
    ['do'] = { { 'body', LIST }, { 'at', CARRY } },
    fn = { { 'name', LIT } },
    forin = { { 'kind', LIT }, { 'kid', LIT }, { 'vid', LIT }, { 'kname', LIT }, { 'vname', LIT }, { 'e', NODE }, { 'body', LIST }, { 'at', CARRY } },
    fornum = { { 'id', LIT }, { 'name', LIT }, { 'from', NODE }, { 'to', NODE }, { 'step', NODE }, { 'body', LIST }, { 'at', CARRY } },
    global = { { 'name', LIT } },
    gref = { { 'name', LIT } },
    ['if'] = { { 'clauses', CLAUSES }, { 'els', LIST }, { 'at', CARRY } },
    index = { { 'obj', NODE }, { 'key', NODE } },
    -- (`pin`: the per-iteration locals the closure copies when it is made — semantic, so a kid)
    lambda = { { 'id', LIT }, { 'params', LITS }, { 'pnames', LITS }, { 'free', LITS }, { 'pin', LITS }, { 'freeset', CARRY }, { 'body', LIST }, { 'at', CARRY } },
    -- (`forced`: set after construction by assignment conversion — a variable a closure stores into is dynamic; the
    -- round trip on real IR found it, the constructor census cannot)
    ['local'] = { { 'id', LIT }, { 'name', LIT }, { 'forced', LIT }, { 'e', NODE }, { 'at', CARRY } },
    localm = { { 'ids', LITS }, { 'names', LITS }, { 'forced', LIT }, { 'es', LIST }, { 'at', CARRY } },
    method = { { 'obj', NODE }, { 'm', LIT }, { 'args', LIST } },
    ['nil'] = {},
    num = { { 'v', LIT } },
    prim = { { 'name', LIT }, { 'args', LIST } },
    ['repeat'] = { { 'body', LIST }, { 'cond', NODE }, { 'at', CARRY } },
    ret = { { 'es', LIST }, { 'at', CARRY } },
    str = { { 'v', LIT } },
    table = { { 'fields', FIELDS } },
    un = { { 'o', LIT }, { 'e', NODE } },
    var = { { 'id', LIT }, { 'name', LIT } },
    ['while'] = { { 'cond', NODE }, { 'body', LIST }, { 'at', CARRY } },
}

local function refuse(why) error({ refusal = 'mixterm: ' .. why }, 0) end
local NONE = 'none'
local function none() return { k = NONE, kids = {} } end

local to_term
local function list_term(l)
    if l == nil then return none() end
    local kids = {}
    for i, x in ipairs(l) do kids[i] = to_term(x) end
    return { k = 'seq', kids = kids }
end
local function lits_term(l)
    if l == nil then return none() end
    local kids = {}
    for i, x in ipairs(l) do kids[i] = { k = 'lit', v = x } end
    return { k = 'seq', kids = kids }
end

--- an IR node (expression or statement) -> an algebra term. An unknown kind, and a field the schema does not name,
--- refuse BY NAME — the round trip must be exact, so nothing is dropped silently
function to_term(n)
    if n == nil then return none() end
    local s = M.SCHEMA[n.op]
    if not s then refuse('no schema for the IR kind ' .. tostring(n.op)) end
    local known = { op = true }
    for _, f in ipairs(s) do known[f[1]] = true end
    for k in pairs(n) do if not known[k] then refuse(('the field `%s` of an IR `%s` is not in its schema'):format(tostring(k), n.op)) end end
    local t = { k = n.op, kids = {} }
    for _, f in ipairs(s) do
        local name, how = f[1], f[2]
        local v = n[name]
        if how == CARRY then t[name] = v
        elseif how == NODE then t.kids[#t.kids + 1] = to_term(v)
        elseif how == LIST then t.kids[#t.kids + 1] = list_term(v)
        elseif how == LIT then t.kids[#t.kids + 1] = v == nil and none() or { k = 'lit', v = v }
        elseif how == LITS then t.kids[#t.kids + 1] = lits_term(v)
        elseif how == CLAUSES then
            local cs = {}
            for i, c in ipairs(v or {}) do cs[i] = { k = 'clause', kids = { to_term(c.cond), list_term(c.body) } } end
            t.kids[#t.kids + 1] = v == nil and none() or { k = 'seq', kids = cs }
        elseif how == FIELDS then
            local fs = {}
            for i, x in ipairs(v or {}) do fs[i] = { k = 'field', kids = { to_term(x.key), to_term(x.val) } } end
            t.kids[#t.kids + 1] = v == nil and none() or { k = 'seq', kids = fs }
        else refuse('the role ' .. tostring(how)) end
    end
    return t
end
M.to_term = to_term

local of_term
local function of_list(t)
    if t.k == NONE then return nil end
    local l = {}
    for i, x in ipairs(t.kids) do l[i] = of_term(x) end
    return l
end
local function of_lits(t)
    if t.k == NONE then return nil end
    local l = {}
    for i, x in ipairs(t.kids) do l[i] = x.v end
    return l
end

--- an algebra term made by to_term (or rebuilt by an algebra operation) -> the IR node
function of_term(t)
    if t.k == NONE then return nil end
    local s = M.SCHEMA[t.k]
    if not s then refuse('no schema for the term kind ' .. tostring(t.k)) end
    local n, j = { op = t.k }, 0
    for _, f in ipairs(s) do
        local name, how = f[1], f[2]
        if how == CARRY then n[name] = t[name]
        else
            j = j + 1
            local kid = t.kids[j]
            if kid == nil then refuse(('a `%s` term lacks its kid %d (%s)'):format(t.k, j, name)) end
            if how == NODE then n[name] = of_term(kid)
            elseif how == LIST then n[name] = of_list(kid)
            elseif how == LIT then if kid.k ~= NONE then n[name] = kid.v end
            elseif how == LITS then n[name] = of_lits(kid)
            elseif how == CLAUSES then
                if kid.k ~= NONE then
                    local cs = {}
                    for i, c in ipairs(kid.kids) do cs[i] = { cond = of_term(c.kids[1]), body = of_list(c.kids[2]) } end
                    n[name] = cs
                end
            elseif how == FIELDS then
                if kid.k ~= NONE then
                    local fs = {}
                    for i, x in ipairs(kid.kids) do fs[i] = { key = of_term(x.kids[1]), val = of_term(x.kids[2]) } end
                    n[name] = fs
                end
            end
        end
    end
    return n
end
M.of_term = of_term

--- the term t with every `var` NAMED in `names` (a set, or a map from name) made a HOLE of that name — residual
--- placeholders become algebra holes, so filling them is A.instantiate / A.fill
function M.holes(t, names)
    if t.k == 'var' then
        local nm = t.kids[2]
        if nm and nm.k == 'lit' and names[nm.v] ~= nil then return { k = 'hole', h = nm.v } end
        return t
    end
    if not t.kids then return t end
    local kids = {}
    for i, c in ipairs(t.kids) do kids[i] = M.holes(c, names) end
    local n = {}
    for k, v in pairs(t) do n[k] = v end
    n.kids = kids
    return n
end

--- A RESIDUAL PROGRAM AS A TERM GRAPH (CART-1341 step 9): one recursion equation per residual function — `fun(params,
--- body)` — and every call of a residual function an EDGE to that function's equation instead of its generated name,
--- so recursion is a cycle and the program is the term-graph object of termgraph.lua (canonical form = Def. 4). Printed
--- by A.tg_show it is independent of the generated function names and their order: two residuals that differ only by
--- naming print the same. Variable names stay labels (lowering derives them from declaration ids — deterministic).
--- res: { funcs = { name -> { params, body } }, order, entry } -> term graph
function M.program_graph(res)
    local eqs, n, fun_rv = {}, 0, {}
    for i, name in ipairs(res.order) do fun_rv[name] = 'f' .. i end
    local emit
    function emit(t)
        n = n + 1
        local rv = 'x' .. n
        if t.k == 'lit' then
            eqs[rv] = { kind = 'node', sym = 'lit:' .. type(t.v) .. ':' .. tostring(t.v), args = {} }
            return rv
        end
        local args = {}
        if t.k == 'call' and t.kids[1].k == 'lit' and fun_rv[t.kids[1].v] then
            args[1] = fun_rv[t.kids[1].v] -- (the callee's equation: a residual call is an edge, recursion a cycle)
            args[2] = emit(t.kids[2])
        else
            for i, c in ipairs(t.kids or {}) do args[i] = emit(c) end
        end
        eqs[rv] = { kind = 'node', sym = t.k, args = args }
        return rv
    end
    for _, name in ipairs(res.order) do
        local f = res.funcs[name]
        local ps = {}
        for i, p in ipairs(f.params) do ps[i] = { k = 'lit', v = p } end
        eqs[fun_rv[name]] = { kind = 'node', sym = 'fun', args = { emit({ k = 'seq', kids = ps }), emit(M.block_term(f.body)) } }
    end
    return require('cartograph.algebra').load().tg_canon({ root = fun_rv[res.entry], eqs = eqs })
end

--- a statement list (a body) <-> a `seq` term
function M.block_term(b) return list_term(b) end
function M.of_block(t) return of_list(t) or {} end

return M
