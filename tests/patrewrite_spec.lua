-- CART-1057: the first REMEDY for a loopcost finding — a backtracking search idiom rewritten into a
-- verified linear equivalent (lua/cartograph/patrewrite.lua).
-- ★ ACCEPTANCE: every rule answers like the original on 114k corpus inputs (M.verify) and measures
-- linear where the original is quadratic (M.measure; the obvious trim rewrite measured 1.90 and was
-- rejected). On cartograph itself: 4 sites, 7 declined with reasons.

local P = require 'cartograph.patrewrite'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local txn = require 'cartograph.txn'

local FIX = vim.fn.getcwd() .. '/tests/fixtures/patrewrite/trims.lua'

local function has_lua()
    return pcall(vim.treesitter.language.add, 'lua')
end

test('patrewrite: every catalog rule answers like the original on the whole corpus', function ()
    ok(#P._corpus() > 100000, 'corpus size ' .. #P._corpus())
    for _, r in ipairs(P.RULES) do
        local v, witness = P.verify(r)
        ok(v, r.id .. ' differs on ' .. vim.inspect(witness))
    end
    -- the check can FAIL: the obvious-but-wrong nil-returning rewrite differs on a blank string
    local bad = { id = 'bad', old = P.RULES[1].old, new = function(s) return s:match('^%s*(.*%S)') end }
    local v, witness = P.verify(bad)
    ok(not v and witness and not witness:find('%S'), 'a nil-for-blank rewrite is refused, on ' .. vim.inspect(witness))
end)

test('patrewrite: ★ every rule\'s new expression is LINEAR — cost is part of acceptance, and the check can fail', function ()
    for _, r in ipairs(P.RULES) do
        local e = P.measure(r)
        ok(e < 1.4, ('%s measures %.2f'):format(r.id, e))
    end
    -- the obvious trim rewrite answers identically and is quadratic on all-whitespace input
    local naive = function(s) return (s:match('^%s*(.*%S)') or '') end
    local e = P.measure(P.RULES[1], naive)
    ok(e > 1.6, ('the naive rewrite must measure quadratic, got %.2f'):format(e))
end)

test('patrewrite: sites, and every decline says why', function ()
    if not has_lua() then skip 'no lua parser' end
    local src = table.concat(vim.fn.readfile(FIX), '\n')
    local found, declined = P.sites(src)
    local got = {}
    for _, s in ipairs(found) do got[#got + 1] = s.line .. ':' .. s.rule end
    eq({ '5:trim', '6:trim', '7:rtrim', '8:trim-gsub', '9:trim' }, got)
    local why = {}
    for _, d in ipairs(declined) do why[d.line] = d.reason end
    ok(why[12] and why[12]:find('two values'), 'gsub in a multi-value position: ' .. tostring(why[12]))
    ok(why[13] and why[13]:find('twice'), 'a subject containing a call is not duplicated: ' .. tostring(why[13]))
    ok(why[16] and why[16]:find('suppressed'), 'the marker declines: ' .. tostring(why[16]))
    eq(3, #declined)
    -- a METHOD site carries its premise; the string.match form does not need one
    ok(found[1].premise and found[1].premise:find('is a string'))
    eq(nil, found[2].premise)
end)

test('patrewrite: ★ END TO END — the rewritten FILE behaves like the original on the corpus', function ()
    if not has_lua() then skip 'no lua parser' end
    local dir = vim.fn.tempname(); vim.fn.mkdir(dir, 'p')
    vim.fn.writefile(vim.fn.readfile(FIX), dir .. '/trims.lua')
    local data = ts.extract(dir)
    store.ingest(data)
    local plan, why = P.plan(store, 'trims.lua')
    ok(plan, why)
    eq(5, #plan.moves)
    local before, after = txn.dryrun(store, plan)
    ok(before and after and after['trims.lua'], 'dry-run produced the rewritten file')
    local old_m = assert(loadstring(before['trims.lua']))()
    local new_m = assert(loadstring(after['trims.lua']))()
    local corpus = P._corpus()
    for _, fname in ipairs({ 'trim', 'trim_fn', 'rtrim', 'trim_gsub', 'gsub_multi', 'call_subject', 'kept', 'word' }) do
        for i = 1, #corpus, 7 do
            local s = corpus[i]
            local a1, a2 = old_m[fname](s)
            local b1, b2 = new_m[fname](s)
            if a1 ~= b1 or a2 ~= b2 then
                error(('%s differs on %q: %s vs %s'):format(fname, s, tostring(a1), tostring(b1)))
            end
        end
    end
    local t = { name = '  x y  ' }
    eq(old_m.trim_field(t), new_m.trim_field(t))
    -- and the idioms are gone from the rewritten sites (the declined ones keep theirs)
    local n_old = select(2, after['trims.lua']:gsub('%^%%s%*%(%.%-%)%%s%*%$', ''))
    eq(3, n_old, 'three declined sites keep the idiom')
end)
