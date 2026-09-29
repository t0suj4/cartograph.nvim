-- cartograph.luajs — THE LUA -> JAVASCRIPT EMITTER (CART-1197). One Lua source in, one CommonJS module out, every
-- construct expanded into the TEMPLATE PACK (lua/cartograph/luajs/pack.js) — never into a guess.
--
--   emit(src, file, opts) -> js text, refusals = { { kind, why, line } }, stats
--     opts.pack   the require path of the pack from the emitted module (default './$pack.js')
--
-- THE CONTRACT, which is the arc's honesty invariant applied to a code generator:
--   ★ EVERY construct is emitted by a DECLARED form or REFUSED BY NAME. A refusal is emitted as `$abort("<kind>: <why>")`
--     at the construct's place, so the module still parses and the rest is still translated — one run counts every
--     break, never only the first. The dispatch is over the grammar kinds that occur (44 in lua/, measured), and its
--     default arm refuses.
--   ★ FAITHFUL FOR EVERY RUNTIME TYPE: truthiness, and/or, arithmetic, comparisons, concatenation, # and indexing go
--     through the pack, which decides at run time what the operands ARE. No type is inferred here (~10% of inferred
--     types are fabricated, and in a code generator a fabricated type is a miscompile).
--   ★ REPRESENTATIONS (user decisions 2026-09-29): strings are BYTE strings (a literal's bytes become \xHH escapes);
--     each table constructor's shape comes from cartograph.tblshape — ARRAY -> $arr (1-based), RECORD -> $rec, anything
--     else -> $map; an access is always the pack's representation-polymorphic $idx / $set.
--   ★ SCOPE: a Lua local is a JS `let` with a FRESH name whenever the name is already visible (`local x = x` would be a
--     TDZ error in JS, and two `local x` in one block a SyntaxError); a free name is `$G.<name>`.
-- NOT YET (refused by name): general goto, labels other than the loop-end `continue` idiom, a map constructor whose
-- last positional value is multi-valued, attributes (<const>/<close> are not LuaJIT syntax anyway).
local M = {}

local JS_RESERVED = {}
for w in ([[break case catch class const continue debugger default delete do else enum export extends false finally
    for function if import in instanceof new null return super switch this throw true try typeof var void while with
    yield let static implements interface package private protected public await arguments eval undefined NaN
    Infinity module exports require]]):gmatch('%S+') do JS_RESERVED[w] = true end

local function field_of(n, name) for c, f in n:iter_children() do if f == name then return c end end end
local function fields_of(n, name)
    local out = {}
    for c, f in n:iter_children() do if f == name then out[#out + 1] = c end end
    return out
end
local function named_kids(n)
    local out = {}
    for c in n:iter_children() do if c:named() and c:type() ~= 'comment' then out[#out + 1] = c end end
    return out
end

--- a JS string literal for a BYTE string: printable ASCII as itself, every other byte as \xHH
local function js_str(bytes)
    return '"' .. bytes:gsub('[%z\1-\31\34\92\127-\255]', function (c) return ('\\x%02x'):format(c:byte()) end) .. '"'
end

--- a JS number literal for a Lua number
local function js_num(n)
    if n ~= n then return 'NaN' end
    if n == math.huge then return 'Infinity' end
    if n == -math.huge then return '(-Infinity)' end
    if n == math.floor(n) and math.abs(n) < 2 ^ 53 then return ('%d'):format(n) end
    return ('%.17g'):format(n)
end

function M.emit(src, file, opts)
    opts = opts or {}
    local tree = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]
    local root = tree:root()
    local shapes = require('cartograph.tblshape').of(src, file, tree)
    local T = require 'cartograph.tblshape'
    local refusals, stats = {}, { nodes = 0, refused = 0, arr = 0, rec = 0, map = 0 }
    local function text(n) return vim.treesitter.get_node_text(n, src) end
    local function line(n) return (n:start()) + 1 end
    local function refuse(n, kind, why)
        refusals[#refusals + 1] = { kind = kind, why = why, line = line(n) }
        stats.refused = stats.refused + 1
        return ('$abort(%s)'):format(js_str(kind .. ': ' .. why .. ' (' .. tostring(file) .. ':' .. line(n) .. ')'))
    end
    local tmp = 0
    local function fresh(base) tmp = tmp + 1; return ('$%s%d'):format(base, tmp) end

    -- ★ THE LOCAL HALF IS DECLARED RULES (cartograph.luajs.rules, CART-1199): every node's lossless term, modulo
    -- layout, read over THIS tree — `pterm` finds a node's term, `pnode` the node a rule's hole bound
    local Rules = require 'cartograph.luajs.rules'
    local pterm, pnode, memo = {}, {}, {}
    local read, unread = require('cartograph.algebraread').read_tree(src, 'lua', tree, function (node, t)
        local p = Rules.project(t, memo)
        pterm[node:id()] = p
        pnode[p] = node
    end)
    if read then unread = nil end

    -- ── scopes ───────────────────────────────────────────────────────────────────────────────────────────────────
    local function scope(parent) return { vars = {}, parent = parent, used = parent and parent.used or {} } end
    local function lookup(sc, name)
        while sc do if sc.vars[name] then return sc.vars[name] end; sc = sc.parent end
    end
    local function declare(sc, name)
        local js = JS_RESERVED[name] and (name .. '$') or name
        if lookup(sc, name) or sc.used[js] then
            local i = 1
            while sc.used[js .. '$' .. i] do i = i + 1 end
            js = js .. '$' .. i
        end
        sc.used[js] = true
        sc.vars[name] = js
        return js
    end

    local expr, stmt, block, args_js, explist_js, fn_js

    --- a node by the declared rule its term matches -> its JS | nil. The holes are emitted in SOURCE order (a hole's
    --- emission can mint fresh names, so the order is part of the output)
    local function by_rule(n, sc, ctx)
        local p = pterm[n:id()]
        if not p then return nil end
        local c, vals = Rules.match(p)
        if not c then return nil end
        local order = {}
        for h, v in pairs(vals) do
            local node = pnode[v]
            if not node then error(('luajs rule `%s`: hole %s bound a term with no node'):format(c.lua, h), 0) end
            order[#order + 1] = { h = h, node = node, at = select(3, node:start()) }
        end
        table.sort(order, function (x, y) return x.at < y.at end)
        local js = {}
        for _, o in ipairs(order) do
            local mode = c.as[o.h] or 'expr'
            if mode == 'name' then js[o.h] = js_str(text(o.node))
            elseif mode == 'block' then js[o.h] = block(o.node, scope(sc), ctx)
            else js[o.h] = expr(o.node, sc, mode == 'raw') end
        end
        return Rules.render(c, js)
    end

    --- is this expression multi-valued in a list tail (a call, or `...`)?
    local function multi(n) return n:type() == 'function_call' or n:type() == 'vararg_expression' end

    --- an expression list as JS array items: every value truncated to one except a multi-valued LAST, spread
    function explist_js(nodes, sc)
        local out = {}
        for i, n in ipairs(nodes) do
            if i == #nodes and multi(n) then
                out[#out + 1] = n:type() == 'vararg_expression' and '...$va' or ('...$all(%s)'):format(expr(n, sc, true))
            else
                out[#out + 1] = expr(n, sc)
            end
        end
        return table.concat(out, ', ')
    end

    function args_js(argsnode, sc)
        local kids = named_kids(argsnode)
        -- f "s" and f { … } are a single argument
        return explist_js(kids, sc)
    end


    --- a table constructor in its SHAPE's representation
    local function table_js(n, sc)
        local _, _, start = n:start()
        local sh = shapes[start]
        local rep = T.representation(sh and sh.class or 'OPAQUE')
        local pos, named = {}, {}
        local fields = {}
        for c in n:iter_children() do if c:type() == 'field' then fields[#fields + 1] = c end end
        for i, f in ipairs(fields) do
            local k, v = field_of(f, 'name'), field_of(f, 'value')
            local bracketed = false
            for cc in f:iter_children() do if not cc:named() and cc:type() == '[' then bracketed = true end end
            if not k then
                pos[#pos + 1] = { node = v, last = (i == #fields) }
            elseif not bracketed then
                named[#named + 1] = { key = js_str(text(k)), val = v }
            else
                named[#named + 1] = { key = expr(k, sc), val = v }
            end
        end
        if rep == 'ARRAY' and #named == 0 then
            stats.arr = stats.arr + 1
            local nodes = {}
            for _, p in ipairs(pos) do nodes[#nodes + 1] = p.node end
            return ('$arr(%s)'):format(explist_js(nodes, sc))
        end
        if rep == 'RECORD' and #pos == 0 then
            stats.rec = stats.rec + 1
            local parts = {}
            for _, e in ipairs(named) do parts[#parts + 1] = e.key .. ', ' .. expr(e.val, sc) end
            return ('$rec(%s)'):format(table.concat(parts, ', '))
        end
        stats.map = stats.map + 1
        local parts, spread = {}, nil
        for i, p in ipairs(pos) do
            if p.last and multi(p.node) then
                -- a multi-valued LAST positional entry: its values land at positions i, i+1, … ($mappos)
                spread = { at = i, js = p.node:type() == 'vararg_expression' and '...$va' or ('...$all(%s)'):format(expr(p.node, sc, true)) }
            else
                parts[#parts + 1] = i .. ', ' .. expr(p.node, sc)
            end
        end
        for _, e in ipairs(named) do parts[#parts + 1] = e.key .. ', ' .. expr(e.val, sc) end
        local m = ('$map(%s)'):format(table.concat(parts, ', '))
        if spread then return ('$mappos(%s, %d, %s)'):format(m, spread.at, spread.js) end
        return m
    end

    --- a function call: raw (may be an MV) when `raw`, else truncated to one value
    local function call_js(n, sc, raw)
        local name, argsn = field_of(n, 'name'), field_of(n, 'arguments')
        local a = argsn and args_js(argsn, sc) or ''
        local c
        if name and name:type() == 'method_index_expression' then
            local obj, m = field_of(name, 'table'), field_of(name, 'method')
            c = ('$m(%s, %s%s)'):format(expr(obj, sc), js_str(text(m)), a ~= '' and (', ' .. a) or '')
        else
            local f = expr(name, sc)
            -- EVERY call goes through $call: a missing function fails as Lua's `attempt to call a nil value` (not a JS
            -- TypeError — measured: 36 module loads), and a TABLE with __call is callable. A direct call for locals was an
            -- unfaithful shortcut — it assumed a local holds a function, and the metatables differential caught it
            c = ('$call(%s%s)'):format(f, a ~= '' and (', ' .. a) or '')
        end
        return raw and c or ('$1(%s)'):format(c)
    end

    function expr(n, sc, raw)
        stats.nodes = stats.nodes + 1
        local r = by_rule(n, sc)
        if r then return r end
        local t = n:type()
        if t == 'identifier' then
            local name = text(n)
            return lookup(sc, name) or ('$G.' .. (name:match('^[%a_][%w_]*$') and name or ('[' .. js_str(name) .. ']')))
        elseif t == 'number' then
            local v = tonumber(text(n))
            if not v then return refuse(n, 'number', 'a literal Lua cannot read: ' .. text(n)) end
            return js_num(v)
        elseif t == 'string' then
            local f = load('return ' .. text(n))
            local ok, v = pcall(f or error)
            if not ok or type(v) ~= 'string' then return refuse(n, 'string', 'a literal Lua cannot read') end
            return js_str(v)
        elseif t == 'function_definition' then return fn_js(n, sc, nil)
        elseif t == 'function_call' then return call_js(n, sc, raw)
        elseif t == 'table_constructor' then return table_js(n, sc)
        -- an operator no declared rule covers (5.3's `//`, `&`, …)
        elseif t == 'binary_expression' then
            return refuse(n, 'operator', 'no template for the binary operator ' .. text(field_of(n, 'operator')))
        elseif t == 'unary_expression' then
            return refuse(n, 'operator', 'no template for the unary operator ' .. text(field_of(n, 'operator')))
        end
        return refuse(n, t, 'no template for this expression kind')
    end

    --- a function (definition or declaration body): params, varargs, and `self` for a method
    function fn_js(n, sc, self_name)
        local fsc = scope(sc)
        local params = {}
        if self_name then params[#params + 1] = declare(fsc, 'self') end
        local pnode = field_of(n, 'parameters')
        local va = false
        for _, p in ipairs(pnode and named_kids(pnode) or {}) do
            if p:type() == 'vararg_expression' then va = true
            else params[#params + 1] = declare(fsc, text(p)) end
        end
        if va then params[#params + 1] = '...$va' end
        local body = field_of(n, 'body')
        local inner = body and block(body, fsc, {}) or ''
        -- falling off the end returns NO values (a JS function would return one undefined — one nil)
        local kids = body and named_kids(body) or {}
        local last = kids[#kids]
        if not (last and last:type() == 'return_statement') then inner = inner .. 'return $mv();\n' end
        return ('function (%s) {\n%s}'):format(table.concat(params, ', '), inner)
    end

    --- an assignment target: a JS setter statement for value `v`
    local function assign_to(target, v, sc)
        local t = target:type()
        if t == 'identifier' then
            local name = text(target)
            local js = lookup(sc, name)
            return js and ('%s = %s;'):format(js, v) or ('$G.%s = %s;'):format(name, v)
        elseif t == 'dot_index_expression' then
            return ('$set(%s, %s, %s);'):format(expr(field_of(target, 'table'), sc), js_str(text(field_of(target, 'field'))), v)
        elseif t == 'bracket_index_expression' then
            return ('$set(%s, %s, %s);'):format(expr(field_of(target, 'table'), sc), expr(field_of(target, 'field'), sc), v)
        end
        return refuse(target, 'assignment', 'no template for the target kind ' .. t) .. ';'
    end

    --- ctx: { loop_label = <js label>, continue_label = <lua label>, loop_kind }
    function stmt(n, sc, ctx)
        local t = n:type()
        if t == 'comment' or t == 'empty_statement' then return '' end
        local r = by_rule(n, sc, ctx)
        if r then return r end
        if t == 'variable_declaration' then
            local asg = named_kids(n)[1]
            if asg and asg:type() == 'variable_list' then
                local names = {}
                for _, v in ipairs(named_kids(asg)) do
                    if v:type() == 'attribute' then return refuse(v, 'attribute', 'a <const>/<close> attribute') .. ';' end
                    names[#names + 1] = declare(sc, text(v))
                end
                return ('let %s;'):format(table.concat(names, ', '))
            end
            local vl, el = nil, nil
            for c in asg:iter_children() do
                if c:type() == 'variable_list' then vl = c elseif c:type() == 'expression_list' then el = c end
            end
            local vals = el and named_kids(el) or {}
            local names = vl and named_kids(vl) or {}
            for _, v in ipairs(names) do
                if v:type() == 'attribute' then return refuse(v, 'attribute', 'a <const>/<close> attribute') .. ';' end
            end
            -- the values are evaluated in the scope BEFORE the names exist (the sequential let)
            local js
            if #names == 1 and #vals == 1 then
                js = expr(vals[1], sc)
                return ('let %s = %s;'):format(declare(sc, text(names[1])), js)
            end
            js = ('$adj(%d, [%s])'):format(#names, explist_js(vals, sc))
            local jn = {}
            for _, v in ipairs(names) do jn[#jn + 1] = declare(sc, text(v)) end
            return ('let [%s] = %s;'):format(table.concat(jn, ', '), js)
        elseif t == 'assignment_statement' then
            local vl, el
            for c in n:iter_children() do
                if c:type() == 'variable_list' then vl = c elseif c:type() == 'expression_list' then el = c end
            end
            local targets, vals = named_kids(vl), named_kids(el)
            if #targets == 1 and #vals == 1 then return assign_to(targets[1], expr(vals[1], sc), sc) end
            local tv = fresh('v')
            local out = { ('{ const %s = $adj(%d, [%s]);'):format(tv, #targets, explist_js(vals, sc)) }
            for i, tg in ipairs(targets) do out[#out + 1] = assign_to(tg, ('%s[%d]'):format(tv, i - 1), sc) end
            out[#out + 1] = '}'
            return table.concat(out, ' ')
        elseif t == 'function_call' then
            return expr(n, sc, true) .. ';'
        elseif t == 'function_declaration' then
            local is_local = false
            for c in n:iter_children() do if not c:named() and c:type() == 'local' then is_local = true end end
            local name = field_of(n, 'name')
            if is_local then
                local js = declare(sc, text(name)) -- declared BEFORE the body: a local function sees itself
                return ('let %s; %s = %s;'):format(js, js, fn_js(n, sc, nil))
            end
            if name:type() == 'method_index_expression' then
                return ('$set(%s, %s, %s);'):format(expr(field_of(name, 'table'), sc), js_str(text(field_of(name, 'method'))), fn_js(n, sc, 'self'))
            end
            return assign_to(name, fn_js(n, sc, nil), sc)
        elseif t == 'return_statement' then
            -- no value and one value are declared rules; a LIST is a value-position case
            local el = named_kids(n)[1]
            return ('return $mv(%s);'):format(explist_js(el and named_kids(el) or {}, sc))
        elseif t == 'if_statement' then
            local out = { ('if ($t(%s)) {\n%s}'):format(expr(field_of(n, 'condition'), sc), block(field_of(n, 'consequence'), scope(sc), ctx)) }
            for _, alt in ipairs(fields_of(n, 'alternative')) do
                if alt:type() == 'elseif_statement' then
                    out[#out + 1] = (' else if ($t(%s)) {\n%s}'):format(expr(field_of(alt, 'condition'), sc), block(field_of(alt, 'consequence'), scope(sc), ctx))
                else
                    out[#out + 1] = (' else {\n%s}'):format(block(field_of(alt, 'body'), scope(sc), ctx))
                end
            end
            return table.concat(out)
        elseif t == 'while_statement' then
            local lbl = fresh('L')
            return ('%s: while ($t(%s)) {\n%s}'):format(lbl, expr(field_of(n, 'condition'), sc),
                block(field_of(n, 'body'), scope(sc), { loop_label = lbl, labels = ctx and ctx.labels }))
        elseif t == 'repeat_statement' then
            local lbl = fresh('L')
            local rsc = scope(sc)
            local body = block(field_of(n, 'body'), rsc, { loop_label = lbl, labels = ctx and ctx.labels })
            -- the condition sees the body's locals: it is evaluated INSIDE the body's block
            return ('%s: do {\n%sif ($t(%s)) break;\n} while (true);'):format(lbl, body, expr(field_of(n, 'condition'), rsc))
        elseif t == 'for_statement' then
            local clause = field_of(n, 'clause')
            local lbl = fresh('L')
            local fsc = scope(sc)
            if clause:type() == 'for_numeric_clause' then
                local i, a, b, c, up = fresh('i'), fresh('a'), fresh('b'), fresh('s'), fresh('u')
                local start = expr(field_of(clause, 'start'), sc)
                local stop = expr(field_of(clause, 'end'), sc)
                local step = field_of(clause, 'step') and expr(field_of(clause, 'step'), sc) or '1'
                local var = declare(fsc, text(field_of(clause, 'name')))
                local body = block(field_of(n, 'body'), fsc, { loop_label = lbl, labels = ctx and ctx.labels })
                -- the three values are checked AFTER all are evaluated, as Lua does ($forprep: a number or a numeric string)
                return ('{ const [%s, %s, %s, %s] = $forprep(%s, %s, %s);\n%s: for (let %s = %s; %s ? %s <= %s : %s >= %s; %s += %s) { let %s = %s;\n%s} }')
                    :format(a, b, c, up, start, stop, step, lbl, i, a, up, i, b, i, b, i, c, var, i, body)
            end
            local vl, el
            for cc in clause:iter_children() do
                if cc:type() == 'variable_list' then vl = cc elseif cc:type() == 'expression_list' then el = cc end
            end
            local f, s, ctl = fresh('f'), fresh('s'), fresh('c')
            local init = ('$adj(3, [%s])'):format(explist_js(named_kids(el), sc))
            local vars = {}
            for _, v in ipairs(named_kids(vl)) do vars[#vars + 1] = declare(fsc, text(v)) end
            local body = block(field_of(n, 'body'), fsc, { loop_label = lbl, labels = ctx and ctx.labels })
            return ('{ let [%s, %s, %s] = %s;\n%s: for (;;) { let [%s] = $adj(%d, $all(%s(%s, %s))); if (%s === undefined) break; %s = %s;\n%s} }')
                :format(f, s, ctl, init, lbl, table.concat(vars, ', '), #vars, f, s, ctl, vars[1], ctl, vars[1], body)
        elseif t == 'break_statement' then
            -- Lua's break names ITS loop: a synthetic goto loop (below) between it and the loop must not catch it
            return (ctx and ctx.loop_label) and ('break ' .. ctx.loop_label .. ';') or 'break;'
        elseif t == 'goto_statement' then
            local label = text(named_kids(n)[1])
            local act = ctx and ctx.labels and ctx.labels[label]
            if act then return act .. ';' end
            return refuse(n, 'goto', 'a goto whose label is not visible, or in a shape that crosses another label\'s region') .. ';'
        elseif t == 'label_statement' then
            return '' -- structured by its block
        end
        return refuse(n, t, 'no template for this statement kind') .. ';'
    end

    -- the gotos inside `node` that name `label`, not crossing a function boundary (a label is invisible in nested functions)
    local GQ = vim.treesitter.query.parse('lua', '(goto_statement (identifier) @g)')
    local function jumps_to(node, label)
        for _, g in GQ:iter_captures(node, src, 0, -1) do
            if text(g) == label then
                local p, crossed = g:parent(), false
                while p and not p:equal(node) do
                    local pt = p:type()
                    if pt == 'function_definition' or pt == 'function_declaration' then crossed = true; break end
                    p = p:parent()
                end
                if not crossed then return true end
            end
        end
        return false
    end

    --- a block's statements, with its LABELS structured (every Lua goto has a JS form, by Lua's own scoping rules —
    --- a goto reaches only a label visible in an enclosing block):
    ---   FORWARD   gotos before the label: the statements from the first such goto's statement up to the label become a
    ---             labeled block, `goto L` = `break <block>` (a local declared inside that region cannot be used after the
    ---             label — Lua forbids jumping into its scope — so the region's scope is the right one)
    ---   BACKWARD  gotos after the label: the statements after it to the block's end become a labeled `for (;;)`, `goto L`
    ---             = `continue <loop>` (its `break;` at the end falls out once)
    --- The loop-end `continue` idiom is the forward case (the region ends at the body's end, and a repeat's `until` test
    --- follows the region — so it is no longer a special case). Regions that CROSS without nesting are refused by name.
    function block(n, sc, ctx)
        if not n then return '' end
        local kids = named_kids(n)
        local regions = {} -- { from, to, open, close }
        local fwd_act, bwd_act = {}, {} -- label -> js action, by the side of the label the goto is on
        local label_at = {}
        for k, kid in ipairs(kids) do
            if kid:type() == 'label_statement' then
                local name = text(named_kids(kid)[1])
                label_at[name] = k
                local first
                for i = 1, k - 1 do if jumps_to(kids[i], name) then first = i; break end end
                if first then
                    local jl = fresh('Gf')
                    regions[#regions + 1] = { from = first, to = k - 1, open = jl .. ': {', close = '}' }
                    fwd_act[name] = 'break ' .. jl
                end
                local back = false
                for i = k + 1, #kids do if jumps_to(kids[i], name) then back = true; break end end
                if back then
                    local jl = fresh('Gb')
                    regions[#regions + 1] = { from = k + 1, to = #kids, open = jl .. ': for (;;) {', close = 'break;\n}' }
                    bwd_act[name] = 'continue ' .. jl
                end
            end
        end
        for i = 1, #regions do
            for j = i + 1, #regions do
                local a, b = regions[i], regions[j]
                local nested = (a.from <= b.from and b.to <= a.to) or (b.from <= a.from and a.to <= b.to)
                local apart = a.to < b.from or b.to < a.from
                if not nested and not apart then return refuse(n, 'goto', 'two labels whose goto regions cross') .. ';\n' end
            end
        end
        -- open outer regions first, close inner first
        table.sort(regions, function (a, b) if a.from ~= b.from then return a.from < b.from end return a.to > b.to end)
        local out = {}
        for i, kid in ipairs(kids) do
            for _, r in ipairs(regions) do if r.from == i then out[#out + 1] = r.open .. '\n' end end
            -- the labels this statement sees: a goto BEFORE its label jumps forward, AFTER it backward
            local labels = setmetatable({}, { __index = ctx and ctx.labels })
            for name, k in pairs(label_at) do
                if i < k and fwd_act[name] then labels[name] = fwd_act[name]
                elseif i > k and bwd_act[name] then labels[name] = bwd_act[name] end
            end
            local s = stmt(kid, sc, { loop_label = ctx and ctx.loop_label, labels = labels })
            if s ~= '' then out[#out + 1] = s .. '\n' end
            for j = #regions, 1, -1 do if regions[j].to == i then out[#out + 1] = regions[j].close .. '\n' end end
        end
        return table.concat(out)
    end

    local top = scope(nil)
    -- a source the lossless reader refuses (an error or MISSING node) has no terms to match: the chunk refuses by name
    local body = unread and (refuse(root, 'read', tostring(unread)) .. ';\n') or block(root, top, nil)
    local pack = opts.pack or './$pack.js'
    local names = '$forprep, $t, $and, $or, $mv, $1, $all, $adj, $arr, $rec, $map, $idx, $set, $len, $m, $call, $mappos, $add, $sub, $mul, $div, $mod, $pow, $neg, $cat, $eq, $lt, $le, $gt, $ge, $abort, $G'
    -- the CHUNK is a function of its varargs, as a Lua chunk is: require passes the module name (nvim's own modules
    -- read it — `{ _fold = ..., … }` in vim/treesitter.lua), a script run directly gets its arguments
    local js = ("'use strict';\n// transliterated from %s by cartograph.luajs — do not edit\nconst { %s } = require(%s);\n"
        .. "const $chunk = function (...$va) {\n%s};\nmodule.exports = { $chunk };\n"
        .. "if (require.main === module) $chunk(...process.argv.slice(2));\n")
        :format(tostring(file), names, js_str(pack), body)
    return js, refusals, stats
end

--- ★ THE TREE-SITTER BRIDGE for the transliterated vim.treesitter (lua/cartograph/luajs/tsbridge.c): built by the HOST
--- COMPILER against tree-sitter's own source (`ts_src` = its lib/ dir; default LUAJS_TS_SRC, else the highest pkgit
--- tree-sitter), cached by the hash of both sources. -> the executable | nil, why
function M.bridge(ts_src)
    ts_src = ts_src or vim.env.LUAJS_TS_SRC
    if not ts_src then
        local found = vim.fn.glob(vim.fn.expand('~/.local/share/pkgit/tree-sitter/*/lib/src/lib.c'), false, true)
        table.sort(found, function (a, b) return vim.version.lt(vim.version.parse(a:match('/v?([%d.]+)/lib/')) or { 0 }, vim.version.parse(b:match('/v?([%d.]+)/lib/')) or { 0 }) end)
        ts_src = found[#found] and found[#found]:gsub('/src/lib%.c$', '')
    end
    if not ts_src or vim.fn.filereadable(ts_src .. '/src/lib.c') ~= 1 then return nil, 'no tree-sitter source (set LUAJS_TS_SRC to its lib/ directory)' end
    local here = debug.getinfo(1, 'S').source:sub(2):gsub('[^/]+$', '')
    local csrc = here .. 'luajs/tsbridge.c'
    local key = vim.fn.sha256(table.concat(vim.fn.readfile(csrc, 'b'), '\n') .. ts_src):sub(1, 16)
    local dir = vim.fn.stdpath('cache') .. '/cartograph'
    local exe = dir .. '/tsbridge-' .. key
    if vim.fn.executable(exe) == 1 then return exe end
    vim.fn.mkdir(dir, 'p')
    local r = vim.system({ 'gcc', '-O2', '-std=gnu11', '-w', '-I' .. ts_src .. '/include', '-I' .. ts_src .. '/src', ts_src .. '/src/lib.c', csrc, '-ldl', '-o', exe }, { text = true }):wait()
    if r.code ~= 0 then return nil, 'building the tree-sitter bridge failed: ' .. (r.stderr or '') end
    return exe
end

--- the environment a transliterated module runs in: its root, the bridge, the runtime path parsers are found on
local LUAJS_DIR = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/luajs'

--- the pack's COMPANION files, DERIVED: every `require('./$X.js')` of pack.js and, transitively, of each companion
--- (the matcher, libm's pow, the FPU primitives it needs) -> { { published = '$X.js', source = <lua/cartograph/luajs/X.js> } }
--- — never a hand list: four callers kept one, and a third generated file would have had to be added to each
function M.companions()
    local out, seen, queue = {}, {}, { LUAJS_DIR .. '/pack.js' }
    while #queue > 0 do
        local fd = io.open(table.remove(queue, 1))
        local s = fd and fd:read('a') or ''
        if fd then fd:close() end
        for name in s:gmatch("require%('%./%$([%w_]+)%.js'%)") do
            if not seen[name] then
                seen[name] = true
                out[#out + 1] = { published = '$' .. name .. '.js', source = LUAJS_DIR .. '/' .. name .. '.js' }
                queue[#queue + 1] = LUAJS_DIR .. '/' .. name .. '.js'
            end
        end
    end
    return out
end

--- install the template pack (as `$pack.js`) and every companion beside it in `dir`
function M.install_pack(dir)
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile(vim.fn.readfile(LUAJS_DIR .. '/pack.js', 'b'), dir .. '/$pack.js', 'b')
    for _, c in ipairs(M.companions()) do vim.fn.writefile(vim.fn.readfile(c.source, 'b'), dir .. '/' .. c.published, 'b') end
end

function M.run_env(out_dir, src_root)
    local env = { LUAJS_ROOT = out_dir, LUAJS_SRC_ROOT = src_root }
    env.LUAJS_TS_BRIDGE = M.bridge()
    env.LUAJS_RTP = table.concat(vim.api.nvim_list_runtime_paths(), ':')
    return env
end

--- ★ NVIM'S OWN PURE-LUA RUNTIME, transliterated into `out_dir` (the pack loads vim.split / inspect / fs / uri from it
--- lazily). The modules are DERIVED: the pack's own `$require('vim.…')` names, then every `require('vim.…')` literal
--- inside an emitted runtime module, while its file exists under `vimrt` (default: this nvim's $VIMRUNTIME/lua).
--- -> { { rel, dest, refusals } }
function M.vim_runtime(out_dir, pack_text, vimrt)
    vimrt = vimrt or (vim.env.VIMRUNTIME .. '/lua')
    local queue, queued, out = {}, {}, {}
    local function enqueue(mod) if not queued[mod] then queued[mod] = true; queue[#queue + 1] = mod end end
    for mod in pack_text:gmatch("%$require%('(vim%.[%w_.]+)'%)") do enqueue(mod) end
    -- + nvim's OWN lazy submodule list (vim/_init_packages.lua's `vim._submodules = {…}` and vim/_core/editor.lua's
    -- `for k, v in pairs({…}) do vim._submodules[k] = v`), minus the names the PACK declares as editor surfaces (its
    -- `for (const ed of [...])` refusal list); written as vim/$submodules.json, which the pack's vim miss handler reads
    local function rd(p) local f = io.open(vimrt .. '/' .. p); if not f then return '' end; local s = f:read('a'); f:close(); return s end
    local editor = {}
    local edlist = pack_text:match('for %(const ed of %[(.-)%]%)') or ''
    for nm in edlist:gmatch("'([%w_]+)'") do editor[nm] = true end
    local subs, subset = {}, {}
    local function add_keys(tbl) for key in tbl:gmatch('([%a_][%w_]*)%s*=%s*true') do if not subset[key] and not editor[key] then subset[key] = true; subs[#subs + 1] = key end end end
    add_keys(rd('vim/_init_packages.lua'):match('vim%._submodules%s*=%s*(%b{})') or '')
    add_keys(rd('vim/_core/editor.lua'):match('for k, v in pairs%((%b{})%) do%s*vim%._submodules') or '')
    table.sort(subs)
    for _, key in ipairs(subs) do enqueue('vim.' .. key) end
    vim.fn.mkdir(out_dir .. '/vim', 'p')
    local sj = assert(io.open(out_dir .. '/vim/$submodules.json', 'w')); sj:write(vim.json.encode(subs)); sj:close()
    while #queue > 0 do
        local mod = table.remove(queue, 1)
        local rel = mod:gsub('%.', '/') .. '.lua'
        local fd = io.open(vimrt .. '/' .. rel)
        if fd then
            local src = fd:read('a'); fd:close()
            for dep in src:gmatch("require%s*%(?%s*['\"](vim%.[%w_.]+)['\"]") do enqueue(dep) end
            -- `vim._defer_require('vim.x', { a = …, b = … })` names its submodules only at run time: root .. '.' .. key
            for root, keys in src:gmatch("_defer_require%(%s*['\"](vim[%w_.]*)['\"]%s*,%s*(%b{})") do
                for key in keys:gmatch('([%a_][%w_]*)%s*=') do enqueue(root .. '.' .. key) end
            end
            local depth = select(2, rel:gsub('/', ''))
            local js, refusals = M.emit(src, rel, { pack = ('../'):rep(depth) .. '$pack.js' })
            local dest = out_dir .. '/' .. rel:gsub('%.lua$', '.js')
            vim.fn.mkdir(vim.fn.fnamemodify(dest, ':h'), 'p')
            local w = assert(io.open(dest, 'wb')); w:write(js); w:close()
            out[#out + 1] = { rel = rel, dest = dest, refusals = refusals }
        end
    end
    return out
end

return M

