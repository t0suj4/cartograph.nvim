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
local FN_TYPES = {
    function_declaration = true, function_definition = true, -- lua
    method = true, singleton_method = true,                  -- ruby
}
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
local function fn_node(node, src, lang)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
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
local function field_unstable_of(fn, src)
    local stale = {} -- list of { prefix = <path str>, inclusive = bool }
    local function mark(prefix, inclusive) if prefix then stale[#stale + 1] = { prefix = prefix, inclusive = inclusive } end end
    local function walk(n)
        local t = n:type()
        -- `assignment_statement` = (variable_list) = (expression_list); `local x = …` is
        -- a `variable_declaration` wrapping one, so handling the inner form catches both.
        if t == 'assignment_statement' then
            local vlist, elist
            for c in n:iter_children() do
                -- @langs-ok lua-only: field_unstable_of gates depth-≥1 PATHS, and ruby
                -- has none by design, so this walk is never reached for ruby facts
                if c:type() == 'variable_list' then vlist = c
                -- @langs-ok lua-only, same reason
                elseif c:type() == 'expression_list' then elist = c end
            end
            if vlist then for tgt in vlist:iter_children() do -- field-write targets
                -- @langs-ok lua-only, same reason: ruby facts are all depth 0
                if tgt:type() == 'dot_index_expression' then
                    local p = path_of(tgt, src); if p then mark(p.path, true) end -- A.f inclusive
                -- @langs-ok lua-only, same reason as above
                elseif tgt:type() == 'bracket_index_expression' then
                    local b = path_of(tgt:named_child(0), src); if b then mark(b.path, false) end -- A[?] → A.*
                end
            end end
            if elist then for v in elist:iter_children() do -- alias RHS (identifier or field path)
                if v:named() then local p = path_of(v, src); if p then mark(p.path, false) end end -- y = A → A.*
            end end
        elseif t == 'function_call' then -- A passed as arg, or A:m() receiver
            local args = n:field('arguments')[1]
            if args then for a in args:iter_children() do
                if a:named() then local p = path_of(a, src); if p then mark(p.path, false) end end
            end end
            local callee = n:named_child(0)
            -- @langs-ok lua-only staling walk; ruby has no depth-≥1 facts to stale
            if callee and callee:type() == 'method_index_expression' then
                local p = path_of(callee:named_child(0), src); if p then mark(p.path, false) end
            end
        end
        for c in n:iter_children() do
            if c:named() and not FN_TYPES[c:type()] then walk(c) end -- nested fns = own scope
        end
    end
    walk(fn)
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
local function fact_live(f, mutated, stale)
    if mutated[f.root] then return false end
    if (f.depth or 0) >= 1 then
        for _, e in ipairs(stale) do
            if prefix_covers(e.prefix, e.inclusive, f.var) then return false end
        end
    end
    return true
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
    local funstable = field_unstable_of(fn, src)

    local points, seenguard = {}, {}
    local function visit(n)
        for c in n:iter_children() do
            if c:named() then
                if STMT_BLOCK[c:type()] then
                    for stmt in c:iter_children() do
                        if stmt:named() and not tsutil.is_comment(stmt) then
                            local env = {}
                            for _, g in ipairs(cfg.guards_over(stmt, src)) do
                                for _, f in ipairs(classify(g.cond, src, not g.neg)) do
                                    if fact_live(f, mutated, funstable) then
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
    for _, g in ipairs(cfg.guards_over(node, src)) do
        for _, f in ipairs(classify(g.cond, src, not g.neg)) do
            if fact_live(f, mutated or {}, funstable or {}) then
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
    local funstable = field_unstable_of(fn, src)
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
        for c in n:iter_children() do
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
    local funstable = field_unstable_of(fn, src)
    -- determine() handles only SINGLE predicates, so a conjunction `cond and other()`
    -- (where only `cond` is known) is correctly NOT flagged — the other conjunct still
    -- gates the branch.
    local checks = {}
    local function visit(n)
        for c in n:iter_children() do
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
    local mutated, funstable = mutated_of(node), field_unstable_of(fn, src)

    local sites = {}
    local summary = { method_calls = 0, typed = 0, certified = 0, candidate = 0 }
    local function visit(n)
        for c in n:iter_children() do
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

return M
