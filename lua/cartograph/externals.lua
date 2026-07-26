-- EXTERNAL-SURFACE READING — the boundary a scope reaches for but does NOT
-- define. Every eligible reference that resolves to nothing in the corpus is a
-- FACT, not noise ([[cartograph-linker]] "cannot-link IS a finding";
-- [[cartograph-cross-project]] boundary): an external module / global / API, or
-- an untyped receiver whose type lives outside the corpus. Read-only, honest `~`
-- — this reading makes NO resolution claim; it describes the hole.
--
-- SHAPE FROM USES: the members USED on an unresolved base are its inferred shape
-- (`node:type()` + `node:named_child()` ⇒ `node` has `{type, named_child}`).
-- This is backward inference — uses constrain the definition
-- ([[graph-vm-type-resolution]] bidirectional) — honest by construction (no
-- definition exists to forward-flow from, so usage is the only signal). It is
-- the seed for TWO things: the WRITE side (suggest a stub / `---@class` of the
-- shape the external must have) and the external API stubs receiver-typing
-- stalled on ([[cartograph-goal-vm-linker]] V4 / the blocked bucket).
--
-- The shape is read from `c.full` (already in the store — NO re-parse). Bases
-- are grouped by NAME; a `~` hypothesis (same-named locals of different types
-- aggregate — the reading says so). Recognized builtins/libraries are TAGGED
-- (expected externals, not boundary surprises), extend KNOWN per language.

local callrec = require 'cartograph.callrec'

local M = {}

-- recognized language builtins/libraries — a known external, not a boundary
-- unknown. MVP = Lua + nvim; extend per language as corpora demand.
local KNOWN = {
    -- lua builtins
    ipairs = true, pairs = true, next = true, type = true, tostring = true,
    tonumber = true, pcall = true, xpcall = true, error = true, assert = true,
    select = true, print = true, require = true, setmetatable = true,
    getmetatable = true, rawget = true, rawset = true, rawequal = true,
    rawlen = true, unpack = true, collectgarbage = true, load = true,
    loadstring = true, dofile = true, loadfile = true,
    -- lua libraries (base names)
    table = true, string = true, math = true, io = true, os = true,
    coroutine = true, debug = true, utf8 = true, package = true, bit = true,
    jit = true, ffi = true,
    -- nvim
    vim = true,
}

-- split a call's full chain into (base, member-chain): `node:type` → node,type;
-- `vim.fn.expand` → vim, fn.expand; a bare `require` → require, nil.
local function split(full)
    local base, member = full:match('^([%w_]+)[:%.](.+)$')
    if base then return base, member end
    return full, nil
end

--- Classify every call into the external surface.
--- Returns { total, resolved, internal_multi, cross_scope, stdlib_tail,
---   external, bases = { [base] = { calls, members = {m -> n}, files = set,
---   bare, known } } }.
function M.surface(store)
    local s = { total = 0, resolved = 0, internal_multi = 0, cross_scope = 0,
        stdlib_tail = 0, external = 0, unread = 0, bases = {} }
    for _, c in callrec.each(store.data) do
        s.total = s.total + 1
        if callrec.to(c) then
            s.resolved = s.resolved + 1
        elseif c.refused then
            local r = c.refused.rule
            if r == 'ambiguous' then s.internal_multi = s.internal_multi + 1
            elseif r == 'blocked' then s.cross_scope = s.cross_scope + 1
            elseif r == 'vocab' then s.stdlib_tail = s.stdlib_tail + 1 end
        elseif c.ext and c.ext.why == 'unread-file' then
            -- silent, but NOT the boundary: an import binds this receiver to a
            -- file we KNOW and never parsed (bundle / missing grammar /
            -- UNAVAILABLE read). Its own bucket, and deliberately NOT added to
            -- `bases`, so it reaches neither the external surface nor
            -- portability's requirement set — putting a name we have no evidence
            -- about into "candidate porting work" is exactly the overclaim the
            -- disposition exists to stop.
            s.unread = s.unread + 1
        else
            -- SILENT (c.to nil, c.refused nil) = external-unknown: the boundary.
            s.external = s.external + 1
            local base, member = split(callrec.full(c) or callrec.callee(c) or '?')
            local e = s.bases[base]
            if not e then
                e = { calls = 0, members = {}, files = {}, bare = 0,
                    known = KNOWN[base] or false }
                s.bases[base] = e
            end
            e.calls = e.calls + 1
            if member then e.members[member] = (e.members[member] or 0) + 1
            else e.bare = e.bare + 1 end
            if callrec.file(c) then e.files[callrec.file(c)] = true end
        end
    end
    return s
end

--- THE REFERENCE SURFACE: qualified READS of names this graph does not define.
--- A SECOND surface, deliberately not folded into surface() above.
---
--- WHY IT EXISTS: surface() is built from CALL records, so a name that is read but
--- never called is invisible to it — and that is exactly where two whole classes of
--- porting work live. Measured on the Von Neumann mod: `game.entity_prototypes[...]`
--- is an INDEX EXPRESSION (three occurrences) and `global.foo` is a FIELD ACCESS (30
--- of them), so neither produces a call record and neither could ever appear in a
--- call-derived requirement set. The attribute distillation made the artifact able to
--- adjudicate such names; this is what lets them be seen at all.
---
--- WHY IT IS SEPARATE: folding reads into surface() would move `bases`, and with it
--- every portability count on every corpus. Reads and calls are also different
--- evidence — a call names something invoked, a read names something touched — so a
--- report that merged them could not say which it meant. The caller decides.
---
--- COST, measured: ~3.5 ms per function, because expr.of re-parses the enclosing
--- function per node — 233 ms for a 34-file mod, 6.1 s for grocy (1697 fns), 35.6 s
--- for libs (10387 fns). Hence opt-in, and never part of surface().
---
--- LANGUAGE COVERAGE, measured rather than assumed: this finds what the expr layer
--- models as FIELD ACCESS. Lua, php and js yes (grocy: 54 names). JAVA NO — 51 of 60
--- sampled functions produced an IR and 156 rows carried expressions, yet 0 dotted
--- reads, because expr's FIELD table lists dot_index_expression / field_expression /
--- member_expression and Java's node is `field_access`. Adding it is one word, but it
--- changes the expression IR for every analyzer built on it (optimize's LICM/CSE,
--- narrow, untangle) on every Java corpus — its own change, with its own gate run.
--- KNOWN IMPRECISION, measured and guarded rather than hidden: LOOP BINDINGS are
--- not in the locals set. Neither df nor the expr IR marks them — `for _, gen in
--- pairs(list)` puts `gen` in `use` and never in `def`, and the expr layer models the
--- head as an opaque node whose bindings sit in a `variable_list` child. Identifying
--- them needs per-language BINDER NODE TYPES, which is spec territory, not something
--- to hand-roll here; until that exists a loop-bound receiver looks like an unknown
--- global (`crashSiteGenerator.energy` did).
--- So a root seen in only ONE function is WITHHELD and counted: a loop variable is
--- function-local by nature, while a real global is touched from several places. That
--- under-reports a global used exactly once — the safe direction, and the count says
--- how much was withheld rather than leaving it silent.
--- Returns { names = {name -> n}, where = {name -> file}, total, withheld }.
function M.references(store)
    local expr = require 'cartograph.expr'
    local out = { names = {}, where = {}, total = 0, withheld = 0 }
    -- collected first, filtered after: the withhold test is about a ROOT's spread
    -- across functions, which is not known until every function has been walked
    local cand, roots = {}, {}
    local data = store.data or {}
    -- names this graph DEFINES: a read rooted at one of them is internal, whatever
    -- else it is. Bare def names, since a read's root is a bare name.
    local defined = {}
    for _, n in ipairs(data.nodes or {}) do
        if n.name then defined[n.name:match('([%w_]+)$') or n.name] = true end
    end
    for _, n in ipairs(data.nodes or {}) do
        if n.kind == 'function' or n.kind == 'method' then
            local ok, eo = pcall(expr.of, store, n.id)
            local fl = ok and eo and eo.fl
            if fl then
                -- LOCAL ROOTS: parameters plus anything assigned in the body. A read
                -- rooted at one of these is a receiver whose type we do not know, not
                -- an external name — `p.mineable_properties` where p is a local says
                -- nothing about the environment.
                local locals = {}
                for _, pn in ipairs(fl.params or {}) do locals[pn] = true end
                for _, r in ipairs(fl.stmts or {}) do
                    for _, d in ipairs(r.def or {}) do locals[d] = true end
                end
                for _, r in ipairs(fl.stmts or {}) do
                    local got = {}
                    for _, e in ipairs((r.expr or {}).rhs or {}) do expr.dotted_reads(e, got) end
                    for _, e in ipairs((r.expr or {}).lhs or {}) do expr.dotted_reads(e, got) end
                    expr.dotted_reads((r.expr or {}).cond, got)
                    for _, chain in ipairs(got) do
                        local rootname = chain:match('^([%w_]+)')
                        if rootname and not locals[rootname] and not defined[rootname] then
                            local c = cand[chain]
                            if not c then c = { n = 0, fns = {}, file = n.file }
                                cand[chain] = c end
                            c.n = c.n + 1
                            c.fns[n.id] = true
                            roots[rootname] = roots[rootname] or {}
                            roots[rootname][n.id] = true
                        end
                    end
                end
            end
        end
    end
    for chain, c in pairs(cand) do
        local rootname = chain:match('^([%w_]+)')
        local spread = 0
        for _ in pairs(roots[rootname] or {}) do spread = spread + 1 end
        if spread >= 2 then
            out.names[chain] = c.n
            out.where[chain] = c.file
        else
            out.withheld = out.withheld + 1
        end
    end
    for _ in pairs(out.names) do out.total = out.total + 1 end
    return out
end

-- bases sorted UNKNOWN-first (the boundary surprises lead), then by call volume
local function ranked(bases)
    local out = {}
    for b, e in pairs(bases) do out[#out + 1] = { b = b, e = e } end
    table.sort(out, function (x, y)
        if x.e.known ~= y.e.known then return not x.e.known end -- unknown first
        if x.e.calls ~= y.e.calls then return x.e.calls > y.e.calls end
        return x.b < y.b
    end)
    return out
end

-- top-N used members of a base, as the inferred shape string
local function shape_of(e, cap)
    local mem = {}
    for m, cnt in pairs(e.members) do mem[#mem + 1] = { m = m, c = cnt } end
    table.sort(mem, function (x, y)
        if x.c ~= y.c then return x.c > y.c end
        return x.m < y.m
    end)
    if #mem == 0 then return e.bare > 0 and '(bare call)' or '' end
    local parts = {}
    for i = 1, math.min(cap, #mem) do parts[#parts + 1] = mem[i].m end
    return '{ ' .. table.concat(parts, ', ')
        .. (#mem > cap and (', +' .. (#mem - cap) .. ' more') or '') .. ' }'
end

--- Display lines for :CartographExternals.
function M.report(store, opts)
    opts = opts or {}
    local cap = opts.limit or 40
    local s = M.surface(store)
    local rk = ranked(s.bases)
    local nknown, nunk = 0, 0
    for _, r in ipairs(rk) do
        if r.e.known then nknown = nknown + 1 else nunk = nunk + 1 end
    end
    local lines = {
        ('external surface — %d calls: %d resolved · %d external(~) · %d internal-multi · %d cross-scope · %d stdlib-tail')
            :format(s.total, s.resolved, s.external, s.internal_multi,
                s.cross_scope, s.stdlib_tail),
        ('%d distinct external bases: %d recognized builtin/stdlib, %d UNKNOWN')
            :format(#rk, nknown, nunk),
        'the boundary — names used but defined nowhere here; each with its USED',
        'shape (inferred backward from usage, ~; bases grouped by NAME).',
        '',
    }
    local shown = 0
    for _, r in ipairs(rk) do
        if shown >= cap then
            lines[#lines + 1] = ('  … %d more external bases'):format(#rk - shown)
            break
        end
        shown = shown + 1
        local e = r.e
        local nf = 0; for _ in pairs(e.files) do nf = nf + 1 end
        lines[#lines + 1] = ('  %-8s %-22s ×%-6d %3df  %s'):format(
            e.known and 'stdlib' or '~extern', r.b, e.calls, nf, shape_of(e, 8))
    end
    return lines
end

return M
