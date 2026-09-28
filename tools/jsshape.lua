-- jsshape — WHAT SHAPE IS EACH TABLE? The evidence for the "objects/arrays by shape" representation of the JS
-- transliteration (CART-1197; user decision 2026-09-29). Per ALLOCATION SITE (a table constructor):
--
--   nvim --headless -u NONE -l tools/jsshape.lua <dir> [--show CLASS]
--
-- A constructor BOUND BY `local x = {…}` is judged by EVERY USE OF THAT BINDING — the references the scope graph
-- resolves to that declaration (boundat + A.resolve: a shadowing local of the same name is a different binding, and
-- `x` inside `"x"` or `t.x` is no reference at all), each classified by its tree-sitter context:
--   array evidence    x[<number>], x[#x + 1], #x, ipairs(x), table.insert/remove/concat/sort/unpack(x, …)
--   record evidence   x.k, x:m(), x["literal"], and named entries in the constructor
--   unknown key       x[<expr>] whose key is neither a number nor a string literal (object / Map / array?)
--   escape            passed to another function, returned, stored in a table, aliased (the far side is unseen:
--                     its accesses must be REPRESENTATION-POLYMORPHIC, whatever this site chooses)
--   rebound           `x = …` later (the local holds more than this allocation)
-- ⇒ ARRAY (array evidence only) · RECORD (record only) · MIXED (both — a JS Array with properties, or a Map) ·
--   DYNAMIC (an unknown key: Map unless the key type is proven) · OPAQUE (no evidence at all).
-- A constructor NOT bound to a local (an argument, a return value, a field of another table) is judged by its own
-- entries only (positional -> array, named -> record, both -> mixed, none -> opaque) and counted apart.
-- ★ CONTROL: the number of constructors found by the query, beside the number judged, so a lost population shows.
local dir = vim.fn.fnamemodify(assert(arg[1], 'usage: jsshape.lua <dir> [--show CLASS]'), ':p'):gsub('/$', '')
local show
for i = 2, #arg do if arg[i] == '--show' then show = arg[i + 1] end end
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local B = require 'cartograph.boundat'

local ARRAY_FNS = { ipairs = true, ['table.insert'] = true, ['table.remove'] = true, ['table.concat'] = true,
    ['table.sort'] = true, unpack = true, ['table.unpack'] = true }
local NEUTRAL_FNS = { pairs = true, next = true, type = true, tostring = true, rawequal = true, assert = true }

local Q = vim.treesitter.query.parse('lua', '(table_constructor) @t')
local function text(n, src) return vim.treesitter.get_node_text(n, src) end
local function field_of(n, name) for c, f in n:iter_children() do if f == name then return c end end end

--- the entries of a constructor: positional count, named count
local function entries(tc, src)
    local pos, named = 0, 0
    for c in tc:iter_children() do
        if c:type() == 'field' then
            if field_of(c, 'name') then named = named + 1 else pos = pos + 1 end
        end
    end
    return pos, named
end

--- classify ONE reference node (an identifier) by its context
local function context(n, src, name)
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

local files = vim.fs.find(function (name) return name:match('%.lua$') end, { path = dir, type = 'file', limit = math.huge })
table.sort(files)
local classes, bound_n, free_n, found_n, ctx_total, noscope = {}, 0, 0, 0, {}, 0
local free_classes = {}
local examples = {}
for _, path in ipairs(files) do
    local fd = io.open(path); local src = fd:read('a'); fd:close()
    local rel = path:sub(#dir + 2)
    local tree = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]
    local root = tree:root()
    -- byte offset -> (row, col)
    local starts = { 0 }
    for i = 1, #src do if src:byte(i) == 10 then starts[#starts + 1] = i end end
    local function rc(off)
        local lo, hi = 1, #starts
        while lo < hi do local mid = math.floor((lo + hi + 1) / 2); if starts[mid] <= off then lo = mid else hi = mid - 1 end end
        return lo - 1, off - starts[lo]
    end
    local h = B.of(src, rel)
    -- the binding each declaration offset names, and every reference resolved to its declaration
    local uses = {}
    if h then
        local A, G = h.A, h.G
        for id, ref in pairs(G.refs or {}) do
            local off = h.ref_off[id]
            if off then
                -- ⚠ A.resolve takes the reference's ID (passing the record raised inside the pcall and every use was
                -- silently dropped — measured on the fixture: 11 references, 0 resolved)
                local okr, R = pcall(A.resolve, G, id)
                if okr and R and not R.absent and not R.ambiguous and R.entries and R.entries[1] then
                    local d = R.entries[1].decl
                    uses[d] = uses[d] or {}
                    table.insert(uses[d], off)
                end
            end
        end
    else noscope = noscope + 1 end
    local decl_at = {}
    for id, off in pairs(h and h.decl_off or {}) do decl_at[off] = id end
    for _, tc in Q:iter_captures(root, src, 0, -1) do
        found_n = found_n + 1
        local pos, named = entries(tc, src)
        -- bound by `local x = {…}`: the constructor is the i-th value of a local declaration whose i-th name is x
        local el = tc:parent()
        local stmt = el and el:type() == 'expression_list' and el:parent()
        local nameid
        if stmt and stmt:type() == 'assignment_statement' and stmt:parent() and stmt:parent():type() == 'variable_declaration' then
            local idx, i = nil, 0
            for c in el:iter_children() do if c:named() then i = i + 1; if c:equal(tc) then idx = i end end end
            local vl = field_of(stmt, 'name') and stmt or nil
            local names = {}
            for c in stmt:iter_children() do if c:type() == 'variable_list' then for v in c:iter_children() do if v:named() then names[#names + 1] = v end end end end
            nameid = idx and names[idx]
            if nameid and nameid:type() ~= 'identifier' then nameid = nil end
        end
        local ev = { array = named == 0 and pos > 0 and 1 or 0, record = named > 0 and 1 or 0 }
        if pos > 0 and named > 0 then ev.array = 1 end
        local class
        if nameid and h then
            local _, _, off = nameid:start()
            local d = decl_at[off]
            if d then
                bound_n = bound_n + 1
                local name = text(nameid, src)
                for _, roff in ipairs(uses[d] or {}) do
                    local r, c = rc(roff)
                    local n = root:named_descendant_for_range(r, c, r, c)
                    local k = n and context(n, src, name) or 'other'
                    ev[k] = (ev[k] or 0) + 1
                    ctx_total[k] = (ctx_total[k] or 0) + 1
                end
                if (ev.rebound or 0) > 0 then class = 'REBOUND'
                elseif (ev['unknown-key'] or 0) > 0 then class = 'DYNAMIC'
                elseif ev.array > 0 and ev.record > 0 then class = 'MIXED'
                elseif ev.array > 0 then class = 'ARRAY'
                elseif ev.record > 0 then class = 'RECORD'
                else class = 'OPAQUE' end
                if (ev.escape or 0) > 0 then class = class .. ' +escapes' end
                classes[class] = (classes[class] or 0) + 1
                if show and class:find(show, 1, true) then
                    local row = tc:start()
                    examples[#examples + 1] = ('%s:%d  %s  %s'):format(rel, row + 1, name, vim.inspect(ev, { newline = '', indent = '' }))
                end
            end
        end
        if not class then
            free_n = free_n + 1
            local fc = (pos > 0 and named > 0) and 'MIXED' or pos > 0 and 'ARRAY' or named > 0 and 'RECORD' or 'OPAQUE'
            free_classes[fc] = (free_classes[fc] or 0) + 1
        end
    end
end

local function dump(title, t, total)
    io.write(title, '\n')
    local rows = {}
    for k, n in pairs(t) do rows[#rows + 1] = { k = k, n = n } end
    table.sort(rows, function (a, b) if a.n ~= b.n then return a.n > b.n end return a.k < b.k end)
    for _, r in ipairs(rows) do io.write(('  %7d  %5.1f%%  %s\n'):format(r.n, total > 0 and 100 * r.n / total or 0, r.k)) end
end
io.write(('jsshape over %s: %d file(s) (%d without a scope graph); %d constructors found, %d bound to a local, %d not\n')
    :format(dir, #files, noscope, found_n, bound_n, free_n))
dump('BOUND (judged by every use of the binding):', classes, bound_n)
dump('NOT BOUND (judged by the constructor\'s own entries):', free_classes, free_n)
local ctot = 0
for _, n in pairs(ctx_total) do ctot = ctot + n end
dump(('USES of bound tables, by context (%d):'):format(ctot), ctx_total, ctot)
if show then io.write('\nexamples of ', show, ':\n'); for i = 1, math.min(40, #examples) do io.write('  ', examples[i], '\n') end end
