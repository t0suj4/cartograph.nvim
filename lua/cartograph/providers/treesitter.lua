-- Tree-sitter GraphProvider: the SECOND provider, and the one that makes the
-- cockpit language-agnostic. It produces the same neutral schema the lua-ls
-- CLI emits (nodes/edges/calls), from nothing but parse trees — in-editor,
-- no server, any language with a parser and a spec below.
--
-- Honesty contract: tree-sitter has no type resolution, so every cross-file
-- link is NAME-MATCHED — exactly the `~`/inferred vocabulary the browser
-- already renders. Same-file exact matches are kept plain; cross-file unique
-- names are inferred; ambiguous names refuse to link (the lua-ls fallback
-- rule). Capabilities are partial by construction: `df` is a lite
-- approximation (statement lines, def/use names), `effects`/`rets` are not
-- emitted; consumers already degrade to honest frontiers.

local atr = require 'cartograph.at' -- dual-mode range reads: relink/refresh re-run these paths over the FOLDED store
-- @langs bash c cpp go haskell java javascript lua odin php python ruby rust scheme tsx typescript zig
-- THE EXTRACTOR: every shipped language passes through here, which is why its
-- node-type knowledge is supposed to live in the per-language SPECS rather than in
-- this file. Declared so the language fence checks that separation holds.
local flowmod = require 'cartograph.flow' -- df-strangler step 4: eager per-fn fine flow rows, folded at ingest (flow requires nothing back → no cycle)
local dfmod = require 'cartograph.df' -- fat-record migration: the DUAL-MODE df.stmts accessor (folded OR raw), so relink readers are fold-agnostic (df requires nothing → no cycle)
local constfold = require 'cartograph.constfold' -- const-fold ladder step 1: same-file scalar-const index + argv fold (no cycle)
local transport = require 'cartograph.transport' -- WHERE bytes come from: the list/stamp/read contract, disk today (transport requires nothing back → no cycle)
local M = {}

-- Call DISPOSITION reasons ([[cartograph-graph-improvements]] #1): the
-- resolver's otherwise-SILENT nil returns become tagged. A callee outside the
-- graph is EXTERNAL (with the gate that placed it there) or below the noise
-- floor — a fact the resolver KNOWS and used to discard, forcing the D-census
-- to reconstruct it by regexing source. Stamped on `c.ext` (see census.disp
-- for the total disposition). Shared read-only literals — many calls point at
-- the same table, so nothing may mutate them in place.
M.EXT = {
    vocab  = { disp = 'external', why = 'vocab' },     -- a stdlib_names word
    prefix = { disp = 'external', why = 'prefix' },    -- a stdlib_prefixes head
    exact  = { disp = 'external', why = 'exact-key' }, -- exact-only key miss
    nodef  = { disp = 'external', why = 'no-def' },    -- no def anywhere
    short  = { disp = 'noise',    why = 'short' },      -- sub-3-char noise floor
    stdlib = { disp = 'external', why = 'stdlib' },     -- an L2 environment-profile
                                                        -- surface ([[cartograph-stdlib-profile]]):
                                                        -- known external, version-keyed,
                                                        -- refines no-def when a profile is active
    -- the answering file is KNOWN and is NOT external: an import binds the receiver
    -- to it, but that file was never parsed. "I know which file would answer and
    -- could not read it" is a FRONTIER, not a boundary — minting `external` here
    -- would state a project boundary on the strength of a failure.
    -- WHICH CASES REACH THIS, measured rather than assumed: an UNAVAILABLE read (a
    -- corrupt archive member, EACCES, a wire failure, no libz for a deflated entry)
    -- and a missing grammar. NOT bundles, which this was originally written for: a
    -- bundle is an OUTPUT ARTIFACT referenced by URL, never imported by the module
    -- graph, and across ghost/grocy/sylius/jquery/mootools/desynced there are ZERO
    -- import edges — zero edges of ANY kind — pointing at one.
    unread  = { disp = 'frontier', why = 'unread-file' },
    stdalias = { disp = 'external', why = 'std-alias' },-- a call whose root name is
                                                        -- bound to the stdlib via an explicit
                                                        -- `const X = std....` binding in its file
                                                        -- (self-evidencing, needs no profile);
                                                        -- shadows any project def of the leaf
}
local EXT = M.EXT

-- L2 environment-profile activation ([[cartograph-stdlib-profile]] P2): a repo
-- SHAPE (cartograph/shapes.lua) can imply a runtime profile (factorio-mod →
-- lua-factorio). Resolved ONCE per extraction from the root; a factorio-shaped
-- tree's Lua calls then classify to the `stdlib` disposition instead of a bare
-- no-def. NB the shape detector is root-marker only for now (multi-mod trees are
-- a known review item); a non-matching root → nil → behaviour unchanged.
local _profile_mod = require 'cartograph.spec.profile'
local _shapes_mod -- lazy (avoid a load cycle: shapes → config, never us)
--- `override` DISPOSES of shape inference, exactly as an explicit `opts.packs` does
--- (CART-0217): a string names the profile to activate, and `false` means NONE — so
--- nil (absent) triggers detection while `false` does not. That nil/false asymmetry
--- IS the packs doctrine, repeated here rather than reinvented.
---
--- AN UNUSABLE NAME IS AN ERROR, NOT A FALLBACK. Quietly reverting to shape
--- detection would let a typo change how a whole graph resolves while reporting
--- success — the same failure that let an INGREDIENT artifact be selected as a
--- portability target and report "0 LOST" (CART-0209). env_usable is the fence.
local function active_profile_for(root, override)
    if override == false then return nil end -- explicit NONE: the `{}` of this axis
    if override ~= nil then
        local prof, err = _profile_mod.env_usable(override)
        if not prof then
            error('cartograph: profile override — ' .. tostring(err), 0)
        end
        return prof
    end
    if type(root) ~= 'string' then return nil end
    _shapes_mod = _shapes_mod or require 'cartograph.shapes'
    -- UP-direction ([[cartograph-repo-shapes]]): a sub-root inside a shaped repo
    -- (discourse/app/models under a Rails app) inherits its L2 profile — root-
    -- only probing can't see a marker two levels up. Bounded ancestor walk,
    -- .git-boundary-stopped, so a framework-SOURCE repo never false-activates.
    local pf = _shapes_mod.profile_for(root)
    if pf then return _profile_mod.load(pf.profile) end
    return nil
end

-- EXT.stdlib if the effective spec's active profile covers `name` (a bare free
-- fn, or a call rooted at a profile namespace) — else nil (caller falls back to
-- its own no-def). The nodef-position gate: project resolution has already
-- failed here, so profile-labelling cannot shadow a real def.
local function prof_ext(spec, name)
    local prof = spec and spec._profile
    if not prof then return nil end
    if prof.free[name] then return EXT.stdlib end
    local r = name:match('^([%w_]+)%.')
    if r and prof.nsset and prof.nsset[r] then return EXT.stdlib end
    return nil
end

-- P0 EXTRACTION PROFILER ([[cartograph-perf-cut]]): per-phase wall accumulators,
-- gated on M.PROFILE so a normal run pays only a bool short-circuit (pstart
-- returns nil when off → padd is a nil no-op; the hot flow.build site never even
-- calls hrtime). tools/profile.lua flips it and reads data.prof. Nanoseconds.
M.PROFILE = false
local prof
local function pstart() return M.PROFILE and vim.uv.hrtime() or nil end
local function padd(key, t0)
    if t0 then prof[key] = (prof[key] or 0) + (vim.uv.hrtime() - t0) end
end

-- shared node primitives live in the spec substrate so spec modules share ONE
-- definition without a require cycle ([[cartograph.spec.tsutil]]). Aliased
-- locals → all call sites here are unchanged.
local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text

--- The NAME text of a declarator capture, with whitespace squeezed out.
---
--- ★★ A `qualified_identifier` WHOSE `::` IS A *MISSING* TOKEN IS A MISPARSE, NOT A
--- QUALIFIED NAME (CART-0434). tree-sitter's error recovery inserts a ZERO-WIDTH `::` where
--- the grammar demanded one, so the node LOOKS qualified and its separator has EMPTY TEXT.
--- Every genuine qualified name — `ns::f`, `a::b::c`, `C<T>::m`, `i::MaybeHandle<i::String>`
--- — carries a `::` token with real text. Squeezing the whitespace out of a misparsed one
--- FABRICATES a symbol:
---
---     ZIG_EXTERN_C LLVMTargetMachineRef ZigLLVMCreateTargetMachine(…);   // zig_llvm.h:107
---       cpp: function_declarator > qualified_identifier
---              namespace_identifier "LLVMTargetMachineRef"   <- the RETURN TYPE
---              identifier           "ZigLLVMCreateTargetMachine"
---       -> node named `LLVMTargetMachineRefZigLLVMCreateTargetMachine`
---
--- The macro eats the type slot, so the next two identifiers look like `ns name`. Worse than
--- a wrong name: the return type is presented as a NAMESPACE, so qualified resolution hunts
--- for a member of something that does not exist and every caller of the real function
--- resolves to nothing. The honest name is the TRAILING identifier — what a C parse of the
--- same bytes produces, where the type lands in an ERROR node and the declarator is clean.
---
--- ★★ AND THE FIRST CUT OF THIS TESTED THE WRONG THING — "does the TEXT contain `::`" —
--- which is true of the zig case and FALSE OF v8's whole class, where the glued-on return
--- type is itself qualified or templated:
---
---     V8_WARN_UNUSED_RESULT MaybeLocal<Function> ScriptCompiler::CompileFunction(…)
---       -> qualified_identifier "MaybeLocal<Function> ScriptCompiler::CompileFunction"
---          contains `::`, so a text test passes it straight through
---
--- I measured zig, cpp and cppmodern, found 1 + 2 + 0, and called it small. v8 — the corpus
--- the ticket itself named as the gate — was the population that had the answer. THE
--- STRUCTURAL SIGNAL IS EXACT WHERE THE TEXT ONE IS NOT: read the token, not the string.
---
--- The unglue drops everything up to and INCLUDING the missing separator, so a real
--- qualifier behind one survives: `ScriptCompiler::CompileFunction`, not `CompileFunction`.
---
--- ★★ AND THE MISSING SEPARATOR IS NOT ALWAYS AT THE TOP — v8 again, second correction:
---
---     V8_WARN_UNUSED_RESULT
---     inline i::MaybeHandle<i::String> NewString(…)
---       qualified_identifier "i::MaybeHandle<i::String> NewString"   <- `::` here is REAL
---         namespace_identifier "i" · [::] · qualified_identifier
---            "MaybeHandle<i::String> NewString"                      <- `::` here is MISSING
---
--- A return type that is ITSELF qualified puts a real separator above the fabricated one, so
--- checking this node's own children finds nothing and the whole glued string is returned.
--- The walk therefore descends the LAST named child looking for a deeper missing token, and
--- the answer is everything after the DEEPEST one: `NewString`, since every level above it
--- is the return type. ★ Twice now the fix was right about the case it was written against
--- and blind one shape over — both times v8 held the shape, and both times the correction
--- came from MEASURING it rather than from re-reading the code.
--- ★ IT CANNOT FIRE ON REAL C++ by construction — a written `::` is never zero-width.
--- ONE recursive walk for both shapes, because they are two spellings of one recovery and
--- each of them can sit at ANY depth: a qualified return type puts a real separator above the
--- fabricated one (`std::optional<T> OS::method`), so a check of the top node's children
--- finds nothing in either form. Returns the corrected text, or nil when nothing is glued.
local function qname(namen, src)
    -- ★★ THE DEEPEST SIGNAL WINS, AND THAT ORDERING IS THE WHOLE FUNCTION. Two macros before
    -- a qualified template return type put BOTH shapes in one node, at different depths:
    --
    --     V8_NOINLINE V8_PRESERVE_MOST std::pair<IntType, uint32_t> read_leb_slowpath(…)
    --       qualified_identifier
    --         namespace_identifier "V8_PRESERVE_MOST"    <- the second macro, as a namespace
    --         ERROR "std"                                <- SHAPE 2, at the top
    --         [tok] :: "::"  (real)
    --         qualified_identifier "pair<…> read_leb_slowpath"
    --           template_type · [tok] :: ""  MISSING     <- SHAPE 1, one level down
    --           identifier "read_leb_slowpath"
    --
    -- Checking this level first answered `std::pair<IntType,uint32_t>read_leb_slowpath` —
    -- it stripped one macro and glued the rest. EVERYTHING ABOVE THE DEEPEST SIGNAL IS
    -- RETURN TYPE, so the descent has to come before either local test. Measured: fixing the
    -- nested case without this made the v8 residual go 15 -> 17, because three names that had
    -- been fully glued became half-glued and my detector counts both the same.
    local last
    for c in namen:iter_children() do if c:named() then last = c end end
    -- @langs-ok `qualified_identifier` is a CPP-ONLY node type; the comparison
    -- being false in every other grammar is exactly what confines this unglue to
    -- C++ misparses, and they fall through to the plain squeezed text (the
    -- @langs-ok cpp-only node type; false in every other grammar BY DESIGN
    if last and last:type() == 'qualified_identifier' then
        local deep = qname(last, src)
        if deep then return deep end
    end
    -- shape 1: a MISSING (zero-width) `::` — everything after it is the real name
    local past, tail = false, nil
    for c in namen:iter_children() do
        if not c:named() then
            if c:type() == '::' and node_text(c, src) == '' then past = true end
        elseif past then tail = c; break end
    end
    if tail then
        -- @langs-ok `qualified_identifier` is a CPP-ONLY node type; the comparison
        -- being false in every other grammar is exactly what confines this unglue to
        -- C++ misparses, and they fall through to the plain squeezed text (the
        -- @langs-ok cpp-only node type; false in every other grammar BY DESIGN
        return (tail:type() == 'qualified_identifier' and qname(tail, src))
            or (node_text(tail, src):gsub('%s+', ''))
    end
    -- shape 2: an ERROR child — the real name starts there
    local parts, seen = {}, false
    for c in namen:iter_children() do
        if not seen and c:named() and c:type() == 'ERROR' then seen = true end
        if seen then parts[#parts + 1] = node_text(c, src) end
    end
    if seen and #parts > 0 then return (table.concat(parts):gsub('%s+', '')) end
    return nil
end

--- ★★ A NAME THAT IS ITSELF A DECLARATOR IS NOT A NAME (CART-0435). A C++20 CONSTRAINED
--- constructor — `requires` after the parameter list, then a member-initializer list —
--- nests one `function_declarator` inside another, and `declarator: (_) @name` in the cpp
--- spec's `functions`/`interface` queries happily captures the inner one:
---
---     V8_INLINE Handle(Handle<S> handle)
---       requires(is_subtype_v<S, T>)
---         : HandleBase(handle) {}
---
---     function_definition
---       type: type_identifier "V8_INLINE"           <- the macro takes the type slot
---       declarator: function_declarator             <- the OUTER one
---         declarator: function_declarator           <- @name captures THIS
---           declarator: identifier "Handle"         <- the name actually is HERE
---           parameters: parameter_list "(Handle<S> handle)"
---           requires_clause "requires(…) : HandleBase"
---         parameters: parameter_list "(handle)"     <- the member-init ARGS, misparsed
---
--- ★ THE GRAMMAR DOES PLACE `requires_clause` — this is not a pre-C++20 parser, and the
--- ERROR-node recovery CART-0434 added for `qualified_identifier` cannot see this at all
--- (the captured node is a `function_declarator`, never a qualified name). What the grammar
--- gets wrong is the MEMBER-INITIALIZER LIST: `: HandleBase` is swallowed into the
--- requires_clause and its argument list `(handle)` is left over as a second parameter_list,
--- which is what forces the second declarator level. BOTH spellings of the constraint —
--- `requires(expr)` and the paren-less `requires std::is_same_v<This, MaybeObject>` — produce
--- the identical signature, so one descent covers both.
--- ★ AN ORDINARY CONSTRUCTOR NEVER NESTS: `Widget(int a) : count_(a) {}` puts the
--- field_initializer_list beside the declarator, one level, and this loop does not fire.
--- Measured: 14 fabricated names in v8's handles.h / maybe-handles.h / tagged.h, 0 after.
--- ★ ONLY `function_declarator`. A function returning a function pointer nests through
--- `parenthesized_declarator`/`pointer_declarator` and is named `(*makeFn(inta))` today —
--- the same class of defect, a different (unmeasured) population, its own ticket.
local function name_text(namen, src)
    -- @langs-ok `function_declarator` is a C/CPP-ONLY node type; the comparison is false in
    -- every other grammar BY DESIGN, which is what confines this descent to C++ misparses
    while namen:type() == 'function_declarator' do
        local inner = namen:field('declarator')[1]
        if not inner then break end
        namen = inner
    end
    -- @langs-ok `qualified_identifier` is a CPP-ONLY node type; the comparison
    -- being false in every other grammar is exactly what confines this unglue to
    -- C++ misparses, and they fall through to the plain squeezed text (the
    -- @langs-ok cpp-only node type; false in every other grammar BY DESIGN
    if namen:type() == 'qualified_identifier' then
        local fixed = qname(namen, src)
        if fixed then return fixed end
    end
    return (node_text(namen, src):gsub('%s+', ''))
end
local inext = tsutil.inext
local refusal = tsutil.refusal

-- shared empty iterator: the `... or function () end` fallback used to allocate
-- a fresh closure on every nil-children branch in hot loops
local function NOOP() end

-- CONFINEMENT REFUSAL (CART-0230). A def the source declares file-local, whose
-- name is never mentioned in a value position anywhere in its own file, cannot have
-- escaped that file — so a call from ANOTHER file is not reaching it, however
-- unique the name happens to be workspace-wide. Both resolve drivers consult this
-- before minting a cross-file edge; an honest unresolved call replaces a
-- manufactured one.
--
-- MEASURED on our own tree (526 files, 2430 cross-file inferred edges, 2419-edge
-- residual hand-sampled at 50): refuses 435 edges, of which the sample says 10 are
-- wrong and 0 are right. Both premises are load-bearing — `exported == false`
-- alone refuses 598 and kills 5 CORRECT edges, the commands/*.lua calls into
-- commands.lua's `local function cmd`/`live`, which DO escape through the `H`
-- handoff table those submodules destructure. n=50 with 0 observed false
-- positives bounds the FP rate near 8.6%, not at zero.
--
-- TRI-STATE, and the test is `== false` in both premises on purpose. A language
-- with no exported_def leaves `exported` nil; a spec with no escape_names leaves
-- `escapes` nil; either nil means NOT ASKED. Reading those as "no" is exactly the
-- absence-as-falseness bug that made this guard's first version fire on 99.5% of
-- the population and kill every correct edge in the sample.
local function confined(n, cfile)
    return n.file ~= cfile and n.exported == false and n.escapes == false
end

-- ── per-language specs ───────────────────────────────────────────────────────
-- Each spec: file extensions, tree-sitter queries with a shared capture
-- protocol (@def/@name for functions and vars, @call/@name for calls), and
-- small hooks where grammars genuinely differ.

-- ONE scope model per parse tree, shared by extract_defs (df binder tags)
-- and extract_calls (receiver typing) — keyed by TREE IDENTITY (the same
-- tsroot userdata flows to both passes), so per-tree lifetime is
-- structural: node ids cannot alias across trees, and the two-models-per-
-- file redundancy is gone. nil when the language has no scope spec.
local jvt_sm, jvt_root = nil, nil
local function tree_model(tsroot, src, spec)
    if jvt_root ~= tsroot then
        jvt_root = tsroot
        jvt_sm = spec.scopes
            and require('cartograph.scope').model(src, spec.scopes) or nil
    end
    return jvt_sm
end

-- WRITE-position classifiers (the write axis, rung 1: syntactic). A mention
-- is a WRITE when it sits anywhere on an assignment-target chain: the base
-- is MUTATED, the final field ASSIGNED, intermediates mutated too — all
-- writes in the "does this fn change state reachable through this name"
-- sense the use edge answers. Bracket KEYS are reads:
--   x = v          x writes            state.x = 1    state AND x write
--   t[k] = v       t writes, k reads   a.b.c = v      a, b, c all write
-- Policy per language, called from collect_mentions only when the mention's
-- parent type is in spec.write_gate (zero cost on the read-heavy common
-- path). Languages without a classifier ship no mode — absent, not wrong.

-- GUARD CLASS of a write (the guard-summaries rung, census-justified:
-- ~half of all in-fn writes are guarded). Returns a SOUND chain:
--   0 = unguarded   1 = guarded (some enclosing condition — the hedge)
--   2 = SET-ONCE    (the write provably cannot overwrite: an absence test
--                    of the SAME target chain in conjunct position, an
--                    else-arm of a presence test, or an idiom form —
--                    `X = X or v`, `$x ??= v`)
-- Set-once matching is AST-hardened: the tested chain's source text must
-- equal the written chain's (the text census's word-match over-credited
-- receiver mentions). Conjunct-sound: absence tests are only accepted
-- through `and` — under `or`/`not` the branch can run with the target
-- present. elseif arms never claim set-once (the top condition is FALSE
-- there). Everything unprovable stays class 1 — a named hedge, not a lie.

-- scalar literal node types across the grammars (lua/php/js/python/java…)
local SCALAR_LIT = { ['true'] = true, ['false'] = true, ['nil'] = true,
    number = true, boolean = true, null = true, integer = true, float = true,
    none = true, true_ = true, false_ = true }

local IDXC = { dot_index_expression = true, bracket_index_expression = true,
    subscript_expression = true, member_access_expression = true,
    variable_name = true }

-- the written chain's top node (same climb as is_write; bracket KEYS stop it)
local function chain_top(c, n)
    local cur, p = c, n
    while p do
        local pt = p:type()
        if not IDXC[pt] then break end
        if (pt == 'bracket_index_expression' or pt == 'subscript_expression')
            and p:named_child(0) ~= cur then break end
        cur = p
        p = p:parent()
    end
    return cur
end

local function ntext(x, src) return (node_text(x, src):gsub('%s', '')) end

-- guard substrate lives in spec/tsutil.lua (shared with the spec modules'
-- GUARDS without a require cycle); the engine's generic guard machinery
-- (conj_abs, guard_class) uses optext_is. chain_eq/unparen were used only by
-- the lua/php GUARDS and moved with them into their spec modules.
local optext_is = tsutil.optext_is

-- absence test anywhere in CONJUNCT position (descend parens + and only)
local function conj_abs(G, n, src, chain)
    n = tsutil.unparen(n)
    if n:type() == G.binop and optext_is(n, src, G.andops) then
        return conj_abs(G, n:named_child(0), src, chain)
            or conj_abs(G, n:named_child(1), src, chain)
    end
    return G.abs_test(n, src, chain)
end

-- param-name map of a fn node: name -> 1-based index (nil when no params)
local function param_map(fnnode, src, pfield)
    local ps = fnnode:field(pfield)[1]
    if not ps then return nil end
    local map, i = nil, 0
    for ch in ps:iter_children() do
        if ch:named() then
            local nm
            local t = ch:type()
            if t == 'identifier' then nm = node_text(ch, src)
            elseif t == 'simple_parameter' or t == 'variable_name'
                or t == 'property_promotion_parameter' then
                nm = node_text(ch, src):match('%$[%w_]+')
            end
            i = i + 1
            if nm then
                map = map or {}
                map[nm] = i
            end
        end
    end
    return map
end

-- the immediate FIELD of a base-position mention (`state.x` at the state
-- mention -> 'x'; computed keys -> '[]'; not a field access -> nil).
-- Language-generic over the IDXC types; php unwraps the $ sigil.
local function mention_field(c, n, src)
    local p = n
    -- @langs-ok php/bash `$var` mention shape; the other grammars use a plain identifier, handled by the arm above
    if p:type() == 'variable_name' then c = p; p = p:parent() end
    if not p then return nil end
    local t = p:type()
    if t == 'dot_index_expression' or t == 'member_access_expression' then
        if p:named_child(0) ~= c then return nil end
        local f = p:named_child(1)
        return f and node_text(f, src) or '[]'
    end
    if t == 'bracket_index_expression' or t == 'subscript_expression' then
        if p:named_child(0) ~= c then return nil end
        local k = p:named_child(1)
        -- @langs-ok a STRING key in a bracket index (`t["k"]`); the grammars lacking `string` name it `string_literal` and do not index by string literal syntactically
        if k and k:type() == 'string' then
            local inner = k:named_child(0)
            if inner then return node_text(inner, src) end
        end
        return '[]'
    end
    return nil
end

-- the leftmost identifier of a chain (its BASE): `t.x['k']` -> t
local function leftmost(top)
    local x = top
    while true do
        local ch = x:named_child(0)
        if not ch then return x end
        x = ch
    end
end

-- a bare param (or its negation) in CONJUNCT position: returns ±index.
-- Sound in the SKIP direction only: "no write unless param i truthy" —
-- additional conjuncts merely restrict further, they cannot fire a write.
local function param_conj(G, n, src, params)
    n = tsutil.unparen(n)
    local t = n:type()
    if t == G.binop and optext_is(n, src, G.andops) then
        return param_conj(G, n:named_child(0), src, params)
            or param_conj(G, n:named_child(1), src, params)
    end
    if t == G.negop then
        local op = n:child(0)
        if op and not op:named() and op:type() == G.negtok then
            local x = n:named_child(0)
            if x then
                local i = params[node_text(x, src)]
                if i then return -i end
            end
        end
        return nil
    end
    local i = params[node_text(n, src)]
    return i
end

local function guard_class(c, n, src, G)
    local top = chain_top(c, n)
    local chain -- LAZY: most writes never reach a text comparison
    local function ch()
        if not chain then chain = ntext(top, src) end
        return chain
    end
    if G.rhs_setonce(top, src, ch) then return 2 end
    local class = 0
    local conds, nc, negcond, fnnode
    local node, p = top, top:parent()
    while p do
        local pt = p:type()
        if G.fn[pt] then fnnode = p break end
        if G.cond[pt] then
            -- the condition is the first named child in both grammars
            -- (field() allocates a result table per call — this loop is
            -- per-write × per-ancestor, measured hot)
            local cond = p:named_child(0)
            if cond and node ~= cond then
                class = 1
                local at = node:type()
                if at == G.else_t then
                    if G.presence(cond, src, ch()) then return 2 end
                    negcond = negcond or cond
                elseif at ~= G.elseif_t then
                    if conj_abs(G, cond, src, ch()) then return 2 end
                    nc = (nc or 0) + 1
                    conds = conds or {}
                    conds[nc] = cond
                end
            end
        end
        node = p
        p = p:parent()
    end
    -- pw: this write's BASE is a param of the enclosing fn — the
    -- param-MUTATION fact the purity fixpoint needs, and it is a
    -- LANGUAGE SEMANTIC: lua/js tables are reference-typed (`function
    -- f(t) t.x = 1` writes the CALLER's table), php arrays/scalars are
    -- VALUE-typed (a param write mutates a local copy — no fact; php
    -- object mutation and &-params belong to the by-ref rung).
    -- Name-matched to THIS fn's own params (~): closure writes to an
    -- outer fn's param are not attributed — a known honesty gap.
    local params = fnnode and param_map(fnnode, src, G.pfield)
    local pw
    if params and G.pw_refsem and leftmost(top) == c then
        pw = params[node_text(c, src)]
    end
    -- the param predicate (gp): only when guarded, not set-once, in a fn
    if class == 1 and params then
        for i = 1, nc or 0 do
            local gp = param_conj(G, conds[i], src, params)
            if gp then return 1, gp, pw end
        end
        if negcond then -- else-arm: the whole condition, negated
            local x = negcond
            x = tsutil.unparen(x)
            local i = params[node_text(x, src)]
            if i then return 1, -i, pw end
        end
    end
    return class, nil, pw
end

-- exported for on-demand re-analysis (the field atlas re-parses a file
-- and reruns the write/guard classifiers on live nodes)
M.guard_class = guard_class


-- The RAILS overlay pack's def-emitters ([[cartograph-modular-specs]]): reuse
-- the R3 def-emitter mechanism for ActiveRecord associations and `delegate`.
-- An association `has_many :posts` / `belongs_to :author` DEFINES instance
-- accessors (`Model#posts`, `Model#posts=`); `delegate :name, :email, to: …`
-- defines a delegating reader per method. These are Rails DSL, not base Ruby —
-- so they live in the pack, composed on only for a Rails corpus.
local RB_ASSOC = { belongs_to = true, has_one = true, has_many = true,
    has_and_belongs_to_many = true }
local function ruby_rails_synth(tsroot, src)
    local out = {}
    local function owner(callnode)
        local p = callnode:parent()
        while p do
            local t = p:type()
            if t == 'class' or t == 'module' then
                local n = p:field('name')[1]
                return n and node_text(n, src)
            end
            p = p:parent()
        end
    end
    local function walk(n)
        -- @langs-ok ruby/python `call` node — this walk is the ruby symbol-argument harvest below
        if n:type() == 'call' then
            local m = n:field('method')[1]
            local mn = m and node_text(m, src)
            local args = mn and n:field('arguments')[1]
            if args and RB_ASSOC[mn] then
                local C = owner(n)
                if C then
                    -- the FIRST symbol is the association name → reader + writer
                    for c in args:iter_children() do
                        -- @langs-ok ruby `simple_symbol` (`:sym`) — ruby-only literal, no analogue to mirror
                        if c:type() == 'simple_symbol' then
                            local sym = node_text(c, src):sub(2)
                            if sym:match('^[%a_][%w_]*$') then
                                out[#out + 1] = { name = C .. '#' .. sym, node = c }
                                out[#out + 1] = { name = C .. '#' .. sym .. '=', node = c }
                            end
                            break
                        end
                    end
                end
            elseif args and mn == 'delegate' then
                local C = owner(n)
                if C then
                    -- every top-level symbol is a delegated method; the `to:`/
                    -- `prefix:`/`allow_nil:` options are pairs, skipped
                    for c in args:iter_children() do
                        -- @langs-ok ruby `simple_symbol` again, same harvest
                        if c:type() == 'simple_symbol' then
                            local sym = node_text(c, src):sub(2)
                            if sym:match('^[%a_][%w_]*$') then
                                out[#out + 1] = { name = C .. '#' .. sym, node = c }
                            end
                        end
                    end
                end
            end
        end
        for ch in n:iter_children() do walk(ch) end
    end
    walk(tsroot)
    return out
end




-- Zig-R5 receiver typing. `fn m(self: *Foo, x: Bar) { self.a(); x.b() }` — a
-- call `recv.method()` is typed by finding `recv` in the NEAREST enclosing
-- function_declaration's parameter list and reading its declared type. The
-- type is lexical + explicit, so this is sound and unambiguous — `self`
-- resolves per-method (no file-level collision), and a miss is honest.



M.spec = {
}

-- zig's spec (L0+L1) lives in its own module now — the first per-language
-- extraction ([[cartograph-spec-layering]] P1 step 2). Same table the inline
-- entry produced; the engine reads M.spec.zig identically.
M.spec.zig = require 'cartograph.spec.zig'
-- the simple languages (no dedicated helpers) — extracted modules, same tables
-- ([[cartograph-spec-layering]] P1). Before the typescript/tsx derivations,
-- which tbl_extend M.spec.javascript.
M.spec.c = require 'cartograph.spec.c'
M.spec.cpp = require 'cartograph.spec.cpp'
M.spec.scheme = require 'cartograph.spec.scheme'
M.spec.javascript = require 'cartograph.spec.javascript'
M.spec.go = require 'cartograph.spec.go'
M.spec.haskell = require 'cartograph.spec.haskell'
M.spec.rust = require 'cartograph.spec.rust'
M.spec.python = require 'cartograph.spec.python'
M.spec.bash = require 'cartograph.spec.bash'
M.spec.odin = require 'cartograph.spec.odin' -- 11th module (moved via the move-set flow)
M.spec.ruby = require 'cartograph.spec.ruby' -- 12th (move-set flow; rails-pack helpers stay)
M.spec.php = require 'cartograph.spec.php' -- 13th (move-set flow; guard substrate → tsutil)
M.spec.lua = require 'cartograph.spec.lua' -- 14th (move-set flow; scope/guards/ecosystem detectors)
-- java (15th, LAST inline spec): java_var_type takes the scope model as a param
-- (threaded via qualify_call), so the generic tree_model/jvt_sm cache stays here;
-- the resolver reads _jdk_types/_service_markers/_bean_name back off the module.
local javaspec = require 'cartograph.spec.java'
M.spec.java = javaspec

-- typescript is the javascript spec under another parser
M.spec.typescript = vim.tbl_extend('force', {}, M.spec.javascript)
M.spec.typescript.exts = { 'ts' }

-- SCOPE-REGIME per language: declaration node types that are BLOCK-scoped (the
-- binding dies at its region's end); everything unlisted = function-scoped. The
-- per-language config home for flow's fine reaching (consumed via flow.build's
-- cfg.regime seam; was flow.REGIME, consolidated here alongside params_field /
-- is_method / df_ids). php/python/ruby have no block scope → no regime.
M.spec.lua.regime = { variable_declaration = 'block', local_declaration = 'block',
    local_variable_declaration = 'block' }
M.spec.javascript.regime = { lexical_declaration = 'block' } -- let/const; var = hoisted

-- ── EXTRA CONTROL NODES, PER LANGUAGE (CART-0363) ────────────────────────────
-- flow.lua's CTRL/PRELOOP sets are `*_statement`-shaped, which is one language's
-- spelling. A control node absent from them is emitted as a PLAIN ROW and du then
-- harvests its whole subtree, so THE BODY GETS NO ROWS AT ALL — no CFG, no
-- per-statement def/use, nothing for df / reaching / liveness / LICM / untangle /
-- extract / the clone tiers to read. MEASURED before this existed: ruby opened ZERO
-- control structures (2219 opaque on rails/activerecord alone), ghost lost 594
-- for-of/for-in sites and jquery 91.
--
-- ★ THREADED FROM THE SPEC RATHER THAN GROWN AS A UNION, which is the v120 precedent
-- recorded in cache.lua: "flow's nested-function stop was a hardcoded cross-language
-- union ... now threaded per-language from the spec". A union is how the set got one
-- language's spelling in the first place.
--
-- `ctrl` = also a control statement (recurse its sub-regions).
-- `preloop` = of those, the ones tested BEFORE the body, so a zero-trip skip is
-- feasible and the back-edge wires to the head.
M.spec.javascript.ctrl = { for_in_statement = true }   -- for…of AND for…in share the type
M.spec.javascript.preloop = { for_in_statement = true }
-- ★ THE JS SWITCH BODY WAS 100% OPAQUE (CART-0390) — java's situation before CART-0363, one
-- language over. js spells it `switch_statement > switch_body > switch_case / switch_default`,
-- and flow classified NONE of the three, so the body was emitted by the generic fallback as
-- ONE plain row and every statement inside folded into it. Measured: a two-arm switch with
-- four statements produced exactly TWO rows.
-- ★ IN THE SPEC, NOT THE BASE SETS, and that distinction is the whole `pattern` lesson again:
-- `switch_body`/`switch_default` are js-family only, but `switch_case` IS ALSO ZIG AND ODIN
-- (checked via language.inspect across all 17 grammars). A base entry would have silently
-- re-modelled two other languages' switches. The seam exists for exactly this.
M.spec.javascript.body = { switch_body = true }
M.spec.javascript.clause = { switch_case = 'case', switch_default = 'case' }
-- ('case' for BOTH: the arm-vs-default distinction is made by whether the arm has a LABEL,
--  not by its spelling, so `switch_default` gets a proper case row like C's `default_statement`)
M.spec.typescript.ctrl = M.spec.javascript.ctrl
M.spec.typescript.preloop = M.spec.javascript.preloop
M.spec.typescript.body = M.spec.javascript.body
M.spec.typescript.clause = M.spec.javascript.clause

-- RUBY (CART-0363). Verified by parsing each form and reading the grammar's own names:
--   if / unless   {condition, consequence -> `then`, alternative -> `elsif` | `else`}
--   while / until {condition, body -> `do`}
--   case          {value}, with `when` {pattern, body} children
--   for           {pattern, value, body -> `do`}
-- ★ ALL FOUR CLASSES ARE NEEDED. `ctrl` alone opens the loop and then folds its whole body
-- into one row, because `then`/`do` are not `block` and so are not recognised as regions.
-- Ruby opened ZERO control structures before this: 2219 opaque on rails/activerecord alone.
-- ★ A MAP FROM NODE TYPE TO ROLE, not a bare set (CART-0382). `true` = a control statement
-- with no special role; 'if' = successors' IF branch, which detects an EXHAUSTIVE false arm
-- and WITHHOLDS the skip edge. Ruby's `if` is spelled `if`, so it never matched flow's base
-- IF_T (`if_statement`/`if_expression`) and fell to the generic branch, which adds an edge to
-- every child AND to the next statement — so `if a … else … end` claimed control could skip
-- BOTH arms. Sound (over-approximate) but false, and optapply's PRE is built on exactly that
-- exhaustiveness. The role lives on `ctrl` so it cannot drift away from it.
M.spec.ruby.ctrl = { ['if'] = 'if', ['unless'] = 'if', ['while'] = true,
    ['until'] = true, ['case'] = 'switch', ['for'] = true,
    -- `begin … rescue … ensure … end`, role 'try': its handlers are reachable from any point
    -- in the body, which is what the TRY branch of successors models. It was `kind=stmt`
    -- before, so the WHOLE block folded into one row and body + handler had no rows at all
    -- (CART-0386). 187 sites in activerecord/lib, 632 in discourse/app.
    ['begin'] = 'try',
    -- THE MODIFIER FORMS ARE THE DOMINANT REMAINDER, not a corner: measured 738 `x if c`
    -- and 311 `x unless c` on rails/activerecord alone, against 1575 rows the block forms
    -- opened. `{condition, body}` where body is a single statement rather than a region —
    -- the emit fallback handles that, which is the same path a C-family unbraced body takes.
    -- cfg.lua already models both in its COND set (and unless_modifier in INVERTED), so this
    -- brings the ROW model level with the dominance model rather than ahead of it.
    if_modifier = 'if', unless_modifier = 'if' }
-- PRE-condition: the test runs before the body, so a zero-trip skip is feasible and the
-- back-edge wires to the head. `until` is a while with an INVERTED condition, which cfg.lua
-- already models (its INVERTED set) — the loop STRUCTURE is identical, so it belongs here.
M.spec.ruby.preloop = { ['while'] = true, ['until'] = true, ['for'] = true }
M.spec.ruby.body = { ['then'] = true, ['do'] = true }
-- a MAP, not a set: the value names WHICH clause class, so clause() can dispatch without
-- two more spec keys. `elsif` is a guard over a body (condition + consequence), `when` is a
-- switch case (pattern + body), `else` is the plain alternative.
-- ★ THE VALUE NAMES THE ROLE, and for `rescue`/`ensure` it has to: neither spelling contains
-- a tell the name-substring fallback could match, so `ensure` would have become a generic
-- 'clause' that successors' TRY branch routes as an ordinary sibling rather than the
-- normal-completion path. 'catch' also routes `rescue` to the BINDING treatment, so
-- `rescue E => e` defs `e` instead of reading a variable nothing defines.
M.spec.ruby.clause = { ['elsif'] = 'elseif', ['else'] = 'else', ['when'] = 'case',
    ['rescue'] = 'catch', ['ensure'] = 'finally' }
-- ── ATTACHED BLOCKS (CART-0363 part B) ──────────────────────────────────────────────
-- ★ THE FORM RUBY IS ACTUALLY WRITTEN IN. Measured: activesupport 464 `do…end` + 403 brace
-- blocks, 18% of its statements inside one; activerecord 1200 + 708, 20%. Until now a whole
-- block was ONE row — `xs.each do |x| g(x); h(x) end` came back as a single `call` row with
-- use={xs,each,x,g,h} — so the largest single population of ruby statements had no rows at
-- all, exactly the condition part A removed for `if`/`while`/`case`/`begin`.
-- ★ AND `x` WAS A USE. The block parameter is the THIRD phantom free variable this ticket
-- found, after the collection-loop variable and the exception variable: a read of a name
-- nothing defines, which liveness, reaching and narrowing all believe.
--
-- ★ MODELLED AS A PRE-CONDITION LOOP, WHICH IS THE ONE SOUND CHOICE FOR ALL THREE USES.
-- A block is a loop body for `each` (0..n times), a once-runner for `tap`, and a DEFERRED
-- body for `lambda`. A plain region would claim exactly-once, which is UNSOUND for `each` —
-- the same way a missing back edge was for js for-of. Pre-condition covers all three: the
-- zero-trip skip admits "never ran", the back edge admits "ran many times". A method ->
-- semantics table (each=loop, tap=once, lambda=deferred) is the PRECISION refinement and
-- belongs in a profile, not in the base model, where a wrong entry would be unsound.
--
-- ★ `block` IS IN EIGHT GRAMMARS — go java lua odin python ruby rust zig, checked via
-- language.inspect — AND IN LUA IT IS THE REGION CONTAINER ITSELF. So this can only ever
-- live in the spec. A base entry would have re-modelled seven other languages' bodies as
-- ruby blocks. `do_block`/`block_body`/`body_statement`/`block_parameters` are ruby-only.
M.spec.ruby.ctrl['do_block'] = true
M.spec.ruby.ctrl['block'] = true
M.spec.ruby.preloop['do_block'] = true
M.spec.ruby.preloop['block'] = true
-- the two block body containers. `body_statement` is also a METHOD's body, which is reached
-- through fn_body's `body` FIELD and region()'s named-children walk — neither consults this
-- set — and `begin` hangs its statements DIRECTLY (verified by parse), so adding it here
-- moves nothing but the block case.
M.spec.ruby.body['body_statement'] = true
M.spec.ruby.body['block_body'] = true
-- ★ THE FIFTH CLASS: <attached block type> -> <field holding its binder list>. A MAP because
-- the field is needed anyway (the head's defs are read off it) and a sibling key would be a
-- drift pair — the same argument that made `ctrl` a role map. flow's du stops at these
-- UNCONDITIONALLY and hands them back, because a block can hang off a call ANYWHERE in the
-- statement (`q = xs.map { … }` puts it under an assignment's RHS), so no field on the ROW's
-- own node can find it.
M.spec.ruby.blocks = { do_block = 'parameters', block = 'parameters' }
M.spec.typescript.regime = M.spec.javascript.regime
-- TS-ONLY declarations (interface/enum) — added to the typescript spec ALONE:
-- these node types don't exist in the JS grammar, so they can't live in the
-- shared `functions` query (it must compile under both). Routed to handle_iface
-- via the @tsiface/@tsenum catch-all capture (defn+cat, no @name → the
-- handle_iface branch of the dispatch), which mints a browse-only TYPE node +
-- its members. Concatenated into `combined` through the `interface` slot.
M.spec.typescript.interface = [=[
    (interface_declaration name: (type_identifier) @tsiface) @def
    (enum_declaration name: (identifier) @tsenum) @def
    (type_alias_declaration name: (type_identifier) @tstype) @def
    (internal_module name: (identifier) @tsns) @def
]=]
-- CLASS INHERITANCE (pivot B2) → data.extends → resolve_super. The two grammars
-- shape `extends` DIFFERENTLY, so each spec gets its own query: JS's class_heritage
-- holds the superclass expression DIRECTLY; TS wraps it in an extends_clause. A
-- dotted superclass (`extends ns.Base`) captures the member_expression's PROPERTY
-- (the bare `Base` a class node is keyed by), so handle_super's name matches.
-- A mixin-call superclass (`extends mix(Base)`) is deliberately NOT captured —
-- not statically a named class. (class name = identifier in JS, type_identifier
-- in TS.) implements/interface-extends are set-valued → the resolve_interface
-- linker's territory, not this single-parent extends map.
M.spec.javascript.super_query = [=[
    (class_declaration name: (identifier) @child
        (class_heritage (identifier) @parent))
    (class_declaration name: (identifier) @child
        (class_heritage (member_expression property: (property_identifier) @parent)))
]=]
M.spec.typescript.super_query = [=[
    (class_declaration name: (type_identifier) @child
        (class_heritage (extends_clause (identifier) @parent)))
    (class_declaration name: (type_identifier) @child
        (class_heritage (extends_clause
            (member_expression property: (property_identifier) @parent))))
]=]
-- CLASS FIELD-ARROWS: `class C { m = () => {} }` / `private m = async () => {}` —
-- a field whose value is a function is a method in all but grammar (React class
-- components + services define handlers this way, called via this.m()). Keyed
-- `C.m` (qualify unwraps the field def to class_body), so B3 this-typing resolves
-- them. Per-grammar: JS field_definition `property:`, TS public_field_definition
-- `name:` (the query for one doesn't compile under the other → separate slots).
M.spec.javascript.fields = [=[
    (field_definition property: (property_identifier) @name value: (arrow_function) @def)
    (field_definition property: (property_identifier) @name value: (function_expression) @def)
]=]
M.spec.typescript.fields = [=[
    (public_field_definition name: (property_identifier) @name value: (arrow_function) @def)
    (public_field_definition name: (property_identifier) @name value: (function_expression) @def)
]=]
-- .tsx (React TS): the tsx grammar is typescript + JSX, so the typescript spec
-- (all its queries/hooks) applies verbatim under another PARSER — the same
-- "TS is the JS family under another grammar" move as typescript. Cloned AFTER
-- typescript's interface/super_query are set so tsx inherits them; exts override
-- to {tsx}. elang_for folds tsx → the javascript family (so .tsx↔.ts↔.js↔.jsx are
-- one resolution language); parse_lang_for keeps the tsx grammar for parsing.
M.spec.tsx = vim.tbl_extend('force', {}, M.spec.typescript)
M.spec.tsx.exts = { 'tsx' }
M.spec.rust.regime = { let_declaration = 'block' }
M.spec.c.regime = { declaration = 'block' }
M.spec.cpp.regime = { declaration = 'block' }
M.spec.java.regime = { local_variable_declaration = 'block' }
M.spec.go.regime = { short_var_declaration = 'block', var_declaration = 'block' }

local LIT_DEPTH, LIT_ITEMS, NAME_CAP = 6, 64, 48

-- ── helpers ──────────────────────────────────────────────────────────────────


local function pos_of(n)
    local sr, sc, er, ec = n:range()
    return { start = { line = sr, char = sc }, ['end'] = { line = er, char = ec } }
end

local function cap_node(ns)
    if type(ns) == 'table' and ns[1] ~= nil then return ns[#ns] end
    return ns
end

-- The raw-parser rider (fusion Stage C): the extract hot loop parses via
-- a REUSED raw TSParser per language — LanguageTree construction
-- (injection scanning, a per-file object graph) measured ~16% of parse
-- cost, and extraction queries only ever visit the host tree. Containers
-- keep LanguageTree (injections ARE their content); anything raw can't
-- serve falls back to it. Trees are immutable: reusing one parser across
-- files is safe, earlier trees stay valid while referenced.
local RAW_PARSERS = {} -- lang -> TSParser | false (raw unavailable)
local function raw_parse(lang, src)
    local p = RAW_PARSERS[lang]
    if p == nil then
        p = false
        if vim._create_ts_parser then
            local ok, added = pcall(vim.treesitter.language.add, lang)
            if ok and added then
                local okc, np = pcall(vim._create_ts_parser, lang)
                if okc then p = np end
            end
        end
        RAW_PARSERS[lang] = p
    end
    if not p then return nil end
    local ok, tree = pcall(p.parse, p, nil, src)
    if ok then return tree end
    return nil
end

local QUERY_ERRORS = {}
local function parse_query(lang, q)
    if not q then return nil end -- the spec doesn't define this concept
    local ok, query = pcall(vim.treesitter.query.parse, lang, q)
    if not ok then
        -- a broken query must be LOUD: silently emitting nothing for a
        -- whole language looks like an empty project
        local key = lang .. '\31' .. q:sub(1, 40)
        if not QUERY_ERRORS[key] then
            QUERY_ERRORS[key] = true
            vim.notify(('cartograph/treesitter: %s query failed: %s')
                :format(lang, tostring(query):match('[^\n]*')), vim.log.levels.WARN)
        end
        return nil
    end
    return query
end

local DEFAULT_FN_TYPES = { function_definition = true, function_declaration = true }

--- Which node types bound a FUNCTION SCOPE in `lang` — the one answer to
--- "which function encloses this node?", which four modules used to answer
--- from four private tables (CART-0306).
---
--- ★ AN EMPTY DECLARED SET IS A REFUSAL, NOT AN UNSET FIELD. `spec.fn_types = {}`
--- is scheme saying it cannot answer from node types at all (its function node is
--- `list`, the same type as every s-expression). It must stay empty rather than
--- fall through to the two names below, neither of which exists in that grammar —
--- the fallback would answer nil everywhere and read as "this file has no
--- functions". `{}` is truthy in lua so `or` happens to work today; the explicit
--- nil test is here so that stays true if a spec ever declares `false`.
--- @param lang string
--- @return table<string, true>
function M.fn_types(lang)
    local s = M.spec[lang]
    if s and s.fn_types ~= nil then return s.fn_types end
    return DEFAULT_FN_TYPES
end

-- ★★ THE SECOND SET, AND CONFLATING IT WITH THE FIRST IS A SOUNDNESS BUG.
-- "Which function encloses this node?" (fn_types, above) and "where does the flow
-- walk STOP?" are different questions, because a flow stop is only sound at a node
-- type whose interior gets its OWN flow record. Stop at a type the extractor never
-- mints and the rows are not relocated to a better owner — they are DELETED.
-- Absence rendered as silence, this time inside the walk (CART-0308).
--
-- MEASURED, by threading fn_types straight through and reading dfgate: go 30 ->
-- 1772 divergences (`func_literal` is a scope but go's `functions` query captures
-- only function_declaration/method_declaration, so every closure body in the corpus
-- was orphaned), python 3 -> 66 (`lambda`), ruby and rust likewise. Confirmed
-- against the QUERIES, not a sample — a type absent from a 120-file sample may
-- still be minted; a type absent from the query never is.
--
-- LEGACY is the union flow carried before this change. It is kept WHOLE and
-- deliberately: it already stopped at unminted types for cpp/java (`lambda_
-- expression`) and php (`anonymous_function`, `arrow_function`), so that orphaning
-- is PRE-EXISTING and pinned into every dfparity census. Removing those is a real
-- fix and a separate one — folding it in here would double the blast radius and
-- confound the recalibration. This change only stops making it worse.
local LEGACY_FN_STOP = { function_definition = true, function_declaration = true,
    method_declaration = true, anonymous_function = true, arrow_function = true,
    lambda_expression = true, constructor_declaration = true }

--- Where flow's walk stops descending: every LEGACY stop, plus the language's own
--- scope types MINUS the ones it declares it does not mint (`fn_unminted`).
---
--- ★ `fn_unminted` MEANS "NOT *ALWAYS* MINTED", and the distinction is not pedantic.
--- A type minted in only SOME syntactic positions is unsound as a stop, because the
--- other positions get no node to receive the rows. js `function_expression` is the
--- case: minted as a declarator/pair value, an argument, or an assignment right —
--- and NOT as an IIFE head, which is the shape jquery and ghost are built out of.
--- Listing it costs the pre-existing over-collection into the enclosing function;
--- omitting it cost 21420 deleted rows on ghost alone. When in doubt, list it: the
--- failure modes are not symmetric.
--- @param lang string
--- @return table<string, true>
function M.flow_stop(lang)
    local s = M.spec[lang]
    local unminted = (s and s.fn_unminted) or {}
    local out = {}
    for t in pairs(LEGACY_FN_STOP) do out[t] = true end
    for t in pairs(M.fn_types(lang)) do
        if not unminted[t] then out[t] = true end
    end
    return out
end

-- `memo` (optional, PER TREE — node ids alias across trees) caches the
-- answer at every ancestor visited: call sites in the same function stop
-- one level up instead of re-walking to the root each time.
local IF_PATH = {} -- scratch: ids visited this walk (single-threaded)
-- UNCONDITIONAL TOP-LEVEL? a def node is a module-load statement that runs
-- exactly once, in load order, iff its AST ancestry reaches the chunk root
-- without passing through a `block` — every conditional/loop/function body (and
-- a `do…end`) introduces a block, so any of them makes the def guarded/nested,
-- NOT a load-order sibling. Consumed by resolve_reassign (the reassignment-
-- override / value-flow resolver): a slot whose defs are all top-level HAS a
-- last-write winner; a branch-selected def (DebugLib `if nLog then … else …`)
-- does NOT, and must never redirect. Conservative: `do`-blocks read as guarded
-- (sound — we skip a rare unconditional case rather than risk a false winner).
local function toplevel_def(defn)
    local a = defn:parent()
    while a do
        local t = a:type()
        if t == 'block' then return false end
        if t == 'chunk' then return true end
        a = a:parent()
    end
    return false
end

local function in_function(n, spec, memo)
    local types = spec and spec.fn_types or DEFAULT_FN_TYPES
    local p = n:parent()
    if not memo then
        while p do
            if types[p:type()] then return p end
            p = p:parent()
        end
        return nil
    end
    local np = 0
    while p do
        local id = p:id()
        local hit = memo[id]
        if hit == nil and types[p:type()] then hit = p end
        if hit ~= nil then
            for i = 1, np do memo[IF_PATH[i]] = hit end
            memo[id] = hit
            return hit or nil
        end
        np = np + 1
        IF_PATH[np] = id
        p = p:parent()
    end
    for i = 1, np do memo[IF_PATH[i]] = false end
    return nil
end

-- literal data, the lua-ls litdata contract: strings/numbers/booleans,
-- {ref='name'} for identifiers, {expr='...'} frontiers for the rest,
-- nested tables recurse (mixed array+hash stringifies integer keys)
local function litval(n, src, spec, depth)
    local t = n:type()
    if t == 'string' or t == 'string_literal' then
        local txt = node_text(n, src)
        return (txt:gsub('^["\'%[=]+', ''):gsub('["\'%]=]+$', ''))
    end
    if t == 'number' or t == 'number_literal' or t == 'integer' or t == 'float' then
        return tonumber(node_text(n, src)) or node_text(n, src)
    end
    if t == 'true' then return true end
    if t == 'false' then return false end
    if t == 'identifier' or t == 'dot_index_expression' or t == 'field_expression'
        or t == 'attribute' or t == 'dotted_name' then
        return { ref = node_text(n, src) }
    end
    if t == 'function_definition' or t == 'lambda' then return { expr = 'function' } end
    if t == 'function_call' or t == 'call_expression' or t == 'call' then
        return { expr = node_text(n, src):gsub('%s+', ' '):sub(1, NAME_CAP) }
    end
    if (spec.litdata_types or {})[t] and depth < LIT_DEPTH then
        local arr, map, count = {}, {}, 0
        for _, item in inext, n, -1 do
            if item:named() and not tsutil.is_comment(item) then
                count = count + 1
                if count > LIT_ITEMS then break end
                local it = item:type()
                if it == 'initializer_pair' then
                    -- C designated initializer: .field = value
                    local des = item:field('designator')
                    local vf = item:field('value')[1]
                    local v = vf and litval(vf, src, spec, depth + 1)
                    local k = des and des[1]
                        and node_text(des[1], src):gsub('^[%.%[]', ''):gsub('%]$', '')
                    if k and v ~= nil then
                        map[k] = v
                    elseif v ~= nil then
                        arr[#arr + 1] = v
                    end
                elseif it == 'array_element_initializer' then
                    -- php: positional children; 2 = key => value, 1 = element
                    local kids = {}
                    for _, c2 in inext, item, -1 do
                        if c2:named() and not tsutil.is_comment(c2) then kids[#kids + 1] = c2 end
                    end
                    local v = kids[#kids] and litval(kids[#kids], src, spec, depth + 1)
                    if #kids >= 2 and v ~= nil then
                        local k = node_text(kids[1], src):gsub('^["\']', ''):gsub('["\']$', '')
                        map[k] = v
                    elseif v ~= nil then
                        arr[#arr + 1] = v
                    end
                elseif it == 'field' or it == 'pair' then
                    local kf = item:field('name')[1] or item:field('key')[1]
                    local vf = item:field('value')[1]
                    local v = vf and litval(vf, src, spec, depth + 1)
                    if kf and v ~= nil then
                        local k = node_text(kf, src):gsub('^["\']', ''):gsub('["\']$', '')
                        map[k] = v
                    elseif not kf and v ~= nil then
                        arr[#arr + 1] = v
                    end
                else
                    local v = litval(item, src, spec, depth + 1)
                    arr[#arr + 1] = v ~= nil and v or { expr = '?' }
                end
            end
        end
        local hasA, hasM = #arr > 0, next(map) ~= nil
        if hasA and hasM then
            for i, v in ipairs(arr) do map[tostring(i)] = v end
            return map
        end
        if hasA then return arr end
        return map
    end
    return nil
end

-- a callable ARGUMENT shape, classified at parse time (they are free
-- here; recovering them later means re-reading source):
--   [obj, 'method'] / array($o, 'm')  -> the string names the method
--   &Class::method (possibly inside a Bind-style wrapper call)
local function callable_arg(a, src)
    local t = a:type()
    if t == 'array_creation_expression' or t == 'array' then
        local els = {}
        for _, el in inext, a, -1 do
            if el:named() and not tsutil.is_comment(el) then
                -- @langs-ok php `array_element_initializer` — php's array-literal element wrapper
                if el:type() == 'array_element_initializer' then
                    el = el:named_child(0) or el
                end
                els[#els + 1] = el
            end
        end
        local last = els[#els]
        if #els >= 2 and last and last:type():find('string') then
            return node_text(last, src):gsub('^["\']', ''):gsub('["\']$', '')
        end
        return nil
    end
    if t == 'pointer_expression' or t == 'call_expression' then
        local found
        local function hunt(n, depth)
            if found or depth > 4 then return end
            -- @langs-ok cpp `qualified_identifier` / `pointer_expression` — C++ name+deref shapes
            if n:type() == 'qualified_identifier'
                and n:parent() and n:parent():type() == 'pointer_expression' then
                found = node_text(n, src)
                return
            end
            for _, c in inext, n, -1 do
                if c:named() then hunt(c, depth + 1) end
            end
        end
        hunt(a, 0)
        return found
    end
    return nil
end

-- in-function LOCAL binding names (const/let/var, INCLUDING destructuring), for
-- the local-shadow gate: a bare callee bound locally must not name-match a global
-- (the local shadows it — Promise reject/resolve params are handled by fn.params;
-- this covers `const [x, setX] = useState()` hook setters etc. that df does not
-- track for the JS family). Opt-in via spec.local_decls; walks the body but STOPS
-- at nested fns (their bindings are their own scope, not this one's).
local function fn_locals(def, spec, src)
    if not spec.local_decls then return nil end
    local body = spec.body_field and def:field(spec.body_field)[1]
    local out, seen = {}, {}
    local function add(id)
        local t = node_text(id, src)
        if t ~= '' and not seen[t] then seen[t] = true; out[#out + 1] = t end
    end
    local function binding_ids(n) -- identifier leaves of a binding pattern
        local t = n:type()
        if t == 'identifier' or t == 'shorthand_property_identifier_pattern' then add(n)
        else
            for _, c in inext, n, -1 do
                if c:named() then binding_ids(c) end
            end
        end
    end
    local function walk(n)
        for _, c in inext, n, -1 do
            if c:named() then
                local ct = c:type()
                if spec.fn_types[ct] then -- nested fn: its own scope
                elseif spec.local_decls[ct] then
                    for _, d in inext, c, -1 do
                        -- @langs-ok java/js `variable_declarator` — those grammars wrap a declared name
                        if d:type() == 'variable_declarator' then
                            local nm = d:field('name')[1]
                            if nm then binding_ids(nm) end
                        end
                    end
                else walk(c) end
            end
        end
    end
    if body then walk(body) end
    -- DESTRUCTURED params (`({onFocus}) =>`, `([a,b]) =>`) bind local names too —
    -- and unlike a POSITIONAL identifier param (which may be an AMD `define(…,
    -- function(dep){})` dep whose global name-match is correct), a destructured
    -- param is NEVER an AMD dep → unambiguously local, safe to gate. Positional
    -- identifier params stay in node.params (fn_params, ungated).
    local ps = spec.params_field and def:field(spec.params_field)[1]
    if ps then
        for _, c in inext, ps, -1 do
            local ct = c:type()
            if ct == 'object_pattern' or ct == 'array_pattern' then
                binding_ids(c)
            elseif ct == 'required_parameter' or ct == 'optional_parameter' then
                for _, pc in inext, c, -1 do -- TS wraps the pattern
                    local pt = pc:type()
                    if pt == 'object_pattern' or pt == 'array_pattern' then binding_ids(pc) end
                end
            end
        end
    end
    return #out > 0 and out or nil
end

local function fn_params(def, spec, src, method)
    -- ★ `params_of` IS THE POSITIONAL TWIN OF `params_field`, and this reader did not consult
    -- it while flow's `param_names` did (CART-0438). A hook honoured by ONE of its two
    -- readers is worse than no hook: odin's flow got its parameters and its NODES did not,
    -- and nothing said so.
    local ps = (spec.params_field and def:field(spec.params_field)[1])
        or (spec.params_of and spec.params_of(def))
    local out = method and { 'self' } or {}
    if ps then
        for _, c in inext, ps, -1 do
            -- @langs-ok the per-language PARAM-NAME chain: each arm names the grammar it serves (`variable` scheme, `variable_name` php, `pointer_declarator` c/cpp) and the arms together cover the roster
            if c:type() == 'identifier' or c:type() == 'variable' then
                out[#out + 1] = node_text(c, src)
            -- @langs-ok same param-name chain (php/bash $var)
            elseif c:type() == 'variable_name' then -- php $param
                out[#out + 1] = node_text(c, src):gsub('^%$', '')
            elseif c:named() then -- c parameter_declaration / defaulted params
                for _, id in inext, c, -1 do
                    -- @langs-ok same param-name chain
                    if id:type() == 'identifier' then
                        out[#out + 1] = node_text(id, src)
                        break
                    end
                    -- @langs-ok same param-name chain (php $param)
                    if id:type() == 'variable_name' then
                        out[#out + 1] = node_text(id, src):gsub('^%$', '')
                        break
                    end
                    -- @langs-ok same param-name chain (c/cpp pointer declarator)
                    if id:type() == 'pointer_declarator' then
                        local inner = id:field('declarator')[1]
                        -- @langs-ok same param-name chain (c/cpp pointer declarator inner name)
                        if inner and inner:type() == 'identifier' then
                            out[#out + 1] = node_text(inner, src)
                        end
                        break
                    end
                end
            end
        end
    end
    return #out > 0 and out or nil
end

-- ── extraction ───────────────────────────────────────────────────────────────

-- ★★ WHAT `.h` MEANS IS A PROPERTY OF THE TREE, NOT OF THE EXTENSION (CART-0410).
-- spec/c.lua claims `.h` and spec/cpp.lua claims only .hpp/.hh/.hxx — so every C++
-- project that names its headers `.h`, which is most of them, had every header parsed
-- with the C grammar. `class Foo { … }` is not a syntax error in C: `class Foo` reads
-- as type + declarator and the body reads as its compound_statement, so THE WHOLE
-- CLASS BECOMES ONE function_definition and every method prototype inside it resolves
-- to that one node, inheriting the class's field list as its own statement rows.
-- MEASURED on 7kaa: ~3700 fabricated `function` nodes across 189 headers, and the
-- expression census counted one class's rows 25.8 times over.
--
-- ★ AND UNCONDITIONAL `.h → cpp` IS A NO-GO, MEASURED, NOT ASSUMED. Def nodes in `.h`
-- files, same corpus, two processes:
--     openfirmware (pure C)  2196 → 2050   (-232 real decls, +86 mostly garbage)
--     gforth       (pure C)  6189 → 6157
--     7kaa         (C++)     5634 → 2514   (the fabrication leaving)
-- The C++ grammar loses real declarations on real C headers — a run of file-scope
-- `int curcol;` swallowed after one construct puts the parser in an error state.
--
-- So the rule is REPO SHAPE: a tree containing any C++ source names its headers C++,
-- and a pure-C tree pays nothing because it never triggers. Decided ONCE from the full
-- file list, which is also why it is not derived per-file or per-shard — a shard
-- holding only `include/` sees no `.cpp` and would answer C for a C++ repo.
local CXX_SRC = { cpp = true, cc = true, cxx = true, hpp = true, hh = true, hxx = true }
local H_LANG = 'c' -- until a tree says otherwise; `.h` stays in c.exts as the default

-- the two by-EXTENSION memos, declared here because set_h_lang below must clear them
-- (their own commentary lives at their original definition sites further down)
local EXT_ELANG = {} -- ext -> { lang|false, spec|false }
local EXT_PLANG = {} -- ext -> lang|false

--- The language `.h` means for a tree, from its FULL file list. Pure — the caller
--- decides when to ask, so a worker can be handed the parent's answer instead.
function M.h_lang_for(files)
    for _, f in ipairs(files or {}) do
        local e = f:match('%.([%w]+)$')
        if e and CXX_SRC[e:lower()] then return 'cpp' end
    end
    return 'c'
end

--- Adopt a tree's answer. ★ THIS IS THE ONE THING THAT MAKES THE BY-EXTENSION MEMOS
--- STALE, so it is the one thing that clears them — see the note above EXT_ELANG.
function M.set_h_lang(v)
    v = (v == 'cpp') and 'cpp' or 'c'
    if v ~= H_LANG then
        H_LANG = v
        EXT_ELANG['h'], EXT_PLANG['h'] = nil, nil
    end
    return H_LANG
end

function M.h_lang() return H_LANG end

-- ★★ THE QUESTION SPLITS IN TWO, AND CONFLATING THEM WAS A BUG (CART-0412).
-- "which spec claims this EXTENSION" depends on nothing but the extension and is
-- worth caching. "does this spec DISCLAIM this particular FILE" depends on the whole
-- filename and must be asked every time. They used to be one function behind one
-- by-extension memo, which meant the first `.php` file resolved decided for every
-- `.blade.php` after it AND VICE VERSA — restoring CART-0347's fabrication in one
-- direction, blanking every real php file in the other, picked by walk order.
--
-- ★ THE RULE THIS ENCODES: a cache key must be as fine as the answer. Staleness was
-- never the risk here — the registry really is static — and the old comment argued
-- exactly that, about the wrong thing.
local EXT_BASE = {} -- ext -> { lang|false, spec|false, disclaim|false }
local function base_for(ext)
    local hit = EXT_BASE[ext]
    if hit then return hit[1] or nil, hit[2] or nil, hit[3] or nil end
    local lang, spec
    for l, s in pairs(M.spec) do
        for _, e in ipairs(s.exts) do
            if e == ext then lang, spec = l, s; break end
        end
        if lang then break end
    end
    EXT_BASE[ext] = { lang or false, spec or false,
        (spec and spec.ext_disclaim) or false }
    return lang, spec, spec and spec.ext_disclaim or nil
end

--- ★ A SPEC MAY DISCLAIM A COMPOUND SUFFIX THAT REUSES ITS EXTENSION (CART-0347).
--- `x.blade.php` ends in `.php`, so the registry claimed 96 Laravel templates per
--- grocy — and the php grammar does NOT error on them: a blade file has no `<?php`
--- tag, so the whole thing parses as inline text, `has_error=false`, one named child.
--- Valid php, semantically empty. What came out was 192 FABRICATED NODES (a module +
--- a region per file) named after template directives — `region
--- @extends('layout.default')` — and ZERO of the 1608 calls those templates contain.
--- Refusing the file is the honest answer: we do not have a blade grammar, and parsing
--- a template as its host language invents structure rather than finding it.
--- PER FILE, NEVER MEMOIZED BY EXTENSION — that is the whole of CART-0412.
local function disclaims(file, discl)
    for _, d in ipairs(discl or {}) do
        if file:sub(-#d - 1) == '.' .. d then return true end
    end
    return false
end

local function lang_for(file)
    local ext = file:match('%.([%w]+)$')
    if not ext then return nil end
    -- the repo-shape override, ahead of the registry scan (see above). No spec
    -- disclaims `.h`, so nothing is skipped by taking this early exit.
    if ext == 'h' then return H_LANG, M.spec[H_LANG] end
    local lang, spec, discl = base_for(ext)
    if not lang or disclaims(file, discl) then return nil end
    return lang, spec
end

-- container files: one FILE, several language regions (vue/svelte SFCs).
-- The container grammar's injection queries yield host-language trees at
-- ABSOLUTE positions, so extraction runs the host spec over each region
-- with no offset arithmetic anywhere.
local CONTAINERS = { vue = 'vue', svelte = 'svelte' }

local function container_for(file)
    local ext = file:match('%.([%w]+)$')
    return ext and CONTAINERS[ext] or nil
end

-- effective language: what governs a file's RESOLUTION semantics (the
-- never-cross-languages gate, stdlib vocabulary, scope hook). Containers
-- resolve as their host; typescript IS the javascript spec under another
-- parser — so js/ts/vue/svelte collapse to ONE family, the way TS
-- legally imports JS (allowJs) and SFC scripts import both.
-- memoized by EXTENSION: elang_for runs once per call site during
-- resolution (87k on server), and lang_for underneath is a spec-registry
-- scan.
--
-- ★ THE OLD CLAIM HERE — "the registry is static, so the memo cannot go stale" — was
-- true about the REGISTRY and is the wrong question. What matters is whether the KEY
-- is as fine as the ANSWER, and twice it has not been:
--   · `.h` depends on the TREE, not the extension (CART-0410). `set_h_lang` is the
--     single writer and clears this memo and EXT_PLANG when the answer changes.
--   · `ext_disclaim` depends on the FULL FILENAME — `x.php` and `v.blade.php` share
--     the key `php` and must NOT share the answer (CART-0412). So what is cached is
--     the by-extension half only, WITH the disclaim list; the per-file test runs on
--     every call, hit or miss. Cheap: a handful of suffix compares against a list
--     that is empty for every language but php.
-- (declared above, next to set_h_lang, so the writer can reach it)
local function elang_for(file)
    local ext = file:match('%.([%w]+)$') or ''
    local hit = EXT_ELANG[ext]
    if hit then
        if disclaims(file, hit[3] or nil) then return nil end
        return hit[1] or nil, hit[2] or nil
    end
    local lang, spec, discl
    if CONTAINERS[ext] then
        lang, spec = 'javascript', M.spec.javascript
    elseif ext == 'h' then
        lang, spec = H_LANG, M.spec[H_LANG]
    else
        -- base_for, NOT lang_for: the memo must hold the UNDISCLAIMED answer, or the
        -- first `.blade.php` seen would cache `nil` for every `.php` behind it —
        -- which is the bug this structure exists to make unrepresentable.
        lang, spec, discl = base_for(ext)
        -- typescript AND tsx fold to the javascript RESOLUTION family + spec (one
        -- language across .js/.jsx/.ts/.tsx); the real PARSER differs per file
        -- (parse_lang_for keeps typescript/tsx). .jsx is already 'javascript'.
        if lang == 'typescript' or lang == 'tsx' then
            lang, spec = 'javascript', M.spec.javascript
        end
    end
    EXT_ELANG[ext] = { lang or false, spec or false, discl or false }
    if disclaims(file, discl) then return nil end
    return lang, spec
end

-- the GRAMMAR to parse a file with. elang_for collapses typescript→javascript
-- for the resolution FAMILY + spec (so .ts and .js resolve as ONE language —
-- the way TS legally imports JS under allowJs, and the never-cross gate must
-- treat a .ts↔.js edge as same-family). The PARSER must NOT collapse: TS
-- syntax (annotations, interfaces, generics) ERRORS OUT under the JS grammar,
-- blanking every on-demand re-parse lens (forms/detail/lens flow). So the
-- resolution lang is javascript but the parse grammar stays typescript — the
-- "TS is the JS spec under another PARSER" the elang_for comment describes.
-- Extraction (lang_for, not elang_for) already parses .ts under typescript;
-- this is the analysis-side counterpart. Containers keep elang_for's host
-- grammar (their region trees are JS). Memoized by extension like elang_for —
-- EXT_PLANG is declared next to set_h_lang, which is its invalidator.
-- Same two-halves structure as elang_for (CART-0412): the memo holds the
-- UNDISCLAIMED by-extension answer plus the disclaim list; the per-file suffix test
-- runs on every call. A blade template must refuse here too — this is the entry point
-- every on-demand RE-PARSE uses (lens, forms, optimize, expr), which is precisely
-- where the loss direction of that bug was live.
local function parse_lang_for(file)
    local ext = file:match('%.([%w]+)$') or ''
    local hit = EXT_PLANG[ext]
    if hit then
        if disclaims(file, hit[2] or nil) then return nil end
        return hit[1] or nil
    end
    local plang, discl
    if CONTAINERS[ext] then
        plang = 'javascript'
    elseif ext == 'h' then
        plang = H_LANG
    else
        -- base_for, not lang_for: cache the undisclaimed answer (see elang_for)
        plang, _, discl = base_for(ext) -- the REAL registered grammar (typescript for .ts)
    end
    EXT_PLANG[ext] = { plang or false, discl or false }
    if disclaims(file, discl) then return nil end
    return plang
end

-- Transitive superclass resolution. `parent::m()` where the DIRECT parent
-- only INHERITS m (no exact `Parent::m` def) tail-refuses across every
-- class's m; walk the `extends` chain (data.extends: bare child->parent
-- names) to the nearest ancestor that actually DEFINES m. Sound for single
-- inheritance (php/java): if nothing between the two overrides m, the
-- inherited m IS that ancestor's. Runs as an enrichment over the fully
-- built graph, not the hot resolve loop, and is BOUNDED by a step limit +
-- cycle guard so a deep or malformed hierarchy can never walk away.
local SUPER_STEP_LIMIT = 32
local function build_super(extends)
    local super = {}
    for _, e in ipairs(extends or {}) do
        local prev = super[e.child]
        if prev == nil then super[e.child] = e.parent
        elseif prev ~= e.parent then super[e.child] = false end -- name collision
    end
    return super
end

-- member in class C: own defs (`:` then `.`), else walk the extends `super`
-- chain; unique fit or nil. Shared by resolve_self (self:m) and
-- resolve_local_ctor (obj:m) — the receiver-typing chain resolver.
--- `file` + `scope_of` are OPTIONAL and additive: omit them and this behaves exactly as it
--- always did (any corpus-wide duplicate = give up). Pass them and a duplicate falls back
--- to the SCOPE LADDER the main resolver already walks — same file, then same scope.
---
--- WHY (CART-0241, measured on wow): a corpus of addons VENDORS its libraries, so
--- `AceConfigDialog:GetStatusTable` exists 24 times, once per addon. `dup` then refused all
--- 24 when the answer is obviously the copy in the calling file. 298 `self:m()` calls were
--- unresolved for exactly that reason — 184 whose enclosing method has no call site at all
--- (so the lexical V3 stage below was eligible and only its LOOKUP missed) and 114 where
--- call-site typing had already determined the class and stage (2) then found nothing.
--- The other 83 stay unresolved BY DESIGN: their enclosing method is demonstrably called on
--- a different receiver, which is evidence that self is NOT the owner.
local function chain_lookup(super, exact, C, member, clang, file, scope_of)
    local seen, cur = {}, C
    for _ = 1, SUPER_STEP_LIMIT do
        for _, sep in ipairs({ ':', '.' }) do
            local fit, dup
            local same, sscope, nsame, nscope = nil, nil, 0, 0
            local sc = file and scope_of and scope_of(file)
            for _, nd in ipairs(exact[cur .. sep .. member] or {}) do
                if elang_for(nd.file) == clang then
                    if fit and fit.id ~= nd.id then dup = true else fit = nd end
                    if file and nd.file == file then nsame = nsame + 1; same = nd end
                    if sc ~= nil and scope_of(nd.file) == sc then
                        nscope = nscope + 1; sscope = nd
                    end
                end
            end
            if dup then
                if nsame == 1 then return same end
                if nscope == 1 then return sscope end
                return nil
            end
            if fit then return fit end
        end
        local par = super[cur]
        if not par or seen[par] then break end
        seen[par] = true; cur = par
    end
    return nil
end

-- parent_fn[id] = innermost ENCLOSING fn node — precomputed ONCE (stack over
-- range-sorted fns, O(n log n)) so an enclosing-chain walk is a parent-link chase
-- (O(nesting depth)), NOT an O(fns-in-file) scan per call (quadratic on minified
-- JS). Shared by the B3 this-typing arrow-walk, the local-shadow gate, and
-- resolve_local_callable. range is a TABLE at extract but a PACKED NUMBER after
-- store.ingest (relink path) — read via atr, which handles both.
local function build_parent_fn(node_index)
    local parent_fn, byfile = {}, {}
    for _, node in pairs(node_index) do
        if (node.kind == 'function' or node.kind == 'method')
            and node.file and node.range then
            local l = byfile[node.file]; if not l then l = {}; byfile[node.file] = l end
            l[#l + 1] = node
        end
    end
    for _, fns in pairs(byfile) do
        -- STRICT weak ordering (a<b and b<a must never both hold, else table.sort
        -- garbles the array → inverted parents): asc start, OUTER (later end)
        -- first, id as a stable tiebreak.
        table.sort(fns, function (a, b)
            local asl, bsl = atr.sl(a.range), atr.sl(b.range)
            if asl ~= bsl then return asl < bsl end
            local asc, bsc = atr.sc(a.range), atr.sc(b.range)
            if asc ~= bsc then return asc < bsc end
            local ael, bel = atr.el(a.range), atr.el(b.range)
            if ael ~= bel then return ael > bel end
            local aec, bec = atr.ec(a.range), atr.ec(b.range)
            if aec ~= bec then return aec > bec end
            return a.id < b.id
        end)
        local function le(fr, gr) -- f is inside g iff f.start <= g.end
            local fl, gl = atr.sl(fr), atr.el(gr)
            if fl ~= gl then return fl < gl end
            return atr.sc(fr) <= atr.ec(gr)
        end
        local stack = {}
        for _, f in ipairs(fns) do
            while #stack > 0 and not le(f.range, stack[#stack].range) do
                stack[#stack] = nil
            end
            if #stack > 0 then parent_fn[f.id] = stack[#stack] end
            stack[#stack + 1] = f
        end
    end
    return parent_fn
end
-- Upgrade still-refused `Head::method` calls in place (addref + inferred);
-- returns how many resolved. `exact` and `addref` come from whichever pass
-- calls this (extract or relink) so it reads the CURRENT full node set.
local function resolve_super(cv, extends, exact, addref, node_index)
    if not (extends and extends[1]) then return 0 end
    local super = build_super(extends)
    local cget, cset = cv.get, cv.set
    local n = 0
    for i = 1, cv.n do
        local crefused, cfull = cget(i, 'refused'), cget(i, 'full')
        if not cget(i, 'to') and crefused and crefused.cands and cfull then
            -- separator is language-relative: `::` (php/java), `:`/`.` (lua
            -- colon/dot methods). Captured so the ancestor lookup key reuses the
            -- SAME separator the def keys and this call use — one path, all langs.
            local head, sep, method = cfull:match('^([%w_]+)([:.]+)([%w_]+)$')
            local cfn = cget(i, 'fn')
            -- `super.m()` (JS/TS): the receiver IS the enclosing class's parent.
            -- Rewrite head to the enclosing class (from the call's fn owner) so
            -- the SAME ancestor walk resolves it — super[owner] is the parent,
            -- and the loop then finds parent.m up the chain. Sound: `super`
            -- unambiguously names the lexical parent; skip if the enclosing fn
            -- isn't a class method (e.g. a nested callback → owner underivable).
            if head == 'super' then
                local fn = node_index and cfn and node_index[cfn]
                head = fn and fn.name and fn.name:match('^(.+)[.:][%w_]+$') or nil
            end
            if head and sep and super[head] then
                local clang = elang_for(cget(i, 'file'))
                local seen, cur, target = { [head] = true }, head, nil
                for _ = 1, SUPER_STEP_LIMIT do
                    local par = super[cur]
                    if not par or seen[par] then break end -- top of chain / cycle
                    seen[par] = true
                    local cands = exact[par .. sep .. method]
                    if cands then
                        local fit, dup = nil, false
                        for _, node in ipairs(cands) do
                            if elang_for(node.file) == clang then
                                if fit then dup = true else fit = node end
                            end
                        end
                        if dup then break end -- ambiguous where defined: refuse
                        if fit then target = fit; break end
                    end
                    cur = par
                end
                if target then
                    cset(i, 'to', target.id)
                    cset(i, 'inferred', true)
                    cset(i, 'refused', nil)
                    if cfn then
                        local cline = cget(i, 'line')
                        addref(cfn, target.id, cget(i, 'at')
                            or { start = { line = cline, char = 0 },
                                ['end'] = { line = cline, char = 0 } }, true)
                    end
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- Find the def of `cls<sep>method`, separator-generic (`::` java/php,
-- `:`/`.` lua): cls's OWN def first, else walk its superclass `super` chain to
-- the nearest ancestor that defines it. Unique language-fitting node or nil
-- (ambiguous-where-defined → nil, refuse). Mirrors resolve_super's walk but
-- starts AT cls (checks cls itself), so an impl that defines the method
-- directly resolves without a chain.
local function find_def(cls, sep, method, super, exact, clang)
    local seen, cur = {}, cls
    for _ = 1, SUPER_STEP_LIMIT do
        local cands = exact[cur .. sep .. method]
        if cands then
            local fit, dup = nil, false
            for _, nd in ipairs(cands) do
                if elang_for(nd.file) == clang then
                    if fit and fit.id ~= nd.id then dup = true else fit = nd end
                end
            end
            if dup then return nil end
            if fit then return fit end
        end
        local par = super[cur]
        if not par or seen[par] then break end
        seen[par] = true; cur = par
    end
    return nil
end

-- Interface→impl DI resolution (F1 — [[cartograph-linker]]'s first Java kind,
-- SET-valued). A call lands on an interface's ABSTRACT method `I::m` (the stub
-- exact-matches the receiver's declared interface type — the edge "stubbed at
-- the service boundary"). If exactly ONE @stereotype bean class implements I
-- (directly or through I's super-interfaces), REDIRECT the call to that impl's
-- concrete `C::m` — the only dispatch target an @Autowired receiver can hold.
-- Linker set semantics: singleton → resolve (inferred ~, since reflection/
-- manual instantiation could differ); >1 → leave at the interface (honest
-- polymorphic frontier) UNLESS the receiver field carries a @Qualifier that
-- names one of the impls (bean name = explicit @Service("x") or the
-- decapitalized class name) → narrow to it; 0 → leave (no-impl frontier).
--
-- TWO SOUNDNESS GATES select the candidate implementer set — do NOT drop
-- either to "generalize" to plain Java (counting all named implementers is
-- UNSOUND: a functional interface has one named impl but many anonymous/lambda
-- impls that `implements` never captures → a false "unique"):
--   (1) BEAN gate (Spring @Autowired): candidates = @stereotype implementers.
--       An injected receiver holds the bean, so "unique bean impl" is the real
--       dispatch target. @Qualifier narrows an ambiguous set by bean name.
--   (2) SERVICE-MARKER gate (a service-locator idiom like metasfresh's
--       `Services.get(IFoo.class)`): when the interface transitively extends a
--       MARKER (ISingletonService/…), candidates = ALL implementers. Sound
--       here precisely because a marked service interface is FAT (many methods,
--       so no lambda impls) and single-impl by convention; the receiver is the
--       registered singleton. The marker is the certificate that lifts the
--       "no lambdas" assumption the bean gate gets from @stereotype.
-- Both: singleton → resolve (~inferred); >1 → leave at the interface (honest
-- polymorphic frontier); 0 → leave (no-impl frontier). Simple-name keyed, so a
-- cross-package name COLLISION stays refused. No markers present (e.g. plain
-- non-Spring Java) → gate (2) is inert, behaviour is exactly the bean gate —
-- verified: `gate libs` (elasticsearch) stays identical. Bounded like
-- resolve_super by the step limit + cycle guard.
local function resolve_interface(cv, implements, beans, extends, exact, addref, markers)
    if not (implements and implements[1]) then return 0 end
    beans = beans or {}; markers = markers or {}
    local super = build_super(extends)
    local allimpls, beanimpls = {}, {} -- iface -> { [class]=true }
    local ifext = {} -- iface(child) -> { parent iface, ... } : child extends parent
    local function add(map, iface, cls)
        local s = map[iface]; if not s then s = {}; map[iface] = s end
        s[cls] = true
    end
    for _, e in ipairs(implements) do
        if e.cintf then
            local l = ifext[e.child]; if not l then l = {}; ifext[e.child] = l end
            l[#l + 1] = e.iface
        else
            add(allimpls, e.iface, e.child)
            if beans[e.child] then add(beanimpls, e.iface, e.child) end
        end
    end
    -- SERVICE TYPES: interfaces transitively extending a marker (fixpoint over
    -- the interface-extends edges, seeded by the marker set)
    local svc = {}
    for _ = 1, SUPER_STEP_LIMIT do
        local changed = false
        for child, parents in pairs(ifext) do
            if not svc[child] then
                for _, p in ipairs(parents) do
                    if markers[p] or svc[p] then svc[child] = true; changed = true; break end
                end
            end
        end
        if not changed then break end
    end
    -- push each interface's members up its extends chain (I extends J ⟹ J's
    -- impls include I's) to a fixpoint, for both maps; bounded rounds
    for _ = 1, SUPER_STEP_LIMIT do
        local changed = false
        for child, parents in pairs(ifext) do
            for _, p in ipairs(parents) do
                for _, map in ipairs({ allimpls, beanimpls }) do
                    if map[child] then
                        for cls in pairs(map[child]) do
                            if not (map[p] and map[p][cls]) then
                                add(map, p, cls); changed = true
                            end
                        end
                    end
                end
            end
        end
        if not changed then break end
    end
    local cget, cset = cv.get, cv.set
    local n = 0
    for i = 1, cv.n do
        local cfull = cget(i, 'full')
        if cfull then
            local head, sep, method = cfull:match('^([%w_]+)([:.]+)([%w_]+)$')
            -- a service-marked interface draws from ALL implementers; otherwise
            -- only @stereotype beans are candidates
            local set = head and (svc[head] and allimpls[head] or beanimpls[head])
            if set then
                local only, cnt = nil, 0
                for cls in pairs(set) do cnt = cnt + 1; only = cls end
                -- @Qualifier narrows an ambiguous set to the named bean: the
                -- impl whose bean name (explicit @Service("x"), else the
                -- decapitalized class name) matches the receiver's qualifier
                local cqual = cget(i, 'qualifier')
                if cnt > 1 and cqual then
                    for cls in pairs(set) do
                        local bn = beans[cls]
                        local name = (type(bn) == 'string' and bn)
                            or (cls:sub(1, 1):lower() .. cls:sub(2))
                        if name == cqual then only = cls; cnt = 1; break end
                    end
                end
                if cnt == 1 then
                    local target = find_def(only, sep, method, super, exact,
                        elang_for(cget(i, 'file')))
                    if target and target.id ~= cget(i, 'to') then
                        cset(i, 'to', target.id)
                        cset(i, 'inferred', true)
                        cset(i, 'refused', nil)
                        local cfn = cget(i, 'fn')
                        if cfn then
                            local cline = cget(i, 'line')
                            addref(cfn, target.id, cget(i, 'at')
                                or { start = { line = cline, char = 0 },
                                    ['end'] = { line = cline, char = 0 } }, true)
                        end
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

--- Does a candidate def's own name AGREE with the RECEIVER PATH of a call name?
--- `def` agrees with `call` when def's whole dotted name is a suffix of call's at a
--- separator boundary AND carries a qualifier of its own — so for a call
--- `jQuery.find.attr`, the candidate `find.attr` agrees (its receiver `find` is right
--- there in the call) while a bare `attr` does not (it says nothing about a receiver)
--- and `Expr.attr` disagrees.
---
--- WHY ONLY MULTI-SEGMENT: a BARE candidate is neutral, never agreeing. Treating a bare
--- `m` as agreeing with `R.m` is the rule that looks obvious and is wrong — it would
--- make a free function outrank a method for every receiver call in every corpus (a
--- `foo.bar()` whose receiver type we do not know is far more likely to be `Class.bar`
--- than a bare `bar`). Deciding THAT needs the receiver's TYPE, which is receiver typing
--- ([[cartograph-local-type-inference]]: shipped for zig, measured-low for the dynamic
--- languages). This predicate deliberately answers only the part a NAME can settle.
local function recv_agrees(call, defname)
    if not defname or #defname >= #call then return false end
    -- the candidate must name a receiver of its own; a bare name is neutral
    if not defname:find('[%.:>#]') then return false end
    if call:sub(-#defname) ~= defname then return false end
    local sep = call:sub(-#defname - 1, -#defname - 1)
    return sep == '.' or sep == ':' or sep == '>' or sep == '#'
end

--- The UNIQUE fn/method named `key` defined in `file` — the shared question behind two
--- passes that both had it subtly wrong. Returns (fit, dup).
---
--- Both wrote `tail[key] or exact[key]`, which selects an index by whether the tail list
--- is empty ANYWHERE IN THE CORPUS, not by whether it answers HERE. So the moment any
--- file defines `<anything>.key`, a module's own BARE `key` becomes unreachable:
--- MEASURED on jquery, `jQuery.error(…)` resolved to a foreign `find.error` because
--- core.js's bare `error` sat in `exact` while `tail` was non-empty — and the correction
--- resolve_module_alias exists to make could not fire.
---
--- FALLBACK, not union: consult `tail` first and `exact` only when tail answered nothing
--- in this file. A union would also change answers the old code got right — zig files
--- hold both `Config.resolve` and a bare `resolve`, and merging the two sets makes a
--- previously-unique fit ambiguous.
---
--- NOTE FOR ANYONE EDITING THIS: do NOT write `for _, l in ipairs({ tail[k], exact[k] })`.
--- ipairs STOPS AT THE FIRST NIL, so a nil tail list (the common case — a bare-named def
--- is not tail-indexed) skips the exact index too. That hole cost module_alias 845 of its
--- 1054 fills on zig, and I mis-attributed the loss to a pipeline cascade before finding
--- it. The lists are named explicitly here for exactly that reason.
local function fit_in_file(tail, exact, key, file)
    local function scan(list)
        local fit, dup = nil, false
        for _, nd in ipairs(list or {}) do
            if nd.file == file and (nd.kind == 'function' or nd.kind == 'method') then
                if fit and fit.id ~= nd.id then dup = true else fit = nd end
            end
        end
        return fit, dup
    end
    local fit, dup = scan(tail[key])
    if fit then return fit, dup end
    return scan(exact[key])
end

-- ── FIELD-ALIAS RESOLUTION (CART-0237) ────────────────────────────────────────────
-- `local make_recipe = data_util.make_recipe` … then 226 bare `make_recipe{…}` calls.
-- resolve_module_alias above answers `alias.member()`; this answers the case where the
-- MEMBER itself was bound to a local and the call is BARE. Same evidence class — an
-- explicit binding in the caller's own file — and the same authority: a binding beats any
-- corpus-wide name match ([[cartograph-linker]] layer 1).
--
-- WHY IT MATTERS: before this, those calls name-matched to whatever unique `make_recipe`
-- the corpus happened to hold — SE's private `local function make_recipe` in
-- arcosphere.lua, 226 phantom edges — and once CART-0230 refused that, they resolved to
-- nothing while the answer sat on line 3 of every caller.
--
-- MEASURED, before -> after (a textual pre-count of the same shape as the check)
--   factorio   242 unresolved -> 10,   43 already-correct -> 275
--   self       121 unresolved ->  1,   33 already-correct -> 155  (our own
--              `local node_text = tsutil.node_text` idiom, 122 calls)
--   desynced     0 — it has no require-based module aliasing at all
-- ZERO corrections anywhere, so this is purely additive coverage, not a rewrite stage.
--
-- MODULE-LEVEL ALIASES ONLY, and that is a soundness boundary rather than a gap to close
-- later: handle_var (where the alias is recorded) is gated on `not in_function`, so a
-- `local add_fn = data_util.tech_add_…` written INSIDE a function is never collected. It
-- must not be: this map is keyed by FILE, and a function-local binding is visible only in
-- its own function, so applying it file-wide would resolve calls that never saw it. The
-- residual above (10 on factorio, 1 on self) is exactly those, left unclaimed on purpose.
--
-- SOUNDNESS: gated on (1) an explicit require BINDING for the receiver in this file,
-- (2) a SINGLE binding of the local (n > 1 = rebound = dropped, the ctorbinds
-- discipline — which is also what stops a same-named local elsewhere in the file from
-- being mistaken for the alias), and (3) a UNIQUE fn with that member name in the bound
-- module's file. Any of the three missing → no edge.
--
-- The tier is `inferred` to MATCH resolve_module_alias, which resolves on the same
-- evidence. CART-0237 argued for exact; whether a binding-derived edge should outrank a
-- name match is a real question, but it must be decided for BOTH passes at once, not
-- introduced as a silent difference between two siblings.
local function resolve_field_alias(cv, edges, exact, tail, addref, node_index, faliases)
    if not (faliases and next(faliases)) then return 0 end
    local amap = {} -- file -> { require-alias -> module file }
    for _, e in ipairs(edges or {}) do
        if e.kind == 'import' and e.bind and e.from and e.to then
            local m = amap[e.from]; if not m then m = {}; amap[e.from] = m end
            m[e.bind] = e.to
        end
    end
    if not next(amap) then return 0 end
    local cget, cset = cv.get, cv.set
    local n = 0
    for i = 1, cv.n do
        do
            local cfile = cget(i, 'file')
            local fa = cfile and faliases[cfile]
            local callee = fa and tostring(cget(i, 'callee') or '')
            local b = callee and fa[callee]
            -- BARE call only: a dotted/method form is resolve_module_alias's job, and a
            -- `full` carrying a receiver means this local was not the callee.
            local cfull = b and cget(i, 'full')
            if b and b.n == 1 and not (cfull and tostring(cfull):find('[%.:]')) then
                local mod = amap[cfile] and amap[cfile][b.recv]
                local fit, dup = nil, false
                if mod then fit, dup = fit_in_file(tail, exact, b.member, mod) end
                -- FILL an unresolved call, OR CORRECT one that landed OUTSIDE the bound
                -- module — the binding is authoritative, exactly as in
                -- resolve_module_alias. Needed for more than symmetry: a same-named
                -- private helper in a THIRD file that escapes its file (so CART-0230
                -- cannot refuse it) is a live name-match competitor, and without the
                -- override the phantom wins over the binding written in the caller.
                local cto = cget(i, 'to')
                local cur = cto and node_index and node_index[cto]
                local foreign = cur ~= nil and cur.file ~= mod
                if fit and not dup and fit.id ~= cto and (not cto or foreign) then
                    cset(i, 'to', fit.id)
                    -- NOT `inferred`. The ladder's own label for that flag is
                    -- "inferred (~ unique name)", and the name is exactly what this
                    -- resolution did NOT use — the caller's own binding line names the
                    -- module member. Marking it `~` also made swallowed-type fire on every
                    -- one of these (MEASURED +156 findings on our own tree) telling the
                    -- user their receiver type was laundered, when the type is written on
                    -- line 3 of the file. resolve_module_alias DOES mark its (same-
                    -- evidence) resolutions `~`; that looks like the same mislabel, but it
                    -- is a calibrated pass with its own count, so it gets its own ticket
                    -- and its own measurement rather than a silent change here.
                    cset(i, 'inferred', nil)
                    cset(i, 'refused', nil)
                    cset(i, 'ext', nil)
                    local cfn = cget(i, 'fn')
                    if cfn then
                        local cline = cget(i, 'line')
                        -- 4th arg nil: I marked the CALL unhedged in 019ad4b but left the
                        -- EDGE `~`, so the two disagreed about the same resolution
                        -- (CART-0244 found it while auditing module_alias's tier)
                        addref(cfn, fit.id, cget(i, 'at')
                            or { start = { line = cline, char = 0 },
                                 ['end'] = { line = cline, char = 0 } }, nil)
                    end
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- Upgrade still-refused MODULE-ALIAS calls: `alias.member(...)` where `alias` is
-- bound to require('mod') in this file (the import edge's `bind`) → mod's `member`
-- export. The receiver's module is KNOWN, so the ambiguous tail (`get`/`has`/…)
-- narrows to the unique fn/method defined in that module file. This is RUNG-1
-- receiver resolution ([[cartograph-scope-model]]) — require-alias, VM-INDEPENDENT
-- — wiring the import edges + the tail index, no new analysis. Marked inferred
-- (~): a derived resolution via the alias binding (a single-assignment/reaching
-- check would promote it, and rule out reassigned aliases — banked). Lua-only
-- today (only lua's spec captures import_bind); js/php import forms come later.
local function resolve_module_alias(cv, edges, exact, tail, addref, node_index, unparsed)
    -- files that are KNOWN but never PARSED (bundle / missing grammar / UNAVAILABLE
    -- read). THREADED, not derived from node_index: in the extract driver the
    -- frontier module nodes are appended AFTER the resolution pipeline runs, so
    -- deriving them here saw an empty set and a call into a bundle stayed disposed
    -- `external` — the bug this parameter exists to fix. Each driver supplies it
    -- from whatever it has at that moment (extract: its in-flight roster; relink:
    -- data.unparsed), and resolveparity is what holds the two honest.
    local unread = {}
    for _, f in ipairs(unparsed or {}) do unread[f] = true end
    for _, n in pairs(node_index or {}) do
        if n.unparsed and n.file then unread[n.file] = true end
    end
    local amap = {} -- file -> { alias -> module-file }, from require binds
    for _, e in ipairs(edges or {}) do
        if e.kind == 'import' and e.bind and e.from and e.to then
            local m = amap[e.from]; if not m then m = {}; amap[e.from] = m end
            m[e.bind] = e.to
        end
    end
    if not next(amap) then return 0 end
    local cget, cset = cv.get, cv.set
    local n = 0
    for i = 1, cv.n do
        -- a require-alias `recv` (a SINGLE segment before member — not an a.b.c chain).
        -- BINDING beats corpus name-match ([[cartograph-linker]] layer 1): `git.m` where
        -- git=require("M") means M's export m, INDEPENDENT of what other files name their
        -- locals. So resolve — or CORRECT a resolution that landed OUTSIDE M — to M's OWN
        -- def, whenever M's file uniquely defines m. This kills the class where a FOREIGN
        -- file's `alias.m = …` (a test mock / monkey-patch of the imported module) wrongly
        -- wins over the module's real export. Re-exports (M lacks its own m → no fit) and
        -- extensions (m added elsewhere, not in M → no fit) are untouched: no override fires.
        do
            local cfull, cfile = cget(i, 'full'), cget(i, 'file')
            local recv, member = nil, nil
            if cfull then recv, member = cfull:match('^([%w_]+)[.:]([%w_]+)$') end
            -- fallback: the receiver preserved separately (zig field calls key
            -- only the member into `full`, but recv_local kept the object) — so
            -- a lowercase alias `bar.run()` is still recognized here.
            local crecv, ccallee = cget(i, 'recv'), cget(i, 'callee')
            if not recv and crecv and ccallee then
                recv, member = crecv, ccallee
            end
            local mod = recv and amap[cfile] and amap[cfile][recv]
            if mod then
                -- the UNIQUE fn/method with this tail defined in the alias's module
                local fit, dup = fit_in_file(tail, exact, member, mod)
                local cto = cget(i, 'to')
                -- NO fit, and the bound module is a file we never read: the
                -- disposition the main resolver left (`no-def`, i.e. external =
                -- "the project boundary") is a claim it cannot support. We know
                -- exactly which file would answer. Say UNREAD instead. Narrow by
                -- construction: it needs an explicit import BINDING plus an
                -- unparsed target, so a corpus full of bundles does not become one
                -- big frontier — only calls actually aimed INTO a bundle do. Not
                -- counted as a resolution (it resolves nothing); the pass's return
                -- stays the number of calls it actually linked.
                if not fit and not cto and unread[mod] then
                    cset(i, 'ext', EXT.unread)
                end
                if fit and not dup and fit.id ~= cto then
                    -- fill an UNRESOLVED call (refused-with-candidates, or a
                    -- clean exact-only refusal that leaves no refusal record —
                    -- zig's `Foo.method` typed key), OR correct a FOREIGN
                    -- resolution (current target outside M) to M's own export.
                    -- In-module resolutions are left alone. Sound: gated on a
                    -- UNIQUE fit in the bound module (the binding is authoritative).
                    local cur = cto and node_index and node_index[cto]
                    local foreign = cur ~= nil and cur.file ~= mod
                    if not cto or foreign then
                        cset(i, 'to', fit.id)
                        -- NOT hedged (CART-0244). The `inferred` flag means "resolved by
                        -- unique NAME" — the ladder's own label is "inferred (~ unique
                        -- name)" and its complement is called `matched`/`linked` by census,
                        -- graphdiff and the ladder. This resolution used no corpus-wide
                        -- name: the require BINDING pins the file, the CALL names the
                        -- member, and fit_in_file requires it to be unique inside that
                        -- file. MEASURED on the `self` corpus (the whole repo): all 1775
                        -- module_alias resolutions carried the ~, and they were 26.6% of
                        -- the calls feeding swallowed-type — a quarter of that lint's
                        -- population telling the user to annotate a type that
                        -- `local m = require 'x'` already states. Unhedging it drops
                        -- swallowed-type from 1986 to 1748 on lua/ (dogfood's corpus) and
                        -- moves 219 edges from ~inferred to matched; resolution% does not
                        -- move, because these are the SAME edges. resolve_field_alias (the
                        -- `local f = m.field` sibling) was already unhedged; the two agree
                        -- now, on the call flag AND the edge flag.
                        cset(i, 'inferred', nil)
                        cset(i, 'refused', nil)
                        local cfn = cget(i, 'fn')
                        if cfn then
                            local cline = cget(i, 'line')
                            -- 4th arg nil: the EDGE is unhedged too, matching the call
                            -- flag above (CART-0244)
                            addref(cfn, fit.id, cget(i, 'at')
                                or { start = { line = cline, char = 0 },
                                    ['end'] = { line = cline, char = 0 } }, nil)
                        end
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

-- MULTI-LEVEL CHAIN TYPE ([[cartograph-zig-arc]]): a chained call
-- `root.Type.method()` names its method in the PascalCase segment right before
-- it (c.chainty — a TYPE namespace, e.g. `link.File.open` → File). ADDITIVE and
-- unresolved-only: same-file chains already resolve via the bare-tail path, so
-- this only fills chains the tail LEFT UNRESOLVED (cross-file: bare `open` is
-- ambiguous, but `File.open` is unique). Sound — the type is explicit in the
-- source, keyed exact, and filled only on a UNIQUE fit (else left refused,
-- honest). Instance chains (`l.field.method`, lowercase penult) carry no
-- chainty → untouched (they need struct field-type inference, a separate arc).
local function resolve_chain_type(cv, exact, addref, node_index)
    local cget, cset = cv.get, cv.set
    local n = 0
    for i = 1, cv.n do
        local cchainty, ccallee = cget(i, 'chainty'), cget(i, 'callee')
        if not cget(i, 'to') and cchainty and ccallee then
            local key = cchainty .. '.' .. ccallee
            local fit, dup = nil, false
            for _, nd in ipairs(exact[key] or {}) do
                if nd.kind == 'function' or nd.kind == 'method' then
                    if fit and fit.id ~= nd.id then dup = true else fit = nd end
                end
            end
            if fit and not dup then
                cset(i, 'to', fit.id)
                cset(i, 'inferred', true)
                cset(i, 'refused', nil)
                local cfn = cget(i, 'fn')
                if cfn then
                    local cline = cget(i, 'line')
                    addref(cfn, fit.id, cget(i, 'at')
                        or { start = { line = cline, char = 0 },
                            ['end'] = { line = cline, char = 0 } }, true)
                end
                n = n + 1
            end
        end
    end
    return n
end

-- Std-alias DISPOSITION ([[cartograph-stdlib-profile]] bucket A): a call whose
-- ROOT name is bound to the standard library in its file (`const assert =
-- std.debug.assert; assert()` / `const mem = std.mem; mem.eql()`) is a stdlib
-- call — the const binding is authoritative and shadows any project def of the
-- same leaf. Sets c.ext = std-alias AND reconstructs the CANONICAL symbol into
-- c.stdpath (the mint pass turns that into a real resolution). Relabels an
-- UNRESOLVED call (c.to == nil, whether a bare no-def OR a refused-with-cands
-- name collision). Runs LAST so it only speaks for what every resolver left
-- unresolved. Self-evidencing: needs no active profile and no curated free-set
-- (the soundness gap that reverted the profile's type-precise free-match face).
local function resolve_std_alias(cv, stdaliases)
    if not stdaliases or not next(stdaliases) then return 0 end
    local cget, cset = cv.get, cv.set
    local n = 0
    for i = 1, cv.n do
        if not cget(i, 'to') then
            local cfile, ccallee = cget(i, 'file'), cget(i, 'callee')
            local paths = stdaliases[cfile]
            -- bare call: recv is nil, the name is the callee; receiver call:
            -- the chain root is the receiver (recv = single-id `mem.eql`,
            -- recvroot = deep chain `std.mem.eql` → "std"). Either way key the
            -- ROOT (never the member) — `x.assert()` where x is a project alias
            -- must NOT fire just because `assert` is elsewhere std-bound.
            local crecv, crecvroot = cget(i, 'recv'), cget(i, 'recvroot')
            local root = crecv or crecvroot or ccallee
            local base = paths and root and paths[root]
            if base then
                cset(i, 'refused', nil)
                cset(i, 'ext', EXT.stdalias)
                -- CANONICAL symbol: alias-path(root) ++ (receiver-chain minus
                -- root) ++ "." ++ callee. A bare call (no receiver) IS the
                -- aliased callable → the base path itself.
                local crecvpath = cget(i, 'recvpath')
                if crecvpath and crecvpath:sub(1, #root) == root then
                    cset(i, 'stdpath', base .. crecvpath:sub(#root + 1) .. '.' .. ccallee)
                elseif crecv then
                    cset(i, 'stdpath', base .. '.' .. ccallee)
                else
                    cset(i, 'stdpath', base)
                end
                n = n + 1
            end
        end
    end
    return n
end

-- MINT the stdlib RESOLUTION face ([[cartograph-stdlib-profile]]): turn the
-- std-alias disposition (c.stdpath) into a real RESOLUTION — one synthetic
-- EXTERNAL node per canonical std symbol, the call resolved to it and its ref
-- edge stamped the `stdlib` tier ([[cartograph-tier]]) so census/LSP treat it as
-- resolved-but-external (go-to-def / hover target a real node; no local def =
-- honest frontier). GLOBAL + IDEMPOTENT: runs once on the assembled graph
-- (post-merge / post-idpass) and again on relink, reusing minted nodes/edges
-- keyed by the canonical path — so re-runs and inline-vs-parallel agree (the
-- node id is a deterministic function of the symbol). Never touches a call that
-- already resolved to a project def (guarded by `not c.to`, which stdpath calls
-- are by construction).
-- generic external-node minting CORE, shared by the zig std-alias face and the
-- L2 profile face. `pathfor(cget, i)` returns call i's canonical external symbol
-- (or nil to skip); scheme/file namespace the minted nodes so distinct sources
-- (zig-std vs ruby-rails vs …) never collide. GLOBAL + IDEMPOTENT (reuses nodes/
-- edges keyed by path), guarded by `not c.to` (never clobbers a project def).
local function mint_nodes(data, node_index, scheme, file, pathfor)
    -- INDEX-FORM over the columnar store when the parent holds one, else records
    -- (the record-fold PEAK path — relink runs fully columnar with no records)
    local cv = require('cartograph.callview').of(data)
    local cget, cset = cv.get, cv.set
    -- reuse existing minted nodes (idempotent re-run) keyed by canonical path
    local bypath = {}
    for _, nd in ipairs(data.nodes) do
        if nd.external and nd.file == file then bypath[nd.name] = nd end
    end
    -- existing stdlib ref edges: from\31to → edge (dedup + append occurrences)
    local refkey = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' and e.stdlib then refkey[e.from .. '\31' .. e.to] = e end
    end
    local resolved, minted = 0, 0
    for i = 1, cv.n do
        local path = (not cget(i, 'to')) and pathfor(cget, i)
        if path then
            local nd = bypath[path]
            if not nd then
                nd = { id = scheme .. path, name = path,
                    kind = 'external', file = file, external = true, order = -1,
                    range = { start = { line = 0, char = 0 },
                        ['end'] = { line = 0, char = 0 } } }
                data.nodes[#data.nodes + 1] = nd
                bypath[path] = nd
                if node_index then node_index[nd.id] = nd end
                minted = minted + 1
            end
            cset(i, 'to', nd.id)
            cset(i, 'ext', nil)
            cset(i, 'refused', nil)
            cset(i, 'prov', 'stdlib') -- the by_prov axis: minted external resolution
            resolved = resolved + 1
            local cfn = cget(i, 'fn')
            if cfn then
                local k = cfn .. '\31' .. nd.id
                local e = refkey[k]
                if not e then
                    e = { from = cfn, to = nd.id, kind = 'ref', at = {}, stdlib = true }
                    refkey[k] = e
                    data.edges[#data.edges + 1] = e
                end
                local cline = cget(i, 'line')
                e.at[#e.at + 1] = cget(i, 'at') or { start = { line = cline, char = 0 },
                    ['end'] = { line = cline, char = 0 } }
            end
        end
    end
    return resolved, minted
end
local STD_FILE = 'zig-std'          -- synthetic file of a minted std node
local STD_SCHEME = 'zig-std::'      -- deterministic id prefix (symbol-keyed)
local function mint_std_nodes(data, node_index)
    return mint_nodes(data, node_index, STD_SCHEME, STD_FILE,
        function (cget, i) return cget(i, 'stdpath') end)
end
M.mint_std_nodes = mint_std_nodes

-- PROFILE resolution face ([[cartograph-stdlib-profile]]): promote the L2 profile
-- DISPOSITION (c.ext why='stdlib', set by prof_ext at the no-def fallback) into a
-- real resolution — mint one `<runtime>::<callee>` external node per framework
-- method, resolved at the `stdlib` tier so LSP def/hover target a node. OPT-IN per
-- profile (`profile.mint`) so a disposition-only profile (lua-factorio) stays gate-
-- neutral. The disposition already language-scoped the calls (prof_ext fires only
-- for profile.lang files) and left c.to nil, so this never shadows a project def.
local function mint_profile_nodes(data, node_index, profile)
    local canon = profile.canon or {}
    -- a profile MAY supply its own receiver-aware mapper (factorio: a
    -- `<global>.<method>` call → the documented `Class::method`, read from c.full);
    -- when present it OWNS the mint decision. Otherwise the default member-canon
    -- path applies (ruby: dispatch-by-member-name → canonical `Owner#member`).
    local mint_path = profile.mint_path
    return mint_nodes(data, node_index, profile.runtime .. '::', profile.runtime,
        function (cget, i)
            local e = cget(i, 'ext')
            if type(e) ~= 'table' then return nil end
            local callee = cget(i, 'callee')
            if not callee then return nil end
            if mint_path then return mint_path(callee, cget(i, 'full'), e.why) end
            -- prof_ext disposition (no-def framework method the profile covers):
            -- OWNER-PRECISE canonical `Owner#member` path, else the bare name.
            if e.why == 'stdlib' then return canon[callee] or callee end
            -- stdlib_names VOCAB: a DECLARED framework name (base ruby + rails pack —
            -- e.g. the primary AR verbs find/where/save/create dispatched to vocab
            -- before prof_ext). Mint it too, but ONLY when the profile knows its owner
            -- (canon) — so generic domain-name vocab (name/id/value) that isn't a
            -- curated profile method stays unminted, not over-claimed at the tier.
            if e.why == 'vocab' and canon[callee] then return canon[callee] end
            return nil
        end)
end
M.mint_profile_nodes = mint_profile_nodes

-- INSTANCE-CHAIN FIELD TYPING ([[cartograph-zig-arc]]): an instance chain
-- `root.field.method()` resolves when the root's TYPE is known (c.chainroot, a
-- param type from extraction) AND that type's FIELD has a keyable type
-- (data.fieldtypes). FILE-BOUND, not bare-name: the field's type name is bound
-- to a specific FILE — (A) an @import alias in the field-declaring file (`strtab:
-- StringTable` where `const StringTable = @import("../StringTable.zig")` → that
-- file), else (B) a same-file local `const T = struct` (the type has a method in
-- the field's own file) — and the method is resolved as the UNIQUE fn/method IN
-- THAT FILE. Bare-name exact[ftype.method] is UNSOUND: same-named types collide
-- across subsystems (measured 25% wrong — MachO's StringTable is `link/`, not the
-- unrelated mingw one). Binding to a file (resolve_module_alias's posture) kills
-- that. ADDITIVE, unresolved-only. The bulk of instance chains stay unresolved —
-- their root is a local (needs local type inference) or the field is a generic/
-- builtin (needs generics modelling).
local function resolve_field_chain(cv, fieldtypes, edges, exact, tail, addref, node_index)
    if not (fieldtypes and fieldtypes[1]) then return 0 end
    -- field map: typename -> field -> {ftype, file} (cross-file conflict on one
    -- typename.field → false = ambiguous → skip)
    local fm = {}
    for _, f in ipairs(fieldtypes) do
        local t = fm[f.typename]; if not t then t = {}; fm[f.typename] = t end
        if t[f.field] == nil then t[f.field] = { ftype = f.ftype, file = f.file }
        elseif t[f.field] and t[f.field].ftype ~= f.ftype then t[f.field] = false end
    end
    -- import alias map: file -> alias -> target file (the @import binding)
    local amap = {}
    for _, e in ipairs(edges or {}) do
        if e.kind == 'import' and e.bind and e.from and e.to then
            amap[e.from] = amap[e.from] or {}; amap[e.from][e.bind] = e.to
        end
    end
    -- typefiles: type name -> set of files defining a method of it (`T.m` keys),
    -- for the same-file-local binding
    local typefiles = {}
    for key, nds in pairs(exact) do
        local ty = key:match('^([%w_]+)%.[%w_]+$')
        if ty then
            for _, nd in ipairs(nds) do
                if nd.kind == 'function' or nd.kind == 'method' then
                    typefiles[ty] = typefiles[ty] or {}; typefiles[ty][nd.file] = true
                end
            end
        end
    end
    local cget, cset = cv.get, cv.set
    local n = 0
    for i = 1, cv.n do
        local cchainroot, cchainfield, ccallee =
            cget(i, 'chainroot'), cget(i, 'chainfield'), cget(i, 'callee')
        if not cget(i, 'to') and cchainroot and cchainfield and ccallee then
            local byfield = fm[cchainroot]
            local fe = byfield and byfield[cchainfield]
            if fe then -- (false = ambiguous → skip)
                -- bind the field's TYPE to a file, then resolve the method there
                local tfile = amap[fe.file] and amap[fe.file][fe.ftype] -- (A) @import
                if not tfile and typefiles[fe.ftype] and typefiles[fe.ftype][fe.file] then
                    tfile = fe.file -- (B) same-file local type
                end
                if tfile then
                    local fit, dup = fit_in_file(tail, exact, ccallee, tfile)
                    if fit and not dup then
                        cset(i, 'to', fit.id)
                        cset(i, 'inferred', true)
                        cset(i, 'refused', nil)
                        local cfn = cget(i, 'fn')
                        if cfn then
                            local cline = cget(i, 'line')
                            addref(cfn, fit.id, cget(i, 'at')
                                or { start = { line = cline, char = 0 },
                                    ['end'] = { line = cline, char = 0 } }, true)
                        end
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

-- REASSIGNMENT-OVERRIDE (value-flow resolution, [[cartograph-linker]] /
-- [[graph-vm-type-resolution]]): a table slot `Owner.field` written by SEVERAL
-- unconditional top-level defs is, at runtime, the LAST write in load order —
-- the monkey-patch idiom `function T:m() … end; T.m = function(self) … end` calls
-- the reassignment, not the colon-def. A call name-matched to a NON-last def of
-- such a slot is REDIRECTED to the last (value-flow beats the separator/first-def
-- name-match, generalizing v55's binding-beats-name-match). SOUND-GATED on
-- node.top: fires ONLY when every participating def is an unconditional load-order
-- sibling. A branch-selected slot (`if nLog then function kit:Debug … else … end`,
-- the measured-dominant real case) has NO load-order winner and is left exactly as
-- name-matched — no false redirect. Slot unifies `:`/`.` (T:m and T.m are one slot).
-- Same-file only (the winner is keyed by file): a cross-file "override" is not a
-- load-order fact. The redirect is marked inferred (~) — it is an inference.
local function resolve_reassign(cv, node_index, addref)
    local function slot_of(name)
        local owner, _, field = name:match('^(.+)([:.])([%w_]+)$')
        return owner and (owner .. '.' .. field) or nil
    end
    -- bucket top-level fn/method defs by (file, slot); a bucket with >=2 defs has
    -- a winner = the max-order (last-in-load) def.
    local byslot = {}
    for _, nd in pairs(node_index) do
        if nd.top and (nd.kind == 'function' or nd.kind == 'method') then
            local slot = slot_of(nd.name)
            if slot then
                local k = (nd.file or '?') .. '\31' .. slot
                byslot[k] = byslot[k] or {}
                byslot[k][#byslot[k] + 1] = nd
            end
        end
    end
    local winner = {}
    for k, defs in pairs(byslot) do
        if #defs >= 2 then
            local last = defs[1]
            for i = 2, #defs do
                if (defs[i].order or 0) > (last.order or 0) then last = defs[i] end
            end
            winner[k] = last
        end
    end
    if not next(winner) then return 0 end
    local cget, cset = cv.get, cv.set
    local n = 0
    for i = 1, cv.n do
        local cto = cget(i, 'to')
        local tn = cto and node_index[cto]
        if tn and tn.top and (tn.kind == 'function' or tn.kind == 'method') then
            local slot = slot_of(tn.name)
            local w = slot and winner[(tn.file or '?') .. '\31' .. slot]
            if w and w.id ~= cto then
                cset(i, 'to', w.id)
                cset(i, 'inferred', true)
                local cfn = cget(i, 'fn')
                if cfn then
                    local cline = cget(i, 'line')
                    addref(cfn, w.id, cget(i, 'at')
                        or { start = { line = cline, char = 0 },
                            ['end'] = { line = cline, char = 0 } }, true)
                end
                n = n + 1
            end
        end
    end
    return n
end

-- STRING-KEYED REGISTRY (the linker kind; the read-dual of `reg` edges,
-- [[cartograph-linker]] stage 3). A retrieval keyed by a string literal resolves
-- to the value REGISTERED under that key, WITHIN the same sharing scope — a WoW
-- addon bundles its own library copies, so LibStub("AceAddon-3.0") in addon A
-- binds to A's OWN AceAddon (same .toc scope); a key with no in-scope registration
-- stays unresolved (the honest external boundary, and it never mints the
-- cross-addon edge the .toc scoping killed). Keys arrive as folded literals
-- (const-fold, v50). Register: `local L = <recv>:NewLibrary("X")` /
-- `:NewModule("Y")` / `:NewAddon("Z")` → the bound local (the registered table).
-- Retrieve: LibStub("X") (fn-call form) + :GetLibrary/:GetModule/:GetAddon("X").
-- Emits a ref edge to the registered table + records `c.registry` (inferred ~);
-- does NOT set c.to (the target is a table, not a call target). INERT on any
-- corpus without these idioms (non-WoW) → no gate recalibration there.
local REG_REGISTER = { NewLibrary = 'lib', NewModule = 'module', NewAddon = 'addon' }
local REG_RETRIEVE = { GetLibrary = 'lib', GetModule = 'module', GetAddon = 'addon' }
local function resolve_registry(cv, node_index, addref, scope_of, consts, exact)
    local cget, cset = cv.get, cv.set
    -- class-owner set: a name that owns a method (`X:m`/`X.m` in exact). A register
    -- line `local Lib, oldminor = :NewLibrary(...)` gives BOTH vars start.char 0 (the
    -- extraction attributes them to the statement, not the identifier), so the
    -- leftmost-by-char tiebreak below is a coin-flip decided by unstable pairs() order
    -- — the returned-minor could win, so LibStub("AceConsole-3.0") resolved to
    -- `oldminor` not `AceConsole`. Prefer the var that is a CLASS (the registered lib
    -- OWNS methods; oldminor owns nothing) — sound + deterministic.
    local is_class = {}
    for name in pairs(exact or {}) do
        local owner = name:match('^([%w_]+)[:.]')
        if owner then is_class[owner] = true end
    end
    -- the key as a STRING: a folded literal (k='lit', warm/relink argv) OR a
    -- k='local' whose name resolves to a same-file scalar-string const (the
    -- INITIAL extract runs before const-fold's post-pass, so fold the key here
    -- from the same const index — `consts` is nil on relink where argv is folded).
    -- Index-form: (call index ci, argv slot j) instead of the element table.
    local function keyof(ci, j, file)
        if j > cv.argn(ci) then return nil end
        local ak = cv.aget(ci, j, 'k')
        if ak == 'lit' then return cv.aget(ci, j, 'v') end
        if ak == 'local' then
            local aname = cv.aget(ci, j, 'name')
            if aname and consts and consts[file] then
                local v = consts[file][aname]
                return type(v) == 'string' and v or nil
            end
        end
    end
    -- the local a register call's result binds to = the registered table, found
    -- by (file, line): `local L = recv:NewLibrary("X")` puts L on the call's line
    local varAt
    local index, n = {}, 0
    for i = 1, cv.n do
        local cfile = cget(i, 'file')
        local kind = cget(i, 'method') and REG_REGISTER[cget(i, 'callee')]
        local key = kind and keyof(i, 2, cfile)
        if key then
            if not varAt then
                varAt = {}
                for _, nd in pairs(node_index) do
                    if nd.kind == 'var' and nd.file and nd.range then
                        -- the primary binding of the register line. Prefer a CLASS-
                        -- owner (the lib table owns methods; a sibling `oldminor`
                        -- owns nothing), then the leftmost by start.char. Fixes the
                        -- char-0 tie where the returned-minor could win the toss.
                        local vk = nd.file .. '\0' .. atr.sl(nd.range)
                        local cur = varAt[vk]
                        local ndc, curc = is_class[nd.name], cur and is_class[cur.name]
                        if not cur or (ndc and not curc)
                            or (ndc == curc and atr.sc(nd.range) < atr.sc(cur.range)) then
                            varAt[vk] = nd
                        end
                    end
                end
            end
            local def = varAt[cfile .. '\0' .. cget(i, 'line')]
            if def then
                index[(scope_of(cfile) or '') .. '\0' .. kind .. '\0' .. key] = def
            end
        end
    end
    if not next(index) then return 0 end
    -- a retrieval RESOLVES TO the LibStub/Get* function as a normal call target;
    -- the registry link is about what it RETURNS (the registered table), so it
    -- rides ALONGSIDE c.to (additive ref edge + c.registry marker), not instead.
    for i = 1, cv.n do
        if not cget(i, 'registry') then
            local cfile, ccallee = cget(i, 'file'), cget(i, 'callee')
            local kind, key
            if cget(i, 'method') and REG_RETRIEVE[ccallee] then
                kind, key = REG_RETRIEVE[ccallee], keyof(i, 2, cfile)
            elseif ccallee == 'LibStub' and not cget(i, 'method') then
                kind, key = 'lib', keyof(i, 1, cfile)
            end
            local def = kind and key
                and index[(scope_of(cfile) or '') .. '\0' .. kind .. '\0' .. key]
            -- the resolution FACT (c.registry) is recorded even at top level
            -- (c.fn nil — the common `local X = LibStub("Y")` module form); the
            -- navigable ref edge rides only when there's an enclosing fn `from`
            local cfn = cget(i, 'fn')
            if def and def.id ~= cfn then
                local cat = cget(i, 'at')
                if cfn and cat then addref(cfn, def.id, cat, true) end
                cset(i, 'registry', def.id)
                n = n + 1
            end
        end
    end
    return n
end

-- V1: SOUND self:member resolution ([[cartograph-linker]] receiver-typing).
-- `self` is param-0 of a colon-method; its type is the JOIN of receiver types
-- over the method's RESOLVED call sites (backward flow) — NOT the lexical owner,
-- which the census showed is ~89% wrong (handler-self = an API frame; mixin-self
-- = a derived instance). Once self's class C is DETERMINED (all call sites agree
-- on one class), self:member resolves in C's own defs + extends chain. The
-- soundness gate: any untypeable call site POISONS the method to hedge, and a
-- receiver that is `self` inherits the ENCLOSING method's class — so a resolution
-- happens only when every path types self to a single class; otherwise the call
-- is left unresolved (never a lexical guess). Bounded fixpoint: typing a method
-- propagates to the methods it reaches via self:. Marked inferred (~) — a derived
-- resolution (known limit: a local shadowing a class NAME could mis-seed; the ~
-- tier is honest about it). Lua-shaped (self as an explicit param-0).
--- THE SELF-TYPE MAP (`selft`) IS GLOBAL EVIDENCE, and `seed` is how a PARTIAL call
--- set borrows the whole-graph version of it ([[cartograph-merging-strategies]], the
--- calls half). Two of this pass's conditions read ABSENCE as positive evidence, so
--- both misfire when call sites are merely not resident:
---   · selft[mid] == false (POISONED — called somewhere with an untypeable receiver)
---     gates V1/V2. Fewer resident calls means less poison, so MORE self-typing.
---   · selft[cfn] == nil (UNTOUCHED — no in-corpus call site at all, hence framework-
---     invoked) gates the V3 lexical tier. Fewer resident calls means more ids look
---     untouched, so MORE lexical typing.
--- Both err toward over-claiming, and ANTI-monotonically: the less you materialize the
--- more you assert. Measured on rust — 4 calls resolved at ~ that a full graph refuses.
--- `seed` (nil on every whole-graph path, so extract and relink are unchanged) starts
--- the map from a full graph's outcome, making the pass behave as if it had seen every
--- call site. M._selft exposes the computed map so it can be captured and carried.
local function resolve_self(cv, node_index, extends, exact, addref, seed, scope_of)
    local cget, cset = cv.get, cv.set
    -- class-name set: any table T that owns a method (`T:x` / `T.x` in exact)
    local is_class = {}
    for name in pairs(exact) do
        local owner = name:match('^([%w_]+)[:.]')
        if owner then is_class[owner] = true end
    end
    if not next(is_class) then return 0 end
    local super = build_super(extends)
    local selft = {}    -- method-id -> { [class]=true } accumulator, or false=poisoned
    -- borrow a whole-graph outcome when one was carried in (COPIED, so the seed stays
    -- reusable across materializations and this run cannot mutate a shared artifact)
    for mid, v in pairs(seed or {}) do
        if v == false then selft[mid] = false
        else
            local s = {}
            for c in pairs(v) do s[c] = true end
            selft[mid] = s
        end
    end
    local function addtype(mid, C)
        if selft[mid] == false then return end
        selft[mid] = selft[mid] or {}
        selft[mid][C] = true
    end
    local function selfclass(mid) -- the SINGLE determined class, or nil (hedge)
        local s = selft[mid]
        if not s then return nil end
        local one
        for c in pairs(s) do if one then return nil else one = c end end
        return one
    end
    local n = 0
    for round = 1, 6 do
        local progress = false
        -- (1) accumulate self-types from resolved method call sites (backward)
        for i = 1, cv.n do
            local cto, cfull = cget(i, 'to'), cget(i, 'full')
            if cto and cfull and node_index[cto] and node_index[cto].kind == 'method' then
                local recv = cfull:match('^([%w_]+)[:.]')
                local cfn = cget(i, 'fn')
                if recv == 'self' then
                    local CE = cfn and selfclass(cfn) -- enclosing method's self
                    if CE then addtype(cto, CE)
                    elseif cfn and selft[cfn] == false then selft[cto] = false end
                elseif recv and is_class[recv] then
                    addtype(cto, recv)            -- literal class receiver
                elseif recv then
                    selft[cto] = false            -- untypeable receiver → hedge
                end
            end
        end
        -- (2) resolve self:member calls whose enclosing method is typed to one class
        for i = 1, cv.n do
            local cfull, cfn = cget(i, 'full'), cget(i, 'fn')
            if not cget(i, 'to') and cfull and cfn then
                local member = cfull:match('^self[:.]([%w_]+)$')
                local C = member and selfclass(cfn)
                if C then
                    -- scope-aware: a vendored library is duplicated per addon (CART-0241)
                    local fit = chain_lookup(super, exact, C, member,
                        elang_for(cget(i, 'file')), cget(i, 'file'), scope_of)
                    if fit then
                        cset(i, 'to', fit.id); cset(i, 'inferred', true); cset(i, 'refused', nil)
                        local cline = cget(i, 'line')
                        addref(cfn, fit.id, cget(i, 'at')
                            or { start = { line = cline, char = 0 },
                                 ['end'] = { line = cline, char = 0 } }, true)
                        n = n + 1; progress = true
                    end
                end
            end
        end
        if not progress and round > 1 then break end
    end
    -- V3: FRAMEWORK-INVOKED methods have NO in-corpus call site, so the backward-
    -- flow fixpoint above left them untyped. Type self LEXICALLY for a colon-method
    -- `M:foo` whose owner M is a GENUINE OBJECT (owns >=2 colon-methods): the OO/
    -- framework contract invokes M:foo with M as self (Ace3 :NewModule modules,
    -- widget mixins, event handlers). Chain-walked so a member inherited from a
    -- mixin/base resolves; unique-hit only; inferred (~). This is NOT the naive
    -- ~89%-wrong lexical guess — it fires ONLY where call-site typing hedged, gated
    -- to multi-method owners, and the extends chain fixes the mixin misses that
    -- sank the naive form. ([[cartograph-linker]] V3 framework adapters)
    -- colon-method count per FULL DOTTED owner: `Widget.prototype:m` counts for
    -- owner `Widget.prototype`, NOT the first segment `Widget` — the prototype-OOP
    -- idiom (Ace2 widgets: `X.prototype:method`) is a genuine object in its own
    -- right, and truncating the owner made it invisible to the >=2 gate.
    local methodcount = {}
    for name in pairs(exact) do
        local owner = name:match('^(.+):[%w_]+$')
        if owner then methodcount[owner] = (methodcount[owner] or 0) + 1 end
    end
    for i = 1, cv.n do
        -- ONLY methods with NO in-corpus call site (selft untouched = truly
        -- framework-invoked). A POISONED method (selft==false, called with an
        -- untypeable receiver) keeps V1's hedge — lexical self would be unsound
        -- there (the method IS invoked on an unknown receiver, maybe not M).
        local cfull, cfn = cget(i, 'full'), cget(i, 'fn')
        if cfull and cfn and node_index[cfn] and selft[cfn] == nil then
            local member = cfull:match('^self[:.]([%w_]+)$')
            local fn = node_index[cfn]
            -- FULL dotted owner (`Widget.prototype:Refresh` → `Widget.prototype`),
            -- so self is typed to the prototype and self:m resolves in ITS members.
            local owner = member and fn.name and fn.name:match('^(.+)[:.][%w_]+$')
            if owner and (methodcount[owner] or 0) >= 2 then
                local fit = chain_lookup(super, exact, owner, member,
                    elang_for(cget(i, 'file')), cget(i, 'file'), scope_of)
                -- FILL an unresolved call, OR OVERRIDE a FOREIGN promiscuous match:
                -- the main resolve()'s member-name tail-match resolves `self:m` to an
                -- UNRELATED same-named method when the owner truncated (all
                -- `Waterfall*.prototype:SetText` landed on `FuBarPlugin:SetText`).
                -- self IS `owner` here (a colon-method of a genuine object), so
                -- owner's own m is definitively the target — receiver-type beats
                -- name-match (generalizing v55/v56 to self-typing). MEASURED: the
                -- override fires 0× on non-dotted owners (all already correct), so
                -- it can't regress the correct self:member resolutions.
                local cto = cget(i, 'to')
                if fit and fit.id ~= cto then
                    local cur = cto and node_index[cto]
                    local curowner = cur and cur.name and cur.name:match('^(.+)[:.][%w_]+$')
                    if not cto or (curowner ~= nil and curowner ~= owner) then
                        cset(i, 'to', fit.id); cset(i, 'inferred', true); cset(i, 'refused', nil)
                        local cline = cget(i, 'line')
                        addref(cfn, fit.id, cget(i, 'at')
                            or { start = { line = cline, char = 0 },
                                 ['end'] = { line = cline, char = 0 } }, true)
                        n = n + 1
                    end
                end
            end
        end
    end
    -- B3: JS/TS `this.member()` typing (pivot B3, [[cartograph-jsts-pivot]]). `this`
    -- inside a class method IS the instance; type it LEXICALLY to the enclosing
    -- class (from the method's `C.member` key, B1) and resolve member through C's
    -- extends chain (B2). Separate from the lua self machinery above: `this` is
    -- never param-0 and JS methods called on instances get V1-poisoned, so this
    -- block does NOT consult selft — it's an independent lexical pass. ~-tier
    -- (honest: JS `this` can be rebound by detach/bind/arrow, and virtual dispatch
    -- can pick a subclass override — chain_lookup returns the lexically-visible
    -- definition, unique-or-hedge). Gated to a GENUINE object (owner owns >=2 dot-
    -- methods) so a bare data-holder object doesn't seed a guess; JS/TS only.
    local dotcount = {}
    for name in pairs(exact) do
        local owner = name:match('^(.+)%.[%w_]+$')
        if owner then dotcount[owner] = (dotcount[owner] or 0) + 1 end
    end
    -- what class does `this` refer to at a call whose enclosing fn is `fnid`?
    -- `this` in an ARROW is inherited lexically → walk up through arrows; `this`
    -- in a REGULAR function is REBOUND at call time → stop (dynamic, don't type).
    -- The establishing fn is the nearest class MEMBER (a method or field-arrow,
    -- keyed `C.member` with C a genuine object owning >=2 methods) reached without
    -- crossing a regular-function boundary. This is the function()/()=>{} `this`
    -- semantics, made sound: `class C{ m(){ f(()=>this.x()) } }` types (arrow),
    -- `class C{ m(){ function g(){ this.x() } } }` does NOT (g rebinds this).
    local this_parent = build_parent_fn(node_index)
    local function this_owner(fnid)
        local cur = node_index[fnid]
        while cur do
            local owner = cur.name and cur.name:match('^(.+)%.[%w_]+$')
            if owner and is_class[owner] and (dotcount[owner] or 0) >= 2 then
                return owner -- a class member (method / field-arrow): this = C
            end
            if not cur.arrow then return nil end -- regular fn / top-level: this rebound
            cur = this_parent[cur.id] -- arrow: inherit this from the enclosing fn
        end
    end
    for i = 1, cv.n do
        local cfull, cfn = cget(i, 'full'), cget(i, 'fn')
        if not cget(i, 'to') and cfull and cfn and node_index[cfn]
            and elang_for(cget(i, 'file')) == 'javascript' then
            local member = cfull:match('^this%.([%w_]+)$')
            local owner = member and this_owner(cfn)
            if owner then
                local fit = chain_lookup(super, exact, owner, member, 'javascript')
                if fit then
                    cset(i, 'to', fit.id); cset(i, 'inferred', true); cset(i, 'refused', nil)
                    local cline = cget(i, 'line')
                    addref(cfn, fit.id, cget(i, 'at')
                        or { start = { line = cline, char = 0 },
                             ['end'] = { line = cline, char = 0 } }, true)
                    n = n + 1
                end
            end
        end
    end
    -- publish the map so a whole-graph run can be CARRIED to a partial one (see the
    -- header). Read-only for consumers; a fresh run overwrites it.
    M._selft = selft
    return n
end

-- V2: locals typed by a constructor ([[cartograph-linker]] receiver-typing).
-- `local obj = C.new(...)` / `obj = make()` etc. → obj:member / obj.member
-- resolves through obj's class's extends chain. Reads per-file ctor binds
-- (data.ctorbinds: file -> { local -> {callee, n} }, collected at extraction).
-- The class is derived two ways:
--   CUT 1 — the `.new`/`:new` CONVENTION: callee `C.new` → class C (C a class).
--   CUT 2 — the constructor's RETURN-CLASS: the callee resolves to a fn whose
--     body setmetatable's a table to C (a setmetatable-extends edge INSIDE the
--     fn's range) → that fn's return-class is C. Bypasses the naming convention
--     (works for `.make`/`.create`/any name, and inline setmetatable). Reuses V0's
--     extends edges + `line`.
-- SINGLE-ASSIGNMENT gated (n ~= 1 dropped — a rebind would change the type).
-- Inferred (~): a reassignment to a non-ctor value escapes the count (cut 3 =
-- reaching-verify the returned value IS the setmetatable'd one → promote ~→proven).
local function resolve_local_ctor(cv, node_index, ctorbinds, smtclasses, extends, exact, addref)
    if not (ctorbinds and next(ctorbinds)) then return 0 end
    local super = build_super(extends)
    local is_class = {}
    for name in pairs(exact) do
        local owner = name:match('^([%w_]+)[:.]')
        if owner then is_class[owner] = true end
    end
    -- CUT 2: return-class per fn NAME = the unique __index class of a setmetatable
    -- inside the fn's range (data.smtclasses: file -> {{class,line}}). A fn whose
    -- body builds one instance-metatable returns that instance. Ambiguous (2+
    -- distinct classes in range) → nil (hedge).
    local retclass = {}
    if smtclasses and next(smtclasses) then
        for _, nd in pairs(node_index or {}) do
            if (nd.kind == 'function' or nd.kind == 'method') and nd.name and nd.range
                and smtclasses[nd.file] then
                local s, en = atr.sl(nd.range), atr.el(nd.range)
                local one, amb
                for _, sm in ipairs(smtclasses[nd.file]) do
                    if sm.line >= s and sm.line <= en then
                        if one and one ~= sm.class then amb = true else one = sm.class end
                    end
                end
                if one and not amb then retclass[nd.name] = one end
            end
        end
    end
    local cget, cset = cv.get, cv.set
    local n = 0
    for i = 1, cv.n do
        local cfull, cfn = cget(i, 'full'), cget(i, 'fn')
        if not cget(i, 'to') and cfull and cfn then
            local cfile = cget(i, 'file')
            local recv, member = cfull:match('^([%w_]+)[:.]([%w_]+)$')
            local fb = recv and recv ~= 'self' and ctorbinds[cfile]
            local b = fb and fb[recv]
            if b and b.n == 1 and b.callee then
                -- CUT 1 (.new convention) then CUT 2 (callee fn's return-class)
                local cls = b.callee:match('^([%w_]+)[.:]new$')
                if not (cls and is_class[cls]) then cls = retclass[b.callee] end
                -- CUT 3 (JS/TS): `const o = new C()` stores the bare class C as
                -- the callee (no `.new`), so the callee IS the class. `new C()`
                -- constructs exactly a C instance → o.member walks C's chain.
                -- elang-gated so lua/php callable-class idioms are untouched.
                if not (cls and is_class[cls]) and is_class[b.callee]
                    and elang_for(cfile) == 'javascript' then cls = b.callee end
                if cls and is_class[cls] then
                    local fit = chain_lookup(super, exact, cls, member, elang_for(cfile))
                    if fit then
                        cset(i, 'to', fit.id); cset(i, 'inferred', true); cset(i, 'refused', nil)
                        local cline = cget(i, 'line')
                        addref(cfn, fit.id, cget(i, 'at')
                            or { start = { line = cline, char = 0 },
                                 ['end'] = { line = cline, char = 0 } }, true)
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

-- Ruby R4 — inheritance + mixin ancestor resolution. When R2/R3 keyed a bare
-- (or self) call `C#m` / `C.m` and it MISSED (the method is inherited, not
-- defined on C), walk C's ancestors — superclass chain + include/prepend
-- modules (instance) + extend modules (singleton) — for the nearest UNIQUE
-- definition. Recovers exactly the frontiers R2/R3 honestly declined. HEDGED
-- (~): dynamic dispatch + Ruby's full MRO aren't modeled, this is the nearest
-- static ancestor. `anc` = the edge list {c,p,mode} from ruby_ancestors.
-- ALSO does rescoped-R5 additive ctor-typing: an unresolved `x.foo` whose
-- receiver `x` is `ctorbinds`-typed to C (from `x = C.new`, single-assignment)
-- resolves to C#foo — C's own def, else up C's ancestors. ADDITIVE: only
-- touches calls the file-local heuristic left unresolved (c.recv + not c.to).
local function resolve_ruby_ancestors(cv, anc, exact, addref, node_index, ctorbinds)
    local have_anc = anc and #anc > 0
    if not (have_anc or (ctorbinds and next(ctorbinds))) then return 0 end
    anc = anc or {}
    -- adjacency by mode: inst (p#m), sings (superclass p.m), singe (extend p#m)
    local inst, sings, singe = {}, {}, {}
    local function add(map, k, v) map[k] = map[k] or {}; map[k][#map[k] + 1] = v end
    for _, e in ipairs(anc) do
        if e.mode == 'inst' then add(inst, e.c, e.p)
        elseif e.mode == 'sings' then add(sings, e.c, e.p)
        elseif e.mode == 'singe' then add(singe, e.c, e.p) end
    end
    -- nearest unique def of `member` up an adjacency chain, looking up
    -- `parent .. sep .. member`. BFS (nearest first); >1 distinct at the same
    -- frontier depth → ambiguous, give up (honest).
    local function chase(start, member, adj, sep)
        local seen, frontier = { [start] = true }, { start }
        for _ = 1, SUPER_STEP_LIMIT do
            local nextf, hit = {}, nil
            for _, cur in ipairs(frontier) do
                for _, p in ipairs(adj[cur] or {}) do
                    if not seen[p] then
                        seen[p] = true
                        nextf[#nextf + 1] = p
                        for _, nd in ipairs(exact[p .. sep .. member] or {}) do
                            if elang_for(nd.file) == 'ruby' then
                                if hit and hit.id ~= nd.id then return nil end
                                hit = nd
                            end
                        end
                    end
                end
            end
            if hit then return hit end
            if #nextf == 0 then break end
            frontier = nextf
        end
        return nil
    end
    -- the UNIQUE ruby def at an exact key (C's own def, before chasing up)
    local function uniq(key)
        local hit
        for _, nd in ipairs(exact[key] or {}) do
            if elang_for(nd.file) == 'ruby' then
                if hit and hit.id ~= nd.id then return nil end
                hit = nd
            end
        end
        return hit
    end
    local cget, cset = cv.get, cv.set
    local n = 0
    for i = 1, cv.n do
        local cfn = cget(i, 'fn')
        if not cget(i, 'to') and cfn then
            local fit
            local crecv, ccallee = cget(i, 'recv'), cget(i, 'callee')
            local csuperx, cfull = cget(i, 'superx'), cget(i, 'full')
            if crecv and ctorbinds then
                -- rescoped R5: x.foo where x = C.new (single-assignment) →
                -- C#foo (own), else C's ancestors. Additive (call was unresolved).
                local fb = ctorbinds[cget(i, 'file')]
                local b = fb and fb[crecv]
                if b and b.n == 1 and b.cls and ccallee then
                    fit = uniq(b.cls .. '#' .. ccallee)
                        or chase(b.cls, ccallee, inst, '#')
                end
            elseif csuperx then
                -- `super`: chase the enclosing method's name up the ancestors,
                -- skipping C's own def (chase looks at PARENTS). instance
                -- method → superclass/include chain (p#m); singleton → the
                -- superclass singleton chain (p.m).
                local sx = csuperx
                if sx.sing then fit = chase(sx.cls, sx.member, sings, '.')
                else fit = chase(sx.cls, sx.member, inst, '#') end
            elseif cfull then
                local cls, csep, member = cfull:match('^(%u[%w_]*)([#.])([%w_?!=]+)$')
                if cls and csep == '#' then
                    fit = chase(cls, member, inst, '#')
                elseif cls and csep == '.' then
                    -- superclass singletons (p.m) then extend-modules (m#member)
                    fit = chase(cls, member, sings, '.')
                    if not fit then fit = chase(cls, member, singe, '#') end
                end
            end
            if fit then
                cset(i, 'to', fit.id); cset(i, 'inferred', true); cset(i, 'refused', nil)
                local cline = cget(i, 'line')
                addref(cfn, fit.id, cget(i, 'at')
                    or { start = { line = cline, char = 0 },
                         ['end'] = { line = cline, char = 0 } }, true)
                n = n + 1
            end
        end
    end
    return n
end

-- Return-type rounds (the graph-VM MVP — see the graph-vm design memo).
-- A call whose receiver is ANOTHER call (f().g()) or a local typed only by
-- its initializer's return (`var x = f(); x.g()`) could not be qualified
-- lexically; extract recorded the DETERMINING call site on it (c.rt). Once
-- that call resolves, its target's declared return type (n.ret — the
-- per-method summary) qualifies this one: Ret::method, exact-matched with
-- the same language-fit/ambiguity discipline as resolve_super. Chains
-- settle in ROUNDS — a().b().c() unlocks one link per pass: the
-- types⇄call-graph mutual fixpoint in its smallest form. Round count is
-- returned for the measurement protocol. Shared by extract and relink.
local function resolve_returns(cv, node_index, exact, addref)
    local cget, cset = cv.get, cv.set
    local callidx = {}
    -- the deferred WORKLIST: rounds iterate only the calls still carrying
    -- unresolved rt provenance, not the whole call array per round (which
    -- profiled at ~2% of extract on server — 3 rounds x 240k calls). Both
    -- callidx and the worklist hold call INDICES, not record handles (index-form).
    local deferred, dn = {}, 0
    for i = 1, cv.n do
        local cat = cget(i, 'at')
        if cat then
            callidx[cget(i, 'file') .. '\31' .. atr.sl(cat) .. '\31' .. atr.sc(cat)] = i
        end
        if cget(i, 'rt') and not cget(i, 'to') and cget(i, 'callee') then
            dn = dn + 1
            deferred[dn] = i
        end
    end
    local n, rounds = 0, 0
    repeat
        local progress = false
        rounds = rounds + 1
        local keep, kn = {}, 0
        for di = 1, dn do
            local ci = deferred[di]
            local settled = false
            do
                local crt = cget(ci, 'rt')
                local dci = callidx[cget(ci, 'file') .. '\31' .. crt.r .. '\31' .. crt.c]
                local dto = dci and cget(dci, 'to')
                local dnode = dto and node_index[dto]
                local ret = dnode and dnode.ret
                -- GENERIC Class<T> return: the determining call's target binds
                -- its return type to a Class<T> parameter, so the concrete
                -- return is the type its class-literal argument names
                -- (Services.get(IFoo.class) → IFoo). Reads the call's own arg —
                -- signature-driven, general to any `<T> T m(Class<T>)`.
                if dnode and dnode.retclass and dci and cv.argn(dci) >= dnode.retclass then
                    local ak = cv.aget(dci, dnode.retclass, 'k')
                    local av = cv.aget(dci, dnode.retclass, 'v')
                    if ak == 'class' and av then ret = av end
                end
                local drefused = dci and cget(dci, 'refused')
                if not ret and drefused and drefused.cands
                    and drefused.n and drefused.n <= #drefused.cands then
                    -- overloads refuse the CALL, but when every candidate
                    -- declares the same return type, the TYPE is unambiguous
                    -- and the chain continues (untruncated cands only — a
                    -- capped list can't prove agreement)
                    local agree
                    for _, id in ipairs(drefused.cands) do
                        local r = node_index[id] and node_index[id].ret
                        if not r or (agree and r ~= agree) then agree = nil break end
                        agree = r
                    end
                    ret = agree
                end
                -- a JDK return type dispatches into the stdlib (java's stdlib
                -- gate; other langs skip — their stdlib disposition handles it).
                -- The method-key separator is per-language: java `::`, zig `.`
                -- (spec.methodsep, default `::` so java stays identical).
                local ccallee = cget(ci, 'callee')
                local clang = ret and elang_for(cget(ci, 'file'))
                local jdk_gated = clang == 'java' and javaspec._jdk_types[ret]
                if ret and not jdk_gated then
                    local sep = (M.spec[clang] and M.spec[clang].methodsep) or '::'
                    local rkey = ret .. sep .. ccallee
                    local fit, dup
                    for _, node in ipairs(exact[rkey] or {}) do
                        if elang_for(node.file) == clang then
                            if fit then dup = true else fit = node end
                        end
                    end
                    if fit and not dup then
                        cset(ci, 'to', fit.id)
                        -- a deferred chained call had no lexical qualification;
                        -- record the one the return type gives it, so a later
                        -- pass (resolve_interface) can act on it — e.g. redirect
                        -- an interface-typed return `Ret::m` to its impl.
                        -- rtfull MARKS the synthesis: this full is part of the
                        -- ROUNDS' verdict, not lexical fact — the parallel
                        -- audit nulls it with the resolution it belongs to (a
                        -- kept one changed relink's question from the bare
                        -- stdlib-gated callee to a qualified name, minting
                        -- edges inline never had; the par gate caught it)
                        if not cget(ci, 'full') then
                            cset(ci, 'full', rkey)
                            cset(ci, 'rtfull', true)
                        end
                        cset(ci, 'inferred', true) -- type INFERRED through a summary
                        cset(ci, 'tinf', true) -- the TYPE-INFERRED tier (the VM's own
                        -- output: resolved via a return-type summary, a
                        -- stronger signal than a name-matched ~ guess; the
                        -- honesty ladder's middle rung). inferred STAYS so
                        -- the parallel audit still nulls + relink re-derives.
                        cset(ci, 'refused', nil)
                        -- c.rt STAYS: a worker settles chains slice-locally,
                        -- the parallel audit nulls every inferred resolution,
                        -- and relink must re-derive from the provenance
                        -- (idempotent — the `not c.to` guard skips settled
                        -- calls; name-ambiguous chains have no tail rescue)
                        local cfn = cget(ci, 'fn')
                        if cfn then addref(cfn, fit.id, cget(ci, 'at'), true, true) end
                        n = n + 1
                        progress = true
                        settled = true
                    end
                end
            end
            if not settled then
                kn = kn + 1
                keep[kn] = ci
            end
        end
        deferred, dn = keep, kn
    until not progress or dn == 0
    return n, rounds
end

-- HONESTY (the uniform-honesty invariant, read as a resolver pass): a bare call
-- whose callee is a PARAM or a LOCAL of the enclosing fn must resolve OR refuse
-- — never drop silently (it is a callable we can SEE the binding for; silence
-- is the gap the silent-drop lint exists to catch). Two regimes, keyed by what
-- the binding IS:
--   * a PARAM callee is HIGHER-ORDER — its target is whatever the caller
--     passed, unknowable at the def site → an honest refusal (rule
--     'higher-order'); the effects machinery already inherits its summary via
--     CALLS={i}, but the REF edge has no single static target.
--   * a LOCAL callee (a df-def of the fn) that names a UNIQUE same-file
--     function/method def resolves to it, INFERRED — this is the forward-decl /
--     short-name local fn the `#name<3` name gate dropped: we gate on
--     UNBOUND-ness, not length (a BOUND short name like `nm`/`go` resolves; a
--     free one — a loop counter — has no matching def and stays silent). A
--     local with no unique matching def is an honest refusal (rule 'fn-value').
-- Only touches calls the main pass + the resolve_* siblings left SILENT
-- (to==nil AND refused==nil), so it can neither override a resolution nor a
-- prior refusal. Runs last, after every other call resolver. Returns a count.
-- The binding may live in the IMMEDIATE fn or in an ENCLOSING (lexical) one:
-- a callback fn is its own node (v51), so a param/local CAPTURED from an outer
-- scope and called inside the callback is not in the callback's own params/df —
-- walk the enclosing-fn chain (innermost→outermost, nearest binding wins). The
-- fast path (immediate fn) covers the common case; ancestors only on a miss.
-- is `callee` bound in fn's enclosing chain? 'higher-order' (a PARAM), 'local' (a
-- local DECL), or nil (free — a genuine global candidate). THE LOCAL-SHADOW basis:
-- a locally-bound bare callee must NOT name-match a global (the local shadows it).
-- Reads fn.params + fn.locals (js-family in-function decls, incl. destructuring)
-- + df.stmts (langs whose df tracks locals — lua). Nearest binding wins; walks
-- captures across callback boundaries via parent_fn.
-- 'higher-order' (a PARAM), 'localdecl' (a fn.locals binding — a JS const/let/var,
-- incl. destructuring: a VALUE, never a resolvable fn def), 'local' (a df-tracked
-- local — lua's `local f; function f() end` forward-decl, IS the same-file fn), or
-- nil (free). The two local kinds are DISJOINT by language (js sets fn.locals + has
-- no df locals; lua the reverse), so the check order is unambiguous.
local function callee_binding(callee, fn, parent_fn)
    local function hasp(f) for _, p in ipairs(f.params or {}) do if p == callee then return true end end end
    local function hasdecl(f) for _, l in ipairs(f.locals or {}) do if l == callee then return true end end end
    local function hasdf(f)
        -- light path (F2 build_symtab): dfdef is the precomputed set of names df defines
        -- — the only projection of df resolution reads. Else the DUAL-MODE df accessor
        -- (folded columns OR raw records — fold-agnostic; the fat-record migration).
        if f.dfdef then return f.dfdef[callee] == true end
        for _, st in ipairs(dfmod.stmts(f)) do
            for _, d in ipairs(st.def or {}) do if d == callee then return true end end
        end
    end
    local f = fn
    while f do
        if hasp(f) then return 'higher-order' end
        if hasdecl(f) then return 'localdecl' end
        if hasdf(f) then return 'local' end
        f = parent_fn and parent_fn[f.id]
    end
end

-- the LOCAL-SHADOW gate: a bare callee is a shadow iff it's a JS/TS localdecl
-- binding (const/let/var, incl. destructuring) AND no same-file fn/method of that
-- name exists for it to legitimately BE. `const f = ()=>{}` HAS a same-file fn
-- node → NOT a shadow, the main loop resolves it same-file (plain); `const
-- [x,setX]=useState()` has none → a shadow, so a cross-file global name-match
-- would be the bug → skip the match (resolve_local_callable refuses fn-value).
-- Only 'localdecl' (not params: an AMD `define([…],function(dep){})` dep is a
-- param whose global name-match is correct; not lua df-locals: unchanged).
local function localdecl_shadow(callee, file, fn, parent_fn, exact)
    if callee_binding(callee, fn, parent_fn) ~= 'localdecl' then return false end
    for _, d in ipairs(exact[callee] or {}) do
        if d.file == file and (d.kind == 'function' or d.kind == 'method') then
            return false -- a same-file def exists → the main loop resolves it plain
        end
    end
    return true
end

local function resolve_local_callable(cv, node_index, exact, addref, parent_fn)
    local cget, cset = cv.get, cv.set
    local n = 0
    parent_fn = parent_fn or build_parent_fn(node_index)
    for i = 1, cv.n do
        local ccallee, cfn = cget(i, 'callee'), cget(i, 'fn')
        -- ★ A RECEIVER-QUALIFIED CALL STILL REACHES HERE, AND IT SHOULD NOT — but the
        -- obvious guard was MEASURED and is worse (CART-0398). This pass declines a call
        -- with a dotted `full` (`a.b()`), because a member dispatch is not a call through a
        -- local of the member's name; `full` is only the DOTTED spelling, and ruby
        -- (dispatch-by-member-name) and zig (field calls) keep the receiver separately in
        -- `recv`, so theirs fall through: `if match = message.match(/…/)` comes back refused
        -- `fn-value`, a positive claim about a method on `message`, and false.
        -- ADDING `and not cget(i, 'recv')` FIXES THAT AND FAILS THE SILENT GATE: 35 calls on
        -- activesupport alone stop refusing and start being SILENT, which is the invariant
        -- lint.lua names ("a call must RESOLVE or SPEAK a refusal"). The honest answer is a
        -- receiver-shaped REFUSAL RULE, not silence, and that is a design change.
        if ccallee and not cget(i, 'full') and not cget(i, 'dynamic') and not cget(i, 'to')
            and not cget(i, 'refused') and cfn then
            local fn = node_index[cfn]
            if fn then
                local regime = callee_binding(ccallee, fn, parent_fn)
                if regime == 'higher-order' then
                    cset(i, 'refused', { rule = 'higher-order' })
                    n = n + 1
                elseif regime == 'local' or regime == 'localdecl' then
                    -- resolve to the UNIQUE same-file function/method def the local
                    -- names — a lua forward-decl (`local f; function f()`) or a JS
                    -- `const f = function/arrow` binding IS that def. A binding to a
                    -- non-fn value (destructured `const [x,setX]=useState()` hook
                    -- setter, cross-file shadow) finds none → refused fn-value.
                    local cfile = cget(i, 'file')
                    local hit, dup
                    for _, d in ipairs(exact[ccallee] or {}) do
                        if d.file == cfile
                            and (d.kind == 'function' or d.kind == 'method') then
                            if hit then dup = true; break end
                            hit = d
                        end
                    end
                    if hit and not dup then
                        cset(i, 'to', hit.id)
                        cset(i, 'inferred', true)
                        local cat = cget(i, 'at')
                        if cat then addref(cfn, hit.id, cat, true) end
                    else
                        cset(i, 'refused', { rule = 'fn-value' })
                    end
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- THE RESOLUTION PIPELINE ([[cartograph-resolution-pipeline]]): the 12 post-
-- passes as ONE ordered list, so extract and relink share it instead of hand-
-- mirroring the sequence (two drivers kept in sync by hand was the standing
-- drift hazard). Each pass adapts the shared ctx to its resolver's signature
-- and returns the count it resolved. ORDER IS SEMANTIC (it used to live as
-- prose at the call site): super/module_alias/chains/registry feed the
-- receiver typing; `reassign` is a REWRITE stage (redirect a name-match to the
-- load-order-effective def) placed BEFORE the return rounds so a corrected
-- target feeds receiver typing; `returns` settles receiver-deferred calls once
-- determining calls exist; the receiver passes (self/local_ctor/ruby) run
-- next; `local_callable` is LAST — the honesty residual, catching only what
-- every other resolver left silent. Additive / unresolved-only EXCEPT reassign
-- (the one flagged rewrite). ctx = { calls, data, exact, tail, addref,
-- node_index, scope_of, consts, parent_fn } — `data` carries the per-language
-- fact tables. Z1 (local type inference) lands as a NEW ENTRY here, never a
-- new inline arm.
local RESOLVE_PASSES = {
    { name = 'super', run = function (x)
        return resolve_super(x.cv, x.data.extends, x.exact, x.addref, x.node_index) end },
    { name = 'module_alias', run = function (x)
        return resolve_module_alias(x.cv, x.data.edges, x.exact, x.tail, x.addref,
            x.node_index, x.unparsed) end },
    { name = 'field_alias', run = function (x) -- `local f = mod.field` then bare f()
        return resolve_field_alias(x.cv, x.data.edges, x.exact, x.tail, x.addref,
            x.node_index, x.data.fieldalias) end },
    { name = 'chain_type', run = function (x)
        return resolve_chain_type(x.cv, x.exact, x.addref, x.node_index) end },
    { name = 'field_chain', run = function (x)
        return resolve_field_chain(x.cv, x.data.fieldtypes, x.data.edges, x.exact, x.tail, x.addref, x.node_index) end },
    { name = 'registry', run = function (x)
        return resolve_registry(x.cv, x.node_index, x.addref, x.scope_of, x.consts, x.exact) end },
    { name = 'reassign', run = function (x) -- REWRITE stage (see header)
        return resolve_reassign(x.cv, x.node_index, x.addref) end },
    { name = 'returns', run = function (x)
        local retn, rounds = resolve_returns(x.cv, x.node_index, x.exact, x.addref)
        x.ret_resolved, x.ret_rounds = retn, rounds
        return retn end },
    { name = 'self', run = function (x)
        -- data.selft_seed: a whole-graph self-type map carried into a PARTIAL call set
        -- (demand materialization). nil on every whole-graph path, so extract/relink
        -- are byte-identical — the gates are the proof.
        local r = resolve_self(x.cv, x.node_index, x.data.extends, x.exact, x.addref,
            x.data.selft_seed, x.scope_of)
        -- STAMP the map with the graph it describes. Without this, a consumer could
        -- carry a map left over from a DIFFERENT corpus in the same process — a stale
        -- self-type map is worse than none, since it types against foreign classes.
        M._selft_root = x.data.root
        return r end },
    { name = 'local_ctor', run = function (x)
        return resolve_local_ctor(x.cv, x.node_index, x.data.ctorbinds, x.data.smtclasses, x.data.extends, x.exact, x.addref) end },
    { name = 'ruby_ancestors', run = function (x)
        return resolve_ruby_ancestors(x.cv, x.data.ruby_anc, x.exact, x.addref, x.node_index, x.data.ruby_ctor) end },
    { name = 'interface', run = function (x)
        return resolve_interface(x.cv, x.data.implements, x.data.beans, x.data.extends, x.exact, x.addref, javaspec._service_markers) end },
    { name = 'local_callable', run = function (x)
        return resolve_local_callable(x.cv, x.node_index, x.exact, x.addref, x.parent_fn) end },
    -- DISPOSITION (not resolution): label std-aliased calls the resolvers left
    -- unresolved. Last, so it only speaks for genuine no-defs / refusals.
    { name = 'std_alias', run = function (x)
        return resolve_std_alias(x.cv, x.data.stdaliases) end },
}
M.RESOLVE_PASSES = RESOLVE_PASSES -- exposed for ablation/attribution + the gate

-- run the pipeline over a ctx; returns the total count resolved. THE one place
-- the pass order lives — extract runs it over the full call set, relink over
-- the touched subset (ctx.consts differs: extract folds const keys, relink nil).
local function run_resolve_passes(ctx)
    -- CALL ACCESS is representation-neutral (callview, the record-fold PEAK arc):
    -- INDEX-FORM over the columnar store when the parent holds one (ctx.data.
    -- _callstore — no records, no proxies), else raw records (the default path,
    -- byte-identical). Each pass reads/writes through this cv instead of an
    -- `ipairs(calls)` over record handles. [[cartograph-record-fold-arc]]
    local cv = require('cartograph.callview').of(ctx.data)
    ctx.cv = cv
    local cget, cset = cv.get, cv.set
    -- PROVENANCE (the by_prov axis, [[cartograph-provenance-surfacing]]): stamp
    -- c.prov = which stage landed the resolution. This is the pipeline memo's
    -- "ablation = free attribution" — the ONE driver, so attribution is a diff
    -- of the resolved set, no per-pass return-contract change. FIRST-resolver-
    -- wins: anything already resolved when the pipeline starts rode the base
    -- exact/name-match resolution ('base'); each pass then claims the calls it
    -- newly resolves (c.to now set, prov still unstamped). A later REWRITE
    -- (reassign) that retargets an already-attributed call does NOT re-stamp —
    -- prov names who first linked it. (Minting stamps 'stdlib' at mint time.)
    for i = 1, cv.n do
        if cget(i, 'to') and not cget(i, 'prov') then cset(i, 'prov', 'base') end
    end
    local n = 0
    for _, p in ipairs(RESOLVE_PASSES) do
        n = n + (p.run(ctx) or 0)
        for i = 1, cv.n do
            if cget(i, 'to') and not cget(i, 'prov') then cset(i, 'prov', p.name) end
        end
    end
    return n
end

-- leading lines that BELONG to a def — comments, decorators,
-- attributes, annotations: what must travel with its text when an
-- edit verb moves it. Keyed by effective language.
local ATTACH = {
    lua = { '^%s*%-%-' },
    haskell = { '^%s*%-%-' },
    scheme = { '^%s*;' },
    c = { '^%s*//', '^%s*/%*', '^%s*%*' },
    cpp = { '^%s*//', '^%s*/%*', '^%s*%*' },
    javascript = { '^%s*//', '^%s*/%*', '^%s*%*', '^%s*@' },
    php = { '^%s*//', '^%s*#', '^%s*/%*', '^%s*%*' },
    ruby = { '^%s*#' },
    java = { '^%s*//', '^%s*/%*', '^%s*%*', '^%s*@' },
    go = { '^%s*//' },
    rust = { '^%s*//', '^%s*/%*', '^%s*%*', '^%s*#%[' },
    python = { '^%s*#', '^%s*@' },
    zig = { '^%s*//' },
    odin = { '^%s*//' },
}

function M.attach_pats(file)
    local lang = elang_for(file)
    return lang and ATTACH[lang] or {}
end

--- The annotation tag-line pattern for `file`, or nil where the language declares
--- none — which is the honest answer for "this file has no annotations we can
--- read", NOT "this file has none" (CART-0240).
function M.annot_tag(file)
    local lang, spec = elang_for(file)
    return lang and spec and spec.annot_tag or nil
end

-- the effective language, for verbs that need a hazard decision
function M.lang_of(file)
    return (elang_for(file))
end

-- the grammar a re-parse of `file` must use (typescript for .ts, not the
-- javascript family lang) — see parse_lang_for. Callers that RE-PARSE for
-- analysis (lens flow, forms) parse with this and resolve with lang_of's spec.
function M.parse_lang(file)
    return parse_lang_for(file)
end

--- Is this file a CONTAINER (one file, several language regions — vue/svelte SFC)?
---
--- ★ EXPORTED BECAUSE `parse_lang` ANSWERS FOR A CONTAINER AND THE ANSWER IS A TRAP
--- (CART-0410). `parse_lang('App.vue')` returns `javascript` — correct for "which
--- grammar parses the SCRIPT REGION", and catastrophic for a caller that reads it as
--- "parse this FILE as javascript": an SFC's template and style are not JS, so a
--- whole-file re-parse invents structure the way parsing a blade template as php does
--- (see lang_for's ext_disclaim comment — same defect, one layer up).
--- A caller that re-parses WHOLE FILES must exclude containers; extraction does not,
--- because it walks the injection regions instead.
function M.is_container(file)
    return file ~= nil and container_for(file) ~= nil
end

-- a NEW file's obligatory first lines (extract-module creates files)
function M.file_header(file)
    if elang_for(file) == 'php' then return { '<?php', '' } end
    return {}
end

-- the import line a file would use to reach `dest`, and its alias —
-- nil when this language's wiring is not mechanically writable
function M.import_line(from_file, dest)
    local _, spec = elang_for(from_file)
    if not (spec and spec.import_line) then return nil end
    return spec.import_line(dest)
end

-- patterns matching this file's import lines (new-import placement)
function M.import_pats(file)
    local _, spec = elang_for(file)
    return spec and spec.import_pats or nil
end

-- ── body-descent (browser) ────────────────────────────────────────────────
-- The block/scope nodes whose named children ARE statements (imperative
-- langs), and the clause wrappers a block hides behind (else/elif/case…).
-- Used to walk ONE level of nesting into a compound statement.
local SUBSTMT_BLOCKS = {
    block = true, compound_statement = true, statement_block = true,
    suite = true, do_block = true, declaration_list = true,
    field_declaration_list = true, class_body = true, switch_body = true,
    -- php/java `switch_block`, rust `match_block`; ruby's `then` is the BODY
    -- wrapper of a when/if — a block, not a clause, its children ARE the
    -- statements — and `body_statement` is a ruby method's body.
    switch_block = true, match_block = true, ['then'] = true,
    body_statement = true,
    -- zig (and `struct_declaration` is odin's spelling too), from the navigation
    -- census (CART-0463). zig's grammar wraps a body TWICE -- `if_statement >
    -- block_expression > block` -- and names a container declaration as the VALUE of a
    -- variable declaration: `const S = struct { ... }`. Both read as blocks here, and
    -- the wrapper flattens because emit_block collapses a block whose only remaining
    -- child is another block.
    -- NOT `enum_declaration`: JAVA SPELLS ITS ENUM THAT WAY TOO, and there the node
    -- holds modifiers and a name beside its enum_body, so opening it would put a
    -- `Foo` row and a body row where a member list belongs. zig's enum members stay
    -- unreachable for now (60 traps, filed) rather than trading a silence for junk.
    block_expression = true, labeled_type_expression = true,
    struct_declaration = true, union_declaration = true, opaque_declaration = true,
    -- java's FOUR OTHER bodies (CART-0459). `class_body` was here from the start and
    -- the rest never were, so a CONSTRUCTOR's statements -- 79 traps in 40 files of
    -- elasticsearch, the largest single java cause -- had no route in at all, while the
    -- method beside it worked.
    constructor_body = true, enum_body = true, interface_body = true,
    annotation_type_body = true,
}
-- A block whose children belong to the ENCLOSING list rather than to a row of their own:
-- java's enum_body holds `enum_body_declarations` beside its constants, and that node is
-- pure grammar -- a row for it would read as a second copy of the methods below it. This
-- is deliberately a named set and not a general rule: splicing every block-inside-a-block
-- would dissolve a bare `{ }` scope in c++ into its parent, which is a real construct.
local SPLICE_BLOCKS = { enum_body_declarations = true }
-- Named children of a block that are NOT statements. ruby's do_block carries its
-- `|x|` parameter list beside the body; the parameters have a home in the detail lens
-- and the signature, not in a list of statements.
-- A label hangs BESIDE the thing it labels, in four spellings: zig `block_label`
-- (`outer:` / `blk:`), c and cpp `statement_identifier`, go `label_name`. Java spells
-- it plain `identifier` and is deliberately NOT here -- ruby's bare `private` is an
-- identifier that IS a statement, and this set is consulted for every language.
-- (No field name to lean on either: only c/cpp declare `label:`, probed.)
local PARAM_SKIP = { block_parameters = true, block_label = true,
    statement_identifier = true, label_name = true }
local SUBSTMT_CLAUSES = {
    else_statement = true, elseif_statement = true, else_clause = true,
    elif_clause = true, elseif_clause = true, catch_clause = true,
    finally_clause = true, do_statement = true,
    case_statement = true, switch_case = true, when_entry = true,
    -- php AND odin spell the `elseif` KEYWORD `else_if_clause`, one underscore
    -- away from the `elseif_clause` above; ruby spells it `elsif`. Both were
    -- absent, so those branches' bodies had no descent route, and both were found
    -- by navcensus (CART-0458) rather than by reading the table — which is the
    -- point: a name set is only as complete as the last person to edit it.
    else_if_clause = true, elsif = true,
    -- python's `except`, and PEP 654's `except*` (probed: the node is
    -- `except_group_clause`). Its `else_clause` and `finally_clause` were already here
    -- under names it happens to SHARE with other grammars, so a try statement showed
    -- its body, its else and its finally and silently dropped every HANDLER — the one
    -- and only python cause in the census (CART-0460).
    except_clause = true, except_group_clause = true,
}
-- A CASE is a place you GO, not a wrapper to see through: it stays ONE form of
-- its own (so a switch reads as its arms) and its body statements are its DIRECT
-- children — `case 1: g(); break;` has no block between them. Checked BEFORE the
-- clause set, which two of these are also in.
-- NB langaudit cannot fence this: it reads `x:type() == 'literal'` comparisons,
-- and a TABLE of node types is correct-by-construction to it. The attribution on
-- each line is the only record of which grammar the name came from.
local SUBSTMT_CASES = {
    case_statement = true, default_statement = true,             -- php, c, cpp
    switch_case = true, switch_default = true,                   -- js/ts, zig, odin
    switch_block_statement_group = true, switch_rule = true,      -- java (`:` and `->`)
    expression_case = true, type_case = true, default_case = true, -- go
    match_arm = true,                                            -- rust
    when = true, ['else'] = true,                                -- ruby
    case_clause = true,                                          -- python
}
-- Wrappers a compound form hides behind in expression-oriented grammars: rust's
-- `match` is an EXPRESSION, so a bare `match x { … }` statement is an
-- expression_statement around a match_expression and the arms sit two levels
-- down. Seen THROUGH; never a form of their own.
-- zig's labeled_statement wraps BOTH a labeled loop (`outer: for (...) |i| {`) and a
-- plain braced block (an `else { }` parses as a labeled_statement with no label), and
-- transparent answers for both: as a child it is kept as the LABEL row, and descending
-- that row unwraps past the label to the loop or the block.
local SUBSTMT_TRANSPARENT = { expression_statement = true, match_expression = true,
    labeled_statement = true }
-- Where a case's LABEL ends and its body begins. Grammars mark it three ways and
-- a case may use any one, so all three are consulted: a separator TOKEN (php/c/
-- js/go/odin/python `:`, rust/zig `=>`, java's arrow form `->`), a label NODE of
-- its own (java's `switch_label`), or a named FIELD (ruby's `when`). The field
-- cannot be read blind — php's `case_statement.value` is the LABEL while rust's
-- `match_arm.value` is the BODY, so one blanket field rule would drop the body
-- of one language to keep the label of another.
local CLAUSE_SEP = { [':'] = true, ['=>'] = true, ['->'] = true }
local CLAUSE_LABEL_TYPE = { switch_label = true } -- java
local CLAUSE_LABEL_FIELD = { when = 'pattern' }   -- ruby
-- lisp: nesting is child LIST forms, not blocks
local LISP_LANGS = { scheme = true, commonlisp = true, clojure = true, fennel = true, janet = true }
-- the quote sigils and their unquotes: a wrapper the descent looks THROUGH
-- ★ THE UNQUOTES COME IN TWO FAMILIES AND I GUESSED ONE. `,`/`,@` inside a quasiquote
-- are `unquote`/`unquote_splicing`; `#,`/`#,@` inside a QUASISYNTAX are `unsyntax`/
-- `unsyntax_splicing`, separate node types. Adding only the first pair left 178 of
-- scheme's 546 traps and the census named the other two in one run -- the fix's own
-- gap, found by the tool the fix came from.
local LISP_QUOTE = { quote = true, quasiquote = true, syntax = true, quasisyntax = true,
    unquote = true, unquote_splicing = true, unsyntax = true, unsyntax_splicing = true }
-- top-of-file containers whose named children are statements (position mode)
local ROOT_TYPES = { chunk = true, program = true, source_file = true,
    translation_unit = true, module = true, block = true, ['end'] = true }

-- immediate sub-forms of `node`: nested statements (through block/clause
-- wrappers) for imperative langs; child list forms for lisp (the head symbol
-- and, for a def/lambda, the signature list are not sub-forms).
local function child_forms(node, lisp)
    local out = {}
    if lisp then
        -- every child list is a nested form (the caller drops the signature
        -- list of a def/lambda); bare symbols/atoms are leaves, not forms.
        -- A QUOTE SIGIL IS PUNCTUATION, not a level: `'`, `#'`, `` ` ``, `#\`` and the
        -- unquotes inside them each wrap the form they quote, and the wrapper carries no
        -- information a row could show that its content does not. Seeing through them is
        -- what opens guile's macro TEMPLATES (CART-0461): 575 of scheme's 584 trapped
        -- forms sat behind quasisyntax, quasiquote or syntax, i.e. behind `#`(begin
        -- #,@(fold ...))` -- code being built, holding lambdas and conditionals.
        -- The remaining 9 sat behind a plain `'`, which is DATA -- a literal alist -- and
        -- it is descendable on purpose: a collection literal is structure, and the
        -- browser draws structure ([[cartograph-vision]]: a general graph viewer).
        -- A VECTOR is not punctuation, so it keeps its row and descends like a list.
        local function emit_lisp(n)
            for _, c in inext, n, -1 do
                if c:named() then
                    local t = c:type()
                    -- @langs-ok scheme `list`/`vector` and the four quote sigils --
                    -- s-expression node types, scheme-only by construction
                    if t == 'list' or t == 'vector' then
                        out[#out + 1] = c
                    elseif LISP_QUOTE[t] then
                        emit_lisp(c)
                    end
                end
            end
        end
        emit_lisp(node)
        return out
    end
    -- A block's statements, for a block met as a CHILD or handed in as the node
    -- itself. Two subtractions: a PARAMETER list is not a statement (ruby's do_block
    -- holds `block_parameters` beside its body, and it was rendering as a `|x|` row --
    -- which the navigation census cannot see, because a census of what is MISSING is
    -- blind to what is spurious), and a block whose only remaining child is another
    -- block is a pure WRAPPER, so it flattens (ruby `do_block > body_statement`).
    local function emit_block(b)
        local kids = {}
        for _, g in inext, b, -1 do
            if g:named() and not tsutil.is_comment(g) and not PARAM_SKIP[g:type()] then
                kids[#kids + 1] = g
            end
        end
        if #kids == 1 and SUBSTMT_BLOCKS[kids[1]:type()] then return emit_block(kids[1]) end
        for _, g in ipairs(kids) do
            if SPLICE_BLOCKS[g:type()] then emit_block(g) else out[#out + 1] = g end
        end
    end

    -- `case` is true when `n` IS a case clause: then its own children are the
    -- body, so they are emitted from here -- everything past the label.
    -- `host` is the type of the node we were ASKED about, so a child of that same
    -- type is an `else if` WRITTEN AS TWO WORDS and must be seen through. It needs
    -- no name list, which is why it is threaded rather than tabled: the grammars
    -- disagree about where the nested if hangs (php/js/c/cpp/zig/rust put it under
    -- an else_clause, java/go make it the outer if's own child) and agree that it
    -- is spelled the same as its host.
    local function scan(n, case, host)
        local past, label = true, nil
        if case then
            for _, c in inext, n, -1 do
                if not c:named() and CLAUSE_SEP[c:type()] then past = false break end
            end
            local f = CLAUSE_LABEL_FIELD[n:type()]
            if f then label = n:field(f)[1] end
        end
        for _, c in inext, n, -1 do
            if not c:named() then
                if CLAUSE_SEP[c:type()] then past = true end
            elseif not tsutil.is_comment(c) then
                local t = c:type()
                if SUBSTMT_BLOCKS[t] then
                    emit_block(c)
                elseif SUBSTMT_CASES[t] then
                    out[#out + 1] = c -- an arm is a form, not a wrapper
                elseif SUBSTMT_CLAUSES[t] then
                    scan(c, false, host)
                elseif SUBSTMT_TRANSPARENT[t] and not case then
                    -- see through it to the block/arms inside -- but KEEP IT if there
                    -- is nothing in there. A transparent node exists to be looked past
                    -- when it wraps a control form (rust's `match` under an
                    -- expression_statement); when it wraps a plain call it IS the
                    -- statement, and looking past it dropped the entire body of every
                    -- braceless `if (x) a();` (CART-0457).
                    local before = #out
                    scan(c, false, host)
                    if #out == before then out[#out + 1] = c end
                elseif host and t == host and not case then
                    scan(c, false, host) -- `} else if (...) {`: the same form again
                elseif case and past and not CLAUSE_LABEL_TYPE[t]
                    and not (label and c:equal(label)) then
                    out[#out + 1] = c
                end
            end
        end
    end
    -- ★ THE NODE ITSELF. Every rule above reads the node's CHILDREN, so a block or a
    -- transparent wrapper HANDED IN was a dead end: ruby's `do |x|` body row, a bare
    -- `{ }` scope block in c++, and rust's whole if/for/while family (an if_expression
    -- under an expression_statement) all descended into nothing. The navigation census
    -- found all three as one family (CART-0457); they are one fix because the scan
    -- never asked what it was standing ON.
    local entry = node
    while SUBSTMT_TRANSPARENT[entry:type()] do
        local only
        for _, c in inext, entry, -1 do
            -- PARAM_SKIP is subtracted here for the same reason as in emit_block: a
            -- label is not a candidate body, and counting it would make zig's
            -- labeled_statement look like two children and stop the unwrap.
            if c:named() and not tsutil.is_comment(c) and not PARAM_SKIP[c:type()] then
                if only then only = nil break end -- more than one: do not guess
                only = c
            end
        end
        if not only then break end
        entry = only
    end
    if SUBSTMT_BLOCKS[entry:type()] then
        emit_block(entry)
        return out
    end
    scan(entry, SUBSTMT_CASES[entry:type()] or false, entry:type())
    return out
end

--- The descent step itself, for the NAVIGATION CENSUS (tools/navcensus.lua).
--- Exported rather than copied: ctrlcensus exists because a second copy of
--- flow's control set had drifted inside the probe that was measuring the fix,
--- which then reported the fix had not worked. An audit holding its own idea of
--- the answer audits itself, so the census walks THIS function -- the one the
--- browser descends with.
--- Takes the LANGUAGE, not the lisp flag: which languages nest by child lists
--- is this file's knowledge, and a caller that had to answer it would be holding
--- exactly the second copy this export exists to avoid.
--- @param node userdata  a TSNode
--- @param lang string    the grammar the node was parsed with
--- @return userdata[] the immediate sub-forms
function M.child_forms(node, lang)
    local lisp = LISP_LANGS[lang] or false
    -- THE ROOT IS THE ONE NODE child_forms CANNOT ANSWER FOR, and the browser
    -- never asks: it enters a file at the fn/region level, so the file's own
    -- statements arrive from the symbol list, not from a descent. A census that
    -- walks the whole file needs that first step, and taking it as "the root's
    -- named children" here keeps the census from owning a ROOT_TYPES copy. Lisp
    -- needs no special case -- its child-list rule already answers for the root.
    if not lisp and not node:parent() then
        local out = {}
        for _, c in inext, node, -1 do
            if c:named() and not tsutil.is_comment(c) then out[#out + 1] = c end
        end
        return out
    end
    return child_forms(node, lisp)
end

-- (binder_at — the scope-model shadow-attribution service — was RETIRED here
-- with df-strangler step-5 fine half: extract.plan, its last consumer, now takes
-- flow's scope-correct CFG reaching, so a shadowed name resolves by def ROW
-- without a separate on-demand binder resolver. [[cartograph-df-strangler]])

--- One form record. The form's OWN text (first line), so several forms sharing
--- a source line read distinctly; whitespace collapsed and truncated.
local function form_rec(node, src, lisp)
    local sr, sc, er, ec = node:range()
    return { sr = sr, sc = sc, er = er, ec = ec,
        text = node_text(node, src):gsub('%s+', ' '):gsub('^%s*', ''):sub(1, 80),
        branch = #child_forms(node, lisp) > 0 }
end

--- The node spanning an EXACT range. `named_descendant_for_range` answers the
--- ENCLOSING node whenever the range's end is not inside its own node — a
--- go/odin case arm's range runs on to the NEXT arm's indent, so the probe
--- answers `switch` and both the block view and its detail lens hand back the
--- arms you descended FROM. Detect that (the answer does not begin where the
--- range does), re-probe from the START and climb to the widest node that
--- begins there and still fits. Narrowed to that case on purpose: probing from
--- the start unconditionally regresses lua's nested `if`, where a `block` and
--- the `if_statement` inside it share a range and the climb takes the outer,
--- which child_forms cannot answer for.
local function node_for_range(root, sr, sc, er, ec)
    local n = root:named_descendant_for_range(sr, sc, er, math.max(sc, ec - 1))
    if not n then return nil end
    local nsr, nsc = n:range()
    if nsr == sr and nsc == sc then return n end
    local a = root:named_descendant_for_range(sr, sc, sr, sc)
    while a and a:parent() do
        local psr, psc, per, pec = a:parent():range()
        if psr == sr and psc == sc and (per < er or (per == er and pec <= ec)) then
            a = a:parent()
        else break end
    end
    if a then
        local asr, asc = a:range()
        if asr == sr and asc == sc then return a end
    end
    return n
end

--- Immediate sub-forms of a form in `file`, for the browser's block descent.
--- Three modes:
---   * EXACT node — pass the full range (sr,sc,er,ec) of a known node (a
---     function's body, or a sub-form returned by a previous call).
---   * POSITION — pass only (sr,sc): the enclosing STATEMENT at that point
---     (walking up but stopping before its block), e.g. a df row's line.
---   * RUN — pass a range plus `{ run = true }`: the top-level statements
---     INSIDE that range, for a subject that is a run of siblings rather than a
---     node (a region). Explicit because it cannot be inferred: a one-statement
---     run and that statement itself are the same range.
--- Returns a list of { sr, sc, er, ec (0-based, ec exclusive), text, branch },
--- branch = true when that sub-form has its own sub-forms (descend again).
--- Recomputed on demand — nothing is cached in the graph.
function M.forms(file, sr, sc, er, ec, opts)
    local _, spec = elang_for(file)
    local lang = parse_lang_for(file) -- TS parses under typescript, not js
    if not (lang and spec) then return {} end
    local src = transport.read_source(file)
    if not src then return {} end
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return {} end
    local tree = parser:parse()[1]
    if not tree then return {} end
    local root = tree:root()
    local lisp = LISP_LANGS[lang] or false

    local n
    if opts and opts.run then
        -- RUN MODE. A sibling run is not a node: a region — the browser's fold
        -- over a stretch of top-level statements between two function
        -- definitions — spans several siblings, and nothing in the tree carries
        -- exactly that range. The probe answers the enclosing `program` (whose
        -- forms would be the whole file) and the start-anchored climb answers
        -- the run's FIRST statement (whose forms are nothing). Neither is the
        -- run. So the caller, who knows it is asking about a run, says so — a
        -- heuristic here would have to guess between "this range IS one node,
        -- show me inside it" and "this range is a run, show me its members",
        -- and those are the same range whenever a run has one member.
        local host = root:named_descendant_for_range(sr, sc, er, math.max(sc, ec - 1))
        local out = {}
        for _, c in inext, host, -1 do
            if c:named() and not tsutil.is_comment(c) then
                local csr, csc, cer, cec = c:range()
                if (csr > sr or (csr == sr and csc >= sc))
                    and (cer < er or (cer == er and cec <= ec)) then
                    out[#out + 1] = form_rec(c, src, lisp)
                end
            end
        end
        return out
    end
    if er then
        -- exact node spanning the given range (ec exclusive -> inclusive probe)
        n = node_for_range(root, sr, sc, er, ec)
    else
        -- position mode: the statement that STARTS on row `sr` — the child of
        -- a block/root that begins there (indentation-agnostic; col ignored)
        local function find_stmt(node)
            local container = SUBSTMT_BLOCKS[node:type()] or ROOT_TYPES[node:type()]
                or SUBSTMT_CASES[node:type()] -- a case holds its statements directly
            for _, c in inext, node, -1 do
                if c:named() and not tsutil.is_comment(c) then
                    local csr, _, cer = c:range()
                    if container and csr == sr then return c end
                    if sr >= csr and sr <= cer then
                        local f = find_stmt(c)
                        if f then return f end
                    end
                end
            end
        end
        n = find_stmt(root)
    end
    if not n then return {} end

    -- a lisp def/lambda/let: the first list child is the signature/bindings,
    -- not a body form
    local drop_first_list = false
    if lisp then
        local head = n:named_child(0)
        -- @langs-ok scheme `symbol` — the s-expression head
        if head and head:type() == 'symbol' then
            local h = node_text(head, src)
            if h:match('^define') or h:match('^lambda') or h:match('^let')
                or h == 'named-lambda' then
                drop_first_list = true
            end
        end
    end

    local subs = child_forms(n, lisp)
    -- ...and it is the signature only if it sits IMMEDIATELY AFTER THE HEAD. Dropping
    -- the first list unconditionally was safe only while a quoted form could not be a
    -- form at all: the moment the quote sigils opened (CART-0461), `(define roman
    -- '((1000 #\M) ...))` had its alist taken for an argument list and
    -- `(define-syntax c (syntax-rules ...))` lost its whole transformer. Second named
    -- child or it stays.
    if lisp and drop_first_list and subs[1] then
        local second = n:named_child(1)
        if second and second:equal(subs[1]) then table.remove(subs, 1) end
    end

    local out = {}
    for _, s in ipairs(subs) do out[#out + 1] = form_rec(s, src, lisp) end
    return out
end

--- Every NAME MENTION in a source range, in source order, for the row-local pick
--- (CART-0471: reaching a variable inside a call is a POSITION question, not a
--- containment one). The type set is `spec.mention_types` -- the SAME declared set
--- the mention collector resolves with, so the pick can only offer names the graph
--- could have an opinion about, and no new per-language table is minted (php `name`,
--- haskell `variable`, bash `word`/`variable_name`, scheme `symbol`, identifier
--- elsewhere).
--- @return {text:string, sr:integer, sc:integer, er:integer, ec:integer}[]
function M.names(file, sr, sc, er, ec)
    local _, spec = elang_for(file)
    local lang = parse_lang_for(file)
    if not (lang and spec) then return {} end
    local src = transport.read_source(file)
    if not src then return {} end
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return {} end
    local tree = parser:parse()[1]
    if not tree then return {} end
    local idt = spec.mention_types or { identifier = true }
    local out, seen = {}, {}
    local function walk(n)
        local nsr, nsc, ner, nec = n:range()
        if ner < sr or nsr > er then return end -- no overlap with the asked range
        if n:named() and idt[n:type()] then
            local inside = (nsr > sr or (nsr == sr and nsc >= sc))
                and (ner < er or (ner == er and nec <= ec))
            local k = nsr .. ',' .. nsc
            if inside and not seen[k] then
                seen[k] = true
                out[#out + 1] = { text = node_text(n, src), sr = nsr, sc = nsc,
                    er = ner, ec = nec }
            end
        end
        for c in n:iter_children() do walk(c) end
    end
    walk(tree:root())
    table.sort(out, function(a, b)
        if a.sr ~= b.sr then return a.sr < b.sr end
        return a.sc < b.sc
    end)
    return out
end

local function container_trees(parser, clang)
    if not clang then return nil end
    -- injection queries may use nvim-treesitter's CUSTOM directives
    -- (svelte: set-lang-from-mimetype! for lang="ts" attributes). Workers
    -- have the plugin on their rtp but never load it — register the
    -- directives before the first injected parse. Idempotent.
    pcall(require, 'nvim-treesitter.query_predicates')
    local out = {}
    -- a failed injection parse degrades to an EMPTY region list (module
    -- skeleton, honest frontier), never to misreading the container tree
    -- as host code
    if not pcall(parser.parse, parser, true) then return out end
    parser:for_each_tree(function (tree, ltree)
        local hl = ltree:lang()
        if hl ~= clang and M.spec[hl] then
            local rt = tree:root()
            local sr, sc, er = rt:range()
            out[#out + 1] = { root = rt, lang = hl, spec = M.spec[hl],
                s = sr, c = sc, e = er }
        end
    end)
    table.sort(out, function (a, b)
        if a.s ~= b.s then return a.s < b.s end
        if a.c ~= b.c then return a.c < b.c end
        return a.e > b.e
    end)
    return out
end

local EXCLUDE_DIRS = { node_modules = true, vendor = true, dist = true,
    build = true, cache = true, minified = true,
    -- vendored-source conventions (hugo's deps/, azerothcore's deps/)
    deps = true, third_party = true, thirdparty = true, external = true }

local function list_files(root, subdirs, tp)
    tp = tp or transport
    local out, minified, tokens = {}, {}, {}
    local seen_real = {} -- external symlink targets already walked (cycles/dups)
    -- stack languages (forth/postscript) can't have a faithful grammar even in
    -- principle, so they're a SEPARATE provider — but they share this walk, and
    -- with it every exclusion rule. Third return, disjoint from `out` by
    -- extension: a file no spec claims, that a dialect does.
    local dialect_of = require('cartograph.providers.tokens').dialect_of
    local function in_scope(rel)
        if not subdirs then return true end
        for _, p in ipairs(subdirs) do
            if rel == p or rel:sub(1, #p + 1) == p .. '/' then return true end
        end
        return false
    end
    local function want(rel)
        if rel:match('%.min%.js$') then -- bundles: opaque frontiers, not source
            if in_scope(rel) then minified[#minified + 1] = rel end
            return false
        end
        return in_scope(rel)
    end
    local function rec(rel)
        -- transport.dir yields nothing for an unreadable container, which is
        -- what the old `while it do` guard did for a nil scandir handle
        for name, t in tp.dir(rel == '' and root or (root .. '/' .. rel)) do
            if name:sub(1, 1) ~= '.' then
                local r = rel == '' and name or (rel .. '/' .. name)
                -- WHAT THIS ENTRY REALLY IS is the SUBSTRATE's question, not the
                -- walk's: symlinks exist only on a filesystem, so the policy
                -- (follow a dir-link only when it leaves the root, skip an
                -- internal alias) lives in the disk transport. The walk keeps
                -- just the cross-entry DEDUP, which is generic set logic over
                -- whatever canonical identity the substrate hands back — two
                -- aliases to one real directory must not yield every file twice.
                local rty, canon = tp.resolve_entry(root, r, t)
                if canon then
                    if seen_real[canon] then rty = t else seen_real[canon] = true end
                end
                t = rty
                if t == 'directory' then
                    local ex = EXCLUDE_DIRS[name:lower()]
                    if not ex then
                        for _, x in ipairs(require('cartograph.config').exclude or {}) do
                            if name == x then ex = true break end
                        end
                    end
                    if not ex then rec(r) end
                elseif (lang_for(r) or container_for(r)) and want(r) then
                    out[#out + 1] = r
                elseif dialect_of(r) and want(r) then
                    tokens[#tokens + 1] = r
                end
            end
        end
    end
    rec('')
    table.sort(out)
    table.sort(minified)
    table.sort(tokens)
    return out, minified, tokens
end
-- the cache diffs the tree with the same walk/exclusion rules extraction uses.
-- Third return = the stack-language files, for the token provider; every
-- existing caller keeps at most two, so it costs them nothing.
function M.list_files(root, subdirs, tp) return list_files(root, subdirs, tp) end

-- ── mentions: collect (phase 1, tree live) + reduce (lookups ready) ──────
-- The id pass needs GLOBAL lookups (uniqueness is corpus-wide), so it used
-- to be a second read+parse of every file after the node set settled. Split
-- it instead: collect_mentions rides the phase-1 tree and packs every
-- identifier occurrence into a per-file varint string; reduce_mentions
-- replays the id-pass decisions over that buffer — pure table lookups, no
-- tree, no second parse. Lexical boundness (scope-model step 3) is the one
-- decision that needs the tree, so collect computes it EAGERLY with a scope
-- STACK folded on the fly during its single DFS: harvest a scope's symtab
-- on entry, pop on exit, answer per identifier from that name's active
-- binders — measured 3x cheaper than per-mention resolve() ancestor walks,
-- bound-for-bound identical on libs/self/server. Buffers stay small
-- (server: ~7 MB packed occurrences + ~4 MB interned names).

local MENTION_ID = { identifier = true }
local NO_NAMES = {}
-- pure-content pieces of a string literal, per grammar: anything ELSE
-- inside a string is interpolation (typed-strings v1: k='lit' means KNOWN)
local STR_PARTS = { string_content = true, string_value = true,
    string_fragment = true, string_start = true, string_end = true,
    escape_sequence = true, heredoc_start = true, heredoc_end = true }

-- LEB128, little-endian base-128
local function vput(parts, v)
    while v >= 0x80 do
        parts[#parts + 1] = string.char(v % 0x80 + 0x80)
        v = math.floor(v / 0x80)
    end
    parts[#parts + 1] = string.char(v)
end
local function vget(s, i)
    local v, m = 0, 1
    local b = s:byte(i)
    while b >= 0x80 do
        v = v + (b - 0x80) * m
        m = m * 0x80
        i = i + 1
        b = s:byte(i)
    end
    return v + b * m, i + 1
end

local MF_ELIGIBLE = 1 -- >=3 chars, non-stdlib: fn-ref / name-index candidate
local MF_CALLEE = 2   -- call position (the call pass already owns it)
local MF_BOUND = 4    -- lexically bound at the use site (scope stack)
local MF_SCOPED = 8   -- collected under a spec WITH a scope model
local MF_RANGE = 16   -- token isn't single-line name-width: explicit end follows
local MF_WRITE = 32   -- write position (anywhere on an assign-target chain)
local MF_GW = 64      -- x2 bits: write's guard class (0 unguarded / 1 guarded
                      -- / 2 set-once) — only meaningful when MF_WRITE set

-- the buffer must SHIP (worker chunk, binary codec): no spec table (it
-- holds functions), just the two spec facts the reduce needs
local function mention_buf(spec)
    return { names = {}, nidx = {}, ok = {}, parts = {}, n = 0,
        fnrefs = spec.id_fn_refs ~= false,
        noindex = spec.name_index == false,
        -- a write classifier ran: use edges may carry rw. Absent = the
        -- language ships NO mode (unknown), never a claimed "read".
        wmode = spec.is_write ~= nil or nil }
end

--- One DFS over a phase-1 tree: pack identifier occurrences (with
--- eligible/callee/bound flags) into buf — and, when extract registered
--- function bodies in `dfreg`, compute df-lite IN THE SAME WALK (the
--- second rider). df-lite: each body's top-level statements with def/use
--- NAME lists and def->use dependencies — approximate (no scoping) but
--- structurally the lua-ls df contract, so the fn altitude and extract
--- engine work. Nested fn bodies feed EVERY enclosing context (a stack),
--- exactly as the old per-fn walks did. Binder tags (scope-model phase 2)
--- come straight off the LIVE scope stack at the def site — the same
--- answer jvt_sm.resolve gave post-walk, without retaining nodes.
--- Shared by the fused extract and the standalone id_pass (refresh path,
--- which passes no dfreg — extract already computed df for those files).
-- dfrec: build the legacy df RECORD off the fn-node stack (the oracle's
-- independent df, opts.legacy_df). When false, the stack is still tracked for
-- write-axis (pw) attribution, but no def/use/dep is accumulated — df comes
-- from flow.coarse (df-strangler step 6).
-- esc (CART-0236): the THIRD rider. A table = collect into it the names this
-- file mentions in a VALUE position (the confinement fact, CART-0230), which is
-- the same question `callee` already answers for one shape; the rest of the rule
-- is grammar and lives in spec.escape_nonvalue. Its own walk was +14% of the
-- whole extract, and it asked a tree this one is already holding.
local function collect_mentions(buf, tsroot, src, spec, dfreg, dfrec, esc)
    local scopes = spec.scopes
    local idt = spec.mention_types or MENTION_ID
    local wgate, is_write, guards = spec.write_gate, spec.is_write, spec.guards
    local wq, wqn = {}, 0 -- queued write mentions (stride 5, see below)
    local nm = buf.nm or 0 -- mention ordinal (continues across region calls)
    local FLDGATE = { dot_index_expression = true, bracket_index_expression = true,
        member_access_expression = true, subscript_expression = true,
        variable_name = true }
    local dfid = spec.df_ids
    local modskip = spec.binding_modifiers -- CART-0234
    local escnv = esc and spec.escape_nonvalue -- CART-0236
    -- WHICH PARENT NODE TYPES HOLD A CALLEE NAME, declared per language rather
    -- than guessed from a global list (CART-0499). Same shape as escape_nonvalue
    -- above and keyed the same way — on the PARENT type, which is what the walk
    -- has in hand — because the four-name `or` chain this replaces was inline in
    -- the provider, where nothing could audit it: langaudit cannot see a table of
    -- node-type names (CART-0451) and it certainly cannot see an or-chain.
    local callpos = spec.call_positions
    local stdlib = spec.stdlib_names or NO_NAMES
    local names, nidx, nok, parts = buf.names, buf.nidx, buf.ok, buf.parts
    local scoped = scopes and MF_SCOPED or 0
    local active = {} -- name -> stack of visibility rows (false = scope-wide)
    local ctxs, nctx = {}, 0 -- open df contexts (dfrec only), innermost last
    local fnstack, fdepth = {}, 0 -- enclosing fn NODES, for pw attribution
    -- (tracked always — decoupled from the df-record build ctxs above)

    local function walk(n, defpos, dfon)
        local nt = n:type()
        local pushed
        local entry = scopes and scopes[nt]
        if entry then
            local t = {}
            entry.harvest(n, src, t)
            pushed = {}
            for name, b in pairs(t) do
                local a = active[name]
                if not a then a = {} active[name] = a end
                a[#a + 1] = b.row or false
                pushed[#pushed + 1] = name
            end
        end
        local bodyctx = dfreg and dfreg[n:id()]
        if bodyctx then
            fdepth = fdepth + 1
            fnstack[fdepth] = bodyctx.node -- always: pw attribution
            if dfrec then                  -- oracle df record build only
                nctx = nctx + 1
                ctxs[nctx] = bodyctx
                bodyctx.stmts = {}
            end
        end
        local callk = callpos and callpos[nt]
        -- df def positions are THIS node's gift to its children:
        -- assignment lefts, declarators, transparent wrappers
        local asgleft, decld, dfk, declist
        if nctx > 0 then
            if nt == 'assignment_statement' or nt == 'assignment'
                or nt == 'assignment_expression'
                or nt == 'augmented_assignment_expression'
                or nt == 'variable_assignment' then -- bash x=… (name field)
                asgleft = n:field('left')[1] or n:field('name')[1]
                    or n:child(0)
                dfk = 1
            elseif nt == 'declaration_command' then -- bash local/declare
                dfk = 2
            elseif nt == 'init_declarator' or nt == 'variable_declarator' then
                decld = n:field('declarator')[1] or n:field('name')[1]
                dfk = 3
            elseif defpos and (nt == 'pointer_declarator'
                or nt == 'array_declarator') then
                -- C/C++ `Type *p`, `**pp`, `arr[N]`: def-position continues down
                -- the `declarator` field to the inner name (NOT to array `size`
                -- or pointer `type_qualifier`, which are uses/non-names).
                decld = n:field('declarator')[1]
                dfk = 3
            elseif nt == 'declaration' then
                -- C/C++ declaration: EVERY `declarator`-field child is
                -- def-position (bare `int x;` / `Foo *p;`, multi `int a, b;`,
                -- and `= init` via init_declarator). The `type` field is left
                -- alone. This is what defs a NO-INITIALIZER declaration's name
                -- (init_declarator only exists WITH `=`).
                declist = n:field('declarator')
                dfk = 7
            else
                -- def position survives transparent wrappers only; C++
                -- `reference_declarator` (`Type &r`) has no declarator field —
                -- its lone named child IS the inner declarator.
                dfk = defpos and (nt == 'variable_list'
                    or nt == 'variable_name' or nt == 'reference_declarator')
            end
        end
        local i, c = 0, n:child(0)
        while c do
            local ct = c:type()
            -- A BINDING MODIFIER (lua 5.4 `<const>`/`<close>`) decorates a declaration and
            -- references nothing, so its subtree is skipped ENTIRELY — no mention, no df
            -- use. Without this the identifier inside it became a mention of a symbol named
            -- `const`, which is a phantom REFERENCE the moment a corpus really has one
            -- (`local const = require 'const'` is idiomatic). Language-declared, because the
            -- same node name is python's field access. CART-0234, the third collector: expr
            -- and flow's du had the identical fabrication.
            if modskip and modskip[ct] then
                i = i + 1
                c = n:child(i)
                goto continue_child
            end
            -- LAZY per-child facts: named() is an FFI call and most java
            -- children are anonymous tokens — pay it only on paths that
            -- consume it (the regression the first fused draft measured)
            local cnamed, cdfon, name
            local cdefpos, cdfid
            if nctx > 0 then
                cnamed = c:named()
                if bodyctx and cnamed and not tsutil.COMMENT[ct] then
                    -- a body's direct named children ARE its statements
                    bodyctx.cur = { l = c:range() + 1,
                        def = {}, use = {}, dep = {} }
                    bodyctx.sd, bodyctx.su = {}, {}
                    bodyctx.stmts[#bodyctx.stmts + 1] = bodyctx.cur
                end
                if dfon and cnamed then
                    if dfk == 1 then cdefpos = c == asgleft
                    elseif dfk == 2 then cdefpos = ct == 'variable_name'
                    elseif dfk == 3 then cdefpos = c == decld
                    elseif dfk == 7 then
                        cdefpos = false
                        for _, dd in ipairs(declist) do if c == dd then cdefpos = true break end end
                    else cdefpos = dfk end
                    if ct == 'identifier' or ct == 'name'
                        or (dfid and dfid[ct]) then cdfid = true end
                end
                cdfon = dfon and cnamed and not cdfid
            else
                cdfon = true -- df restarts fresh at the next body anyway
            end
            if cdfid then
                name = node_text(c, src)
                for k = 1, nctx do
                    local x = ctxs[k]
                    local st = x.cur
                    if st then
                        if cdefpos then
                            if not x.sd[name] then
                                x.sd[name] = true
                                st.def[#st.def + 1] = name
                            end
                        elseif not x.su[name] and not x.sd[name] then
                            x.su[name] = true
                            st.use[#st.use + 1] = name
                        end
                    end
                end
            end
            if idt[ct] and (cnamed or cnamed == nil and c:named()) then
                if name == nil then name = node_text(c, src) end
                local sr, sc, er, ec = c:range()
                -- THE CALLEE TEST, from the declaration. `callk` is a FIELD NAME
                -- or a named-child INDEX (see spec/contract.lua); the index form
                -- is for grammars that give the position no field at all — a
                -- sexp's head, a rust macro name, bash's command_name — and it
                -- also costs nothing, where field() allocates a table per call.
                -- This is now ONE field() lookup instead of the two the old chain
                -- did for every mention inside any call node.
                local callee = false
                if callk ~= nil then
                    callee = (type(callk) == 'number' and n:named_child(callk)
                        or n:field(callk)[1]) == c
                end
                if escnv and not callee then
                    -- a value mention unless the grammar says this position is
                    -- not one. `nt` is the PARENT type (n is c's parent), which is
                    -- exactly what the spec table is keyed on.
                    local k = escnv[nt]
                    if k == nil or (k ~= true and n:named_child(k) ~= c) then
                        esc[name] = true
                    end
                end
                local idx = nidx[name]
                if not idx then
                    idx = buf.n + 1
                    buf.n = idx
                    nidx[name] = idx
                    names[idx] = name
                    nok[idx] = (#name >= 3 and not stdlib[name]) or nil
                end
                local bound
                local a = active[name]
                if a then
                    for j = #a, 1, -1 do
                        local r = a[j]
                        if r == false or r <= sr then bound = true break end
                    end
                end
                local flags = scoped + (nok[idx] and MF_ELIGIBLE or 0)
                    + (callee and MF_CALLEE or 0) + (bound and MF_BOUND or 0)
                local simple = er == sr and ec == sc + #name
                if not simple then flags = flags + MF_RANGE end
                local iswrite = wgate and wgate[nt] and is_write(c, n)
                if iswrite then flags = flags + MF_WRITE end
                nm = nm + 1
                -- FIELD CAPTURE: which field does this mention access —
                -- ships as (ordinal, name-id) pairs; the reduce aggregates
                -- per use edge (e.flds). Gated on the parent type: zero
                -- cost for plain mentions.
                if FLDGATE[nt] then
                    local fname = mention_field(c, n, src)
                    if fname then
                        local fidx = nidx[fname]
                        if not fidx then
                            fidx = buf.n + 1
                            buf.n = fidx
                            nidx[fname] = fidx
                            names[fidx] = fname
                            nok[fidx] = (#fname >= 3 and not stdlib[fname]) or nil
                        end
                        local l = buf.fld
                        if not l then l = {}; buf.fld = l end
                        l[#l + 1] = nm
                        l[#l + 1] = fidx
                    end
                end
                vput(parts, idx)
                vput(parts, sr)
                vput(parts, sc)
                parts[#parts + 1] = string.char(flags)
                if iswrite and guards then
                    -- classify OUT OF LINE (its loops would break the JIT
                    -- trace of this hot loop): queue node + flag-slot index
                    -- + ordinal + the enclosing fn's node (pw attribution)
                    wqn = wqn + 1
                    local b = wqn * 5
                    wq[b - 4], wq[b - 3], wq[b - 2], wq[b - 1] = c, n, #parts, nm
                    wq[b] = fdepth > 0 and fnstack[fdepth] or false
                end
                if not simple then
                    vput(parts, er)
                    vput(parts, ec)
                end
            end
            if head and (cnamed or cnamed == nil and c:named()) then
                head = false
            end
            if c:child(0) then walk(c, cdefpos, cdfon) end
            i = i + 1
            c = n:child(i)
            ::continue_child::
        end
        if bodyctx then
            fdepth = fdepth - 1
        end
        if bodyctx and dfrec then
            nctx = nctx - 1
            bodyctx.cur, bodyctx.sd, bodyctx.su = nil, nil, nil
            local stmts = bodyctx.stmts
            if #stmts > 0 then
                -- dependencies + free inputs
                local defined, inputs, inset = {}, {}, {}
                for _, p in ipairs(bodyctx.params or {}) do defined[p] = 0 end
                for si, st in ipairs(stmts) do
                    for _, u in ipairs(st.use) do
                        local from = defined[u]
                        if from and from > 0 then
                            st.dep[#st.dep + 1] = { from = from, var = u }
                        elseif from == nil and not inset[u] then
                            inset[u] = true
                            inputs[#inputs + 1] = u
                        end
                    end
                    for _, d in ipairs(st.def) do
                        defined[d] = defined[d] or si
                    end
                end
                bodyctx.node.df = { inputs = inputs, stmts = stmts }
            end
            bodyctx.stmts = nil
        end
        if pushed then
            for k = #pushed, 1, -1 do
                local a = active[pushed[k]]
                a[#a] = nil
            end
        end
    end
    walk(tsroot, false, true)
    buf.nm = nm
    -- the deferred guard classification: a tight monomorphic loop, the
    -- flag byte patched in place (each flag is its own parts slot). The
    -- param predicate (±index) can't ride the FULL flag byte — it ships
    -- as flat (ordinal, gp) pairs on the buffer (JSON-safe for workers).
    local pwseen
    for i = 1, wqn do
        local b = i * 5
        local g, gp, pw = guard_class(wq[b - 4], wq[b - 3], src, guards)
        if g > 0 then
            local slot = wq[b - 2]
            parts[slot] = string.char(parts[slot]:byte() + g * MF_GW)
        end
        if gp then
            local l = buf.gp
            if not l then l = {}; buf.gp = l end
            l[#l + 1] = wq[b - 1]
            l[#l + 1] = gp
        end
        -- the param-write fact lands on the FN NODE (a node fact, minted
        -- at extract; refresh re-extracts the file, so it stays fresh)
        local fnode = pw and wq[b]
        if fnode then
            local set = fnode._pwset
            if not set then set = {}; fnode._pwset = set; pwseen = pwseen or {}; pwseen[#pwseen + 1] = fnode end
            set[pw] = true
        end
    end
    if pwseen then
        for _, fnode in ipairs(pwseen) do
            local set = fnode._pwset
            if set then
                local arr = fnode.pw or {}
                for _, x in ipairs(arr) do set[x] = true end
                local out2, k2 = {}, 0
                for x in pairs(set) do k2 = k2 + 1; out2[k2] = x end
                table.sort(out2)
                fnode.pw = out2
                fnode._pwset = nil
            end
        end
    end
end

--- WHICH FILES DEFINE A VAR, derived from the lookups the pass already holds
--- rather than threaded alongside `fn_ranges`. Four call paths supply that table
--- (fused inline, refresh, the parallel accumulator, the demand materializer)
--- and a fifth field would have to survive worker serialization on one of them;
--- `var_named` is already on all four, so the answer is a fold over it.
--- Memoized on L, which lives exactly as long as one pass.
--- NARROW CAVEAT: under `narrow` (the demand path) var_named is name-filtered,
--- so this set is too -- a file whose only var is outside the wanted name set
--- reads as having none. That path materializes one file for one query and its
--- mentions were already narrowed; noted rather than papered over.
local function var_files(L)
    local s = L._varfiles
    if not s then
        s = {}
        for _, lst in pairs(L.var_named or {}) do
            for _, v in ipairs(lst) do s[v.file] = true end
        end
        L._varfiles = s
    end
    return s
end

--- Replay the id-pass decisions over a collected buffer: pure lookups
--- against L (the same callback contract id_pass always took).
local function reduce_mentions(file, buf, L)
    -- NO EARLY RETURN ON A FILE WITHOUT FUNCTIONS. `fn_at` below is allowed to
    -- answer nil now (the mention belongs to the module), so an empty extent
    -- list is a working input rather than a reason to stop -- and stopping here
    -- was the third gate, after the two in extract, that made a php config
    -- file's file-scope writes unreachable (CART-0479).
    local ranges = L.fn_ranges[file] or {}
    -- ...but the FN-REF half of this pass stays scoped to files that always had
    -- it. Opening the gate for var-only files scaled `reg` edges on mantis from
    -- 751 to 4047 (CART-0501 holds that measurement, and it must be RE-RUN: it
    -- was taken while `iscall` was still blind to php, so most of those 4047
    -- were mislabelled calls that v145 has since removed).
    -- ★ THE ENTANGLEMENT THIS COMMENT USED TO CLAIM IS GONE. It said fixing the
    -- call-position list was blocked on owner-less call sites, because "the reg
    -- edge is today the only record the call happened". It was not:
    -- own_module_calls (v107) already adds a REF EDGE FROM THE ENCLOSING REGION
    -- for every resolved module-level call — measured on full mantisbt, 10949
    -- owner-less resolved calls and exactly 10949 region-sourced ref
    -- occurrences. So v145 named the call positions on its own, and of 724
    -- removed (file -> target) reg pairs ZERO were left without a surviving
    -- edge. What CART-0455 still owns is the `fn` FIELD (own_module_calls adds
    -- an edge and never sets it), which is why no altitude can list those calls
    -- — a different fact from reachability, and not touched here.
    local fnref_ok = L.fn_ranges[file] ~= nil
    local fnrefs = buf.fnrefs
    local names = buf.names
    local function fn_at(line)
        local best
        for _, r in ipairs(ranges) do
            if r.s <= line and line <= r.e
                and (not best or r.s >= best.s) then best = r end
        end
        return best and best.id
    end
    local useEdge, regEdge = {}, {}
    local wmode = buf.wmode
    local gpmap
    if buf.gp then
        gpmap = {}
        for i = 1, #buf.gp, 2 do gpmap[buf.gp[i]] = buf.gp[i + 1] end
    end
    local fldmap
    if buf.fld then
        fldmap = {}
        for i = 1, #buf.fld, 2 do fldmap[buf.fld[i]] = buf.fld[i + 1] end
    end
    local ord = 0
    local m = buf.m
    local i, len = 1, #m
    while i <= len do
        local idx, sr, sc, flags
        idx, i = vget(m, i)
        sr, i = vget(m, i)
        sc, i = vget(m, i)
        flags = m:byte(i)
        i = i + 1
        ord = ord + 1
        local name = names[idx]
        local er, ec = sr, sc + #name
        local gw = 0
        if flags >= MF_GW then
            gw = (flags - flags % MF_GW) / MF_GW
            flags = flags % MF_GW
        end
        local write
        if flags >= MF_WRITE then
            write = true
            flags = flags - MF_WRITE
        end
        if flags >= MF_RANGE then
            flags = flags - MF_RANGE
            er, i = vget(m, i)
            ec, i = vget(m, i)
        end
        local scoped = flags >= MF_SCOPED
        local bound = flags % MF_SCOPED >= MF_BOUND
        local callee = flags % MF_BOUND >= MF_CALLEE
        local eligible = flags % MF_CALLEE >= MF_ELIGIBLE
        if eligible and not callee and fnrefs and fnref_ok then
            local u = L.fn_unique[name]
            if u and L.scopes and L.scopes[u.file] ~= L.scopes[file] then
                u = nil -- unique, but across a boundary
            end
            -- lexical-first (scope-model step 3): a BOUND name never
            -- crosses the file boundary
            if u and scoped and u.file ~= file and bound then u = nil end
            if u and not (u.file == file and sr == u.line) then
                local from = fn_at(sr)
                local at = { start = { line = sr, char = sc },
                    ['end'] = { line = er, char = ec } }
                if from then
                    L.addref(from, u.id, at, true)
                else
                    -- referenced from top-level DATA (a dispatch table /
                    -- registry): the fn is kept alive, and the reference is
                    -- a REGISTRATION edge from this module — an alibi you
                    -- can descend into.
                    -- This used to ALSO set the node's cbarg mark. It no longer
                    -- does: the `reg` edge below is minted from the same branch,
                    -- so the flag was a strictly redundant copy of an edge —
                    -- and being a node field it was INDISTINGUISHABLE from the
                    -- two cbarg classes that mean something else (a table-field
                    -- def; a callback argument). That mattered because cbarg
                    -- gates the same-file CONFIRMED tier while this pass runs
                    -- AFTER resolution: extract resolved before the mark existed
                    -- and confirmed, relink read it off the ingested node and
                    -- hedged — the whole extract-vs-relink divergence
                    -- tools/resolveparity measures. Extract was the one that was
                    -- RIGHT (`local function f` called directly from the same
                    -- file is confirmed; appearing in the module's `return {...}`
                    -- export table does not make that call dynamic), so the cure
                    -- is to stop feeding this class to resolution at all.
                    -- Consumers that want "referenced from data" ask the edge:
                    -- band:registrants(id) / :n_registrants(id).
                    -- [[cartograph-merging-strategies]]
                    local rk = file .. '\31' .. u.id
                    local e = regEdge[rk]
                    if not e then
                        e = { from = file, to = u.id, kind = 'reg', at = {} }
                        regEdge[rk] = e
                        L.adduse(e)
                    end
                    e.at[#e.at + 1] = at
                end
            end
        end
        local cands = L.var_named[name]
        if cands then
            local var
            for _, v in ipairs(cands) do
                if v.file == file then var = v break end
            end
            if not var and #cands == 1
                and not (L.scopes and L.scopes[cands[1].file]
                    ~= L.scopes[file]) then
                -- the cross-file unique fallback only for FREE names:
                -- bound never crosses the file boundary
                if not (scoped and bound) then var = cands[1] end
            end
            -- A MENTION ON *ANY* SAME-FILE HOMONYM'S DEF LINE IS NOT A USE.
            -- The skip used to name only the RESOLVED candidate's line, which
            -- was enough while a file-scope mention was dropped anyway. It is
            -- not enough now: `local x = 1` … `local x = 2` in one lua chunk
            -- mints two var nodes, the loop above resolves both mentions to the
            -- FIRST, and the second one's own def line would arrive here as a
            -- write claiming x@1 was reassigned. Lua says it was not -- that is
            -- a NEW binding shadowing the old -- so the edge would be a
            -- fabrication, and cartograph's own tree holds 90 such pairs.
            -- Whether a redefinition is a re-assignment (php `$g = …` twice) or
            -- a shadow (lua `local` twice) is the declaration-vs-assignment
            -- axis the specs do not carry yet (CART-0500), so this widens the
            -- SKIP: php rival re-assignments stay invisible as writes until
            -- then. Under-reporting is the safe direction; a colliding claim
            -- fabricates. [[cartograph-expr-attribute-collision]]
            local ownline = false
            if var then
                for _, v in ipairs(cands) do
                    if v.file == file and sr == v.line then ownline = true break end
                end
            end
            if var and not ownline then
                -- ★ A FILE-SCOPE MENTION BELONGS TO THE MODULE. `fn_at` is nil
                -- for a mention outside every function extent, and this branch
                -- used to drop it -- while the fn-ref branch twenty lines above
                -- has always fallen back to the FILE node for the same reason
                -- ("referenced from top-level DATA"). The consequence measured
                -- on mantis: 2129 of 2537 vars had NO use edge of any kind and
                -- the state atlas read `const` over the empty set, 84% of every
                -- var the browser can open. A module node's id IS its file
                -- path, so `from` stays a resolvable node id either way.
                -- (The `do` is what the `if from then` guard became: `from`
                -- can no longer be nil, and the block still scopes k/e.)
                local from = fn_at(sr) or file
                do
                    local k = from .. '\31' .. var.id
                    local e = useEdge[k]
                    if not e then
                        e = { from = from, to = var.id, kind = 'use', at = {} }
                        useEdge[k] = e
                        L.adduse(e)
                    end
                    e.at[#e.at + 1] = { start = { line = sr, char = sc },
                        ['end'] = { line = er, char = ec } }
                    -- FIELD FACTS: per-edge per-field packed rw+gw*4
                    -- ('' = whole-var access — rebinds, f(state), pairs)
                    if wmode then
                        local fi = fldmap and fldmap[ord]
                        local fname = fi and names[fi] or ''
                        local fl = e.flds
                        if not fl then fl = {}; e.flds = fl end
                        local cur = fl[fname] or 0
                        local prevrw = cur % 4
                        local rwb = write and 2 or 1
                        if prevrw ~= rwb and prevrw ~= 3 then
                            prevrw = prevrw == 0 and rwb or 3
                        end
                        local g = (cur - cur % 4) / 4
                        if write then
                            local gg = gw + 1
                            if g == 0 or gg < g then g = gg end
                        end
                        fl[fname] = prevrw + g * 4
                    end
                    -- the write axis: 1 read / 2 write / 3 both, OR of the
                    -- edge's occurrences — only where a classifier ran
                    -- (buf.wmode); elsewhere mode stays ABSENT, never "read"
                    if wmode then
                        local mode = write and 2 or 1
                        if e.rw ~= mode and e.rw ~= 3 then
                            e.rw = e.rw and 3 or mode
                        end
                        -- guard chain, MIN over write occurrences (a true
                        -- claim about ALL writes): 1 some-unguarded /
                        -- 2 all-guarded / 3 all-SET-ONCE (commutative)
                        if write then
                            local g = gw + 1
                            if not e.gw or g < e.gw then e.gw = g end
                            -- param predicate: kept only when EVERY write
                            -- agrees on the same ±param index (false = dead)
                            local gp = gpmap and gpmap[ord]
                            if e.gp == nil then e.gp = gp or false
                            elseif gp ~= e.gp then e.gp = false end
                        end
                    end
                end
            end
        end
    end
    -- a dead param predicate (conflicting/unguarded writes) reads as absent
    for _, e in pairs(useEdge) do
        if e.gp == false then e.gp = nil end
    end
    -- the per-file identifier NAME SET (the mention index): what lets a
    -- later splice answer "which files mention this global?" without a
    -- corpus scan
    if L.add_names and not buf.noindex and buf.n > 0 then
        local ns = {}
        for j = 1, buf.n do
            if buf.ok[j] then ns[#ns + 1] = names[j] end
        end
        if #ns > 0 then
            table.sort(ns) -- deterministic pack (worker == inline)
            L.add_names(file, '\31' .. table.concat(ns, '\31') .. '\31')
        end
    end
end

-- The id pass: identifier occurrences naming a known top-level var (same
-- file, or unique across the workspace) or — outside call position — a
-- unique function (dispatch tables, registry values). A top-level
-- function reference becomes a `reg` edge, which is what says a
-- dispatch-table entry is not dead code (it used to also flag the node
-- cbarg; see reduce_mentions for why that stopped). Takes SUPPLIED lookups because
-- every decision is corpus-global: slice-local uniqueness is not global
-- uniqueness. This standalone form (read + parse + collect + reduce) is
-- the REFRESH path; the fused extract collects during phase 1 and only
-- reduces here-style at the end — no second parse.
-- L = { fn_unique = name -> {id,file,line,node?} (globally unique fns),
--       var_named = name -> { {id,file,line}, ... } (top-level vars),
--       fn_ranges = file -> { {s,e,id}, ... },
--       addref(from,to,at,inferred), adduse(edge),
--       add_names(file, packed)? — per-file identifier NAME SET (the
--       mention index: \31-separated, sorted; ≥3 chars, stdlib excluded),
--       recorded while we're iterating every identifier anyway. This is
--       what lets a later splice answer "which files mention this
--       global?" without a corpus scan. Gated per language:
--       spec.name_index = false opts a language out (when bare-identifier
--       mention does not imply potential global use). }
local function id_pass(root, files, L, abs, tp)
    tp = tp or transport
    abs = abs or function (f) return root .. '/' .. f end
    for _, file in ipairs(files) do
        -- same widening as the fused gate: a var-only file has mentions
        if L.fn_ranges[file] or var_files(L)[file] then
            local lang, spec = lang_for(file)
            local clang = container_for(file)
            if clang then lang, spec = 'javascript', M.spec.javascript end
            local src = tp.read_source(abs(file))
            local okp, parser = pcall(vim.treesitter.get_string_parser,
                src or '', clang or lang)
            if src and okp then
                local troots = container_trees(parser, clang)
                    or { { root = parser:parse()[1]:root(), spec = spec,
                        lang = lang } }
                local buf = mention_buf(spec)
                for _, tr in ipairs(troots) do
                    collect_mentions(buf, tr.root, src, tr.spec)
                end
                buf.m = table.concat(buf.parts)
                reduce_mentions(file, buf, L)
            end
        end
    end
end

--- Global name lookups for the standalone id pass, from a full node set.
--- Used by the parallel driver (phase 2) and refresh (changed files).
--- The global lookups the id pass / mention reduce resolve against.
---
--- NARROWING (`narrow`, index-and-reduce step 2, [[cartograph-merging-strategies]]):
--- a demand query touches a handful of names, and holding the whole corpus's
--- fn_unique/var_named resident to answer it is the cost the thin index exists to
--- avoid. `narrow = { names = <set>, files = <set> }` restricts the RESULT to
--- those names — identical, for every name in the set, to the unnarrowed build.
---
--- The invariant, and it is the whole reason this is a name filter and not a file
--- filter: NARROW THE OUTPUT, NEVER THE EVIDENCE.
---
---   · fn_unique is a CORPUS-WIDE uniqueness claim (count[name] == 1). Filter the
---     nodes by FILE and count undercounts, so a name that is ambiguous across the
---     repo looks unique in the slice and resolves to the wrong def — the ghost/v8
---     bug the parity gate caught, and why a worker slice's "unique" is a batch
---     artifact (see the pre-scan note in extract). Filter by NAME and every
---     bearer of a retained name is still counted, so count is exact.
---   · scopes: `sp.scope(f, fileset, root)` walks UP through `fileset` for a crate
---     root (rust lib.rs/main.rs). Narrowing that fileset erases roots, so two
---     files in different crates would compare equal and cross-crate matches would
---     stop being refused. So `narrow` limits WHICH files get a scope computed —
---     the retained candidates plus the caller's own files, since the reduce
---     compares scopes[candidate.file] against scopes[mention.file] — while the
---     fileset it is computed AGAINST stays the complete module roster.
---
--- That roster is why the module nodes must stay resident wholesale under any
--- future demand loading of `nodes`: one node per file, and the scope evidence
--- depends on all of them.
---@param nodes table
---@param root string
---@param narrow table|nil  { names = set, files = set } — nil = the whole corpus
function M.lookups(nodes, root, narrow)
    local want = narrow and narrow.names or nil
    local count = {}
    for _, n in ipairs(nodes) do
        if (not want or want[n.name])
            and (n.kind == 'function' or n.kind == 'method') and not n.torn
            and not n.decl then -- a prototype declaration is not a call target
            count[n.name] = (count[n.name] or 0) + 1
        end
    end
    local fn_unique, var_named = {}, {}
    for _, n in ipairs(nodes) do
        if want and not want[n.name] then -- outside the narrowed name set
        elseif n.torn then -- beyond a parse error: never name-matched
        elseif (n.kind == 'function' or n.kind == 'method')
            and not n.decl and count[n.name] == 1 then
            fn_unique[n.name] = { id = n.id, file = n.file,
                line = atr.sl(n.range) }
        elseif n.kind == 'var' and not n.sql and not n.ctype then
            -- interface types/macros (ctype) are browse-only, not use targets
            var_named[n.name] = var_named[n.name] or {}
            table.insert(var_named[n.name],
                { id = n.id, file = n.file, line = atr.sl(n.range) })
        end
    end
    -- scope map: languages with a resolution boundary (rust crates) get
    -- their id-pass matches confined to it
    local fileset, scopes, any = {}, {}, false
    for _, n in ipairs(nodes) do
        if n.kind == 'module' then fileset[n.file] = true end
    end
    -- which files need one (see the header): the retained candidates' files, so
    -- the reduce can compare a candidate's scope, plus the caller's own files,
    -- whose mentions are the other side of that comparison
    local only
    if narrow then
        only = {}
        for _, e in pairs(fn_unique) do only[e.file] = true end
        for _, lst in pairs(var_named) do
            for _, e in ipairs(lst) do only[e.file] = true end
        end
        for f in pairs(narrow.files or {}) do only[f] = true end
    end
    for f in pairs(fileset) do
        if not only or only[f] then
            local _, sp = elang_for(f)
            if sp and sp.scope then
                scopes[f] = sp.scope(f, fileset, root) -- fileset stays COMPLETE
                any = true
            end
        end
    end
    return { fn_unique = fn_unique, var_named = var_named,
        scopes = any and scopes or nil }
end

--- Fold a standalone id-pass result into a graph: ref pairs dedup into
--- existing edges (like addref). Shared by refresh and the parallel driver.
function M.merge_idpass(data, out, touched)
    local refEdge = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' then refEdge[e.from .. '\31' .. e.to] = e end
    end
    for _, e in ipairs(out.edges or {}) do
        local k = e.kind == 'ref' and (e.from .. '\31' .. e.to)
        local ex = k and refEdge[k]
        if ex then
            for _, at in ipairs(e.at or {}) do ex.at[#ex.at + 1] = at end
            if not e.inferred then ex.inferred = nil end
        else
            if k then refEdge[k] = e end
            data.edges[#data.edges + 1] = e
        end
        if touched then
            touched[e.from:match('^(.-)::') or e.from] = true
        end
    end
    if out.names then
        data.names = data.names or {}
        for f, s in pairs(out.names) do data.names[f] = s end
    end
end

--- Standalone id pass over `files` with global lookups (parallel phase
--- 2, run inside a worker). Returns { edges = {...}, names = {...} }.
local function idpass_sink(lookups)
    local out = { edges = {}, names = {} }
    local refEdge = {}
    local L = {
        fn_unique = lookups.fn_unique,
        var_named = lookups.var_named,
        fn_ranges = lookups.fn_ranges,
        scopes = lookups.scopes,
        add_names = function (f, s) out.names[f] = s end,
        addref = function (from, to, at, inferred, tinf)
            local k = from .. '\31' .. to
            local e = refEdge[k]
            if not e then
                e = { from = from, to = to, kind = 'ref', at = {},
                    self = (from == to) or nil, inferred = inferred or nil }
                refEdge[k] = e
                out.edges[#out.edges + 1] = e
            end
            if not inferred then e.inferred = nil end
            e.at[#e.at + 1] = at
        end,
        adduse = function (e) out.edges[#out.edges + 1] = e end,
    }
    return L, out
end

function M.id_pass(root, files, lookups, abs, tp)
    local L, out = idpass_sink(lookups)
    id_pass(root, files, L, abs, tp)
    return out
end

--- Parallel phase 2 without processes: reduce SHIPPED mention buffers
--- (collected by phase-1 workers) against parent-built global lookups.
--- Same output contract as M.id_pass.
function M.mention_reduce(files, mentions, lookups)
    local L, out = idpass_sink(lookups)
    for _, file in ipairs(files) do
        local buf = mentions[file]
        if buf then reduce_mentions(file, buf, L) end
    end
    return out
end

-- OVERLAY PACKS ([[cartograph-modular-specs]]): a framework/DSL layer that
-- COMPOSES onto a base language spec — the unit of modularity is the framework,
-- not the language. A pack targets a `lang` and contributes additive vocab
-- (`stdlib_names`, unioned) and def-emitters (`synth_defs`, chained). The base
-- ruby spec stays pure Ruby; the `rails` pack adds the ActiveRecord/ActiveSupport
-- verbs (moved out of ruby.stdlib_names) + association/delegate def-emitters.
-- Activated per-corpus (corpus.packs / opts.packs); measurable with-vs-without.
M.packs = {
    rails = {
        lang = 'ruby',
        -- ActiveRecord / ActionController / ActiveSupport verbs: framework
        -- methods, refused rather than absorbed by a project def
        stdlib_names = { save = true, update = true, destroy = true,
            find = true, where = true, create = true, build = true,
            params = true, render = true, perform = true, process = true,
            valid = true, present = true, blank = true, errors = true },
        synth_defs = ruby_rails_synth,
        -- R5b-more receiver typing ([[cartograph-ruby-arc]]): ActiveRecord class
        -- FINDERS that return a model INSTANCE. `x = User.find(id); x.foo` types
        -- x as User (→ User#foo), riding the R5 ctor-bind path (spec.ctor_finders
        -- threaded into ruby_ctor_binds). ONLY instance-returning finders —
        -- where/all/order return a Relation (NOT an instance), and generic
        -- first/last/take are collection methods on any receiver (measured 0
        -- wins, over-reach risk). Measured +40 sound / 0 loss on the rails corpus.
        ctor_finders = { find = true, find_by = true, ['find_by!'] = true,
            find_or_create_by = true, ['find_or_create_by!'] = true,
            find_or_initialize_by = true, find_sole_by = true },
    },
    -- the test-DSL pack (RSpec + factory_bot) — the second ruby pack, proving
    -- MULTI-PACK composition (rails + rspec) and cleaning the spec-dir census
    -- skew (measured: 45% of spec calls are DSL verbs, all "unresolved" without
    -- it). v1 = VOCAB only: the DSL verbs become honest framework refusals. The
    -- `let`/`subject`/`described_class` DEF-EMITTERS (which need an example-group
    -- block scoping model — spec code is blocks, not methods) are a v2 sub-rung.
    rspec = {
        lang = 'ruby',
        stdlib_names = {
            -- structure + hooks
            describe = true, context = true, it = true, specify = true,
            example = true, before = true, after = true, around = true,
            let = true, ['let!'] = true, subject = true, its = true,
            described_class = true, xit = true, fit = true, pending = true,
            skip = true,
            -- expectations + matchers
            expect = true, to = true, to_not = true, not_to = true,
            eq = true, eql = true, equal = true, be = true, match = true,
            include = true, contain_exactly = true, raise_error = true,
            change = true, have_attributes = true, respond_to = true,
            satisfy = true, start_with = true, end_with = true, be_within = true,
            -- mocks / stubs
            allow = true, receive = true, double = true, instance_double = true,
            class_double = true, spy = true, have_received = true,
            receive_messages = true, expect_any_instance_of = true,
            allow_any_instance_of = true,
            -- shared examples/context
            shared_examples = true, shared_context = true,
            it_behaves_like = true, it_should_behave_like = true,
            include_examples = true, include_context = true,
            -- factory_bot (build/create overlap the rails pack — union is fine)
            build_stubbed = true, attributes_for = true, create_list = true,
            build_list = true, create_pair = true, ['stub_const'] = true,
        },
    },
}

-- Build the effective spec for `lang` when overlay `packs` (a list of pack
-- tables) are active: union stdlib_names, chain synth_defs; everything else is
-- inherited from the base via metatable. Returns nil when no pack targets this
-- lang (the caller keeps the base spec). Pure — never mutates the base.
function M.compose_spec(lang, base, packs)
    if not base then return nil end
    local applicable = {}
    for _, p in ipairs(packs) do
        if p.lang == lang then applicable[#applicable + 1] = p end
    end
    if #applicable == 0 then return nil end
    local composed = setmetatable({}, { __index = base })
    local sn = {}
    for k in pairs(base.stdlib_names or {}) do sn[k] = true end
    local synths = base.synth_defs and { base.synth_defs } or {}
    -- ctor_finders (rails R5b-more): union the packs' instance-returning finder
    -- sets onto the base's (base ruby has none → pure-Ruby stays `.new`-only).
    local cf, cf_any = {}, base.ctor_finders ~= nil
    for k in pairs(base.ctor_finders or {}) do cf[k] = true end
    for _, p in ipairs(applicable) do
        for k in pairs(p.stdlib_names or {}) do sn[k] = true end
        if p.synth_defs then synths[#synths + 1] = p.synth_defs end
        if p.ctor_finders then
            cf_any = true
            for k in pairs(p.ctor_finders) do cf[k] = true end
        end
    end
    composed.stdlib_names = sn
    if cf_any then composed.ctor_finders = cf end
    if #synths > 0 then
        composed.synth_defs = function (tsroot, src)
            local all = {}
            for _, fn in ipairs(synths) do
                for _, d in ipairs(fn(tsroot, src)) do all[#all + 1] = d end
            end
            return all
        end
    end
    return composed
end

-- A memoized spec-overlay resolver: eff_spec(lang, spec) applies the active pack
-- composition (base ⊕ packs) and the L2 profile overlay (base ⊕ L2), once per
-- lang. extract and relink build the SAME thing over their own active_packs /
-- active_profile — this is that shared closure, memo per call (fresh per builder).
local function spec_overlay(active_packs, active_profile)
    local composed_spec = {}
    return function (lang, spec)
        if not lang then return spec end
        local c = composed_spec[lang]
        if c == nil then
            c = (#active_packs > 0 and M.compose_spec(lang, spec, active_packs)) or spec
            if active_profile and lang == active_profile.lang then
                c = setmetatable({ _profile = active_profile }, { __index = c })
            end
            composed_spec[lang] = c
        end
        return c
    end
end

-- A namespace-aperture refusal resolver: if `name` is prefixed by a registered
-- namespace (ns_pfx) and something conjures that namespace — a per-file aperture,
-- else the global witness — the ref is refused with that witness; nil = no
-- aperture story (stay silent). extract and relink build the same resolver over
-- their own ns_pfx / apertures / global_witness (all final by construction time).
local function aperture_refuser(ns_pfx, apertures, global_witness)
    return function (name, file)
        local pfx = name:match('^([^/#]+)[/#]')
        if not (pfx and ns_pfx[pfx]) then return nil end
        local w = apertures[file]
            and { file = file, line = apertures[file][1].line }
            or global_witness
        if not w then return nil end
        return { rule = 'aperture', witness = w.file .. ':' .. (w.line + 1) }
    end
end

-- A ref-edge adder: dedups (from,to) 'ref' edges through `refEdge` and appends
-- each new one to `edges`; a re-add accumulates the occurrence range in e.at and
-- upgrades tiers (a confirmed ref clears `inferred`; `tinf` is upgrade-only).
-- extract and relink share this over their own refEdge + edge list (data.edges,
-- which extract aliases as a local `edges`).
-- MODULE-LEVEL OWNERSHIP (v107). A call outside any function resolves fine —
-- target found, call.to set — and its edge used to be dropped because `from` was
-- nil, so top-level code contributed nothing to the call graph. Von-Neumann
-- measured 69 region nodes over 2045 source lines and 0 of its 110 call edges;
-- `createScript`, called from a top-level `return function() … end`, read as 0
-- callers AND 0 registrants. The bare-NAME path already kept its top-level
-- evidence as a registration from the module, so the WEAKER evidence survived
-- while an actual CALL was discarded.
--
-- A POST-PASS, and that is the whole point. Resolution happens in several passes,
-- each ending `if fn then addref(...)`, and patching them one by one produced an
-- INLINE-VS-PARALLEL SPLIT: the inline passes dropped what they resolved while
-- relink's single fallback kept it, so a parallel extraction grew edges (and one
-- tier flip) that the inline one lacked. The matrix `par` column caught it on 12
-- corpora. Running once over the FINISHED call records makes the rule
-- pass-independent, so both paths attribute exactly the same set: in parallel a
-- worker owns what it resolved and relink owns the rest, and addref dedupes by
-- (from,to) so a union is safe.
--- The region index, derived from the NODES rather than from extraction-time
--- bookkeeping. Both drivers have nodes, so both build the SAME index — which is
--- the point: the first version had extract read its own `regionRanges` while
--- relink rebuilt from node_index, and the two disagreed on 2 of 12 sites in
--- haskell alone (inline 10 region-owned edges, parallel 12). Identical call sets
--- and identical region sets make the rule deterministic per call, so a worker's
--- share plus relink's share is exactly the inline set.
--- Ranges are read through `atr`: a TABLE at extract, a packed NUMBER after ingest.
local function region_index(nodes)
    local byfile = {}
    for _, nd in pairs(nodes) do
        if nd.kind == 'region' and nd.stmtrun and nd.file and nd.range then
            local l = byfile[nd.file]
            if not l then l = {}; byfile[nd.file] = l end
            l[#l + 1] = nd
        end
    end
    return function (file, line)
        local best
        for _, nd in ipairs(byfile[file] or {}) do
            local sl, el = atr.sl(nd.range), atr.el(nd.range)
            if sl <= line and line <= el
                and (not best or sl >= atr.sl(best.range)) then best = nd end
        end
        return best and best.id
    end
end

--- @param count integer  how many call records there are
--- @param get fun(i:integer, field:string):any  field accessor for record `i`
--- Takes an ACCESSOR rather than a list because relink reads its calls through a
--- COLUMN VIEW while extract holds plain records. One rule, two adapters — writing
--- the rule twice is exactly what produced the split this pass exists to close.
local function own_module_calls(count, get, region_at, addref)
    local added = 0
    for i = 1, count do
        local to, fn, file = get(i, 'to'), get(i, 'fn'), get(i, 'file')
        if to and not fn and file then
            local at = get(i, 'at')
            local line = (at and at.start and at.start.line) or get(i, 'line')
            local reg = line and region_at(file, line)
            -- reg ~= to guards the degenerate self-edge (a region that IS the target)
            if reg and reg ~= to then
                addref(reg, to, at
                    or { start = { line = line, char = 0 },
                        ['end'] = { line = line, char = 0 } }, get(i, 'inferred'))
                added = added + 1
            end
        end
    end
    return added
end

local function ref_adder(refEdge, edges)
    return function (from, to, at, inferred, tinf)
        local k = from .. '\31' .. to
        local e = refEdge[k]
        if not e then
            e = { from = from, to = to, kind = 'ref', at = {},
                self = (from == to) or nil, inferred = inferred or nil }
            refEdge[k] = e
            edges[#edges + 1] = e
        end
        if not inferred then e.inferred = nil end
        if tinf then e.tinf = true end -- type-inferred tier (upgrade-only)
        e.at[#e.at + 1] = at
    end
end

--- INDEX-ONLY front-end ([[cartograph-thin-index]]): the thin symbol index — parse +
--- DEF nodes only (no calls, df, flow, mentions, or resolution). Reuses extract's own
--- extract_defs, so the def set is byte-faithful to a full extract's; ~10x cheaper in
--- time + memory (thinindex probe). LSP def/symbol/nav serve off this; calls/df/flow
--- defer to on-demand full extraction. Returns a schema-1 graph with nodes only.
function M.index_only(root, opts)
    local o = { defs_only = true }
    for k, v in pairs(opts or {}) do o[k] = v end
    o.defs_only = true
    local data = M.extract(root, o)
    -- HONESTY MARKER ([[cartograph-thin-index]]): this graph has NO call graph / effect
    -- PDG (calls were never built). Whole-graph verbs — untangle/reorder/references/call-
    -- hierarchy AND the call-graph SUMMARIES (census/ladder/externals/escalate) — refuse
    -- (commands.whole_graph) rather than serve a degraded/empty answer that reads as
    -- "none" (e.g. census "nodes 0", ladder "0 calls", externals "0 external"). A full
    -- :Cartograph open ingests fresh data without the marker → clears it.
    -- The FIELD is provenance and stays set for the lifetime of this graph, because the
    -- cache decides on it (warm_decision must never serve a thin cache to a full open,
    -- and a partial graph's self-type map must not overwrite a whole one). The verbs go
    -- through store.is_index_only(), which answers the narrower CAPABILITY question and
    -- goes false once on-demand materialization has covered every file — see the
    -- provenance-vs-capability note there.
    data.index_only = true
    return data
end

--- Extract a neutral-schema graph from a directory tree. Any file whose
--- extension has a spec (and an available parser) participates.
---@param root string
---@return table data  the schema-1 graph (ready for store.ingest)
function M.extract(root, opts)
    if M.PROFILE then prof = {}; prof._t0 = vim.uv.hrtime() end
    -- turn over per-EXTRACTION derived state ([[cartograph-validity]]): the spec
    -- layer's per-root memos (package identity, addon/plugin layout) derive from a
    -- TREE, so a cheap validity key does not exist for them — they key on this
    -- epoch instead. Bumping here is what makes a second extraction see a tree that
    -- changed since the first, which it previously could not.
    require('cartograph.validity').bump('extract')
    -- a URI root (self://loaded — the running instance's multi-root corpus)
    -- keeps off the filesystem's path rules: its files are plugin-labelled
    -- keys (telescope.nvim/lua/…) that resolve to real directories through
    -- opts.abs. A plain directory root joins as before.
    if not root:match('^%w+://') then
        root = vim.fn.fnamemodify(vim.fn.expand(root), ':p'):gsub('/+$', '')
    end
    local abs = (opts and opts.abs) or function (f) return root .. '/' .. f end
    -- WHERE BYTES COME FROM, threaded exactly like opts.abs above (which says
    -- how to LOCATE a file; this says how to READ one). A declarative spec
    -- rebuilds into a live stack — opts.transport may be either, since a stack
    -- answers the same op set as the module's disk-only default. Threaded rather
    -- than global because extraction also runs in spawned worker processes
    -- (parallel.lua), which a module-level registry could never reach.
    -- accepts EITHER a live stack (it has the ops) or a declarative spec (it does
    -- not, so build it): a worker receives the spec, an in-process caller may
    -- pass either. Nothing threaded = the module's disk-only stack.
    local tp = opts and opts.transport
    if tp and not tp.read then tp = transport.build(tp) end
    tp = tp or transport
    -- INDEX-ONLY front-end ([[cartograph-thin-index]] M.index_only): parse + DEF nodes
    -- only — no per-def flow/df, no calls, no mentions/refs, no resolution. Yields the
    -- thin symbol index (id/name/kind/file/range/exported/torn/decl/ret) the LSP/nav
    -- def-and-symbol path needs; calls/df/flow defer to on-demand full extraction.
    local defs_only = opts and opts.defs_only or nil
    -- DATAFLOW-ONLY ([[cartograph-thin-index]] on-demand materialization): defs + per-def
    -- df/flow, but NO calls, mentions, or resolution. df/flow are LOCAL (per-function), so a
    -- file's df/flow extracted alone is byte-faithful to a full extract's — used to fill a
    -- file's dataflow on demand (analysis/refactoring verbs) over the resident def index,
    -- without the whole-graph relink calls would need. (defs_only skips df/flow; this keeps it.)
    local dataflow_only = opts and opts.dataflow_only or nil
    local files, minified
    if opts and opts.files then
        -- explicit work list (parallel batches, demand extraction):
        -- no tree walk, no bundle synthesis — the caller owns both
        files, minified = opts.files, {}
    else
        local _plf = pstart()
        files, minified = list_files(root, opts and opts.subdirs, tp)
        padd('list_files', _plf)
    end
    -- ★ WHAT `.h` MEANS, DECIDED ONCE, FROM THE WHOLE TREE (CART-0410). The rule needs
    -- the FULL file list, and a worker never has one — `opts.files` is a BATCH, and a
    -- batch of `include/*.h` contains no C++ source and would answer C for a C++ repo.
    -- So the parent decides and threads `opts.h_lang` down, exactly as it threads
    -- transport and packs, and for the same reason the comment above gives: a
    -- module-level registry cannot reach a spawned process.
    -- opts.fileset is the parent's full list when one was passed (demand extraction).
    M.set_h_lang(opts and opts.h_lang
        or M.h_lang_for(opts and opts.fileset or files))

    local fileset = {}
    for _, f in ipairs(opts and opts.fileset or files) do fileset[f] = true end
    for _, f in ipairs(files) do fileset[f] = true end
    -- IMPORTABLE is fileset plus the OPAQUE FRONTIERS (bundles): a `*.min.js` is a
    -- real file that a real import targets, and leaving it unresolvable meant the
    -- import edge vanished AND every call through the imported name was disposed
    -- `external` — a project-boundary claim about a file we simply never parsed.
    -- Kept SEPARATE from fileset because fileset also drives the SCOPE map (rust
    -- crates, addon/package boundaries), and a bundle has no business acquiring a
    -- scope; only import resolution should see it.
    local importable = {}
    for f in pairs(fileset) do importable[f] = true end
    for _, f in ipairs(minified or {}) do importable[f] = true end

    -- stamps: what each parsed file's truth is keyed to (mtime+size — a
    -- display-honesty gate for edits that arrive OUTSIDE nvim, not an
    -- eviction key, so no content hash needed). store.stale() compares.
    local data = { schema = 1, root = root, provider = 'treesitter',
        capabilities = { calls = true, litdata = true, df = 'lite' },
        -- CARRIED ON THE GRAPH so a later re-parse agrees with the build (CART-0410).
        -- Analysis re-parses (expr, lens, optimize) run long after extraction and often
        -- in another process off a CACHE LOAD, with only a repo-relative path in hand —
        -- they cannot re-derive this, and deriving it from a loaded SHARD would be
        -- wrong anyway (a shard can be all headers). store.ingest re-adopts it.
        h_lang = M.h_lang(),
        nodes = {}, edges = {}, calls = {}, stamps = {} }
    local nodes, edges, calls = data.nodes, data.edges, data.calls
    local no_parser = {}

    -- overlay packs (rails): compose the pack's vocab + def-emitters onto the
    -- base spec per language. Stored on data.packs so relink/refresh re-apply
    -- the same. `eff_spec` wraps a base spec with the composition (memoized).
    -- S2 ([[cartograph-repo-shapes]]): with NO explicit packs, DEFAULT from the
    -- project shape (packs_for's UP-walk) — opening a Rails app (or a sub-dir)
    -- auto-activates the pack. Explicit opts.packs DISPOSES, incl. an explicit
    -- `{}` (packless) — so nil (absent) triggers detection, {} does not.
    local packnames = opts and opts.packs
    if packnames == nil then
        _shapes_mod = _shapes_mod or require 'cartograph.shapes'
        packnames = _shapes_mod.packs_for(root)
    end
    local active_packs = {}
    for _, pn in ipairs(packnames) do
        if M.packs[pn] then active_packs[#active_packs + 1] = M.packs[pn] end
    end
    if #packnames > 0 then data.packs = packnames end
    -- L2 env profile the repo shape implies (factorio-mod → lua-factorio); nil
    -- for an unshaped root. Composed AFTER packs (base ⊕ L2 ⊕ L3), memoized/lang.
    -- opts.profile DISPOSES of the shape's choice (CART-0217): a name activates that
    -- profile, `false` activates none. Recorded on data.profile like the detected
    -- case, so relink/refresh and the cache identity see what was actually used.
    local active_profile = active_profile_for(root, opts and opts.profile)
    if active_profile then data.profile = active_profile.runtime end
    local eff_spec = spec_overlay(active_packs, active_profile)

    -- per-name def indexes for the resolution pass
    local exact, tail = {}, {} -- name -> {fn node,...}; last segment -> {...}
    local varsByName = {}      -- name -> {var node,...}
    local constDefs = {}       -- file -> name -> string|false (const-fold index,
                               -- set-once scalar-string bindings; false=poisoned)
    local lastFn = {}          -- file -> last emitted fn node (equation merging)
    local fnRanges = {}        -- file -> { {s=line, e=line, id=id}, ... }
    local varFiles = {}       -- file -> true if it DEFINES a var (a mention target)
    local mentions = {}        -- file -> packed mention buffer (Stage B)
    local pending = {}         -- unresolved references, matched after all files

    -- ids are file::name@line — two same-name defs on ONE line (minified
    -- bundles, same-line C++ prototypes) must not silently ALIAS in every
    -- by-id index; a collision appends ~2, ~3… (validator: node-dup-id)
    local idseen = {}
    local function uid(id)
        if not idseen[id] then idseen[id] = true; return id end
        local k = 2
        while idseen[id .. '~' .. k] do k = k + 1 end
        id = id .. '~' .. k
        idseen[id] = true
        return id
    end

    local function fn_at(file, line)
        local best
        for _, r in ipairs(fnRanges[file] or {}) do
            if r.s <= line and line <= r.e and (not best or r.s >= best.s) then best = r end
        end
        return best and best.id
    end


    local function stamp(file)
        local s = tp.stamp(abs(file))
        if s then data.stamps[file] = s end
    end

    -- defs: functions, top-level vars, blocks, imports — one TREE at
    -- a time, so container files (vue/svelte SFCs) can run it once per
    -- script region while plain files run it on their single root
    -- escpend (CART-0236): a table = the mention walk will answer the confinement
    -- question for this file, so collect the fn nodes that WANT the answer and let
    -- the caller stamp them once the set exists (a post-pass per file, still well
    -- before resolution, which runs after the whole file loop). nil = no mention
    -- walk is coming (index-only front-ends): fall back to the spec's own walk,
    -- which is then the file's ONLY walk.
    local function extract_defs(file, lang, spec, src, tsroot, dfreg, escpend)
        -- df-strangler step 6: production DERIVES df from flow.coarse (no
        -- second AST walk). The legacy dfreg df-build survives ONLY as the
        -- parity ORACLE, gated on opts.legacy_df (bench.extract) so dfparity
        -- compares flow.coarse against an INDEPENDENT df, not a circular echo.
        local legacy_df = opts and opts.legacy_df or false
        tree_model(tsroot, src, spec) -- df binder tags read the shared model
        -- a def extracted from BEYOND a parse error has escaped its
        -- context (magento's php5 `$s{0}` truncates the class; the
        -- methods after it float unqualified and absorb tails). Torn
        -- defs stay visible — jumpable nodes — but are never indexed
        -- for name matching: refuse, don't absorb
        local errow
        if tsroot:has_error() then
            local function rec(n)
                if n:type() == 'ERROR' then return (n:range()) end
                if not n:has_error() then return nil end
                local best
                for _, c in inext, n, -1 do
                    local r = rec(c)
                    if r and (not best or r < best) then best = r end
                end
                return best
            end
            errow = rec(tsroot)
        end
        -- torn policy. Default: everything beyond the FIRST error row —
        -- calibrated on truncated class contexts (magento php5), where a
        -- def after the error has lost its enclosing qualifier. Languages
        -- whose defs carry no enclosing context opt into NODE-LOCAL
        -- tearing (spec.torn_by_node): torn only when the error sits
        -- inside the def's own subtree. bash needs this — one exotic
        -- parameter expansion at line 580 must not tear the remaining 98%
        -- of a 26k-line script (testssl.sh, ble.sh contribs measured).
        local function torn_of(dn, sp)
            if spec.torn_by_node then
                return errow ~= nil and dn:has_error() or nil
            end
            return errow and sp.start.line >= errow or nil
        end
        -- functions / vars / interface / super: ONE cursor (fusion
        -- Stage A). Every query cursor walks the WHOLE tree in C, and
        -- this ran four of them per file; the sections' captures are
        -- disjoint (@name = function, @vname = var, @child/@parent =
        -- super, a category capture = interface), so each match of the
        -- CONCATENATED query self-identifies and dispatches inline.
        -- Section-relative match order is a subsequence of tree order —
        -- all the order the sections ever relied on (merge_equations,
        -- seen_var). Underscore captures (@_kw) are predicate helpers
        -- and never dispatch.
        -- start line of every fn/method def, for block flushing. Keyed by
        -- LINE, not node: TSNode identity does not survive across
        -- traversals (== is a metamethod, table keys are raw).
        local fnDefLines = {}
        -- a multi-assignment (`a, b = 1, 2`) cross-products name×value in
        -- the query, so dedup by the (name,line) id it produces
        local seen_var = {}
        -- CONFINEMENT (CART-0230). For a def the spec calls file-local, does its name
        -- ever appear in this file in a VALUE position? One walk per file, lazily, and
        -- only for languages that answer the question at all. Tri-state like
        -- `exported`: nil = never asked, and every consumer must test `== false`.
        -- (Per REGION, not per file, for container files — a name defined in one
        -- script region and passed as a value in another would read as confined. Only
        -- lua defines the hook and lua files are single-region, but a spec adding it
        -- for an SFC language needs to widen this first.)
        local escset
        local function escapes_file(nm)
            if not spec.escape_names then return nil end
            escset = escset or spec.escape_names(tsroot, src)
            return escset[nm] == true
        end
        -- `aname` (optional): an ANONYMOUS fn (a callback arrow/function passed
        -- as a call argument, no binding name) — extracted as its own fn node so
        -- its body has a home (its own df/flow, its inner calls attribute to IT
        -- via fn_at). Given a synthetic display name; NOT added to the name
        -- resolution index (exact/tail) — it is never a call target by name.
        -- `spec.skip_def`: a per-def veto, for a captured def that must not become a
        -- NAME in the graph. The other gates are per-language blankets (toplevel_only /
        -- toplevel_parent); this one asks about THIS def, because a query can match a
        -- shape whose soundness depends on something no query can test — js
        -- `X.y = function(){}` is a definition when X is a module namespace and junk
        -- when X is a function-local object (MEASURED: a local `opt.complete = …` in
        -- jquery answered every bare `complete()` callback call in the corpus).
        local function handle_fn(defn, namen, aname)
            if defn and (namen or aname)
                and not (not aname and spec.toplevel_only
                    and in_function(defn, spec))
                and not (not aname and spec.skip_def
                    and spec.skip_def(defn, namen, src))
                and not (not aname and spec.toplevel_parent and defn:parent()
                    and defn:parent():type() ~= spec.toplevel_parent) then
                local name = aname
                if not name then
                    name = name_text(namen, src)
                    if spec.qualify then name = spec.qualify(name, defn, src) end
                end
                local sp = pos_of(defn)
                local method = not aname and spec.is_method(name, defn)
                local id = uid(('%s::%s@%d'):format(file, name, sp.start.line))
                local params = fn_params(defn, spec, src, method and lang == 'lua')
                -- tri-state visibility: true/false = the provider's
                -- verdict (lint trusts it over kind heuristics);
                -- nil = this language has no visibility concept
                local exp
                if spec.exported_def then
                    exp = spec.exported_def(defn, src) == true
                end
                -- and if it IS file-local: did the value ever leave? Asked only where
                -- the answer can change a resolution (exp == false), so no file pays
                -- the walk for a language or a def the guard cannot use.
                local wantesc = exp == false and not aname
                local esc
                if wantesc and not escpend then esc = escapes_file(name) end
                local isfield = aname and true
                    or (spec.field_fn_cbarg
                        -- @langs-ok lua/haskell/odin `field` — the callback-arg field shape this spec hook needs
                        and namen:parent() and namen:parent():type() == 'field')
                if spec.cbarg_within and not isfield then
                    local a = defn:parent()
                    while a do
                        if spec.cbarg_within[a:type()] then isfield = true break end
                        a = a:parent()
                    end
                end
                if spec.cbarg_def and not isfield then
                    isfield = spec.cbarg_def(defn, src) or false
                end
                -- multi-equation definitions (haskell) are ONE function:
                -- fold this equation into the previous node
                local prev = not aname and spec.merge_equations and lastFn[file]
                if prev and prev.name == name then
                    prev.range['end'] = sp['end']
                    for _, r in ipairs(fnRanges[file] or {}) do
                        if r.id == prev.id then r.e = sp['end'].line break end
                    end
                    fnDefLines[sp.start.line] = true
                    goto fn_done
                end
                local torn = torn_of(defn, sp)
                -- FINE flow rows (df-strangler step 4): eager per-fn flow, folded
                -- at ingest (store.ingest). Coverage MATCHES the generic df
                -- (body_field langs) — haskell's custom-dataflow model isn't
                -- imperative, so flow skips it and df's hook stays sole there.
                -- cfg mirrors df: method seeds 'self' exactly as df's fn_params
                -- (`method and lang=='lua'`) so flow.params ≡ df params → coarse
                -- parity is airtight. Keep only {stmts,params} (cfg is build-time).
                -- flow/df are per-def dataflow — the bulk. defs_only skips them (the
                -- symbol stub carries none); the declared-return summary (dret) stays,
                -- it's a cheap signature read the index/summaries want.
                local _pf = pstart()
                local fl = not defs_only and (spec.body_field or spec.body_of)
                    and flowmod.build(defn, src, {
                    pfield = spec.params_field, df_ids = spec.df_ids,
                    mods = spec.binding_modifiers, -- CART-0234
                    body_of = spec.body_of, params_of = spec.params_of, -- CART-0305
                    fn_types = M.flow_stop(lang), -- the nested-fn STOP, not the
                    -- enclosure set: only where a node is minted to hold the rows
                    ctrl = spec.ctrl, preloop = spec.preloop,
                    body = spec.body, clause = spec.clause, -- CART-0363
                    blocks = spec.blocks,                   -- attached blocks (part B)
                    binder_fields = spec.binder_fields,     -- destructuring/imports (CART-0358)
                    regime = spec.regime, method = method and lang == 'lua' }) or nil
                padd('flow.build', _pf)
                local dret, dretclass
                if spec.def_ret then dret, dretclass = spec.def_ret(defn, src) end
                -- df (step 6): a custom-df lang (haskell) builds its own; every
                -- generic body_field lang DERIVES df from flow.coarse — the
                -- coarse projection of the fine rows already built, no second
                -- walk. Under legacy_df the derivation is SKIPPED so the dfreg
                -- rider below can build df independently (the oracle target).
                local dfrec
                local _pco = pstart()
                if not defs_only and spec.dataflow then
                    dfrec = spec.dataflow(defn, spec, src, params)
                elseif fl and not legacy_df then
                    local co, inputs = flowmod.coarse(fl)
                    dfrec = { inputs = inputs, stmts = co }
                end
                padd('flow.coarse', _pco)
                nodes[#nodes + 1] = { id = id, name = name,
                    kind = method and 'method' or 'function', file = file,
                    range = sp, order = sp.start.line, params = params,
                    -- in-function local bindings (js family; local-shadow gate)
                    locals = not aname and fn_locals(defn, spec, src) or nil,
                    -- an arrow inherits `this` lexically; a regular function
                    -- rebinds it — the B3 this-typing walk needs to tell them apart
                    -- @langs-ok js/ts `arrow_function` — the B3 this-typing walk is a JS-family concern
                    arrow = defn:type() == 'arrow_function' or nil,
                    cbarg = isfield or nil,
                    -- unconditional module-load def (lua): a load-order sibling
                    -- for the reassignment-override resolver (resolve_reassign)
                    top = (lang == 'lua' and toplevel_def(defn)) or nil,
                    exported = exp,
                    -- CART-0230: only meaningful with exported == false. true = the
                    -- name is mentioned in a value position in its own file, so the
                    -- value may have escaped; false = it provably never did.
                    escapes = esc,
                    torn = torn,
                    entry = (spec.entry_names or {})[name] or nil,
                    -- declared return type (base name): the per-function
                    -- SUMMARY the return-type rounds ride (graph-VM MVP)
                    ret = dret,
                    -- generic `Class<T>` return: the arg index binding T (the
                    -- return-type rounds read the call's class-literal there)
                    retclass = dretclass,
                    df = dfrec,
                    flow = fl and { stmts = fl.stmts, params = fl.params } or nil }
                lastFn[file] = nodes[#nodes]
                if wantesc and escpend then escpend[#escpend + 1] = nodes[#nodes] end
                -- register this body in dfreg: ALWAYS (cheap — one entry) so
                -- the mention DFS keeps a fn-node stack for write-axis (pw)
                -- attribution. The df-record ACCUMULATION off that stack runs
                -- only under legacy_df (the oracle's independent df); in
                -- production the stack is used for pw alone, df stays the
                -- flow.coarse derived above.
                if not spec.dataflow and spec.body_field then
                    local b = defn:field(spec.body_field)[1]
                    if b then
                        dfreg[b:id()] = { params = params, node = nodes[#nodes] }
                    end
                end
                fnDefLines[sp.start.line] = true
                -- the outermost query pattern may match a nested def too;
                -- ranges keep the innermost containing fn for attribution
                fnRanges[file] = fnRanges[file] or {}
                table.insert(fnRanges[file], { s = sp.start.line, e = sp['end'].line, id = id })
                if not torn and not aname then
                    exact[name] = exact[name] or {}
                    table.insert(exact[name], nodes[#nodes])
                    local tl = name:match('([%w_]+)$')
                    if tl and tl ~= name then
                        tail[tl] = tail[tl] or {}
                        table.insert(tail[tl], nodes[#nodes])
                    end
                    -- extra EXACT keys for one def (zig value-receiver dual-key):
                    -- the def keeps its bare same-file reach above AND gains a
                    -- Type.method key so a pointer-typed cross-file receiver call
                    -- can meet it. exact-only (no tail) — an alias key must not
                    -- become a promiscuous tail target. PERSISTED on the node
                    -- (n.altkeys) because alt_keys reads the live tree (defn/src),
                    -- which is gone by relink — the parallel/rebuild resolver
                    -- (M.relink) re-derives exact from n.name + n.altkeys, so
                    -- inline and parallel stay identical (the `par` gate).
                    if spec.alt_keys then
                        local ak = spec.alt_keys(name, defn, src)
                        if #ak > 0 then
                            nodes[#nodes].altkeys = ak
                            for _, k in ipairs(ak) do
                                exact[k] = exact[k] or {}
                                table.insert(exact[k], nodes[#nodes])
                            end
                        end
                    end
                end
                ::fn_done::
            end
        end
        -- an anonymous callback fn (arrow/function_expression passed as a call
        -- argument): name it after the call it is an argument to, for
        -- navigability (`forEach#cb`), then take handle_fn's anonymous path.
        -- ★ THE CALL SPELLINGS ARE PER-LANGUAGE and this used to know only js's, so a java
        -- lambda captured as @adef would have been named `fn#cb` — the same name for every
        -- callback in the file (CART-0406). java spells the call `method_invocation` and
        -- keeps the callee under `name`, not `function`. Kept as one table rather than a spec
        -- key: it is two entries per language and the FIELD fallback chain below already
        -- covers the difference, so a seam here would be ceremony around four names.
        local ANONCALL = { call_expression = true, new_expression = true,     -- js/ts
            method_invocation = true, object_creation_expression = true }     -- java
        local function handle_anon_fn(defn)
            local nm = 'fn'
            local args = defn:parent()
            local call = args and args:parent()
            if call and ANONCALL[call:type()] then
                local f = call:field('function')[1]
                    or call:field('constructor')[1]
                    or call:field('name')[1]      -- java: method_invocation.name
                    or call:field('type')[1]      -- java: object_creation_expression.type
                local seg = f and node_text(f, src):match('([%w_$]+)%s*$')
                if seg then nm = seg end
            end
            handle_fn(defn, nil, nm .. '#cb')
        end
        local function handle_var(defn, namen, valn)
            if defn and namen and not in_function(defn, spec)
                and not (spec.toplevel_parent and defn:parent()
                    and defn:parent():type() ~= spec.toplevel_parent) then
                local name = node_text(namen, src)
                local sp = pos_of(defn)
                -- raw id, NOT uid(): the seen_var dedup below is the
                -- multi-assign cross-product guard and works BY colliding
                -- (pos, bb = a.p, a.b visits pos twice); a var can never
                -- reach the graph with a dup id because this guard drops it
                local id = ('%s::var:%s@%d'):format(file, name, sp.start.line)
                if not seen_var[id] then
                    seen_var[id] = true
                    local d = valn and (spec.litdata_types or {})[valn:type()]
                        and litval(valn, src, spec, 0) or nil
                    local torn = torn_of(defn, sp)
                    nodes[#nodes + 1] = { id = id, name = name, kind = 'var',
                        file = file, range = sp, order = sp.start.line,
                        torn = torn,
                        data = type(d) == 'table' and d or nil }
                    if not torn then
                        varsByName[name] = varsByName[name] or {}
                        table.insert(varsByName[name], nodes[#nodes])
                        -- THIS FILE HAS SOMETHING A MENTION CAN ATTACH TO. The
                        -- mention gates below used to read "has functions", as
                        -- a proxy for "a mention could have an owner" -- true
                        -- while every use edge hung off a function, and that is
                        -- what CART-0479 killed: a file-scope mention now
                        -- attributes to the MODULE, so a var-only file (a php
                        -- config, a lua data table) has mentions worth reducing
                        -- and was skipped before its first one was read.
                        --
                        -- ★ INSIDE `not torn`, DELIBERATELY, and it must stay
                        -- in lockstep with the ONE predicate on the other side:
                        -- M.lookups indexes a var into `var_named` iff
                        -- `not n.torn and not n.sql and not n.ctype`. The fused
                        -- extract reads THIS set and the standalone id pass
                        -- (refresh, workers) derives its own from var_named, so
                        -- any difference between the two is an inline-vs-refresh
                        -- divergence -- a file scanned by one path and not the
                        -- other, which is the exact shape the parity gates
                        -- exist to catch. ctype vars never reach handle_var
                        -- (handle_iface mints those) and sql vars are minted by
                        -- a later pass, so `not torn` is the whole difference.
                        varFiles[file] = true
                    end
                    -- CONST-FOLD index (ladder step 1): a set-once STRING
                    -- literal binding lets identifier args fold to k='lit'
                    -- (constfold.fold, post-pass). A non-string / torn / rebind
                    -- binding POISONS the name — sound, string-only keeps the
                    -- k='lit' contract. [[cartograph-const-fold]]
                    local sv
                    if not torn and valn then
                        local cv = litval(valn, src, spec, 0)
                        if type(cv) == 'string' then sv = cv end
                    end
                    constfold.record(constDefs, file, name, sv)
                    -- FIELD ALIAS (CART-0237): `local f = mod.field`. Recorded per (file,
                    -- local) with a REBIND COUNTER, exactly like ctorbinds — a name bound
                    -- twice in one file is not a stable alias and the pass drops it. That
                    -- is also what protects against a same-named local elsewhere in the
                    -- file shadowing the module member.
                    if spec.field_alias and valn and not torn then
                        local arecv, amember = spec.field_alias(valn, src)
                        if arecv and amember then
                            data.fieldalias = data.fieldalias or {}
                            local fa = data.fieldalias[file]
                            if not fa then fa = {}; data.fieldalias[file] = fa end
                            local b = fa[name]
                            if not b then fa[name] = { recv = arecv, member = amember, n = 1 }
                            else b.n = b.n + 1 end
                        end
                    end
                end
            end
        end
        -- header/interface elements (C/C++): prototypes, macros and types.
        -- A prototype is a DECLARATION (never indexed, marked decl); a
        -- function-like macro IS a call target and indexes. namen here is
        -- the CATEGORY capture node; cat its capture name.
        local function handle_iface(defn, namen, cat)
            if defn and namen then
                local name = name_text(namen, src)
                local sp = pos_of(defn)
                local torn = torn_of(defn, sp)
                if cat == 'proto' or cat == 'macrofn' then
                    local node = { name = name, kind = 'function',
                        id = uid(('%s::%s@%d'):format(file, name, sp.start.line)),
                        file = file, range = sp, order = sp.start.line,
                        torn = torn, decl = cat == 'proto' or nil,
                        macro = cat == 'macrofn' or nil }
                    nodes[#nodes + 1] = node
                    -- prototypes never index; a fn-like macro resolves
                    if not torn and cat == 'macrofn' then
                        exact[name] = exact[name] or {}
                        table.insert(exact[name], node)
                        local tl = name:match('([%w_]+)$')
                        if tl and tl ~= name then
                            tail[tl] = tail[tl] or {}
                            table.insert(tail[tl], node)
                        end
                    end
                elseif cat == 'tstype' or cat == 'tsns' then
                    -- TS type alias (`type Id = …`) / namespace (`namespace NS {}`):
                    -- a browse-only TYPE node (ctype excludes it from value
                    -- resolution). Faithful representation; namespace MEMBER
                    -- qualification (NS.helper) is a banked follow-on — the
                    -- contents are still captured (bare) by the normal fn/class query.
                    nodes[#nodes + 1] = { name = name, kind = 'var',
                        id = uid(('%s::type:%s@%d'):format(file, name, sp.start.line)),
                        file = file, range = sp, order = sp.start.line,
                        torn = torn, ctype = cat == 'tstype' and 'type' or 'namespace' }
                elseif cat == 'tsiface' or cat == 'tsenum' then
                    -- TS interface/enum (pivot A1-tail). The declaration itself
                    -- is a browse-only TYPE node (kind='var' + ctype), like a C
                    -- struct/enum: ctype EXCLUDES it from value resolution (the
                    -- lookups var_named gate), so this is purely ADDITIVE — no
                    -- resolution edge changes. Then its members: interface method
                    -- signatures are DECL methods keyed `Iface.method` (a
                    -- signature, not an impl → decl=true, never indexed as a call
                    -- target, like a C prototype); interface property signatures
                    -- and enum members are browse-only `Owner.member` var nodes.
                    local kindname = cat == 'tsiface' and 'interface' or 'enum'
                    nodes[#nodes + 1] = { name = name, kind = 'var',
                        id = uid(('%s::type:%s@%d'):format(file, name, sp.start.line)),
                        file = file, range = sp, order = sp.start.line,
                        torn = torn, ctype = kindname }
                    local body = defn:field('body')[1]
                    if body and not torn then
                        for _, m in inext, body, -1 do
                            local mt = m:type()
                            local mn, mkind, mctype
                            if cat == 'tsiface' and mt == 'method_signature' then
                                mn, mkind = m:field('name')[1], 'method'
                            elseif cat == 'tsiface' and mt == 'property_signature' then
                                mn, mkind, mctype = m:field('name')[1], 'var', 'field'
                            elseif cat == 'tsenum' and mt == 'property_identifier' then
                                mn, mkind, mctype = m, 'var', 'enumMember'
                            elseif cat == 'tsenum' and mt == 'enum_assignment' then
                                mn, mkind, mctype = m:field('name')[1], 'var', 'enumMember'
                            end
                            if mn then
                                local msp = pos_of(mn)
                                local mname = name .. '.' .. node_text(mn, src):gsub('%s+', '')
                                nodes[#nodes + 1] = { name = mname, kind = mkind,
                                    id = uid(('%s::%s@%d'):format(file, mname, msp.start.line)),
                                    file = file, range = msp, order = msp.start.line,
                                    decl = mkind == 'method' or nil, ctype = mctype }
                            end
                        end
                    end
                else -- struct / union / enum / typedef / object macro
                    nodes[#nodes + 1] = { name = name, kind = 'var',
                        id = uid(('%s::type:%s@%d'):format(file, name, sp.start.line)),
                        file = file, range = sp, order = sp.start.line,
                        torn = torn, ctype = cat }
                end
            end
        end
        local function handle_super(childn, parentn)
            local child = node_text(childn, src)
            local t = node_text(parentn, src)
            local parent = t:match('[^\\]+$') or t
            data.extends = data.extends or {}
            data.extends[#data.extends + 1] =
                { child = child, parent = parent, file = file }
        end
        -- V2 cut 2: a `setmetatable(_, {__index = C})` ANYWHERE (any first arg,
        -- incl. the anonymous `setmetatable({}, …)` return form) records C + its
        -- line, so a fn whose body contains one has return-class C (the fn returns
        -- a C-instance). Separate from extends (which needs a NAMED child).
        local function handle_smt(clsn)
            local cls = node_text(clsn, src)
            data.smtclasses = data.smtclasses or {}
            local fs = data.smtclasses[file]
            if not fs then fs = {}; data.smtclasses[file] = fs end
            fs[#fs + 1] = { class = cls, line = ({ clsn:range() })[1] }
        end
        -- V2: `local obj = <call>(...)` → obj may be a class instance. Record the
        -- CALLEE text per (file, local); n>1 (rebound) drops it at resolve time
        -- (single-assignment gate). resolve_local_ctor derives the class two ways:
        -- the `.new`/`:new` convention (cut 1) OR the callee fn's return-class
        -- (cut 2 — bypasses the naming convention). Only constructor-SHAPED callees
        -- (`X`, `X.m`, `X:m`) are recorded; deeper chains skipped.
        local function handle_ctor(varn, calln)
            local callee = node_text(calln, src)
            if not callee:match('^[%w_]+[:.]?[%w_]*$') then return end
            local lv = node_text(varn, src)
            data.ctorbinds = data.ctorbinds or {}
            local fb = data.ctorbinds[file]
            if not fb then fb = {}; data.ctorbinds[file] = fb end
            local b = fb[lv]
            if not b then fb[lv] = { callee = callee, n = 1 } else b.n = b.n + 1 end
        end
        local combined = spec._defs_query
        if combined == nil then
            combined = table.concat({ spec.functions or '', spec.vars or '',
                spec.interface or '', spec.super_query or '',
                spec.ctor_query or '', spec.smt_query or '',
                spec.fields or '' }, '\n')
            spec._defs_query = combined
        end
        local q = parse_query(lang, combined)
        if q then
            for _, match in q:iter_matches(tsroot, src, 0, -1) do
                local defn, namen, vdefn, vnamen, valn, adefn
                local childn, parentn, catn, cat, cvarn, cctorn, smtn
                for id, ns in pairs(match) do
                    local capn = q.captures[id]
                    local n = cap_node(ns)
                    if capn == 'def' then defn = n
                    elseif capn == 'adef' then adefn = n
                    elseif capn == 'name' then namen = n
                    elseif capn == 'vdef' then vdefn = n
                    elseif capn == 'vname' then vnamen = n
                    elseif capn == 'value' then valn = n
                    elseif capn == 'child' then childn = n
                    elseif capn == 'parent' then parentn = n
                    elseif capn == 'cvar' then cvarn = n
                    elseif capn == 'cctor' then cctorn = n
                    elseif capn == 'smtclass' then smtn = n
                    elseif capn:sub(1, 1) ~= '_' then catn, cat = n, capn end
                end
                if smtn then
                    handle_smt(smtn)
                elseif cvarn and cctorn then
                    handle_ctor(cvarn, cctorn)
                elseif childn and parentn then
                    handle_super(childn, parentn)
                elseif vdefn and vnamen then
                    handle_var(vdefn, vnamen, valn)
                elseif defn and catn then
                    handle_iface(defn, catn, cat)
                elseif defn and namen then
                    handle_fn(defn, namen)
                elseif adefn then
                    handle_anon_fn(adefn)
                end
            end
        end
        -- synthetic defs (ruby attr_*): DSL calls that DEFINE accessor methods
        -- with no `def` keyword. Emit them as real method nodes + register in
        -- the exact/tail indexes so calls resolve to them.
        if spec.synth_defs then
            for _, sd in ipairs(spec.synth_defs(tsroot, src)) do
                local sp = pos_of(sd.node)
                local id = uid(('%s::%s@%d'):format(file, sd.name, sp.start.line))
                local node = { id = id, name = sd.name, kind = 'method',
                    file = file, range = sp, order = sp.start.line, synth = true }
                nodes[#nodes + 1] = node
                exact[sd.name] = exact[sd.name] or {}
                table.insert(exact[sd.name], node)
                local tl = sd.name:match('([%w_]+)$')
                if tl and tl ~= sd.name then
                    tail[tl] = tail[tl] or {}
                    table.insert(tail[tl], node)
                end
            end
        end
        -- R4 ancestor edges (ruby inheritance + mixins): collected corpus-wide
        -- (classes reopen), consumed by resolve_ruby_ancestors.
        if spec.scan_ancestors then
            data.ruby_anc = data.ruby_anc or {}
            local ra = data.ruby_anc
            for _, e in ipairs(spec.scan_ancestors(tsroot, src)) do
                e.file = file -- file-tagged so the parallel merge dedups it
                ra[#ra + 1] = e
            end
        end
        -- R5 ctor bindings (`u = Const.new`): per-file var→class, single-
        -- assignment gated (a var bound twice → false = ambiguous, dropped).
        -- spec.ctor_finders (rails pack, R5b-more) extends the scan to AR finders
        -- (`u = User.find_by`) — same bind/gate/resolve path as `.new`.
        if spec.scan_ctors then
            data.ruby_ctor = data.ruby_ctor or {}
            local fb = data.ruby_ctor[file] or {}
            data.ruby_ctor[file] = fb
            for _, cb in ipairs(spec.scan_ctors(tsroot, src, spec.ctor_finders)) do
                if fb[cb.var] == nil then fb[cb.var] = { cls = cb.cls, n = 1 }
                elseif fb[cb.var] then fb[cb.var].n = fb[cb.var].n + 1 end
            end
        end

        -- regions: runs of top-level statements that aren't function defs
        do
            local lines = vim.split(src, '\n', { plain = true })
            local container = tsroot
            if spec.block_container then
                for _, c in inext, tsroot, -1 do
                    if c:type() == spec.block_container then container = c break end
                end
            end
            local run = nil
            local function flush()
                if run then
                    local id = uid(('%s::region@%d'):format(file, run.s.start.line))
                    nodes[#nodes + 1] = { id = id, name = run.name, kind = 'region',
                        file = file, order = run.s.start.line,
                        -- `stmtrun` = a run of TOP-LEVEL STATEMENTS, as opposed to a
                        -- container region (a vue/svelte `template`). Only these own
                        -- module-level code, and the mark is what keeps extract's
                        -- index and relink's identical: relink rebuilds from
                        -- node_index, which holds every region, and without the mark
                        -- it attributed a template's ref to the template — a
                        -- parallel-vs-sequential divergence the graph-identity gate
                        -- caught.
                        stmtrun = true,
                        range = { start = run.s.start, ['end'] = run.e['end'] } }
                    run = nil
                end
            end
            for _, stmt in inext, container, -1 do
                if stmt:named() and not tsutil.is_comment(stmt)
                    and not (spec.block_skip or {})[stmt:type()] then
                    local p = pos_of(stmt)
                    -- a top-level fn def statement starts on the def's line
                    -- (`function f()`, and `f = function()` share the line);
                    -- it ends the current run rather than joining it
                    if fnDefLines[p.start.line] then
                        flush()
                    elseif not run then
                        run = { s = p, e = p,
                            name = (lines[p.start.line + 1] or ''):match('^%s*(.-)%s*$'):sub(1, NAME_CAP) }
                    else
                        run.e = p
                    end
                end
            end
            flush()
        end

        -- imports
        if spec.import_query then
            q = parse_query(lang, spec.import_query)
            if q then
                -- iter_matches, not iter_captures: predicates (#eq?) only
                -- apply to matches; iter_captures would yield raw captures
                -- ONE EDGE PER IMPORT SITE, keyed by the @path node's position:
                -- several query patterns can match the same site (a namespace
                -- import also matches the general import form; a CJS require
                -- matches both its declaration and the bare call), and a spec may
                -- supply @bind on only one of them. Deduping here keeps the edge
                -- set identical to what it was before binds existed and merges the
                -- bind into it, rather than emitting a second edge that would move
                -- every JS corpus gate.
                local at_site = {}
                for _, match in q:iter_matches(tsroot, src, 0, -1) do
                    local pathn, bindn
                    for id, ns in pairs(match) do
                        local cn = q.captures[id]
                        if cn == 'path' then pathn = cap_node(ns)
                        elseif cn == 'bind' then bindn = cap_node(ns) end
                    end
                    if pathn then
                        local sr, sc = pathn:start()
                        local site = sr * 4096 + sc
                        local target = spec.resolve_import(
                            node_text(pathn, src), importable, file, root)
                        if target and target ~= file then
                            local bind = bindn and node_text(bindn, src) or nil
                            -- WHAT KIND OF IMPORT IS THIS SITE (CART-0510)?
                            -- A BOUNDED ANCESTOR WALK, because @path sits at a
                            -- different depth in every language's query and the
                            -- capture name cannot carry two independent bits:
                            --   php   (require_once_expression (string) @path)
                            --         -> the kind node is the PARENT
                            --   bash  (command … argument: (word) @path)
                            --         -> also the parent (the #any-of? already
                            --            decided which commands match)
                            --   js    (call_expression … arguments: (…) @path)
                            --         -> `arguments` is the parent, so the kind
                            --            node is TWO up. That counter-example is
                            --            why one level is not enough and three is.
                            -- The table only names import-expression types, so a
                            -- walk that finds nothing sets NOTHING: absence means
                            -- "this language's syntax does not discriminate",
                            -- never "once".
                            local kind
                            if spec.import_kinds then
                                local n2, hops = pathn, 0
                                while n2 and hops <= 3 do
                                    kind = spec.import_kinds[n2:type()]
                                    if kind then break end
                                    n2, hops = n2:parent(), hops + 1
                                end
                            end
                            local idx = at_site[site]
                            if idx then
                                if bind and not edges[idx].bind then
                                    edges[idx].bind = bind
                                end
                                -- MERGE LIKE `bind`: several patterns match one
                                -- site (a CJS require matches its declaration AND
                                -- the bare call), and only some carry a kind. Test
                                -- `once == nil` — "not asked" — because a kindless
                                -- pattern landing first must not block a real
                                -- `once = false`, which is a POSITIVE answer.
                                if kind and edges[idx].once == nil then
                                    edges[idx].once = kind.once
                                    edges[idx].soft = kind.soft
                                    edges[idx].site = in_function(pathn, spec)
                                        and 'fn' or 'file'
                                end
                            else
                                local e = { from = file, to = target,
                                    kind = 'import', bind = bind }
                                -- all three fields together or none: setting
                                -- `site` on a site whose KIND is unknown would
                                -- claim half a fact
                                if kind then
                                    e.once, e.soft = kind.once, kind.soft
                                    e.site = in_function(pathn, spec)
                                        and 'fn' or 'file'
                                end
                                edges[#edges + 1] = e
                                at_site[site] = #edges
                            end
                        end
                    end
                end
            end
        end

        -- interface→impl: its own pass (SET-valued @iface — one `implements`
        -- clause captures many interfaces, and the shared defs loop's cap_node
        -- would keep only the last). Records data.implements (child→iface, with
        -- cintf marking the interface-extends-interface arm) + data.beans (the
        -- @stereotype implementers). resolve_interface consumes both.
        if spec.iface_query then
            q = parse_query(lang, spec.iface_query)
            if q then
                for _, match in q:iter_matches(tsroot, src, 0, -1) do
                    local decl, childn, ifaces = nil, nil, {}
                    for id, ns in pairs(match) do
                        local cn = q.captures[id]
                        if cn == 'idecl' then decl = cap_node(ns)
                        elseif cn == 'ichild' then childn = cap_node(ns)
                        elseif cn == 'iface' then
                            if type(ns) == 'table' and ns[1] ~= nil then
                                for _, x in ipairs(ns) do ifaces[#ifaces + 1] = x end
                            else ifaces[#ifaces + 1] = ns end
                        end
                    end
                    if childn and decl then
                        local child = node_text(childn, src)
                        -- @langs-ok java/php/ts `interface_declaration` — languages without interfaces have nothing to mirror
                        local cintf = decl:type() == 'interface_declaration'
                        data.implements = data.implements or {}
                        for _, ifn in ipairs(ifaces) do
                            data.implements[#data.implements + 1] = { child = child,
                                iface = node_text(ifn, src), cintf = cintf, file = file }
                        end
                        if not cintf then
                            local bn = javaspec._bean_name(decl, src)
                            if bn then
                                data.beans = data.beans or {}
                                data.beans[child] = bn -- explicit name or `true`
                            end
                        end
                    end
                end
            end
        end


    end

    -- calls: inventory + reference sites (resolved after all files).
    -- Containers also run this over TEMPLATE EXPRESSION trees — an
    -- @click="save(item)" is a real call_expression at absolute rows
    local function extract_calls(file, lang, spec, src, tsroot)
        tree_model(tsroot, src, spec) -- shared with extract_defs (same tree)
        local ifmemo = {} -- per TREE by construction (dies with this call)
        -- calls (inventory + reference sites, resolved after all files)
        local q = parse_query(lang, spec.calls)
        if q then
            for _, match in q:iter_matches(tsroot, src, 0, -1) do
                local calln, namen
                for id, ns in pairs(match) do
                    local cap = q.captures[id]
                    local n = cap_node(ns)
                    if cap == 'call' then calln = n elseif cap == 'name' then namen = n end
                end
                -- context skip: constructs that merely LOOK like calls
                -- (C++ constructor member-initializers: count(count))
                if calln and spec.call_skip_within then
                    local a, hops = calln:parent(), 0
                    while a and hops < 3 do
                        if spec.call_skip_within[a:type()] then
                            calln = nil
                            break
                        end
                        a = a:parent()
                        hops = hops + 1
                    end
                end
                -- positional skip: a list that only LOOKS like an application
                -- because of the syntax (scheme: a define/lambda's parameter
                -- list `(f x)` is not a call to f — it was the self-caller bug)
                if calln and spec.skip_call and spec.skip_call(calln, src) then
                    calln = nil
                end
                if calln and namen
                    and not (spec.call_skip or {})[node_text(namen, src)] then
                    local full = name_text(namen, src)
                    -- method-ness reads the SOURCE text: a receiver-aware
                    -- rewrite below must not shift the implicit-self arg
                    local method = full:find(':') ~= nil
                    -- receiver-aware qualification: a $this->/self:: call
                    -- names a method of the ENCLOSING class, so the spec
                    -- may rewrite the resolution key to Class::name —
                    -- exact match beats every tail fallback; inheritance
                    -- still falls through to tails
                    local qhedge, qdefer, qqual
                    if spec.qualify_call then
                        local q, h, d, qn = spec.qualify_call(calln, full, src, jvt_sm)
                        full, qhedge, qdefer, qqual = q or full, h, d, qn
                    end
                    -- the inventory names the VERB (lint configs match on it);
                    -- the full expression text drives resolution. A dynamic
                    -- callee keeps its sigil: `→ $op` says what it is
                    local dynamic = spec.dynamic_callee_types
                        and spec.dynamic_callee_types[namen:type()] or nil
                    -- A LITERAL KEY TAKES IT BACK TO STATIC (CART-0345):
                    -- `handlers['init']()` names its member in the source, so
                    -- claiming the graph cannot see it would be a false negative
                    -- fact. The key is the LAST named child. Only consulted when
                    -- the spec declares the set, so php's `$op()` is untouched.
                    if dynamic and spec.dynamic_callee_static_key then
                        local nk = namen:named_child_count()
                        local key = nk > 0 and namen:named_child(nk - 1) or nil
                        if key and spec.dynamic_callee_static_key[key:type()] then
                            dynamic = nil
                        end
                    end
                    local callee = dynamic and full
                        or full:match('([%w_]+)$') or full
                    local sp = pos_of(calln)
                    local encl = in_function(calln, spec, ifmemo)
                    local is_top = encl == nil
                    if spec.is_top then is_top = spec.is_top(calln, src) end
                    local args, argv = {}, {}
                    if method then
                        args[1] = ''
                        argv[1] = { k = 'expr' }
                    end
                    local argsn = calln:field('arguments')[1]
                    -- @langs-ok lua's sugar call forms `f"s"` / `f{...}`, which only lua's grammar admits
                    if argsn and (argsn:type() == 'string' or argsn:type() == 'table_constructor') then
                        local v = argsn:type() == 'string'
                            and node_text(argsn, src):gsub('^["\']', ''):gsub('["\']$', '') or ''
                        args[#args + 1] = v
                        argv[#argv + 1] = v ~= '' and { k = 'lit', v = v } or { k = 'expr' }
                        argsn = nil
                    end
                    local argnodes
                    if not argsn then
                        -- bash: arguments are repeated `argument:` fields
                        -- on the command itself, no container node
                        local fa = calln:field('argument')
                        if fa and #fa > 0 then argnodes = fa end
                    end
                    for _, a in (argsn and argsn.child and inext)
                        or (argnodes and ipairs(argnodes)) or NOOP,
                        argnodes or argsn, argnodes and 0 or -1 do
                        if a:named() and not tsutil.is_comment(a) then
                            -- KEYWORD arguments: unwrap to the VALUE node
                            -- (classified exactly like a positional) and
                            -- remember the name — f(callback=handler) is
                            -- dispatch testimony regardless of slot, and
                            -- sink tables may index by name (MaD's
                            -- Argument[name:]). Position semantics: kw
                            -- entries don't occupy a positional index.
                            local kw
                            local t0 = a:type()
                            if t0 == 'keyword_argument' then -- python
                                local nf = a:field('name')[1]
                                local vf = a:field('value')[1]
                                if nf and vf then
                                    kw = node_text(nf, src)
                                    a = vf
                                end
                            elseif t0 == 'pair' then -- ruby kwargs
                                local kf = a:field('key')[1]
                                local vf = a:field('value')[1]
                                if kf and vf then
                                    kw = node_text(kf, src):gsub(':$', '')
                                    a = vf
                                end
                            elseif t0 == 'argument' then -- php wraps each arg
                                -- PHP 8 named: (argument name: (name) value)
                                local nf = a:field('name')[1]
                                if nf and a:named_child_count() > 1 then
                                    kw = node_text(nf, src)
                                    a = a:named_child(a:named_child_count() - 1) or a
                                else
                                    a = a:named_child(0) or a
                                end
                            end
                            local nargv = #argv
                            local t = a:type()
                            if t == 'list_splat' or t == 'dictionary_splat'
                                or t == 'spread_element'
                                or t == 'splat_argument'
                                or t == 'variadic_unpacking' then
                                -- spread DESTROYS positional knowledge for
                                -- everything after it — consumers must not
                                -- silently mis-index (knowledge lattice)
                                args[#args + 1] = ''
                                argv[#argv + 1] = { k = 'spread' }
                            elseif t == 'class_literal' then
                                -- java `X.class` — carry the named TYPE so a
                                -- generic `Class<T>` return can bind T = X in
                                -- the return-type rounds (resolve_returns)
                                local ti = a:named_child(0)
                                args[#args + 1] = ''
                                argv[#argv + 1] = { k = 'class',
                                    -- @langs-ok `type_identifier` in a typed-argument position; the grammars lacking it are untyped or name types differently, and this arm only fires where the spec supplies a typed arg
                                    v = ti and ti:type() == 'type_identifier'
                                        and node_text(ti, src) or nil }
                            elseif t == 'string' or t == 'string_literal'
                                or t == 'encapsed_string' then -- php "..."
                                -- interpolated string (typed-strings v1):
                                -- k='lit' must mean KNOWN — "$var" IS the
                                -- variable, "lead $x…" only proves a PREFIX
                                local exp
                                for _, sc2 in inext, a, -1 do
                                    if sc2:named() and not STR_PARTS[sc2:type()] then
                                        exp = sc2
                                        break
                                    end
                                end
                                if exp then
                                    local txt = node_text(a, src)
                                    local asr, asc = a:range()
                                    local esr, esc = exp:range()
                                    local head = esr == asr
                                        and txt:sub(2, esc - asc) or nil
                                    local lone = txt:gsub('^["\']', '')
                                        :gsub('["\']$', '')
                                        :match('^%${?([%w_]+)}?$')
                                    args[#args + 1] = ''
                                    if head and head ~= '' then
                                        argv[#argv + 1] = { k = 'concat',
                                            prefix = head }
                                    elseif lone then
                                        argv[#argv + 1] = { k = 'local',
                                            name = lone,
                                            l = select(1, a:range()) }
                                    else
                                        argv[#argv + 1] = { k = 'expr' }
                                    end
                                else
                                    local v = node_text(a, src)
                                        :gsub('^["\']', ''):gsub('["\']$', '')
                                    args[#args + 1] = v
                                    argv[#argv + 1] = { k = 'lit', v = v }
                                end
                            elseif SCALAR_LIT[t] then
                                -- boolean/nil/number literals: the FLAG
                                -- pattern (f(x, true)) — dischargeable
                                -- against param-guarded writes (e.gp)
                                args[#args + 1] = ''
                                argv[#argv + 1] = { k = 'scalar', v = node_text(a, src) }
                            elseif t == 'identifier' then
                                args[#args + 1] = ''
                                argv[#argv + 1] = { k = 'local', name = node_text(a, src),
                                    l = select(1, a:range()) }
                            elseif t == 'function_definition' or t == 'lambda' then
                                args[#args + 1] = ''
                                argv[#argv + 1] = { k = 'func' }
                            elseif t == 'variable_name' then -- php $var
                                args[#args + 1] = ''
                                argv[#argv + 1] = { k = 'local',
                                    name = node_text(a, src):gsub('^%$', ''),
                                    l = select(1, a:range()) }
                            elseif t == 'binary_expression'
                                and a:field('left')[1]
                                and a:field('left')[1]:type():find('string') then
                                -- 'prefix_' . x — the key is a PREFIX FAMILY
                                local pre = node_text(a:field('left')[1], src)
                                    :gsub('^["\']', ''):gsub('["\']$', '')
                                args[#args + 1] = ''
                                argv[#argv + 1] = { k = 'concat', prefix = pre }
                            else
                                local cname = callable_arg(a, src)
                                args[#args + 1] = ''
                                argv[#argv + 1] = cname
                                    and { k = 'callable', name = cname }
                                    or { k = 'expr' }
                            end
                            if kw and #argv > nargv then
                                argv[#argv].kw = kw
                            end
                        end
                    end
                    -- an import call also emits the module edge — with
                    -- the LOCAL it binds, when the spec can read it
                    -- (requalification needs to know which name means
                    -- which module)
                    if spec.import_call and full == spec.import_call then
                        local target = args[1] and args[1] ~= ''
                            and spec.resolve_import(args[1], importable, file, root)
                        if target and target ~= file then
                            local pt = calln:parent()
                            local ptt = pt and pt:type() or ''
                            edges[#edges + 1] = { from = file, to = target, kind = 'import',
                                bind = spec.import_bind
                                    and spec.import_bind(calln, src) or nil,
                                sideeffect = (ptt == 'chunk' or ptt == 'block'
                                    or ptt:find('expression_statement')) and true or nil }
                        end
                    end
                    -- custom loader verbs (mantis require_api): the spec
                    -- recognizes loader-SHAPED names with a source-file
                    -- literal; the edge is name-matched, so it carries ~
                    if spec.import_call_like and args[1] and args[1] ~= ''
                        and spec.import_call_like(full, args[1]) then
                        local target = spec.resolve_import(args[1], importable, file, root)
                        if target and target ~= file then
                            edges[#edges + 1] = { from = file, to = target,
                                kind = 'import', inferred = true }
                        end
                    end
                    -- instance chain `root.field.method()`: the root's TYPE and
                    -- the field name (see chain_root) — resolve_field_chain looks
                    -- the field's type up in the global field map.
                    local chroot, chfield
                    if spec.chain_root then
                        chroot, chfield = spec.chain_root(calln, src)
                    end
                    local c = { callee = callee, args = args, argv = argv,
                        file = file, line = sp.start.line, method = method,
                        full = full ~= callee and full or nil,
                        chainroot = chroot, chainfield = chfield,
                        dynamic = dynamic,
                        hedge = qhedge, -- hedged qualification: edge gets ~
                        rt = qdefer -- receiver typed by ANOTHER call's return:
                        -- the return-type rounds settle it (java: qualify_call's
                        -- defer). Z1b: a set-once local const bound to a call
                        -- (`const x = C.init(); x.m()`) records the determining
                        -- call's position via local_ret ([[cartograph-local-type-inference]]).
                            or (spec.local_ret and spec.local_ret(calln, src)) or nil,
                        qualifier = qqual, -- @Qualifier bean name on the
                        -- receiver field (resolve_interface narrows on it)
                        at = pos_of(namen), -- callee token range: relink
                        -- rebuilds edges at full fidelity, not line-anchored
                        -- identifier receiver (`x.foo`): the local name, for
                        -- ADDITIVE ctor-typing (rescoped R5). `full` stays bare
                        -- so the file-local heuristic is untouched.
                        recv = spec.recv_local and spec.recv_local(calln, src) or nil,
                        -- leftmost id of a DEEP receiver chain (`std.mem.eql` →
                        -- "std") — complements recv (single-id only); the
                        -- std-alias disposition keys either as the call root.
                        recvroot = spec.recv_root and spec.recv_root(calln, src) or nil,
                        -- full receiver-chain text (`std.mem.eql` → "std.mem"):
                        -- the mint pass rebuilds the canonical std symbol from it.
                        recvpath = spec.recv_path and spec.recv_path(calln, src) or nil,
                        -- multi-level chain `root.Type.method()`: the PascalCase
                        -- segment right before the method (its type namespace),
                        -- persisted for the additive chain post-pass. Bare `full`
                        -- untouched, so the same-file tail path (which already
                        -- resolves same-file chains) is unchanged.
                        chainty = spec.chain_type and spec.chain_type(calln, src) or nil,
                        top = is_top or nil }
                    calls[#calls + 1] = c
                    local indirect = (spec.indirect_calls or {})[callee]
                    indirect = indirect and args[indirect + (method and 1 or 0)]
                    indirect = indirect ~= '' and indirect or nil
                    c.indirect = indirect
                    pending[#pending + 1] = { call = c, file = file, full = full,
                        indirect = indirect,
                        at = pos_of(namen), encl = encl and pos_of(encl) }
                end
            end
        end
        -- bare no-paren calls (the open ceiling): identifiers that are
        -- implicit-self method calls, keyed through qualify_call (R2 → Owner#m)
        -- like any other call. No args (a bare call takes none), method=false.
        if spec.scan_bare_calls then
            for _, bc in ipairs(spec.scan_bare_calls(tsroot, src)) do
                local id, name = bc.node, bc.name
                if not (spec.call_skip or {})[name] then
                    local full, qhedge = name, nil
                    if spec.qualify_call then
                        local qk, h = spec.qualify_call(id, name, src, jvt_sm)
                        full, qhedge = qk or name, h
                    end
                    local sp = pos_of(id)
                    local encl = in_function(id, spec, ifmemo)
                    local is_top = encl == nil
                    if spec.is_top then is_top = spec.is_top(id, src) end
                    local c = { callee = name, args = {}, argv = {},
                        file = file, line = sp.start.line, method = false,
                        full = full ~= name and full or nil, hedge = qhedge,
                        at = pos_of(id), top = is_top or nil, bare = true }
                    calls[#calls + 1] = c
                    pending[#pending + 1] = { call = c, file = file, full = full,
                        at = pos_of(id), encl = encl and pos_of(encl) }
                end
            end
        end
        -- R4 `super` keyword: emit a call resolved by resolve_ruby_ancestors
        -- (superx path) to the ANCESTOR's same-named method. full=nil so the
        -- main loop leaves it unresolved (and sets c.fn); it never self-matches
        -- the enclosing method.
        if spec.scan_super then
            for _, s in ipairs(spec.scan_super(tsroot, src)) do
                local sp = pos_of(s.node)
                local encl = in_function(s.node, spec, ifmemo)
                local c = { callee = 'super', args = {}, argv = {}, file = file,
                    line = sp.start.line, method = false, at = pos_of(s.node),
                    superx = { cls = s.cls, member = s.member, sing = s.sing } }
                calls[#calls + 1] = c
                pending[#pending + 1] = { call = c, file = file, full = 'super',
                    at = pos_of(s.node), encl = encl and pos_of(encl) }
            end
        end
        -- @import module binding: `const NAME = @import("f.zig")` is a
        -- builtin_function (not a captured call), so scan for it and emit the
        -- module edge with its alias — resolve_module_alias resolves the
        -- `NAME.member()` calls against it (same edge shape as import_call).
        if spec.scan_imports and spec.resolve_import then
            for _, imp in ipairs(spec.scan_imports(tsroot, src)) do
                local target = spec.resolve_import(imp.path, importable, file, root)
                if target and target ~= file then
                    edges[#edges + 1] = { from = file, to = target,
                        kind = 'import', bind = imp.alias, inferred = true }
                end
            end
        end
        -- std-alias bindings (zig): a per-file name-set bound to the standard
        -- library (`const assert = std.debug.assert`), consumed by the
        -- resolve_std_alias disposition pass ([[cartograph-stdlib-profile]]).
        if spec.std_aliases then
            local set = spec.std_aliases(tsroot, src)
            if next(set) then
                data.stdaliases = data.stdaliases or {}
                data.stdaliases[file] = set
            end
        end
        -- struct field types (zig): a file-tagged side-table typename→field→type
        -- for resolve_field_chain (instance chains `root.field.method()`)
        if spec.scan_fields then
            for _, f in ipairs(spec.scan_fields(tsroot, src)) do
                data.fieldtypes = data.fieldtypes or {}
                data.fieldtypes[#data.fieldtypes + 1] = { typename = f.typename,
                    field = f.field, ftype = f.ftype, file = file }
            end
        end
    end

    local cunparsed = {}

    -- container SFCs: the injection queries hand back host-language
    -- trees at absolute positions — script regions get the full pass,
    -- template expression trees the call pass (the id pass walks both
    -- later). Missing grammar → an opaque frontier module, like *.min.js.
    local function extract_container(file, clang, src)
        local okp, parser = pcall(vim.treesitter.get_string_parser, src, clang)
        if not okp then
            no_parser[clang] = true
            nodes[#nodes + 1] = { id = file, name = file, kind = 'module',
                file = file, unparsed = true, order = -1,
                range = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } } }
            cunparsed[#cunparsed + 1] = file
            return
        end
        local regions = container_trees(parser, clang) or {}
        local croot = parser:trees()[1]:root()
        stamp(file)
        nodes[#nodes + 1] = { id = file, name = file, kind = 'module', file = file,
            range = pos_of(croot), order = -1 }
        -- which regions are <script>? (the rest are template expressions)
        local scripts = {}
        local cq = parse_query(clang, '(script_element (raw_text) @s)')
        if cq then
            for _, n in cq:iter_captures(croot, src, 0, -1) do
                local s, _, e = n:range()
                scripts[#scripts + 1] = { s = s, e = e }
            end
        end
        local regdfs = {}
        for ri, r in ipairs(regions) do
            local script = false
            for _, x in ipairs(scripts) do
                if r.s >= x.s and r.s <= x.e then script = true break end
            end
            -- per-REGION df registry: regions are separate trees, and
            -- node ids alias across trees
            regdfs[ri] = {}
            if script then
                extract_defs(file, r.lang, r.spec, src, r.root, regdfs[ri])
            end
            extract_calls(file, r.lang, r.spec, src, r.root)
        end
        if fnRanges[file] or varFiles[file] then
            local buf = mention_buf(M.spec.javascript)
            for ri, r in ipairs(regions) do
                collect_mentions(buf, r.root, src, r.spec, regdfs[ri],
                    opts and opts.legacy_df)
            end
            buf.m = table.concat(buf.parts)
            buf.parts, buf.nidx = nil, nil
            mentions[file] = buf
        end
        -- the template as ONE visible block row (a jump target): its
        -- extent is the top-level markup that isn't script/style
        local tps, tpe
        for _, c in inext, croot, -1 do
            local t = c:type()
            if c:named() and t ~= 'script_element' and t ~= 'style_element'
                and not tsutil.COMMENT[t] then
                local s, _, e = c:range()
                if not tps or s < tps then tps = s end
                if not tpe or e > tpe then tpe = e end
            end
        end
        if tps then
            nodes[#nodes + 1] = { id = uid(('%s::template@%d'):format(file, tps)),
                name = 'template', kind = 'region', file = file, order = tps,
                range = { start = { line = tps, char = 0 },
                    ['end'] = { line = tpe, char = 0 } } }
        end
    end

    for _, file in ipairs(files) do
        local src, rerr = tp.read_source(abs(file))
        if not src then
            -- UNAVAILABLE is not absence: the file is known to exist, we simply
            -- could not read it. Dropping it would delete its module node and
            -- silently reclassify every call into it as `external` — a
            -- CONFIDENT BOUNDARY CLAIM derived from a failure. So it lands as an
            -- opaque frontier instead, the same shape a *.min.js bundle or a
            -- missing grammar gets: visible, stamped, unparsed. ABSENT (the file
            -- vanished between the walk and the read) is a real race and stays a
            -- silent skip.
            if rerr == transport.UNAVAILABLE then
                stamp(file) -- stat still works on an unreadable file
                nodes[#nodes + 1] = { id = file, name = file, kind = 'module',
                    file = file, unparsed = true, order = -1,
                    range = { start = { line = 0, char = 0 },
                        ['end'] = { line = 0, char = 0 } } }
                cunparsed[#cunparsed + 1] = file
            end
            goto next_file
        end
        local clang = container_for(file)
        if clang then
            extract_container(file, clang, src)
            goto next_file
        end
        do
            local lang, spec = lang_for(file)
            spec = eff_spec(lang, spec) -- overlay pack composition (rails)
            -- vendored bundles that dodge the *.min.js name (nocodb's
            -- swagger-ui-bundle.js): a line no human wrote means BUNDLE —
            -- content decides what the filename doesn't say. Opaque
            -- frontier, same as *.min.js
            if lang == 'javascript' or lang == 'typescript' then
                for line in src:sub(1, 32768):gmatch('[^\n]+') do
                    if #line > 5000 then
                        stamp(file)
                        nodes[#nodes + 1] = { id = file, name = file,
                            kind = 'module', file = file, unparsed = true,
                            order = -1, range = { start = { line = 0, char = 0 },
                                ['end'] = { line = 0, char = 0 } } }
                        cunparsed[#cunparsed + 1] = file
                        goto next_file
                    end
                end
            end
            local tsroot
            local rawtree, keepparser -- keep referenced: nodes below live
            -- only as long as their tree (and its owning parser) does
            local function parse_into()
                local _pp = pstart()
                rawtree = raw_parse(lang, src)
                if rawtree then
                    tsroot = rawtree:root()
                else
                    local okp, parser =
                        pcall(vim.treesitter.get_string_parser, src, lang)
                    if not okp then padd('parse', _pp) return false end
                    keepparser = parser
                    tsroot = parser:parse()[1]:root()
                end
                padd('parse', _pp)
                return true
            end
            if not parse_into() then
                no_parser[lang] = true
                goto next_file
            end
            -- ★★ SOURCE REPAIR, ITERATED (CART-0439). A spec may declare a shape its
            -- grammar CANNOT parse and hand back length-preserving repaired bytes;
            -- see spec/cpp.lua's `src_repair` for the case that forced it (a macro
            -- between `class` and its name dissolves the class, every method, the base
            -- clause and the access specifiers, in one). The hook is handed the TREE,
            -- not the text, so the repair is gated on the parse being demonstrably
            -- wrong — and it costs one extra parse only for the files that are.
            -- Bounded: a repair that does not converge (v8's EXPORT_TEMPLATE_DECLARE(…)
            -- can never become a class) must not spin.
            if spec.src_repair then
                for _ = 1, 4 do
                    local fixed = spec.src_repair(tsroot, src)
                    if not fixed then break end
                    src = fixed
                    if not parse_into() then break end
                end
            end
            stamp(file)
            nodes[#nodes + 1] = { id = file, name = file, kind = 'module', file = file,
                range = pos_of(tsroot), order = -1,
                effects = spec.module_effects
                    and spec.module_effects(tsroot, src) or nil }
            if spec.aperture_query then
                local aq = parse_query(lang, spec.aperture_query)
                if aq then
                    local aps
                    for cid, an in aq:iter_captures(tsroot, src, 0, -1) do
                        local cap = aq.captures[cid]
                        if cap:sub(1, 1) ~= '_' then
                            aps = aps or {}
                            aps[#aps + 1] = { rule = cap, line = (an:range()) }
                        end
                    end
                    nodes[#nodes].apertures = aps
                end
            end
            local dfreg = {}
            -- CART-0236: hand the confinement question to the mention walk when one
            -- is coming. The list stays empty for a file with no file-local def, and
            -- a non-empty list implies fnRanges[file] (handle_fn fills both), so the
            -- stamping pass below cannot be skipped out from under it.
            local escpend = (spec.escape_nonvalue
                and not (defs_only or dataflow_only)) and {} or nil
            local _pd = pstart()
            extract_defs(file, lang, spec, src, tsroot, dfreg, escpend)
            padd('extract_defs', _pd) -- incl. flow.build (timed separately)
            -- calls + mentions/refs are deferred entirely in the index-only / dataflow-only
            -- front-ends (they, and the resolution they feed, are the bulk that defers on-demand)
            if not (defs_only or dataflow_only) then
            local _pc = pstart()
            extract_calls(file, lang, spec, src, tsroot)
            padd('extract_calls', _pc)
            -- fusion Stage B: mentions ride the SAME tree — the id pass
            -- never parses again. df rides the same walk via dfreg
            -- (registered by extract_defs above).
            -- THE GATE IS "HAS A MENTION TARGET", not "has functions". It read
            -- `fnRanges[file]` for as long as every use edge needed an owning
            -- function, and a file with only file-scope vars therefore never
            -- had its mentions collected -- so the fix in reduce_mentions
            -- (attribute to the module) would have been dead code for exactly
            -- the files that carry the most module state (CART-0479: mantis's
            -- config_defaults_inc.php defines the globals the whole app reads).
            if fnRanges[file] or varFiles[file] then
                local buf = mention_buf(spec)
                local escset = escpend and escpend[1] and {} or nil
                local _pm = pstart()
                collect_mentions(buf, tsroot, src, spec, dfreg,
                    opts and opts.legacy_df, escset)
                padd('collect_mentions', _pm)
                buf.m = table.concat(buf.parts)
                buf.parts, buf.nidx = nil, nil
                mentions[file] = buf
                if escset then
                    -- tri-state, like `exported`: this is the ASKED answer, so a
                    -- name absent from the set is a definite false (confined), never
                    -- a nil standing in for "we did not look".
                    for _, fn in ipairs(escpend) do
                        fn.escapes = escset[fn.name] == true
                    end
                end
            end
            end -- if not defs_only (calls + mentions deferred)
        end
        ::next_file::
    end

    -- ── resolution pass: name-matched, ambiguity refuses to link ─────────────
    local _prs = pstart()
    local scope_cache = {}
    local function scope_of(f)
        if scope_cache[f] == nil then
            local _, sp = elang_for(f)
            scope_cache[f] = sp and sp.scope
                and sp.scope(f, fileset, root) or false
        end
        return scope_cache[f] or nil
    end
    local refEdge = {}
    local addref = ref_adder(refEdge, edges)
    -- a REGISTRATION edge: fn passed as data at load time (a callback
    -- list, an operations table) is kept alive by its module — an alibi
    local regEdge = {}
    local function addreg(from, to, at)
        local k = from .. '\31' .. to
        local e = regEdge[k]
        if not e then
            e = { from = from, to = to, kind = 'reg', at = {} }
            regEdge[k] = e
            edges[#edges + 1] = e
        end
        if at then e.at[#e.at + 1] = at end
    end
    -- aperture witnesses + corpus fn NAMESPACES (literal-name languages):
    -- an unresolved call whose first /-or-# segment matches a known fn
    -- namespace is corpus-internal (ble/bash/read), not an external
    -- command — with conjuring sites in the corpus, the honest answer is
    -- refusal-with-witness, not silence. Witness pick is deterministic
    -- (same file first, else lexicographically smallest file's first site)
    local apertures, ns_pfx, global_witness = {}, {}, nil
    for _, n in ipairs(nodes) do
        if n.kind == 'module' and n.apertures then
            apertures[n.file] = n.apertures
            if not global_witness or n.file < global_witness.file then
                global_witness = { file = n.file, line = n.apertures[1].line }
            end
        elseif n.kind == 'function' or n.kind == 'method' then
            local pfx = n.name:match('^([^/#]+)[/#]')
            if pfx then
                local _, dsp = elang_for(n.file)
                if dsp and dsp.literal_names then ns_pfx[pfx] = true end
            end
        end
    end
    local aperture_refusal = aperture_refuser(ns_pfx, apertures, global_witness)
    local function resolve(name, file)
        -- 1-2 char names are shadow-bait for WORKSPACE matching (pattern
        -- vars, loop counters — noise-dominated in every language), but a
        -- name with a SAME-FILE def has a definite binder: silently
        -- skipping those was a real honesty gap (the synjs min.js `q3()`
        -- key witness). Short names get the same-file tier ONLY; every
        -- cross-file fallback below stays behind the noise floor.
        local short = #name < 3
        local clang, spec = elang_for(file)
        spec = eff_spec(clang, spec) -- overlay pack (rails vocab in stdlib_names)
        local snames = spec and spec.stdlib_names or {}
        if snames[name] then return nil, nil, nil, EXT.vocab end
        local cands = exact[name]
        -- the stdlib TAIL gate guards the fallbacks below; an exact match
        -- on a fully-qualified name (Engine::new) clears first. Literal-
        -- name languages (bash) have no qualification syntax at all — a
        -- slashed fn like ble/bash/read must not vocab-die on tail `read`
        if not cands and not (spec and spec.literal_names)
            and snames[name:match('([%w_%-]+)$') or ''] then
            return nil, nil, { rule = 'vocab' }
        end
        if cands then
            -- an explicit `def` overrides a synthesized accessor (ruby: a real
            -- method beats attr_accessor). When both share this exact name, the
            -- synth nodes are shadowed — drop them so the def resolves cleanly
            -- instead of a false ambiguity.
            do
                local hasreal = false
                for _, n in ipairs(cands) do
                    if not n.synth then hasreal = true break end
                end
                if hasreal then
                    local filt = {}
                    for _, n in ipairs(cands) do
                        if not n.synth then filt[#filt + 1] = n end
                    end
                    cands = filt
                end
            end
            -- same-file priority is a FILE-SCOPE assumption (lua locals, C
            -- statics); dynamically-dispatched defs (instance methods) don't
            -- get it — they link only when globally unique
            local same, samedup
            for _, n in ipairs(cands) do
                if n.file == file and not n.cbarg then
                    if same then -- ambiguous within the file: refuse
                        samedup = samedup or { same }
                        samedup[#samedup + 1] = n
                    else
                        same = n
                    end
                end
            end
            if samedup then return nil, nil, refusal('samefile', samedup) end
            if same then return same, false end
            if short then return nil, nil, nil, EXT.short end -- no same-file binder: noise floor
            -- workspace-unique, but never across a scope boundary (rust
            -- crates: bare names cannot legally cross); dotted callees
            -- are method syntax and never match free functions
            local sc = scope_of(file)
            -- QUALIFIED references (pkg.Fn, x.method) are how code legally
            -- crosses a scope boundary, so they match globally — rust
            -- additionally knows x.f() is method dispatch; bare
            -- identifiers never cross, so their uniqueness is scope-local
            -- (`::` is a qualified receiver too — Class::m explicitly names
            -- the class and crosses packages, same as the tail path below)
            local dotted = name:find('.', 1, true) ~= nil
                or name:find('->', 1, true) ~= nil
                or name:find('::', 1, true) ~= nil
                or (spec and spec.hash_qualified
                    and name:find('#', 1, true) ~= nil)
            local fitset = {}
            for _, n in ipairs(cands) do
                local fits
                if dotted then
                    fits = not (spec and spec.dot_calls_are_methods)
                        or n.kind == 'method'
                    -- WoW addons: a qualified/method name's receiver is
                    -- the addon's OWN object (its vendored Ace copy) —
                    -- qualified names stay scope-local too. Single-scope
                    -- trees ('' everywhere) are unaffected.
                    if fits and spec and spec.qualified_scope_local then
                        fits = sc == nil or scope_of(n.file) == sc
                    end
                else
                    fits = sc == nil or scope_of(n.file) == sc
                end
                -- a name never crosses LANGUAGES: that is xlang's job,
                -- explicit and string-keyed — js .replace() must not
                -- tail-match a ruby #replace
                if fits and elang_for(n.file) ~= clang then fits = false end
                -- a confined file-local is not a candidate for a call in another
                -- file, however unique its name is here (CART-0230)
                if fits and confined(n, file) then fits = false end
                if fits then fitset[#fitset + 1] = n end
            end
            if #fitset == 1 then return fitset[1], true end
            -- the refusal is a PLACE: who was refused, and by which rule
            return nil, nil, refusal(#fitset > 1 and 'ambiguous' or 'blocked',
                #fitset > 0 and fitset or cands)
        end
        if short then return nil, nil, nil, EXT.short end -- free short name: noise floor holds
        -- receiver-evidence keys (ruby `Foo.bar`) are exact-or-nothing: an
        -- exact miss is an honest frontier, never a promiscuous tail guess
        if spec and spec.exact_only_key and spec.exact_only_key(name) then
            return nil, nil, nil, EXT.exact
        end
        for _, pre in ipairs(spec and spec.stdlib_prefixes or {}) do
            if name:sub(1, #pre) == pre then return nil, nil, nil, EXT.prefix end
        end
        -- literal-name languages never tail-match: a bash command names
        -- its function EXACTLY (slashes are just characters), so `split`
        -- must not fuzzy-hit thousands of ble/string#split-style defs —
        -- an unknown name is an external command, not a near-miss...
        -- UNLESS it wears a known fn namespace and the corpus contains
        -- conjuring sites: then refusal-with-witness (the aperture)
        if spec and spec.literal_names then
            local ar = aperture_refusal(name, file)
            if ar then return nil, nil, ar end
            return nil, nil, nil, prof_ext(spec, name) or EXT.nodef
        end
        local tl = name:match('([%w_]+)$')
        local tc = tl and (tail[tl] or exact[tl])
        if tc then
            local sc = scope_of(file)
            local dotted = name:find('.', 1, true) ~= nil
                or name:find('->', 1, true) ~= nil
                or name:find('::', 1, true) ~= nil
                or (spec and spec.hash_qualified
                    and name:find('#', 1, true) ~= nil)
            local function admits(n)
                local fits
                if dotted then
                    fits = not (spec and spec.dot_calls_are_methods)
                        or n.kind == 'method'
                    -- WoW addons: a qualified/method name's receiver is
                    -- the addon's OWN object (its vendored Ace copy) —
                    -- qualified names stay scope-local too. Single-scope
                    -- trees ('' everywhere) are unaffected.
                    if fits and spec and spec.qualified_scope_local then
                        fits = sc == nil or scope_of(n.file) == sc
                    end
                else
                    fits = sc == nil or scope_of(n.file) == sc
                end
                -- a name never crosses LANGUAGES: that is xlang's job,
                -- explicit and string-keyed — js .replace() must not
                -- tail-match a ruby #replace
                if fits and elang_for(n.file) ~= clang then fits = false end
                if fits and confined(n, file) then fits = false end -- CART-0230
                return fits
            end
            -- ── RECEIVER-PATH AGREEMENT, before the tail-vs-exact preference.
            -- A call `a.b.m` and a candidate named `b.m` agree on the RECEIVER, which
            -- the bare tail `m` says nothing about. Where exactly one admitted
            -- candidate agrees, that is a better answer than whichever index happened
            -- to answer first — and it is the only receiver question a NAME can settle
            -- (see recv_agrees). ADDITIVE BY CONSTRUCTION: a unique agreement either
            -- fills a call the tail preference left ambiguous, or corrects one it
            -- resolved to a candidate whose receiver contradicts the call's; with no
            -- unique agreement the block below runs exactly as it did.
            if dotted then
                local agree
                for _, list in ipairs({ tail[tl] or {}, exact[tl] or {} }) do
                    for _, n in ipairs(list) do
                        if recv_agrees(name, n.name) and admits(n) then
                            if agree and agree.id ~= n.id then agree = nil; goto no_agree end
                            agree = n
                        end
                    end
                end
                if agree then return agree, true end
                ::no_agree::
            end
            local fitset = {}
            for _, n in ipairs(tc) do
                if admits(n) then fitset[#fitset + 1] = n end
            end
            if #fitset == 1 then return fitset[1], true end
            return nil, nil, refusal(#fitset > 1 and 'ambiguous' or 'blocked',
                #fitset > 0 and fitset or tc)
        end
        return nil, nil, nil, prof_ext(spec, name) or EXT.nodef
    end
    -- single-assignment literal flow: `$fn = 'compute'; $fn(3)` resolves —
    -- but ONLY when the variable has exactly one def in the function (two
    -- defs mean a branch chose, and we will not pick sides)
    local src_cache = {}
    local node_index = {}
    for _, n in ipairs(nodes) do node_index[n.id] = n end
    local function literal_flow(p)
        local fnid = fn_at(p.file, p.at.start.line)
        local fnode
        for _, r in ipairs(fnRanges[p.file] or {}) do
            if r.id == fnid then fnode = r end
        end
        local varname = p.full:match('^%$([%w_]+)$')
        if not (varname and fnid) then return nil end
        local fnode_n = node_index[fnid]
        local stmts = fnode_n and dfmod.stmts(fnode_n) -- dual-mode df accessor
        if not stmts then return nil end
        local defstmt, ndefs = nil, 0
        for _, st in ipairs(stmts) do
            for _, d in ipairs(st.def) do
                if d == varname then
                    ndefs = ndefs + 1
                    defstmt = st
                end
            end
        end
        if ndefs ~= 1 or not defstmt then return nil end
        if src_cache[p.file] == nil then
            -- `or false` is the "tried and failed" sentinel, distinct from the
            -- nil that means "not tried yet"
            src_cache[p.file] = tp.lines(abs(p.file)) or false
        end
        local line = src_cache[p.file] and src_cache[p.file][defstmt.l] or ''
        local lit = line:match('%$' .. varname .. [=[%s*=%s*['"]([%w_:\]+)['"]]=])
        if not lit then return nil end
        return resolve(lit, p.file), lit
    end
    -- typed-strings: STRING recovery for a sink arg — the prize is the
    -- VALUE: the def line's quoted string, full when the quote closes
    -- into plain punctuation, otherwise an honest PREFIX (multiline SQL,
    -- '…' . $x concatenation). One def in the fn = CONFIDENT. Several
    -- defs = the NEAREST ABOVE the use, HEDGED: right for sequential
    -- reuse (mantis redefines $t_query per query), but a branch may have
    -- chosen — the tier says so (the literal-flow analyzer, mantis cut).
    local function flow_string(file, line0, varname)
        local fnid = fn_at(file, line0)
        if not (varname and fnid) then return nil end
        local fnode_n = node_index[fnid]
        local stmts = fnode_n and dfmod.stmts(fnode_n) -- dual-mode df accessor
        if not stmts then return nil end
        local ndefs = 0
        for _, st in ipairs(stmts) do
            for _, d in ipairs(st.def) do
                if d == varname then ndefs = ndefs + 1 end
            end
        end
        if ndefs == 0 then return nil end
        local hedged = ndefs > 1 or nil
        local fnrow = 0
        for _, r in ipairs(fnRanges[file] or {}) do
            if r.id == fnid then fnrow = r.s break end
        end
        if src_cache[file] == nil then
            src_cache[file] = tp.lines(abs(file)) or false
        end
        -- the assignment may sit NESTED inside its statement (an
        -- if-guard) and `.=` appends may follow it — appends PRESERVE the
        -- base as a prefix, so scan the source upward from the use over
        -- the whole fn for the nearest PLAIN assignment (`.=` never
        -- matches); df already hedged multi-def flows
        local line, qch, pos
        for l = line0, fnrow + 1, -1 do
            local cand = src_cache[file] and src_cache[file][l] or ''
            qch, pos = cand:match('%$?' .. varname .. [=[%s*=%s*(['"])()]=])
            if qch then
                line = cand
                break
            end
            -- php heredoc (<<<SQL … SQL;): the following lines ARE the
            -- literal, until the terminator (or the use = still a prefix)
            local hd = cand:match('%$?' .. varname .. '%s*=%s*<<<%s*[\'"]?(%u+)')
            if hd then
                local parts = {}
                for hl = l + 1, line0 do
                    local t2 = src_cache[file][hl] or ''
                    if t2:match('^%s*' .. hd .. '%s*;?%s*$') then
                        return table.concat(parts, ' '), nil, hedged
                    end
                    parts[#parts + 1] = t2
                end
                return table.concat(parts, ' '), true, hedged
            end
        end
        if not qch then return nil end
        local rest = line:sub(pos)
        local close = rest:find(qch, 1, true)
        if not close then return rest, true, hedged end -- off the line: prefix
        local v = rest:sub(1, close - 1)
        local after = rest:sub(close + 1):match('^%s*(%p?)')
        if after == '' or after == ';' or after == ',' or after == ')' then
            return v, nil, hedged
        end
        return v, true, hedged -- concatenation continues: a prefix
    end

    -- cbarg marks are RESOLUTION INPUT (same-file priority skips dispatched
    -- defs), so they must be COMPLETE BEFORE the pass, not minted during it:
    -- a mid-pass mint made the tier depend on call order, and a cross-pass
    -- one (worker pass vs relink pass) made inline and parallel disagree —
    -- both found by the --parallel parity gate. The pre-scan marks
    -- module-level identifier args naming a globally-unique fn (the
    -- name-only core of the upgrade's criterion; the upgrade itself still
    -- runs in the pass, it just no longer marks).
    -- ... and they must be GLOBAL evidence: a worker slice's "unique" is a
    -- batch artifact (one arch header per slice makes GENERAL_REGISTERS
    -- unique), and a slice-minted mark RIDES THE NODE through merge into
    -- relink, denying the same-file priority inline grants — the parity
    -- gate caught it (ghost/v8). Slice extracts skip the pre-scan; the
    -- audit's dispatched[] recompute + relink's own global pre-scan are
    -- the authoritative correction.
    if not (opts and (opts.skip_idpass or opts.defs_only or opts.dataflow_only)) then
        for _, p in ipairs(pending) do
            if not fn_at(p.file, p.at.start.line) then
                for _, a in ipairs(p.call.argv) do
                    if a.k == 'local' and a.name then
                        local cands = exact[a.name]
                        if cands and #cands == 1 and (cands[1].kind == 'function'
                            or cands[1].kind == 'method') then
                            cands[1].cbarg = true
                        end
                    end
                end
            end
        end
    end
    -- local-shadow gate: a bare callee bound in its enclosing fn (param or local
    -- decl) must NOT name-match a corpus global — the local shadows it. Built once.
    local parent_fn = build_parent_fn(node_index)
    for _, p in ipairs(pending) do
        -- typed-string SINKS (typed-strings v1): recover the sink arg —
        -- literal, literal-headed concat (PREFIX), or single-assignment
        -- local (flow). ty='sql' rides the call for the sql miner;
        -- ty='code' (eval) exposes the head token as the REAL callee via
        -- the traced machinery (relink re-derives after a parallel audit,
        -- exactly like $fn literal flow).
        do
            local _, psp = elang_for(p.file)
            local sink = psp and psp.string_sinks
                and psp.string_sinks[p.full or p.call.callee]
            -- a sink arg is a POSITION (int) or a KEYWORD name (string —
            -- MaD's Argument[name:]; python execute(sql=...) style)
            local a
            if sink then
                if type(sink.arg) == 'string' then
                    for _, x in ipairs(p.call.argv) do
                        if x.kw == sink.arg then a = x; break end
                    end
                else
                    a = p.call.argv[sink.arg]
                    if a and (a.kw or a.k == 'spread') then a = nil end
                    -- positional index past a spread is unknowable
                    for i = 1, math.min(sink.arg or 0, #p.call.argv) do
                        if p.call.argv[i].k == 'spread' and i < sink.arg then
                            a = nil
                            break
                        end
                    end
                end
            end
            if a then
                local v, pre, hedged
                if a.k == 'lit' then v = a.v
                elseif a.k == 'concat' then v, pre = a.prefix, true
                elseif a.k == 'local' and a.name then
                    v, pre, hedged =
                        flow_string(p.file, p.at.start.line, a.name)
                end
                if v and v ~= '' then
                    p.call.strarg = { ty = sink.ty, v = v, pre = pre or nil,
                        hedge = hedged or nil }
                    -- a hedged head must not mint a confident dispatch
                    if sink.ty == 'code' and not hedged
                        and not p.call.traced then
                        -- head only when its boundary is PROVEN: trailing
                        -- whitespace, or the whole string was read
                        local head = pre
                            and v:match('^%s*([^%s$\'"`;|&<>]+)%s')
                            or v:match('^%s*([^%s$\'"`;|&<>]+)%s*$')
                            or v:match('^%s*([^%s$\'"`;|&<>]+)%s')
                        if head and #head >= 3 then p.call.traced = head end
                    end
                end
            end
        end
        -- ── SLICE EXTRACTS DO NOT RESOLVE (CART-0232) ────────────────────────────
        -- `exact`/`tail` here are built from THIS SLICE's nodes, so "the only def with
        -- that name" is a batch artifact: a name that is ambiguous across the corpus
        -- looks unique inside one worker's files and resolves. That edge then RIDES THE
        -- MERGE into relink, which only re-resolves calls whose `to` is still nil — so
        -- the phantom is never revisited and the parallel graph gains edges the inline
        -- one refuses. MEASURED on ghost: jobs=1 identical to inline, jobs=2 stable but
        -- +2 edges, jobs=4 VARYING run to run (the partition itself varies), which is
        -- what left the matrix `par` column permanently red.
        --
        -- This is the THIRD time this exact shape has been found here, and the fix is
        -- the one the other two already use: a slice skips the global-evidence step and
        -- relink is authoritative. See the id pass ("slice-local uniqueness is not
        -- global uniqueness") and the cbarg pre-scan ("a worker slice's unique is a
        -- batch artifact... slice extracts skip the pre-scan"). Resolution was the one
        -- stage still doing it.
        --
        -- The typed-string / traced / dynamic EXTRACTION facts above stay: they are
        -- properties of the call's own text, not of the name index.
        local resolve_here = not (opts and opts.skip_idpass)
        local target, inferred, refused, ext
        if p.call.dynamic then
            -- $fn(...): frontier — unless single-assignment literal flow
            -- pins the name down within the function
            local lit, t = nil, nil
            t, lit = literal_flow(p)
            -- traced carries the LITERAL whenever one was found (truthy as
            -- before) so relink can re-resolve it — a parallel slice may
            -- know the literal but not see its target.
            -- RUN EVEN IN A SLICE: the literal is a FILE-LOCAL fact (a single
            -- assignment inside this function), and recording it is exactly how the
            -- design intends a slice to hand the call to relink. Skipping the whole
            -- block cost phpproj's `$handler = 'scale'; $handler(4)` edge — the
            -- parity test caught it immediately.
            if lit then p.call.traced = lit end
            if resolve_here then
                target = t
                if target then
                    p.call.dynamic = nil -- pinned down: no longer a frontier
                end
            end
        elseif not resolve_here then
            -- a slice leaves the call unresolved for the parent's relink, exactly as a
            -- fresh call arrives there (see the note above)
        elseif p.indirect then
            target = resolve(p.indirect, p.file)
            inferred = false -- the literal IS the dispatch mechanism
        else
            -- local-shadow gate: a BARE callee bound in the enclosing fn (a param,
            -- e.g. a Promise `reject`, or a local decl, e.g. a `const [x,setX]=…`
            -- hook setter) is NOT a global — leave it for resolve_local_callable
            -- (refuse higher-order / resolve the same-file local) instead of
            -- name-matching a foreign global of the same name.
            -- p.call.full (NOT p.full — that's the resolve KEY, = the callee for
            -- bare calls); a bare call has no full receiver. Gate ONLY 'localdecl'
            -- (a JS/TS const/let/var binding, incl. destructured hook setters): an
            -- unambiguous local VALUE that shadows any global. NOT params — an AMD
            -- `define([…], function(jQuery,…){})` dep is a param whose name-match
            -- to the global IS correct; only a genuine callback param (reject) is a
            -- false global, and the two are indistinguishable here (banked).
            local from = not p.call.full and fn_at(p.file, p.at.start.line)
            local shadowed = from and node_index[from]
                and localdecl_shadow(p.call.callee, p.file, node_index[from], parent_fn, exact)
            if not shadowed then
                target, inferred, refused, ext = resolve(p.full or p.call.callee, p.file)
            end
        end
        if not target and not p.call.dynamic
            and type(p.call.traced) == 'string' then
            -- code sink: the eval'd HEAD is the dispatch (literal, so not ~)
            local t2 = resolve(p.call.traced, p.file)
            if t2 then target, inferred, refused = t2, false, nil end
        end
        if target then
            p.call.to = target.id
            -- a hedged qualification caps the edge at ~ even where the
            -- name-match itself is confident (same-file): the RECEIVER TYPE
            -- was a shadow-walkout guess, and the edge must say so
            local hedged = inferred or p.call.hedge ~= nil
            p.call.inferred = hedged or nil
            local from = fn_at(p.file, p.at.start.line)
            p.call.fn = from
            -- a module-level call (from == nil) is owned by its REGION, attributed
            -- in ONE post-pass after every resolution pass has run — see
            -- own_module_calls below
            if from then addref(from, target.id, p.at, hedged) end
        else
            p.call.fn = fn_at(p.file, p.at.start.line)
            p.call.refused = refused
            -- the resolver knew WHY it stayed silent (external/noise): keep it
            -- ([[cartograph-graph-improvements]] #1). refused and ext are
            -- mutually exclusive — a refusal has candidates, ext does not.
            p.call.ext = not refused and ext or nil
        end
        -- callback pattern: an identifier argument naming a unique function
        for _, a in ipairs(p.call.argv) do
            if a.k == 'local' and a.name then
                local t2, _ = resolve(a.name, p.file)
                if t2 and (t2.kind == 'function' or t2.kind == 'method') then
                    a.k, a.to, a.up = 'func', t2.id, true
                    local from = p.call.fn
                    if from then
                        addref(from, t2.id, p.at, true)
                    else
                        -- passed as data at load time (RunPython(forward),
                        -- operations lists): registered, not dead — and the
                        -- module is the registrant (a descendable alibi).
                        -- The cbarg MARK happened in the pre-scan; minting
                        -- it here made resolution order-dependent
                        addreg(p.file, t2.id, p.at)
                    end
                end
            end
        end
    end

    padd('resolve_setup', _prs)
    local _pr = pstart()
    -- run THE RESOLUTION PIPELINE — the 12 post-passes, one ordered list shared
    -- with relink ([[cartograph-resolution-pipeline]]). ctx.consts folds the
    -- const-fold k='local' keys for the registry pass; ret_* carries the
    -- return-round report back out.
    -- the frontier roster AS IT STANDS NOW: bundles from the walk plus whatever
    -- the file loop turned into an opaque frontier (missing grammar, UNAVAILABLE
    -- read). Their module nodes are minted after this point, which is exactly why
    -- the set has to travel rather than be read back off the graph.
    local unparsed_now = {}
    for _, f in ipairs(minified or {}) do unparsed_now[#unparsed_now + 1] = f end
    for _, f in ipairs(cunparsed or {}) do unparsed_now[#unparsed_now + 1] = f end
    local resolve_ctx = { calls = calls, data = data, exact = exact,
        tail = tail, addref = addref, node_index = node_index,
        scope_of = scope_of, consts = constDefs, parent_fn = parent_fn,
        unparsed = unparsed_now }
    -- slice extracts skip the passes too (CART-0232): every one of them reads the
    -- slice-local exact/tail index, and relink re-runs the whole pipeline globally.
    if not (opts and opts.skip_idpass) then run_resolve_passes(resolve_ctx) end
    if (resolve_ctx.ret_resolved or 0) > 0 then
        data.ret_resolved = resolve_ctx.ret_resolved
        data.ret_rounds = resolve_ctx.ret_rounds
    end
    padd('resolve', _pr)

    -- use edges + function references (the id pass — factored so parallel
    -- extraction can run it in workers against PARENT-built global
    -- lookups; slice-local uniqueness is not global uniqueness)
    if not (opts and (opts.skip_idpass or opts.defs_only or opts.dataflow_only)) then
        local fn_unique = {}
        for name, fns in pairs(exact) do
            if #fns == 1 then
                fn_unique[name] = { id = fns[1].id, file = fns[1].file,
                    line = atr.sl(fns[1].range), node = fns[1] }
            end
        end
        local var_named = {}
        for name, vars in pairs(varsByName) do
            local list = {}
            for _, v in ipairs(vars) do
                list[#list + 1] = { id = v.id, file = v.file,
                    line = atr.sl(v.range) }
            end
            var_named[name] = list
        end
        data.names = {}
        local seq_scopes, seq_any = {}, false
        for f in pairs(fileset) do
            local _, sp = elang_for(f)
            if sp and sp.scope then
                seq_scopes[f] = sp.scope(f, fileset, root)
                seq_any = true
            end
        end
        local L = {
            fn_unique = fn_unique,
            var_named = var_named,
            fn_ranges = fnRanges,
            scopes = seq_any and seq_scopes or nil,
            addref = addref,
            adduse = function (e) edges[#edges + 1] = e end,
            add_names = function (f, s) data.names[f] = s end,
        }
        for _, file in ipairs(files) do
            local buf = mentions[file]
            if buf then reduce_mentions(file, buf, L) end
        end
        -- stdlib RESOLUTION face ([[cartograph-stdlib-profile]]): mint external
        -- std nodes for std-aliased calls. Runs here for the INLINE full extract
        -- (global, single data); the parallel PARENT does it in relink instead.
        if data.stdaliases then mint_std_nodes(data, node_index) end
        -- profile resolution face: mint <runtime>::<method> nodes for a minting
        -- profile's disposed framework calls (ruby-rails). Same inline-vs-relink split.
        if active_profile and active_profile.mint then
            mint_profile_nodes(data, node_index, active_profile)
        end
    else
        -- the parallel driver needs each slice's function extents AND
        -- mention buffers to run the reduce later (all decisions global)
        data.fn_ranges = fnRanges
        data.mentions = mentions
    end

    -- minified bundles as OPAQUE frontiers: visible modules, no parsed
    -- content — descend reaches into them by lazy text search (store)
    local okc, cfg = pcall(require, 'cartograph.config')
    if #minified > 0 and not (okc and cfg.unparsed == false) then
        data.unparsed = minified
        for _, f in ipairs(minified) do
            nodes[#nodes + 1] = { id = f, name = f, kind = 'module', file = f,
                unparsed = true, order = -1,
                range = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } } }
        end
    end
    -- container files whose grammar is missing already have their frontier
    -- module node; the list feeds the same lazy text-search descend
    if #cunparsed > 0 then
        data.unparsed = data.unparsed or {}
        for _, f in ipairs(cunparsed) do
            table.insert(data.unparsed, f)
        end
    end
    data.no_parser = next(no_parser) and vim.tbl_keys(no_parser) or nil
    -- CONST-FOLD post-pass (ladder step 1): upgrade identifier call args to
    -- literals where the name folds to a same-file set-once scalar constant.
    -- Baked into calls here so parallel workers + relink inherit folded argv.
    local _pcf = pstart()
    constfold.fold(calls, constDefs)
    padd('constfold', _pcf)
    -- Module-level calls get their REGION owner, off an index built from the NODES so
    -- both drivers see the same regions.
    --
    -- ONLY WHERE RESOLUTION IS FINAL. A worker CHUNK resolves against its slice, and
    -- relink later recomputes those verdicts against the whole graph ("a worker's
    -- slice-local refusal is stale"). An edge, once added, is never retracted — so
    -- attributing inside a chunk LEAKED two haskell edges whose calls relink then
    -- correctly un-resolved: inline had 10 region-owned edges, parallel 12, and the
    -- matrix `par` column failed on 12 corpora. Same guard, and the same reason, as
    -- the fold below: a chunk's work is provisional.
    if not (opts and (opts.skip_idpass or opts.defs_only or opts.dataflow_only)) then
        own_module_calls(#calls, function (i, f) return calls[i][f] end,
            region_index(data.nodes), addref)
    end
    -- fat-record migration P3: fold df/flow at PRODUCTION so the fat records never persist
    -- past extraction (ingest's fold becomes an idempotent no-op via data._dfcol/_flowcol;
    -- the folded columns are now serializable — P3a — so the cache round-trips the FOLDED
    -- form). SKIP for worker CHUNKS (skip_idpass): their per-chunk cols can't merge; the
    -- parallel PARENT folds the merged graph. Readers are fold-agnostic (P2), so unaffected.
    if not (opts and (opts.skip_idpass or opts.defs_only or opts.dataflow_only)) then
        dfmod.fold(data)
        flowmod.fold(data)
    end
    if M.PROFILE then padd('total', prof._t0); data.prof = prof end
    return data
end

-- THE RESOLUTION INDEX (merging-strategies first cut, [[cartograph-merging-
-- strategies]]): everything resolution needs to look a name/id up, derived PURELY
-- from the node set — `exact`/`tail` (name & last-segment → fn/method nodes,
-- torn/decl-filtered + zig altkeys), `node_index` (id → node), and the literal-
-- name aperture facts (apertures/ns_pfx/global_witness). relink built these inline
-- (the whole-graph merge peak = building this over the full node set + the edges);
-- factoring it into ONE first-class object is the seam that lets the index be
-- built compact/shared and resolution run somewhere OTHER than a central whole-
-- graph pass (index-and-reduce, per-shard, on-demand). Behavior-frozen: same
-- values relink built inline (node_index over ALL nodes is order-independent;
-- exact/tail insertion order preserved; global_witness is a min). elang_for
-- (module upvalue) supplies the literal-name disposition.
local function build_index(nodes)
    local exact, tail, node_index = {}, {}, {}
    local apertures, ns_pfx, global_witness = {}, {}, nil
    for _, n in ipairs(nodes) do
        node_index[n.id] = n
        if (n.kind == 'function' or n.kind == 'method') and not n.torn
            and not n.decl then -- a prototype declaration is not a call target
            exact[n.name] = exact[n.name] or {}
            table.insert(exact[n.name], n)
            local tl = n.name:match('([%w_]+)$')
            if tl and tl ~= n.name then
                tail[tl] = tail[tl] or {}
                table.insert(tail[tl], n)
            end
            -- persisted extra exact keys (zig value-receiver dual-key)
            if n.altkeys then
                for _, k in ipairs(n.altkeys) do
                    exact[k] = exact[k] or {}
                    table.insert(exact[k], n)
                end
            end
        end
    end
    for _, n in ipairs(nodes) do
        if n.kind == 'module' and n.apertures then
            apertures[n.file] = n.apertures
            if not global_witness or n.file < global_witness.file then
                global_witness = { file = n.file, line = n.apertures[1].line }
            end
        elseif n.kind == 'function' or n.kind == 'method' then
            local pfx = n.name:match('^([^/#]+)[/#]')
            if pfx then
                local _, dsp = elang_for(n.file)
                if dsp and dsp.literal_names then ns_pfx[pfx] = true end
            end
        end
    end
    return { exact = exact, tail = tail, node_index = node_index,
        apertures = apertures, ns_pfx = ns_pfx, global_witness = global_witness }
end
M.build_index = build_index -- exposed as the seam a per-shard / on-demand resolver reuses

-- build_symtab — the LIGHT resolution index (federation F2 step 3, [[cartograph-band-
-- federation]] / [[cartograph-consumer-federation]]). Same exact/tail keying as build_index,
-- but each entry is a compact STUB {id, kind, file, name} — the fields cross-band resolution
-- actually reads (bandlink/bandresolve touch id/kind/file(lang) only) — NOT the full node
-- (flow/df = 69-90% of a node's bytes, analysis payload never read by resolution; measured by
-- f2peak). This is the SYMBOL-TABLE INDIRECTION: hold this flat table, stream/defer the heavy
-- detail. Resolution-equivalent to build_index (symtabgate proves f2gate verdicts identical);
-- resident is ~5-20% of the full index (the fan-out-free peak win f2peak modelled).
local function build_symtab(nodes)
    local exact, tail, node_index = {}, {}, {}
    local apertures, ns_pfx, global_witness = {}, {}, nil
    for _, n in ipairs(nodes) do
        -- node_index covers EVERY node (mirrors build_index — call targets / enclosing fns
        -- are looked up by id regardless of kind/torn/decl). The resolution read-set (audited
        -- off M.relink): id/kind/file/name + ret/retclass/arrow/exported/escapes/cbarg; NOT flow/df
        -- (the analysis payload). exact/tail/node_index alias the SAME stub so a cbarg write
        -- via exact is visible via node_index (relink mutates cbarg in-pass).
        -- params/locals/dfdef feed callee_binding (the local-shadow / fn-value gate).
        -- dfdef = the light NAME-SET df defines (the only df projection resolution reads
        -- — hasdf) — carried instead of the heavy df.stmts.
        local dfdef
        for _, st in ipairs(dfmod.stmts(n)) do -- dual-mode: folded OR raw (fold-agnostic)
            for _, d in ipairs(st.def or {}) do
                dfdef = dfdef or {}; dfdef[d] = true
            end
        end
        local stub = { id = n.id, kind = n.kind, file = n.file, name = n.name,
            ret = n.ret, retclass = n.retclass, arrow = n.arrow,
            exported = n.exported, escapes = n.escapes, cbarg = n.cbarg,
            params = n.params, locals = n.locals, dfdef = dfdef }
        node_index[n.id] = stub
        if (n.kind == 'function' or n.kind == 'method') and not n.torn and not n.decl then
            exact[n.name] = exact[n.name] or {}
            table.insert(exact[n.name], stub)
            local tl = n.name:match('([%w_]+)$')
            if tl and tl ~= n.name then
                tail[tl] = tail[tl] or {}
                table.insert(tail[tl], stub)
            end
            if n.altkeys then
                for _, k in ipairs(n.altkeys) do
                    exact[k] = exact[k] or {}
                    table.insert(exact[k], stub)
                end
            end
        end
    end
    -- aux tables relink also reads (light): apertures (literal-name langs), ns_pfx, witness.
    -- non-def nodes aren't in node_index (resolution never looks them up by id).
    for _, n in ipairs(nodes) do
        if n.kind == 'module' and n.apertures then
            apertures[n.file] = n.apertures
            if not global_witness or n.file < global_witness.file then
                global_witness = { file = n.file, line = n.apertures[1].line }
            end
        elseif n.kind == 'function' or n.kind == 'method' then
            local pfx = n.name:match('^([^/#]+)[/#]')
            if pfx then
                local _, dsp = elang_for(n.file)
                if dsp and dsp.literal_names then ns_pfx[pfx] = true end
            end
        end
    end
    return { exact = exact, tail = tail, node_index = node_index,
        apertures = apertures, ns_pfx = ns_pfx, global_witness = global_witness }
end
M.build_symtab = build_symtab -- the F2 light index (drop-in for build_index's resolution reads)

--- Re-resolve name-matched links over a (possibly spliced) graph: every
--- call lacking `to` gets another chance against the CURRENT node set,
--- and its ref edge is added (deduped against existing edges). Mirrors
--- extract()'s resolution semantics — same-file non-cbarg priority,
--- unique-tail fallback, stdlib gates, min-length guard. Used by live
--- refresh, where a changed file's calls (and other files' calls INTO
--- the changed file) need relinking.
function M.relink(data, touched)
    local relset = {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'module' then relset[n.file] = true end
    end
    -- overlay packs: mirror extract's composition so relink's resolve uses the
    -- same (rails) vocab. Synth nodes are already in data.nodes (indexed below).
    local active_packs = {}
    for _, pn in ipairs(data.packs or {}) do
        if M.packs[pn] then active_packs[#active_packs + 1] = M.packs[pn] end
    end
    -- PREFER WHAT THE GRAPH WAS BUILT WITH. data.profile is set by extract (detected
    -- or overridden) and restored by cache's empty_data on a warm graph, so it is the
    -- authoritative answer; re-deriving from the shape would silently drop an override
    -- at relink and refresh time. Falls back to detection when absent — the old
    -- behaviour on every graph with no profile recorded.
    --
    -- DELIBERATELY NOT THROUGH env_usable. That fence exists for USER input, where a
    -- bad name must be an error rather than a silent fallback. `data.profile` is our
    -- OWN recorded value, already validated when it was chosen, so re-validating it
    -- here would only create a new failure mode: a warm graph naming a profile since
    -- renamed or removed would make relink THROW instead of degrading to detection.
    local active_profile = (data.profile and _profile_mod.load(data.profile))
        or active_profile_for(data.root)
    -- record the active profile on the parallel-parent result too (extract stamps
    -- it inline; relink is the parallel path — keep the provenance field consistent)
    if active_profile then data.profile = active_profile.runtime end
    local eff_spec = spec_overlay(active_packs, active_profile)
    local scope_cache = {}
    local function scope_of(f)
        if scope_cache[f] == nil then
            local _, sp = elang_for(f)
            scope_cache[f] = sp and sp.scope
                and sp.scope(f, relset, data.root) or false
        end
        return scope_cache[f] or nil
    end
    -- THE INDEX (one first-class object; the merging-strategies seam). node_index
    -- is available immediately (was built later inline — order-independent, so
    -- earlier is equivalent). federated_resolve (F2 step 3b, default off): resolution
    -- runs off the LIGHT symbol table (stubs, no flow/df) instead of full nodes —
    -- the correctness milestone (gate --parallel per-item IDENTITY is the oracle);
    -- the peak drop lands once detail is streamed off residency (step 3c).
    local index = (require('cartograph.config').federated_resolve and build_symtab
        or build_index)(data.nodes)
    local exact, tail, node_index = index.exact, index.tail, index.node_index
    local apertures, ns_pfx, global_witness = index.apertures, index.ns_pfx, index.global_witness
    local aperture_refusal = aperture_refuser(ns_pfx, apertures, global_witness)
    local refEdge, regEdge = {}, {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' then refEdge[e.from .. '\31' .. e.to] = e
        elseif e.kind == 'reg' then regEdge[e.from .. '\31' .. e.to] = e end
    end
    local addref = ref_adder(refEdge, data.edges)
    local function addreg(from, to, at)
        local k = from .. '\31' .. to
        if regEdge[k] then return end -- already registered from this module
        local e = { from = from, to = to, kind = 'reg', at = at and { at } or {} }
        regEdge[k] = e
        data.edges[#data.edges + 1] = e
    end
    local function resolve(name, file)
        -- short names: same-file tier only (see extract's resolve, the
        -- synjs q3 witness); cross-file fallbacks stay noise-gated
        local short = #name < 3
        local clang, spec = elang_for(file)
        spec = eff_spec(clang, spec) -- overlay pack (rails vocab in stdlib_names)
        local snames = spec and spec.stdlib_names or {}
        if snames[name] then return nil, nil, nil, EXT.vocab end
        local cands = exact[name]
        -- the stdlib TAIL gate guards the fallbacks below; an exact match
        -- on a fully-qualified name (Engine::new) clears first. Literal-
        -- name languages (bash) have no qualification syntax at all — a
        -- slashed fn like ble/bash/read must not vocab-die on tail `read`
        if not cands and not (spec and spec.literal_names)
            and snames[name:match('([%w_%-]+)$') or ''] then
            return nil, nil, { rule = 'vocab' }
        end
        if cands then
            local same, samedup
            for _, n in ipairs(cands) do
                if n.file == file and not n.cbarg then
                    if same then -- ambiguous within the file: refuse
                        samedup = samedup or { same }
                        samedup[#samedup + 1] = n
                    else
                        same = n
                    end
                end
            end
            if samedup then return nil, nil, refusal('samefile', samedup) end
            if same then return same, false end
            if short then return nil, nil, nil, EXT.short end -- no same-file binder: noise floor
            -- workspace-unique, but never across a scope boundary (rust
            -- crates: bare names cannot legally cross); dotted callees
            -- are method syntax and never match free functions
            local sc = scope_of(file)
            -- QUALIFIED references (pkg.Fn, x.method) are how code legally
            -- crosses a scope boundary, so they match globally — rust
            -- additionally knows x.f() is method dispatch; bare
            -- identifiers never cross, so their uniqueness is scope-local
            -- (`::` is a qualified receiver too — Class::m explicitly names
            -- the class and crosses packages, same as the tail path below)
            local dotted = name:find('.', 1, true) ~= nil
                or name:find('->', 1, true) ~= nil
                or name:find('::', 1, true) ~= nil
                or (spec and spec.hash_qualified
                    and name:find('#', 1, true) ~= nil)
            local fitset = {}
            for _, n in ipairs(cands) do
                local fits
                if dotted then
                    fits = not (spec and spec.dot_calls_are_methods)
                        or n.kind == 'method'
                    -- WoW addons: a qualified/method name's receiver is
                    -- the addon's OWN object (its vendored Ace copy) —
                    -- qualified names stay scope-local too. Single-scope
                    -- trees ('' everywhere) are unaffected.
                    if fits and spec and spec.qualified_scope_local then
                        fits = sc == nil or scope_of(n.file) == sc
                    end
                else
                    fits = sc == nil or scope_of(n.file) == sc
                end
                -- a name never crosses LANGUAGES: that is xlang's job,
                -- explicit and string-keyed — js .replace() must not
                -- tail-match a ruby #replace
                if fits and elang_for(n.file) ~= clang then fits = false end
                -- a confined file-local is not a candidate for a call in another
                -- file, however unique its name is here (CART-0230)
                if fits and confined(n, file) then fits = false end
                if fits then fitset[#fitset + 1] = n end
            end
            if #fitset == 1 then return fitset[1], true end
            -- the refusal is a PLACE: who was refused, and by which rule
            return nil, nil, refusal(#fitset > 1 and 'ambiguous' or 'blocked',
                #fitset > 0 and fitset or cands)
        end
        if short then return nil, nil, nil, EXT.short end -- free short name: noise floor holds
        -- receiver-evidence keys (ruby `Foo.bar`) are exact-or-nothing: an
        -- exact miss is an honest frontier, never a promiscuous tail guess
        if spec and spec.exact_only_key and spec.exact_only_key(name) then
            return nil, nil, nil, EXT.exact
        end
        for _, pre in ipairs(spec and spec.stdlib_prefixes or {}) do
            if name:sub(1, #pre) == pre then return nil, nil, nil, EXT.prefix end
        end
        -- literal-name languages never tail-match: a bash command names
        -- its function EXACTLY (slashes are just characters), so `split`
        -- must not fuzzy-hit thousands of ble/string#split-style defs —
        -- an unknown name is an external command, not a near-miss...
        -- UNLESS it wears a known fn namespace and the corpus contains
        -- conjuring sites: then refusal-with-witness (the aperture)
        if spec and spec.literal_names then
            local ar = aperture_refusal(name, file)
            if ar then return nil, nil, ar end
            return nil, nil, nil, prof_ext(spec, name) or EXT.nodef
        end
        local tl = name:match('([%w_]+)$')
        local tc = tl and (tail[tl] or exact[tl])
        if tc then
            local sc = scope_of(file)
            local dotted = name:find('.', 1, true) ~= nil
                or name:find('->', 1, true) ~= nil
                or name:find('::', 1, true) ~= nil
                or (spec and spec.hash_qualified
                    and name:find('#', 1, true) ~= nil)
            local function admits(n)
                local fits
                if dotted then
                    fits = not (spec and spec.dot_calls_are_methods)
                        or n.kind == 'method'
                    -- WoW addons: a qualified/method name's receiver is
                    -- the addon's OWN object (its vendored Ace copy) —
                    -- qualified names stay scope-local too. Single-scope
                    -- trees ('' everywhere) are unaffected.
                    if fits and spec and spec.qualified_scope_local then
                        fits = sc == nil or scope_of(n.file) == sc
                    end
                else
                    fits = sc == nil or scope_of(n.file) == sc
                end
                -- a name never crosses LANGUAGES: that is xlang's job,
                -- explicit and string-keyed — js .replace() must not
                -- tail-match a ruby #replace
                if fits and elang_for(n.file) ~= clang then fits = false end
                if fits and confined(n, file) then fits = false end -- CART-0230
                return fits
            end
            -- ── RECEIVER-PATH AGREEMENT, before the tail-vs-exact preference.
            -- A call `a.b.m` and a candidate named `b.m` agree on the RECEIVER, which
            -- the bare tail `m` says nothing about. Where exactly one admitted
            -- candidate agrees, that is a better answer than whichever index happened
            -- to answer first — and it is the only receiver question a NAME can settle
            -- (see recv_agrees). ADDITIVE BY CONSTRUCTION: a unique agreement either
            -- fills a call the tail preference left ambiguous, or corrects one it
            -- resolved to a candidate whose receiver contradicts the call's; with no
            -- unique agreement the block below runs exactly as it did.
            if dotted then
                local agree
                for _, list in ipairs({ tail[tl] or {}, exact[tl] or {} }) do
                    for _, n in ipairs(list) do
                        if recv_agrees(name, n.name) and admits(n) then
                            if agree and agree.id ~= n.id then agree = nil; goto no_agree end
                            agree = n
                        end
                    end
                end
                if agree then return agree, true end
                ::no_agree::
            end
            local fitset = {}
            for _, n in ipairs(tc) do
                if admits(n) then fitset[#fitset + 1] = n end
            end
            if #fitset == 1 then return fitset[1], true end
            return nil, nil, refusal(#fitset > 1 and 'ambiguous' or 'blocked',
                #fitset > 0 and fitset or tc)
        end
        return nil, nil, nil, prof_ext(spec, name) or EXT.nodef
    end
    local n = 0
    -- CALL ACCESS is representation-neutral (callview, the record-fold PEAK arc):
    -- relink's base resolve loop + the cbarg pre-scan + the pipeline (via ctx.cv)
    -- read/write calls INDEX-FORM over the columnar store when the parent holds
    -- one (data._callstore), else raw records. [[cartograph-record-fold-arc]]
    local cv = require('cartograph.callview').of(data)
    local cget, cset = cv.get, cv.set
    -- cbarg pre-scan, mirroring extract's: marks are resolution INPUT and
    -- must be complete before the pass (see extract; --parallel parity).
    -- An arg a WORKER already upgraded arrives as k='func' with a.up —
    -- it still testifies (skipping it hid the mark from relink while the
    -- inline pre-scan saw it: a tier flip the parity gate caught)
    for i = 1, cv.n do
        if not cget(i, 'fn') then
            for j = 1, cv.argn(i) do
                local ak, aname = cv.aget(i, j, 'k'), cv.aget(i, j, 'name')
                if (ak == 'local' or (ak == 'func' and cv.aget(i, j, 'up'))) and aname then
                    local cands = exact[aname]
                    if cands and #cands == 1 and (cands[1].kind == 'function'
                        or cands[1].kind == 'method') then
                        cands[1].cbarg = true
                    end
                end
            end
        end
    end
    -- node_index came from build_index above (the local-shadow gate + super.m()
    -- owner lookup + module-alias foreign-override read it).
    -- local-shadow gate (see extract): built once, shared with resolve_local_callable
    local parent_fn = build_parent_fn(node_index)
    -- the region index for module-level ownership: the SAME helper extract uses, so
    -- the two drivers cannot disagree about which regions exist (see region_index)
    local region_at = region_index(node_index)
    for i = 1, cv.n do
        local cfile = cget(i, 'file')
        local cfn = cget(i, 'fn')
        -- dynamic calls stay frontiers UNLESS a literal-flow trace already
        -- named the callee (a parallel slice may know the literal but not
        -- have seen its target)
        local ctraced = cget(i, 'traced')
        if not cget(i, 'to') and (not cget(i, 'dynamic') or type(ctraced) == 'string') then
            local target, inferred, refused, ext
            local cfull, ccallee = cget(i, 'full'), cget(i, 'callee')
            if type(ctraced) == 'string' then
                target = resolve(ctraced, cfile)
                inferred = false
            elseif cget(i, 'indirect') then
                target = resolve(cget(i, 'indirect'), cfile)
                inferred = false
            elseif not cfull and cfn and node_index[cfn]
                and localdecl_shadow(ccallee, cfile, node_index[cfn], parent_fn, exact) then
                -- local-shadow gate (see extract): a JS/TS const/let/var-bound bare
                -- callee with no same-file def is not a global — leave it for
                -- resolve_local_callable (refuse fn-value) below
            else
                target, inferred, refused, ext = resolve(cfull or ccallee, cfile)
            end
            if target then
                cset(i, 'to', target.id)
                -- the ~ mark is part of the resolution, not decoration:
                -- a relinked call must carry the same honesty as extract's
                -- (including the hedged-qualification cap, see extract)
                local hedged = inferred or cget(i, 'hedge') ~= nil
                cset(i, 'inferred', hedged or nil)
                cset(i, 'refused', nil)
                cset(i, 'ext', nil) -- was external/noise, now resolved (re-link mutates)
                if cget(i, 'dynamic') then cset(i, 'dynamic', nil) end -- pinned by the trace
                n = n + 1
                if touched then touched[cfile] = true end
                if cfn then
                    local cline = cget(i, 'line')
                    addref(cfn, target.id, cget(i, 'at')
                        or { start = { line = cline, char = 0 },
                            ['end'] = { line = cline, char = 0 } }, hedged)
                end
            else
                -- the refusal recomputed against the CURRENT global
                -- node set (a worker's slice-local refusal is stale)
                cset(i, 'refused', refused)
                cset(i, 'ext', not refused and ext or nil) -- else external/noise why
            end
        end
        -- callback-pattern mirror: an identifier argument naming a unique
        -- function upgrades to a resolved 'func' arg (extract does this;
        -- without the mirror a splice or audit loses the upgrade)
        for j = 1, cv.argn(i) do
            local ak, aname = cv.aget(i, j, 'k'), cv.aget(i, j, 'name')
            if ak == 'local' and aname then
                local t2 = resolve(aname, cfile)
                if t2 and (t2.kind == 'function' or t2.kind == 'method') then
                    cv.aset(i, j, 'k', 'func'); cv.aset(i, j, 'to', t2.id); cv.aset(i, j, 'up', true)
                    if touched then touched[cfile] = true end
                    local cline = cget(i, 'line')
                    if cfn then
                        addref(cfn, t2.id,
                            { start = { line = cline, char = 0 },
                                ['end'] = { line = cline, char = 0 } }, true)
                    else
                        -- the MARK happened in the pre-scan (see extract)
                        addreg(cfile, t2.id,
                            { start = { line = cline, char = 0 },
                                ['end'] = { line = cline, char = 0 } })
                        if touched then touched[t2.file] = true end
                    end
                end
            end
        end
    end
    -- run THE RESOLUTION PIPELINE over the full (merged/spliced) graph — the
    -- SAME ordered list extract runs, no longer a hand-mirrored copy
    -- ([[cartograph-resolution-pipeline]]): one list, two drivers. relink's ctx
    -- passes consts=nil (const-fold keys are extract-only); node_index was
    -- built above, before the resolve loop.
    n = n + run_resolve_passes({ calls = data.calls, data = data, exact = exact,
        tail = tail, addref = addref, node_index = node_index,
        scope_of = scope_of, consts = nil, parent_fn = parent_fn,
        -- relink reads the roster off the graph, where extract could not: by this
        -- point the frontier module nodes exist, so node_index would answer too —
        -- passing it keeps the two drivers giving the pass the same input rather
        -- than two different routes to it
        unparsed = data.unparsed })
    -- stdlib RESOLUTION face: mint std nodes for std-aliased calls. GLOBAL here
    -- (relink runs over the full merged graph → covers the parallel parent);
    -- idempotent, so re-running on an incremental relink is safe.
    if data.stdaliases then mint_std_nodes(data, node_index) end
    -- profile resolution face: covers the parallel parent (relink recomputes
    -- active_profile; data.profile isn't restamped here). Idempotent like above.
    if active_profile and active_profile.mint then
        mint_profile_nodes(data, node_index, active_profile)
    end
    -- federated_resolve: cbarg marks the pre-scan added went to the light STUBS
    -- (node_index/exact are stubs); replay them onto the real graph nodes (the sole
    -- node mutation relink makes — the light index otherwise touches no node detail).
    if require('cartograph.config').federated_resolve then
        for _, gn in ipairs(data.nodes) do
            local s = node_index[gn.id]
            if s and s.cbarg then gn.cbarg = true end
        end
    end
    -- module-level ownership, relink's half: the SAME post-pass extract runs, over
    -- the column view. Both must run — in a parallel extraction a worker owns what
    -- it resolved and relink owns the rest — and addref dedupes by (from,to), so the
    -- union is exactly the inline set.
    own_module_calls(cv.n, cget, region_at, addref)
    return n
end

return M
