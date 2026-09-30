-- cartograph.luajs.cpath — ARGUMENT TYPES BY PATH: for any C function over the Lua API, which value tags each argument
-- slot may hold on the paths that reach no no-return raiser (CART-1240 leaf 2). No checker is named: a three-valued
-- interpreter walks the preprocessed C, the slot holding the SET of every tag (each a REPRESENTATIVE the compiler
-- builds with LuaJIT's own setters) at every argument count, one run per (function, position).
--
-- Every fact is the tree's: the tags and their setters (lj_obj.h), lua.h's type codes, the no-return raisers (the
-- noreturn macros), TValue's layout (the compiler's), a sentinel's tag (its initializer: setnilV(&g->nilnode.val)),
-- the result convention (lj_lib.h's FFH_RES / FFH_RETRY), the first-class tags (the API's own lua_type), a builtin's
-- meaning (cartograph.cjs.BUILTINS). A tag per position is ALWAYS accepted, CONTENT-dependent (some paths return,
-- some reject: a numeric string), or NEVER; ABSENT is one more.
-- LOOPS without unrolling (CART-1240 leaf 3): each body runs over its EXECUTABLE graph (cfg.graph) to a fixpoint — a
-- node joins what reaches it within a loop token, a loop head keeps up to 8 distinct states and then WIDENS; goto,
-- break, continue and a switch's fall-through are edges. The STACK is a value of the path: L->top / L->base move
-- (lua_settop's fill loop), and a reallocated stack keeps its indices (the origin is wherever L->stack points).
-- ⚠ LIMITS, reported and never silent: the per-run step budget (`over`); an FFI conversion is content-dependent; a
-- recursive call is OPTIMISTIC (every element returns, the stack where it was — CART-1243); a char* step counts
-- TValues, not bytes (CART-1244).
local M = {}

local function readfile(p) local fd = io.open(p, 'rb'); if not fd then return nil end local s = fd:read('a'); fd:close(); return s end

--- the TAGS and their representatives, from the compiler: every `#define LJ_T<NAME> (~Nu)` of lj_obj.h, built with the
--- setter lj_obj.h itself gives its kind (a primitive — at or above LJ_TISPRI — through setpriV, the number through
--- setnumV, a GC object through setgcVraw), printed as its 64-bit word; and every `tvis*` predicate over every one of
--- them (the REFERENCE the interpreter must reproduce) -> { order = { names }, tag = { [name] = { value, u64 } },
--- tvis = { names }, matrix = { [pred] = { [name] = 0|1 } } } | nil, why
function M.reps(src, cflags, header)
    header = header or (src .. '/lj_obj.h')
    local objh = readfile(header) or ''
    local order, seen = {}, {}
    for name in objh:gmatch('#define%s+LJ_T(%u+)%s+%(~%d+u%)') do if not seen[name] then seen[name] = true; order[#order + 1] = name end end
    local preds, pseen = {}, {}
    for p in objh:gmatch('#define%s+(tvis[%w_]+)%(o%)') do if not pseen[p] then pseen[p] = true; preds[#preds + 1] = p end end
    local body = { '  static double cell[8]; TValue v;' }
    for _, name in ipairs(order) do
        local T = 'LJ_T' .. name
        body[#body + 1] = ('  if (%s >= LJ_TISPRI) setpriV(&v, %s); else if (%s == LJ_TNUMX) setnumV(&v, 1.5); else setgcVraw(&v, (GCobj *)cell, %s);'):format(T, T, T, T)
        local row = {}
        for _, p in ipairs(preds) do row[#row + 1] = ('%s(&v) ? 1 : 0'):format(p) end
        body[#body + 1] = ('  printf("%s %%u %%016llx'):format(name) .. string.rep(' %d', #preds) .. ('\\n", (unsigned)%s, (unsigned long long)v.u64, %s);'):format(T, table.concat(row, ', '))
    end
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    local c = tmp .. '/reps.c'
    local fd = assert(io.open(c, 'w'))
    fd:write('#include <stdio.h>\n#include "' .. vim.fn.fnamemodify(header, ':t') .. '"\nint main(void) {\n', table.concat(body, '\n'), '\n  return 0;\n}\n')
    fd:close()
    local cmd = { 'gcc', '-w', '-o', tmp .. '/reps' }
    vim.list_extend(cmd, cflags or {})
    vim.list_extend(cmd, { '-I' .. src, c })
    local r = vim.system(cmd, { text = true }):wait()
    if r.code ~= 0 then vim.fn.delete(tmp, 'rf'); return nil, 'the representatives program failed: ' .. (r.stderr or '') end
    local out = vim.system({ tmp .. '/reps' }, { text = true }):wait().stdout or ''
    vim.fn.delete(tmp, 'rf')
    local R = { order = order, tag = {}, tvis = preds, matrix = {} }
    for _, p in ipairs(preds) do R.matrix[p] = {} end
    for line in out:gmatch('[^\n]+') do
        local f = vim.split(line, ' ', { plain = true })
        R.tag[f[1]] = { value = tonumber(f[2]), u64 = f[3] }
        for i, p in ipairs(preds) do R.matrix[p][f[1]] = tonumber(f[3 + i]) end
    end
    return R
end

-- ── THE INTERPRETER is cartograph.cinterp (general C); this module is its LuaJIT ADAPTER ────────────────────────────
local CI = require 'cartograph.cinterp'
local ffi = require 'ffi'
local int, asnum, literal, elem, at, tx, kids = CI._int, CI.asnum, CI._literal, CI.elem, CI.at, CI.tx, CI.kids
M._int, M._truth, M._binop, M.INT, M.ctype, M._literal, M._field, M.analyzer = CI._int, CI._truth, CI._binop, CI.INT, CI.ctype, CI._literal, CI._field, CI.analyzer
M.thread = CI.thread

--- THE FRAME, from the tree — nothing named but the API's own count: lua_gettop's `return top - base` names the
--- THREAD type (its parameter's) and the frame's two fields, top the minuend; the ORIGIN is the field the frame's
--- REBASE subtracts (a reallocation: `delta = new - old` with old read from thread->F, then top moved by delta; none
--- found, none modelled) -> { thread, top, base, origin, origin_in } | nil, why
function M.frame(ctx)
    local g = ctx.defs.lua_gettop
    if not (g and g.params[1] and g.params[1].pointee) then return nil, 'no lua_gettop(<thread> *) in the tree' end
    local fr = { thread = g.params[1].pointee }
    local function strip(n)
        while n and (n:type() == 'cast_expression' or n:type() == 'parenthesized_expression') do
            n = n:type() == 'cast_expression' and n:field('value')[1] or kids(n)[1]
        end
        return n
    end
    -- `p->f` under casts and parens -> f
    local function pfield(n, src, p)
        n = strip(n)
        if n and n:type() == 'field_expression' and tx(n:field('operator')[1], src) == '->' then
            local a = strip(n:field('argument')[1])
            if a and a:type() == 'identifier' and tx(a, src) == p then return tx(n:field('field')[1], src) end
        end
        return nil
    end
    local function find_pfield(n, src, p)
        local f = pfield(n, src, p)
        if f then return f end
        for c in n:iter_children() do if c:named() then f = find_pfield(c, src, p); if f then return f end end end
        return nil
    end
    local mq = vim.treesitter.query.parse('c', '(binary_expression operator: "-") @b')
    for _, b in mq:iter_captures(g.node, g.src, 0, -1) do
        local l, r = pfield(b:field('left')[1], g.src, g.params[1].name), pfield(b:field('right')[1], g.src, g.params[1].name)
        if l and r then fr.top, fr.base = l, r; break end
    end
    if not fr.top then return nil, 'lua_gettop reads no `top - base` of its thread' end
    -- the REBASE: `thread->top = … + delta …`, `delta = new - old`, `old = … thread->F …`
    local vq = vim.treesitter.query.parse('c', [[
        (init_declarator declarator: (_) @d value: (_) @v)
        (assignment_expression left: (identifier) @d right: (_) @v)]])
    local aq = vim.treesitter.query.parse('c', '(assignment_expression left: (field_expression) @l right: (_) @r)')
    local found = {}
    for _, d in pairs(ctx.defs) do
        local p
        for _, pp in ipairs(d.params) do if pp.pointee == fr.thread then p = pp.name end end
        if p and tx(d.node, d.src):find('%->%s*' .. fr.top .. '%s*=') then
            local val = {}
            local dn
            for id, node in vq:iter_captures(d.node, d.src, 0, -1) do
                if vq.captures[id] == 'd' then
                    dn = node
                    while dn and dn:type() == 'pointer_declarator' do dn = dn:field('declarator')[1] end
                elseif dn and dn:type() == 'identifier' then val[tx(dn, d.src)] = node end
            end
            local lhs
            for id, node in aq:iter_captures(d.node, d.src, 0, -1) do
                if aq.captures[id] == 'l' then lhs = pfield(node, d.src, p)
                elseif lhs == fr.top then
                    local function idents(n)
                        if n:type() == 'identifier' then
                            local dv = val[tx(n, d.src)] and strip(val[tx(n, d.src)])
                            if dv and dv:type() == 'binary_expression' and tx(dv:field('operator')[1], d.src) == '-' then
                                local old = strip(dv:field('right')[1])
                                local ov = old and old:type() == 'identifier' and val[tx(old, d.src)]
                                local f = ov and find_pfield(ov, d.src, p)
                                if f and f ~= fr.top and f ~= fr.base then found[f] = d.name end
                            end
                        end
                        for c in n:iter_children() do if c:named() then idents(c) end end
                    end
                    idents(node)
                end
            end
        end
    end
    local fs = vim.tbl_keys(found)
    if #fs == 1 then fr.origin, fr.origin_in = fs[1], found[fs[1]] end
    return fr
end

--- a function's ACCEPTANCE at one slot: every first-class tag (the number at several values) in ONE run per argument
--- count, ABSENT in one more -> { [tag] = 'always' | 'content' | 'never' }, over, the return values seen
function M.acceptance(A, ctx, d, args, pos, maxcount)
    local tags = {}
    for _, t in ipairs(ctx.reps.order) do
        if ctx.firstclass[t] then
            if t == ctx.numtag then for _, v in ipairs(ctx.numvars) do tags[v] = true end else tags[t] = true end
        end
    end
    -- ONE run: every (tag, count) with the slot present, and ABSENT at every count below it
    local set = {}
    for count = pos, maxcount do for t in pairs(tags) do set[t .. '@' .. count] = true end end
    for count = 0, pos - 1 do set['ABSENT@' .. count] = true end
    local slots = {}
    for i = 1, maxcount do if i ~= pos then slots[i] = '?' end end
    A.steps = 0 -- (the budget is PER RUN)
    local sum = A.run(d, args, slots, pos, set, false)
    local ret, rej, rets = {}, {}, {}
    for e in pairs(set) do
        local t = elem(e)
        if sum.ret[e] then ret[t] = true end
        if sum.rej[e] or not sum.ret[e] then rej[t] = true end
    end
    for _, r in ipairs(sum.returns or {}) do for e in pairs(r.fset) do rets[#rets + 1] = at(r.v, e) or false end end
    local over = sum.over
    -- (the number's VALUES join back into one tag: some accepted and some rejected is content-dependent)
    local out = {}
    for t in pairs(tags) do
        local base = ctx.numof[t] or t
        local r0 = out[base] or { ret = false, rej = false }
        r0.ret, r0.rej = r0.ret or (ret[t] or false), r0.rej or (rej[t] or false)
        out[base] = r0
    end
    out.ABSENT = { ret = ret.ABSENT or false, rej = rej.ABSENT or false }
    for t, b in pairs(out) do out[t] = b.ret and (b.rej and 'content' or 'always') or 'never' end
    return out, over, rets
end

--- THE CONTEXT: every fact DERIVED from the tree (cartograph.cinterp.facts — each by the evidence it finds, none by
--- a runtime's name) -> the interpreter's ctx plus this adapter's facts (numbers, first-class tags, type names, the
--- result rule) and ctx.facts, the whole table. A fact that does not derive raises, naming its gap.
function M.context(src)
    local FT = require 'cartograph.cinterp.facts'
    local T = FT.derive({ src = src })
    local got, miss = T.got, {}
    for _, f in ipairs({ 'units', 'noret', 'frame', 'layout', 'reps', 'sentinels', 'builtins', 'numbers', 'firstclass', 'typenames', 'result' }) do
        if got[f] == nil then miss[#miss + 1] = f .. ' (' .. tostring(T.rows[f] and T.rows[f].gap) .. ')' end
    end
    if #miss > 0 then error('cpath: facts not derived: ' .. table.concat(miss, '; ')) end
    local ctx = FT.ctx(got)
    ctx.numtag, ctx.numvars, ctx.numof = got.numbers.numtag, got.numbers.numvars, got.numbers.numof
    ctx.firstclass, ctx.typenames, ctx.result, ctx.facts = got.firstclass, got.typenames, got.result, T
    return ctx
end

-- ── THE MEASUREMENT ────────────────────────────────────────────────────────────────────────────────────────────────
--- a position's reading as type() names: accepted (always or content-dependent), always, the absent and nil status,
--- and whether it is TAG-INDEPENDENT (every first-class tag the same status: an unread or `any` position)
function M.reading(acc, tn)
    local a, al, statuses = {}, {}, {}
    for tag, st in pairs(acc) do
        if tag ~= 'ABSENT' then
            statuses[st] = true
            if st ~= 'never' then a[tn[tag]] = true end
            if st == 'always' then al[tn[tag]] = true end
        end
    end
    local function l(set) local x = vim.tbl_keys(set); table.sort(x); return x end
    return { accepted = l(a), always = l(al), absent = acc.ABSENT, nilst = acc.NIL, untyped = vim.tbl_count(statuses) == 1 }
end

--- the COMPARISON of a path reading with a checker's (leaf 1's) at one position, both as type() names: nil acceptance
--- is optionality on both sides, a checker's `any` is every first-class type -> nil (the same) | a named difference
--- ('finer: also accepts …' — a coercion or a value the checker's name did not say; 'narrower: rejects …'; or both)
function M.compare(path_acc, path_opt, chk_acc, chk_opt, firstnames)
    local a, b = {}, {}
    for _, t in ipairs(path_acc) do a[t] = true end
    for _, t in ipairs(chk_acc) do
        if t == 'any' then for n in pairs(firstnames) do b[n] = true end else b[t] = true end
    end
    -- OPTIONAL means may be ABSENT on both sides (checkany takes nil as a value, and rejects absence); a checker that
    -- is optional also accepts nil
    if chk_opt then b['nil'] = true end
    local more, less = {}, {}
    for t in pairs(a) do if not b[t] then more[#more + 1] = t end end
    for t in pairs(b) do if not a[t] then less[#less + 1] = t end end
    table.sort(more); table.sort(less)
    local out = {}
    if #more > 0 then out[#out + 1] = 'finer: also accepts ' .. table.concat(more, '|') end
    if #less > 0 then out[#out + 1] = 'narrower: rejects ' .. table.concat(less, '|') end
    if (path_opt or false) ~= (chk_opt or false) then out[#out + 1] = ('optional: path %s / checker %s'):format(tostring(path_opt), tostring(chk_opt)) end
    if #out == 0 then return nil end
    return table.concat(out, '; ')
end

--- opts: { src, cflags, config, positions = K (default 4), witness = bool, leaf1 = csig's measure (for the JOIN) }
function M.measure(opts)
    local PM, OJ = require 'cartograph.luajs.packmap', require 'cartograph.oraclejoin'
    local src = opts.src
    local t0 = vim.uv.hrtime()
    local ctx = M.context(src)
    local tn = ctx.typenames
    local reg = ctx.facts.got.registrations or PM.registrations(src, opts.config)
    local _, where = PM.oracle_library(reg)
    local rr = ctx.result
    local A = M.analyzer(ctx)
    local K = opts.positions or 4
    local rows, stats = {}, { functions = 0, positions = 0, typed = 0, untyped = 0, over = 0, raise_only = 0 }
    for _, f in ipairs(reg.funcs) do
        local rname = where[f.module]
        if not f.noreg and rname and f.cfn and ctx.defs[f.cfn] then
            local q = (rname == '_G' and '' or (rname .. '.')) .. f.name
            local d = ctx.defs[f.cfn]
            local row = { cfn = f.cfn, kind = f.kind, pos = {} }
            local results = {}
            local anyret = false
            for k = 1, K do
                local acc, over, rets = M.acceptance(A, ctx, d, { CI.thread(), n = 1 }, k, K + 1)
                for _, v in ipairs(rets) do results[#results + 1] = v end
                local r = M.reading(acc, tn)
                r.over = over
                row.pos[k] = r
                if #r.accepted > 0 or r.absent ~= 'never' then anyret = true end
                stats.positions = stats.positions + 1
                if r.untyped then stats.untyped = stats.untyped + 1 else stats.typed = stats.typed + 1 end
                if over then stats.over = stats.over + 1 end
            end
            -- a C body that NEVER returns (the VM's fast path handles success; the C only raises: assert)
            row.raise_only = not anyret
            if row.raise_only then stats.raise_only = stats.raise_only + 1 end
            -- RESULT COUNTS
            local counts, unknown = {}, false
            for _, v in ipairs(results) do
                if v and v.k == 'i' then
                    local n = asnum(v)
                    if f.kind == 'CF' then counts[n] = true
                    elseif rr.offset and n ~= rr.retry then counts[n - rr.offset] = true end
                else unknown = true end
            end
            local cl = vim.tbl_keys(counts); table.sort(cl)
            row.results = { counts = cl, unknown = unknown }
            rows[q] = row
            stats.functions = stats.functions + 1
        end
    end
    local out = { rows = rows, stats = stats, seconds = (vim.uv.hrtime() - t0) / 1e9,
        firstclass = ctx.firstclass, reps = ctx.reps }
    -- THE JOIN with leaf 1 (the checker reading), at the positions leaf 1 states and closes
    if opts.leaf1 then
        local L1 = opts.leaf1.ours
        local inputs = {}
        -- (a RAISE-ONLY C body — the VM's fast path does the work, the C only raises — states no contract to join)
        for q in pairs(rows) do if L1[q] and L1[q].sig and not rows[q].raise_only then inputs[#inputs + 1] = q end end
        table.sort(inputs)
        local function kvobj(map) local keys = vim.tbl_keys(map); table.sort(keys); return { keys = keys, o = map } end
        local positions = {}
        for _, q in ipairs(inputs) do
            local s1 = L1[q].sig
            local ps = {}
            for k, p in pairs(s1.params) do if not s1.open[k] and not p.dispatch and p.types[1] ~= '?' and rows[q].pos[k] then ps[#ps + 1] = k end end
            table.sort(ps)
            positions[q] = ps
        end
        local CS = require 'cartograph.luajs.csig'
        local firstnames = {}
        for t, yes in pairs(ctx.firstclass) do if yes then firstnames[tn[t]] = true end end
        local function diffs(a, b)
            for _, k in ipairs(a.keys) do
                local x, y = a.o[k].o, b.o[k] and b.o[k].o
                if y then
                    local d = M.compare(vim.split(x.t, '|', { trimempty = true }), x.opt, vim.split(y.t, '|', { trimempty = true }), y.opt, firstnames)
                    if d then return d end
                end
            end
            return nil
        end
        out.join = OJ.run({
            inputs = inputs,
            read = function (q)
                if #positions[q] == 0 then return nil, 'leaf 1 states no closed position here' end
                local v = {}
                for _, k in ipairs(positions[q]) do
                    local r = rows[q].pos[k]
                    v[tostring(k)] = kvobj({ t = table.concat(r.accepted, '|'), opt = r.absent ~= 'never' })
                end
                return kvobj(v)
            end,
            oracle = function (q)
                local v = {}
                for _, k in ipairs(positions[q]) do
                    local p = L1[q].sig.params[k]
                    v[tostring(k)] = kvobj({ t = table.concat(CS.accepted(p), '|'), opt = p.opt })
                end
                return kvobj(v)
            end,
            eq = function (a, b) return diffs(a, b) == nil end,
            cause = function (_, _, a, b) return diffs(a, b) or 'other' end,
            examples = 6,
        })
        -- the positions ONLY the path reading types (leaf 1 refused the function, or left the position open)
        local only = {}
        for q, row in pairs(rows) do
            local s1 = L1[q] and L1[q].sig
            for k, r in pairs(row.pos) do
                local stated = s1 and s1.params[k] and not s1.open[k]
                if not r.untyped and not stated and #r.accepted > 0 then only[#only + 1] = { q = q, k = k } end
            end
        end
        table.sort(only, function (a, b) if a.q ~= b.q then return a.q < b.q end return a.k < b.k end)
        out.only = only
    end
    -- THE WITNESS on the positions only this reading types (csig's: a child LuaJIT, LuaJIT's own error wording)
    if opts.witness ~= false and out.only then
        local CS = require 'cartograph.luajs.csig'
        local jobs, byq = {}, {}
        for _, o in ipairs(out.only) do byq[o.q] = byq[o.q] or {}; table.insert(byq[o.q], o.k) end
        for q, ks in pairs(byq) do
            local P, pre = {}, {}
            for k, r in pairs(rows[q].pos) do pre[k] = { types = r.always[1] and r.always or r.accepted } end
            for _, k in ipairs(ks) do
                local r = rows[q].pos[k]
                P[k] = { types = r.always[1] and r.always or r.accepted, all = r.accepted, opt = r.absent ~= 'never' }
            end
            jobs[#jobs + 1] = { q = q, params = P, prefix = pre }
        end
        table.sort(jobs, function (a, b) return a.q < b.q end)
        local W = CS.witness(jobs, PM.vocabulary(src))
        local tally, notes = { confirmed = 0, contradicted = 0, named = 0, other = 0, lost = 0 }, {}
        local firstnames2 = {}
        for t, yes in pairs(ctx.firstclass) do if yes then firstnames2[tn[t]] = true end end
        for _, j in ipairs(jobs) do
            local w = W[j.q]
            if w.lost then tally.lost = tally.lost + 1 end
            for _, pr in ipairs(w.probes) do
                local r = rows[j.q].pos[pr.k]
                if pr.ok then
                    -- a probe the path reading REJECTS was accepted by LuaJIT: a contradiction of this reading
                    tally.contradicted = tally.contradicted + 1
                    notes[#notes + 1] = ('%s #%d: LuaJIT ACCEPTED a value the path reading rejects'):format(j.q, pr.k)
                elseif pr.at == pr.k and pr.expected then
                    local exp = pr.expected:gsub(' expected$', '')
                    local ok = exp == 'value' and r.absent == 'never'
                    for _, t in ipairs(r.accepted) do if exp:find(t, 1, true) then ok = true end end
                    -- a message naming a type OUTSIDE type()'s names ("coroutine", "C type"): the library's own word
                    local named = not ok and not firstnames2[exp] and not exp:find(' or ', 1, true)
                    if named then tally.named = (tally.named or 0) + 1; notes[#notes + 1] = ('%s #%d: LuaJIT names the type "%s" (path reading %s)'):format(j.q, pr.k, exp, table.concat(r.accepted, '|'))
                    elseif ok then tally.confirmed = tally.confirmed + 1
                    else tally.contradicted = tally.contradicted + 1; notes[#notes + 1] = ('%s #%d: path reading %s, LuaJIT says "%s"'):format(j.q, pr.k, table.concat(r.accepted, '|'), pr.expected) end
                else
                    tally.other = tally.other + 1
                    notes[#notes + 1] = ('%s #%d: %s'):format(j.q, pr.k, pr.at and ('raised at #' .. pr.at .. ': ' .. tostring(pr.expected)) or tostring(pr.other))
                end
            end
        end
        out.witness = { functions = #jobs, tally = tally, notes = notes }
    end
    return out
end

return M
