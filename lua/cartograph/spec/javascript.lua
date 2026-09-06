-- The JAVASCRIPT language spec (L0 grammar binding + L1 name model)
-- extracted from the engine ([[cartograph-spec-layering]] P1). Pure motion.

-- @langs javascript typescript tsx
-- NOT just javascript, despite the filename: treesitter.lua derives the typescript
-- and tsx specs FROM this one (`M.spec.typescript = tbl_extend({}, M.spec.javascript)`),
-- so it deliberately names TS-only nodes such as `public_field_definition`. The audit
-- found that by flagging exactly that comparison against a javascript-only claim —
-- the file's real language set was wider than its name and nothing said so.

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text

-- ONE owner for "what is a function scope here" — the spec field below and the
-- local-shadow walk inside `local_decls` both read this. They were two separate
-- literals that happened to agree; a set with two copies is a set that will
-- eventually disagree with itself (CART-0306). The generator forms are new:
-- omitting them made a node inside `function* g(){}` resolve to the OUTER
-- function, which is simply the wrong answer.
local FN_TYPES = {
    function_declaration = true, method_definition = true,
    arrow_function = true, function_expression = true,
    generator_function = true, generator_function_declaration = true,
}

-- IS THIS MENTION A WRITE? (CART-0532) The largest population of the whole arc:
-- ghost carries 7804 .js + 942 .ts var nodes and 34577 + 1279 use edges, every one
-- of them with no rw / gw / gp / flds. One spec covers js, ts and tsx.
--
-- ★ AND I NEARLY CONCLUDED JAVASCRIPT WAS INERT, from the small corpora — jquery
-- has 0 var nodes and mootools 7. That is the zig mistake in reverse (CART-0538):
-- judging a language by whichever corpus happens to be named for it. ghost is the
-- one that answers.
local function js_is_write(c, n)
    local cur, p = c, n
    while p do
        local pt = p:type()
        if pt == 'member_expression' then
            cur, p = p, p:parent() -- `o.prop = v`, nesting through `o.inner.deep`
        elseif pt == 'subscript_expression' then
            -- `a[i] = v` writes a; the INDEX reads — and js does NOT wrap the
            -- index (unlike cpp's subscript_argument_list), so both mentions
            -- arrive here and the object test is what separates them
            if p:field('object')[1] ~= cur then return false end
            cur, p = p, p:parent()
        elseif pt == 'object_pattern' or pt == 'array_pattern'
            or pt == 'object_assignment_pattern' or pt == 'rest_pattern'
            or pt == 'pair_pattern' then
            -- destructuring TARGETS: `({q} = o)` · `[w] = a` · `{a: b} = o`.
            -- The same node types appear under a variable_declarator for
            -- `const {q} = o`, which is a BINDING — climbing and then testing the
            -- top is what tells the two apart.
            cur, p = p, p:parent()
        elseif pt == 'parenthesized_expression' then
            cur, p = p, p:parent() -- `({q} = o)` needs the parens to be transparent
        else
            break
        end
    end
    if not p then return false end
    local pt = p:type()
    if pt == 'assignment_expression' or pt == 'augmented_assignment_expression' then
        return p:named_child(0) == cur -- js spells `=` and `+=` as DIFFERENT types
    elseif pt == 'update_expression' then
        return true -- g++ / --g
    end
    -- variable_declarator (let/const/var, incl. destructuring) BINDS
    return false
end

-- ★★★ THE DETERMINING CALL OF A SET-ONCE LOCAL (CART-0800). `resolve_returns` is
-- a fixpoint over calls: it follows `c.rt` — the POSITION of the call whose return
-- value this call is invoked on — to that call's target, reads the target's `ret`,
-- and resolves `ret.member`. It has shipped unfed on JS because nothing ever set
-- `rt`, and `rt` comes from `spec.local_ret`, which only zig declared.
-- So `const stub = sinon.stub(); stub.returns(...)` had no link between the two
-- statements at all. This builds it, modelled on zig_local_retpos.
-- ⚠ SET-ONCE ONLY. A name declared twice in the same function is recorded as
-- `false` — ambiguous — because the second binding may carry a different type and
-- a wrong `rt` propagates through the fixpoint rather than merely failing.
-- ⚠ AND PER-FUNCTION, not per-file: two functions may each bind `res` to a
-- different call, and merging them would cross the streams.
local js_ret_map, js_ret_src
local JS_FN = { function_declaration = true, method_definition = true,
    arrow_function = true, function_expression = true, generator_function = true,
    generator_function_declaration = true }

local function build_js_ret_map(tsroot, src)
    local map = {}
    local function walk(n, curfn)
        if JS_FN[n:type()] then curfn = n end
        if n:type() == 'variable_declarator' and curfn then
            local nm = n:field('name')[1]
            local val = n:field('value')[1]
            -- `const x = await f()` is the dominant JS shape; unwrap it
            if val and val:type() == 'await_expression' then val = val:named_child(0) end
            if nm and nm:type() == 'identifier' and val
                and val:type() == 'call_expression' then
                local fe = val:field('function')[1]
                local namenode
                if fe and fe:type() == 'identifier' then namenode = fe
                elseif fe and fe:type() == 'member_expression' then
                    namenode = fe:field('property')[1]
                end
                if namenode then
                    local key, fid = node_text(nm, src), curfn:id()
                    map[fid] = map[fid] or {}
                    if map[fid][key] == nil then
                        local r, c = namenode:start()
                        map[fid][key] = { r = r, c = c }
                    else map[fid][key] = false end -- rebound → ambiguous
                end
            end
        end
        for c in n:iter_children() do walk(c, curfn) end
    end
    walk(tsroot, nil)
    return map
end


return {
    is_write = js_is_write,
    -- the PREFILTER: every immediate parent type a write mention can have.
    -- Without it the classifier is never invoked (v147 shipped that mistake).
    write_gate = { assignment_expression = true,
        augmented_assignment_expression = true, update_expression = true,
        member_expression = true, subscript_expression = true,
        object_pattern = true, array_pattern = true,
        object_assignment_pattern = true, rest_pattern = true,
        pair_pattern = true },
    -- INDEX POSITIONS (CART-0533): parent node type -> the child holding the
    -- OBJECT of a BRACKET-style access. Separate from `member_positions` because
    -- the two answer different questions: a member name is a NAME (and must not
    -- be matched against the bare-name function index), while a bracket key is an
    -- EXPRESSION and the mention inside it is a genuine value read.
    -- ★ TEN LANGUAGES SPELL ONE CONCEPT SIX WAYS — array / operand / object /
    -- value / argument / bare child 0 — which is why this is declared and not
    -- hardcoded. It was hardcoded, and java's `array_access` was absent, so
    -- `atanTab[i] = v` against `private static final double[] atanTab` recorded a
    -- WHOLE-VAR write: a claimed REBIND of a `final` field, which is a compile
    -- error. 47 of those in libs alone.
    index_positions = {
        subscript_expression = 'object', -- t[k] · shared by ts/tsx
    },
    -- MEMBER-NAME POSITIONS (CART-0529): parent node type -> the child holding a
    -- MEMBER NAME, i.e. a name that is reached THROUGH A RECEIVER. Same shape as
    -- `call_positions`, and read for the opposite purpose: a mention here must
    -- NOT be matched against the corpus-wide unique-function index, because a
    -- bare name match says nothing about which object the receiver holds.
    -- Measured on wow_addons: 724 of 2988 reg occurrences (24.2%) sat in member
    -- position, and the sample held outright cross-file fabrication
    -- (`db.ResetProfile = DBObjectLib.ResetProfile` pointing at an unrelated
    -- addon's local ResetProfile).
    -- ★ BRACKET FORMS ARE DELIBERATELY ABSENT (`t[k]`, `t["k"]`, subscript_*):
    -- their key is an EXPRESSION, so the mention inside is a genuine value read
    -- and vetoing it would lose a real reference. Only dot-style member NAMES
    -- belong here.
    member_positions = {
        member_expression = 'property', -- o.NAME -- shared by ts/tsx
    },
    -- CALL POSITIONS (CART-0499): parent node type -> which child holds the
    -- CALLEE NAME, as a field name or a named-child index. Replaces a
    -- hardcoded four-name or-chain inline in the provider that php, java,
    -- bash, rust macros, ruby and haskell were all missing from -- so a call
    -- to a corpus-unique function became a fn REFERENCE and minted a `reg`
    -- edge ("kept alive by top-level DATA"), a different fact. 96.6% of
    -- mantisbt's reg occurrences were mislabelled calls.
    call_positions = {
        call_expression = 'function', -- foo(1) -- shared by ts/tsx
    },
        exts = { 'js', 'mjs', 'cjs', 'jsx' }, -- the JS grammar handles JSX
        -- BINDER NODES: see spec/lua.lua. `for (const g of t)` binds g as a direct
        -- identifier child; a classic `for` binds inside its initializer.
        binders = {
            { node = 'for_in_statement' },
            { node = 'for_statement', child = 'lexical_declaration' },
        },
        -- MEMBER-TARGET FUNCTION LITERALS. MEASURED (tools/assigndef.lua):
        -- `X.y = function(){}` minted NOTHING, while the declarator form
        -- (`const f = function(){}`) and the prototype form both did — worth 6.4% of
        -- jquery's unresolved calls and 1.9% of ghost's (jQuery.extend,
        -- jQuery.Callbacks, opt.complete). Lua has always minted the same shape
        -- (`M.f = function() end`), so this closes a gap BETWEEN TWO FRONT ENDS rather
        -- than adding a new kind of claim, and it is no more aggressive than the
        -- object-literal `pair` patterns already here (`{ complete: () => {} }` mints
        -- a bare `complete`; the assignment form at least carries its receiver).
        -- ONE pattern now serves the prototype case too: the collapse
        -- (`X.prototype.m` -> `X.m`) lives in qualify and keys on the literal
        -- `.prototype.` in the name, so the old `#eq? @_pp "prototype"` gate is no
        -- longer what distinguishes the two forms.
        -- Note a CHAINED assignment (`a.b = c.d = function(){}`) still mints only the
        -- INNERMOST name: the outer right-hand side is an assignment_expression, not a
        -- function. jQuery's `jQuery.extend = jQuery.fn.extend = function(){}` is that
        -- shape, so `jQuery.fn.extend` is minted and `jQuery.extend` is not — one def
        -- per function NODE, which is the constraint that keeps a def a fact.
        functions = [=[
            (function_declaration name: (identifier) @name) @def
            (method_definition name: (property_identifier) @name) @def
            (variable_declarator name: (identifier) @name value: (arrow_function) @def)
            (variable_declarator name: (identifier) @name value: (function_expression) @def)
            (pair key: (property_identifier) @name value: (arrow_function) @def)
            (pair key: (property_identifier) @name value: (function_expression) @def)
            (arguments (arrow_function) @adef)
            (arguments (function_expression) @adef)
            ; ANY member target, not just X.prototype.m — see the note above the field
            (assignment_expression
                left: (member_expression) @name
                right: (function_expression) @def)
            (assignment_expression
                left: (member_expression) @name
                right: (arrow_function) @def)
        ]=],
        calls = [=[
            (call_expression function: (identifier) @name) @call
            (call_expression function: (member_expression) @name) @call
        ]=],
        vars = [=[
            (program (lexical_declaration
                (variable_declarator name: (identifier) @vname value: (_) @value) @vdef))
            (program (variable_declaration
                (variable_declarator name: (identifier) @vname value: (_) @value) @vdef))
        ]=],
        -- V2 ctor-typing: `const o = new C(...)` (ANYWHERE, incl. in-function)
        -- binds o to class C; resolve_local_ctor types o.member → C.member. The
        -- callee stored is the bare class C (not lua's `C.new` convention) → the
        -- JS cut in resolve_local_ctor keys on is_class[callee] directly.
        -- the receiver is a set-once local bound to a call: hand
        -- `resolve_returns` the position of that determining call.
        local_ret = function (calln, src)
            if calln:type() ~= 'call_expression' then return nil end
            local fe = calln:field('function')[1]
            if not fe or fe:type() ~= 'member_expression' then return nil end
            local obj = fe:field('object')[1]
            if not (obj and obj:type() == 'identifier') then return nil end
            if src ~= js_ret_src then
                local r = calln
                while r:parent() do r = r:parent() end
                js_ret_map = build_js_ret_map(r, src)
                js_ret_src = src
            end
            local name = node_text(obj, src)
            local p = calln:parent()
            while p do
                if JS_FN[p:type()] then
                    local e = js_ret_map[p:id()]
                    local hit = e and e[name]
                    if hit then return hit end
                end
                if p:type() == 'program' then return nil end
                p = p:parent()
            end
        end,
        ctor_query = [=[
            (variable_declarator name: (identifier) @cvar
                value: (new_expression constructor: (identifier) @cctor))
            (assignment_expression left: (identifier) @cvar
                right: (new_expression constructor: (identifier) @cctor))
        ]=],
        -- THE LOCALITY VETO for the member-target pattern above. `X.y = function(){}`
        -- is a definition worth naming when X is a module namespace (`jQuery.param`,
        -- `module.exports.x`) and JUNK when X is a function-local object: MEASURED on
        -- jquery, `opt.complete = function(){}` inside jQuery.speed minted a def whose
        -- tail then answered every bare `complete()` callback call in the corpus —
        -- four confident wrong resolutions replacing four honest refusals.
        -- A query cannot ask this, so the spec does: is the receiver's ROOT bound as a
        -- parameter or a local declaration in an enclosing function?
        -- `this.x = …` is deliberately NOT vetoed — it is the pre-class instance-method
        -- form, and its receiver is not a local binding.
        skip_def = function (defn, _, src)
            local asg = defn:parent()
            if not (asg and asg:type() == 'assignment_expression') then return false end
            local lhs = asg:field('left')[1]
            if not (lhs and lhs:type() == 'member_expression') then return false end
            -- NEVER veto the prototype form. It minted before this veto existed, and a
            -- prototype assignment defines a CLASS method however its constructor
            -- variable is scoped (`var K = function(){}; K.prototype.m = …` inside a
            -- module closure is the normal pre-ES6 idiom). Without this the veto
            -- REMOVED 62 pre-existing defs on ghost and 4 on mootools — a change that
            -- is supposed to be purely additive.
            if node_text(lhs, src):find('%.prototype%.') then return false end
            -- the receiver ROOT: the leftmost identifier of the member chain
            local root = lhs
            while root and root:type() == 'member_expression' do
                root = root:field('object')[1]
            end
            -- `this.x = function(){}` is vetoed too. It IS the pre-class instance-method
            -- idiom, but the def name `this.x` names no owner — it is a key nothing can
            -- match on purpose, and its TAIL then answers unrelated calls. MEASURED on
            -- mootools: `this.$each = function(){}` has tail `each` (a `$` is not a word
            -- character), so it captured bare `each(…)` calls corpus-wide. Naming these
            -- properly needs the enclosing constructor's name — a separate piece of work.
            if root and root:type() == 'this' then return true end
            if not (root and root:type() == 'identifier') then return false end
            local want = node_text(root, src)
            local fn_types = FN_TYPES
            -- A POSITIONAL IDENTIFIER PARAMETER IS NOT TREATED AS LOCAL, which
            -- fn_locals already argues for the local-shadow gate: in the AMD/IIFE shape
            -- every pre-ES6 library uses, `define(["./core"], function (jQuery) { … })`
            -- passes the namespace itself as a positional parameter. Vetoing those
            -- removed 36 of jquery's 52 new defs — the whole `jQuery.*` surface, i.e.
            -- most of the measured value. A DESTRUCTURED param has no such reading and
            -- is vetoed below.
            local seen_fn = false
            local up = asg:parent()
            while up do
                if fn_types[up:type()] then
                    seen_fn = true
                    local ps = up:field('parameters')[1]
                    if ps then
                        for p in ps:iter_children() do
                            local pt = p:type()
                            if (pt == 'object_pattern' or pt == 'array_pattern')
                                and node_text(p, src):find(
                                    '%f[%w_]' .. want .. '%f[^%w_]') then
                                return true
                            end
                        end
                    end
                end
                up = up:parent()
            end
            if not seen_fn then return false end -- top level: not a local
            -- a local DECLARATION (`var opt = …` / `const o = {}`) anywhere in an
            -- enclosing function body. Scanning the enclosing function's TEXT for a
            -- declaration of that name is deliberately coarse in the SAFE direction:
            -- a false "local" only withholds a def, never invents one.
            -- a local DECLARATION in an enclosing function. STRUCTURAL, not a text
            -- scan: a scan for `var <name>` misses every declarator after the first in
            -- a comma-separated list, which is how jquery declares most of its locals
            -- (`var opts = …, hooks, oldfire`) — it let `hooks.empty.fire`,
            -- `elemData.handle` and `xhr.onreadystatechange` through on the first try.
            local function declares(fnnode)
                local body = fnnode:field('body')[1]
                if not body then return false end
                local found = false
                local function walk(n)
                    if found then return end
                    for c in n:iter_children() do
                        if found then return end
                        if c:named() then
                            local ct = c:type()
                            if fn_types[ct] then -- a nested fn: its own scope
                            elseif ct == 'variable_declaration'
                                or ct == 'lexical_declaration' then
                                for d in c:iter_children() do
                                    if d:type() == 'variable_declarator' then
                                        local nm = d:field('name')[1]
                                        -- destructuring binds several names; any
                                        -- identifier leaf counts
                                        if nm and node_text(nm, src):find(
                                            '%f[%w_]' .. want .. '%f[^%w_]') then
                                            found = true; return
                                        end
                                    end
                                end
                            else walk(c) end
                        end
                    end
                end
                walk(body)
                return found
            end
            up = asg:parent()
            while up do
                if fn_types[up:type()] and declares(up) then return true end
                up = up:parent()
            end
            return false
        end,
        params_field = 'parameters',
        body_field = 'body',
        fn_types = FN_TYPES,
        -- ── DYNAMIC DISPATCH: THE MEMBER IS RUNTIME STATE (CART-0345/0344) ──
        -- `obj[k]()` selects its callee at run time — the `dynamic` rung, "a call the
        -- graph KNOWS IT CANNOT SEE", which is a different fact from `frontier`
        -- ("we failed to resolve"). Undeclared here until now, so every such call
        -- landed in frontier and any measurement of dynamic dispatch on a javascript
        -- corpus would have reported it as absent.
        -- ★ A LITERAL KEY IS NOT DYNAMIC: `obj["lit"]()` names its member in
        -- the source, and claiming we cannot see it would be a false negative
        -- FACT. Node names verified by parsing a snippet per grammar, not guessed.
        dynamic_callee_types = { subscript_expression = true },
        dynamic_callee_static_key = { string = true, number = true },
        -- ★ "MINTED" HAS TO MEAN *ALWAYS* MINTED, NOT SOMETIMES. The generator
        -- forms are never captured by the `functions` query above. But
        -- `function_expression` is worse than never — it is CONDITIONAL: minted
        -- as a variable_declarator value, a pair value, an `arguments` child or
        -- an assignment_expression right, and NOT minted anywhere else. The
        -- position that matters is the IIFE, `(function(){ … })()`, which is
        -- what jquery and ghost are built out of. Treating it as a flow stop
        -- deleted every IIFE body's rows: dfgate ghost 6986 -> 28406.
        -- A conditionally-minted type must be listed here, because the cost of
        -- being wrong is DELETED rows and the cost of being conservative is only
        -- the pre-existing over-collection into the enclosing function (CART-0308).
        -- `method_definition` goes the same way, for the same reason one step
        -- down: the query names `name: (property_identifier)`, so a `#private`
        -- or `[computed]` method is not minted. Ghost kept +440 divergences over
        -- its baseline until this was listed; jquery and mootools are pre-ES6 and
        -- had already returned to their EXACT pinned counts, which is what showed
        -- the residual was method_definition and nothing else.
        --
        -- ★★ SO JAVASCRIPT GAINS NO STOP AT ALL, and that is the honest outcome
        -- rather than a failure: this query is POSITIONAL — it mints a function by
        -- where it SITS, not by what it IS — so no js scope type is unconditionally
        -- minted except `function_declaration`, which LEGACY already stops at. A
        -- language whose def query is positional cannot support scope stops until
        -- the query does (CART-0313). The measurable win here is ruby, rust and
        -- odin, whose `method`/`function_item`/`procedure_declaration` always are.
        fn_unminted = { generator_function = true,
            generator_function_declaration = true, function_expression = true,
            method_definition = true },
        is_method = function (_, def) return def:type() == 'method_definition' end,
        -- ES6 methods carry their class: `class C { m(){} }` -> `C.m` (the JS
        -- analog of lua `C:m` / php `C::m`). A method_definition is a class
        -- member IFF its DIRECT parent is class_body — object-literal methods
        -- (`{ m(){} }`, incl. ones nested inside a class method) parent an
        -- `object`, so they stay bare, never falsely borrowing an outer class.
        -- `.` separator: aligns the key with how methods are called (obj.m),
        -- so a `ClassName.m()` reference exact-matches, while the tail index
        -- ([%w_]+$ -> `m`) still catches the unqualified `x.m()` receiver calls.
        -- Anonymous class expressions borrow their binding variable's name
        -- (`const C = class {…}`); a truly nameless class leaves methods bare.
        qualify = function (name, defn, src)
            -- pre-ES6 prototype method (pivot B4): `X.prototype.m = function` is
            -- captured with @name = the whole LHS `X.prototype.m`; collapse to the
            -- class key `X.m` (the same shape B1 gives ES6 methods, so B3
            -- this-typing / resolve_super treat a prototype "class" identically).
            -- `A.B.prototype.m` → `A.B.m`. The query's #eq? "prototype" gate means
            -- only genuine prototype assignments reach here in this form.
            local powner, pmethod = name:match('^(.+)%.prototype%.([%w_]+)$')
            if powner then return powner .. '.' .. pmethod end
            local body = defn:parent()
            -- field-arrow (`class C { m = () => {} }`): the fn's parent is the
            -- field def, whose parent is class_body — unwrap so C.m keys like a method.
            if body and (body:type() == 'field_definition'
                or body:type() == 'public_field_definition') then
                body = body:parent()
            end
            if not (body and body:type() == 'class_body') then return name end
            local cls = body:parent()
            if not cls then return name end
            local nm = cls:field('name')[1]
            local owner = nm and node_text(nm, src)
            if not owner and cls:type() == 'class' then
                local par = cls:parent() -- `const C = class {…}`
                if par and par:type() == 'variable_declarator' then
                    local vn = par:field('name')[1]
                    owner = vn and node_text(vn, src)
                end
            end
            return owner and (owner .. '.' .. name) or name
        end,
        -- in-function local declarations, for fn_locals (the local-shadow gate);
        -- df doesn't track JS locals so the destructured `const [x,setX]=…` hook
        -- setters would name-match a global without this.
        local_decls = { lexical_declaration = true, variable_declaration = true },
        -- ★ DESTRUCTURING AND IMPORTS BIND NAMES (CART-0358). Every one of them was lost:
        -- `const {k: ren} = src` gave `def=[] use=[ren,src]` — the bound name counted as a
        -- READ OF THE STATEMENT THAT DEFINES IT. Two wrong behaviours by spelling, which is
        -- why no single symptom could census the population: the SHORTHAND form vanished
        -- entirely (its binder is `shorthand_property_identifier_pattern`, in nobody's ids
        -- set) while renames, arrays and rest LEAKED AS USES. Measured on ghost: 2732
        -- patterns binding 4413 names, of which 1466 sites / 2094 names are destructured
        -- `require()` imports — the population the const-index census read as ZERO.
        --
        -- FIELD-PRECISE, from the grammar's own output, because two children of a pattern
        -- genuinely READ: `object_assignment_pattern`'s `right` and a `computed_property_name`
        -- key (reached by NOT being the `value` field of its pair_pattern, so it needs no
        -- entry — the absence of a rule is what makes it a read).
        binder_fields = {
            object_pattern = true, array_pattern = true, rest_pattern = true,
            pair_pattern = { 'value' },              -- the KEY is not a name at all
            object_assignment_pattern = { 'left' },  -- `right` is a default EXPRESSION
            -- imports. The linkage itself rides the import EDGE (the @path capture in
            -- import_query, which is unconditional), so nothing is lost by the foreign
            -- name of an aliased specifier ceasing to be a phantom local read.
            import_statement = true, import_clause = true,
            named_imports = true, namespace_import = true,
            import_specifier = { 'alias', 'name' },  -- `N2 as N3` binds N3
        },
        -- a binding target may be PARENTHESISED: `({body: b} = await x)`, the only way to
        -- destructure into existing bindings. du never needed this — its walk descends
        -- every child and meets the pattern regardless of the wrapper.
        binder_paren = 'parenthesized_expression',
        -- the shorthand PATTERN binder is a name; its object-LITERAL sibling
        -- `shorthand_property_identifier` is one letter apart and is a genuine READ that
        -- is ALSO missing — deliberately not fixed here, it moves the use axis (CART-0418).
        df_ids = { identifier = true, name = true,
            shorthand_property_identifier_pattern = true,
            -- and its LITERAL sibling, one letter shorter, which REFERENCES rather than
            -- binds: `const o = {a}` reads `a`. Both were missing, and because both sides
            -- missed the literal one the self-gate could not see it (CART-0418).
            shorthand_property_identifier = true },
        stdlib_prefixes = { 'console.', 'JSON.', 'Object.', 'Array.', 'Math.',
            'Promise.', 'window.', 'document.', 'chrome.' },
        -- the WORKSPACE PACKAGE (nearest package.json ancestor) scopes
        -- bare names: monorepo packages import across, never leak across
        scope = function (file, _, root)
            if not root then return '' end
            local dir = file:match('^(.*)/[^/]*$') or ''
            while dir ~= '' do
                if vim.uv.fs_stat(root .. '/' .. dir .. '/package.json') then
                    return dir
                end
                dir = dir:match('^(.*)/[^/]*$') or ''
            end
            return ''
        end,
        -- dom/framework vocabulary
        stdlib_names = { getAttribute = true, setAttribute = true,
            addEventListener = true, removeEventListener = true,
            querySelector = true, querySelectorAll = true,
            createElement = true, appendChild = true, dispatch = true,
            subscribe = true, push = true, pop = true, shift = true,
            slice = true, splice = true, join = true, split = true,
            filter = true, map = true, forEach = true, reduce = true,
            find = true, includes = true, indexOf = true, replace = true,
            trim = true, toString = true, concat = true, keys = true,
            values = true, entries = true, assign = true, freeze = true,
            stringify = true, parse = true, emit = true, on = true,
            off = true, once = true, get = true, set = true, has = true,
            add = true, delete = true, clear = true, next = true,
            startsWith = true, endsWith = true, some = true, every = true,
            sort = true, reverse = true, flat = true, substring = true,
            toLowerCase = true, toUpperCase = true, padStart = true,
            charAt = true,
            ['$emit'] = true, ['$on'] = true, ['$nextTick'] = true },
        litdata_types = { object = true, array = true },
        -- ESM imports + CommonJS require + dynamic import(). require/import
        -- match ONLY a lone string literal argument — computed paths stay
        -- unresolved (honest frontier, not a guess). Predicates demand
        -- iter_matches in the consumer (iter_captures ignores #eq?).
        -- @bind is the LOCAL NAME an import introduces, which is what lets a call
        -- through that name be attributed to the imported file (resolve_module_alias,
        -- and the `unread-file` disposition for a call into an opaque bundle). Only
        -- SINGLE-bind forms are captured: a default import, a namespace import, and
        -- CommonJS `const x = require(...)`. NAMED imports (`import {a, b}`) bind
        -- several names to one edge and the edge carries one `bind`, so they stay
        -- uncaptured rather than being represented wrongly — a deliberate gap, not
        -- an oversight.
        --
        -- Several patterns can match ONE import site (a namespace import matches the
        -- general form too, and a CJS require matches both the declaration and the
        -- bare-call form). The consumer dedupes on the @path NODE, so the edge set is
        -- exactly what it was before binds existed; only the bind is added.
        import_query = [=[
            (import_statement
                (import_clause [
                    (identifier) @bind
                    (namespace_import (identifier) @bind)
                ])?
                source: (string) @path)
            (lexical_declaration (variable_declarator
                name: (identifier) @bind
                value: (call_expression
                    function: (identifier) @_rq (#eq? @_rq "require")
                    arguments: (arguments . (string) @path .))))
            (call_expression
                function: (identifier) @_fn (#eq? @_fn "require")
                arguments: (arguments . (string) @path .))
            (call_expression
                function: (import)
                arguments: (arguments . (string) @path .))
        ]=],
        --- ★★★ A DESTRUCTURED IMPORT BINDS EACH NAME TO A PACKAGE MEMBER
        --- (CART-0804). `const {expect} = require('chai')` and `import {stub} from
        --- 'sinon'` bind a name that is called BARE thereafter, so the call carries
        --- no receiver and nothing connects it to the package — `expect` alone is
        --- 2242 unresolved calls on ghost, from one line repeated across the test
        --- tree. v183's pkgbind covers only the whole-namespace form
        --- (`const sinon = require('sinon')`), because its `@bind` capture is a
        --- single identifier and a destructuring pattern is not one.
        ---
        --- Returns { [local name] = member name } for the enclosing binding, or
        --- nil. The LOCAL may differ from the MEMBER (`{expect: e}`, `{stub as s}`)
        --- and both are needed: the member is what the surface can confirm, the
        --- local is what the call site says.
        ---
        --- ⚠ THIS IS A BINDING, NOT A GUESS — which is what makes it the sound half
        --- of CART-0801's argument. The syntax NAMES the package; the only thing
        --- inferred is that a destructured name is a member of it, and the caller
        --- still gates the rewrite on the profile confirming that member exists.
        import_members = function (pathn, src, text)
            local n = pathn
            for _ = 1, 4 do -- arguments -> call_expression -> declarator
                n = n and n:parent()
                if not n then return nil end
                local t = n:type()
                if t == 'variable_declarator' or t == 'assignment_expression'
                    or t == 'import_statement' then break end
            end
            if not n then return nil end
            local out, found = {}, false
            local function shorthand(id)
                local nm = text(id, src)
                if nm and nm:match('^[%w_$]+$') then out[nm] = nm; found = true end
            end
            local function pair(keyn, valn)
                local k, v = text(keyn, src), text(valn, src)
                if k and v and k:match('^[%w_$]+$') and v:match('^[%w_$]+$') then
                    out[v] = k; found = true
                end
            end
            local function walk(node)
                for ch in node:iter_children() do
                    if ch:named() then
                        local t = ch:type()
                        if t == 'shorthand_property_identifier_pattern' then
                            shorthand(ch)
                        elseif t == 'pair_pattern' then
                            -- `{ expect: e }` — key is the MEMBER, value the local
                            local k = ch:field('key')[1]
                            local v = ch:field('value')[1]
                            if k and v and v:type() == 'identifier' then pair(k, v) end
                        elseif t == 'import_specifier' then
                            -- `{ stub }` or `{ stub as s }` — alias is the local
                            local nm = ch:field('name')[1]
                            local al = ch:field('alias')[1]
                            if nm and al then pair(nm, al)
                            elseif nm then shorthand(nm) end
                        elseif t == 'object_pattern' or t == 'named_imports'
                            or t == 'import_clause' then
                            walk(ch)
                        end
                    end
                end
            end
            local tn = n:type()
            if tn == 'variable_declarator' or tn == 'assignment_expression' then
                local target = n:field('name')[1] or n:field('left')[1]
                if target and target:type() == 'object_pattern' then walk(target) end
            else
                walk(n) -- import_statement: descend to its named_imports
            end
            return found and out or nil
        end,
        resolve_import = function (path, files, from)
            path = path:gsub('^["\']', ''):gsub('["\']$', '')
            local function norm(p) -- ./ and ../ segments
                local parts = {}
                for seg in p:gmatch('[^/]+') do
                    if seg == '..' then parts[#parts] = nil
                    elseif seg ~= '.' then parts[#parts + 1] = seg end
                end
                return table.concat(parts, '/')
            end
            local function try(cand)
                cand = norm(cand)
                for _, c in ipairs({ cand, cand .. '.js', cand .. '.ts',
                    (cand:gsub('%.js$', '.ts')),
                    cand .. '/index.js', cand .. '/index.ts' }) do
                    if files[c] then return c end
                end
            end
            local dir = from:match('^(.*)/[^/]*$')
            if path:match('^[@~]/') then
                -- bundler alias ('@/x', '~/x'): the package's src/ (vite)
                -- or the app root itself (nuxt). The package.json isn't in
                -- the fileset, so walk ancestors and let existence decide
                local x = path:sub(3)
                local anc = dir
                while anc do
                    local hit = try(anc .. '/src/' .. x) or try(anc .. '/' .. x)
                    if hit then return hit end
                    anc = anc:match('^(.*)/[^/]*$')
                end
                return try('src/' .. x) or try(x)
            end
            return try(dir and (dir .. '/' .. path) or path)
        end,
}
