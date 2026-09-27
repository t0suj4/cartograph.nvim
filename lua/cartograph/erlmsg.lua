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
local M = {}

local function read(p)
    local fd = io.open(p, 'rb'); if not fd then return nil end
    local s = fd:read('a'); fd:close(); return s
end

local function named(n)
    local out = {}
    if not n then return out end
    for c in n:iter_children() do if c:named() and c:type() ~= 'comment' then out[#out + 1] = c end end
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

local VERB = { call = 'handle_call', cast = 'handle_cast' }

function M.attach(data)
    local stats = { sites = 0, explicit = 0, by_message = 0, unknown_target = 0, reached = 0, candidates_only = 0,
        none = 0, ambiguous = 0, edges = 0, unreached = {}, rows = {} }
    local root = data and data.root
    if not root or root:match('^%w+://') then return stats end
    -- tree gen_servers: module -> { handle_call = { {first, src, line}… }, handle_cast = …, fn = { [name] = id } }
    local servers, trees = {}, {}
    local fnid = {}
    for _, n in ipairs(data.nodes or {}) do
        if n.kind == 'function' and n.file and n.file:match('%.erl$') then
            local a = n.altkeys and n.altkeys[1]
            if a then fnid[n.file .. '\0' .. a] = n.id end
        end
    end
    for _, n in ipairs(data.nodes or {}) do
        if n.kind == 'module' and n.file and n.file:match('%.erl$') then
            local src = read(root .. '/' .. n.file)
            local ok, p = false, nil
            if src then ok, p = pcall(vim.treesitter.get_string_parser, src, 'erlang') end
            local r = ok and p and p:parse()[1]:root()
            if r then
                trees[n.file] = { root = r, src = src }
                if src:match('\n%-behaviou?r%(%s*gen_server%s*%)') then
                    local mod = n.file:match('([^/]+)%.erl$')
                    local sv = { file = n.file, handle_call = {}, handle_cast = {} }
                    for form in r:iter_children() do
                        if form:type() == 'fun_decl' then
                            for _, cl in ipairs(named(form)) do
                                local nm = cl:field('name')[1]
                                local name = nm and vim.treesitter.get_node_text(nm, src)
                                if name and sv[name] then
                                    local first = named(cl:field('args')[1])[1]
                                    if first then table.insert(sv[name], { first = first, line = (cl:start()) + 1 }) end
                                end
                            end
                        end
                    end
                    servers[mod] = sv
                end
            end
        end
    end
    -- the clauses of module `mod` a message reaches (first match): selected (yes) and candidates (unknown before a yes)
    local function reach(sv, handler, msg, msrc, specific_only)
        local sel, cand = nil, {}
        for _, cl in ipairs(sv[handler]) do
            local is_var = cl.first:type() == 'var'
            if not (specific_only and is_var) then
                local r = M.unify(cl.first, trees[sv.file].src, msg, msrc)
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
        for form in t.root:iter_children() do
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
        for c in n:iter_children() do if c:named() then names_in(c, t, own, acc) end end
        return acc
    end
    local function helper_body(t, name)
        local clauses = {}
        for form in t.root:iter_children() do
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
                for c in n:iter_children() do if c:named() then scan(c) end end
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
        local verb = c.full and c.full:match('^gen_server%.(%a+)/%d$')
        local handler = verb and VERB[verb]
        local t = handler and trees[c.file]
        if t and c.at and c.fn then
            local node = t.root:named_descendant_for_range(c.at.start.line, c.at.start.char, c.at['end'].line, c.at['end'].char)
            while node and node:type() ~= 'call' do node = node:parent() end
            local args = node and named(node:field('args')[1])
            local s, msg = args and args[1], args and args[2]
            if s and msg then
                stats.sites = stats.sites + 1
                local T = vim.treesitter.get_node_text
                local own = c.file:match('([^/]+)%.erl$')
                local target = server_of(s, t, node, own)
                local row = { file = c.file, line = c.line and c.line + 1, verb = verb }
                if target and servers[target] then
                    stats.explicit = stats.explicit + 1
                    local sel, cand = reach(servers[target], handler, msg, t.src, false)
                    local lines = {}
                    if sel then lines[1] = sel.line; stats.reached = stats.reached + 1
                    elseif #cand > 0 then stats.candidates_only = stats.candidates_only + 1 else stats.none = stats.none + 1 end
                    for _, cl in ipairs(cand) do if not sel or cl.line < sel.line then lines[#lines + 1] = cl.line end end
                    for _, l in ipairs(lines) do reached_clause[target .. ':' .. l] = true end
                    if #lines > 0 then
                        edge(c.fn, fnid[servers[target].file .. '\0' .. handler .. '/' .. (handler == 'handle_call' and 3 or 2)],
                            verb, lines, false, c.at)
                    end
                    row.target, row.clauses = target, lines
                else
                    stats.by_message = stats.by_message + 1
                    local hits = {}
                    for mod, sv in pairs(servers) do
                        local sel = reach(sv, handler, msg, t.src, true)
                        if sel then hits[#hits + 1] = { mod = mod, line = sel.line } end
                    end
                    if #hits == 0 then stats.unknown_target = stats.unknown_target + 1
                    else
                        stats.reached = stats.reached + 1
                        if #hits > 1 then stats.ambiguous = stats.ambiguous + 1 end
                        for _, h in ipairs(hits) do
                            reached_clause[h.mod .. ':' .. h.line] = true
                            edge(c.fn, fnid[servers[h.mod].file .. '\0' .. handler .. '/' .. (handler == 'handle_call' and 3 or 2)],
                                verb, { h.line }, #hits > 1, c.at)
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
        for _, h in ipairs({ 'handle_call', 'handle_cast' }) do
            for _, cl in ipairs(sv[h]) do
                if cl.first:type() ~= 'var' and not reached_clause[mod .. ':' .. cl.line] then
                    stats.unreached[#stats.unreached + 1] = { module = mod, handler = h, line = cl.line,
                        pattern = vim.treesitter.get_node_text(cl.first, trees[sv.file].src):gsub('%s+', ' '):sub(1, 80) }
                end
            end
        end
    end
    data.erlmsg = stats
    return stats
end

function M.summary(s)
    if not s or s.sites == 0 then return nil end
    return ('erlmsg: %d gen_server call/cast site(s) — %d to an explicit server, %d by message; %d reach a clause, %d only '
        .. 'candidates; %d edge(s); %d specific clause(s) no site in the tree reaches'):format(s.sites, s.explicit,
        s.by_message, s.reached, s.candidates_only, s.edges, #s.unreached)
end

return M
