-- retained.lua — RETAINED GROWTH: state that outlives a call, grown by it, and never shrunk.
--
-- USER (2026-09-25): "Let's do the retained growth one" — metric #3 of the static performance list
-- (after loopcost's time and bytes units). loopcost prices what a call RUNS and ALLOCATES; this asks
-- what a call LEAVES BEHIND. The shape: a container reached through a name the function does not
-- own (an upvalue, a module table's field, a global) gets a NEW slot on a call — `S[k] = v` with a
-- key from the input, `S[#S + 1] = v`, `table.insert(S, v)` — and no code anywhere removes one:
-- no `S[k] = nil`, no `table.remove(S)`, no wipe, no reassignment `S = {}` inside a function, and
-- the table is not weak. Such a container grows for the life of the process: an unbounded cache,
-- a registry nobody unregisters from, a log. Memoization is the common, often harmless, case — the
-- lens cannot know a key domain's size, so a KEYED growth (per distinct key) ranks under an APPEND
-- (per call, whatever the arguments).
--
-- ── THE CLASSES, by who could shrink it ────────────────────────────────────────────
--   private   the root is a `local` of this file and not the file's returned module table: only
--             this file can reach it, so "no shrink in this file" is the whole search
--   exported  a field of the returned module table: another file can shrink it through the module;
--             a shrink or reset of the same FIELD NAME anywhere in the project suppresses it (by
--             name: a hedge in the SUPPRESSING direction, reported as a count)
--   global    no `local` declares the root: any file can; searched project-wide by name, likewise
--
-- ⚠ TEXT SCAFFOLDS, each named: `local R` declarations, the returned name (`return M`) and weak
-- tables (`setmetatable(..., { __mode = ... })` on the declaring line) are read from the file's
-- text. Containers are keyed by their spelling per file, so two locals of one name in two scopes
-- share a key (a shrink of one suppresses the other: under-reporting, never a false finding).
-- ⚠ A SHAPE, NOT A LEAK: a grower called once at startup fills a bounded table. `callers` (call
-- sites of the growing function) is on the finding so a reader can tell a hot path from an init.

local expr = require 'cartograph.expr'
local at = require 'cartograph.at'

local M = {}

local PLAIN_ASSIGN = { assignment_statement = true, assignment = true, assignment_expression = true }

local function root_of(e)
    while e and (e.k == 'field' or e.k == 'index') do e = e.b end
    return e and e.k == 'name' and e.n or nil
end
local function text_of(e)
    if not e then return '?' end
    if e.k == 'name' then return e.n end
    if e.k == 'field' then return text_of(e.b) .. '.' .. e.n end
    if e.k == 'index' then return text_of(e.b) .. '[]' end
    return '?'
end
local function last_segment(e)
    if e and e.k == 'field' then return e.n end
    if e and e.k == 'name' then return e.n end
    return nil
end
local function is_nil(e) return e and e.k == 'lit' and e.ty == 'nil' end
-- a key naming a FIXED slot: a literal, or a constant by its name
local function fixed_key(e)
    return e and (e.k == 'lit' or (e.k == 'name' and e.n:match('^[A-Z][A-Z0-9_]*$'))) and true or false
end
local function append_key(i, base)
    return i and i.k == 'bin' and i.op == '+' and i.l and i.l.k == 'un' and i.l.op == '#'
        and expr.key(i.l.e) == expr.key(base)
end
-- the spelled name of a call's callee (`table.insert`, `wipe`)
local function callee_text(c)
    local f = c.f
    if not f then return nil end
    if f.k == 'name' then return f.n end
    if f.k == 'field' and f.b and f.b.k == 'name' then return f.b.n .. '.' .. f.n end
    return nil
end

--- @param store table   an ingested store
--- @param data table    the extraction (nodes + calls)
--- @param opts table|nil { files = <lua pattern> } — which files' containers are REPORTED (shrinks are
---   searched everywhere)
--- @return table { findings = {...}, stats = {...} }
function M.analyze(store, data, opts)
    opts = opts or {}
    local spec_of = {}
    local function spec_for(file)
        local lang = file and expr.lang_of(file)
        if not lang then return nil end
        if spec_of[lang] == nil then
            local ok, sp = pcall(require, 'cartograph.spec.' .. lang)
            spec_of[lang] = ok and type(sp) == 'table' and sp or false
        end
        return spec_of[lang] or nil
    end
    local callers = {}
    for _, c in ipairs(data.calls or {}) do if c.to then callers[c.to] = (callers[c.to] or 0) + 1 end end

    local grows = {}                  -- file -> container key -> { text, root, last, sites = {...} }
    local shrunk = {}                 -- file -> container key -> true
    local shrunk_name = {}            -- last segment -> { [file] = true } (for exported/global)
    local stats = { fns = 0, grow_sites = 0, shrink_sites = 0, containers = 0 }
    local function mark_shrink(file, e)
        local k = expr.key(e)
        shrunk[file] = shrunk[file] or {}
        shrunk[file][k] = true
        local ls = last_segment(e)
        if ls then shrunk_name[ls] = shrunk_name[ls] or {}; shrunk_name[ls][file] = true end
        stats.shrink_sites = stats.shrink_sites + 1
    end

    -- PASS 1: every function's rows and the names it DECLARES (params, locals, binders), and its
    -- lexically ENCLOSING function. A container rooted in a name an enclosing function declares lives
    -- as long as THAT call (a closure appending to its builder's `out`): not retained. That was 6 of 6
    -- sampled findings on cartograph before this rule.
    local fns, by_file = {}, {}
    for _, n in ipairs(data.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and n.file and n.range then
            local got = expr.of(store, n.id)
            local fl = got and got.fl
            local spec = spec_for(n.file)
            if fl and fl.stmts and spec and spec.container_ops then
                local own, cursor = {}, {}
                for _, p in ipairs(fl.params or {}) do own[p] = true end
                for v in pairs(got.bound or {}) do own[v] = true end
                for _, r in ipairs(fl.stmts) do
                    if not PLAIN_ASSIGN[r.t or ''] then
                        for _, v in ipairs(r.def or {}) do own[v] = true end
                        -- a local declared from a NUMBER literal: a cursor this call starts afresh
                        local rhs = r.expr and r.expr.rhs
                        if #(r.def or {}) == 1 and rhs and #rhs == 1 and rhs[1].k == 'lit' and rhs[1].ty == 'num' then
                            cursor[r.def[1]] = true
                        end
                    end
                end
                local rec = { n = n, rows = fl.stmts, own = own, cursor = cursor, ops = spec.container_ops,
                    s = at.sl(n.range), e = at.el(n.range) }
                fns[#fns + 1] = rec
                local l = by_file[n.file] or {}; l[#l + 1] = rec; by_file[n.file] = l
            end
        end
    end
    for _, list in pairs(by_file) do
        table.sort(list, function(a, b) if a.s ~= b.s then return a.s < b.s end return a.e > b.e end)
        local stack = {}
        for _, rec in ipairs(list) do
            while #stack > 0 and stack[#stack].e < rec.s do stack[#stack] = nil end
            rec.parent = stack[#stack]
            stack[#stack + 1] = rec
        end
    end
    local function enclosing_declares(rec, name)
        local p = rec.parent
        while p do if p.own[name] then return true end; p = p.parent end
        return false
    end

    -- PASS 2: the grow and shrink sites
    for _, rec in ipairs(fns) do
        local n, rows, own, ops, cursor = rec.n, rec.rows, rec.own, rec.ops, rec.cursor
        stats.fns = stats.fns + 1
        local function in_loop(i)
            local p = rows[i].parent
            while p and p ~= 0 do
                if (rows[p].t or ''):find('for') or (rows[p].t or ''):find('while') or (rows[p].t or ''):find('repeat') then return true end
                p = rows[p].parent
            end
            return false
        end
        local function grow(e, how, i)
            local root = root_of(e)
            -- the call's own table, or an enclosing call's: it dies with that call
            if not root or own[root] or enclosing_declares(rec, root) then return end
            local k = expr.key(e)
            grows[n.file] = grows[n.file] or {}
            local g = grows[n.file][k]
            if not g then
                -- the containers that HOLD this one: resetting any of them drops it too
                local anc, x = {}, e.b
                while x and (x.k == 'field' or x.k == 'index' or x.k == 'name') do
                    -- by NAME only a FIELD means the same thing in another file; a root name does only for a global
                    anc[#anc + 1] = { key = expr.key(x), last = (x.k == 'field' or x.k == 'name') and last_segment(x) or nil, root = x.k == 'name' }
                    x = x.b
                end
                g = { text = text_of(e), root = root, last = last_segment(e), anc = anc, sites = {} }
                grows[n.file][k] = g
            end
            g.sites[#g.sites + 1] = { fn = n.id, name = n.name, line = rows[i].l, how = how, in_loop = in_loop(i) }
            stats.grow_sites = stats.grow_sites + 1
        end
        for i, r in ipairs(rows) do
            local e = r.expr
            local lhs, rhs = e and e.lhs or {}, e and e.rhs or {}
            if PLAIN_ASSIGN[r.t or ''] then
                for j, l in ipairs(lhs) do
                    local v = rhs[j]
                    if l.k == 'index' then
                        if is_nil(v) then mark_shrink(n.file, l.b)
                        elseif append_key(l.i, l.b) then grow(l.b, 'append', i)
                        -- `path[np] = x` with `local np = 0` in this call: a scratch slot reused per call
                        elseif not fixed_key(l.i) and not (l.i.k == 'name' and cursor[l.i.n]) then grow(l.b, 'keyed', i) end
                    elseif (l.k == 'name' or l.k == 'field') and v then
                        -- a REASSIGNMENT inside a function replaces the container: a reset
                        mark_shrink(n.file, l)
                    end
                end
            end
            for _, x in ipairs(rhs) do
                expr.walk(x, function(c)
                    if c.k ~= 'call' then return end
                    local name = callee_text(c)
                    local g, s = name and ops.grow[name], name and ops.shrink[name]
                    local a = (g or s) and c.a and c.a[g or s]
                    if a and (a.k == 'name' or a.k == 'field' or a.k == 'index') then
                        if s then mark_shrink(n.file, a) else grow(a, 'append', i) end
                    end
                end)
            end
        end
    end

    -- the file's text facts: `local R` declarations, the returned name, weak tables
    local text_memo = {}
    local function text_facts(file)
        local t = text_memo[file]
        if t then return t end
        t = { locals = {}, weak = {}, returned = nil }
        local src = (store.content and store.content({ file = file, id = file, kind = 'module' })) or {}
        for _, l in ipairs(src) do
            local decl = l:match('^%s*local%s+function%s+([%w_]+)') or l:match('^%s*local%s+([%w_,%s]+)')
            if decl then
                for v in decl:gmatch('[%w_]+') do t.locals[v] = true end
                if l:find('__mode', 1, true) then
                    for v in (l:match('^%s*local%s+([%w_,%s]+)=') or ''):gmatch('[%w_]+') do t.weak[v] = true end
                end
            end
            local r = l:match('^return%s+([%w_]+)%s*$')
            if r then t.returned = r end
        end
        text_memo[file] = t
        return t
    end

    local findings = {}
    local suppressed = 0
    for file, conts in pairs(grows) do
        if not opts.files or file:match(opts.files) then
            local tf = text_facts(file)
            for k, g in pairs(conts) do
                stats.containers = stats.containers + 1
                local class = (not tf.locals[g.root]) and 'global' or (g.root == tf.returned and 'exported') or 'private'
                local shrink_here = shrunk[file] and shrunk[file][k]
                for _, a in ipairs(g.anc) do if shrunk[file] and shrunk[file][a.key] then shrink_here = true end end
                local elsewhere = 0
                if class ~= 'private' then
                    local names = { g.last }
                    for _, a in ipairs(g.anc) do
                        if not a.root or class == 'global' then names[#names + 1] = a.last end
                    end
                    for _, nm in pairs(names) do
                        for f2 in pairs(nm and shrunk_name[nm] or {}) do if f2 ~= file then elsewhere = elsewhere + 1 end end
                    end
                end
                if tf.weak[g.root] or shrink_here or elsewhere > 0 then
                    suppressed = suppressed + 1
                else
                    local append, calls = false, 0
                    for _, s in ipairs(g.sites) do
                        if s.how == 'append' then append = true end
                        calls = math.max(calls, callers[s.fn] or 0)
                    end
                    table.sort(g.sites, function(a, b) return a.line < b.line end)
                    findings[#findings + 1] = { file = file, line = g.sites[1].line, container = g.text,
                        class = class, how = append and 'append' or 'keyed', sites = g.sites, callers = calls }
                end
            end
        end
    end
    stats.suppressed = suppressed
    local CLASS = { private = 1, exported = 2, global = 3 }
    table.sort(findings, function(a, b)
        if a.how ~= b.how then return a.how == 'append' end
        if a.class ~= b.class then return CLASS[a.class] < CLASS[b.class] end
        if a.callers ~= b.callers then return a.callers > b.callers end
        if a.file ~= b.file then return a.file < b.file end
        return a.line < b.line
    end)
    return { findings = findings, stats = stats }
end

--- one line per finding: the container, how it grows, where, and who calls the grower
function M.text(f)
    local ss = {}
    for _, s in ipairs(f.sites) do
        ss[#ss + 1] = ('%s@%d%s%s'):format(s.name or '?', s.line, s.how == 'append' and ' append' or ' keyed',
            s.in_loop and ' (in a loop)' or '')
    end
    return ('%s grows [%s, %s], never shrunk; grower call sites %d:  %s'):format(f.container, f.how, f.class,
        f.callers, table.concat(ss, ', '))
end

return M
