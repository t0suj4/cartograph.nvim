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
local function go_is_write(c, n)
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
        for ch in p:iter_children() do
            if not ch:named() and ch:type() == '=' then return true end
        end
        return false
    end
    -- short_var_declaration / var_spec and everything else: a BINDING or a read
    return false
end

return {
    is_write = go_is_write,
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
        import_query = [=[ (import_spec path: (interpreted_string_literal) @path) ]=],
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
