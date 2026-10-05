-- cartograph.mixfn — ONE FUNCTION OF THE GRAPH AS A mix PROGRAM (CART-1445: the specializer in composable pieces).
-- The piece every per-function use of mix shares: the function's source slice, its header renamed to a standalone
-- `local function f(…)` (a method's `self` first), read losslessly and LOWERED. What it lowers ALONE: a module local
-- or helper it calls is a free name there — a global, dynamic — so every answer built on it is conservative about
-- anything outside the parameters (binding-times reports that as `outside`). The other pieces are mix's own exports:
-- bta (binding times), specialize, print, run (the oracle), describe (a located refusal).
local M = {}

local MX = function () return require 'cartograph.mix' end

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
        local okp, text, order, lines, knowns = pcall(MA.program, key, { store.data.root .. '/' .. n.file })
        local why
        if okp then
            local term = require('cartograph.algebraread').read(text, 'lua')
            local okl, prog = pcall(MX().lower, term, { lines = lines })
            local entry = MA.mangle(key)
            if okl and prog.funcs[entry] then
                local names = {}
                for i, pid in ipairs(prog.funcs[entry].params) do names[i] = prog.names[pid] end
                -- (knowns: the file's constants the cone reads — static to bta and specialize as opts.globals)
                return prog, names, entry, { cone = true, members = #order, knowns = knowns }
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
