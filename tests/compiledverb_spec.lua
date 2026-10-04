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

test('compiledverb: a mix REFUSAL is remembered like a success — the same object, an equal template, and a fresh process (from disk) do not pay it again (CART-1436)', function ()
    local MA = require 'cartograph.mixalg'
    local real, calls = MA.compile_match, 0
    MA.compile_match = function () calls = calls + 1; error({ refusal = 'synthetic budget' }, 0) end
    local T = A.template(A.node('refusal_probe_' .. tostring(vim.uv.hrtime()), A.hole('x')))
    local ok1, f1, why1 = pcall(CV.match, T)
    local ok2, f2, why2 = pcall(CV.match, T)
    local ok3, f3 = pcall(CV.match, vim.deepcopy(T))
    -- a fresh process: the module's memo and refusal table gone, only the disk store left
    package.loaded['cartograph.compiledverb'] = nil
    local CV2 = require 'cartograph.compiledverb'
    local ok4, f4, why4 = pcall(CV2.match, vim.deepcopy(T))
    package.loaded['cartograph.compiledverb'] = CV
    MA.compile_match = real
    ok(ok1 and ok2 and ok3 and ok4, 'no call raised')
    eq(nil, f1); ok(tostring(why1):find('synthetic budget', 1, true), tostring(why1))
    eq(nil, f2); eq(why1, why2, 'the same object: the remembered refusal')
    eq(nil, f3)
    eq(nil, f4)
    if os.getenv('CARTOGRAPH_STAMPCACHE') ~= '0' then
        eq(1, calls, 'mix ran ONCE for the object, an equal template and a fresh process')
        ok(tostring(why4):find('synthetic budget', 1, true), 'the disk keeps the reason: ' .. tostring(why4))
    end
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

test('compiledverb: a compiled matcher that RAISES is DEOPTIMIZED — the original runs, and ITS error is the one the caller sees, from the algebra\'s source (CART-1459)', function ()
    ready()
    local T = rules()[8].lhs
    local f = assert(CV.match(T))
    local d0 = CV.stats.deopt
    -- (a subject the original cannot read: a kid that is no term — A.match raises in algebra/match.lua)
    local bad = { k = T.body.k, kids = { 5 } }
    local okw, want = pcall(A.match, T, bad)
    eq(false, okw)
    local okf, got = pcall(f, bad)
    eq(false, okf)
    ok(tostring(got):find('algebra/match.lua', 1, true), 'the ORIGINAL\'s error: ' .. tostring(got))
    eq(tostring(want), tostring(got))
    eq(d0 + 1, CV.stats.deopt, 'the compiled matcher raised and was deoptimized')
end)

test('compiledverb: a compiled matcher that raises where the original ANSWERS has DIVERGED — the right answer returned, the divergence recorded, the matcher retired (CART-1459)', function ()
    ready()
    local T = rules()[8].lhs
    local I = CV.samples(T)[1]
    local calls, told = 0, nil
    local served = CV.deopt(T, function () calls = calls + 1; error('boom in residual code') end, function (d) told = d end)
    local v0 = CV.stats.diverged
    eq(A.match(T, I), served(I))
    eq(v0 + 1, CV.stats.diverged)
    ok(told and told.error:find('boom in residual code', 1, true), vim.inspect(told))
    eq(told, CV.divergences[#CV.divergences])
    eq(A.match(T, I), served(I))
    eq(1, calls, 'retired: the second call runs only the original')
    -- (and CV.match REFUSES it from then on: a fake compiler that passes the sample law, then raises on one subject)
    local T2 = vim.deepcopy(rules()[9].lhs)
    local odd = { k = T2.body.k, kids = {} }
    local fake = function (S) if S == odd then error('boom at run time') end return A.match(T2, S) end
    local f2, how = CV.match(T2, { compile = function () return fake, 'fake text', {}, {} end })
    eq('compiled', how)
    eq(A.match(T2, odd), f2(odd))
    local again, why = CV.match(T2)
    eq(nil, again); ok(tostring(why):find('DIVERGED at run time', 1, true), tostring(why))
end)
