-- The STATE ATLAS: every module var classified by its use-edge facts —
-- the write axis (rw), guard summaries (gw) and param predicates (gp)
-- composed into a state-discipline map ([[cartograph-write-axis]]):
--
--   const          no function writes it (init-time writes are not use
--                  edges, so 'const' means constant AFTER load)
--   dead           written, never read — dead state (or dynamic access
--                  the graph can't see: the ~ hedge, always spoken)
--   set-once       every write edge is all-set-once (gw=3): init-shaped
--                  state, writes COMMUTE
--   single-writer  one owning fn writes, others only read — an ownership
--                  invariant worth knowing when it breaks
--   multi-writer   contended state: the reorder/race attention list
--   unclassified   some use edge carries no rw (a language without the
--                  write classifier) — unknown, never guessed
--
-- Pure consumer: no extraction change, every fact already in the graph.

-- @langs lua php javascript python typescript tsx
-- NOT a lua module despite the neighbours: `field_of` reads php's `variable_name`
-- wrapper and pairs `dot_index_expression`/`member_access_expression` and
-- `bracket_index_expression`/`subscript_expression` as or-groups — it was written
-- polyglot and nothing said so (the spec/javascript.lua precedent, CART-0304).
local M = {}

M.LABELS = { 'const', 'dead', 'set-once', 'single-writer', 'multi-writer',
    'unclassified' }

--- Classify one var by its use edges. Returns
--- { label, nr, nw, writers = {fn ids}, gw = min guard tier of writes }.
function M.classify(store, id)
    local nr, nw, unk, gwmin = 0, 0, false, nil
    local writers = {}
    for _, u in ipairs(store.topo():var_used_by_detail(id)) do
        local rw = u.rw
        if not rw then
            unk = true
        else
            if rw == 1 or rw == 3 then nr = nr + 1 end
            if rw >= 2 then
                nw = nw + 1
                writers[nw] = u.from
                local g = u.gw or 1
                if not gwmin or g < gwmin then gwmin = g end
            end
        end
    end
    local label
    if unk then label = 'unclassified'
    elseif nw == 0 then label = 'const'
    elseif nr == 0 then label = 'dead'
    elseif gwmin == 3 then label = 'set-once'
    elseif nw == 1 then label = 'single-writer'
    else label = 'multi-writer' end
    return { label = label, nr = nr, nw = nw, writers = writers, gw = gwmin }
end

-- ── the FIELD atlas: one var, decomposed per field, on demand ────────────
-- Fields are not nodes — the edge facts aggregate over them (`state` is
-- multi-writer even when x has one owner and y is set-once). This
-- re-parses the var's consumer files (the detail.lua pattern) and reruns
-- the SAME write/guard classifiers on the live nodes, grouped by the
-- occurrence's immediate field. Whole-var accesses (`f(state)`,
-- `pairs(state)`, rebinds) land in the '(whole)' bucket; a whole-var
-- WRITE hedges every field claim (it could have written anything).

local function ext_spec(file)
    local ts = require 'cartograph.providers.treesitter'
    local ext = file:match('%.([%w_]+)$')
    if not ext then return nil end
    for lang, spec in pairs(ts.spec) do
        for _, e in ipairs(spec.exts or {}) do
            if e == ext then return lang, spec end
        end
    end
end

-- the immediate field of a base-var occurrence, or nil for a whole-var use
local function field_of(c, src)
    local p = c:parent()
    -- @langs-ok php's `$x` wrapper; a no-op peel on every other declared grammar
    if p and p:type() == 'variable_name' then c = p; p = p:parent() end -- php $x
    if not p then return nil end
    local t = p:type()
    if t == 'dot_index_expression' or t == 'member_access_expression' then
        if p:named_child(0) ~= c then return nil end
        local f = p:named_child(1)
        return f and vim.treesitter.get_node_text(f, src) or '[]'
    end
    if t == 'bracket_index_expression' or t == 'subscript_expression' then
        if p:named_child(0) ~= c then return nil end
        local k = p:named_child(1)
        if k and k:type() == 'string' then
            local inner = k:named_child(0)
            if inner then return vim.treesitter.get_node_text(inner, src) end
        end
        return '[]' -- computed key: one bucket, honestly coarse
    end
    return nil
end

--- Per-field classification of one var. `cache` (optional) shares parsed
--- trees across calls (the census sweep). Returns nil, why on refusal.
--- { fields = { name -> {label, nr, nw, writers={set}, hedged} },
---   whole = { nr, nw }, files = n }
function M.fields(store, id, cache)
    local ts = require 'cartograph.providers.treesitter'
    local atr = require 'cartograph.at'
    local uses = store.topo():var_used_by_detail(id)
    if #uses == 0 then return nil, 'no uses' end
    cache = cache or {}
    local fields, whole = {}, { nr = 0, nw = 0 }
    for _, u in ipairs(uses) do
        local fn = store.node(u.from)
        local file = fn and fn.file
        if file then
            local entry = cache[file]
            if entry == nil then
                local lang, spec = ext_spec(file)
                if lang and spec and spec.is_write then
                    local fd = io.open(store.abs(file), 'r')
                    if fd then
                        local src = fd:read('*a')
                        fd:close()
                        local okp, parser =
                            pcall(vim.treesitter.get_string_parser, src, lang)
                        if okp and parser then
                            local okt, tree = pcall(function ()
                                return parser:parse()[1]
                            end)
                            if okt and tree then
                                entry = { root = tree:root(), src = src, spec = spec }
                            end
                        end
                    end
                end
                entry = entry or false
                cache[file] = entry
            end
            if entry then
                local root, src, spec = entry.root, entry.src, entry.spec
                for _, r in ipairs(u.at or {}) do
                    local sl, sc = atr.sl(r), atr.sc(r)
                    local c = root:named_descendant_for_range(sl, sc, sl, sc + 1)
                    if c then
                        local f = field_of(c, src)
                        local n = c:parent()
                        local w = n and spec.is_write(c, n)
                        if not f then
                            if w then whole.nw = whole.nw + 1
                            else whole.nr = whole.nr + 1 end
                        else
                            local rec = fields[f]
                            if not rec then
                                rec = { nr = 0, nw = 0, writers = {}, gw = nil }
                                fields[f] = rec
                            end
                            if w then
                                rec.nw = rec.nw + 1
                                rec.writers[u.from] = true
                                local g = spec.guards
                                    and ts.guard_class(c, n, src, spec.guards) + 1
                                    or 1
                                if not rec.gw or g < rec.gw then rec.gw = g end
                            else
                                rec.nr = rec.nr + 1
                            end
                        end
                    end
                end
            end
        end
    end
    local nfiles = 0
    for _, e in pairs(cache) do if e then nfiles = nfiles + 1 end end
    for _, rec in pairs(fields) do
        local nwriters = 0
        for _ in pairs(rec.writers) do nwriters = nwriters + 1 end
        if rec.nw == 0 then rec.label = rec.nr > 0 and 'const' or 'const'
        elseif rec.nr == 0 then rec.label = 'dead'
        elseif rec.gw == 3 then rec.label = 'set-once'
        elseif nwriters == 1 then rec.label = 'single-writer'
        else rec.label = 'multi-writer' end
        rec.nwriters = nwriters
        -- a whole-var write could touch ANY field: every claim hedged
        if whole.nw > 0 then rec.hedged = true end
    end
    return { fields = fields, whole = whole, files = nfiles }
end

--- The whole graph's census: counts per label + the var lists.
--- Synthetic/browse-only vars (sql entities, C interface types) excluded,
--- mirroring the resolver's own var vocabulary.
function M.census(store)
    local counts, vars = {}, {}
    for _, l in ipairs(M.LABELS) do counts[l] = 0; vars[l] = {} end
    local total = 0
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'var' and not n.sql and not n.ctype
            and n.id:sub(1, 5) ~= 'sql::' then
            total = total + 1
            local c = M.classify(store, n.id)
            counts[c.label] = counts[c.label] + 1
            table.insert(vars[c.label], { id = n.id, name = n.name,
                file = n.file, nr = c.nr, nw = c.nw })
        end
    end
    return { total = total, counts = counts, vars = vars }
end

return M
