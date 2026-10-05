-- erlclauses — WHICH CLAUSE A CALL REACHES, and its reverse: clauses no call reaches (CART-1110). erlang.
-- @langs erlang
--
-- ★★ A CALL SITE IS ITS CALLEE'S PEER (USER 2026-09-27, CART-1138: "function calls are basically peers to
-- functions"). The client/server merge one altitude down: the callee's clause heads are what it accepts, the call's
-- argument terms are what the caller sends, and first-match selection decides. Per call site to a function of
-- two or more clauses defined in the tree:
--   exact     one clause certainly takes it (every earlier clause says no, this one yes)
--   possible  one or more clauses may (a maybe: an unknown argument, an undecidable guard)
--   none      EVERY clause says no: a `function_clause` crash waiting — or a gap in reading the arguments. Each is
--             listed with its reason, never counted as a bug on its own.
-- And per function the clauses no call site reaches. Only for a function NOT exported, never taken as a fun value
-- (`fun f/1`), and one definition (not -ifdef variants): its callers are then all call sites in its module, so "no
-- call reaches it" is a claim about the whole program.
-- The argument terms come from erlterms WITHOUT summarizing calls (a call's result is a hole: a maybe, never a
-- wrong no), so this reads records, atoms, tuples, lists, bindings and patterns in scope.
local tsutil = require 'cartograph.spec.tsutil' -- (tsutil.inext: indexed child iteration, CART-1453)
local M = {}

local function txt(n, src) return vim.treesitter.get_node_text(n, src) end
local function named(x)
    local out = {}
    if x then for _, c in tsutil.inext, x, -1 do if c:named() then out[#out + 1] = c end end end
    return out
end

--- the census over the .erl files of `dir`. opts = { E = erlrecords env (record scopes) } -> rows, stats
---   row = { file, line, caller, callee = 'mod:fn/n', kind = 'exact' | 'possible' | 'none', clause = k | nil,
---           possible = { k… }, verdicts = { … } }
function M.census(dir, opts)
    opts = opts or {}
    local ET = require 'cartograph.erlterms'
    local P = ET.program { dirs = { dir }, E = opts.E }
    local stats = { files = 0, sites = 0, exact = 0, possible = 0, none = 0, functions = 0, clauses = 0,
        unreached = 0, exported_skipped = 0 }
    local rows, reached = {}, {}
    local modules = {}
    for _, f in ipairs(vim.fn.glob(dir .. '/*.erl', false, true)) do
        local name = vim.fn.fnamemodify(f, ':t:r')
        modules[#modules + 1] = name
    end
    table.sort(modules)
    local exported_cache = {}
    local function exports(m)
        if exported_cache[m.path] then return exported_cache[m.path] end
        local ex, all = {}, false
        for list in m.src:gmatch('%-export%s*%(%s*%[(.-)%]%s*%)') do
            for nm, ar in list:gmatch("'?([%w_@]+)'?%s*/%s*(%d+)") do ex[nm .. '/' .. ar] = true end
        end
        if m.src:find('export_all', 1, true) then all = true end
        -- a function taken as a FUN VALUE (`fun transform_listener/1` handed to lists:map) is called with whatever
        -- its receiver passes: no call site in the tree says which clause, so it is reachable by unknown callers
        local funref = {}
        for nm, ar in m.src:gmatch("fun%s+'?([%w_@]+)'?%s*/%s*(%d+)") do funref[nm .. '/' .. ar] = true end
        exported_cache[m.path] = { set = ex, all = all, funref = funref }
        return exported_cache[m.path]
    end
    for _, modname in ipairs(modules) do
        local m = P:module(modname)
        if m then
            stats.files = stats.files + 1
            local ctx = {}
            for k, v in pairs(m.ctx) do ctx[k] = v end
            ctx.program = nil   -- a call's result is a hole: the arguments are read, never summarized
            local function walk(x, fnname)
                for _, c in tsutil.inext, x, -1 do
                    local here = fnname
                    if c:type() == 'function_clause' then
                        local nn = c:field('name')[1]
                        here = nn and (txt(nn, m.src) .. '/' .. #named(c:field('args')[1])) or here
                    end
                    local callee_mod, callnode
                    if c:type() == 'call' and c:parent():type() ~= 'remote' then
                        callee_mod, callnode = modname, c
                    elseif c:type() == 'remote' then
                        local mn = c:field('module')[1]
                        local ma = mn and (mn:field('module')[1] or mn:named_child(0))
                        if ma and ma:type() == 'atom' then callee_mod = txt(ma, m.src):gsub("^'(.*)'$", '%1') end
                        callnode = c:field('fun')[1]
                    end
                    if callee_mod and callnode then
                        local e = callnode:field('expr')[1]
                        local argn = named(callnode:field('args')[1])
                        if e and e:type() == 'atom' then
                            local fn = txt(e, m.src):gsub("^'(.*)'$", '%1')
                            local cm = P:module(callee_mod)
                            local key = fn .. '/' .. #argn
                            local cls = cm and cm.fns[key]
                            if cls and #cls >= 2 then
                                stats.sites = stats.sites + 1
                                local S = ET.session()
                                local args = {}
                                for i, an in ipairs(argn) do args[i] = (ET.term(an, m.src, ctx, S)) end
                                local vs, runs = ET.clause_verdicts(P, callee_mod, fn, args, S)
                                vs, runs = vs or {}, runs or {}
                                -- first match within each definition; several definitions (-ifdef variants) make
                                -- a certain clause in one only a possible one overall
                                local kind, clause, possible = 'none', nil, {}
                                local stopped, nruns = {}, 0
                                for _, r in pairs(runs) do if r > nruns then nruns = r end end
                                for k, v in ipairs(vs) do
                                    local r = runs[k] or 1
                                    if not stopped[r] then
                                        if v == 'yes' then
                                            stopped[r] = true
                                            if nruns <= 1 then clause = k else possible[#possible + 1] = k end
                                        elseif v == 'maybe' then possible[#possible + 1] = k end
                                    end
                                    if clause then break end
                                end
                                if clause and #possible == 0 then kind = 'exact'
                                elseif clause or #possible > 0 then
                                    kind = 'possible'
                                    if clause then possible[#possible + 1] = clause end
                                end
                                stats[kind] = stats[kind] + 1
                                local id = callee_mod .. ':' .. key
                                reached[id] = reached[id] or {}
                                if clause then reached[id][clause] = true end
                                for _, k in ipairs(possible) do reached[id][k] = true end
                                rows[#rows + 1] = { file = modname .. '.erl', line = c:start() + 1, caller = here,
                                    callee = id, kind = kind, clause = kind == 'exact' and clause or nil,
                                    possible = possible, verdicts = vs, args = args }
                            end
                        end
                    end
                    walk(c, here)
                end
            end
            walk(m.root, nil)
        end
    end
    -- the reverse: clauses no in-tree call reaches, for functions whose callers are all in the tree
    local unreached = {}
    for _, modname in ipairs(modules) do
        local m = P:module(modname)
        if m then
            local ex = exports(m)
            local keys = {}
            for key in pairs(m.fns) do keys[#keys + 1] = key end
            table.sort(keys)
            for _, key in ipairs(keys) do
                local cls = m.fns[key]
                if #cls >= 2 then
                    stats.functions = stats.functions + 1
                    stats.clauses = stats.clauses + #cls
                    local id = modname .. ':' .. key
                    -- ONE function, or preprocessor VARIANTS of one (-ifdef(X) f() -> …; -else f() -> …): two fun_decls
                    -- of one name/arity are two definitions a build chooses between, not two clauses (erlvariants)
                    -- (each clause is its own fun_decl in the grammar; a DEFINITION ends at the clause whose text
                    -- ends with `.`, so two `.`-terminated runs of one name/arity are two definitions)
                    local runs = 0
                    for _, cl in ipairs(cls) do
                        if vim.trim(txt(cl:parent(), m.src)):sub(-1) == '.' then runs = runs + 1 end
                    end
                    if runs > 1 then stats.variants = (stats.variants or 0) + 1
                    elseif ex.all or ex.set[key] then stats.exported_skipped = stats.exported_skipped + 1
                    elseif ex.funref[key] then stats.fun_values = (stats.fun_values or 0) + 1
                    elseif reached[id] then
                        for k = 1, #cls do
                            if not reached[id][k] then
                                stats.unreached = stats.unreached + 1
                                unreached[#unreached + 1] = { callee = id, clause = k, line = cls[k]:start() + 1,
                                    file = modname .. '.erl' }
                            end
                        end
                    end
                end
            end
        end
    end
    return rows, stats, unreached
end

return M
