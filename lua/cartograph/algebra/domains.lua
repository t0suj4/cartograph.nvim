-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ THIS PART REACHES BACK FOR NOTHING: no captures, no free identifiers. Nine
-- sections in, the first fully self-contained one — a section boundary that IS
-- a dependency boundary, which `hopau` only appeared to be by luck.
return function (M, SHARED)
local _ = SHARED

-- ── domains ───────────────────────────────────────────────────────────────────
function M.open() return { kind = 'open' } end

function M.closed(v) return { kind = 'closed', value = v } end

function M.kinds(list)
    local set = {}
    for _, k in ipairs(list) do set[k] = true end
    return { kind = 'kinds', set = set }
end

function M.ref(name) return { kind = 'ref', name = name } end

function M.alt(...) return { kind = 'alt', alts = { ... } } end

function M.rep(of, min, max) return { kind = 'rep', of = of, min = min or 0, max = max } end

function M.both(a, b) return { kind = 'both', a = a, b = b } end

function M.context() return { kind = 'context' } end

function M.show_domain(D)
    if D.kind == 'open' then return '*' end
    if D.kind == 'closed' then return '=' .. M.show(D.value) end
    if D.kind == 'kinds' then
        local ks = {}
        for k in pairs(D.set) do ks[#ks + 1] = k end
        table.sort(ks)
        return '{' .. table.concat(ks, '|') .. '}'
    end
    if D.kind == 'ref' then return '@' .. D.name end
    if D.kind == 'alt' then
        local ps = {}
        for i, a in ipairs(D.alts) do ps[i] = M.show_domain(a) end
        return '(' .. table.concat(ps, ' | ') .. ')'
    end
    if D.kind == 'rep' then return M.show_domain(D.of) .. '{' .. D.min .. ',' .. (D.max or '') .. '}' end
    if D.kind == 'both' then return M.show_domain(D.a) .. ' & ' .. M.show_domain(D.b) end
    if D.kind == 'context' then return '◦-context' end
    return '?'
end

--- does value v satisfy domain D?  env = { defs = {name -> template}, self = template }
function M.admits(D, v, env)
    env = env or {}
    if D.kind == 'open' then return true end
    if D.kind == 'closed' then
        if M.eq(D.value, v) then return true end
        return false, 'pinned to ' .. M.show(D.value) .. ', got ' .. M.show(v)
    end
    if D.kind == 'kinds' then
        if D.set[v.k] then return true end
        return false, 'kind ' .. tostring(v.k) .. ' not in ' .. M.show_domain(D)
    end
    if D.kind == 'ref' then
        local T = D.name == 'self' and env.self or (env.defs or {})[D.name]
        if not T then return false, 'unresolved @' .. D.name end
        local m = M.match(T, v, { defs = env.defs, self = D.name == 'self' and env.self or T })
        if m.ok then return true end
        return false, '@' .. D.name .. ' refused: ' .. m.refusal.why
    end
    if D.kind == 'alt' then
        local whys = {}
        for _, a in ipairs(D.alts) do
            local ok, why = M.admits(a, v, env)
            if ok then return true end
            whys[#whys + 1] = why
        end
        return false, 'no alternative: ' .. table.concat(whys, '; ')
    end
    if D.kind == 'rep' then
        if v.k ~= 'seq' then return false, 'a repetition binds a seq, got ' .. tostring(v.k) end
        local n = #v.kids
        if n < D.min or (D.max and n > D.max) then
            return false, ('count %d outside {%d,%s}'):format(n, D.min, tostring(D.max or ''))
        end
        for i, e in ipairs(v.kids) do
            local ok, why = M.admits(D.of, e, env)
            if not ok then return false, ('element %d: %s'):format(i, why) end
        end
        return true
    end
    if D.kind == 'both' then
        local ok, why = M.admits(D.a, v, env)
        if not ok then return false, why end
        return M.admits(D.b, v, env)
    end
    if D.kind == 'context' then
        local n = 0
        local function count(t)
            if t.k == 'cursor' then n = n + 1 end
            for _, c in ipairs(t.kids or {}) do count(c) end
        end
        if v.k ~= 'seq' then return false, 'a context is a seq with one cursor, got ' .. tostring(v.k) end
        count(v)
        if n == 1 then return true end
        return false, ('a context has exactly one cursor, this has %d'):format(n)
    end
    return false, 'unknown domain ' .. tostring(D.kind)
end

--- intersection of two domains, simplified where the answer is syntactic
function M.meet(A, B, env)
    if A.kind == 'open' then return B end
    if B.kind == 'open' then return A end
    -- a pin is a point: it survives only if the other side admits it; otherwise the conjunction,
    -- which admits nothing (UNIFY.md found the old "return the pin" unsound in merge)
    if A.kind == 'closed' or B.kind == 'closed' then
        local P, O = A.kind == 'closed' and A or B, A.kind == 'closed' and B or A
        if O.kind == 'closed' then return M.eq(P.value, O.value) and P or M.both(A, B) end
        if M.admits(O, P.value, env) then return P end
        return M.both(A, B)
    end
    if A.kind == 'kinds' and B.kind == 'kinds' then
        local out = {}
        for k in pairs(A.set) do if B.set[k] then out[#out + 1] = k end end
        return M.kinds(out)
    end
    return M.both(A, B)
end

--- A entails B (every value of A is a value of B) — syntactic, partial
function M.entails(A, B, env)
    if B.kind == 'open' then return true end
    if A.kind == 'open' then return false end
    if A.kind == 'closed' then return (M.admits(B, A.value, env)) end
    if A.kind == 'kinds' and B.kind == 'kinds' then
        for k in pairs(A.set) do if not B.set[k] then return false end end
        return true
    end
    if A.kind == 'alt' then
        for _, a in ipairs(A.alts) do if not M.entails(a, B, env) then return false end end
        return true
    end
    if B.kind == 'alt' then
        for _, b in ipairs(B.alts) do if M.entails(A, b, env) then return true end end
    end
    if A.kind == B.kind and A.kind == 'ref' then return A.name == B.name end
    -- the meet's domains (UNIFY.md): every value of a&b is a value of a and of b
    if B.kind == 'both' then return M.entails(A, B.a, env) and M.entails(A, B.b, env) end
    if A.kind == 'both' then return M.entails(A.a, B, env) or M.entails(A.b, B, env) end
    return false
end
end
