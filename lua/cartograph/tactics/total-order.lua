-- TOTAL-ORDER (write, CART-1444): make a sort's comparator TOTAL — the rewrite sort-ties asks for (CART-1434's hand
-- edit). `site` = the sort's call site as sort-ties reports it (file:line, relative to the graph's root), `by` = the
-- tie-break: element paths (`.id`, `[1].file`, …) in order, as sort-ties' `separators` lists them (non-nil and
-- distinct across EVERY element of the sorts it saw there). The comparator's final `return L op R` becomes
--     if L ~= R then return L op R end
--     if a.p1 ~= b.p1 then return a.p1 < b.p1 end      (each tie-break but the last)
--     return a.pN < b.pN
-- which orders every pair the old comparator ordered the same way, and the old ties by the tie-break, ascending.
-- ★ WHICH FIELD IS THE DECISION: without `by` the run STOPS on `tie-break` (sort-ties derives the candidates; choosing
-- among them is a judgement about what the order MEANS). REFUSES BY NAME (unbuilt): no `table.sort` at the site, a
-- comparator passed by name (rewrite it where it is defined), a final statement that is not `return L < R` / `L > R`.
local T = require('cartograph.tactic').T
local inext = require('cartograph.spec.tsutil').inext

local function text_of(node, src) return vim.treesitter.get_node_text(node, src) end

local function build(p, store)
    local file, line = tostring(p.site):match('^(.-):(%d+)$')
    if not file then return nil, ('site = file:line (as sort-ties reports it), not %q'):format(tostring(p.site)), 'ill-posed' end
    line = tonumber(line)
    local src = require('cartograph.txn').read_file(store.data.root, file)
    if not src then return nil, ('cannot read %s'):format(file), 'stale' end
    if not file:match('%.lua$') then return nil, ('total-order writes Lua; %s is not a .lua file'):format(file), 'unbuilt' end
    local root = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    -- the INNERMOST `table.sort(…)` call whose lines hold the site
    local call
    local function walk(n)
        local sl, _, el = n:range()
        if line - 1 < sl or line - 1 > el then return end
        if n:type() == 'function_call' then
            local name = n:field('name')[1]
            if name and text_of(name, src) == 'table.sort' then call = n end
        end
        for _, c in inext, n, -1 do walk(c) end
    end
    walk(root)
    if not call then return nil, ('no table.sort call at %s'):format(p.site), 'unbuilt' end
    local args = call:field('arguments')[1]
    local cmp = args and args:named_child(1)
    if not cmp then return nil, ('the sort at %s has no comparator: its elements sort by `<` — a list of distinct scalars has no ties'):format(p.site), 'unbuilt' end
    if cmp:type() ~= 'function_definition' then
        return nil, ('the comparator at %s is `%s`, passed by name: rewrite it where it is defined'):format(p.site, text_of(cmp, src)), 'unbuilt'
    end
    local names = {}
    for _, c in inext, cmp:field('parameters')[1], -1 do if c:named() then names[#names + 1] = text_of(c, src) end end
    if #names ~= 2 then return nil, ('the comparator at %s takes %d parameters, not (a, b)'):format(p.site, #names), 'unbuilt' end
    local body = cmp:field('body')[1]
    local last = body and body:named_child(body:named_child_count() - 1)
    local expr = last and last:type() == 'return_statement' and last:named_child(0)
    expr = expr and expr:type() == 'expression_list' and expr:named_child_count() == 1 and expr:named_child(0)
    local op = expr and expr:type() == 'binary_expression' and expr:child(1) and expr:child(1):type()
    if not (op == '<' or op == '>') then
        return nil, ('the comparator at %s does not end in `return L < R` / `return L > R`: %s'):format(p.site,
            last and vim.trim(text_of(last, src)):sub(1, 80) or '(empty)'), 'unbuilt'
    end
    if not p.by or #p.by == 0 then
        return nil, ('which tie-break makes the sort at %s total? by = element paths (`.id`, `[1].file`): run sort-ties — its `separators` are the paths unique across every element there'):format(p.site), 'decision'
    end
    for _, path in ipairs(p.by) do
        local rest = path
        while rest ~= '' do
            local nxt = rest:match('^%.[%a_][%w_]*()') or rest:match('^%[%d+%]()')
            if not nxt then return nil, ('by: `%s` is not an element path (`.field`, `[1].field`)'):format(path), 'ill-posed' end
            rest = rest:sub(nxt)
        end
    end
    local L, R = text_of(expr:named_child(0), src), text_of(expr:named_child(1), src)
    local lines = vim.split(src, '\n', { plain = true })
    local ls, lc = last:start()
    local ind = lines[ls + 1]:match('^[ \t]*')
    local a, b = names[1], names[2]
    local out = { ('if %s ~= %s then return %s %s %s end'):format(L, R, L, op, R) }
    for i, path in ipairs(p.by) do
        if i < #p.by then out[#out + 1] = ind .. ('if %s%s ~= %s%s then return %s%s < %s%s end'):format(a, path, b, path, a, path, b, path)
        else out[#out + 1] = ind .. ('return %s%s < %s%s'):format(a, path, b, path) end
    end
    local before = text_of(cmp, src)
    local cs, cc = cmp:start()
    -- the comparator's text with its final return replaced (offsets inside the comparator's own text)
    local function offset(l, c) local o = 0; for i = 1, l do o = o + #lines[i] + 1 end; return o + c end
    local s0, l0 = offset(cs, cc), offset(ls, lc)
    local l1 = l0 + #text_of(last, src)
    local after = before:sub(1, l0 - s0) .. table.concat(out, '\n') .. before:sub(l1 - s0 + 1)
    return T.step('edit', { file = file, before = before, after = after })
end

local SRC = table.concat({
    'local M = {}',
    'function M.order(xs)',
    '  table.sort(xs, function (a, b)',
    '    return a.len < b.len',
    '  end)',
    '  return xs',
    'end',
    'function M.named(xs) table.sort(xs, M.cmp) return xs end',
    'function M.call(xs) table.sort(xs, function (a, b) return M.cmp(a, b) end) return xs end',
    'return M', '' }, '\n')

return {
    name = 'total-order',
    kind = 'write',
    tags = { 'code', 'optimize' },
    summary = 'make a sort comparator TOTAL: site = file:line of a table.sort (sort-ties reports it), by = tie-break element paths (`.id`, `[1].file`; sort-ties lists the separators) — the final `return L < R` becomes `if L ~= R then return L < R end` + the tie-breaks; without `by` it stops on the tie-break decision',
    params = { site = 'string', by = 'list?' },
    build = build,
    examples = {
        {
            name = 'a partial comparator gets the tie-break: equal lengths now come out by id, whatever the input order',
            files = { ['s.lua'] = SRC },
            params = { site = 's.lua:3', by = '.id' },
            expect = { status = 'done', applied = 1, check = function (root)
                local m = dofile(root .. '/s.lua')
                local one = m.order({ { len = 1, id = 3 }, { len = 0, id = 9 }, { len = 1, id = 1 }, { len = 1, id = 2 } })
                local two = m.order({ { len = 1, id = 2 }, { len = 1, id = 1 }, { len = 0, id = 9 }, { len = 1, id = 3 } })
                local ids = {}
                for i = 1, 4 do ids[i] = one[i].id .. '/' .. two[i].id end
                return table.concat(ids, ' ') == '9/9 1/1 2/2 3/3', table.concat(ids, ' ') .. '\n' .. io.open(root .. '/s.lua'):read('a')
            end },
        },
        {
            name = 'no `by`: the run STOPS on the tie-break decision, nothing written',
            files = { ['s.lua'] = SRC },
            params = { site = 's.lua:4' },
            expect = { status = 'stopped', applied = 0 },
        },
        {
            name = 'a comparator passed BY NAME, and one that does not end in a comparison: refused by name as unbuilt',
            files = { ['s.lua'] = SRC },
            params = { site = 's.lua:8', by = '.id' },
            expect = { status = 'failed', applied = 0, check = function (root)
                local tb = require 'cartograph.toolbelt'
                local r = tb.run(require 'cartograph.store', 'total-order', { site = 's.lua:9', by = '.id' }, { apply = true })
                return r and r.status == 'failed' and r.class == 'unbuilt' and r.why:find('does not end in', 1, true) ~= nil, vim.inspect(r and r.why)
            end },
        },
    },
}
