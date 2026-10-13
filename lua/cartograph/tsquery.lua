-- cartograph.tsquery — a tree-sitter QUERY compiled to a per-node MATCHER (CART-1659). A query runs its own traversal
-- (the C cursor) and hands every match to Lua as a fresh table; a matcher compiled from it instead answers "which
-- patterns match at THIS node" for a walk that is visiting the node anyway — the calls query rides a walk instead of
-- being one (~0.8 s of a 19 s extraction on the 428-file corpus).
--   local m = assert(tsquery.compile(query_text))      nil, why for a construct outside the subset (the caller keeps
--                                                       the real query then: refused by name, never approximated)
--   m.roots[node_type] / m.wild                        the patterns that can START at a node of that type
--   tsquery.at(m, node, emit)                          emit(pattern_index, captures) for every match rooted at node,
--                                                       captures = { [name] = node }
--   tsquery.all(m, root, emit)                          every match in the tree (a standalone walk; the oracle's form)
-- THE SUBSET: `(type child…) @cap` patterns, `(_)` (any named node), `field: (…)` children, an unanchored child (any
-- named child of that shape), a `.` anchor before the first child (it must be the first named child), captures
-- anywhere. REFUSED: predicates (#eq? …), alternations [ ], quantifiers * + ?, string (anonymous) nodes, negated
-- fields, wildcards without parentheses, more than one anchor. Every call query of every language spec is in it.
-- ⚠ EQUAL BY ORACLE, not by argument: tools/experiments/tsquery_oracle.lua diffs the ordered match lists against
-- `query:iter_matches` on real trees.
local M = {}

local function tokenize(s)
    local toks, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c:match('%s') then i = i + 1
        elseif c == ';' then local e = s:find('\n', i, true) or n; i = e + 1 -- (a comment)
        elseif c == '(' or c == ')' or c == '.' then toks[#toks + 1] = c; i = i + 1
        elseif c == '@' then
            local name = s:match('^@([%w_%.%-]+)', i); if not name then return nil, 'a bad capture at ' .. i end
            toks[#toks + 1] = { cap = name }; i = i + 1 + #name
        else
            local word = s:match('^[%w_]+', i)
            if not word then return nil, ('`%s` is outside the compiled subset'):format(c) end
            i = i + #word
            if s:sub(i, i) == ':' then toks[#toks + 1] = { field = word }; i = i + 1
            else toks[#toks + 1] = { word = word } end
        end
    end
    return toks
end

-- pattern := '(' type {child} ')' {'@' cap}      child := ['.'] [field ':'] pattern
local function parse(toks)
    local pos = 1
    local function peek() return toks[pos] end
    local pat
    function pat()
        if peek() ~= '(' then return nil, 'a pattern starts with `(`' end
        pos = pos + 1
        local t = peek()
        if type(t) ~= 'table' or not t.word then return nil, 'a pattern names a node type' end
        pos = pos + 1
        local p = { type = t.word ~= '_' and t.word or nil, kids = {}, caps = {} }
        local anchored = false
        while peek() ~= ')' do
            if peek() == nil then return nil, 'an unclosed pattern' end
            local anchor = false
            if peek() == '.' then
                if #p.kids > 0 or anchored then return nil, 'an anchor other than before the first child' end
                anchor, anchored = true, true; pos = pos + 1
            end
            local field
            if type(peek()) == 'table' and peek().field then field = peek().field; pos = pos + 1 end
            local k, why = pat()
            if not k then return nil, why end
            k.field, k.anchor = field, anchor
            p.kids[#p.kids + 1] = k
        end
        pos = pos + 1
        while type(peek()) == 'table' and peek().cap do p.caps[#p.caps + 1] = peek().cap; pos = pos + 1 end
        return p
    end
    local out = {}
    while pos <= #toks do
        local p, why = pat()
        if not p then return nil, why end
        out[#out + 1] = p
    end
    return out
end

function M.compile(text)
    local toks, why = tokenize(text)
    if not toks then return nil, why end
    local pats, pwhy = parse(toks)
    if not pats then return nil, pwhy end
    local m = { roots = {}, wild = {}, n = #pats }
    for i, p in ipairs(pats) do
        if p.type then
            local l = m.roots[p.type] or {}; m.roots[p.type] = l
            l[#l + 1] = { i, p }
        else
            m.wild[#m.wild + 1] = { i, p }
        end
    end
    return m
end

-- ★ WHEN A MATCH IS YIELDED. tree-sitter hands a match over when it COMPLETES — at the last node of the match in
-- pre-order — not where it starts: ruby's `a.b(x).c do … end` holds two calls starting at one byte, and the inner one
-- (method `b`) completes before the outer (method `c`, after the whole receiver). The oracle diffed exactly that order
-- (ruby-lsp, 17 rows). So every match carries its COMPLETION KEY: the start byte and the depth of its last node in
-- pre-order (an ancestor precedes its descendants at one byte) — and `all` yields in key order.
local function later(a_byte, a_depth, b_byte, b_depth)
    return a_byte > b_byte or (a_byte == b_byte and a_depth > b_depth)
end

-- every way pattern `p` matches node `n` (at depth `d`), each a captures table extending `caps` -> calls
-- k(caps, byte, depth) per way, byte / depth the completion key so far
local function each(p, n, caps, k, d, kb, kd)
    if p.type and n:type() ~= p.type then return end
    if not p.type and not n:named() then return end
    local _, _, nb = n:start()
    if not kb or later(nb, d, kb, kd) then kb, kd = nb, d end
    local mine = caps
    if #p.caps > 0 then
        mine = setmetatable({}, { __index = caps })
        for _, c in ipairs(p.caps) do rawset(mine, c, n) end
    end
    -- the children, in order: kid j matches some child after kid j-1's (a field kid: among that field's nodes)
    local kids = p.kids
    local function from(j, after, cc, b, dd)
        if j > #kids then return k(cc, b, dd) end
        local kp = kids[j]
        if kp.anchor then
            local c = n:named_child(0)
            if c and (not kp.field or n:field(kp.field)[1] == c) then
                each(kp, c, cc, function (c2, b2, d2) from(j + 1, 0, c2, b2, d2) end, d + 1, b, dd)
            end
            return
        end
        if kp.field then
            for _, c in ipairs(n:field(kp.field)) do
                local ci = nil
                for x = after, n:named_child_count() - 1 do if n:named_child(x) == c then ci = x; break end end
                if ci then each(kp, c, cc, function (c2, b2, d2) from(j + 1, ci + 1, c2, b2, d2) end, d + 1, b, dd) end
            end
        else
            for x = after, n:named_child_count() - 1 do
                each(kp, n:named_child(x), cc, function (c2, b2, d2) from(j + 1, x + 1, c2, b2, d2) end, d + 1, b, dd)
            end
        end
    end
    from(1, 0, mine, kb, kd)
end

local function flat(caps)
    local out = {}
    local mt = getmetatable(caps)
    while caps do
        for k, v in pairs(caps) do if out[k] == nil then out[k] = v end end
        mt = getmetatable(caps); caps = mt and mt.__index or nil
    end
    return out
end

-- ★ A CHAIN COMPILES TO A LOOP. Every call query is a CHAIN — each pattern node has at most one child pattern
-- (`(call_expression function: (identifier) @name) @call`, zig's two levels) — so a chain is compiled to straight
-- code: per level, the candidate children (the field's nodes, the first named child for an anchor, else every named
-- child), a type test, the captures written into a FRESH table only when the whole chain matched. Nested chain nodes
-- are each other's descendants, so the completion key is the DEEPEST node's. The interpreted `each` (closures, a
-- metatable per capture level, a child-index scan per field node) cost the fused walk more than the query it replaced.
-- A pattern with siblings stays interpreted.
local function chain_of(p)
    local levels = {}
    local cur = p
    while cur do
        levels[#levels + 1] = cur
        if #cur.kids > 1 then return nil end
        cur = cur.kids[1]
    end
    return levels
end
local function compile_chain(levels)
    local nl = #levels
    local wild_root = levels[1].type == nil
    return function (n, d, emit, pat)
        if wild_root and not n:named() then return end -- ((_) is a NAMED node; the caller dispatched only typed roots)
        local nodes = { n }
        local function level(j, parent)
            if j > nl then
                local caps = {}
                for x = 1, nl do for _, c in ipairs(levels[x].caps) do caps[c] = nodes[x] end end
                local last = nodes[nl]
                local _, _, b = last:start()
                return emit(pat, caps, b, d + nl - 1)
            end
            local lp = levels[j]
            local T = lp.type
            if lp.anchor then
                local c = parent:named_child(0)
                if c and (not lp.field or parent:field(lp.field)[1] == c) and (T and c:type() == T or not T) then
                    nodes[j] = c; level(j + 1, c)
                end
            elseif lp.field then
                for _, c in ipairs(parent:field(lp.field)) do
                    if T and c:type() == T or (not T and c:named()) then nodes[j] = c; level(j + 1, c) end
                end
            else
                for x = 0, parent:named_child_count() - 1 do
                    local c = parent:named_child(x)
                    if not T or c:type() == T then nodes[j] = c; level(j + 1, c) end
                end
            end
        end
        level(2, n)
    end
end

--- every match rooted at `node` (at depth `d` of the walk, its type `nt` if the walk has it), in pattern order:
--- emit(pattern, captures, byte, depth), byte / depth its completion key (see `later`)
function M.at(m, node, emit, d, nt)
    d = d or 1
    nt = nt or node:type()
    local l = m.roots[nt]
    if #m.wild > 0 then
        -- (wildcard-rooted and typed patterns that complete at one node come in PATTERN INDEX order, as the query
        -- yields them — merged once per node type)
        m.merged = m.merged or {}
        local mg = m.merged[nt]
        if not mg then
            mg = {}
            for _, e in ipairs(l or {}) do mg[#mg + 1] = e end
            for _, e in ipairs(m.wild) do mg[#mg + 1] = e end
            table.sort(mg, function (x, y) return x[1] < y[1] end)
            m.merged[nt] = mg
        end
        l = mg
    end
    if l then
        for _, e in ipairs(l) do
            if e.fast == nil then local lv = chain_of(e[2]); e.fast = lv and compile_chain(lv) or false end
            if e.fast then e.fast(node, d, emit, e[1])
            else each(e[2], node, {}, function (caps, b, dd) emit(e[1], flat(caps), b, dd) end, d) end
        end
    end
end


--- matches gathered during a walk, released in tree-sitter's order: by completion key, then as found (a stable
--- sort — two matches completing at one node keep the order the walk found them in)
function M.ordered(rows)
    for i, r in ipairs(rows) do r.seq = i end
    table.sort(rows, function (a, b)
        if a.byte ~= b.byte then return a.byte < b.byte end
        if a.depth ~= b.depth then return a.depth < b.depth end
        return a.seq < b.seq
    end)
    return rows
end

--- A QUERY'S MATCHES, COMPILED WHEN IT CAN BE: an iterator of captures tables ({ [name] = node }, the LAST node of
--- a multi-node capture — the extractor's cap_node) in tree-sitter's order. `text` is the query's source (compiled
--- once, cached); outside the subset — or CARTOGRAPH_TSQUERY=0 — it is `query:iter_matches(root, src, 0, -1, opts)`.
--- `pre`: rows a walk already gathered for this tree with M.at ({ caps, byte, depth }), nil to walk here.
--- (Lives here, not in the provider: its extractor function sits at LuaJIT's 60-upvalue limit.)
local COMPILED = {} -- query text -> matcher | false
--- the compiled matcher for a query's text (cached), or false: outside the subset, or CARTOGRAPH_TSQUERY=0 — a walk
--- that gathers rows for M.iter asks this first
function M.compiled(text)
    local m = COMPILED[text]
    if m == nil then m = M.compile(text) or false; COMPILED[text] = m end
    return os.getenv('CARTOGRAPH_TSQUERY') ~= '0' and m or false
end
function M.iter(query, text, root, src, opts, pre)
    local m = M.compiled(text)
    if m then
        local rows = pre
        if not rows then
            rows = {}
            require('cartograph.treewalk').solo(root, { any = function (n, _, _, d)
                M.at(m, n, function (_, caps, b, dd) rows[#rows + 1] = { caps = caps, byte = b, depth = dd } end, d)
            end })
        end
        M.ordered(rows)
        local i = 0
        return function () i = i + 1; local r = rows[i]; return r and r.caps end
    end
    local it = query:iter_matches(root, src, 0, -1, opts)
    return function ()
        local _, match = it()
        if not match then return nil end
        local caps = {}
        for id, ns in pairs(match) do caps[query.captures[id]] = (type(ns) == 'table' and ns[1] ~= nil) and ns[#ns] or ns end
        return caps
    end
end

--- every match in the tree, in tree-sitter's order: emit(pattern, captures)
function M.all(m, root, emit)
    local rows = {}
    require('cartograph.treewalk').solo(root, { any = function (n, _, _, d)
        M.at(m, n, function (pat, caps, b, dd) rows[#rows + 1] = { pat = pat, caps = caps, byte = b, depth = dd } end, d)
    end })
    for _, r in ipairs(M.ordered(rows)) do emit(r.pat, r.caps) end
end

return M
