-- The PHP language spec + its base helpers, extracted via the move-set flow
-- ([[cartograph-spec-layering]]). close_moveset({php_is_write, PHP_GUARDS,
-- PHP_BASENAMES}) → exactly those three (ordered by source line); the guard
-- substrate (chain_eq/optext_is/unparen) is SHARED with lua's GUARDS so it was
-- relocated into spec/tsutil.lua rather than pulled in here — both this module
-- and the engine require it from there. node_text/inext are the other shared
-- deps. Pure motion; behaviour-identical.

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text
local inext = tsutil.inext
local chain_eq = tsutil.chain_eq
local optext_is = tsutil.optext_is
local unparen = tsutil.unparen

-- php PSR-4 suffix imports: basename -> {files} index, memoized per
-- fileset (weak keys: dies with the fileset, workers build their own)
local PHP_BASENAMES = setmetatable({}, { __mode = 'k' })

local function php_is_write(c, n)
    local cur, p = c, n
    if p:type() == 'variable_name' then      -- $x: unwrap the sigil
        cur, p = p, p:parent()
    elseif p:type() ~= 'member_access_expression' then
        return false                          -- ->name rides the chain below
    end
    while p do
        local pt = p:type()
        if pt == 'subscript_expression' then
            if p:named_child(0) ~= cur then return false end -- key = a read
            cur, p = p, p:parent()
        elseif pt == 'member_access_expression' then
            cur, p = p, p:parent() -- object and field both ride the chain
        elseif pt == 'assignment_expression'
            or pt == 'augmented_assignment_expression'
            or pt == 'reference_assignment_expression' then
            return p:named_child(0) == cur
        elseif pt == 'update_expression' then -- $x++ / --$x
            return true
        elseif pt == 'unset_statement' then
            return true
        elseif pt == 'by_ref' then            -- foreach ($a as &$v): $v aliases
            return true
        elseif pt == 'foreach_statement' then
            -- the ITERATED array is written only when iterated by reference
            if p:named_child(0) ~= cur then return false end
            for ch in p:iter_children() do
                if ch:type() == 'by_ref' then return true end
            end
            return false
        elseif pt == 'list_literal' then      -- list($a, $b) = f()
            local gp = p:parent()
            return gp ~= nil and gp:type() == 'assignment_expression'
                and gp:named_child(0) == p
        else
            return false                      -- a plain read context
        end
    end
    return false
end

local PHP_GUARDS = {
    cond = { if_statement = true, else_if_clause = true, while_statement = true },
    else_t = 'else_clause', elseif_t = 'else_if_clause',
    fn = { function_definition = true, method_declaration = true,
        anonymous_function_creation_expression = true, arrow_function = true },
    binop = 'binary_expression', andops = { ['&&'] = true, ['and'] = true },
    negop = 'unary_op_expression', negtok = '!', pfield = 'parameters',
    -- `!isset(X)` / `empty(X)` / `!X` / `X === null` / `null === X`
    abs_test = function (n, src, chain)
        local t = n:type()
        if t == 'unary_op_expression' then
            local op = n:child(0)
            if op and not op:named() and op:type() == '!' then
                local x = unparen(n:named_child(0))
                if not x then return false end
                if chain_eq(x, src, chain) then return true end
                if x:type() == 'function_call_expression' then
                    local fname = x:field('function')[1]
                    if fname and node_text(fname, src) == 'isset' then
                        local args = x:field('arguments')[1]
                        local a = args and args:named_child(0)
                        return a ~= nil and chain_eq(a, src, chain)
                    end
                end
            end
        elseif t == 'function_call_expression' then
            local fname = n:field('function')[1]
            if fname and node_text(fname, src) == 'empty' then
                local args = n:field('arguments')[1]
                local a = args and args:named_child(0)
                return a ~= nil and chain_eq(a, src, chain)
            end
        elseif t == 'binary_expression'
            and optext_is(n, src, { ['==='] = true, ['=='] = true }) then
            local a, b = n:named_child(0), n:named_child(1)
            if a and b then
                if a:type() == 'null' then return chain_eq(b, src, chain) end
                if b:type() == 'null' then return chain_eq(a, src, chain) end
            end
        end
        return false
    end,
    presence = function (cond, src, chain)
        cond = unparen(cond)
        if cond == nil then return false end
        if chain_eq(cond, src, chain) then return true end
        if cond:type() == 'function_call_expression' then
            local fname = cond:field('function')[1]
            if fname and node_text(fname, src) == 'isset' then
                local args = cond:field('arguments')[1]
                local a = args and args:named_child(0)
                return a ~= nil and chain_eq(a, src, chain)
            end
        end
        return false
    end,
    -- `X ??= v` / `X = X ?? v`
    rhs_setonce = function (top, src, chain)
        local p = top:parent()
        if not p then return false end
        local pt = p:type()
        if pt == 'augmented_assignment_expression'
            and p:named_child(0) == top
            and optext_is(p, src, { ['??='] = true }) then
            return true
        end
        if pt == 'assignment_expression' and p:named_child(0) == top then
            local rhs = p:named_child(1)
            if rhs and rhs:type() == 'binary_expression'
                and optext_is(rhs, src, { ['??'] = true }) then
                local l = rhs:named_child(0)
                return l ~= nil and chain_eq(l, src, chain())
            end
        end
        return false
    end,
}

return {
    exts = { 'php' },
    write_gate = { variable_name = true, member_access_expression = true },
    is_write = php_is_write,
    guards = PHP_GUARDS,
    -- typed-string SINKS (typed-strings v1): the API contract types
    -- the arg — CONFIDENT, unlike content sniffing (~ by design)
    string_sinks = {
        db_query = { arg = 1, ty = 'sql' },     -- mantis/drupal wrapper
        mysql_query = { arg = 1, ty = 'sql' },
        mysqli_query = { arg = 2, ty = 'sql' },
        pg_query = { arg = 1, ty = 'sql' },
    },
    functions = [=[
        (function_definition name: (name) @name) @def
        (method_declaration name: (name) @name) @def
    ]=],
    calls = [=[
        (function_call_expression function: (name) @name) @call
        (member_call_expression name: (name) @name) @call
        (scoped_call_expression name: (name) @name) @call
        (function_call_expression function: (variable_name) @name) @call
    ]=],
    -- call_user_func('name', ...) CALLS name: the literal resolves as
    -- the real callee (the string is the dispatch mechanism, not a ~)
    indirect_calls = { call_user_func = 1, call_user_func_array = 1 },
    -- a variable in callee position is runtime state ($fn()) — by NODE
    -- TYPE: jQuery's $() is a plain identifier and must stay a call
    dynamic_callee_types = { variable_name = true },
    vars = [=[
        (program (expression_statement (assignment_expression
            left: (variable_name (name) @vname) right: (_) @value) @vdef))
        (const_declaration (const_element (name) @vname (_) @value) @vdef)
    ]=],
    params_field = 'parameters',
    body_field = 'body',
    fn_types = { function_definition = true, method_declaration = true,
        anonymous_function_creation_expression = true, arrow_function = true },
    is_method = function (_, def) return def:type() == 'method_declaration' end,
    -- methods carry their class: Worker::work (ambiguity semantics match cpp)
    qualify = function (name, defn, src)
        local p2 = defn:parent()
        while p2 do
            local t = p2:type()
            if t == 'class_declaration' or t == 'interface_declaration'
                or t == 'trait_declaration' then
                local cn = p2:field('name')[1]
                return cn and (node_text(cn, src) .. '::' .. name)
                    or name
            end
            p2 = p2:parent()
        end
        return name
    end,
    -- an ATTRIBUTE with arguments registers the method with a
    -- framework (#[Route('/x')]) — the java annotation-with-args
    -- lesson; bare markers (#[\Override]) don't register anything
    cbarg_def = function (defn, src)
        for _, c in inext, defn, -1 do
            if c:type() == 'attribute_list'
                and node_text(c, src)
                    :find('(', 1, true) then
                return true
            end
        end
        return false
    end,
    -- $this->m() / self::m() / static::m(): the receiver IS the
    -- enclosing class — resolve as Class::m before any tail guess.
    -- parent::m() is the receiver's SUPERCLASS — read the enclosing
    -- class's `extends` (base_clause) and resolve as Parent::m. This
    -- is the single largest refusal bucket in every OO php tree: every
    -- class has a __construct, so a bare parent::__construct tail-
    -- matches ALL of them (2313 candidates in magento) and refuses.
    qualify_call = function (calln, name, src)
        if name:find(':', 1, true) then return nil end
        local t, kind = calln:type(), nil
        if t == 'member_call_expression' then
            local o = calln:field('object')[1]
            if o and o:type() == 'variable_name'
                and node_text(o, src) == '$this' then
                kind = 'self'
            end
        elseif t == 'scoped_call_expression' then
            local s = calln:field('scope')[1]
            if s and s:type() == 'relative_scope' then
                kind = node_text(s, src) == 'parent'
                    and 'parent' or 'self'
            end
        end
        if not kind then return nil end
        local p2 = calln:parent()
        while p2 do
            local tt = p2:type()
            if tt == 'class_declaration' or tt == 'trait_declaration'
                or tt == 'interface_declaration' then
                if kind == 'self' then
                    local cn = p2:field('name')[1]
                    return cn and (node_text(cn, src)
                        .. '::' .. name) or nil
                end
                -- parent::m — resolve to the superclass named by the
                -- enclosing class's base_clause. A trait has no
                -- base_clause (its parent is the using class, unknown
                -- here) → decline and stay a refusal. When the direct
                -- parent only INHERITS m (no exact Parent::m def), the
                -- name falls through to the tail path unchanged — no
                -- worse than today, honest about the chain we can't walk.
                for _, c in inext, p2, -1 do
                    if c:type() == 'base_clause' then
                        for _, pc in inext, c, -1 do
                            local pt = pc:type()
                            if pt == 'name' or pt == 'qualified_name' then
                                -- def keys use the bare class name; take
                                -- the last namespace segment (\App\Foo→Foo;
                                -- PSR-0 Mage_Core_X has no '\' → stays whole)
                                local ptxt = node_text(pc, src)
                                return (ptxt:match('[^\\]+$') or ptxt)
                                    .. '::' .. name
                            end
                        end
                    end
                end
                return nil
            end
            p2 = p2:parent()
        end
    end,
    mention_types = { name = true },
    -- OO extends: child class -> superclass name (bare last segment,
    -- the same key form defs use). Feeds transitive parent::m resolution.
    super_query = [=[
        (class_declaration
            name: (name) @child
            (base_clause [(name) (qualified_name)] @parent))
    ]=],
    block_skip = { php_tag = true, class_declaration = true,
        interface_declaration = true, trait_declaration = true },
    litdata_types = { array_creation_expression = true },
    import_query = [=[
        (require_once_expression (string) @path)
        (require_expression (string) @path)
        (include_once_expression (string) @path)
        (include_expression (string) @path)
        (namespace_use_clause (qualified_name) @path)
        (base_clause (name) @path)
        (base_clause (qualified_name) @path)
        (class_interface_clause (name) @path)
        (class_interface_clause (qualified_name) @path)
    ]=],
    resolve_import = function (path, files, from)
        path = path:gsub('^["\']', ''):gsub('["\']$', '')
        -- a namespaced class (use App\X, extends \App\X) or a PSR-0
        -- underscore class (extends Mage_Core_Model_Abstract): both
        -- name a file by convention. PSR-4 roots REMAP prefixes
        -- (composer: BitBag\OpenMarketplace\ -> src/), so try
        -- progressively SHORTER suffixes, longest first; a match
        -- counts only while unique, ambiguity refuses, as ever
        local sep = path:find('\\') and '\\'
            or (path:match('^%u[%w]*_[%w_]+$') and '_')
        if sep then
            local idx = PHP_BASENAMES[files]
            if not idx then
                idx = {}
                for f in pairs(files) do
                    local b = f:match('([^/]+)$')
                    local l = idx[b]
                    if l then l[#l + 1] = f else idx[b] = { f } end
                end
                PHP_BASENAMES[files] = idx
            end
            local segs = {}
            for s in path:gmatch('[^' .. sep .. ']+') do segs[#segs + 1] = s end
            local cands = idx[segs[#segs] .. '.php']
            if not cands then return nil end
            for i = 1, #segs do
                local suffix, hit = table.concat(segs, '/', i) .. '.php', nil
                for _, f in ipairs(cands) do
                    if f == suffix or f:sub(-#suffix - 1) == '/' .. suffix then
                        if hit then return nil end -- ambiguous: refuse
                        hit = f
                    end
                end
                if hit then return hit end
            end
            return nil
        end
        local dir = from:match('^(.*)/[^/]*$')
        for _, cand in ipairs({ dir and (dir .. '/' .. path) or path, path }) do
            if files[cand] then return cand end
        end
        -- a bare filename (custom loaders pass 'bug_api.php', the
        -- loader supplies the directory): unique basename decides
        if not path:find('/') then
            local idx = PHP_BASENAMES[files]
            if not idx then
                idx = {}
                for f in pairs(files) do
                    local b = f:match('([^/]+)$')
                    local l = idx[b]
                    if l then l[#l + 1] = f else idx[b] = { f } end
                end
                PHP_BASENAMES[files] = idx
            end
            local cands = idx[path]
            if cands and #cands == 1 then return cands[1] end
        end
    end,
    -- CUSTOM loaders (mantis's require_api('bug_api.php')): a verb
    -- named like a loader whose literal argument is a php file
    -- includes that file — name-matched, so the edge carries ~
    import_call_like = function (name, arg)
        return arg:sub(-4) == '.php'
            and (name:match('^require_') or name:match('^include_')
                or name:match('^load_')) ~= nil
    end,
    stdlib_names = { isset = true, unset = true, empty = true,
        count = true, define = true, defined = true, sprintf = true,
        printf = true, implode = true, explode = true, in_array = true,
        array_merge = true, array_map = true, array_filter = true,
        array_keys = true, array_values = true, str_replace = true,
        strlen = true, substr = true, strpos = true, trim = true,
        intval = true, strval = true, is_array = true, is_null = true,
        is_string = true, is_int = true, is_numeric = true,
        trigger_error = true, function_exists = true,
        class_exists = true },
}
