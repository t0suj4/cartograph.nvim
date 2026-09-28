-- cartograph.tblshape — WHAT SHAPE IS EACH TABLE? Per table constructor in one Lua source (CART-1197): the evidence
-- the JS transliteration's objects/arrays-by-shape representation is chosen from (user decision 2026-09-29), and the
-- census `tools/jsshape.lua` reports. ONE copy of the judgement for both.
--
--   of(src, file) -> { [start byte of the constructor] = { class, bound, ev = { array, record, unknown-key, escape,
--                    rebound, neutral, other }, uses = <the same counts from the binding's USES alone>, name? } }, why
--
-- A constructor BOUND BY `local x = {…}` is judged by EVERY USE OF THAT BINDING — the references the scope graph
-- resolves to that declaration (boundat + A.resolve: a shadowing local of the same name is another binding, and `x`
-- inside `"x"` or `t.x` is no reference at all), each classified by its tree-sitter context:
--   array     x[<number>], x[#x + 1], #x, ipairs(x), table.insert/remove/concat/sort/unpack(x, …)
--   record    x.k, x:m(), x["literal"], and named entries in the constructor
--   unknown   x[<expr>] whose key is neither a number nor a string literal
--   escape    passed to another function, returned, stored in a table, aliased
--   rebound   `x = …` later (the local holds more than this allocation)
-- ⇒ class ARRAY · RECORD · MIXED · DYNAMIC (an unknown key) · OPAQUE (no evidence) · REBOUND, suffixed ` +escapes`.
-- An UNBOUND constructor (an argument, a return value, a field of another table) is judged by its own entries only.
-- ⚠ A.resolve(G, id) takes the reference's ID: passing the record raised inside the pcall and every use was dropped
-- (measured on the fixture: 11 references, 0 resolved — a uniform zero).
local M = {}

local ARRAY_FNS = { ipairs = true, ['table.insert'] = true, ['table.remove'] = true, ['table.concat'] = true,
    ['table.sort'] = true, unpack = true, ['table.unpack'] = true }
local NEUTRAL_FNS = { pairs = true, next = true, type = true, tostring = true, rawequal = true, assert = true }

local function text(n, src) return vim.treesitter.get_node_text(n, src) end
local function field_of(n, name) for c, f in n:iter_children() do if f == name then return c end end end

--- the entries of a constructor: positional count, named count, dynamic-key count. A BRACKETED key is judged by the
--- key: `["lit"] = v` is named, `[1] = v` positional-shaped, `[expr] = v` a dynamic key (counting it as named would make
--- a RECORD that must then hold a non-string key — an abort the emitter would ship)
function M.entries(tc)
    local pos, named, dyn = 0, 0, 0
    for c in tc:iter_children() do
        if c:type() == 'field' then
            local k = field_of(c, 'name')
            local bracketed = false
            for cc in c:iter_children() do if not cc:named() and cc:type() == '[' then bracketed = true end end
            if not k then pos = pos + 1
            elseif not bracketed then named = named + 1
            elseif k:type() == 'string' then named = named + 1
            elseif k:type() == 'number' then pos = pos + 1
            else dyn = dyn + 1 end
        end
    end
    return pos, named, dyn
end

--- classify ONE reference node (an identifier) by its context
function M.context(n, src, name)
    local p = n:parent()
    if not p then return 'other' end
    local t = p:type()
    if t == 'bracket_index_expression' and field_of(p, 'table') == n then
        local k = field_of(p, 'field')
        local kt = k and k:type()
        if kt == 'number' then return 'array' end
        if kt == 'string' then return 'record' end
        if k and kt == 'binary_expression' and text(k, src):match('^#%s*' .. name .. '%s*%+%s*1$') then return 'array' end
        return 'unknown-key'
    elseif t == 'dot_index_expression' and field_of(p, 'table') == n then return 'record'
    elseif t == 'method_index_expression' and field_of(p, 'table') == n then return 'record'
    elseif t == 'unary_expression' and text(p, src):match('^#') then return 'array'
    elseif t == 'arguments' then
        local call = p:parent()
        local callee = call and field_of(call, 'name')
        local cname = callee and text(callee, src) or '?'
        if ARRAY_FNS[cname] then
            -- only as the FIRST argument (table.insert(t, x): t is the array; x is stored = an escape)
            local first
            for c in p:iter_children() do if c:named() and c:type() ~= 'comment' then first = c; break end end
            return first == n and 'array' or 'escape'
        end
        if NEUTRAL_FNS[cname] then return 'neutral' end
        return 'escape'
    elseif t == 'expression_list' then
        local gp = p:parent()
        if gp and gp:type() == 'return_statement' then return 'escape' end
        if gp and gp:type() == 'for_generic_clause' then return 'neutral' end
        return 'escape' -- the value side of an assignment: an alias
    elseif t == 'variable_list' then return 'rebound'
    elseif t == 'field' then return 'escape' -- stored in another table
    elseif t == 'binary_expression' then
        local op
        for c in p:iter_children() do if not c:named() then op = text(c, src) end end
        if op == '==' or op == '~=' then return 'neutral' end
        return 'escape' -- `t or {}`, `t and t.x`: the value flows on
    elseif t == 'parenthesized_expression' then return 'escape'
    end
    return 'other'
end

--- the class of a bound constructor from its evidence
function M.class_of(ev)
    local c
    if (ev.rebound or 0) > 0 then c = 'REBOUND'
    elseif (ev['unknown-key'] or 0) > 0 then c = 'DYNAMIC'
    elseif (ev.array or 0) > 0 and (ev.record or 0) > 0 then c = 'MIXED'
    elseif (ev.array or 0) > 0 then c = 'ARRAY'
    elseif (ev.record or 0) > 0 then c = 'RECORD'
    else c = 'OPAQUE' end
    if (ev.escape or 0) > 0 then c = c .. ' +escapes' end
    return c
end

local Q
function M.of(src, file, tree)
    local B = require 'cartograph.boundat'
    Q = Q or vim.treesitter.query.parse('lua', '(table_constructor) @t')
    tree = tree or vim.treesitter.get_string_parser(src, 'lua'):parse()[1]
    local root = tree:root()
    local starts = { 0 }
    for i = 1, #src do if src:byte(i) == 10 then starts[#starts + 1] = i end end
    local function rc(off)
        local lo, hi = 1, #starts
        while lo < hi do local mid = math.floor((lo + hi + 1) / 2); if starts[mid] <= off then lo = mid else hi = mid - 1 end end
        return lo - 1, off - starts[lo]
    end
    local h, hwhy = B.of(src, file)
    -- every reference resolved to its declaration
    local uses = {}
    if h then
        local A, G = h.A, h.G
        for id in pairs(G.refs or {}) do
            local off = h.ref_off[id]
            if off then
                local okr, R = pcall(A.resolve, G, id)
                if okr and R and not R.absent and not R.ambiguous and R.entries and R.entries[1] then
                    local d = R.entries[1].decl
                    uses[d] = uses[d] or {}
                    table.insert(uses[d], off)
                end
            end
        end
    end
    local decl_at = {}
    for id, off in pairs(h and h.decl_off or {}) do decl_at[off] = id end
    local out = {}
    for _, tc in Q:iter_captures(root, src, 0, -1) do
        local pos, named, dyn = M.entries(tc)
        -- bound by `local x = {…}`: the constructor is the i-th value of a local declaration whose i-th name is x
        local el = tc:parent()
        local stmt = el and el:type() == 'expression_list' and el:parent()
        local nameid
        if stmt and stmt:type() == 'assignment_statement' and stmt:parent() and stmt:parent():type() == 'variable_declaration' then
            local idx, i = nil, 0
            for c in el:iter_children() do if c:named() then i = i + 1; if c:equal(tc) then idx = i end end end
            local names = {}
            for c in stmt:iter_children() do if c:type() == 'variable_list' then for v in c:iter_children() do if v:named() then names[#names + 1] = v end end end end
            nameid = idx and names[idx]
            if nameid and nameid:type() ~= 'identifier' then nameid = nil end
        end
        local ev = { array = (pos > 0) and 1 or 0, record = (named > 0) and 1 or 0, ['unknown-key'] = dyn > 0 and 1 or nil }
        local _, _, start = tc:start()
        local rec
        if nameid and h then
            local _, _, off = nameid:start()
            local d = decl_at[off]
            if d then
                local name = text(nameid, src)
                local ctx = {}
                for _, roff in ipairs(uses[d] or {}) do
                    local r, c = rc(roff)
                    local n = root:named_descendant_for_range(r, c, r, c)
                    local k = n and M.context(n, src, name) or 'other'
                    ev[k] = (ev[k] or 0) + 1
                    ctx[k] = (ctx[k] or 0) + 1
                end
                rec = { class = M.class_of(ev), bound = true, ev = ev, uses = ctx, name = name }
            end
        end
        if not rec then
            rec = { bound = false, ev = ev,
                class = dyn > 0 and 'DYNAMIC' or (pos > 0 and named > 0) and 'MIXED' or pos > 0 and 'ARRAY' or named > 0 and 'RECORD' or 'OPAQUE' }
        end
        out[start] = rec
    end
    return out, (not h) and hwhy or nil
end

--- the JS REPRESENTATION a class maps to: ARRAY / RECORD for those shapes, MAP for everything else (a dictionary, a
--- mix, an empty table whose uses are not visible)
function M.representation(class)
    local base = tostring(class):match('^(%u+)')
    if base == 'ARRAY' then return 'ARRAY' end
    if base == 'RECORD' then return 'RECORD' end
    return 'MAP'
end

return M
