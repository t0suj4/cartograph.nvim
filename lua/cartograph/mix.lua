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
-- LOOPS (CART-1450 rung 1): while / repeat / break. A loop whose condition is static UNROLLS; one left with a residual
-- break puts its unrolled iterations in `repeat … until true`, which that break leaves. A break under DYNAMIC control
-- makes every store in its loop's body dynamic (the congruence: the code after the loop sees one of several exits).
-- PINS: a closure capturing a per-iteration local copies it when made (lam.pin, M.cval).
-- ASSUMPTIONS (CART-1463): opts.assume — a read of an assumed field of a dynamic variable is STATIC, guarded at run time
-- (MIXDEOPT before its statement): speculative specialization, the caller runs the original when a guard fires.
-- POSITIONS (CART-1459): every lowered statement and lambda carries `at`, its first line in the text mix read (the reader
-- is lossless: counting its lits' newlines places every node); opts.lines maps those lines to the ORIGINAL ({ src,
-- line }: mixalg's assembled programs) -> prog.where(at). A refusal is LOCATED (e.at, e.where, e.chain: the active
-- calls, innermost first; M.describe prints it), and an error the evaluator raises carries the original's position —
-- `error(msg)` and a lazy error alike — never mix.lua's own line (CART-1458).
-- REFUSED by name, never residualized silently: varargs, goto, metatables (not in S); a pinned local the loop body
-- assigns after the capture, a dynamic one used after its iteration; a closure assigning a captured parameter;
-- a static table reaching dynamic code. A STATIC computation that reads a dynamic variable REFUSES (every dynamic slot
-- holds DYN): a binding-time gap is a named refusal, never a nil. ⚠ mix is written INSIDE S (no while / repeat /
-- goto / varargs / metatables / load): S4–S5 self-apply it — tests/mix_spec.lua fences that.
local M = {}

local function refuse(why) error({ refusal = why }, 0) end
M.refuse = refuse

-- ── LOWER: algebra term -> IR ──────────────────────────────────────────────────────────────────────────────────────
-- (a COMMENT is trivia wherever it stands — between a table's fields, a call's arguments, an if's clauses — and the
-- reader keeps it as a kid: never a named kid, or a position would read it as the next expression)
local TRIVIA = { comment = true, comment_content = true }
local function named(t)
    local out = {}
    for _, c in ipairs(t.kids or {}) do if c.k ~= 'lit' and not TRIVIA[c.k] then out[#out + 1] = c end end
    return out
end
-- t when it is a `block` node, else nil — an EMPTY block has no node, so a position can hold the next clause instead
local function block_of(t)
    if t and t.k == 'block' then return t end
    return nil
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
local function lookup(scope, name, cx)
    cx.tick = cx.tick + 1 -- (lowering runs in textual order: the tick orders captures and assignments)
    local s, crossed = scope, {}
    for _ = 1, 10000 do
        if not s then return nil, 0 end
        local id = s.names[name]
        if id then
            if #crossed > 0 then
                -- (a PER-ITERATION local — a loop's variable or a local of its body — captured by a closure: each
                -- iteration is its own variable in Lua, while an activation keeps one slot per declaration. The
                -- closure made in the iteration (the outermost one crossed) PINS it: its value is copied when the
                -- closure is made. Exact unless the loop body assigns it afterwards — M.lower refuses that)
                local t = s
                for _ = 1, 10000 do
                    if not t or t.fnb then break end
                    if t.loop then
                        crossed[#crossed].pin[id] = true
                        cx.pinned[id] = name
                        cx.pinfirst[id] = cx.pinfirst[id] or cx.tick
                        break
                    end
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
    if not body:find('\\', 1, true) then return body end
    -- the escapes Lua 5.1 / LuaJIT read: \n \t \r \a \b \f \v \\ \" \' \<newline>, \ddd decimal, \xXX hex
    local out, skip = {}, 0
    for i = 1, #body do
        if skip > 0 then skip = skip - 1
        else
            local c = body:sub(i, i)
            if c ~= '\\' then out[#out + 1] = c
            else
                local d = body:sub(i + 1, i + 1)
                local ESC = { n = '\n', t = '\t', r = '\r', a = '\a', b = '\b', f = '\f', v = '\v', ['\\'] = '\\', ['"'] = '"', ["'"] = "'", ['\n'] = '\n' }
                if ESC[d] then out[#out + 1] = ESC[d]; skip = 1
                elseif d:match('%d') then
                    local digits = body:match('^%d%d?%d?', i + 1)
                    if tonumber(digits) > 255 then refuse('the escape \\' .. digits .. ' (beyond a byte)') end
                    out[#out + 1] = string.char(tonumber(digits)); skip = #digits
                elseif d == 'x' and body:match('^%x%x', i + 2) then
                    out[#out + 1] = string.char(tonumber(body:sub(i + 2, i + 3), 16)); skip = 3
                else refuse('the escape \\' .. d .. ' in a string literal') end
            end
        end
    end
    return table.concat(out)
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
    local lam = { op = 'lambda', id = cx.nlam, params = {}, pnames = {}, freeset = {}, pin = {}, at = cx.lineof[pnode] }
    local ps = { names = {}, up = scope, fnb = lam }
    for _, p in ipairs(named(pnode)) do
        if p.k ~= 'identifier' then refuse('a parameter list with ' .. p.k) end
        lam.params[#lam.params + 1] = declare(cx, ps, text(p))
        cx.isparam[lam.params[#lam.params]] = true
        lam.pnames[#lam.pnames + 1] = text(p)
    end
    if #lam.params > 8 then refuse('a function expression of more than 8 parameters') end
    lam.body = bnode and lower_block(bnode, cx, ps) or {}
    local free = {}
    for id in pairs(lam.freeset) do free[#free + 1] = id end
    table.sort(free)
    lam.free = free
    lam.freeset = nil
    local pin = {}
    for id in pairs(lam.pin) do pin[#pin + 1] = id end
    table.sort(pin)
    lam.pin = pin
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
        local id = lookup(scope, name, cx)
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
        local args = {}
        for _, a in ipairs(named(n[#n])) do args[#args + 1] = lower_expr(a, cx, scope) end
        if callee.k == 'method_index_expression' then
            -- (`o:m(…)`: its own op — evaluated as o[m](o, …), whatever o is: a string's library method, a closure field)
            local cn = named(callee)
            return { op = 'method', obj = lower_expr(cn[1], cx, scope), m = text(cn[2]), args = args }
        end
        local f = lower_expr(callee, cx, scope)
        if f.op == 'fn' then return { op = 'call', fn = f.name, args = args } end
        if f.op == 'global' then return { op = 'prim', name = f.name, args = args } end
        return { op = 'callv', f = f, args = args } -- (a call through a value: a closure)
    end
    if k == 'table_constructor' then
        local fields, pos, lastpos = {}, 0, false
        for _, f in ipairs(named(t)) do
            local fn = named(f)
            lastpos = #fn == 1
            if #fn == 1 then
                pos = pos + 1
                fields[#fields + 1] = { key = { op = 'num', v = pos }, val = lower_expr(fn[1], cx, scope) }
            elseif token(f) == '[' then
                fields[#fields + 1] = { key = lower_expr(fn[1], cx, scope), val = lower_expr(fn[2], cx, scope) }
            else
                fields[#fields + 1] = { key = { op = 'str', v = text(fn[1]) }, val = lower_expr(fn[2], cx, scope) }
            end
        end
        -- (the LAST positional field EXPANDS a call's values from its position on — `{ unpack(path) }` copies the whole
        -- list. As one field it kept only the first: algebra core's child() lost every middle step of a path, CART-1461)
        local last = fields[#fields]
        if lastpos and last and M.MULTI[last.val.op] then
            fields[#fields] = nil
            return { op = 'table', fields = fields, rest = last.val, restat = pos }
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
        local es = {}
        for i, e in ipairs(exprs) do es[i] = lower_expr(e, cx, scope) end -- (values first: `local x = x` reads the outer x)
        if #vars == #exprs then
            for i, v in ipairs(vars) do out[#out + 1] = { op = 'local', id = declare(cx, scope, text(v)), e = es[i] } end
        else
            -- (several values: the last expression expands — `local ok, why = f(x)` — or the rest are nil)
            local ids = {}
            for i, v in ipairs(vars) do ids[i] = declare(cx, scope, text(v)) end
            out[#out + 1] = { op = 'localm', ids = ids, es = es }
        end
        return
    end
    if k == 'assignment_statement' then
        local parts = named(t)
        local vars, exprs = named(parts[1]), named(parts[2])
        local targets, writes = {}, {}
        for i, v in ipairs(vars) do
            local root = target_root(v)
            if root then
                local id, crossed = lookup(scope, text(root), cx)
                if id and crossed > 0 then
                    -- ASSIGNMENT CONVERSION: a closure assigning a variable it captured makes that variable a BOX (one
                    -- shared cell, whichever residual function the closure ends up in); a closure storing into a
                    -- captured table makes that table dynamic (it is shared by reference)
                    if root == v then
                        if cx.isparam[id] then refuse('a closure assigning the captured parameter `' .. text(root) .. '` (rung 3: a parameter is not boxed)') end
                        if cx.loopvar[id] then refuse('a closure assigning the captured loop variable `' .. text(root) .. '` (rung 3: a loop variable is not boxed)') end
                        cx.boxed[id] = true
                    else cx.forced[id] = true end
                elseif id and root == v then
                    -- (when: its tick, or LATE when a loop nested in the variable's scope repeats it — a later round
                    -- of that loop runs after a capture written above it)
                    local t, late = scope, false
                    for _ = 1, 10000 do
                        if not t or t.names[text(root)] == id then break end
                        if t.loop then late = true end
                        t = t.up
                    end
                    writes[#writes + 1] = { id = id, late = late }
                end
            end
            targets[i] = lower_expr(v, cx, scope)
            if targets[i].op ~= 'var' and targets[i].op ~= 'index' then refuse('an assignment to ' .. text(v)) end
        end
        local es = {}
        for i, e in ipairs(exprs) do es[i] = lower_expr(e, cx, scope) end
        -- (the write happens AFTER its values are computed: `v = function () return v end` captures, then assigns)
        cx.tick = cx.tick + 1
        for _, w in ipairs(writes) do cx.assigned[w.id] = math.max(cx.assigned[w.id] or 0, w.late and math.huge or cx.tick) end
        if #targets == 1 and #es == 1 then out[#out + 1] = { op = 'assign', target = targets[1], e = es[1] }
        else out[#out + 1] = { op = 'assignm', targets = targets, es = es } end
        return
    end
    if k == 'function_call' then
        out[#out + 1] = { op = 'callstmt', e = lower_expr(t, cx, scope) }
        return
    end
    if k == 'return_statement' then
        local el = named(t)[1]
        local es = {}
        for i, e in ipairs(el and named(el) or {}) do es[i] = lower_expr(e, cx, scope) end
        out[#out + 1] = { op = 'ret', es = es }
        return
    end
    if k == 'if_statement' then
        -- (an EMPTY block is no node at all: `if a then elseif b then … end` has the elseif clause where the then-block
        -- would be — so every block is taken by KIND, never by position; CART-1335)
        local n = named(t)
        local clauses, els = {}, nil
        local first = block_of(n[2])
        clauses[1] = { cond = lower_expr(n[1], cx, scope), body = lower_block(first, cx, scope) }
        for i = first and 3 or 2, #n do
            local c = n[i]
            if c.k == 'elseif_statement' then
                local cn = named(c)
                clauses[#clauses + 1] = { cond = lower_expr(cn[1], cx, scope), body = lower_block(block_of(cn[2]), cx, scope) }
            elseif c.k == 'else_statement' then
                els = lower_block(block_of(named(c)[1]), cx, scope)
            end
        end
        out[#out + 1] = { op = 'if', clauses = clauses, els = els or {} }
        return
    end
    if k == 'for_statement' then
        local n = named(t)
        local clause, body = n[1], block_of(n[2])
        local inner = { names = {}, up = scope, loop = true }
        if clause.k == 'for_numeric_clause' then
            local cn = named(clause)
            local from, to = lower_expr(cn[2], cx, scope), lower_expr(cn[3], cx, scope)
            local step = cn[4] and lower_expr(cn[4], cx, scope) or { op = 'num', v = 1 }
            local id = declare(cx, inner, text(cn[1]))
            cx.loopvar[id] = true
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
        cx.loopvar[kid] = true
        if vid then cx.loopvar[vid] = true end
        out[#out + 1] = { op = 'forin', kind = it.name, e = it.args[1], kid = kid, vid = vid, body = lower_block(body, cx, inner) }
        return
    end
    if k == 'do_statement' then
        local b = block_of(named(t)[1])
        out[#out + 1] = { op = 'do', body = b and lower_block(b, cx, { names = {}, up = scope }) or {} }
        return
    end
    if k == 'while_statement' then
        -- (the body's locals are per ITERATION, as a for's: a closure capturing one refuses — the loop scope)
        local n = named(t)
        local cond = lower_expr(n[1], cx, scope)
        out[#out + 1] = { op = 'while', cond = cond, body = lower_block(block_of(n[2]), cx, { names = {}, up = scope, loop = true }) }
        return
    end
    if k == 'repeat_statement' then
        -- (`until` is read INSIDE the body's scope: it sees the body's locals)
        local n = named(t)
        local inner = { names = {}, up = { names = {}, up = scope, loop = true } }
        local body = lower_block(#n > 1 and block_of(n[1]) or nil, cx, nil, inner)
        out[#out + 1] = { op = 'repeat', body = body, cond = lower_expr(n[#n], cx, inner) }
        return
    end
    if k == 'break_statement' then out[#out + 1] = { op = 'break' }; return end
    if k == 'comment' or k == 'comment_content' or k == 'empty_statement' then return end
    if k == 'goto_statement' or k == 'label_statement' then refuse('`' .. k .. '` (not in S)') end
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

-- inner: the block's own scope when the caller must read it afterwards (a repeat's `until`)
function lower_block(t, cx, scope, inner)
    local out = {}
    if not t then return out end -- (an empty block)
    inner = inner or { names = {}, up = scope }
    for _, s in ipairs(named(t)) do
        local n0, at = #out, cx.lineof[s]
        -- (a refusal is LOCATED: the innermost statement's line — every nested block comes through here first)
        local okl, e = pcall(lower_stmt, s, cx, inner, out)
        if not okl then
            if type(e) ~= 'table' or not e.refusal then error(e, 0) end
            e.at = e.at or at
            -- (the CENSUS: a refused statement is recorded and skipped, and lowering goes on, so one run lists
            -- everything mix does not handle yet)
            if not cx.collect then error(e, 0) end
            cx.collect[#cx.collect + 1] = { why = e.refusal, text = (text(s):gsub('%s+', ' ')):sub(1, 100), at = e.at,
                where = cx.where and cx.where(e.at) }
        end
        for i = n0 + 1, #out do out[i].at = out[i].at or at end
    end
    return out
end

-- the ASSIGNMENT CONVERSION of a lowered body: a boxed variable's declaration becomes `{ e }` (and is forced dynamic),
-- a read v[1], a write a store into it; a forced variable's declaration is marked dynamic
local box_expr, box_block
function box_expr(e, boxed, forced)
    local op = e.op
    if op == 'var' then
        if boxed[e.id] then return { op = 'index', obj = e, key = { op = 'num', v = 1 } } end
        return e
    end
    local n = {}
    for k, v in pairs(e) do n[k] = v end
    if op == 'bin' then n.l, n.r = box_expr(e.l, boxed, forced), box_expr(e.r, boxed, forced)
    elseif op == 'un' then n.e = box_expr(e.e, boxed, forced)
    elseif op == 'index' then n.obj, n.key = box_expr(e.obj, boxed, forced), box_expr(e.key, boxed, forced)
    elseif op == 'table' then
        n.fields = {}
        for i, f in ipairs(e.fields) do n.fields[i] = { key = box_expr(f.key, boxed, forced), val = box_expr(f.val, boxed, forced) } end
        if e.rest then n.rest = box_expr(e.rest, boxed, forced) end
    elseif op == 'call' or op == 'prim' or op == 'callv' or op == 'method' then
        n.args = {}
        for i, a in ipairs(e.args) do n.args[i] = box_expr(a, boxed, forced) end
        if op == 'callv' then n.f = box_expr(e.f, boxed, forced) end
        if op == 'method' then n.obj = box_expr(e.obj, boxed, forced) end
    elseif op == 'lambda' then n.body = box_block(e.body, boxed, forced)
    end
    return n
end
function box_block(stmts, boxed, forced)
    local out = {}
    for i, s in ipairs(stmts) do
        local n = {}
        for k, v in pairs(s) do n[k] = v end
        local op = s.op
        if op == 'local' then
            n.e = box_expr(s.e, boxed, forced)
            if boxed[s.id] then n.e = { op = 'table', fields = { { key = { op = 'num', v = 1 }, val = n.e } } } end
            if boxed[s.id] or (forced and forced[s.id]) then n.forced = true end
        elseif op == 'localm' then
            for _, id in ipairs(s.ids) do
                if boxed[id] then refuse('a declaration of several values whose variable a closure assigns (rung 3)') end
                if forced and forced[id] then n.forced = true end
            end
            n.es = {}
            for j, e in ipairs(s.es) do n.es[j] = box_expr(e, boxed, forced) end
        elseif op == 'assign' then n.target, n.e = box_expr(s.target, boxed, forced), box_expr(s.e, boxed, forced)
        elseif op == 'assignm' then
            n.targets, n.es = {}, {}
            for j, t in ipairs(s.targets) do n.targets[j] = box_expr(t, boxed, forced) end
            for j, e in ipairs(s.es) do n.es[j] = box_expr(e, boxed, forced) end
        elseif op == 'callstmt' then n.e = box_expr(s.e, boxed, forced)
        elseif op == 'ret' then
            n.es = {}
            for j, e in ipairs(s.es) do n.es[j] = box_expr(e, boxed, forced) end
        elseif op == 'if' then
            n.clauses = {}
            for j, c in ipairs(s.clauses) do n.clauses[j] = { cond = box_expr(c.cond, boxed, forced), body = box_block(c.body, boxed, forced) } end
            n.els = box_block(s.els, boxed, forced)
        elseif op == 'fornum' then
            n.from, n.to, n.step = box_expr(s.from, boxed, forced), box_expr(s.to, boxed, forced), box_expr(s.step, boxed, forced)
            n.body = box_block(s.body, boxed, forced)
        elseif op == 'forin' then n.e = box_expr(s.e, boxed, forced); n.body = box_block(s.body, boxed, forced)
        elseif op == 'do' then n.body = box_block(s.body, boxed, forced)
        elseif op == 'while' or op == 'repeat' then n.cond = box_expr(s.cond, boxed, forced); n.body = box_block(s.body, boxed, forced)
        end
        out[i] = n
    end
    return out
end
function M.box(stmts, boxed, forced)
    if next(boxed) == nil and next(forced) == nil then return stmts end
    return box_block(stmts, boxed, forced)
end

--- a chunk of top-level function declarations -> program { funcs = { name -> { name, params = { id … }, pnames, body } },
--- names = { id -> source name } }. opts.collect = {}: the CENSUS — every refused statement recorded there as
--- { why, text } and skipped, instead of the first one refusing the whole program
function M.lower(term, opts)
    local cx = { funcs = {}, names = {}, nid = 0, nlam = 0, collect = opts and opts.collect, isparam = {}, boxed = {}, forced = {},
        pinned = {}, pinfirst = {}, assigned = {}, loopvar = {}, tick = 0 }
    -- LINES (CART-1459): every node's FIRST LINE — the reader is lossless, its lits ARE the source, so counting their
    -- newlines in order places every node. Statements and lambdas carry it as `at` (bookkeeping: the algebra does not
    -- see it). opts.lines maps a line of THIS text to where it came from ({ src, line }: an assembled program's
    -- definitions come from several files) -> prog.where(at) = 'src:line', as Lua itself prints a position
    local lineof, line = {}, 1
    local function place(t)
        if t.k == 'lit' then
            local v = tostring(t.v)
            local first = v:find('%S') and line + select(2, v:sub(1, v:find('%S') - 1):gsub('\n', '')) or nil
            line = line + select(2, v:gsub('\n', ''))
            return first
        end
        local first
        for _, c in ipairs(t.kids or {}) do
            local f = place(c)
            first = first or f
        end
        lineof[t] = first
        return first
    end
    place(term)
    cx.lineof = lineof
    local lines = opts and opts.lines
    if lines then cx.where = function (at) local l = at and lines[at]; return l and (l.src .. ':' .. l.line) or nil end end
    local decls = {}
    for _, d in ipairs(named(term)) do
        if d.k == 'function_declaration' then
            local n = named(d)
            local name = text(n[1])
            cx.funcs[name] = true
            decls[#decls + 1] = { name = name, params = n[2], body = n[3] }
        elseif d.k == 'variable_declaration' and named(d)[1] and named(d)[1].k ~= 'assignment_statement' then
            -- (a forward declaration `local f, g` — the residual printer's own)
        elseif d.k ~= 'return_statement' and d.k ~= 'comment' and d.k ~= 'comment_content' and d.k ~= 'empty_statement' then
            refuse('top-level ' .. d.k .. ' (a program is top-level function declarations)')
        end
    end
    for _, d in ipairs(decls) do
        local scope = { names = {}, up = nil }
        local params, pnames = {}, {}
        for _, p in ipairs(named(d.params)) do
            if p.k ~= 'identifier' then refuse('a parameter list with ' .. p.k) end
            params[#params + 1] = declare(cx, scope, text(p))
            cx.isparam[params[#params]] = true
            pnames[#pnames + 1] = text(p)
        end
        cx.funcs[d.name] = { name = d.name, params = params, pnames = pnames, body = d.body and lower_block(d.body, cx, scope) or {},
            at = lineof[d.params] }
    end
    -- PINS are copies: a pinned local the loop body ASSIGNS AFTER a closure captured it (not through a closure — that
    -- one is a box, made afresh each iteration) would change under the copy. An assignment written before the first
    -- capture, outside any loop nested in the variable's scope, runs before it in every iteration
    local stale = {}
    for id, name in pairs(cx.pinned) do
        if (cx.assigned[id] or 0) > cx.pinfirst[id] and not cx.boxed[id] then stale[#stale + 1] = name end
    end
    table.sort(stale)
    for _, name in ipairs(stale) do
        local why = 'a closure capturing `' .. name .. '`, a local of one loop iteration that the loop body assigns (rung 2: no upvalue boxes)'
        if not cx.collect then refuse(why) end
        cx.collect[#cx.collect + 1] = { why = why, text = name }
    end
    -- RECORDS: a local table that never escapes is its fields, one local each (SRA, CART-1331 rung 4a)
    cx.sra = { candidates = 0, replaced = 0, escapes = {} }
    for _, f in pairs(cx.funcs) do f.body = M.sra(f.body, cx) end
    -- BOXES: every boxed variable's declaration holds { v }, every read is v[1], every write a store into it
    for _, f in pairs(cx.funcs) do f.body = M.box(f.body, cx.boxed, cx.forced) end
    return { funcs = cx.funcs, names = cx.names, forced = cx.forced, boxed = cx.boxed, sra = cx.sra, where = cx.where }
end

-- ── SRA: SCALAR REPLACEMENT OF A LOCAL RECORD (CART-1331 rung 4a) ──────────────────────────────────────────────────
-- mix's binding times are per VARIABLE, all-or-nothing per table: one store under dynamic control, one dynamic field,
-- and the whole record is dynamic and allocated at run time. A local table that NEVER ESCAPES — declared by a
-- constructor whose keys are all literals, and used ONLY as `t.k` / `t[<literal>]` (read or stored) in the function or
-- lambda that declares it — is replaced by one local per field before any analysis runs, so the existing per-variable
-- binding times become PER-FIELD binding times: a static field folds away, a dynamic one is a residual local, and no
-- table is built. ESCAPE (the record stays a table, as before): any other use of the variable (an argument, a return,
-- `#t`, a method call, a comparison, stored into another table, rebound), a field read in ANOTHER function (a closure
-- capturing it), a non-literal or duplicate constructor key. Written over the cartograph.mixterm LENS: one generic walk,
-- no per-kind switch. -> the body, rewritten; cx.sra counts candidates / replaced and the escape reasons
local function sra_key(k)
    if (k.k == 'num' or k.k == 'str') and k.kids[1] and k.kids[1].k == 'lit' then return k.k .. ':' .. tostring(k.kids[1].v) end
    return nil
end
local function var_id(t) if t.k == 'var' and t.kids[1] and t.kids[1].k == 'lit' then return t.kids[1].v end return nil end
local function none_t() return { k = 'none', kids = {} } end

function M.sra(body, cx)
    local MT = require 'cartograph.mixterm'
    local t = MT.block_term(body)
    local cand = {}
    -- (1) CANDIDATES: `local t = { <literal keys> }`, with the lambda that declares it (0: the function itself)
    local owner = 0
    local function find(n)
        if n.k == 'lambda' then
            local saved = owner
            owner = n.kids[1].k == 'lit' and n.kids[1].v or saved
            for _, c in ipairs(n.kids) do find(c) end
            owner = saved
            return
        end
        if n.k == 'local' and n.kids[4] and n.kids[4].k == 'table' and n.kids[4].kids[2].k == 'none' and n.kids[1].k == 'lit' then
            local fields, keys, order, ok = n.kids[4].kids[1].kids or {}, {}, {}, true
            for _, f in ipairs(fields) do
                local key = sra_key(f.kids[1])
                if not key or keys[key] then ok = false else keys[key] = f.kids[1]; order[#order + 1] = key end
            end
            cx.sra.candidates = cx.sra.candidates + 1
            if ok then cand[n.kids[1].v] = { keys = keys, order = order, owner = owner }
            else cx.sra.escapes[#cx.sra.escapes + 1] = 'a non-literal or duplicate constructor key' end
        end
        for _, c in ipairs(n.kids or {}) do find(c) end
    end
    find(t)
    if next(cand) == nil then return body end
    -- (2) USES: only `t.<literal>` in the declaring function / lambda; anything else ESCAPES
    local function escape(id, why)
        if cand[id] then cand[id] = nil; cx.sra.escapes[#cx.sra.escapes + 1] = why end
    end
    owner = 0
    local function use(n)
        if n.k == 'lambda' then
            -- (a closure capturing the record needs no rule of its own: every use inside it is a field read in another
            -- function or a use as a value — a mutant dropping a capture rule survived, so there is none)
            local saved = owner
            owner = n.kids[1].k == 'lit' and n.kids[1].v or saved
            for _, c in ipairs(n.kids) do use(c) end
            owner = saved
            return
        end
        if n.k == 'index' then
            local id = var_id(n.kids[1])
            if id and cand[id] then
                local key = sra_key(n.kids[2])
                if not key then escape(id, 'a non-literal key')
                elseif cand[id].owner ~= owner then escape(id, 'used in another function')
                else cand[id].keys[key] = cand[id].keys[key] or n.kids[2] end
                return
            end
        end
        local id = var_id(n)
        if id then escape(id, 'used as a value'); return end
        for _, c in ipairs(n.kids or {}) do use(c) end
    end
    use(t)
    if next(cand) == nil then return body end
    -- (3) REWRITE: one local per field; `t.k` -> that local; the declaration -> the fields' declarations, in order
    for id, c in pairs(cand) do
        c.fid = {}
        local extra = {}
        for key in pairs(c.keys) do
            local seen = false
            for _, k in ipairs(c.order) do if k == key then seen = true end end
            if not seen then extra[#extra + 1] = key end
        end
        table.sort(extra)
        for _, key in ipairs(extra) do c.order[#c.order + 1] = key end
        for _, key in ipairs(c.order) do
            cx.nid = cx.nid + 1
            c.fid[key] = cx.nid
            cx.names[cx.nid] = tostring(cx.names[id]) .. '_' .. tostring(c.keys[key].kids[1].v)
        end
        cx.sra.replaced = cx.sra.replaced + 1
    end
    local function var_t(fid) return { k = 'var', kids = { { k = 'lit', v = fid }, none_t() } } end
    local function local_t(fid, e) return { k = 'local', kids = { { k = 'lit', v = fid }, none_t(), none_t(), e } } end
    local rw
    local function rw_seq(n)
        local kids = {}
        for _, s in ipairs(n.kids) do
            local id = s.k == 'local' and s.kids[1].k == 'lit' and s.kids[1].v
            local c = id and cand[id]
            if c and s.kids[4].k == 'table' then
                local vals = {}
                for _, f in ipairs(s.kids[4].kids[1].kids or {}) do vals[sra_key(f.kids[1])] = rw(f.kids[2]) end
                for _, key in ipairs(c.order) do kids[#kids + 1] = local_t(c.fid[key], vals[key] or { k = 'nil', kids = {} }) end
            else kids[#kids + 1] = rw(s) end
        end
        local out = {}
        for k, v in pairs(n) do out[k] = v end
        out.kids = kids
        return out
    end
    function rw(n)
        if n.k == 'index' then
            local id = var_id(n.kids[1])
            if id and cand[id] then return var_t(cand[id].fid[sra_key(n.kids[2])]) end
        end
        if n.k == 'seq' then return rw_seq(n) end
        if not n.kids then return n end
        local out = {}
        for k, v in pairs(n) do out[k] = v end
        out.kids = {}
        for i, c in ipairs(n.kids) do out.kids[i] = rw(c) end
        return out
    end
    return MT.of_block(rw(t))
end

-- ── the INTERPRETER (static evaluation, and the step counter of the payoff gate) ────────────────────────────────────
local PRIMS = {
    tostring = tostring, tonumber = tonumber, type = type, unpack = unpack, select = select, next = next,
    rawequal = rawequal, error = error, pcall = pcall, assert = assert,
    ['math.floor'] = math.floor, ['math.ceil'] = math.ceil, ['math.max'] = math.max, ['math.min'] = math.min, ['math.abs'] = math.abs,
    ['string.format'] = string.format, ['string.sub'] = string.sub, ['string.len'] = string.len, ['string.rep'] = string.rep,
    ['string.gsub'] = string.gsub, ['string.find'] = string.find, ['string.match'] = string.match, ['string.byte'] = string.byte,
    ['string.char'] = string.char, ['string.upper'] = string.upper, ['string.lower'] = string.lower,
    ['table.insert'] = table.insert, ['table.remove'] = table.remove, ['table.sort'] = table.sort, ['table.concat'] = table.concat,
}
M.PRIMS = PRIMS
-- primitives NEVER computed early: they mutate a table, or raise (an error is the residual program's, not mix's)
local EFFECT = { ['table.insert'] = true, ['table.remove'] = true, ['table.sort'] = true, error = true, assert = true }
M.EFFECT = EFFECT
-- global VALUES (not calls) that are constants of the language
local CONSTS = { ['math.huge'] = math.huge, ['math.pi'] = math.pi }
M.CONSTS = CONSTS
-- KNOWN GLOBALS of the current specialization (opts.globals: a module's DATA — `M.grammars` — named by its path):
-- static values to the evaluator; a host value of them reaching dynamic code is residualized as its PATH, and the
-- residual chunk is loaded with those globals in its environment
local KNOWN = {}
-- ASSUMPTIONS of the current specialization (opts.assume, CART-1463): { [field] = { value = v } } — a read `x.field` of a
-- DYNAMIC variable x is taken to be v: STATIC, so the code it guards folds away; a residual GUARD before its statement
-- checks it at run time (`if type(x) == 'table' and x.field ~= v then MIXDEOPT() end`) and deoptimizes when it fails.
-- Speculative specialization: the compiled code is smaller and faster on the inputs it assumes, and still right on
-- the rest, because the caller runs the original when MIXDEOPT fires
local ASSUME = {}
-- is `e` an assumed read — a static field name in ASSUME, of a variable?
local function assumed_read(e)
    return e.op == 'index' and e.key.op == 'str' and ASSUME[e.key.v] ~= nil and e.obj.op == 'var'
end
-- an assumed value (a scalar or nil) as residual IR
local function scalar_ir(v)
    if v == nil then return { op = 'nil' } end
    if type(v) == 'boolean' then return { op = 'bool', v = v } end
    if type(v) == 'number' then return { op = 'num', v = v } end
    if type(v) == 'string' then return { op = 'str', v = v } end
    refuse('an assumption whose value is a ' .. type(v) .. ' (scalars and nil only)')
end

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

-- a block's DONE when a `break` ran: not a return — the innermost loop stops, and nothing above it sees it
local BREAK = 'break'
M.BREAK = BREAK
-- a closure's free variable: its PINNED copy (a per-iteration local, copied when the closure was made — NILV a pinned
-- nil), else the slot of the activation it was made in
local NILV = {}
function M.cval(c, id)
    local p = c.pin
    if p then
        local v = p[id]
        if v == NILV then return nil end
        if v ~= nil then return v end
    end
    return c.env[id]
end
-- does a loop body hold a break of ITS loop (under any control: in an if, a do — not in a nested loop or function)?
local function breaks(stmts)
    for _, s in ipairs(stmts) do
        if s.op == 'break' then return true end
        if s.op == 'do' and breaks(s.body) then return true end
        if s.op == 'if' then
            for _, c in ipairs(s.clauses) do if breaks(c.body) then return true end end
            if breaks(s.els) then return true end
        end
    end
    return false
end
M._breaks = breaks

-- an evaluator over prog: { eval(e, env), exec(stmts, env) -> done, value, R }. R: { steps, budget, depth (the
-- activations below the caller's), clos = { [function value] -> closure }, new_closure(lam, env, bt, dfree),
-- on_closure (called for a closure made at depth 0) }. A closure value is a real Lua function (a host primitive may
-- call it) whose record — { lam, env, bt, dfree, fn } — the specializer reads through R.clos.
-- the ops whose value is a LIST when last in a list (Lua's expansion): a call of any kind
local MULTI = { call = true, callv = true, prim = true, method = true }
M.MULTI = MULTI

-- a host function's results as a list (up to 8: no varargs in S, so trailing nils are not counted)
local function host(f, a)
    local r1, r2, r3, r4, r5, r6, r7, r8 = f(unpack(a, 1, a.n or #a))
    local r = { r1, r2, r3, r4, r5, r6, r7, r8 }
    local n = 0
    for i = 1, 8 do if r[i] ~= nil then n = i end end
    r.n = n
    return r
end

function M.evaluator(prog, budget)
    local R = { steps = 0, budget = budget or 1e7, depth = 0, clos = {}, on_closure = nil }
    local exec_block, apply, eval, eval_multi, evals
    -- (one activation deeper; the depth restored on a refusal too)
    local function deeper(stmts, env)
        R.depth = R.depth + 1
        local at0 = R.at
        local ok, done, v = pcall(exec_block, stmts, env)
        R.depth = R.depth - 1
        if not ok then error(done, 0) end -- (R.at stays the INNERMOST statement: where the error happened)
        R.at = at0
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
        if n == 6 then return function (a, b, d, e, f, g) return apply(c, { a, b, d, e, f, g }) end end
        if n == 7 then return function (a, b, d, e, f, g, h) return apply(c, { a, b, d, e, f, g, h }) end end
        return function (a, b, d, e, f, g, h, i) return apply(c, { a, b, d, e, f, g, h, i }) end
    end
    -- a closure applied -> the list of its results
    local function applyl(c, args)
        local fenv = {}
        for _, id in ipairs(c.lam.free) do fenv[id] = M.cval(c, id) end
        for i, id in ipairs(c.lam.params) do fenv[id] = args[i] end
        local _, vs = deeper(c.lam.body, fenv)
        return vs or { n = 0 }
    end
    -- (the Lua function a host primitive calls: every result handed back)
    function apply(c, args)
        local vs = applyl(c, args)
        return unpack(vs, 1, vs.n)
    end
    -- a TOP-LEVEL FUNCTION used as a value: a closure with no free variables over a lambda that stands for it (one
    -- per function: the same key every time)
    local fnlam, fnval = {}, {}
    function R.fnvalue(name)
        if fnval[name] then return fnval[name] end
        local f = prog.funcs[name]
        fnlam[name] = { op = 'lambda', id = 'fn:' .. name, params = f.params, pnames = f.pnames, body = f.body, free = {} }
        local fn = R.new_closure(fnlam[name], {})
        fnval[name] = fn
        return fn
    end
    function R.new_closure(lam, env, bt, dfree)
        local c = { lam = lam, env = env, bt = bt or {}, dfree = dfree or {} }
        c.fn = wrap(c)
        R.clos[c.fn] = c
        return c.fn, c
    end
    -- a list of expressions -> its values (the last one EXPANDS when it is a call)
    function evals(es, env)
        local out = { n = 0 }
        for i, e in ipairs(es) do
            if i == #es and MULTI[e.op] then
                local vs = eval_multi(e, env)
                for j = 1, vs.n do out[i + j - 1] = vs[j] end
                out.n = i - 1 + vs.n
            else out[i] = eval(e, env); out.n = i end
        end
        return out
    end
    -- a call of any kind -> the list of its results
    function eval_multi(e, env)
        R.steps = R.steps + 1
        if R.steps > R.budget then refuse('the interpreter budget (' .. R.budget .. ' steps)') end
        local op = e.op
        if op == 'call' then
            local f = prog.funcs[e.fn]
            local a = evals(e.args, env)
            local fenv = {}
            for i, id in ipairs(f.params) do fenv[id] = a[i] end
            local _, vs = deeper(f.body, fenv)
            return vs or { n = 0 }
        end
        if op == 'callv' then
            local f = eval(e.f, env)
            local a = evals(e.args, env)
            local c = R.clos[f]
            if not c then refuse('a call through a ' .. type(f) .. ' value that is no closure of the program') end
            return applyl(c, a)
        end
        if op == 'prim' then
            local p = PRIMS[e.name]
            if not p then refuse('the primitive ' .. e.name .. ' (not in the table)') end
            -- (an `error(msg)` at the default level is prefixed with the position of its call — the ORIGINAL's, from
            -- the program's line map, never this evaluator's own line in mix.lua: CART-1458)
            if e.name == 'error' and prog.where then
                local a = evals(e.args, env)
                local w = prog.where(R.at)
                if w and type(a[1]) == 'string' and (a[2] == nil or a[2] == 1) then error(w .. ': ' .. a[1], 0) end
                error(a[1], a[2] == nil and 1 or a[2])
            end
            local vs = host(p, evals(e.args, env))
            -- (a static pcall must not swallow mix's own refusal: re-raised, never a value)
            if e.name == 'pcall' and vs[1] == false and type(vs[2]) == 'table' and vs[2].refusal then error(vs[2], 0) end
            return vs
        end
        if op == 'method' then
            local o = eval(e.obj, env)
            local a = evals(e.args, env)
            local args = { o, n = a.n + 1 }
            for i = 1, a.n do args[i + 1] = a[i] end
            local f
            if type(o) == 'string' then f = string[e.m]
            elseif type(o) == 'table' then f = o[e.m] end
            local c = f and R.clos[f]
            if c then return applyl(c, args) end
            if type(o) == 'string' and type(f) == 'function' then return host(f, args) end
            refuse('the method `' .. tostring(e.m) .. '` of a ' .. type(o))
        end
        return { eval(e, env), n = 1 }
    end
    function eval(e, env)
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
        if op == 'index' then
            -- (an ASSUMED read of a dynamic variable: the assumed value, and the specializer is told to guard it)
            if assumed_read(e) and env[e.obj.id] == DYN and R.on_assume and R.on_assume(e.obj, e.key.v) then
                return ASSUME[e.key.v].value
            end
            return eval(e.obj, env)[eval(e.key, env)]
        end
        if op == 'table' then
            local t = {}
            for _, f in ipairs(e.fields) do t[eval(f.key, env)] = eval(f.val, env) end
            if e.rest then
                local vs = eval_multi(e.rest, env)
                for j = 1, vs.n do t[e.restat + j - 1] = vs[j] end
            end
            return t
        end
        if op == 'lambda' then
            local fn, c = R.new_closure(e, env)
            if e.pin and #e.pin > 0 then
                c.pin = {}
                for _, id in ipairs(e.pin) do
                    local v = env[id]
                    if v == nil then v = NILV end
                    c.pin[id] = v
                end
            end
            if R.depth == 0 and R.on_closure then R.on_closure(c) end
            return fn
        end
        if MULTI[op] then
            R.steps = R.steps - 1 -- (eval_multi counts the step)
            return eval_multi(e, env)[1]
        end
        if op == 'fn' then return R.fnvalue(e.name) end
        if op == 'global' then
            if CONSTS[e.name] ~= nil then return CONSTS[e.name] end
            if KNOWN[e.name] ~= nil then return KNOWN[e.name] end
            refuse('the global ' .. e.name)
        end
        refuse('the IR op ' .. tostring(op))
    end
    -- exec_block -> done (a return ran), value
    function exec_block(stmts, env)
        for _, s in ipairs(stmts) do
            R.steps = R.steps + 1
            R.at = s.at
            local op = s.op
            if op == 'local' then env[s.id] = eval(s.e, env)
            elseif op == 'localm' then
                local vs = evals(s.es, env)
                for i, id in ipairs(s.ids) do env[id] = vs[i] end
            elseif op == 'assign' then
                if s.target.op == 'var' then env[s.target.id] = eval(s.e, env)
                else eval(s.target.obj, env)[eval(s.target.key, env)] = eval(s.e, env) end
            elseif op == 'assignm' then
                local vs = evals(s.es, env)
                for i, t in ipairs(s.targets) do
                    if t.op == 'var' then env[t.id] = vs[i] else eval(t.obj, env)[eval(t.key, env)] = vs[i] end
                end
            elseif op == 'callstmt' then eval(s.e, env)
            elseif op == 'ret' then return true, evals(s.es, env)
            elseif op == 'break' then return BREAK
            elseif op == 'if' then
                local taken = false
                for _, c in ipairs(s.clauses) do
                    if not taken and eval(c.cond, env) then
                        taken = true
                        local done, v = exec_block(c.body, env)
                        if done then return done, v end
                    end
                end
                if not taken then
                    local done, v = exec_block(s.els, env)
                    if done then return done, v end
                end
            elseif op == 'fornum' then
                for i = eval(s.from, env), eval(s.to, env), eval(s.step, env) do
                    env[s.id] = i
                    local done, v = exec_block(s.body, env)
                    if done == BREAK then break end
                    if done then return true, v end
                end
            elseif op == 'forin' then
                local it = s.kind == 'ipairs' and ipairs or pairs
                for k, v in it(eval(s.e, env)) do
                    env[s.kid] = k
                    if s.vid then env[s.vid] = v end
                    local done, rv = exec_block(s.body, env)
                    if done == BREAK then break end
                    if done then return true, rv end
                end
            elseif op == 'while' or op == 'repeat' then
                -- (no host while: mix stays inside the S it accepts by habit — a bounded for, the step budget the bound)
                for _ = 1, math.huge do
                    if op == 'while' and not eval(s.cond, env) then break end
                    local done, v = exec_block(s.body, env)
                    if done == BREAK then break end
                    if done then return true, v end
                    if op == 'repeat' and eval(s.cond, env) then break end
                end
            elseif op == 'do' then
                local done, v = exec_block(s.body, env)
                if done then return done, v end
            else refuse('the IR statement ' .. tostring(op)) end
        end
        return false, nil
    end
    return { eval = eval, eval_multi = eval_multi, evals = evals, exec = exec_block, R = R }
end

-- run(prog, fname, args, budget) -> value, steps. The budget refuses by name when exhausted.
function M.run(prog, fname, args, budget)
    local ev = M.evaluator(prog, budget)
    local f = prog.funcs[fname]
    if not f then refuse('no function ' .. tostring(fname)) end
    local env = {}
    for i, id in ipairs(f.params) do env[id] = args[i] end
    local _, vs = ev.exec(f.body, env)
    return vs and vs[1], ev.R.steps
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
    if op == 'global' and (CONSTS[e.name] ~= nil or KNOWN[e.name] ~= nil) then return S end
    if op == 'fn' then return S end
    if op == 'var' then return bt[e.id] or S end
    if op == 'lambda' then
        for _, id in ipairs(e.free) do if (bt[id] or S) ~= S then return C end end
        return S
    end
    if op == 'bin' then return opnd(join(bt_expr(e.l, bt), bt_expr(e.r, bt))) end
    if op == 'un' then return opnd(bt_expr(e.e, bt)) end
    if op == 'index' then
        if assumed_read(e) then return S end -- (speculated: its value is the assumption's, guarded at run time)
        return opnd(join(bt_expr(e.obj, bt), bt_expr(e.key, bt)))
    end
    if op == 'table' then
        local r = S
        for _, f in ipairs(e.fields) do r = join(r, join(bt_expr(f.key, bt), bt_expr(f.val, bt))) end
        if e.rest then r = join(r, bt_expr(e.rest, bt)) end
        return opnd(r)
    end
    if op == 'call' or op == 'prim' then
        local r = S
        for _, a in ipairs(e.args) do r = join(r, bt_expr(a, bt)) end
        if op == 'prim' and EFFECT[e.name] then return D end -- (a mutation or a raise: never computed early)
        return opnd(r)
    end
    if op == 'method' then
        local r = bt_expr(e.obj, bt)
        for _, a in ipairs(e.args) do r = join(r, bt_expr(a, bt)) end
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

-- the variable a store's target is rooted in (`t` of `t.a[i]`), or nil
local function store_root(t)
    local x = t
    for _ = 1, 1000 do
        if x.op == 'var' then return x end
        if x.op ~= 'index' then return nil end
        x = x.obj
    end
    return nil
end

-- loop: the innermost enclosing loop's record — { dyn = true } once a `break` of it runs under DYNAMIC control
local function bt_block(stmts, bt, ctrl, loop)
    local changed = false
    local function set(id, v)
        local old = bt[id]
        local new = old and join(old, v) or v
        if new ~= old then bt[id] = new; changed = true end
    end
    for _, s in ipairs(stmts) do
        local op = s.op
        if op == 'local' then set(s.id, s.forced and D or bt_expr(s.e, bt))
        elseif op == 'localm' then
            for i, id in ipairs(s.ids) do
                local e = s.es[math.min(i, #s.es)]
                set(id, s.forced and D or (e and bt_expr(e, bt) or S))
            end
        elseif op == 'assignm' then
            for i, t in ipairs(s.targets) do
                local e = s.es[math.min(i, #s.es)]
                local v = join(ctrl, e and bt_expr(e, bt) or S)
                if t.op == 'var' then set(t.id, v)
                else local root = store_root(t); if root then set(root.id, D) end end
            end
        elseif op == 'assign' then
            local v = join(ctrl, bt_expr(s.e, bt)) -- CONGRUENCE: assigned under dynamic control -> D
            if s.target.op == 'var' then set(s.target.id, v)
            else
                -- a store into a table — at any depth, `list.sites[n] = x` — makes the table it is rooted in dynamic (a
                -- static table never changes at run time)
                local root = store_root(s.target)
                if root then set(root.id, D) end
            end
        elseif op == 'if' then
            local c = ctrl
            for _, cl in ipairs(s.clauses) do
                c = join(c, opnd(bt_expr(cl.cond, bt)))
                if bt_block(cl.body, bt, c, loop) then changed = true end
            end
            if bt_block(s.els, bt, c, loop) then changed = true end
        elseif op == 'break' then
            if ctrl == D and loop then loop.dyn = true end
        elseif op == 'fornum' or op == 'forin' or op == 'while' or op == 'repeat' then
            local b
            if op == 'fornum' then b = join(ctrl, opnd(join(bt_expr(s.from, bt), join(bt_expr(s.to, bt), bt_expr(s.step, bt)))))
            elseif op == 'forin' then b = join(ctrl, opnd(bt_expr(s.e, bt)))
            else b = join(ctrl, opnd(bt_expr(s.cond, bt))) end
            if op == 'fornum' then set(s.id, b)
            elseif op == 'forin' then set(s.kid, b); if s.vid then set(s.vid, b) end end
            -- CONGRUENCE OF A BREAK: once a break runs under dynamic control, which iteration is the last is dynamic —
            -- every store in the body is under dynamic control (the code after the loop sees one of several exits).
            -- The loop itself is marked (bt[s] = D): a static condition still cannot unroll it
            local lp = { dyn = bt[s] == D }
            if bt_block(s.body, bt, lp.dyn and D or b, lp) then changed = true end
            if lp.dyn and bt[s] ~= D then
                set(s, D)
                bt_block(s.body, bt, D, lp)
            end
        elseif op == 'do' then
            if bt_block(s.body, bt, ctrl, loop) then changed = true end
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
    for i, id in ipairs(f.params) do
        bt[id] = division[i]
        if prog.forced and prog.forced[id] and division[i] ~= D then
            refuse('the static parameter `' .. tostring(prog.names[id]) .. '` is stored into by a closure (a static table cannot change at run time)')
        end
    end
    return fixpoint(f.body, bt)
end

--- the binding times of a lambda's body: its parameters by the division, its free variables as where it was made
function M.bta_lambda(lam, division, freebt, forced)
    local bt = {}
    for _, id in ipairs(lam.free) do bt[id] = freebt[id] or S end
    for i, id in ipairs(lam.params) do
        bt[id] = division[i] or S
        if forced and forced[id] and bt[id] ~= D then refuse('a static closure argument stored into by a closure (rung 3)') end
    end
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
            else parts[#parts + 1] = id .. '=' .. serialize(M.cval(c, id), (depth or 0) + 1, clos, seen, intable) end
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

-- ── GENERALIZATION (CART-1332): a program point's CONFIGURATION as an ALGEBRA TERM ─────────────────────────────────
--- a static value as an algebra term: a number / string / boolean a lit, a table `tbl` of `kv` pairs (keys in order),
--- a closure `clo:<lambda>` of its free values (a dynamic one a HOLE `v<id>`), anything else a node named by its type. budget:
--- { n } nodes left — past it, nil (the configuration is too big to compare)
local function vterm(v, clos, seen, budget)
    budget.n = budget.n - 1
    if budget.n < 0 then return nil end
    local ty = type(v)
    if ty == 'number' or ty == 'string' or ty == 'boolean' then return { k = 'lit', v = v } end
    if v == nil then return { k = 'nil', kids = {} } end
    if seen[v] then return { k = 'cycle', kids = {} } end
    if ty == 'table' then
        seen[v] = true
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function (a, b) return tostring(a) < tostring(b) end)
        local kids = {}
        for i, k in ipairs(keys) do
            local kt, vt = vterm(k, clos, seen, budget), vterm(v[k], clos, seen, budget)
            if not kt or not vt then return nil end
            kids[i] = { k = 'kv', kids = { kt, vt } }
        end
        seen[v] = nil
        return { k = 'tbl', kids = kids }
    end
    local c = ty == 'function' and clos[v]
    if c then
        seen[v] = true
        local kids = {}
        for i, id in ipairs(c.lam.free) do
            if c.bt[id] == D then kids[i] = { k = 'hole', h = 'v' .. tostring(id) }
            else
                kids[i] = vterm(M.cval(c, id), clos, seen, budget)
                if not kids[i] then return nil end
            end
        end
        seen[v] = nil
        return { k = 'clo:' .. c.lam.id, kids = kids }
    end
    return { k = ty, kids = {} }
end

--- a call's configuration -> the TEMPLATE body `<group>(arg …)` (CART-1341): a dynamic argument is a HOLE `a<i>` — the
--- configuration is a staged instance of the call — a static one its value's term | nil
function M.config_term(group, division, svals, clos)
    local kids, budget = {}, { n = 20000 }
    for i = 1, #division do
        if division[i] == D then kids[i] = { k = 'hole', h = 'a' .. i }
        else
            kids[i] = vterm(svals[i], clos, {}, budget)
            if not kids[i] then return nil end
        end
    end
    return { k = group, kids = kids }
end

--- HOMEOMORPHIC EMBEDDING a ⊴ b: b is a with more around it — b DIVES (a embeds in one of b's kids) or COUPLES (the same
--- head, a's kids embedded in order into a subsequence of b's). A number embeds every number and a string every string
--- (the leaves an unbounded computation grows through); a boolean only itself. MEMOIZED on the (a, b) node pair: each
--- pair is decided once, O(|a|·|b|) — without it diving and coupling reach the same pair along every path, 2^depth
--- (CART-1334). memo: { [a] = { [b] = bool } } shared across calls on the same terms; charge(): called once per pair
--- decided (mix passes its budget's spend)
function M.embeds(a, b, memo, charge)
    memo = memo or {}
    local row = memo[a]
    if not row then
        row = {}
        memo[a] = row
    end
    if row[b] ~= nil then return row[b] end
    if charge then charge() end
    local r = false
    if a.k == 'lit' and b.k == 'lit' then
        local ta = type(a.v)
        r = ta == type(b.v) and (ta == 'number' or ta == 'string' or a.v == b.v)
    elseif b.k == 'hole' then r = a.k == 'hole' -- (every dynamic value is one symbol; a hole has no kids to dive into)
    elseif b.k ~= 'lit' then
        for _, c in ipairs(b.kids) do if not r and M.embeds(a, c, memo, charge) then r = true end end
        if not r and a.k == b.k then
            -- (the leftmost kid each of a's kids embeds in: no later choice can do better. No while/break: mix stays
            -- inside S)
            local j, all = 1, true
            for _, x in ipairs(a.kids) do
                local at = nil
                if all then
                    for i = j, #b.kids do if not at and M.embeds(x, b.kids[i], memo, charge) then at = i end end
                end
                if at then j = at + 1 else all = false end
            end
            r = all
        end
    end
    row[b] = r
    return r
end

--- specialize prog's `fname` to the static values of the S parameters -> residual program { funcs = { name -> { name,
--- params = { rname … }, body } }, entry }, stats. opts: budget (unfold steps), name (the entry's residual name)
function M.specialize(prog, fname, division, statics, opts)
    opts = opts or {}
    KNOWN = opts.globals or {}
    ASSUME = opts.assume or {}
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
    -- ITERATION SCOPES: every loop body specialized (an unrolled iteration, a residual loop's body) is a token on
    -- iters while it is. A closure capturing a DYNAMIC per-iteration local carries its residual NAME, declared in that
    -- iteration's residual block: used after the iteration — lifted, unfolded, passed to a program point — the name
    -- would be out of scope, so that use refuses by name
    local iters, active, ntok = {}, {}, 0
    local function cut_iters(n)
        for i = #iters, n + 1, -1 do active[iters[i]] = nil; iters[i] = nil end
    end
    local function check_iter(c)
        if c.iter and not active[c.iter] then
            refuse('a closure capturing a dynamic local of one loop iteration, used after that iteration (rung 2: no upvalue boxes)')
        end
    end
    -- an ASSUMED read of the dynamic variable `obj` (evaluated now, in `current`): guard it before the statement being
    -- specialized -> true when it can be guarded (the variable has a residual name and a statement is collecting)
    function R.on_assume(obj, field)
        local X = current
        local nm = X and X.ren[obj.id]
        if not nm or not X.guards then return false end
        local k = nm .. '.' .. field
        if not X.guards[k] then
            X.guards[k] = true
            X.guards[#X.guards + 1] = { op = 'if', clauses = { { cond = { op = 'bin', o = 'and',
                l = { op = 'bin', o = '==', l = { op = 'prim', name = 'type', args = { { op = 'var', name = nm } } }, r = { op = 'str', v = 'table' } },
                r = { op = 'bin', o = '~=', l = { op = 'index', obj = { op = 'var', name = nm }, key = { op = 'str', v = field } }, r = scalar_ir(ASSUME[field].value) } },
                body = { { op = 'callstmt', e = { op = 'prim', name = 'MIXDEOPT', args = {} } } } } }, els = {} }
        end
        return true
    end
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
        for _, id in ipairs(c.lam.pin or {}) do
            if c.bt[id] == D then c.iter = iters[#iters]; break end
        end
    end
    -- STATIC evaluation. A Lua error it raises (not a refusal) is the PROGRAM's — a static computation in an arm the
    -- template makes invalid (`t.kids[1]` of a node with no kids, under a dynamic guard): it is raised as LAZY and
    -- becomes a residual `error(...)` where the statement stood (the original raises there only if it gets there)
    local function lazy(f, a, X)
        current = X
        local ok, v = pcall(f, a, X.env)
        if ok then return v end
        if type(v) == 'table' then error(v, 0) end
        local msg = tostring(v):gsub('^[^:]*:%d+: ', '')
        -- (where it happened in the ORIGINAL — the innermost statement the evaluator ran — when the program has a map)
        error({ lazy = msg, where = prog.where and prog.where(R.at) or nil }, 0)
    end
    local function sval(e, X) return lazy(ev.eval, e, X) end
    local function svalm(e, X) return lazy(ev.eval_multi, e, X) end
    local function svall(es, X) return lazy(ev.evals, es, X) end
    local unfolding = {} -- program points being unfolded right now: a recursive one becomes a program point instead
    -- (an unfold is a TRANSACTION: the program points it creates are rolled back when it fails — a failed attempt must
    -- not leave a memoized name whose body was never built)
    local mlog = {}
    local function mark() return #res.order, #mlog end
    local function rollback(no, nm)
        for i = #res.order, no + 1, -1 do res.funcs[res.order[i]] = nil; res.order[i] = nil end
        for i = #mlog, nm + 1, -1 do memo[mlog[i]] = nil; mlog[i] = nil end
    end
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
    -- (calls of the same FUNCTION: a closure's lambda whatever it captured — its free values are in its configuration)
    local function group(T) if T.kind == 'fn' then return T.name end return 'λ' .. T.c.lam.id end
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
            else btcache[key] = M.bta_lambda(T.c.lam, division, T.c.bt, prog.forced) end
        end
        return btcache[key]
    end
    -- a new specialization context for T's body: { bt, env, ren, frame }; a closure target's free variables bound as it
    -- carries them (static ones to their values, dynamic ones to their residual names in the caller). frame: the CALL
    -- whose body it is — { g, division, svals, parent, cand }, its parent the call whose body that call was made in: the
    -- ACTIVE CALLS are this chain, so an error caught anywhere leaves nothing stale behind
    local function context(T, division, frame)
        local X = { bt = bt_of(T, division), env = {}, ren = {}, frame = frame }
        if T.kind == 'lam' then
            check_iter(T.c)
            for _, id in ipairs(T.c.lam.free) do
                if T.c.bt[id] == D then X.env[id] = DYN; X.ren[id] = T.c.dfree[id] else X.env[id] = M.cval(T.c, id) end
            end
        end
        return X
    end

    local spec_block, rexpr, lift, dnames, table_rest
    -- a loop body specialized inside its own ITERATION SCOPE
    local function loop_body(stmts, X)
        local n = #iters
        ntok = ntok + 1
        iters[n + 1] = ntok
        active[ntok] = true
        local b, d = spec_block(stmts, X)
        cut_iters(n)
        return b, d
    end
    -- the CONSTANT POOL: a static table (or a host value with no path from a known global) that reaches dynamic code
    -- is REFERENCED, not copied — MIXK[i], a table handed to the residual chunk's environment (res.pool): identity and
    -- sharing kept. Only data the program never stores into gets here (a table stored into is dynamic)
    local pool, poolix = {}, {}
    res.pool = pool
    local function constref(v)
        local i = poolix[v]
        if not i then i = #pool + 1; pool[i] = v; poolix[v] = i end
        return { op = 'index', obj = { op = 'gref', name = 'MIXK' }, key = { op = 'num', v = i } }
    end
    -- GENERALIZE: a parameter static at the call (division S / C) that the body makes DYNAMIC (`iend = iend or #ik`)
    -- starts the residual body as a local holding its lifted value
    local function generalize(params, division, X)
        local pro = {}
        for i, id in ipairs(params) do
            if division[i] ~= D and X.bt[id] == D then
                local e = lift(X.env[id], X)
                X.env[id] = DYN
                X.ren[id] = rname(id)
                pro[#pro + 1] = { op = 'local', name = rname(id), e = e }
            end
        end
        return pro
    end
    local function prepend(pro, body)
        if #pro == 0 then return body end
        for _, x in ipairs(body) do pro[#pro + 1] = x end
        return pro
    end

    -- a static value as residual IR (lifting); a closure becomes a residual function expression
    function lift(v, X)
        local ty = type(v)
        if ty == 'number' then
            -- (a non-finite number has no literal: lifted as the division that makes it — no global needed)
            if v ~= v then return { op = 'bin', o = '/', l = { op = 'num', v = 0 }, r = { op = 'num', v = 0 } } end
            if v == math.huge then return { op = 'bin', o = '/', l = { op = 'num', v = 1 }, r = { op = 'num', v = 0 } } end
            if v == -math.huge then return { op = 'bin', o = '/', l = { op = 'num', v = -1 }, r = { op = 'num', v = 0 } } end
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
            local X2 = context(T, division, X.frame)
            local params = {}
            for i, id in ipairs(c.lam.params) do X2.env[id] = DYN; X2.ren[id] = rname(id); params[i] = rname(id) end
            local body = spec_block(c.lam.body, X2)
            depth = depth - 1
            return { op = 'lambda', params = params, body = body }
        end
        if ty == 'table' then return constref(v) end
        refuse('a static ' .. ty .. ' reaches dynamic code')
    end

    -- the RESIDUAL NAMES a static value carries: every dynamic free variable of every closure reachable from it (through
    -- closures' static free values and tables), as `id=name` into out — what an unfolded expression reads by name
    function dnames(v, seen, out)
        if type(v) == 'function' then
            local c = R.clos[v]
            if not c or seen[c] then return end
            seen[c] = true
            for _, id in ipairs(c.lam.free) do
                if c.dfree[id] then out[#out + 1] = id .. '=' .. c.dfree[id] else dnames(M.cval(c, id), seen, out) end
            end
        elseif type(v) == 'table' and not seen[v] then
            seen[v] = true
            for _, x in pairs(v) do if type(x) == 'function' or type(x) == 'table' then dnames(x, seen, out) end end
        end
    end
    -- UNFOLD: T's body specialized to (division, svals) in place -> its single returned expression, the residual
    -- names of its dynamic parameters (holes, substituted by the caller) | nil
    local function unfold(T, division, svals, frame)
        local key = t_key(T) .. ':' .. table.concat(division, '') .. ':' .. args_key(svals, #division, R.clos)
        if unfolding[key] then return nil end
        -- THE OUTCOME IS MEMOIZED per configuration — the body is specialized once, not once per call site: an unrolled
        -- static loop calls the same helper with the same configuration again and again (compiling match: 105,972
        -- attempts over 138 configurations, 70,714 of them re-discovering the same failure, CART-1455). Kept in `memo`,
        -- so a rolled-back transaction forgets it with the program points its residual may call. A closure's key also
        -- names the residual variables its dynamic free values live in: the unfolded expression reads them directly
        -- (MODULO RENAMING: the names are fresh in every nested unfold — `#hole9537` here, `#hole26511` there — so the key
        -- holds them as placeholders by first occurrence, and a hit renames the stored residual's names to this call's)
        local names = {}
        if T.kind == 'lam' then dnames(T.c.fn, {}, names) end
        for i = 1, #division do dnames(svals[i], {}, names) end
        local canon, order, idx = {}, {}, {}
        for i, s in ipairs(names) do
            local id, nm = s:match('^(.-)=(.*)$')
            if not idx[nm] then order[#order + 1] = nm; idx[nm] = #order end
            canon[i] = id .. '=@' .. idx[nm]
        end
        local ukey = 'unfold:' .. key .. ':' .. table.concat(canon, ',')
        local m = memo[ukey]
        if m == false then return nil end
        if m then
            local subst, any, captured = {}, false, false
            for k, old in ipairs(m.order) do
                if old ~= order[k] then
                    subst[old] = { op = 'var', name = order[k] }; any = true
                    -- (a name the stored residual also BINDS — a lifted function's local — would be renamed away from its
                    -- binder: no reuse, the configuration is specialized afresh)
                    if m.bound[old] then captured = true end
                end
            end
            if not any then return m.inl, m.hs end
            if not captured then return M.substitute(m.inl, subst), m.hs end
            m = nil
        end
        unfolding[key] = true
        enter('unfold')
        local X2 = context(T, division, frame)
        local hs = {}
        for i, id in ipairs(t_params(T)) do
            if division[i] == D then
                holes = holes + 1
                X2.env[id] = DYN
                X2.ren[id] = '#hole' .. holes -- (no residual name can collide with it)
                hs[#hs + 1] = X2.ren[id]
            else X2.env[id] = svals[i] end
        end
        local no, nm, d0 = mark()
        d0 = depth
        local ni = #iters
        local ok, body = pcall(function ()
            local pro = generalize(t_params(T), division, X2)
            return prepend(pro, (spec_block(t_body(T), X2)))
        end)
        unfolding[key] = nil
        depth = d0 - 1
        cut_iters(ni)
        if not ok then
            rollback(no, nm)
            -- (FAIL FAST on a refusal no retry can escape: a budget, the depth, and a KEY that cannot be formed — a static
            -- value nested too deep is a property of the configuration, so the program point the caller falls back to
            -- meets the same key again: 19,585 rollbacks of fully built points compiling one template, CART-1455)
            if type(body) == 'table' and body.refusal and (body.refusal:find('budget', 1, true) or body.refusal:find('depth', 1, true)
                or body.refusal:find('nested deeper than', 1, true)) then error(body, 0) end
            if type(body) ~= 'table' then error(body, 0) end
            memo[ukey] = false
            mlog[#mlog + 1] = ukey
            return nil
        end
        memo[ukey] = false
        -- (a body with an assumption's GUARDS is no single `return e`: it becomes a program point. Folding the guards into
        -- the expression was measured to fire on no template, CART-1463)
        if #body == 1 and body[1].op == 'ret' and #body[1].es == 1 then
            memo[ukey] = { inl = body[1].es[1], hs = hs, order = order, bound = M.bound_names(body[1].es[1], {}) }
        end
        mlog[#mlog + 1] = ukey
        if memo[ukey] then return memo[ukey].inl, hs end
        return nil
    end

    -- a PROGRAM POINT for T under (division, svals) -> its residual name, the extra arguments the call passes: the
    -- dynamic free variables of every closure in it (T's own first, then the arguments', depth first), which the
    -- residual function takes as parameters under fresh names
    local function point(T, division, svals, frame)
        local extra_args, extra_params = {}, {}
        local cloned, nc = {}, 0
        local function clone(c)
            if cloned[c] then return cloned[c] end
            check_iter(c)
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
                elseif b == C and R.clos[M.cval(c, id)] then env[id] = clone(R.clos[M.cval(c, id)]).fn
                else env[id] = M.cval(c, id) end
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
        mlog[#mlog + 1] = key
        local rf = { name = name, params = {}, body = nil }
        res.funcs[name] = rf
        res.order[#res.order + 1] = name
        local X2 = context(T2, division, frame)
        for i, id in ipairs(params) do
            if division[i] == D then X2.env[id] = DYN; X2.ren[id] = rname(id); rf.params[#rf.params + 1] = rname(id)
            else X2.env[id] = csvals[i] end
        end
        for _, p in ipairs(extra_params) do rf.params[#rf.params + 1] = p end
        enter('program point')
        local pro = generalize(params, division, X2)
        rf.body = prepend(pro, (spec_block(t_body(T2), X2)))
        depth = depth - 1
        return name, extra_args
    end

    -- the WHISTLE's answer, asked only when a recursion ran past the depth: the nearest active call of the same function
    -- (anc) EMBEDS this one (fr) — fr grew from it — and A.join of their CONFIGURATIONS (algebra terms) puts a HOLE in
    -- the static arguments that changed -> { [i] = true } the parameters to GENERALIZE (made dynamic, their values
    -- lifted at the call) | nil. A hole in a closure argument is no answer (lifting a closure is not generalizing it)
    local function has_hole(t)
        if t.k == 'hole' then return true end
        for _, c in ipairs(t.kids or {}) do if has_hole(c) then return true end end
        return false
    end
    local function generalization(anc, fr)
        local ta = M.config_term(fr.g, anc.division, anc.svals, R.clos)
        local tb = M.config_term(fr.g, fr.division, fr.svals, R.clos)
        if not ta or not tb or #ta.kids ~= #tb.kids or not M.embeds(ta, tb, {}, spend) then return nil end
        local j = require('cartograph.algebra').load().join(ta, tb)
        local body = j and j.template.body
        if not body or body.k ~= fr.g then return nil end
        local force, any = {}, false
        for i = 1, #tb.kids do
            if fr.division[i] ~= D and has_hole(body.kids[i]) then
                if type(fr.svals[i]) == 'function' then return nil end
                force[i] = true
                any = true
            end
        end
        if any then return force end
        return nil
    end

    -- THE GENERALIZED CONFIGURATIONS, per function: { template, force } — the configuration a generalization retried
    -- with, as a TEMPLATE (its holes the dynamic arguments, the generalized ones included), and the parameters it made
    -- dynamic. Recorded always; READ only under opts.reuse = 'eager' (USER, 2026-10-03: "we can have both, the eager one
    -- could be useful for code analysis/exploration. But we can keep today's behavior"): a later call whose configuration
    -- is an INSTANCE of a recorded template (A.instance_of) reuses that generalization at once, instead of specializing
    -- to its static values first — the supercompiler's folding: fewer residual functions, less specialization.
    local general = {}
    local function record_general(fr, f2)
        local div = {}
        for i = 1, #fr.division do div[i] = f2[i] and D or fr.division[i] end
        local t = M.config_term(fr.g, div, fr.svals, R.clos)
        if not t then return end
        general[fr.g] = general[fr.g] or {}
        local l = general[fr.g]
        l[#l + 1] = { template = require('cartograph.algebra').load().template(t), force = f2 }
    end
    -- under reuse = 'eager': the parameters to make dynamic for the first recorded generalization this call's
    -- configuration is an instance of — every position where the template has a HOLE and this call is static (the
    -- generalized function is specialized with all of them dynamic, whichever made them so) | nil
    local function eager_force(g, division, svals)
        local l = general[g]
        if opts.reuse ~= 'eager' or not l then return nil end
        local t = M.config_term(g, division, svals, R.clos)
        if not t then return nil end
        local A = require('cartograph.algebra').load()
        local mine = A.template(t)
        for _, e in ipairs(l) do
            if A.instance_of(mine, e.template) then
                local f = {}
                for i, kid in ipairs(e.template.body.kids) do if kid.k == 'hole' and division[i] ~= D then f[i] = true end end
                return f
            end
        end
        return nil
    end

    -- the nearest active call of g at or above the call f, and whether a call of g at or above f is a candidate already
    local function nearest(f, g)
        if not f then return nil, false end
        local a, u = nearest(f.parent, g)
        if f.g == g then return f, u or f.cand == true end
        return a, u
    end

    local call_spec, dispatch
    -- a call of T with argument expressions argexprs, in X -> residual expression. force: parameters made DYNAMIC
    -- whatever their argument (a generalization), its static value lifted
    local function apply_spec(T, argexprs, X, force)
        local params = t_params(T)
        local division, svals, dargs = {}, {}, {}
        local nargs = #argexprs
        for i, a in ipairs(argexprs) do
            local b = bt_expr(a, X.bt)
            local expands = i == nargs and M.MULTI[a.op] and nargs < #params
            if expands and b == S then
                -- (a static call last: its values fill the remaining parameters)
                local vs = svalm(a, X)
                for j = 1, math.max(vs.n, 1) do
                    local p = i + j - 1
                    if force and force[p] then division[p] = D; dargs[#dargs + 1] = lift(vs[j], X)
                    else division[p] = S; svals[p] = vs[j] end
                end
                nargs = i - 1 + math.max(vs.n, 1)
            elseif expands then refuse('the last argument of a call expands several dynamic values into its parameters (rung 3)')
            elseif b == D or (force and force[i]) then division[i] = D; dargs[#dargs + 1] = rexpr(a, X)
            else division[i] = b; svals[i] = sval(a, X) end
        end
        for i = nargs + 1, #params do -- (a missing argument is a static nil)
            if force and force[i] then division[i] = D; dargs[#dargs + 1] = { op = 'nil' } else division[i] = S end
        end
        local g = group(T)
        if not force then
            local ef = eager_force(g, division, svals)
            if ef and next(ef) then return apply_spec(T, argexprs, X, ef) end
        end
        -- ★ A CLOSURE THAT KEEPS GROWING IS MADE DYNAMIC (CART-1456). A continuation built per step — match's go_kids
        -- adds one per template child — nests a little deeper with every call, until no key can be formed for it ("a
        -- static value nested deeper than 20": the configuration itself refuses, so the call is not retried as it is).
        -- Generalizing cannot help (a hole in a closure refuses): instead the call is specialized again ONCE with every
        -- closure argument DYNAMIC — each lifted to a residual function and called at run time — and the chain stops
        -- growing at this call
        if not force then
            local grow = {}
            for i = 1, #division do
                if division[i] ~= D and type(svals[i]) == 'function' and R.clos[svals[i]] then grow[i] = true end
            end
            if next(grow) then
                local no, nm = mark()
                local d0, ni = depth, #iters
                local ok, r = pcall(dispatch, T, argexprs, X, force, g, division, svals, dargs)
                if ok then return r end
                depth = d0
                cut_iters(ni)
                if not (type(r) == 'table' and r.refusal and r.refusal:find('nested deeper than', 1, true)) then error(r, 0) end
                rollback(no, nm)
                return apply_spec(T, argexprs, X, grow)
            end
        end
        return dispatch(T, argexprs, X, force, g, division, svals, dargs)
    end

    -- the call's DISPATCH, its arguments evaluated: a program point / unfold, or a CANDIDATE for generalization
    function dispatch(T, argexprs, X, force, g, division, svals, dargs)
        local anc, under = nearest(X.frame, g)
        local fr = { g = g, division = division, svals = svals, parent = X.frame, at = T.kind == 'fn' and T.f.at or T.c.lam.at }
        if force or not anc or under then return call_spec(T, division, svals, dargs, fr) end
        -- a CANDIDATE: the first call of g under an active call of g. If what it starts runs past the depth, it is
        -- GENERALIZED against that call and specialized again — once (the retry passes force: no candidate again)
        -- (a refusal coming through an UNFOLD attempt finds its program points rolled back and the depth restored by
        -- the attempt's own catch; the mark and the depth here cover a call whose configuration is already being
        -- unfolded above — it goes straight to a program point. No fixture reaches that path: a mutant dropping the
        -- rollback survives)
        fr.cand = true
        local no, nm = mark()
        local d0, ni = depth, #iters
        local ok, r = pcall(call_spec, T, division, svals, dargs, fr)
        if ok then return r end
        depth = d0
        cut_iters(ni)
        if not (type(r) == 'table' and r.refusal and r.refusal:find('specialization depth', 1, true)) then error(r, 0) end
        local f2 = generalization(anc, fr)
        if not f2 then error(r, 0) end
        rollback(no, nm)
        record_general(fr, f2)
        return apply_spec(T, argexprs, X, f2)
    end

    -- T under (division, svals), its dynamic arguments dargs -> the residual call (or the unfolded expression)
    function call_spec(T, division, svals, dargs, fr)
        -- UNFOLD when the callee's residual body is one `return e`: substitute its dynamic parameters
        local inl, hs = unfold(T, division, svals, fr)
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
        local name, extra = point(T, division, svals, fr)
        for _, x in ipairs(extra) do dargs[#dargs + 1] = x end
        return { op = 'call', fn = name, args = dargs }
    end

    -- a static HOST value (a function or table of a known global) in a dynamic position: its PATH from that global
    local function rpath(e, X)
        if e.op == 'global' then return { op = 'gref', name = e.name } end
        if e.op == 'index' then return { op = 'index', obj = rpath(e.obj, X), key = lift(sval(e.key, X), X) } end
        local v = sval(e, X)
        if type(v) == 'table' or type(v) == 'function' then return constref(v) end
        refuse('a static host value reaching dynamic code by no path from a known global')
    end

    -- a residual table's REST (the expanding last positional field): a static call's values become fields at their
    -- indices, a dynamic one stays the residual table's rest -> out
    function table_rest(out, e, X)
        if not e.rest then return out end
        if bt_expr(e.rest, X.bt) == S then
            local vs = svalm(e.rest, X)
            for j = 1, vs.n do out.fields[#out.fields + 1] = { key = { op = 'num', v = e.restat + j - 1 }, val = lift(vs[j], X) } end
            return out
        end
        out.rest, out.restat = rexpr(e.rest, X), e.restat
        return out
    end
    -- a residual expression for e in X; a static e (or a closure) is computed and lifted
    function rexpr(e, X)
        spend()
        if bt_expr(e, X.bt) ~= D then
            -- (a static table CONSTRUCTOR in a dynamic position — a forced or boxed variable's `{}` / `{ 0 }` — is built
            -- at run time from its lifted fields: a table is never lifted whole, and two runs must not share one)
            if e.op == 'table' then
                local fields = {}
                for i, f in ipairs(e.fields) do fields[i] = { key = lift(sval(f.key, X), X), val = rexpr(f.val, X) } end
                return table_rest({ op = 'table', fields = fields }, e, X)
            end
            local v = sval(e, X)
            if (type(v) == 'function' and not R.clos[v]) or type(v) == 'table' then return rpath(e, X) end
            return lift(v, X)
        end
        local op = e.op
        if op == 'var' then
            local nm = X.ren[e.id]
            if not nm then refuse('no residual name for `' .. tostring(prog.names[e.id]) .. '`') end
            return { op = 'var', name = nm }
        end
        if op == 'bin' then
            -- (`and` / `or` with a STATIC left side: its value decides now — the BTA cannot know it, the specializer does)
            if (e.o == 'and' or e.o == 'or') and bt_expr(e.l, X.bt) == S then
                local a = sval(e.l, X)
                if (e.o == 'and' and not a) or (e.o == 'or' and a) then return lift(a, X) end
                return rexpr(e.r, X)
            end
            return { op = 'bin', o = e.o, l = rexpr(e.l, X), r = rexpr(e.r, X) }
        end
        if op == 'un' then return { op = 'un', o = e.o, e = rexpr(e.e, X) } end
        if op == 'index' then return { op = 'index', obj = rexpr(e.obj, X), key = rexpr(e.key, X) } end
        if op == 'table' then
            local fields = {}
            for i, f in ipairs(e.fields) do fields[i] = { key = rexpr(f.key, X), val = rexpr(f.val, X) } end
            return table_rest({ op = 'table', fields = fields }, e, X)
        end
        if op == 'prim' then
            local args = {}
            for i, a in ipairs(e.args) do args[i] = rexpr(a, X) end
            return { op = 'prim', name = e.name, args = args }
        end
        if op == 'method' then
            local args = {}
            for i, a in ipairs(e.args) do args[i] = rexpr(a, X) end
            return { op = 'method', obj = rexpr(e.obj, X), m = e.m, args = args }
        end
        if op == 'call' then return apply_spec({ kind = 'fn', name = e.fn, f = prog.funcs[e.fn] }, e.args, X) end
        if op == 'callv' then
            if bt_expr(e.f, X.bt) == D then
                local args = {}
                for i, a in ipairs(e.args) do args[i] = rexpr(a, X) end
                return { op = 'callv', f = rexpr(e.f, X), args = args }
            end
            local c = R.clos[sval(e.f, X)]
            if not c then
                -- (a HOST function of a known global, called with dynamic arguments: a residual call through its path)
                local args = {}
                for i, a in ipairs(e.args) do args[i] = rexpr(a, X) end
                return { op = 'callv', f = rpath(e.f, X), args = args }
            end
            return apply_spec({ kind = 'lam', c = c }, e.args, X)
        end
        if op == 'global' then refuse('the global `' .. tostring(e.name) .. '` (only the language\'s constants, the primitive table and opts.globals are known)') end
        refuse('residualizing the IR op ' .. tostring(op))
    end

    -- residual expressions for a LIST (a return's, a multiple declaration's): a static call last expands to every value
    local function rexprs(es, X)
        local out = {}
        for i, e in ipairs(es) do
            if i == #es and M.MULTI[e.op] and bt_expr(e, X.bt) == S then
                local vs = svalm(e, X)
                for j = 1, vs.n do out[#out + 1] = lift(vs[j], X) end
            else out[#out + 1] = rexpr(e, X) end
        end
        return out
    end
    local function list_bt(ids, es, bt)
        local any_d, all_d = false, true
        for i = 1, #ids do
            local e = es[math.min(i, #es)]
            local b = bt[ids[i]] or (e and bt_expr(e, bt)) or S
            if b == D then any_d = true else all_d = false end
        end
        return any_d, all_d
    end

    -- residual statements for stmts in X; returns rstmts, done (a return reached under static control)
    function spec_block(stmts, X)
        local out = {}
        local bt, env = X.bt, X.env
        local unrolled
        local function step(s)
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
            elseif op == 'localm' then
                local any_d, all_d = list_bt(s.ids, s.es, bt)
                if not any_d then
                    local vs = svall(s.es, X)
                    for i, id in ipairs(s.ids) do env[id] = vs[i] end
                elseif all_d then
                    local es = rexprs(s.es, X)
                    local names = {}
                    for i, id in ipairs(s.ids) do names[i] = rname(id); env[id] = DYN; X.ren[id] = names[i] end
                    out[#out + 1] = { op = 'localm', names = names, es = es }
                else refuse('a declaration of several values mixing static and dynamic ones (rung 3)') end
            elseif op == 'assignm' then
                local vars = {}
                for i, t in ipairs(s.targets) do vars[i] = t.op == 'var' and t.id or -i end
                local any_d, all_d = false, true
                for i, t in ipairs(s.targets) do
                    local d = t.op ~= 'var' or bt[t.id] == D
                    if d then any_d = true else all_d = false end
                end
                if not any_d then
                    local vs = svall(s.es, X)
                    for i, t in ipairs(s.targets) do env[t.id] = vs[i] end
                elseif all_d then
                    local targets = {}
                    for i, t in ipairs(s.targets) do
                        if t.op == 'var' then
                            local nm = X.ren[t.id]
                            if not nm then refuse('no residual name for `' .. tostring(prog.names[t.id]) .. '`') end
                            targets[i] = { op = 'var', name = nm }
                        else targets[i] = rexpr(t, X) end
                    end
                    out[#out + 1] = { op = 'assignm', targets = targets, es = rexprs(s.es, X) }
                else refuse('a multiple assignment mixing static and dynamic targets (rung 3)') end
            elseif op == 'callstmt' then
                if bt_expr(s.e, bt) == S then sval(s.e, X) -- (a static call, run for its effect)
                else out[#out + 1] = { op = 'callstmt', e = rexpr(s.e, X) } end
            elseif op == 'ret' then
                out[#out + 1] = { op = 'ret', es = rexprs(s.es, X) }
                return true
            elseif op == 'break' then
                -- (residual whatever its control: in a residual loop it is that loop's; in an unrolled one the unrolled
                -- iterations sit in a `repeat … until true`, which it leaves)
                out[#out + 1] = { op = 'break' }
                return BREAK
            elseif op == 'if' then
                -- the static prefix of the clauses decides; from the first dynamic condition on, a residual if
                local rclauses, rels, decided = {}, nil, false
                for _, c in ipairs(s.clauses) do
                    if not decided then
                        if #rclauses == 0 and opnd(bt_expr(c.cond, bt)) == S then
                            if sval(c.cond, X) then
                                local body, done = spec_block(c.body, X)
                                for _, x in ipairs(body) do out[#out + 1] = x end
                                if done then return done end
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
                        if done then return done end
                    else
                        rels = spec_block(s.els, X)
                        out[#out + 1] = { op = 'if', clauses = rclauses, els = rels }
                    end
                end
            elseif op == 'fornum' then
                if bt[s.id] == S then -- UNROLL
                    local seq, done = {}, false
                    for i = sval(s.from, X), sval(s.to, X), sval(s.step, X) do
                        spend(10)
                        env[s.id] = i
                        local body, d = loop_body(s.body, X)
                        if #body > 0 then seq[#seq + 1] = { op = 'do', body = body } end
                        if d then done = d; break end
                    end
                    return unrolled(s, seq, done)
                else
                    local from, to, step = rexpr(s.from, X), rexpr(s.to, X), rexpr(s.step, X)
                    env[s.id] = DYN
                    X.ren[s.id] = rname(s.id)
                    out[#out + 1] = { op = 'fornum', name = rname(s.id), from = from, to = to, step = step, body = (loop_body(s.body, X)) }
                end
            elseif op == 'forin' then
                if bt[s.kid] == S then -- UNROLL (pairs: in the order this host iterates — order-sensitive programs are not gated)
                    local it = s.kind == 'ipairs' and ipairs or pairs
                    local seq, done = {}, false
                    for k, v in it(sval(s.e, X)) do
                        spend(10)
                        env[s.kid] = k
                        if s.vid then env[s.vid] = v end
                        local body, d = loop_body(s.body, X)
                        if #body > 0 then seq[#seq + 1] = { op = 'do', body = body } end
                        if d then done = d; break end
                    end
                    return unrolled(s, seq, done)
                else
                    local e = rexpr(s.e, X)
                    env[s.kid] = DYN
                    X.ren[s.kid] = rname(s.kid)
                    if s.vid then env[s.vid] = DYN; X.ren[s.vid] = rname(s.vid) end
                    out[#out + 1] = { op = 'forin', kind = s.kind, e = e, kname = rname(s.kid),
                        vname = s.vid and rname(s.vid) or nil, body = (loop_body(s.body, X)) }
                end
            elseif op == 'while' or op == 'repeat' then
                if opnd(bt_expr(s.cond, bt)) == S and bt[s] ~= D then -- UNROLL (the budget bounds a loop that never ends)
                    local seq, done = {}, false
                    for _ = 1, math.huge do
                        if op == 'while' and not sval(s.cond, X) then break end
                        spend(10)
                        local body, d = loop_body(s.body, X)
                        if #body > 0 then seq[#seq + 1] = { op = 'do', body = body } end
                        if d then done = d; break end
                        if op == 'repeat' and sval(s.cond, X) then break end
                    end
                    return unrolled(s, seq, done)
                end
                -- (every store in a dynamic loop's body is dynamic — the congruence — so its static values hold in
                -- every iteration and the body is specialized once; `until` after the body: it reads the body's locals)
                if op == 'while' then
                    local cond = rexpr(s.cond, X)
                    out[#out + 1] = { op = 'while', cond = cond, body = (loop_body(s.body, X)) }
                else
                    local body = loop_body(s.body, X)
                    out[#out + 1] = { op = 'repeat', body = body, cond = rexpr(s.cond, X) }
                end
            elseif op == 'do' then
                local body, done = spec_block(s.body, X)
                if #body > 0 then out[#out + 1] = { op = 'do', body = body } end
                if done then return done end
            else refuse('specializing the IR statement ' .. tostring(op)) end
            return false
        end
        -- an UNROLLED loop's iterations into out -> done. A STATIC break ended the unrolling: its residual `break`,
        -- the last statement of the last iteration, is dropped. A residual break still there (one under dynamic
        -- control) puts the iterations in `repeat … until true`, which it leaves with the iterations still to come
        function unrolled(_, seq, done)
            local last = seq[#seq]
            if done == BREAK and last and last.body[#last.body].op == 'break' then
                table.remove(last.body)
                if #last.body == 0 then table.remove(seq) end
            end
            if breaks(seq) then out[#out + 1] = { op = 'repeat', body = seq, cond = { op = 'bool', v = true } }
            else for _, x in ipairs(seq) do out[#out + 1] = x end end
            return done == true
        end
        for _, s in ipairs(stmts) do
            spend()
            R.at = s.at
            -- (the GUARDS of the assumptions this statement's static parts made go BEFORE its residual)
            local mark0, prevg = #out, X.guards
            X.guards = {}
            local okst, done = pcall(step, s)
            local gs = X.guards
            X.guards = prevg
            for i, g in ipairs(gs) do table.insert(out, mark0 + i, g) end
            if not okst then
                if type(done) == 'table' and done.lazy then
                    -- (with a position, the residual raises the ORIGINAL's message whole: `error(msg, 0)`)
                    local args = { { op = 'str', v = done.lazy } }
                    if done.where then args = { { op = 'str', v = done.where .. ': ' .. done.lazy }, { op = 'num', v = 0 } } end
                    out[#out + 1] = { op = 'callstmt', e = { op = 'prim', name = 'error', args = args } }
                    return out, true
                end
                -- (a refusal is LOCATED: the innermost statement and the active calls)
                if type(done) == 'table' and done.refusal and not done.at then
                    done.at, done.where = s.at, prog.where and prog.where(s.at) or nil
                    done.chain = {}
                    local fr = X.frame
                    for _ = 1, 200 do
                        if not fr then break end
                        done.chain[#done.chain + 1] = fr.g .. (fr.at and prog.where and prog.where(fr.at) and (' (' .. prog.where(fr.at) .. ')') or '')
                        fr = fr.parent
                    end
                end
                error(done, 0)
            end
            if done then return out, done end
        end
        return out, false
    end

    local root = { g = fname, division = division, svals = statics, at = prog.funcs[fname] and prog.funcs[fname].at }
    local entry = point({ kind = 'fn', name = fname, f = prog.funcs[fname] }, division, statics, root)
    res.entry = entry
    return res, { unfold_steps = used, functions = #res.order }
end

-- ── residual IR helpers ────────────────────────────────────────────────────────────────────────────────────────────
local count_block

--- count the uses of each residual variable name in a residual expression (a use inside a function expression counts
--- as MANY: when and how often it runs is the lambda's call sites')
function M.count_uses(e, uses, w)
    w = w or 1
    local op = e.op
    if op == 'var' then uses[e.name] = (uses[e.name] or 0) + w
    elseif op == 'bin' then M.count_uses(e.l, uses, w); M.count_uses(e.r, uses, w)
    elseif op == 'un' then M.count_uses(e.e, uses, w)
    elseif op == 'index' then M.count_uses(e.obj, uses, w); M.count_uses(e.key, uses, w)
    elseif op == 'table' then
        for _, f in ipairs(e.fields) do M.count_uses(f.key, uses, w); M.count_uses(f.val, uses, w) end
        if e.rest then M.count_uses(e.rest, uses, w) end
    elseif op == 'call' or op == 'prim' then for _, a in ipairs(e.args) do M.count_uses(a, uses, w) end
    elseif op == 'callv' then M.count_uses(e.f, uses, w); for _, a in ipairs(e.args) do M.count_uses(a, uses, w) end
    elseif op == 'method' then M.count_uses(e.obj, uses, w); for _, a in ipairs(e.args) do M.count_uses(a, uses, w) end
    elseif op == 'lambda' then count_block(e.body, uses, 2) end
end
function count_block(stmts, uses, w)
    for _, s in ipairs(stmts) do
        local op = s.op
        if op == 'local' or op == 'callstmt' then M.count_uses(s.e, uses, w)
        elseif op == 'ret' or op == 'localm' then for _, e in ipairs(s.es) do M.count_uses(e, uses, w) end
        elseif op == 'assign' then M.count_uses(s.target, uses, w); M.count_uses(s.e, uses, w)
        elseif op == 'assignm' then
            for _, t in ipairs(s.targets) do M.count_uses(t, uses, w) end
            for _, e in ipairs(s.es) do M.count_uses(e, uses, w) end
        elseif op == 'if' then
            for _, c in ipairs(s.clauses) do M.count_uses(c.cond, uses, w); count_block(c.body, uses, w) end
            count_block(s.els, uses, w)
        elseif op == 'fornum' then
            M.count_uses(s.from, uses, w); M.count_uses(s.to, uses, w); M.count_uses(s.step, uses, w); count_block(s.body, uses, w)
        elseif op == 'forin' then M.count_uses(s.e, uses, w); count_block(s.body, uses, w)
        elseif op == 'while' or op == 'repeat' then M.count_uses(s.cond, uses, w); count_block(s.body, uses, w)
        elseif op == 'do' then count_block(s.body, uses, w) end
    end
end

--- the residual names a residual expression BINDS (a lifted function's parameters, its locals, its loop variables)
--- into set -> set
function M.bound_names(e, set)
    if type(e) ~= 'table' then return set end
    local op = e.op
    if op == 'lambda' then for _, p in ipairs(e.params or {}) do set[p] = true end end
    if op == 'local' and e.name then set[e.name] = true end
    if op == 'localm' then for _, n in ipairs(e.names or {}) do set[n] = true end end
    if op == 'fornum' and e.name then set[e.name] = true end
    if op == 'forin' then
        if e.kname then set[e.kname] = true end
        if e.vname then set[e.vname] = true end
    end
    for k, v in pairs(e) do if k ~= 'op' and type(v) == 'table' then M.bound_names(v, set) end end
    return set
end

--- UNFOLD's substitution is the ALGEBRA's (CART-1341 step 8): the inlined residual expression seen through the lens
--- (cartograph.mixterm), its placeholder variables made HOLES, filled by A.instantiate with the dynamic arguments' terms,
--- and the IR read back. The hand-rolled walk this replaces substituted the same names in the same places — the 33
--- compiled luajs matchers are byte-identical across the change.
function M.substitute(e, subst)
    local MT, A = require 'cartograph.mixterm', require('cartograph.algebra').load()
    local T = A.template(MT.holes(MT.to_term(e), subst))
    local V = {}
    for h in pairs(T.holes) do V[h] = MT.to_term(subst[h]) end -- (only the holes the expression has: a parameter
    local r = A.instantiate(T, V)                                --  the body never reads is no hole)
    if not r.ok then
        refuse('the algebra refused an unfold\'s substitution: unfilled ' .. table.concat(r.unfilled or {}, ',') .. '; rejected '
            .. table.concat(r.rejected or {}, ',') .. '; extra ' .. table.concat(r.extra or {}, ','))
    end
    return MT.of_term(r.term)
end

-- ── PRINT: residual IR -> Lua text ─────────────────────────────────────────────────────────────────────────────────
-- (every compound expression is parenthesized: no precedence table to keep right)
local pblock, pexpr
-- (while printing a program of many functions: the table its functions are fields of — M.print sets it)
local FNTABLE = nil
-- an expression in a PREFIX position (indexed, called): a literal or constructor there is no Lua syntax — `nil[k]`,
-- `"s"[k]`, `{ … }[k]` — so it is parenthesized (and `(nil)[k]` raises at run time, as the original would)
local PREFIXOK = { var = true, gref = true, index = true, call = true, prim = true, callv = true, method = true, lambda = true }
local function prefix(e, ind)
    local t = pexpr(e, ind)
    if PREFIXOK[e.op] then return t end
    return '(' .. t .. ')'
end
function pexpr(e, ind)
    ind = ind or ''
    local op = e.op
    if op == 'num' then
        if e.v == math.floor(e.v) and e.v > -1e15 and e.v < 1e15 then return string.format('%d', e.v) end
        return string.format('%.17g', e.v)
    end
    if op == 'str' then return string.format('%q', e.v) end
    if op == 'bool' then return tostring(e.v) end
    if op == 'nil' then return 'nil' end
    if op == 'var' or op == 'gref' then return e.name end
    if op == 'bin' then return '(' .. pexpr(e.l, ind) .. ' ' .. e.o .. ' ' .. pexpr(e.r, ind) .. ')' end
    if op == 'un' then return '(' .. e.o .. (e.o == 'not' and ' ' or '') .. pexpr(e.e, ind) .. ')' end
    if op == 'index' then return prefix(e.obj, ind) .. '[' .. pexpr(e.key, ind) .. ']' end
    if op == 'table' then
        local parts = {}
        -- (a REST expands in Lua only as the last POSITIONAL field: printed positionally after fields that are exactly
        -- the positions before it — `{ a, b, f() }` — or, past anything else, appended at its index at run time)
        local positional = e.rest ~= nil
        for i, f in ipairs(e.fields) do
            if not (f.key.op == 'num' and f.key.v == i) then positional = false end
        end
        if e.rest and positional and #e.fields == e.restat - 1 then
            for i, f in ipairs(e.fields) do parts[i] = pexpr(f.val, ind) end
            parts[#parts + 1] = pexpr(e.rest, ind)
            return '{ ' .. table.concat(parts, ', ') .. ' }'
        end
        for i, f in ipairs(e.fields) do parts[i] = '[' .. pexpr(f.key, ind) .. '] = ' .. pexpr(f.val, ind) end
        local t = '{ ' .. table.concat(parts, ', ') .. ' }'
        if not e.rest then return t end
        return ('(function (t, ...) for i = 1, select("#", ...) do t[%d + i - 1] = (select(i, ...)) end return t end)(%s, %s)')
            :format(e.restat, t, pexpr(e.rest, ind))
    end
    if op == 'method' then
        local parts = {}
        for i, a in ipairs(e.args) do parts[i] = pexpr(a, ind) end
        return '(' .. pexpr(e.obj, ind) .. '):' .. e.m .. '(' .. table.concat(parts, ', ') .. ')'
    end
    if op == 'call' or op == 'prim' or op == 'callv' then
        local parts = {}
        for i, a in ipairs(e.args) do parts[i] = pexpr(a, ind) end
        local f = op == 'callv' and prefix(e.f, ind) or (e.fn or e.name)
        if op == 'call' and FNTABLE then f = FNTABLE .. '.' .. f end
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
        -- (and a call that UNFOLDED to a plain expression is no statement at all: kept as `local _ = e`, any call
        -- inside it still made)
        local t = pexpr(s.e, ind)
        if t:sub(1, 1) == '(' or not M.MULTI[s.e.op] then t = 'local _ = ' .. t end
        out[#out + 1] = ind .. t
    elseif op == 'ret' then
        local parts = {}
        for i, e in ipairs(s.es) do parts[i] = pexpr(e, ind) end
        out[#out + 1] = ind .. 'return' .. (#parts > 0 and (' ' .. table.concat(parts, ', ')) or '')
    elseif op == 'localm' then
        local parts = {}
        for i, e in ipairs(s.es) do parts[i] = pexpr(e, ind) end
        out[#out + 1] = ind .. 'local ' .. table.concat(s.names, ', ') .. (#parts > 0 and (' = ' .. table.concat(parts, ', ')) or '')
    elseif op == 'assignm' then
        local ts, parts = {}, {}
        for i, t in ipairs(s.targets) do ts[i] = pexpr(t, ind) end
        for i, e in ipairs(s.es) do parts[i] = pexpr(e, ind) end
        out[#out + 1] = ind .. table.concat(ts, ', ') .. ' = ' .. table.concat(parts, ', ')
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
    elseif op == 'while' then
        out[#out + 1] = ind .. 'while ' .. pexpr(s.cond, ind) .. ' do'
        pblock(s.body, ind .. '    ', out)
        out[#out + 1] = ind .. 'end'
    elseif op == 'repeat' then
        out[#out + 1] = ind .. 'repeat'
        pblock(s.body, ind .. '    ', out)
        out[#out + 1] = ind .. 'until ' .. pexpr(s.cond, ind)
    elseif op == 'break' then out[#out + 1] = ind .. 'break'
    else refuse('printing the IR statement ' .. tostring(op)) end
end
function pblock(stmts, ind, out) for _, s in ipairs(stmts) do pstmt(s, ind, out) end end

--- a refusal as a sentence: why, WHERE in the original (`src:line`, when the program has a line map, else the line of
--- the text mix read), and the calls that were active (innermost first)
function M.describe(e)
    if type(e) ~= 'table' then return tostring(e) end
    local function short(x) return (tostring(x):gsub('[^%s(]*lua/cartograph/', '')) end -- (display only: `where` stays exact)
    local s = tostring(e.refusal or e.lazy or '?')
    if e.where then s = s .. ' — at ' .. short(e.where) elseif e.at then s = s .. ' — at line ' .. e.at end
    local c = e.chain or {}
    if #c > 0 then
        local shown = {}
        for i, f in ipairs(c) do shown[i] = short(f) end
        -- (a long chain is a RECURSION: the innermost calls, how often each function recurs in between, the outermost)
        if #shown > 8 then
            local mid, order = {}, {}
            for i = 5, #shown - 1 do
                local g = c[i]:match('^(%S+)')
                if not mid[g] then order[#order + 1] = g end
                mid[g] = (mid[g] or 0) + 1
            end
            local parts = {}
            for _, g in ipairs(order) do parts[#parts + 1] = g .. '×' .. mid[g] end
            shown = { shown[1], shown[2], shown[3], shown[4], ('… %d calls: %s …'):format(#c - 5, table.concat(parts, ' ')), shown[#shown] }
        end
        s = s .. ', in ' .. table.concat(shown, ' ← ')
    end
    return s
end

--- the residual program as a Lua chunk: its functions, forward-declared, and `return <entry>`. Past 180 functions
--- they are FIELDS of one table instead (a chunk holds at most 200 locals: a keyed template's matcher had more, and
--- its chunk did not load, CART-1462)
function M.print(res)
    local out = {}
    local names = {}
    for i, n in ipairs(res.order) do names[i] = n end
    FNTABLE = (#names > 180) and 'MIXF' or nil
    if FNTABLE then out[#out + 1] = 'local MIXF = {}'
    else out[#out + 1] = 'local ' .. table.concat(names, ', ') end
    local okp, err = pcall(function ()
        for _, n in ipairs(res.order) do
            local f = res.funcs[n]
            out[#out + 1] = 'function ' .. (FNTABLE and (FNTABLE .. '.') or '') .. n .. '(' .. table.concat(f.params, ', ') .. ')'
            pblock(f.body, '    ', out)
            out[#out + 1] = 'end'
        end
    end)
    local tbl = FNTABLE
    FNTABLE = nil
    if not okp then error(err, 0) end
    out[#out + 1] = 'return ' .. (tbl and (tbl .. '.') or '') .. res.entry
    return table.concat(out, '\n') .. '\n'
end

--- mix(term, fname, division, statics) -> residual Lua text, stats, the constant pool (load the text with MIXK = pool,
--- and opts.globals, in its environment when the residual references them)
function M.mix(term, fname, division, statics, opts)
    local prog = M.lower(term, { lines = opts and opts.lines })
    local res, stats = M.specialize(prog, fname, division, statics, opts)
    return M.print(res), stats, res.pool
end

return M
