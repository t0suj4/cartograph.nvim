-- loopcost.lua — INPUT-SIZED LOOP NESTING, ACROSS CALLS: the hidden quadratic (CART-1057).
--
-- USER (2026-09-24): "cartograph should be able to find inefficiency and narrow down performance
-- issues, if it's a missing capability it's a work list"; "we should be able to surface these
-- inefficient shapes in cartograph". The shipped performance lenses (optimize's LICM/CSE, exprlint's
-- concat-in-loop) are PER FUNCTION, and the quadratic that made hive's extraction run for hours
-- (treesitter.lua `fn_at`, a linear scan of the file's function ranges called once per call site)
-- is harmless inside its own function: the cost is the COMPOSITION. They scored 0 of 57.
--
-- ── THE SHAPE ─────────────────────────────────────────────────────────────────────
-- A loop is INPUT-SIZED when what it iterates is not a constant: its head reads a name that is
-- not bound by the loop itself, not an iteration builtin, and not a local whose only definition
-- is a constructor of literals. A param, an upvalue, a global, a field of one, a local built up
-- from any of those: all input-sized. An ALL-CAPS name is taken as a constant BY ITS NAME, and
-- the finding says so (`const_by_name`) rather than hiding the guess.
--   depth(F) = max( input-loop nesting inside F,
--                   for each call inside F: (input loops of F around the call) + depth(callee) )
-- A depth of 2 or more that is reached THROUGH A CALL is a HIDDEN nesting: neither function
-- shows it alone. That is the finding; the chain (outer loop -> call -> inner loop) is its
-- witness. A depth of 2 inside one function is VISIBLE nesting, reported apart and ranked lower.
-- ★ SHARED STATE RANKS FIRST. A nested loop is usually a PARTITION (per file, the file's own
-- matches: linear in total) or a FAN-OUT (a node's children). The quadratic that bites is a callee
-- that SCANS STATE OUTLIVING THE CALL — an upvalue or a global that accumulates over the whole run
-- (`fnRanges`, a list searched linearly by key) — once per element of an outer walk. So a hidden
-- finding whose inner loop iterates an upvalue/global is `hidden-shared`, ranked above `hidden`,
-- above `visible`. Found by ranking the fixture: by depth alone fn_at sat at 61 of 116, under
-- per-file x per-match chains that are linear in total.
-- ★ AN ACCUMULATING OUTER LOOP RANKS FIRST INSIDE THAT. fn_at is called per element of `pending`,
-- which the extractor APPENDS to for every call site of every file; `regions` and a file's `match`es
-- are parts of one element. A shared scan inside a loop over an accumulator is the corpus-sized
-- product. Detected from the file's text (`v[#v + 1] =`, `table.insert(v,`): a ranking signal only.
-- ⚠ A SHAPE, NOT A COST: the lens does not know how big a collection is at run time. Ten
-- elements nested in ten is nothing. The ranking is depth; the verdict needs a workload
-- (a profile, CART-1058). What this answers is "where CAN it be quadratic", with the names.
--
-- ── KNOWN LIMITS, each with its ticket ─────────────────────────────────────────────
--   MEMOIZATION IS INVISIBLE: a build guarded by `if not cache[k] then ... end` reads as a loop run
--     per call. After the fn_at fix the lens still reports it (as `hidden`, no longer `hidden-shared`,
--     because the scan moved into a helper over a param) — the reverse check half-passes.
--   ONE CHAIN PER FUNCTION: depth(F) keeps the deepest path only, so a shallower SHARED scan beside a
--     deeper plain one is masked (literal_flow's dead fnRanges scan hid behind df.stmts).
--   THE HEAD IS READ AS TEXT (role() below, a SCAFFOLD): the expression IR does not decompose a Lua
--     generic-for head (CART-1061), so called names, receivers and fields are told apart by their
--     position in the head's first line.
--   NO SIZES: a shape, not a cost; the verdict needs a workload (CART-1058).
--
-- ── THE BYTES UNIT (opts.unit = 'bytes') ───────────────────────────────────────────
-- The same algebra over ALLOCATION: the events are allocation sites (a table, a closure, a string
-- built by concatenation, an append — allocations() below) instead of loops, and a builtin costs
-- what it ALLOCATES (`alloc` in call_costs; absent = its time cost, an upper bound). Bytes never
-- exceed time per function, so the bytes findings are the time findings that ALSO allocate at that
-- degree: GC churn, and the memory side of a time/memory trade (idxrewrite's index).
-- ★ ACCEPTED BY MEASUREMENT: the spec runs the fixture and measures allocated bytes at two sizes
-- (GC stopped, JIT off — deterministic), and the static degree must match the growth exponent.
-- ⚠ With the JIT on, LuaJIT's allocation SINKING can remove an allocation this counts: an upper bound.
--
-- ── CALLEES: THE CALL GRAPH, THEN LEXICAL SCOPE ─────────────────────────────────────
-- A call the resolver linked (`c.to`) is followed. A BARE call it refused is resolved here by
-- LEXICAL SCOPE when exactly one same-named function is visible from the call: defined in the
-- same file, inside a function (or the file) that encloses the call. That is how the fixture is
-- reached at all: treesitter.lua holds TWO local `fn_at`s in two enclosing functions, so name
-- matching refuses all 8 calls, and each is decided by which function it sits in. Such an edge
-- is `lexical` on the finding (name-matched, scoped), never a claim the call graph made. The rule
-- belongs in the resolver (CART-1059); it lives here until it moves.

local expr = require 'cartograph.expr'
local argv = require 'cartograph.argv'
local flow = require 'cartograph.flow'
local at = require 'cartograph.at'

local M = {}

-- ⚠ NO LIST OF ITERATION BUILTINS: a builtin in a head is CALLED (`ipairs(t)`, `range(n)`) and
-- role() drops a called name; `next` is the iterator-triple rule. A name list is what the fixture
-- caught: `items` (python's dict method) in it silently dropped every variable named `items`.

local function const_ctor(node)
    -- a table constructor of BOUNDED SIZE: it has as many elements as it spells, whatever their
    -- values (`{ '^local%s+' .. esc, ... }` is two elements) — unless its LAST element is a call or
    -- `...`, which expand to any number of values. (The first cut demanded literal leaves, and read
    -- prologue.lua's two-pattern list as input-sized.)
    if not node or node.k ~= 'table' or not node.kids or #node.kids == 0 then return false end
    local last = node.kids[#node.kids]
    local v = last and (last.k == 'pair' and nil or last)
    if v and (v.k == 'call' or v.k == 'vararg') then return false end
    return true
end

--- innermost-enclosing lookup over one file's function spans, built once: sort by start,
--- keep each span's PARENT, and answer a line by walking up from the last span starting at
--- or before it. Nested-or-disjoint spans (a syntax tree) make the walk a parent chain, so a
--- query costs the nesting depth, not the file's function count — the very defect this lens
--- exists to find must not be in it.
local function span_index(spans)
    table.sort(spans, function(a, b) if a.s ~= b.s then return a.s < b.s end return a.e > b.e end)
    local stack = {}
    for _, sp in ipairs(spans) do
        while #stack > 0 and stack[#stack].e < sp.s do stack[#stack] = nil end
        sp.parent = stack[#stack]
        stack[#stack + 1] = sp
    end
    local starts = {}
    for i, sp in ipairs(spans) do starts[i] = sp.s end
    return function(line)
        local lo, hi, k = 1, #spans, 0
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            if starts[mid] <= line then k = mid; lo = mid + 1 else hi = mid - 1 end
        end
        local sp = spans[k]
        while sp and sp.e < line do sp = sp.parent end
        return sp
    end
end

--- ACCUMULATION BY CONCATENATION (`s = s .. x`, `self.buf = self.buf .. chunk`): an OPERATOR with a
--- cost. A string is copied whole by every concatenation, so the row costs the target's CURRENT
--- size, and its level is the degree of that size:
---   growth  the input-sized loops around the row that do not also hold a RESET of the target (a
---           non-accumulating assignment, a `local` declaration, a rebinding of its base object, or
---           the loop that binds the base: each iteration a fresh element) — the string grows per trip
---   entry   1 when the target ARRIVES input-sized: a string parameter, a field of a parameter, or
---           state outliving the call (an upvalue/global, or a field of one)
---   level = max(growth, entry); a local built from nothing in a loop-free function is 0
--- ★ THE COMPOSED CASE IS THE NEW ONE: `buf = buf .. x` on an upvalue, in a function with no loop,
--- called once per element of an outer walk, is quadratic across calls, and no per-function lens
--- (exprlint's concat-in-loop) can see it — there is no loop where the concat is. It is `shared`
--- (ranked as hidden-shared), the same predicate as a loop over an upvalue. A field of `self` is a
--- parameter's, not shared, exactly as a loop over `self.items` is.
--- ⚠ Like a shared loop, a shared string may be reset in ANOTHER function (a flush): not checked.
--- The binder of a loop is read from the head TEXT (CART-1061), as role() does.
local PLAIN_ASSIGN = { assignment_statement = true, assignment = true, assignment_expression = true }
local function target_text(e)
    if e.k == 'name' then return e.n end
    if e.k == 'field' then return target_text(e.b) .. '.' .. e.n end
    if e.k == 'index' then return target_text(e.b) .. '[]' end
    return '?'
end
local function accumulations(rows, loops, params, bound, lines, op)
    if not op then return {} end
    local function within(L, r)
        local p = rows[r].parent
        while p and p ~= 0 do if p == L then return true end; p = rows[p].parent end
        return false
    end
    local function root_of(e)
        while e and (e.k == 'field' or e.k == 'index') do e = e.b end
        return e and e.k == 'name' and e.n or nil
    end
    -- every row that (re)binds a NAME or assigns a TARGET, by structural key
    local binds, assigns, acc = {}, {}, {}
    for i, r in ipairs(rows) do
        local e = r.expr
        for _, l in ipairs(e and e.lhs or {}) do
            if l.k == 'name' then local t = binds[l.n] or {}; t[#t + 1] = i; binds[l.n] = t end
            if expr.is_pure(l) then local k = expr.key(l); local t = assigns[k] or {}; t[#t + 1] = i; assigns[k] = t end
        end
        -- a declaration (`local s = s .. x`) makes a NEW binding from the old one: not an accumulation
        if e and PLAIN_ASSIGN[r.t or ''] and e.lhs and e.rhs and #e.lhs == 1 and #e.rhs == 1
            and e.rhs[1].k == 'bin' and e.rhs[1].op == op and expr.is_pure(e.lhs[1]) then
            local lk, self_read = expr.key(e.lhs[1]), false
            expr.walk(e.rhs[1], function(x)
                if not self_read and (x.k == 'name' or x.k == 'field' or x.k == 'index')
                    and expr.is_pure(x) and expr.key(x) == lk then self_read = true end
            end)
            if self_read then acc[i] = { key = lk, target = target_text(e.lhs[1]), lhs = e.lhs[1] } end
        end
    end
    local out = {}
    for i, a in pairs(acc) do
        local l = a.lhs
        local root = root_of(l)
        if root then
            local resets = {}
            for _, j in ipairs(assigns[a.key] or {}) do if not acc[j] or acc[j].key ~= a.key then resets[#resets + 1] = j end end
            if l.k ~= 'name' then for _, j in ipairs(binds[root] or {}) do resets[#resets + 1] = j end end
            local growth, chain = 0, {}
            for _, L in ipairs(loops) do
                if L.input and within(L.row, i) then
                    local head = lines[L.line] or ''
                    local binders = head:match('for%s+(.-)%s+in%f[%s]') or head:match('for%s+([%w_]+)%s*=') or ''
                    local binds_root = binders:find('%f[%w_]' .. root:gsub('%p', '%%%0') .. '%f[^%w_]') ~= nil
                    local reset_inside = false
                    for _, j in ipairs(resets) do if within(L.row, j) then reset_inside = true; break end end
                    if not binds_root and not reset_inside then growth = growth + 1; chain[#chain + 1] = L end
                end
            end
            local rebound = false
            for _, j in ipairs(binds[root] or {}) do if not acc[j] then rebound = true end end
            local outlives = not params[root] and not bound[root] and not rebound
            local entry = (params[root] or outlives) and 1 or 0
            local level = math.max(growth, entry)
            if level > 0 then
                out[#out + 1] = { row = i, line = rows[i].l, level = level, growth = growth,
                    target = a.target or root, shared = outlives and #resets == 0 or nil, param = params[root] or nil }
            end
        end
    end
    table.sort(out, function(x, y) return x.row < y.row end)
    return out
end

--- ALLOCATION SITES (the BYTES unit): a row that creates a fresh object — a table constructor, a
--- closure, a string built by the concatenation operator (not an accumulation: accumulations() prices
--- those by the target's size), or an APPEND (`t[#t + 1] = v`, which grows t by one slot). Each is a
--- bounded allocation (size degree 0); what makes it grow is the loops around it, counted by the
--- caller of this list exactly as for a call. A closure's own body is not this function's (the `fn`
--- node is an opaque leaf), so a helper's `{}` is priced where the helper is called.
local function allocations(rows, op, accums, LOOP)
    local skip = {}
    for _, a in ipairs(accums) do skip[a.row] = true end
    local out = {}
    for i, r in ipairs(rows) do
        local e, what = r.expr, nil
        local function scan(list, side)
            for _, x in ipairs(list or {}) do
                expr.walk(x, function(n)
                    if what then return end
                    if n.k == 'table' then what = 'table'
                    elseif n.k == 'fn' then what = 'closure'
                    elseif side == 'rhs' and op and n.k == 'bin' and n.op == op and not skip[i] then what = 'string'
                    elseif side == 'lhs' and n.k == 'index' and n.i and n.i.k == 'bin' and n.i.op == '+'
                        and n.i.l and n.i.l.k == 'un' and n.i.l.op == '#' then what = 'append' end
                end)
            end
        end
        if e and not (r.t or ''):find('^if') then scan(e.rhs, 'rhs'); scan(e.lhs, 'lhs') end
        -- a FOR head's expressions are evaluated ONCE per entry into the loop (a while/repeat condition
        -- is evaluated per trip, and stays counted)
        local p = r.parent and rows[r.parent]
        local head = (LOOP[r.t or ''] or (p and LOOP[p.t or ''] and (r.t or ''):find('clause'))) and (r.t or ''):find('^for') and true or nil
        if what then out[#out + 1] = { row = i, line = r.l, what = what, size = 0, head = head } end
    end
    return out
end

--- one function's loops: which are input-sized, what they iterate, and each loop's line span.
local function loops_of(store, fn, spec)
    local got = expr.of(store, fn.id)
    local fl = got and got.fl
    if not fl or not fl.stmts or #fl.stmts == 0 then return nil end
    local rows = fl.stmts
    local LOOP = flow.loops_of(fl)
    local defrow = {}          -- var -> { rows that define it }
    for i, r in ipairs(rows) do
        for _, v in ipairs(r.def or {}) do
            local l = defrow[v] or {}; l[#l + 1] = i; defrow[v] = l
        end
    end
    local params = {}
    for _, p in ipairs(fl.params or {}) do params[p] = true end
    local function within(L, r)
        local p = rows[r].parent
        while p and p ~= 0 do if p == L then return true end; p = rows[p].parent end
        return false
    end
    local fn_end = fn.range and at.el(fn.range) + 1 or math.huge
    local lines = (store.content and store.content(fn)) or {}
    local out = {}
    for i, r in ipairs(rows) do
        if LOOP[r.t or ''] then
            -- LOOP BINDERS: du records a Lua generic/numeric-for binder as a USE, not a def (flow's
            -- LOOPVAR covers java/js/cpp only), so the spec's `binders` answer (`got.bound`, every
            -- name a binder node binds in this function) is subtracted. A name bound by an OUTER
            -- loop is subtracted too: iterating the current element's parts is a fan-out, not a
            -- second input dimension.
            local bound = setmetatable({}, { __index = got.bound or {} })
            for _, v in ipairs(r.def or {}) do bound[v] = true end
            local iterates, const_by_name, shared = {}, {}, {}
            local head = lines[r.l] or ''
            -- WHAT A NAME IS IN THE HEAD, by its position in the head's text: called (`ipairs(t)`,
            -- `inext(n)`; ONE mechanism, the text, not the call records beside it), the receiver of a call (`q:iter_matches(root)`,
            -- `math.min(a, b)`: the module or object, not the collection), or a field (`st.def`, which
            -- du lists as a read of `def`). None of those is WHAT is iterated.
            local function role(v)
                local pv = v:gsub('%p', '%%%0')
                -- lua's explicit generic-for triple `for _, c in inext, n, -1`: the FIRST
                -- expression is the iterator function, the state after it is what is walked
                if head:find('%f[%w_]in%s+' .. pv .. '%s*,') then return nil end
                for pre, post, eq1 in head:gmatch('(.?)%f[%w_]' .. pv .. '%f[^%w_](%s*[%(%.:]?)(=?=?)') do
                    local p1 = post:gsub('%s', '')
                    -- `{ plain = true }` in a head: a constructor KEY, not a read (du lists it as a use)
                    if eq1 == '=' and p1 == '' then pre = '.' end
                    if pre ~= '.' and pre ~= ':' then
                        if p1 == '' then return 'value' end -- followed by neither `(` nor `.`/`:`
                        -- ONE walk decides: `v(` = CALLED, `v.x(` / `v.a.b:c(` = a RECEIVER (a module or an
                        -- object, any depth), `v.x` alone = a field read of v (a value)
                        local at = head:find('%f[%w_]' .. pv .. '%f[^%w_]')
                        local j = at and at + #v
                        while j do
                            local _, e2 = head:find('^%s*[%.:]%s*[%w_]+', j)
                            if not e2 then break end
                            j = e2 + 1
                        end
                        local rest = j and head:match('^%s*(.?)', j) or ''
                        if rest ~= '(' and rest ~= '"' and rest ~= "'" and rest ~= '{' then return 'value' end
                    end
                end
                return nil
            end
            for _, v in ipairs(r.use or {}) do
                if not bound[v] and v ~= '_' and role(v) == 'value' then
                    local defs = defrow[v]
                    local constant = false
                    if defs and not params[v] and #defs == 1 then
                        local rhs = rows[defs[1]].expr and rows[defs[1]].expr.rhs
                        constant = rhs and #rhs == 1 and const_ctor(rhs[1]) or false
                    end
                    if v:match('^[A-Z][A-Z0-9_]*$') then const_by_name[#const_by_name + 1] = v
                    elseif not constant then
                        iterates[#iterates + 1] = v
                        -- neither a param nor defined here: an upvalue or a global, i.e. state
                        -- that outlives one call (see SHARED in the header)
                        -- (a while/repeat loop's trip count is not a collection's size: its reads
                        -- make it input-sized, never SHARED)
                        if not params[v] and not defs and r.t ~= 'while_statement'
                            and r.t ~= 'repeat_statement' then shared[#shared + 1] = v end
                    end
                end
            end
            -- the span: from the head to the line before the first row after it that is
            -- not inside it (or the function's end)
            local e = fn_end
            for j = i + 1, #rows do
                if not within(i, j) then e = math.max(r.l, rows[j].l - 1); break end
            end
            -- A MAYBE-LOOP: nothing input-sized is named, but the head CALLS something for its
            -- collection (`ipairs(vim.api.nvim_list_bufs())`, `while more() do`) — a size nobody knows.
            -- Not a certified level (that would be a guess) and not a zero (that would hide it): a hole.
            local maybe
            if #iterates == 0 then
                for callee in head:gmatch('([%a_][%w_%.:]*)%s*%(') do
                    local base = callee:match('([%w_]+)$')
                    if base ~= 'ipairs' and base ~= 'pairs' and base ~= 'next' and base ~= 'for' and base ~= 'while' then
                        maybe = callee; break
                    end
                end
            end
            out[#out + 1] = { row = i, line = r.l, last = e, kind = r.t, input = #iterates > 0, maybe = maybe,
                iterates = iterates, const_by_name = #const_by_name > 0 and const_by_name or nil,
                shared = #shared > 0 and shared or nil, head_use = r.use or {} }
        end
    end
    -- the function's NAME CLASSES, for a builtin's arguments (the same predicate as a loop head)
    local const = {}
    for v, defs in pairs(defrow) do
        if #defs == 1 and not params[v] then
            local rhs = rows[defs[1]].expr and rows[defs[1]].expr.rhs
            if rhs and #rhs == 1 and const_ctor(rhs[1]) then const[v] = true end
        end
    end
    local accums = accumulations(rows, out, params, got.bound or {}, lines, spec and spec.concat_op)
    return { loops = out, bound = got.bound or {}, params = params, defs = defrow, const = const,
        accums = accums, allocs = allocations(rows, spec and spec.concat_op, accums, LOOP) }
end

--- @param store table   an ingested store
--- @param data table    the extraction (nodes + calls)
--- @param opts table|nil { files = <lua pattern>, fileset = { [file] = true } } — which functions are REPORTED
---   (callees anywhere are still followed)
--- @return table { findings = {...}, stats = {...} }
function M.analyze(store, data, opts)
    opts = opts or {}
    -- THE UNIT: 'time' (steps; the default) or 'bytes' (allocation). ONE algebra, two sets of events:
    -- time counts loops, calls and accumulations; bytes counts allocation sites, calls and
    -- accumulations, and prices a builtin by its `alloc` (default: its time cost — a call cannot
    -- allocate more than it runs, so the default is an upper bound and a lower one must cite).
    local BYTES = opts.unit == 'bytes'
    local fns, by_id, by_file_name, spans_of = {}, {}, {}, {}
    for _, n in ipairs(data.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and n.file and n.range then
            by_id[n.id] = n
            local short = (n.name or ''):match('([%w_]+)$')
            local k = n.file .. '\0' .. (short or '')
            local l = by_file_name[k] or {}; l[#l + 1] = n; by_file_name[k] = l
            local sp = spans_of[n.file] or {}
            sp[#sp + 1] = { s = at.sl(n.range) + 1, e = at.el(n.range) + 1, id = n.id }
            spans_of[n.file] = sp
            if (not opts.files or n.file:match(opts.files)) and (not opts.fileset or opts.fileset[n.file]) then
                fns[#fns + 1] = n
            end
        end
    end
    local enclosing = {}
    for f, sp in pairs(spans_of) do enclosing[f] = span_index(sp) end
    local function parent_span(node)
        -- the function the node is DEFINED in: the innermost span containing its start line,
        -- other than its own
        local find = enclosing[node.file]
        local sp = find and find(at.sl(node.range) + 1)
        while sp and sp.id == node.id do sp = sp.parent end
        return sp
    end
    local calls_of = {}
    for _, c in ipairs(data.calls or {}) do
        if c.fn then local l = calls_of[c.fn] or {}; l[#l + 1] = c; calls_of[c.fn] = l end
    end
    local stats = { fns = 0, analysed = 0, loops = 0, input_loops = 0, calls = 0,
        calls_in_input_loops = 0, followed_graph = 0, followed_lexical = 0, refused = 0, accums = 0, allocs = 0 }

    local callee_memo = {}
    local callee_of_raw, resolve_lexical
    local function callee_of(c)
        local m = callee_memo[c]
        if m == nil then
            local g, how = callee_of_raw(c)
            m = g and { g, how } or false
            callee_memo[c] = m
        end
        if m then return m[1], m[2] end
        return nil
    end
    function callee_of_raw(c)
        if c.to and by_id[c.to] then return by_id[c.to], 'graph' end
        if c.to or not c.callee or (c.full and c.full ~= c.callee) or not c.file then return nil end
        local g = resolve_lexical(c.callee, c.file, (c.line or 0) + 1)
        if g then return g, 'lexical' end
        return nil
    end
    function resolve_lexical(name, file, line)
        local cands = file and by_file_name[file .. '\0' .. name]
        if not cands then return nil end
        local best, best_depth, tie
        for _, cand in ipairs(cands) do
            local par = parent_span(cand)
            local visible = (not par) or (par.s <= line and line <= par.e)
            if visible then
                local d = 0; local p = par
                while p do d = d + 1; p = p.parent end
                if not best or d > best_depth then best, best_depth, tie = cand, d, false
                elseif d == best_depth then tie = true end
            end
        end
        if best and not tie then return best end
        return nil
    end

    -- ── THE VALUE: certified depth + HOLES (the unknowns along the chain) ───────────
    -- `c` is what is PROVEN: own input-sized loops, resolved callees, costed builtins whose growing
    -- argument is input-sized. A HOLE is a call whose cost is not known — `unresolved` (project code
    -- the graph did not link), `uncosted` (a library call with no call_costs entry), `dynamic` (a
    -- method on an unknown receiver, a callback not found), `recursive` (a cycle). ALONG a chain c
    -- adds and holes unite; ACROSS alternatives the greatest c wins and the holes of every path
    -- TIED with it are kept. A finding with holes is `depth >= c`: never raised to a guess, never
    -- read as zero. (Holes on a path BELOW the winning c are dropped: such a path could exceed it
    -- only if its unknown is worth the gap; the report says "holes at the certified depth".)
    local HOLE_CAP = 8
    local function merge(a, b)
        if not b or #b == 0 then return a end
        if not a or #a == 0 then return b end
        local out, seen, extra = {}, {}, (a.more or 0) + (b.more or 0)
        for _, src in ipairs({ a, b }) do
            for _, h in ipairs(src) do
                local k = h.name .. '\0' .. h.class
                if not seen[k] then
                    seen[k] = true
                    if #out < HOLE_CAP then out[#out + 1] = h else extra = extra + 1 end
                end
            end
        end
        out.more = extra > 0 and extra or nil
        return out
    end
    local project_names = {}
    for k in pairs(by_file_name) do project_names[k:match('%z(.*)$') or ''] = true end
    local function hole_of(name, c, class)
        local short = (name or ''):match('([%w_]+)$') or name
        class = class or ((c and c.method) and 'dynamic') or (project_names[short] and 'unresolved') or 'uncosted'
        return { name = name or '?', class = class, file = c and c.file, line = c and ((c.line or 0) + 1) }
    end
    -- callback nodes minted on a call's line (`pcall(function() ... end)` -> `pcall#cb`)
    local cb_at = {}
    for _, n in ipairs(data.nodes or {}) do
        if n.file and n.range and n.name and n.name:find('#', 1, true) and by_id[n.id] then
            local k = n.file .. '\0' .. at.sl(n.range)
            local l = cb_at[k] or {}; l[#l + 1] = n; cb_at[k] = l
        end
    end
    local lang_spec = {}
    local function spec_for(file)
        local lang = file and expr.lang_of(file)
        if not lang then return nil end
        local t = lang_spec[lang]
        if t == nil then
            local ok, sp = pcall(require, 'cartograph.spec.' .. lang)
            t = ok and type(sp) == 'table' and sp or false
            lang_spec[lang] = t
        end
        return t or nil
    end

    -- ★ RECURSION, DETERMINISTICALLY: the call graph's strongly connected components, once. A call
    -- to a function in the caller's OWN component costs a `recursive` hole and never re-enters; a call
    -- INTO a component from outside costs its members' greatest base depth (+ that hole). A
    -- re-entry guard ("return a stub while active") memoizes partial answers, so a function's depth
    -- would depend on which caller asked first — the order-dependence the Maven BOM cycle guard had
    -- (CART-1051, rule 7). Components are over the resolved call edges (graph + lexical).
    local scc_of, self_loop, comp_members = {}, {}, {}
    do
        local index, low, onstack, stack, nexti, comp = {}, {}, {}, {}, 0, 0
        local function succ(id)
            local out = {}
            for _, c in ipairs(calls_of[id] or {}) do
                local g = callee_of(c)
                if g then
                    if g.id == id then self_loop[id] = true end
                    out[#out + 1] = g.id
                end
            end
            return out
        end
        for id in pairs(by_id) do
            if not index[id] then
                -- iterative Tarjan: frames of { id, successors, next position }
                local frames = { { id, succ(id), 1 } }
                index[id], low[id] = nexti, nexti; nexti = nexti + 1
                stack[#stack + 1] = id; onstack[id] = true
                while #frames > 0 do
                    local fr = frames[#frames]
                    local v, ss, k = fr[1], fr[2], fr[3]
                    if k <= #ss then
                        fr[3] = k + 1
                        local w = ss[k]
                        if not index[w] then
                            index[w], low[w] = nexti, nexti; nexti = nexti + 1
                            stack[#stack + 1] = w; onstack[w] = true
                            frames[#frames + 1] = { w, succ(w), 1 }
                        elseif onstack[w] and index[w] < low[v] then low[v] = index[w] end
                    else
                        frames[#frames] = nil
                        if #frames > 0 then
                            local u = frames[#frames][1]
                            if low[v] < low[u] then low[u] = low[v] end
                        end
                        if low[v] == index[v] then
                            comp = comp + 1
                            local members = {}
                            repeat
                                local w = stack[#stack]; stack[#stack] = nil; onstack[w] = nil
                                scc_of[w] = comp; members[#members + 1] = w
                            until w == v
                            if #members > 1 then
                                for _, w in ipairs(members) do self_loop[w] = self_loop[w] or 'scc' end
                            end
                            if #members > 1 or self_loop[v] then comp_members[comp] = members end
                        end
                    end
                end
            end
        end
    end
    local function same_scc(a, b)
        return scc_of[a] and scc_of[a] == scc_of[b] and (a ~= b or self_loop[a]) and true or false
    end

    local memo, active, loops_memo = {}, {}, {}
    local function loops_for(fn)
        local L = loops_memo[fn.id]
        if L == nil then
            local ok, got = pcall(loops_of, store, fn, spec_for(fn.file))
            L = ok and got or false
            loops_memo[fn.id] = L
        end
        return L or nil
    end
    -- the input-sized loops around a line (certified), and the MAYBE-loops around it (holes)
    local function around(loops, line, callee_name, file, in_for_head)
        local n, chain, mh = 0, {}, nil
        for _, L in ipairs(loops) do
            if (L.input or L.maybe) and line >= L.line and line <= L.last and not (in_for_head and line == L.line) then
                local in_head = false
                if line == L.line and callee_name then
                    for _, v in ipairs(L.head_use) do if v == callee_name then in_head = true end end
                end
                if not in_head then
                    if L.input then n = n + 1; chain[#chain + 1] = L
                    else
                        mh = merge(mh, { { name = ('loop over %s()'):format(L.maybe), class = 'dynamic',
                            file = file, line = L.line } })
                    end
                end
            end
        end
        return n, chain, mh
    end
    -- an ARGUMENT's size, by the loop head's predicate: none (a literal, a loop binder = the current
    -- element, a constant) | param | local | shared (an upvalue/global) | expr (not a plain name)
    local function arg_size(ctx, c, i)
        local name, k
        if i == 0 then
            -- the RECEIVER's text is `full` minus `:callee`: a plain name or a field/index of one
            -- (`x.name`, `t[1]`) is classed by its BASE name, as a loop head is; anything else — a
            -- call result (`src:sub(a, b)`), a parenthesized expression — has an unknown size
            local recv = (c.full or ''):match('^(.*)[:%.][%w_]+$') or ''
            if recv:find('[%(%)]') or not recv:match('^[%a_]') then return 'expr', recv end
            name = recv:match('^([%a_][%w_]*)'); k = 'local'
        else
            -- ⚠ a METHOD call's argv carries its RECEIVER first (`text:find(line)` -> text, line)
            local a = argv.at(c, c.method and i + 1 or i)
            if not a then return 'none' end
            k, name = a.k, a.name
        end
        if k == 'lit' or k == 'scalar' then return 'none' end
        if not name then return 'expr' end
        if ctx.bound[name] or name:match('^[A-Z][A-Z0-9_]*$') then return 'none', name end
        if ctx.params[name] then return 'param', name end
        if ctx.defs[name] then return ctx.const[name] and 'none' or 'local', name end
        return 'shared', name
    end

    local depth
    local function func_arg_cost(c, k)
        local a = argv.at(c, c.method and k + 1 or k)
        if not a or a.k == 'lit' or a.k == 'scalar' then return nil end
        if a.name then -- a function passed BY NAME (`pcall(heavy, t)`: k = 'func', name = 'heavy')
            local g = resolve_lexical(a.name, c.file, (c.line or 0) + 1)
            if g then return depth(g) end
            return { c = 0, holes = { hole_of(a.name, c) } }
        end
        if a.k == 'func' or a.k == 'callable' then -- an inline function: the callback node on the line
            local l = c.file and cb_at[c.file .. '\0' .. (c.line or 0)]
            if l and #l == 1 then return depth(l[1]) end
            return { c = 0, holes = { hole_of((c.full or c.callee or '?') .. '(function)', c, 'dynamic') } }
        end
        return nil
    end
    local function builtin_cost(entry, key, c, ctx, spec)
        local e = entry.arity and entry.arity[argv.n(c) - (c.method and 1 or 0)] or nil
        local cost = (e and e.cost) or entry.cost
        local arg = (e and e.arg) or entry.arg or 1
        local function at_arg(i) return argv.at(c, c.method and i + 1 or i) end
        if BYTES then
            local a = (e and e.alloc) or entry.alloc
            if a == 'captures' then
                -- a find returns indices, plus a substring per CAPTURE: bounded unless the pattern
                -- captures (or is not a literal, or the search is not plain)
                local pa = entry.plain and at_arg(entry.plain)
                local pp = entry.pattern and at_arg(entry.pattern)
                local text = pp and pp.k == 'lit' and pp.v and (spec and spec.unescape and spec.unescape(pp.v) or pp.v)
                local captures = not text or text:gsub('%%.', ''):find('(', 1, true)
                a = ((pa and pa.v == 'true') or not captures) and 'const' or 'n'
            end
            cost = a or (cost == 'nlogn' and 'n' or cost)
        end
        local rec = { c = 0, builtin = key, by_name = entry.by_name, log = cost == 'nlogn', cost = cost }
        if cost ~= 'const' then
            rec.size, rec.argname = arg_size(ctx, c, arg)
            -- an expression's size is NOT KNOWN: a hole, never a certified level (the rule for
            -- every unknown), e.g. the slice in `src:sub(a, b):match(p)`
            if rec.size == 'expr' then
                rec.holes = merge(rec.holes, { hole_of(('%s over %s'):format(key, rec.argname or 'an expression'), c, 'dynamic') })
            elseif rec.size ~= 'none' then rec.c = 1 end
        end
        if entry.calls then
            local f = func_arg_cost(c, entry.calls.arg)
            if f then
                rec.c = entry.calls.per == 'element' and rec.c + f.c or math.max(rec.c, f.c)
                rec.holes, rec.fvia = f.holes, f
            end
        end
        -- THE PATTERN (only where the subject is input-sized: backtracking multiplies ITS length).
        -- An upper bound needs adversarial input, so it is a HOLE, never certified depth.
        if not BYTES and entry.pattern and rec.size and rec.size ~= 'none' and rec.size ~= 'expr' then
            local pa = entry.plain and at_arg(entry.plain)
            if not (pa and pa.v == 'true') then
                local pp = at_arg(entry.pattern)
                if pp and pp.k == 'lit' and pp.v and spec and spec.pattern_degree then
                    local text = spec.unescape and spec.unescape(pp.v) or pp.v
                    local d = spec.pattern_degree(text, entry.no_anchor)
                    rec.pattern, rec.degree = pp.v, d
                    if d >= 2 then
                        rec.holes = merge(rec.holes, { { name = ('%s %q <= n^%d'):format(key, pp.v, d), class = 'backtrack',
                            degree = d, file = c.file, line = (c.line or 0) + 1 } })
                    end
                elseif pp then
                    rec.holes = merge(rec.holes, { hole_of(key .. ' <pattern>', c, 'dynamic') })
                end
            end
        end
        return rec
    end
    -- what one call COSTS: a node's depth, a costed builtin, or a hole
    local function callee_cost(c, ctx, fn)
        local g, how = callee_of(c)
        if g then
            -- INSIDE its own component a call costs only the recursion it closes (a hole): a walk the
            -- lens cannot size, never certified depth (a recursive tree walk is linear)
            if same_scc(fn.id, g.id) then return { c = 0, holes = { hole_of(g.name, c, 'recursive') } } end
            local members = comp_members[scc_of[g.id]]
            if members then
                -- ENTERING a component from outside may run any member's loops: its depth is the
                -- greatest BASE depth over the members (each computed with intra-component calls as
                -- holes, so no cycle is followed and the answer does not depend on visiting order)
                local best
                for _, mid in ipairs(members) do
                    local d = depth(by_id[mid])
                    if not best or d.c > best.c or (d.c == best.c and mid == g.id) then best = d end
                end
                local holes = { hole_of(g.name, c, 'recursive') }
                for _, mid in ipairs(members) do holes = merge(holes, depth(by_id[mid]).holes) end
                return { c = best.c, holes = holes, node = g, how = how, sub = best }
            end
            local sub = depth(g)
            return { c = sub.c, holes = sub.holes, node = g, how = how, sub = sub }
        end
        local spec = spec_for(c.file or fn.file)
        local costs = spec and spec.call_costs
        if costs then
            local key = c.full or c.callee -- `full` is nil on some bare calls; the callee is the name
            local entry = key and costs[key]
            if not entry and c.method and c.callee then key = ':' .. c.callee; entry = costs[key] end
            if entry then return builtin_cost(entry, key, c, ctx, spec) end
        end
        return { c = 0, holes = { hole_of(c.full or c.callee, c) } }
    end
    function depth(fn)
        local m = memo[fn.id]
        if m then return m end
        if active[fn.id] then return { c = 0, holes = { hole_of(fn.name or fn.id, { file = fn.file }, 'recursive') } } end
        active[fn.id] = true
        local ctx = loops_for(fn)
        local loops = ctx and ctx.loops or {}
        local best = { c = 0 }
        local function consider(cand)
            if cand.c > best.c then best = cand
            elseif cand.c == best.c and cand.holes and #cand.holes > 0 then
                local nb = {}
                for k, v in pairs(best) do nb[k] = v end
                nb.holes = merge(best.holes, cand.holes)
                best = nb
            end
        end
        for _, L in ipairs(BYTES and {} or loops) do
            if L.input or L.maybe then
                local n, chain, mh = around(loops, L.line, nil, fn.file)
                consider({ c = n, loops = chain, visible = L.input and true or nil, holes = mh })
            end
        end
        -- an ALLOCATION SITE (bytes): the loops around it
        for _, A in ipairs(BYTES and ctx and ctx.allocs or {}) do
            local n, chain, mh = around(loops, A.line, nil, fn.file, A.head)
            consider({ c = n + A.size, loops = chain, visible = true, holes = mh, alloc = A })
        end
        -- an ACCUMULATING CONCATENATION costs its target's size (accumulations() above)
        for _, A in ipairs(ctx and ctx.accums or {}) do
            local n, chain, mh = around(loops, A.line, nil, fn.file)
            consider({ c = n + A.level, loops = chain, visible = true, holes = mh, concat = A })
        end
        if ctx then
            for _, c in ipairs(calls_of[fn.id] or {}) do
                local cc = callee_cost(c, ctx, fn)
                if cc.c > 0 or (cc.holes and #cc.holes > 0) then
                    local n, chain, mh = around(loops, (c.line or 0) + 1, c.callee, fn.file)
                    consider({ c = n + cc.c, holes = merge(cc.holes, mh), loops = chain, via = cc })
                end
            end
        end
        active[fn.id] = nil
        memo[fn.id] = best
        return best
    end

    -- ACCUMULATORS, per file: names the file appends to (`v[#v + 1] =`, `table.insert(v,`).
    -- ⚠ TEXT, file-scoped: a same-named local elsewhere in the file counts too. It only RANKS.
    local acc_memo = {}
    local function accumulators(file, sample_fn)
        local a = acc_memo[file]
        if a then return a end
        a = {}
        local src = (store.content and store.content({ file = file, id = file, kind = 'module' })) or {}
        if #src == 0 and sample_fn then src = store.content(sample_fn) or {} end
        for _, l in ipairs(src) do
            for v in l:gmatch('([%w_]+)%[#([%w_]+)%s*%+%s*1%]%s*=') do a[v] = true end
            for v in l:gmatch('table%.insert%(%s*([%w_]+)%s*,') do a[v] = true end
        end
        acc_memo[file] = a
        return a
    end
    local function outer_accumulates(file, chain, fn)
        local a = accumulators(file, fn)
        for _, L in ipairs(chain or {}) do
            for _, v in ipairs(L.iterates) do if a[v] then return v end end
        end
        return nil
    end
    -- does the callee side SCAN SHARED STATE? a depth-contributing loop reading an upvalue/global,
    -- or a costed builtin whose growing argument is one, down the chain
    local function scans_shared(rec)
        while rec do
            if rec.builtin then
                if rec.size == 'shared' then return { shared = { rec.argname or rec.builtin } } end
                rec = rec.fvia
            else
                for _, L in ipairs(rec.loops or {}) do if L.shared then return L end end
                if rec.concat and rec.concat.shared then return { shared = { rec.concat.target } } end
                local v = rec.via
                if rec.sub then rec = rec.sub elseif v then rec = v.sub or v else rec = nil end
            end
        end
        return nil
    end

    local findings, hole_count = {}, {}
    stats.costed, stats.holes = 0, {}
    for _, fn in ipairs(fns) do
        stats.fns = stats.fns + 1
        local ctx = loops_for(fn)
        if ctx then
            local loops = ctx.loops
            stats.analysed = stats.analysed + 1
            stats.loops = stats.loops + #loops
            for _, L in ipairs(loops) do if L.input then stats.input_loops = stats.input_loops + 1 end end
            stats.accums = stats.accums + #(ctx.accums or {})
            stats.allocs = stats.allocs + #(ctx.allocs or {})
            local seen = {}
            for _, c in ipairs(calls_of[fn.id] or {}) do
                stats.calls = stats.calls + 1
                local line = (c.line or 0) + 1
                local n, chain, mh = around(loops, line, c.callee, fn.file)
                if n > 0 then
                    stats.calls_in_input_loops = stats.calls_in_input_loops + 1
                    local cc = callee_cost(c, ctx, fn)
                    if cc.node then
                        if cc.how == 'graph' then stats.followed_graph = stats.followed_graph + 1
                        else stats.followed_lexical = stats.followed_lexical + 1 end
                    elseif cc.builtin then stats.costed = stats.costed + 1
                    else
                        stats.refused = stats.refused + 1
                        local cl = cc.holes and cc.holes[1] and cc.holes[1].class or 'none'
                        stats.holes[cl] = (stats.holes[cl] or 0) + 1
                    end
                    local total = n + cc.c
                    local holes = merge(cc.holes, mh)
                    local kind
                    if total >= 2 then kind = scans_shared(cc) and 'hidden-shared' or 'hidden'
                    elseif holes and #holes > 0 then kind = 'possible' end
                    local key = (cc.node and cc.node.id or cc.builtin or c.full or c.callee or '?') .. '\0' .. chain[#chain].line
                    if kind and not seen[key] then
                        seen[key] = true
                        local sh = kind == 'hidden-shared' and scans_shared(cc) or nil
                        findings[#findings + 1] = { kind = kind, unit = opts.unit, fn = fn.id, file = fn.file, line = line,
                            depth = total, holes = holes, outer = chain,
                            callee = cc.node and cc.node.id, builtin = cc.builtin, how = cc.how,
                            inner = cc.node and cc.sub or cc, shared = sh and sh.shared or nil,
                            accumulator = sh and outer_accumulates(fn.file, chain, fn) or nil }
                        if kind == 'possible' then
                            for _, h in ipairs(holes) do
                                local hk = h.name .. '\0' .. h.class
                                hole_count[hk] = (hole_count[hk] or 0) + 1
                            end
                        end
                    end
                end
            end
            local own = depth(fn)
            if own.visible and own.c >= 2 then
                findings[#findings + 1] = { kind = 'visible', fn = fn.id, file = fn.file,
                    line = (own.concat or own.alloc or own.loops[#own.loops]).line, depth = own.c,
                    outer = own.loops, concat = own.concat, alloc = own.alloc, unit = opts.unit }
            end
        end
    end
    local RANK = { ['hidden-shared'] = 1, hidden = 2, visible = 3, possible = 4 }
    table.sort(findings, function(a, b)
        if a.kind ~= b.kind then return RANK[a.kind] < RANK[b.kind] end
        if (a.accumulator ~= nil) ~= (b.accumulator ~= nil) then return a.accumulator ~= nil end
        if a.depth ~= b.depth then return a.depth > b.depth end
        local ha, hb = a.holes and #a.holes or 0, b.holes and #b.holes or 0
        if ha ~= hb then return ha < hb end
        if a.file ~= b.file then return a.file < b.file end
        return a.line < b.line
    end)
    -- THE WORK LIST THE UNKNOWNS MAKE: each hole, by how many `possible` findings it would decide
    local worklist = {}
    for hk, nn in pairs(hole_count) do
        local name, class = hk:match('^(.-)%z(.*)$')
        worklist[#worklist + 1] = { name = name, class = class, findings = nn }
    end
    table.sort(worklist, function(a, b)
        if a.findings ~= b.findings then return a.findings > b.findings end
        return a.name < b.name
    end)
    -- depth_of(id): any function's { c, holes, loops, via } — for callers that price functions, not
    -- call sites (the name-word prior measurement, CART-1057)
    return { findings = findings, stats = stats, worklist = worklist,
        depth_of = function(id) local n = by_id[id]; return n and depth(n) or nil end }
end

--- a finding's chain, for display: the outer loops, then each callee (a node, a costed builtin, a
--- callback it invokes) and its loops; `>=` and the holes when the depth is not certified whole
local function builtin_text(rec)
    return ('-> %s[%s%s]%s'):format(rec.builtin,
        rec.cost == 'const' and 'const' or ((rec.log and 'n log n' or 'n') .. ' over ' .. (rec.argname or rec.size or '?')
            .. (rec.size == 'shared' and ' shared' or '') .. (rec.size == 'none' and ' (bounded)' or '')),
        rec.by_name and ', by name' or '', rec.pattern and (' pattern %q degree %d'):format(rec.pattern, rec.degree) or '')
end
function M.chain(f)
    local parts = {}
    local function loops_text(ls)
        for _, L in ipairs(ls or {}) do
            parts[#parts + 1] = ('loop@%d over {%s}%s%s'):format(L.line, table.concat(L.iterates, ','),
                L.shared and (' shared:' .. table.concat(L.shared, ',')) or '',
                L.const_by_name and (' (+const by name: ' .. table.concat(L.const_by_name, ',') .. ')') or '')
        end
    end
    local function concat_text(A)
        if A then
            parts[#parts + 1] = ('concat@%d grows %s [size n^%d%s]'):format(A.line, A.target, A.level,
                A.shared and ', shared' or (A.param and ', from a param' or ''))
        end
    end
    local function alloc_text(A)
        if A then parts[#parts + 1] = ('alloc@%d %s'):format(A.line, A.what) end
    end
    loops_text(f.outer)
    concat_text(f.concat)
    alloc_text(f.alloc)
    local rec, callee, how = f.inner, f.callee, f.how
    local guard = 0
    while rec and guard < 32 do
        guard = guard + 1
        if rec.builtin then
            parts[#parts + 1] = builtin_text(rec)
            rec = rec.fvia
            if rec then parts[#parts + 1] = '(calls its function argument)' end
        else
            if callee then parts[#parts + 1] = ('-> %s%s'):format(callee, how == 'lexical' and ' (lexical)' or '') end
            loops_text(rec.loops)
            concat_text(rec.concat)
            alloc_text(rec.alloc)
            local v = rec.via
            if not v then break end
            if v.node then callee, how, rec = v.node.id, v.how, v.sub
            elseif v.builtin then callee, rec = nil, v
            else break end
        end
    end
    if f.holes and #f.holes > 0 then
        local hs = {}
        for _, h in ipairs(f.holes) do hs[#hs + 1] = ('%s [%s]'):format(h.name, h.class) end
        parts[#parts + 1] = ('  >= holes: %s%s'):format(table.concat(hs, ', '), f.holes.more and (' +' .. f.holes.more) or '')
    end
    return table.concat(parts, '  ')
end

--- THE UPPER BOUND a finding's holes allow: a `backtrack` hole is a BOUNDED unknown (its pattern's
--- degree, an upper bound itself), every other class is unbounded. Holes on one chain and on tied
--- chains are merged into one set, so the extras are SUMMED — a safe over-estimate, never an under one.
--- @return number  certified depth + sum(degree - 1) over backtrack holes, or math.huge
function M.upper(f)
    local u = f.depth
    for _, h in ipairs(f.holes or {}) do
        if h.class == 'backtrack' and h.degree then u = u + h.degree - 1 else return math.huge end
    end
    if f.holes and f.holes.more then return math.huge end
    return u
end

--- `depth 2`, `depth 2..4` (only bounded holes) or `depth >=1` (an unbounded one)
function M.depth_text(f)
    if not (f.holes and #f.holes > 0) then return tostring(f.depth) end
    local u = M.upper(f)
    if u == math.huge then return '>=' .. f.depth end
    return f.depth .. '..' .. u
end

--- The cockpit view for ONE function (:CartographLoopCost): the callers that run it inside an
--- input-sized loop, and the callees it runs inside its own. Analyses the function's file and its
--- callers' files only, so it answers in a big tree without the whole-repo pass (tools/perfscan.lua).
function M.report(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return { 'loopcost: no such node' } end
    local data = store.data or {}
    local fileset = { [node.file] = true }
    for _, c in ipairs(data.calls or {}) do
        if c.file and (c.to == fn_id or c.callee == (node.name or ''):match('([%w_]+)$')) then fileset[c.file] = true end
    end
    local R = M.analyze(store, data, { fileset = fileset })
    local function passes(f)
        if f.callee == fn_id then return true end
        local sub = f.inner
        while sub and sub.via do
            local v = sub.via
            if not v.node then return false end
            if v.node.id == fn_id then return true end
            sub = v.sub
        end
        return false
    end
    local out = { ('loopcost — %s   (a SHAPE, not a cost: CART-1057)'):format(node.name or fn_id), '' }
    local by_callers, own = {}, {}
    for rank, f in ipairs(R.findings) do
        if f.fn == fn_id then own[#own + 1] = { rank, f } elseif passes(f) then by_callers[#by_callers + 1] = { rank, f } end
    end
    local function line_of(rank, f)
        return ('  %s:%d  #%d %s depth %s%s  %s'):format(f.file, f.line, rank, f.kind, M.depth_text(f),
            f.accumulator and (' (outer accumulates ' .. f.accumulator .. ')') or '', M.chain(f))
    end
    out[#out + 1] = ('CALLED INSIDE INPUT-SIZED LOOPS (%d): the callers that multiply it'):format(#by_callers)
    for _, x in ipairs(by_callers) do out[#out + 1] = line_of(x[1], x[2]) end
    out[#out + 1] = ''
    out[#out + 1] = ('ITS OWN NESTING (%d): the loops it runs around its callees, or inside itself'):format(#own)
    for _, x in ipairs(own) do out[#out + 1] = line_of(x[1], x[2]) end
    out[#out + 1] = ''
    out[#out + 1] = ('scope: %d function(s) in %d file(s); ranks are within that scope. kinds: hidden-shared > hidden > visible > possible (>= : holes).')
        :format(R.stats.fns, vim.tbl_count(fileset))
    return out
end

return M
