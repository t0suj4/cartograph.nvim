-- narrow.lua — branch-sensitive NARROWING (INC 1: Lua nil/truthiness), the TYPE
-- sibling of const-fold ([[cartograph-type-narrowing]]). A per-language GUARD
-- VOCABULARY classifies a guard condition into narrowing FACTS `{var, kind, when}`
-- (`when` = the cond truth value under which the fact holds). cfg.guards_over gives
-- which guards structurally dominate a point (+ `neg` = ¬cond holds there), so a
-- fact is ACTIVE at a point when `fact.when == (not guard.neg)`. Read-only
-- knowledge, SOUND only where the predicate proves it (conjunctions narrow; `or`
-- and negated compounds don't). The vocab is EXTENSIBLE per language — INC 1 fills
-- Lua nil/truthiness; typeof/instanceof/discriminant (JS/Java) slot in later
-- (instanceof matters for other codebases — the table is ready for it).

-- @langs lua ruby

local cfg = require 'cartograph.cfg'
local at = require 'cartograph.at'
local flowmod = require 'cartograph.flow'
local builtins = require 'cartograph.builtins'
local tsutil = require 'cartograph.spec.tsutil'

local M = {}

-- vars REASSIGNED (an assignment, not a fresh `local`) anywhere in the fn.
-- guards_over is purely structural — it can't see that `if x then … x = f() … use(x)`
-- reassigns x between the guard and the use, staling the narrowing. Conservatively
-- kill narrowing for any reassigned var (sound: never under-kills). Reuses flow's def.
--
-- ★ THE STATEMENT TYPE IS PER-GRAMMAR, and this was one literal: 'assignment_
-- statement', which is LUA's name. Ruby's is `assignment` (plus `operator_assignment`
-- for `x ||= v`), so the moment ruby entered EXT_LANG this returned EMPTY for every
-- ruby function — 6168 assignments' worth of staling silently absent on discourse
-- alone, i.e. precisely the unsoundness the paragraph above exists to prevent, in the
-- helper written to prevent it. A hardcoded node-type name inside a shared helper is
-- a language assumption in disguise (the third in this arc, after cfg's
-- `== 'if_statement'` guard-clause test and the `block` type-name collision).
local ASSIGN = {
    assignment_statement = true,                    -- lua
    assignment = true, operator_assignment = true,  -- ruby
    -- for whoever adds them next; harmless until the language is in EXT_LANG
    assignment_expression = true, augmented_assignment_expression = true,
}
local function mutated_of(store_node)
    local m = {}
    local fl = store_node and flowmod.present(store_node) and flowmod.record(store_node)
    if fl and fl.stmts then
        for _, s in ipairs(fl.stmts) do
            if ASSIGN[s.t] then
                for _, v in ipairs(s.def or {}) do m[v] = true end
            end
        end
    end
    return m
end

local function txt(n, src) return n and vim.treesitter.get_node_text(n, src) or '' end

-- the fn's BOUND names (params + every local/assignment target). A `type` in here
-- SHADOWS the global builtin, so `type(x)` is not the real type() and its type-test
-- narrowing would be unsound — the gate below drops those facts via builtins.genuine.
-- Conservative: a shadow anywhere (even a sibling scope) disables type narrowing for the fn.
local function bound_set(store_node)
    local b = {}
    local fl = store_node and flowmod.present(store_node) and flowmod.record(store_node)
    if fl then
        for _, p in ipairs(fl.params or {}) do b[p] = true end
        for _, s in ipairs(fl.stmts or {}) do for _, d in ipairs(s.def or {}) do b[d] = true end end
    end
    return b
end

-- wrap the raw classifier so TYPE-test facts are dropped when `type` is shadowed in the
-- fn (they bubble up to the flat result list, so filtering the top level catches all
-- nesting depths). nil/truthy facts are untouched. Returns the raw classifier unchanged
-- when type is the genuine global.
local function gated_classify(raw, type_shadowed)
    if not type_shadowed then return raw end
    return function (cond, src, holds)
        local out = {}
        for _, f in ipairs(raw(cond, src, holds)) do
            if not f.kind:match('^type:') then out[#out + 1] = f end
        end
        return out
    end
end

-- is the type-test channel untrustworthy in this fn? LUA-SPECIFIC: lua's test is a
-- call to the GLOBAL `type`, which a local of the same name shadows. Ruby's is the
-- METHOD `is_a?` on the receiver itself — there is no global to shadow, so the gate
-- does not apply and hardcoding 'lua' here would have silently disabled ruby's
-- type: facts (or, worse if the argument order ever flipped, trusted a shadowed one).
local function type_is_shadowed(lang, node)
    if lang ~= 'lua' then return false end
    return not builtins.genuine('lua', 'type', bound_set(node))
end

-- ── per-language guard vocabulary ────────────────────────────────────────────
-- vocab[lang](cond, src, holds) -> { {var, kind}, ... } = the facts that MUST hold
-- given the condition evaluates to `holds` (true for positive nesting, false for a
-- passed early-exit). Polarity is pushed THROUGH the connectives (De Morgan) rather
-- than flipped per-fact, so a conjunction under negation (`if not a and b then
-- return` → after, ¬(a∧b) proves NOTHING) is sound. kind: 'truthy' (from `if x` —
-- non-nil AND non-false) or 'non-nil' (from x~=nil); truthy ⟹ non-nil.
local vocab = {}

-- canonical dot-path of a narrowable location: an identifier (`x`) or a dot-index
-- chain rooted at one (`opts.subdirs`, `self.cache.x`). Returns {path, root, depth}
-- (depth 0 = a bare var, ≥1 = a field path), else nil. Bracket-index and any
-- non-identifier root are NOT paths (unpredictable key / not staling-trackable).
local function path_of(n, src)
    if not n then return nil end
    if n:type() == 'identifier' then return { path = txt(n, src), root = txt(n, src), depth = 0 } end
    -- @langs-ok lua-only helper: ruby has NO field paths by design (x.y is a method
    -- dispatch), so rb_path deliberately has no dot-chain arm to mirror this one
    if n:type() == 'dot_index_expression' then
        local base = path_of(n:named_child(0), src)
        local fld = n:field('field')[1]
        if base and fld then
            return { path = base.path .. '.' .. txt(fld, src), root = base.root, depth = base.depth + 1 }
        end
    end
    return nil
end
-- `type(P)` over a single path (identifier or field path) → its path info, else nil
local function type_call_path(n, src)
    -- @langs-ok lua-only helper: the ruby type test is the METHOD is_a?, read by
    -- rb_classify's call arm, not a global call like lua's type()
    if not n or n:type() ~= 'function_call' then return nil end
    local callee = n:named_child(0)
    if not (callee and callee:type() == 'identifier' and txt(callee, src) == 'type') then return nil end
    local args = n:field('arguments')[1]
    local arg = args and args:named_child(0)
    if arg and not args:named_child(1) then return path_of(arg, src) end
    return nil
end
-- the content of a string literal (quotes stripped), else nil
local function str_lit(n, src)
    if not n or n:type() ~= 'string' then return nil end
    return (txt(n, src):match('^["\'](.-)["\']$'))
end
-- a DISCRIMINANT literal (string or number) → an `eq:` kind tag; the s:/n: prefix
-- keeps the string "1" distinct from the number 1 (never confuse them at compare).
local function disc_kind(n, src)
    if not n then return nil end
    local s = str_lit(n, src)
    if s then return 'eq:s:' .. s end
    -- @langs-ok lua-only helper: ruby's numeric literal is `integer`, handled by
    -- rb_lit_kind, which is this function's ruby twin
    if n:type() == 'number' then return 'eq:n:' .. txt(n, src) end
    return nil
end
-- a fact over a narrowed path: carries root + depth so staling (field_unstable) can
-- gate depth-≥1 paths while leaving depth-0 vars on the call-immune floor.
local function fact(p, kind) return { var = p.path, kind = kind, root = p.root, depth = p.depth } end

local function lua_classify(cond, src, holds)
    if not cond then return {} end
    local t = cond:type()
    if t == 'parenthesized_expression' then
        return lua_classify(cond:named_child(0), src, holds)
    elseif t == 'unary_expression' then
        if txt(cond:child(0), src) == 'not' then -- ¬X holds ⟺ X holds with flipped value
            return lua_classify(cond:named_child(0), src, not holds)
        end
        return {}
    elseif t == 'binary_expression' then
        local l, r = cond:named_child(0), cond:named_child(1)
        local op = txt(cond:child(1), src)
        if op == 'and' then
            if not holds then return {} end -- ¬(a∧b) = ¬a∨¬b → nothing certain
            local out = lua_classify(l, src, true)
            for _, f in ipairs(lua_classify(r, src, true)) do out[#out + 1] = f end
            return out
        elseif op == 'or' then
            if holds then return {} end -- (a∨b) → nothing; ¬(a∨b) = ¬a∧¬b → both hold
            local out = lua_classify(l, src, false)
            for _, f in ipairs(lua_classify(r, src, false)) do out[#out + 1] = f end
            return out
        elseif op == '==' or op == '~=' then
            -- P == nil / P ~= nil (either order), P a var OR a field path (narrow v2)
            local p
            if txt(r, src) == 'nil' then p = path_of(l, src)
            elseif txt(l, src) == 'nil' then p = path_of(r, src) end
            if p and ((op == '~=') == holds) then return { fact(p, 'non-nil') } end
            if p then return {} end -- P == nil under holds proves P nil — no positive fact
            -- TYPE-TEST (devirt seed): type(P) == 'T' / ~= 'T'. Sound — a call can't change a
            -- local's type, and a field path's type is gated by field_unstable. Positive only.
            local tp = type_call_path(l, src) and str_lit(r, src) and { type_call_path(l, src), str_lit(r, src) }
                or (type_call_path(r, src) and str_lit(l, src) and { type_call_path(r, src), str_lit(l, src) })
            if tp and ((op == '==') == holds) then return { fact(tp[1], 'type:' .. tp[2]) } end
            -- DISCRIMINANT (narrow v2): P == 'lit' / P ~= 'lit', a string/number literal.
            -- P holds value `lit` when (== & holds) or (~= & ¬holds); implies non-nil + truthy.
            local dp = path_of(l, src) and disc_kind(r, src) and { path_of(l, src), disc_kind(r, src) }
                or (path_of(r, src) and disc_kind(l, src) and { path_of(r, src), disc_kind(l, src) })
            if dp and ((op == '==') == holds) then return { fact(dp[1], dp[2]) } end
            return {}
        end
        return {}
    else -- `if P` — P a var (`if x`) or a field path (`if opts.subdirs`)
        local p = path_of(cond, src)
        if p and holds then return { fact(p, 'truthy') } end
        return {}
    end
end
vocab.lua = lua_classify

-- ── RUBY (CART-0300) ─────────────────────────────────────────────────────────
-- MEASURED FIRST over 6494 distinct (condition, polarity) guards on discourse/app +
-- rails/activesupport, because the precondition is "conditions the vocab can
-- CLASSIFY", not "statements under a guard". What the census said, and it is not what
-- a port of the lua vocab would have assumed:
--
--   receiver non-nil (any `.`-call)  1465 facts  47-55% of the total — the LARGEST rung
--   truthy (bare var / @ivar)         677
--   present? / blank?                 583        24% of discourse's, FOUR in activesupport
--   type: from is_a?/kind_of?          70
--   non-nil from nil? / == nil        100        just 1.8-3.5% of forms
--
-- ★ SO A NIL-CENTRED PORT OF THE LUA VOCAB WOULD HAVE MEASURED AS NEARLY DEAD. Lua's
-- vocab is built around `x ~= nil`; ruby's guard culture is presence predicates and
-- method dispatch, and `x.nil?` is the rarest form of the lot. Size by the IDIOM, not
-- by the mechanism you already have.
--
-- TWO STRUCTURAL DIVERGENCES FROM LUA, both soundness-driven:
--
-- (1) NO FIELD PATHS. In lua `x.y` is a dot_index_expression — a table read, stable
--     until something writes it, which is why lua narrows depth-≥1 paths under a
--     staling gate. In ruby `x.y` is a `call`: a METHOD DISPATCH that may return a
--     different value on each evaluation, with no syntactic way to tell an attr_reader
--     from a computation. So ruby paths are depth 0 ONLY (identifier / @ivar) and
--     `x.y` chains are refused. 1236 of discourse's guards (24%) fall here — the
--     largest refused bucket, and refusing it is the whole point.
--
-- (2) ★ A NEW INFERENCE CHANNEL, POLARITY-INDEPENDENT: evaluating `x.m` AT ALL proves
--     x non-nil, because `nil.m` raises NoMethodError. If execution reached past the
--     condition, the receiver was not nil — on BOTH branches, which no other fact here
--     is. Excluded: the methods NilClass really does answer (`to_s`, `nil?`, `class`,
--     `present?`/`blank?` under ActiveSupport, …) and safe navigation `x&.m`, which
--     exists precisely to permit nil. This is the biggest rung and it is not a
--     vocabulary entry at all; the same channel applies to python (AttributeError on
--     None), which is a follow-on.
local RB_ROOT = { identifier = true, instance_variable = true }
-- methods NilClass answers, so dispatching them proves nothing about the receiver
local RB_NIL_OK = {
    ['to_s'] = true, ['to_a'] = true, ['to_h'] = true, ['to_i'] = true, ['to_f'] = true,
    ['to_r'] = true, ['to_c'] = true, ['inspect'] = true, ['nil?'] = true,
    ['class'] = true, ['hash'] = true, ['dup'] = true, ['clone'] = true,
    ['freeze'] = true, ['frozen?'] = true, ['tap'] = true, ['then'] = true,
    ['itself'] = true, ['send'] = true, ['public_send'] = true, ['methods'] = true,
    ['object_id'] = true, ['instance_variables'] = true, ['instance_of?'] = true,
    ['is_a?'] = true, ['kind_of?'] = true, ['respond_to?'] = true, ['equal?'] = true,
    ['eql?'] = true, ['=='] = true, ['!='] = true, ['display'] = true,
    -- ActiveSupport extends NilClass with these
    ['present?'] = true, ['blank?'] = true, ['presence'] = true, ['try'] = true,
    ['in?'] = true, ['as_json'] = true, ['duplicable?'] = true,
}
local RB_TYPEP = { ['is_a?'] = true, ['kind_of?'] = true, ['instance_of?'] = true }
-- a depth-0 ruby path (`x` or `@x`), else nil. Deliberately NOT recursive: see (1).
local function rb_path(n, src)
    if n and RB_ROOT[n:type()] then
        local s = txt(n, src)
        return { path = s, root = s, depth = 0 }
    end
    return nil
end
-- the constant name in `x.is_a?(K)` / `x.is_a? K`, else nil
local function rb_const(args, src)
    local a = args and args:named_child(0)
    if not a or args:named_child(1) then return nil end
    -- @langs-ok ruby-only helper: a class NAME in is_a?(K). Lua has no constant node
    -- and its type test compares a string, handled by str_lit
    if a:type() == 'constant' or a:type() == 'scope_resolution' then return txt(a, src) end
    return nil
end
local function rb_lit_kind(n, src)
    if not n then return nil end
    local t = n:type()
    if t == 'string' then
        local s = txt(n, src):match('^["\'](.-)["\']$')
        return s and ('eq:s:' .. s) or nil
    end
    if t == 'integer' then return 'eq:n:' .. txt(n, src) end
    -- a SYMBOL gets its OWN discriminator, for exactly the reason the s:/n: prefixes
    -- exist: `:draft` and `"draft"` are not equal in ruby, so tagging both `eq:s:`
    -- would let a discriminant proved by one satisfy a test against the other. The
    -- `sym:` tag also deliberately fails env_type's `^eq:s:` string test — a Symbol
    -- is not a String — and the leading colon is stripped so the tag carries the VALUE.
    if t == 'simple_symbol' then return 'eq:sym:' .. (txt(n, src):gsub('^:', '')) end
    return nil
end

-- Channel (2) applied to a CHAIN's innermost receiver: `z.owner.active?` proves z
-- non-nil, because z answered `.owner`. The method judged is the one dispatched ON THE
-- ROOT, not the outermost — `z.to_s.empty?` proves nothing, since nil answers `to_s`.
-- Any `&.` between the root and its hop refuses the whole claim; the operator further
-- out does not matter (`z.owner&.active?` still had z answer `.owner`). A non-call
-- link in the chain (`params[:a].valid?`) ends the descent without a claim.
local function rb_root_nonnil(node, src)
    local n = node
    -- @langs-ok ruby-only helper (rb_*): `call` is ruby's dot-dispatch node, and this
    -- whole chain-descent exists because ruby has no field-access node at all
    while n and n:type() == 'call' do
        local r = n:field('receiver')[1]
        if not r then return {} end
        if txt(n:field('operator')[1], src) ~= '.' then return {} end
        local p = rb_path(r, src)
        if p then
            if RB_NIL_OK[txt(n:field('method')[1], src)] then return {} end
            return { fact(p, 'non-nil') }
        end
        n = r
    end
    return {}
end

local function rb_classify(cond, src, holds, depth)
    depth = depth or 0
    if not cond or depth > 8 then return {} end
    local t = cond:type()
    if t == 'parenthesized_statements' or t == 'begin_block' then
        return rb_classify(cond:named_child(0), src, holds, depth + 1)
    end
    if RB_ROOT[t] then -- `if x` / `if @x`: only nil and false are falsy in ruby
        local p = rb_path(cond, src)
        if p and holds then return { fact(p, 'truthy') } end
        return {}
    end
    if t == 'unary' then
        local op = txt(cond:field('operator')[1], src)
        if op == '!' or op == 'not' then
            local operand = cond:named_child(0)
            return rb_classify(operand, src, not holds, depth + 1)
        end
        return {}
    end
    if t == 'binary' then
        local op = txt(cond:field('operator')[1], src)
        local l, r = cond:field('left')[1], cond:field('right')[1]
        if op == '&&' or op == 'and' then
            if not holds then return {} end -- ¬(a∧b) proves nothing about either
            local out = rb_classify(l, src, true, depth + 1)
            for _, f in ipairs(rb_classify(r, src, true, depth + 1)) do out[#out + 1] = f end
            return out
        elseif op == '||' or op == 'or' then
            if holds then return {} end     -- (a∨b) proves nothing; ¬(a∨b) proves both
            local out = rb_classify(l, src, false, depth + 1)
            for _, f in ipairs(rb_classify(r, src, false, depth + 1)) do out[#out + 1] = f end
            return out
        elseif op == '==' or op == '!=' then
            local lp, rp = rb_path(l, src), rb_path(r, src)
            local lnil, rnil = txt(l, src) == 'nil', txt(r, src) == 'nil'
            local p = (lp and rnil and lp) or (rp and lnil and rp) or nil
            if p then
                if (op == '!=') == holds then return { fact(p, 'non-nil') } end
                return {} -- `x == nil` holding proves x IS nil: no positive fact
            end
            local dp = (lp and rb_lit_kind(r, src) and { lp, rb_lit_kind(r, src) })
                or (rp and rb_lit_kind(l, src) and { rp, rb_lit_kind(l, src) }) or nil
            if dp and ((op == '==') == holds) then return { fact(dp[1], dp[2]) } end
            return {}
        end
        -- any other operator (`>`, `<=>`, `=~`, `+`) DISPATCHES on the left operand,
        -- so reaching here proves it non-nil whichever way the test went
        local lp = rb_path(l, src)
        if lp then return { fact(lp, 'non-nil') } end
        return {}
    end
    if t == 'call' then
        local recv = cond:field('receiver')[1]
        if not recv then return {} end -- a bare `valid?` says nothing about a variable
        local p = rb_path(recv, src)
        -- a DEEP receiver (`z.owner.active?`): the PATH is refused per divergence (1),
        -- but the chain's ROOT still answered its own hop, so channel (2) applies to it
        if not p then return rb_root_nonnil(recv, src) end
        local m = txt(cond:field('method')[1], src)
        local op = txt(cond:field('operator')[1], src)
        if op == '&.' then return {} end -- safe navigation permits nil by construction
        if m == 'nil?' then
            if not holds then return { fact(p, 'non-nil') } end
            return {}
        end
        -- present?/blank? are ActiveSupport, and SOUND to read in either world: if the
        -- call evaluated at all then either AS is loaded (nil.present? is false, false
        -- .present? is false ⇒ present? true means truthy) or it is not (a receiver
        -- answering present? at all is a non-nil object, hence truthy).
        if m == 'present?' and holds then return { fact(p, 'truthy') } end
        if m == 'blank?' and not holds then return { fact(p, 'truthy') } end
        if RB_TYPEP[m] and holds then
            local k = rb_const(cond:field('arguments')[1], src)
            if k then return { fact(p, 'type:' .. k) } end
            return {}
        end
        if not RB_NIL_OK[m] then return { fact(p, 'non-nil') } end -- the (2) channel
        return {}
    end
    if t == 'element_reference' then -- `params[:id]` dispatches `[]` on the receiver
        local p = rb_path(cond:named_child(0), src)
        if p then return { fact(p, 'non-nil') } end
        return {}
    end
    return {}
end
vocab.ruby = function (cond, src, holds) return rb_classify(cond, src, holds, 0) end

local EXT_LANG = { lua = 'lua', rb = 'ruby' } -- INC 1 lua; ruby = CART-0300

-- ★ WHICH VERB SUPPORTS WHICH LANGUAGE, and it is NOT the same answer for all four.
-- `narrow` (the lens) is fully language-driven — the vocab classifies the condition
-- and STMT_BLOCK finds the statements — so it serves ruby. The other three still find
-- their SUBJECTS with lua-specific node types: `redundant` looks for an
-- `if_statement`, `devirt` for a `function_call` with a `method_index_expression`
-- callee, `param_nilability` for DEREF_INDEX shapes and a lua CONDN set. Landing
-- vocab.ruby was by itself enough to let all four past the old `vocab[lang]` check,
-- after which those three would have walked a ruby tree, matched nothing, and returned
-- an EMPTY list — indistinguishable from "this function has nothing to report".
-- Refusing by name keeps the absence legible.
local VERB_LANG = {
    narrow = { lua = true, ruby = true },
    param_nilability = { lua = true },
    redundant = { lua = true },
    devirt = { lua = true },
}

-- ── the fn's AST (re-parse; guards_over is inherently AST-based, like taint) ──
-- The scope-boundary set, DERIVED from the specs of exactly the languages
-- VERB_LANG admits, rather than written out here (CART-0306). A union is the
-- right shape only when it is over a KNOWN language list that maintains itself:
-- add ruby to a verb above and this follows, where the hand-written version
-- would have quietly gone on describing lua.
local FN_TYPES = {}
for _, langs in pairs(VERB_LANG) do
    for lang in pairs(langs) do
        for t in pairs(require('cartograph.providers.treesitter').fn_types(lang)) do
            FN_TYPES[t] = true
        end
    end
end
-- statement CONTAINERS — where the walk below looks for the statements to annotate.
-- Was the single literal 'block', i.e. LUA's name: on ruby the walk would have found
-- no statements at all and returned an EMPTY point list, which reads as "nothing to
-- narrow here" rather than as "this language is not wired up". Absence rendered as
-- silence, in the shape that is hardest to notice ([[cartograph-concern-layering]]).
local STMT_BLOCK = {
    block = true,                                            -- lua
    body_statement = true, ['then'] = true, ['do'] = true,   -- ruby
    block_body = true, ['else'] = true,
}
-- (exported: a rewrite learned from an example pairs a body with a body of ANOTHER kind — ruby's if `then` and a
-- block's `body_statement` — only when both are here, CART-1666)
M.STMT_BLOCK = STMT_BLOCK
local function fn_node(node, src, lang)
    local ok, parser = pcall(vim.treesitter.get_string_parser, require('cartograph.parseview').view(src, lang), lang)
    if not ok then return nil end
    local root = parser:parse()[1]:root()
    local sl, sc, el, ec = at.sl(node.range), at.sc(node.range),
        at.el(node.range), at.ec(node.range)
    local d = root:named_descendant_for_range(sl, sc, el, ec)
    while d do
        if FN_TYPES[d:type()] then return d end
        d = d:parent()
    end
    return nil
end

-- ── field-path STALING (the aliasing floor for depth-≥1 facts) ──────────────
-- A field path `r.f` narrowed by a guard can be invalidated in ways a bare local
-- cannot. We collect STALING PREFIXES (whole-fn, conservative like mutated_of):
--   • field-write `A.f = …` / `A[i] = …` → the exact path (and everything under it)
--     may change → prefix A.f INCLUSIVE (a bracket-write's key is unknown → the base
--     A becomes exclusive-unstable: any field of A may change).
--   • a call receiving container `A` (`foo(A)` / `A:m()`) or an ALIAS (`y = A`) → the
--     callee/alias may write A's FIELDS but cannot rebind A itself → prefix A EXCLUSIVE
--     (kills `A.x`, leaves `A`). Passing `A.f` (a field VALUE) only exposes `A.f.*`.
-- A depth-≥1 fact on path P is dropped if some prefix entry covers P (see fact_live);
-- bare-var facts are immune (a call can't nil a caller's local) and use mutated_of.
-- Root reassignment is covered separately by mutated_of.
-- ★ A CALL THAT CANNOT WRITE ITS ARGUMENT DOES NOT STALE IT (CART-1677). Staling a field path on EVERY call that receives
-- its root — `foo(A)`, `A:m()` — killed 11276 of lua/cartograph's 29431 field-path guard facts on calls alone. A
-- call is HARMLESS to argument i when its resolved callee's effect summary carries no hedge, does not mutate that
-- parameter (pwx) and writes no module state at all (a module write could reach A through an alias stored there
-- before this function ran); or, unresolved, when the builtin signature registry knows it and its `w` does not list
-- that position (`type`, `ipairs`, `string.format` — `table.sort` writes its first). Measured: 4823 of the 11276
-- facts survive. CARTOGRAPH_NARROW_EFFECTS=0: every call stales, as before. -> harmless(call_node, argi) | nil
local function call_harmless(store, node)
    if os.getenv('CARTOGRAPH_NARROW_EFFECTS') == '0' or not (store and node and store.topo) then return nil end
    local E = require 'cartograph.effects'
    local callrec = require 'cartograph.callrec'
    local atr = require 'cartograph.at'
    local sums = E.summaries(store)
    local sites = store.topo():sites(node.id)
    local memo = {}
    return function (cn, argi)
        local r, c0 = cn:start()
        local key = r .. ':' .. c0 .. ':' .. argi
        if memo[key] ~= nil then return memo[key] end
        local c, bd
        for _, x in ipairs(sites) do
            if callrec.line(x) == r then -- (0-based, as the node's row)
                local d = math.abs((x.at and atr.sc(x.at) or 0) - c0)
                if not bd or d < bd then c, bd = x, d end
            end
        end
        local ok = false
        if c then
            local pos = argi == 0 and 1 or (argi + (callrec.method(c) and 1 or 0))
            local to = callrec.to(c)
            local s = to and sums[to]
            if s then
                ok = not s.h and not (s.pwx and s.pwx[pos]) and next(s.w or {}) == nil
            elseif not to then
                local sig = E.sig_of('lua', callrec.full(c) or callrec.callee(c), callrec.method(c))
                if sig then
                    ok = true
                    for _, wi in ipairs(sig.w or {}) do if wi == pos then ok = false end end
                end
            end
        end
        memo[key] = ok
        return ok
    end
end

-- ★★ THE INTERIM STALING RULE (CART-1684; designed and costed by the flowpath research, ~/work/flowpath
-- RESEARCH.md §0 / §15.4, as its variant I4). Staling by NAME — a write naming a prefix of A.x, a call RECEIVING A —
-- kept false facts whenever a write reached the guarded table through another name: a zero-argument mutator of an
-- upvalue, a param alias, another argument's field (its metamorphic harness, execution as the oracle: 57 violations in
-- 87 cases). Under this rule EVERY call is a suspect unless provably harmless (a plain-`pure` summary that reaches no
-- write through a name that is neither its param nor a fresh local, or a builtin whose contract writes, calls and does
-- nothing), every field write stales the facts naming that field, and a depth-0 fact on a name the function does not
-- bind is exposed like a field path. Refinements, each sound: the USE bound (an entry entirely after the use point,
-- outside every loop around it, cannot run between guard and use), array-only builtins (table.insert / remove / a
-- comparator-less sort write integer slots), provably NUMERIC keys, and writes into a table built fresh after the guard.
-- Harness: 57 -> 8 violations, all __index / __newindex (counting every off-chain index as a call — `meta`, I4M — closes
-- them at a cost the research left as a decision). The sound end state is R4 (MOD on the points-to graph).
-- CARTOGRAPH_NARROW_INTERIM=0 restores name-based staling (an A/B switch only).
local NI_ON = os.getenv('CARTOGRAPH_NARROW_INTERIM') ~= '0'
local NI = { on = NI_ON, ub = NI_ON, meta = os.getenv('CARTOGRAPH_NARROW_META') == '1', arr = NI_ON, numkey = NI_ON,
    fresh = NI_ON }
M._NI = NI
local LUASTD = { table = true, string = true, math = true, os = true, io = true, coroutine = true, debug = true,
    bit = true, utf8 = true }
local ARRAY_ONLY = { ['table.insert'] = true, ['table.remove'] = true, ['table.sort'] = 1 }
-- EVERY call is a suspect: harmless only when it can write NO table — resolved with a summary effects.purity reads
-- plain 'pure' (no module write, no pwx anywhere, no world effect, no hedge, no handed-in callee), or unresolved into a
-- builtin whose contract is pure with no `w`, no `calls`, no `io` and not the name-matched `~` method tier. The call
-- record must sit at the node's EXACT column (a nearest-column match could borrow a neighbour's verdict).
-- -> fn(call node) -> ok, category
-- ★ effects.purity reads 'pure' for a closure that writes a field of an UPVALUE that is not a module var — `do local
-- s = state; later = function () s.cur = nil end end`, a factory's `return function () t.cur = nil end` (measured:
-- both 'pure', narrowcost FINDINGS). So 'pure' alone is not harmless: the callee and everything it reaches must also
-- write no field through a name that is neither its own parameter (pwx covers those) nor a local it built fresh.
local UVW = setmetatable({}, { __mode = 'k' })
local function direct_uvw(store, fid)
    local n = store.node(fid)
    if not (n and n.file and n.file:match('%.lua$')) then return true end
    -- (store.content is the WHOLE file; one parse per file, the callee found by its range as fn_node does)
    local fc = UVW[store] and UVW[store].__files or {}
    if UVW[store] then UVW[store].__files = fc end
    local ent = fc[n.file]
    if not ent then
        local src = table.concat(store.content(n) or {}, '\n')
        local ok, parser = pcall(vim.treesitter.get_string_parser, require('cartograph.parseview').view(src, 'lua'), 'lua')
        ent = { src = src, root = ok and parser:parse()[1]:root() or nil }
        fc[n.file] = ent
    end
    if not ent.root then return true end
    local src = ent.src
    local d = ent.root:named_descendant_for_range(at.sl(n.range), at.sc(n.range), at.el(n.range), at.ec(n.range))
    while d and not FN_TYPES[d:type()] do d = d:parent() end
    local f = d
    if not f then return true end
    local params, fresh = {}, {}
    -- (a root effects already TRACKS — a module var its summary lists — is no blind spot: its write is in s.w)
    local tracked = {}
    local sm = require('cartograph.effects').summaries(store)[fid]
    for key in pairs(sm and sm.w or {}) do local v = key:match('var:([^@]+)@'); if v then tracked[v] = true end end
    local ps = f:field('parameters')[1]
    if ps then for _, c in tsutil.inamed, ps, -1 do if c:type() == 'identifier' then params[txt(c, src)] = true end end end
    local hit = false
    local function rootname(x)
        -- @langs-ok lua-only: the CART-1684 interim rule (interim_for runs it on lua functions only)
        while x and (x:type() == 'dot_index_expression' or x:type() == 'bracket_index_expression') do x = x:named_child(0) end
        return x and x:type() == 'identifier' and txt(x, src) or nil
    end
    local function walk(x)
        if hit then return end
        local t = x:type()
        if t == 'variable_declaration' then
            -- `local o = {}` / `local o = setmetatable({}, mt)` is FRESH
            local a = x:named_child(0)
            -- @langs-ok lua-only: the CART-1684 interim rule (interim_for runs it on lua functions only)
            if a and a:type() == 'assignment_statement' then
                local vl, el = a:named_child(0), a:named_child(1)
                if vl and el then
                    for i = 0, vl:named_child_count() - 1 do
                        local v, e = vl:named_child(i), el:named_child(i)
                        if v and e and v:type() == 'identifier' then
                            local et = txt(e, src)
                            -- @langs-ok lua-only: the CART-1684 interim rule (interim_for runs it on lua functions only)
                            fresh[txt(v, src)] = (e:type() == 'table_constructor' or et:match('^setmetatable%s*%(%s*{')) and true or nil
                        end
                    end
                end
            end
        elseif t == 'assignment_statement' then
            local vl = x:named_child(0)
            if vl then for _, tgt in tsutil.inamed, vl, -1 do
                local tt = tgt:type()
                if tt == 'dot_index_expression' or tt == 'bracket_index_expression' then
                    local r = rootname(tgt)
                    if not r or not (params[r] or fresh[r] or tracked[r]) then hit = true end
                elseif tt == 'identifier' then fresh[txt(tgt, src)] = nil end -- (rebound: no longer known fresh)
            end end
        end
        for _, c in tsutil.inamed, x, -1 do if not FN_TYPES[c:type()] then walk(c) end end
    end
    walk(f)
    return hit
end
local function reaches_uvw(store, fid)
    -- (one memo per graph GENERATION: a re-ingest — the harness re-uses one store — invalidates every parse and verdict)
    local memo = UVW[store]
    if not memo or memo.__gen ~= store.generation then memo = { __files = {}, __gen = store.generation }; UVW[store] = memo end
    if memo[fid] ~= nil then return memo[fid] end
    local callrec = require 'cartograph.callrec'
    local seen, work, hit = { [fid] = true }, { fid }, false
    while #work > 0 and not hit do
        local f = table.remove(work)
        if memo[f] == true or direct_uvw(store, f) then hit = true break end
        for _, c in ipairs(store.topo():sites(f) or {}) do
            local to = callrec.to(c)
            if to and not seen[to] then seen[to] = true; work[#work + 1] = to end
        end
    end
    memo[fid] = hit
    return hit
end
M._reaches_uvw = reaches_uvw

local function interim_harmless(store, node)
    local E = require 'cartograph.effects'
    local callrec = require 'cartograph.callrec'
    local atr = require 'cartograph.at'
    local sums = store and store.topo and E.summaries(store) or {}
    local sites = store and store.topo and store.topo():sites(node.id) or {}
    local memo = {}
    return function (cn)
        local id = cn:id()
        if memo[id] then return memo[id][1], memo[id][2] end
        local r, c0 = cn:start()
        local c
        for _, x in ipairs(sites) do
            if callrec.line(x) == r and (x.at and atr.sc(x.at) or -1) == c0 then c = x; break end
        end
        local ok, cat = false, 'unmatched'
        if c then
            local to = callrec.to(c)
            if to then
                local s = sums[to]
                if not s then cat = 'nosummary'
                else
                    local p = E.purity(store, to)
                    if p == 'pure' then
                        if reaches_uvw(store, to) then cat = 'pure-but-upvalue-write' else ok, cat = true, 'pure' end
                    else cat = p or 'nosummary' end
                end
            else
                local name = callrec.full(c) or callrec.callee(c)
                local sig, tier = E.sig_of('lua', name, callrec.method(c))
                local an = ARRAY_ONLY[name]
                local args = cn:field('arguments')[1]
                if an == 1 and args and args:named_child(1) ~= nil then an = nil end -- (sort WITH a comparator calls it)
                if NI.arr and an then
                    ok, cat = true, 'array-builtin'
                elseif not sig then cat = 'unresolved'
                elseif tier == 'method~' then cat = 'builtin-method~'
                elseif sig.calls then cat = 'builtin-calls'
                elseif sig.w then cat = 'builtin-writes'
                elseif sig.io then cat = 'builtin-io'
                elseif not sig.pure then cat = 'builtin-impure'
                else ok, cat = true, 'builtin-pure' end
            end
        end
        memo[id] = { ok, cat }
        return ok, cat
    end
end
M._interim_harmless = interim_harmless
-- (the interim rule reads LUA trees — its node types are lua's; every other language keeps name-based staling)
local function interim_for(store, node)
    return NI.on and node and type(node.file) == 'string' and node.file:match('%.lua$') and interim_harmless(store, node) or nil
end

local function field_unstable_of(fn, src, harmless, iharm)
    local stale = {} -- list of { prefix = <path str>, inclusive = bool }
    -- (a CALL-derived entry carries its call node and argument position — 0 the method receiver — for the call-staling
    -- census: does the callee's effect summary say it writes there at all? CART-1677)
    -- (`at`: the byte the staling node starts at — an entry BEFORE a guard cannot invalidate what the guard proves,
    -- see fact_live; `from` the node itself)
    local function mark(prefix, inclusive, call, argi, from)
        if prefix then
            local at = from and select(3, from:start())
            stale[#stale + 1] = { prefix = prefix, inclusive = inclusive, call = call, argi = argi, at = at,
                endb = from and select(3, from:end_()) }
        end
    end
    -- (INTERIM entries: `ifield` a field NAME written, `iall` every fact, `imeta` an index off the guarded chain; `cat`
    -- why. `at` / `endb` nil = unpositioned: a write inside a nested function runs whenever it is called)
    local function imark(e, from)
        if from then e.at = select(3, from:start()); e.endb = select(3, from:end_()) end
        e.interim = true
        stale[#stale + 1] = e
    end
    local function keyname(b) -- a bracket index's literal string key, else nil
        local k = b:field('field')[1]
        if k and k:type() == 'string' then local c = k:field('content')[1]; return c and txt(c, src) or '' end
        return nil
    end
    local function fieldwrite(tgt, nested)
        local tt = tgt:type()
        local tbl = tgt:named_child(0)
        local troot = not nested and tbl and tbl:type() == 'identifier' and txt(tbl, src) or nil
        local n0 = #stale
        if tt == 'dot_index_expression' then
            local f = tgt:field('field')[1]
            imark({ ifield = f and txt(f, src), cat = nested and 'nested-field-write' or 'field-write' }, not nested and tgt or nil)
        elseif tt == 'bracket_index_expression' then
            local k = keyname(tgt)
            if k then imark({ ifield = k, cat = nested and 'nested-field-write' or 'field-write' }, not nested and tgt or nil)
            else imark({ iall = true, cat = nested and 'nested-dynkey-write' or 'dynkey-write',
                keynode = not nested and tgt:field('field')[1] or nil }, not nested and tgt or nil) end
        end
        if troot then for i = n0 + 1, #stale do stale[i].troot = troot end end
    end
    -- (a nested function's writes: field writes stale by name whenever it may run; a name it ASSIGNS is CAPTURED)
    local function nested(n)
        -- @langs-ok lua-only: the CART-1684 interim rule (interim_for runs it on lua functions only)
        if n:type() == 'assignment_statement' then
            for _, c in tsutil.inext, n, -1 do
                -- @langs-ok lua-only: the CART-1684 interim rule (interim_for runs it on lua functions only)
                if c:type() == 'variable_list' then for _, tgt in tsutil.inext, c, -1 do
                    if tgt:type() == 'identifier' then
                        stale.captured = stale.captured or {}
                        stale.captured[txt(tgt, src)] = true
                    else fieldwrite(tgt, true) end
                end end
            end
        end
        for _, c in tsutil.inext, n, -1 do if c:named() then nested(c) end end
    end
    -- (the names this function BINDS itself: params, locals, local functions, loop variables — a depth-0 fact on any
    -- other name is an upvalue or a global, which a call can reassign)
    local bound = {}
    stale.bound = bound
    do
        local ps = fn:field('parameters')[1]
        if ps then for _, c in tsutil.inamed, ps, -1 do if c:type() == 'identifier' then bound[txt(c, src)] = true end end end
    end
    local declcount, numvars, freshdecl = {}, {}, {}
    local function decl(nm) bound[nm] = true; declcount[nm] = (declcount[nm] or 0) + 1 end
    local function binds(n)
        local t = n:type()
        if t == 'variable_declaration' then
            local function names(x)
                for _, c in tsutil.inamed, x, -1 do
                    if c:type() == 'identifier' then decl(txt(c, src))
                    -- @langs-ok lua-only: the CART-1684 interim rule (interim_for runs it on lua functions only)
                    elseif c:type() == 'variable_list' or c:type() == 'assignment_statement' then names(c) end
                end
            end
            names(n)
            -- (`local r = {}`: where a FRESH table is bound, for NI.fresh)
            local a = n:named_child(0)
            -- @langs-ok lua-only: the CART-1684 interim rule (interim_for runs it on lua functions only)
            if a and a:type() == 'assignment_statement' then
                local vl, el = a:named_child(0), a:named_child(1)
                if vl and el and vl:named_child_count() == 1 and el:named_child_count() == 1
                    -- @langs-ok lua-only: the CART-1684 interim rule (interim_for runs it on lua functions only)
                    and vl:named_child(0):type() == 'identifier' and el:named_child(0):type() == 'table_constructor' then
                    freshdecl[txt(vl:named_child(0), src)] = select(3, n:start())
                end
            end
        elseif t == 'function_declaration' then
            local nm = n:field('name')[1]
            -- @langs-ok lua-only: the CART-1684 interim rule (interim_for runs it on lua functions only)
            if nm and nm:type() == 'identifier' and n:parent() and n:parent():type() ~= 'chunk' then
                -- (`local function g` and a bare `function g` both name an identifier; only `local` binds — check the text)
                if txt(n, src):match('^local%s') then decl(txt(nm, src)) end
            end
        elseif t == 'for_generic_clause' then
            -- (`for i, v in ipairs(t)`: i is a NUMBER)
            local vl, el
            for _, c in tsutil.inamed, n, -1 do
                -- @langs-ok lua-only: the CART-1684 interim rule (interim_for runs it on lua functions only)
                if c:type() == 'variable_list' then vl = c elseif c:type() == 'expression_list' then el = c end
            end
            local it = el and el:named_child(0)
            -- @langs-ok lua-only: the CART-1684 interim rule (interim_for runs it on lua functions only)
            local isip = it and it:type() == 'function_call' and it:named_child(0) and txt(it:named_child(0), src) == 'ipairs'
            if vl then local k = 0; for _, v in tsutil.inamed, vl, -1 do
                k = k + 1
                decl(txt(v, src))
                if isip and k == 1 then numvars[txt(v, src)] = true end
            end end
        elseif t == 'for_numeric_clause' then
            local nm = n:field('name')[1]; if nm then decl(txt(nm, src)); numvars[txt(nm, src)] = true end
        end
    end
    local function walk(n)
        local t = n:type()
        if iharm then
            binds(n)
            if t == 'function_call' then
                local ok, cat = iharm(n)
                if not ok then imark({ iall = true, cat = cat, call = n }, n)
                -- (even a harmless call may be a nested closure that REBINDS a captured name: its summary need not say)
                else imark({ icallany = true, cat = 'call-captured', call = n }, n) end
            elseif NI.meta and (t == 'dot_index_expression' or t == 'bracket_index_expression'
                    or t == 'method_index_expression') then
                local p
                if t == 'method_index_expression' then
                    local r = path_of(n:named_child(0), src); local m = n:field('method')[1]
                    p = r and m and (r.path .. '.' .. txt(m, src))
                else p = path_of(n, src); p = p and p.path end
                -- (the Lua stdlib tables carry no metatable: `table.insert`, `string.format` read plain fields)
                local r0 = p and p:match('^([%w_]+)')
                if not (r0 and LUASTD[r0] and not bound[r0]) then imark({ imeta = true, path = p, cat = 'meta' }, n) end
            end
        end
        -- `assignment_statement` = (variable_list) = (expression_list); `local x = …` is
        -- a `variable_declaration` wrapping one, so handling the inner form catches both.
        if t == 'assignment_statement' then
            local vlist, elist
            for _, c in tsutil.inext, n, -1 do
                -- @langs-ok lua-only: field_unstable_of gates depth-≥1 PATHS, and ruby
                -- has none by design, so this walk is never reached for ruby facts
                if c:type() == 'variable_list' then vlist = c
                -- @langs-ok lua-only, same reason
                elseif c:type() == 'expression_list' then elist = c end
            end
            if vlist then for _, tgt in tsutil.inext, vlist, -1 do -- field-write targets
                if iharm then fieldwrite(tgt, false) end
                -- @langs-ok lua-only, same reason: ruby facts are all depth 0
                if tgt:type() == 'dot_index_expression' then
                    local p = path_of(tgt, src); if p then mark(p.path, true, nil, nil, tgt) end -- A.f inclusive
                -- @langs-ok lua-only, same reason as above
                elseif tgt:type() == 'bracket_index_expression' then
                    local b = path_of(tgt:named_child(0), src); if b then mark(b.path, false, nil, nil, tgt) end -- A[?] → A.*
                -- (a plain REASSIGNMENT of a name — not a `local` declaration, a new binding: where it starts, for the
                -- root's position rule in fact_live)
                -- @langs-ok lua-only, same reason as above
                elseif tgt:type() == 'identifier' and n:parent() and n:parent():type() ~= 'variable_declaration' then
                    local nm = vim.treesitter.get_node_text(tgt, src)
                    stale.assign_at = stale.assign_at or {}
                    stale.assign_at[nm] = stale.assign_at[nm] or {}
                    table.insert(stale.assign_at[nm], select(3, tgt:start()))
                end
            end end
            if elist then for _, v in tsutil.inext, elist, -1 do -- alias RHS (identifier or field path)
                if v:named() then local p = path_of(v, src); if p then mark(p.path, false, nil, nil, v) end end -- y = A → A.*
            end end
        elseif t == 'function_call' then -- A passed as arg, or A:m() receiver
            local args = n:field('arguments')[1]
            if args then local ai = 0; for _, a in tsutil.inamed, args, -1 do
                ai = ai + 1
                local p = path_of(a, src); if p and not (harmless and harmless(n, ai)) then mark(p.path, false, n, ai, n) end
            end end
            local callee = n:named_child(0)
            -- @langs-ok lua-only staling walk; ruby has no depth-≥1 facts to stale
            if callee and callee:type() == 'method_index_expression' then
                local p = path_of(callee:named_child(0), src); if p and not (harmless and harmless(n, 0)) then mark(p.path, false, n, 0, n) end
            end
        elseif t == 'goto_statement' then -- @langs-ok lua-only staling walk
            stale.has_goto = true -- (a backward jump breaks textual order: no position rule in this function)
        end
        for _, c in tsutil.inext, n, -1 do
            if c:named() and not FN_TYPES[c:type()] then walk(c) end -- nested fns = own scope
            if iharm and c:named() and FN_TYPES[c:type()] then
                -- (a nested function DECLARED `local function g` binds g here; `function A.f()` WRITES A.f)
                binds(c)
                local nm = c:field('name')[1]
                -- @langs-ok lua-only: the CART-1684 interim rule (interim_for runs it on lua functions only)
                if nm and nm:type() == 'dot_index_expression' then fieldwrite(nm, false)
                -- @langs-ok lua-only: the CART-1684 interim rule (interim_for runs it on lua functions only)
                elseif nm and nm:type() == 'method_index_expression' then
                    local m = nm:field('method')[1]
                    imark({ ifield = m and txt(m, src), cat = 'field-write' }, nm)
                end
                nested(c)
            end
        end
    end
    walk(fn)
    if iharm and NI.fresh then
        -- (a write INTO a table this function built AFTER the guard — `local out = {}` bound once, never reassigned nor
        -- captured, written as `out[k]` / `out.f` — cannot touch an object the guarded path ran through: those existed
        -- when the guard ran, and putting the new table on the path takes a write the other rules already see)
        for _, e in ipairs(stale) do
            local r = e.troot
            if r and freshdecl[r] and declcount[r] == 1 and not (stale.assign_at and stale.assign_at[r])
                and not (stale.captured and stale.captured[r]) then e.fresh_at = freshdecl[r] end
        end
    end
    if iharm and NI.numkey then
        -- (a bracket write whose key is provably a NUMBER cannot reach a field a dot path names: `out[#out + 1] = x`,
        -- `t[i] = v` for a numeric-for / ipairs index declared once and never reassigned)
        local function numeric(k)
            if not k then return false end
            local t = k:type()
            if t == 'number' then return true end
            if t == 'parenthesized_expression' then return numeric(k:named_child(0)) end
            if t == 'unary_expression' then return txt(k:child(0), src) == '#' end
            if t == 'binary_expression' then
                local op = txt(k:child(1), src)
                return (op == '+' or op == '-' or op == '*' or op == '%') and numeric(k:named_child(0)) and numeric(k:named_child(1))
            end
            if t == 'identifier' then
                local nm = txt(k, src)
                return numvars[nm] == true and declcount[nm] == 1 and not (stale.assign_at and stale.assign_at[nm])
                    and not (stale.captured and stale.captured[nm])
            end
            return false
        end
        for _, e in ipairs(stale) do
            if e.keynode and numeric(e.keynode) then e.iall = nil; e.cat = 'numkey-write' end
        end
    end
    return stale
end

-- does staling prefix `a` cover path `p`? `a` is a prefix of `p` when p == a or p
-- continues past a dot boundary (`a.` …). Inclusive covers the exact path too.
local function prefix_covers(a, inclusive, p)
    if p == a then return inclusive end
    return p:sub(1, #a + 1) == a .. '.'
end
-- keep a fact `f` at a point. A field path (depth ≥ 1) needs its root un-reassigned
-- AND no staling prefix covering its path; a bare var only needs un-reassignment.
-- ★ POSITION (CART-1677): a staling entry that starts BEFORE the guard's condition ran before the guard was checked, so
-- it cannot invalidate what the guard proves — unless a LOOP holding the point also holds the entry (a later iteration
-- runs it after the guard) or the function has a `goto`. `gb` = the guard condition's start byte, `loops` = the byte
-- ranges of the loops enclosing the point ({ start, end } pairs); both nil = the old, position-blind rule.
local function before_guard(e, gb, loops, stale)
    if not (gb and e.at and e.at < gb) or stale.has_goto then return false end
    for _, l in ipairs(loops or {}) do if e.at >= l[1] and e.at < l[2] then return false end end
    return true
end
-- the same rule for the ROOT: a name reassigned (mutated_of: anywhere in the function) keeps a fact only when EVERY
-- reassignment the walk saw starts before the guard and no loop around the point holds one — and the walk saw at least
-- one (mutated_of may know a write the walk does not position: then it still kills)
local function reassigned_before(root, gb, loops, stale)
    local at = stale and stale.assign_at and stale.assign_at[root]
    if not (gb and at and #at > 0) or stale.has_goto then return false end
    for _, b in ipairs(at) do
        if b >= gb then return false end
        for _, l in ipairs(loops or {}) do if b >= l[1] and b < l[2] then return false end end
    end
    return true
end
-- (NI.ub: an entry that ends before the use point `ub`, or runs inside a loop around the point, can reach it; one that
-- starts at or after it, outside every such loop, cannot. A goto disables the rule)
local function after_use(e, ub, loops, stale)
    if not (NI.ub and ub and e.at and e.endb) or stale.has_goto then return false end
    if e.endb <= ub then return false end
    for _, l in ipairs(loops or {}) do if e.at >= l[1] and e.at < l[2] then return false end end
    return true
end
-- does interim entry e reach fact f?
local function interim_hits(f, e, captured)
    local depth = f.depth or 0
    if e.iall then return true end
    if e.icallany then return captured ~= nil and captured[f.root] == true end
    if e.ifield then
        if depth == 0 then return e.ifield == f.var end -- (`_G.x = …` for a global root)
        for part in f.var:gmatch('%.([^.]+)') do if part == e.ifield then return true end end
        return false
    end
    if e.imeta then
        if depth == 0 then return false end
        if e.path and (f.var == e.path or f.var:sub(1, #e.path + 1) == e.path .. '.') then return false end
        return true
    end
    return false
end
-- (the interim kills of the LAST fact_live call, by category: read by the census)
M._last_kill = nil
local function fact_live(f, mutated, stale, gb, loops, ub)
    M._last_kill = nil
    if mutated[f.root] and not reassigned_before(f.root, gb, loops, stale) then return false end
    local depth = f.depth or 0
    -- (INTERIM: a depth-0 fact on a name this function does not bind, or one a nested function assigns, is exposed to
    -- calls like a field path)
    local exposed0 = NI.on and depth == 0 and stale.bound and (not stale.bound[f.root] or (stale.captured and stale.captured[f.root]))
    if depth >= 1 or exposed0 then
        local cats
        for _, e in ipairs(stale) do
            if not before_guard(e, gb, loops, stale) and not after_use(e, ub, loops, stale) then
                if e.interim then
                    local fresh = e.fresh_at and gb and e.fresh_at > gb and not stale.has_goto
                    if not fresh and interim_hits(f, e, stale.captured) then cats = cats or {}; cats[e.cat] = true end
                elseif depth >= 1 and prefix_covers(e.prefix, e.inclusive, f.var) then return false end
            end
        end
        if cats then M._last_kill = cats; return false end
    end
    return true
end
-- the byte ranges of the loops enclosing `node` up to `fn` (fact_live's `loops`)
local LOOPS = { while_statement = true, for_statement = true, repeat_statement = true }
local function loops_of(node, fn)
    local out = {}
    local a = node:parent()
    while a and (not fn or a:id() ~= fn:id()) do
        if LOOPS[a:type()] then out[#out + 1] = { select(3, a:start()), select(3, a:end_()) } end
        a = a:parent()
    end
    return out
end

-- kind precedence: a concrete value (eq:) proves a type, a type proves non-nil +
-- truthy; truthy/non-nil are the floor. Higher = stronger; env keeps the strongest.
local function kind_rank(k)
    if not k then return 0 end
    if k:match('^eq:') then return 4 end
    if k:match('^type:') then return 3 end
    if k == 'truthy' then return 2 end
    return 1 -- non-nil
end
-- the DISPLAY collapse for M.narrow's report env: eq:/type: are shown verbatim,
-- truthy/non-nil collapse to the sound floor 'non-nil' (what a guard minimally proves).
local function disp(kind) return (kind:match('^eq:') or kind:match('^type:')) and kind or 'non-nil' end
-- human form of a kind for the lens: `is string` / `= 'foo'` / `= 3` / `non-nil`.
local function show_kind(kind)
    local ty = kind:match('^type:(.+)$'); if ty then return 'is ' .. ty end
    local s = kind:match('^eq:s:(.*)$'); if s then return ("= '%s'"):format(s) end
    local n = kind:match('^eq:n:(.+)$'); if n then return '= ' .. n end
    return kind
end

--- Branch-sensitive narrowing of the focused fn. Walks the body's statements; at
--- each, cfg.guards_over gives the dominating guards, the vocab classifies each into
--- facts, and a fact is kept when its polarity matches the guard's truth value.
--- @return table { lang, unsupported?, points: { {line, kind, env: {[var]=kind}} }, nguards }
function M.narrow(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return { points = {} } end
    local lang = EXT_LANG[node.file:match('%.(%w+)$') or '']
    if not lang or not (vocab[lang] and VERB_LANG.narrow[lang]) then
        return { lang = node.file:match('%.(%w+)$'), unsupported = true, points = {} }
    end
    local src = table.concat(store.content(node) or {}, '\n')
    local fn = fn_node(node, src, lang)
    if not fn then return { lang = lang, points = {} } end
    local classify = gated_classify(vocab[lang], type_is_shadowed(lang, node))
    local mutated = mutated_of(node)
    local funstable = field_unstable_of(fn, src, call_harmless(store, node), interim_for(store, node))

    local points, seenguard = {}, {}
    local function visit(n)
        for _, c in tsutil.inamed, n, -1 do
            if STMT_BLOCK[c:type()] then
                for _, stmt in tsutil.inext, c, -1 do
                    if stmt:named() and not tsutil.is_comment(stmt) then
                        local env = {}
                        local sloops = loops_of(stmt, fn)
                        for _, g in ipairs(cfg.guards_over(stmt, src)) do
                            for _, f in ipairs(classify(g.cond, src, not g.neg)) do
                                local live = fact_live(f, mutated, funstable, select(3, g.cond:start()), sloops, select(3, stmt:start()))
                                if M._ni_hook then M._ni_hook(stmt, f, live, M._last_kill) end
                                if live then
                                    -- keep the STRONGEST kind; eq:/type: shown verbatim,
                                    -- nil/truthy collapse to the sound floor 'non-nil'
                                    if kind_rank(f.kind) > kind_rank(env[f.var]) then
                                        env[f.var] = disp(f.kind)
                                    end
                                    seenguard[g.cond:id()] = true
                                end
                            end
                        end
                        if next(env) then
                            points[#points + 1] = { line = stmt:start() + 1,
                                kind = stmt:type(), env = env }
                        end
                    end
                end
            end
            if not FN_TYPES[c:type()] then visit(c) end -- nested fns = their own scope
        end
    end
    visit(fn)
    table.sort(points, function (a, b) return a.line < b.line end)
    local nguards = 0
    for _ in pairs(seenguard) do nguards = nguards + 1 end
    return { lang = lang, points = points, nguards = nguards }
end

-- the narrowing env active AT a node from its DOMINATING guards (excludes the
-- node's own condition — guards_over walks parents). Keeps the RAW STRONGEST kind
-- (eq: ⊐ type: ⊐ truthy ⊐ non-nil) — determine() needs truthy distinct from non-nil
-- and the eq: value verbatim. Keyed by PATH (a bare var or a field path).
local function env_of(node, src, classify, mutated, funstable)
    local env = {}
    local nloops = loops_of(node)
    for _, g in ipairs(cfg.guards_over(node, src)) do
        for _, f in ipairs(classify(g.cond, src, not g.neg)) do
            if fact_live(f, mutated or {}, funstable or {}, select(3, g.cond:start()), nloops, select(3, node:start())) then
                if kind_rank(f.kind) > kind_rank(env[f.var]) then env[f.var] = f.kind end
            end
        end
    end
    return env
end

-- env-fact interrogation: an eq: value proves its literal's type (string/number); a
-- TYPE fact implies non-nil (type(nil)=='nil') and truthy for every type but boolean
-- (false) and nil. `v` is a path key (bare var or field path).
local function env_type(env, v)
    local e = env[v]; if not e then return nil end
    local ty = e:match('^type:(.+)$'); if ty then return ty end
    if e:match('^eq:s:') then return 'string' end
    if e:match('^eq:n:') then return 'number' end
    return nil
end
local function env_nonnil(env, v)
    local e = env[v]
    return e == 'truthy' or e == 'non-nil' or (env_type(env, v) and env_type(env, v) ~= 'nil') or false
end
local function env_truthy(env, v)
    if env[v] == 'truthy' then return true end
    local ty = env_type(env, v)
    return ty ~= nil and ty ~= 'boolean' and ty ~= 'nil'
end

-- is a SIMPLE condition already DETERMINED by `env`? → 'always-true' (tautology,
-- then-branch always taken) | 'dead' (contradiction, then-branch dead) | nil.
-- `if P` needs TRUTHY; `P~=nil`/`P==nil` need non-nil; `not P` dead under truthy; a
-- type-test is determined by a proven TYPE fact; a discriminant `P=='v'` by a proven
-- eq: value (P a bare var or a field path throughout).
local function determine(cond, src, env)
    local t = cond:type()
    if t == 'parenthesized_expression' then return determine(cond:named_child(0), src, env) end
    if t == 'unary_expression' and txt(cond:child(0), src) == 'not' then
        local ip = path_of(cond:named_child(0), src)
        if ip and env_truthy(env, ip.path) then return 'dead' end
        return nil
    end
    local pp = path_of(cond, src) -- `if P` truthy test
    if pp then
        if env_truthy(env, pp.path) then return 'always-true' end
        return nil
    end
    if t == 'binary_expression' then
        local l, r = cond:named_child(0), cond:named_child(1)
        local op = txt(cond:child(1), src)
        local np -- P == nil / P ~= nil
        if txt(r, src) == 'nil' then np = path_of(l, src)
        elseif txt(l, src) == 'nil' then np = path_of(r, src) end
        if np and env_nonnil(env, np.path) then
            if op == '~=' then return 'always-true' end -- P~=nil, P known non-nil
            if op == '==' then return 'dead' end        -- P==nil, P known non-nil
        end
        if op == '==' or op == '~=' then
            -- type-test determined by a proven type fact
            local tp = (type_call_path(l, src) and str_lit(r, src) and { type_call_path(l, src), str_lit(r, src) })
                or (type_call_path(r, src) and str_lit(l, src) and { type_call_path(r, src), str_lit(l, src) })
            if tp then
                local kty = env_type(env, tp[1].path)
                if kty then
                    local same = (kty == tp[2])
                    if op == '==' then return same and 'always-true' or 'dead' end
                    return same and 'dead' or 'always-true' -- ~=
                end
            end
            -- discriminant determined by a proven eq: value
            local dp = (path_of(l, src) and disc_kind(r, src) and { path_of(l, src), disc_kind(r, src) })
                or (path_of(r, src) and disc_kind(l, src) and { path_of(r, src), disc_kind(l, src) })
            if dp then
                local kv = env[dp[1].path]
                if kv and kv:match('^eq:') then
                    local same = (kv == dp[2])
                    if op == '==' then return same and 'always-true' or 'dead' end
                    return same and 'dead' or 'always-true' -- ~=
                end
            end
        end
    end
    return nil
end

-- ── parameter-nilability ([[cartograph-expression-layer]] Rung 2) ────────────
-- a nil-UNSAFE dereference of a parameter at node `n` → the param name, else nil. In
-- Lua these all ERROR on nil: p.x / p[i] / p:m() / p() / #p / arithmetic|concat on p.
local DEREF_INDEX = { dot_index_expression = true, bracket_index_expression = true,
    method_index_expression = true }
local ARITH = { ['+'] = true, ['-'] = true, ['*'] = true, ['/'] = true,
    ['%'] = true, ['^'] = true, ['..'] = true, ['//'] = true }
-- returns the list of parameter names dereffed at `n` (arithmetic touches BOTH operands)
local function param_derefs(n, src, params)
    local out, t = {}, n:type()
    local function add(o)
        if o and o:type() == 'identifier' and params[txt(o, src)] then out[#out + 1] = txt(o, src) end
    end
    if DEREF_INDEX[t] then add(n:named_child(0))
    elseif t == 'function_call' then add(n:named_child(0))
    elseif t == 'unary_expression' then
        if txt(n:child(0), src) == '#' then add(n:named_child(0)) end
    elseif t == 'binary_expression' then
        if ARITH[txt(n:child(1), src)] then add(n:named_child(0)); add(n:named_child(1)) end
    end
    return out
end

-- the LuaCATS `---@param` annotations in the doc block directly above the fn's
-- top-level statement → { [name] = 'optional' | 'non-nil' }. Optional = `name?`,
-- a `?`-suffixed type, or a `nil` union member (what lua-ls treats as nilable).
-- optionality of a `---@param` TYPE (the text after `name[?] `): 'optional' /
-- 'non-nil' when CONFIDENT, else nil = "don't compare" (a complex table/fun type we
-- won't risk mis-reading — the oracle must never false-conflict on a parser guess).
local function ann_optional(rest)
    rest = vim.trim(rest or '')
    local tok = rest:match('^(%S+)') -- the first token = a SIMPLE type, or the start of a complex one
    if not tok then return nil end
    if tok:match('^[{(]') or tok == 'fun' then return nil end -- `{…}` / `fun(…)` → unsure
    if tok:match('%?$') then return 'optional' end
    if ('|' .. tok .. '|'):match('|nil|') then return 'optional' end -- a nil union member
    if tok:match('^[%w_%.%[%]|]+$') then return 'non-nil' end -- a clean plain type
    return nil
end
local STMT_PARENT = { block = true, chunk = true }
local function param_annotations(fn, src)
    local s = fn
    while s:parent() and not STMT_PARENT[s:parent():type()] do s = s:parent() end
    local ann, block = {}, {}
    local sib = s:prev_named_sibling()
    -- @langs-ok the `---@param` annotation block is lua's, and param_nilability is
    -- gated to lua by VERB_LANG; ruby's declared types live in RBS/sig, not a comment
    while sib and sib:type() == 'comment' do block[#block + 1] = txt(sib, src); sib = sib:prev_named_sibling() end
    for _, line in ipairs(block) do
        local name, opt, rest = line:match('^%s*%-%-%-?@param%s+([%w_]+)(%??)%s*(.*)$')
        if name then
            local a = opt == '?' and 'optional' or ann_optional(rest)
            if a then ann[name] = a end -- nil (unsure) → leave unset, no comparison
        end
    end
    return ann
end

--- PARAMETER-NILABILITY inference (Rung 2, the lua-ls DISAGREEMENT ORACLE). For each
--- parameter, infer whether the body REQUIRES it non-nil (an unguarded nil-unsafe
--- deref, or an `assert`), TOLERATES nil (every deref guarded / short-circuited /
--- nil-tested), or is UNCONSTRAINED. Sound-first: a deref is protected by a dominating
--- guard (env_of/guards_over — incl. early-exit), an enclosing short-circuit
--- (`p and p.x`, `p ~= nil and …`), or an assert; a REASSIGNED param (`p = p or {}`)
--- is left unconstrained (conservative). Compared against the `---@param` annotation:
--- inferred REQUIRED + annotated OPTIONAL (`?`) = a real defect (the body crashes on a
--- nil the type permits) — the keystone disagreement.
--- @return table { lang, unsupported?, params: { {name, verdict, site?, annotated?, conflict?} } }
function M.param_nilability(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return { params = {} } end
    local lang = EXT_LANG[node.file:match('%.(%w+)$') or '']
    if not lang or not (vocab[lang] and VERB_LANG.param_nilability[lang]) then
        return { lang = node.file:match('%.(%w+)$'), unsupported = true, params = {} }
    end
    local src = table.concat(store.content(node) or {}, '\n')
    local fn = fn_node(node, src, lang)
    if not fn then return { lang = lang, params = {} } end
    local classify, mutated = gated_classify(vocab[lang], type_is_shadowed(lang, node)), mutated_of(node)
    local funstable = field_unstable_of(fn, src, call_harmless(store, node), interim_for(store, node))
    local fl = flowmod.present(node) and flowmod.record(node)
    local plist = (fl and fl.params) or {}
    local params = {}
    for _, p in ipairs(plist) do if p ~= 'self' then params[p] = true end end
    if not next(params) then return { lang = lang, params = {} } end

    local unguarded, asserted, tested = {}, {}, {}
    local function note_tested(cond)
        for _, f in ipairs(classify(cond, src, true)) do tested[f.var] = true end
        for _, f in ipairs(classify(cond, src, false)) do tested[f.var] = true end
    end
    local CONDN = { if_statement = true, elseif_statement = true, while_statement = true,
        repeat_statement = true }
    local function walk(n, proven)
        local t = n:type()
        if t == 'function_call' then -- assert(cond) proves its conjuncts non-nil
            local callee = n:named_child(0)
            if callee and callee:type() == 'identifier' and txt(callee, src) == 'assert' then
                local args = n:field('arguments')[1]
                local cond = args and args:named_child(0)
                if cond then for _, f in ipairs(classify(cond, src, true)) do
                    asserted[f.var] = true; tested[f.var] = true
                end end
            end
        end
        if CONDN[t] then local c = n:field('condition')[1]; if c then note_tested(c) end end
        for _, p in ipairs(param_derefs(n, src, params)) do
            if not proven[p] and not env_of(n, src, classify, mutated, funstable)[p] then
                unguarded[p] = unguarded[p] or (n:start() + 1)
            end
        end
        if t == 'binary_expression' then
            local op = txt(n:child(1), src)
            local l, r = n:named_child(0), n:named_child(1)
            if (op == 'and' or op == 'or') and l and r then
                walk(l, proven)
                local p2 = {}; for k in pairs(proven) do p2[k] = true end
                for _, f in ipairs(classify(l, src, op == 'and')) do p2[f.var] = true; tested[f.var] = true end
                walk(r, p2)
                return
            end
        end
        for _, c in tsutil.inext, n, -1 do
            if c:named() and not FN_TYPES[c:type()] then walk(c, proven) end
        end
    end
    walk(fn, {})

    local ann = param_annotations(fn, src)
    local out = {}
    for _, p in ipairs(plist) do
        if p ~= 'self' then
            -- REQUIRED is HIGH-CONFIDENCE (the oracle must be trustworthy): either an
            -- `assert`, or an unguarded deref of a param that is NEVER nil-tested
            -- anywhere in the body — if the author checks it even once they are
            -- nil-aware (a correlated guard through an intermediate we can't track →
            -- optional), so a nil-tested param is never called required. Conservative:
            -- under-infers required, never false-flags a defended param.
            local verdict, site
            if mutated[p] then verdict = 'unknown'
            elseif asserted[p] then verdict = 'required'
            elseif unguarded[p] and not tested[p] then verdict, site = 'required', unguarded[p]
            elseif tested[p] or unguarded[p] then verdict = 'optional'
            else verdict = 'unknown' end
            local a = ann[p]
            local conflict = (verdict == 'required' and a == 'optional')
                or (verdict == 'optional' and a == 'non-nil')
            out[#out + 1] = { name = p, verdict = verdict, site = site, annotated = a,
                conflict = conflict or nil }
        end
    end
    return { lang = lang, params = out }
end

--- REDUNDANT-CHECK ELIMINATION (INC 2, the paving-stone lint). An `if` whose
--- condition re-tests a fact a DOMINATING guard already established is dead: the
--- env at the guard already determines the condition. `always=true` → the
--- then-branch is always taken (the check is a tautology); `always=false` → the
--- then-branch is dead (the check contradicts what's known). The TYPE twin of
--- const-fold's dead-branch. Sound: only where a proven fact determines the test.
--- @return table { lang, unsupported?, checks: { {line, var, kind, always, cond} } }
function M.redundant(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return { checks = {} } end
    local lang = EXT_LANG[node.file:match('%.(%w+)$') or '']
    if not lang or not (vocab[lang] and VERB_LANG.redundant[lang]) then
        return { lang = node.file:match('%.(%w+)$'), unsupported = true, checks = {} }
    end
    local src = table.concat(store.content(node) or {}, '\n')
    local fn = fn_node(node, src, lang)
    if not fn then return { lang = lang, checks = {} } end
    local classify = gated_classify(vocab[lang], type_is_shadowed(lang, node))
    local mutated = mutated_of(node)
    local funstable = field_unstable_of(fn, src, call_harmless(store, node), interim_for(store, node))
    -- determine() handles only SINGLE predicates, so a conjunction `cond and other()`
    -- (where only `cond` is known) is correctly NOT flagged — the other conjunct still
    -- gates the branch.
    local checks = {}
    local function visit(n)
        for _, c in tsutil.inext, n, -1 do
            if c:named() then
                -- @langs-ok `redundant` is gated to lua by VERB_LANG: its subject IS
                -- a lua if_statement, and ruby's equivalent needs its own finder (CART-0302)
                if c:type() == 'if_statement' then
                    local cond = c:field('condition')[1]
                    if cond then
                        local d = determine(cond, src, env_of(c, src, classify, mutated, funstable))
                        if d then
                            checks[#checks + 1] = { line = cond:start() + 1,
                                always = (d == 'always-true'), cond = txt(cond, src) }
                        end
                    end
                end
                if not FN_TYPES[c:type()] then visit(c) end -- nested fns = their own scope
            end
        end
    end
    visit(fn)
    table.sort(checks, function (a, b) return a.line < b.line end)
    return { lang = lang, checks = checks }
end

--- DEVIRTUALIZATION report (narrow v2, the type-fact consumer). A method call
--- `recv:m()` is dynamic dispatch; where a dominating guard narrows the receiver to a
--- CONCRETE type, the target is (partly) resolved:
---   • recv is `type:string` (or an eq: string) → `s:m()` ALWAYS dispatches through the
---     string metatable to `string.m` (fixed at the C level — sound even if the global
---     `string` is shadowed). CERTIFIED: a named static target, an inline candidate.
---   • recv is another concrete `type:T` → a CANDIDATE: the receiver's type is known but
---     the target needs a class/metatable binding, which guard-narrowing can't supply —
---     it needs the VM's receiver typing ([[graph-vm-type-resolution]]/[[cartograph-linker]]).
--- Receivers narrowed only to non-nil/truthy are NOT devirt sites (that says nothing
--- about WHICH method). The summary quantifies the devirt gap: how many dispatches a
--- concrete receiver type would turn static, and how many the VM still gates.
--- @return table { lang, unsupported?, sites: { {line, recv, method, status, target?, fact, why?} }, summary }
function M.devirt(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return { sites = {}, summary = {} } end
    local lang = EXT_LANG[node.file:match('%.(%w+)$') or '']
    if not lang or not (vocab[lang] and VERB_LANG.devirt[lang]) then
        return { lang = node.file:match('%.(%w+)$'), unsupported = true, sites = {}, summary = {} }
    end
    local src = table.concat(store.content(node) or {}, '\n')
    local fn = fn_node(node, src, lang)
    if not fn then return { lang = lang, sites = {}, summary = {} } end
    local classify = gated_classify(vocab[lang], type_is_shadowed(lang, node))
    local mutated, funstable = mutated_of(node), field_unstable_of(fn, src, call_harmless(store, node), interim_for(store, node))

    local sites = {}
    local summary = { method_calls = 0, typed = 0, certified = 0, candidate = 0 }
    local function visit(n)
        for _, c in tsutil.inext, n, -1 do
            if c:named() then
                -- @langs-ok `devirt` is gated to lua by VERB_LANG: its subject is a lua
                -- method call, and ruby dispatch needs its own finder (CART-0302)
                if c:type() == 'function_call' then
                    local callee = c:named_child(0)
                    -- @langs-ok same lua-gated devirt subject
                    if callee and callee:type() == 'method_index_expression' then
                        summary.method_calls = summary.method_calls + 1
                        local rp = path_of(callee:named_child(0), src)
                        local method = callee:field('method')[1] and txt(callee:field('method')[1], src)
                        if rp and method then
                            local kind = env_of(c, src, classify, mutated, funstable)[rp.path]
                            -- a concrete TYPE (from type-test or an eq: literal), not non-nil/truthy
                            local ty = kind and (kind:match('^type:(.+)$')
                                or (kind:match('^eq:s:') and 'string') or (kind:match('^eq:n:') and 'number'))
                            if ty then
                                summary.typed = summary.typed + 1
                                if ty == 'string' then
                                    summary.certified = summary.certified + 1
                                    sites[#sites + 1] = { line = c:start() + 1, recv = rp.path, method = method,
                                        status = 'certified', target = 'string.' .. method, fact = kind }
                                else
                                    summary.candidate = summary.candidate + 1
                                    sites[#sites + 1] = { line = c:start() + 1, recv = rp.path, method = method,
                                        status = 'candidate', fact = kind,
                                        why = ('%s receiver — target needs a class binding (VM)'):format(ty) }
                                end
                            end
                        end
                    end
                end
                if not FN_TYPES[c:type()] then visit(c) end -- nested fns = their own scope
            end
        end
    end
    visit(fn)
    table.sort(sites, function (a, b) return a.line < b.line end)
    return { lang = lang, sites = sites, summary = summary }
end

--- The lens surface (:CartographNarrow): where a guard narrows a variable, and to
--- what. Per statement under a narrowing guard, its active facts (`x: non-nil`).
function M.report(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return { 'narrow: no such node' } end
    local res = M.narrow(store, fn_id)
    if res.unsupported then
        return { ('narrow: %s not yet supported (INC 1 = Lua nil/truthiness)')
            :format(res.lang or '?') }
    end
    if #res.points == 0 then
        return { ('narrow: %s — no guard-narrowed regions'):format(node.name or fn_id) }
    end
    local L = { ('narrow: %s — %d narrowing guard(s) over %d statement(s)')
        :format(node.name or fn_id, res.nguards, #res.points), '' }
    for _, p in ipairs(res.points) do
        local facts = {}
        for var, kind in pairs(p.env) do
            facts[#facts + 1] = ('%s: %s'):format(var, show_kind(kind))
        end
        table.sort(facts)
        L[#L + 1] = ('  L%-4d %-16s %s'):format(p.line, p.kind, table.concat(facts, ', '))
    end
    -- INC 2: redundant checks — an `if` re-testing an already-proven fact
    local red = M.redundant(store, fn_id)
    if #red.checks > 0 then
        L[#L + 1] = ''
        L[#L + 1] = ('redundant check(s) — %d (already determined by a dominating guard):')
            :format(#red.checks)
        for _, c in ipairs(red.checks) do
            L[#L + 1] = ('  L%-4d if %s  →  %s'):format(c.line, c.cond,
                c.always and 'always true, then-branch always taken'
                    or 'always false, then-branch dead')
        end
    end
    L[#L + 1] = ''
    L[#L + 1] = 'a fact holds only where its guard PROVES it (nil-check / truthiness / type-test /'
    L[#L + 1] = 'discriminant `f == "v"` / and-conjunction; `or` and negated compounds do not narrow).'
    L[#L + 1] = 'a FIELD path (opts.mode) is narrowed too, dropped where the root is field-written,'
    L[#L + 1] = 'passed to a call, or aliased (may stale it). Sound knowledge — feeds redundant-check'
    L[#L + 1] = 'elimination + devirtualization, not a guess.'
    return L
end

--- The lens surface (:CartographParamNil): the focused fn's inferred parameter
--- nilability contracts, and any DISAGREEMENT with the `---@param` annotations.
function M.param_report(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return { 'param-nil: no such node' } end
    local res = M.param_nilability(store, fn_id)
    if res.unsupported then
        return { ('param-nil: %s not yet supported (Lua only)'):format(res.lang or '?') }
    end
    if #res.params == 0 then
        return { ('param-nil: %s — no parameters'):format(node.name or fn_id) }
    end
    local L = { ('param-nil: %s — inferred parameter nilability'):format(node.name or fn_id), '' }
    local nconf = 0
    for _, p in ipairs(res.params) do
        local mark = p.conflict and '⚠' or ' '
        if p.conflict then nconf = nconf + 1 end
        local ann = p.annotated and (' [@param: ' .. p.annotated .. ']') or ''
        local site = p.site and (' — deref @L' .. p.site) or ''
        L[#L + 1] = ('  %s %-16s %-10s%s%s'):format(mark, p.name, p.verdict, ann, site)
    end
    L[#L + 1] = ''
    if nconf > 0 then
        L[#L + 1] = ('⚠ %d DISAGREEMENT(S) with the annotations — inferred non-nil-required vs'):format(nconf)
        L[#L + 1] = '  a nilable `?` param (the body derefs a nil the type permits), or the'
        L[#L + 1] = '  reverse (a defended param the type forbids nil for). A real defect on one side.'
    else
        L[#L + 1] = '(required = an unguarded deref / assert assumes non-nil; optional = every'
        L[#L + 1] = ' deref is guarded / short-circuited; unknown = never dereferenced, or reassigned.'
        L[#L + 1] = ' Where a `---@param` annotation exists, a mismatch is flagged ⚠.)'
    end
    return L
end

--- The lens surface (:CartographDevirt): dispatch sites the narrowing facts can turn
--- static, and the gap the VM still gates.
function M.devirt_report(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return { 'devirt: no such node' } end
    local res = M.devirt(store, fn_id)
    if res.unsupported then
        return { ('devirt: %s not yet supported (Lua only)'):format(res.lang or '?') }
    end
    local s = res.summary
    if #res.sites == 0 then
        return { ('devirt: %s — no concretely-typed dispatch receivers (of %d method call(s))')
            :format(node.name or fn_id, s.method_calls or 0) }
    end
    local L = { ('devirt: %s — %d method call(s), %d with a concrete-typed receiver')
        :format(node.name or fn_id, s.method_calls, s.typed), '' }
    for _, d in ipairs(res.sites) do
        if d.status == 'certified' then
            L[#L + 1] = ('  L%-4d %s:%s()  →  %s   [certified: %s]')
                :format(d.line, d.recv, d.method, d.target, show_kind(d.fact))
        else
            L[#L + 1] = ('  L%-4d %s:%s()  ~  candidate (%s)'):format(d.line, d.recv, d.method, d.why)
        end
    end
    L[#L + 1] = ''
    L[#L + 1] = ('%d certified (dispatch resolved to a stdlib target now) · %d candidate (blocked')
        :format(s.certified, s.candidate)
    L[#L + 1] = 'on VM receiver typing). A certified site is sound: `s:m()` on a string always'
    L[#L + 1] = 'dispatches to string.m. The candidate count is the devirt gap the VM would close.'
    return L
end

--- LUA: what a LOCAL'S OWN DEFINITION proves at `site` (CART-1668) — `local t = {}` and never assigned again is a
--- table at every later use. Sound by construction: the NEAREST binding of a name, walking out from the site through
--- its enclosing blocks (earlier sibling statements only — they ran before it); a parameter, a `for` variable or a
--- `local function` met first BLOCKS the name (no fact); a name that is the target of a plain assignment ANYWHERE in
--- the function — nested closures included, `function () t = nil end` — has none; and the initializer must evaluate
--- as a CLOSED CONSTANT (no name read, no call: `{}`, `"x"`, `1`), its type is the fact. -> { [name] = 'type:T' }
-- (lua's binder kinds, per language: facts_at calls this only for lua — ruby has no declaration statement, a name
-- is bound by its first assignment, which this reading of `local` does not model)
local DEF_KINDS = { lua = { decl = 'variable_declaration', asg = 'assignment_statement', fdecl = 'function_declaration' } }
function M._lua_def_kinds(site, fn, text)
    local K = DEF_KINDS.lua
    local seen = {} -- name -> the initializer node | false (a binder that proves nothing)
    local function bind(name, value) if seen[name] == nil then seen[name] = value or false end end
    local function names_in(n, out)
        for _, c in tsutil.inamed, n, -1 do
            if c:type() == 'identifier' then out[#out + 1] = vim.treesitter.get_node_text(c, text) end
        end
        return out
    end
    local child, anc = site, site:parent()
    while anc do
        local t = anc:type()
        if t == 'block' or t == 'chunk' then
            -- (earlier siblings, nearest first)
            local prev = child:prev_named_sibling()
            while prev do
                if prev:type() == K.decl then
                    local asg = prev:named_child(0)
                    if asg and asg:type() == K.asg then
                        local vl, el = asg:named_child(0), asg:named_child(1)
                        local vals = {}
                        for _, v in tsutil.inamed, el, -1 do vals[#vals + 1] = v end
                        local names = names_in(vl, {})
                        for i = #names, 1, -1 do bind(names[i], #vals == #names and vals[i]) end
                    else
                        for _, nm in ipairs(names_in(prev, {})) do bind(nm, false) end -- `local x` (no value)
                    end
                elseif prev:type() == K.fdecl then
                    local nm = prev:field('name')[1]
                    if nm then bind(vim.treesitter.get_node_text(nm, text), false) end
                end
                prev = prev:prev_named_sibling()
            end
        elseif t == 'for_statement' then
            local clause = anc:field('clause')[1] or anc:named_child(0)
            if clause then for _, nm in ipairs(names_in(clause, {})) do bind(nm, false) end end
        end
        if anc:id() == fn:id() then
            local ps = fn:field('parameters')[1]
            if ps then for _, nm in ipairs(names_in(ps, {})) do bind(nm, false) end end
            break
        end
        child, anc = anc, anc:parent()
    end
    -- (a plain assignment anywhere in the function, closures included, revokes the definition)
    local assigned = {}
    local function scan(n)
        for _, c in tsutil.inamed, n, -1 do
            if c:type() == K.asg and n:type() ~= K.decl then
                local vl = c:named_child(0)
                if vl then for _, nm in ipairs(names_in(vl, {})) do assigned[nm] = true end end
            end
            scan(c)
        end
    end
    scan(fn)
    local out = {}
    for name, value in pairs(seen) do
        if value and not assigned[name] then
            local src = vim.treesitter.get_node_text(value, text)
            -- (no call: a literal's method — `("x"):rep(1e10)` — reads no name and still runs)
            local chunk = not src:find('[(:]') and loadstring('return ' .. src)
            if chunk then
                local read = false
                setfenv(chunk, setmetatable({}, { __index = function () read = true end }))
                local okc, c = pcall(chunk)
                if okc and not read and c ~= nil then out[name] = 'type:' .. type(c) end
            end
        end
    end
    return out
end

--- The narrowing facts AT A POSITION of `text` (a file of the graph, read as it is NOW): the dominating guards of the
--- node there, RAW kinds (truthy is not collapsed to non-nil — `false` is excluded by truthy only). A rewrite asks it
--- whether a site's operand can take a value its rule treats differently (byexample, CART-1668). The innermost
--- function holding the position must be a node of the graph: its flow record is what kills a reassigned var's facts,
--- and without it no fact is sound — nil then, never an empty env read as "nothing narrowed".
--- -> { [path] = kind } | nil, why
--- CALL-STALING CENSUS (CART-1677, a diagnostic): a field-path fact (`A.x`, depth >= 1) dies wherever a call anywhere in
--- the function receives `A` — `foo(A)`, `A:m()` — whatever the callee does. For one function: every guard fact on a
--- field path at every statement, how many staling kills, how many ONLY calls kill, and of those how many the callees'
--- EFFECT SUMMARIES clear — every covering call resolved to a callee that does not mutate that argument (no pwx at the
--- position, an argument counted with a method's receiver as 1, as argv does) and carries no hedge; `pure` = every
--- covering callee pure. `sums` = effects.summaries(store), `sites` = store.topo():sites(fn_id).
--- -> { facts, killed, by_calls_only, cleared_index, cleared_pure, unresolved }
function M._call_kill_census(store, fn_id, sums, sites)
    local out = { facts = 0, killed = 0, by_calls_only = 0, cleared_index = 0, cleared_pure = 0, unresolved = 0,
        cleared_position = 0, cleared_position_or_index = 0, killers = {} }
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return out end
    local lang = EXT_LANG[node.file:match('%.(%w+)$') or '']
    if lang ~= 'lua' then return out end
    local src = table.concat(store.content(node) or {}, '\n')
    local fn = fn_node(node, src, lang)
    if not fn then return out end
    local classify = gated_classify(vocab[lang], type_is_shadowed(lang, node))
    local mutated = mutated_of(node)
    local stale = field_unstable_of(fn, src)
    local callrec = require 'cartograph.callrec'
    local E = require 'cartograph.effects'
    -- the call record of a call node: same line, nearest column
    local function record_of(cn)
        local r, c0 = cn:start()
        local best, bd
        for _, c in ipairs(sites or {}) do
            if callrec.line(c) == r then -- (callrec.line is 0-based, as the node's row)
                local at = c.at and require('cartograph.at').sc(c.at) or 0
                local d = math.abs(at - c0)
                if not bd or d < bd then best, bd = c, d end
            end
        end
        return best
    end
    local verdict = {} -- call node id .. ':' .. argi -> 'index' | 'pure' | false
    local function cleared(e)
        local key = e.call:id() .. ':' .. e.argi
        if verdict[key] ~= nil then return verdict[key] end
        local c = record_of(e.call)
        local to = c and callrec.to(c)
        local s = to and sums[to]
        local v = false
        local pos = c and (e.argi == 0 and 1 or (e.argi + (callrec.method(c) and 1 or 0)))
        if s then
            if not s.h and not (s.pwx and s.pwx[pos]) then
                -- ('strict': no module-state write either — a callee writing module state could reach A through an
                -- alias stored there before this function ran)
                v = E.purity(store, to) == 'pure' and 'pure' or (next(s.w or {}) == nil and 'strict' or 'index')
            end
        elseif c and not to then
            -- (an UNRESOLVED call into a builtin the signature registry knows — type, ipairs, string.format —
            -- writes only the arguments its signature lists in `w`: table.sort writes its first)
            local sig = E.sig_of('lua', callrec.full(c) or callrec.callee(c), callrec.method(c))
            if sig then
                local writes = false
                for _, wi in ipairs(sig.w or {}) do if wi == pos then writes = true end end
                if not writes then v = 'strict' end -- (a builtin reaches no module table through its other arguments)
            else
                out.unresolved = out.unresolved + 1
            end
        else
            out.unresolved = out.unresolved + 1
        end
        verdict[key] = v
        return v
    end
    local seen = {}
    local function visit(n)
        for _, c in tsutil.inamed, n, -1 do
            if STMT_BLOCK[c:type()] then
                for _, stmt in tsutil.inext, c, -1 do
                    if stmt:named() and not tsutil.is_comment(stmt) then
                        for _, g in ipairs(cfg.guards_over(stmt, src)) do
                            for _, f in ipairs(classify(g.cond, src, not g.neg)) do
                                local k = stmt:id() .. f.var
                                if (f.depth or 0) >= 1 and not mutated[f.root] and not seen[k] then
                                    seen[k] = true
                                    out.facts = out.facts + 1
                                    local any, other, calls = false, false, {}
                                    for _, e in ipairs(stale) do
                                        if prefix_covers(e.prefix, e.inclusive, f.var) then
                                            any = true
                                            if e.call then calls[#calls + 1] = e else other = true end
                                        end
                                    end
                                    if any then out.killed = out.killed + 1 end
                                    if any and not other then
                                        out.by_calls_only = out.by_calls_only + 1
                                        local all, pure = true, true
                                        for _, e in ipairs(calls) do
                                            local v = cleared(e)
                                            if not v then all = false; pure = false; break end
                                            if v ~= 'pure' then pure = false end
                                        end
                                        if all then out.cleared_index = out.cleared_index + 1 end
                                        local strict = true
                                        for _, e in ipairs(calls) do local v = cleared(e); if v ~= 'pure' and v ~= 'strict' then strict = false end end
                                        if strict then out.cleared_strict = (out.cleared_strict or 0) + 1 end
                                        if pure then out.cleared_pure = out.cleared_pure + 1 end
                                        -- (POSITION: a call that starts before the guard cannot invalidate what the
                                        -- guard proves — unless a LOOP holding both brings control back around)
                                        local gb = select(3, g.cond:start())
                                        local loops = {}
                                        local a = stmt:parent()
                                        while a and a:id() ~= fn:id() do
                                            local at = a:type()
                                            if at == 'while_statement' or at == 'for_statement' or at == 'repeat_statement' then loops[#loops + 1] = a end -- @langs-ok lua-only census
                                            a = a:parent()
                                        end
                                        local function before(e)
                                            local cb = select(3, e.call:start())
                                            if cb >= gb then return false end
                                            for _, l in ipairs(loops) do
                                                local _, _, lb = l:start(); local _, _, le = l:end_()
                                                if cb >= lb and cb < le then return false end
                                            end
                                            return true
                                        end
                                        local allpos, mix = true, true
                                        for _, e in ipairs(calls) do
                                            local p = before(e)
                                            if not p then allpos = false end
                                            if not p and not cleared(e) then mix = false end
                                        end
                                        if allpos then out.cleared_position = out.cleared_position + 1 end
                                        if mix then out.cleared_position_or_index = out.cleared_position_or_index + 1
                                        else
                                            -- (what still kills it: the uncleared calls after the guard, by callee name and
                                            -- whether a summary exists for it)
                                            for _, e in ipairs(calls) do
                                                if not before(e) and not cleared(e) then
                                                    local c = record_of(e.call)
                                                    local to = c and callrec.to(c)
                                                    local nm = (c and (callrec.full(c) or callrec.callee(c)) or ('? L' .. (e.call:start() + 1) .. ' ' .. vim.treesitter.get_node_text(e.call, src):sub(1, 40))):gsub('^[%w_]+[:.]', '.')
                                                    local why = not to and 'unresolved' or (sums[to] and (sums[to].h and 'hedged' or 'mutates it') or 'no summary')
                                                    local k = why .. ' ' .. nm
                                                    out.killers[k] = (out.killers[k] or 0) + 1
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if not FN_TYPES[c:type()] then visit(c) end
        end
    end
    visit(fn)
    return out
end

--- REASSIGNMENT CENSUS (CART-1677, a diagnostic): a guard fact whose ROOT is assigned anywhere in the function dies
--- (mutated_of is flow-insensitive). For one function: guard facts at statements, how many the root's reassignment kills,
--- and how many would survive by POSITION — every assignment of the root starts before the guard's condition and no
--- loop around the point holds it (no goto in the function). -> { facts, killed, before_guard }
function M._reassign_census(store, fn_id)
    local out = { facts = 0, killed = 0, before_guard = 0 }
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return out end
    local lang = EXT_LANG[node.file:match('%.(%w+)$') or '']
    if lang ~= 'lua' then return out end
    local src = table.concat(store.content(node) or {}, '\n')
    local fn = fn_node(node, src, lang)
    if not fn then return out end
    local classify = gated_classify(vocab[lang], type_is_shadowed(lang, node))
    local mutated = mutated_of(node)
    -- the root's assignment positions (a plain `x = …`, not a `local` declaration), and any goto
    local at, has_goto = {}, false
    local function scan(n)
        for _, c in tsutil.inamed, n, -1 do
            local t = c:type()
            if t == 'goto_statement' then has_goto = true end -- @langs-ok lua-only census
            if t == 'assignment_statement' and n:type() ~= 'variable_declaration' then -- @langs-ok lua-only census
                local vl = c:named_child(0)
                for _, v in tsutil.inamed, vl or c, -1 do
                    if v:type() == 'identifier' then -- @langs-ok lua-only census
                        local nm = txt(v, src)
                        at[nm] = at[nm] or {}
                        table.insert(at[nm], select(3, v:start()))
                    end
                end
            end
            if not FN_TYPES[t] then scan(c) end
        end
    end
    scan(fn)
    local seen = {}
    local function visit(n)
        for _, c in tsutil.inamed, n, -1 do
            if STMT_BLOCK[c:type()] then
                for _, stmt in tsutil.inext, c, -1 do
                    if stmt:named() and not tsutil.is_comment(stmt) then
                        local loops = loops_of(stmt, fn)
                        for _, g in ipairs(cfg.guards_over(stmt, src)) do
                            local gb = select(3, g.cond:start())
                            for _, f in ipairs(classify(g.cond, src, not g.neg)) do
                                local k = stmt:id() .. f.var
                                if not seen[k] then
                                    seen[k] = true
                                    out.facts = out.facts + 1
                                    if mutated[f.root] then
                                        out.killed = out.killed + 1
                                        local ok = not has_goto and at[f.root] ~= nil
                                        for _, b in ipairs(at[f.root] or {}) do
                                            if b >= gb then ok = false end
                                            for _, l in ipairs(loops) do if b >= l[1] and b < l[2] then ok = false end end
                                        end
                                        if ok then out.before_guard = out.before_guard + 1 end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if not FN_TYPES[c:type()] then visit(c) end
        end
    end
    visit(fn)
    return out
end

function M.facts_at(store, rel, text, row, col)
    local lang = EXT_LANG[rel:match('%.(%w+)$') or '']
    if not lang or not (vocab[lang] and VERB_LANG.narrow[lang]) then return nil, 'no narrowing vocabulary for ' .. rel end
    local ok, parser = pcall(vim.treesitter.get_string_parser, require('cartograph.parseview').view(text, lang), lang)
    if not ok or not parser then return nil, 'no parser' end
    local root = parser:parse()[1]:root()
    local site = root:named_descendant_for_range(row, col, row, col)
    local fn = site
    while fn and not FN_TYPES[fn:type()] do fn = fn:parent() end
    if not fn then return nil, 'the position is at file scope: no function, no guards' end
    local fsl = fn:start()
    local node, twice
    for _, n in ipairs(store.by_file and store.by_file[rel] or {}) do
        if n.range and at.sl(n.range) == fsl then twice = node ~= nil; node = node or n end
    end
    if not node then return nil, 'the enclosing function is no node of the graph (its reassignments are unknown)' end
    if twice then return nil, 'two definitions start on the enclosing function\'s line: which one holds the position is not known' end
    local classify = gated_classify(vocab[lang], type_is_shadowed(lang, node))
    local env = env_of(site, text, classify, mutated_of(node), field_unstable_of(fn, text, call_harmless(store, node), interim_for(store, node)))
    if lang == 'lua' then
        for name, kind in pairs(M._lua_def_kinds(site, fn, text)) do
            if kind_rank(kind) > kind_rank(env[name]) then env[name] = kind end
        end
    end
    return env
end

return M
