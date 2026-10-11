-- cartograph.emptyfallback — the optimizer's EMPTY-FALLBACK finding (CART-1657), Lua's: which `t or {}` is built only
-- to be read, provably — the sites optapply.plan_empty (verb `hoist-empty`) rewrites. Its own module because it reads
-- Lua's node types; optimize.lua's lenses ride the expression IR across languages.
-- @langs lua
local tsutil = require 'cartograph.spec.tsutil'
local effects = require 'cartograph.effects'

local M = {}

-- ★ AN EMPTY FALLBACK BUILT TO BE READ (the general optimizer's first pass, CART-1657): `ipairs(t or {})` builds a
-- fresh empty table on every call, read once by a builtin and dropped — 16 M of 27 M tables one solve of lua/cartograph
-- allocated (935e310, by hand). Sound BY CONSTRUCTION only where nothing can name, write or compare the table: the `{}`
-- is the right operand of `or`, and the whole `or` is
--   an argument a builtin effects.SIGS declares it only READS (`reads`: its contents, never its identity — next,
--   unpack, table.concat, rawlen; select, rawequal, getmetatable, tostring do not qualify) and does not hand back — or
--   does (`yields_arg`: pairs / ipairs) as the SOLE iterator expression of a generic for, where that state has no name;
--   or the operand of `#`.
-- The builtin must not be rebound at the site (the scope model sees no binder for its name). A non-empty constant, a
-- table compared or used as a key, one passed to unknown code: not this pass (they need facts the roster lacks).
-- -> { { range = { sr, sc, er, ec } of the `{}`, how = 'iterator' | 'reads' | 'length', callee, closed = its function
-- reads no outer local (a site the hoist leaves: it would OPEN that function) } }
function M.empty_fallbacks(src, lang)
    if lang ~= 'lua' then return {} end
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
    if not ok or not parser then return {} end
    local tree = parser:parse()[1]:root()
    local okspec, spec = pcall(require, 'cartograph.spec.lua')
    if not okspec then spec = nil end
    local sm = spec and spec.lexical_scopes and require('cartograph.scope').model(src, spec.lexical_scopes)
    local SIGS = effects.SIGS.lua.exact
    local function text(n) return vim.treesitter.get_node_text(n, src) end
    -- (a builtin that looks only at the CONTENTS of argument i — effects' `reads`: no write, no identity, no return of
    -- it; `yields_arg` = it hands the table back, as pairs / ipairs do)
    local function readonly(name, i)
        local sg = SIGS[name]
        if not (sg and sg.pure and not sg.w and not sg.calls and not sg.returns_arg and not sg.raises and sg.reads) then return nil end
        for _, r in ipairs(sg.reads) do
            if r == i then
                for _, y in ipairs(sg.yields_arg or {}) do if y == i then return 'yields' end end
                return 'reads'
            end
        end
    end
    local function empty_or(e) -- `X or {}`, parenthesized or not -> the `{}` node
        while e and e:type() == 'parenthesized_expression' do e = e:named_child(0) end
        if not (e and e:type() == 'binary_expression') then return nil end
        local op
        for _, x in tsutil.inext, e, -1 do if not x:named() then op = text(x) end end
        local r = e:named_child(1)
        if op == 'or' and r and r:type() == 'table_constructor' and r:named_child_count() == 0 then return r end
    end
    local out = {}
    -- ★ A CLOSED FUNCTION STAYS CLOSED: one that reads no local from outside itself can be LIFTED as code — a qlower
    -- kernel loaded alone (solve.lua's run_worklist), a closure mix assembles from source — and hoisting its fallback to
    -- a file-level constant would give it its first outer reference. -> closed(fn): no identifier in fn resolves to a
    -- binder declared outside it (a global is no outer local)
    local closed_memo = {}
    local function closed(fn)
        local key = fn:id()
        if closed_memo[key] ~= nil then return closed_memo[key] end
        local inside = {}
        local function decl(n)
            for _, c in tsutil.inext, n, -1 do
                local t = c:type()
                if t == 'parameters' or t == 'variable_list' or t == 'for_numeric_clause' then
                    for _, x in tsutil.inext, c, -1 do if x:type() == 'identifier' then inside[text(x)] = true end end
                elseif t == 'function_declaration' then local nm = c:field('name')[1]; if nm and nm:type() == 'identifier' then inside[text(nm)] = true end
                end
                decl(c)
            end
        end
        decl(fn)
        local verdict = true
        local own = fn:field('name')[1] -- (the function's own NAME is its declaration, not a reference it makes)
        local function refs(n)
            if not verdict then return end
            for _, c in tsutil.inext, n, -1 do
                if c:type() == 'identifier' and not (own and c:id() == own:id()) then
                    local p = c:parent()
                    local field = p and (p:type() == 'dot_index_expression' or p:type() == 'method_index_expression') and p:named_child(0):id() ~= c:id()
                    local name = text(c)
                    if not field and not inside[name] and sm then
                        local _, k = sm.resolve(name, c)
                        if k > 0 then verdict = false; return end
                    end
                end
                refs(c)
            end
        end
        refs(fn)
        closed_memo[key] = verdict
        return verdict
    end
    local function enclosing(n)
        local p = n:parent()
        while p and p:type() ~= 'function_declaration' and p:type() ~= 'function_definition' do p = p:parent() end
        return p
    end
    local function bound(name, at)
        if not sm then return false end
        local _, k = sm.resolve(name, at) -- (two values: `sm and sm.resolve(…)` would keep only the first)
        return k > 0
    end
    local function walk(n)
        local t = n:type()
        if t == 'function_call' then
            local f, args = n:field('name')[1], n:field('arguments')[1]
            local name = f and text(f)
            local root = name and name:match('^[%a_][%w_]*')
            local how, e
            for i = 0, (args and args:named_child_count() or 0) - 1 do
                local x = empty_or(args:named_child(i))
                if x then how, e = name and readonly(name, i + 1), x; break end
            end
            if e and how and not bound(root, n) then
                local ok2 = how == 'reads'
                if how == 'yields' then
                    -- (the SOLE expression of a generic for's iterator list)
                    local el = n:parent()
                    local cl = el and el:parent()
                    ok2 = el and el:type() == 'expression_list' and el:named_child_count() == 1 and cl and cl:type() == 'for_generic_clause'
                end
                local fn = ok2 and enclosing(n)
                if ok2 then out[#out + 1] = { range = { e:range() }, how = how == 'yields' and 'iterator' or 'reads', callee = name, closed = fn and closed(fn) or false } end
            end
        elseif t == 'unary_expression' and text(n):match('^%s*#') then
            local e = empty_or(n:named_child(0))
            local fn = e and enclosing(n)
            if e then out[#out + 1] = { range = { e:range() }, how = 'length', callee = '#', closed = fn and closed(fn) or false } end
        end
        for _, c in tsutil.inext, n, -1 do walk(c) end
    end
    walk(tree)
    return out
end

return M
