-- The RUST language spec (L0 grammar binding + L1 name model)
-- extracted from the engine ([[cartograph-spec-layering]] P1). Pure motion.

-- @langs rust — a spec IS one grammar's mapping, so every node type here is
-- rust's by construction.

-- IS THIS MENTION A WRITE? (CART-0532) The sixth language, and the second
-- smallest population — 206 use edges on the rust corpus. Declared as a PAIR
-- (is_write + write_gate), which the suite now requires: v147 shipped a
-- classifier without its gate, so it was never called, and because `wmode` is
-- `spec.is_write ~= nil` the axis switched on anyway and reported everything as a
-- READ — atlas then minted `const` over a write pass that had not run.
-- MEMO CALLS (CART-1585): a write of their receiver that fills an ABSENT slot only — set-once by the method's contract:
-- `CELL.get_or_init(f)` (OnceCell / OnceLock), `opt.get_or_insert_with(f)` (Option), and the entry API's
-- `m.entry(k).or_insert(v)` / `or_insert_with` / `or_default` — `entry(k).and_modify(..)` updates a PRESENT key and
-- stays out. `fn` is the call's callee chain `X.method`, X the receiver.
local RS_MEMO = { get_or_init = true, get_or_try_init = true, get_or_insert = true, get_or_insert_with = true }
local RS_OR_INSERT = { or_insert = true, or_insert_with = true, or_insert_with_key = true, or_default = true }
local function rs_memo_call(p, fn, src)
    -- (a field_expression whose parent is a call IS its callee, and a call under a field_expression IS its value:
    -- the arguments sit in their own node)
    if not (src and p and p:type() == 'call_expression' and fn:type() == 'field_expression') then return false end
    local text = require('cartograph.spec.tsutil').node_text
    local nm = fn:field('field')[1]
    nm = nm and text(nm, src)
    if RS_MEMO[nm] then return true end
    if nm ~= 'entry' then return false end
    local f2 = p:parent() -- `X.entry(k)` is the VALUE of `.or_insert`, whose parent is the call
    if not (f2 and f2:type() == 'field_expression') then return false end
    local m2 = f2:field('field')[1] -- (and `.or_insert` is called: an uncalled method is no rust value)
    return m2 ~= nil and RS_OR_INSERT[text(m2, src)] == true
end
local function rust_is_write(c, n, src)
    local cur, p = c, n
    while p do
        local pt = p:type()
        if pt == 'field_expression' then
            -- `s.field = v`, and it NESTS: `s.inner.deep = v` is a
            -- field_expression whose own child is one, so both halves of every
            -- level ride the chain
            cur, p = p, p:parent()
        elseif pt == 'index_expression' then
            if p:named_child(0) ~= cur then return false end -- the INDEX reads
            cur, p = p, p:parent()
        elseif pt == 'unary_expression' then
            cur, p = p, p:parent() -- `*p = v`: the deref rides
        else
            break
        end
    end
    if not p then return false end
    local pt = p:type()
    -- (the receiver IS the mention: its slot, `'[]'` — the capture would name the method the field)
    if rs_memo_call(p, cur, src) then return true, cur:field('value')[1] == c and '[]' or nil, true end -- (and READS: it tests the slot)
    if pt == 'assignment_expression' or pt == 'compound_assignment_expr' then
        -- rust spells `=` and `+=` as DIFFERENT node types, unlike go and java
        return p:named_child(0) == cur
    end
    -- let_declaration BINDS (and carries its own `mutable_specifier` child, so
    -- `let mut x = 1` is still a binding); rust has no ++/--.
    return false
end

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text
local inext = tsutil.inext

-- ── THE GUARD GRAMMAR (CART-1582) ─────────────────────────────────────────────────────────────────────────────────
-- rust's lazy initialisation: `if X.is_none() { X = Some(..) }`, `if X == None`, `if !X`, and the else arm of
-- `if X.is_some()` / `if X != None` / `if X`. `None` is an identifier to the grammar. Module state is rare in rust
-- (`static mut`, unsafe) — its memos live in struct fields, which the write axis does not model (CART-1575).
local chain_eq, optext_is, unparen = tsutil.chain_eq, tsutil.optext_is, tsutil.unparen
-- `X.<method>()` with no arguments -> X, when method is one of `names`
local function rs_method_on(n, names, src)
    if n:type() ~= 'call_expression' then return nil end
    local f, args = n:field('function')[1], n:field('arguments')[1]
    if not (f and f:type() == 'field_expression' and args and args:named_child_count() == 0) then return nil end
    local m = f:field('field')[1]
    if not (m and names[node_text(m, src)]) then return nil end
    return f:field('value')[1]
end
local function rs_none_operand(n, ops, src)
    if n:type() ~= 'binary_expression' or not optext_is(n, nil, ops) then return nil end
    local a, b = unparen(n:named_child(0)), unparen(n:named_child(1))
    if b and node_text(b, src) == 'None' then return a end
    if a and node_text(a, src) == 'None' then return b end
    return nil
end
local RUST_GUARDS = {
    cond = { if_expression = true, while_expression = true },
    else_t = 'else_clause',
    fn = { function_item = true, closure_expression = true },
    binop = 'binary_expression', andops = { ['&&'] = true },
    negop = 'unary_expression', negtok = '!', pfield = 'parameters',
    abs_test = function (n, src, chain)
        local x = rs_method_on(n, { is_none = true }, src) or rs_none_operand(n, { ['=='] = true }, src)
        if x then return chain_eq(unparen(x), src, chain) end
        if n:type() == 'unary_expression' and n:child(0) and n:child(0):type() == '!' then
            local y = unparen(n:named_child(0))
            return y ~= nil and chain_eq(y, src, chain)
        end
        return false
    end,
    presence = function (cond, src, chain)
        cond = unparen(cond)
        if cond == nil then return false end
        if chain_eq(cond, src, chain) then return true end
        local x = rs_method_on(cond, { is_some = true }, src) or rs_none_operand(cond, { ['!='] = true }, src)
        return x ~= nil and chain_eq(unparen(x), src, chain)
    end,
    -- the memo call: `CELL.get_or_init(f)`, `m.entry(k).or_insert(v)` (CART-1585)
    rhs_setonce = function (top, src) return rs_memo_call(top:parent(), top, src) end,
}

-- ── LEXICAL SCOPES (CART-1598, rust) ──────────────────────────────────────────────────────────────────────────────
-- rust declared no scope model, so the cross-file unique join claimed every param and local. A pattern binds its
-- identifier leaves — never a tuple-struct / struct pattern's TYPE (`Some` in `Some(x)`), a scoped path or a field
-- NAME (`P { r: rr }` binds rr; the shorthand `P { q }` binds q). A function / closure binds its params, a block its
-- `let`s from the declaring row, and `for` / `if let` / `while let` / a match arm their patterns.
local function rs_pattern_names(p, src, out, row)
    if not p then return end
    local t = p:type()
    if t == 'identifier' or t == 'shorthand_field_identifier' then
        -- (a CAPITALISED identifier in a pattern is a variant / const being MATCHED — `None`, `MAX` —, never a binding)
        local nm = node_text(p, src)
        if not nm:match('^%u') then out[nm] = { row = row } end
    elseif t == 'field_pattern' then
        local sub = p:field('pattern')[1]
        if sub then rs_pattern_names(sub, src, out, row) else rs_pattern_names(p:field('name')[1], src, out, row) end
    elseif t == 'tuple_pattern' or t == 'tuple_struct_pattern' or t == 'struct_pattern' or t == 'slice_pattern'
        or t == 'ref_pattern' or t == 'mut_pattern' or t == 'or_pattern' or t == 'captured_pattern'
        or t == 'match_pattern' or t == 'reference_pattern' then
        -- (a tuple-struct pattern's TYPE `Some` is capitalised: the identifier arm above skips it)
        for _, c in inext, p, -1 do
            if c:named() then rs_pattern_names(c, src, out, row) end
        end
    end
end
local function rs_params(node, src, out)
    local ps = node:field('parameters')[1]
    if not ps then return end
    for _, c in inext, ps, -1 do
        if c:type() == 'parameter' then rs_pattern_names(c:field('pattern')[1], src, out)
        elseif c:named() and c:type() ~= 'self_parameter' then rs_pattern_names(c, src, out) end -- (a closure's bare `mut cq`)
    end
end
local function rs_block(node, src, out)
    for _, st in inext, node, -1 do
        if st:type() == 'let_declaration' then rs_pattern_names(st:field('pattern')[1], src, out, (select(1, st:range()))) end
    end
end
local function rs_lets(node, src, out) -- a `for` pattern, an `if let` / `while let` condition (let chains too), a match arm
    if node:type() == 'match_arm' or node:type() == 'for_expression' then rs_pattern_names(node:field('pattern')[1], src, out) return end
    local function conds(c)
        if not c then return end
        if c:type() == 'let_condition' then rs_pattern_names(c:field('pattern')[1], src, out)
        elseif c:type() == 'let_chain' then for _, k in inext, c, -1 do conds(k) end end
    end
    conds(node:field('condition')[1])
end
local RUST_LEXICAL_SCOPES = {
    function_item = { kind = 'param', harvest = rs_params }, closure_expression = { kind = 'param', harvest = rs_params },
    block = { kind = 'local', harvest = rs_block },
    for_expression = { kind = 'local', harvest = rs_lets }, if_expression = { kind = 'local', harvest = rs_lets },
    while_expression = { kind = 'local', harvest = rs_lets }, match_arm = { kind = 'local', harvest = rs_lets },
}
-- the call-argument / callee gate's binders (fn.locals). That gate is POSITION-BLIND — a name in fn.locals shadows
-- every call of it anywhere in the function — so it gets only the binders visible across the body: the params, the
-- TOP block's `let`s (not one whose initializer names itself: `let x = x()` calls the outer x) and a closure's
-- params (a closure assigned to a `let` mints no node, its calls are the enclosing fn's). A nested block's, a match
-- arm's, an `if let`'s binding stays out: cargo's `match registry(…) { Ok((registry, _)) => … }` had refused
-- the call by the ARM's name.
local function rs_fn_locals(def, src, out)
    -- (the fn's OWN params reach the call gate through fn.params already: a param callee is 'higher-order')
    local body = def:field('body')[1]
    if not body then return end
    local function lets(b)
        for _, st in inext, b, -1 do
            if st:type() == 'let_declaration' then
                local names = {}
                rs_pattern_names(st:field('pattern')[1], src, names)
                local self = tsutil.mentions_of(st:field('value')[1], src, names) or {}
                for nm in pairs(names) do if not self[nm] then out[nm] = {} end end
            end
        end
    end
    lets(body)
    local function closures(n)
        for _, c in inext, n, -1 do
            if c:type() == 'closure_expression' then
                rs_params(c, src, out)
                local cb = c:field('body')[1] -- (and its TOP block's lets, as go's literal: the closure mints no node)
                if cb and cb:type() == 'block' then lets(cb) end
            end
            closures(c)
        end
    end
    closures(body)
end

return {
    lexical_scopes = RUST_LEXICAL_SCOPES, -- CART-1598
    fn_locals = rs_fn_locals,
    guards = RUST_GUARDS,
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
        index_expression = 0, -- s[i] · child 0, no field
    },
    is_write = rust_is_write,
    -- the PREFILTER: every immediate parent type a rust write mention can have.
    -- Without it the classifier is never invoked (see the note on it).
    write_gate = { assignment_expression = true, compound_assignment_expr = true,
        field_expression = true, index_expression = true,
        unary_expression = true },
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
        field_expression = 'field', -- o.NAME
    },
    -- CALL POSITIONS (CART-0499): parent node type -> which child holds the
    -- CALLEE NAME, as a field name or a named-child index. Replaces a
    -- hardcoded four-name or-chain inline in the provider that php, java,
    -- bash, rust macros, ruby and haskell were all missing from -- so a call
    -- to a corpus-unique function became a fn REFERENCE and minted a `reg`
    -- edge ("kept alive by top-level DATA"), a different fact. 96.6% of
    -- mantisbt's reg occurrences were mislabelled calls.
    call_positions = {
        call_expression = 'function', -- g(1)
        macro_invocation = 0, -- println!(…) -- no field for the macro name
    },
        exts = { 'rs' },
        functions = [[
            (function_item name: (identifier) @name) @def
            (macro_definition name: (identifier) @name) @def
        ]],
        calls = [[
            (call_expression function: (identifier) @name) @call
            (call_expression function: (field_expression) @name) @call
            (call_expression function: (scoped_identifier) @name) @call
            (macro_invocation macro: (identifier) @name) @call
        ]],
        vars = [[
            (const_item name: (identifier) @vname value: (_) @value) @vdef
            (static_item name: (identifier) @vname value: (_) @value) @vdef
        ]],
        params_field = 'parameters',
        body_field = 'body',
        fn_types = { function_item = true, closure_expression = true,
            macro_definition = true }, -- the `functions` query calls a macro a def
        -- a closure encloses, but the `functions` query mints only function_item
        -- and macro_definition — so it is not a sound flow stop (CART-0308).
        fn_unminted = { closure_expression = true },
        -- fns inside impl/trait blocks are methods, carrying their type:
        -- Config::new — which also keeps every type's `new` distinct
        is_method = function (_, def)
            local p = def:parent()
            while p do
                local t = p:type()
                if t == 'impl_item' or t == 'trait_item' then return true end
                p = p:parent()
            end
            return false
        end,
        qualify = function (name, defn, src)
            local p = defn:parent()
            while p do
                local t = p:type()
                if t == 'impl_item' or t == 'trait_item' then
                    local ty = p:field('type')[1] or p:field('name')[1]
                    -- generics (Foo<T>) reduce to the base type name
                    if ty then
                        local txt = node_text(ty, src)
                            :match('^([%w_]+)')
                        if txt then return txt .. '::' .. name end
                    end
                    return name
                end
                p = p:parent()
            end
            return name
        end,
        entry_names = { main = true },
        -- impl/trait/mod wrap real content; type declarations are data
        block_skip = { impl_item = true, trait_item = true, mod_item = true,
            foreign_mod_item = true },
        -- `impl Trait for Type` methods are called through the trait —
        -- trait objects, generics — invisibly to a name graph: registered
        -- by construction, never dead (the @receiver lesson, rust edition)
        cbarg_def = function (defn, src)
            -- #[test]/#[bench]/#[no_mangle]: invoked by harness or linker
            local sib = defn:prev_named_sibling()
            while sib and sib:type() == 'attribute_item' do
                local t = node_text(sib, src)
                if t:find('test') or t:find('no_mangle')
                    or t:find('bench') then
                    return true
                end
                sib = sib:prev_named_sibling()
            end
            local p = defn:parent()
            while p do
                if p:type() == 'impl_item' then
                    return p:field('trait')[1] ~= nil
                end
                p = p:parent()
            end
            return false
        end,
        -- pub fns are a library crate's exported surface: no in-repo
        -- caller says nothing about their liveness
        exported_def = function (defn, _)
            for _, c in inext, defn, -1 do
                if c:type() == 'visibility_modifier' then return true end
            end
            return false
        end,
        -- rust identifiers are mostly LOCALS (`let args = ...` shadows any
        -- fn named args); bare-fn-as-value flows through call arguments
        -- (the argv upgrade), so the id-pass mention branch is noise here
        id_fn_refs = false,
        -- x.foo() is METHOD syntax: it can never reach a free function,
        -- so dotted callees only ever match method defs
        dot_calls_are_methods = true,
        -- the CRATE is the name-resolution boundary: a bare identifier in
        -- one crate can never legally reach another crate's private fn,
        -- so workspace-unique is tested within the crate, never across
        scope = function (file, files)
            local dir = file:match('^(.*)/[^/]*$') or ''
            while dir ~= '' do
                if files[dir .. '/lib.rs'] or files[dir .. '/main.rs'] then
                    return dir
                end
                dir = dir:match('^(.*)/[^/]*$') or ''
            end
            return ''
        end,
        -- iterator/Option/Result vocabulary and ubiquitous trait methods:
        -- a project def with one of these names must not absorb the
        -- language's own calls
        stdlib_names = { clone = true, unwrap = true, expect = true,
            into = true, from = true, to_string = true, as_str = true,
            as_ref = true, as_bytes = true, iter = true, into_iter = true,
            next = true, len = true, push = true, pop = true, insert = true,
            get = true, map = true, and_then = true, unwrap_or = true,
            unwrap_or_else = true, collect = true, to_owned = true,
            borrow = true, lock = true, read = true, write = true,
            send = true, recv = true, join = true, spawn = true,
            contains = true, starts_with = true, ends_with = true,
            split = true, trim = true, parse = true, is_empty = true,
            is_some = true, is_none = true, ok = true, err = true,
            default = true, new = true, fmt = true, eq = true, cmp = true,
            hash = true, drop = true, deref = true, extend = true,
            -- std macros (captured as calls by the macro_invocation query)
            format = true, print = true, println = true, eprintln = true,
            vec = true, panic = true, assert = true, assert_eq = true,
            assert_ne = true, debug_assert = true, matches = true,
            todo = true, unimplemented = true, unreachable = true,
            include_str = true, concat = true, env = true, cfg = true },
        stdlib_prefixes = { 'std::', 'core::', 'alloc::', 'String::',
            'Vec::', 'Box::', 'Arc::', 'Rc::', 'Option::', 'Result::',
            'Path::', 'PathBuf::', 'HashMap::', 'HashSet::', 'BTreeMap::' },
        import_query = [[ (use_declaration argument: (_) @path) ]],
        --- `use a::b::C;` binds `C`; `use a::b as c;` binds `c`. Both are read off
        --- the SAME @path text rather than a second capture, because the alias sits
        --- in a `use_as_clause` that would have to replace @path to be captured and
        --- resolve_import wants the whole path.
        --- ⚠ REFUSES THE BRACE AND GLOB FORMS. `use a::{b, c}` binds TWO names and
        --- `use a::*` binds an unknown set; a single bind for either would name one
        --- of them and silently mean all, which is a fabricated binding rather than
        --- a missing one. Absent is the honest answer until the schema can carry a
        --- SET ([[cartograph-external-surface]]'s set-valued binding).
        import_bind_path = function (path)
            if path:find('[{*]') then return nil end
            local alias = path:match('%s+as%s+([%w_]+)%s*$')
            if alias then return alias end
            return (path:gsub('%s', ''):match('([%w_]+)$'))
        end,
        resolve_import = function (path, files, from)
            -- crate::a::b -> <src root>/a/b.rs | a/b/mod.rs | a.rs (the
            -- last segment may be an item, not a module); super/self are
            -- relative; a foreign first segment is another crate: honest nil
            path = path:gsub('%s', ''):gsub('{.*$', ''):gsub('%*$', '')
            local segs = {}
            for s in path:gmatch('[%w_]+') do segs[#segs + 1] = s end
            if #segs == 0 then return nil end
            local dir = from:match('^(.*)/[^/]*$') or ''
            local base
            if segs[1] == 'crate' then
                -- the crate root: nearest ancestor holding lib.rs/main.rs
                local d = dir
                while d ~= '' do
                    if files[d .. '/lib.rs'] or files[d .. '/main.rs'] then
                        base = d
                        break
                    end
                    d = d:match('^(.*)/[^/]*$') or ''
                end
                table.remove(segs, 1)
            elseif segs[1] == 'super' then
                base = dir:match('^(.*)/[^/]*$') or ''
                table.remove(segs, 1)
            elseif segs[1] == 'self' then
                base = dir
                table.remove(segs, 1)
            else
                return nil
            end
            if not base or #segs == 0 then return nil end
            for last = #segs, math.max(#segs - 1, 1), -1 do
                local p = base
                for i = 1, last do p = p .. '/' .. segs[i] end
                if files[p .. '.rs'] then return p .. '.rs' end
                if files[p .. '/mod.rs'] then return p .. '/mod.rs' end
            end
            -- a single-segment item lives in the base module itself
            for _, cand in ipairs({ base .. '/lib.rs', base .. '/main.rs',
                base .. '/mod.rs', base .. '.rs' }) do
                if files[cand] then return cand end
            end
            return nil
        end,
}
