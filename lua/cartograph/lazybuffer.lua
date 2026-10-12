-- cartograph.lazybuffer — the optimizer's LAZY-BUFFER finding (CART-1663), Lua's: a function-local string buffer that
-- is only APPENDED to and finally CONCATENATED allocates its table on the SECOND piece — the first lives in a local.
-- Most such buffers hold one piece: dkjson's scanstring built a table per JSON string (1.31 M of 1.62 M tables of its
-- decode+encode workload) and special-cased n == 1 only after allocating; by hand, -12% under LuaJIT, -9.5% under PUC
-- Lua 5.1, the output equal. The sites optapply.plan_buffer (verb `lazy-buffer`) rewrites. Its own module because it
-- reads Lua's node types.
-- @langs lua
--
-- A SITE, and its proof obligations (every one checked on the syntax; anything else refuses the site, named):
--   the declaration `local b = {}` (the LENGTH form) or `local b, n = {}, 0` (the COUNTER form), inside a function;
--   every later mention of `b` in that function, outside nested functions, is one of
--     append    `b[#b + 1] = e` | `table.insert(b, e)` (a statement)        — length form
--               `n = n + 1` followed by `b[n] = e`                          — counter form (n written by nothing else)
--     first     `b[1]` read                                                 — is the first piece in both forms
--     concat    `table.concat(b)` | `table.concat(b, sep)`, sep a literal or a name (its local alias counts)
--   `b` is declared once in the function (no shadowing binder), no use nests inside another's rewritten text.
-- THE INVARIANT the rewrite keeps: FIRST == the original b[1] always, and the table exists exactly when the original
-- held two or more pieces (a nil append is a no-op in both). So `b[1]` reads FIRST, and concat is the table's when it
-- exists, else FIRST as a string (`'' .. FIRST`: the conversion table.concat applies to a number), else ''.
local tsutil = require 'cartograph.spec.tsutil'

local M = {}

local FN = { function_declaration = true, function_definition = true }
local STMT_PARENT = { block = true, chunk = true }

--- the lazy-buffer sites of a Lua text -> { { name, form = 'length' | 'counter', fn = { sr, sc } (the function's
--- start), decl = { sr, sc, er, ec }, ctor = { sr, sc } (the `{}` — an alloc-census key), edits = { { s, e, text } … } (byte offsets, 0-based start, exclusive end) } },
--- refusals = { { name, line, why } }
function M.sites(src, lang)
    if lang ~= 'lua' then return {}, {} end
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
    if not ok or not parser then return {}, {} end
    local root = parser:parse()[1]:root()
    local function text(n) return vim.treesitter.get_node_text(n, src) end
    local function squeeze(s) return (s:gsub('%s+', '')) end
    local function byte_range(n) local _, _, s = n:start(); local _, _, e = n:end_(); return s, e end
    -- the local names the file binds to table.concat / table.insert (`local concat = table.concat`, also in a list)
    local alias = { ['table.concat'] = 'concat', ['table.insert'] = 'insert' }
    local function scan_aliases(n)
        for _, c in tsutil.inamed, n, -1 do
            if c:type() == 'variable_declaration' then
                local a = c:named_child(0)
                if a and a:type() == 'assignment_statement' then
                    local vl, el = a:named_child(0), a:named_child(1)
                    for i = 0, (vl and vl:named_child_count() or 0) - 1 do
                        local nm, v = vl:named_child(i), el and el:named_child(i)
                        local vt = v and squeeze(text(v))
                        if nm and (vt == 'table.concat' or vt == 'table.insert') then alias[text(nm)] = alias[vt] end
                    end
                end
            end
        end
    end
    scan_aliases(root) -- (file-level aliases: dkjson's `local concat = table.concat`)
    local out, refusals = {}, {}
    local function refuse(name, n, why) refusals[#refusals + 1] = { name = name, line = select(1, n:start()) + 1, why = why } end

    -- every identifier `name` inside fn (outside nested functions) after byte `after`; `shadow` = another binder of it
    local function mentions(fn, name, after)
        local uses, shadow, nested = {}, false, false
        local function walk(n, depth_fn)
            for _, c in tsutil.inamed, n, -1 do
                local t = c:type()
                if FN[t] then walk(c, depth_fn + 1)
                elseif t == 'identifier' and text(c) == name then
                    local s = byte_range(c)
                    if s > after then
                        if depth_fn > 0 then nested = true else uses[#uses + 1] = c end
                    end
                else
                    walk(c, depth_fn)
                end
            end
        end
        walk(fn, 0)
        -- (a second binder of the name anywhere in fn: a parameter, a local, a for variable — refuse rather than resolve)
        local function binders(n)
            for _, c in tsutil.inamed, n, -1 do
                local t = c:type()
                local list -- (the node whose identifier children are binders)
                if t == 'parameters' then list = c
                elseif t == 'variable_list' and c:parent() and c:parent():parent() and c:parent():parent():type() == 'variable_declaration' then list = c
                elseif t == 'for_generic_clause' then list = c:named_child(0)
                elseif t == 'for_numeric_clause' then
                    local id = c:field('name')[1]
                    if id and text(id) == name then shadow = true end
                end
                for _, id in tsutil.inamed, list or c, -1 do
                    if list and id:type() == 'identifier' and text(id) == name and byte_range(id) ~= after then shadow = true end
                end
                binders(c)
            end
        end
        binders(fn)
        return uses, shadow, nested
    end

    local function callee_of(call) local nm = call:field('name')[1]; return nm and squeeze(text(nm)) end
    local function args_of(call)
        local a = call:field('arguments')[1]
        local out_ = {}
        for _, x in tsutil.inamed, a or call, -1 do if a then out_[#out_ + 1] = x end end
        return out_, a
    end

    local function consider(decl, fn)
        local asg = decl:named_child(0)
        if not (asg and asg:type() == 'assignment_statement') then return end
        local vl, el = asg:named_child(0), asg:named_child(1)
        if not (vl and el) then return end
        local nv, ne = vl:named_child_count(), el:named_child_count()
        local b, v1 = vl:named_child(0), el:named_child(0)
        if not (b and b:type() == 'identifier' and v1 and v1:type() == 'table_constructor' and v1:named_child_count() == 0) then return end
        local form, n_node
        if nv == 1 and ne == 1 then form = 'length'
        elseif nv == 2 and ne == 2 and vl:named_child(1):type() == 'identifier' and squeeze(text(el:named_child(1))) == '0' then
            form, n_node = 'counter', vl:named_child(1)
        else return end
        local name = text(b)
        local bstart = byte_range(b)
        local uses, shadow, nested = mentions(fn, name, bstart)
        if shadow then return refuse(name, decl, 'the name is bound again in the function') end
        if nested then return refuse(name, decl, 'a nested function mentions it') end
        if #uses == 0 then return end
        local nname = n_node and text(n_node)
        local edits, kinds = {}, {}
        local inside = {} -- (the `#b` in an append's own key: part of that append, not a use of its own)
        for _, u in ipairs(uses) do
            if inside[u:id()] then goto next_use end
            local p = u:parent()
            local pt = p and p:type()
            if pt == 'bracket_index_expression' and p:field('table')[1] == u then
                local key = p:field('field')[1]
                local vlist = p:parent()
                local stmt = vlist and vlist:type() == 'variable_list' and vlist:parent()
                if stmt and stmt:type() == 'assignment_statement' and vlist:named_child_count() == 1 then
                    local vals = stmt:named_child(1)
                    if not (vals and vals:named_child_count() == 1) then return refuse(name, u, 'a multiple assignment') end
                    local e = vals:named_child(0)
                    local k = key and squeeze(text(key))
                    if form == 'length' and k == '#' .. name .. '+1' then
                        local len = key:named_child(0) -- (`#b`, the binary expression's left operand)
                        local lid = len and len:named_child(0)
                        if lid then inside[lid:id()] = true end
                        kinds[#kinds + 1] = 'append'
                        edits[#edits + 1] = { stmt, 'append', text(e) }
                    elseif form == 'counter' and k == nname then
                        -- (the previous statement must be the counter's increment)
                        local prev = stmt:prev_named_sibling()
                        -- (a `;` between the two is a statement node of its own: `n = n + 1; b[n] = e`)
                        while prev and prev:type() == 'empty_statement' do prev = prev:prev_named_sibling() end
                        if not (prev and squeeze(text(prev)) == nname .. '=' .. nname .. '+1') then return refuse(name, u, 'b[n] = e not right after n = n + 1') end
                        kinds[#kinds + 1] = 'append'
                        edits[#edits + 1] = { stmt, 'append_n', text(e) }
                    else return refuse(name, u, 'a write at another key') end
                elseif key and squeeze(text(key)) == '1' then
                    edits[#edits + 1] = { p, 'first' }
                else return refuse(name, u, 'a read at another key') end
            elseif pt == 'arguments' then
                local call = p:parent()
                local args = args_of(call)
                local which = alias[callee_of(call) or '']
                if args[1] ~= u then return refuse(name, u, 'passed as a later argument') end
                if which == 'insert' and #args == 2 and form == 'length' and STMT_PARENT[(call:parent() or call):type()] then
                    kinds[#kinds + 1] = 'append'
                    edits[#edits + 1] = { call, 'append', text(args[2]) }
                elseif which == 'concat' and #args <= 2 then
                    local sep = args[2]
                    if sep and not (sep:type() == 'string' or sep:type() == 'identifier') then return refuse(name, u, 'a concat separator that is no literal or name') end
                    edits[#edits + 1] = { call, 'concat', callee_of(call), sep and text(sep) or nil }
                else return refuse(name, u, 'passed to another call') end
            else return refuse(name, u, 'used otherwise (' .. tostring(pt) .. ')') end
            ::next_use::
        end
        -- the counter is written only by its increments
        if form == 'counter' then
            local nuses = mentions(fn, nname, byte_range(n_node))
            for _, x in ipairs(nuses) do
                local vlist = x:parent()
                if vlist and vlist:type() == 'variable_list' then
                    local stmt = vlist:parent()
                    if not (stmt and squeeze(text(stmt)) == nname .. '=' .. nname .. '+1') then return refuse(name, x, 'the counter is written otherwise') end
                end
            end
        end
        local has_append = false
        for _, k in ipairs(kinds) do if k == 'append' then has_append = true end end
        if not has_append then return end
        -- (a fresh local name for the first piece)
        local first, k = name .. '_first', 0
        while src:find('%f[%w_]' .. first .. '%f[^%w_]') do k = k + 1; first = name .. '_first' .. k end
        local E = {}
        for _, ed in ipairs(edits) do
            local s, e = byte_range(ed[1])
            local t
            if ed[2] == 'append' then
                t = ('do local %s_v = %s; if %s then %s[#%s + 1] = %s_v elseif %s == nil then %s = %s_v else %s = { %s, %s_v } end end')
                    :format(first, ed[3], name, name, name, first, first, first, first, name, first, first)
            elseif ed[2] == 'append_n' then
                t = ('if %s == 1 then %s = %s else if %s == 2 then %s = { %s } end %s[%s] = %s end')
                    :format(nname, first, ed[3], nname, name, first, name, nname, ed[3])
            elseif ed[2] == 'first' then t = first
            else
                local sep = ed[4] and (', ' .. ed[4]) or ''
                t = ('(%s and %s(%s%s) or (%s == nil and \'\' or \'\' .. %s))'):format(name, ed[3], name, sep, first, first)
            end
            E[#E + 1] = { s, e, t }
        end
        local ds, de = byte_range(decl)
        local dt = form == 'length' and ('local %s, %s'):format(name, first)
            or ('local %s, %s, %s = nil, 0, nil'):format(name, nname, first)
        E[#E + 1] = { ds, de, dt }
        table.sort(E, function (a, b2) return a[1] < b2[1] end)
        for i = 2, #E do if E[i][1] < E[i - 1][2] then return refuse(name, decl, 'one use nests inside another') end end
        local fsr, fsc = fn:start()
        local dsr, dsc, der, dec = decl:range()
        local csr, csc = v1:start()
        out[#out + 1] = { name = name, form = form, first = first, fn = { fsr, fsc }, decl = { dsr, dsc, der, dec }, ctor = { csr, csc }, edits = E }
    end

    local function walk(n, fn)
        for _, c in tsutil.inamed, n, -1 do
            local t = c:type()
            if FN[t] then walk(c, c)
            else
                if t == 'variable_declaration' and fn then consider(c, fn) end
                walk(c, fn)
            end
        end
    end
    walk(root, nil)
    return out, refusals
end

--- apply sites' edits to src -> the new text
function M.apply(src, sites)
    local E = {}
    for _, s in ipairs(sites) do for _, e in ipairs(s.edits) do E[#E + 1] = e end end
    table.sort(E, function (a, b) return a[1] > b[1] end)
    local out = src
    for _, e in ipairs(E) do out = out:sub(1, e[1]) .. e[3] .. out:sub(e[2] + 1) end
    return out
end

return M
