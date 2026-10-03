-- cartograph.compiledverb (CART-1339): match COMPILED to a static template by mix, used only once a SAMPLE LAW accepts
-- it, cached per object and on disk — and the consumer (byexample's rewrite) gives the same answers either way.
local CV = require 'cartograph.compiledverb'
local A = require('cartograph.algebra').load()
local R = require 'cartograph.algebraread'

local function ready() if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end end
local function rules() return require('cartograph.luajs.rules').all() end

test('compiledverb: a compiled matcher is ACCEPTED by the sample law and equals A.match on real subjects — the boundary samples include the template\'s own instances and degenerate terms', function ()
    ready()
    local all = rules()
    local term = assert(R.read(io.open('lua/cartograph/byexample.lua'):read('a'), 'lua'))
    for _, i in ipairs({ 1, 5, 14 }) do
        local T = all[i].lhs
        local f, how = CV.match(T)
        ok(f, 'rule ' .. i .. ': ' .. tostring(how))
        local samples = CV.samples(T)
        ok(#samples >= 5, #samples .. ' samples')
        local n = 0
        for _, pos in ipairs(A.positions(term)) do
            eq(A.match(T, pos.node), f(pos.node), ('rule %d at %s'):format(i, table.concat(pos.path, '.')))
            n = n + 1
        end
        ok(n > 1000, n .. ' real subjects')
    end
end)

test('compiledverb: a WRONG matcher is REJECTED by name — the law compares the whole result, not just ok', function ()
    local T = rules()[1].lhs
    local yes = function () return { ok = true, values = {} } end
    local okw, why = CV.accept(T, yes, CV.samples(T))
    ok(not okw and why:find('differs from A.match', 1, true), tostring(why))
    -- right on `ok`, wrong elsewhere: a matcher that drops the steps count is still refused
    local drop = function (I) local r = A.match(T, I); r.steps = nil; return r end
    local okd, whyd = CV.accept(T, drop, CV.samples(T))
    ok(not okd, tostring(whyd))
end)

test('compiledverb: CACHED — the same template object is a memo hit; an equal template (another object) comes from disk; CARTOGRAPH_COMPILED=0 turns it off', function ()
    ready()
    local T = rules()[3].lhs
    local f1 = CV.match(T)
    local f2, how2 = CV.match(T)
    eq(f1, f2); eq('memo', how2)
    local _, how3 = CV.match(vim.deepcopy(T))
    if os.getenv('CARTOGRAPH_STAMPCACHE') ~= '0' then eq('disk', how3) end
    vim.env.CARTOGRAPH_COMPILED = '0'
    local f4, why4 = CV.match(vim.deepcopy(T))
    vim.env.CARTOGRAPH_COMPILED = nil
    eq(nil, f4); ok(why4:find('disabled', 1, true), tostring(why4))
end)

test('compiledverb: a CHECKED memo — a template EDITED IN PLACE after compiling is not served the stale matcher (CART-1403)', function ()
    ready()
    local A = require('cartograph.algebra').load()
    local T
    for _, r in ipairs(rules()) do if not T and next(r.lhs.holes) then T = vim.deepcopy(r.lhs) end end
    ok(T, 'a rule with a hole')
    local f1 = CV.match(T)
    local _, how = CV.match(T)
    eq('memo', how, 'the premise: the same object, unchanged, is a hit')
    -- pin a hole's domain IN PLACE: the template's value changed, so the memo must not answer
    local h = next(T.holes)
    T.holes[h].domain = A.closed(A.lit('never-this-value'))
    local f2, how2 = CV.match(T)
    ok(how2 ~= 'memo', 'an edited template is recompiled or read from disk, not served from the memo: ' .. tostring(how2))
    ok(f2 ~= f1, 'and gets its own matcher')
end)

test('compiledverb: the CONSUMER gives the same answers — byexample.rewrite over real files, compiled vs interpreted, the same text and the same sites', function ()
    ready()
    local BE = require 'cartograph.byexample'
    local rules_ = assert(BE.learn('if x == nil then return end', 'if not x then return end'))
    local total = 0
    local served = function () return CV.stats.memo + CV.stats.disk + CV.stats.compiled end
    local before = served()
    for _, rel in ipairs({ 'lua/cartograph/mix.lua', 'lua/cartograph/byexample.lua', 'lua/cartograph/toolbelt.lua' }) do
        local src = io.open(rel):read('a')
        local tc, nc = BE.rewrite(rules_, src)
        vim.env.CARTOGRAPH_COMPILED = '0'
        local ti, ni = BE.rewrite(rules_, src)
        vim.env.CARTOGRAPH_COMPILED = nil
        eq(ni, nc, rel); eq(ti, tc, rel)
        total = total + nc
    end
    ok(total > 0, total .. ' sites rewritten')
    ok(served() >= before + 3, 'the rewrite took the COMPILED path (one matcher per file served)')
end)
