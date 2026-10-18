-- CONTRAST-FAMILIES (discovery): learn from POSITIVE and NEGATIVE examples. The positives are partitioned into families
-- by description length (A.partition), and a merge whose template would cover a negative is VETOED (the partition's
-- `admissible`, asked lazily: Golem's test on an rlgg). USER 2026-10-18: "Could we add negative examples support to
-- learn by example or could a tactic solve it?" — the generalizer gives the MOST SPECIFIC template of its members, so a
-- negative that matches it is covered by every template of those members: the only levers are SPLITTING the family
-- (this veto) and NARROWING the holes (`closed`: the summary policy 'enumerate', each hole closed to the values its
-- members bound, up to `cap`). A negative covered by a SINGLETON's template (the positive itself) is the features'
-- limit — a different label on the same record — reported as `inseparable`, not a failure of the learner.
-- Input: `examples` = JSON { pos = [records], neg = [records] } (`@file` reads one; keys starting with `_` are labels,
-- not features: `_where` names the site in the report), or `pos` / `neg` as lists of algebra terms. Records are read
-- through the kv view (A.lua_kv) and encoded as ONE family, so positives and negatives share their shape.
-- ★ A FAILED NEGATIVE IS A DIAGNOSTIC (USER 2026-10-18: "a failed negative could produce enough for diagnostics. Like
-- when you give it directly opposite examples" — Winston's NEAR MISS). Each veto says WHICH negative stopped the merge and
-- reads it hole by hole against the members' values: NARROWABLE when some feature's value is new to the family (closing
-- that hole would exclude it: `closed=1`, or that feature is the rule's condition), CORRELATED when every value was seen
-- among the members but not together (only a split separates: a conjunction). An INSEPARABLE positive names the
-- negatives equal to it on every feature: opposite labels on one record, so the fix is a NEW FEATURE, not the learner.
-- The CLAIM, the algebra's own law plus the veto: every family's template matches each of its members, and no family
-- of two or more members covers a negative. The value also carries the UNCONSTRAINED partition beside it (`plain`) —
-- what the negatives changed.
local function A() return require('cartograph.algebra').load() end

local function strip(x)
    if type(x) ~= 'table' then return x end
    local o = {}
    for k, v in pairs(x) do if not (type(k) == 'string' and k:sub(1, 1) == '_') then o[k] = strip(v) end end
    return o
end

local function inputs(p)
    local a = A()
    if p.examples then
        local d = vim.json.decode(p.examples)
        local all, labels = {}, { pos = {}, neg = {}, intent = {} }
        for _, side in ipairs { 'pos', 'neg' } do
            for i, r in ipairs(d[side] or {}) do all[#all + 1] = a.lua_kv(strip(r)); labels[side][i] = r._where or r._class end
        end
        for i, r in ipairs(d.pos or {}) do labels.intent[i] = r._intent end
        local terms = a.kv_terms(all)
        local P, N = {}, {}
        for i = 1, #(d.pos or {}) do P[i] = terms[i] end
        for i = 1, #(d.neg or {}) do N[i] = terms[#P + i] end
        return P, N, labels
    end
    return p.pos or {}, p.neg or {}, { pos = {}, neg = {}, intent = {} }
end

-- (the feature a hole stands for: the keys of the kv pairs above it, `a.b`; `[i]` for a list position)
local function hole_features(body)
    local out = {}
    local function walk(t, path)
        if type(t) ~= 'table' then return end
        if t.k == 'hole' then out[t.h] = #path > 0 and table.concat(path, '.') or '(root)'; return end
        -- (a PRESENCE mark on a pair, `?h1:pair "a" …` (the node's `opt`): the hole is whether those keys are there — one
        -- hole may mark several)
        if t.opt and t.k == 'pair' and t.kids and t.kids[1] and t.kids[1].k == 'lit' then
            local key = table.concat(path, '.') .. (#path > 0 and '.' or '') .. tostring(t.kids[1].v)
            out[t.opt] = out[t.opt] and out[t.opt]:gsub('%)$', ',' .. key .. ')') or ('present(' .. key .. ')')
        end
        if t.k == 'pair' and t.kids and t.kids[1] and t.kids[1].k == 'lit' then
            path[#path + 1] = tostring(t.kids[1].v); walk(t.kids[2], path); path[#path] = nil; return
        end
        for i, c in ipairs(t.kids or {}) do
            if t.k == 'arr' then path[#path + 1] = '[' .. i .. ']' end
            walk(c, path)
            if t.k == 'arr' then path[#path] = nil end
        end
    end
    walk(body, {})
    return out
end

-- ★ WHEN THE RESULT IS NOT WHAT THE AUTHOR MEANT (USER 2026-10-18: "Can it explain if the result is not what author
-- wanted?"). A positive may carry `_intent`, the author's group. Every deviation is explained:
-- * SPLIT: one intent across several families. The final partition left each such pair unmerged for exactly one of
--   three reasons, and the report says which: a negative VETOED the merged template (the veto diagnostic); the two
--   share no fixed structure (`min_fixed`); or merging does not pay (description length: the merged template's
--   holes cost more than the two templates save — the features where they differ are listed, and agreeing on them
--   is what would merge them).
-- * MERGE: several intents in one family. The features whose values SEPARATE the intents inside it are listed: there,
--   a negative or `closed=1` can split them; when no feature separates them, the intents differ in nothing recorded.
local function nfixed(t)
    if type(t) ~= 'table' or t.k == 'hole' then return 0 end
    local n = 1
    for _, c in ipairs(t.kids or {}) do n = n + nfixed(c) end
    return n
end
local function explain(a, part, P, N, labels, gen, diagnose)
    local fam_of, any = {}, false
    for k, f in ipairs(part.families) do for _, m in ipairs(f.members) do fam_of[m] = k; if labels.intent[m] ~= nil then any = true end end end
    if not any then return nil end
    local out = { splits = {}, merges = {} }
    -- SPLIT: for each intent, each pair of families holding it
    local fams_of = {}
    for m, k in pairs(fam_of) do
        local g = labels.intent[m]
        if g ~= nil then fams_of[g] = fams_of[g] or {}; fams_of[g][k] = true end
    end
    for g, ks in pairs(fams_of) do
        local l = {}
        for k in pairs(ks) do l[#l + 1] = k end
        table.sort(l)
        for x = 1, #l do for y = x + 1, #l do
            local fa, fb = part.families[l[x]], part.families[l[y]]
            local members = {}
            for _, m in ipairs(fa.members) do members[#members + 1] = m end
            for _, m in ipairs(fb.members) do members[#members + 1] = m end
            table.sort(members)
            local Is = {}
            for _, m in ipairs(members) do Is[#Is + 1] = P[m] end
            local gg = a.generalize(Is, gen)
            local Vs = {}
            for i, m in ipairs(members) do Vs[m] = gg.values[i] end
            local dl = a.family_dl(gg.template, Vs, {})
            local merged = { members = members, template = gg.template, env = gg.env }
            local e = { intent = g, families = { l[x], l[y] }, template = a.show(gg.template.body), gain = fa.dl + fb.dl - dl }
            for j, n in ipairs(N) do
                local mm = a.match(gg.template, n, { lazy_refusal = true, defs = gg.env and gg.env.defs })
                if mm.ok then e.why, e.veto = 'vetoed', diagnose(merged, j, mm); break end
            end
            if not e.why and nfixed(gg.template.body) < 1 then e.why = 'nothing shared' end
            if not e.why then
                e.why = e.gain <= 0 and 'does not pay' or 'greedy'
                -- (the features where the two families differ: the merged template's holes)
                local feats, diff = hole_features(gg.template.body), {}
                for h in pairs(feats) do
                    local va, vb = {}, {}
                    for i, m in ipairs(members) do
                        local val = gg.values[i] and gg.values[i][h]
                        if val ~= nil then local sv = a.show(val); if fam_of[m] == l[x] then va[sv] = true else vb[sv] = true end end
                    end
                    local la, lb = {}, {}
                    for k2 in pairs(va) do la[#la + 1] = k2 end
                    for k2 in pairs(vb) do lb[#lb + 1] = k2 end
                    table.sort(la); table.sort(lb)
                    -- (DISJOINT: no value on both sides — a feature that tells the two families apart, listed first)
                    local disjoint = true
                    for k2 in pairs(va) do if vb[k2] then disjoint = false end end
                    diff[#diff + 1] = { feature = feats[h], a = la, b = lb, disjoint = disjoint }
                end
                table.sort(diff, function (p, q)
                    if p.disjoint ~= q.disjoint then return p.disjoint end
                    return p.feature < q.feature
                end)
                e.differ = diff
            end
            out.splits[#out.splits + 1] = e
        end end
    end
    -- MERGE: several intents in one family
    for k, f in ipairs(part.families) do
        local by, nint = {}, 0
        for _, m in ipairs(f.members) do
            local g = labels.intent[m]
            if g ~= nil then if not by[g] then by[g] = {}; nint = nint + 1 end; table.insert(by[g], m) end
        end
        if nint > 1 then
            local feats, sep = hole_features(f.template.body), {}
            local vals = {}
            for _, m in ipairs(f.members) do
                local r = a.match(f.template, P[m], { defs = f.env and f.env.defs })
                if r.ok then for h, val in pairs(r.values or {}) do vals[h] = vals[h] or {}; vals[h][m] = a.show(val) end end
            end
            for h, col in pairs(vals) do
                -- (separating: no value appears under two intents)
                local owner, ok_, per = {}, true, {}
                for m, sv in pairs(col) do
                    local g = labels.intent[m]
                    if g ~= nil then
                        if owner[sv] ~= nil and owner[sv] ~= g then ok_ = false end
                        owner[sv] = g
                        per[g] = per[g] or {}; per[g][sv] = true
                    end
                end
                if ok_ then
                    local pl = {}
                    for g, set in pairs(per) do local l = {}; for sv in pairs(set) do l[#l + 1] = sv end; table.sort(l); pl[tostring(g)] = l end
                    sep[#sep + 1] = { feature = feats[h] or h, by_intent = pl }
                end
            end
            table.sort(sep, function (p, q) return p.feature < q.feature end)
            local counts = {}
            for g, l in pairs(by) do counts[tostring(g)] = #l end
            out.merges[#out.merges + 1] = { family = k, intents = counts, template = a.show(f.template.body), separating = sep,
                why = #sep > 0 and 'no negative separates them; these features do' or 'no recorded feature separates them' }
        end
    end
    out.agrees = #out.splits == 0 and #out.merges == 0
    return out
end

local E = {
    name = 'contrast-families',
    kind = 'discovery',
    tags = { 'find', 'algebra' },
    measures = 'CART-1697',
    summary = 'learn templates from positive AND negative examples: partition the positives by MDL, vetoing any merged family whose template covers a negative; closed=1 closes each hole to the values its members bound (cap, default 8)',
    params = { examples = 'string?', pos = 'list?', neg = 'list?', closed = 'string?', cap = 'string?' },
    measure = function (_, p)
        local a = A()
        local P, N, labels = inputs(p)
        if #P == 0 then return nil, 'no positive examples' end
        local gen = (p.closed == '1' or p.closed == 'true') and { summary = 'enumerate', cap = tonumber(p.cap) or 8 } or nil
        local function covered(f)
            local out = {}
            for j, n in ipairs(N) do if a.match(f.template, n, { lazy_refusal = true, defs = f.env and f.env.defs }).ok then out[#out + 1] = j end end
            return out
        end
        local asked, vetoes, seen = 0, {}, {}
        local function diagnose(f, j, m)
            -- hole by hole: the negative's value against the values the members bound there
            local feats, holes, new = hole_features(f.template.body), {}, false
            for h, nv in pairs(m.values or {}) do
                local mine, has = {}, false
                for _, i in ipairs(f.members) do
                    local r = a.match(f.template, P[i], { defs = f.env and f.env.defs })
                    local v = r.ok and r.values and r.values[h]
                    if v then local sv = a.show(v); if not mine[sv] then mine[sv] = true; mine[#mine + 1] = sv end; if a.eq(v, nv) then has = true end end
                end
                table.sort(mine)
                holes[#holes + 1] = { feature = feats[h] or h, negative = a.show(nv), members = mine, new = not has }
                new = new or not has
            end
            table.sort(holes, function (x, y) return x.feature < y.feature end)
            return { members = f.members, negative = j, neg_where = labels.neg[j], class = new and 'narrowable' or 'correlated', holes = holes }
        end
        -- (the greedy loop rebuilds every candidate family each step: a verdict is kept per member set, so a vetoed
        -- pair is matched against the negatives once)
        local part = a.partition(P, { generalize = gen, admissible = function (f)
            local key = table.concat(f.members, ',')
            if seen[key] ~= nil then return seen[key] end
            asked = asked + 1
            for j, n in ipairs(N) do
                local m = a.match(f.template, n, { lazy_refusal = true, defs = f.env and f.env.defs })
                if m.ok then seen[key] = false; vetoes[#vetoes + 1] = diagnose(f, j, m); return false end
            end
            seen[key] = true
            return true
        end })
        local plain = a.partition(P, { generalize = gen })
        local function report(pt)
            local fams, negs = {}, 0
            for _, f in ipairs(pt.families) do
                local cov = covered(f)
                local rebuilt = true
                for _, m in ipairs(f.members) do if not a.match(f.template, P[m], { defs = f.env and f.env.defs }).ok then rebuilt = false end end
                local where = {}
                for _, m in ipairs(f.members) do if labels.pos[m] and #where < 3 then where[#where + 1] = labels.pos[m] end end
                local nwhere = {}
                for _, j in ipairs(cov) do if labels.neg[j] and #nwhere < 3 then nwhere[#nwhere + 1] = labels.neg[j] end end
                fams[#fams + 1] = { members = f.members, template = a.show(f.template.body), covers = #cov, rebuilt = rebuilt,
                    where = where, neg_where = nwhere }
                negs = negs + #cov
            end
            return { families = fams, covered = negs, dl = pt.dl }
        end
        local v = report(part)
        v.plain = report(plain)
        v.asked, v.positives, v.negatives = asked, #P, #N
        v.vetoes = vetoes
        v.narrowable, v.correlated = 0, 0
        for _, x in ipairs(vetoes) do v[x.class] = v[x.class] + 1 end
        v.inseparable, v.opposite = {}, {}
        for k, f in ipairs(v.families) do
            if #f.members == 1 and f.covers > 0 then
                local i = f.members[1]
                v.inseparable[#v.inseparable + 1] = i
                local negs = {}
                for _, j in ipairs(covered(part.families[k])) do negs[#negs + 1] = labels.neg[j] or j end
                v.opposite[#v.opposite + 1] = { positive = labels.pos[i] or i, negatives = negs, record = f.template,
                    why = 'equal on every feature: no feature tells them apart — add one' }
            end
        end
        v.intent = explain(a, part, P, N, labels, gen, diagnose)
        return v
    end,
    claim = function (v)
        for _, f in ipairs(v.families) do
            if not f.rebuilt then return false, 'a family template does not match its own members: ' .. f.template end
            if #f.members > 1 and f.covers > 0 then return false, ('a %d-member family covers %d negative(s): %s'):format(#f.members, f.covers, f.template) end
        end
        local it = v.intent and ('; intent: %d split(s), %d merge(s)'):format(#v.intent.splits, #v.intent.merges) or ''
        return true, ('%d positives -> %d families (unconstrained %d) covering %d of %d negatives (unconstrained %d); %d inseparable positive(s); %d veto(es): %d narrowable, %d correlated')
            :format(v.positives, #v.families, #v.plain.families, v.covered, v.negatives, v.plain.covered, #v.inseparable,
                #v.vetoes, v.narrowable, v.correlated) .. it
    end,
}

-- a record per site: an op and two features
local function rec(op, base, key, where) return { op = op, base = base, key = key, _where = where } end
local function json(pos, neg) return vim.json.encode({ pos = pos, neg = neg }) end

E.examples = {
    {
        name = 'a negative SPLITS the family the positives alone would form: storeDyn with a tainted key, with or without a metatable, but not a load',
        files = {},
        params = { examples = json(
            { rec('storeDyn', 'meta', 'top', 'p1'), rec('storeDyn', 'plain', 'top', 'p2'), rec('loadDyn', 'meta', 'top', 'p3') },
            { rec('loadDyn', 'plain', 'top', 'n1') }) },
        expect = { holds = true, check = function (v)
            -- unconstrained, one family {?op, ?base, top} covers n1; vetoed, the storeDyn pair stays and the load is alone
            if #v.plain.families ~= 1 or v.plain.covered ~= 1 then return false, 'the unconstrained partition should be one family covering n1: ' .. vim.inspect(v.plain) end
            if #v.families ~= 2 or v.covered ~= 0 then return false, 'vetoed: two families, no negative covered: ' .. vim.inspect(v.families) end
            -- the diagnostic: n1's op and base were each SEEN among the three, never together — a split, not a narrowing
            local x = v.vetoes[1]
            if not (x and x.neg_where == 'n1' and x.class == 'correlated') then return false, 'the veto should name n1 as correlated: ' .. vim.inspect(v.vetoes) end
            return true
        end },
    },
    {
        name = 'a negative equal to a positive is INSEPARABLE — reported, not a failure',
        files = {},
        params = { examples = json({ rec('call', 'meta', 'top', 'p1'), rec('call', 'plain', 'none', 'p2') }, { rec('call', 'meta', 'top', 'n1') }) },
        expect = { holds = true, check = function (v)
            local o = v.opposite[1]
            return #v.inseparable == 1 and v.inseparable[1] == 1 and o and o.positive == 'p1' and o.negatives[1] == 'n1', vim.inspect(v.opposite)
        end },
    },
    {
        name = 'closed=1 narrows the holes instead of splitting: the pair stays ONE family with ?base in {meta, plain}, and a third base is not covered',
        files = {},
        params = { closed = '1', examples = json(
            { rec('storeDyn', 'meta', 'top', 'p1'), rec('storeDyn', 'plain', 'top', 'p2') },
            { rec('storeDyn', 'string', 'top', 'n1') }) },
        expect = { holds = true, check = function (v)
            return #v.families == 1 and v.covered == 0, vim.inspect(v.families)
        end },
    },
    {
        name = 'a NEAR MISS is narrowable: the veto names the one feature whose value is new to the family (base = string)',
        files = {},
        params = { examples = json(
            { rec('storeDyn', 'meta', 'top', 'p1'), rec('storeDyn', 'plain', 'top', 'p2') },
            { rec('storeDyn', 'string', 'top', 'n1') }) },
        expect = { holds = true, check = function (v)
            local x = v.vetoes[1]
            if not (x and x.class == 'narrowable') then return false, vim.inspect(v.vetoes) end
            local new = {}
            for _, h in ipairs(x.holes) do if h.new then new[#new + 1] = h.feature .. '=' .. h.negative end end
            return #v.families == 2 and #new == 1 and new[1] == 'base="string"', table.concat(new, ' ')
        end },
    },
    {
        name = 'a REPETITION hole: the veto matches a negative through the family env (`@h1.elem`), not only the members',
        files = {},
        params = { examples = vim.json.encode({
            pos = { { op = 'store', kinds = { 'empty' } }, { op = 'store', kinds = { 'fn', 'str' } },
                { op = 'store', kinds = { 'fn', 'num', 'str' } }, { op = 'store', kinds = { 'ext', 'fn', 'num', 'str' } } },
            neg = { { op = 'store', kinds = { 'fn', 'num' }, _where = 'n1' } } }) },
        expect = { holds = true, check = function (v)
            return v.plain.covered == 1 and v.covered == 0 and #v.vetoes > 0, ('plain covers %d, vetoed covers %d, %d vetoes'):format(v.plain.covered, v.covered, #v.vetoes)
        end },
    },
    {
        name = 'INTENT, split by a veto: the author grouped all three; the report names the negative that split them',
        files = {},
        params = { examples = json(
            { { op = 'storeDyn', base = 'meta', key = 'top', _intent = 'X' }, { op = 'storeDyn', base = 'plain', key = 'top', _intent = 'X' },
              { op = 'loadDyn', base = 'meta', key = 'top', _intent = 'X' } },
            { rec('loadDyn', 'plain', 'top', 'n1') }) },
        expect = { holds = true, check = function (v)
            local x = v.intent and v.intent.splits[1]
            return x and x.why == 'vetoed' and x.veto.neg_where == 'n1' and #v.intent.merges == 0, vim.inspect(v.intent)
        end },
    },
    {
        name = 'INTENT, split because merging does not pay: the two share no key, and the report lists what differs',
        files = {},
        params = { examples = json({ { a = 'x1', b = 'y1', c = 'z1', _intent = 'X' }, { d = 'x2', e = 'y2', f = 'z2', _intent = 'X' } }, {}) },
        expect = { holds = true, check = function (v)
            local x = v.intent and v.intent.splits[1]
            local feats = {}
            for _, d in ipairs(x and x.differ or {}) do feats[#feats + 1] = d.feature end
            return x and x.why == 'does not pay' and x.gain <= 0 and table.concat(feats, ' ') == 'present(a,b,c) present(d,e,f)'
                and x.differ[1].disjoint, vim.inspect(x)
        end },
    },
    {
        name = 'INTENT, merged: two intents in one family; `base` separates them, so a negative or closed=1 would split them',
        files = {},
        params = { examples = json({ { op = 'store', base = 'meta', _intent = 'A' }, { op = 'store', base = 'plain', _intent = 'B' } }, {}) },
        expect = { holds = true, check = function (v)
            local x = v.intent and v.intent.merges[1]
            return x and #x.separating == 1 and x.separating[1].feature == 'base' and x.separating[1].by_intent.A[1] == '"meta"', vim.inspect(x)
        end },
    },
    {
        name = 'INTENT, merged with NOTHING to separate them: the intents differ in no recorded feature',
        files = {},
        params = { examples = json({ { op = 'store', base = 'meta', _intent = 'A' }, { op = 'store', base = 'meta', _intent = 'B' },
            { op = 'store', base = 'plain', _intent = 'A' } }, {}) },
        expect = { holds = true, check = function (v)
            local x = v.intent and v.intent.merges[1]
            return x and #x.separating == 0 and x.why == 'no recorded feature separates them', vim.inspect(x)
        end },
    },
    {
        name = 'without negatives the result is the plain partition',
        files = {},
        params = { examples = json({ rec('storeDyn', 'meta', 'top'), rec('storeDyn', 'plain', 'top'), rec('loadDyn', 'meta', 'top') }, {}) },
        expect = { holds = true, check = function (v)
            return #v.families == #v.plain.families and v.asked > 0, ('%d vs %d, asked %d'):format(#v.families, #v.plain.families, v.asked)
        end },
    },
}

return E
