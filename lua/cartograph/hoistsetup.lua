-- hoistsetup.lua — THE WRITE STEP of redundancy.lua: set up an idempotent fact ONCE in the common setup, and delete
-- the copies that become redundant (CART-1070). `:CartographHoistSetup`.
--
-- USER (2026-09-25): "do the write step". The plan redundancy.lua's `hoist` finding describes, as a txn plan:
--   INSERT  into the prelude, just before its first top-level loop (the one that loads the units) and above that
--           loop's own comment block, the hoisted statement AS SPELLED at the sites: the modal statement shape (on
--           this repo 246 of 247 sites are `if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end`),
--           with the local its argument names, wrapped in `do ... end` so the prelude gains no new name
--   DELETE  every direct step of that fact in the units, and with it:
--             - its GUARD, when the step is the guard's only statement, the guard has no else, and the condition
--               has no effect (pure, or only calls the spec declares effect-free / deterministic): `if C then step
--               end` goes whole; an `if` holding other statements loses only the step
--             - the LOCAL its argument names, when nothing else in its scope reads it any more
-- DECLINED, each by name and left as it is (still correct, only redundant): a step that is not a statement of its
-- own (inside an expression), a statement sharing its lines with other code, a guard whose condition does something.
-- Extents come from the tree-sitter tree (a row carries only its start line); deletions are whole lines.
-- ⚠ It rides redundancy.lua's premises, carried on the plan: the step is idempotent (declared, measured) and
-- setting it up EARLIER changes nothing else (unchecked — run the affected specs ALONE after applying: that is the
-- check, and `SPEC=<name>` is the isolation it needs).

local expr = require 'cartograph.expr'
local txn = require 'cartograph.txn'
local redundancy = require 'cartograph.redundancy'

local M = {}

-- every named node of a file's tree, keyed by `type:start_row` (0-based)
local function node_index(src, lang)
    local ok, parser = pcall(vim.treesitter.get_string_parser, require('cartograph.parseview').view(src, lang), lang)
    if not ok or not parser then return nil end
    local tree = parser:parse()[1]
    local idx = {}
    local function walk(n)
        local sr = n:range()
        local k = n:type() .. ':' .. sr
        if not idx[k] then idx[k] = n end
        for c in n:iter_children() do if c:named() then walk(c) end end
    end
    walk(tree:root())
    return idx
end

-- does the node own its lines outright (only whitespace before it on its first line, only whitespace or a comment
-- after it on its last)?
local function owns_lines(n, lines)
    local sr, sc, er, ec = n:range()
    local first, last = lines[sr + 1] or '', lines[er + 1] or ''
    if first:sub(1, sc):find('%S') then return false end
    local tail = last:sub(ec + 1)
    return not tail:find('%S') or tail:match('^%s*%-%-') ~= nil
end

local function text_of(n, lines)
    local sr, sc, er, ec = n:range()
    if sr == er then return { (lines[sr + 1] or ''):sub(sc + 1, ec) } end
    local out = { (lines[sr + 1] or ''):sub(sc + 1) }
    for l = sr + 2, er do out[#out + 1] = lines[l] end
    out[#out + 1] = (lines[er + 1] or ''):sub(1, ec)
    -- re-indent the continuation lines relative to the first
    local base = (lines[sr + 1] or ''):match('^(%s*)') or ''
    for i = 2, #out do if out[i]:sub(1, #base) == base then out[i] = out[i]:sub(#base + 1) end end
    return out
end

local function callee_text(c)
    local function dotted(e)
        if not e then return nil end
        if e.k == 'name' then return e.n end
        if e.k == 'field' then local b = dotted(e.b); return b and (b .. '.' .. e.n) or nil end
    end
    local f = c.f
    if f and f.k == 'name' then return f.n end
    if f and f.k == 'field' then local b = dotted(f.b); return b and (b .. (f.method and ':' or '.') .. f.n) or nil end
end

-- a condition with NO EFFECT: pure, or its calls are all declared effect-free / deterministic by the spec
local function effect_free(cond, spec)
    if not cond then return false end
    local okk = true
    expr.walk(cond, function(n)
        if n.k == 'call' then
            local name = callee_text(n)
            if not (name and ((spec.effect_free_calls or {})[name] or (spec.deterministic_calls or {})[name])) then okk = false end
        elseif n.k == 'table' or n.k == 'fn' or n.k == 'vararg' then okk = false end
    end)
    return okk
end

--- the plan for ONE hoist finding (default: the largest one)
--- @return table|nil plan, string|nil why, string|nil code, table|nil declined
function M.plan(store, opts)
    opts = opts or {}
    local data = store.data or {}
    local R = redundancy.analyze(store, data, { prelude = opts.prelude, entry = opts.entry })
    local hoist
    for _, f in ipairs(R.findings) do
        if f.kind == 'hoist' and f.where == 'prelude' and (not opts.fact or f.fact.key == opts.fact) then hoist = f; break end
    end
    if not hoist then return nil, 'no fact to hoist into a prelude' .. (R.why and (' (' .. R.why .. ')') or ''), 'no-candidates', {} end
    local fact, prelude = hoist.fact, hoist.to

    local files, declined, moves = {}, {}, {}
    local function file_rec(rel)
        local f = files[rel]
        if f then return f end
        local lines = store.content({ file = rel, id = rel, kind = 'module' }) or {}
        local lang = expr.lang_of(rel)
        local ok, spec = pcall(require, 'cartograph.spec.' .. (lang or ''))
        f = { rel = rel, lines = lines, idx = node_index(table.concat(lines, '\n'), lang), spec = ok and spec or {},
            dels = {}, ins = {}, gone = {} }
        files[rel] = f
        return f
    end

    -- the contexts of every step's file, by node id: its rows (for guards and the argument's local)
    local rows_of = {}
    local function ctx_rows(fn_id)
        local r = rows_of[fn_id]
        if r ~= nil then return r or nil end
        local n = store.node(fn_id)
        local g = n and (n.kind == 'module' and expr.of_module(store, fn_id) or expr.of(store, fn_id))
        r = g and g.fl and g.fl.stmts or false
        rows_of[fn_id] = r
        return r or nil
    end

    -- ── DELETE: each direct step in a unit ──────────────────────────────────────
    -- first COLLECT the steps (statement rows) per context, then DECIDE per guard: an `if` whose every statement is
    -- a step of this fact, whose condition has no effect, and which holds no `elseif`, goes whole (else and all);
    -- otherwise each step goes alone. (An `if` emptied step by step would be left as `if C then else end`.)
    local shape_count, shape_site = {}, {}
    local function shape(f, node, rows, row_i, fn)
        local norm = table.concat(text_of(node, f.lines), '\n'):gsub('%s+', ' ')
        shape_count[norm] = (shape_count[norm] or 0) + 1
        shape_site[norm] = shape_site[norm] or { f = f, node = node, rows = rows, row = row_i, fn = fn }
    end
    local function delete(f, node, file, line, what)
        if not owns_lines(node, f.lines) then
            declined[#declined + 1] = { file = file, line = line, reason = 'shares its line with other code' }
            return false
        end
        local sr, _, er = node:range()
        f.dels[#f.dels + 1] = { s = sr, e = er }
        for l = sr + 1, er + 1 do f.gone[l] = true end
        moves[#moves + 1] = { file = file, line = line, what = what }
        return true
    end
    local groups, order = {}, {}
    for _, s in ipairs(fact.steps) do
        if s.file ~= prelude then
            local f = file_rec(s.file)
            local rows = ctx_rows(s.fn)
            local call = f.idx and f.idx['function_call:' .. (s.line - 1)]
            local row_i
            for i, r in ipairs(rows or {}) do if r.l == s.line and r.t == 'function_call' then row_i = i end end
            if not (call and row_i) then
                declined[#declined + 1] = { file = s.file, line = s.line, reason = 'not a statement of its own (inside an expression)' }
            else
                local r = rows[row_i]
                local pi = r.parent or 0
                local p = pi ~= 0 and rows[pi] or nil
                local gk = (p and (p.t or ''):find('^if')) and (s.fn .. '#' .. pi) or (s.fn .. '@' .. row_i)
                if not groups[gk] then
                    groups[gk] = { f = f, rows = rows, fn = s.fn, file = s.file, parent = p and (p.t or ''):find('^if') and pi or nil, steps = {} }
                    order[#order + 1] = gk
                end
                table.insert(groups[gk].steps, { row = row_i, call = call, line = s.line })
            end
        end
    end
    for _, gk in ipairs(order) do
        local g = groups[gk]
        local f, rows = g.f, g.rows
        local whole = false
        if g.parent then
            local p = rows[g.parent]
            local children, nested = 0, false
            for _, q in ipairs(rows) do
                if q.parent == g.parent then children = children + 1 end
                -- any deeper row under this if (an elseif clause, a nested block) forbids the whole deletion
                local a = q.parent
                while a and a ~= 0 and a ~= g.parent do a = rows[a].parent end
                if a == g.parent and q.parent ~= g.parent then nested = true end
            end
            local ifn = f.idx['if_statement:' .. (p.l - 1)]
            if ifn and children == #g.steps and not nested then
                if effect_free(p.expr and p.expr.cond, f.spec) then whole = ifn
                else
                    for _, st in ipairs(g.steps) do
                        declined[#declined + 1] = { file = g.file, line = st.line,
                            reason = 'its guard `if` would be left empty, and its condition has an effect' }
                    end
                    g.steps = {}
                end
            end
        end
        if whole then
            if delete(f, whole, g.file, g.steps[1].line, #g.steps > 1 and ('guarded step x%d'):format(#g.steps) or 'guarded step') then
                shape(f, whole, rows, g.steps[1].row, g.fn)
            end
        else
            for _, st in ipairs(g.steps) do
                if delete(f, st.call, g.file, st.line, 'step') then shape(f, st.call, rows, st.row, g.fn) end
            end
        end
    end
    if #moves == 0 then return nil, 'every step of ' .. fact.key .. ' was declined', 'all-declined', declined end

    -- ── the ARGUMENT'S LOCAL, when nothing else in its scope reads it any more ────
    -- ⚠ a FUNCTION-DECLARATION row counts its whole body as uses (du's documented over-reach at a declaration row),
    -- so it is skipped here: that body is read through its own function node's rows, where deletions are seen
    local function reads_left(f, rows, name, skip_line)
        for _, r in ipairs(rows) do
            if not f.gone[r.l] and r.l ~= skip_line and not (r.t or ''):find('function_declaration') then
                for _, u in ipairs(r.use or {}) do if u == name then return true end end
            end
        end
        return false
    end
    local done_local = {}
    for _, s in ipairs(fact.steps) do
        local f = files[s.file]
        local rows = f and ctx_rows(s.fn)
        if f and rows and f.gone[s.line] then
            local call_row
            for _, r in ipairs(rows) do if r.l == s.line and r.t == 'function_call' then call_row = r end end
            local call
            if call_row and call_row.expr then
                for _, x in ipairs(call_row.expr.rhs or {}) do if x.k == 'call' then call = x end end
            end
            local arg = call and call.a and call.a[1]
            if arg and arg.k == 'name' then
                -- the declaring row: in this function, else at file level
                local scopes = { { rows = rows, fn = s.fn } }
                local mod = store.node(s.file)
                if mod then scopes[#scopes + 1] = { rows = ctx_rows(s.file) or {}, fn = s.file, file_level = true } end
                for _, sc in ipairs(scopes) do
                    local decl
                    for _, r in ipairs(sc.rows) do
                        if r.t == 'variable_declaration' and #(r.def or {}) == 1 and r.def[1] == arg.n then decl = r end
                    end
                    if decl then
                        local key = s.file .. ':' .. decl.l
                        if not done_local[key] then
                            -- file level: every function of the file may read it; function level: this one only
                            local still = false
                            if sc.file_level then
                                for _, n in ipairs(store.data.nodes or {}) do
                                    if n.file == s.file and (n.kind == 'function' or n.kind == 'method' or n.kind == 'module') then
                                        local rr = ctx_rows(n.id)
                                        if rr and reads_left(f, rr, arg.n, decl.l) then still = true; break end
                                    end
                                end
                            else
                                still = reads_left(f, sc.rows, arg.n, decl.l)
                            end
                            local dn = f.idx and f.idx['variable_declaration:' .. (decl.l - 1)]
                            if not still and dn and owns_lines(dn, f.lines) then
                                done_local[key] = true
                                local sr, _, er = dn:range()
                                f.dels[#f.dels + 1] = { s = sr, e = er }
                                for l = sr + 1, er + 1 do f.gone[l] = true end
                                moves[#moves + 1] = { file = s.file, line = decl.l, what = 'unused local `' .. arg.n .. '`' }
                            end
                        end
                        break
                    end
                end
            end
        end
    end

    -- ── INSERT into the prelude: the modal statement shape, with its argument's local ──
    local best, bn = nil, -1
    for norm, n in pairs(shape_count) do if n > bn or (n == bn and norm < best) then best, bn = norm, n end end
    local site = shape_site[best]
    local block = {}
    local stmt = text_of(site.node, site.f.lines)
    local r = site.rows[site.row]
    local call
    for _, x in ipairs((r.expr and r.expr.rhs) or {}) do if x.k == 'call' then call = x end end
    local arg = call and call.a and call.a[1]
    local decl_text
    if arg and arg.k == 'name' then
        local search = { site.rows, ctx_rows(site.f.rel) or {} }
        for _, rows in ipairs(search) do
            for _, q in ipairs(rows) do
                if not decl_text and q.t == 'variable_declaration' and #(q.def or {}) == 1 and q.def[1] == arg.n then
                    local dn = site.f.idx['variable_declaration:' .. (q.l - 1)]
                    if dn then decl_text = text_of(dn, site.f.lines) end
                end
            end
        end
    end
    local copies = 0
    for _, m in ipairs(moves) do if m.what:find('step') then copies = copies + 1 end end
    block[#block + 1] = ('-- COMMON SETUP, once for every unit this file loads (hoisted by cartograph: redundancy.lua, %d copies removed)')
        :format(copies)
    if decl_text then
        block[#block + 1] = 'do'
        for _, l in ipairs(decl_text) do block[#block + 1] = '    ' .. l end
        for _, l in ipairs(stmt) do block[#block + 1] = '    ' .. l end
        block[#block + 1] = 'end'
    else
        for _, l in ipairs(stmt) do block[#block + 1] = l end
    end
    local pf = file_rec(prelude)
    local prows = ctx_rows(prelude) or {}
    local loop_line
    for _, q in ipairs(prows) do
        if (q.parent or 0) == 0 and (q.t or ''):find('^for') or (q.parent or 0) == 0 and (q.t or ''):find('^while') then
            loop_line = q.l; break
        end
    end
    if not loop_line then return nil, 'the prelude ' .. prelude .. ' has no top-level loop to set up before', 'no-anchor', declined end
    local at = loop_line - 1 -- 1-based line just above the loop
    while at > 0 and (pf.lines[at] or ''):match('^%s*%-%-') do at = at - 1 end
    pf.ins[#pf.ins + 1] = { after = at - 1, lines = block }

    local touched, stamps = {}, {}
    for rel, f in pairs(files) do
        if #f.dels > 0 or #f.ins > 0 then touched[#touched + 1] = rel; stamps[rel] = txn.disk_stamp(data.root, rel) end
    end
    table.sort(touched)
    local edits = {}
    for rel, f in pairs(files) do edits[rel] = { dels = f.dels, ins = f.ins } end
    return txn.protocol({ verb = 'hoist-setup', guards = { 'parses', 'spans-unchanged' }, refspecs = {},
        touched = touched, generation = store.generation, stamps = stamps,
        desc = ('hoist-setup: %s into %s, %d change(s) in %d file(s)'):format(fact.key, prelude, #moves, #touched),
        -- UNREVIEWED, not 'all': behaviour is kept only under the plan's premises, and one of them (setting it up
        -- earlier changes nothing else) is unchecked. Running each touched unit ALONE is that review.
        preserves = 'unreviewed',
        fact = fact.key, prelude = prelude, edits = edits, moves = moves, declined = declined, block = block,
        premises = hoist.assumes },
        function(p)
            return function(rel, before)
                local e = p.edits[rel]
                if not e or before == false then return before end
                return txn.edit_file(before, e.dels, {}, e.ins)
            end
        end), nil, nil, declined
end

--- dry-run lines for the cockpit
function M.report(store, opts)
    local plan, why, _, declined = M.plan(store, opts)
    local out = { 'hoist-setup', '' }
    if not plan then
        out[#out + 1] = why
        for _, d in ipairs(declined or {}) do out[#out + 1] = ('  %s:%d DECLINED: %s'):format(d.file, d.line, d.reason) end
        return out
    end
    out[#out + 1] = ('fact    %s'):format(plan.fact)
    out[#out + 1] = ('into    %s (before its first top-level loop)'):format(plan.prelude)
    for _, a in ipairs(plan.premises or {}) do
        out[#out + 1] = ('premise %s [%s]: %s%s'):format(a.id, a.basis, a.says, a.src and ('  — ' .. a.src) or '')
    end
    local n = {}
    for _, m in ipairs(plan.moves) do n[m.what] = (n[m.what] or 0) + 1 end
    for what, c in pairs(n) do out[#out + 1] = ('removes %d %s(s)'):format(c, what) end
    out[#out + 1] = ('touches %d file(s); %d declined'):format(#plan.touched, #plan.declined)
    for _, d in ipairs(plan.declined) do out[#out + 1] = ('  %s:%d DECLINED: %s'):format(d.file, d.line, d.reason) end
    out[#out + 1] = 'then: run each touched unit ALONE (SPEC=<name>) — that checks the order-insensitive premise'
    out[#out + 1] = ''
    local before, after, err = txn.dryrun(store, plan)
    if not before then out[#out + 1] = 'dry-run failed: ' .. tostring(err); return out end
    for _, l in ipairs(txn.difftext(before, after, plan.touched)) do out[#out + 1] = l end
    return out
end

return M
