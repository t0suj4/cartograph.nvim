-- cartograph.mixterm (CART-1341): mix's IR seen by the algebra through a LENS — the round trip on real IR is the oracle,
-- the schema is held to mix.lua's own constructor sites, and the algebra must SEE what is semantic.
local MX = require 'cartograph.mix'
local MT = require 'cartograph.mixterm'
local R = require 'cartograph.algebraread'
local A = require('cartograph.algebra').load()

local function ready() if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end end
local function body_of(src, fname) return MX.lower(assert(R.read(src, 'lua'))).funcs[fname].body end

test('mixterm: the ROUND TRIP on real IR — every function of the algebra\'s match closure (source IR) and of a compiled matcher (residual IR) comes back identical', function ()
    ready()
    local MA = require 'cartograph.mixalg'
    local prog = MX.lower(assert(R.read((MA.program('M.match')), 'lua')))
    local nodes, nf = 0, 0
    local function count(t) nodes = nodes + 1; for _, c in ipairs(t.kids or {}) do count(c) end end
    local function check(tag, body)
        local t = MT.block_term(body)
        count(t)
        eq(body, MT.of_block(t), tag)
        nf = nf + 1
    end
    for name, f in pairs(prog.funcs) do check('source ' .. name, f.body) end
    local rule = require('cartograph.luajs.rules').all()[5]
    local res = MX.specialize(prog, 'M_match', { 'S', 'D', 'S' }, { rule.lhs }, { budget = 5e6, globals = { ['M.grammars'] = A.grammars or {} } })
    for name, f in pairs(res.funcs) do check('residual ' .. name, f.body) end
    ok(nf >= 50 and nodes >= 5000, ('%d functions, %d term nodes'):format(nf, nodes))
end)

test('mixterm: the algebra SEES what is semantic — an operator and a constant are kids, so `x + 1` is not `x - 1`, and A.join through the lens holes exactly the constant', function ()
    ready()
    local function expr(src) return body_of('local function f(x)\n    return ' .. src .. '\nend\n', 'f')[1].es[1] end
    local plus1, minus1, plus2 = MT.to_term(expr('x + 1')), MT.to_term(expr('x - 1')), MT.to_term(expr('x + 2'))
    ok(not A.eq(plus1, minus1), 'the operator is a kid')
    ok(A.eq(plus1, MT.to_term(expr('x + 1'))), 'equal IR, equal terms')
    local j = A.join(A.template(plus1), A.template(plus2))
    eq(1, #j.new, 'one hole: ' .. A.show(j.template.body))
    local back = A.instantiate(j.template, { [j.new[1]] = j.frags[j.new[1]].left })
    eq(expr('x + 1'), MT.of_term(back.term), 'instantiated with the left side, the lens gives back the IR of x + 1')
end)

test('mixterm: the SCHEMA is held to mix.lua — every constructor site\'s fields are in its kind\'s schema, and every schema kind is constructed somewhere', function ()
    ready()
    local src = io.open('lua/cartograph/mix.lua'):read('a')
    local tree = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    local q = vim.treesitter.query.parse('lua', '(table_constructor) @t')
    local seen, sites, stray = {}, 0, {}
    for _, t in q:iter_captures(tree, src, 0, -1) do
        local op, fields = nil, {}
        for i = 0, t:named_child_count() - 1 do
            local f = t:named_child(i)
            local nm, val = f:field('name')[1], f:field('value')[1]
            if f:type() == 'field' and nm then
                local key = vim.treesitter.get_node_text(nm, src)
                fields[#fields + 1] = key
                if key == 'op' and val and val:type() == 'string' then op = (vim.treesitter.get_node_text(val, src):gsub('^[\'"]', ''):gsub('[\'"]$', '')) end
            end
        end
        if op then
            sites = sites + 1
            seen[op] = true
            local s = MT.SCHEMA[op]
            if not s then stray[#stray + 1] = op .. ' (no schema)'
            else
                local names = {}
                for _, e in ipairs(s) do names[e[1]] = true end
                for _, k in ipairs(fields) do if k ~= 'op' and not names[k] then stray[#stray + 1] = op .. '.' .. k end end
            end
        end
    end
    eq({}, stray, 'constructor fields outside the schema')
    local unused = {}
    for k in pairs(MT.SCHEMA) do if not seen[k] then unused[#unused + 1] = k end end
    eq({}, unused, 'schema kinds no constructor makes')
    ok(sites >= 80, sites .. ' constructor sites')
end)

test('mixterm: a RESIDUAL PROGRAM is a term graph — calls are edges, recursion a cycle — so tg_show compares residuals independent of the generated function names', function ()
    ready()
    local src = 'local function count(x, n)\n    if x > 0 then return count(x - 1, n + 1) end\n    return n\nend\n'
    local prog = MX.lower(assert(R.read(src, 'lua')))
    local res = MX.specialize(prog, 'count', { 'D', 'S' }, { nil, 0 })
    -- the same residual with every function renamed: different text, the same graph
    local ren = {}
    for i, nm in ipairs(res.order) do ren[nm] = 'renamed_' .. (#res.order - i + 1) end
    local function rename(t)
        if t.k == 'call' and t.kids[1].k == 'lit' and ren[t.kids[1].v] then
            return { k = 'call', kids = { { k = 'lit', v = ren[t.kids[1].v] }, rename(t.kids[2]) } }
        end
        if not t.kids then return t end
        local kids = {}
        for i, c in ipairs(t.kids) do kids[i] = rename(c) end
        return { k = t.k, kids = kids }
    end
    local res2 = { funcs = {}, order = {}, entry = ren[res.entry] }
    for i = #res.order, 1, -1 do
        local nm = res.order[i]
        res2.order[#res2.order + 1] = ren[nm]
        res2.funcs[ren[nm]] = { name = ren[nm], params = res.funcs[nm].params, body = MT.of_block(rename(MT.block_term(res.funcs[nm].body))) }
    end
    ok(MX.print(res) ~= MX.print(res2), 'the texts differ')
    local s1, s2 = A.tg_show(MT.program_graph(res)), A.tg_show(MT.program_graph(res2))
    eq(s1, s2, 'the graphs print the same')
    -- recursion is a CYCLE: some function's equation is called from inside its own body
    local cyclic = false
    for z in s1:gmatch('(z%d+)=fun%(') do if s1:find('call(' .. z .. ',', 1, true) then cyclic = true end end
    ok(cyclic, 'a residual function calls itself through an edge\n' .. s1)
    -- and a structural difference is seen: n starting at 1 instead of 0
    local res3 = MX.specialize(MX.lower(assert(R.read(src, 'lua'))), 'count', { 'D', 'S' }, { nil, 1 })
    ok(A.tg_show(MT.program_graph(res3)) ~= s1, 'a different residual prints differently')
end)

test('mixterm: what the lens does not know is REFUSED by name — an unknown kind, a field outside the schema', function ()
    local okk, e1 = pcall(MT.to_term, { op = 'goto', label = 'x' })
    ok(not okk and e1.refusal:find('no schema for the IR kind goto', 1, true), vim.inspect(e1))
    local okf, e2 = pcall(MT.to_term, { op = 'num', v = 1, extra = true })
    ok(not okf and e2.refusal:find('`extra`', 1, true), vim.inspect(e2))
end)
