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
local flowmod = require 'cartograph.flow' -- df-strangler step 4: eager per-fn fine flow rows, folded at ingest (flow requires nothing back → no cycle)
local dfmod = require 'cartograph.df' -- fat-record migration: the DUAL-MODE df.stmts accessor (folded OR raw), so relink readers are fold-agnostic (df requires nothing → no cycle)
local constfold = require 'cartograph.constfold' -- const-fold ladder step 1: same-file scalar-const index + argv fold (no cycle)
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
local function active_profile_for(root)
    if type(root) ~= 'string' then return nil end
    _shapes_mod = _shapes_mod or require 'cartograph.shapes'
    for _, p in ipairs(_shapes_mod.probe(root)) do
        if p.evidence and p.config and p.config.profile then
            return _profile_mod.load(p.config.profile)
        end
    end
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
local inext = tsutil.inext
local refusal = tsutil.refusal

-- shared empty iterator: the `... or function () end` fallback used to allocate
-- a fresh closure on every nil-children branch in hot loops
local function NOOP() end

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
    while n:type() == 'parenthesized_expression' do n = n:named_child(0) end
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
    while n:type() == 'parenthesized_expression' do n = n:named_child(0) end
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
            while x:type() == 'parenthesized_expression' do x = x:named_child(0) end
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
        if n:type() == 'call' then
            local m = n:field('method')[1]
            local mn = m and node_text(m, src)
            local args = mn and n:field('arguments')[1]
            if args and RB_ASSOC[mn] then
                local C = owner(n)
                if C then
                    -- the FIRST symbol is the association name → reader + writer
                    for c in args:iter_children() do
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
            if item:named() and item:type() ~= 'comment' then
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
                        if c2:named() and c2:type() ~= 'comment' then kids[#kids + 1] = c2 end
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
            if el:named() and el:type() ~= 'comment' then
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
    local ps = spec.params_field and def:field(spec.params_field)[1]
    local out = method and { 'self' } or {}
    if ps then
        for _, c in inext, ps, -1 do
            if c:type() == 'identifier' or c:type() == 'variable' then
                out[#out + 1] = node_text(c, src)
            elseif c:type() == 'variable_name' then -- php $param
                out[#out + 1] = node_text(c, src):gsub('^%$', '')
            elseif c:named() then -- c parameter_declaration / defaulted params
                for _, id in inext, c, -1 do
                    if id:type() == 'identifier' then
                        out[#out + 1] = node_text(id, src)
                        break
                    end
                    if id:type() == 'variable_name' then
                        out[#out + 1] = node_text(id, src):gsub('^%$', '')
                        break
                    end
                    if id:type() == 'pointer_declarator' then
                        local inner = id:field('declarator')[1]
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

local function lang_for(file)
    local ext = file:match('%.([%w]+)$')
    if not ext then return nil end
    for lang, spec in pairs(M.spec) do
        for _, e in ipairs(spec.exts) do
            if e == ext then return lang, spec end
        end
    end
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
-- scan. The registry is static (no runtime spec mutation), so the memo
-- cannot go stale.
local EXT_ELANG = {} -- ext -> { lang|false, spec|false }
local function elang_for(file)
    local ext = file:match('%.([%w]+)$') or ''
    local hit = EXT_ELANG[ext]
    if hit then return hit[1] or nil, hit[2] or nil end
    local lang, spec
    if CONTAINERS[ext] then
        lang, spec = 'javascript', M.spec.javascript
    else
        lang, spec = lang_for(file)
        -- typescript AND tsx fold to the javascript RESOLUTION family + spec (one
        -- language across .js/.jsx/.ts/.tsx); the real PARSER differs per file
        -- (parse_lang_for keeps typescript/tsx). .jsx is already 'javascript'.
        if lang == 'typescript' or lang == 'tsx' then
            lang, spec = 'javascript', M.spec.javascript
        end
    end
    EXT_ELANG[ext] = { lang or false, spec or false }
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
-- grammar (their region trees are JS). Memoized by extension like elang_for.
local EXT_PLANG = {}
local function parse_lang_for(file)
    local ext = file:match('%.([%w]+)$') or ''
    local hit = EXT_PLANG[ext]
    if hit ~= nil then return hit or nil end
    local plang
    if CONTAINERS[ext] then
        plang = 'javascript'
    else
        plang = lang_for(file) -- the REAL registered grammar (typescript for .ts)
    end
    EXT_PLANG[ext] = plang or false
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
local function chain_lookup(super, exact, C, member, clang)
    local seen, cur = {}, C
    for _ = 1, SUPER_STEP_LIMIT do
        for _, sep in ipairs({ ':', '.' }) do
            local fit, dup
            for _, nd in ipairs(exact[cur .. sep .. member] or {}) do
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

-- Upgrade still-refused MODULE-ALIAS calls: `alias.member(...)` where `alias` is
-- bound to require('mod') in this file (the import edge's `bind`) → mod's `member`
-- export. The receiver's module is KNOWN, so the ambiguous tail (`get`/`has`/…)
-- narrows to the unique fn/method defined in that module file. This is RUNG-1
-- receiver resolution ([[cartograph-scope-model]]) — require-alias, VM-INDEPENDENT
-- — wiring the import edges + the tail index, no new analysis. Marked inferred
-- (~): a derived resolution via the alias binding (a single-assignment/reaching
-- check would promote it, and rule out reassigned aliases — banked). Lua-only
-- today (only lua's spec captures import_bind); js/php import forms come later.
local function resolve_module_alias(cv, edges, exact, tail, addref, node_index)
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
                local fit, dup = nil, false
                for _, nd in ipairs(tail[member] or exact[member] or {}) do
                    if nd.file == mod and (nd.kind == 'function' or nd.kind == 'method') then
                        if fit and fit.id ~= nd.id then dup = true else fit = nd end
                    end
                end
                local cto = cget(i, 'to')
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
    return mint_nodes(data, node_index, profile.runtime .. '::', profile.runtime,
        function (cget, i)
            local e = cget(i, 'ext')
            if type(e) ~= 'table' then return nil end
            local callee = cget(i, 'callee')
            if not callee then return nil end
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
                    local fit, dup = nil, false
                    for _, nd in ipairs(tail[ccallee] or exact[ccallee] or {}) do
                        if nd.file == tfile
                            and (nd.kind == 'function' or nd.kind == 'method') then
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
                        local vk = nd.file .. '\0' .. nd.range.start.line
                        local cur = varAt[vk]
                        local ndc, curc = is_class[nd.name], cur and is_class[cur.name]
                        if not cur or (ndc and not curc)
                            or (ndc == curc and nd.range.start.char < cur.range.start.char) then
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
local function resolve_self(cv, node_index, extends, exact, addref)
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
                    local fit = chain_lookup(super, exact, C, member, elang_for(cget(i, 'file')))
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
                local fit = chain_lookup(super, exact, owner, member, elang_for(cget(i, 'file')))
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
                local s, en = nd.range.start.line, nd.range['end'].line
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
        return resolve_module_alias(x.cv, x.data.edges, x.exact, x.tail, x.addref, x.node_index) end },
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
        return resolve_self(x.cv, x.node_index, x.data.extends, x.exact, x.addref) end },
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
}
local SUBSTMT_CLAUSES = {
    else_statement = true, elseif_statement = true, else_clause = true,
    elif_clause = true, elseif_clause = true, catch_clause = true,
    finally_clause = true, ['then'] = true, do_statement = true,
    case_statement = true, switch_case = true, when_entry = true,
}
-- lisp: nesting is child LIST forms, not blocks
local LISP_LANGS = { scheme = true, commonlisp = true, clojure = true, fennel = true, janet = true }
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
        -- list of a def/lambda); bare symbols/atoms are leaves, not forms
        for _, c in inext, node, -1 do
            if c:named() and c:type() == 'list' then out[#out + 1] = c end
        end
        return out
    end
    local function scan(n)
        for _, c in inext, n, -1 do
            if c:named() and c:type() ~= 'comment' then
                local t = c:type()
                if SUBSTMT_BLOCKS[t] then
                    for _, g in inext, c, -1 do
                        if g:named() and g:type() ~= 'comment' then out[#out + 1] = g end
                    end
                elseif SUBSTMT_CLAUSES[t] then
                    scan(c)
                end
            end
        end
    end
    scan(node)
    return out
end

-- (binder_at — the scope-model shadow-attribution service — was RETIRED here
-- with df-strangler step-5 fine half: extract.plan, its last consumer, now takes
-- flow's scope-correct CFG reaching, so a shadowed name resolves by def ROW
-- without a separate on-demand binder resolver. [[cartograph-df-strangler]])

--- Immediate sub-forms of a form in `file`, for the browser's block descent.
--- Two modes:
---   * EXACT node — pass the full range (sr,sc,er,ec) of a known node (a
---     function's body, or a sub-form returned by a previous call).
---   * POSITION — pass only (sr,sc): the enclosing STATEMENT at that point
---     (walking up but stopping before its block), e.g. a df row's line.
--- Returns a list of { sr, sc, er, ec (0-based, ec exclusive), text, branch },
--- branch = true when that sub-form has its own sub-forms (descend again).
--- Recomputed on demand — nothing is cached in the graph.
function M.forms(file, sr, sc, er, ec)
    local _, spec = elang_for(file)
    local lang = parse_lang_for(file) -- TS parses under typescript, not js
    if not (lang and spec) then return {} end
    local fd = io.open(file, 'r')
    if not fd then return {} end
    local src = fd:read('a'); fd:close()
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return {} end
    local tree = parser:parse()[1]
    if not tree then return {} end
    local root = tree:root()
    local lisp = LISP_LANGS[lang] or false

    local n
    if er then
        -- exact node spanning the given range (ec exclusive -> inclusive probe)
        n = root:named_descendant_for_range(sr, sc, er, math.max(sc, ec - 1))
    else
        -- position mode: the statement that STARTS on row `sr` — the child of
        -- a block/root that begins there (indentation-agnostic; col ignored)
        local function find_stmt(node)
            local container = SUBSTMT_BLOCKS[node:type()] or ROOT_TYPES[node:type()]
            for _, c in inext, node, -1 do
                if c:named() and c:type() ~= 'comment' then
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
        if head and head:type() == 'symbol' then
            local h = node_text(head, src)
            if h:match('^define') or h:match('^lambda') or h:match('^let')
                or h == 'named-lambda' then
                drop_first_list = true
            end
        end
    end

    local subs = child_forms(n, lisp)
    if lisp and drop_first_list and subs[1] then table.remove(subs, 1) end

    local out = {}
    for _, s in ipairs(subs) do
        local ssr, ssc, ser, sec = s:range()
        -- the form's OWN text (first line), so several forms sharing a source
        -- line read distinctly; whitespace collapsed, truncated
        local text = node_text(s, src):gsub('%s+', ' '):gsub('^%s*', ''):sub(1, 80)
        out[#out + 1] = { sr = ssr, sc = ssc, er = ser, ec = sec, text = text,
            branch = #child_forms(s, lisp) > 0 }
    end
    return out
end

-- argument-list containers and conditional statements, for the detail lens
local ARG_LISTS = { arguments = true, argument_list = true }
local COND_TYPES = { if_statement = true, elseif_statement = true,
    while_statement = true, repeat_statement = true, switch_statement = true,
    ['for_statement'] = true, for_in_statement = true, when = true }

-- a statement's DETAIL items: for a conditional, its condition; otherwise the
-- arguments of any calls it makes (not descending into nested blocks — those
-- belong to the block lens). Each item is { kind='cond'|'arg', sr,sc,er,ec, text }.
local function detail_items(stmt, src)
    local items = {}
    local function mk(kind, n)
        local a, b, c, d = n:range()
        items[#items + 1] = { kind = kind, sr = a, sc = b, er = c, ec = d,
            text = node_text(n, src):gsub('%s+', ' '):gsub('^%s*', ''):sub(1, 80) }
    end
    if COND_TYPES[stmt:type()] then
        local cond = stmt:field('condition')[1]
        if not cond then
            for _, c in inext, stmt, -1 do
                if c:named() and c:type() ~= 'comment'
                    and not SUBSTMT_BLOCKS[c:type()] then cond = c break end
            end
        end
        if cond then mk('cond', cond) end
        return items -- the body is the block lens's concern, not the detail's
    end
    local function walk(n)
        for _, c in inext, n, -1 do
            if c:named() and c:type() ~= 'comment' and not SUBSTMT_BLOCKS[c:type()] then
                if ARG_LISTS[c:type()] then
                    for _, a in inext, c, -1 do
                        if a:named() and a:type() ~= 'comment' then mk('arg', a) end
                    end
                else
                    walk(c)
                end
            end
        end
    end
    walk(stmt)
    return items
end

--- The detail-lens rows for a code range: each top-level statement with its
--- detail items (a conditional's condition; a call's arguments). Same on-demand
--- parse as M.forms; returns { {sr,sc,er,ec,text, items={...}}, ... }.
function M.detail(file, sr, sc, er, ec)
    local _, spec = elang_for(file)
    local lang = parse_lang_for(file) -- TS parses under typescript, not js
    if not (lang and spec) then return {} end
    local fd = io.open(file, 'r'); if not fd then return {} end
    local src = fd:read('a'); fd:close()
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return {} end
    local tree = parser:parse()[1]; if not tree then return {} end
    local root = tree:root()
    local lisp = LISP_LANGS[lang] or false
    local n = root:named_descendant_for_range(sr, sc, er or sr, er and math.max(sc, ec - 1) or sc)
    if not n then return {} end
    if not er then
        while n:parent() do
            local pr, pc = n:parent():start()
            if pr == sr and pc == sc and not SUBSTMT_BLOCKS[n:parent():type()] then
                n = n:parent()
            else break end
        end
    end
    local stmts = child_forms(n, lisp)
    local out = {}
    for _, s in ipairs(stmts) do
        local a, b, c, d = s:range()
        out[#out + 1] = { sr = a, sc = b, er = c, ec = d,
            text = node_text(s, src):gsub('%s+', ' '):gsub('^%s*', ''):sub(1, 80),
            items = detail_items(s, src) }
    end
    return out
end

-- parse a container file and return its host-language trees in
-- DETERMINISTIC position order (the LanguageTree child table has no
-- stable iteration order; worker output must equal inline output).
-- nil for plain files, so callers can fall back to the single root.
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

local function list_files(root, subdirs)
    local out, minified = {}, {}
    local seen_real = {} -- external symlink targets already walked (cycles/dups)
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
        local it = vim.uv.fs_scandir(rel == '' and root or (root .. '/' .. rel))
        while it do
            local name, t = vim.uv.fs_scandir_next(it)
            if not name then break end
            if name:sub(1, 1) ~= '.' then
                local r = rel == '' and name or (rel .. '/' .. name)
                if t == 'link' then
                    -- a symlinked DIR: follow only when it points OUTSIDE
                    -- the root (a corpus assembled from symlinks —
                    -- factorio-mods). An INTERNAL alias (ripgrep's
                    -- HomebrewFormula -> pkg/brew) is skipped: the real
                    -- path is walked normally, and following both would
                    -- duplicate every file under two keys.
                    local p = root .. '/' .. r
                    local st = vim.uv.fs_stat(p)
                    if st and st.type == 'directory' then
                        local rp = vim.uv.fs_realpath(p)
                        local rootrp = vim.uv.fs_realpath(root)
                        if rp and rootrp
                            and rp:sub(1, #rootrp + 1) ~= rootrp .. '/' then
                            if not seen_real[rp] then
                                seen_real[rp] = true
                                t = 'directory'
                            end
                        end
                    elseif st and st.type == 'file' then
                        t = 'file'
                    end
                end
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
                end
            end
        end
    end
    rec('')
    table.sort(out)
    table.sort(minified)
    return out, minified
end
-- the cache diffs the tree with the same walk/exclusion rules extraction uses
function M.list_files(root, subdirs) return list_files(root, subdirs) end

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
local function collect_mentions(buf, tsroot, src, spec, dfreg, dfrec)
    local scopes = spec.scopes
    local idt = spec.mention_types or MENTION_ID
    local wgate, is_write, guards = spec.write_gate, spec.is_write, spec.guards
    local wq, wqn = {}, 0 -- queued write mentions (stride 5, see below)
    local nm = buf.nm or 0 -- mention ordinal (continues across region calls)
    local FLDGATE = { dot_index_expression = true, bracket_index_expression = true,
        member_access_expression = true, subscript_expression = true,
        variable_name = true }
    local dfid = spec.df_ids
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
        local iscall = nt == 'call_expression' or nt == 'function_call'
            or nt == 'call' or nt == 'apply'
        local head = nt == 'list' -- sexp head IS the callee (no fields)
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
            -- LAZY per-child facts: named() is an FFI call and most java
            -- children are anonymous tokens — pay it only on paths that
            -- consume it (the regression the first fused draft measured)
            local cnamed, cdfon, name
            local cdefpos, cdfid
            if nctx > 0 then
                cnamed = c:named()
                if bodyctx and cnamed and ct ~= 'comment' then
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
                local callee = iscall
                    and (n:field('function')[1] == c or n:field('name')[1] == c)
                    or head -- the mention guard already proved c named
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

--- Replay the id-pass decisions over a collected buffer: pure lookups
--- against L (the same callback contract id_pass always took).
local function reduce_mentions(file, buf, L)
    local ranges = L.fn_ranges[file]
    if not ranges then return end
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
        if eligible and not callee and fnrefs then
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
                    -- can descend into
                    L.mark_cbarg(u)
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
            if var and not (var.file == file and sr == var.line) then
                local from = fn_at(sr)
                if from then
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
-- function reference marks the target dynamically dispatched (cbarg): a
-- dispatch-table entry is not dead code. Takes SUPPLIED lookups because
-- every decision is corpus-global: slice-local uniqueness is not global
-- uniqueness. This standalone form (read + parse + collect + reduce) is
-- the REFRESH path; the fused extract collects during phase 1 and only
-- reduces here-style at the end — no second parse.
-- L = { fn_unique = name -> {id,file,line,node?} (globally unique fns),
--       var_named = name -> { {id,file,line}, ... } (top-level vars),
--       fn_ranges = file -> { {s,e,id}, ... },
--       addref(from,to,at,inferred), adduse(edge), mark_cbarg(entry),
--       add_names(file, packed)? — per-file identifier NAME SET (the
--       mention index: \31-separated, sorted; ≥3 chars, stdlib excluded),
--       recorded while we're iterating every identifier anyway. This is
--       what lets a later splice answer "which files mention this
--       global?" without a corpus scan. Gated per language:
--       spec.name_index = false opts a language out (when bare-identifier
--       mention does not imply potential global use). }
local function id_pass(root, files, L, abs)
    abs = abs or function (f) return root .. '/' .. f end
    for _, file in ipairs(files) do
        if L.fn_ranges[file] then
            local lang, spec = lang_for(file)
            local clang = container_for(file)
            if clang then lang, spec = 'javascript', M.spec.javascript end
            local fd = io.open(abs(file), 'r')
            local src = fd and fd:read('a')
            if fd then fd:close() end
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
function M.lookups(nodes, root)
    local count = {}
    for _, n in ipairs(nodes) do
        if (n.kind == 'function' or n.kind == 'method') and not n.torn
            and not n.decl then -- a prototype declaration is not a call target
            count[n.name] = (count[n.name] or 0) + 1
        end
    end
    local fn_unique, var_named = {}, {}
    for _, n in ipairs(nodes) do
        if n.torn then -- beyond a parse error: never name-matched
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
    for f in pairs(fileset) do
        local _, sp = elang_for(f)
        if sp and sp.scope then
            scopes[f] = sp.scope(f, fileset, root)
            any = true
        end
    end
    return { fn_unique = fn_unique, var_named = var_named,
        scopes = any and scopes or nil }
end

--- Fold a standalone id-pass result into a graph: ref pairs dedup into
--- existing edges (like addref), cbarg marks apply. Shared by refresh
--- and the parallel driver.
function M.merge_idpass(data, out, touched)
    local refEdge = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' then refEdge[e.from .. '\31' .. e.to] = e end
    end
    local byid = {}
    for _, n in ipairs(data.nodes) do byid[n.id] = n end
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
    for _, id in ipairs(out.cbarg or {}) do
        if byid[id] then
            byid[id].cbarg = true
            if touched then touched[byid[id].file] = true end
        end
    end
    if out.names then
        data.names = data.names or {}
        for f, s in pairs(out.names) do data.names[f] = s end
    end
end

--- Standalone id pass over `files` with global lookups (parallel phase
--- 2, run inside a worker). Returns { edges = {...}, cbarg = {id, ...} }.
local function idpass_sink(lookups)
    local out = { edges = {}, cbarg = {}, names = {} }
    local refEdge, seen_cb = {}, {}
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
        mark_cbarg = function (u)
            if not seen_cb[u.id] then
                seen_cb[u.id] = true
                out.cbarg[#out.cbarg + 1] = u.id
            end
        end,
    }
    return L, out
end

function M.id_pass(root, files, lookups, abs)
    local L, out = idpass_sink(lookups)
    id_pass(root, files, L, abs)
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
    for _, p in ipairs(applicable) do
        for k in pairs(p.stdlib_names or {}) do sn[k] = true end
        if p.synth_defs then synths[#synths + 1] = p.synth_defs end
    end
    composed.stdlib_names = sn
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
    -- PDG (calls were never built). Whole-graph verbs (untangle/reorder/references/call-
    -- hierarchy) read it and refuse rather than serve a degraded/empty answer that reads
    -- as "none". A full :Cartograph open ingests fresh data without the marker → clears it.
    data.index_only = true
    return data
end

--- Extract a neutral-schema graph from a directory tree. Any file whose
--- extension has a spec (and an available parser) participates.
---@param root string
---@return table data  the schema-1 graph (ready for store.ingest)
function M.extract(root, opts)
    if M.PROFILE then prof = {}; prof._t0 = vim.uv.hrtime() end
    -- a URI root (self://loaded — the running instance's multi-root corpus)
    -- keeps off the filesystem's path rules: its files are plugin-labelled
    -- keys (telescope.nvim/lua/…) that resolve to real directories through
    -- opts.abs. A plain directory root joins as before.
    if not root:match('^%w+://') then
        root = vim.fn.fnamemodify(vim.fn.expand(root), ':p'):gsub('/+$', '')
    end
    local abs = (opts and opts.abs) or function (f) return root .. '/' .. f end
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
        files, minified = list_files(root, opts and opts.subdirs)
        padd('list_files', _plf)
    end
    local fileset = {}
    for _, f in ipairs(opts and opts.fileset or files) do fileset[f] = true end
    for _, f in ipairs(files) do fileset[f] = true end

    -- stamps: what each parsed file's truth is keyed to (mtime+size — a
    -- display-honesty gate for edits that arrive OUTSIDE nvim, not an
    -- eviction key, so no content hash needed). store.stale() compares.
    local data = { schema = 1, root = root, provider = 'treesitter',
        capabilities = { calls = true, litdata = true, df = 'lite' },
        nodes = {}, edges = {}, calls = {}, stamps = {} }
    local nodes, edges, calls = data.nodes, data.edges, data.calls
    local no_parser = {}

    -- overlay packs (rails): compose the pack's vocab + def-emitters onto the
    -- base spec per language. Stored on data.packs so relink/refresh re-apply
    -- the same. `eff_spec` wraps a base spec with the composition (memoized).
    local packnames = (opts and opts.packs) or {}
    local active_packs = {}
    for _, pn in ipairs(packnames) do
        if M.packs[pn] then active_packs[#active_packs + 1] = M.packs[pn] end
    end
    if #packnames > 0 then data.packs = packnames end
    -- L2 env profile the repo shape implies (factorio-mod → lua-factorio); nil
    -- for an unshaped root. Composed AFTER packs (base ⊕ L2 ⊕ L3), memoized/lang.
    local active_profile = active_profile_for(root)
    if active_profile then data.profile = active_profile.runtime end
    local composed_spec = {}
    local function eff_spec(lang, spec)
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

    -- per-name def indexes for the resolution pass
    local exact, tail = {}, {} -- name -> {fn node,...}; last segment -> {...}
    local varsByName = {}      -- name -> {var node,...}
    local constDefs = {}       -- file -> name -> string|false (const-fold index,
                               -- set-once scalar-string bindings; false=poisoned)
    local lastFn = {}          -- file -> last emitted fn node (equation merging)
    local fnRanges = {}        -- file -> { {s=line, e=line, id=id}, ... }
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
        local st = vim.uv.fs_stat(abs(file))
        if st then
            data.stamps[file] = ('%d:%d:%d')
                :format(st.mtime.sec, st.mtime.nsec, st.size)
        end
    end

    -- defs: functions, top-level vars, blocks, imports — one TREE at
    -- a time, so container files (vue/svelte SFCs) can run it once per
    -- script region while plain files run it on their single root
    local function extract_defs(file, lang, spec, src, tsroot, dfreg)
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
        -- `aname` (optional): an ANONYMOUS fn (a callback arrow/function passed
        -- as a call argument, no binding name) — extracted as its own fn node so
        -- its body has a home (its own df/flow, its inner calls attribute to IT
        -- via fn_at). Given a synthetic display name; NOT added to the name
        -- resolution index (exact/tail) — it is never a call target by name.
        local function handle_fn(defn, namen, aname)
            if defn and (namen or aname)
                and not (not aname and spec.toplevel_only
                    and in_function(defn, spec))
                and not (not aname and spec.toplevel_parent and defn:parent()
                    and defn:parent():type() ~= spec.toplevel_parent) then
                local name = aname
                if not name then
                    name = node_text(namen, src):gsub('%s+', '')
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
                local isfield = aname and true
                    or (spec.field_fn_cbarg
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
                local fl = not defs_only and spec.body_field and flowmod.build(defn, src, {
                    pfield = spec.params_field, df_ids = spec.df_ids,
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
                    arrow = defn:type() == 'arrow_function' or nil,
                    cbarg = isfield or nil,
                    -- unconditional module-load def (lua): a load-order sibling
                    -- for the reassignment-override resolver (resolve_reassign)
                    top = (lang == 'lua' and toplevel_def(defn)) or nil,
                    exported = exp,
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
        local function handle_anon_fn(defn)
            local nm = 'fn'
            local args = defn:parent()
            local call = args and args:parent()
            if call then
                local ct = call:type()
                if ct == 'call_expression' or ct == 'new_expression' then
                    local f = call:field('function')[1]
                        or call:field('constructor')[1]
                    local seg = f and node_text(f, src):match('([%w_$]+)%s*$')
                    if seg then nm = seg end
                end
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
                end
            end
        end
        -- header/interface elements (C/C++): prototypes, macros and types.
        -- A prototype is a DECLARATION (never indexed, marked decl); a
        -- function-like macro IS a call target and indexes. namen here is
        -- the CATEGORY capture node; cat its capture name.
        local function handle_iface(defn, namen, cat)
            if defn and namen then
                local name = node_text(namen, src):gsub('%s+', '')
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
        if spec.scan_ctors then
            data.ruby_ctor = data.ruby_ctor or {}
            local fb = data.ruby_ctor[file] or {}
            data.ruby_ctor[file] = fb
            for _, cb in ipairs(spec.scan_ctors(tsroot, src)) do
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
                        range = { start = run.s.start, ['end'] = run.e['end'] } }
                    run = nil
                end
            end
            for _, stmt in inext, container, -1 do
                if stmt:named() and stmt:type() ~= 'comment'
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
                for _, match in q:iter_matches(tsroot, src, 0, -1) do
                    for id, ns in pairs(match) do
                        if q.captures[id] == 'path' then
                            local target = spec.resolve_import(
                                node_text(cap_node(ns), src), fileset, file, root)
                            if target and target ~= file then
                                edges[#edges + 1] = { from = file, to = target, kind = 'import' }
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
                    local full = node_text(namen, src):gsub('%s+', '')
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
                        if a:named() and a:type() ~= 'comment' then
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
                            and spec.resolve_import(args[1], fileset, file, root)
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
                        local target = spec.resolve_import(args[1], fileset, file, root)
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
                local target = spec.resolve_import(imp.path, fileset, file, root)
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
        if fnRanges[file] then
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
                and t ~= 'comment' then
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
        local fd = io.open(abs(file), 'r')
        local src = fd and fd:read('a')
        if fd then fd:close() end
        if not src then goto next_file end
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
            local rawtree = raw_parse(lang, src) -- keep referenced: nodes
            -- below live only as long as their tree does
            local _pp = pstart()
            if rawtree then
                tsroot = rawtree:root()
            else
                local okp, parser = pcall(vim.treesitter.get_string_parser, src, lang)
                if not okp then
                    no_parser[lang] = true
                    goto next_file
                end
                tsroot = parser:parse()[1]:root()
            end
            padd('parse', _pp)
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
            local _pd = pstart()
            extract_defs(file, lang, spec, src, tsroot, dfreg)
            padd('extract_defs', _pd) -- incl. flow.build (timed separately)
            -- calls + mentions/refs are deferred entirely in the index-only / dataflow-only
            -- front-ends (they, and the resolution they feed, are the bulk that defers on-demand)
            if not (defs_only or dataflow_only) then
            local _pc = pstart()
            extract_calls(file, lang, spec, src, tsroot)
            padd('extract_calls', _pc)
            -- fusion Stage B: mentions ride the SAME tree — the id pass
            -- never parses again (files without functions stay out, the
            -- same gate the id pass always had). df rides the same walk
            -- via dfreg (registered by extract_defs above).
            if fnRanges[file] then
                local buf = mention_buf(spec)
                local _pm = pstart()
                collect_mentions(buf, tsroot, src, spec, dfreg, opts and opts.legacy_df)
                padd('collect_mentions', _pm)
                buf.m = table.concat(buf.parts)
                buf.parts, buf.nidx = nil, nil
                mentions[file] = buf
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
    local function addref(from, to, at, inferred, tinf)
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
    local function aperture_refusal(name, file)
        local pfx = name:match('^([^/#]+)[/#]')
        if not (pfx and ns_pfx[pfx]) then return nil end
        local w = apertures[file]
            and { file = file, line = apertures[file][1].line }
            or global_witness
        if not w then return nil end -- nothing conjures: stay silent
        return { rule = 'aperture', witness = w.file .. ':' .. (w.line + 1) }
    end
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
            local fitset = {}
            for _, n in ipairs(tc) do
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
                if fits then fitset[#fitset + 1] = n end
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
            local fd = io.open(abs(p.file), 'r')
            src_cache[p.file] = fd and vim.split(fd:read('a'), '\n', { plain = true }) or false
            if fd then fd:close() end
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
            local fd = io.open(abs(file), 'r')
            src_cache[file] = fd
                and vim.split(fd:read('a'), '\n', { plain = true }) or false
            if fd then fd:close() end
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
        local target, inferred, refused, ext
        if p.call.dynamic then
            -- $fn(...): frontier — unless single-assignment literal flow
            -- pins the name down within the function
            local lit
            target, lit = literal_flow(p)
            -- traced carries the LITERAL whenever one was found (truthy as
            -- before) so relink can re-resolve it — a parallel slice may
            -- know the literal but not see its target
            if lit then p.call.traced = lit end
            if target then
                p.call.dynamic = nil -- pinned down: no longer a frontier
            end
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
    local resolve_ctx = { calls = calls, data = data, exact = exact,
        tail = tail, addref = addref, node_index = node_index,
        scope_of = scope_of, consts = constDefs, parent_fn = parent_fn }
    run_resolve_passes(resolve_ctx)
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
            mark_cbarg = function (u) u.node.cbarg = true end,
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
        -- off M.relink): id/kind/file/name + ret/retclass/arrow/exported/cbarg; NOT flow/df
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
            exported = n.exported, cbarg = n.cbarg,
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
    local active_profile = active_profile_for(data.root)
    -- record the active profile on the parallel-parent result too (extract stamps
    -- it inline; relink is the parallel path — keep the provenance field consistent)
    if active_profile then data.profile = active_profile.runtime end
    local composed_spec = {}
    local function eff_spec(lang, spec)
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
    local function aperture_refusal(name, file)
        local pfx = name:match('^([^/#]+)[/#]')
        if not (pfx and ns_pfx[pfx]) then return nil end
        local w = apertures[file]
            and { file = file, line = apertures[file][1].line }
            or global_witness
        if not w then return nil end
        return { rule = 'aperture', witness = w.file .. ':' .. (w.line + 1) }
    end
    local refEdge, regEdge = {}, {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' then refEdge[e.from .. '\31' .. e.to] = e
        elseif e.kind == 'reg' then regEdge[e.from .. '\31' .. e.to] = e end
    end
    local function addref(from, to, at, inferred, tinf)
        local k = from .. '\31' .. to
        local e = refEdge[k]
        if not e then
            e = { from = from, to = to, kind = 'ref', at = {},
                self = (from == to) or nil, inferred = inferred or nil }
            refEdge[k] = e
            data.edges[#data.edges + 1] = e
        end
        if not inferred then e.inferred = nil end
        if tinf then e.tinf = true end -- type-inferred tier (upgrade-only)
        e.at[#e.at + 1] = at
    end
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
            local fitset = {}
            for _, n in ipairs(tc) do
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
                if fits then fitset[#fitset + 1] = n end
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
        scope_of = scope_of, consts = nil, parent_fn = parent_fn })
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
    return n
end

return M
