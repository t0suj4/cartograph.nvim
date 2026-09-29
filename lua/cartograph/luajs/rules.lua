-- cartograph.luajs.rules — THE LOCAL HALF OF THE LUA→JS EMITTER AS DECLARED RULES (CART-1199 leaf 1).
--
-- A rule is a PAIR OF EXAMPLES: a Lua source with holes and the JS it becomes. Both sides are READ by the lossless
-- reader (cartograph.algebraread) into algebra terms; the left side is MATCHED against a node's term (algebra match),
-- the right side INSTANTIATED with the holes' emitted JS (algebra instantiate) and printed (cst_print). No construct in
-- this file is written as code: a rule is its two texts.
--
--   · EVERY IDENTIFIER on the left is a hole, named by its text; on the right, an identifier with a hole's name is its
--     site (`$add`, `undefined` are not hole names, so they stay). Every left hole must be used on the right — a rule
--     that drops an operand drops its side effects — and every right hole bound on the left; compile refuses otherwise.
--   · A HOLE'S MODE says how the emitter renders what it binds (`as`): `expr` (default: one value), `raw` (a call left
--     multi-valued), `name` (the identifier's own text as a JS string — the field of `a.f`, which is not a variable),
--     `block` (a child scope, the current loop/label context). A block hole is WRITTEN as a call statement of its name
--     (`do b() end`: a bare `b` is not a Lua statement) and compile lifts it to the `block` node that holds it.
--   · The left side is a statement when it reads as one inside `do … end`, else an expression (`return <lua>`).
--   · MATCHING IS MODULO LAYOUT: whitespace gaps and comments are dropped from both sides (`a+b`, `a --[[c]] + b`
--     and `a + b` are one term), as the hand emitter's field reads ignored them.
--
-- ★ WHAT IS NOT HERE, AND WHY (the CONTEXT half, cartograph.luajs): identifiers (scope), declarations and assignment
-- targets (scope), functions (scope, varargs, self), calls (method vs $call, value position), table constructors
-- (tblshape's representation), multi-value lists (value position), loops (fresh labels), if/elseif (a variable-length
-- alternative list), goto/break/labels (block structure), and numeric/string literals (their VALUE is Lua's own reading
-- of the text, not a template of it).
local M = {}

M.RULES = {
    -- literals whose JS is a constant
    { lua = 'nil', js = 'undefined' },
    { lua = 'true', js = 'true' },
    { lua = 'false', js = 'false' },
    { lua = '...', js = '$va[0]' },
    -- grouping truncates to one value (the hole's default mode)
    { lua = '(a)', js = '(a)' },
    -- indexing honours __index
    { lua = 'a.f', js = '$idx(a, f)', as = { f = 'name' } },
    { lua = 'a[k]', js = '$idx(a, k)' },
    -- arithmetic and concatenation honour their metamethods and Lua's coercions
    { lua = 'a + b', js = '$add(a, b)' },
    { lua = 'a - b', js = '$sub(a, b)' },
    { lua = 'a * b', js = '$mul(a, b)' },
    { lua = 'a / b', js = '$div(a, b)' },
    { lua = 'a % b', js = '$mod(a, b)' },
    { lua = 'a ^ b', js = '$pow(a, b)' },
    { lua = 'a .. b', js = '$cat(a, b)' },
    -- comparison (equality honours __eq: 5.1, both operands tables sharing one; $eq's first test is ===)
    { lua = 'a == b', js = '$eq(a, b)' },
    { lua = 'a ~= b', js = '!$eq(a, b)' },
    { lua = 'a < b', js = '$lt(a, b)' },
    { lua = 'a <= b', js = '$le(a, b)' },
    { lua = 'a > b', js = '$gt(a, b)' },
    { lua = 'a >= b', js = '$ge(a, b)' },
    -- the right operand of and/or is evaluated only when it decides
    { lua = 'a and b', js = '$and(a, () => b)' },
    { lua = 'a or b', js = '$or(a, () => b)' },
    { lua = 'not a', js = '!$t(a)' },
    { lua = '-a', js = '$neg(a)' },
    { lua = '#a', js = '$len(a)' },
    -- statements
    { lua = 'do b() end', js = '{\nb}', as = { b = 'block' } },
    { lua = 'do end', js = '{\n}' },
    -- NO values is an EMPTY list, not one nil (`select('#', f())` is 0, and `print(f())` prints an empty line)
    { lua = 'return', js = 'return $mv();' },
    { lua = 'return;', js = 'return $mv();' },
    -- `...` as the ONE returned value is ALL the varargs (the `...` rule above is its one-value reading; found by the
    -- bounded-exhaustive generator, CART-1206: `return ...` with ('x', nil) returned 1 value, Lua 2). Before `return a`:
    -- rules sharing a head are tried in order
    { lua = 'return ...', js = 'return $mv(...$va);' },
    { lua = 'return ...;', js = 'return $mv(...$va);' },
    { lua = 'return a', js = 'return a;', as = { a = 'raw' } },
    { lua = 'return a;', js = 'return a;', as = { a = 'raw' } },
}

local MODES = { expr = true, raw = true, name = true, block = true }

local A_ -- the algebra, loaded once
local function A()
    if not A_ then A_ = assert(require('cartograph.algebra').load()) end
    return A_
end

--- a term is LAYOUT when it is a whitespace gap or a comment
local function layout(t) return (t.k == 'lit' and type(t.v) == 'string' and t.v:match('^%s*$')) or t.k == 'comment' end

--- the term modulo layout. A named leaf (`(identifier "x")`, one lit kid) keeps its text whatever it is: only GAPS
--- between a node's kids are layout. `memo` maps a term to its projection (the emitter projects each subterm once).
local function project(t, memo)
    if memo and memo[t] then return memo[t] end
    local a = A()
    local p = t
    if t.kids and not (#t.kids == 1 and t.kids[1].k == 'lit') and t.k ~= 'hole' then
        local kids = {}
        for _, c in ipairs(t.kids) do if not layout(c) then kids[#kids + 1] = project(c, memo) end end
        p = a.rebuild(t, kids)
    end
    if memo then memo[t] = p end
    return p
end
M.project = project

--- the index key of a (projected) term: its kind and its own literal kids, in order
local function head(t)
    local parts = { t.k }
    for _, c in ipairs(t.kids or {}) do if c.k == 'lit' then parts[#parts + 1] = tostring(c.v) end end
    return table.concat(parts, '\31')
end
M.head = head

local function name_of(t) -- an identifier term's text
    return t.k == 'identifier' and t.kids and t.kids[1] and t.kids[1].v or nil
end

--- compile one rule -> { lhs = template, rhs = template, key, as, lua, js } | error naming the rule
local function compile(rule)
    local a, R = A(), require 'cartograph.algebraread'
    local function bad(why) error(('luajs rule `%s` -> `%s`: %s'):format(rule.lua, rule.js, why), 0) end
    for h, m in pairs(rule.as or {}) do if not MODES[m] then bad(('hole %s: unknown mode %s'):format(h, tostring(m))) end end
    -- the left side: ONE statement (read INSIDE `do … end`), else ONE expression (read as `return <lua>`). Both
    -- wrappers are measured choices: at a chunk's start `#a` reads as a shebang line, and tree-sitter-lua reads
    -- `return return` CLEANLY, the second `return` an identifier — so the expression reading cannot go first
    local lhs
    local chunk = R.read('do ' .. rule.lua .. ' end', 'lua')
    local ds = chunk and project(chunk).kids[1]
    local body = ds and ds.k == 'do_statement' and ds.kids[2]
    if body and body.k == 'block' and #body.kids == 1 and #ds.kids == 3 then lhs = body.kids[1] end
    if not lhs then
        local ret = R.read('return ' .. rule.lua, 'lua')
        local rs = ret and project(ret).kids[1]
        local el = rs and rs.kids and rs.kids[2]
        if not (el and el.k == 'expression_list' and #el.kids == 1 and #rs.kids == 2) then
            bad('the Lua side reads neither as ONE statement nor as ONE expression')
        end
        lhs = el.kids[1]
    end
    local as = rule.as or {}
    local holes = {}
    local function holed(t)
        -- a block hole: the `block` whose only statement is the call `h()`
        if t.k == 'block' and #t.kids == 1 and t.kids[1].k == 'function_call' then
            local h = name_of(t.kids[1].kids[1])
            if h and as[h] == 'block' then holes[h] = true; return a.hole(h) end
        end
        local n = name_of(t)
        if n then holes[n] = true; return a.hole(n) end
        if t.k == 'lit' or not t.kids then return t end
        local kids = {}
        for i, c in ipairs(t.kids) do kids[i] = holed(c) end
        return a.rebuild(t, kids)
    end
    local L = holed(lhs)
    for h, m in pairs(as) do if not holes[h] then bad(('hole %s (%s) is not on the Lua side'):format(h, m)) end end
    -- the right side: the whole JS program, its hole-named identifiers made sites
    local prog, why = R.read(rule.js, 'javascript')
    if not prog then bad('the JS side does not read: ' .. tostring(why)) end
    local used = {}
    local function sites(t)
        local n = name_of(t)
        if n and holes[n] then used[n] = true; return a.hole(n) end
        if t.k == 'lit' or not t.kids then return t end
        local kids = {}
        for i, c in ipairs(t.kids) do kids[i] = sites(c) end
        return a.rebuild(t, kids)
    end
    local Rt = sites(prog)
    for h in pairs(holes) do if not used[h] then bad(('hole %s is dropped: the JS side never uses it'):format(h)) end end
    return { lhs = a.template(L), rhs = a.template(Rt), key = head(lhs), as = as, lua = rule.lua, js = rule.js }
end

local compiled, index -- built once, on first use
local function load()
    if compiled then return end
    -- ATOMIC: a rule that fails to compile raises, and must not leave a PARTIAL table behind for the next caller to
    -- run with (measured: one crash, then every later file emitted without the rules after the bad one)
    local cs, ix = {}, {}
    for i, r in ipairs(M.RULES) do
        local c = compile(r)
        c.i = i
        cs[i] = c
        ix[c.key] = ix[c.key] or {}
        table.insert(ix[c.key], c)
    end
    compiled, index = cs, ix
end

M.hits = {} -- rule index -> times it fired (the dead-rule instrument: tools/luajs.lua reports a rule that never fires)

M.compile = compile

--- the rule a (projected) term matches -> compiled rule, { hole -> bound projected subterm } | nil
function M.match(p)
    load()
    local cands = index[head(p)]
    if not cands then return nil end
    local a = A()
    for _, c in ipairs(cands) do
        local m = a.match(c.lhs, p)
        if m.ok then
            M.hits[c.i] = (M.hits[c.i] or 0) + 1
            return c, m.values
        end
    end
    return nil
end

--- the JS a rule produces, its holes filled with `js` (hole -> JS text)
function M.render(c, js)
    local a = A()
    local V = {}
    for h, s in pairs(js) do V[h] = a.lit(s) end
    local inst = a.instantiate(c.rhs, V)
    if not inst.ok then error(('luajs rule `%s`: instantiation failed'):format(c.lua), 0) end
    return a.cst_print(inst.term)
end

--- every compiled rule (compiling them all: a rule that does not compile fails here, by name)
function M.all()
    load()
    return compiled
end

return M
