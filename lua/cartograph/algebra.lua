-- cartograph.algebra — THE SEAM ONTO THE PROVEN ALGEBRA (CART-0889).
--
-- USER (2026-09-13): "I want to absorb the algebra into cartograph."
--
-- ★★★ ABSORB MEANS GIVE IT A HOME, NOT MAKE A COPY. The algebra at
-- `~/tools/templates` is built and proven -- 6001 lines, 243 busted tests, a
-- four-arrow basis (term formers + `rebuild`, the position lens, `join`,
-- `unify`) from which 18 of 20 operators re-derive. Absorbing it is promoting
-- the DRIVER's load path (tools/algebradrive.lua, CART-0881) into the shipped
-- tree so analysis can ask it questions -- not vendoring its source.
--
-- ★★ WHY NOT VENDOR IT. A copy is a second authority that drifts, which is the
-- failure this whole arc exists to avoid (CART-0746: A COPIED WALKER IS A
-- COPIED BUG). The user has frozen the prototype for the duration of this work
-- ("I won't touch the prototype until we're done") -- that makes the bytes
-- stable WHILE WE BUILD, and says nothing about after. The freeze is a
-- convenience, never the licence to copy.
--
-- ★★ WHY NOT PORT THE ARROWS. `join` and `unify` operate on TERMS, and the
-- adapter below already reproduces the prototype pair-for-pair over real IR
-- (59/59, zero disagreements on kind, ctx count and hedge count). Porting them
-- onto the expr IR would re-open the twin-node and nil-slot questions of
-- CART-0882, which the adapter answers by construction: `expr.children` is the
-- position lens, and it is the one the shipped `walk` itself consumes.
--
-- ★★★ THE LOAD PATH IS A DECLARED SOURCE, NEVER THE ANALYSED TREE. `dofile`
-- EXECUTES what it loads, so the only acceptable origins are cartograph's own
-- config, an environment variable the user set, and a fixed default under
-- `$HOME`. A path read out of the corpus -- a manifest, a comment, a config
-- file in the repo being analysed -- must never reach here. That is the
-- standing invariant in its sharpest form: THE ANALYSED TREE CAN SELECT, IT
-- CANNOT SUPPLY. Same trust model as the clangd provider, which also runs an
-- external the user installed, and which health.lua reports the same way.
--
-- ★★ SPANS RIDE THROUGH FOR FREE, AND THAT IS A FACT ABOUT THEIR SOURCE.
-- `A.rebuild(t, kids)` carries "every field that is not the child list", and
-- `A.eq` compares only `k`, `v`, `n` and `kids`. So an `at` span attached to a
-- term SURVIVES every arrow and DISTURBS NO COMPARISON -- which is what would
-- let a result be mapped back to a buffer. ⚠ THE DAY SOMETHING TEACHES `eq` TO
-- COMPARE ANOTHER FIELD, SPANS STOP RIDING and every span-carrying result goes
-- quietly wrong. It is checked in their source, not assumed here.
--
-- ★★ AN ABSENT ALGEBRA IS A NAMED ANSWER, NOT A QUIET DEGRADE. Every consumer
-- must render `unavailable` as its own rung. Falling back to the heuristic
-- without saying so is absence-rendered-as-a-plausible-positive, the shape
-- shared by every guarantee-outside-the-code failure on record.
--
-- ⚠ A CONSUMER MUST NAME ITS BAND AND SAMPLE BY STRIDE. `clones.near` ranks
-- worst-first, so "the first N pairs" is "the worst N pairs" and reads as a
-- population. Term size is unbounded in the corpus.
--
-- ★★ THE TWO SCALES COST DIFFERENT ORDERS, MEASURED, NOT GUESSED (wow, 4000
-- pairs, stride 6): FUNCTION-scale `vertical` runs 0.2-12s with 51% of pairs
-- out of band, so it can only ever be an offline instrument. NODE-scale
-- `vertical` on a single struct hole ran <10ms on 199 of 199 calls -- nothing
-- in any slower bucket. That gap is the whole licence for the analysis-time
-- consumer below to ask per HOLE and never per FUNCTION.

local M = {}

-- ⚠ ONE NAME FOR THE COLLAPSED-LOCAL SENTINEL. `M.term` writes it and
-- `M.hole_kind` reads it back to tell a `localglobal` refusal from a name hole;
-- spelling it twice is the two-lists defect this file has been on the wrong end
-- of three times (CART-0928, CART-0929, CART-0932). The `\1` prefix is chosen so
-- no source identifier can collide with it.
local LOCAL_SENTINEL = '\1local'

--- ⚠ NO LONGER THE LOAD PATH. Since the vendoring (CART-0912) this answers
--- "where did the copy COME FROM", and its only consumers are the drift fence
--- and the absorption ledger, both of which read the donor AS TEXT and neither
--- of which executes it. The declared-source rule in the header still governs
--- it — a path out of the analysed tree must never reach a reader either — but
--- nothing here `dofile`s any more.
--- @return string path, string source
function M.path()
    local cfg = require('cartograph.config').algebra_path
    if cfg then return vim.fn.expand(cfg), 'config.algebra_path' end
    local env = os.getenv('CARTOGRAPH_ALGEBRA')
    if env and env ~= '' then return env, 'CARTOGRAPH_ALGEBRA' end
    return (os.getenv('HOME') or '') .. '/tools/templates/algebra.lua', 'default'
end

local loaded, load_err

--- ★★★ VENDORED 2026-09-13 (CART-0912): the algebra is CARTOGRAPH'S OWN CODE
--- now, at `cartograph.algebra.core`, and this no longer `dofile`s anything.
--- USER: "The end goal is to make the code cartograph's own. But dofile-ing it
--- is an acceptable intermediate step." The intermediate step is over.
---
--- ★★ AND THIS REMOVES A TRUST BOUNDARY RATHER THAN WEAKENING ONE. The header
--- above argues at length that the load path must be a DECLARED source because
--- `dofile` EXECUTES what it loads. Requiring an in-tree module executes code
--- that is in the repository, reviewed, and covered by the suite — there is no
--- longer an external file to declare, and `M.path()` survives only to say
--- where the copy CAME FROM (see `tools/vendordrift.lua`).
---
--- ⚠ THE REFUSAL PATH IS STILL REAL AND STILL EXERCISED. `config.algebra =
--- false` disables the seam, so every consumer's `unavailable` rung keeps its
--- test. A rung whose only trigger was a missing file would have gone dead the
--- moment the file stopped being able to be missing.
--- @return table|nil algebra, string|nil err
function M.load()
    -- ⚠ THE DISABLE CHECK IS NOT MEMOIZED, and neither is it merely cheap to
    -- repeat: `setup{}` can flip `config.algebra` after this module has already
    -- loaded, and a memoized refusal would keep answering for a setting the
    -- user has since changed. It is also what makes the refusal TESTABLE in a
    -- process that has already loaded the algebra -- a refusal path that can
    -- only be exercised by a cold process is a path nothing ever exercises.
    if require('cartograph.config').algebra == false then
        return nil, 'disabled (config.algebra = false)'
    end
    if loaded then return loaded end
    if load_err then return nil, load_err end
    local ok, A = pcall(require, 'cartograph.algebra.core')
    if not ok or type(A) ~= 'table' then
        load_err = ('failed to load cartograph.algebra.core: %s'):format(tostring(A))
        return nil, load_err
    end
    loaded = A
    -- ★★★ THE LAST STEP OF LOADING IS WIRING OUR TREE-SITTER IN (CART-0961).
    -- `origin.unported` records `M.parsers.lua` as one of the three things that
    -- did not come with the vendoring: the donor's `lua` grammar reads
    -- `A.parsers.lua` and answers nil without it, which makes every operator
    -- that consumes a term READ FROM SOURCE unavailable. The hook is ours, is
    -- not vendored, and lives in `cartograph.algebraread`.
    -- ⚠ INSTALLED AFTER `loaded` IS SET, and the hook closes over `A` rather
    -- than calling back here, so a parse can never re-enter this function.
    -- ⚠ AND IT IS NOT FATAL. A tree-sitter parser that is missing makes the
    -- READER unavailable, not the algebra — the same absent/unavailable split
    -- the rest of the seam draws, and the grammar already answers nil.
    local okr, reader = pcall(require, 'cartograph.algebraread')
    if okr and type(A.parsers) == 'table' then A.parsers.lua = reader.parser(A) end
    return A
end

--- the vendoring record: donor repo, revision and sha at the time the copy was
--- taken. Read by `tools/vendordrift.lua` and by anything reporting provenance.
--- @return table origin
function M.origin()
    return require 'cartograph.algebra.origin'
end

--- @return boolean ok, string reason
function M.available()
    local A, err = M.load()
    if not A then return false, err end
    local o = M.origin()
    return true, ('vendored %s (from %s/%s)'):format(
        o.donor_rev:sub(1, 8), o.donor_repo, o.donor_file)
end

-- ── the adapter: cartograph expr IR → prototype term ────────────────────────
--
-- ⚠ A DISCRIMINANT MUST NOT BE A FIELD -- `A.eq` compares `k`, `v`, `n` and the
-- kid list ONLY, so a `bin` carrying `op = '+'` and one carrying `op = '-'` would
-- compare EQUAL if the operator lived in a field, and would anti-unify to nothing
-- instead of to a hole.
--
-- ★★★ AND IT IS A KID, NOT PART OF THE KIND (CART-0934). This paragraph read
-- "discriminants go IN THE KIND" and prescribed `bin:+`, which fixed `eq` and broke
-- the lgg: A KIND CAN NEVER BE A HOLE, so two terms differing only in an operator
-- or a selector had DIFFERENT KINDS at that node and the whole subterm collapsed to
-- a bare hole. The kid list is the one place that is both compared by `eq` and
-- open to a hole. `kind_of` returns the pair and `M.term` leads the kid list with
-- it; see its doc comment below for the measurement.
--
-- ⚠ A LITERAL CARRIES ITS TYPE for the same reason: `expr.key` writes
-- `L<ty>:<v>`, so number 1 and string "1" are distinct there. Dropping the type
-- would make them equal and silently under-report divergence.
--- the term KIND for an expr node, plus the DISCRIMINANT that rides as its first
--- KID when it has one (`+` for a `bin`, the selector for a `field`).
---
--- ★★★ A DISCRIMINANT IS A KID, NOT PART OF THE KIND (CART-0934). It used to be
--- welded on — `bin:+`, `field.foo` — and a KIND CAN NEVER BE A HOLE, so two terms
--- differing only in an operator or a selector had different kinds at that node, the
--- lgg collapsed the whole subterm to a bare hole, and the family was inadmissible.
--- MEASURED: `(field.foo a)`/`(field.bar a)` gave 2 families and
--- `one_family_admissible = false`; as `(field ?h1 a)` it is ONE family with the base
--- kept as fixed structure. `clones.anti_unify_row` has always called a differing
--- field or operator a CLEAN EXTRACTABLE PARAMETER, so the welded form is also what
--- stopped the algebra from replacing it.
---
--- ⚠ IT MUST BE A KID AND NOT A FIELD, and that distinction is the whole reason the
--- weld existed. `A.eq` compares `k`, `v`, `n` and THE KID LIST only — an operator in
--- a plain field would be invisible to it, so `a + b` and `a - b` would compare EQUAL
--- and anti-unify to nothing. In the kid list it is compared, so they stay distinct
--- AND can be abstracted. Verified both ways in tests/algebra_spec.lua.
---
--- ⚠ IF AN EAU THEORY EVER LANDS, IT KEYS ON THE WRONG THING. `eau` reads
--- `theory[t.k]`, and algebradrive's note cites EAU.md's "operator theories would be a
--- profile table over `bin:*`" — which this change dissolves into a single `bin`.
--- A theory would need `t.kids[1].n`. Nothing declares one today (verified by grep),
--- so this is a note for whoever writes the first, not a regression.
--- @return string kind, string|nil discriminant
function M.kind_of(e)
    local k = e.k
    if k == 'bin' or k == 'un' then return k, tostring(e.op) end
    if k == 'field' then return (e.method and 'method' or 'field'), tostring(e.n) end
    return k
end

-- ⚠ `table.unpack or unpack` ONCE, AND NEVER INSIDE an `and`/`or` -- an
-- `and`/`or` expression TRUNCATES A MULTIPLE RETURN TO ONE VALUE, which once
-- gave every node its FIRST child only and then reported agreement over the
-- truncated terms (CART-0881).
local tunpack = table.unpack or unpack

--- cartograph expr node → prototype term.
---
--- ⚠ `locals` COLLAPSES EVERY LOCAL TO ONE SYMBOL, and that is not a
--- simplification chosen here -- it mirrors `clones.anti_unify`'s own alpha rule
--- ("both locals: alpha-equivalent, no hole"). WITHOUT IT two functions that
--- differ only in local NAMES do not align at all, which is most real
--- near-clones. The cost is recorded upstream: distinct locals wear one symbol,
--- so a template can say less than it means.
---
--- @param e table expr node
--- @param locals table|nil set of local names
--- @param unsupported table|nil optional counter for unmodelled leaf kinds
--- ★★★ `srcmap` IS A SIDE TABLE, NOT A FIELD ON THE TERM (CART-0939 blocker 1).
--- The struct-hole consumers (`M.drift`, `dc_size`, `dc_kids`, `rcanon`,
--- `local_deps`) each take an EXPR NODE, and a term has none -- so migrating
--- `anti_unify` needs a way back. The obvious move is `t.src = e`, riding free the
--- way `at` does because `rebuild` carries every non-child field and `eq` ignores
--- it. ⚠ AND IT IS WRONG: `A.copy` is a DEEP copy over `pairs(t)` (core.lua:63,
--- used by abstract, classify and composition), so it would recursively clone the
--- whole expression subtree hanging off every term -- and the clone's `src` would
--- no longer BE the node, which is the one property the consumers need.
--- ⇒ A map keyed by the term's identity gives the same answer, costs the term
---   nothing, and cannot be deep-copied by accident. It is opt-in for the same
---   reason `unsupported` is: a caller that does not need it pays nothing.
function M.term(e, locals, unsupported, srcmap)
    local A = M.load()
    if not A then return nil end
    if e == nil then return nil end
    if type(e) ~= 'table' or e.k == nil then return nil end
    local k = e.k
    local t
    if k == 'lit' then
        t = A.lit(tostring(e.ty) .. ':' .. tostring(e.v))
    elseif k == 'name' then
        t = (locals and locals[e.n]) and A.name(LOCAL_SENTINEL) or A.name(tostring(e.n))
    else
        -- ★ THE CHILD LIST COMES FROM `expr.children`, THE SOURCE `walk` ITSELF
        -- CONSUMES (CART-0882). Not a per-kind descent written here -- that
        -- would be another hand-written traversal and another chance to omit a
        -- kind silently.
        local kids = {}
        for _, c in ipairs(require('cartograph.expr').children(e)) do
            local ct = M.term(c, locals, unsupported, srcmap)
            if ct then kids[#kids + 1] = ct end
        end
        if unsupported and #kids == 0
            and not (k == 'table' or k == '?' or k == 'type') then
            -- a leaf kind the adapter does not model: counted, never guessed at
            unsupported[k] = (unsupported[k] or 0) + 1
        end
        -- ONE SOURCE FOR BOTH HALVES: `kind_of` returns the kind and, where the
        -- grammar has one, the discriminant that leads the kid list. Deriving them
        -- in two places is the second-list defect this change exists to remove.
        local kk, disc = M.kind_of(e)
        if disc then
            local all = { A.name(disc) }
            for _, c in ipairs(kids) do all[#all + 1] = c end
            t = A.node(kk, tunpack(all))
        else
            t = A.node(kk, tunpack(kids))
        end
    end
    -- the span, carried as a non-child field: rebuild keeps it, eq ignores it
    if e.at then t.at = e.at end
    if srcmap then srcmap[t] = e end
    return t
end

--- a clone ROW ({lhs, rhs, cond}) as one term, so a pair of rows is a pair of
--- instances the lgg can take. Shape mirrors `clones.anti_unify_row`.
function M.row_term(r, locals, unsupported, srcmap)
    local A = M.load()
    if not A then return nil end
    if type(r) ~= 'table' then return nil end
    if r.k ~= nil then return M.term(r, locals, unsupported, srcmap) end
    local kids = {}
    local function push(list, tag)
        local seq = {}
        for _, x in ipairs(list or {}) do
            local t = M.term(x, locals, unsupported, srcmap)
            if t then seq[#seq + 1] = t end
        end
        kids[#kids + 1] = A.node(tag, tunpack(seq))
    end
    push(r.lhs, 'lhs'); push(r.rhs, 'rhs')
    local c = r.cond and M.term(r.cond, locals, unsupported, srcmap) or nil
    if c then kids[#kids + 1] = A.node('cond', c) end
    return A.node('row', tunpack(kids))
end

--- a whole FUNCTION as one term: a seq of its rows, so two functions are two
--- instances the lgg can take. Third consumer of this shape, hence it lives here
--- and not in each tool -- the same rule the rewire enforced for `term`.
---
--- ⚠ A ROW THE ADAPTER CANNOT BUILD BECOMES `row~`, NOT NOTHING. Dropping it
--- would silently shorten one side and make a positional alignment compare rows
--- that are not counterparts; a distinct marker keeps the arity honest.
function M.fn_term(f)
    local A = M.load()
    if not A then return nil end
    local rows = {}
    for i = 1, #(f.exprs or {}) do
        rows[i] = M.row_term(f.exprs[i], f.locals) or A.node('row~')
    end
    return A.seq(rows)
end

--- ⚠ `A.generalize` RETURNS A RESULT RECORD and so does `A.template`: the
--- TEMPLATE is `{ body, holes, edits }`, and the TERM is `template.body`. Asking
--- a template for `.k` yields nil, silently -- which is how a "is this a bare
--- hole" guard can be DEAD and never once fire (CART-0888). These two accessors
--- exist so no consumer has to remember which record it is holding.
function M.is_collapsed(tmpl)
    local b = tmpl and tmpl.body
    return b ~= nil and b.k == 'hole'
end

--- how much FIXED structure a template shares — the prototype's own admissibility
--- test (`partition`'s `min_fixed`). ★ THE RETRACTION LAW CANNOT REPLACE THIS: a
--- bare-hole template retracts to EVERY instance trivially, so "it retracts" is
--- not evidence the members are one family. Verified, not assumed.
function M.fixed_nodes(t)
    if t == nil then return 0 end
    if t.k == 'hole' then return 0 end
    local n = 1
    for _, c in ipairs(t.kids or {}) do n = n + M.fixed_nodes(c) end
    return n
end

--- how much material a template PRESERVES — `fixed_nodes` plus whatever a hole
--- carries in its ARGUMENT LIST. The admissibility measure for a template produced
--- by a CONTEXT-VARIABLE generalizer (`A.vertical`, BK rigid lgg over hedges),
--- where `fixed_nodes` is not one and silently admits everything.
---
--- ★★★ IT DIFFERS FROM `fixed_nodes` IN EXACTLY ONE WAY: it DESCENDS INTO A HOLE'S
--- KIDS. `vertical` returns a context hole carrying the arguments both sides shared
--- — measured, `{k='hole', h='X1', ctx=true, kids={{k='name', n='a'}}}` — and
--- `fixed_nodes` returns 0 at the hole without looking inside. That is not a small
--- difference: it is the whole signal. HOPAU.md calls the same thing `Y(ȳ)`, "the
--- list of locals in scope that its differing subterm actually uses".
---
--- ⚠ WHY A SECOND MEASURE RATHER THAN A LOWER `min_fixed`. MEASURED over a graded
--- corpus, `A.vertical` on each pair, seq-wrapped:
---
---     CASE                          template                 fixed  PRESERVED
---     identical                     (seq (bin:+ a b))            4      4
---     literal differs               (seq (bin:+ a ?x1...))       3      3
---     global name differs           (seq (call ?x1...))          2      2
---     FIELD selector differs        (seq ?X1(a))                 1      2
---     OPERATOR differs              (seq ?X1(a b))               1      3
---     operator differs, big arms    (seq ?X1((call f x) b))      1      5
---     unrelated                     (seq ?x1...)                 1      1
---     bare names                    (seq ?x1...)                 1      1
---     deep unrelated                (seq ?x1...)                 1      1
---
--- `fixed_nodes` scores the last SIX identically at 1 — three families we want and
--- three we must refuse — because the 1 is the `seq` WRAPPER, not shared structure.
--- So no threshold on it separates them, and lowering `min_fixed` admits everything.
--- `preserved_nodes` separates cleanly at >= 2 and is MONOTONE in shared material
--- (2 / 3 / 5), so it ranks candidates as well as admitting them.
---
--- ⚠ THE THRESHOLD IS NOT 1 AND DEPENDS ON THE WRAPPER. A seq-wrapped template
--- scores 1 for the wrapper alone, so "admissible" is >= 2 here. Pass the floor
--- explicitly; do not reuse `min_fixed`'s default.
--- @param t table a template BODY
--- @return number
function M.preserved_nodes(t)
    if t == nil then return 0 end
    local n = (t.k == 'hole') and 0 or 1
    for _, c in ipairs(t.kids or {}) do n = n + M.preserved_nodes(c) end
    return n
end

--- ARE THESE TWO TERMS ONE CONCEPT-FAMILY? Returns `ok, info`, where info carries
--- `template`, `preserved`, and on a refusal a `why`.
---
--- ★★★ WHY THIS IS NOT `A.partition` (CART-0934). partition is the right answer and
--- cannot be used yet, for two reasons that are its CALLERS' problem, not its own:
---   • `mdl.family_of` hard-codes the FIRST-ORDER lgg, which cannot abstract a
---     discriminant position; `A.vertical` (BK rigid lgg over hedges) can, and there
---     is no hook to swap the generalizer.
---   • `family_of` also hard-codes `fixed_nodes(T.body) >= min_fixed`, which is NOT an
---     admissibility test for a context-variable template — MEASURED: it scores a real
---     family and a vacuous one identically at 1, because that 1 is the seq WRAPPER.
--- Both sit in the VENDORED core, whose local edits are the in-progress split
--- (CART-0912) watched by tools/vendordrift.lua. Bending it here would put a semantic
--- change underneath a structural divergence.
---
--- ⚠ SO THIS IS A SECOND FAMILY SELECTOR BESIDE `partition` — EXACTLY THE SHAPE OF
--- THE DEFECT THIS SESSION KEEPS FINDING (CART-0932, two set-builders; CART-0928, two
--- stop lists). It is defensible only because it is TEMPORARY and strictly NARROWER
--- (pairwise, never n-ary), and migrating to the algebra is the stated destination.
--- ★ THE EXIT CONDITION, so it does not become permanent by neglect: when `family_of`
--- accepts a generalizer AND an admissibility measure, DELETE THIS and call partition.
--- It is not a fallback to keep beside it.
---
--- ⚠ PAIRWISE ON PURPOSE. `vertical(s, q)` is binary and minimises across ALIGNMENTS,
--- so folding it over n members is unlikely to be associative — families would depend
--- on member order. Donor enumeration needs pairs, so the fold is not needed and is
--- not guessed at here.
--- @param a table term
--- @param b table term
--- ⚠ A REFUSAL CARRIES NO `preserved`, AND A CALLER MUST NOT READ THAT AS ZERO.
--- `ok == false` with `why = 'vertical produced no template'` means the generalizer
--- declined; `info.preserved` is nil, NOT a low score. Ranking callers that collapse
--- it to 0 will rank a refusal alongside a genuine mismatch — I did exactly that an
--- hour after writing this and published two rankings that were measuring the
--- declines (CART-0937). Destructure `ok` first.
--- @param a table term
--- @param b table term
--- @param opts table|nil { floor = number, skeleton = 'zhang'|'jwz'|nil }
--- @return boolean ok, table info
function M.pair_family(a, b, opts)
    opts = opts or {}
    local A = M.load()
    if not A then return false, { why = 'algebra unavailable' } end
    -- ★★★ `skeleton = 'zhang'` IS NOT A TUNING CHOICE, IT IS THE DIFFERENCE BETWEEN
    -- WORKING AND SILENTLY REFUSING (CART-0937). `vertical`'s DEFAULT strategy
    -- enumerates LCS alignments and keeps the ADMISSIBLE ones; above ~6 rows / ~40
    -- nodes it finds NONE and returns `candidates = 0` — with `truncated = false`
    -- and `budget_refusals = 0`, i.e. a SILENT EMPTY, not a refusal. MEASURED on a
    -- real pair, truncating row by row:
    --     rows 6  sizes 32/34  preserved 28   template
    --     rows 7  sizes 40/41  NO TEMPLATE, candidates = 0, truncated = FALSE
    -- ⚠ RAISING `cap` DOES NOT HELP (512 gives the same zero): the enumerated
    -- alignments are not admissible, so more of them changes nothing. `zhang` picks
    -- ONE alignment by TREE EDIT DISTANCE instead (Zhang's constrained distance,
    -- vertical.lua:240 dispatches it) and the same full-size pair then preserves 55
    -- of 57 nodes. ⇒ THE DEFAULT IS USABLE ONLY ON TOY TERMS, which is exactly what
    -- the first tests for this function were built from.
    local okv, r = pcall(A.vertical, A.seq({ a }), A.seq({ b }),
        { skeleton = opts.skeleton or 'zhang' })
    if not okv or not r or not r.templates or not r.templates[1] then
        return false, { why = 'vertical produced no template' }
    end
    local T = r.templates[1]
    local body = T.body or T
    local p = M.preserved_nodes(body)
    -- ⚠ THE FLOOR IS WRAPPER-DEPENDENT AND IS PASSED, NEVER INHERITED. A seq-wrapped
    -- template scores 1 for the WRAPPER ALONE, so the floor is 2 here; reusing
    -- `min_fixed`'s default of 1 would admit every pair in the tree. That is the trap a
    -- NEGATIVE example caught — three positives alone looked like a clean win — so it
    -- is written as a number with its reason rather than a default to be inherited.
    local floor = opts.floor or 2
    if p < floor then
        return false, { template = body, preserved = p,
            why = ('preserves %d, floor %d — the seq wrapper alone'):format(p, floor) }
    end
    return true, { template = body, preserved = p, values = T.values }
end

-- ── reading the lgg's holes back in cartograph's vocabulary ─────────────────
--
-- ★★★ THIS IS THE MIGRATION'S HALF OF THE SEAM (CART-0939). `A.generalize` gives
-- UNIFORM holes: a name and a value per instance, with no notion of literal /
-- name / field / operator / struct. Every consumer of `clones.anti_unify` reads
-- exactly that vocabulary, so replacing the walker needs something that recovers
-- it -- and that something must NOT be a second descent, or the walker has been
-- rebuilt under a new name and the migration bought nothing (CART-0746).
--
-- It lives here rather than in a driver because THREE callers need it identically
-- (`analyze_pair`, `element_template` and `clones.match` all call the walker), and
-- a copy per driver is the defect this file exists to avoid.

--- the cartograph hole KIND for a divergence, from the two values at one site.
---
--- ★★ A FLAT DISPATCH, DELIBERATELY. It reads the two values, the enclosing term's
--- kind and the child INDEX -- nothing else, and it never recurses.
---
--- ⚠⚠ THE DISCRIMINANT IS POSITIONAL AND THE PARENT'S KIND ALONE CANNOT SEE IT.
--- Since CART-0934 the operator and the field selector are reified as the FIRST
--- KID, an ordinary `name` leaf -- so `+` vs `-`, `.foo` vs `.bar` and `x` vs `y`
--- are THE SAME SHAPE in the term encoding. A `field` term is
--- `field(name:selector, base)`: TWO name-ish children, only the first of which is
--- the selector. MEASURED on `slice / slice` in our own tree: keying on the parent
--- kind alone called `at.sl(a)` against `atr.sl(a)` four FIELD holes where the
--- walker rightly reports one NAME hole.
---
--- ⚠ A LOCAL FACING A GLOBAL IS A REFUSAL, not a name hole. `M.term` collapses
--- every local to one sentinel, so two locals are already equal and never reach
--- here; one local against one global is the `localglobal` struct hole.
--- @param v1 table|nil the value at this site in instance A (a TERM)
--- @param v2 table|nil the value at this site in instance B
--- @param pk string|nil the enclosing term's kind
--- @param idx number|nil this site's index in the enclosing kid list
--- @return string 'literal' | 'name' | 'field' | 'operator' | 'struct'
function M.hole_kind(v1, v2, pk, idx)
    if v1 == nil or v2 == nil then return 'struct' end
    if type(v1) ~= 'table' or type(v2) ~= 'table' then return 'struct' end
    if v1.k ~= v2.k then return 'struct' end
    if v1.k == 'lit' then return 'literal' end
    if v1.k == 'name' then
        if (v1.n == LOCAL_SENTINEL) ~= (v2.n == LOCAL_SENTINEL) then return 'struct' end
        if idx == 1 then
            if pk == 'bin' or pk == 'un' then return 'operator' end
            if pk == 'field' or pk == 'method' then return 'field' end
        end
        return 'name'
    end
    return 'struct'
end

--- every hole SITE in a template body, zipped against two instances.
---
--- ⚠⚠ SITES, NOT NAMES, AND THE SPAN COMES FROM THE INSTANCE. The lgg is
--- NON-LINEAR by default: one hole name stands at every position whose value tuple
--- is equal, so reading `values[1][h].at` gives every site of that hole THE SAME
--- span. MEASURED: it reported `literal@139:34-139:44 x2` and
--- `field@2267:27-2267:29 x4` -- one span with a multiplicity, an artifact of the
--- key rather than a disagreement. Zipping the body against the instance gives
--- each site the span of the subterm actually standing there.
---
--- ★ AND THE FALLBACK IS THE ENCLOSING TERM'S SPAN, which is the same rule our
--- side records as `at_encloses`: a reified discriminant has no node of its own,
--- so an operator or selector hole takes the span of the node that contains it.
--- ⇒ IT ALSO RECOVERS A SPAN WHERE THE WALKER HAS NONE. A method-call `field` node
--- is built without one (CART-0940), so `anti_unify` emits a field hole with
--- `at_a = nil` while this returns the enclosing call's range.
--- @param body table the template BODY (holes are `k == 'hole'`)
--- @param ia table|nil instance A as a term
--- @param ib table|nil instance B as a term
--- @return table list of { h, pk, idx, a, b, at }, in pre-order
function M.hole_sites(body, ia, ib)
    local out = {}
    local function walk(t, xa, xb, pk, idx, pat)
        if type(t) ~= 'table' then return end
        if t.k == 'hole' then
            -- ★★★ `rep` IS REPORTED, NOT INTERPRETED. `A.generalize` places a HEDGE
            -- hole -- a slice of a child list -- whenever the instances' arities
            -- differ, unconditionally: there is no flag to turn it off (`align` is
            -- `join`'s option, not this one). cartograph HAS NO HEDGE: `anti_unify`
            -- emits `struct why='arity'` and refuses. So every consumer migrating off
            -- the walker has to decide what a hedge means to it, and that decision is
            -- NOT the same for all three -- `element_template` must refuse to keep
            -- `M.match` discriminating, while a future consumer may want the
            -- repetition claim. Reporting the fact and leaving the policy to the
            -- caller is what keeps this from becoming a fourth place that decides.
            out[#out + 1] = { h = t.h, pk = pk, idx = idx, a = xa, b = xb,
                rep = t.rep or nil,
                at = (type(xa) == 'table' and xa.at) or pat }
            return
        end
        local ka = (type(xa) == 'table' and xa.kids) or {}
        local kb = (type(xb) == 'table' and xb.kids) or {}
        for i, c in ipairs(t.kids or {}) do
            -- ⚠⚠ THE ENCLOSING SPAN COMES FROM THE INSTANCE, NOT FROM THE TEMPLATE.
            -- It read `t.at or pat` and passed every real run, because a template
            -- node the lgg REBUILDS from instance A inherits A's `at` (rebuild
            -- carries every field that is not the child list). That is a guarantee
            -- about SOMEONE ELSE'S SOURCE, and it is void the moment a template is
            -- built any other way -- a hand-made body, or a node the lgg constructs
            -- rather than rebuilds. Reading the instance makes it hold by
            -- construction; the template is kept only as a second fallback.
            local pa = (type(xa) == 'table' and xa.at) or t.at or pat
            walk(c, ka[i], kb[i], t.k, i, pa)
        end
    end
    walk(body, ia, ib, nil, nil, nil)
    return out
end

return M
