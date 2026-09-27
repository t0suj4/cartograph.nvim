-- peergen — THE PEER GENERATOR'S CORE (CART-1138): a protocol model -> a self-contained Lua client of it.
--
-- ★★ IMITATING THE PEER (USER 2026-09-27). An implementation's EXTERNAL choices (the requests it offers to handle,
-- clause by clause) are its peer's INTERNAL choices (which request to send), so the implementation yields the
-- peer's POSSIBILITIES — every request it accepts, every reply shape it can give — and never its POLICY, which a
-- generated client hands to its caller. This module knows NOTHING about any protocol: an adapter (xmpppeer for XMPP
-- IQ) builds the model from an implementation, and the plumbing is a parameter (the transport the client is given:
-- an in-process imitation, canned replies, a socket).
--
-- THE MODEL
--   model = { name, doc, operations = { op… } }
--   op    = { name,                     -- the Lua function name (the adapter makes it unique and stable)
--             doc = { line… },          -- what the op is, where it comes from
--             params = { name… },       -- the caller supplies each as a TERM
--             request = term,           -- a template: holes named by params, the rest fixed
--             replies = { { name, term, doc } … } }   -- the reply cases, tried in order; a hole binds an output
--   term  = { k = kind, v = value, lk = literal kind, h = hole name, rep = true (a sequence hole), kids = { term… } }
--           — the algebra's term shape, so an adapter passes its terms as they are
--
-- THE CLIENT (the generated file has no `require`: the runtime is written into it)
--   local C = dofile(path).new(transport)       transport.exchange(request, op, args) -> reply term
--   local case, bindings, reply = C.<op>({ Param = term, … })   -- nil, 'unrecognized reply', reply when none fits
--   C.term.lit(v, lk), C.term.node(k, …)        build argument terms
local M = {}

-- the runtime written into every generated client: fill a template, match a reply against a case
M.RUNTIME = [==[
local R = {}
function R.lit(v, lk) return { k = 'lit', v = v, lk = lk } end
function R.node(k, ...) return { k = k, kids = { ... } } end
local function lit_eq(a, b) return a.v == b.v and (a.lk == nil or b.lk == nil or a.lk == b.lk) end
function R.equal(a, b)
    if a.k ~= b.k then return false end
    if a.k == 'lit' then return lit_eq(a, b) end
    if a.k == 'hole' then return a.h == b.h end
    local ak, bk = a.kids or {}, b.kids or {}
    if #ak ~= #bk then return false end
    for i = 1, #ak do if not R.equal(ak[i], bk[i]) then return false end end
    return true
end
-- a template with its holes filled from env: a sequence hole's value (a list) splices into the parent
function R.fill(t, env)
    if t.k == 'hole' then
        local v = env[t.h]
        if v == nil then return t end
        return v
    end
    if not t.kids then return t end
    local kids = {}
    for _, c in ipairs(t.kids) do
        if c.k == 'hole' and c.rep and env[c.h] ~= nil then
            for _, x in ipairs(env[c.h].kids or {}) do kids[#kids + 1] = x end
        else kids[#kids + 1] = R.fill(c, env) end
    end
    local o = {}
    for key, v in pairs(t) do o[key] = v end
    o.kids = kids
    return o
end
-- a reply against a case: env (the holes' values) or nil. One sequence hole per list: the fixed children before and
-- after it align, the rest is the sequence (bound as a list).
function R.match(p, t, env)
    if p.k == 'hole' and not p.rep then
        if env[p.h] ~= nil then return R.equal(env[p.h], t) and env or nil end
        env[p.h] = t
        return env
    end
    if t.k == 'hole' then return nil end
    if p.k ~= t.k then return nil end
    if p.k == 'lit' then return lit_eq(p, t) and env or nil end
    local pk, tk = p.kids or {}, t.kids or {}
    local hi
    for i, c in ipairs(pk) do if c.k == 'hole' and c.rep then hi = i end end
    if not hi then
        if #pk ~= #tk then return nil end
        for i = 1, #pk do if not R.match(pk[i], tk[i], env) then return nil end end
        return env
    end
    local pre, suf = hi - 1, #pk - hi
    if #tk < pre + suf then return nil end
    for i = 1, pre do if not R.match(pk[i], tk[i], env) then return nil end end
    for j = 0, suf - 1 do if not R.match(pk[#pk - j], tk[#tk - j], env) then return nil end end
    local mid = {}
    for i = pre + 1, #tk - suf do mid[#mid + 1] = tk[i] end
    local seq = { k = 'list', kids = mid }
    local h = pk[hi].h
    if env[h] ~= nil then return R.equal(env[h], seq) and env or nil end
    env[h] = seq
    return env
end
]==]

local function ser(t, out)
    if type(t) ~= 'table' then out[#out + 1] = ('%q'):format(tostring(t)); return end
    out[#out + 1] = '{k=' .. ('%q'):format(tostring(t.k))
    if t.v ~= nil then out[#out + 1] = ',v=' .. ('%q'):format(tostring(t.v)) end
    if t.lk ~= nil then out[#out + 1] = ',lk=' .. ('%q'):format(tostring(t.lk)) end
    if t.h ~= nil then out[#out + 1] = ',h=' .. ('%q'):format(tostring(t.h)) end
    if t.rep then out[#out + 1] = ',rep=true' end
    if t.kids and #t.kids > 0 then
        out[#out + 1] = ',kids={'
        for i, c in ipairs(t.kids) do
            if i > 1 then out[#out + 1] = ',' end
            ser(c, out)
        end
        out[#out + 1] = '}'
    elseif t.kids then out[#out + 1] = ',kids={}' end
    out[#out + 1] = '}'
end
--- a term as a Lua literal (deterministic: fixed key order)
function M.serialize(t)
    local out = {}
    ser(t, out)
    return table.concat(out)
end

local function ident(s) return (tostring(s):gsub('[^%w_]', '_'):gsub('^(%d)', '_%1')) end

--- the model -> the client's Lua source. Operations in name order; every string escaped; no `require` in it.
function M.generate(model)
    local ops = {}
    for _, op in ipairs(model.operations or {}) do ops[#ops + 1] = op end
    table.sort(ops, function (a, b) return a.name < b.name end)
    local L = {}
    local function w(s) L[#L + 1] = s end
    w('-- generated by cartograph peergen (CART-1138) — do not edit: regenerate from the implementation.')
    w('-- ' .. tostring(model.name or 'peer') .. ': ' .. #ops .. ' operation(s)')
    for _, d in ipairs(model.doc or {}) do w('-- ' .. d) end
    w(M.RUNTIME)
    w('local OPS = {}')
    for _, op in ipairs(ops) do
        w('')
        for _, d in ipairs(op.doc or {}) do w('-- ' .. d) end
        local params = {}
        for _, p in ipairs(op.params or {}) do params[#params + 1] = ('%q'):format(p) end
        w(('OPS[%q] = { name = %q, params = { %s },'):format(op.name, op.name, table.concat(params, ', ')))
        w('    request = ' .. M.serialize(op.request) .. ',')
        w('    replies = {')
        for _, c in ipairs(op.replies or {}) do
            w(('        { name = %q, term = %s },'):format(c.name, M.serialize(c.term)))
        end
        w('    } }')
    end
    w([==[

local C = { operations = OPS, term = { lit = R.lit, node = R.node } }
--- a client over `transport` (transport.exchange(request, op, args) -> reply term)
function C.new(transport)
    local c = { operations = OPS, term = C.term }
    for name, op in pairs(OPS) do
        c[name] = function (args)
            args = args or {}
            for _, p in ipairs(op.params) do
                if args[p] == nil then error(name .. ': missing argument ' .. p, 2) end
            end
            local req = R.fill(op.request, args)
            local rep = transport.exchange(req, op, args)
            for _, case in ipairs(op.replies) do
                local env = R.match(case.term, rep, {})
                if env then return case.name, env, rep end
            end
            return nil, 'unrecognized reply', rep
        end
    end
    return c
end
C.runtime = R
return C]==])
    return table.concat(L, '\n') .. '\n'
end

M.ident = ident
return M
