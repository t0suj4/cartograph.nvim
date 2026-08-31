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

local atr = require 'cartograph.at'

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
--- LANGUAGE COVERAGE IS A PER-LANGUAGE DECLARATION, and this surface only sees what
--- the expr layer models as FIELD ACCESS. Measured, and it moved: lua and js always;
--- php, python and go once their node names were entered (CART-0224 — grocy 54 -> 151
--- names, python 0 -> 154, go 38 -> 3363). JAVA NO: its `field_access` /
--- `method_invocation` are still unmapped, and adding them is a project rather than a
--- word, because CALL decides is_pure / allocates and optimize APPLIES rewrites.
--- RUBY IS THE CASE TO KNOW ABOUT: it has FLOW (2104 of 2303 functions carry a record)
--- but NO EXPRESSION IR, so this surface can examine none of it. That is now REPORTED
--- as unmodelled rather than returned as zero — `analysed` / `unmodelled` /
--- `unmodelled_langs` below exist so a caller can tell an EMPTY answer from an ABSENT
--- one, and portability's read section says which it is.
--- LOOP BINDINGS are locals, and now known to be: the language specs declare their
--- BINDER NODES and expr.of reports the bound names from the same parse it already
--- performs. Before that they were in neither df's `def` nor the IR's binder position,
--- so a loop-bound receiver looked like an unknown global
--- (`crashSiteGenerator.energy` did) and the surface had to withhold every root seen
--- in only ONE function to compensate. That heuristic is gone: precision came from
--- declaring the grammar rather than from guessing at spread.
--- `withheld` is kept at 0 for callers that report it — a language with no declared
--- binders simply contributes no bound names, which shows up as reads to adjudicate
--- rather than as silence.
--- A DEFINITION SILENCES A READ ONLY IN THE FILE THAT MAKES IT (CART-0649). The
--- project-def filter used to be PROJECT-WIDE and unscoped — every def name in the
--- graph, from any file, reachable or not, locals included — so ONE binding anywhere
--- deleted every read of that name everywhere, with no row, no hedge and no count.
--- Measured victims, all in the Factorio 1.1 corpus:
---   railloader   `global = {}` on line 7 of spec/EntityQueue_spec.lua — a file the
---                port report ITSELF calls "reached by NO entry point" — took the
---                reads diff from 8 LOST to 1. The missing 7 were the `global` ->
---                `storage` rename, the single largest item of a 1.1 -> 2.0 port.
---   Von Neumann  `local script = require('k-lib')()` in ONE scenario file silenced
---                all 41 `script.*` reads in the other 33.
--- So: a def in THIS file still silences (`local script` genuinely rebinds the name
--- for the file that wrote it, and cage.lua's own reads do go through the wrapper); a
--- def in ANOTHER file no longer silences, it MARKS — the read is reported with the
--- files that also bind its root, and the caller decides how loudly to hedge.
--- ⚠ SILENCE IS THE ONE ANSWER THAT CANNOT BE CHECKED, which is why the direction of
--- this fix is "keep and mark" rather than a cleverer suppression rule.
---
--- ⚠ AND A PROFILE-MINTED NODE IS NOT A PROJECT DEFINITION. External nodes carry the
--- PROFILE NAME where a file goes (`file = 'lua-factorio'`, `name = 'LuaBootstrap::
--- on_event'`), and the bare-name key took `log`, `on_event`, `add_interface` out of
--- that. The environment's own provided names were silencing reads of themselves.
---
--- ⚠ WHAT THIS DOES NOT FIX, and it needs the extractor: a bare `global = global or {}`
--- at file scope — the standard init idiom, live in SpaceMod 1.1.3's control.lua — is
--- an assignment to the ENVIRONMENT's global, not a new binding, yet a var node records
--- no binding FORM so it is indistinguishable from `local global = …`. spec/lua.lua's
--- `vars` query already separates the two patterns (`variable_declaration` vs a bare
--- `chunk` assignment); recording which one matched is CART-0500's item and would make
--- the same-file case answerable too.
---
--- RECEIVER-ROOTED READS ARE COLLECTED, NOT DISCARDED (CART-0650). A chain rooted at
--- a local, a parameter or a loop variable is excluded from `names` on purpose — it is
--- evidence about a receiver, not about the environment's globals — but its MEMBER is
--- still adjudicable, so it lands in `receiver_reads` for a caller that has a class
--- space to ask. Two surfaces out of one pass; the loop already had both in hand and
--- threw one away.
---
--- Returns { names = {name -> n}, where = {name -> file}, files = {name -> sorted
--- list of files}, shadowed = {name -> sorted list of OTHER files binding its root},
--- receiver_reads = {chain -> n}, receiver_files = {chain -> sorted list of files},
--- total, withheld }.
---
--- `where` IS A SAMPLE, `files` IS THE POPULATION. `where` keeps the first file a name
--- was seen in (node order) so existing callers do not move, but every question about
--- WHICH ENVIRONMENT a name belongs to has to ask `files`: a name read in two files
--- has no single home, and answering from `where` makes the verdict depend on which
--- file happened to be visited first (CART-0215).
--- THE SOURCE SPAN OF A ROW'S EXPRESSIONS, as one key (CART-0641). nil when the row
--- has no ranged expression, in which case it is never deduped — silence is better
--- than collapsing two rows we cannot tell apart.
local function row_span_key(r)
    local e = r.expr or {}
    local parts = nil
    for _, side in ipairs({ e.rhs or {}, e.lhs or {} }) do
        for _, x in ipairs(side) do
            if not x.at then return nil end
            parts = parts or {}
            parts[#parts + 1] = ('%d.%d-%d.%d'):format(atr.sl(x.at), atr.sc(x.at),
                atr.el(x.at), atr.ec(x.at))
        end
    end
    return parts and table.concat(parts, '|') or nil
end

function M.references(store)
    local expr = require 'cartograph.expr'
    local tsl = function (f)
        local ok, ts = pcall(require, 'cartograph.providers.treesitter')
        return ok and ts.lang_of and ts.lang_of(f) or nil
    end
    local out = { names = {}, where = {}, files = {}, total = 0, withheld = 0,
        -- HOW MANY FUNCTIONS THIS COULD NOT LOOK AT, and in which languages
        -- (CART-0224 step 2). expr.of returns nil for a language the expression
        -- layer does not model, and skipping those silently made `total = 0`
        -- indistinguishable from "this corpus reads nothing external". Measured on a
        -- ruby corpus: 2303 functions, 2104 WITH flow records, and 0 yielding an
        -- expression record — so the read surface reported nothing and the portability
        -- report simply omitted its section. A caller must be able to tell an EMPTY
        -- answer from an ABSENT one.
        analysed = 0, unmodelled = 0, unmodelled_langs = {}, shadowed = {},
        receiver_reads = {}, receiver_files = {} }
    local fileset, shadowset, rfileset = {}, {}, {}
    local data = store.data or {}
    -- names this graph DEFINES, AND IN WHICH FILE. Bare def names, since a read's
    -- root is a bare name. Per-file rather than per-project: see the note above — the
    -- unscoped version silenced 41 reads in one mod and 18 in another, invisibly.
    -- `kind == 'external'` is skipped: those are PROFILE-MINTED and their `file` is the
    -- profile's name, so counting them made the environment silence reads of itself.
    local defined_in = {}
    for _, n in ipairs(data.nodes or {}) do
        if n.name and n.kind ~= 'external' then
            local bare = n.name:match('([%w_]+)$') or n.name
            local where = defined_in[bare]
            if not where then where = {}; defined_in[bare] = where end
            if n.file then where[n.file] = true end
        end
    end
    for _, n in ipairs(data.nodes or {}) do
        if n.kind == 'function' or n.kind == 'method' then
            local ok, eo = pcall(expr.of, store, n.id)
            local fl = ok and eo and eo.fl
            if not fl then
                -- not modelled (or unreadable): COUNT it, with the language, so the
                -- caller can say WHY it has nothing rather than implying there is
                -- nothing to say
                out.unmodelled = out.unmodelled + 1
                local lang = n.file and tsl(n.file)
                if lang then
                    out.unmodelled_langs[lang] = (out.unmodelled_langs[lang] or 0) + 1
                end
            else
                out.analysed = out.analysed + 1
            end
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
                -- and the BINDER-declared names (loop variables), which df never
                -- records as definitions
                for bn in pairs(eo.bound or {}) do locals[bn] = true end
                -- ⚠ A LOOP HEADER IS TWO ROWS, AND BOTH ARE CORRECT (CART-0641).
                -- `for k, v in pairs(t) do` emits a PRE-LOOP init row (flow.lua:1090
                -- — the init runs before the head, and df needs that ordering) AND the
                -- `for_statement` control row that CFG needs. Both carry the same
                -- expression, because the header IS the init. Nothing is wrong with
                -- either row: a set-based consumer like reaching-definitions is
                -- idempotent over the repeat. An OCCURRENCE COUNTER is not, and this
                -- is one — `global.playersNeedZoom` reported 7 reads against 6.
                --
                -- Keyed on the FULL RANGE of both expression lists, start and end,
                -- line and char. ⚠ A COARSER KEY IS WRONG AND MEASURABLY SO: keying
                -- on (start line, row line) reported 25.3% of rows as duplicates on
                -- cartograph, with an `if_statement + stmt` and a `stmt + stmt`
                -- bucket that are pure artifacts of two statements sharing a line.
                -- The full range gives 8.1%, ALL of it `for_statement + stmt`.
                -- ★ LHS IS IN THE KEY TOO, so two rows that share an rhs but assign
                -- to different targets are not collapsed — the pair this exists for
                -- has no lhs at all.
                local rowseen = {}
                for _, r in ipairs(fl.stmts or {}) do
                    local rk = row_span_key(r)
                    if rk and rowseen[rk] then goto next_row end
                    if rk then rowseen[rk] = true end
                    local got = {}
                    for _, e in ipairs((r.expr or {}).rhs or {}) do expr.dotted_reads(e, got) end
                    for _, e in ipairs((r.expr or {}).lhs or {}) do expr.dotted_reads(e, got) end
                    -- ⚠ `cond` IS NOT WALKED, AND THAT IS NOT AN OVERSIGHT (CART-0634).
                    -- A row that has a condition ALSO carries that condition in `rhs`,
                    -- so reading both counted every read inside an `if` TWICE. It
                    -- showed up as a port worklist that did not reconcile with the
                    -- files: `global.donecrashsite` reported 3 reads against 2 in the
                    -- source, and every one of the seven `global.*` names was over by
                    -- exactly its number of conditions.
                    --
                    -- MEASURED before removing it, as a MULTISET and not a set — the
                    -- claim is about the COUNT, so a chain appearing twice in `cond`
                    -- and once in `rhs` had to be able to fail the test: 9637 rows
                    -- with a condition on cartograph itself and 89 on Von-Neumann,
                    -- ZERO with a read `rhs` lacks. If that ever stops holding, this
                    -- undercounts — and the check is one probe, not a guess.
                    --
                    -- ⚠ AND PER-ROW DEDUPE WOULD HAVE BEEN WRONG. The obvious fix —
                    -- collapse repeats within a row — breaks `global.x = global.x or
                    -- {}`, which is TWO real occurrences on one line and is why
                    -- `global.savedRailbots` (11 reads, 7 lines) was one of the two
                    -- names that already reconciled.
                    for _, chain in ipairs(got) do
                        local rootname = chain:match('^([%w_]+)')
                        local binds = rootname and defined_in[rootname]
                        -- THIS file's own binding still wins; another file's does not
                        if rootname and locals[rootname] then
                            -- ★ RECEIVER-ROOTED, AND NOT THEREFORE UNINTERESTING
                            -- (CART-0650). A chain rooted at a local, a parameter or a
                            -- loop variable says nothing about which GLOBALS the
                            -- environment holds — which is why it is excluded above —
                            -- but its MEMBER is still a name the target's class space
                            -- can rule on, and that test needs no receiver at all.
                            -- railloader reads `e.circuit_connection_definitions` at
                            -- three sites; it was on LuaEntity in 1.1 and is on no 2.0
                            -- class, and the name appeared NOWHERE in the port report:
                            -- the reads diff drops receiver-rooted chains and the
                            -- class-space audit only ever consumed calls.
                            out.receiver_reads[chain] = (out.receiver_reads[chain] or 0) + 1
                            if n.file then
                                local rf = rfileset[chain]
                                if not rf then rf = {}; rfileset[chain] = rf end
                                rf[n.file] = true
                            end
                        elseif rootname
                            and not (binds and n.file and binds[n.file]) then
                            out.names[chain] = (out.names[chain] or 0) + 1
                            out.where[chain] = out.where[chain] or n.file
                            if binds then
                                local sh = shadowset[chain]
                                if not sh then sh = {}; shadowset[chain] = sh end
                                for f in pairs(binds) do
                                    if f ~= n.file then sh[f] = true end
                                end
                            end
                            if n.file then
                                local fs = fileset[chain]
                                if not fs then fs = {}; fileset[chain] = fs end
                                fs[n.file] = true
                            end
                        end
                    end
                    ::next_row::
                end
            end
        end
    end
    for _ in pairs(out.names) do out.total = out.total + 1 end
    -- sets -> sorted lists, so iteration order is deterministic for both reports and
    -- gates (the set is built in node order, which is not)
    for chain, fs in pairs(fileset) do
        local l = {}
        for f in pairs(fs) do l[#l + 1] = f end
        table.sort(l)
        out.files[chain] = l
    end
    for chain, sh in pairs(shadowset) do
        local l = {}
        for f in pairs(sh) do l[#l + 1] = f end
        if #l > 0 then table.sort(l); out.shadowed[chain] = l end
    end
    for chain, rf in pairs(rfileset) do
        local l = {}
        for f in pairs(rf) do l[#l + 1] = f end
        table.sort(l)
        out.receiver_files[chain] = l
    end
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
