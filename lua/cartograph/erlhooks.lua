-- erlhooks — A KEYED REGISTRY'S DISPATCH: from each site that RUNS a key to the handlers REGISTERED under it
-- (CART-1130 step 3, CART-1128). erlang.
-- @langs erlang
--
-- ★ BOTH SIDES ARE IN THE TREE, AND BOTH ARE DERIVED. ejabberd's hooks: a module registers a handler under a hook
-- name — by a `{hook, Name, Function, Seq}` tuple its start/2 returns (read by the interpreter gen_mod states,
-- cartograph.erlderive) or by a direct `ejabberd_hooks:add(Name, Host, Module, Function, Seq)` — and something
-- elsewhere runs the name: `ejabberd_hooks:run_fold(Name, Host, Acc, Args)`. The call graph saw neither half as an
-- edge. Nothing below names ejabberd, hooks, `add` or `run`:
--   REGISTERING VERBS  the effect calls of the generating interpreter (erlderive: the one whose effect is a
--                      carrier's registering verb) — here add, subscribe, add_iq_handler, register_commands.
--   REGISTRATIONS      the derived facts whose effect is such a verb, plus every direct call to it.
--   DISPATCH SITES     calls into the SAME module as a registering verb, with a verb that is no interpreter's effect
--                      (the unregistering twin's delete/unsubscribe are effects too, and excluded) AND whose definition
--                      INVOKES a handler: it makes a dynamic call (`Mod:f(...)`, apply/3) itself or through that
--                      module's own functions. A shared key alone is not dispatch — gen_iq_handler:get_features/2 and
--                      start/1 take the component key and call nothing (3 of the first run's 5 iq "dispatch" sites).
--   THE KEY POSITION   the (registration argument, dispatch argument) pair whose literal values OVERLAP most —
--                      greenspun's own test (an import verb shares keys with an export).
--   THE HANDLER        the (module, function) pair among a registration's arguments that RESOLVES: an argument naming
--                      a module of the tree and a later one naming a function it defines.
-- Each dispatch site gets a hedged `ref` to every handler registered under its key (`hook = key`); the ARITY is
-- not matched (run passes a list whose length is the handler's arity, often not a literal). Keys run with no
-- registration anywhere in the tree, and registrations never run, are reported: the first is the extension surface
-- for out-of-tree modules, or dead dispatch.
-- ⚠ SESSION-LIVE, a post-pass (cartograph.postpass).
local M = {}

local D = require 'cartograph.erlderive'
local G = require 'cartograph.generators'

local function read(p)
    local fd = io.open(p, 'rb'); if not fd then return nil end
    local s = fd:read('a'); fd:close(); return s
end

local function verb_of(full) return full and full:match('^([%w_]+%.[%w_]+)') end

function M.attach(data)
    local stats = { registrations = 0, from_tuples = 0, from_calls = 0, sites = 0, edges = 0, keys = {},
        unregistered = {}, unrun = {}, verbs = {} }
    local root = data and data.root
    if not root or root:match('^%w+://') then return stats end
    local ts = require 'cartograph.providers.treesitter'
    -- modules of the tree and the functions each defines
    local files, modfile, fns = {}, {}, {}
    for _, n in ipairs(data.nodes or {}) do
        if n.kind == 'module' and n.file and n.file:match('%.erl$') then
            local src = read(root .. '/' .. n.file)
            if src then files[#files + 1] = { rel = n.file, src = src } end
            modfile[n.file:match('([^/]+)%.erl$')] = n.file
        elseif n.kind == 'function' and n.file and n.file:match('%.erl$') then
            fns[n.file] = fns[n.file] or {}
            fns[n.file][n.name] = fns[n.file][n.name] or {}
            table.insert(fns[n.file][n.name], n.id)
        end
    end
    -- the interpreters, the generating one, every interpreter's effect verbs
    local interps, effects = {}, {}
    for _, f in ipairs(files) do
        for _, it in ipairs(D.find(f.src, f.rel)) do
            interps[#interps + 1] = it
            for _, cl in ipairs(it.clauses) do effects[cl.effect.mod .. '.' .. cl.effect.fn] = true end
        end
    end
    local carrier = {}
    for _, b in ipairs(require('cartograph.xlang').default_bindings) do
        local v = b.export and b.export.verb
        if type(v) == 'string' then carrier[v] = true elseif type(v) == 'table' then for _, x in ipairs(v) do carrier[x] = true end end
    end
    local gen_it
    for _, it in ipairs(interps) do
        for _, cl in ipairs(it.clauses) do if carrier[cl.effect.fn] then gen_it = gen_it or it end end
    end
    if not gen_it then return stats end
    local registering = {}
    for _, cl in ipairs(gen_it.clauses) do registering[cl.effect.mod .. '.' .. cl.effect.fn] = true end
    -- REGISTRATIONS: { verb, args = {text|false…}, file, line, how }
    local regs = {}
    local gen = D.generator(gen_it, D.context_chain(gen_it, files), ts.spec.erlang)
    for _, f in ipairs(files) do
        local ok, p = pcall(vim.treesitter.get_string_parser, f.src, 'erlang')
        local r = ok and p:parse()[1]:root()
        for _, fa in ipairs(r and (G.read(gen, r, f.src, f.rel)) or {}) do
            local v = fa.parts[1]
            if registering[v] then
                local args = {}
                for i = 2, #fa.parts do args[#args + 1] = fa.parts[i] end
                regs[#regs + 1] = { verb = v, args = args, file = f.rel, line = fa.site[1] + 1, how = 'tuple' }
                stats.from_tuples = stats.from_tuples + 1
            end
        end
    end
    for _, c in ipairs(data.calls or {}) do
        local v = verb_of(c.full)
        if v and registering[v] and c.argv then
            local args, any = {}, false
            for i, a in ipairs(c.argv) do args[i] = (a.k == 'lit' or a.k == 'scalar') and a.v or false; any = any or args[i] end
            -- a call with no literal argument names no key: the interpreter's OWN effect call
            -- (`hooks:add(Hook, Host, Module, Function, Seq)` inside gen_mod) is the mechanism, not a registration
            if any then
                regs[#regs + 1] = { verb = v, args = args, file = c.file, line = c.line and c.line + 1, how = 'call' }
                stats.from_calls = stats.from_calls + 1
            else
                stats.unkeyed = (stats.unkeyed or 0) + 1
            end
        end
    end
    stats.registrations = #regs
    -- DISPATCH SITES per registering verb: calls into its module, verbs that are no interpreter's effect
    local by_verb = {}
    for _, rg in ipairs(regs) do by_verb[rg.verb] = by_verb[rg.verb] or {}; table.insert(by_verb[rg.verb], rg) end
    local refEdge = {}
    for _, e in ipairs(data.edges or {}) do if e.kind == 'ref' then refEdge[e.from .. '\31' .. e.to] = e end end
    -- the functions of a module that INVOKE something dynamic, directly or through the module's own functions
    local invokes_memo = {}
    local function invokers(file)
        if invokes_memo[file] then return invokes_memo[file] end
        local set, callers = {}, {}
        for _, c in ipairs(data.calls or {}) do
            if c.file == file and c.fn and (c.dynamic or (c.callee == 'apply' and #(c.argv or {}) == 3)) then set[c.fn] = true end
        end
        for _, e in ipairs(data.edges or {}) do
            if e.kind == 'ref' and e.from:sub(1, #file + 2) == file .. '::' and e.to:sub(1, #file + 2) == file .. '::' then
                callers[e.to] = callers[e.to] or {}; table.insert(callers[e.to], e.from)
            end
        end
        local stack = {}
        for id in pairs(set) do stack[#stack + 1] = id end
        while #stack > 0 do
            local id = table.remove(stack)
            for _, from in ipairs(callers[id] or {}) do
                if not set[from] then set[from] = true; stack[#stack + 1] = from end
            end
        end
        local names = {}
        for id in pairs(set) do local nm = id:match('::([^@]+)@'); if nm then names[nm] = true end end
        invokes_memo[file] = names
        return names
    end
    for verb, rs in pairs(by_verb) do
        local mod = verb:match('^([%w_]+)%.')
        local inv = modfile[mod] and invokers(modfile[mod]) or {}
        local disp = {}
        for _, c in ipairs(data.calls or {}) do
            local v = verb_of(c.full)
            if v and v:match('^' .. mod .. '%.') and not effects[v] and c.argv and c.fn and inv[v:match('%.([%w_]+)$')] then
                disp[#disp + 1] = c
            end
        end
        -- the key position: the (registration arg, dispatch arg) pair of most overlapping literal values
        local best, bp, bq = 0, nil, nil
        for p = 1, 6 do
            local rv = {}
            for _, rg in ipairs(rs) do if rg.args[p] then rv[rg.args[p]] = true end end
            for q = 1, 4 do
                local n = 0
                local seenv = {}
                for _, c in ipairs(disp) do
                    local a = c.argv[q]
                    if a and a.k == 'lit' and rv[a.v] and not seenv[a.v] then seenv[a.v] = true; n = n + 1 end
                end
                if n > best then best, bp, bq = n, p, q end
            end
        end
        if bp then
            -- handlers by key: the resolving (module, function) pair among the other arguments
            local handlers = {}
            for _, rg in ipairs(rs) do
                local key = rg.args[bp]
                if key then
                    local hit
                    for i = 1, #rg.args do
                        local mf = i ~= bp and rg.args[i] and modfile[rg.args[i]]
                        if mf then
                            for j = i + 1, #rg.args do
                                local ids = j ~= bp and rg.args[j] and fns[mf] and fns[mf][rg.args[j]]
                                if ids then hit = ids; break end
                            end
                        end
                        if hit then break end
                    end
                    handlers[key] = handlers[key] or {}
                    for _, id in ipairs(hit or {}) do handlers[key][id] = true end
                end
            end
            local run = {}
            for _, c in ipairs(disp) do
                local a = c.argv[bq]
                local key = a and a.k == 'lit' and a.v
                if key then
                    stats.sites = stats.sites + 1
                    run[key] = true
                    local hs = handlers[key]
                    if not hs then stats.unregistered[key] = (stats.unregistered[key] or 0) + 1 end
                    for id in pairs(hs or {}) do
                        if id ~= c.fn then
                            local k = c.fn .. '\31' .. id
                            local e = refEdge[k]
                            if not e then
                                e = { from = c.fn, to = id, kind = 'ref', at = {}, inferred = true, hook = key }
                                refEdge[k] = e
                                data.edges[#data.edges + 1] = e
                                stats.edges = stats.edges + 1
                            end
                            if c.at then e.at[#e.at + 1] = c.at end
                        end
                    end
                end
            end
            for key in pairs(handlers) do
                stats.keys[key] = true
                if not run[key] then stats.unrun[key] = true end
            end
            stats.verbs[#stats.verbs + 1] = { verb = verb, key_arg = bp, dispatch_arg = bq, overlap = best, dispatch = #disp }
        end
    end
    data.erlhooks = stats
    return stats
end

function M.summary(s)
    if not s or s.edges == 0 then return nil end
    local nu = 0
    for _ in pairs(s.unregistered) do nu = nu + 1 end
    return ('erlhooks: %d registration(s) (%d tuple, %d call), %d dispatch site(s), %d handler edge(s); %d key(s) run '
        .. 'with no registration in the tree'):format(s.registrations, s.from_tuples, s.from_calls, s.sites, s.edges, nu)
end

return M
