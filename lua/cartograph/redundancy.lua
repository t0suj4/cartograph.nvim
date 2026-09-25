-- redundancy.lua — REDUNDANT SETUP and where it belongs: availability of an idempotent effect over a harness's
-- run order (the setup half of the general analysis; its "missing" half is CART-1070).
--
-- USER (2026-09-25): "I think spec can do common setup, if so, can cartograph suggest it?", then "do the
-- redundancy elimination". The case that asked for it: 139 spec files spell nvim-treesitter's path, 128 define
-- their own parser probe, 254 lines append it to the runtimepath — and tests/run.lua, which runs before every
-- spec, could do it once.
--
-- ── THE MODEL ──────────────────────────────────────────────────────────────────────
-- A FACT is an idempotent effect with its argument: `vim.opt.rtp:append(<dir>)`. Which calls establish a fact
-- is DECLARED (spec.idempotent_steps, each cited: a premise that PRODUCES suggestions, so it must be true, and
-- each was measured). A fact's identity is the step plus its argument's canonical form: a name defined once is
-- replaced by its definition (`local TSDIR = vim.fn.expand(...)`), in the function or at file level.
--   THE RUN ORDER (a harness, derived — see harness() below): the PRELUDE's top level runs first (the file that
--   defines the entry, `_G.test`), then each UNIT's top level (the files that call it), then the entry
--   callbacks. What is GUARANTEED before a test body, in every way the harness can be run: the prelude's top
--   level before its first loop, the body's OWN unit's top level, and the rows before it in the body that
--   dominate it. NOT another unit's top level (absent under `SPEC=`), NOT an earlier sibling test (it may skip
--   or fail before its setup ran) — crediting either is exactly the order dependence CART-1069 was.
--   A HELPER establishes a fact when an establishing row sits at its body's top level (unconditional); a call to
--   it is then an establishing step (`via`), to a fixpoint over helpers calling helpers.
-- ── WHAT IT REPORTS ────────────────────────────────────────────────────────────────
--   redundant       a direct step whose fact is already guaranteed at that point: deletable as it stands
--   redundant-via   a helper call whose establishing part is already guaranteed (the call stays: it may probe)
--   hoist           a fact established in N places across K units that the prelude (K >= 2) or the unit's top
--                   level (K = 1) could establish ONCE: every one of the N direct steps then reads redundant
-- Every hoist carries its premises (`assumes`, the CART-1071 record): the step is idempotent (declared, cited)
-- and establishing it EARLIER changes nothing else (unchecked — e.g. the runtimepath's search order).
-- ⚠ DOMINANCE IS STRUCTURAL: a row dominates a later one when its block is the later one's block or an
-- enclosing loop/function block; a row inside an if/else dominates nothing outside it. Conservative: a missed
-- dominance under-reports redundancy, it never deletes a needed step.

local expr = require 'cartograph.expr'

local M = {}

local LOOPISH = { for_statement = true, while_statement = true, repeat_statement = true,
    for_in_statement = true, for_generic_clause = true, for_numeric_clause = true }

local function dotted(e)
    if not e then return nil end
    if e.k == 'name' then return e.n end
    if e.k == 'field' then local b = dotted(e.b); return b and (b .. '.' .. e.n) or nil end
    return nil
end
-- the spelled callee of a call node: `vim.opt.rtp:append`, `vim.treesitter.language.add`, `ready`
local function callee_text(c)
    local f = c.f
    if not f then return nil end
    if f.k == 'name' then return f.n end
    if f.k == 'field' then
        local b = dotted(f.b)
        return b and (b .. (f.method and ':' or '.') .. f.n) or nil
    end
    return nil
end

-- the names a row list defines ONCE, with the expression they are defined as
local function single_defs(rows)
    local count, val = {}, {}
    for _, r in ipairs(rows or {}) do
        for _, v in ipairs(r.def or {}) do count[v] = (count[v] or 0) + 1 end
        local rhs = r.expr and r.expr.rhs
        if #(r.def or {}) == 1 and rhs and #rhs == 1 then val[r.def[1]] = rhs[1] end
    end
    local out = {}
    for v, n in pairs(count) do if n == 1 and val[v] then out[v] = val[v] end end
    return out
end

-- THE CANONICAL FORM of an argument, or nil when it is not CLOSED. Closed = the same value at every site in every
-- run: a literal, a name defined once as a closed expression (in the function, else at file level), a `..` of
-- closed parts, a call DECLARED deterministic (spec.deterministic_calls, cited) of closed arguments. A param, a
-- loop variable, `vim.fn.tempname()` are not: such a fact is the same only WITHIN one context. (Found on the
-- first real run: six `rtp:append(vim.fn.tempname())` read as one fact and drew a hoist suggestion.)
local function canon(e, ldefs, fdefs, det, depth)
    if not e then return nil end
    depth = depth or 0
    if e.k == 'lit' then return tostring(e.v) end
    if e.k == 'name' then
        local d = ldefs[e.n] or fdefs[e.n]
        if d and depth < 4 then return canon(d, ldefs, fdefs, det, depth + 1) end
        return nil
    end
    if e.k == 'bin' and e.op == '..' then
        local l, r = canon(e.l, ldefs, fdefs, det, depth + 1), canon(e.r, ldefs, fdefs, det, depth + 1)
        return l and r and (l .. ' .. ' .. r) or nil
    end
    if e.k == 'call' then
        local name = callee_text(e)
        if not (name and det and det[name]) then return nil end
        local parts = {}
        for _, a in ipairs(e.a or {}) do
            local k = canon(a, ldefs, fdefs, det, depth + 1)
            if not k then return nil end
            parts[#parts + 1] = k
        end
        return name .. '(' .. table.concat(parts, ', ') .. ')'
    end
    return nil
end

-- the calls a row makes (lhs, rhs, cond; an if row repeats its cond in rhs, so deduplicate by key)
local function row_calls(r)
    local out, seen = {}, {}
    local e = r.expr
    if not e then return out end
    local function scan(list)
        for _, x in ipairs(list or {}) do
            expr.walk(x, function(n)
                if n.k == 'call' then
                    local k = expr.key(n)
                    if not seen[k] then seen[k] = true; out[#out + 1] = n end
                end
            end)
        end
    end
    scan(e.lhs); scan(e.rhs)
    if e.cond then scan({ e.cond }) end
    return out
end

-- does row j (earlier) dominate row i in the same row list? j's block must be on i's chain of enclosing blocks
-- (so a row inside a branch dominates nothing outside it). ⚠ THE THEN AND ELSE ROWS OF AN `if` SHARE THE if ROW
-- AS PARENT (only elseif gets a row of its own), so inside an if block the branches are told apart by TEXT: an
-- `else`/`elseif` keyword between the two rows means they sit in different branches. (Found by mutation: without
-- it, two steps in ONE then-branch never dominated each other.)
local function dominates(rows, j, i, lines)
    if j >= i then return false end
    local pj = rows[j].parent or 0
    local p = rows[i].parent or 0
    while true do
        if p == pj then
            if pj == 0 or LOOPISH[rows[pj].t or ''] then return true end
            for l = rows[j].l + 1, rows[i].l do
                if (lines[l] or ''):find('%f[%w_]else') then return false end
            end
            return true
        end
        if p == 0 then return false end
        p = rows[p].parent or 0
    end
end

--- THE HARNESSES: every file that defines the entry as a GLOBAL (`_G.test`) is a prelude; a function merely
--- NAMED `test` is not (the first real run picked algebra/core.lua's). Its UNITS are the files it LOADS: the first
--- file glob in its text (`vim.fn.glob('tests/*_spec.lua')`), `*` not crossing `/`, matched from the tree's root
--- (the suite runs from there) and, failing that, from the prelude's own directory. So this repo has one harness
--- per runner — the real tests/run.lua and the fixtures' — and a fixture is nobody's unit but its own runner's.
--- A prelude with no glob takes every file with an entry callback in its directory and below.
local function glob_pattern(g)
    local p = g:gsub('[%^%$%(%)%%%.%[%]%+%-]', '%%%0'):gsub('%*%*', '\1'):gsub('%*', '[^/]*'):gsub('%?', '[^/]'):gsub('\1', '.-')
    return '^' .. p .. '$'
end
function M.harnesses(data, entry, content)
    entry = entry or 'test'
    -- the candidates are EVERY file (a glob loads a spec that registers no test too: gaps_spec's top level runs
    -- and its helpers are steps); without a glob, the files with an entry callback
    local preludes, seen, cbs, files = {}, {}, {}, {}
    for _, n in ipairs(data.nodes or {}) do
        if n.kind == 'function' and n.file then
            if n.name == '_G.' .. entry and not seen[n.file] then seen[n.file] = true; preludes[#preludes + 1] = n.file end
            if n.name == entry .. '#cb' then cbs[#cbs + 1] = n.file end
        end
        if n.kind == 'module' and n.file then files[#files + 1] = n.file end
    end
    table.sort(preludes)
    local out = {}
    for _, prelude in ipairs(preludes) do
        local glob
        for _, l in ipairs((content and content(prelude)) or {}) do
            glob = glob or l:match('glob%(%s*[\'"]([^\'"]*%*[^\'"]*)[\'"]')
        end
        local dir = prelude:match('^(.*)/[^/]*$')
        local units = {}
        local function try(prefix)
            local pat = glob and glob_pattern(prefix .. glob)
            local any = false
            for _, f in ipairs(pat and files or cbs) do
                if f ~= prelude and (pat and f:match(pat) or (not pat and (not dir or f:sub(1, #dir + 1) == dir .. '/'))) then
                    units[f] = true; any = true
                end
            end
            return any
        end
        if not try('') and dir then try(dir .. '/') end
        out[#out + 1] = { prelude = prelude, units = units, glob = glob }
    end
    return out
end
function M.harness(data, entry, content)
    local h = M.harnesses(data, entry, content)[1]
    if not h then return nil, {} end
    return h.prelude, h.units, h.glob
end

--- @param store table   an ingested store
--- @param data table    the extraction
--- @param opts table|nil { entry = 'test', prelude = <file> (default: derived) }
function M.analyze(store, data, opts)
    opts = opts or {}
    local entry = opts.entry or 'test'
    local function content(file) return store.content and store.content({ file = file, id = file, kind = 'module' }) end
    local hs = M.harnesses(data, entry, content)
    if opts.prelude then
        local keep = {}
        for _, h in ipairs(hs) do if h.prelude == opts.prelude then keep[#keep + 1] = h end end
        hs = keep
    end
    local all = { findings = {}, facts = {}, harnesses = hs,
        stats = { units = 0, bodies = 0, helpers = 0, steps = 0, facts = 0 } }
    if #hs == 0 then all.why = 'no file defines _G.' .. entry; return all end
    for _, h in ipairs(hs) do
        local R = M.analyze_one(store, data, entry, h.prelude, h.units, h.glob)
        for _, f in ipairs(R.findings) do f.harness = h.prelude; all.findings[#all.findings + 1] = f end
        for k, f in pairs(R.facts) do all.facts[h.prelude .. '\0' .. k] = f end
        for k, v in pairs(R.stats) do all.stats[k] = all.stats[k] + v end
    end
    if #hs == 1 then all.prelude, all.units, all.glob = hs[1].prelude, hs[1].units, hs[1].glob end
    local RANK = { hoist = 1, redundant = 2, ['redundant-via'] = 3 }
    table.sort(all.findings, function(a, b)
        if a.kind ~= b.kind then return RANK[a.kind] < RANK[b.kind] end
        if a.kind == 'hoist' and a.would_remove ~= b.would_remove then return a.would_remove > b.would_remove end
        if a.file ~= b.file then return a.file < b.file end
        return (a.line or 0) < (b.line or 0)
    end)
    return all
end

--- one harness: its prelude, its units
function M.analyze_one(store, data, entry, prelude, units, glob)
    local stats = { units = 0, bodies = 0, helpers = 0, steps = 0, facts = 0 }
    for _ in pairs(units) do stats.units = stats.units + 1 end

    local spec_of = {}
    local function spec_for(file)
        local lang = expr.lang_of(file)
        if not lang then return nil end
        if spec_of[lang] == nil then
            local ok, sp = pcall(require, 'cartograph.spec.' .. lang)
            spec_of[lang] = ok and type(sp) == 'table' and sp or false
        end
        return spec_of[lang] or nil
    end
    local function steps_for(file) local sp = spec_for(file); return sp and sp.idempotent_steps end

    -- every context: the prelude's and each unit's TOP LEVEL, every function in them (bodies and helpers)
    local files = { [prelude] = true }
    for f in pairs(units) do files[f] = true end
    local ctxs, by_file = {}, {}
    for _, n in ipairs(data.nodes or {}) do
        if n.file and files[n.file] then
            local rows
            if n.kind == 'module' then
                local m = expr.of_module(store, n.id)
                rows = m and m.fl and m.fl.stmts
            elseif n.kind == 'function' or n.kind == 'method' then
                local g = expr.of(store, n.id)
                rows = g and g.fl and g.fl.stmts
            end
            if rows then
                local c = { node = n, file = n.file, rows = rows, lines = (store.content and store.content(n)) or {},
                    kind = n.kind == 'module' and 'top'
                    or (n.name == entry .. '#cb' and 'body')
                    -- an inline callback (`pcall#cb`) runs whenever its caller decides: its own context, not
                    -- callable by name, and only the prelude is guaranteed before it
                    or ((n.name or ''):find('#', 1, true) and 'closure') or 'helper' }
                ctxs[#ctxs + 1] = c
                by_file[n.file] = by_file[n.file] or {}
                if c.kind == 'top' then by_file[n.file].top = c end
                local short = (n.name or ''):match('([%w_]+)$')
                if c.kind == 'helper' and short then
                    local hs = by_file[n.file].helpers or {}
                    hs[short] = hs[short] == nil and c or false -- a name defined twice resolves to nothing
                    by_file[n.file].helpers = hs
                end
            end
        end
    end
    local function helper_named(file, name)
        local here = by_file[file] and by_file[file].helpers and by_file[file].helpers[name]
        if here then return here end
        local g = by_file[prelude] and by_file[prelude].helpers and by_file[prelude].helpers[name]
        return g or nil -- a prelude global is callable from every unit
    end

    -- the establishing steps of every context, per row: { fact, via = helper ctx | nil, call }
    local facts = {}
    local function fact_of(callee, arg, local_defs, file_defs, entryrec, det, ctx)
        local k = canon(arg, local_defs, file_defs, det)
        -- not closed: the same fact only within this context (the same name, the same value)
        local key = k and (callee .. '(' .. k .. ')') or (callee .. '(' .. expr.key(arg) .. ') @' .. ctx.node.id)
        local f = facts[key]
        if not f then
            f = { key = key, callee = callee, src = entryrec.src, steps = {} }
            facts[key] = f
            stats.facts = stats.facts + 1
        end
        return f
    end
    local file_defs = {}
    for file, rec in pairs(by_file) do file_defs[file] = rec.top and single_defs(rec.top.rows) or {} end
    for _, c in ipairs(ctxs) do
        local steps = steps_for(c.file)
        local sp = spec_for(c.file)
        local det = sp and sp.deterministic_calls
        local ldefs = c.kind == 'top' and {} or single_defs(c.rows)
        c.direct, c.calls = {}, {}
        for i, r in ipairs(c.rows) do
            for _, call in ipairs(row_calls(r)) do
                local name = callee_text(call)
                local st = name and steps and steps[name]
                if st then
                    local f = fact_of(name, call.a and call.a[st.arg or 1], ldefs, file_defs[c.file], st, det, c)
                    c.direct[#c.direct + 1] = { row = i, fact = f }
                elseif name and not name:find('[%.:]') then
                    local h = helper_named(c.file, name)
                    if h and h ~= c then c.calls[#c.calls + 1] = { row = i, helper = h } end
                end
            end
        end
    end
    -- HELPER SUMMARIES: the facts a helper establishes unconditionally (a top-level row of its body), to a fixpoint
    for _, c in ipairs(ctxs) do c.est = {} end
    local changed, rounds = true, 0
    while changed and rounds < 10 do
        changed, rounds = false, rounds + 1
        for _, c in ipairs(ctxs) do
            if c.kind == 'helper' then
                local function add(f) if not c.est[f.key] then c.est[f.key] = f; changed = true end end
                for _, d in ipairs(c.direct) do if (c.rows[d.row].parent or 0) == 0 then add(d.fact) end end
                for _, v in ipairs(c.calls) do
                    if (c.rows[v.row].parent or 0) == 0 then for _, f in pairs(v.helper.est) do add(f) end end
                end
            end
        end
    end

    -- what the PRELUDE guarantees: its top-level rows before its first top-level loop (the units load in it)
    local guaranteed = {}
    local ptop = by_file[prelude] and by_file[prelude].top
    if ptop then
        local stop = math.huge
        for i, r in ipairs(ptop.rows) do
            if (r.parent or 0) == 0 and LOOPISH[r.t or ''] then stop = i; break end
        end
        for _, d in ipairs(ptop.direct) do
            if d.row < stop and (ptop.rows[d.row].parent or 0) == 0 then
                guaranteed[d.fact.key] = guaranteed[d.fact.key] or { file = prelude, line = ptop.rows[d.row].l, how = 'prelude' }
            end
        end
        for _, v in ipairs(ptop.calls) do
            if v.row < stop and (ptop.rows[v.row].parent or 0) == 0 then
                for k in pairs(v.helper.est) do guaranteed[k] = guaranteed[k] or { file = prelude, line = ptop.rows[v.row].l, how = 'prelude' } end
            end
        end
    end
    -- what a unit's TOP LEVEL guarantees to its test bodies (all of it runs at load, before any test)
    local unit_top = {}
    for file in pairs(units) do
        local t = by_file[file] and by_file[file].top
        local g = {}
        if t then
            for _, d in ipairs(t.direct) do
                if (t.rows[d.row].parent or 0) == 0 then g[d.fact.key] = g[d.fact.key] or { file = file, line = t.rows[d.row].l, how = 'unit top level' } end
            end
            for _, v in ipairs(t.calls) do
                if (t.rows[v.row].parent or 0) == 0 then
                    for k in pairs(v.helper.est) do g[k] = g[k] or { file = file, line = t.rows[v.row].l, how = 'unit top level' } end
                end
            end
        end
        unit_top[file] = g
    end

    local findings = {}
    for _, c in ipairs(ctxs) do
        if c.kind == 'body' then stats.bodies = stats.bodies + 1 elseif c.kind == 'helper' then stats.helpers = stats.helpers + 1 end
        -- the establishments in this context, in row order: { row, keys = {fact keys}, via }
        local events = {}
        for _, d in ipairs(c.direct) do events[#events + 1] = { row = d.row, keys = { d.fact.key }, fact = d.fact } end
        for _, v in ipairs(c.calls) do
            local ks = {}
            for k in pairs(v.helper.est) do ks[#ks + 1] = k end
            if #ks > 0 then events[#events + 1] = { row = v.row, keys = ks, via = v.helper } end
        end
        table.sort(events, function(a, b) return a.row < b.row end)
        local is_prelude_top = c.kind == 'top' and c.file == prelude
        for ei, ev in ipairs(events) do
            if not ev.via then stats.steps = stats.steps + 1; ev.fact.steps[#ev.fact.steps + 1] = { file = c.file, line = c.rows[ev.row].l, ctx = c.kind, fn = c.node.id } end
            for _, key in ipairs(ev.keys) do
                -- already guaranteed here? by the prelude (anywhere but the prelude's own top), by the unit's top
                -- level (in a test body), or by an earlier dominating row of this context
                local by = (not is_prelude_top) and guaranteed[key] or nil
                if not by and c.kind == 'body' then by = unit_top[c.file] and unit_top[c.file][key] end
                if not by then
                    for ej = 1, ei - 1 do
                        local e2 = events[ej]
                        local has = false
                        for _, k2 in ipairs(e2.keys) do if k2 == key then has = true end end
                        if has and dominates(c.rows, e2.row, ev.row, c.lines) then
                            by = { file = c.file, line = c.rows[e2.row].l, how = e2.via and ('earlier call to ' .. (e2.via.node.name or '?')) or 'earlier in this body' }
                            break
                        end
                    end
                end
                if by then
                    findings[#findings + 1] = { kind = ev.via and 'redundant-via' or 'redundant', fact = facts[key],
                        file = c.file, line = c.rows[ev.row].l, ctx = c.kind, via = ev.via and ev.via.node.name or nil, by = by }
                end
            end
        end
    end

    -- HOIST: a fact the prelude does not guarantee, established by direct steps in the units
    for key, f in pairs(facts) do
        if not guaranteed[key] then
            local in_units, n = {}, 0
            for _, s in ipairs(f.steps) do
                if units[s.file] then
                    if not in_units[s.file] then in_units[s.file] = true; n = n + 1 end
                end
            end
            local direct = 0
            for _, s in ipairs(f.steps) do if units[s.file] then direct = direct + 1 end end
            local only = n == 1 and next(in_units) or nil
            -- a single unit whose top level already establishes it needs nothing: its bodies read redundant
            if n >= 2 or (n == 1 and direct >= 2 and not (unit_top[only] and unit_top[only][key])) then
                local to, where = prelude, 'prelude'
                if n == 1 then to = next(in_units); where = 'unit top level' end
                findings[#findings + 1] = { kind = 'hoist', fact = f, to = to, where = where, units = n,
                    would_remove = direct, file = to, line = 1,
                    assumes = {
                        { id = 'redundancy.idempotent', dir = 'produce', basis = 'declared', src = f.src,
                            says = f.callee .. ' twice has the effect of once' },
                        { id = 'redundancy.order-insensitive', dir = 'produce', basis = 'unchecked',
                            says = 'establishing it earlier than today changes nothing else (e.g. a search order)' },
                    } }
            end
        end
    end
    local RANK = { hoist = 1, redundant = 2, ['redundant-via'] = 3 }
    table.sort(findings, function(a, b)
        if a.kind ~= b.kind then return RANK[a.kind] < RANK[b.kind] end
        if a.kind == 'hoist' and a.would_remove ~= b.would_remove then return a.would_remove > b.would_remove end
        if a.file ~= b.file then return a.file < b.file end
        return (a.line or 0) < (b.line or 0)
    end)
    return { findings = findings, facts = facts, stats = stats, prelude = prelude, units = units, glob = glob }
end

--- one line per finding
function M.text(f)
    if f.kind == 'hoist' then
        return ('HOIST %s into the %s (%s): established by %d direct step(s) across %d unit(s), each redundant after [assumes: %s]')
            :format(f.fact.key, f.where, f.to, f.would_remove, f.units,
                table.concat(vim.tbl_map(function(a) return a.id end, f.assumes), ', '))
    end
    return ('%s:%d  %s %s%s — already established by %s at %s:%d'):format(f.file, f.line, f.kind, f.fact.key,
        f.via and (' (via ' .. f.via .. ')') or '', f.by.how, f.by.file, f.by.line)
end

return M
