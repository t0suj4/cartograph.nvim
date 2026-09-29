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

    local BIN = { ['+'] = '$add', ['-'] = '$sub', ['*'] = '$mul', ['/'] = '$div', ['%'] = '$mod', ['^'] = '$pow',
        ['..'] = '$cat', ['<'] = '$lt', ['<='] = '$le', ['>'] = '$gt', ['>='] = '$ge' }

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
        local parts = {}
        for i, p in ipairs(pos) do
            if p.last and multi(p.node) then
                return refuse(p.node, 'map-constructor', 'a multi-valued last positional entry in a Map-shaped constructor')
            end
            parts[#parts + 1] = i .. ', ' .. expr(p.node, sc)
        end
        for _, e in ipairs(named) do parts[#parts + 1] = e.key .. ', ' .. expr(e.val, sc) end
        return ('$map(%s)'):format(table.concat(parts, ', '))
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
        elseif t == 'nil' then return 'undefined'
        elseif t == 'true' then return 'true'
        elseif t == 'false' then return 'false'
        elseif t == 'vararg_expression' then return '$va[0]'
        elseif t == 'function_definition' then return fn_js(n, sc, nil)
        elseif t == 'parenthesized_expression' then
            local inner = named_kids(n)[1]
            return '(' .. expr(inner, sc) .. ')'
        elseif t == 'dot_index_expression' then
            return ('$idx(%s, %s)'):format(expr(field_of(n, 'table'), sc), js_str(text(field_of(n, 'field'))))
        elseif t == 'bracket_index_expression' then
            return ('$idx(%s, %s)'):format(expr(field_of(n, 'table'), sc), expr(field_of(n, 'field'), sc))
        elseif t == 'function_call' then return call_js(n, sc, raw)
        elseif t == 'table_constructor' then return table_js(n, sc)
        elseif t == 'binary_expression' then
            local op = text(field_of(n, 'operator'))
            local l, r = field_of(n, 'left'), field_of(n, 'right')
            if op == 'and' then return ('$and(%s, () => %s)'):format(expr(l, sc), expr(r, sc)) end
            if op == 'or' then return ('$or(%s, () => %s)'):format(expr(l, sc), expr(r, sc)) end
            -- equality honours __eq (5.1: both operands tables sharing one __eq); $eq's first test is ===
            if op == '==' then return ('$eq(%s, %s)'):format(expr(l, sc), expr(r, sc)) end
            if op == '~=' then return ('!$eq(%s, %s)'):format(expr(l, sc), expr(r, sc)) end
            local f = BIN[op]
            if not f then return refuse(n, 'operator', 'no template for the binary operator ' .. op) end
            return ('%s(%s, %s)'):format(f, expr(l, sc), expr(r, sc))
        elseif t == 'unary_expression' then
            local op = text(field_of(n, 'operator'))
            local e = field_of(n, 'operand')
            if op == 'not' then return ('!$t(%s)'):format(expr(e, sc)) end
            if op == '-' then return ('$neg(%s)'):format(expr(e, sc)) end
            if op == '#' then return ('$len(%s)'):format(expr(e, sc)) end
            return refuse(n, 'operator', 'no template for the unary operator ' .. op)
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
            local el = named_kids(n)[1]
            local vals = el and named_kids(el) or {}
            if #vals == 0 then return 'return;' end
            if #vals == 1 then return ('return %s;'):format(expr(vals[1], sc, true)) end
            return ('return $mv(%s);'):format(explist_js(vals, sc))
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
                block(field_of(n, 'body'), scope(sc), { loop_label = lbl, loop_kind = 'while', fresh_loop = true, outer = ctx }))
        elseif t == 'repeat_statement' then
            local lbl = fresh('L')
            local rsc = scope(sc)
            local body = block(field_of(n, 'body'), rsc, { loop_label = lbl, loop_kind = 'repeat', fresh_loop = true, outer = ctx })
            -- the condition sees the body's locals: it is evaluated INSIDE the body's block
            return ('%s: do {\n%sif ($t(%s)) break;\n} while (true);'):format(lbl, body, expr(field_of(n, 'condition'), rsc))
        elseif t == 'for_statement' then
            local clause = field_of(n, 'clause')
            local lbl = fresh('L')
            local fsc = scope(sc)
            if clause:type() == 'for_numeric_clause' then
                local i, a, b, c = fresh('i'), fresh('a'), fresh('b'), fresh('s')
                local start = expr(field_of(clause, 'start'), sc)
                local stop = expr(field_of(clause, 'end'), sc)
                local step = field_of(clause, 'step') and expr(field_of(clause, 'step'), sc) or '1'
                local var = declare(fsc, text(field_of(clause, 'name')))
                local body = block(field_of(n, 'body'), fsc, { loop_label = lbl, loop_kind = 'for', fresh_loop = true, outer = ctx })
                return ('{ const %s = +(%s), %s = +(%s), %s = +(%s);\n%s: for (let %s = %s; %s > 0 ? %s <= %s : %s >= %s; %s += %s) { let %s = %s;\n%s} }')
                    :format(a, start, b, stop, c, step, lbl, i, a, c, i, b, i, b, i, c, var, i, body)
            end
            local vl, el
            for cc in clause:iter_children() do
                if cc:type() == 'variable_list' then vl = cc elseif cc:type() == 'expression_list' then el = cc end
            end
            local f, s, ctl = fresh('f'), fresh('s'), fresh('c')
            local init = ('$adj(3, [%s])'):format(explist_js(named_kids(el), sc))
            local vars = {}
            for _, v in ipairs(named_kids(vl)) do vars[#vars + 1] = declare(fsc, text(v)) end
            local body = block(field_of(n, 'body'), fsc, { loop_label = lbl, loop_kind = 'for', fresh_loop = true, outer = ctx })
            return ('{ let [%s, %s, %s] = %s;\n%s: for (;;) { let [%s] = $adj(%d, $all(%s(%s, %s))); if (%s === undefined) break; %s = %s;\n%s} }')
                :format(f, s, ctl, init, lbl, table.concat(vars, ', '), #vars, f, s, ctl, vars[1], ctl, vars[1], body)
        elseif t == 'do_statement' then
            local body = field_of(n, 'body')
            return ('{\n%s}'):format(body and block(body, scope(sc), ctx) or '')
        elseif t == 'break_statement' then return 'break;'
        elseif t == 'goto_statement' then
            local label = text(named_kids(n)[1])
            -- the innermost enclosing loop whose body ENDS with this label: a labeled JS continue reaches it from any depth
            local l = ctx
            while l do
                if l.continue_label == label then
                    if l.loop_kind == 'repeat' then return refuse(n, 'goto', 'the continue idiom inside repeat-until (a JS continue would skip the until test)') .. ';' end
                    return ('continue %s;'):format(l.loop_label)
                end
                l = l.outer
            end
            return refuse(n, 'goto', 'a general goto (no JS form)') .. ';'
        elseif t == 'label_statement' then
            if ctx and ctx.continue_label == text(named_kids(n)[1]) then return '' end
            return refuse(n, 'label', 'a label that is not the loop-end continue target') .. ';'
        end
        return refuse(n, t, 'no template for this statement kind') .. ';'
    end

    --- a block's statements. A LOOP BODY (ctx.fresh_loop) opens a loop context chained to the enclosing one; its last
    --- statement being a label makes that label its `continue` target. Other blocks pass the context through unchanged.
    function block(n, sc, ctx)
        if not n then return '' end
        local kids = named_kids(n)
        local c = ctx
        if ctx and ctx.fresh_loop then
            c = { loop_label = ctx.loop_label, loop_kind = ctx.loop_kind, outer = ctx.outer }
            local last = kids[#kids]
            if last and last:type() == 'label_statement' then c.continue_label = text(named_kids(last)[1]) end
        end
        local out = {}
        for _, k in ipairs(kids) do
            local s = stmt(k, sc, c)
            if s ~= '' then out[#out + 1] = s .. '\n' end
        end
        return table.concat(out)
    end

    local top = scope(nil)
    local body = block(root, top, nil)
    local pack = opts.pack or './$pack.js'
    local names = '$t, $and, $or, $mv, $1, $all, $adj, $arr, $rec, $map, $idx, $set, $len, $m, $call, $add, $sub, $mul, $div, $mod, $pow, $neg, $cat, $eq, $lt, $le, $gt, $ge, $abort, $G'
    local js = ("'use strict';\n// transliterated from %s by cartograph.luajs — do not edit\nconst { %s } = require(%s);\nmodule.exports = $1((function (...$va) {\n%s})());\n")
        :format(tostring(file), names, js_str(pack), body)
    return js, refusals, stats
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
    while #queue > 0 do
        local mod = table.remove(queue, 1)
        local rel = mod:gsub('%.', '/') .. '.lua'
        local fd = io.open(vimrt .. '/' .. rel)
        if fd then
            local src = fd:read('a'); fd:close()
            for dep in src:gmatch("require%s*%(?%s*['\"](vim%.[%w_.]+)['\"]") do enqueue(dep) end
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

