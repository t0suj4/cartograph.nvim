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
    -- ★ DEPENDENT REGIONS ARE ONE EDIT (CART-1435). A region's rule carries over only ITS OWN subterms, so a move that
    -- takes a subterm OUT of one region and INTO another — `x:SetFont(D:GetContentFont("normal"))` ->
    -- `D:SetContentFont(x, "normal")`, the receiver moving into the arguments — was learned as independent token rules,
    -- one of them `iconText -> TSMAPI.Design` (83 sites in TSM). When one region's AFTER side carries a named subterm of
    -- another's BEFORE side, the two are merged at their lowest common ancestor (and every region under it dropped),
    -- to a fixpoint: the rule is then the whole demonstrated edit, its moved subterm a hole on both sides.
    -- (lifted FIRST: a bare-token region is its node — the per-region loop below says why — and a dependence between
    -- regions is between nodes: `f(a, b)` -> `g(b, a)` reports the literals `a` and `b`, the identifiers carry them)
    for k, path in ipairs(regions) do
        while #path > 0 and (get(Tb, path).k == 'lit' or get(Ta, path).k == 'lit') do
            local up = {}
            for i = 1, #path - 1 do up[i] = path[i] end
            path = up
        end
        regions[k] = path
    end
    local function carries(pi, pj)
        local bsubs, found = subtrees(get(Tb, pi), {}), false
        local function look(t)
            if found then return end
            if t.k ~= 'lit' and has_name(t) then
                for _, s in ipairs(bsubs) do if a.eq(s, t) then found = true; return end end
            end
            for _, c in ipairs(t.kids or {}) do look(c) end
        end
        look(get(Ta, pj))
        return found
    end
    local function under(p, q) -- is q at or below p?
        if #q < #p then return false end
        for i = 1, #p do if p[i] ~= q[i] then return false end end
        return true
    end
    local merged = true
    while merged and #regions > 1 do
        merged = false
        for i = 1, #regions do
            for j = 1, #regions do
                if not merged and i ~= j and carries(regions[i], regions[j]) then
                    local l = {}
                    for k = 1, math.min(#regions[i], #regions[j]) do
                        if regions[i][k] ~= regions[j][k] then break end
                        l[k] = regions[i][k]
                    end
                    local keep = { l }
                    for _, r in ipairs(regions) do if not under(l, r) then keep[#keep + 1] = r end end
                    regions, merged = keep, true
                end
            end
        end
    end
    -- a region's RULE SIDES: its before and after subterms with the carried-over subterms made holes -> lhs term, rhs
    -- term, Lb, La, the number of holes
    local function sides(path)
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
        -- ★ EVERY HOLE THE RIGHT SIDE USES MUST BE BOUND BY THE LEFT (CART-1173). MEASURED: inserting `a = a + 1`
        -- between `local a = 1` and `return a` picked the two statements AND the identifier `a`; the left side's
        -- statement holes swallowed every `a`, so the right side's `a` hole was bound by nothing, instantiation failed
        -- at every site, and the rule "matched nothing" on an identical body. So a larger pick that CONTAINS a pick the
        -- right side still needs unbound is dropped, until every right-side hole is bound: the rule becomes
        -- `local ?1 = 1; return ?1` -> `local ?1 = 1; ?1 = ?1 + 1; return ?1`.
        local function holes_of(t, out)
            out = out or {}
            if t.k == 'hole' and t.h then out[t.h] = true end -- algebra/core: { k = 'hole', h = <name> }
            for _, c in ipairs(t.kids or {}) do holes_of(c, out) end
            return out
        end
        local function contains(big, small)
            if a.eq(big, small) then return true end
            for _, c in ipairs(big.kids or {}) do if contains(c, small) then return true end end
            return false
        end
        for _ = 1, #picks do
            local hb, ha = holes_of(holed(Lb)), holes_of(holed(La))
            local unbound = {}
            for k, p in ipairs(picks) do if ha['h' .. k] and not hb['h' .. k] then unbound[#unbound + 1] = p end end
            if #unbound == 0 then break end
            local keep = {}
            for _, p in ipairs(picks) do
                local swallows = false
                for _, u in ipairs(unbound) do if p ~= u and contains(p, u) then swallows = true; break end end
                if not swallows then keep[#keep + 1] = p end
            end
            if #keep == #picks then break end
            picks = keep
        end
        return holed(Lb), holed(La), Lb, La, #picks
    end
    -- ★ A REGION WITH NO CONSTANT IS NO EVIDENCE (CART-1452). When its rule's LEFT side holds nothing but holes and
    -- node kinds, it matches any node of that kind: `for c in n:iter_children()` -> `for _, c in tsutil.inext, n, -1`
    -- made the binder list a region of its own, `c -> _, c` (`?1 -> _, ?1`), which rewrote EVERY one-name list in a
    -- file (547 corrupt declarations in flow.lua) while its demonstration passed. Such a region is lifted to its parent
    -- until its left side holds a constant (a token: here the clause's `in`), and a region it then contains is part of it
    local function constant(t)
        if t.k == 'lit' then return tostring(t.v):match('%S') ~= nil end
        for _, c in ipairs(t.kids or {}) do if constant(c) then return true end end
        return false
    end
    for _ = 1, 10000 do
        local lifted = false
        for k, path in ipairs(regions) do
            if #path > 0 and not constant((sides(path))) then
                local up = {}
                for i = 1, #path - 1 do up[i] = path[i] end
                local keep = { up }
                for j, r in ipairs(regions) do if j ~= k and not under(up, r) then keep[#keep + 1] = r end end
                regions, lifted = keep, true
                break
            end
        end
        if not lifted then break end
    end
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
        local hl, hr, Lb, La, nholes = sides(path)
        local lhs, rhs = a.template(hl), a.template(hr)
        -- ★ A RULE THAT MATCHES ITS OWN OUTPUT NEVER RUNS OUT OF WORK (and could not be re-run as `empty`)
        if a.match(lhs, La).ok then
            return nil, ('the learned rule `%s -> %s` matches its own output — applying it again would rewrite forever')
                :format(a.cst_print(Lb), a.cst_print(La)), 'ill-posed'
        end
        rules[#rules + 1] = { lhs = lhs, rhs = rhs, lhs_text = a.cst_print(Lb), rhs_text = a.cst_print(La), holes = nholes }
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
        -- (the rule's template is STATIC across every position: match COMPILED to it, accepted by its sample law
        -- first — cartograph.compiledverb, CART-1339; refused or disabled, the interpreted A.match)
        -- (only `ok` and a hit's `values` are read here: refusals without details, -31% matching — CART-1465)
        local compiled = require('cartograph.compiledverb').match(rule.lhs, { refusal = 'none' })
        -- (and only at the positions that CAN be a match root: an anchor token's ancestor at its fixed depth —
        -- cartograph.prefilter, sound; no anchor, or CARTOGRAPH_PREFILTER=0, every position)
        local poss = os.getenv('CARTOGRAPH_PREFILTER') ~= '0' and require('cartograph.prefilter').candidates(t, rule.lhs, src) or a.positions(t)
        for _, pos in ipairs(poss) do
            if not inside(pos.path) then
                local m = compiled and compiled(pos.node) or a.match(rule.lhs, pos.node)
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

local function files_in(store, scope, lang)
    local out = {}
    if scope == 'all' then
        -- the files OF THE RULE'S LANGUAGE, by the graph's own path -> parser rule (not an extension typed here)
        local ts = require 'cartograph.providers.treesitter'
        lang = lang or 'lua' -- @langs-ok the reader's audited roster decides (the declaration in algebraread's header)
        for _, f in ipairs(store.files or {}) do if ts.parse_lang(f) == lang then out[#out + 1] = f end end
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
    -- ★ WITHIN ONE FUNCTION (CART-1176, edit-in): `within` = a durable ref (or a node id). The rule rewrites only that
    -- node's own source slice — read as a chunk, or as `return <expr>` when it is an expression (a function value in a
    -- table) — and the slice is spliced back; nothing outside the function can match. Terms carry no spans, so the
    -- scope is the TEXT the graph's range names, not a position filter.
    if opts.within ~= nil then
        local id = type(opts.within) == 'table' and store.resolve_ref(opts.within) or opts.within
        local n = id and store.node(id)
        if not n then return nil, ('the function to edit within does not resolve (%s)'):format(vim.inspect(opts.within)), 'stale' end
        local atr = require 'cartograph.at'
        local text = txn.read_file(root, n.file)
        if not text then return nil, ('cannot read %s'):format(n.file), 'stale' end
        local lines = vim.split(text, '\n', { plain = true })
        local sl, sc, el, ec = atr.sl(n.range), atr.sc(n.range), atr.el(n.range), atr.ec(n.range)
        local function offset(l, c) local o = 0; for i = 1, l do o = o + #lines[i] + 1 end; return o + c end
        local s0, e0 = offset(sl, sc), offset(el, ec)
        local slice = text:sub(s0 + 1, e0)
        local new, n_sites = M.rewrite(rules, slice, opts.lang)
        local wrapped = false
        if not new then
            new, n_sites = M.rewrite(rules, 'return ' .. slice, opts.lang)
            if new then new, wrapped = new:gsub('^return ', '', 1), true end
        end
        local rule_text = {}
        for _, r in ipairs(rules) do rule_text[#rule_text + 1] = ('`%s` -> `%s`'):format(r.lhs_text, r.rhs_text) end
        if not new then return nil, ('%s does not read losslessly on its own: %s'):format(tostring(n.name), tostring(n_sites)), 'frontier' end
        if n_sites == 0 then
            return nil, ('the rule %s matches nothing inside %s'):format(table.concat(rule_text, ', '), tostring(n.name)), 'empty'
        end
        local plan = {
            verb = 'rewrite-by-example', guards = { 'parses' }, generation = store.generation,
            touched = { n.file }, stamps = { [n.file] = txn.disk_stamp(root, n.file) },
            refspecs = { { id = n.id, name = n.name, ref = store.ref_of(n.id), what = 'symbol' } },
            edits = { [n.file] = text:sub(1, s0) .. new .. text:sub(e0 + 1) }, rules = rule_text, sites = n_sites,
            within = n.name, wrapped = wrapped or nil,
            preserves = 'none',
            preserves_why = 'the rewrite applies what ONE example demonstrated; nothing checks that it preserves behaviour',
            hazards = {},
            desc = ('rewrite by example within %s: %s, %d site(s)'):format(tostring(n.name), table.concat(rule_text, ', '), n_sites),
        }
        return txn.protocol(plan, function (p) return function (rel, before) return p.edits[rel] or before end end)
    end
    local scan = files_in(store, opts.scope or 'all', opts.lang)
    local edits, touched, stamps, per, total, unread = {}, {}, {}, {}, 0, {}
    -- ★ THE PREFILTER (cartograph.prefilter): a file whose text lacks a fixed token of EVERY rule cannot hold a match —
    -- a sound necessary condition, so it is skipped before it is parsed (CARTOGRAPH_PREFILTER=0 turns it off)
    local filters = {}
    if os.getenv('CARTOGRAPH_PREFILTER') ~= '0' then
        for i, r in ipairs(rules) do filters[i] = require('cartograph.prefilter').text(r.lhs) end
    end
    local function may_match(text)
        if #filters == 0 then return true end
        for _, f in ipairs(filters) do if f(text) then return true end end
        return false
    end
    local prefiltered = 0
    for _, rel in ipairs(scan) do
        local text = txn.read_file(root, rel)
        if text and not may_match(text) then prefiltered = prefiltered + 1; text = nil end
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
        edits = edits, rules = rule_text, sites = total, prefiltered = prefiltered,
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
