-- cartograph.mix — an OFFLINE PARTIAL EVALUATOR for the Lua subset S (CART-1278, S2 of the specializer arc CART-1276).
-- Given a program (top-level functions), an entry function, a DIVISION of its parameters (S = static, known now; D =
-- dynamic, known later) and the static values, mix produces a RESIDUAL program over the dynamic parameters only, with
-- mix(f, s)(d) == f(s, d). Classic offline mix (Jones, Gomard, Sestoft): a binding-time analysis first, then a
-- specializer driven by it; higher-order after Lambda-mix / Similix.
--   LOWER    an algebra term (algebraread, lossless CST) -> a small IR; every variable resolved to its declaration (an id),
--            every function expression a LAMBDA with its FREE variables
--   BTA      per (function or lambda, division), monovariant inside it, over S < C < D: C is a STATIC CLOSURE — its code
--            known, some free variable dynamic — applied by specializing its body, never run; a value in an operator,
--            condition or table position that is C is D; a variable assigned under DYNAMIC control is D (congruence)
--   SPEC     static parts computed (static calls run by this module's own interpreter), dynamic parts residualized;
--            a call with a dynamic or closure argument is a PROGRAM POINT (function or lambda, division, static values)
--            memoized into one residual function — or UNFOLDED in place when its residual body is a single `return e`.
--            A closure's DYNAMIC free variables become extra parameters of every program point it is passed to, under
--            fresh names (each specialization has its own RENAMING: declaration id -> residual name), so a continuation
--            built per step — the matcher's shape — carries its captured positions in. A closure reaching a dynamic
--            position (a residual call, a returned value) is LIFTED: its body specialized into a residual `function`.
--   PRINT    residual IR -> Lua text (the caller re-reads it through algebraread and loads it)
-- REFUSED by name, never residualized silently: varargs, while / repeat / goto, method calls, metatables (not in S);
-- a closure capturing a per-iteration loop local or ASSIGNING a captured variable (rung 2 keeps no upvalue boxes);
-- a static table reaching dynamic code. A STATIC computation that reads a dynamic variable REFUSES (every dynamic slot
-- holds DYN): a binding-time gap is a named refusal, never a nil. ⚠ mix is written INSIDE S (no while / repeat /
-- goto / varargs / metatables / load): S4–S5 self-apply it — tests/mix_spec.lua fences that.
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

-- scopes: a chain of { names = { name -> id }, up, fnb = the lambda whose parameters it holds, loop = a loop's scope }.
-- -> id, the number of lambda boundaries crossed (each crossed lambda records the id as FREE)
local function lookup(scope, name)
    local s, crossed = scope, {}
    for _ = 1, 10000 do
        if not s then return nil, 0 end
        local id = s.names[name]
        if id then
            if #crossed > 0 then
                -- (a per-iteration local — a loop's variable or a local of its body — captured by a closure: each
                -- iteration is its own variable in Lua, and rung 2 keeps one slot per declaration)
                local t = s
                for _ = 1, 10000 do
                    if not t or t.fnb then break end
                    if t.loop then refuse('a closure capturing `' .. name .. '`, a local of one loop iteration (rung 2: no upvalue boxes)') end
                    t = t.up
                end
                for _, lam in ipairs(crossed) do lam.freeset[id] = true end
            end
            return id, #crossed
        end
        if s.fnb then crossed[#crossed + 1] = s.fnb end
        s = s.up
    end
    return nil, 0
end

local function string_value(t)
    local raw = text(t)
    local q = raw:sub(1, 1)
    if q ~= '"' and q ~= "'" then refuse('a long-bracket string literal (rung 1 reads quoted strings only)') end
    local body = raw:sub(2, -2)
    if body:find('\\', 1, true) then refuse('an escape sequence in a string literal (rung 1)') end
    return body
end

local function declare(cx, scope, name)
    cx.nid = cx.nid + 1
    local id = cx.nid
    scope.names[name] = id
    cx.names[id] = name
    return id
end

-- a function expression -> { op = 'lambda', id, params = { id … }, pnames, body, free = { id … } (sorted) }
local function lower_lambda(pnode, bnode, cx, scope)
    cx.nlam = cx.nlam + 1
    local lam = { op = 'lambda', id = cx.nlam, params = {}, pnames = {}, freeset = {} }
    local ps = { names = {}, up = scope, fnb = lam }
    for _, p in ipairs(named(pnode)) do
        if p.k ~= 'identifier' then refuse('a parameter list with ' .. p.k) end
        lam.params[#lam.params + 1] = declare(cx, ps, text(p))
        lam.pnames[#lam.pnames + 1] = text(p)
    end
    if #lam.params > 6 then refuse('a function expression of more than 6 parameters (rung 2)') end
    lam.body = bnode and lower_block(bnode, cx, ps) or {}
    local free = {}
    for id in pairs(lam.freeset) do free[#free + 1] = id end
    table.sort(free)
    lam.free = free
    lam.freeset = nil
    return lam
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
        if callee.k == 'method_index_expression' then refuse('a method call `' .. text(callee) .. '` (rung 2)') end
        local args = {}
        for _, a in ipairs(named(n[#n])) do args[#args + 1] = lower_expr(a, cx, scope) end
        local f = lower_expr(callee, cx, scope)
        if f.op == 'fn' then return { op = 'call', fn = f.name, args = args } end
        if f.op == 'global' then return { op = 'prim', name = f.name, args = args } end
        return { op = 'callv', f = f, args = args } -- (a call through a value: a closure)
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
    if k == 'function_definition' then
        local n = named(t)
        return lower_lambda(n[1], n[2], cx, scope)
    end
    if k == 'vararg_expression' then refuse('varargs (not in S)') end
    refuse('the expression kind ' .. k)
end

-- the root variable of an assignment target (`t` of `t.a[i]`), or nil
local function target_root(t)
    local x = t
    for _ = 1, 1000 do
        if x.k == 'identifier' then return x end
        if x.k ~= 'bracket_index_expression' and x.k ~= 'dot_index_expression' then return nil end
        x = named(x)[1]
    end
    return nil
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
        local root = target_root(vars[1])
        if root then
            local _, crossed = lookup(scope, text(root))
            if crossed > 0 then
                refuse('a closure assigning the captured `' .. text(root) .. '` (rung 2: no upvalue boxes)')
            end
        end
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
        local inner = { names = {}, up = scope, loop = true }
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
    if k == 'function_declaration' then
        -- `local function f(…)`: f is declared before its body, so the body may call it (a closure capturing itself)
        if token(t) ~= 'local' then refuse('a nested non-local function declaration (rung 2: `local function` only)') end
        local n = named(t)
        local id = declare(cx, scope, text(n[1]))
        out[#out + 1] = { op = 'local', id = id, e = lower_lambda(n[2], n[3], cx, scope) }
        return
    end
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
    local cx = { funcs = {}, names = {}, nid = 0, nlam = 0 }
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

-- the value of every DYNAMIC slot in a specialization's static environment: a static computation that reads one is a
-- binding-time gap, refused by name
local DYN = { dynamic = true }
M.DYN = DYN

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

-- an evaluator over prog: { eval(e, env), exec(stmts, env) -> done, value, R }. R: { steps, budget, depth (the
-- activations below the caller's), clos = { [function value] -> closure }, new_closure(lam, env, bt, dfree),
-- on_closure (called for a closure made at depth 0) }. A closure value is a real Lua function (a host primitive may
-- call it) whose record — { lam, env, bt, dfree, fn } — the specializer reads through R.clos.
function M.evaluator(prog, budget)
    local R = { steps = 0, budget = budget or 1e7, depth = 0, clos = {}, on_closure = nil }
    local exec_block, apply
    -- (one activation deeper; the depth restored on a refusal too)
    local function deeper(stmts, env)
        R.depth = R.depth + 1
        local ok, done, v = pcall(exec_block, stmts, env)
        R.depth = R.depth - 1
        if not ok then error(done, 0) end
        return done, v
    end
    -- a closure's Lua function, one per arity (no varargs: mix stays inside S)
    local function wrap(c)
        local n = #c.lam.params
        if n == 0 then return function () return apply(c, {}) end end
        if n == 1 then return function (a) return apply(c, { a }) end end
        if n == 2 then return function (a, b) return apply(c, { a, b }) end end
        if n == 3 then return function (a, b, d) return apply(c, { a, b, d }) end end
        if n == 4 then return function (a, b, d, e) return apply(c, { a, b, d, e }) end end
        if n == 5 then return function (a, b, d, e, f) return apply(c, { a, b, d, e, f }) end end
        return function (a, b, d, e, f, g) return apply(c, { a, b, d, e, f, g }) end
    end
    function apply(c, args)
        local fenv = {}
        for _, id in ipairs(c.lam.free) do fenv[id] = c.env[id] end
        for i, id in ipairs(c.lam.params) do fenv[id] = args[i] end
        local _, v = deeper(c.lam.body, fenv)
        return v
    end
    function R.new_closure(lam, env, bt, dfree)
        local c = { lam = lam, env = env, bt = bt or {}, dfree = dfree or {} }
        c.fn = wrap(c)
        R.clos[c.fn] = c
        return c.fn, c
    end
    local function eval(e, env)
        R.steps = R.steps + 1
        if R.steps > R.budget then refuse('the interpreter budget (' .. R.budget .. ' steps)') end
        local op = e.op
        if op == 'num' or op == 'str' or op == 'bool' then return e.v end
        if op == 'nil' then return nil end
        if op == 'var' then
            local v = env[e.id]
            if v == DYN then refuse('a static computation read the dynamic `' .. tostring(prog.names[e.id]) .. '` (a binding-time gap)') end
            return v
        end
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
        if op == 'lambda' then
            local fn, c = R.new_closure(e, env)
            if R.depth == 0 and R.on_closure then R.on_closure(c) end
            return fn
        end
        if op == 'call' then
            local f = prog.funcs[e.fn]
            local fenv = {}
            for i, id in ipairs(f.params) do fenv[id] = eval(e.args[i], env) end
            local _, v = deeper(f.body, fenv)
            return v
        end
        if op == 'callv' then
            local f = eval(e.f, env)
            local a = {}
            for i, x in ipairs(e.args) do a[i] = eval(x, env) end
            local c = R.clos[f]
            if not c then refuse('a call through a ' .. type(f) .. ' value that is no closure of the program') end
            return apply(c, a)
        end
        if op == 'prim' then
            local p = PRIMS[e.name]
            if not p then refuse('the primitive ' .. e.name .. ' (not in the table)') end
            local a = {}
            for i, x in ipairs(e.args) do a[i] = eval(x, env) end
            return p(unpack(a, 1, #e.args))
        end
        if op == 'fn' then refuse('the top-level function ' .. e.name .. ' used as a value (rung 2: function expressions only)') end
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

-- ── BTA: per (function or lambda, division), monovariant inside it, over S < C < D ─────────────────────────────────
local S, C, D = 'S', 'C', 'D'
local RANK = { S = 1, C = 2, D = 3 }
local function join(a, b) if RANK[a] >= RANK[b] then return a end return b end
-- (a closure in an operator, condition or table position — compared, indexed, stored: its value is not computed now)
local function opnd(b) if b == C then return D end return b end

-- the binding time of an expression under bt (id -> S / C / D). A call is S when every argument is (it is then RUN);
-- a lambda is S when every free variable is, else C; a call through a C or D value is D (it is specialized)
local function bt_expr(e, bt)
    local op = e.op
    if op == 'num' or op == 'str' or op == 'bool' or op == 'nil' then return S end
    if op == 'var' then return bt[e.id] or S end
    if op == 'lambda' then
        for _, id in ipairs(e.free) do if (bt[id] or S) ~= S then return C end end
        return S
    end
    if op == 'bin' then return opnd(join(bt_expr(e.l, bt), bt_expr(e.r, bt))) end
    if op == 'un' then return opnd(bt_expr(e.e, bt)) end
    if op == 'index' then return opnd(join(bt_expr(e.obj, bt), bt_expr(e.key, bt))) end
    if op == 'table' then
        local r = S
        for _, f in ipairs(e.fields) do r = join(r, join(bt_expr(f.key, bt), bt_expr(f.val, bt))) end
        return opnd(r)
    end
    if op == 'call' or op == 'prim' then
        local r = S
        for _, a in ipairs(e.args) do r = join(r, bt_expr(a, bt)) end
        if op == 'prim' and e.name == 'table.insert' then return D end -- (a mutation: never computed early)
        return opnd(r)
    end
    if op == 'callv' then
        if bt_expr(e.f, bt) ~= S then return D end
        local r = S
        for _, a in ipairs(e.args) do r = join(r, bt_expr(a, bt)) end
        return opnd(r)
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
                c = join(c, opnd(bt_expr(cl.cond, bt)))
                if bt_block(cl.body, bt, c) then changed = true end
            end
            if bt_block(s.els, bt, c) then changed = true end
        elseif op == 'fornum' then
            local b = join(ctrl, opnd(join(bt_expr(s.from, bt), join(bt_expr(s.to, bt), bt_expr(s.step, bt)))))
            set(s.id, b)
            if bt_block(s.body, bt, b) then changed = true end
        elseif op == 'forin' then
            local b = join(ctrl, opnd(bt_expr(s.e, bt)))
            set(s.kid, b)
            if s.vid then set(s.vid, b) end
            if bt_block(s.body, bt, b) then changed = true end
        elseif op == 'do' then
            if bt_block(s.body, bt, ctrl) then changed = true end
        end
    end
    return changed
end

local function fixpoint(body, bt)
    for _ = 1, 1000 do
        if not bt_block(body, bt, S) then return bt end
    end
    refuse('the binding-time analysis did not reach a fixpoint')
end

--- the binding times of one function under a division ({ 'S' | 'C' | 'D' } per parameter) -> { [id] = S | C | D }
function M.bta(prog, fname, division)
    local f = prog.funcs[fname]
    local bt = {}
    for i, id in ipairs(f.params) do bt[id] = division[i] end
    return fixpoint(f.body, bt)
end

--- the binding times of a lambda's body: its parameters by the division, its free variables as where it was made
function M.bta_lambda(lam, division, freebt)
    local bt = {}
    for _, id in ipairs(lam.free) do bt[id] = freebt[id] or S end
    for i, id in ipairs(lam.params) do bt[id] = division[i] or S end
    return fixpoint(lam.body, bt)
end

-- ── SPEC: the specializer ──────────────────────────────────────────────────────────────────────────────────────────
-- a static value's KEY (program points are memoized by it). A closure is its lambda and its STATIC free values; a
-- dynamic free variable is only marked — its value is an argument, not part of the key. clos: the evaluator's
-- closure records; seen: closures on the current path (a closure capturing itself); intable: inside a static table
local function serialize(v, depth, clos, seen, intable)
    local ty = type(v)
    if ty == 'number' or ty == 'boolean' or ty == 'nil' then return tostring(v) end
    if ty == 'string' then return string.format('%q', v) end
    if ty == 'table' then
        if (depth or 0) > 20 then refuse('a static value nested deeper than 20') end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function (a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = serialize(k, (depth or 0) + 1, clos, seen, true) .. '=' .. serialize(v[k], (depth or 0) + 1, clos, seen, true) end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    if ty == 'function' then
        local c = clos and clos[v]
        if not c then refuse('a static value of type function that is no closure of the program') end
        seen = seen or {}
        if seen[c] then return 'λ' .. c.lam.id .. '@' end
        seen[c] = true
        local parts = {}
        for _, id in ipairs(c.lam.free) do
            local b = c.bt[id] or S
            if b == D then
                if intable then refuse('a closure with a dynamic free variable inside a static table (rung 2)') end
                parts[#parts + 1] = id .. ':D'
            else parts[#parts + 1] = id .. '=' .. serialize(c.env[id], (depth or 0) + 1, clos, seen, intable) end
        end
        seen[c] = nil
        return 'λ' .. c.lam.id .. '{' .. table.concat(parts, ',') .. '}'
    end
    refuse('a static value of type ' .. ty)
end
M._serialize = serialize
-- an ARGUMENT LIST's key: each argument at the top level (a closure argument is not "inside a static table")
local function args_key(svals, n, clos)
    local parts = {}
    for i = 1, n do parts[i] = serialize(svals[i], 0, clos) end
    return '(' .. table.concat(parts, ',') .. ')'
end

--- specialize prog's `fname` to the static values of the S parameters -> residual program { funcs = { name -> { name,
--- params = { rname … }, body } }, entry }, stats. opts: budget (unfold steps), name (the entry's residual name)
function M.specialize(prog, fname, division, statics, opts)
    opts = opts or {}
    local budget = opts.budget or 100000
    local used = 0
    local res = { funcs = {}, order = {} }
    local memo, btcache = {}, {}
    local counter, holes = 0, 0
    local function spend(n)
        used = used + (n or 1)
        if used > budget then refuse('the unfold budget (' .. budget .. ')') end
    end
    local function rname(id) return prog.names[id] .. '_' .. id end
    -- STATIC computation: the interpreter over the ORIGINAL program (a static call runs the function itself). A closure
    -- made by a static computation directly in a specialization (depth 0) records, from that specialization, which
    -- of its free variables are dynamic and their residual names there
    local ev = M.evaluator(prog, opts.static_budget or 1e7)
    local R = ev.R
    local current
    function R.on_closure(c)
        local X = current
        for _, id in ipairs(c.lam.free) do
            local b = X.bt[id] or S
            c.bt[id] = b
            if b == D then
                local nm = X.ren[id]
                if not nm then refuse('no residual name for the captured `' .. tostring(prog.names[id]) .. '`') end
                c.dfree[id] = nm
            end
        end
    end
    local function sval(e, X) current = X; return ev.eval(e, X.env) end
    local unfolding = {} -- program points being unfolded right now: a recursive one becomes a program point instead
    -- NESTING: every unfold and program point nests a specialization (and unfold a pcall — LuaJIT allows ~200 nested C
    -- calls); past opts.depth the specialization REFUSES by name instead of overflowing the C stack
    local depth, maxdepth = 0, opts.depth or 120
    local function enter(what)
        depth = depth + 1
        if depth > maxdepth then refuse('the specialization depth (' .. maxdepth .. ' nested ' .. what .. 's: a static value that never repeats?)') end
    end

    -- a TARGET is a top-level function { kind = 'fn', name, f } or a closure { kind = 'lam', c }
    local function t_params(T) if T.kind == 'fn' then return T.f.params end return T.c.lam.params end
    local function t_body(T) if T.kind == 'fn' then return T.f.body end return T.c.lam.body end
    local function t_key(T) if T.kind == 'fn' then return T.name end return serialize(T.c.fn, 0, R.clos) end
    local function bt_of(T, division)
        local key
        if T.kind == 'fn' then key = T.name .. ':' .. table.concat(division, '')
        else
            local fb = {}
            for i, id in ipairs(T.c.lam.free) do fb[i] = T.c.bt[id] or S end
            key = 'λ' .. T.c.lam.id .. ':' .. table.concat(division, '') .. ':' .. table.concat(fb, '')
        end
        if not btcache[key] then
            if T.kind == 'fn' then btcache[key] = M.bta(prog, T.name, division)
            else btcache[key] = M.bta_lambda(T.c.lam, division, T.c.bt) end
        end
        return btcache[key]
    end
    -- a new specialization context for T's body: { bt, env, ren }; a closure target's free variables bound as it
    -- carries them (static ones to their values, dynamic ones to their residual names in the caller)
    local function context(T, division)
        local X = { bt = bt_of(T, division), env = {}, ren = {} }
        if T.kind == 'lam' then
            for _, id in ipairs(T.c.lam.free) do
                if T.c.bt[id] == D then X.env[id] = DYN; X.ren[id] = T.c.dfree[id] else X.env[id] = T.c.env[id] end
            end
        end
        return X
    end

    local spec_block, rexpr

    -- a static value as residual IR (lifting); a closure becomes a residual function expression
    local function lift(v, X)
        local ty = type(v)
        if ty == 'number' then
            if v ~= v or v == math.huge or v == -math.huge then refuse('lifting a non-finite number') end
            return { op = 'num', v = v }
        end
        if ty == 'string' then return { op = 'str', v = v } end
        if ty == 'boolean' then return { op = 'bool', v = v } end
        if ty == 'nil' then return { op = 'nil' } end
        if ty == 'function' then
            local c = R.clos[v]
            if not c then refuse('a static host function reaches dynamic code') end
            -- LIFT: the body specialized with every parameter dynamic
            local T = { kind = 'lam', c = c }
            local division = {}
            for i = 1, #c.lam.params do division[i] = D end
            enter('lifted closure')
            local X2 = context(T, division)
            local params = {}
            for i, id in ipairs(c.lam.params) do X2.env[id] = DYN; X2.ren[id] = rname(id); params[i] = rname(id) end
            local body = spec_block(c.lam.body, X2)
            depth = depth - 1
            return { op = 'lambda', params = params, body = body }
        end
        refuse('a static ' .. ty .. ' reaches dynamic code (lifting tables is not in rung 2)')
    end

    -- UNFOLD: T's body specialized to (division, svals) in place -> its single returned expression, the residual
    -- names of its dynamic parameters (holes, substituted by the caller) | nil
    local function unfold(T, division, svals)
        local key = t_key(T) .. ':' .. table.concat(division, '') .. ':' .. args_key(svals, #division, R.clos)
        if unfolding[key] then return nil end
        unfolding[key] = true
        enter('unfold')
        local X2 = context(T, division)
        local hs = {}
        for i, id in ipairs(t_params(T)) do
            if division[i] == D then
                holes = holes + 1
                X2.env[id] = DYN
                X2.ren[id] = '#hole' .. holes -- (no residual name can collide with it)
                hs[#hs + 1] = X2.ren[id]
            else X2.env[id] = svals[i] end
        end
        local ok, body = pcall(spec_block, t_body(T), X2)
        unfolding[key] = nil
        depth = depth - 1
        if not ok then
            if type(body) == 'table' and body.refusal and (body.refusal:find('budget', 1, true) or body.refusal:find('depth', 1, true)) then error(body, 0) end
            if type(body) ~= 'table' then error(body, 0) end
            return nil
        end
        if #body == 1 and body[1].op == 'ret' then return body[1].e, hs end
        return nil
    end

    -- a PROGRAM POINT for T under (division, svals) -> its residual name, the extra arguments the call passes: the
    -- dynamic free variables of every closure in it (T's own first, then the arguments', depth first), which the
    -- residual function takes as parameters under fresh names
    local function point(T, division, svals)
        local extra_args, extra_params = {}, {}
        local cloned, nc = {}, 0
        local function clone(c)
            if cloned[c] then return cloned[c] end
            local env, dfree = {}, {}
            local _, copy = R.new_closure(c.lam, env, c.bt, dfree)
            cloned[c] = copy
            for _, id in ipairs(c.lam.free) do
                local b = c.bt[id] or S
                if b == D then
                    nc = nc + 1
                    local nm = rname(id) .. 'c' .. nc
                    extra_args[#extra_args + 1] = { op = 'var', name = c.dfree[id] }
                    extra_params[#extra_params + 1] = nm
                    dfree[id] = nm
                    env[id] = DYN
                elseif b == C and R.clos[c.env[id]] then env[id] = clone(R.clos[c.env[id]]).fn
                else env[id] = c.env[id] end
            end
            return copy
        end
        local T2 = T
        if T.kind == 'lam' then T2 = { kind = 'lam', c = clone(T.c) } end
        local params = t_params(T)
        local csvals = {}
        for i = 1, #params do
            local v = svals[i]
            local c = type(v) == 'function' and R.clos[v] or nil
            if c then csvals[i] = clone(c).fn else csvals[i] = v end
        end
        local key = t_key(T) .. ':' .. table.concat(division, '') .. ':' .. args_key(svals, #division, R.clos)
        local name = memo[key]
        if name then return name, extra_args end
        counter = counter + 1
        name = (counter == 1 and opts.name) or ((T.kind == 'fn' and T.name or 'lambda') .. '_' .. counter)
        memo[key] = name
        local rf = { name = name, params = {}, body = nil }
        res.funcs[name] = rf
        res.order[#res.order + 1] = name
        local X2 = context(T2, division)
        for i, id in ipairs(params) do
            if division[i] == D then X2.env[id] = DYN; X2.ren[id] = rname(id); rf.params[#rf.params + 1] = rname(id)
            else X2.env[id] = csvals[i] end
        end
        for _, p in ipairs(extra_params) do rf.params[#rf.params + 1] = p end
        enter('program point')
        rf.body = (spec_block(t_body(T2), X2))
        depth = depth - 1
        return name, extra_args
    end

    -- a call of T with argument expressions argexprs, in X -> residual expression
    local function apply_spec(T, argexprs, X)
        local params = t_params(T)
        local division, svals, dargs = {}, {}, {}
        for i, a in ipairs(argexprs) do
            local b = bt_expr(a, X.bt)
            if b == D then division[i] = D; dargs[#dargs + 1] = rexpr(a, X)
            else division[i] = b; svals[i] = sval(a, X) end
        end
        for i = #argexprs + 1, #params do division[i] = S end -- (a missing argument is a static nil)
        -- UNFOLD when the callee's residual body is one `return e`: substitute its dynamic parameters
        local inl, hs = unfold(T, division, svals)
        if inl then
            local subst, uses = {}, {}
            for i, h in ipairs(hs) do subst[h] = dargs[i] end
            M.count_uses(inl, uses)
            local okk = true
            for nm, a in pairs(subst) do
                if (uses[nm] or 0) > 1 and a.op ~= 'var' and a.op ~= 'num' and a.op ~= 'str' and a.op ~= 'bool' and a.op ~= 'nil' then okk = false end
            end
            if okk then return M.substitute(inl, subst) end
        end
        local name, extra = point(T, division, svals)
        for _, x in ipairs(extra) do dargs[#dargs + 1] = x end
        return { op = 'call', fn = name, args = dargs }
    end

    -- a residual expression for e in X; a static e (or a closure) is computed and lifted
    function rexpr(e, X)
        spend()
        if bt_expr(e, X.bt) ~= D then return lift(sval(e, X), X) end
        local op = e.op
        if op == 'var' then
            local nm = X.ren[e.id]
            if not nm then refuse('no residual name for `' .. tostring(prog.names[e.id]) .. '`') end
            return { op = 'var', name = nm }
        end
        if op == 'bin' then return { op = 'bin', o = e.o, l = rexpr(e.l, X), r = rexpr(e.r, X) } end
        if op == 'un' then return { op = 'un', o = e.o, e = rexpr(e.e, X) } end
        if op == 'index' then return { op = 'index', obj = rexpr(e.obj, X), key = rexpr(e.key, X) } end
        if op == 'table' then
            local fields = {}
            for i, f in ipairs(e.fields) do fields[i] = { key = rexpr(f.key, X), val = rexpr(f.val, X) } end
            return { op = 'table', fields = fields }
        end
        if op == 'prim' then
            local args = {}
            for i, a in ipairs(e.args) do args[i] = rexpr(a, X) end
            return { op = 'prim', name = e.name, args = args }
        end
        if op == 'call' then return apply_spec({ kind = 'fn', name = e.fn, f = prog.funcs[e.fn] }, e.args, X) end
        if op == 'callv' then
            if bt_expr(e.f, X.bt) == D then
                local args = {}
                for i, a in ipairs(e.args) do args[i] = rexpr(a, X) end
                return { op = 'callv', f = rexpr(e.f, X), args = args }
            end
            local c = R.clos[sval(e.f, X)]
            if not c then refuse('a call through a static value that is no closure of the program') end
            return apply_spec({ kind = 'lam', c = c }, e.args, X)
        end
        refuse('residualizing the IR op ' .. tostring(op))
    end

    -- residual statements for stmts in X; returns rstmts, done (a return reached under static control)
    function spec_block(stmts, X)
        local out = {}
        local bt, env = X.bt, X.env
        for _, s in ipairs(stmts) do
            spend()
            local op = s.op
            if op == 'local' then
                if bt[s.id] ~= D then env[s.id] = sval(s.e, X) -- (S: its value; C: the closure)
                else
                    local e = rexpr(s.e, X)
                    env[s.id] = DYN
                    X.ren[s.id] = rname(s.id)
                    out[#out + 1] = { op = 'local', name = rname(s.id), e = e }
                end
            elseif op == 'assign' then
                if s.target.op == 'var' then
                    if bt[s.target.id] ~= D then env[s.target.id] = sval(s.e, X)
                    else
                        local nm = X.ren[s.target.id]
                        if not nm then refuse('no residual name for `' .. tostring(prog.names[s.target.id]) .. '`') end
                        out[#out + 1] = { op = 'assign', target = { op = 'var', name = nm }, e = rexpr(s.e, X) }
                    end
                else
                    out[#out + 1] = { op = 'assign', target = rexpr(s.target, X), e = rexpr(s.e, X) }
                end
            elseif op == 'callstmt' then
                if bt_expr(s.e, bt) == S then sval(s.e, X) -- (a static call, run for its effect)
                else out[#out + 1] = { op = 'callstmt', e = rexpr(s.e, X) } end
            elseif op == 'ret' then
                out[#out + 1] = { op = 'ret', e = rexpr(s.e, X) }
                return out, true
            elseif op == 'if' then
                -- the static prefix of the clauses decides; from the first dynamic condition on, a residual if
                local rclauses, rels, decided = {}, nil, false
                for _, c in ipairs(s.clauses) do
                    if not decided then
                        if #rclauses == 0 and opnd(bt_expr(c.cond, bt)) == S then
                            if sval(c.cond, X) then
                                local body, done = spec_block(c.body, X)
                                for _, x in ipairs(body) do out[#out + 1] = x end
                                if done then return out, true end
                                decided = true
                            end
                        else
                            local body = spec_block(c.body, X)
                            rclauses[#rclauses + 1] = { cond = rexpr(c.cond, X), body = body }
                        end
                    end
                end
                if not decided then
                    if #rclauses == 0 then
                        local body, done = spec_block(s.els, X)
                        for _, x in ipairs(body) do out[#out + 1] = x end
                        if done then return out, true end
                    else
                        rels = spec_block(s.els, X)
                        out[#out + 1] = { op = 'if', clauses = rclauses, els = rels }
                    end
                end
            elseif op == 'fornum' then
                if bt[s.id] == S then -- UNROLL
                    for i = sval(s.from, X), sval(s.to, X), sval(s.step, X) do
                        spend(10)
                        env[s.id] = i
                        local body, done = spec_block(s.body, X)
                        if #body > 0 then out[#out + 1] = { op = 'do', body = body } end
                        if done then return out, true end
                    end
                else
                    local from, to, step = rexpr(s.from, X), rexpr(s.to, X), rexpr(s.step, X)
                    env[s.id] = DYN
                    X.ren[s.id] = rname(s.id)
                    out[#out + 1] = { op = 'fornum', name = rname(s.id), from = from, to = to, step = step, body = (spec_block(s.body, X)) }
                end
            elseif op == 'forin' then
                if bt[s.kid] == S then -- UNROLL (pairs: in the order this host iterates — order-sensitive programs are not gated)
                    local it = s.kind == 'ipairs' and ipairs or pairs
                    for k, v in it(sval(s.e, X)) do
                        spend(10)
                        env[s.kid] = k
                        if s.vid then env[s.vid] = v end
                        local body, done = spec_block(s.body, X)
                        if #body > 0 then out[#out + 1] = { op = 'do', body = body } end
                        if done then return out, true end
                    end
                else
                    local e = rexpr(s.e, X)
                    env[s.kid] = DYN
                    X.ren[s.kid] = rname(s.kid)
                    if s.vid then env[s.vid] = DYN; X.ren[s.vid] = rname(s.vid) end
                    out[#out + 1] = { op = 'forin', kind = s.kind, e = e, kname = rname(s.kid),
                        vname = s.vid and rname(s.vid) or nil, body = (spec_block(s.body, X)) }
                end
            elseif op == 'do' then
                local body, done = spec_block(s.body, X)
                if #body > 0 then out[#out + 1] = { op = 'do', body = body } end
                if done then return out, true end
            else refuse('specializing the IR statement ' .. tostring(op)) end
        end
        return out, false
    end

    local entry = point({ kind = 'fn', name = fname, f = prog.funcs[fname] }, division, statics)
    res.entry = entry
    return res, { unfold_steps = used, functions = #res.order }
end

-- ── residual IR helpers ────────────────────────────────────────────────────────────────────────────────────────────
local count_block, subst_block

--- count the uses of each residual variable name in a residual expression (a use inside a function expression counts
--- as MANY: when and how often it runs is the lambda's call sites')
function M.count_uses(e, uses, w)
    w = w or 1
    local op = e.op
    if op == 'var' then uses[e.name] = (uses[e.name] or 0) + w
    elseif op == 'bin' then M.count_uses(e.l, uses, w); M.count_uses(e.r, uses, w)
    elseif op == 'un' then M.count_uses(e.e, uses, w)
    elseif op == 'index' then M.count_uses(e.obj, uses, w); M.count_uses(e.key, uses, w)
    elseif op == 'table' then for _, f in ipairs(e.fields) do M.count_uses(f.key, uses, w); M.count_uses(f.val, uses, w) end
    elseif op == 'call' or op == 'prim' then for _, a in ipairs(e.args) do M.count_uses(a, uses, w) end
    elseif op == 'callv' then M.count_uses(e.f, uses, w); for _, a in ipairs(e.args) do M.count_uses(a, uses, w) end
    elseif op == 'lambda' then count_block(e.body, uses, 2) end
end
function count_block(stmts, uses, w)
    for _, s in ipairs(stmts) do
        local op = s.op
        if op == 'local' or op == 'ret' or op == 'callstmt' then M.count_uses(s.e, uses, w)
        elseif op == 'assign' then M.count_uses(s.target, uses, w); M.count_uses(s.e, uses, w)
        elseif op == 'if' then
            for _, c in ipairs(s.clauses) do M.count_uses(c.cond, uses, w); count_block(c.body, uses, w) end
            count_block(s.els, uses, w)
        elseif op == 'fornum' then
            M.count_uses(s.from, uses, w); M.count_uses(s.to, uses, w); M.count_uses(s.step, uses, w); count_block(s.body, uses, w)
        elseif op == 'forin' then M.count_uses(s.e, uses, w); count_block(s.body, uses, w)
        elseif op == 'do' then count_block(s.body, uses, w) end
    end
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
    if op == 'callv' then
        local args = {}
        for i, a in ipairs(e.args) do args[i] = M.substitute(a, subst) end
        return { op = 'callv', f = M.substitute(e.f, subst), args = args }
    end
    if op == 'lambda' then return { op = 'lambda', params = e.params, body = subst_block(e.body, subst) } end
    return e
end
function subst_block(stmts, subst)
    local out = {}
    for i, s in ipairs(stmts) do
        local op = s.op
        local n = {}
        for k, v in pairs(s) do n[k] = v end
        if op == 'local' or op == 'ret' or op == 'callstmt' then n.e = M.substitute(s.e, subst)
        elseif op == 'assign' then n.target = M.substitute(s.target, subst); n.e = M.substitute(s.e, subst)
        elseif op == 'if' then
            n.clauses = {}
            for j, c in ipairs(s.clauses) do n.clauses[j] = { cond = M.substitute(c.cond, subst), body = subst_block(c.body, subst) } end
            n.els = subst_block(s.els, subst)
        elseif op == 'fornum' then
            n.from, n.to, n.step = M.substitute(s.from, subst), M.substitute(s.to, subst), M.substitute(s.step, subst)
            n.body = subst_block(s.body, subst)
        elseif op == 'forin' then n.e = M.substitute(s.e, subst); n.body = subst_block(s.body, subst)
        elseif op == 'do' then n.body = subst_block(s.body, subst) end
        out[i] = n
    end
    return out
end

-- ── PRINT: residual IR -> Lua text ─────────────────────────────────────────────────────────────────────────────────
-- (every compound expression is parenthesized: no precedence table to keep right)
local pblock
local function pexpr(e, ind)
    ind = ind or ''
    local op = e.op
    if op == 'num' then
        if e.v == math.floor(e.v) and e.v > -1e15 and e.v < 1e15 then return string.format('%d', e.v) end
        return string.format('%.17g', e.v)
    end
    if op == 'str' then return string.format('%q', e.v) end
    if op == 'bool' then return tostring(e.v) end
    if op == 'nil' then return 'nil' end
    if op == 'var' then return e.name end
    if op == 'bin' then return '(' .. pexpr(e.l, ind) .. ' ' .. e.o .. ' ' .. pexpr(e.r, ind) .. ')' end
    if op == 'un' then return '(' .. e.o .. (e.o == 'not' and ' ' or '') .. pexpr(e.e, ind) .. ')' end
    if op == 'index' then return pexpr(e.obj, ind) .. '[' .. pexpr(e.key, ind) .. ']' end
    if op == 'table' then
        local parts = {}
        for i, f in ipairs(e.fields) do parts[i] = '[' .. pexpr(f.key, ind) .. '] = ' .. pexpr(f.val, ind) end
        return '{ ' .. table.concat(parts, ', ') .. ' }'
    end
    if op == 'call' or op == 'prim' or op == 'callv' then
        local parts = {}
        for i, a in ipairs(e.args) do parts[i] = pexpr(a, ind) end
        local f = op == 'callv' and pexpr(e.f, ind) or (e.fn or e.name)
        return f .. '(' .. table.concat(parts, ', ') .. ')'
    end
    if op == 'lambda' then
        local lines = {}
        pblock(e.body, ind .. '    ', lines)
        return '(function (' .. table.concat(e.params, ', ') .. ')\n' .. table.concat(lines, '\n') .. (#lines > 0 and '\n' or '') .. ind .. 'end)'
    end
    refuse('printing the IR op ' .. tostring(op))
end
M._pexpr = pexpr

local function pstmt(s, ind, out)
    local op = s.op
    if op == 'local' then out[#out + 1] = ind .. 'local ' .. s.name .. ' = ' .. pexpr(s.e, ind)
    elseif op == 'assign' then out[#out + 1] = ind .. pexpr(s.target, ind) .. ' = ' .. pexpr(s.e, ind)
    elseif op == 'callstmt' then
        -- (a statement may not begin with `(`: Lua would read it as a call of the previous line's expression)
        local t = pexpr(s.e, ind)
        if t:sub(1, 1) == '(' then t = 'local _ = ' .. t end
        out[#out + 1] = ind .. t
    elseif op == 'ret' then out[#out + 1] = ind .. 'return ' .. pexpr(s.e, ind)
    elseif op == 'if' then
        for i, c in ipairs(s.clauses) do
            out[#out + 1] = ind .. (i == 1 and 'if ' or 'elseif ') .. pexpr(c.cond, ind) .. ' then'
            pblock(c.body, ind .. '    ', out)
        end
        if #s.els > 0 then
            out[#out + 1] = ind .. 'else'
            pblock(s.els, ind .. '    ', out)
        end
        out[#out + 1] = ind .. 'end'
    elseif op == 'fornum' then
        out[#out + 1] = ind .. 'for ' .. s.name .. ' = ' .. pexpr(s.from, ind) .. ', ' .. pexpr(s.to, ind) .. ', ' .. pexpr(s.step, ind) .. ' do'
        pblock(s.body, ind .. '    ', out)
        out[#out + 1] = ind .. 'end'
    elseif op == 'forin' then
        out[#out + 1] = ind .. 'for ' .. s.kname .. (s.vname and (', ' .. s.vname) or '') .. ' in ' .. s.kind .. '(' .. pexpr(s.e, ind) .. ') do'
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
