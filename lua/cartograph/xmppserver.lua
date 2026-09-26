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

--- Every send site in the erlang files of `dir`, with the term the value encodes to.
--- opts = { E = erlrecords env (the module record scopes), spec = xmppspec (optional: is the record on the wire?) }
--- -> rows { file, line, fn (enclosing clause name/arity), verb, term, holes, status, record, wire = entry names }
function M.sends(dir, opts)
    opts = opts or {}
    local ET = require 'cartograph.erlterms'
    local E = opts.E
    local rows = {}
    local verbs = {}
    for _, v in ipairs(M.SEND_VERBS) do verbs[v.fn] = verbs[v.fn] or {}; verbs[v.fn][v.mod] = v end
    for _, f in ipairs(vim.fn.glob(dir .. '/*.erl', false, true)) do
        local fd = io.open(f, 'rb'); local src = fd and fd:read('a'); if fd then fd:close() end
        if src and (src:find('make_iq_result', 1, true) or src:find('ejabberd_router:route', 1, true)) then
            local root = vim.treesitter.get_string_parser(src, 'erlang'):parse()[1]:root()
            local scope = E and E:scope(f)
            local ctx = {
                module = src:match('%-module%(%s*([%w_]+)%s*%)'),
                record_fields = function (rec)
                    local d = scope and scope.records[rec]
                    if not d then return nil end
                    local out = {}
                    for i, fl in ipairs(d.fields) do out[i] = fl.name end
                    return out
                end,
                defaults = function (rec)
                    local d = scope and scope.records[rec]
                    if not d then return nil end
                    local out = {}
                    for _, fl in ipairs(d.fields) do out[fl.name] = fl.default end
                    return out
                end,
            }
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
                                local term, holes = ET.term(an, src, ctx)
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
                                    status = ET.status(term), record = rec,
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
    return rows
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
