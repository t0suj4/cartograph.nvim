-- fieldlink.lua — the FIELD/MEMBER linker ([[cartograph-linker]] Track 3), the
-- data-member analog of self:method receiver typing. A `self.field` READ inside a
-- typed method of class C resolves to the `self.field = …` WRITE(s) on C (its own
-- methods + its extends ancestors) — go-to-definition for a field, luals-comparable.
--
-- SCOPE = RESOLUTION, not a lint. The undefined-member LINT is measured dead on Lua
-- (dynamic members / metatables → a writeless read is NOT a defect). So a read with
-- NO same-class write is left UNRESOLVED (never flagged). Resolution is sound where
-- a write exists AND self is genuinely typed to C: the V3 genuine-object gate (C owns
-- ≥2 colon-methods) types self=C by the OO contract. Set-valued on multiple writes
-- (the field's def is the join, like the linker's multi-definer globals). Analysis-
-- only — a per-fn lens over re-parsed content, no schema/fold change, no VERSION bump.

local at = require 'cartograph.at'

local M = {}

local FN_TYPES = { function_declaration = true, function_definition = true }
local function txt(n, src) return n and vim.treesitter.get_node_text(n, src) or '' end

-- store.content returns the WHOLE file, so we parse the file once (cached) and
-- LOCATE each method's fn node by its range — lines are then absolute (0-based ts
-- → +1). `cache` maps file → { root, src } across a single M.fields call.
local function file_parse(store, file, cache)
    local e = cache[file]
    if e ~= nil then return e end
    local node = { file = file } -- content() only needs .file
    local src = table.concat(store.content(node) or {}, '\n')
    local ok, p = pcall(vim.treesitter.get_string_parser, src, 'lua')
    e = ok and { root = p:parse()[1]:root(), src = src } or false
    cache[file] = e
    return e
end
local function fn_node_at(root, range)
    local d = root:named_descendant_for_range(at.sl(range), at.sc(range),
        at.el(range), at.ec(range))
    while d and not FN_TYPES[d:type()] do d = d:parent() end
    return d
end

-- `self.field = …` writes WITHIN a method's fn node → out[field] = { {line, method} }.
-- Absolute lines (the file-parse is whole-file). Nested closures capture the same self.
local function collect_writes(fn, src, method, file, out)
    if not fn then return end
    local function walk(n)
        if n:type() == 'assignment_statement' then
            for c in n:iter_children() do
                if c:type() == 'variable_list' then
                    for t in c:iter_children() do
                        if t:type() == 'dot_index_expression' then
                            local base, fld = t:named_child(0), t:field('field')[1]
                            if base and txt(base, src) == 'self' and fld then
                                local f = txt(fld, src)
                                out[f] = out[f] or {}
                                out[f][#out[f] + 1] = { line = t:start() + 1, method = method, file = file }
                            end
                        end
                    end
                end
            end
        end
        for c in n:iter_children() do
            if c:named() and (c == fn or not FN_TYPES[c:type()]) then walk(c) end
        end
    end
    for c in fn:iter_children() do if c:named() and not FN_TYPES[c:type()] then walk(c) end end
end

-- `self.field` READS within a method's fn node (not a write target) → { {field, line} }.
local function collect_reads(fn, src, out)
    if not fn then return end
    local function walk(n, inwrite)
        if n:type() == 'assignment_statement' then -- LHS targets are writes, RHS are reads
            local vl, el
            for c in n:iter_children() do
                if c:type() == 'variable_list' then vl = c
                elseif c:type() == 'expression_list' then el = c end
            end
            if vl then for t in vl:iter_children() do if t:named() then walk(t, true) end end end
            if el then for e in el:iter_children() do if e:named() then walk(e, false) end end end
            return
        end
        if n:type() == 'dot_index_expression' and not inwrite then
            local base, fld = n:named_child(0), n:field('field')[1]
            if base and txt(base, src) == 'self' and fld then
                local frow, fcol = fld:start() -- the field NAME position (0-based) for an oracle query
                out[#out + 1] = { field = txt(fld, src), line = n:start() + 1, row = frow, col = fcol }
            end
        end
        for c in n:iter_children() do
            if c:named() and not FN_TYPES[c:type()] then walk(c, inwrite) end
        end
    end
    for c in fn:iter_children() do if c:named() and not FN_TYPES[c:type()] then walk(c, false) end end
end

-- the class NAME that owns a colon-method node (`C:method` → C), else nil
local function owner_of(node)
    return node and node.name and node.name:match('^([%w_]+)[:.]')
end

-- the extends parents of C (single-parent map from data.extends), walked to collect
-- ancestors so a field written on a base class resolves from a subclass method.
local function ancestors(store, C)
    local chain, seen, cur = { C }, { [C] = true }, C
    local extends = store.data and store.data.extends
    for _ = 1, 16 do
        local par
        for _, e in ipairs(extends or {}) do
            if e.child == cur then if par and par ~= e.parent then par = nil; break end par = e.parent end
        end
        if not par or seen[par] then break end
        seen[par] = true; chain[#chain + 1] = par; cur = par
    end
    return chain
end

--- FIELD-LINK the focused method: resolve its `self.field` reads to the field's
--- write site(s) on its class (+ ancestors). SOUND-gated: fires only when the owner
--- class is a genuine object (≥2 colon-methods); a read with no same-class write is
--- left unresolved (NOT flagged — the dead undefined-member lint).
--- @return table { class, unsupported?, gated?, reads: { {line, field, defs: {{line,method}}} }, nresolved, nreads }
function M.fields(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return { reads = {} } end
    if not node.file:match('%.lua$') then
        return { lang = node.file:match('%.(%w+)$'), unsupported = true, reads = {} }
    end
    local C = owner_of(node)
    if not C then return { reads = {}, gated = 'not a method (no receiver class)' } end

    -- the class's methods (own + ancestors), and the genuine-object gate count
    local classes = {}
    for _, c in ipairs(ancestors(store, C)) do classes[c] = true end
    local methods, methodcount = {}, 0
    for _, n in ipairs(store.data.nodes or {}) do
        local o = owner_of(n)
        if o and classes[o] and (n.kind == 'method' or n.kind == 'function') then
            methods[#methods + 1] = n
            if o == C and n.name:match('^' .. C .. ':') then methodcount = methodcount + 1 end
        end
    end
    if methodcount < 2 then -- too weak a signal that self is really C (V3 gate)
        return { class = C, gated = 'owner owns <2 colon-methods (not a genuine object)', reads = {} }
    end

    -- WRITES: self.field = … across every method of C and its ancestors. Parse each
    -- file once (store.content is whole-file); locate each method by its range.
    local cache, writes = {}, {}
    for _, m in ipairs(methods) do
        local fp = m.range and file_parse(store, m.file, cache)
        if fp then collect_writes(fn_node_at(fp.root, m.range), fp.src, m.name, m.file, writes) end
    end
    -- READS: self.field in the focused method
    local reads = {}
    local fp = node.range and file_parse(store, node.file, cache)
    if fp then collect_reads(fn_node_at(fp.root, node.range), fp.src, reads) end

    local out, nres = {}, 0
    for _, r in ipairs(reads) do
        local defs = writes[r.field]
        if defs then
            nres = nres + 1
            out[#out + 1] = { line = r.line, field = r.field, defs = defs, row = r.row, col = r.col }
        end
    end
    table.sort(out, function (a, b) return a.line < b.line end)
    return { class = C, reads = out, nresolved = nres, nreads = #reads }
end

--- The lens surface (:CartographFields): where the focused method's self.field reads
--- are DEFINED (which method assigns them), receiver-typed. Set-valued when a field is
--- written in several places (the def is the join).
function M.report(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return { 'field-link: no such node' } end
    local res = M.fields(store, fn_id)
    if res.unsupported then
        return { ('field-link: %s not yet supported (Lua only)'):format(res.lang or '?') }
    end
    if res.gated then
        return { ('field-link: %s — %s'):format(node.name or fn_id, res.gated) }
    end
    if #res.reads == 0 then
        return { ('field-link: %s — no self.field reads resolve to a same-class write (of %d read(s))')
            :format(node.name or fn_id, res.nreads or 0) }
    end
    local L = { ('field-link: %s (class %s) — %d/%d self.field read(s) resolved to their def')
        :format(node.name or fn_id, res.class, res.nresolved, res.nreads), '' }
    for _, r in ipairs(res.reads) do
        local sites = {}
        for _, d in ipairs(r.defs) do sites[#sites + 1] = ('%s @L%d'):format(d.method, d.line) end
        table.sort(sites)
        L[#L + 1] = ('  L%-4d self.%-16s ←  %s'):format(r.line, r.field, table.concat(sites, ', '))
    end
    L[#L + 1] = ''
    L[#L + 1] = 'a read resolves to the self.field = … write(s) on the class (own methods +'
    L[#L + 1] = 'extends ancestors), self typed by the genuine-object contract. Set-valued on'
    L[#L + 1] = 'multiple writes; a writeless read is left unresolved (NOT flagged — sound-first).'
    return L
end

return M
