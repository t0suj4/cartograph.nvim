-- derive.lua — the re-derivation pass (REDERIVE.md): every operator below is rebuilt from the
-- BASIS alone, and the suite judges it. The basis, made checkable by construction: this
-- module only sees the table B built in `apply`, which holds the term formers, `rebuild`, the
-- position lens (`locate_at`, `put`, `positions`), `join`, and the declared PARAMETERS (eq,
-- show, the domain algebra, `template`, the grammar table). A derivation that needs anything
-- else fails loudly with "not in the basis" — and that failure is a finding.
local D = {}
local B -- the basis, bound in apply()
local unpack = table.unpack or unpack

local ALLOWED = {
    -- term formers and the one rebuild discipline
    'lit', 'name', 'node', 'seq', 'hole', 'ctx', 'cursor', 'present', 'absent', 'kinds', 'rebuild', 'copy',
    -- the position lens
    'locate_at', 'put', 'positions',
    'with_cursor', -- the zipper focus (CTXCUT.md): a slice with one cursor, a lens construction the derived match enumerates over
    -- the join
    'join',
    -- parameters: equality, printing, the domain algebra, the template constructor, grammars
    'eq', 'show', 'admits', 'entails', 'meet', 'open', 'closed', 'kinds', 'alt', 'ref', 'rep', 'both',
    'context', 'show_domain', 'template', 'grammars', 'observed',
    'key_name', 'widen', -- the key's name in a message, the domain widening (CASCADE.md)
    'classify_over', 'has_keyed', -- the edit calculus's reading of attributed regions (CLASSIFY.md) and the keyed test
    'admits_slice', -- the domain algebra's arm for a slice holding hedge variables (a query template as the instance)
    'spans', 'unfold_why', -- the sheet's byte ranges under cst_print (SURGERY.md), a print-side lens like show
    'EXTRACT_RULES', 'absence_of', -- the destination's lift rules, a declared parameter like the grammar table (LOOP.md); the negatives' classification
    'best', 'lex_order', 'by', 'then_', -- the PREFERENCE primitive and its order builders: an order is a declared parameter (PRIMITIVES.md)
    'SCOPE_RULES', -- the library boundary, a declared parameter (DESTINATION.md, RESOLVE.md)
    'summarize', 'rederive_domains',
    'unify', -- the MEET: the fourth arrow of the basis (UNIFY.md), not derivable from the other three -- the domain summary is part of the domain algebra (DOMAINS.md)
    -- the KV LENS (CART-1379): a declared ADAPTER, like the grammar table — the data adapters' JSON-like view as keyed
    -- terms and back (kv_terms decides list keyedness per FAMILY, kv_template decodes a generalization into the kv
    -- record in the view's written order); the kv family is derived over it
    'kv_terms', 'kv_term', 'kv_template', 'kv_kind',
}

local function is_hole(t) return type(t) == 'table' and t.k == 'hole' end
local function key(path) return #path == 0 and 'root' or table.concat(path, '/') end
local function child(path, i) local p = { unpack(path) }; p[#p + 1] = i; return p end
local function cat(p, q) local r = { unpack(p) }; for _, x in ipairs(q) do r[#r + 1] = x end; return r end
local function parent_of(path) return { unpack(path, 1, #path - 1) }, path[#path] end
local function is_prefix(p, q) if #p > #q then return false end; for i = 1, #p do if p[i] ~= q[i] then return false end end; return true end
local function later_first(a, b) -- deeper / later sites first, so untouched indices stay valid
    if #a.path ~= #b.path then return #a.path > #b.path end
    for i = 1, #a.path do if a.path[i] ~= b.path[i] then return a.path[i] > b.path[i] end end
    return false
end

-- ── sites, from positions ──────────────────────────────────────────────────────
function D.sites(T)
    local H = {}
    local body = T.body
    -- the presence holes above a position: every ancestor carrying an `opt` mark (KEYED.md)
    local function under_of(path)
        local under
        for d = 1, #path - 1 do
            local anc = B.locate_at(body, { unpack(path, 1, d) })
            if anc and anc.opt then under = under or {}; under[#under + 1] = { h = anc.opt, path = { unpack(path, 1, d) } } end
        end
        return under
    end
    for _, p in ipairs(B.positions(body)) do
        local t = p.node
        if t.opt then -- an optional kid of a keyed node: its presence hole sits at its own path
            local e = H[t.opt]
            if not e then
                e = { sites = {}, domain = (T.holes and T.holes[t.opt] and T.holes[t.opt].domain) or B.kinds { 'present', 'absent' },
                    origin = (T.holes and T.holes[t.opt] and T.holes[t.opt].origin) or 'derived', rep = false, presence = true }
                H[t.opt] = e
            end
            e.sites[#e.sites + 1] = { path = p.path, presence = true, under = under_of(p.path) }
        end
        if is_hole(t) then
            local e = H[t.h]
            if not e then
                e = { sites = {}, domain = (T.holes and T.holes[t.h] and T.holes[t.h].domain) or B.open(), origin = (T.holes and T.holes[t.h] and T.holes[t.h].origin) or 'derived', was = T.holes and T.holes[t.h] and T.holes[t.h].was or nil, rep = t.rep or false }
                H[t.h] = e
            end
            local site = { path = p.path }
            local through
            for d = 0, #p.path - 1 do -- boundaries crossed on the way down
                local anc = B.locate_at(body, { unpack(p.path, 1, d) })
                if anc.k == 'embed' then through = through or {}; through[#through + 1] = { path = { unpack(p.path, 1, d) }, g = anc.g } end
            end
            site.through = through
            site.under = under_of(p.path)
            e.sites[#e.sites + 1] = site
            e.ctx = t.ctx or false
        end
    end
    return H
end
function D.hole_names(T)
    local names = {}
    for h in pairs(D.sites(T)) do names[#names + 1] = h end
    table.sort(names)
    return names
end
local function ground(t)
    for _, p in ipairs(B.positions(t)) do if is_hole(p.node) then return false end end
    return true
end

-- ── apply: put every value at every site, later sites first; hedges splice ─────
local function normalize_embeds(body)
    local ps = B.positions(body)
    for i = #ps, 1, -1 do
        local p = ps[i]
        if p.node.k == 'embed' then
            local cur = B.locate_at(body, p.path)
            if cur and cur.k == 'embed' and ground(cur.kids[1]) then
                local text = B.grammars[cur.g].print(cur.kids[1])
                if not text then error('embed: inner instance is not printable under ' .. cur.g) end
                body = B.put(body, p.path, B.lit(text))
            end
        end
    end
    return body
end
function D.apply(T, sigma)
    local H = D.sites(T)
    local plan, unfilled = {}, {}
    for h, e in pairs(H) do
        if e.presence then -- a presence hole marks a pair; instantiate drops or keeps the pair, nothing is put
        elseif sigma[h] ~= nil then
            for _, s in ipairs(e.sites) do plan[#plan + 1] = { h = h, path = s.path, rep = e.rep, ctx = e.ctx } end
        else
            unfilled[h] = true
        end
    end
    table.sort(plan, later_first)
    local body = T.body
    for _, p in ipairs(plan) do
        if p.ctx then
            -- a context hole: its (already substituted, deeper-first) kids are the hedge; the
            -- value is a context with one cursor; plugging is a SPLICE at the cursor's site,
            -- and the plugged context's kids replace the hole's position in its parent
            local here = B.locate_at(body, p.path)
            local hedge = here.kids or {}
            local ctxv = sigma[p.h]
            local cpath
            for _, q in ipairs(B.positions(ctxv)) do if q.node.k == 'cursor' then cpath = q.path end end
            if not cpath then error('context value has no cursor') end
            local cparent, cidx = parent_of(cpath)
            local cp = B.locate_at(ctxv, cparent)
            local kids = {}
            for j = 1, cidx - 1 do kids[#kids + 1] = cp.kids[j] end
            for _, e in ipairs(hedge) do kids[#kids + 1] = B.copy(e) end
            for j = cidx + 1, #cp.kids do kids[#kids + 1] = cp.kids[j] end
            local plugged = B.put(ctxv, cparent, B.rebuild(cp, kids))
            if #p.path == 0 then body = plugged
            else
                local ppath, idx = parent_of(p.path)
                local parent = B.locate_at(body, ppath)
                local pk = {}
                for j = 1, idx - 1 do pk[#pk + 1] = parent.kids[j] end
                for _, e in ipairs(plugged.kids or {}) do pk[#pk + 1] = e end
                for j = idx + 1, #parent.kids do pk[#pk + 1] = parent.kids[j] end
                body = B.put(body, ppath, B.rebuild(parent, pk))
            end
        elseif p.rep then
            local ppath, idx = parent_of(p.path)
            local parent = B.locate_at(body, ppath)
            local kids = {}
            for j = 1, idx - 1 do kids[#kids + 1] = parent.kids[j] end
            for _, e in ipairs(sigma[p.h].kids or {}) do kids[#kids + 1] = B.copy(e) end
            for j = idx + 1, #parent.kids do kids[#kids + 1] = parent.kids[j] end
            body = B.put(body, ppath, B.rebuild(parent, kids))
        else
            body = B.put(body, p.path, B.copy(sigma[p.h]))
        end
    end
    body = normalize_embeds(body)
    local domains = {}
    for h in pairs(unfilled) do domains[h] = T.holes[h] and B.copy(T.holes[h]) or { domain = B.open(), origin = 'derived' } end
    return B.template(body, domains)
end

local function is_absent(v) return type(v) == 'table' and v.k == 'absent' end
function D.instantiate(T, V, env)
    local H = D.sites(T)
    local missing, rejected, extra = {}, {}, {}
    for h in pairs(V) do if not H[h] then extra[#extra + 1] = h end end
    -- a hole is owed only at a site not under an optional pair whose presence is absent (KEYED.md)
    local function owed(e)
        for _, s in ipairs(e.sites) do
            local dropped = false
            for _, u in ipairs(s.under or {}) do if is_absent(V[u.h]) then dropped = true end end
            if not dropped then return true end
        end
        return false
    end
    for h, e in pairs(H) do
        if V[h] == nil then if owed(e) then missing[#missing + 1] = h end
        else
            local ok, why = B.admits(e.domain, V[h], env)
            if not ok then rejected[#rejected + 1] = h .. ': ' .. why end
        end
    end
    table.sort(missing); table.sort(rejected); table.sort(extra)
    if #missing > 0 or #rejected > 0 or #extra > 0 then return { ok = false, unfilled = missing, rejected = rejected, extra = extra } end
    -- no post-check for holes left in the result: a VALUE may itself carry holes (an input
    -- variable is a constant of the problem, EAU.md), exactly as the original does not check
    local body = D.apply(T, V).body
    -- an optional pair whose presence is absent is dropped; an instance carries no presence mark
    local function strip(t)
        if type(t) ~= 'table' then return t end
        if not t.kids then return t end
        local kids = {}
        for _, c in ipairs(t.kids) do
            if c.opt and is_absent(V[c.opt]) then -- dropped
            else
                local c2 = strip(c)
                if c2.opt and V[c2.opt] ~= nil then c2 = B.copy(c2); c2.opt = nil end
                kids[#kids + 1] = c2
            end
        end
        return B.rebuild(t, kids)
    end
    return { ok = true, term = strip(body) }
end

-- ── the third leg: read and cut at positions, through boundaries by parsing ────
local function locate_through(I, path, through)
    if not through then return B.locate_at(I, path) end
    local root, consumed = I, 0
    for _, b in ipairs(through) do
        local sub = B.locate_at(root, { unpack(b.path, consumed + 1) })
        local inner = sub.k == 'embed' and sub.kids[1] or B.grammars[b.g].parse(sub.v)
        if not inner then return nil end
        root, consumed = inner, #b.path + 1
    end
    return B.locate_at(root, { unpack(path, consumed + 1) })
end
local function need_cursor(who, h, s)
    if not s.cursor then error(who .. ': a context site (hole ' .. h .. ') needs a cursor record; H from sites(T) has none, H from match does') end
end
--- the slice at a context site, as a list of copies, and the path of the node whose kids hold the cursor list
local function slice_of(I, s)
    local ppath, start = parent_of(s.path)
    local parent = B.locate_at(I, ppath)
    local slice = {}
    for j = start, start + (s.n or 0) - 1 do slice[#slice + 1] = B.copy(parent.kids[j]) end
    return slice
end
local function cursor_parent(s) -- the node whose kids hold the cursor list, and the focus's first index in it
    local ppath, start = parent_of(s.path)
    local p = s.cursor.path
    if #p == 0 then return ppath, start + s.cursor.from - 1 end -- top level: cursor.from counts from the slice's first element
    local q = { unpack(ppath) }
    q[#q + 1] = start + p[1] - 1
    for i = 2, #p do q[#q + 1] = p[i] end
    return q, s.cursor.from
end
--- the context value in basis terms: the slice as a seq, the cursor list rebuilt around one
--- cursor former, `put` back at the relative path (Huet's path read off at a site, CTXCUT.md)
local function cut_context(I, s)
    local c = B.seq(slice_of(I, s))
    local L = B.locate_at(c, s.cursor.path)
    local kids = {}
    for j = 1, s.cursor.from - 1 do kids[#kids + 1] = L.kids[j] end
    kids[#kids + 1] = B.cursor()
    for j = s.cursor.from + s.cursor.n, #L.kids do kids[#kids + 1] = L.kids[j] end
    return B.put(c, s.cursor.path, B.rebuild(L, kids))
end
function D.values_at(I, H)
    local V, conflicts = {}, {}
    local function dropped(s) -- under an optional pair this instance lacks: no value owed
        for _, u in ipairs(s.under or {}) do if B.locate_at(I, u.path) == nil then return true end end
        return false
    end
    for h, e in pairs(H) do
        for _, s in ipairs(e.sites) do
            local v
            if dropped(s) then v = nil
            elseif e.presence then v = B.locate_at(I, s.path) ~= nil and B.present() or B.absent()
            elseif e.ctx then
                need_cursor('values_at', h, s)
                v = cut_context(I, s)
            elseif e.rep then
                local ppath, start = parent_of(s.path)
                local parent = locate_through(I, ppath, s.through)
                local kids = {}
                for j = start, start + (s.n or 0) - 1 do kids[#kids + 1] = B.copy(parent.kids[j]) end
                v = B.seq(kids)
            else
                v = B.copy(locate_through(I, s.path, s.through))
            end
            if v == nil then -- dropped
            elseif V[h] == nil then V[h] = v elseif not B.eq(V[h], v) then conflicts[#conflicts + 1] = h end
        end
    end
    return V, conflicts
end
local function place(root, consumed, p, node)
    -- put `node` at the absolute site p.path, crossing the boundaries listed in p.through
    local through = p.through or {}
    local nxt = through[1]
    if nxt then
        local rel = { unpack(nxt.path, consumed + 1) }
        local sub = B.locate_at(root, rel)
        local inner = sub.k == 'embed' and sub.kids[1] or B.grammars[nxt.g].parse(sub.v)
        local rest = { through = { unpack(through, 2) }, path = p.path, rep = p.rep, n = p.n, h = p.h }
        local inner2 = place(inner, #nxt.path + 1, rest, node)
        return B.put(root, rel, { k = 'embed', g = nxt.g, kids = { inner2 } })
    end
    local rel = { unpack(p.path, consumed + 1) }
    if #rel == 0 and consumed > 0 then error("abstract: a hole cannot replace a whole boundary") end
    if p.rep then
        local ppath, start = parent_of(rel)
        local parent = B.locate_at(root, ppath)
        local kids = {}
        for j = 1, start - 1 do kids[#kids + 1] = parent.kids[j] end
        kids[#kids + 1] = node
        for j = start + (p.n or 0), #parent.kids do kids[#kids + 1] = parent.kids[j] end
        return B.put(root, ppath, B.rebuild(parent, kids))
    end
    return B.put(root, rel, node)
end
local function later_first_ids(a, b) -- later_first, then the later-bound site at one path, else the positive-width one
    if #a.path ~= #b.path then return #a.path > #b.path end
    for i = 1, #a.path do if a.path[i] ~= b.path[i] then return a.path[i] > b.path[i] end end
    if a.id and b.id then return a.id > b.id end
    return (a.n or 1) > (b.n or 1)
end
function D.abstract(I, H)
    local entries = {}
    for h, e in pairs(H) do
        for _, s in ipairs(e.sites) do
            if e.ctx then need_cursor('abstract', h, s) end
            entries[#entries + 1] = { h = h, path = s.path, n = s.n, rep = e.rep, ctx = e.ctx or nil, cursor = s.cursor,
                through = s.through, id = s.id, within = s.within, presence = e.presence or nil, under = s.under }
        end
    end
    local function inside(e, pool) -- the sites matched inside e's applied hedge, transitively
        if not e.id then return {} end
        local ids, out, grew = { [e.id] = true }, {}, true
        while grew do
            grew = false
            for _, x in ipairs(pool) do if x.within and ids[x.within] and not ids[x.id] then ids[x.id] = true; grew = true end end
        end
        for _, x in ipairs(pool) do if x.id ~= e.id and ids[x.id] then out[#out + 1] = x end end
        return out
    end
    local build
    local function cut(orig, e, pool) -- the context hole node: the sub-slice at the cursor, abstracted on its own coordinates
        local Lparent, fstart = cursor_parent(e)
        local L = B.locate_at(orig, Lparent)
        local kids = {}
        for j = fstart, fstart + e.cursor.n - 1 do kids[#kids + 1] = B.copy(L.kids[j]) end
        local rebased = {}
        for _, x in ipairs(inside(e, pool)) do
            local y = {}
            for k2, v in pairs(x) do y[k2] = v end
            y.path = { unpack(x.path, #Lparent + 1) }
            y.path[1] = y.path[1] - fstart + 1
            rebased[#rebased + 1] = y
        end
        return B.ctx(e.h, build(B.seq(kids), e.id, rebased).kids)
    end
    build = function(orig, enc, pool)
        local plan = {}
        for _, x in ipairs(pool) do if x.within == enc then plan[#plan + 1] = x end end
        table.sort(plan, later_first_ids)
        local body = B.copy(orig)
        for _, p in ipairs(plan) do
            for _, u in ipairs(p.under or {}) do
                if B.locate_at(body, u.path) == nil then
                    error(('abstract: optional pair %s (hole %s) is absent in this instance; abstract from a member carrying it'):format(u.path[#u.path], u.h))
                end
            end
            if p.presence then
                local pair = B.locate_at(body, p.path)
                if pair == nil then
                    error(('abstract: optional pair %s (hole %s) is absent in this instance; abstract from a member carrying it'):format(p.path[#p.path], p.h))
                end
                local marked = B.copy(pair); marked.opt = p.h
                body = B.put(body, p.path, marked)
            elseif p.ctx then
                local node = cut(orig, p, pool)
                local ppath, start = parent_of(p.path)
                local parent = B.locate_at(body, ppath)
                local kids = {}
                for j = 1, start - 1 do kids[#kids + 1] = parent.kids[j] end
                kids[#kids + 1] = node
                for j = start + (p.n or 0), #parent.kids do kids[#kids + 1] = parent.kids[j] end
                body = B.put(body, ppath, B.rebuild(parent, kids))
            else
                body = place(body, 0, p, B.hole(p.h, p.rep or nil))
            end
        end
        return body
    end
    local body = build(I, nil, entries)
    local domains = {}
    for h, e in pairs(H) do domains[h] = { domain = e.domain, origin = e.origin or 'derived', was = e.was } end
    return B.template(body, domains)
end
function D.locate(I, V)
    local cands, ambiguous = {}, false
    for h, v in pairs(V) do
        cands[h] = {}
        for _, p in ipairs(B.positions(I)) do if B.eq(p.node, v) then cands[h][#cands[h] + 1] = key(p.path) end end
        if #cands[h] ~= 1 then ambiguous = true end
    end
    return cands, ambiguous
end

-- ── match, as the join with nothing new, split or widened ─────────────────────
local function mismatch_why(a, b)
    if a.k ~= b.k then return ('kind %s vs %s'):format(a.k, tostring(b.k)) end
    if a.k == 'lit' then return ('literal %s vs %s'):format(B.show(a), B.show(b)) end
    if a.k == 'name' then return ('name %s vs %s'):format(a.n, b.n) end
    if a.kids and b.kids and #a.kids ~= #b.kids then return ('arity: %d vs %d children'):format(#a.kids, #b.kids) end
    return 'fixed parts differ'
end
local TRACE = os.getenv('DMATCH_TRACE') -- instruments: every candidate substitution on stderr,
local SLOW = tonumber(os.getenv('DMATCH_SLOW') or '') -- and every match slower than this many seconds
local HEDK = 'hedge\1' -- and an instance-side HEDGE hole likewise (join aligns one hedge per list; a query's hedges are values)
local function is_skolem_hedge(t) return type(t) == 'table' and type(t.k) == 'string' and t.k:sub(1, #HEDK) == HEDK end
--- the CLOSING step of the derived match: join with nothing new, split or widened, values read
--- off the right map (REDERIVE.md). Reached once no variable-width choice is left (DMATCH.md).
local function match_close(T, I, env)
    env = env or {}
    env = { defs = env.defs, self = env.self or T, hole_domains = env.hole_domains } -- `ref 'self'` names the template being matched
    -- positional: the original matcher walks child lists in order and has no keyed-table branch
    local r, why = B.join(T, I, { env = env, positional = true })
    if not r then
        -- the hand-built matcher names an alignment mismatch first (KEYED.md): find the first pair of
        -- positionally aligned nodes whose disciplines differ
        local function disc(x) return x.align or 'positional' end
        local function first_mismatch(t, i)
            if type(t) ~= 'table' or type(i) ~= 'table' or is_hole(t) or is_hole(i) then return nil end
            if disc(t) ~= disc(i) then return disc(t), disc(i) end
            for j, c in ipairs(t.kids or {}) do
                if (i.kids or {})[j] == nil then return nil end
                local a, b = first_mismatch(c, i.kids[j])
                if a then return a, b end
            end
            return nil
        end
        local ta, ia = first_mismatch(T.body, I)
        if ta then why = ('alignment: template %s, instance %s'):format(ta, ia) end
        if why == 'fixed parts differ' then -- join's word for a structural mismatch: name the first one as the matcher does
            local function first_diff(t, i, path)
                if type(t) ~= 'table' or type(i) ~= 'table' or is_hole(t) or is_hole(i) or t.k == 'embed' or t.align then return nil end
                if t.k == 'lit' or t.k == 'name' then if not B.eq(t, i) then return path, (t.k == 'lit' and 'literal %s vs %s' or 'name %s vs %s'):format(B.show(t), B.show(i)) end return nil end
                if t.k ~= i.k then return path, ('kind %s vs %s'):format(tostring(t.k), tostring(i.k)) end
                local tk, ik = t.kids or {}, i.kids or {}
                local hedged = false
                for _, c in ipairs(tk) do if is_hole(c) and c.rep then hedged = true end end
                if not hedged and #tk ~= #ik then return path, #tk < #ik and ('arity: %d unmatched children'):format(#ik - #tk) or ('arity: template child %d has no counterpart'):format(#ik + 1) end
                if not hedged then for j = 1, #tk do local a, b = first_diff(tk[j], ik[j], child(path, j)); if a then return a, b end end end
                return nil
            end
            local at, w2 = first_diff(T.body, I, {})
            if at then return { ok = false, refusal = { at = key(at), why = w2 } } end
        end
        return { ok = false, refusal = { at = 'root', why = why } }
    end
    local function site_of(n)
        local e = D.sites(r.template)[n]
        return e and e.sites[1] and key(e.sites[1].path) or 'root'
    end
    if #(r.relaxed or {}) > 0 then
        return { ok = false, refusal = { at = 'root', why = 'keys out of order: the instance permutes a keyed-ordered node' } }
    end
    if #r.new > 0 then
        local f = r.frags[r.new[1]]
        -- a presence fragment: the join made a pair optional, so one side lacked the key
        local p = D.sites(r.template)[r.new[1]]
        p = p and p.sites[1] and p.sites[1].path
        local k = p and p[#p]
        if f.left and f.left.k == 'absent' then return { ok = false, refusal = { at = site_of(r.new[1]), why = 'key ' .. tostring(k) .. ' has no counterpart in the template' } } end
        if type(f.left) == 'table' and type(f.right) == 'table' and not is_hole(f.left) and not is_hole(f.right) and (f.left.align or 'positional') ~= (f.right.align or 'positional') then
            return { ok = false, refusal = { at = site_of(r.new[1]), why = ('alignment: template %s, instance %s'):format(f.left.align or 'positional', f.right.align or 'positional') } }
        end
        if type(f.left) == 'table' and f.left.k == 'embed' and type(f.right) == 'table' and f.right.k == 'lit' and type(f.right.v) == 'string' and B.grammars[f.left.g] and not B.grammars[f.left.g].parse(f.right.v) then
            return { ok = false, refusal = { at = site_of(r.new[1]), why = ('the string does not parse under %s: %s'):format(f.left.g, f.right.v) } }
        end
        if f.left and f.left.k == 'present' and f.right and f.right.k == 'absent' then return { ok = false, refusal = { at = site_of(r.new[1]), why = 'key ' .. tostring(k) .. ' is missing' } } end
        return { ok = false, refusal = { at = site_of(r.new[1]), why = mismatch_why(f.left, f.right) } }
    end
    if #r.split > 0 then
        local s = r.split[1]
        return { ok = false, refusal = { at = site_of(s.to),
            why = ('hole %s already bound to %s, here %s'):format(s.from, B.show(r.frags[s.from].right), B.show(r.frags[s.to].right)) } }
    end
    local H = D.sites(T)
    local values, S = {}, {}
    for h in pairs(H) do
        local v = r.frags[h].right
        if is_skolem_hedge(v) and not H[h].rep then
            return { ok = false, refusal = { at = site_of(h), why = 'hole ' .. h .. ': a hedge variable cannot fill a term hole' } }
        end
        if type(v) == 'table' and v.k == 'noval' then v = nil end -- under an optional pair the instance lacks: no value owed
        if v == nil then
            -- under an optional pair the instance lacks: no value owed, and no site (the hand-built matcher records none)
        elseif H[h].rep and type(v) == 'table' and v.k == 'seq' and (function() for _, e in ipairs(v.kids) do if is_skolem_hedge(e) then return true end end end)() then
            -- a hedge hole facing a slice that holds the query's own hedge variables (Skolemized)
            local plain, hedges = {}, {}
            for _, e in ipairs(v.kids) do
                if is_skolem_hedge(e) then local q = e.k:sub(#HEDK + 1); hedges[#hedges + 1] = env.hole_domains and env.hole_domains[q] and env.hole_domains[q].domain or B.open()
                else plain[#plain + 1] = e end
            end
            local ok, dwhy = B.admits_slice(H[h].domain, plain, hedges, env)
            if not ok then return { ok = false, refusal = { at = site_of(h), why = 'hole ' .. h .. ': ' .. dwhy } } end
        elseif is_hole(v) and env.hole_domains then -- a hole facing a hole: subsumption of domains
            local d1 = env.hole_domains[v.h] and env.hole_domains[v.h].domain or B.open()
            if not B.entails(d1, H[h].domain, env) then
                return { ok = false, refusal = { at = site_of(h), why = ('hole %s: ?%s %s does not entail %s'):format(h, v.h, B.show_domain(d1), B.show_domain(H[h].domain)) } }
            end
        else
            local ok, dwhy = B.admits(H[h].domain, v, env)
            if not ok then return { ok = false, refusal = { at = site_of(h), why = 'hole ' .. h .. ': ' .. dwhy } } end
        end
        if v ~= nil then
            values[h] = B.copy(v)
            S[h] = { sites = {}, domain = H[h].domain, rep = H[h].rep, origin = H[h].origin, was = H[h].was, presence = H[h].presence or nil }
            -- a hedge site carries its count: the holes leg of the gate is instance-relative
            for _, s in ipairs(H[h].sites) do S[h].sites[#S[h].sites + 1] = { path = s.path, n = (H[h].rep or (type(v) == 'table' and v.k == 'seq')) and #(v.kids or {}) or nil, presence = s.presence, under = s.under } end
        end
    end
    return { ok = true, values = values, sites = S, provenance = B.observed(values, S) }
end

-- ── MATCH AS A SEARCH (DMATCH.md). Kutsia, JSC 2007, pp. 21-22: a sequence variable at the
-- head of a list is eliminated by Projection (it takes the empty hedge) or widened by one
-- term (SVE2, W1), each step a substitution applied to the whole problem; matching against a
-- ground side is finitary because every step consumes the instance. His remark on
-- Mathematica's matcher fixes the order used here: the shortest sequence for the first
-- sequence variable first, stop at the first solution. Context holes (BK 2014, CTXMATCH.md)
-- are eliminated the same way: every placement of one cursor inside a slice of the instance
-- (the zipper focus, `with_cursor`) is a candidate context value. Each candidate is a
-- substitution through the derived `apply`; the closing step is join with nothing new.
local Q = 'q\1' -- instance-side holes are renamed apart for the search (a query template's holes are values, never choice points)
local function is_q(h) return type(h) == 'string' and h:sub(1, 2) == Q end
local function is_var_width(t) return is_hole(t) and (t.rep or t.ctx) and not is_q(t.h) and true or false end
local CTXK = 'ctx\1' -- an instance-side CONTEXT hole is carried through the search as an opaque node of its own kind
-- (HEDK and is_skolem_hedge are declared above the closing step, which refuses a term hole facing one)
local function rename_holes(t, f, skolem) -- a deep copy with every hole name mapped (context kids and presence marks included)
    if type(t) ~= 'table' then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    if t.k == 'hole' then
        c.h = f(t.h)
        if skolem == 'in' and t.ctx then c.k = CTXK .. c.h; c.ctx = nil; c.kids = c.kids or {} -- join has no context variables: a constant of its own kind
        elseif skolem == 'in' and t.rep then c.k = HEDK .. c.h; c.rep = nil; c.kids = {} end
    elseif skolem == 'out' and type(t.k) == 'string' and t.k:sub(1, #CTXK) == CTXK then
        c.k, c.ctx, c.h = 'hole', true, f(t.h)
    elseif skolem == 'out' and is_skolem_hedge(t) then
        c.k, c.rep, c.h, c.kids = 'hole', true, f(t.h), nil
    end
    if t.opt then c.opt = f(t.opt) end
    if t.kids then c.kids = {}; for i, x in ipairs(t.kids) do c.kids[i] = rename_holes(x, f, skolem) end end
    return c
end
--- the first choice point in preorder: a list holding two or more variable-width holes or a
--- context hole. Kids before it are fixed-width, so the instance list and index are
--- determinate; a list with exactly one hedge hole is FORCED (join's rule) and not a choice.
local function FAILED(at, why) return { failed = true, at = key(at), why = why } end -- a determinate mismatch on the way to the next choice: no substitution can repair it
--- the first choice point in preorder: a list holding two or more variable-width holes or a
--- context hole. Kids before it are fixed-width, so the instance list and index are
--- determinate; a list with exactly one hedge hole is FORCED (join's rule) and not a choice.
--- On the way, determinate positions are checked (a node's kind, a leaf's value, a list's
--- length without hedges): the hand-built matcher fails at the first such mismatch, and so
--- must the search, or every wrong width is only refuted after the remaining choices are
--- enumerated. Returns a choice, nil (nothing left to choose: close with join), or FAIL.
local function choice_point(t, i, ipath)
    if type(t) ~= 'table' or type(i) ~= 'table' then return nil end
    if is_hole(t) or is_hole(i) then return nil end -- a term hole, or a hole on the instance side: the closing join decides
    if t.k == 'embed' or t.align then return nil end -- a grammar boundary or a keyed node: the closing join decides
    if t.k == 'lit' or t.k == 'name' then
        if not B.eq(t, i) then return FAILED(ipath, (t.k == 'lit' and 'literal %s vs %s' or 'name %s vs %s'):format(B.show(t), B.show(i))) end
        return nil
    end
    if t.k ~= i.k then return FAILED(ipath, ('kind %s vs %s'):format(tostring(t.k), tostring(i.k))) end
    local tk, ik = t.kids or {}, i.kids or {}
    local nvar, first_var, has_ctx = 0, nil, false
    for j, c in ipairs(tk) do
        if is_var_width(c) then nvar = nvar + 1; first_var = first_var or j; has_ctx = has_ctx or (c.ctx and true or false) end
    end
    if nvar == 0 and #tk ~= #ik then return FAILED(ipath, #tk < #ik and ('arity: %d unmatched children'):format(#ik - #tk) or ('arity: template child %d has no counterpart'):format(#ik + 1)) end
    local upto = first_var and first_var - 1 or #tk
    for j = 1, upto do
        if ik[j] == nil then return FAILED(ipath, ('arity: template child %d has no counterpart'):format(j)) end
        local cp = choice_point(tk[j], ik[j], child(ipath, j))
        if cp then return cp end
    end
    if nvar == 0 then return nil end
    if nvar == 1 and not has_ctx then -- FORCED (join's rule); an instance-side hedge is an opaque node of width one here
        local w = #ik - (#tk - 1)
        if w < 0 then return FAILED(ipath, ('arity: template child %d has no counterpart'):format(#ik + 1)) end
        for j = first_var + 1, #tk do
            local cp = choice_point(tk[j], ik[j + w - 1], child(ipath, j + w - 1))
            if cp then return cp end
        end
        return nil
    end
    return { hole = tk[first_var], tk = tk, ik = ik, ti = first_var, ii = first_var, ipath = ipath }
end
--- every list a cursor could sit in: the slice itself (p = {}), then each element's kid list
--- and deeper, in preorder (the order the hand-built matcher uses; a context hole on the
--- instance side is descended into, as a context may contain context variables)
local function placements(slice, f)
    local r = f(slice, {})
    if r then return r end
    local function walk(e, p)
        if type(e) ~= 'table' or not e.kids or (is_hole(e) and not e.ctx) then return nil end
        local r2 = f(e.kids, p)
        if r2 then return r2 end
        for i, c in ipairs(e.kids) do
            local r3 = walk(c, child(p, i))
            if r3 then return r3 end
        end
        return nil
    end
    for i, e in ipairs(slice) do
        local r4 = walk(e, { i })
        if r4 then return r4 end
    end
    return nil
end
local function values_key(V)
    local ks = {}
    for h in pairs(V) do ks[#ks + 1] = h end
    table.sort(ks)
    local parts = {}
    for _, h in ipairs(ks) do parts[#parts + 1] = h .. '=' .. B.show(V[h]) end
    return table.concat(parts, '\1')
end
function D.match(T, I, env)
    env = env or {}
    local cap = env.cap or 20000
    local hole_domains = env.hole_domains
    local counter = env._steps or { n = 0 } -- shared with the inner filter matches, so the budget is one
    local function has_hole(t)
        if type(t) ~= 'table' then return false end
        if is_hole(t) then return true end
        for _, c in ipairs(t.kids or {}) do if has_hole(c) then return true end end
        return false
    end
    if not env._prepared and has_hole(I) then -- a template as the instance: its holes are renamed apart (they are values, never choice points), and back in the answer
        I = rename_holes(I, function(h) return Q .. h end, 'in')
        if hole_domains then
            local hd = {}
            for h, e in pairs(hole_domains) do hd[Q .. h] = e end
            hole_domains = hd
        end
    end
    local menv = { defs = env.defs, self = env.self or T, hole_domains = hole_domains }
    local H0 = D.sites(T)
    local last_refusal, all, seen = nil, {}, {}
    local BUDGET = {}
    local nid, within_of = 0, {}
    -- the applied hedge of a context must match the cursor's sub-slice on its own (the
    -- hand-built matcher matches it there before binding the context): a cheap necessary
    -- condition checked before the substitution, or the search runs the whole remainder for
    -- every placement of every context
    -- the applied hedge must match the cursor's sub-slice on its own (the hand-built matcher
    -- matches it there before binding the context). Every matcher of that inner problem is
    -- returned and each becomes part of the substitution with the context value, so the outer
    -- search never re-enumerates what the inner one settled (it did, and the work squared).
    local function hedge_matchers(kids, sub)
        if #kids == 0 then return #sub == 0 and { {} } or {} end
        local ks, domains = {}, {}
        for i, x in ipairs(kids) do ks[i] = B.copy(x) end
        for h, e in pairs(H0) do domains[h] = { domain = e.domain, origin = e.origin } end
        local inner = D.match(B.template(B.seq(ks), domains), B.seq(sub), { defs = env.defs, self = menv.self, hole_domains = hole_domains, _prepared = true, _steps = counter, cap = cap, collect = true })
        if not inner.ok then
            if inner.refusal and inner.refusal.why:find('budget', 1, true) then return 'budget' end
            return {}
        end
        local out = {}
        for i, m in ipairs(inner.all) do out[i] = m.values end
        return out
    end -- site ids in binding order, and the enclosing context of each hole (CTXCUT.md)
    local function mark_within(t, id) -- every hole inside a context's applied hedge is `within` that context's site
        if type(t) ~= 'table' then return end
        if is_hole(t) and not is_q(t.h) then within_of[t.h] = id end
        for _, c in ipairs(t.kids or {}) do mark_within(c, id) end
    end
    --- the sites read off T, I and V once every hole is bound (the third leg, CTXCUT.md): the
    --- template and the instance walked in parallel, a hedge occurrence spanning #V[h].kids
    --- positions, a context occurrence spanning the width of its plugged image and carrying
    --- the cursor record its value fixes; ids in preorder (binding order), `within` the
    --- enclosing context's id. Positional lists only: under a keyed node or a boundary the
    --- closing step's entries stand.
    local function cursor_of(v) -- the cursor's list path inside the context value, its index there
        for _, q in ipairs(B.positions(v)) do
            if q.node.k == 'cursor' then
                local ppath, idx = parent_of(q.path)
                return ppath, idx
            end
        end
    end
    local function read_sites(V, base)
        local out = {}
        for h, e in pairs(base) do out[h] = { sites = {}, domain = e.domain, rep = e.rep, ctx = e.ctx, origin = e.origin, was = e.was, presence = e.presence } end
        local function width_of_ctx(hole)
            local img = D.apply(B.template(B.seq { B.copy(hole) }), V).body
            return #(img.kids or {})
        end
        local function add(h, site) if out[h] then out[h].sites[#out[h].sites + 1] = site end end
        local function walk(t, i, ipath, enc)
            if type(t) ~= 'table' or type(i) ~= 'table' or is_hole(t) or t.k == 'embed' or t.align then return end
            local ii = 1
            for _, c in ipairs(t.kids or {}) do
                if is_hole(c) and c.rep then
                    local w = #((V[c.h] or {}).kids or {})
                    nid = nid + 1
                    add(c.h, { path = child(ipath, ii), n = w, id = nid, within = enc })
                    ii = ii + w
                elseif is_hole(c) and c.ctx then
                    local v = V[c.h]
                    local w = v and width_of_ctx(c) or 1
                    nid = nid + 1
                    local id = nid
                    local site = { path = child(ipath, ii), n = w, id = id, within = enc }
                    if v then
                        local cpath, cidx = cursor_of(v)
                        -- the cursor stands for the hedge's image: its span is the image's width
                        local himg = D.apply(B.template(B.seq((function() local ks = {}; for j, x in ipairs(c.kids or {}) do ks[j] = B.copy(x) end; return ks end)())), V).body
                        site.cursor = { path = cpath, from = cidx, n = #(himg.kids or {}) }
                        -- the hedge's own holes sit in the instance at the cursor's place: a top-level
                        -- cursor puts them in the parent list from index ii + cidx - 1, a deeper one in
                        -- the list the cursor path reaches inside the slice's element; the walk sees the
                        -- hedge as that list with padding before it, so indices are instance indices
                        local ikids, lpath, offset
                        if #cpath == 0 then
                            ikids, lpath, offset = i.kids or {}, ipath, ii - 1 + cidx - 1
                        else
                            lpath = { unpack(ipath) }
                            lpath[#lpath + 1] = ii + cpath[1] - 1
                            for q = 2, #cpath do lpath[#lpath + 1] = cpath[q] end
                            local rel = { ii + cpath[1] - 1 }
                            for q = 2, #cpath do rel[#rel + 1] = cpath[q] end
                            local L2 = B.locate_at(i, rel)
                            ikids, offset = (L2 and L2.kids) or {}, cidx - 1
                        end
                        local shifted, ishift = {}, {}
                        for j = 1, offset do shifted[j] = { k = 'pad' }; ishift[j] = { k = 'pad' } end
                        for _, x in ipairs(c.kids or {}) do shifted[#shifted + 1] = x end
                        for j = offset + 1, #ikids do ishift[#ishift + 1] = ikids[j] end
                        walk({ k = 'seq', kids = shifted }, { k = 'seq', kids = ishift }, lpath, id)
                    end
                    add(c.h, site)
                    ii = ii + w
                else
                    if is_hole(c) then
                        nid = nid + 1
                        local v = V[c.h]
                        add(c.h, { path = child(ipath, ii), n = (type(v) == 'table' and v.k == 'seq') and #v.kids or nil, id = nid, within = enc })
                    end
                    walk(c, (i.kids or {})[ii], child(ipath, ii), enc)
                    ii = ii + 1
                end
            end
        end
        walk(T.body, I, {}, nil)
        return out
    end
    local function finish(r) -- strip the renamed query holes, restore names inside values, read the sites off T, I, V
        local values = {}
        for h, v in pairs(r.values) do
            if not is_q(h) then
                -- an inner problem (the applied hedge of a context) stays in the renamed world: its
                -- bindings ride into the outer substitution; only the outermost answer is renamed back
                values[h] = env._prepared and v or rename_holes(v, function(x) return is_q(x) and x:sub(3) or x end, 'out')
            end
        end
        local base = {}
        for h, e in pairs(H0) do if not is_q(h) then base[h] = { sites = {}, domain = e.domain, rep = e.rep, ctx = e.ctx, origin = e.origin, was = e.was, presence = e.presence } end end
        for h, e in pairs(r.sites) do if not is_q(h) then base[h] = e end end
        local sites = read_sites(r.values, base)
        for h, e in pairs(base) do -- holes the walk did not reach (under a keyed node or a boundary): the closing step's entries
            if #sites[h].sites == 0 then sites[h] = e; for _, st in ipairs(e.sites) do if not st.id then nid = nid + 1; st.id = nid end end end
            if #sites[h].sites == 0 and values[h] == nil then sites[h] = nil end -- no value owed (under an absent pair): no entry, as the hand-built matcher
        end
        r.values, r.sites = values, sites
        r.provenance = B.observed(values, sites)
        return r
    end
    local function search(Tc, chosen, sites, k)
        local cp = choice_point(Tc.body, I, {})
        if cp and cp.failed then
            if TRACE then io.stderr:write(('FAIL early: %s vs %s\n'):format(B.show(Tc.body):sub(1, 160), B.show(I):sub(1, 160))) end
            counter.n = counter.n + 1
            if counter.n > cap then return BUDGET end
            last_refusal = { at = cp.at, why = cp.why }
            return nil
        end
        if not cp then
            counter.n = counter.n + 1
            if counter.n > cap then return BUDGET end
            local r = match_close(Tc, I, menv)
            if not r.ok then last_refusal = r.refusal; return nil end
            for h, v in pairs(chosen) do r.values[h] = v end
            for h, s in pairs(sites) do r.sites[h] = s end
            return k(finish(r))
        end
        local hole, tk, ik, ti, ii, ipath = cp.hole, cp.tk, cp.ik, cp.ti, cp.ii, cp.ipath
        local h = hole.h
        local fixed = 0
        for j = ti + 1, #tk do if not is_var_width(tk[j]) then fixed = fixed + 1 end end
        local maxn = #ik - ii + 1 - fixed
        local e0 = H0[h] or { domain = B.open(), origin = 'derived' }
        local function try(value, site, more)
            counter.n = counter.n + 1
            if counter.n > cap then return BUDGET end
            local ok, why
            local held = false -- a slice holding the query's own hedge variables (Skolemized): the slice rule, as in the closing step
            if hole.rep and type(value) == 'table' and value.k == 'seq' then for _, e in ipairs(value.kids) do if is_skolem_hedge(e) then held = true end end end
            if held then
                local plain, hedges = {}, {}
                for _, e in ipairs(value.kids) do
                    if is_skolem_hedge(e) then local q = e.k:sub(#HEDK + 1); hedges[#hedges + 1] = hole_domains and hole_domains[q] and hole_domains[q].domain or B.open()
                    else plain[#plain + 1] = e end
                end
                ok, why = B.admits_slice(e0.domain, plain, hedges, { defs = env.defs, self = menv.self })
            else
                ok, why = B.admits(e0.domain, value, { defs = env.defs, self = menv.self })
            end
            if not ok then last_refusal = { at = key(site.path), why = 'hole ' .. h .. ': ' .. why }; return nil end
            nid = nid + 1
            site.id, site.within = nid, within_of[h]
            if hole.ctx then for _, c in ipairs(hole.kids or {}) do mark_within(c, nid) end end -- the applied hedge's holes are within this context's site
            local sigma = {}
            for x, v in pairs(more or {}) do sigma[x] = v end -- the inner matcher's bindings ride along
            sigma[h] = value
            local T2 = D.apply(Tc, sigma) -- Kutsia's substitution step, applied to the whole problem (every occurrence of h)
            if TRACE then io.stderr:write(('TRY %s = %s\n    %s -> %s\n'):format(h, B.show(value), B.show(Tc.body), B.show(T2.body))) end
            local chosen2, sites2 = {}, {}
            for x, v in pairs(chosen) do chosen2[x] = v end
            for x, v in pairs(sites) do sites2[x] = v end
            for x, v in pairs(more or {}) do if not is_q(x) then chosen2[x] = v end end
            chosen2[h] = value
            sites2[h] = { sites = { site }, domain = e0.domain, rep = e0.rep or nil, ctx = e0.ctx or nil, origin = e0.origin, was = e0.was }
            return search(T2, chosen2, sites2, k)
        end
        if hole.ctx then
            for n = 0, maxn do
                local slice = {}
                for j = ii, ii + n - 1 do slice[#slice + 1] = ik[j] end
                local r = placements(slice, function(L, p)
                    for j1 = 1, #L + 1 do
                        for j2 = j1 - 1, #L do
                            local sub = {}
                            for j = j1, j2 do sub[#sub + 1] = L[j] end
                            local inner = hedge_matchers(hole.kids or {}, sub)
                            if inner == 'budget' then return BUDGET end
                            for _, more in ipairs(inner) do
                                local res = try(B.with_cursor(slice, p, j1, j2), { path = child(ipath, ii), n = n, cursor = { path = p, from = j1, n = j2 - j1 + 1 } }, more)
                                if res then return res end
                            end
                        end
                    end
                    return nil
                end)
                if r then return r end
            end
            return nil
        end
        for w = 0, maxn do -- Projection first, then Widening by one term (P, SVE2, W1)
            local slice = {}
            for j = ii, ii + w - 1 do slice[#slice + 1] = ik[j] end
            -- a hedge hole standing for a hedge hole is a slice of one opaque node: the hedge domain
            -- admits it element by element, as the hand-built matcher's bind does with the seq
            local res = try(B.seq(slice), { path = child(ipath, ii), n = w })
            if res then return res end
        end
        return nil
    end
    local res
    if env.collect then
        res = search(T, {}, {}, function(r)
            local kv = values_key(r.values)
            if not seen[kv] then seen[kv] = true; all[#all + 1] = { values = r.values, sites = r.sites } end
            return nil -- every matcher: keep searching
        end)
        if res == BUDGET then return { ok = false, all = all, steps = counter.n, refusal = { at = 'root', why = 'matching budget exceeded (hedge and context matching are NP-complete)' } } end
        return { ok = #all > 0, all = all, steps = counter.n, refusal = #all == 0 and last_refusal or nil }
    end
    local t_start = SLOW and os.clock()
    res = search(T, {}, {}, function(r) return r end)
    if t_start and os.clock() - t_start > SLOW then
        io.stderr:write(('SLOW %.1fs steps %d ok %s\n    T = %s\n    I = %s\n'):format(os.clock() - t_start, counter.n, tostring(res and res ~= BUDGET and true or false), B.show(T.body):sub(1, 150), B.show(I):sub(1, 150)))
    end
    if res == BUDGET then return { ok = false, refusal = { at = 'root', why = 'matching budget exceeded (hedge and context matching are NP-complete)' }, values = {}, sites = {}, steps = counter.n } end
    if res then res.steps = counter.n; return res end
    return { ok = false, refusal = last_refusal or { at = 'root', why = 'no match' }, values = {}, sites = {}, steps = counter.n }
end

-- ── the classify diff, as the join's hole sites ────────────────────────────────
function D.diff_regions(a, b, path, out)
    -- the classify diff is the FIXED-ARITY lgg: join under the 'none' rigidity (no hedge holes)
    local r = B.join(B.template(a), b, { align = 'none', positional = true })
    if not r then out[#out + 1] = path; return end
    for _, e in pairs(D.sites(r.template)) do
        for _, s in ipairs(e.sites) do out[#out + 1] = cat(path, s.path) end
    end
end

-- ── composition and the edits, through put ─────────────────────────────────────
local function edited(T, op) local T2 = B.copy(T); T2.edits[#T2.edits + 1] = op; return T2 end
local function rename_hole_names(t, ren)
    if is_hole(t) then return B.hole(ren[t.h] or t.h, t.rep) end
    if not t.kids then return B.copy(t) end
    local kids = {}
    for i, c in ipairs(t.kids) do kids[i] = rename_hole_names(c, ren) end
    return B.rebuild(t, kids)
end
function D.fill(T, h, T2)
    local ren = {}
    for _, g in ipairs(D.hole_names(T2)) do ren[g] = (T.holes[g] and g ~= h) and (h .. '.' .. g) or g end
    local body = D.apply(T, { [h] = rename_hole_names(T2.body, ren) }).body
    local domains = {}
    for g, e in pairs(T.holes) do if g ~= h then domains[g] = B.copy(e) end end
    for g, e in pairs(T2.holes) do domains[ren[g]] = B.copy(e) end
    return B.template(body, domains)
end
function D.merge(T, h1, h2)
    if not (T.holes[h1] and T.holes[h2]) then return nil, 'no such holes' end
    local T2 = edited(T, { op = 'merge', h = h1, into = h2 })
    local H = D.sites(T)
    for _, s in ipairs(H[h2].sites) do T2.body = B.put(T2.body, s.path, B.hole(h1, H[h2].rep or nil)) end
    T2.holes[h1].domain = B.meet(T2.holes[h1].domain, T2.holes[h2].domain)
    T2.holes[h2] = nil
    return T2
end
function D.split(T, h, site_index, h2)
    local H = D.sites(T)
    local s = H[h] and H[h].sites[site_index]
    if not s then return nil, 'no such site' end
    local T2 = edited(T, { op = 'split', h = h, site = site_index, new = h2 })
    T2.body = B.put(T2.body, s.path, B.hole(h2, H[h].rep or nil))
    T2.holes[h2] = { domain = B.copy(T.holes[h].domain), origin = T.holes[h].origin }
    return T2
end
function D.dig(T, path, h, domain)
    if is_hole(B.locate_at(T.body, path)) then return nil, 'already a hole' end
    local T2 = edited(T, { op = 'dig', h = h, at = key(path), path = B.copy(path), domain = domain })
    T2.body = B.put(T2.body, path, B.hole(h))
    T2.holes[h] = { domain = domain or B.open(), origin = domain and 'supplied' or 'derived' }
    local H = D.sites(T2)
    for g in pairs(T2.holes) do if not H[g] then T2.holes[g] = nil end end
    return T2
end
function D.rewrite(T, path, sub)
    local before = D.sites(T)
    local T2 = edited(T, { op = 'rewrite', h = '*', at = key(path), path = B.copy(path), sub = B.copy(sub) })
    T2.body = B.put(T2.body, path, B.copy(sub))
    local after = D.sites(T2)
    for h in pairs(before) do if not after[h] then return nil, 'rewrite would discard hole ' .. h end end
    for h in pairs(after) do if not before[h] then return nil, 'rewrite may only mention existing holes (' .. h .. ' is new)' end end
    return T2
end

-- ── generalize, as a fold of join ──────────────────────────────────────────────
function D.generalize(instances, opts)
    opts = opts or {}
    local env = opts.env or { defs = {} }
    env.defs = env.defs or {}
    local T = B.template(B.copy(instances[1]))
    local values = { {} }
    for k = 2, #instances do
        local r, why = B.join(T, instances[k], { prefix = opts.prefix or 'h', env = env,
            linear = opts.linear, grammars = opts.grammars, positional = opts.positional, align = opts.align })
        if not r then error('generalize via join: ' .. why) end
        for i = 1, k - 1 do values[i] = r.left(values[i]) end
        values[k] = r.right({})
        T = r.template
    end
    T.edits = {}
    -- join sees one fragment at a time and writes `open` for a fragment with holes inside; the
    -- fold has the whole column, so the derived domains are recomputed from it (DOMAINS.md),
    -- and the structural claims (repetition, recursion) are the same summaries generalize
    -- makes, read off the same column (HEDGEJOIN.md)
    local _, notes = B.rederive_domains(T, values, { env = env, need = opts.need, grammars = opts.grammars, split_cap = opts.split_cap })
    return { template = T, values = values, notes = notes, env = env }
end

-- ── trace, as instantiate with origin tags carried by rebuild ──────────────────

-- ★ THE CONTRACT OUR COPY GREW (CART-1360, the verb audit, 2026-10-03): the original trace's origins carry, besides
-- src / stage / hole / at, a hole occurrence's SITE (its index among the hole's sites, in preorder — CLASSIFY.md reads
-- it: classify.lua indexes touched[hole][site]) and its TPATH (the template path of that site), and an EMBED origin
-- (the string's grammar, text, spans and the inner trace's own origins). The older derivation carried none of it, so
-- DERIVE=trace failed 28 tests through classify / propagate / cascade / transplant. Rebuilt from the basis alone, the
-- original's single pass: rebuild + copy + seq + template + the grammar table (inner_template is derived here: the
-- embed's inner template with the outer domains copied in). Keyed bodies are refused, as the original refuses them.
function D.trace(T, V, env, stage)
    stage = stage or 1
    local r = D.instantiate(T, V, env)
    if not r.ok then return r end
    for h, e in pairs(D.sites(T)) do if e.ctx then return { ok = false, why = 'context hole ' .. h .. ' unsupported' } end end
    if B.has_keyed(T.body) then return { ok = false, why = 'keyed nodes unsupported by trace (positional paths)' } end
    local origins, seen = {}, {}
    local function attribute(out_path, h, v, base, site, tpath)
        for _, p in ipairs(B.positions(v)) do
            origins[key(cat(out_path, p.path))] = { src = 'hole', stage = stage, hole = h, at = cat(base, p.path), site = site, tpath = tpath }
        end
    end
    local build
    function build(t, tpath, out_path)
        if is_hole(t) then
            seen[t.h] = (seen[t.h] or 0) + 1
            attribute(out_path, t.h, V[t.h], {}, seen[t.h], tpath)
            return B.copy(V[t.h])
        end
        if t.k == 'embed' then
            local Ti, Vi = B.template(t.kids[1]), {}
            for h in pairs(Ti.holes) do
                Ti.holes[h].domain, Ti.holes[h].origin, Ti.holes[h].was = T.holes[h].domain, T.holes[h].origin, T.holes[h].was
                Vi[h] = V[h]
            end
            local inner = D.trace(Ti, Vi, env, stage)
            local text, spans = B.grammars[t.g].print(inner.term)
            origins[key(out_path)] = { src = 'embed', stage = stage, g = t.g, at = tpath, text = text, spans = spans, origins = inner.origins }
            return B.lit(text)
        end
        origins[key(out_path)] = { src = 'fixed', stage = stage, at = tpath }
        if not t.kids then return B.copy(t) end
        local kids, n = {}, 0
        for i, c in ipairs(t.kids) do
            if is_hole(c) and c.rep then
                seen[c.h] = (seen[c.h] or 0) + 1
                for j, e in ipairs(V[c.h].kids or {}) do
                    n = n + 1
                    attribute(child(out_path, n), c.h, e, { j }, seen[c.h], child(tpath, i))
                    kids[n] = B.copy(e)
                end
            else
                n = n + 1
                kids[n] = build(c, child(tpath, i), child(out_path, n))
            end
        end
        return B.rebuild(t, kids)
    end
    return { ok = true, term = build(T.body, {}, {}), origins = origins }
end

-- ── migrate_one, as the lens round trip through the edit ───────────────────────
function D.migrate_one(T, T2, op, V, env)
    if op.op == 'rewrite' then
        local W = {}
        for k, v in pairs(V) do W[k] = v end
        local r = D.instantiate(T2, W, env)
        if not r.ok then return nil, 'rewrite: does not instantiate' end
        return W
    elseif op.op == 'join' then
        local r, why = B.join(T, op.with)
        if not r then return nil, 'join: ' .. why end
        local W, err = r.left(V)
        if not W then return nil, 'join: ' .. err end
        return W
    end
    local I = D.instantiate(T, V, env)
    if not I.ok then return nil, op.op .. ' ' .. tostring(op.h) .. ': member does not instantiate' end
    local m = D.match(T2, I.term, env)
    if not m.ok then return nil, op.op .. ' ' .. tostring(op.h) .. ': ' .. m.refusal.why end
    return m.values
end

-- ── the hook ───────────────────────────────────────────────────────────────────
-- ── instance_of, as the meet being a renaming: T1 ≤ T2  iff  meet(T1, T2) ≅ T1 ───
-- the left map sends every hole of T1 to a distinct hole whose meet domain is T1's own, or a
-- pinned hole to its pin (a pin and its value are the same set of instances)
function D.instance_of(T1, T2, env)
    local r = B.unify(T1, T2, { env = env })
    if not r then return false end
    local seen = {}
    for h, e in pairs(T1.holes) do
        local t = r.left[h]
        if is_hole(t) then
            if seen[t.h] then return false end
            seen[t.h] = true
            if B.show_domain(r.template.holes[t.h].domain) ~= B.show_domain(e.domain) then return false end
        elseif not (e.domain.kind == 'closed' and B.eq(t, e.domain.value)) then return false end
    end
    return true
end

-- ── link by value and normalization (LINK.md), from equality and the derived match ─────────
local function dfamily(F) if F.body then return { template = F, values = F.values or {} } end; return F end
local function dread(v, reader, env)
    if v == nil then return nil end
    if reader == nil then return v end
    if type(reader) == 'function' then return reader(v) end
    local m = D.match(reader.template, v, env)
    if not m.ok then return nil end
    return m.values[reader.hole]
end
-- a composite key (KEYED.md "Composite keys"): a list of holes reads to a seq of the components,
-- each through its own reader (a list indexed like the holes) or one reader for all
local function dreadv(V, holes, reader, env)
    if type(holes) ~= 'table' then return dread(V[holes], reader, env) end
    local parts = {}
    for i, h in ipairs(holes) do
        local r = reader
        if type(reader) == 'table' and reader.template == nil then r = reader[i] end
        local v = dread(V[h], r, env)
        if v == nil then return nil end
        parts[i] = v
    end
    return B.seq(parts)
end
function D.primary_key(F, hole, opts)
    F = dfamily(F)
    local seen, dups = {}, {}
    for i, V in ipairs(F.values) do
        local k = dreadv(V, hole, opts and opts.read, opts and opts.env)
        if k ~= nil then
            local found = false
            for _, e in ipairs(seen) do
                if B.eq(e.key, k) then found = true; e.members[#e.members + 1] = i; if #e.members == 2 then dups[#dups + 1] = e end end
            end
            if not found then seen[#seen + 1] = { key = k, members = { i } } end
        end
    end
    return #dups == 0, dups
end
function D.link(A, B_, spec)
    A, B_ = dfamily(A), dfamily(B_)
    local env = spec.env
    local out = { from = spec.from, to = spec.to, tuples = {}, pairs = {}, dangling = {}, unreadable = { a = {}, b = {} }, ambiguity = {}, fan = 0,
        readers = { from = spec.read_from and (type(spec.read_from) == 'table' and spec.read_from.template) or nil,
                    to = spec.read_to and (type(spec.read_to) == 'table' and spec.read_to.template) or nil }, read = { from = spec.read_from, to = spec.read_to }, complete = spec.complete }
    local bkeys = {}
    for j, V in ipairs(B_.values) do
        local k = dreadv(V, spec.to, spec.read_to, env)
        if k == nil then out.unreadable.b[#out.unreadable.b + 1] = j else bkeys[#bkeys + 1] = { j = j, key = k } end
    end
    out.is_function = D.primary_key(B_, spec.to, { read = spec.read_to, env = env })
    local relatives = {}
    for i, V in ipairs(A.values) do
        local k = dreadv(V, spec.from, spec.read_from, env)
        if k == nil then out.unreadable.a[#out.unreadable.a + 1] = i
        else
            local bs = {}
            for _, e in ipairs(bkeys) do
                if B.eq(e.key, k) then bs[#bs + 1] = e.j; out.tuples[#out.tuples + 1] = { a = i, b = e.j, key = k, from = spec.from, to = spec.to } end
            end
            local rel
            for _, r in ipairs(relatives) do if B.eq(r.key, k) then rel = r end end
            if not rel then rel = { key = k, a = {}, b = bs }; relatives[#relatives + 1] = rel end
            rel.a[#rel.a + 1] = i
            if #bs == 0 then out.dangling[#out.dangling + 1] = i end
            if #bs > out.fan then out.fan = #bs end
            out.pairs[#out.pairs + 1] = { a = i, b = bs, key = k }
        end
    end
    for _, r in ipairs(relatives) do if #r.a > 1 and #r.b > 1 then out.ambiguity[#out.ambiguity + 1] = r end end
    return out
end
-- ── cascade, from the link's tuples and the derived match and instantiate (CASCADE.md) ──
local function dwrite(v, reader, new, env)
    if reader == nil then return new end
    if type(reader) == 'function' then return nil, 'a function reader has no inverse; give a {template, hole} reader' end
    local m = D.match(reader.template, v, env)
    if not m.ok then return nil, 'the old value does not read through the reader: ' .. (m.refusal and m.refusal.why or 'no match') end
    local W = {}
    for h, x in pairs(m.values) do W[h] = x end
    W[reader.hole] = new
    local r = D.instantiate(reader.template, W, env)
    if not r.ok then return nil, 'the reader does not write the new key: ' .. B.unfold_why(r) end
    return r.term
end
local function dreader_at(spec, x) if type(spec) == 'table' and spec.template == nil then return spec[x] end; return spec end
function D.cascade(L, A, B_, j, C, opts)
    opts = opts or {}
    A, B_ = dfamily(A), dfamily(B_)
    local env = opts.env
    if not L.is_function then return nil, ('cascade: %s is not a key of the referenced family (SQL-92 §11.8 syntax rule 2: the referenced columns are a unique key)'):format(B.key_name(L.to)) end
    if not C or C.kind ~= 'value' then return nil, ('cascade: the edit is %s, not a value edit; only a key value cascades'):format(tostring(C and C.kind)) end
    local tos = type(L.to) == 'table' and L.to or { L.to }
    local froms = type(L.from) == 'table' and L.from or { L.from }
    local changed = {}
    for _, c in ipairs(C.changed) do for x, h in ipairs(tos) do if h == c.h then changed[x] = c end end end
    if next(changed) == nil then return nil, ('cascade: no component of the key %s changed'):format(B.key_name(L.to)) end
    local read_to, read_from = L.read and L.read.to, L.read and L.read.from
    local oldk = dreadv(B_.values[j], L.to, read_to, env)
    local newk = dreadv(C.values, L.to, read_to, env)
    if newk == nil then return nil, 'cascade: the new key does not read through the reader' end
    for j2, V in ipairs(B_.values) do
        if j2 ~= j and B.eq(dreadv(V, L.to, read_to, env) or B.seq {}, newk) then
            return nil, ('cascade: the new key %s is already the key of member %d; the referenced key must stay unique'):format(B.show(newk), j2)
        end
    end
    local rows = {}
    for _, t in ipairs(L.tuples) do if t.b == j then rows[#rows + 1] = t.a end end
    local newparts = type(L.to) == 'table' and newk.kids or { newk }
    local values, widened, T = {}, {}, A.template
    for _, a in ipairs(rows) do
        local W = {}
        for h, v in pairs(A.values[a]) do W[h] = v end
        for x in pairs(changed) do
            local nv, why = dwrite(W[froms[x]], dreader_at(read_from, x), newparts[x], env)
            if nv == nil then return nil, ('cascade: member %d of the referencing family, hole %s: %s'):format(a, froms[x], why) end
            W[froms[x]] = nv
        end
        local r = D.instantiate(T, W, env)
        if not r.ok and #r.rejected > 0 then
            for _, x in ipairs(r.rejected) do
                local h = x:match('^([^:]+):')
                if not T.holes[h] or T.holes[h].origin == 'supplied' then return nil, ('cascade: member %d: a supplied domain refuses the new key: %s'):format(a, x) end
                if T == A.template then T = B.copy(T) end
                local from = B.show_domain(T.holes[h].domain)
                T.holes[h].domain = B.widen(T.holes[h].domain, W[h])
                widened[#widened + 1] = { h = h, member = a, from = from, to = B.show_domain(T.holes[h].domain) }
            end
            r = D.instantiate(T, W, env)
        end
        if not r.ok then return nil, ('cascade: member %d does not instantiate with the new key: %s'):format(a, B.unfold_why(r)) end
        values[a] = W
    end
    return { key = { from = oldk, to = newk }, rows = rows, values = values, template = T, widened = widened,
        preview = function(a) return D.instantiate(T, values[a], env).term end,
        commit = function(members)
            local set = {}
            for _, a in ipairs(members or rows) do set[a] = true end
            local new = {}
            for a, V in ipairs(A.values) do new[a] = (set[a] and values[a]) and values[a] or V end
            return new
        end }
end
function D.cascade_delete(L, j)
    local rows = {}
    for _, t in ipairs(L.tuples) do if t.b == j then rows[#rows + 1] = t.a end end
    return { rows = rows, why = #rows > 0 and ('%d matching row(s) of the referencing family would dangle'):format(#rows) or 'no matching row' }
end
function D.normalize(F, hole, T_elem, opts)
    F = dfamily(F); opts = opts or {}
    local key, rows, unmatched, values = opts.key, {}, {}, {}
    local keys = type(key) == 'table' and key or (key and { key } or {})
    for i, V in ipairs(F.values) do
        local col = V[hole]
        if type(col) ~= 'table' or col.k ~= 'seq' then return nil, ('normalize: hole %s of member %d is not a sequence (a simple domain needs no normalization)'):format(hole, i) end
        for _, k in ipairs(keys) do
            local kv = V[k]
            if kv == nil then return nil, ('normalize: member %d has no value for the key %s'):format(i, k) end
            if type(kv) == 'table' and kv.k == 'seq' then return nil, ('normalize: the key %s is nonsimple (Codd 1970 §1.4, condition 2)'):format(k) end
        end
        for k2, e in ipairs(col.kids) do
            local m = D.match(T_elem, e, opts.env)
            if m.ok then
                local row = {}
                for h, v in pairs(m.values) do row[h] = v end
                for _, k in ipairs(keys) do
                    if row[k] ~= nil then return nil, ('normalize: the element template already has a hole named %s'):format(k) end
                    row[k] = B.copy(V[k])
                end
                values[#values + 1] = row
                rows[#rows + 1] = { parent = i, index = k2, sites = m.sites }
            else unmatched[#unmatched + 1] = { parent = i, index = k2, why = m.refusal and m.refusal.why } end
        end
    end
    return { template = T_elem, values = values, rows = rows, key = key, from = { hole = hole }, unmatched = unmatched }
end


-- ── hunks, as the join of the two unfoldings read at its sites (SURGERY.md) ───────────
-- The surgery between a member before and after an edit is the difference between two
-- unfoldings, and the algebra's difference analysis is join: join(before, after) has a hole
-- wherever the two differ (a hedge where the arity does, by the identical-ends rule), and
-- the derived match reads each hole's site in either unfolding. A hunk is a site's span on
-- the left replaced by the same site's span on the right. Attribution through trace.
local function site_span(S, parent_of_site, site)
    -- a term site is one position; a hedge site is `n` kids of its parent from the index
    -- the path ends in, an empty one the point before the next kid
    if site.n == nil then local s = S[key(site.path)]; return s.from, s.to end
    local par, idx = parent_of_site(site.path)
    if site.n > 0 then return S[key(child(par, idx))].from, S[key(child(par, idx + site.n - 1))].to end
    local from = idx > 1 and S[key(child(par, idx - 1))].to + 1 or S[key(par)].from
    return from, from - 1
end
function D.hunks(T, V, T2, V2, env)
    T2 = T2 or T; V2 = V2 or V
    local a = D.trace(T, V, env); if not a.ok then return nil, 'before: ' .. B.unfold_why(a) end
    local b = D.trace(T2, V2, env); if not b.ok then return nil, 'after: ' .. B.unfold_why(b) end
    local I1, I2 = a.term, b.term
    local S1, X1 = B.spans(I1)
    local S2, X2 = B.spans(I2)
    local J = B.join(B.template(I1), I2, { env = env })
    if not J then return nil, 'the two unfoldings do not join' end
    local m1, m2 = D.match(J.template, I1, env), D.match(J.template, I2, env)
    if not (m1.ok and m2.ok) then return nil, 'the join does not match its own sides' end
    local n1 = #(T.edits or {})
    local function hole_on(body, path)
        local t = body
        if is_hole(t) then return t.h end
        for _, s in ipairs(path) do t = t.kids and t.kids[s]; if not t then return nil end; if is_hole(t) then return t.h end end
    end
    local out = {}
    for h in pairs(J.template.holes) do
        local s1, s2 = m1.sites[h], m2.sites[h]
        s1 = s1 and (s1.sites or s1) or {}; s2 = s2 and (s2.sites or s2) or {}
        for k = 1, math.max(#s1, #s2) do
            local from, to = site_span(S1, parent_of, s1[k])
            local nfrom, nto = site_span(S2, parent_of, s2[k])
            local hk = { from = from, to = to, old = X1:sub(from, to), new = X2:sub(nfrom, nto), at = s1[k].path, at2 = s2[k].path }
            if s1[k].n ~= nil then -- a hedge site: a list hunk over the parent's kids, as refine_hunks writes it
                local par1, idx1 = parent_of(s1[k].path)
                local par2, idx2 = parent_of(s2[k].path)
                hk.at, hk.at2 = par1, par2
                hk.kids, hk.kids2 = { idx1, idx1 + s1[k].n - 1 }, { idx2, idx2 + s2[k].n - 1 }
            end
            local o1 = to >= from and a.origins[key(s1[k].n and child(parent_of(s1[k].path), select(2, parent_of(s1[k].path))) or s1[k].path)] or nil
            local o2 = nto >= nfrom and b.origins[key(s2[k].n and child(parent_of(s2[k].path), select(2, parent_of(s2[k].path))) or s2[k].path)] or nil
            local hole = (o1 and o1.src == 'hole' and o1.hole) or (o2 and o2.src == 'hole' and o2.hole)
            local before = o1 and o1.src == 'fixed' and o1.at or nil
            local after = o2 and o2.src == 'fixed' and o2.at or nil -- T2's coordinates, where the edits' paths live
            if not hole and (after or before) then hole = hole_on(T2.body, after or before) or (before and hole_on(T.body, before)) or nil end
            if hole then hk.src = 'value'; hk.hole = hole elseif after or before then hk.src = 'template' else hk.src = 'unknown' end
            if after or before then for e = n1 + 1, #(T2.edits or {}) do local op = T2.edits[e]; if op.path and is_prefix(op.path, after or before) then hk.edit = e end end end
            out[#out + 1] = hk
        end
    end
    table.sort(out, function(x, y) return x.from < y.from end)
    return out, X2
end
-- ── classify, as the join of the two instances read at its sites (CLASSIFY.md) ──────────
-- The hand-built classify reads the LCS hunks between a member's unfolding and the edited
-- instance through trace's origins (`classify_over` is that core, in the basis as the edit
-- calculus's reading of attributed regions). The derived form feeds it the derived hunks,
-- join read at its sites, and the derived trace; the derived trace carries no site index, so
-- the store law over a non-linear hole reads the site from the hole's sites in preorder.
-- ── extract, from the sites and the lens (LOOP.md) ──────────────────────────────
-- the helper is the body with each hole's lift site put to the destination's replacement,
-- deepest first; the call template is the lifted arguments in parameter order, carrying the
-- template's own holes, so a member's call is instantiate with the same values
local function reindent(t, by)
    if by == nil or by == '' then return t end
    local function go(x, inside)
        if type(x) ~= 'table' then return x end
        if x.k == 'lit' then
            if inside or type(x.v) ~= 'string' or not x.v:find('\n', 1, true) then return x end
            return B.lit((x.v:gsub('\n', '\n' .. by)))
        end
        if is_hole(x) or not x.kids then return x end
        local kids = {}
        local inner = inside or x.k == 'string' or x.k == 'comment'
        for i, c in ipairs(x.kids) do kids[i] = go(c, inner) end
        return B.rebuild(x, kids)
    end
    return go(t, false)
end
D.reindent = reindent
function D.extract(T, opts)
    opts = opts or {}
    local rules = B.EXTRACT_RULES[opts.lang or 'lua']
    if not rules then return nil, 'extract: no lift rules for ' .. tostring(opts.lang) end
    local name = opts.name or 'extracted'
    if T.body.k ~= 'function_definition' then return nil, 'extract: the template is a ' .. tostring(T.body.k) .. ', not a function_definition' end
    local S, order = D.sites(T), D.hole_names(T)
    local lifts, params = {}, {}
    for i, h in ipairs(order) do
        local e = S[h]
        if e.rep then return nil, 'extract: hole ' .. h .. ' is a hedge; a sequence is not one value' end
        if e.ctx then return nil, 'extract: hole ' .. h .. ' is a context hole' end
        local p = (opts.params and opts.params[h]) or ('p' .. i)
        params[#params + 1] = { hole = h, param = p }
        local arg_shown
        for _, site in ipairs(e.sites) do
            local anc, idx = {}, {}
            for d = #site.path - 1, 0, -1 do anc[#anc + 1] = B.locate_at(T.body, { unpack(site.path, 1, d) }); idx[#idx + 1] = site.path[d + 1] end
            local hit, rname
            for rn, r in pairs(rules) do if not r.refuse and r.test(anc, idx) then hit, rname = r, rn end end
            if not hit then for rn, r in pairs(rules) do if r.refuse and r.test(anc, idx) then hit, rname = r, rn end end end
            if not hit then return nil, ('extract: hole %s at %s: no lift rule for a %s'):format(h, key(site.path), tostring(anc[1] and anc[1].k)) end
            if hit.refuse then return nil, ('extract: hole %s at %s %s'):format(h, key(site.path), hit.refuse) end
            local at = { unpack(site.path, 1, #site.path - hit.depth) }
            local arg = hit.arg(anc[hit.depth], h)
            if arg_shown and arg_shown ~= B.show(arg) then return nil, ('extract: hole %s is lifted two ways (%s / %s)'):format(h, arg_shown, B.show(arg)) end
            arg_shown = B.show(arg)
            lifts[#lifts + 1] = { hole = h, param = p, at = at, rule = rname, arg = arg, lift = hit }
        end
    end
    table.sort(lifts, function(a, b) if #a.at ~= #b.at then return #a.at > #b.at end; return key(a.at) > key(b.at) end)
    local body = B.copy(T.body)
    for _, l in ipairs(lifts) do
        l.replace = l.lift.replace(B.locate_at(body, l.at), l.param); l.lift = nil
        body = B.put(body, l.at, B.copy(l.replace))
    end
    body = reindent(body, opts.reindent)
    local ind = opts.indent or ''
    local pk, ak = { B.lit '(' }, { B.lit '(' }
    local by_hole = {}
    for _, l in ipairs(lifts) do by_hole[l.hole] = l.arg end
    for i, pr in ipairs(params) do
        if i > 1 then pk[#pk + 1] = B.lit ','; pk[#pk + 1] = B.lit ' '; ak[#ak + 1] = B.lit ','; ak[#ak + 1] = B.lit ' ' end
        pk[#pk + 1] = B.node('identifier', B.lit(pr.param))
        ak[#ak + 1] = B.copy(by_hole[pr.hole])
    end
    pk[#pk + 1] = B.lit ')'; ak[#ak + 1] = B.lit ')'
    local helper = B.node('function_declaration', B.lit 'local', B.lit ' ', B.lit 'function', B.lit ' ', B.node('identifier', B.lit(name)),
        B.node('parameters', unpack(pk)), B.lit('\n' .. ind .. '    '),
        B.node('block', B.node('return_statement', B.lit 'return', B.lit ' ', B.node('expression_list', body))), B.lit('\n' .. ind), B.lit 'end')
    local call = B.template(B.node('function_call', B.node('identifier', B.lit(name)), B.node('arguments', unpack(ak))), T.holes)
    local CS = D.sites(call)
    for _, h in ipairs(order) do if not CS[h] or #CS[h].sites ~= 1 then return nil, 'extract: hole ' .. h .. ' is not passed exactly once' end end
    for h in pairs(CS) do if not S[h] then return nil, 'extract: the call mentions a hole the template lacks: ' .. h end end
    return { helper = helper, call = call, params = params, lifts = lifts, name = name, from = T }
end
function D.extract_call(X, V, env)
    for _, pr in ipairs(X.params) do
        local v = V[pr.hole]
        if v == nil then return { ok = false, absence = 'absent', why = 'extract_call: no value for hole ' .. pr.hole } end
        if v.k ~= 'lit' then return { ok = false, absence = 'refused', why = ('extract_call: hole %s: the value %s is not a literal; the call would evaluate it where the callback was written'):format(pr.hole, B.show(v)) } end
    end
    local r = D.instantiate(X.call, V, env)
    if not r.ok then return { ok = false, absence = B.absence_of(r).absence, why = 'extract_call: ' .. B.unfold_why(r) } end
    local m = D.match(X.call, r.term, env)
    if not m.ok then return { ok = false, absence = 'refused', why = 'extract_call: the reader does not verify the writer: ' .. m.refusal.why } end
    for _, pr in ipairs(X.params) do
        if not B.eq(m.values[pr.hole], V[pr.hole]) then return { ok = false, absence = 'refused', why = 'extract_call: the reader reads back a different value at ' .. pr.hole } end
    end
    return { ok = true, term = r.term, verified = true }
end
function D.extract_call_of(X, t, env)
    local m = D.match(X.call, t, env)
    if not m.ok then return nil, m.refusal and m.refusal.why or 'not a call of ' .. X.name end
    return m.values
end

-- ── resolve, from the calculus (RESOLVE.md's source, Fig. 3 with Fig. 19's seen scopes) ──
-- the derivations of S ↣ x^D enumerated by rules N, T, P, I, R over the graph's data, the
-- seen-imports set of rule X and the seen-scopes set of the primed calculus as data; rule R's
-- well-formedness is `match` against the path language P*·I*·D as a template; rule V is the
-- preference primitive under Fig. 2's order. Not Fig. 18: the environments and ◁ are the
-- paper's algorithm, this is the definition it is proved equivalent to.
local WF_PATH
local function path_term(p)
    local ks = {}
    for i, st in ipairs(p) do
        if st.k == 'D' then ks[i] = B.node('D', B.lit(tostring(st.decl)))
        elseif st.k == 'I' then ks[i] = B.node('I', B.lit(tostring(st.ref)))
        else ks[i] = B.node('P') end
    end
    return B.node('path', unpack(ks))
end
local function extend(path, step) local p = {}; for _, s in ipairs(path) do p[#p + 1] = s end; p[#p + 1] = step; return p end
function D.resolve(G, ref, seen_imports, memo)
    WF_PATH = WF_PATH or B.template(B.node('path', B.hole('ps', true), B.hole('is', true), B.node('D', B.hole 'd')), { ps = B.rep(B.kinds { 'P' }), is = B.rep(B.kinds { 'I' }) })
    memo = memo or {} -- one top-level call's cache, never the graph's
    local R = G.refs[ref]
    local I = {}
    for k in pairs(seen_imports or {}) do I[k] = true end
    I[ref] = true -- rule X
    local ikeys = {}
    for k in pairs(I) do ikeys[#ikeys + 1] = k end
    table.sort(ikeys)
    local mk = ref .. '|' .. table.concat(ikeys, ',')
    if memo[mk] then return memo[mk] end
    local reached = {}
    local function walk(S, seen, path)
        if seen[S] then return end -- Fig. 19: a scope is not revisited on one derivation
        local seen2 = {}
        for k in pairs(seen) do seen2[k] = true end
        seen2[S] = true
        for _, d in ipairs(G.scopes[S].decls[R.name] or {}) do reached[#reached + 1] = { decl = d.id, path = extend(path, { k = 'D', decl = d.id }) } end -- rule R
        local P = G.scopes[S].parent
        if P then walk(P, seen2, extend(path, { k = 'P' })) end -- rule P
        for _, imp in ipairs(G.scopes[S].imports) do -- rule I: an import outside the seen set, resolved with rule X's larger set
            if not I[imp.ref] then
                local sub = D.resolve(G, imp.ref, I, memo)
                for _, e in ipairs(sub.entries) do
                    local d = G.decls[e.decl]
                    if d.assoc then walk(d.assoc, seen2, extend(path, { k = 'I', ref = imp.ref, decl = d.id, kind = imp.kind })) end
                end
            end
        end
    end
    walk(R.scope, {}, {})
    local wf = {}
    for _, e in ipairs(reached) do if D.match(WF_PATH, path_term(e.path)).ok then wf[#wf + 1] = e end end -- rule R's WF through the derived match
    local keep = B.best(wf, B.lex_order({ D = 1, I = 2, P = 3 }, function(e) return e.path end)) -- rule V
    local out = { ref = ref, entries = keep, ambiguous = #keep > 1, absent = #keep == 0 }
    memo[mk] = out
    return out
end

-- ── destinations, from the preference primitive and set arithmetic (DESTINATION.md) ──────
local function set_count(S) local n = 0; for _ in pairs(S) do n = n + 1 end; return n end
local function set_list(S) local r = {}; for k in pairs(S) do r[#r + 1] = k end; table.sort(r); return r end
local function jaccard(A_, B_)
    local u, i = {}, 0
    for k in pairs(A_) do u[k] = true; if B_[k] then i = i + 1 end end
    for k in pairs(B_) do u[k] = true end
    local n = set_count(u)
    if n == 0 then return 0 end
    return 1 - i / n
end
function D.destinations(m, homes, opts)
    opts = opts or {}
    local helper_cost, call_extra = opts.helper_cost or 1, opts.call_extra or 1
    local lib = (B.SCOPE_RULES[opts.lang or 'lua'] or {}).library or {}
    local ent = {}
    for k in pairs(m.entities or {}) do if not lib[k] then ent[k] = true end end
    local out = { candidates = {}, suggested = {}, by_price = {} }
    if m.assigns and next(m.assigns) then out.refused_all = 'the text assigns an outer name (' .. table.concat(set_list(m.assigns), ', ') .. '): quality precondition 1' end
    for _, h in ipairs(homes) do
        local acc = 0
        for k in pairs(ent) do if (h.entities or {})[k] then acc = acc + 1 end end
        if acc > 0 or opts.all then
            local S = h.entities or {}
            if h.holds then S = {}; for k in pairs(h.entities or {}) do if k ~= m.name then S[k] = true end end end
            local c = { id = h.id, acc = acc, distance = jaccard(ent, S), provenance = acc > 0 and 'paper' or 'prototype', cost = helper_cost * (h.copies or 1), copies = h.copies or 1, why = {} }
            if m.name and (h.bound or {})[m.name] then c.why[#c.why + 1] = ('a local %s is already bound at %s'):format(m.name, h.id) end
            local unbound = {}
            for k in pairs(m.free or {}) do if not lib[k] and not (h.bound or {})[k] then unbound[#unbound + 1] = k end end
            table.sort(unbound)
            if #unbound > 0 then
                if opts.parameterize then c.parameterized = unbound; c.cost = c.cost + #unbound * call_extra * #(m.calls or {})
                else c.why[#c.why + 1] = ('%s not bound at %s'):format(table.concat(unbound, ', '), h.id) end
            end
            local reach = h.reach or { [h.id] = true }
            local far = {}
            for _, call in ipairs(m.calls or {}) do if not reach[call.home] then far[call.home] = true end end
            if next(far) then
                if h.plumbing then c.cost = c.cost + h.plumbing; c.after_plumbing = set_list(far)
                else c.why[#c.why + 1] = ('not visible from the call in %s'):format(table.concat(set_list(far), ', ')) end
            end
            if out.refused_all then c.why[#c.why + 1] = out.refused_all end
            c.ok = #c.why == 0
            out.candidates[#out.candidates + 1] = c
        end
    end
    local paper = B.then_(B.by(function(c) return c.acc end, true), B.by(function(c) return c.distance end))
    local price = B.by(function(c) return c.cost end)
    table.sort(out.candidates, function(a, b) if paper(a, b) then return true end; if paper(b, a) then return false end; return a.id < b.id end)
    out.suggested = B.best(out.candidates, paper)
    table.sort(out.suggested, function(a, b) return a.id < b.id end)
    for _, c in ipairs(out.candidates) do if c.ok then out.by_price[#out.by_price + 1] = c end end
    table.sort(out.by_price, function(a, b) if price(a, b) then return true end; if price(b, a) then return false end; return a.id < b.id end)
    out.cheapest = B.best(out.candidates, price)
    return out
end

function D.classify(T, V, I2, env)
    local H = D.sites(T)
    for h, e in pairs(H) do if e.ctx then return { kind = 'unsupported', why = 'hole ' .. h .. ' is a context hole' } end end
    if B.has_keyed(T.body) or B.has_keyed(I2) then return { kind = 'unsupported', why = 'keyed nodes: classify reads positional regions (KEYED.md)' } end
    local r1 = D.trace(T, V, env)
    if not r1.ok then return nil, 'V does not instantiate T' end
    if B.eq(r1.term, I2) then return { kind = 'none', template = T, values = V } end
    -- the site index from preorder: the k-th position carrying hole h whose relative path is a
    -- value root (empty, or a first element) opens site k
    local count = {}
    for _, p in ipairs(B.positions(r1.term)) do
        local o = r1.origins[key(p.path)]
        if o and o.src == 'hole' then
            local opens = H[o.hole].rep and (#o.at == 1 and o.at[1] == 1) or (not H[o.hole].rep and #o.at == 0)
            if opens then count[o.hole] = (count[o.hole] or 0) + 1 end
            o.site = count[o.hole] or 1
            o.tpath = o.tpath or (H[o.hole].sites[o.site] or H[o.hole].sites[1] or {}).path
        end
    end
    local hunks = D.hunks(T, V, B.template(I2), {}, env)
    if not hunks then return { kind = 'straddle', why = 'the two instances do not join' } end
    return B.classify_over(T, V, I2, hunks, r1, env)
end
-- ── the KV FAMILY over the kv lens (CART-1379): equality is the term algebra's (a keyed node is a set of pairs by
-- key; a merge-keyed list a set of elements by key), and the generalization is generalize under the fixed-arity rigidity
-- (a list of differing length is ONE hole, kv's rule), decoded into kv's record ─────────────────────────────────────
function D.kv_eq(x, y) return B.eq(B.kv_term(x), B.kv_term(y)) end
function D.kv_eq_keyed(x, y, keyfield)
    keyfield = keyfield or 'name'
    return B.eq(B.kv_term(x, { keyfield = keyfield }), B.kv_term(y, { keyfield = keyfield }))
end
-- ⚠ EXACT ONLY VIA THE HAND-WRITTEN generalize until CART-1395: D.generalize gives a member absent under a presence hole a
-- neighbour's value (6 of 49 jenkins-infra families differ), and DERIVE=kv_generalize stays green because no spec reads
-- such a value vector — the gate cannot see it.
function D.kv_generalize(instances, opts)
    opts = opts or {}
    local keyfield = opts.keyfield or 'name'
    return B.kv_template(D.generalize(B.kv_terms(instances, { keyfield = keyfield }), { align = 'none' }), instances, { keyfield = keyfield })
end
D.OPERATORS = { 'sites', 'apply', 'instantiate', 'values_at', 'abstract', 'locate', 'match', 'diff_regions',
    'fill', 'merge', 'split', 'dig', 'rewrite', 'generalize', 'trace', 'migrate_one', 'instance_of', 'primary_key', 'link', 'normalize', 'hunks', 'classify', 'cascade', 'cascade_delete', 'extract', 'extract_call', 'extract_call_of', 'resolve', 'destinations',
    'kv_eq', 'kv_eq_keyed', 'kv_generalize' }
function D.apply_to(M, which)
    B = setmetatable({}, { __index = function(_, k) error('derive.lua: `' .. tostring(k) .. '` is not in the basis', 2) end })
    for _, k in ipairs(ALLOWED) do rawset(B, k, M[k]) end
    local ops = {}
    if which == 'all' then ops = D.OPERATORS else for w in which:gmatch('[^,]+') do ops[#ops + 1] = w end end
    for _, op in ipairs(ops) do
        assert(D[op], 'no derivation for ' .. op)
        M[op] = D[op]
    end
    return ops
end
D.apply = D.apply -- the term-level apply (substitution) keeps its name; the hook is apply_to
return D
