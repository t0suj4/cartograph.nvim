-- The shape-consumer ROSTER: who consumes a value shape, and which field
-- paths do they touch. Born from the accessor-seam work (at/df/argv) being
-- done by hand — grep + judgment, four times over — because the graph's
-- edges (calls, name-based uses) are not field-sensitive and never follow
-- a VALUE. This module answers the one query that work needed:
--
--   producer (a call like store.occurrences(), or a field like `.at`)
--     -> every scope-local alias of its value (incl. for-in element
--        bindings over `ipairs(producer(...) or {})`)
--     -> every field-dereference PATH with sites (`start.line`, `end.char`)
--     -> honest FRONTIER rows where the value escapes local reasoning
--        (passed as argument, stored into a table, returned, written)
--
-- Honesty: name-matched (~) throughout. No interprocedural flow — an
-- escape is reported, never followed; absence of a deref row is NOT
-- proof of absence past a frontier row. Field producers match by name
-- alone (any `.at`), which over-approximates: the roster is a checklist
-- for a human-driven Encapsulate Field migration, not an oracle.
--
-- Lua-only v1 (the dogfood target is cartograph itself: the at display
-- seam). The walk is the provider's discipline in miniature: a lexical
-- scope stack, taints bound where values are born, uses classified where
-- names are read. The banked follow-up rides the graph-VM: provenance
-- threading through the CSR makes this interprocedural
-- ([[graph-vm-type-resolution]], [[cartograph-shape-roster]]).

local M = {}

-- taint kinds: 'list' = a list of shape records; 'elem' = one record;
-- 'any' = a field producer that is list-or-elem by record kind (e.g. .at
-- is one range on a call, a range LIST on an edge)

local IDX = { dot_index_expression = true, bracket_index_expression = true }

local function node_text(n, src) return vim.treesitter.get_node_text(n, src) end

-- last name segment of a call's callee: `store.occurrences` -> occurrences
local function callee_name(call, src)
    local name = call:field('name')[1] or call:named_child(0)
    if not name then return nil end
    local t = name:type()
    if t == 'identifier' then return node_text(name, src) end
    if t == 'dot_index_expression' or t == 'method_index_expression' then
        local f = name:named_child(name:named_child_count() - 1)
        return f and node_text(f, src)
    end
end

-- field segment of an index expression: `.start` -> start, `['end']` -> end,
-- computed subscript -> '[]'
local function index_segment(idx, src)
    local key = idx:named_child(1)
    if not key then return '[]' end
    if idx:type() == 'dot_index_expression' then return node_text(key, src) end
    if key:type() == 'string' then
        local c = key:named_child(0)
        return c and node_text(c, src) or '[]'
    end
    return '[]'
end

-- is this binary_expression an `or` (whose value IS one of its operands)?
local function is_or(bin, src)
    for i = 0, bin:child_count() - 1 do
        local ch = bin:child(i)
        if not ch:named() and node_text(ch, src) == 'or' then return true end
    end
    return false
end

local Scan = {}
Scan.__index = Scan

function Scan.new(src, file, spec)
    return setmetatable({
        src = src, file = file,
        calls = spec.calls or {},    -- callee name -> 'list'|'elem'
        fields = spec.fields or {},  -- field name  -> 'list'|'elem'|'any'
        rooted = spec.rooted or {},  -- 'base.seg' -> kind: ROOTED field producer
                                     -- (base text must match) — scopes the taint
                                     -- to the real list (`data.calls`), killing
                                     -- the bare-name over-approximation (`.calls`
                                     -- on an unrelated counter record)
        bless = spec.bless or {},    -- accessor names: passing there = SEAMED
        frames = {},                 -- lexical scope stack: {name -> taint|false}
        seeds = 0,
        derefs = {},                 -- { line, col, path, via }
        escapes = {},                -- { line, col, kind, via, detail }
        seamed = {},                 -- { line, col, via, detail } — already migrated
        helpers = {},                -- name -> { params = {…}, body } (same-file defs)
        props = {},                  -- interproc worklist: { name, idx, kind }
        deref_seen = {},             -- "line:col" dedup (a re-walked body re-visits)
    }, Scan)
end

-- kind of a field-producer index expr, honoring ROOTED specs (`base.seg`, the
-- base text must match) BEFORE the bare-name match (any `.seg`). Rooting is
-- what tells `data.calls` (a producer) from `counter.calls` (an unrelated field
-- of the same name) — the over-approximation the bare spec can't avoid.
function Scan:field_kind(idx, seg)
    if next(self.rooted) then
        local base = idx:named_child(0)
        if base then
            local rk = self.rooted[node_text(base, self.src):gsub('%s+', '') .. '.' .. seg]
            if rk then return rk end
        end
    end
    return self.fields[seg]
end

function Scan:lookup(name)
    for i = #self.frames, 1, -1 do
        local t = self.frames[i][name]
        if t ~= nil then return t or nil end -- false = shadow-killed
    end
end

function Scan:bind(name, taint)
    local f = self.frames[#self.frames]
    if f then f[name] = taint or false end
end

-- taint values: 'list' | 'elem' | 'any', or { k = kind, pre = 'start' } for
-- a SUB-shape binding (`local at = r.at.start` — reads of `at.line` then
-- report the full path `start.line`, and its escapes are 'derived', not
-- coverage stops: a value derived from the shape left, not the shape)
local function kindof(t) return type(t) == 'table' and t.k or t end
local function preof(t) return type(t) == 'table' and t.pre or nil end

-- taint of an expression, seeing through `(X)`, `X or {}` and `X and Y`
-- (`or` yields either operand; `and` yields its SECOND when it yields)
function Scan:taintof(expr)
    if not expr then return nil end
    local t = expr:type()
    if t == 'parenthesized_expression' then
        return self:taintof(expr:named_child(0))
    end
    if t == 'binary_expression' then
        if is_or(expr, self.src) then
            return self:taintof(expr:named_child(0))
                or self:taintof(expr:named_child(1))
        end
        for i = 0, expr:child_count() - 1 do -- `X and Y` -> Y
            local ch = expr:child(i)
            if not ch:named() and node_text(ch, self.src) == 'and' then
                return self:taintof(expr:named_child(1))
            end
        end
        return nil -- comparisons, arithmetic, concat: scalars
    end
    if t == 'identifier' then return self:lookup(node_text(expr, self.src)) end
    if t == 'function_call' then
        return self.calls[callee_name(expr, self.src)] -- seeds counted in walk()
    end
    if IDX[t] then
        local seg = index_segment(expr, self.src)
        local k = self:field_kind(expr, seg)
        if k then return k end
        local base = self:taintof(expr:named_child(0))
        local bk = kindof(base)
        -- a LISTMAP (`store.calls_to`, `calls_by_fn`: id -> a list of records)
        -- yields a LIST when indexed; the for-in over THAT gives the record
        if bk == 'listmap' and seg == '[]' then return 'list' end
        if (bk == 'list' or bk == 'any') and seg == '[]' then return 'elem' end
        if (bk == 'elem' or bk == 'any') and seg ~= '[]' then
            -- sub-shape / derived binding: carry the path prefix
            local pre = preof(base)
            return { k = 'elem', pre = pre and (pre .. '.' .. seg) or seg }
        end
    end
    return nil
end

local function line_col(n) local l, c = n:range(); return l + 1, c end

-- classify one read of a tainted value rooted at `node` (an identifier or
-- a producer expression). Climbs index chains for the deref path, then
-- names the context: deref | seamed | escape | benign.
function Scan:use(node, taint, via)
    local src = self.src
    local pre = preof(taint)
    -- climb the index chain while `node` sits in table position; keep the
    -- chain nodes so a rewriter can splice (chain extent + stem expression)
    local path, cur, chain = {}, node, { node }
    if pre then path[1] = pre end
    while true do
        local p = cur:parent()
        if p and IDX[p:type()] and p:named_child(0) == cur then
            path[#path + 1] = index_segment(p, src)
            cur = p
            chain[#chain + 1] = p
        else break end
    end
    local climbed = #path - (pre and 1 or 0) > 0
    local l, c = line_col(node)
    local p = cur:parent()
    local pt = p and p:type()
    -- see through parens and value-carrying `or`s: `#(X or {})` is a use of X
    while pt == 'parenthesized_expression'
        or (pt == 'binary_expression' and is_or(p, src)) do
        cur = p; p = cur:parent(); pt = p and p:type()
    end
    -- a write TO/THROUGH the shape (`e.at = x`, `r.start.line = x`): the
    -- producer side, not a consumer read
    if pt == 'variable_list' and p:parent()
        and p:parent():type() == 'assignment_statement' then
        self.escapes[#self.escapes + 1] = { line = l, col = c, kind = 'write',
            via = via, detail = table.concat(path, '.') }
        return
    end
    if climbed then
        local seenkey = l .. ':' .. c
        if self.deref_seen[seenkey] then return end -- re-walked body: one loc, one deref
        self.deref_seen[seenkey] = true
        local d = { line = l, col = c, path = table.concat(path, '.'), via = via }
        if pre then
            d.pre = true -- prefix taint: the chain is PARTIAL, never rewrite
        else
            -- rewrite payload: full-chain extent + the STEM the accessor takes
            -- (the expression before the last K path segments, for a K-segment
            -- accessor suffix). Two arities are rewritable and we emit both:
            --   1-seg — a RECORD FIELD accessor: `c.file` -> `cr.file(c)`
            --           (stem1 = `c`, the whole chain minus the last segment)
            --   2-seg — a SUB-PATH accessor: `r.start.line` -> `sl(r)`
            --           (stem2 = `r`, the chain minus the last two segments)
            local top = chain[#chain]
            d.ext = { top:range() }
            if #chain >= 2 then d.stem1 = node_text(chain[#chain - 1], src) end
            if #chain >= 3 then d.stem2 = node_text(chain[#chain - 2], src) end
        end
        self.derefs[#self.derefs + 1] = d
        return
    end
    -- from here down the SHAPE itself (or a derived sub-value) is in play;
    -- a derived value escaping is a rewrite site, not a coverage stop
    local esc = pre and 'derived' or nil
    if pt == 'unary_expression' and node_text(p, src):sub(1, 1) == '#' then
        self.derefs[#self.derefs + 1] = { line = l, col = c,
            path = pre and (pre .. '.#') or '#', via = via }
        return
    end
    if pt == 'arguments' then
        local callee = callee_name(p:parent(), src) or '?'
        if callee == 'ipairs' or callee == 'pairs' then return end -- loop seed, handled at the clause
        if self.bless[callee] then
            self.seamed[#self.seamed + 1] = { line = l, col = c,
                via = via, detail = callee .. '()' }
            return
        end
        -- INTERPROC 1-HOP: the WHOLE record (not a derived sub-value) passed to
        -- a resolvable same-file helper → FOLLOW it (taint that helper's matching
        -- param, resolve_params re-walks the body). Coverage no longer stops here.
        if not esc and self.helpers[callee] then
            local sl2, sc2 = cur:range()
            local idx = 0
            for ch in p:iter_children() do
                if ch:named() then
                    idx = idx + 1
                    local cl, cc = ch:range()
                    if cl == sl2 and cc == sc2 then break end
                end
            end
            self.props[#self.props + 1] = { name = callee, idx = idx, kind = kindof(taint) }
            return
        end
        self.escapes[#self.escapes + 1] = { line = l, col = c, kind = esc or 'arg',
            via = via, detail = callee .. '()' }
        return
    end
    if pt == 'field' then -- table_constructor field value: `{ range = r }`
        local key = p:named_child_count() > 1 and p:named_child(0)
        self.escapes[#self.escapes + 1] = { line = l, col = c, kind = esc or 'store',
            via = via, detail = key and node_text(key, src) or '[list item]' }
        return
    end
    if pt == 'return_statement' then
        self.escapes[#self.escapes + 1] = { line = l, col = c,
            kind = esc or 'return', via = via }
        return
    end
    if pt == 'expression_list' then
        local gp = p:parent()
        local gt = gp and gp:type()
        if gt == 'assignment_statement' then
            local wrap = gp:parent()
            if wrap and wrap:type() == 'variable_declaration' then return end -- alias: binding handles it
            -- bare assignment: `t[k] = r` stores; `x = r` re-points a name
            local lhs = gp:named_child(0)
            local target = lhs and lhs:named_child(0)
            if target and IDX[target:type()] then
                self.escapes[#self.escapes + 1] = { line = l, col = c, kind = esc or 'store',
                    via = via, detail = node_text(target, src):gsub('%s+', ' ') }
            end
            return -- plain-name assignment: binding pass covers the alias
        end
        if gt == 'return_statement' then
            self.escapes[#self.escapes + 1] = { line = l, col = c,
                kind = esc or 'return', via = via }
            return
        end
    end
    -- truthiness guards (`if r then`, `r and x or y`), comparisons: benign
    if pt == 'if_statement' or pt == 'elseif_statement' or pt == 'while_statement'
        or pt == 'repeat_statement' or pt == 'binary_expression'
        or pt == 'unary_expression' then return end
    self.escapes[#self.escapes + 1] = { line = l, col = c, kind = esc or 'other',
        via = via, detail = pt or '?' }
end

-- positional (name_i, expr_i) binding for declarations and assignments
function Scan:bind_pairs(vars, exprs)
    local names = {}
    for ch in vars:iter_children() do
        if ch:named() then names[#names + 1] = ch end
    end
    local vals = {}
    if exprs then
        for ch in exprs:iter_children() do
            if ch:named() then vals[#vals + 1] = ch end
        end
    end
    for i, nm in ipairs(names) do
        if nm:type() == 'identifier' then
            self:bind(node_text(nm, self.src), self:taintof(vals[i]))
        end
    end
end

-- for-in clause: `for _, r in ipairs(EXPR)` — element taint for var 2 when
-- EXPR is a tainted list/any; direct elem lists too (`for _, r in next, L`
-- is out of scope, reported by nothing: name-matched honesty)
function Scan:clause_bindings(clause)
    local out = {}
    local vars = clause:named_child(0)
    local exprs = clause:named_child(1)
    if not (vars and exprs) then return out end
    local it = exprs:named_child(0)
    if it and it:type() == 'function_call' then
        local cn = callee_name(it, self.src)
        if cn == 'ipairs' or cn == 'pairs' then
            local arg = it:field('arguments')[1]
            local t = kindof(self:taintof(arg and arg:named_child(0)))
            if t == 'list' or t == 'any' then
                local second = vars:named_child(1)
                if second then out[node_text(second, self.src)] = 'elem' end
            end
        end
    end
    return out
end

function Scan:walk(node, pending)
    local t = node:type()
    if t == 'block' or t == 'chunk' then
        self.frames[#self.frames + 1] = pending or {}
        for ch in node:iter_children() do
            if ch:named() then self:walk(ch) end
        end
        self.frames[#self.frames] = nil
        return
    end
    if t == 'variable_declaration' then
        local asg = node:named_child(0)
        if asg and asg:type() == 'assignment_statement' then
            local vars, exprs = asg:named_child(0), asg:named_child(1)
            if exprs then self:walk(exprs) end -- reads first (RHS sees old bindings)
            self:bind_pairs(vars, exprs)
        end
        return
    end
    if t == 'assignment_statement' then -- bare (non-local)
        local vars, exprs = node:named_child(0), node:named_child(1)
        if exprs then self:walk(exprs) end
        if vars then
            for ch in vars:iter_children() do
                -- index-expression target (`t[k] = r`): its base/subscript are reads
                if ch:named() and ch:type() ~= 'identifier' then self:walk(ch) end
            end
            self:bind_pairs(vars, exprs) -- plain-name targets: name-matched rebind
        end
        return
    end
    if t == 'for_statement' then
        local clause, body
        for ch in node:iter_children() do
            if ch:named() then
                local ct = ch:type()
                if ct == 'for_generic_clause' or ct == 'for_numeric_clause' then clause = ch
                elseif ct == 'block' then body = ch end
            end
        end
        local pend = {}
        if clause and clause:type() == 'for_generic_clause' then
            local exprs = clause:named_child(1)
            if exprs then self:walk(exprs) end -- the iterated expression is a read
            pend = self:clause_bindings(clause)
        elseif clause then
            self:walk(clause)
        end
        if body then self:walk(body, pend) end
        return
    end
    if t == 'function_declaration' or t == 'function_definition' then
        -- params shadow; body is a fresh frame (closures still see outer taints)
        local pend = {}
        local ps = node:field('parameters')[1]
        if ps then
            for ch in ps:iter_children() do
                if ch:named() and ch:type() == 'identifier' then
                    pend[node_text(ch, self.src)] = false
                end
            end
        end
        local body = node:field('body')[1]
        if body then self:walk(body, pend) end
        return
    end
    if t == 'identifier' then
        local p = node:parent()
        local pt = p and p:type()
        -- skip non-read positions: dot-field names, table-constructor keys
        if pt == 'dot_index_expression' and p:named_child(1) == node then return end
        if pt == 'method_index_expression' and p:named_child(1) == node then return end
        if pt == 'field' and p:named_child_count() > 1 and p:named_child(0) == node then return end
        local taint = self:lookup(node_text(node, self.src))
        if taint then self:use(node, taint, 'var:' .. node_text(node, self.src)) end
        return
    end
    if IDX[t] then
        -- a producer FIELD read in place: `u.at` / `c.at.start.line`
        local seg = index_segment(node, self.src)
        local k = self:field_kind(node, seg)
        if k then
            self.seeds = self.seeds + 1
            self:use(node, k, 'field:' .. seg)
        end
        self:walk(node:named_child(0)) -- the base is itself a read
        if t == 'bracket_index_expression' then -- computed subscript: reads too
            local sub = node:named_child(1)
            if sub then self:walk(sub) end
        end
        return
    end
    if t == 'function_call' then
        local cn = callee_name(node, self.src)
        if cn and self.calls[cn] then
            self.seeds = self.seeds + 1
            self:use(node, self.calls[cn], 'call:' .. cn)
        end
        local name = node:field('name')[1]
        -- method receiver is a read (`r:foo()`); plain-name callees are not shape reads
        if name and IDX[name:type()] then self:walk(name:named_child(0)) end
        local args = node:field('arguments')[1]
        if args then self:walk(args) end
        return
    end
    for ch in node:iter_children() do
        if ch:named() then self:walk(ch) end
    end
end

-- PRE-PASS: index same-file function definitions by name → { params, body },
-- so the interproc hop can resolve `f(c)` to f's body and taint param i. Keyed
-- by the callee's LAST segment (`M.f`/`T:m` → `f`), matching callee_name; a
-- name collision over-approximates (checklist honesty), same as the rest.
function Scan:collect_helpers(node)
    if node:type() == 'function_declaration' then
        local nm = node:field('name')[1]
        local key
        if nm then
            local nt = nm:type()
            if nt == 'identifier' then key = node_text(nm, self.src)
            elseif IDX[nt] or nt == 'method_index_expression' then
                local seg = nm:named_child(nm:named_child_count() - 1)
                key = seg and node_text(seg, self.src)
            end
        end
        local body = node:field('body')[1]
        if key and body and not self.helpers[key] then
            local params = {}
            local ps = node:field('parameters')[1]
            if ps then
                for ch in ps:iter_children() do
                    if ch:named() and ch:type() == 'identifier' then
                        params[#params + 1] = node_text(ch, self.src)
                    end
                end
            end
            self.helpers[key] = { params = params, body = body }
        end
    end
    for ch in node:iter_children() do
        if ch:named() then self:collect_helpers(ch) end
    end
end

-- FIXPOINT over the interproc worklist: for each (helper, param i, kind) the
-- walk recorded, re-walk the helper's body with param i tainted. New arg-hops
-- inside extend the worklist; `seen` dedups (recursion/cycles terminate).
function Scan:resolve_params()
    local seen, i = {}, 1
    while i <= #self.props do
        local p = self.props[i]; i = i + 1
        local key = p.name .. '|' .. p.idx .. '|' .. tostring(p.kind)
        if not seen[key] then
            seen[key] = true
            local h = self.helpers[p.name]
            local pname = h and h.params[p.idx]
            if pname and h.body then self:walk(h.body, { [pname] = p.kind }) end
        end
    end
end

--- Scan one Lua source string. spec = { calls = {occurrences='list'},
--- fields = {at='any'} }. Returns { seeds, derefs, escapes }.
function M.scan(src, file, spec)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
    if not ok or not parser then return nil, 'no lua parser' end
    local root = parser:parse()[1]:root()
    local s = Scan.new(src, file, spec)
    s:collect_helpers(root)   -- index helpers first (defs may follow call sites)
    s:walk(root)              -- main producer walk (records interproc worklist)
    s:resolve_params()        -- follow the worklist into helper bodies
    return { file = file, seeds = s.seeds, derefs = s.derefs,
        escapes = s.escapes, seamed = s.seamed }
end

--- Roster over files (rel paths under root). Aggregates a per-path census
--- plus the full frontier list — the Encapsulate Field checklist.
function M.roster(root, files, spec)
    local by_path, sites, frontier, seamed, nseeds = {}, {}, {}, {}, 0
    for _, f in ipairs(files) do
        local fd = io.open(root .. '/' .. f, 'r')
        if fd then
            local src = fd:read('*a'); fd:close()
            local r = M.scan(src, f, spec)
            if r then
                nseeds = nseeds + r.seeds
                for _, d in ipairs(r.derefs) do
                    by_path[d.path] = (by_path[d.path] or 0) + 1
                    sites[#sites + 1] = { file = f, line = d.line, col = d.col,
                        path = d.path, via = d.via,
                        ext = d.ext, stem1 = d.stem1, stem2 = d.stem2, pre = d.pre }
                end
                for _, e in ipairs(r.escapes) do
                    frontier[#frontier + 1] = { file = f, line = e.line, col = e.col,
                        kind = e.kind, via = e.via, detail = e.detail }
                end
                for _, e in ipairs(r.seamed) do
                    seamed[#seamed + 1] = { file = f, line = e.line, col = e.col,
                        via = e.via, detail = e.detail }
                end
            end
        end
    end
    return { seeds = nseeds, by_path = by_path, sites = sites,
        frontier = frontier, seamed = seamed }
end

-- ── the SEAM GUARD (record-fold arc step 2) ──────────────────────────────
-- REPRESENTATION OWNERS: files that save/load/merge/validate/intern the RAW
-- records (the producer side the fold swaps), so they read raw and are NOT
-- seam breaches. Shared by the guard and the CLI rewriter.
M.OWNERS = {
    '^lua/cartograph/providers/', 'store%.lua$', 'fold%.lua$', 'csr%.lua$',
    'argv%.lua$', 'detail%.lua$', 'at%.lua$', 'callrec%.lua$',
    'cache%.lua$', 'refresh%.lua$', 'parallel%.lua$', 'validate%.lua$',
    'refused%.lua$', 'consumers%.lua$',
}

-- the CALL-RECORD producer spec — every way a call record reaches a consumer
-- (kept here so a seam sweep and its guard agree on what to track).
M.CALL_PRODUCERS = {
    rooted = { ['data.calls'] = 'list', ['store.data.calls'] = 'list',
        ['store.calls_to'] = 'listmap' },
    calls = { sites = 'list' }, -- store.topo():sites(fn) yields a call list
}

-- SEAMED call fields: field -> accessor. A field here is CLOSED — its readers
-- all go through the accessor — so step 3 may fold it. The guard fails if a raw
-- read of one reappears in a non-owner file (the fence that keeps it closed).
M.SEAMED = { file = 'callrec.file', callee = 'callrec.callee' }

local function is_owner(f)
    for _, pat in ipairs(M.OWNERS) do if f:find(pat) then return true end end
    return false
end

-- Guard the seamed fields over `files` (rel paths under root). Returns the list
-- of BREACHES: raw derefs of a seamed field in a non-owner file. Empty = the
-- seam holds (every seamed field is fully behind its accessor → foldable). A
-- taint-based fence (not regex): only genuine call-record derefs count, so the
-- overloaded `c.file` on an unrelated record is not a false breach.
function M.guard(root, files)
    local spec = { rooted = M.CALL_PRODUCERS.rooted, calls = M.CALL_PRODUCERS.calls,
        bless = {} }
    for field in pairs(M.SEAMED) do spec.bless[field] = true end
    local r = M.roster(root, files, spec)
    local breaches = {}
    for _, s in ipairs(r.sites) do
        if M.SEAMED[s.path] and not is_owner(s.file) then
            breaches[#breaches + 1] = s
        end
    end
    return breaches
end

return M
