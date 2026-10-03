-- cartograph.prefilter: a SOUND necessary condition derived from a template — required tokens on raw text, and the only
-- positions that can be a match root (an anchor token's ancestor at its fixed depth). Soundness is the test: no match
-- is ever lost, on hand-built shapes and on every luajs rule over real files.
local P = require 'cartograph.prefilter'
local A = require('cartograph.algebra').load()
local R = require 'cartograph.algebraread'

local function ready() if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end end
local lit, node, hole = A.lit, A.node, A.hole

test('prefilter: TOKENS are the fixed leaves every instance carries — not a hole\'s subtree, an optional pair, an embed or whitespace; a PINNED hole\'s value is', function ()
    local opt = { k = 'pair', opt = 'o1', kids = { lit 'maybe' } }
    local body = { k = 'obj', align = true, kids = { lit 'fixed', opt, lit ' ', { k = 'embed', g = 'sh', kids = { lit 'inner' } }, hole 'h', hole 'pin',
        { k = 'hole', h = 'c', ctx = true, kids = { lit 'ctxleaf' } } } }
    local T = A.template(body)
    T.holes.pin.domain = A.closed(lit 'pinned')
    eq({ 'pinned', 'fixed' }, P.tokens(T))
    local f = P.text(T)
    ok(f('xx fixed yy pinned'), 'both present: admitted')
    ok(not f('fixed only'), 'the pinned value missing: refused')
end)

test('prefilter: ANCHORS sit at a FIXED depth — a repetition hole does not move them, a context hole\'s subtree is not one', function ()
    local T = A.template(node('f', hole('xs', true), node('g', lit 'a')))
    eq({ { token = 'a', depth = 2 } }, P.anchors(T))
    local I = A.instantiate(T, { xs = A.seq({ node('b'), node('c'), node('d') }) }).term
    ok(A.match(T, I).ok, 'the instance matches')
    local cands = P.candidates(I, T, A.cst_print(I) .. ' a')
    eq(1, #cands); eq({}, cands[1].path, 'the root is the one candidate')
    eq({}, P.anchors(A.template({ k = 'hole', h = 'c', ctx = true, kids = { lit 'w' } })))
end)

test('prefilter: SOUND on real code — for every luajs rule over real files, every position A.match accepts is a candidate, and every file holding a match passes the text filter', function ()
    ready()
    local rules = require('cartograph.luajs.rules').all()
    local checked, matched = 0, 0
    for _, rel in ipairs({ 'lua/cartograph/byexample.lua', 'lua/cartograph/prefilter.lua', 'lua/cartograph/mixterm.lua' }) do
        local src = io.open(rel):read('a')
        local t = assert(R.read(src, 'lua'))
        local all = A.positions(t)
        for i, r in ipairs(rules) do
            local cands = P.candidates(t, r.lhs, src)
            local set = {}
            for _, c in ipairs(cands or all) do set[table.concat(c.path, '/')] = true end
            local f = P.text(r.lhs)
            for _, pos in ipairs(all) do
                if A.match(r.lhs, pos.node).ok then
                    matched = matched + 1
                    ok(set[table.concat(pos.path, '/')], ('rule %d: a match at %s is no candidate (%s)'):format(i, table.concat(pos.path, '/'), rel))
                    ok(f(src), ('rule %d: %s holds a match but fails the text filter'):format(i, rel))
                end
            end
            checked = checked + 1
        end
    end
    ok(checked == 3 * #rules and matched > 50, ('%d rule x file pairs, %d matches'):format(checked, matched))
end)

test('prefilter: the CONSUMER gives the same answers — byexample.rewrite with and without the prefilter, the same text and sites', function ()
    ready()
    local BE = require 'cartograph.byexample'
    local rules = assert(BE.learn('if x == nil then return end', 'if not x then return end'))
    for _, rel in ipairs({ 'lua/cartograph/mix.lua', 'lua/cartograph/toolbelt.lua' }) do
        local src = io.open(rel):read('a')
        local tp, np = BE.rewrite(rules, src)
        vim.env.CARTOGRAPH_PREFILTER = '0'
        local tu, nu = BE.rewrite(rules, src)
        vim.env.CARTOGRAPH_PREFILTER = nil
        eq(nu, np, rel); eq(tu, tp, rel)
    end
end)
