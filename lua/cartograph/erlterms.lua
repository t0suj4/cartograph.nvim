-- erlterms — an erlang VALUE expression as an algebra TERM: what a function builds, in the same decoded-record
-- encoding the wire merge unifies on (CART-1112 step 1, the term side of CART-1108).
-- @langs erlang
--
-- ★★ THE HARD REVERSES ARE THE SIDE WHERE THE TERM IS COMPUTED, and CART-1112 measured how it is formed at the 184
-- places ejabberd sends a stanza (make_iq_result arg 2, ejabberd_router:route arg 1): 47% a record literal, a variable
-- bound to one, or a record update — readable with an ENCODING alone, no solver. This is that encoding; the other
-- rows (a case/if -> join, a call -> callee summary, a parameter -> summary hole, a pattern-bound variable -> the
-- matched input) are the later steps, and until they exist each is a HOLE that says which step would fill it.
--
-- ENCODING (identical to xmppmerge's client decode, so the two sides unify):
--   #r{f = V}        rec:r(field_1 .. field_n) in the record's DECLARED field order (the ctx's record_fields); a
--                    field the construction does not set takes its DECLARED DEFAULT (`<<>>` -> "", `[]` -> nil,
--                    none -> "undefined": an unset record field IS undefined); a default we cannot read is a hole
--   X#r{f = V}       the base's term with those fields replaced; an unknown base leaves the others as holes
--   [A, B | T]       cons(A, cons(B, T))      atom / integer / plain binary -> lit (quotes and <<"">> dropped)
--   {A, B}           tuple(A, B)
--   ?NS_X / ?MODULE  the macro's value from the distilled vocabulary / the module's own name; #{} -> map
--   Var              its binding: erlang binds once per clause, so the `Var = Expr` match before the use in the same
--                    clause IS its value (followed a few hops); a variable bound by a PATTERN or a PARAMETER is a hole
-- ctx = { record_fields = fn(rec) -> names | nil, defaults = fn(rec) -> { field -> text } | nil }
-- -> term, holes { name -> reason }  (a whole-hole term means nothing was readable)
local M = {}
local unpack = table.unpack or unpack

local function A() return assert(require('cartograph.algebra').load()) end

-- the erlang node types a value is spelled in, tabled for the language fence
local T = {
    record = { record_expr = true }, update = { record_update_expr = true },
    list = { list = true }, pipe = { pipe = true }, tuple = { tuple = true }, var = { var = true },
    atom = { atom = true }, integer = { integer = true }, float = { float = true }, string = { string = true },
    char = { char = true }, binary = { binary = true }, match = { match_expr = true }, paren = { paren_expr = true },
    call = { call = true }, remote = { remote = true }, case = { case_expr = true, if_expr = true },
    clause = { function_clause = true }, fn = { anonymous_fun = true },
    macro = { macro_call_expr = true }, map = { map_expr = true },
}

-- the macro vocabulary the erlang spec reads call arguments with (erl-macros, distilled from the dependency's
-- headers by tools/hrldistill.lua): ?NS_DISCO_INFO -> its URI
local MACROS
local function macros()
    if MACROS == nil then
        local ok, prof = pcall(require, 'cartograph.spec.profile')
        local a = ok and prof and prof.load and prof.load('erl-macros')
        MACROS = a and a.values or false
    end
    return MACROS or nil
end

local function txt(n, src) return vim.treesitter.get_node_text(n, src) end

-- a declared default's TEXT as a term, when it is a literal we can read
local function default_term(text, fresh)
    local a = A()
    if text == nil then return a.lit('undefined') end
    text = vim.trim(text):gsub('%s*::.*$', '')
    if text == '<<>>' or text == '<<"">>' then return a.lit('') end
    if text == '[]' then return a.node('nil') end
    if text == '#{}' then return a.node('map') end
    local b = text:match('^<<"(.*)">>$')
    if b then return a.lit(b) end
    if text:match('^[a-z][%w_@]*$') then return a.lit(text) end
    if text:match("^'.*'$") then return a.lit(text:sub(2, -2)) end
    if text:match('^%-?%d+$') then return a.lit(text) end
    return fresh('default ' .. text)
end

--- the value of `node` (a tree-sitter node in `src`) as a term
function M.term(node, src, ctx)
    local a = A()
    local holes, n = {}, 0
    local function fresh(why)
        n = n + 1
        local h = 'V' .. n
        holes[h] = why
        return a.hole(h)
    end
    -- the enclosing clause (a variable's scope) and the single-assignment binding of `name` before `at`
    local function clause_of(x) while x and not T.clause[x:type()] do x = x:parent() end return x end
    local function binding(var)
        local name, at = txt(var, src), var:start()
        local cl = clause_of(var)
        if not cl then return nil, 'no clause' end
        local args = cl:field('args')[1]
        local is_param = false
        if args then
            local function scan(x)
                for c in x:iter_children() do
                    if T.var[c:type()] and txt(c, src) == name then is_param = true end
                    scan(c)
                end
            end
            scan(args)
        end
        if is_param then return nil, 'parameter (CART-1112 step 4: a summary hole)' end
        local found
        local function walk(x)
            for c in x:iter_children() do
                if c:start() >= at then return end
                if T.match[c:type()] then
                    local l = c:field('lhs')[1]
                    if l and T.var[l:type()] and txt(l, src) == name then found = c:field('rhs')[1] end
                end
                if not T.fn[c:type()] then walk(c) end
            end
        end
        walk(cl)
        if found then return found end
        return nil, 'bound by a pattern (CART-1112 step 5: the matched input)'
    end
    local conv
    local function record(rec, set, base)
        local names = ctx.record_fields and ctx.record_fields(rec)
        if not names then return fresh('#' .. rec .. ' (no declaration in scope)') end
        local defaults = (ctx.defaults and ctx.defaults(rec)) or {}
        local kids = {}
        for i, f in ipairs(names) do
            if set[f] then kids[i] = set[f]
            elseif base and base.k == 'rec:' .. rec and base.kids and base.kids[i] then kids[i] = base.kids[i]
            elseif base then kids[i] = fresh('#' .. rec .. '.' .. f .. ' (from an unknown base)')
            else kids[i] = default_term(defaults[f], fresh) end
        end
        return a.node('rec:' .. rec, unpack(kids, 1, #names))
    end
    local function rec_fields(x)
        local set = {}
        for _, rf in ipairs(x:field('fields')) do
            local fname = rf:field('name')[1]
            local fe = rf:field('expr')[1]
            local vn = fe and (fe:field('expr')[1] or fe)
            if fname and vn then set[txt(fname, src)] = conv(vn) end
        end
        return set
    end
    local function rec_name(x)
        local rn = x:field('name')[1]
        rn = rn and (rn:field('name')[1] or rn)
        return rn and txt(rn, src)
    end
    local depth = 0
    function conv(x)
        if not x then return fresh('nothing') end
        local t = x:type()
        if T.paren[t] then local c = x:named_child(0); return conv(c) end
        if T.record[t] then
            local rec = rec_name(x)
            if not rec then return fresh('a record named by a macro') end
            return record(rec, rec_fields(x))
        end
        if T.update[t] then
            local rec = rec_name(x)
            if not rec then return fresh('a record named by a macro') end
            local b = x:field('expr')[1]
            return record(rec, rec_fields(x), b and conv(b) or nil)
        end
        if T.list[t] then
            local items, tail = {}, nil
            for _, c in ipairs(x:field('exprs')) do
                if T.pipe[c:type()] then
                    items[#items + 1] = conv(c:field('lhs')[1])
                    tail = conv(c:field('rhs')[1])
                else items[#items + 1] = conv(c) end
            end
            local tm = tail or a.node('nil')
            for i = #items, 1, -1 do tm = a.node('cons', items[i], tm) end
            return tm
        end
        if T.tuple[t] then
            local items = {}
            for _, c in ipairs(x:field('expr')) do items[#items + 1] = conv(c) end
            return a.node('tuple', unpack(items, 1, #items))
        end
        if T.atom[t] then return a.lit((txt(x, src):gsub("^'(.*)'$", '%1'))) end
        if T.integer[t] or T.float[t] or T.char[t] then return a.lit(txt(x, src)) end
        if T.string[t] then return a.lit((txt(x, src):gsub('^"(.*)"$', '%1'))) end
        if T.binary[t] then
            local parts = {}
            for _, e in ipairs(x:field('elements')) do
                local el = e:field('element')[1]
                if not el or not T.string[el:type()] or e:field('size')[1] or e:field('types')[1] then
                    return fresh('a binary built at runtime')
                end
                parts[#parts + 1] = txt(el, src):sub(2, -2)
            end
            return a.lit(table.concat(parts))
        end
        if T.var[t] then
            local nm = txt(x, src)
            if nm == '_' then return fresh('_') end
            if depth >= 4 then return fresh(nm .. ' (binding chain too long)') end
            local b, why = binding(x)
            if not b then return fresh(nm .. ': ' .. why) end
            depth = depth + 1
            local r = conv(b)
            depth = depth - 1
            return r
        end
        if T.macro[t] then
            local nn = x:field('name')[1]
            local nm = nn and txt(nn, src)
            if x:field('args')[1] then return fresh('?' .. tostring(nm) .. '(…) (a macro with arguments)') end
            if nm == 'MODULE' and ctx.module then return a.lit(ctx.module) end
            local v = nm and (ctx.macros or macros() or {})[nm]
            if type(v) == 'string' then return a.lit(v) end
            return fresh('?' .. tostring(nm) .. ' (no value in the vocabulary)')
        end
        if T.map[t] then
            if #x:field('fields') == 0 then return a.node('map') end
            return fresh('a map with fields')
        end
        if T.case[t] then return fresh('a case/if value (CART-1112 step 2: join over the arms)') end
        if T.call[t] or T.remote[t] then return fresh('a call result (CART-1112 step 3: the callee summary)') end
        return fresh('a ' .. t .. ' value')
    end
    local tm = conv(node)
    return tm, holes
end

--- a term's completeness: 'complete' (no holes), 'partial', or 'opaque' (the term IS a hole)
function M.status(term)
    if term.k == 'hole' then return 'opaque' end
    local any = false
    local function walk(t)
        if t.k == 'hole' then any = true; return end
        for _, c in ipairs(t.kids or {}) do walk(c) end
    end
    walk(term)
    return any and 'partial' or 'complete'
end

return M
