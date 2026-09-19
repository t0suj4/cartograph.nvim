-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★★★ FIVE SHARED FILE-LOCALS, AND FOR THE FIRST TIME NOTHING HAD TO BE PRUNED:
-- the plan's capture hazards and the free-identifier scan named the SAME FIVE.
-- Every earlier section needed a union of the two and then a manual prune —
-- this one did not, because a capture is now the FREE NAMES OF THE TRAVELLING
-- SET, `(∪reads) \ (∪binds)`, rather than a text match (CART-0912).
return function (M, SHARED)
local at, cat, child, is_hole, key =
    SHARED.at, SHARED.cat, SHARED.child, SHARED.is_hole, SHARED.key

local function all_paths(t, path, f) -- every position under t, with its subterm
    f(path, t)
    for i, c in ipairs(t.kids or {}) do all_paths(c, child(path, i), f) end
end

--- instantiate with attribution. Returns { ok, term, origins = { [key(p)] = origin } }.
function M.trace(T, V, env, stage)
    stage = stage or 1
    local r = M.instantiate(T, V, env)
    if not r.ok then return r end
    for h, e in pairs(M.sites(T)) do if e.ctx then return { ok = false, why = 'context hole ' .. h .. ' unsupported' } end end
    if M.has_keyed(T.body) then return { ok = false, why = 'keyed nodes unsupported by trace (positional paths)' } end
    local origins = {}
    local seen = {} -- occurrences per hole in preorder: the site index (CLASSIFY.md reads it)
    local function attribute_value(out_path, h, v, base, site, tpath)
        all_paths(v, {}, function(q, _)
            origins[key(cat(out_path, q))] = { src = 'hole', stage = stage, hole = h, at = cat(base, q), site = site, tpath = tpath }
        end)
    end
    local function build(t, tpath, out_path)
        if is_hole(t) then -- a point hole: the whole value lands here
            seen[t.h] = (seen[t.h] or 0) + 1
            attribute_value(out_path, t.h, V[t.h], {}, seen[t.h], tpath)
            return M.copy(V[t.h])
        end
        if t.k == 'embed' then -- the string is one output position; its inside is a nested correspondence
            local Ti, Vi = M.inner_template(T, t), {}
            for h in pairs(Ti.holes) do Vi[h] = V[h] end
            local inner = M.trace(Ti, Vi, env, stage)
            local text, spans = M.grammars[t.g].print(inner.term)
            origins[key(out_path)] = { src = 'embed', stage = stage, g = t.g, at = tpath,
                text = text, spans = spans, origins = inner.origins }
            return M.lit(text)
        end
        origins[key(out_path)] = { src = 'fixed', stage = stage, at = tpath }
        if not t.kids then return M.copy(t) end
        local kids, n = {}, 0
        for i, c in ipairs(t.kids) do
            if is_hole(c) and c.rep then -- a repetition hole splices its sequence in
                seen[c.h] = (seen[c.h] or 0) + 1
                for j, e in ipairs(V[c.h].kids or {}) do
                    n = n + 1
                    attribute_value(child(out_path, n), c.h, e, { j }, seen[c.h], child(tpath, i))
                    kids[n] = M.copy(e)
                end
            else
                n = n + 1
                kids[n] = build(c, child(tpath, i), child(out_path, n))
            end
        end
        return M.rebuild(t, kids)
    end
    local term = build(T.body, {}, {})
    return { ok = true, term = term, origins = origins }
end

--- compose: c2's output positions traced through c2 into the previous output where a hole
--- was TAKEN (taken[h] = path in the previous output the hole's value was read from), then
--- through c1. Origins that stop earlier keep their stage. `via` records the path the
--- position had in each intermediate output, newest first.
function M.corr_compose(c2, c1, taken)
    local out = {}
    for k, o in pairs(c2) do
        if o.src == 'hole' and taken[o.hole] then
            local pos = cat(taken[o.hole], o.at)
            local o1 = c1[key(pos)]
            if o1 then
                -- newest first: hops already recorded on o, then this hop, then c1's
                local via = {}
                for _, v in ipairs(o.via or {}) do via[#via + 1] = v end
                via[#via + 1] = { stage = o.stage, at = pos }
                for _, v in ipairs(o1.via or {}) do via[#via + 1] = v end
                out[k] = { src = o1.src, stage = o1.stage, hole = o1.hole, at = o1.at, via = via }
            else
                out[k] = o
            end
        else
            out[k] = o
        end
    end
    return out
end

--- a pipeline: stages { {template, values, taken = { [h] = path in previous output }}, .. }.
--- Every taken hole's value is READ off the previous output, so stage k+1 needs only its
--- external values. Returns { ok, term, outputs, origins, origin(p), impact(k, q) }.
function M.pipeline(stages, env)
    local outputs, corrs, prev = {}, {}, nil
    for k, st in ipairs(stages) do
        local V = {}
        for h, v in pairs(st.values or {}) do V[h] = v end
        for h, q in pairs(st.taken or {}) do
            if not prev then return { ok = false, why = 'stage 1 cannot take' } end
            local v = at(prev, q)
            if v == nil then return { ok = false, why = ('stage %d: nothing at %s to take for %s'):format(k, key(q), h) } end
            V[h] = v
        end
        local r = M.trace(st.template, V, env, k)
        if not r.ok then return { ok = false, why = 'stage ' .. k .. ' refused', detail = r } end
        outputs[k], corrs[k], prev = r.term, r.origins, r.term
    end
    local composed = corrs[#stages]
    for k = #stages - 1, 1, -1 do composed = M.corr_compose(composed, corrs[k], stages[k + 1].taken or {}) end
    local P = { ok = true, term = prev, outputs = outputs, corrs = corrs, origins = composed }
    function P.origin(p) return composed[key(p)] end
    --- every final position whose chain passes through position q of stage k's OUTPUT
    --- (for external inputs of a stage see `uses`; at the final stage it is q itself)
    function P.impact(k, q)
        local qk, hits = key(q), {}
        for pk, o in pairs(composed) do
            local pass = false
            for _, v in ipairs(o.via or {}) do if v.stage == k + 1 and key(v.at) == qk then pass = true end end
            if not pass and k == #stages and pk == qk then pass = true end
            if pass then hits[#hits + 1] = pk end
        end
        table.sort(hits)
        return hits
    end
    --- every final position that came from external input `hole` of stage k
    function P.uses(k, hole)
        local hits = {}
        for pk, o in pairs(composed) do
            if o.src == 'hole' and o.stage == k and o.hole == hole then hits[#hits + 1] = pk end
        end
        table.sort(hits)
        return hits
    end
    return P
end

--- the text stage: show() with a span per position, so a cursor offset maps to a path and
--- from there through the pipeline. Serialization is a derivation with a correspondence.
function M.render(t)
    local buf, spans = {}, {}
    local off = 0
    local function emit(s) buf[#buf + 1] = s; off = off + #s end
    local function go(x, path)
        local from = off
        if x.k == 'lit' or x.k == 'name' or is_hole(x) then
            emit(M.show(x))
        else
            emit('(' .. x.k)
            for i, c in ipairs(x.kids or {}) do emit(' '); go(c, child(path, i)) end
            emit(')')
        end
        spans[#spans + 1] = { path = path, from = from, to = off }
    end
    go(t, {})
    return { text = table.concat(buf), spans = spans }
end

--- the innermost span containing a 0-based offset, or nil
function M.at_offset(R, off)
    local best
    for _, s in ipairs(R.spans) do
        if off >= s.from and off < s.to and (not best or (s.to - s.from) < (best.to - best.from)) then best = s end
    end
    return best and best.path
end
end
