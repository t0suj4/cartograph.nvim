-- xmppserver — THE SERVER LEG OF THE XMPP TRIPLE AS ROWS: every registered IQ endpoint, the handler that serves it,
-- and what that handler READS from the request (CART-1087 phase 2, the input CART-0862's gate compares).
-- @langs erlang
--
-- ★★ AN ENDPOINT IS A NAMESPACE PLUS A FUNCTION, AND BOTH HALVES ALREADY EXIST — this module only puts them in one
-- row. ejabberd registers a handler two ways (the registration relation, [[cartograph-registration-relation]]):
--   call   gen_iq_handler:add_iq_handler(Component, Host, ?NS_X, Module, Function)   argv slots 3 / 4 / 5, the
--          binding xlang declares (`{ export = { verb = 'add_iq_handler', name = 3, mod = 4, fn = 5 } }`)
--   tuple  {iq_handler, Component, ?NS_X, Function} or {…, Module, Function} returned from a gen_mod callback,
--          read by erlreg (CART-0846), whose rows already carry the resolved handler
-- and the handler's clause HEADS are its read set since CART-0957 (expr.of → eo.heads: each bound name with the
-- path it comes from, each constant the request must equal, e.g. `const get #iq.type`,
-- `bind Node #iq.sub_els [1] #disco_info.node`).
--
-- ★ NOTHING IS RE-DERIVED HERE. The URI is the vocabulary's (argv's `macro` slot value, filled by the erlang spec
-- from the distilled headers), the handler is xlang's resolver (`handler_by_module`, the pair, never the bare
-- function atom: `process_iq` is defined by a dozen modules), the tuple rows are erlreg's. A row whose URI or
-- handler did not resolve is KEPT and says so: a frontier, never a silent drop.
--
-- ROW = { uri = 'urn:xmpp:time' | nil, key = 'NS_TIME' | nil (the macro, when the slot was one),
--         carrier = 'call' | 'tuple', file, line (the registration site), mod, fn (the handler atoms),
--         handler = node id | nil, why = nil | 'no uri' | 'handler unresolved' | 'not a literal' }
-- READS  = M.reads(store, handler) -> { clauses = n, heads = eo.heads } | nil, why
local M = {}

local argv = require 'cartograph.argv'
local xlang = require 'cartograph.xlang'

local VERB = 'add_iq_handler'
local SLOT = { key = 3, mod = 4, fn = 5 }

local function atom(a)
    if not a then return nil end
    if a.k == 'lit' and type(a.v) == 'string' then return a.v end
    return nil
end

--- Every registered endpoint in `data` (an extraction of the server root), both carriers.
---@return table[] rows, table stats
function M.endpoints(data)
    local rows = {}
    local stats = { call = 0, tuple = 0, no_uri = 0, unresolved = 0, not_literal = 0 }
    local exact = xlang.def_index(data)
    for _, c in ipairs(data.calls or {}) do
        if (c.callee or '') == VERB then
            local k, m, f = argv.at(c, SLOT.key), argv.at(c, SLOT.mod), argv.at(c, SLOT.fn)
            local row = { carrier = 'call', file = c.file, line = c.line,
                uri = k and k.k == 'macro' and k.v or (k and k.k == 'lit' and k.v) or nil,
                key = k and k.k == 'macro' and k.name or nil, mod = atom(m), fn = atom(f) }
            if not (row.mod and row.fn) then
                -- a registration HELPER's own call (`add_iq_handler(Component, Host, NS, Module, Function)` inside
                -- gen_iq_handler / gen_mod): its slots are its parameters, not an endpoint
                row.why = 'not a literal'; stats.not_literal = stats.not_literal + 1
            else
                row.handler = xlang.handler_by_module(exact, row.fn, row.mod)
                if not row.uri then row.why = 'no uri'; stats.no_uri = stats.no_uri + 1
                elseif not row.handler then row.why = 'handler unresolved'; stats.unresolved = stats.unresolved + 1 end
            end
            stats.call = stats.call + 1
            rows[#rows + 1] = row
        end
    end
    local ers = data.erlreg or require('cartograph.erlreg').attach(data)
    for _, r in ipairs(ers.rows or {}) do
        local row = { carrier = 'tuple', file = r.file, line = r.line, uri = r.uri, key = r.key,
            mod = r.mod, fn = r.fn, handler = r.handler }
        if not row.uri then row.why = 'no uri'; stats.no_uri = stats.no_uri + 1
        elseif not row.handler then row.why = 'handler unresolved'; stats.unresolved = stats.unresolved + 1 end
        stats.tuple = stats.tuple + 1
        rows[#rows + 1] = row
    end
    return rows, stats
end

--- What `handler` reads from its request: its clause heads as read sets (expr.of, CART-0957).
function M.reads(store, handler)
    if not handler then return nil, 'no handler' end
    local ok, eo = pcall(require('cartograph.expr').of, store, handler)
    if not ok then return nil, 'expr.of failed: ' .. tostring(eo) end
    if not eo then return nil, 'expr.of refused' end
    return { clauses = eo.clauses or 1, heads = eo.heads or {} }
end

-- ── THE SERVER'S WRITES (CART-1108, via CART-1112 step 1) ───────────────────────────────────────────────────────
-- where a handler SENDS: the stanza handed to the router, or the payload of an IQ result. (module, function,
-- argument position) of the value that goes on the wire.
M.SEND_VERBS = {
    { mod = 'xmpp', fn = 'make_iq_result', arg = 2, what = 'IQ result payload' },
    { mod = 'ejabberd_router', fn = 'route', arg = 1, what = 'routed stanza' },
}
local ERLT = { call = { call = true }, remote = { remote = true }, clause = { function_clause = true } }

--- THE PROGRAM a call is summarized over (CART-1112 step 3): the tree's own modules, then each dependency's src —
--- the dependency roots the record resolver was given (the caller's), selected by the modules the calls name — then
--- the runtime's own source (opts.otp). Shared by sends and responses.
function M.program(dir, E, opts)
    local ET = require 'cartograph.erlterms'
    local dirs = { dir }
    -- a dependency's own files resolve their includes against ITS include/ (rebar's default {i, "include"} for an
    -- app), not the tree's
    local ER = require 'cartograph.erlrecords'
    for _, d in pairs(E and E.apps or {}) do
        dirs[#dirs + 1] = { dir = d .. '/src', E = ER.new { include_dirs = { d .. '/include' }, apps = E.apps } }
    end
    for _, d in ipairs(opts.deps or {}) do dirs[#dirs + 1] = d end
    -- the RUNTIME's own source (opts.otp: an OTP source tree of the version that runs, the caller's): lists:map/foldl
    -- and the rest are read from their definitions, not listed. After the tree and its dependencies.
    if opts.otp then
        local incs = vim.fn.glob(opts.otp .. '/lib/*/include', false, true)
        local OE = ER.new { include_dirs = incs, libs = { opts.otp .. '/lib' } }
        for _, d in ipairs(vim.fn.glob(opts.otp .. '/lib/*/src', false, true)) do dirs[#dirs + 1] = { dir = d, E = OE } end
    end
    return ET.program { dirs = dirs, E = E }
end

-- the hole reasons that are the REQUEST (or a parameter): what the response leg exists to fill
local INPUT = { '^parameter %d', 'part of parameter', 'a field the pattern does not mention', 'a part of the subject it does not state' }
local function is_input(w)
    for _, p in ipairs(INPUT) do if w:find(p) then return true end end
    return false
end

--- THE RESPONSE LEG (CART-1135): each client request the merge ACCEPTED, run through its handler with the CLIENT's
--- request term as the argument that carries it — the reply the handler returns for THAT request. Beside it the
--- same handler with every argument unknown: the holes the request filled are the difference.
--- merged = xmppmerge.merge(...) result; opts = { E, otp, deps } as sends
--- -> rows { file, line, owner, handler, mod, fn, clause, response, holes, status, base, base_holes, input_before,
---           input_after }, totals
function M.responses(merged, dir, opts)
    opts = opts or {}
    local ET = require 'cartograph.erlterms'
    local A = require('cartograph.algebra').load()
    local P = M.program(dir, opts.E, opts)
    local rows = {}
    local tot = { requests = 0, evaluated = 0, complete = 0, partial = 0, opaque = 0, ['one-of'] = 0, input_before = 0, input_after = 0,
        base_complete = 0 }
    for _, row in ipairs(merged.rows or {}) do
        for _, c in ipairs(row.candidates or {}) do
            if c.clause and c.request and c.arg and c.arity and c.mod and c.fn then
                tot.requests = tot.requests + 1
                local S = ET.session()
                for h, why in pairs(c.holes or {}) do S.reasons[h] = 'the client: ' .. tostring(why) end
                local args, base = {}, {}
                for i = 1, c.arity do
                    local hole = A.hole('P' .. i)
                    S.reasons['P' .. i] = ('parameter %d of %s:%s/%d'):format(i, c.mod, c.fn, c.arity)
                    base[i] = hole
                    args[i] = (i == c.arg) and c.request or hole
                end
                local t, holes = ET.call(P, c.mod, c.fn, args, S)
                local bt, bholes = ET.call(P, c.mod, c.fn, base, S)
                -- the holes of a reply, through its alternatives: by what they are
                local function census(term)
                    local n = { input = 0, client = 0, other = 0 }
                    local seen = {}
                    local function walk(x)
                        if x.k == 'hole' then
                            if S.alts[x.h] and not seen[x.h] then
                                seen[x.h] = true
                                for _, y in ipairs(S.alts[x.h]) do walk(y) end
                                return
                            end
                            if seen[x.h] then return end
                            seen[x.h] = true
                            local w = S.reasons[x.h] or ''
                            if w:find('^the client: ') then n.client = n.client + 1
                            elseif is_input(w) then n.input = n.input + 1
                            else n.other = n.other + 1 end
                            return
                        end
                        for _, y in ipairs(x.kids or {}) do walk(y) end
                    end
                    walk(term)
                    return n
                end
                local cn, bn = census(t), census(bt)
                local nin, nbin = cn.input, bn.input
                local st, bst = ET.status(t), ET.status(bt)
                -- a bare hole whose arms were kept: the reply is ONE OF those (S.alts)
                local alts = t.k == 'hole' and S.alts[t.h] or nil
                if alts then st = 'one-of' end
                tot.evaluated = tot.evaluated + 1
                tot[st] = (tot[st] or 0) + 1
                if bst == 'complete' then tot.base_complete = tot.base_complete + 1 end
                tot.input_before, tot.input_after = tot.input_before + nbin, tot.input_after + nin
                rows[#rows + 1] = { file = row.file, line = row.line, owner = row.owner, handler = c.handler, mod = c.mod,
                    fn = c.fn, clause = c.clause, response = t, alts = alts, holes = holes, status = st, base = bt, base_holes = bholes,
                    base_status = bst, input_before = nbin, input_after = nin, client_holes = cn.client,
                    other_before = bn.other, other_after = cn.other }
                tot.client = (tot.client or 0) + cn.client
                tot.other_before, tot.other_after = (tot.other_before or 0) + bn.other, (tot.other_after or 0) + cn.other
            end
        end
    end
    return rows, tot
end

--- Every send site in the erlang files of `dir`, with the term the value encodes to.
--- opts = { E = erlrecords env (the module record scopes), spec = xmppspec (optional: is the record on the wire?),
---          deps = { src dir, … }, otp = an OTP source root (the runtime's version; optional) }
--- -> rows { file, line, fn (enclosing clause name/arity), verb, term, holes, status, record, wire = entry names },
---    stats (the summary session's counters: summaries, memo_hits, recursive cuts, depth cuts, budget)
function M.sends(dir, opts)
    opts = opts or {}
    local ET = require 'cartograph.erlterms'
    local E = opts.E
    local rows = {}
    local P = M.program(dir, E, opts)
    local S = ET.session()
    local verbs = {}
    for _, v in ipairs(M.SEND_VERBS) do verbs[v.fn] = verbs[v.fn] or {}; verbs[v.fn][v.mod] = v end
    for _, f in ipairs(vim.fn.glob(dir .. '/*.erl', false, true)) do
        local fd = io.open(f, 'rb'); local src = fd and fd:read('a'); if fd then fd:close() end
        if src and (src:find('make_iq_result', 1, true) or src:find('ejabberd_router:route', 1, true)) then
            local root = vim.treesitter.get_string_parser(src, 'erlang'):parse()[1]:root()
            local m = P:adopt(f, src)
            local ctx = m and m.ctx or ET.file_ctx(src, f, E, P)
            local function walk(x)
                for c in x:iter_children() do
                    if ERLT.call[c:type()] then
                        local e = c:field('expr')[1]
                        local fname = e and vim.treesitter.get_node_text(e, src)
                        -- the 0.12 shape: (remote module: (remote_module …) fun: (call …))
                        local par = c:parent()
                        local mn = par and ERLT.remote[par:type()] and par:field('module')[1]
                        local mod = mn and vim.treesitter.get_node_text(mn, src):gsub(':$', '')
                        local v = fname and verbs[fname] and mod and verbs[fname][mod]
                        if v then
                            local args, i = {}, 0
                            local al = c:field('args')[1]
                            for a in (al and al:iter_children() or function () end) do
                                if a:named() then i = i + 1; args[i] = a end
                            end
                            local an = args[v.arg]
                            if an then
                                local term, holes = ET.term(an, src, ctx, S)
                                -- a bare hole the join left over different record kinds: the SET of records
                                local set
                                for _, k in ipairs(term.k == 'hole' and S.kinds[term.h] or {}) do
                                    local rn = k:match('^rec:(.+)$')
                                    if not rn then set = nil; break end
                                    set = set or {}
                                    set[#set + 1] = rn
                                end
                                local cl = c
                                while cl and not ERLT.clause[cl:type()] do cl = cl:parent() end
                                local fnm = cl and cl:field('name')[1]
                                local arity = 0
                                local ca = cl and cl:field('args')[1]
                                if ca then for a in ca:iter_children() do if a:named() then arity = arity + 1 end end end
                                local rec = term.k and term.k:match('^rec:(.+)$')
                                rows[#rows + 1] = { file = f:sub(#dir + 2), line = c:start() + 1,
                                    fn = fnm and (vim.treesitter.get_node_text(fnm, src) .. '/' .. arity) or '?',
                                    verb = v.mod .. ':' .. v.fn, what = v.what, term = term, holes = holes,
                                    status = set and 'one-of' or ET.status(term), record = rec, records = set,
                                    wire = rec and opts.spec and opts.spec.by_record and opts.spec.by_record[rec] or nil }
                            end
                        end
                    end
                    walk(c)
                end
            end
            walk(root)
        end
    end
    return rows, S.stats, S
end

--- A head's request shape in one line: the constants it demands and the records it destructures, by path.
function M.head_line(h)
    local parts = {}
    for _, f in ipairs(h.facts or {}) do
        local p = {}
        for _, s in ipairs(f.path or {}) do
            p[#p + 1] = s.rec and (s.field and ('#' .. s.rec .. '.' .. s.field) or ('#' .. s.rec .. '{}'))
                or s.elem and ('[' .. s.elem .. ']')
                or s.tuple and ('{' .. s.tuple .. '}') or s.map and ('#{' .. s.map .. '}')
                or s.head and '[H|' or s.tail and '|T]' or '?'
        end
        local path = table.concat(p, ' ')
        if f.value then parts[#parts + 1] = ('%s=%s'):format(path, f.value)
        elseif f.record then parts[#parts + 1] = path
        elseif path ~= '' then parts[#parts + 1] = ('%s->%s'):format(path, f.name) end
    end
    return table.concat(parts, '  ')
end

return M
