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
        local all, labels = {}, { pos = {}, neg = {} }
        for _, side in ipairs { 'pos', 'neg' } do
            for i, r in ipairs(d[side] or {}) do all[#all + 1] = a.lua_kv(strip(r)); labels[side][i] = r._where or r._class end
        end
        local terms = a.kv_terms(all)
        local P, N = {}, {}
        for i = 1, #(d.pos or {}) do P[i] = terms[i] end
        for i = 1, #(d.neg or {}) do N[i] = terms[#P + i] end
        return P, N, labels
    end
    return p.pos or {}, p.neg or {}, { pos = {}, neg = {} }
end

-- (the feature a hole stands for: the keys of the kv pairs above it, `a.b`; `[i]` for a list position)
local function hole_features(body)
    local out = {}
    local function walk(t, path)
        if type(t) ~= 'table' then return end
        if t.k == 'hole' then out[t.h] = #path > 0 and table.concat(path, '.') or '(root)'; return end
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
        return v
    end,
    claim = function (v)
        for _, f in ipairs(v.families) do
            if not f.rebuilt then return false, 'a family template does not match its own members: ' .. f.template end
            if #f.members > 1 and f.covers > 0 then return false, ('a %d-member family covers %d negative(s): %s'):format(#f.members, f.covers, f.template) end
        end
        return true, ('%d positives -> %d families (unconstrained %d) covering %d of %d negatives (unconstrained %d); %d inseparable positive(s); %d veto(es): %d narrowable, %d correlated')
            :format(v.positives, #v.families, #v.plain.families, v.covered, v.negatives, v.plain.covered, #v.inseparable,
                #v.vetoes, v.narrowable, v.correlated)
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
        name = 'without negatives the result is the plain partition',
        files = {},
        params = { examples = json({ rec('storeDyn', 'meta', 'top'), rec('storeDyn', 'plain', 'top'), rec('loadDyn', 'meta', 'top') }, {}) },
        expect = { holds = true, check = function (v)
            return #v.families == #v.plain.families and v.asked > 0, ('%d vs %d, asked %d'):format(#v.families, #v.plain.families, v.asked)
        end },
    },
}

return E
