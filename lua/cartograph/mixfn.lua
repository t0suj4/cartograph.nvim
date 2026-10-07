-- cartograph.mixfn — ONE FUNCTION OF THE GRAPH AS A mix PROGRAM (CART-1445: the specializer in composable pieces).
-- The piece every per-function use of mix shares: the function's source slice, its header renamed to a standalone
-- `local function f(…)` (a method's `self` first), read losslessly and LOWERED. What it lowers ALONE: a module local
-- or helper it calls is a free name there — a global, dynamic — so every answer built on it is conservative about
-- anything outside the parameters (binding-times reports that as `outside`). The other pieces are mix's own exports:
-- bta (binding times), specialize, print, run (the oracle), describe (a located refusal).
local M = {}

local MX = function () return require 'cartograph.mix' end

--- a HOST function called with the argument list `a` ({ n = …, … }) -> its results as a list, EVERY one counted —
--- trailing nils included (mix's evaluator calls it: the counting needs varargs, and mix itself stays inside S without
--- them — CART-1511: `v(x, nil)` passed no extra value)
local function pack(...) return { n = select('#', ...), ... } end
function M.host_call(f, a) return pack(f(unpack(a, 1, a.n or #a))) end

--- ★ WITH ITS CALL CONE first (mixalg.program over the function's own file: its `M.x` and file-local helpers assembled
--- in, so a helper is code, not a free name) — and ALONE when the cone does not lower (a helper outside S) or the
--- function is a method (the assembly takes a header's written parameters: `self` is implicit).
--- -> prog, params (names, in order), entry (the function's name in prog), how = { cone = bool, members, why }
---  | nil, why, class
function M.lower_ref(store, ref)
    local id = type(ref) == 'table' and store.resolve_ref(ref) or ref
    local n = id and store.node(id)
    if n and tostring(n.file):match('%.lua$') and not tostring(n.name):find(':', 1, true) then
        local MA = require 'cartograph.mixalg'
        local key = tostring(n.name):match('^M%.') and n.name or (vim.fn.fnamemodify(n.file, ':t') .. '::' .. n.name)
        local okp, text, order, lines, knowns, _, prims = pcall(MA.program, key, { store.data.root .. '/' .. n.file })
        local why
        if okp then
            local term = require('cartograph.algebraread').read(text, 'lua')
            local okl, prog = pcall(MX().lower, term, { lines = lines })
            local entry = MA.mangle(key)
            if okl and prog.funcs[entry] then
                local names = {}
                for i, pid in ipairs(prog.funcs[entry].params) do names[i] = prog.names[pid] end
                -- (knowns, prims: the file's constants and primitives the cone reads — to bta and specialize as opts.globals, opts.prims)
                return prog, names, entry, { cone = true, members = #order, knowns = knowns, prims = prims }
            end
            why = okl and ('no entry ' .. entry) or M.why(prog)
        else why = tostring(text) end
        local prog, names, entry, how = M.lower_alone(store, ref)
        if prog then how.why = 'its call cone does not lower: ' .. why end
        return prog, names, entry, how
    end
    return M.lower_alone(store, ref)
end

--- the function ALONE: its header renamed to a standalone `local function f(…)` -> prog, params, 'f', { cone = false }
function M.lower_alone(store, ref)
    local id = type(ref) == 'table' and store.resolve_ref(ref) or ref
    local n = id and store.node(id)
    if not n then return nil, ('the function does not resolve (%s)'):format(vim.inspect(ref)), 'stale' end
    if not tostring(n.file):match('%.lua$') then return nil, ('mix reads Lua; %s is not a .lua file'):format(tostring(n.file)), 'unbuilt' end
    local text = require('cartograph.txn').read_file(store.data.root, n.file)
    if not text then return nil, ('cannot read %s'):format(n.file), 'stale' end
    local at = require 'cartograph.at'
    local lines = vim.split(text, '\n', { plain = true })
    local sl, el = at.sl(n.range), at.el(n.range)
    local src = table.concat(vim.list_slice(lines, sl + 1, el + 1), '\n'):gsub('^%s+', '')
    local params = src:match('^[^(]*%(([^)]*)%)')
    if not params then return nil, ('%s: no parameter list in its first line'):format(tostring(n.name)), 'unbuilt' end
    local method = src:match('^function%s+[%w_.]+:[%w_]+%s*%(') ~= nil
    local body
    if src:match('^local%s+function%s') then body = src:gsub('^local%s+function%s+[%w_]+%s*%(', 'local function f(', 1)
    elseif src:match('^function%s') then body = src:gsub('^function%s+[%w_.:]+%s*%(', method and 'local function f(self, ' or 'local function f(', 1)
    else return nil, ('%s: the header is not `function NAME(…)` / `local function NAME(…)`'):format(tostring(n.name)), 'unbuilt' end
    body = body:gsub('^local function f%(self, %)', 'local function f(self)')
    local term = require('cartograph.algebraread').read(body, 'lua')
    if not term then return nil, ('%s does not read as Lua'):format(tostring(n.name)), 'unbuilt' end
    local okl, prog = pcall(MX().lower, term)
    if not okl then return nil, ('%s is outside mix\'s subset: %s'):format(tostring(n.name), M.why(prog)), 'unbuilt' end
    local names = {}
    for i, pid in ipairs(prog.funcs.f.params) do names[i] = prog.names[pid] end
    return prog, names, 'f', { cone = false }
end

--- the ENVIRONMENT a residual loads in: the constant pool as MIXK, every KNOWN global (opts.globals — mixalg.program's
--- `knowns`) at its dotted path, the rest of _G behind them. A known reaching dynamic code is residualized as its PATH
--- (`fix__RULES[a]`), so a residual loaded without its knowns reads nil (CART-1374). A path whose root is already set
--- (`x.f` when `x` is known) is the root's own field and is not written over. `prims` (mix's opts.prims — the program's
--- own primitives, e.g. mixalg's ALWAYS_OPAQUE) are placed the same way: the residual CALLS them by their path, so a
--- residual loaded without them calls nil (CART-1528).
function M.env(pool, globals, extra, prims)
    local env = { MIXK = pool }
    for k, v in pairs(extra or {}) do env[k] = v end
    if prims then
        local all = {}
        for k, v in pairs(globals or {}) do all[k] = v end
        for k, v in pairs(prims) do if all[k] == nil then all[k] = v end end
        globals = all
    end
    local keys = vim.tbl_keys(globals or {})
    table.sort(keys, function (a, b) local na, nb = select(2, a:gsub('%.', '')), select(2, b:gsub('%.', '')); if na ~= nb then return na < nb end return a < b end)
    for _, path in ipairs(keys) do
        local parts = vim.split(path, '.', { plain = true })
        local t = env
        for i = 1, #parts - 1 do
            if t[parts[i]] == nil then t[parts[i]] = {} end
            t = t[parts[i]]
            if type(t) ~= 'table' then t = nil; break end
        end
        if t and t[parts[#parts]] == nil then t[parts[#parts]] = globals[path] end
    end
    return setmetatable(env, { __index = _G })
end

--- a mix error (a refusal record or a message) as one sentence
function M.why(e)
    if type(e) == 'table' and e.refusal then return MX().describe(e) end
    return tostring(e)
end

local RANK = { S = 1, C = 2, D = 3 }
local function join(a, b) if RANK[a] >= RANK[b] then return a end return b end
local function opnd(b) if b == 'C' then return 'D' end return b end

--- the binding time of f's RESULT under bt (mix.bta's answer): the join over every `return`, each under the binding
--- time of the control it sits in (a return under a dynamic condition is a dynamic result)
function M.result_bt(prog, bt, entry)
    local bte = MX()._bt_expr
    local function walk(stmts, ctrl)
        local r = 'S'
        for _, s in ipairs(stmts or {}) do
            local op = s.op
            if op == 'ret' then
                for _, e in ipairs(s.es or {}) do r = join(r, join(ctrl, bte(e, bt))) end
            elseif op == 'if' then
                local c = ctrl
                for _, cl in ipairs(s.clauses) do
                    c = join(c, opnd(bte(cl.cond, bt)))
                    r = join(r, walk(cl.body, c))
                end
                r = join(r, walk(s.els, c))
            elseif op == 'fornum' or op == 'forin' or op == 'forgen' or op == 'while' or op == 'repeat' then
                local c = join(ctrl, bt[s] or 'S')
                if op == 'fornum' then c = join(c, opnd(join(bte(s.from, bt), join(bte(s.to, bt), bte(s.step, bt)))))
                elseif op == 'forin' then c = join(c, opnd(bte(s.e, bt)))
                elseif op == 'forgen' then for _, e in ipairs(s.es) do c = join(c, opnd(bte(e, bt))) end
                else c = join(c, opnd(bte(s.cond, bt))) end
                r = join(r, walk(s.body, c))
            elseif op == 'do' then r = join(r, walk(s.body, ctrl)) end
        end
        return r
    end
    return walk(prog.funcs[entry or 'f'].body, 'S')
end

return M
