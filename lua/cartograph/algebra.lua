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
-- ⚠ DISCRIMINANTS GO IN THE KIND, NOT IN A FIELD. `A.eq` compares `k`, `v`, `n`
-- and the kid list ONLY, so a `bin` carrying `op = '+'` and one carrying
-- `op = '-'` would compare EQUAL if the operator lived in a field -- and would
-- anti-unify to nothing instead of to a hole. `bin:+` mirrors `expr.key`'s own
-- discriminants, and the prototype expects exactly this shape.
--
-- ⚠ A LITERAL CARRIES ITS TYPE for the same reason: `expr.key` writes
-- `L<ty>:<v>`, so number 1 and string "1" are distinct there. Dropping the type
-- would make them equal and silently under-report divergence.
function M.kind_of(e)
    local k = e.k
    if k == 'bin' or k == 'un' then return k .. ':' .. tostring(e.op) end
    if k == 'field' then return (e.method and 'method.' or 'field.') .. tostring(e.n) end
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
function M.term(e, locals, unsupported)
    local A = M.load()
    if not A then return nil end
    if e == nil then return nil end
    if type(e) ~= 'table' or e.k == nil then return nil end
    local k = e.k
    local t
    if k == 'lit' then
        t = A.lit(tostring(e.ty) .. ':' .. tostring(e.v))
    elseif k == 'name' then
        t = (locals and locals[e.n]) and A.name('\1local') or A.name(tostring(e.n))
    else
        -- ★ THE CHILD LIST COMES FROM `expr.children`, THE SOURCE `walk` ITSELF
        -- CONSUMES (CART-0882). Not a per-kind descent written here -- that
        -- would be another hand-written traversal and another chance to omit a
        -- kind silently.
        local kids = {}
        for _, c in ipairs(require('cartograph.expr').children(e)) do
            local ct = M.term(c, locals, unsupported)
            if ct then kids[#kids + 1] = ct end
        end
        if unsupported and #kids == 0
            and not (k == 'table' or k == '?' or k == 'type') then
            -- a leaf kind the adapter does not model: counted, never guessed at
            unsupported[k] = (unsupported[k] or 0) + 1
        end
        t = A.node(M.kind_of(e), tunpack(kids))
    end
    -- the span, carried as a non-child field: rebuild keeps it, eq ignores it
    if e.at then t.at = e.at end
    return t
end

--- a clone ROW ({lhs, rhs, cond}) as one term, so a pair of rows is a pair of
--- instances the lgg can take. Shape mirrors `clones.anti_unify_row`.
function M.row_term(r, locals, unsupported)
    local A = M.load()
    if not A then return nil end
    if type(r) ~= 'table' then return nil end
    if r.k ~= nil then return M.term(r, locals, unsupported) end
    local kids = {}
    local function push(list, tag)
        local seq = {}
        for _, x in ipairs(list or {}) do
            local t = M.term(x, locals, unsupported)
            if t then seq[#seq + 1] = t end
        end
        kids[#kids + 1] = A.node(tag, tunpack(seq))
    end
    push(r.lhs, 'lhs'); push(r.rhs, 'rhs')
    local c = r.cond and M.term(r.cond, locals, unsupported) or nil
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

return M
