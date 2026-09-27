-- xmpppeer — THE XMPP IQ ADAPTER of the peer generator (CART-1138): an ejabberd tree -> a peergen model.
-- @langs erlang
--
-- The server's EXTERNAL choices, read as the client's POSSIBILITIES:
--   DISPATCH  every registered IQ endpoint (xmppserver.endpoints): (component, namespace) -> handler. The namespace
--             names an operation; the COMPONENT is chosen by the address (`to`), not by the caller — so a namespace
--             several handlers serve (disco#info: mod_disco local and sm, mod_muc, mod_pubsub, …) is ONE operation
--             whose candidates the destination discriminates.
--   ACCEPT    each clause head of a handler as a request TEMPLATE (erlterms.pattern under the module's records):
--             a named variable is a PARAMETER; the whole-request alias is not; the envelope the server or the
--             transport stamps (id, from, xml:lang) is a transport hole; a wildcard field takes the record's
--             declared default (what the decoder gives an absent one); a repeated variable is one parameter.
--   CONTRACT  the filled template against EVERY earlier clause (erlterms.clause_verdicts): reachable (every earlier
--             one says no), maybe (one cannot decide), shadowed (an earlier one takes it: not emitted).
--   REPLIES   the handler run on the template (erlterms.call): one case per alternative (S.alts), a hole named by a
--             parameter echoes the input, the others are outputs, named by position.
local M = {}
local unpack = table.unpack or unpack

local function A() return assert(require('cartograph.algebra').load()) end

-- the envelope a transport stamps: never the caller's to give (the same rule xmppmerge's decode follows)
M.ENVELOPE = { id = true, from = true, lang = true }

-- an operation's name from its namespace: the last segment, with the one before it when the last is a version
-- (urn:xmpp:mam:2 -> mam_2, http://jabber.org/protocol/disco#info -> disco_info)
local function short(uri)
    local s = tostring(uri):gsub('[#/:%.]+$', '')
    local segs = {}
    for seg in s:gmatch('[^/:]+') do segs[#segs + 1] = seg end
    local last = segs[#segs] or s
    if last:match('^[%d%.]+$') and segs[#segs - 1] then last = segs[#segs - 1] .. '_' .. last end
    return (last:gsub('#', '_'):gsub('[^%w_]', '_'):lower())
end

local function copy(t, kids)
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    o.kids = kids
    return o
end

--- the model of `root` (an ejabberd checkout). opts = { spec (xmpp_codec.spec), otp (the runtime's source root),
--- data (an extraction of root, optional) } -> model, stats, index (op name -> candidates, for a transport)
function M.model(root, opts)
    opts = opts or {}
    local a = A()
    local ts = require 'cartograph.providers.treesitter'
    local X = require 'cartograph.xmppserver'
    local ET = require 'cartograph.erlterms'
    local ER = require 'cartograph.erlrecords'
    local data = opts.data or ts.extract(root)
    local endpoints = X.endpoints(data)
    local xmpp = opts.spec and vim.fn.fnamemodify(opts.spec, ':h:h') or vim.fn.expand('~/git/xmpp')
    local E = ER.new { include_dirs = { root .. '/include' }, apps = { xmpp = xmpp } }
    local P = X.program(root .. '/src', E, { otp = opts.otp })
    local stats = { endpoints = #endpoints, handlers = 0, clauses = 0, not_iq = 0, no_source = 0, reachable = 0,
        maybe = 0, shadowed = 0, ops = 0, cases = 0, capped = 0, never_returns = 0 }
    local groups, seen_handler = {}, {}
    for _, e in ipairs(endpoints) do
        local hkey = tostring(e.mod) .. ':' .. tostring(e.fn) .. '@' .. tostring(e.uri) .. '@' .. tostring(e.component)
        if e.handler and e.uri and e.mod and e.fn and not seen_handler[hkey] then
            seen_handler[hkey] = true
            local m = P:module(e.mod)
            -- the handler's arity: 1 (IQ), else the one whose head destructures an #iq
            local key, clauses
            for k, cls in pairs(m and m.fns or {}) do
                local nm, ar = k:match('^(.+)/(%d+)$')
                if nm == e.fn and (not key or tonumber(ar) == 1) then key, clauses = k, cls end
            end
            if not clauses then stats.no_source = stats.no_source + 1
            else
                stats.handlers = stats.handlers + 1
                local arity = tonumber(key:match('/(%d+)$'))
                for k, cl in ipairs(clauses) do
                    stats.clauses = stats.clauses + 1
                    local heads = {}
                    for c in (cl:field('args')[1] or cl):iter_children() do if c:named() then heads[#heads + 1] = c end end
                    local ai = arity
                    for i, h in ipairs(heads) do
                        if vim.treesitter.get_node_text(h, m.src):find('#iq', 1, true) then ai = i; break end
                    end
                    local S = ET.session()
                    local env = { src = m.src, ctx = m.ctx, vars = {} }
                    local pat, binds = ET.pattern(heads[ai], env, S)
                    -- a head that takes ANY request (`process_local_iq(IQ)`: the shape is decided inside) is the
                    -- generic iq: every field the caller's or the transport's
                    local generic = false
                    if pat.k == 'hole' and m.ctx.record_fields and m.ctx.record_fields('iq') then
                        local kids = {}
                        for fi in ipairs(m.ctx.record_fields('iq')) do kids[fi] = a.hole('w' .. fi) end
                        pat, binds, generic = a.node('rec:iq', unpack(kids)), {}, true
                        local names = m.ctx.record_fields('iq')
                        for fi, f in ipairs(names) do
                            if f == 'type' then binds.Type = kids[fi]
                            elseif f == 'to' then binds.To = kids[fi]
                            elseif f == 'sub_els' then binds.SubEls = kids[fi] end
                        end
                    end
                    if pat.k ~= 'rec:iq' then stats.not_iq = stats.not_iq + 1
                    else
                        if generic then stats.generic = (stats.generic or 0) + 1 end
                        -- the variable each leaf hole is (a repeated variable is ONE hole: one parameter)
                        local var_of = {}
                        for nm, t in pairs(binds) do if t.k == 'hole' then var_of[t.h] = nm end end
                        local params = {}
                        -- the retry: which wildcards (by their order in the head) become parameters, not defaults
                        local wild_params, wild_seen = nil, 0
                        local function build(t, rec, field, top)
                            -- the envelope is the transport's whatever the head destructures in it (a handler reading
                            -- #iq{from = #jid{lserver = S}} reads what the server stamped); the destination `to` is
                            -- the caller's, as a whole jid (a constraint the head puts on it is in the op's doc)
                            if top and M.ENVELOPE[field] then return a.hole('@' .. field) end
                            if top and field == 'to' and t.k ~= 'hole' then params.To = true; return a.hole('To') end
                            if t.k == 'hole' then
                                local nm = var_of[t.h]
                                if nm then params[nm] = true; return a.hole(nm, t.rep) end
                                -- a wildcard: the field's declared default (an absent field decodes to it)
                                if top and field == 'to' then params.To = true; return a.hole('To') end
                                if top and field == 'type' then params.Type = true; return a.hole('Type') end
                                if t.rep then return nil end
                                wild_seen = wild_seen + 1
                                if wild_params and field and (wild_params == true or wild_params == wild_seen) then
                                    -- named by its field (Node, Items …); a clash takes a suffix
                                    local nm = field:sub(1, 1):upper() .. field:sub(2)
                                    local n2, j = nm, 1
                                    while params[n2] and params[n2] ~= field do j = j + 1; n2 = nm .. j end
                                    params[n2] = field
                                    return a.hole(n2)
                                end
                                local defs = rec and m.ctx.defaults and m.ctx.defaults(rec)
                                if defs and field then return ET.default_term(defs[field], S) end
                                return a.lit('undefined')
                            end
                            if not t.kids then return t end
                            local r = t.k:match('^rec:(.+)$')
                            local names = r and m.ctx.record_fields and m.ctx.record_fields(r)
                            local kids = {}
                            for i, c in ipairs(t.kids) do
                                local v = build(c, r, names and names[i], r == 'iq' and top)
                                if v then kids[#kids + 1] = v end
                            end
                            return copy(t, kids)
                        end
                        -- the CONTRACT: this clause must be the first a request of this shape reaches
                        local req, args, reach
                        local function contract()
                            wild_seen = 0
                            req = build(pat, nil, nil, true)
                            args = {}
                            for i = 1, arity do args[i] = i == ai and req or a.hole('Arg' .. i) end
                            local vs = ET.clause_verdicts(P, e.mod, e.fn, args, S) or {}
                            reach = vs[k] == 'no' and 'shadowed' or (vs[k] == 'maybe' and 'maybe' or 'reachable')
                            for j = 1, k - 1 do
                                if vs[j] == 'yes' then reach = 'shadowed'; break end
                                if vs[j] == 'maybe' and reach == 'reachable' then reach = 'maybe' end
                            end
                        end
                        contract()
                        -- ★ A DEFAULT CAN SHADOW: filling a wildcard with its default (#disco_info{} -> node = <<>>)
                        -- makes the request an EARLIER clause's (mod_muc: node = <<"">> is #2), and #3 unreachable.
                        -- Retried with the wildcards as parameters: the caller then chooses a value the earlier head
                        -- does not take, and the op says it only maybe reaches this clause.
                        local widened = false
                        if reach == 'shadowed' then
                            -- ONE wildcard at a time first (the fewest new parameters), then all of them
                            local n_wild = wild_seen
                            for w = 1, n_wild do
                                params, wild_params = {}, w
                                contract()
                                if reach ~= 'shadowed' then break end
                            end
                            if reach == 'shadowed' then params, wild_params = {}, true; contract() end
                            wild_params = nil
                            widened = reach ~= 'shadowed'
                            if widened then stats.widened = (stats.widened or 0) + 1 end
                        end
                        stats[reach] = stats[reach] + 1
                        local plist = {}
                        for p in pairs(params) do plist[#plist + 1] = p end
                        table.sort(plist)
                        if reach ~= 'shadowed' then
                            -- the REPLIES: the handler on the template
                            local t = ET.call(P, e.mod, e.fn, args, S)
                            local alts = t.k == 'hole' and S.alts[t.h] or nil
                            local cases = alts or { t }
                            if alts and #alts >= ET.MAX_ALTS then stats.capped = stats.capped + 1 end
                            local ty = req.kids and req.kids[2]
                            local tyname = ty and ty.k == 'lit' and tostring(ty.v) or 'any'
                            local gk = tostring(e.uri) .. '\31' .. tyname .. '\31' .. require('cartograph.peergen').serialize(req)
                            local g = groups[gk]
                            if not g then
                                g = { uri = e.uri, type = tyname, request = req, params = plist, candidates = {}, cases = {} }
                                groups[gk] = g
                            end
                            g.candidates[#g.candidates + 1] = { component = e.component, mod = e.mod, fn = e.fn,
                                handler = e.handler, clause = k, reach = reach, arity = arity, arg = ai }
                            for _, c in ipairs(cases) do g.cases[#g.cases + 1] = c end
                            if t.k == 'hole' and not alts and (S.reasons[t.h] or ''):find('never returns', 1, true) then
                                stats.never_returns = stats.never_returns + 1
                            end
                        end
                    end
                end
            end
        end
    end
    -- the operations: one per (namespace, type, request shape), names stable and unique
    local PG = require 'cartograph.peergen'
    local keys = {}
    for gk in pairs(groups) do keys[#keys + 1] = gk end
    table.sort(keys)
    local ops, used, index = {}, {}, {}
    for _, gk in ipairs(keys) do
        local g = groups[gk]
        local base = short(g.uri) .. '_' .. PG.ident(g.type)
        local name, n = base, 1
        while used[name] do n = n + 1; name = base .. '_' .. n end
        used[name] = true
        -- canonical outputs: a hole not named by a parameter is o1, o2, … by position (deterministic output)
        local pset = {}
        for _, p in ipairs(g.params) do pset[p] = true end
        local replies, seen = {}, {}
        for _, c in ipairs(g.cases) do
            local ren, cnt = {}, 0
            local function canon(t)
                if t.k == 'hole' then
                    if pset[t.h] or t.h:sub(1, 1) == '@' then return t end
                    if not ren[t.h] then cnt = cnt + 1; ren[t.h] = 'o' .. cnt end
                    return a.hole(ren[t.h], t.rep)
                end
                if not t.kids then return t end
                local kids = {}
                for i, x in ipairs(t.kids) do kids[i] = canon(x) end
                return copy(t, kids)
            end
            local ct = canon(c)
            local sk = PG.serialize(ct)
            if not seen[sk] then
                seen[sk] = true
                local cname = (ct.k == 'rec:iq' and ct.kids[2] and ct.kids[2].k == 'lit' and tostring(ct.kids[2].v))
                    or (ct.k == 'lit' and tostring(ct.v)) or (ct.k == 'hole' and 'unknown') or 'reply'
                replies[#replies + 1] = { name = cname, term = ct, key = sk }
            end
        end
        table.sort(replies, function (x, y) return x.key < y.key end)
        local cn = {}
        for _, r in ipairs(replies) do
            cn[r.name] = (cn[r.name] or 0) + 1
            if cn[r.name] > 1 then r.name = r.name .. '_' .. cn[r.name] end
            r.key = nil
        end
        stats.cases = stats.cases + #replies
        local doc = { ('%s  <iq type="%s">  params: %s'):format(g.uri, g.type, table.concat(g.params, ', ')) }
        table.sort(g.candidates, function (x, y)
            return (tostring(x.component) .. x.mod .. x.fn .. x.clause) < (tostring(y.component) .. y.mod .. y.fn .. y.clause)
        end)
        for _, c in ipairs(g.candidates) do
            doc[#doc + 1] = ('  served by %s:%s clause #%d (%s, %s)'):format(c.mod, c.fn, c.clause, tostring(c.component or '?'), c.reach)
        end
        ops[#ops + 1] = { name = name, doc = doc, params = g.params, request = g.request, replies = replies }
        index[name] = g.candidates
    end
    stats.ops = #ops
    local model = { name = 'xmpp iq peer of ' .. root, operations = ops,
        doc = { 'every operation a registered IQ handler accepts, its request a template over its parameters, its replies the cases the',
            'handler can give (a hole named by a parameter echoes the input; o1, o2 … are outputs). @id, @from, @lang are the transport\'s.' } }
    return model, stats, index, P
end

return M
