-- cartograph.byexample — A REWRITE RULE LEARNED FROM ONE EXAMPLE, applied wherever it matches (the toolbelt's
-- `learn`; USER 2026-09-28: "can we create a tactic from an example?").
--
-- transplant.apply learns an edit from an exemplar too, but at FUNCTION granularity: a target must share the
-- exemplar's whole shape. MEASURED on lua/cartograph for `x == nil` -> `not x`: 111 functions contain the pattern and
-- transplant derived the edit for 1. The edit is LOCAL, so this learns a RULE for the region that changed:
--   1. read     before and after with the LOSSLESS reader (algebraread: cst_print(read(src)) == src)
--   2. cut      the region that differs (A.diff_regions): `x == nil` / `not x`
--   3. abstract the subterms the edit CARRIES OVER (in both regions, containing a name) become holes:
--               `?1 == nil` -> `not ?1`. A constant stays fixed: it is part of what the example means.
--   4. apply    every non-overlapping match of the left side, in any file, is replaced by the right side
--               instantiated with the TARGET's own subterms — printed losslessly, so everything outside the rewritten
--               span is byte-identical, and the rewritten span keeps the target's operands exactly as written.
-- ⚠ AN EXAMPLE IS A CLAIM, NOT A PROOF: `x == nil` -> `not x` itself changes behaviour when x is false. The rule
-- applies what was demonstrated and claims nothing more (`preserves = 'none'`); the caller's specs are the oracle.
-- ⚠ WHERE IT APPLIES IS A DECISION: the matches are inferred, so without a `scope` the plan refuses as a decision
-- that lists them (the wrong-symbol lesson: nothing inferred is applied behind the caller).
-- ⚠ FIRST CUT, MEASURED: matching is TRIVIA-SENSITIVE — `y==nil` does not match an example written `x == nil`.
local M = {}

local function A() return require('cartograph.algebra').load() end

local function get(t, path) for _, i in ipairs(path) do t = t.kids[i] end return t end

local function has_name(t)
    if t.k == 'identifier' then return true end
    for _, c in ipairs(t.kids or {}) do if has_name(c) then return true end end
    return false
end

local function subtrees(t, out)
    out[#out + 1] = t
    for _, c in ipairs(t.kids or {}) do subtrees(c, out) end
    return out
end

--- the values the right side's holes need (instantiate refuses a value for a hole its template does not have)
local function only_holes(T, values)
    local out = {}
    for h in pairs(T.holes or {}) do out[h] = values[h] end
    return out
end

--- Learn the rules an example demonstrates. -> { { lhs, rhs, lhs_text, rhs_text } } | nil, why, class
function M.learn(before, after, lang)
    lang = lang or 'lua' -- @langs-ok the reader roster decides; algebraread refuses an unregistered language by name
    local a = A()
    if not a then return nil, 'algebra unavailable', 'environment' end
    local R = require 'cartograph.algebraread'
    local Tb, bwhy = R.read(before, lang)
    if not Tb then return nil, 'the BEFORE text does not read: ' .. tostring(bwhy), 'ill-posed' end
    local Ta, awhy = R.read(after, lang)
    if not Ta then return nil, 'the AFTER text does not read: ' .. tostring(awhy), 'ill-posed' end
    local regions = {}
    a.diff_regions(Tb, Ta, {}, regions)
    if #regions == 0 then return nil, 'before and after are the same term: the example demonstrates no edit', 'ill-posed' end
    local rules = {}
    for _, path in ipairs(regions) do
        -- ⚠ A REGION THAT IS A BARE TOKEN IS LIFTED TO ITS NODE. `x == 0` -> `x <= 0` differs only in the operator,
        -- and a rule `== -> <=` would rewrite EVERY `==` in a file (`x == nil` included): the demonstrated edit is
        -- the comparison, so the region is the expression that holds the token
        while #path > 0 and (get(Tb, path).k == 'lit' or get(Ta, path).k == 'lit') do
            local up = {}
            for i = 1, #path - 1 do up[i] = path[i] end
            path = up
        end
        local Lb, La = get(Tb, path), get(Ta, path)
        -- the carried-over subterms: MAXIMAL subtrees of the after-region equal to one in the before-region
        local bsubs, picks = subtrees(Lb, {}), {}
        local function pick(t)
            if t.k ~= 'lit' and has_name(t) then
                for _, s in ipairs(bsubs) do
                    if a.eq(s, t) then
                        for _, p in ipairs(picks) do if a.eq(p, t) then return end end
                        picks[#picks + 1] = t
                        return
                    end
                end
            end
            for _, c in ipairs(t.kids or {}) do pick(c) end
        end
        pick(La)
        local function holed(t)
            for k, p in ipairs(picks) do if a.eq(p, t) then return a.hole('h' .. k) end end
            if t.k == 'lit' or not t.kids then return t end
            local kids = {}
            for i, c in ipairs(t.kids) do kids[i] = holed(c) end
            return a.rebuild(t, kids)
        end
        local lhs, rhs = a.template(holed(Lb)), a.template(holed(La))
        -- ★ A RULE THAT MATCHES ITS OWN OUTPUT NEVER RUNS OUT OF WORK (and could not be re-run as `empty`)
        if a.match(lhs, La).ok then
            return nil, ('the learned rule `%s -> %s` matches its own output — applying it again would rewrite forever')
                :format(a.cst_print(Lb), a.cst_print(La)), 'ill-posed'
        end
        rules[#rules + 1] = { lhs = lhs, rhs = rhs, lhs_text = a.cst_print(Lb), rhs_text = a.cst_print(La), holes = #picks }
    end
    return rules
end

--- Apply rules to a source text. -> new text, sites (the number of rewrites) | nil, why
function M.rewrite(rules, src, lang)
    local a = A()
    local t, why = require('cartograph.algebraread').read(src, lang or 'lua') -- @langs-ok as learn
    if not t then return nil, why, 'frontier' end
    local sites = 0
    for _, rule in ipairs(rules) do
        local hits, covered = {}, {}
        local function inside(path)
            for _, c in ipairs(covered) do
                if #c <= #path then
                    local pre = true
                    for i = 1, #c do if c[i] ~= path[i] then pre = false; break end end
                    if pre then return true end
                end
            end
            return false
        end
        for _, pos in ipairs(a.positions(t)) do
            if not inside(pos.path) then
                local m = a.match(rule.lhs, pos.node)
                if m.ok then hits[#hits + 1] = { path = pos.path, values = m.values }; covered[#covered + 1] = pos.path end
            end
        end
        -- disjoint subtrees: replacing one never moves another's path
        for k = #hits, 1, -1 do
            local inst = a.instantiate(rule.rhs, only_holes(rule.rhs, hits[k].values))
            if inst.ok then t = a.put(t, hits[k].path, inst.term); sites = sites + 1 end
        end
    end
    return a.cst_print(t), sites
end

local function files_in(store, scope)
    local out = {}
    if scope == 'all' then
        for _, f in ipairs(store.files or {}) do if f:match('%.lua$') then out[#out + 1] = f end end
    else
        for f in tostring(scope):gmatch('[^,]+') do out[#out + 1] = (f:gsub('^%s+', ''):gsub('%s+$', '')) end
    end
    table.sort(out)
    return out
end

--- A txn plan applying the example's rules: { before, after, scope = 'all' | 'a.lua,b.lua' }.
--- Without a scope it refuses as a DECISION that says where the rule matches.
function M.plan(store, opts)
    opts = opts or {}
    local txn = require 'cartograph.txn'
    local rules, why, class = M.learn(opts.before or '', opts.after or '', opts.lang)
    if not rules then return nil, why, class or 'ill-posed' end
    local root = store.data.root
    local scan = files_in(store, opts.scope or 'all')
    local edits, touched, stamps, per, total, unread = {}, {}, {}, {}, 0, {}
    for _, rel in ipairs(scan) do
        local text = txn.read_file(root, rel)
        if text then
            local new, n = M.rewrite(rules, text, opts.lang)
            -- a file the lossless reader cannot read was NOT looked at: say so, never count it as "no match"
            if not new then unread[#unread + 1] = rel end
            if new and n > 0 then
                edits[rel] = new; touched[#touched + 1] = rel
                stamps[rel] = txn.disk_stamp(root, rel)
                per[#per + 1] = ('%s (%d)'):format(rel, n)
                total = total + n
            end
        end
    end
    local rule_text = {}
    for _, r in ipairs(rules) do rule_text[#rule_text + 1] = ('`%s` -> `%s`'):format(r.lhs_text, r.rhs_text) end
    if total == 0 then
        return nil, ('the rule %s matches nothing in %d file(s)'):format(table.concat(rule_text, ', '), #scan), 'empty'
    end
    if not opts.scope then
        return nil, ('the rule %s matches %d site(s) in %d file(s): %s — where it applies is YOUR decision: scope = \'all\', or a comma list of files')
            :format(table.concat(rule_text, ', '), total, #touched, table.concat(per, ', ', 1, math.min(#per, 8))
                .. (#per > 8 and (', and %d more file(s)'):format(#per - 8) or '')), 'decision'
    end
    local plan = {
        verb = 'rewrite-by-example',
        guards = { 'parses' },
        generation = store.generation,
        touched = touched, stamps = stamps, refspecs = {},
        edits = edits, rules = rule_text, sites = total,
        -- an example is a claim, not a proof: the rule applies what was demonstrated
        preserves = 'none',
        preserves_why = 'the rewrite applies what ONE example demonstrated; nothing checks that it preserves behaviour',
        hazards = #unread > 0 and { require('cartograph.hazard').new('unread', ('%d file(s) in scope were not read by the lossless reader, so they were not looked at: %s')
            :format(#unread, table.concat(unread, ', ', 1, math.min(#unread, 6))), nil, { files = unread }, 'frontier') } or {},
        desc = ('rewrite by example: %s, %d site(s) in %d file(s)'):format(table.concat(rule_text, ', '), total, #touched),
    }
    return txn.protocol(plan, function (p) return function (rel, before) return p.edits[rel] or before end end)
end

return M
