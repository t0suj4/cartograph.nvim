-- cartograph.mix — an OFFLINE PARTIAL EVALUATOR for the Lua subset S (CART-1278, S2 of the specializer arc CART-1276).
-- Given a program (top-level functions), an entry function, a DIVISION of its parameters (S = static, known now; D =
-- dynamic, known later) and the static values, mix produces a RESIDUAL program over the dynamic parameters only, with
-- mix(f, s)(d) == f(s, d). Classic offline mix (Jones, Gomard, Sestoft): a binding-time analysis first, then a
-- specializer driven by it.
--   LOWER    an algebra term (algebraread, lossless CST) -> a small IR; every variable resolved to its declaration (an id)
--   BTA      per (function, division), monovariant inside the function: a value is S when every input is S; a variable
--            assigned under DYNAMIC control is D (congruence); a loop whose bounds are S under S control unrolls
--   SPEC     static parts computed (static calls run by this module's own interpreter), dynamic parts residualized;
--            a call with a dynamic argument is a PROGRAM POINT (function, division, static values) — memoized into one
--            residual function — or UNFOLDED in place when its residual body is a single `return e`
--   PRINT    residual IR -> Lua text (the caller re-reads it through algebraread and loads it)
-- RUNG 1 is FIRST-ORDER: closures, varargs, while, method calls and static tables reaching dynamic code are REFUSED by
-- name (error { refusal = … }), never residualized silently. ⚠ mix is written INSIDE S (no while / repeat / goto /
-- varargs / metatables / load): S4–S5 self-apply it — tests/mix_spec.lua fences that.
local M = {}

local function refuse(why) error({ refusal = why }, 0) end
M.refuse = refuse

-- ── LOWER: algebra term -> IR ──────────────────────────────────────────────────────────────────────────────────────
local function named(t)
    local out = {}
    for _, c in ipairs(t.kids or {}) do if c.k ~= 'lit' then out[#out + 1] = c end end
    return out
end
local function text(t)
    if t.k == 'lit' then return t.v end
    local parts = {}
    for _, c in ipairs(t.kids or {}) do parts[#parts + 1] = text(c) end
    return table.concat(parts)
end
-- the first non-whitespace literal token among a node's direct kids (an operator, a keyword)
local function token(t, skip)
    local seen = 0
    for _, c in ipairs(t.kids or {}) do
        if c.k == 'lit' and c.v:gsub('%s', '') ~= '' then
            seen = seen + 1
            if seen > (skip or 0) then return c.v end
        end
    end
    return nil
end
M._text = text

local lower_expr, lower_block

-- scopes: a chain of { names = { name -> id }, up }
local function lookup(scope, name)
    local s = scope
    for _ = 1, 10000 do
        if not s then return nil end
        if s.names[name] then return s.names[name] end
        s = s.up
    end
    return nil
end

local function string_value(t)
    local raw = text(t)
    local q = raw:sub(1, 1)
    if q ~= '"' and q ~= "'" then refuse('a long-bracket string literal (rung 1 reads quoted strings only)') end
    local body = raw:sub(2, -2)
    if body:find('\\', 1, true) then refuse('an escape sequence in a string literal (rung 1)') end
    return body
end

function lower_expr(t, cx, scope)
    local k = t.k
    if k == 'number' then return { op = 'num', v = tonumber(text(t)) } end
    if k == 'string' then return { op = 'str', v = string_value(t) } end
    if k == 'true' then return { op = 'bool', v = true } end
    if k == 'false' then return { op = 'bool', v = false } end
    if k == 'nil' then return { op = 'nil' } end
    if k == 'identifier' then
        local name = text(t)
        local id = lookup(scope, name)
        if id then return { op = 'var', id = id, name = name } end
        if cx.funcs[name] then return { op = 'fn', name = name } end
        return { op = 'global', name = name }
    end
    if k == 'parenthesized_expression' then return lower_expr(named(t)[1], cx, scope) end
    if k == 'binary_expression' then
        local n = named(t)
        return { op = 'bin', o = token(t), l = lower_expr(n[1], cx, scope), r = lower_expr(n[2], cx, scope) }
    end
    if k == 'unary_expression' then
        return { op = 'un', o = token(t), e = lower_expr(named(t)[1], cx, scope) }
    end
    if k == 'bracket_index_expression' then
        local n = named(t)
        return { op = 'index', obj = lower_expr(n[1], cx, scope), key = lower_expr(n[2], cx, scope) }
    end
    if k == 'dot_index_expression' then
        local n = named(t)
        local base = lower_expr(n[1], cx, scope)
        if base.op == 'global' then return { op = 'global', name = base.name .. '.' .. text(n[2]) } end
        return { op = 'index', obj = base, key = { op = 'str', v = text(n[2]) } }
    end
    if k == 'function_call' then
        local n = named(t)
        local callee = n[1]
        if callee.k == 'method_index_expression' then refuse('a method call `' .. text(callee) .. '` (rung 1)') end
        local args = {}
        for _, a in ipairs(named(n[#n])) do args[#args + 1] = lower_expr(a, cx, scope) end
        local f = lower_expr(callee, cx, scope)
        if f.op == 'fn' then return { op = 'call', fn = f.name, args = args } end
        if f.op == 'global' then return { op = 'prim', name = f.name, args = args } end
        refuse('a call through a value `' .. text(callee) .. '` (first-class functions are rung 2)')
    end
    if k == 'table_constructor' then
        local fields, pos = {}, 0
        for _, f in ipairs(named(t)) do
            local fn = named(f)
            if #fn == 1 then
                pos = pos + 1
                fields[#fields + 1] = { key = { op = 'num', v = pos }, val = lower_expr(fn[1], cx, scope) }
            elseif token(f) == '[' then
                fields[#fields + 1] = { key = lower_expr(fn[1], cx, scope), val = lower_expr(fn[2], cx, scope) }
            else
                fields[#fields + 1] = { key = { op = 'str', v = text(fn[1]) }, val = lower_expr(fn[2], cx, scope) }
            end
        end
        return { op = 'table', fields = fields }
    end
    if k == 'function_definition' then refuse('a function expression (closures are rung 2)') end
    if k == 'vararg_expression' then refuse('varargs (not in S)') end
    refuse('the expression kind ' .. k)
end

local function declare(cx, scope, name)
    cx.nid = cx.nid + 1
    local id = cx.nid
    scope.names[name] = id
    cx.names[id] = name
    return id
end

local function lower_stmt(t, cx, scope, out)
    local k = t.k
    if k == 'variable_declaration' then
        local asg = named(t)[1]
        if asg.k ~= 'assignment_statement' then -- `local x` with no value
            for _, nm in ipairs(named(asg)) do out[#out + 1] = { op = 'local', id = declare(cx, scope, text(nm)), e = { op = 'nil' } } end
            return
        end
        local parts = named(asg)
        local vars, exprs = named(parts[1]), named(parts[2])
        if #vars ~= #exprs then refuse('a declaration with ' .. #vars .. ' names and ' .. #exprs .. ' values (rung 1: one each)') end
        local es = {}
        for i, e in ipairs(exprs) do es[i] = lower_expr(e, cx, scope) end -- (values first: `local x = x` reads the outer x)
        for i, v in ipairs(vars) do out[#out + 1] = { op = 'local', id = declare(cx, scope, text(v)), e = es[i] } end
        return
    end
    if k == 'assignment_statement' then
        local parts = named(t)
        local vars, exprs = named(parts[1]), named(parts[2])
        if #vars ~= 1 or #exprs ~= 1 then refuse('a multiple assignment (rung 1)') end
        local target = lower_expr(vars[1], cx, scope)
        if target.op ~= 'var' and target.op ~= 'index' then refuse('an assignment to ' .. text(vars[1])) end
        out[#out + 1] = { op = 'assign', target = target, e = lower_expr(exprs[1], cx, scope) }
        return
    end
    if k == 'function_call' then
        out[#out + 1] = { op = 'callstmt', e = lower_expr(t, cx, scope) }
        return
    end
    if k == 'return_statement' then
        local el = named(t)[1]
        local es = el and named(el) or {}
        if #es > 1 then refuse('a return of several values (rung 1)') end
        out[#out + 1] = { op = 'ret', e = es[1] and lower_expr(es[1], cx, scope) or { op = 'nil' } }
        return
    end
    if k == 'if_statement' then
        local n = named(t)
        local clauses, els = {}, nil
        clauses[1] = { cond = lower_expr(n[1], cx, scope), body = lower_block(n[2], cx, scope) }
        for i = 3, #n do
            local c = n[i]
            if c.k == 'elseif_statement' then
                local cn = named(c)
                clauses[#clauses + 1] = { cond = lower_expr(cn[1], cx, scope), body = lower_block(cn[2], cx, scope) }
            elseif c.k == 'else_statement' then
                els = lower_block(named(c)[1], cx, scope)
            end
        end
        out[#out + 1] = { op = 'if', clauses = clauses, els = els or {} }
        return
    end
    if k == 'for_statement' then
        local n = named(t)
        local clause, body = n[1], n[2]
        local inner = { names = {}, up = scope }
        if clause.k == 'for_numeric_clause' then
            local cn = named(clause)
            local from, to = lower_expr(cn[2], cx, scope), lower_expr(cn[3], cx, scope)
            local step = cn[4] and lower_expr(cn[4], cx, scope) or { op = 'num', v = 1 }
            local id = declare(cx, inner, text(cn[1]))
            out[#out + 1] = { op = 'fornum', id = id, from = from, to = to, step = step, body = lower_block(body, cx, inner) }
            return
        end
        -- generic: `for k, v in ipairs(e)` / `pairs(e)` only
        local cn = named(clause)
        local vl = cn[1].k == 'variable_list' and named(cn[1]) or { cn[1] }
        local el = cn[#cn]
        local iter = el.k == 'expression_list' and named(el)[1] or el
        local it = lower_expr(iter, cx, scope)
        if it.op ~= 'prim' or (it.name ~= 'ipairs' and it.name ~= 'pairs') or #it.args ~= 1 then
            refuse('a generic for over ' .. text(iter) .. ' (rung 1: ipairs / pairs of one table)')
        end
        local kid = declare(cx, inner, text(vl[1]))
        local vid = vl[2] and declare(cx, inner, text(vl[2])) or nil
        out[#out + 1] = { op = 'forin', kind = it.name, e = it.args[1], kid = kid, vid = vid, body = lower_block(body, cx, inner) }
        return
    end
    if k == 'do_statement' then
        local b = named(t)[1]
        out[#out + 1] = { op = 'do', body = b and lower_block(b, cx, { names = {}, up = scope }) or {} }
        return
    end
    if k == 'comment' then return end
    if k == 'while_statement' or k == 'repeat_statement' or k == 'goto_statement' or k == 'label_statement' then
        refuse('`' .. k .. '` (not in S)')
    end
    if k == 'break_statement' then refuse('break (rung 1)') end
    if k == 'function_declaration' then refuse('a nested function declaration (closures are rung 2)') end
    refuse('the statement kind ' .. k)
end

function lower_block(t, cx, scope)
    local out = {}
    local inner = { names = {}, up = scope }
    for _, s in ipairs(named(t)) do lower_stmt(s, cx, inner, out) end
    return out
end

--- a chunk of top-level function declarations -> program { funcs = { name -> { name, params = { id … }, pnames, body } },
--- names = { id -> source name } }
function M.lower(term)
    local cx = { funcs = {}, names = {}, nid = 0 }
    local decls = {}
    for _, d in ipairs(named(term)) do
        if d.k == 'function_declaration' then
            local n = named(d)
            local name = text(n[1])
            cx.funcs[name] = true
            decls[#decls + 1] = { name = name, params = n[2], body = n[3] }
        elseif d.k == 'variable_declaration' and named(d)[1] and named(d)[1].k ~= 'assignment_statement' then
            -- (a forward declaration `local f, g` — the residual printer's own)
        elseif d.k ~= 'return_statement' and d.k ~= 'comment' then
            refuse('top-level ' .. d.k .. ' (a program is top-level function declarations)')
        end
    end
    for _, d in ipairs(decls) do
        local scope = { names = {}, up = nil }
        local params, pnames = {}, {}
        for _, p in ipairs(named(d.params)) do
            if p.k ~= 'identifier' then refuse('a parameter list with ' .. p.k) end
            params[#params + 1] = declare(cx, scope, text(p))
            pnames[#pnames + 1] = text(p)
        end
        cx.funcs[d.name] = { name = d.name, params = params, pnames = pnames, body = d.body and lower_block(d.body, cx, scope) or {} }
    end
    return { funcs = cx.funcs, names = cx.names }
end

-- ── the INTERPRETER (static evaluation, and the step counter of the payoff gate) ────────────────────────────────────
local PRIMS = {
    tostring = tostring, tonumber = tonumber, type = type,
    ['math.floor'] = math.floor, ['math.max'] = math.max, ['math.min'] = math.min, ['math.abs'] = math.abs,
    ['string.format'] = string.format, ['string.sub'] = string.sub, ['string.len'] = string.len, ['string.rep'] = string.rep,
    ['table.insert'] = table.insert, ['table.concat'] = table.concat,
}
M.PRIMS = PRIMS

local function arith(o, a, b)
    if o == '+' then return a + b elseif o == '-' then return a - b elseif o == '*' then return a * b
    elseif o == '/' then return a / b elseif o == '%' then return a % b elseif o == '^' then return a ^ b
    elseif o == '..' then return a .. b
    elseif o == '==' then return a == b elseif o == '~=' then return a ~= b
    elseif o == '<' then return a < b elseif o == '<=' then return a <= b
    elseif o == '>' then return a > b elseif o == '>=' then return a >= b end
    refuse('the operator ' .. tostring(o))
end
M._arith = arith

-- an evaluator over prog: { eval(e, env), exec(stmts, env) -> done, value, R = { steps, budget } }
function M.evaluator(prog, budget)
    local R = { steps = 0, budget = budget or 1e7 }
    local exec_block
    local function eval(e, env)
        R.steps = R.steps + 1
        if R.steps > R.budget then refuse('the interpreter budget (' .. R.budget .. ' steps)') end
        local op = e.op
        if op == 'num' or op == 'str' or op == 'bool' then return e.v end
        if op == 'nil' then return nil end
        if op == 'var' then return env[e.id] end
        if op == 'bin' then
            if e.o == 'and' then local a = eval(e.l, env); if not a then return a end return eval(e.r, env) end
            if e.o == 'or' then local a = eval(e.l, env); if a then return a end return eval(e.r, env) end
            return arith(e.o, eval(e.l, env), eval(e.r, env))
        end
        if op == 'un' then
            local v = eval(e.e, env)
            if e.o == 'not' then return not v elseif e.o == '-' then return -v elseif e.o == '#' then return #v end
            refuse('the unary operator ' .. tostring(e.o))
        end
        if op == 'index' then return eval(e.obj, env)[eval(e.key, env)] end
        if op == 'table' then
            local t = {}
            for _, f in ipairs(e.fields) do t[eval(f.key, env)] = eval(f.val, env) end
            return t
        end
        if op == 'call' then
            local f = prog.funcs[e.fn]
            local fenv = {}
            for i, id in ipairs(f.params) do fenv[id] = eval(e.args[i], env) end
            local _, v = exec_block(f.body, fenv)
            return v
        end
        if op == 'prim' then
            local p = PRIMS[e.name]
            if not p then refuse('the primitive ' .. e.name .. ' (not in the table)') end
            local a = {}
            for i, x in ipairs(e.args) do a[i] = eval(x, env) end
            return p(unpack(a, 1, #e.args))
        end
        if op == 'global' then refuse('the global ' .. e.name) end
        refuse('the IR op ' .. tostring(op))
    end
    -- exec_block -> done (a return ran), value
    function exec_block(stmts, env)
        for _, s in ipairs(stmts) do
            R.steps = R.steps + 1
            local op = s.op
            if op == 'local' then env[s.id] = eval(s.e, env)
            elseif op == 'assign' then
                if s.target.op == 'var' then env[s.target.id] = eval(s.e, env)
                else eval(s.target.obj, env)[eval(s.target.key, env)] = eval(s.e, env) end
            elseif op == 'callstmt' then eval(s.e, env)
            elseif op == 'ret' then return true, eval(s.e, env)
            elseif op == 'if' then
                local taken = false
                for _, c in ipairs(s.clauses) do
                    if not taken and eval(c.cond, env) then
                        taken = true
                        local done, v = exec_block(c.body, env)
                        if done then return true, v end
                    end
                end
                if not taken then
                    local done, v = exec_block(s.els, env)
                    if done then return true, v end
                end
            elseif op == 'fornum' then
                for i = eval(s.from, env), eval(s.to, env), eval(s.step, env) do
                    env[s.id] = i
                    local done, v = exec_block(s.body, env)
                    if done then return true, v end
                end
            elseif op == 'forin' then
                local it = s.kind == 'ipairs' and ipairs or pairs
                for k, v in it(eval(s.e, env)) do
                    env[s.kid] = k
                    if s.vid then env[s.vid] = v end
                    local done, rv = exec_block(s.body, env)
                    if done then return true, rv end
                end
            elseif op == 'do' then
                local done, v = exec_block(s.body, env)
                if done then return true, v end
            else refuse('the IR statement ' .. tostring(op)) end
        end
        return false, nil
    end
    return { eval = eval, exec = exec_block, R = R }
end

-- run(prog, fname, args, budget) -> value, steps. The budget refuses by name when exhausted.
function M.run(prog, fname, args, budget)
    local ev = M.evaluator(prog, budget)
    local f = prog.funcs[fname]
    if not f then refuse('no function ' .. tostring(fname)) end
    local env = {}
    for i, id in ipairs(f.params) do env[id] = args[i] end
    local _, v = ev.exec(f.body, env)
    return v, ev.R.steps
end

-- ── BTA: per (function, division), monovariant inside it ──────────────────────────────────────────────────────────
local S, D = 'S', 'D'
local function join(a, b) if a == D or b == D then return D end return S end

-- the binding time of an expression under bt (id -> S/D); a call is S when every argument is (it is then RUN)
local function bt_expr(e, bt)
    local op = e.op
    if op == 'num' or op == 'str' or op == 'bool' or op == 'nil' then return S end
    if op == 'var' then return bt[e.id] or S end
    if op == 'bin' then return join(bt_expr(e.l, bt), bt_expr(e.r, bt)) end
    if op == 'un' then return bt_expr(e.e, bt) end
    if op == 'index' then return join(bt_expr(e.obj, bt), bt_expr(e.key, bt)) end
    if op == 'table' then
        local r = S
        for _, f in ipairs(e.fields) do r = join(r, join(bt_expr(f.key, bt), bt_expr(f.val, bt))) end
        return r
    end
    if op == 'call' or op == 'prim' then
        local r = S
        for _, a in ipairs(e.args) do r = join(r, bt_expr(a, bt)) end
        if op == 'prim' and e.name == 'table.insert' then return D end -- (a mutation: never computed early)
        return r
    end
    return D
end
M._bt_expr = bt_expr

local function bt_block(stmts, bt, ctrl)
    local changed = false
    local function set(id, v)
        local old = bt[id]
        local new = old and join(old, v) or v
        if new ~= old then bt[id] = new; changed = true end
    end
    for _, s in ipairs(stmts) do
        local op = s.op
        if op == 'local' then set(s.id, bt_expr(s.e, bt))
        elseif op == 'assign' then
            local v = join(ctrl, bt_expr(s.e, bt)) -- CONGRUENCE: assigned under dynamic control -> D
            if s.target.op == 'var' then set(s.target.id, v)
            else
                -- a store into a table: the table itself becomes dynamic (rung 1 never mutates a static table)
                local root = s.target.obj
                if root.op == 'var' then set(root.id, D) end
            end
        elseif op == 'if' then
            local c = ctrl
            for _, cl in ipairs(s.clauses) do
                c = join(c, bt_expr(cl.cond, bt))
                if bt_block(cl.body, bt, c) then changed = true end
            end
            if bt_block(s.els, bt, c) then changed = true end
        elseif op == 'fornum' then
            local b = join(ctrl, join(bt_expr(s.from, bt), join(bt_expr(s.to, bt), bt_expr(s.step, bt))))
            set(s.id, b)
            if bt_block(s.body, bt, b) then changed = true end
        elseif op == 'forin' then
            local b = join(ctrl, bt_expr(s.e, bt))
            set(s.kid, b)
            if s.vid then set(s.vid, b) end
            if bt_block(s.body, bt, b) then changed = true end
        elseif op == 'do' then
            if bt_block(s.body, bt, ctrl) then changed = true end
        end
    end
    return changed
end

--- the binding times of one function under a division ({ 'S' | 'D' } per parameter) -> { [id] = S | D }
function M.bta(prog, fname, division)
    local f = prog.funcs[fname]
    local bt = {}
    for i, id in ipairs(f.params) do bt[id] = division[i] end
    for _ = 1, 1000 do
        if not bt_block(f.body, bt, S) then return bt end
    end
    refuse('the binding-time analysis did not reach a fixpoint')
end

-- ── SPEC: the specializer ──────────────────────────────────────────────────────────────────────────────────────────
local function serialize(v, depth)
    local ty = type(v)
    if ty == 'number' or ty == 'boolean' or ty == 'nil' then return tostring(v) end
    if ty == 'string' then return string.format('%q', v) end
    if ty == 'table' then
        if (depth or 0) > 20 then refuse('a static value nested deeper than 20') end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function (a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = serialize(k, (depth or 0) + 1) .. '=' .. serialize(v[k], (depth or 0) + 1) end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    refuse('a static value of type ' .. ty)
end
M._serialize = serialize

-- a static value as residual IR (lifting)
local function lift(v)
    local ty = type(v)
    if ty == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then refuse('lifting a non-finite number') end
        return { op = 'num', v = v }
    end
    if ty == 'string' then return { op = 'str', v = v } end
    if ty == 'boolean' then return { op = 'bool', v = v } end
    if ty == 'nil' then return { op = 'nil' } end
    refuse('a static ' .. ty .. ' reaches dynamic code (lifting tables is not in rung 1)')
end

--- specialize prog's `fname` to the static values of the S parameters -> residual program { funcs = { name -> { name,
--- params = { rname … }, body } }, entry }, stats. opts: budget (unfold steps), name (the entry's residual name)
function M.specialize(prog, fname, division, statics, opts)
    opts = opts or {}
    local budget = opts.budget or 100000
    local used = 0
    local res = { funcs = {}, order = {} }
    local memo, btcache = {}, {}
    local counter = 0
    local function spend(n)
        used = used + (n or 1)
        if used > budget then refuse('the unfold budget (' .. budget .. ')') end
    end
    local function bt_of(f, division)
        local key = f .. ':' .. table.concat(division, '')
        if not btcache[key] then btcache[key] = M.bta(prog, f, division) end
        return btcache[key]
    end
    local function rname(id) return prog.names[id] .. '_' .. id end
    -- STATIC computation: the interpreter over the ORIGINAL program (a static call runs the function itself)
    local ev = M.evaluator(prog, opts.static_budget or 1e7)
    local function sval(e, env) return ev.eval(e, env) end
    local unfolding = {} -- program points being unfolded right now: a recursive one becomes a program point instead
    -- NESTING: every unfold and program point nests a specialization (and unfold a pcall — LuaJIT allows ~200 nested C
    -- calls); past opts.depth the specialization REFUSES by name instead of overflowing the C stack
    local depth, maxdepth = 0, opts.depth or 120
    local function enter(what)
        depth = depth + 1
        if depth > maxdepth then refuse('the specialization depth (' .. maxdepth .. ' nested ' .. what .. 's: a static value that never repeats?)') end
    end

    local spec_fn -- (fname, division, svals) -> residual function name
    local spec_block

    -- UNFOLD: f's body specialized to (division, svals) in a fresh environment -> its single returned expression | nil
    -- (a point already being unfolded is not unfolded again: recursion under dynamic control becomes a program point)
    local function unfold(f, division, svals)
        local key = f.name .. ':' .. table.concat(division, '') .. ':' .. serialize(svals)
        if unfolding[key] then return nil end
        unfolding[key] = true
        enter('unfold')
        local bt = bt_of(f.name, division)
        local env = {}
        for i, id in ipairs(f.params) do if division[i] == S then env[id] = svals[i] end end
        local ok, body = pcall(spec_block, f.body, bt, env)
        unfolding[key] = nil
        depth = depth - 1
        if not ok then
            if type(body) == 'table' and body.refusal and (body.refusal:find('budget', 1, true) or body.refusal:find('depth', 1, true)) then error(body, 0) end
            if type(body) ~= 'table' then error(body, 0) end
            return nil
        end
        if #body == 1 and body[1].op == 'ret' then return body[1].e end
        return nil
    end

    -- a residual expression for e under (bt, env); a static e is computed and lifted
    local function rexpr(e, bt, env)
        spend()
        if bt_expr(e, bt) == S then
            local v = sval(e, env)
            return lift(v)
        end
        local op = e.op
        if op == 'var' then return { op = 'var', name = rname(e.id) } end
        if op == 'bin' then return { op = 'bin', o = e.o, l = rexpr(e.l, bt, env), r = rexpr(e.r, bt, env) } end
        if op == 'un' then return { op = 'un', o = e.o, e = rexpr(e.e, bt, env) } end
        if op == 'index' then return { op = 'index', obj = rexpr(e.obj, bt, env), key = rexpr(e.key, bt, env) } end
        if op == 'table' then
            local fields = {}
            for i, f in ipairs(e.fields) do fields[i] = { key = rexpr(f.key, bt, env), val = rexpr(f.val, bt, env) } end
            return { op = 'table', fields = fields }
        end
        if op == 'prim' then
            local args = {}
            for i, a in ipairs(e.args) do args[i] = rexpr(a, bt, env) end
            return { op = 'prim', name = e.name, args = args }
        end
        if op == 'call' then
            local f = prog.funcs[e.fn]
            local division, svals, dargs = {}, {}, {}
            for i, a in ipairs(e.args) do
                if bt_expr(a, bt) == S then
                    division[i] = S
                    svals[i] = sval(a, env)
                else
                    division[i] = D
                    dargs[#dargs + 1] = rexpr(a, bt, env)
                end
            end
            for i = #e.args + 1, #f.params do division[i] = S end -- (a missing argument is a static nil)
            -- UNFOLD when the callee's residual body is one `return e`: substitute its dynamic parameters
            local inl = unfold(f, division, svals)
            if inl then
                local subst, uses = {}, {}
                local di = 0
                for i, id in ipairs(f.params) do
                    if division[i] == D then di = di + 1; subst[rname(id)] = dargs[di] end
                end
                M.count_uses(inl, uses)
                local ok = true
                for nm, a in pairs(subst) do
                    if (uses[nm] or 0) > 1 and a.op ~= 'var' and a.op ~= 'num' and a.op ~= 'str' and a.op ~= 'bool' and a.op ~= 'nil' then ok = false end
                end
                if ok then return M.substitute(inl, subst) end
            end
            return { op = 'call', fn = spec_fn(e.fn, division, svals), args = dargs }
        end
        refuse('residualizing the IR op ' .. tostring(op))
    end

    -- residual statements for stmts; returns rstmts, done (a return reached under static control)
    function spec_block(stmts, bt, env)
        local out = {}
        for _, s in ipairs(stmts) do
            spend()
            local op = s.op
            if op == 'local' then
                if bt[s.id] == S then env[s.id] = sval(s.e, env)
                else out[#out + 1] = { op = 'local', name = rname(s.id), e = rexpr(s.e, bt, env) } end
            elseif op == 'assign' then
                if s.target.op == 'var' then
                    if bt[s.target.id] == S then env[s.target.id] = sval(s.e, env)
                    else out[#out + 1] = { op = 'assign', target = { op = 'var', name = rname(s.target.id) }, e = rexpr(s.e, bt, env) } end
                else
                    out[#out + 1] = { op = 'assign', target = rexpr(s.target, bt, env), e = rexpr(s.e, bt, env) }
                end
            elseif op == 'callstmt' then
                out[#out + 1] = { op = 'callstmt', e = rexpr(s.e, bt, env) }
            elseif op == 'ret' then
                out[#out + 1] = { op = 'ret', e = rexpr(s.e, bt, env) }
                return out, true
            elseif op == 'if' then
                -- the static prefix of the clauses decides; from the first dynamic condition on, a residual if
                local rclauses, rels, decided = {}, nil, false
                for _, c in ipairs(s.clauses) do
                    if not decided then
                        if #rclauses == 0 and bt_expr(c.cond, bt) == S then
                            if sval(c.cond, env) then
                                local body, done = spec_block(c.body, bt, env)
                                for _, x in ipairs(body) do out[#out + 1] = x end
                                if done then return out, true end
                                decided = true
                            end
                        else
                            local body = spec_block(c.body, bt, env)
                            rclauses[#rclauses + 1] = { cond = rexpr(c.cond, bt, env), body = body }
                        end
                    end
                end
                if not decided then
                    if #rclauses == 0 then
                        local body, done = spec_block(s.els, bt, env)
                        for _, x in ipairs(body) do out[#out + 1] = x end
                        if done then return out, true end
                    else
                        rels = spec_block(s.els, bt, env)
                        out[#out + 1] = { op = 'if', clauses = rclauses, els = rels }
                    end
                end
            elseif op == 'fornum' then
                if bt[s.id] == S then -- UNROLL
                    for i = sval(s.from, env), sval(s.to, env), sval(s.step, env) do
                        spend(10)
                        env[s.id] = i
                        local body, done = spec_block(s.body, bt, env)
                        if #body > 0 then out[#out + 1] = { op = 'do', body = body } end
                        if done then return out, true end
                    end
                else
                    out[#out + 1] = { op = 'fornum', name = rname(s.id), from = rexpr(s.from, bt, env), to = rexpr(s.to, bt, env),
                        step = rexpr(s.step, bt, env), body = (spec_block(s.body, bt, env)) }
                end
            elseif op == 'forin' then
                if bt[s.kid] == S then -- UNROLL (pairs: in the order this host iterates — order-sensitive programs are not gated)
                    local it = s.kind == 'ipairs' and ipairs or pairs
                    for k, v in it(sval(s.e, env)) do
                        spend(10)
                        env[s.kid] = k
                        if s.vid then env[s.vid] = v end
                        local body, done = spec_block(s.body, bt, env)
                        if #body > 0 then out[#out + 1] = { op = 'do', body = body } end
                        if done then return out, true end
                    end
                else
                    out[#out + 1] = { op = 'forin', kind = s.kind, e = rexpr(s.e, bt, env), kname = rname(s.kid),
                        vname = s.vid and rname(s.vid) or nil, body = (spec_block(s.body, bt, env)) }
                end
            elseif op == 'do' then
                local body, done = spec_block(s.body, bt, env)
                if #body > 0 then out[#out + 1] = { op = 'do', body = body } end
                if done then return out, true end
            else refuse('specializing the IR statement ' .. tostring(op)) end
        end
        return out, false
    end

    function spec_fn(f, division, svals)
        local key = f .. ':' .. table.concat(division, '') .. ':' .. serialize(svals)
        if memo[key] then return memo[key] end
        counter = counter + 1
        local name = (counter == 1 and opts.name) or (f .. '_' .. counter)
        memo[key] = name
        local fn = prog.funcs[f]
        local bt = bt_of(f, division)
        local env, params = {}, {}
        for i, id in ipairs(fn.params) do
            if division[i] == S then env[id] = svals[i] else params[#params + 1] = rname(id) end
        end
        local rf = { name = name, params = params, body = nil }
        res.funcs[name] = rf
        res.order[#res.order + 1] = name
        enter('program point')
        rf.body = (spec_block(fn.body, bt, env))
        depth = depth - 1
        return name
    end

    local entry = spec_fn(fname, division, statics)
    res.entry = entry
    return res, { unfold_steps = used, functions = #res.order }
end


--- count the uses of each residual variable name in a residual expression
function M.count_uses(e, uses)
    local op = e.op
    if op == 'var' then uses[e.name] = (uses[e.name] or 0) + 1
    elseif op == 'bin' then M.count_uses(e.l, uses); M.count_uses(e.r, uses)
    elseif op == 'un' then M.count_uses(e.e, uses)
    elseif op == 'index' then M.count_uses(e.obj, uses); M.count_uses(e.key, uses)
    elseif op == 'table' then for _, f in ipairs(e.fields) do M.count_uses(f.key, uses); M.count_uses(f.val, uses) end
    elseif op == 'call' or op == 'prim' then for _, a in ipairs(e.args) do M.count_uses(a, uses) end end
end

--- substitute residual expressions for residual variable names
function M.substitute(e, subst)
    local op = e.op
    if op == 'var' then return subst[e.name] or e end
    if op == 'bin' then return { op = 'bin', o = e.o, l = M.substitute(e.l, subst), r = M.substitute(e.r, subst) } end
    if op == 'un' then return { op = 'un', o = e.o, e = M.substitute(e.e, subst) } end
    if op == 'index' then return { op = 'index', obj = M.substitute(e.obj, subst), key = M.substitute(e.key, subst) } end
    if op == 'table' then
        local fields = {}
        for i, f in ipairs(e.fields) do fields[i] = { key = M.substitute(f.key, subst), val = M.substitute(f.val, subst) } end
        return { op = 'table', fields = fields }
    end
    if op == 'call' or op == 'prim' then
        local args = {}
        for i, a in ipairs(e.args) do args[i] = M.substitute(a, subst) end
        return { op = op, fn = e.fn, name = e.name, args = args }
    end
    return e
end

-- ── PRINT: residual IR -> Lua text ─────────────────────────────────────────────────────────────────────────────────
-- (every compound expression is parenthesized: no precedence table to keep right)
local function pexpr(e)
    local op = e.op
    if op == 'num' then
        if e.v == math.floor(e.v) and e.v > -1e15 and e.v < 1e15 then return string.format('%d', e.v) end
        return string.format('%.17g', e.v)
    end
    if op == 'str' then return string.format('%q', e.v) end
    if op == 'bool' then return tostring(e.v) end
    if op == 'nil' then return 'nil' end
    if op == 'var' then return e.name end
    if op == 'bin' then return '(' .. pexpr(e.l) .. ' ' .. e.o .. ' ' .. pexpr(e.r) .. ')' end
    if op == 'un' then return '(' .. e.o .. (e.o == 'not' and ' ' or '') .. pexpr(e.e) .. ')' end
    if op == 'index' then return pexpr(e.obj) .. '[' .. pexpr(e.key) .. ']' end
    if op == 'table' then
        local parts = {}
        for i, f in ipairs(e.fields) do parts[i] = '[' .. pexpr(f.key) .. '] = ' .. pexpr(f.val) end
        return '{ ' .. table.concat(parts, ', ') .. ' }'
    end
    if op == 'call' or op == 'prim' then
        local parts = {}
        for i, a in ipairs(e.args) do parts[i] = pexpr(a) end
        return (e.fn or e.name) .. '(' .. table.concat(parts, ', ') .. ')'
    end
    refuse('printing the IR op ' .. tostring(op))
end
M._pexpr = pexpr

local pblock
local function pstmt(s, ind, out)
    local op = s.op
    if op == 'local' then out[#out + 1] = ind .. 'local ' .. s.name .. ' = ' .. pexpr(s.e)
    elseif op == 'assign' then out[#out + 1] = ind .. pexpr(s.target) .. ' = ' .. pexpr(s.e)
    elseif op == 'callstmt' then out[#out + 1] = ind .. pexpr(s.e)
    elseif op == 'ret' then out[#out + 1] = ind .. 'return ' .. pexpr(s.e)
    elseif op == 'if' then
        for i, c in ipairs(s.clauses) do
            out[#out + 1] = ind .. (i == 1 and 'if ' or 'elseif ') .. pexpr(c.cond) .. ' then'
            pblock(c.body, ind .. '    ', out)
        end
        if #s.els > 0 then
            out[#out + 1] = ind .. 'else'
            pblock(s.els, ind .. '    ', out)
        end
        out[#out + 1] = ind .. 'end'
    elseif op == 'fornum' then
        out[#out + 1] = ind .. 'for ' .. s.name .. ' = ' .. pexpr(s.from) .. ', ' .. pexpr(s.to) .. ', ' .. pexpr(s.step) .. ' do'
        pblock(s.body, ind .. '    ', out)
        out[#out + 1] = ind .. 'end'
    elseif op == 'forin' then
        out[#out + 1] = ind .. 'for ' .. s.kname .. (s.vname and (', ' .. s.vname) or '') .. ' in ' .. s.kind .. '(' .. pexpr(s.e) .. ') do'
        pblock(s.body, ind .. '    ', out)
        out[#out + 1] = ind .. 'end'
    elseif op == 'do' then
        out[#out + 1] = ind .. 'do'
        pblock(s.body, ind .. '    ', out)
        out[#out + 1] = ind .. 'end'
    else refuse('printing the IR statement ' .. tostring(op)) end
end
function pblock(stmts, ind, out) for _, s in ipairs(stmts) do pstmt(s, ind, out) end end

--- the residual program as a Lua chunk: its functions, forward-declared, and `return <entry>`
function M.print(res)
    local out = {}
    local names = {}
    for i, n in ipairs(res.order) do names[i] = n end
    out[#out + 1] = 'local ' .. table.concat(names, ', ')
    for _, n in ipairs(res.order) do
        local f = res.funcs[n]
        out[#out + 1] = 'function ' .. n .. '(' .. table.concat(f.params, ', ') .. ')'
        pblock(f.body, '    ', out)
        out[#out + 1] = 'end'
    end
    out[#out + 1] = 'return ' .. res.entry
    return table.concat(out, '\n') .. '\n'
end

--- mix(term, fname, division, statics) -> residual Lua text, stats
function M.mix(term, fname, division, statics, opts)
    local prog = M.lower(term)
    local res, stats = M.specialize(prog, fname, division, statics, opts)
    return M.print(res), stats
end

return M
