-- TEMPLATE-SITES (discovery, CART-1367): every site where a TEMPLATE matches, with what each hole bound — a template
-- query. `example` is an expression written as code (`vim.json.encode(x)`), `holes` names the identifiers in it that
-- are holes (`x`); every other part is fixed. Built only from what exists: the prefilter's text filter on each file
-- (cartograph.prefilter — a file lacking a fixed token cannot hold a match), the reader with a SIDE MAP of source rows
-- keyed by term node (per-occurrence data beside the term, not on it — CART-1361's shape), the prefilter's anchor
-- candidates, and the COMPILED matcher accepted by its sample law (cartograph.compiledverb). byexample's read-only half.
-- Value: { sites = { { file, line, values = { hole -> text } } }, kinds = { hole -> { value kind -> n } }, files }.
-- ⚠ Matching is exact up to the example's own whitespace unless trivia = 1 (CART-1404: modulo whitespace and comments).
-- CLAIM: the template occurs.
local function A() return require('cartograph.algebra').load() end

--- the template of `example` with the identifiers named in `holes` made holes -> template | nil, why
local function template_of(example, holes)
    local a, R = A(), require 'cartograph.algebraread'
    local t = R.read('return ' .. example, 'lua')
    if not t then return nil, ('`%s` does not read as a Lua expression'):format(example) end
    -- the expression is the DEEPEST node that prints exactly as the example (an expression_list prints the same)
    local best
    for _, pos in ipairs(a.positions(t)) do
        if pos.node.kids and a.cst_print(pos.node) == example then best = pos.node end
    end
    if not best then return nil, ('`%s`: no expression node prints as the example'):format(example) end
    local want = {}
    for _, h in ipairs(holes or {}) do want[h] = true end
    local made = {}
    local function hole(n)
        if n.k == 'identifier' and n.kids and n.kids[1] and n.kids[1].k == 'lit' and want[n.kids[1].v] then
            made[n.kids[1].v] = true
            return a.hole(n.kids[1].v)
        end
        if not n.kids then return n end
        local kids = {}
        for i, c in ipairs(n.kids) do kids[i] = hole(c) end
        return a.rebuild(n, kids)
    end
    local body = hole(best)
    for h in pairs(want) do if not made[h] then return nil, ('hole `%s` names no identifier of `%s`'):format(h, example) end end
    return a.template(body)
end

local E = {
    name = 'template-sites',
    kind = 'discovery',
    tags = { 'find', 'code' },
    measures = 'CART-1367',
    summary = 'every site where a template matches, with what each hole bound: example = an expression as code (vim.json.encode(x)), holes = its identifiers that are holes (x), files = scope (default: every .lua file of the graph)',
    params = { example = 'string', holes = 'list?', files = 'list?', trivia = 'string?' },
    measure = function (store, p)
        local a, R = A(), require 'cartograph.algebraread'
        local T, why = template_of(p.example, p.holes)
        if not T then return { error = why } end
        -- ★ trivia = 1: MATCH MODULO TRIVIA (CART-1404, CART-1158 item 1) — the template and each candidate are compared
        -- without the whitespace and comments the reader MARKED as trivia (the gaps it keeps between tokens, the nodes
        -- the parser reports as extras), so `x==nil` is a site of `x == nil`. Rows stay the original nodes'; a bound
        -- value prints modulo trivia when it held some.
        local spec = p.trivia == '1' or p.trivia == true
        if spec then T = a.template(a.strip_trivia(T.body), T.holes) end
        local P, CV = require 'cartograph.prefilter', require 'cartograph.compiledverb'
        local filter = P.text(T)
        local compiled = CV.match(T, { refusal = 'none' }) -- (only `ok` and a hit's `values` are read: CART-1465)
        local files = p.files
        if not files then
            files = {}
            for _, f in ipairs(store.files or {}) do if f:match('%.lua$') then files[#files + 1] = f end end
        end
        local root = store.data.root
        local sites, kinds, read, skipped = {}, {}, 0, 0
        for _, rel in ipairs(files) do
            local fd = io.open(root .. '/' .. rel)
            local src = fd and fd:read('a')
            if fd then fd:close() end
            if src and filter(src) then
                local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
                local rows = {}
                local t = ok and R.read_tree(src, 'lua', parser:parse()[1], function (node, term) rows[term] = (node:range()) end)
                if t then
                    read = read + 1
                    for _, pos in ipairs(P.candidates(t, T, src) or a.positions(t)) do
                        local subject = spec and a.strip_trivia(pos.node) or pos.node
                        local m = compiled and compiled(subject) or a.match(T, subject)
                        if m.ok then
                            local vals = {}
                            for h, v in pairs(m.values) do
                                vals[h] = a.cst_print(v)
                                kinds[h] = kinds[h] or {}
                                kinds[h][v.k] = (kinds[h][v.k] or 0) + 1
                            end
                            sites[#sites + 1] = { file = rel, line = rows[pos.node] and rows[pos.node] + 1, values = vals }
                        end
                    end
                end
            elseif src then skipped = skipped + 1 end
        end
        return { sites = sites, kinds = kinds, files = read, prefiltered = skipped }
    end,
    claim = function (v)
        if v.error then return false, v.error end
        if #v.sites == 0 then return false, ('the template occurs nowhere (%d file(s) read, %d ruled out by text)'):format(v.files, v.prefiltered) end
        return true, ('%d site(s) in %d file(s) read (%d ruled out by text)'):format(#v.sites, v.files, v.prefiltered)
    end,
}

local FILES = {
    ['a.lua'] = 'local M = {}\nfunction M.f(state)\n  local s = vim.json.encode({ a = 1 })\n  return s .. vim.json.encode(state)\nend\nreturn M\n',
    ['b.lua'] = 'return { x = 1 }\n',
    ['c.lua'] = 'local t = {}\nreturn vim.json.encode(t, { indent = true })\n',
}

E.examples = {
    {
        name = 'every site of a one-argument call, with the argument each one sends and its kind; a two-argument call is not this template',
        files = FILES, params = function () return { example = 'vim.json.encode(x)', holes = { 'x' }, files = { 'a.lua', 'b.lua', 'c.lua' } } end,
        expect = { holds = true, check = function (v)
            local lines = {}
            for _, s in ipairs(v.sites) do lines[#lines + 1] = s.file .. ':' .. tostring(s.line) .. ' ' .. s.values.x end
            table.sort(lines)
            return #v.sites == 2 and lines[1] == 'a.lua:3 { a = 1 }' and lines[2] == 'a.lua:4 state'
                and v.kinds.x.table_constructor == 1 and v.kinds.x.identifier == 1 and v.prefiltered == 1, table.concat(lines, '; ')
        end },
    },
    {
        name = 'a hole naming no identifier of the example is refused by name',
        files = FILES, params = function () return { example = 'vim.json.encode(x)', holes = { 'y' }, files = { 'a.lua' } } end,
        expect = { holds = false, check = function (v) return (v.error or ''):find('hole `y`', 1, true) ~= nil, tostring(v.error) end },
    },
    {
        -- CART-1404: `vim.json.encode( state --[[ the record ]] )` is the same call; exact matching misses it
        name = 'trivia = 1 matches MODULO TRIVIA: a call written with extra spaces and a comment inside is a site; exact matching misses it',
        files = { ['d.lua'] = 'return vim.json.encode( state --[[ the record ]] )\n' },
        params = function () return { example = 'vim.json.encode(x)', holes = { 'x' }, files = { 'd.lua' }, trivia = '1' } end,
        expect = { holds = true, check = function (v) return #v.sites == 1 and v.sites[1].values.x == 'state', vim.inspect(v.sites) end },
    },
    {
        name = '…and the same file WITHOUT trivia = 1 has no site (the call\'s spacing is not the example\'s)',
        files = { ['d.lua'] = 'return vim.json.encode( state --[[ the record ]] )\n' },
        params = function () return { example = 'vim.json.encode(x)', holes = { 'x' }, files = { 'd.lua' } } end,
        expect = { holds = false },
    },
    {
        name = 'a template that occurs nowhere says so, with how many files were read and ruled out',
        files = FILES, params = function () return { example = 'vim.mpack.encode(x)', holes = { 'x' }, files = { 'a.lua', 'b.lua', 'c.lua' } } end,
        expect = { holds = false, check = function (v) return #v.sites == 0 and v.prefiltered == 3, ('read %d, ruled out %d'):format(v.files, v.prefiltered) end },
    },
}

return E
