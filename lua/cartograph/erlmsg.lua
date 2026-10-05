-- erlmsg — WHAT A MESSAGE REACHES: from a `gen_server:call/cast` site to the receiving clause of handle_call /
-- handle_cast, chosen by UNIFYING the message with the clause heads (CART-1130 step 4). erlang.
-- @langs erlang
--
-- ★ THE SAME QUESTION AS THE CLIENT -> SERVER MERGE, IN PROCESS. `gen_server:call(?MODULE, {get_room, Name})` runs
-- the first handle_call clause whose request pattern the message matches — Erlang's own first-match rule, the one
-- xmppmerge applies to IQ requests. The call graph had nothing: the request never names its handler.
--
-- THE TARGET MODULE:
--   explicit   the server argument is ?MODULE (the call's own module) or an atom naming a tree gen_server:
--              that module's clauses, first match wins, a catch-all `handle_call(_Request, …)` included. The server
--              is ALSO the call's own module when it is BUILT FROM ?MODULE: the expression contains ?MODULE, or it is a
--              variable bound in the same clause to such an expression, or a call to a single-clause local helper
--              whose body contains it (`Proc = get_proc_name(Host)` with `get_proc_name(H) ->
--              gen_mod:get_module_proc(H, ?MODULE)`). Without this, mod_antispam's `{reload, …}` cast "reached"
--              five modules by message; its own is the one.
--   by message a variable or computed server (a pid, a proc name): the tree gen_servers with a SPECIFIC clause (a
--              non-variable request pattern) that unifies — a catch-all matches every message and is evidence of
--              nothing. More than one module is a SET, each edge `pop_ambiguous`.
-- UNIFICATION is three-valued over the syntax (yes / no / unknown): atoms and literals compare by text (quotes
-- stripped), tuples by arity and element-wise, a record pattern with a record of the same name, a pattern variable
-- or `_` matches anything, a VALUE that is a variable or a call is unknown. First match: a `yes` stops the search,
-- an `unknown` clause stays a candidate and the search goes on, `no` skips.
-- WHAT IT WRITES: one hedged `ref` per (sending function, receiving function), `msg = verb`, `clauses = { line… }`
-- (the clause lines reached). The REVERSE is reported: per module, the specific clauses no send site in the tree
-- reaches — a hedge, not a verdict (a message can come from outside the tree or from a variable).
-- NOT HERE YET: gen_statem (its callback mode decides the receiving function), `Pid ! Msg` (handle_info, whose
-- target is a pid). ⚠ SESSION-LIVE, a post-pass (cartograph.postpass).
local tsutil = require 'cartograph.spec.tsutil' -- (tsutil.inext: indexed child iteration, CART-1453)
local M = {}

local function read(p)
    local fd = io.open(p, 'rb'); if not fd then return nil end
    local s = fd:read('a'); fd:close(); return s
end

local function named(n)
    local out = {}
    if not n then return out end
    for _, c in tsutil.inext, n, -1 do if c:named() and c:type() ~= 'comment' then out[#out + 1] = c end end
    return out
end

local function unq(s) return (s:gsub("^'(.*)'$", '%1')) end

local LIT = { atom = true, integer = true, float = true, string = true, char = true, binary = true }

--- three-valued unification of a PATTERN node against a VALUE node: 'yes' | 'no' | 'unknown'
function M.unify(p, ps, v, vs)
    local T = vim.treesitter.get_node_text
    local pt, vt = p:type(), v:type()
    if pt == 'var' then return 'yes' end
    if pt == 'match_expr' then
        local l, r = p:field('lhs')[1], p:field('rhs')[1]
        local a = l and M.unify(l, ps, v, vs) or 'yes'
        local b = r and M.unify(r, ps, v, vs) or 'yes'
        if a == 'no' or b == 'no' then return 'no' end
        return (a == 'yes' and b == 'yes') and 'yes' or 'unknown'
    end
    if vt == 'var' or vt == 'call' or vt == 'remote' or vt == 'macro_call_expr' and pt ~= 'macro_call_expr' then
        return 'unknown'
    end
    if pt == 'macro_call_expr' or vt == 'macro_call_expr' then
        return (pt == vt and T(p, ps) == T(v, vs)) and 'yes' or 'unknown'
    end
    if LIT[pt] and LIT[vt] then
        if pt ~= vt then return 'no' end
        return unq(T(p, ps)) == unq(T(v, vs)) and 'yes' or 'no'
    end
    if pt == 'tuple' and vt == 'tuple' then
        local pk, vk = named(p), named(v)
        if #pk ~= #vk then return 'no' end
        local all = 'yes'
        for i = 1, #pk do
            local r = M.unify(pk[i], ps, vk[i], vs)
            if r == 'no' then return 'no' end
            if r == 'unknown' then all = 'unknown' end
        end
        return all
    end
    if pt == 'record_expr' and vt == 'record_expr' then
        local pn, vn = p:field('name')[1], v:field('name')[1]
        return (pn and vn and T(pn, ps) == T(vn, vs)) and 'yes' or 'no'
    end
    -- concrete kinds that differ (an atom against a tuple, a tuple against a record) cannot match
    local CONCRETE = { atom = true, integer = true, float = true, string = true, char = true, binary = true,
        tuple = true, record_expr = true, list = true, map_expr = true }
    if CONCRETE[pt] and CONCRETE[vt] and pt ~= vt then return 'no' end
    return 'unknown'
end

-- does an event-type pattern (a gen_statem clause's first argument) admit this verb's event? `call` is delivered as
-- {call, From}, `cast` as the atom cast; a variable admits both
local function admits(p, src, verb)
    local t = p:type()
    if t == 'var' then return true end
    local T = vim.treesitter.get_node_text
    if verb == 'call' then
        if t ~= 'tuple' then return false end
        local k = named(p)
        return #k == 2 and (k[1]:type() == 'var' or (k[1]:type() == 'atom' and unq(T(k[1], src)) == 'call'))
    end
    return t == 'atom' and unq(T(p, src)) == 'cast'
end

-- the site verbs, by behaviour: which kind of server a call targets and which event it sends
local SITES = { ['gen_server'] = 'server', ['gen_statem'] = 'statem' }

function M.attach(data)
    local stats = { sites = 0, explicit = 0, by_message = 0, unknown_target = 0, reached = 0, candidates_only = 0,
        none = 0, ambiguous = 0, edges = 0, unreached = {}, rows = {}, statem_sites = 0 }
    local root = data and data.root
    if not root or root:match('^%w+://') then return stats end
    -- gen_statem's OWN callbacks of arity 3 (terminate/3, …) are not state functions: read from the runtime profile
    local statem_cb = {}
    do
        local ok, prof = pcall(require, 'cartograph.spec.profile')
        local a = ok and prof.load and prof.load('otp-api')
        local b = a and a.behaviours and a.behaviours.gen_statem
        for _, cb in ipairs(b and b.callbacks or {}) do statem_cb[cb.name .. '/' .. cb.arity] = true end
    end
    -- servers: module -> { file, kind = 'server'|'statem', mode, receivers = { call = {R…}, cast = {R…} } }
    --   R = { fn = 'name/arity', clauses = { { pat = content pattern, etype = event-type pattern | nil, line }… } }
    local servers, trees = {}, {}
    local fnid = {}
    for _, n in ipairs(data.nodes or {}) do
        if n.kind == 'function' and n.file and n.file:match('%.erl$') then
            local a = n.altkeys and n.altkeys[1]
            if a then fnid[n.file .. '\0' .. a] = n.id end
        end
    end
    local T = vim.treesitter.get_node_text
    for _, n in ipairs(data.nodes or {}) do
        if n.kind == 'module' and n.file and n.file:match('%.erl$') then
            local src = read(root .. '/' .. n.file)
            local ok, p = false, nil
            if src then ok, p = pcall(vim.treesitter.get_string_parser, src, 'erlang') end
            local r = ok and p and p:parse()[1]:root()
            if r then
                trees[n.file] = { root = r, src = src }
                local kind = (src:match('\n%-behaviou?r%(%s*gen_server%s*%)') and 'server')
                    or (src:match('\n%-behaviou?r%(%s*gen_statem%s*%)') and 'statem') or nil
                if kind then
                    local mod = n.file:match('([^/]+)%.erl$')
                    local byfn = {} -- 'name/arity' -> clauses (args lists), in source order
                    local order = {}
                    for _, form in tsutil.inext, r, -1 do
                        if form:type() == 'fun_decl' then
                            for _, cl in ipairs(named(form)) do
                                local nm = cl:field('name')[1]
                                local args = named(cl:field('args')[1])
                                if nm then
                                    local key = T(nm, src) .. '/' .. #args
                                    if not byfn[key] then byfn[key] = {}; order[#order + 1] = key end
                                    table.insert(byfn[key], { args = args, line = (cl:start()) + 1, body = cl:field('body')[1] })
                                end
                            end
                        end
                    end
                    local sv = { file = n.file, kind = kind, receivers = { call = {}, cast = {} } }
                    local function receiver(key, pat_i, etype_i)
                        local R = { fn = key, clauses = {} }
                        for _, c in ipairs(byfn[key] or {}) do
                            if c.args[pat_i] then
                                R.clauses[#R.clauses + 1] = { pat = c.args[pat_i], etype = etype_i and c.args[etype_i] or nil, line = c.line }
                            end
                        end
                        return R
                    end
                    if kind == 'server' then
                        sv.receivers.call[1] = receiver('handle_call/3', 1)
                        sv.receivers.cast[1] = receiver('handle_cast/2', 1)
                    else
                        -- the callback mode, read from callback_mode()'s body: handle_event_function | state_functions
                        local mode = 'state_functions'
                        for _, c in ipairs(byfn['callback_mode/0'] or {}) do
                            if c.body and T(c.body, src):find('handle_event_function', 1, true) then mode = 'handle_event_function' end
                        end
                        sv.mode = mode
                        if mode == 'handle_event_function' then
                            local R = receiver('handle_event/4', 2, 1)
                            sv.receivers.call[1], sv.receivers.cast[1] = R, R
                        else
                            -- every arity-3 function that is not one of gen_statem's own callbacks is a state function
                            for _, key in ipairs(order) do
                                if key:match('/3$') and not statem_cb[key] then
                                    local R = receiver(key, 2, 1)
                                    sv.receivers.call[#sv.receivers.call + 1] = R
                                    sv.receivers.cast[#sv.receivers.cast + 1] = R
                                end
                            end
                        end
                    end
                    servers[mod] = sv
                end
            end
        end
    end
    -- one receiver's clauses a message reaches (first match): selected (yes) and candidates (unknown before a yes)
    local function reach(R, sv, verb, msg, msrc, specific_only)
        local sel, cand = nil, {}
        local psrc = trees[sv.file].src
        for _, cl in ipairs(R.clauses) do
            if not (cl.etype and not admits(cl.etype, psrc, verb)) and not (specific_only and cl.pat:type() == 'var') then
                local r = M.unify(cl.pat, psrc, msg, msrc)
                if r == 'yes' then sel = cl; break end
                if r == 'unknown' then cand[#cand + 1] = cl end
            end
        end
        return sel, cand
    end
    -- WHICH MODULE a server expression is built from (see the header): the modules it names — ?MODULE (the call's
    -- own), an atom naming a tree gen_server, a same-file macro whose -define is such an atom — in the expression,
    -- the clause's binding of a variable, or a single-clause local helper's body. Exactly one, or nil.
    local define_memo = {}
    local function defines(t)
        if define_memo[t] then return define_memo[t] end
        local d = {}
        for _, form in tsutil.inext, t.root, -1 do
            if form:type() == 'pp_define' then
                local lhs, rep = form:field('lhs')[1], form:field('replacement')[1]
                local nm = lhs and lhs:field('name')[1]
                if nm and rep and rep:type() == 'atom' and not lhs:field('args')[1] then
                    d[vim.treesitter.get_node_text(nm, t.src)] = unq(vim.treesitter.get_node_text(rep, t.src))
                end
            end
        end
        define_memo[t] = d
        return d
    end
    local function names_in(n, t, own, acc)
        local ty = n:type()
        -- the MODULE of a remote call is the callee's, not a server name (`mod_http_upload:get_proc_name(H, ?MODULE)`)
        if ty == 'remote_module' then return acc end
        if ty == 'macro_call_expr' then
            local mn = n:field('name')[1]
            local m = mn and vim.treesitter.get_node_text(mn, t.src)
            if m == 'MODULE' then acc[own] = true
            elseif m and defines(t)[m] and servers[defines(t)[m]] then acc[defines(t)[m]] = true end
        elseif ty == 'atom' and servers[unq(vim.treesitter.get_node_text(n, t.src))] then
            acc[unq(vim.treesitter.get_node_text(n, t.src))] = true
        end
        for _, c in tsutil.inext, n, -1 do if c:named() then names_in(c, t, own, acc) end end
        return acc
    end
    local function helper_body(t, name)
        local clauses = {}
        for _, form in tsutil.inext, t.root, -1 do
            if form:type() == 'fun_decl' then
                for _, cl in ipairs(named(form)) do
                    local nm = cl:field('name')[1]
                    if nm and vim.treesitter.get_node_text(nm, t.src) == name then clauses[#clauses + 1] = cl end
                end
            end
        end
        return #clauses == 1 and clauses[1]:field('body')[1] or nil
    end
    local function server_of(s, t, call, own)
        local acc = {}
        local function from_expr(n)
            names_in(n, t, own, acc)
            local e = n:type() == 'call' and n:field('expr')[1]
            if e and e:type() == 'atom' and not (n:parent() and n:parent():type() == 'remote') then
                local b = helper_body(t, vim.treesitter.get_node_text(e, t.src))
                if b then names_in(b, t, own, acc) end
            end
        end
        from_expr(s)
        if s:type() == 'var' then
            local name = vim.treesitter.get_node_text(s, t.src)
            local cl = call:parent()
            while cl and cl:type() ~= 'function_clause' and cl:type() ~= 'fun_clause' do cl = cl:parent() end
            local function scan(n)
                if n:type() == 'match_expr' then
                    local l, r = n:field('lhs')[1], n:field('rhs')[1]
                    if l and r and l:type() == 'var' and vim.treesitter.get_node_text(l, t.src) == name then from_expr(r) end
                end
                for _, c in tsutil.inext, n, -1 do if c:named() then scan(c) end end
            end
            if cl then scan(cl) end
        end
        local one, n = nil, 0
        for m in pairs(acc) do one, n = m, n + 1 end
        return n == 1 and one or nil
    end
    local reached_clause = {}
    local refEdge = {}
    for _, e in ipairs(data.edges or {}) do if e.kind == 'ref' then refEdge[e.from .. '\31' .. e.to] = e end end
    local function edge(from, to, verb, lines, ambiguous, at)
        if not (from and to) or from == to then return end
        local k = from .. '\31' .. to
        local e = refEdge[k]
        if not e then
            e = { from = from, to = to, kind = 'ref', at = {}, inferred = true, msg = verb, clauses = {},
                pop_ambiguous = ambiguous or nil }
            refEdge[k] = e
            data.edges[#data.edges + 1] = e
            stats.edges = stats.edges + 1
        end
        for _, l in ipairs(lines) do e.clauses[#e.clauses + 1] = l end
        if at then e.at[#e.at + 1] = at end
    end
    for _, c in ipairs(data.calls or {}) do
        local beh, verb = (c.full or ''):match('^([%w_]+)%.(%a+)/%d$')
        local kind = beh and SITES[beh]
        if kind and verb ~= 'call' and verb ~= 'cast' then kind = nil end
        local t = kind and trees[c.file]
        if t and c.at and c.fn then
            local node = t.root:named_descendant_for_range(c.at.start.line, c.at.start.char, c.at['end'].line, c.at['end'].char)
            while node and node:type() ~= 'call' do node = node:parent() end
            local args = node and named(node:field('args')[1])
            local s, msg = args and args[1], args and args[2]
            if s and msg then
                stats.sites = stats.sites + 1
                if kind == 'statem' then stats.statem_sites = stats.statem_sites + 1 end
                local own = c.file:match('([^/]+)%.erl$')
                local target = server_of(s, t, node, own)
                local row = { file = c.file, line = c.line and c.line + 1, verb = verb, kind = kind }
                local tag = kind == 'statem' and ('statem_' .. verb) or verb
                if target and servers[target] and servers[target].kind == kind then
                    stats.explicit = stats.explicit + 1
                    local sv, any, anycand = servers[target], false, false
                    for _, R in ipairs(sv.receivers[verb]) do
                        local sel, cand = reach(R, sv, verb, msg, t.src, false)
                        local lines = {}
                        if sel then lines[1] = sel.line; any = true end
                        for _, cl in ipairs(cand) do if not sel or cl.line < sel.line then lines[#lines + 1] = cl.line; anycand = true end end
                        for _, l in ipairs(lines) do reached_clause[target .. ':' .. l] = true end
                        if #lines > 0 then edge(c.fn, fnid[sv.file .. '\0' .. R.fn], tag, lines, false, c.at) end
                    end
                    if any then stats.reached = stats.reached + 1
                    elseif anycand then stats.candidates_only = stats.candidates_only + 1 else stats.none = stats.none + 1 end
                    row.target = target
                else
                    stats.by_message = stats.by_message + 1
                    local hits = {}
                    for mod, sv in pairs(servers) do
                        if sv.kind == kind then
                            for _, R in ipairs(sv.receivers[verb]) do
                                local sel = reach(R, sv, verb, msg, t.src, true)
                                if sel then hits[#hits + 1] = { mod = mod, fn = R.fn, line = sel.line } end
                            end
                        end
                    end
                    local mods = {}
                    for _, h in ipairs(hits) do mods[h.mod] = true end
                    local nmods = 0
                    for _ in pairs(mods) do nmods = nmods + 1 end
                    if #hits == 0 then stats.unknown_target = stats.unknown_target + 1
                    else
                        stats.reached = stats.reached + 1
                        if nmods > 1 then stats.ambiguous = stats.ambiguous + 1 end
                        for _, h in ipairs(hits) do
                            reached_clause[h.mod .. ':' .. h.line] = true
                            edge(c.fn, fnid[servers[h.mod].file .. '\0' .. h.fn], tag, { h.line }, nmods > 1, c.at)
                        end
                    end
                    row.targets = hits
                end
                stats.rows[#stats.rows + 1] = row
            end
        end
    end
    -- the reverse: specific clauses no send site in the tree reaches (a hedge)
    for mod, sv in pairs(servers) do
        local seenR = {}
        for _, verb in ipairs({ 'call', 'cast' }) do
            for _, R in ipairs(sv.receivers[verb]) do
                if not seenR[R] then
                    seenR[R] = true
                    for _, cl in ipairs(R.clauses) do
                        -- a gen_statem clause for another event source (info, a timeout, enter) is no call/cast's to reach
                        local src_ = trees[sv.file].src
                        local callable = not cl.etype or admits(cl.etype, src_, 'call') or admits(cl.etype, src_, 'cast')
                        if callable and cl.pat:type() ~= 'var' and not reached_clause[mod .. ':' .. cl.line] then
                            stats.unreached[#stats.unreached + 1] = { module = mod, handler = R.fn, line = cl.line,
                                pattern = T(cl.pat, trees[sv.file].src):gsub('%s+', ' '):sub(1, 80) }
                        end
                    end
                end
            end
        end
    end
    data.erlmsg = stats
    return stats
end

function M.summary(s)
    if not s or s.sites == 0 then return nil end
    return ('erlmsg: %d gen_server/gen_statem call/cast site(s) (%d gen_statem) — %d to an explicit server, %d by message; '
        .. '%d reach a clause, %d only candidates; %d edge(s); %d specific clause(s) no site in the tree reaches'):format(
        s.sites, s.statem_sites, s.explicit, s.by_message, s.reached, s.candidates_only, s.edges, #s.unreached)
end

return M
