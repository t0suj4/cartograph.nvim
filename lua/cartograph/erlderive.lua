-- erlderive — GENERATORS DERIVED FROM THE CODE THAT INTERPRETS THEM (CART-1125). erlang.
-- @langs erlang
--
-- ★★ USER, 2026-09-27: "I wonder if it can be derived." For erlang, yes: ejabberd interprets its own registration
-- tuples, in executable code, at gen_mod.erl:406-431 —
--     lists:foreach(fun ({iq_handler, Component, NS, Function}) ->
--                            gen_iq_handler:add_iq_handler(Component, Host, NS, Module, Function);
--                       ({hook, Hook, Function, Seq}) -> ejabberd_hooks:add(Hook, Host, Module, Function, Seq);
--                       … end, Registrations)
-- The clause HEAD is the site pattern (its variables are the holes), the clause GUARD discriminates the forms, and
-- the clause BODY says what a site means: the call it stands for. erlreg re-typed that interpretation by hand
-- (erlreg.CARRIERS); this reads it, and ⚠ NOTHING HERE READS erlreg.CARRIERS — heads from the interpreter, roles
-- from xlang's carrier declaration, the population from the grammar's pattern and type positions — so a join
-- against erlreg is a real acceptance test, not the same table read twice.
--
-- THE SHAPE READ, and only this one: a `fun` passed to lists:foreach over a LIST PARAMETER of the enclosing
-- function, each clause ONE tagged-tuple head and a body of exactly ONE call. A clause of any other shape is kept
-- with the reason it was skipped. Every interpreter found is listed (M.find); which one GENERATES is decided by
-- the carrier: the interpreter whose effect is a carrier's registering verb (`add_iq_handler`, xlang's export side).
-- The unregistering twin (del_registrations) is a CONSISTENCY check — the same author, so not a witness.
--
-- CONTEXT, derived where the code says it: an effect argument that is an OUTER variable (`Module`, `Host`) is
-- bound by whoever calls the interpreting function. `start_module` does
--     case Module:start(Host, Opts) of {ok, Registrations} -> add_registrations(Host, Module, Registrations)
-- so `Module` is the module whose OWN callback returned the list (gen_mod.erl:180-185, recorded as provenance).
-- ⚠ ONE STEP IS STILL ASSUMED, and labelled so: that the callback module is the file whose code holds the tuple
-- (erlreg assumes the same). An outer variable with no such chain (Host) stays an explicit unresolved marker.
-- ★ THE SAME CHAIN GIVES THE POPULATION: the list is what the CALLBACK (start/2) returns, so a site is a tuple in a
-- value position INSIDE that callback. Measured on ejabberd before adding it: 257 of 258 derived facts sat in
-- start/2; the one outside was `{commands, ACmds}` built by ejabberd_old_config's config transform — a tag is not
-- unique to the registry. ⚠ A registration built in a HELPER that start/2 calls would be missed (none today).
local M = {}

local function T(n, src) return vim.treesitter.get_node_text(n, src) end
local function named(n)
    local out = {}
    for c in n:iter_children() do if c:named() and c:type() ~= 'comment' then out[#out + 1] = c end end
    return out
end
local function field(n, f) return n and n:field(f)[1] end

-- a remote call `mod:fun(args)` in the 0.12 grammar: (remote module: (remote_module …) fun: (call expr args))
local function remote_parts(n, src)
    if not n or n:type() ~= 'remote' then return nil end
    local m, f = field(n, 'module'), field(n, 'fun')
    local ma = m and (m:named_child(0) or m)
    local fe = f and field(f, 'expr')
    if not (ma and f and fe) then return nil end
    return { mod = ma, fn = T(fe, src), args = named(field(f, 'args') or f), call = f }
end

-- the variables of a pattern, in order (with `_` counted, since it must become a unique hole)
local function vars_of(n, src, out)
    out = out or {}
    if n:type() == 'var' then out[#out + 1] = n end
    for c in n:iter_children() do if c:named() then vars_of(c, src, out) end end
    return out
end

--- every interpreter of the gen_mod shape in one file. Returns a list of
--- { file, line, fn = {name, arity, params = {var names}}, list_param, clauses = { {…} }, skipped = { {line, why} } }
--- where a clause is { line, tag, arity, head (the tuple node), guard (node|nil), effect = {mod, fn, args} }.
function M.find(src, file)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'erlang')
    local root = ok and parser and parser:parse()[1]:root()
    if not root then return {} end
    local found = {}
    local function enclosing_clause(n)
        local p = n:parent()
        while p and p:type() ~= 'function_clause' do p = p:parent() end
        return p
    end
    local function visit(n)
        local r = remote_parts(n, src)
        if r and T(r.mod, src) == 'lists' and r.fn == 'foreach' and #r.args == 2
                and r.args[1]:type() == 'anonymous_fun' and r.args[2]:type() == 'var' then
            local fc = enclosing_clause(n)
            local params = {}
            for _, a in ipairs(named(field(fc, 'args') or fc)) do params[#params + 1] = a:type() == 'var' and T(a, src) or false end
            local list = T(r.args[2], src)
            local li
            for i, p in ipairs(params) do if p == list then li = i end end
            if fc and li then
                local it = { file = file, line = (n:start()) + 1, list_param = li, clauses = {}, skipped = {},
                    fn = { name = T(field(fc, 'name'), src), arity = #params, params = params } }
                for _, cl in ipairs(named(r.args[1])) do
                    local line = (cl:start()) + 1
                    local args = named(field(cl, 'args') or cl)
                    local head = args[1]
                    local body = named(field(cl, 'body') or cl)
                    local first = head and head:type() == 'tuple' and head:named_child(0)
                    local eff = #body == 1 and remote_parts(body[1], src)
                    if #args ~= 1 or not first or first:type() ~= 'atom' then
                        it.skipped[#it.skipped + 1] = { line = line, why = 'the head is not one tagged tuple' }
                    elseif not eff then
                        it.skipped[#it.skipped + 1] = { line = line, why = 'the body is not exactly one remote call' }
                    else
                        it.clauses[#it.clauses + 1] = { line = line, tag = T(first, src), arity = #named(head),
                            head = head, guard = field(cl, 'guard'),
                            effect = { mod = T(eff.mod, src), fn = eff.fn, args = eff.args } }
                    end
                end
                found[#found + 1] = it
            end
        end
        for c in n:iter_children() do if c:named() then visit(c) end end
    end
    visit(root)
    for _, it in ipairs(found) do it.src = src end
    return found
end

--- the chain that binds an interpreter's OUTER parameter: a caller `F(…, M, …, R)` where R is bound by a case arm over
--- `M:callback(…)`. Returns { [param index] = { kind = 'callback-module', file, line } }.
function M.context_chain(it, files)
    local out = {}
    for _, f in ipairs(files) do
        local ok, parser = pcall(vim.treesitter.get_string_parser, f.src, 'erlang')
        local root = ok and parser and parser:parse()[1]:root()
        local function visit(n)
            if n:type() == 'call' and field(n, 'expr') and field(n, 'expr'):type() == 'atom'
                    and T(field(n, 'expr'), f.src) == it.fn.name then
                local args = named(field(n, 'args') or n)
                local ra = args[it.list_param]
                if #args == it.fn.arity and ra and ra:type() == 'var' then
                    -- the case arm that binds the list, and the dynamic call it is over
                    local p = n:parent()
                    while p and p:type() ~= 'cr_clause' do p = p:parent() end
                    local ce = p and p:parent()
                    local subj = ce and ce:type() == 'case_expr' and field(ce, 'expr')
                    local r = remote_parts(subj, f.src)
                    local binds = false
                    for _, v in ipairs(p and vars_of(field(p, 'pat') or p, f.src) or {}) do
                        if T(v, f.src) == T(ra, f.src) then binds = true end
                    end
                    if r and binds and r.mod:type() == 'var' then
                        for j, a in ipairs(args) do
                            if a:type() == 'var' and T(a, f.src) == T(r.mod, f.src) then
                                out[j] = { kind = 'callback-module', file = f.rel, line = (n:start()) + 1,
                                    via = T(r.mod, f.src) .. ':' .. r.fn, callback = { fn = r.fn, arity = #r.args } }
                            end
                        end
                    end
                end
            end
            for c in n:iter_children() do if c:named() then visit(c) end end
        end
        if root then visit(root) end
    end
    return out
end

-- the head as a snippet: each variable renamed to a placeholder by range (`_` gets a unique name, `_X` a legal one)
local function head_snippet(cl, src)
    local head = cl.head
    local base = select(3, head:range(true))
    local text = T(head, src)
    local reps, n_ = {}, 0
    for _, v in ipairs(vars_of(head, src)) do
        local name = T(v, src)
        if name == '_' then n_ = n_ + 1; name = 'any' .. n_
        elseif name:sub(1, 1) == '_' then name = 'u' .. name:sub(2) end
        local _, _, sb, _, _, eb = v:range(true)
        reps[#reps + 1] = { s = sb - base, e = eb - base, to = '__' .. name, var = T(v, src), hole = name }
    end
    table.sort(reps, function (a, b) return a.s > b.s end)
    local holes = {}
    for _, r in ipairs(reps) do
        text = text:sub(1, r.s) .. r.to .. text:sub(r.e + 1)
        holes[r.var] = r.hole
    end
    return text, holes
end

-- the clause guard as a three-valued test over the matched values: a conjunction of `is_X(Var)` only
local function guard_fn(cl, src, holes, gk)
    if not cl.guard then return nil end
    local gcs = named(cl.guard)
    local tests, opaque = {}, #gcs ~= 1
    for _, e in ipairs(gcs[1] and named(gcs[1]) or {}) do
        local fe = e:type() == 'call' and field(e, 'expr')
        local a = fe and named(field(e, 'args') or e)
        local bif = fe and T(fe, src)
        if bif and gk[bif] and #a == 1 and a[1]:type() == 'var' and holes[T(a[1], src)] then
            tests[#tests + 1] = { bif = bif, hole = holes[T(a[1], src)], kinds = gk[bif], text = T(e, src) }
        else
            opaque = true
        end
    end
    local LIT = { atom = true, integer = true, float = true, string = true, binary = true, tuple = true, list = true, map_expr = true, char = true }
    return function (V)
        if opaque then return 'unknown', 'guard `' .. T(cl.guard, src) .. '` is not a conjunction of type tests' end
        for _, t in ipairs(tests) do
            local v = V[t.hole]
            local k = v and v.k
            local yes = false
            for _, kk in ipairs(t.kinds) do if kk == k then yes = true end end
            if not yes then
                if LIT[k] then return 'no', t.text end
                return 'unknown', t.text .. ' on a ' .. tostring(k)
            end
        end
        return 'yes'
    end
end

--- the generator an interpreter implies: one form per clause (in clause order: erlang tries them in order), the site
--- population restricted to VALUE positions, the output the effect call with each argument a head hole, a context
--- slot or its literal text.
function M.generator(it, chain, spec)
    local src = it.src
    local forms = {}
    local outer = {}
    for j, p in ipairs(it.fn.params) do if p then outer[p] = j end end
    for _, cl in ipairs(it.clauses) do
        local snippet, holes = head_snippet(cl, src)
        local parts = { cl.effect.mod .. '.' .. cl.effect.fn }
        for _, a in ipairs(cl.effect.args) do
            local t = T(a, src)
            if a:type() == 'var' and holes[t] then parts[#parts + 1] = '$' .. holes[t]
            elseif a:type() == 'var' and outer[t] then parts[#parts + 1] = '$ctx_' .. t
            else parts[#parts + 1] = (t:gsub('%$', '')) end
        end
        forms[#forms + 1] = { name = ('%s/%d @%d'):format(cl.tag, cl.arity, cl.line), site = snippet,
            guard = guard_fn(cl, src, holes, spec.guard_kinds or {}),
            out = { { kind = 'effect', parts = parts } } }
    end
    local pat = (spec.pattern and spec.pattern.fields) or {}
    local skip = spec.skip_call
    return {
        name = 'erlang.derived.' .. it.fn.name, lang = 'erlang', source = 'derived',
        why = ('%s:%d interprets these tuples'):format(it.file, it.line),
        -- a VALUE position: not inside a pattern (a match's lhs, a clause head, an arm's pattern — the grammar's
        -- pattern fields plus a function clause's own args) and not in a type context (the ones skip_call walks)
        site_ok = function (node, src)
            -- inside the callback the chain names (start/2), when there is one
            local cb
            for _, c in pairs(chain) do cb = cb or c.callback end
            if cb then
                local fc = node:parent()
                while fc and fc:type() ~= 'function_clause' do fc = fc:parent() end
                if not fc or T(field(fc, 'name'), src) ~= cb.fn or #named(field(fc, 'args') or fc) ~= cb.arity then return false end
            end
            local c, p = node, node:parent()
            while p do
                local f = pat[p:type()]
                if f and field(p, f) and field(p, f):id() == c:id() then return false end
                if p:type() == 'function_clause' and field(p, 'args') and field(p, 'args'):id() == c:id() then return false end
                c, p = p, p:parent()
            end
            return not (skip and skip(node))
        end,
        context = function (_, _, file)
            local ctx = {}
            for name, j in pairs(outer) do
                -- labelled assumption: the callback module is the file holding the tuple
                ctx['ctx_' .. name] = chain[j] and ((file or ''):match('([^/]+)%.erl$') or '?') or ('?' .. name)
            end
            return ctx
        end,
        forms = forms,
    }
end

return M
