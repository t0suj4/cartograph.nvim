-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 3 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
local is_hole, key, occurrences =
    SHARED.is_hole, SHARED.key, SHARED.occurrences

-- ── transplant: apply the edit a → b to c (CART-0879 item 2; CART-0863's REFLECT) ──────
-- Meng, Kim, McKinley, "Systematic Editing: Generating Program Transformations from an
-- Example" (PLDI 2011), §3 read: from one exemplar edit (mA_old, mA_new) SYDIT derives an
-- ABSTRACT, CONTEXT-AWARE edit script (AST edit operations positioned relative to the
-- unchanged statements they depend on; every variable, method and type name replaced by an
-- abstract one, v1 m1 T1, the SAME abstraction in old and new), matches the abstract context
-- in a target mB under a one-to-one identifier mapping, and applies the concretized script.
-- Here the three steps are three operators that exist:
--   context     = join(a, c): the lgg of exemplar and target IS the abstract context with the
--                 identifier abstraction (holes) and the one-to-one mapping (Plotkin's rule:
--                 one hole per value pair) in one step. SYDIT's context is dependence-based
--                 and partial (default k = 1, upstream); ours is total structural agreement.
--   edit        = classify(T_ac, V_a, b): the exemplar's edit in the context's frame; a value
--                 edit, a template edit (the shared part changed, holes relocated by position
--                 where the old region is intact), both, or a STRADDLE.
--   application = the template part through migrate (propagate on the two-member family);
--                 the value part per changed hole: b's new value with every occurrence of a's
--                 old value replaced by c's (SYDIT's concretization; a wrap (g x) over y is
--                 (g y), a replacement z stays z: the ticket's β-reduction in first-order form).
--                 When classify STRADDLES (a hole's value changed at some sites only, or occurs
--                 several times in a rewritten region), the positional frame is ambiguous and
--                 SYDIT's own route runs instead: abstract b by a's hole VALUES, every
--                 occurrence a site (Plotkin's rule), and instantiate with c's values. That
--                 route is refused by name when a hole's value also occurs in the shared part,
--                 because b's mentions of it could not be attributed (the one-to-one mapping
--                 SYDIT requires fails the same way).
-- Nothing is recorded on any edit log: transplant derives a term, it does not move a family.
--   transplant(a, b, c, {align, env, context}) -> { result, kind, route, context, template,
--            values, applied, lifted, replaced, dropped, classify } | nil, why, C
local function abstract_by_value(t, Vs) -- every occurrence of a hole's value becomes a site
    -- top-down, so an outer value (g x) is taken before the x inside it; a node equals at most one
    -- of the (distinct) values, so no ordering among them is needed
    local order = {}
    for h, v in pairs(Vs) do order[#order + 1] = { h = h, v = v } end
    table.sort(order, function(x, y) return x.h < y.h end)
    local function go(u)
        if is_hole(u) then return u end
        for _, o in ipairs(order) do if M.eq(u, o.v) then return M.hole(o.h) end end
        if not u.kids then return M.copy(u) end
        local kids = {}
        for i, c in ipairs(u.kids) do kids[i] = go(c) end
        return M.rebuild(u, kids)
    end
    return go(t)
end

function M.transplant(a, b, c, opts)
    opts = opts or {}
    local env = opts.env
    local T, Va, Vc
    if opts.context then
        -- REFLECT's shape: a supplied context (an idiom template) in place of the lgg
        T = opts.context
        local ma, mc = M.match(T, a, env), M.match(T, c, env)
        if not ma.ok then return nil, 'a does not match the supplied context: ' .. ma.refusal.why end
        if not mc.ok then return nil, 'c does not match the supplied context: ' .. mc.refusal.why end
        Va, Vc = ma.values, mc.values
    else
        -- the context: under the 'none' rigidity by default so the edit stays classifiable
        -- (classify refuses repetition holes; an arity divergence becomes a node hole)
        local r, why = M.join(M.template(M.copy(a)), c, { align = opts.align or 'none', prefix = opts.prefix or 't', env = env })
        if not r then return nil, 'context: ' .. why end
        T, Va, Vc = r.template, r.left({}), r.right({})
        T.edits = {}
    end
    local C, cwhy = M.classify(T, Va, b, env)
    if not C then return nil, 'the exemplar does not instantiate its own context: ' .. tostring(cwhy) end
    local out = { kind = C.kind, route = 'positional', context = T, classify = C, applied = {}, lifted = {}, replaced = {}, dropped = {} }
    if C.kind == 'none' then out.result, out.template, out.values = M.copy(c), T, Vc; return out end
    if C.kind == 'unsupported' then return nil, C.why, C end
    local template, W = T, {}
    local function concretize(h, from, to, vc) -- b's new value with a's old value replaced by c's, everywhere
        local occ = {}
        occurrences(to, from, {}, occ)
        if #occ == 0 then out.replaced[#out.replaced + 1] = { h = h, from = vc, to = to }; return M.copy(to) end
        local sites = {}
        for i, p in ipairs(occ) do sites[i] = { path = p } end
        local D = M.abstract(to, { v = { sites = sites, domain = M.open(), origin = 'derived' } })
        local I = M.instantiate(D, { v = vc }, env)
        out.lifted[#out.lifted + 1] = { h = h, wrap = D, at = #occ, from = vc, to = I.term }
        return I.term
    end
    if C.kind == 'straddle' then
        -- SYDIT's route: abstract b by a's hole values, every occurrence a site
        out.route, out.straddle = 'abstracted', { why = C.why, proposal = C.proposal }
        local seen = {}
        for h, v in pairs(Va) do
            local k = M.show(v)
            if seen[k] then return nil, ('ambiguous: holes %s and %s hold the same value %s in a, so b\'s mentions of it cannot be attributed (%s)'):format(seen[k], h, k, C.why), C end
            seen[k] = h
            local occ = {}
            occurrences(T.body, v, {}, occ)
            if #occ > 0 then
                return nil, ('ambiguous: the value %s of hole %s also occurs in the shared part at %s, so b\'s mentions of it cannot be attributed (%s)'):format(
                    M.show(v), h, key(occ[1]), C.why), C
            end
        end
        local body = abstract_by_value(b, Va)
        local domains = {}
        local present = M.hole_names(M.template(body))
        local set = {}
        for _, h in ipairs(present) do set[h] = true; domains[h] = { domain = M.open(), origin = 'derived' } end
        for h in pairs(Va) do
            if set[h] then W[h] = Vc[h]; out.applied[#out.applied + 1] = { h = h }
            else out.dropped[#out.dropped + 1] = { h = h, value = Vc[h], why = 'hole ' .. h .. ' has no site in b: c\'s value has nowhere to go' } end
        end
        template = M.template(body, domains)
    else
        for h, v in pairs(Vc) do W[h] = v end
        if #C.regions > 0 then
            local mig = assert(M.migrate(T, C.template, { Va, Vc }, env))
            if not mig.values[2] then
                local d = mig.dropped[1]
                return nil, 'the template edit does not carry to c: ' .. tostring(d and d.why), C
            end
            template, W = C.template, mig.values[2]
            for _, p in ipairs(C.regions) do out.applied[#out.applied + 1] = { region = key(p) } end
        end
        for _, ch in ipairs(C.changed) do
            local h, vc = ch.h, W[ch.h]
            if vc == nil then
                out.dropped[#out.dropped + 1] = { h = h, why = 'hole ' .. h .. ' has no value in c after the template edit' }
            else
                W[h] = concretize(h, ch.from, ch.to, vc) -- equal values are the trivial case of the same rule
            end
        end
    end
    -- the result family is {b, c'}: its derived domains are summaries of that column (DOMAINS.md)
    local Vb = M.match(template, b, env)
    template = M.rederive_domains(M.copy(template), { Vb.ok and Vb.values or {}, W })
    local I = M.instantiate(template, W, env)
    if not I.ok then
        local whys = {}
        for _, x in ipairs(I.rejected) do whys[#whys + 1] = x end
        for _, x in ipairs(I.unfilled) do whys[#whys + 1] = 'no value for ' .. x end
        return nil, 'the transplanted values do not instantiate the edited context: ' .. table.concat(whys, '; '), C
    end
    out.result, out.template, out.values = I.term, template, W
    return out
end
end
