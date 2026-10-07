-- fnpeer — a Lua FUNCTION's PEER, for peergen (CART-1538): the adapter that turns a function's own case split into a
-- peergen model, so a generated client can drive two implementations of it — the function interpreted and its mix
-- residual — with every request the function distinguishes, not only the ones a test suite happens to make.
--
-- ★ IMITATING THE PEER (CART-1138), for a function: its EXTERNAL choices are the input shapes its branches tell apart
-- (an algebra operator branches on a term's KIND — `k == 'hole' / 'seq' / 'lit' / …` — and its marks: rep, ctx, opt,
-- align); those are its caller's POSSIBILITIES. Which of them to send is the caller's POLICY, which peergen leaves to
-- the caller of the client — here a coverage-guided search over the case split's vocabulary.
--
-- THE MODEL: one OPERATION per sample of the function's arguments (a call a real suite made): its REQUEST is
-- node('call', arg…) — a template argument as node('template', body), a term argument as itself, any other
-- argument as node('fixed', i) (passed back as sampled) — with the sample's VARIATION POINTS made holes (the subterms
-- whose kind the case split names, shallow first, at most opts.points per argument); a hole's sampled subterm is its
-- default filling. `decode` turns a filled request back into the function's arguments.
-- TERMS: an algebra term is peergen's term shape plus marks (serialized since CART-1538); a literal's non-string
-- value keeps its TYPE in `vt`, as peergen writes v as text.
local M = {}

local SCALAR = { string = true, number = true, boolean = true }

--- an algebra term -> its peergen form (every scalar field kept; a non-string literal's type in vt; rep as true)
function M.encode(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for key, v in pairs(t) do
        if type(key) == 'string' and key ~= 'kids' and SCALAR[type(v)] then o[key] = v end
    end
    if t.rep then o.rep = true end
    if type(t.key) == 'table' then o.key_spec = vim.json.encode(t.key) end
    if t.k == 'lit' and t.v ~= nil and type(t.v) ~= 'string' then o.vt = type(t.v) end
    if t.kids then
        o.kids = {}
        for i, c in ipairs(t.kids) do o.kids[i] = M.encode(c) end
    end
    return o
end

--- a peergen term -> the algebra term it encodes
function M.decode(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for key, v in pairs(t) do
        if key ~= 'kids' and key ~= 'vt' and key ~= 'key_spec' then o[key] = v end
    end
    if t.key_spec then o.key = vim.json.decode(t.key_spec) end
    if t.vt and type(t.v) == 'string' then
        if t.vt == 'number' then o.v = tonumber(t.v) elseif t.vt == 'boolean' then o.v = (t.v == 'true') end
    end
    if t.kids then
        o.kids = {}
        for i, c in ipairs(t.kids) do o.kids[i] = M.decode(c) end
    end
    return o
end

local function is_term(v) return type(v) == 'table' and type(v.k) == 'string' end
local function is_template(v) return type(v) == 'table' and type(v.body) == 'table' and type(v.holes) == 'table' end
local function is_values(v) -- a map hole -> term
    if type(v) ~= 'table' or next(v) == nil then return false end
    for k, x in pairs(v) do if type(k) ~= 'string' or not is_term(x) then return false end end
    return true
end
--- the ROLE of each argument of a sample: 'template' (a record with body and holes), 'term' (a node), 'terms' (a
--- list of nodes), 'values' ({ hole -> term }), 'family' ({ template, values = { hole -> term }… }), 'fixed' (as sampled)
function M.roles(args)
    local r = {}
    for i = 1, args.n or #args do
        local v = args[i]
        if is_template(v) then r[i] = 'template'
        elseif is_term(v) then r[i] = 'term'
        elseif type(v) == 'table' and #v > 0 and (function () for _, x in ipairs(v) do if not is_term(x) then return false end end return true end)() then r[i] = 'terms'
        elseif is_values(v) then r[i] = 'values'
        elseif type(v) == 'table' and is_template(v.template) and type(v.values) == 'table'
            and (function () for _, x in ipairs(v.values) do if not is_values(x) then return false end end return true end)() then r[i] = 'family'
        else r[i] = 'fixed' end
    end
    return r
end
local function sorted(t) local ks = {}; for k in pairs(t) do ks[#ks + 1] = k end; table.sort(ks); return ks end
-- an argument of a role -> its request term (the wrappers' kinds are no algebra kinds, so no point sits on them)
local function enc_arg(role, v)
    if role == 'template' then return { k = 'template', kids = { M.encode(v.body) } } end
    if role == 'term' then return M.encode(v) end
    if role == 'terms' then local kids = {}; for i, x in ipairs(v) do kids[i] = M.encode(x) end; return { k = 'terms', kids = kids } end
    if role == 'values' then
        local pairs_ = {}
        for _, h in ipairs(sorted(v)) do pairs_[#pairs_ + 1] = { k = 'pair', kids = { { k = 'hkey', v = h }, M.encode(v[h]) } } end
        return { k = 'vals', kids = pairs_ }
    end
    if role == 'family' then
        local vs = {}
        for i, V in ipairs(v.values) do
            local pairs_ = {}
            for _, h in ipairs(sorted(V)) do pairs_[#pairs_ + 1] = { k = 'pair', kids = { { k = 'hkey', v = h }, M.encode(V[h]) } } end
            vs[i] = { k = 'vals', kids = pairs_ }
        end
        return { k = 'family', kids = { { k = 'template', kids = { M.encode(v.template.body) } }, { k = 'values', kids = vs } } }
    end
end
M.WRAPPERS = { template = true, terms = true, family = true, values = true, vals = true, pair = true, hkey = true, call = true, fixed = true }

-- the variation points of a term: paths to subterms whose kind the vocabulary names, breadth first, at most max
local function points(t, vocab, max, leaves)
    local out, queue = {}, { { t = t, path = {} } }
    local qi = 1
    while queue[qi] and #out < max do
        local cur = queue[qi]; qi = qi + 1
        if type(cur.t) == 'table' then
            -- (points never NEST: a chosen point's subterm is replaced whole, so nothing below it is a point too)
            local leaf = leaves and not M.WRAPPERS[cur.t.k] and #(cur.t.kids or {}) == 0 and #cur.path > 0
            if vocab[cur.t.k] or leaf then out[#out + 1] = cur.path; goto continue end
            for i, c in ipairs(cur.t.kids or {}) do
                local p = {}
                for j, s in ipairs(cur.path) do p[j] = s end
                p[#p + 1] = i
                queue[#queue + 1] = { t = c, path = p }
            end
        end
        ::continue::
    end
    return out
end
local function at(t, path) for _, i in ipairs(path) do t = t.kids[i] end; return t end
local function put(t, path, sub)
    if #path == 0 then return sub end
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    o.kids = {}
    for i, c in ipairs(t.kids) do o.kids[i] = c end
    local first = path[1]
    local rest = {}
    for j = 2, #path do rest[#rest + 1] = path[j] end
    o.kids[first] = put(t.kids[first], rest, sub)
    return o
end

--- the peergen MODEL of function `name` from its samples -> model, meta { [operation] = { sample, roles, orig } }.
--- opts.vocab: { [kind] = true } the case split's kinds; opts.points: variation points per argument (default 4)
function M.model(name, samples, opts)
    opts = opts or {}
    local vocab, maxp = opts.vocab or {}, opts.points or 4
    local model = { name = 'fnpeer:' .. name, doc = { 'the peer of ' .. name .. ', from ' .. #samples .. ' sampled calls' }, operations = {} }
    local meta = {}
    for si, s in ipairs(samples) do
        local roles = M.roles(s)
        local kids, params, orig, np = {}, {}, {}, 0
        for i = 1, s.n or #s do
            local enc = roles[i] ~= 'fixed' and enc_arg(roles[i], s[i]) or nil
            if enc then
                local ps = points(enc, vocab, maxp)
                if #ps == 0 then ps = points(enc, {}, maxp, true) end -- (no kind the code names: vary the leaves)
                for _, path in ipairs(ps) do
                    np = np + 1
                    local h = 'p' .. np
                    orig[h] = at(enc, path)
                    params[#params + 1] = h
                    enc = put(enc, path, { k = 'hole', h = h })
                end
                kids[i] = enc
            else
                kids[i] = { k = 'fixed', kids = { { k = 'lit', v = tostring(i) } } }
            end
        end
        local opname = name .. '_' .. si
        model.operations[#model.operations + 1] = {
            name = opname, params = params,
            doc = { ('sample %d: %d variation point(s), roles %s'):format(si, np, table.concat(roles, ',')) },
            request = { k = 'call', kids = kids },
            replies = { { name = 'reply', term = { k = 'hole', h = 'result' } } },
        }
        meta[opname] = { sample = s, roles = roles, orig = orig }
    end
    return model, meta
end

--- a FILLED request -> the function's arguments (a template rebuilt with the sample's domains for the holes still in it)
function M.decode_args(A, meta, request)
    local s, args = meta.sample, { n = meta.sample.n or #meta.sample }
    for i = 1, args.n do
        local kid = request.kids[i]
        local function template_of(enc, sample_t)
            local body = M.decode(enc.kids[1])
            local present = A.sites(A.template(body))
            local domains = {}
            for h, rec in pairs(sample_t.holes or {}) do if present[h] then domains[h] = rec end end
            return A.template(body, domains)
        end
        local role = meta.roles[i]
        if role == 'template' then args[i] = template_of(kid, s[i])
        elseif role == 'term' then args[i] = M.decode(kid)
        elseif role == 'terms' then args[i] = {}; for j, x in ipairs(kid.kids) do args[i][j] = M.decode(x) end
        elseif role == 'values' then args[i] = {}; for _, pr in ipairs(kid.kids) do args[i][pr.kids[1].v] = M.decode(pr.kids[2]) end
        elseif role == 'family' then
            local F = vim.deepcopy(s[i])
            F.template = template_of(kid.kids[1], s[i].template)
            F.values = {}
            for j, vals in ipairs(kid.kids[2].kids) do
                local V = {}
                for _, pr in ipairs(vals.kids) do V[pr.kids[1].v] = M.decode(pr.kids[2]) end
                F.values[j] = V
            end
            args[i] = F
        else args[i] = vim.deepcopy(s[i]) end
    end
    return args
end

return M
