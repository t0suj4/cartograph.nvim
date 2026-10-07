-- fnpeer: a Lua function's peer for peergen (CART-1538) — terms survive the trip (marks and literal types), roles are
-- read off a sample, variation points never nest, and the IDENTITY: a client generated from the model, its holes filled
-- with the sampled subterms, hands the transport the sample's own arguments back.

local FP = require 'cartograph.fnpeer'
local PG = require 'cartograph.peergen'
local A = require('cartograph.algebra').load()
local L, H, N = A.lit, A.hole, A.node

test('fnpeer: a term survives encode -> peergen serialize -> decode, marks and literal types included', function ()
    local t = N('f', L(1), L(true), L('s'), H('xs', true), A.ctx('C', { H('y') }), A.name('n'),
        A.keyed('obj', { N('pair', L('a'), L(2)) }), { k = 'embed', g = 'lua', kids = { N('x') } })
    local back = FP.decode(assert(load('return ' .. PG.serialize(FP.encode(t))))())
    eq(A.show(t), A.show(back), 'the same term')
    eq('number', type(back.kids[1].v)); eq('boolean', type(back.kids[2].v)); eq('string', type(back.kids[3].v))
    eq(true, back.kids[4].rep); eq(true, back.kids[5].ctx); eq('n', back.kids[6].n)
    eq('keyed', back.kids[7].align); eq('lua', back.kids[8].g)
end)

test('fnpeer: roles are read off a sample — template, term, a list of terms, a family, anything else fixed', function ()
    local T = A.template(N('f', H('x')))
    local fam = { template = T, values = { { x = L(1) }, { x = L(2) } } }
    eq({ 'template', 'term', 'terms', 'family', 'fixed', 'fixed' }, FP.roles({ n = 6, T, N('g'), { N('a'), N('b') }, fam, { 1, 2 }, 'opt' }))
end)

local function sample()
    local T = A.template(N('f', H('x'), N('g', L(1), H('ys', true))))
    return { n = 4, T, N('call', L(2), A.seq({ L(3) })), { N('a', L(1)), N('b') }, { template = T, values = { { x = L(7), ys = A.seq({}) } } } }
end

test('fnpeer: variation points sit on the kinds the case split names, never nested, and the IDENTITY filling gives the sample back', function ()
    local s = sample()
    local model, meta = FP.model('op', { s }, { vocab = { hole = true, lit = true, seq = true }, points = 8 })
    local o = model.operations[1]
    ok(#o.params > 0, 'variation points: ' .. #o.params)
    -- (no point inside another: each filled whole)
    local seen = 0
    local function count(t) if type(t) ~= 'table' then return end; if t.k == 'hole' and tostring(t.h):match('^p%d+$') then seen = seen + 1; return end; for _, c in ipairs(t.kids or {}) do count(c) end end
    count(o.request)
    eq(#o.params, seen, 'every parameter is one hole of the request')
    -- the client peergen GENERATES from the model, its transport recording what it is handed
    local got
    local client = assert(load(PG.generate(model)))().new({ exchange = function (req, op) got = FP.decode_args(A, meta[op.name], req); return { k = 'reply' } end })
    local args = {}
    for _, h in ipairs(o.params) do args[h] = meta[o.name].orig[h] end
    client[o.name](args)
    eq(A.show(s[1].body), A.show(got[1].body), 'the template')
    eq(A.show(s[2]), A.show(got[2]), 'the term')
    eq({ A.show(s[3][1]), A.show(s[3][2]) }, { A.show(got[3][1]), A.show(got[3][2]) }, 'the list')
    eq(A.show(s[4].template.body), A.show(got[4].template.body), 'the family template')
    eq({ A.show(s[4].values[1].x), A.show(s[4].values[1].ys) }, { A.show(got[4].values[1].x), A.show(got[4].values[1].ys) }, 'the family values')
end)

test('fnpeer: a filling that removes a hole drops its sampled domain; the rebuilt template is well formed', function ()
    local s = { n = 1, A.template(N('f', H('x'), H('z'))) }
    local model, meta = FP.model('op', { s }, { vocab = { hole = true }, points = 8 })
    local o = model.operations[1]
    local got
    local client = assert(load(PG.generate(model)))().new({ exchange = function (req, op) got = FP.decode_args(A, meta[op.name], req); return { k = 'reply' } end })
    local args = {}
    for _, h in ipairs(o.params) do args[h] = FP.encode(L(5)) end -- (every hole replaced by a literal)
    client[o.name](args)
    eq('(f 5 5)', A.show(got[1].body))
    eq({}, vim.tbl_keys(got[1].holes), 'no domain for a hole that is gone')
end)
