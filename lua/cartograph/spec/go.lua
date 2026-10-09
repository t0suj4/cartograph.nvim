-- The GO language spec (L0 grammar binding + L1 name model)
-- extracted from the engine ([[cartograph-spec-layering]] P1). Pure motion.

-- @langs go — a spec IS one grammar's mapping, so every node type here is
-- go's by construction.

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text

-- IS THIS MENTION A WRITE? (CART-0532) The fourth language to answer, after lua,
-- php and python. Until it did, go's 1555 use edges carried no `rw`, no `gw`, no
-- `gp` and no `flds` — all four hang off one `if wmode then` in the reduce.
--
-- go's shape is the most regular of the four and the one place it is SUBTLE is
-- BINDING vs WRITE, which go spells three ways and only one of them is a write:
--   x := 6          short_var_declaration   BINDS
--   var y = 7       var_declaration/var_spec BINDS
--   g = 1           assignment_statement     WRITES
-- The same split lua has for `local x = v`, and getting it wrong would report
-- every declaration as a write and make `set-once` unreachable.
--
-- EVERY FORM PARSED, including the two anonymous operators: a `range_clause`
-- carries `:=` (binds) or `=` (writes) as an UNNAMED child, so the node types
-- alone cannot tell those two apart.
-- MEMO CALLS (CART-1585): `m.LoadOrStore(k, v)` (sync.Map) writes m, and only an ABSENT key — set-once by the method's
-- contract. `once.Do(f)` is the same contract, and stays out: `Do` names http.Client's request too, and no receiver
-- type is known here. `fn` is the call's callee chain `X.LoadOrStore`, X the receiver.
local GO_MEMO = { LoadOrStore = true }
local function go_memo_call(p, fn, src)
    -- (a selector whose parent is a call IS its callee: the arguments sit in an argument_list)
    if not (src and p and p:type() == 'call_expression' and fn:type() == 'selector_expression') then return false end
    local nm = fn:field('field')[1]
    return nm ~= nil and GO_MEMO[node_text(nm, src)] == true
end
local function go_is_write(c, n, src)
    local cur, p = c, n
    while p do
        local pt = p:type()
        if pt == 'selector_expression' then
            cur, p = p, p:parent() -- `o.F = v`: object and field both ride
        elseif pt == 'index_expression' then
            -- `m[k] = v` writes m; the KEY is a read
            if p:named_child(0) ~= cur then return false end
            cur, p = p, p:parent()
        elseif pt == 'unary_expression' then
            cur, p = p, p:parent() -- `*o.P = v`: the deref rides the chain
        elseif pt == 'expression_list' then
            -- go wraps BOTH sides of an assignment in one of these, so this is
            -- only a step: the side is decided by the parent check below
            cur, p = p, p:parent()
        else
            break
        end
    end
    if not p then return false end
    local pt = p:type()
    -- (the receiver IS the mention: a dynamic key of it, `'[]'` — the capture would name `LoadOrStore` the field)
    if go_memo_call(p, cur, src) then return true, cur:field('operand')[1] == c and '[]' or nil, true end -- (and READS: it tests the key)
    if pt == 'assignment_statement' then
        -- child 0 is the LEFT expression_list; arriving here from the right one
        -- fails this test, which is what makes `a, b = b, a` read correctly
        return p:named_child(0) == cur
    elseif pt == 'inc_statement' or pt == 'dec_statement' then
        return true -- g++ / g--
    elseif pt == 'range_clause' then
        -- `for i := range s` BINDS i; `for g = range s` WRITES g. The operator
        -- is an anonymous child, so the distinction is invisible to node types.
        if p:named_child(0) ~= cur then return false end -- the iterated s reads
        for _, ch in tsutil.inext, p, -1 do
            if not ch:named() and ch:type() == '=' then return true end
        end
        return false
    end
    -- short_var_declaration / var_spec and everything else: a BINDING or a read
    return false
end

-- ── THE GUARD GRAMMAR (CART-1579) ─────────────────────────────────────────────────────────────────────────────────
-- go's lazy initialisation: `if cache == nil { cache = … }`, the COMMA-OK memo `if _, ok := m[k]; !ok { m[k] = … }`
-- (`!ok` is the absence of `m[k]`, read through the `if`'s initializer), and the else arm of `if x != nil` / `ok`.
-- go's `if` has no else node — both arms are blocks, told apart by FIELD — and its first child may be the
-- initializer: `cond_of` and `arm` say which is which.
local chain_eq, optext_is, unparen = tsutil.chain_eq, tsutil.optext_is, tsutil.unparen
-- the chain an `ok` of the comma-ok form `v, ok := X` / `_, ok := X` in this `if`'s initializer stands for -> X's text
local function go_ok_chain(ifnode, okname, src)
    local init = ifnode and ifnode:field('initializer')[1]
    if not (init and init:type() == 'short_var_declaration') then return nil end
    local l, r = init:field('left')[1], init:field('right')[1]
    if not (l and r and l:named_child_count() == 2 and r:named_child_count() == 1) then return nil end
    if node_text(l:named_child(1), src) ~= okname then return nil end
    local x = r:named_child(0)
    if x and (x:type() == 'index_expression' or x:type() == 'type_assertion_expression') then return node_text(x, src) end
    return nil
end
local function go_if_of(n) -- the `if` a condition belongs to
    local p = n:parent()
    while p and p:type() ~= 'if_statement' do
        if p:type() == 'block' then return nil end
        p = p:parent()
    end
    return p
end
local function go_nil_operand(n, ops)
    if n:type() ~= 'binary_expression' or not optext_is(n, nil, ops) then return nil end
    local a, b = unparen(n:named_child(0)), unparen(n:named_child(1))
    if b and b:type() == 'nil' then return a end
    if a and a:type() == 'nil' then return b end
    return nil
end
local GO_GUARDS = {
    cond = { if_statement = true },
    cond_of = function (p) return p:field('condition')[1] end,
    arm = function (p, node)
        if p:field('initializer')[1] == node then return 'init' end
        if p:field('alternative')[1] == node then return node:type() == 'if_statement' and 'elseif' or 'else' end
        return nil
    end,
    fn = { function_declaration = true, method_declaration = true, func_literal = true },
    binop = 'binary_expression', andops = { ['&&'] = true },
    negop = 'unary_expression', negtok = '!', pfield = 'parameters',
    pw_refsem = true, -- maps, slices and pointers are reference-typed
    abs_test = function (n, src, chain)
        local x = go_nil_operand(n, { ['=='] = true })
        if x then return chain_eq(x, src, chain) end
        if n:type() == 'unary_expression' and n:child(0) and n:child(0):type() == '!' then
            local ok = unparen(n:named_child(0))
            if ok and ok:type() == 'identifier' then return go_ok_chain(go_if_of(n), node_text(ok, src), src) == chain end
        end
        return false
    end,
    presence = function (cond, src, chain)
        cond = unparen(cond)
        if cond == nil then return false end
        if chain_eq(cond, src, chain) then return true end
        local x = go_nil_operand(cond, { ['!='] = true })
        if x then return chain_eq(x, src, chain) end
        if cond:type() == 'identifier' then return go_ok_chain(go_if_of(cond), node_text(cond, src), src) == chain end
        return false
    end,
    -- the memo call `m.LoadOrStore(k, v)` (CART-1585)
    rhs_setonce = function (top, src) return go_memo_call(top:parent(), top, src) end,
}

-- ── LEXICAL SCOPES (CART-1598) ────────────────────────────────────────────────────────────────────────────────────
-- go declared no scope model, so the cross-file unique join claimed every param and local (the CART-1589 / 1597
-- class). A function binds its receiver, params and NAMED results; a block binds its `:=` / `var` / `const` from the
-- declaring row (go 0.12 wraps a block's statements in a statement_list); an `if` / `for` / `switch` binds its
-- initializer, a range `:=` and a type switch's alias. A package-level name binds nothing — it IS the package's,
-- shared by every file of it.
local function go_idents(n, src, out, row, decl) -- (decl's rows ride as at / ate: its own initializer is not in scope)
    local sr, er, sb, eb
    if decl then local s, _, e = decl:range(); sr, er = s, e; sb, eb = select(3, decl:start()), select(3, decl:end_()) end
    for _, c in tsutil.inext, n, -1 do
        if c:type() == 'identifier' then out[node_text(c, src)] = { row = row, at = sr, ate = er, ab = sb, abe = eb } end
    end
end
local function go_params(node, src, out)
    for _, f in ipairs({ 'receiver', 'parameters', 'result' }) do
        local pl = node:field(f)[1]
        if pl and pl:type() == 'parameter_list' then
            for _, d in tsutil.inext, pl, -1 do
                for _, nm in ipairs(d:field('name')) do out[node_text(nm, src)] = {} end
            end
        end
    end
end
local function go_decl(st, src, out, row) -- one statement's own declarations
    local t = st:type()
    if t == 'short_var_declaration' then
        local l = st:field('left')[1]
        if l then go_idents(l, src, out, row, st) end
    elseif t == 'var_declaration' or t == 'const_declaration' then
        local function specs(n)
            for _, s in tsutil.inext, n, -1 do
                local st2 = s:type()
                if st2 == 'var_spec' or st2 == 'const_spec' then
                    local sr, _, er = s:range()
                    local sb, eb = select(3, s:start()), select(3, s:end_())
                    for _, nm in ipairs(s:field('name')) do out[node_text(nm, src)] = { row = row, at = sr, ate = er, ab = sb, abe = eb } end
                elseif st2 == 'var_spec_list' then specs(s) end
            end
        end
        specs(st)
    end
end
local function go_block(node, src, out)
    for _, c in tsutil.inext, node, -1 do
        if c:type() == 'statement_list' then
            for _, s in tsutil.inext, c, -1 do go_decl(s, src, out, (select(1, s:range()))) end
        else go_decl(c, src, out, (select(1, c:range()))) end
    end
end
local function go_ctrl(node, src, out)
    local init = node:field('initializer')[1]
    if init then go_decl(init, src, out) end
    for _, c in tsutil.inext, node, -1 do
        local t = c:type()
        if t == 'range_clause' then
            local def = false
            for _, k in tsutil.inext, c, -1 do if not k:named() and k:type() == ':=' then def = true end end
            local l = c:field('left')[1]
            if def and l then go_idents(l, src, out) end
        elseif t == 'for_clause' then
            local fi = c:field('initializer')[1]
            if fi then go_decl(fi, src, out) end
        end
    end
    local alias = node:field('alias')[1]
    if alias then go_idents(alias, src, out) end
end
local GO_LEXICAL_SCOPES = {
    function_declaration = { kind = 'param', harvest = go_params },
    method_declaration = { kind = 'param', harvest = go_params },
    func_literal = { kind = 'param', harvest = go_params },
    block = { kind = 'local', harvest = go_block },
    if_statement = { kind = 'local', harvest = go_ctrl }, for_statement = { kind = 'local', harvest = go_ctrl },
    expression_switch_statement = { kind = 'local', harvest = go_ctrl },
    type_switch_statement = { kind = 'local', harvest = go_ctrl },
}
-- the call-argument / callee gate's binders (fn.locals, CART-1597's hook). That gate is POSITION-BLIND — a name in
-- fn.locals shadows every call of it in the function — so it gets only the binders visible across the body: the
-- receiver, params and named results (fn.params holds only the parameter list), the TOP block's `:=` / `var` /
-- `const` (not one whose initializer names itself: `x := x()` calls the outer x) and a func_literal's params
-- (`f := func(p int) { use(p) }` mints no node: its calls are the enclosing fn's). A nested block's or a control
-- statement's binder stays out (cargo's match-arm case, CART-1598 rust).
local function go_fn_locals(def, src, out)
    go_params(def, src, out)
    local body = def:field('body')[1]
    if not body then return end
    local function top(st)
        local names = {}
        go_decl(st, src, names)
        local val = st:field('right')[1] or st
        if st:type() ~= 'short_var_declaration' then val = st end
        local self = tsutil.mentions_of(st:type() == 'short_var_declaration' and st:field('right')[1] or nil, src, names) or {}
        for nm in pairs(names) do if not self[nm] then out[nm] = {} end end
    end
    local function block(b)
        for _, c in tsutil.inext, b, -1 do
            if c:type() == 'statement_list' then for _, s in tsutil.inext, c, -1 do top(s) end else top(c) end
        end
    end
    block(body)
    -- (and a func_literal's params and TOP block: hugo's `c.Run(…, func(c) { matches := func(…); matches(…) })` —
    -- the literal mints no node, so `matches(…)` is the enclosing fn's call, and it reached pageCacheEntry.matches)
    local function lits(n)
        for _, c in tsutil.inext, n, -1 do
            if c:type() == 'func_literal' then
                go_params(c, src, out)
                local lb = c:field('body')[1]
                if lb then block(lb) end
            end
            lits(c)
        end
    end
    lits(body)
end

return {
    lexical_scopes = GO_LEXICAL_SCOPES, -- CART-1598
    fn_locals = go_fn_locals,
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
        index_expression = 'operand', -- s[i] · m["k"]
    },
    is_write = go_is_write,
    guards = GO_GUARDS,
    -- the PREFILTER, and it is not optional: without it collect_mentions never
    -- calls the classifier at all (see python.lua's note). Every immediate
    -- parent type a go write mention can have.
    write_gate = { expression_list = true, selector_expression = true,
        index_expression = true, unary_expression = true,
        inc_statement = true, dec_statement = true, range_clause = true },
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
        selector_expression = 'field', -- o.NAME
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
    },
        exts = { 'go' },
        functions = [=[
            (function_declaration name: (identifier) @name) @def
            (method_declaration name: (field_identifier) @name) @def
        ]=],
        calls = [=[
            (call_expression function: (identifier) @name) @call
            (call_expression function: (selector_expression) @name) @call
        ]=],
        vars = [=[
            (source_file (var_declaration (var_spec
                name: (identifier) @vname value: (_) @value) @vdef))
            (source_file (var_declaration (var_spec
                name: (identifier) @vname type: (_) .) @vdef))
            (source_file (const_declaration (const_spec
                name: (identifier) @vname value: (_) @value) @vdef))
        ]=],
        params_field = 'parameters',
        body_field = 'body',
        fn_types = { function_declaration = true, method_declaration = true,
            func_literal = true }, -- a closure is a scope with no name
        -- a func_literal encloses, but the `functions` query mints only
        -- function_declaration/method_declaration. Stopping there orphaned every
        -- closure body in the corpus: dfgate go 30 -> 1772 divergences (CART-0308).
        fn_unminted = { func_literal = true },
        is_method = function (_, def)
            return def:type() == 'method_declaration'
        end,
        -- methods carry their receiver type: Site.render
        qualify = function (name, defn, src)
            if defn:type() ~= 'method_declaration' then return name end
            local recv = defn:field('receiver')[1]
            if recv then
                local t = node_text(recv, src)
                    :match('%*?([%w_]+)%s*%)')
                    or node_text(recv, src)
                        :match('%*?([%w_]+)')
                if t then return t .. '.' .. name end
            end
            return name
        end,
        -- func main + func init: runtime-invoked, never dead
        entry_names = { main = true, init = true },
        -- the PACKAGE (directory) is Go's bare-name boundary
        scope = function (file, _)
            return file:match('^(.*)/[^/]*$') or ''
        end,
        -- capitalized = exported: no in-repo caller says nothing
        exported_def = function (defn, src)
            local nm = defn:field('name')[1]
            nm = nm and node_text(nm, src) or ''
            return nm:match('^%u') ~= nil
        end,
        -- Go identifiers are mostly locals/fields; fn-as-value flows
        -- through call args (argv upgrade), like rust
        id_fn_refs = false,
        stdlib_names = { append = true, len = true, cap = true, make = true,
            new = true, copy = true, delete = true, panic = true,
            recover = true, print = true, println = true, close = true,
            Error = true, String = true, Len = true, Less = true,
            Swap = true, Read = true, Write = true, Close = true,
            New = true, Get = true, Set = true, Do = true, Run = true,
            Add = true, Wait = true, Done = true, Lock = true,
            Unlock = true, Sprintf = true, Errorf = true, Printf = true },
        stdlib_prefixes = { 'fmt.', 'strings.', 'strconv.', 'os.', 'io.',
            'errors.', 'bytes.', 'time.', 'sync.', 'context.', 'filepath.',
            'path.', 'sort.', 'math.', 'net.', 'http.', 'url.', 'regexp.',
            'reflect.', 'json.', 'bufio.', 'log.', 'slices.', 'maps.',
            'atomic.', 'rand.', 'unicode.', 'utf8.', 'hex.', 'base64.',
            'sha256.', 'exec.', 'testing.', 'assert.', 'require.' },
        -- TWO PATTERNS, ONE SITE: the aliased form captures @bind, the bare form
        -- does not and takes its name from import_bind_path below. The consumer
        -- dedupes on the @path NODE and merges the bind, so the edge set is
        -- unchanged (see the at_site merge in providers/treesitter).
        import_query = [=[
            (import_spec name: (package_identifier) @bind
                path: (interpreted_string_literal) @path)
            (import_spec path: (interpreted_string_literal) @path)
        ]=],
        --- `import "net/http"` binds `http`: the last path segment. NOT always the
        --- package's declared name (a package may declare a name differing from its
        --- directory), so this is a HEURISTIC that the alias capture overrides
        --- whenever the source says otherwise.
        -- `import "x/y"` names a PACKAGE DIRECTORY: resolve_import returns ONE
        -- representative file for it, so a symbol defined in a sibling of that
        -- representative is still what the binding refers to.
        import_unit = 'directory',
        import_bind_path = function (path)
            local last = path:gsub('"', ''):match('([%w_]+)/?$')
            return last
        end,
        resolve_import = function (path, files, _)
            -- module-path imports: find the suffix that exists in-repo,
            -- resolving to the package dir's eponymous or first-known file
            path = path:gsub('"', '')
            local segs = {}
            for seg in path:gmatch('[^/]+') do segs[#segs + 1] = seg end
            for i = 1, #segs do
                local dir = table.concat(segs, '/', i)
                local last = segs[#segs]
                for _, cand in ipairs({ dir .. '/' .. last .. '.go',
                    dir .. '/doc.go', dir .. '/' .. last .. 's.go' }) do
                    if files[cand] then return cand end
                end
            end
            return nil
        end,
}
