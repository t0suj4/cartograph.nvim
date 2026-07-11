-- SINKFLOW — taint rung 0 ([[cartograph-taint-analysis]]): a DIVERGENT
-- SQL-injection smell — one function string-concatenates a param into a
-- query-shaped SINK WITHOUT sanitizing it, while a SIBLING concatenates the
-- same shape into the same sink and DOES ("you defended the peer, not this
-- one"). The honest first rung — no inter-proc fixpoint, no ORM/sink-table.
--
-- The PEER IS REQUIRED, not decorative: it IS the evidence. Measured across
-- the PHP corpora, "unsanitized param -> sink" ALONE over-fires (a param is
-- not a source; untyped legacy code reads as uniformly unsanitized) — mantis
-- 37 FP, sylius 4 FP. Requiring the divergent peer took both to 0 while
-- keeping grocy's real vuln (a param is only suspicious when a peer proves the
-- author knew to defend it). Lone offenders are reachability's job (rung 2).
--
-- Two sanitizer classes: COERCION (scalar type hint / `(int)$x` cast) and
-- PARAMETERIZATION/ESCAPING (param()/db_param/bindValue/escapes — the dominant
-- safe channel; a bound param is not raw). The SINK is a `~` HYPOTHESIS (method
-- name / dangling-operator content / DB receiver), never confirmed — so every
-- finding says so.
--
-- Re-parses PHP on demand (the atlas.M.fields precedent): PHP param type hints
-- and the build-a-string-then-pass flow are not in the closed schema. PHP-only
-- in v1 (sanitizer notions are typed-/framework-specific; Lua would be noise).
--
-- RUNG 1 (M.source_findings, `sink-source` rule): a REQUEST SOURCE
-- ($_GET/$_POST/$_REQUEST/$_COOKIE/$_SERVER/$_FILES) reaching a SQL sink,
-- unsanitized — the classic vulnerable-script shape rung 0 can't see
-- (top-level, source not param, interpolation not just concat). NO peer
-- needed: a superglobal is definitionally tainted. Scope-aware forward taint
-- (fixpoint over each scope's assignments; top-level scripts + each function),
-- carrying whether taint has been EMBEDDED in SQL-carrying string text — only
-- string-embedded taint at a sink is injection (a bare tainted value passed
-- standalone is a bound parameter, e.g. LessQL `where('col', $v)`; that
-- distinction is what keeps it quiet on grocy/mantis/sylius). Sanitizers as
-- rung 0 + scalar casts. Validated on DVWA: the sqli low/impossible gradient
-- (low fires, impossible silent); grocy/mantis/sylius 0.

local M = {}

local function txt(n, src) return vim.treesitter.get_node_text(n, src) end

-- all descendant nodes of the given types (named only)
local function collect(node, types)
    local want, acc = {}, {}
    for _, t in ipairs(types) do want[t] = true end
    local function rec(n)
        if want[n:type()] then acc[#acc + 1] = n end
        for c in n:iter_children() do if c:named() then rec(c) end end
    end
    rec(node)
    return acc
end

local SCALAR = { int = true, float = true, bool = true }

-- parameterization / escaping wrappers: a param passed to one of these is
-- bound or escaped, NOT concatenated raw — the dominant sanitizer in
-- well-written code (mantis's db_param / $query->param, PDO bindValue, the
-- escape family). A reference enclosed by one of these is not a taint source.
local PARAMETERIZE = { param = true, db_param = true, bindvalue = true,
    bindparam = true, quote = true, escape = true, addslashes = true,
    real_escape_string = true, mysqli_real_escape_string = true,
    intval = true, floatval = true }

local function callee_name(call, src)
    local nf = call:field('name')[1] or call:field('function')[1]
    return nf and txt(nf, src):lower() or nil
end

-- is this variable_name occurrence enclosed (up to `root`) by a
-- parameterizing/escaping call?
local function protected_ref(v, root, src)
    local p = v:parent()
    while p do
        local t = p:type()
        if t == 'member_call_expression' or t == 'function_call_expression'
            or t == 'scoped_call_expression' then
            local cn = callee_name(p, src)
            if cn and PARAMETERIZE[cn] then return true end
        end
        if p == root then break end
        p = p:parent()
    end
    return false
end

-- params of a fn node: name -> { scalar = bool } (scalar type hint = the
-- coercion sanitizer). Text-based on each parameter node: robust across the
-- grammar's `type`/no-field shapes.
local function param_info(fnnode, src)
    local info = {}
    local fp
    for c in fnnode:iter_children() do
        if c:type() == 'formal_parameters' then fp = c break end
    end
    if not fp then return info end
    for p in fp:iter_children() do
        local t = p:type()
        if p:named() and (t == 'simple_parameter'
            or t == 'property_promotion_parameter' or t == 'variadic_parameter') then
            local pt = txt(p, src)
            local ty, nm = pt:match('^%s*%??%s*([%a_\\]+)%s+%$([%w_]+)')
            if not nm then nm = pt:match('%$([%w_]+)') end
            if nm then info[nm] = { scalar = ty ~= nil and SCALAR[ty] or false } end
        end
    end
    return info
end

-- first string-literal text inside a node (the concat "prefix")
local function prefix_of(node, src)
    for _, s in ipairs(collect(node, { 'string', 'encapsed_string', 'string_content' })) do
        local t = txt(s, src):gsub('^["\']', ''):gsub('["\']$', '')
        if t ~= '' then return t end
    end
    return nil
end

-- an inline scalar CAST applied to $name (calls like intval() are handled
-- by PARAMETERIZE/protected_ref; this is the `(int)$x` cast syntax)
local function cast_sanitized(text, name)
    local e = '%$' .. name:gsub('(%W)', '%%%1')
    return text:find('%(%s*int[eger]*%s*%)%s*' .. e) ~= nil
        or text:find('%(%s*float%s*%)%s*' .. e) ~= nil
        or text:find('%(%s*bool[ean]*%s*%)%s*' .. e) ~= nil
end

-- Does `node` (a call argument) carry a taint source — a PARAM, or a LOCAL
-- built from a param-concat (one hop) — reaching it through string concat?
-- Returns { param, prefix, sanitized } or nil. `locals` maps name->that hit.
local function taint_in(node, src, params, locals)
    -- a bare local that is itself a param-concat
    if node:type() == 'variable_name' then
        return locals[txt(node, src):gsub('^%$', '')]
    end
    -- otherwise: must be a concat referencing a param directly or a taint-local
    local bins = node:type() == 'binary_expression' and { node }
        or collect(node, { 'binary_expression' })
    if #bins == 0 then return nil end
    local has_concat = false
    for _, b in ipairs(bins) do if txt(b, src):find('%.') then has_concat = true end end
    if not has_concat then return nil end
    for _, v in ipairs(collect(node, { 'variable_name' })) do
        local nm = txt(v, src):gsub('^%$', '')
        -- a reference bound/escaped by a parameterizing wrapper is not raw
        if (params[nm] or locals[nm]) and not protected_ref(v, node, src) then
            if params[nm] then
                local text = txt(node, src)
                return { param = nm, prefix = prefix_of(node, src),
                    sanitized = params[nm].scalar or cast_sanitized(text, nm) }
            else
                return locals[nm]
            end
        end
    end
    return nil
end

local function process_fn(fnnode, src, file, fname, out)
    local params = param_info(fnnode, src)
    if next(params) == nil then return end

    -- local -> its param-concat hit (one hop), from `=` and `.=`
    local locals = {}
    for _, a in ipairs(collect(fnnode,
        { 'assignment_expression', 'augmented_assignment_expression' })) do
        local lhs, rhs = a:field('left')[1], a:field('right')[1]
        if lhs and rhs and lhs:type() == 'variable_name' then
            local hit = taint_in(rhs, src, params, locals)
            if hit then locals[txt(lhs, src):gsub('^%$', '')] = hit end
        end
    end

    for _, call in ipairs(collect(fnnode,
        { 'member_call_expression', 'function_call_expression', 'scoped_call_expression' })) do
        local namef = call:field('name')[1] or call:field('function')[1]
        local callee = namef and txt(namef, src) or '?'
        local objf = call:field('object')[1]
        local receiver = objf and txt(objf, src) or nil
        local argsn = call:field('arguments')[1]
        for arg in (argsn and argsn:iter_children() or function () end) do
            if arg:named() and arg:type() == 'argument' then
                local av = arg:named_child(0) or arg
                local hit = taint_in(av, src, params, locals)
                if hit then
                    out[#out + 1] = { file = file, fn = fname, callee = callee,
                        receiver = receiver, prefix = hit.prefix,
                        param = hit.param, sanitized = hit.sanitized or false,
                        line = select(1, call:range()) + 1 }
                end
            end
        end
    end
end

--- Every candidate egress across the PHP corpus (sanitized + not).
function M.candidates(store)
    local out = {}
    for _, file in ipairs(store.files or {}) do
        if file:match('%.php$') then
            local path = store.abs(file)
            local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path)
            if lines then
                local src = table.concat(lines, '\n')
                local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'php')
                if ok and parser then
                    local root = parser:parse()[1]:root()
                    for _, fn in ipairs(collect(root,
                        { 'function_definition', 'method_declaration' })) do
                        local nf = fn:field('name')[1]
                        process_fn(fn, src, file, nf and txt(nf, src) or '?', out)
                    end
                end
            end
        end
    end
    return out
end

-- the `~`-tier sink hypothesis: returns the reason string, or nil
local function sink_reason(c)
    local cl = c.callee:lower()
    -- 'execute' not bare 'exec': keeps ExecuteDb*/PDOStatement::execute but
    -- excludes shell_exec/exec/system (command injection is a DIFFERENT sink
    -- class — don't mislabel it SQL)
    if cl:find('query') or cl:find('execute') or cl:find('where')
        or cl:find('prepare') or cl:find('select') then
        return ("method '%s'"):format(c.callee)
    end
    if c.prefix and c.prefix:match('[=<>!]=?%s*$') then
        return 'SQL-fragment (concat ends on a dangling operator)'
    end
    local r = c.receiver and c.receiver:lower()
    if r and (r:find('database') or r:find('->db') or r:find('pdo')) then
        return 'DB receiver'
    end
    return nil
end

--- Lint findings: unsanitized candidates that pass the sink hypothesis,
--- with an opportunistic peer-divergence annotation.
function M.findings(store)
    local cands = M.candidates(store)
    -- peer index: (callee, first prefix token) -> a SANITIZED peer fn
    local sanpeer = {}
    for _, c in ipairs(cands) do
        if c.sanitized and c.prefix then
            local tok = c.prefix:match('([%w_]+)')
            if tok then sanpeer[c.callee .. '\31' .. tok] = c.fn end
        end
    end
    local out = {}
    for _, c in ipairs(cands) do
        -- rung 0 REQUIRES a sanitizing peer: the divergence IS the evidence.
        -- "unsanitized param → sink" alone over-fires (a param is not a
        -- source; untyped legacy code reads as uniformly unsanitized) — that
        -- is rung 2's (reachability) job. The peer is what makes this `~`
        -- honest without inter-proc analysis.
        local why = not c.sanitized and sink_reason(c)
        local tok = why and c.prefix and c.prefix:match('([%w_]+)')
        local peer = tok and sanpeer[c.callee .. '\31' .. tok]
        if why and peer and peer ~= c.fn then
            out[#out + 1] = { file = store.abs(c.file), line = c.line,
                message = ('possible SQL injection (~, sink unconfirmed): '
                    .. 'unsanitized param $%s concatenated into %s [%s] — peer '
                    .. '%s() sanitizes the same shape (defended the peer, not this one)')
                    :format(c.param, c.callee ~= '?'
                        and ('sink %s()'):format(c.callee) or 'a query', why, peer) }
        end
    end
    return out
end

-- ── taint rung 1: a REQUEST SOURCE reaching a SQL sink ──────────────────
-- Unlike rung 0, a superglobal is DEFINITIONALLY tainted, so no peer is
-- needed — the source IS the evidence. Interpolation (`"…'$id'"`) and
-- concatenation are both covered for free: a taint carrier is any tainted
-- `variable_name` descendant of the arg, whatever the embedding. Scope-aware
-- forward propagation ($id = $_GET[…]; $q = "… $id"; query($q)); handles the
-- top-level (function-less) scripts that are the classic injection shape and
-- that rung 0 cannot see.

local SOURCES = { _GET = true, _POST = true, _REQUEST = true,
    _COOKIE = true, _SERVER = true, _FILES = true }

local BODY_STOP = { function_definition = true, method_declaration = true,
    anonymous_function = true, arrow_function = true }

-- descendants of `node` of the given types, NOT descending into nested
-- function scopes (a scope sees only its own statements)
local function collect_scoped(node, types)
    local want, acc = {}, {}
    for _, t in ipairs(types) do want[t] = true end
    local function rec(n, top)
        if not top and BODY_STOP[n:type()] then return end
        if want[n:type()] then acc[#acc + 1] = n end
        for c in n:iter_children() do if c:named() then rec(c, false) end end
    end
    rec(node, true)
    return acc
end

-- a scalar cast (int/float/bool) enclosing `v` up to `root` — sanitizes
local function cast_ancestor(v, root, src)
    local p = v:parent()
    while p do
        if p:type() == 'cast_expression' then
            local ty = txt(p, src):match('^%(%s*(%a+)')
            if ty and (SCALAR[ty:lower()] or ty:lower() == 'integer'
                or ty:lower() == 'boolean') then return true end
        end
        if p == root then break end
        p = p:parent()
    end
    return false
end

-- is this variable_name occurrence embedded (up to `root`) in a STRING that
-- carries SQL text — an interpolation, or a concat with a string literal?
-- That embedding IS the injection; a bare value passed standalone (a bound
-- parameter, e.g. LessQL `where('col', $v)`) is not.
local function embedded_at(v, root)
    local p = v:parent()
    while p do
        local t = p:type()
        if t == 'encapsed_string' then return true end
        if t == 'binary_expression' and #collect(p, { 'string', 'encapsed_string' }) > 0 then
            return true
        end
        if p == root then break end
        p = p:parent()
    end
    return false
end

-- unsanitized taint carried into `node`: { src, embedded } or nil. `embedded`
-- is true when the taint reaches `node` inside SQL-carrying string text
-- (here, or inherited transitively). A ref bound/escaped by a parameterizer
-- or scalar cast is not raw.
local function embed_witness(node, src, tainted)
    local best
    for _, v in ipairs(collect(node, { 'variable_name' })) do
        if not protected_ref(v, node, src) and not cast_ancestor(v, node, src) then
            local nm = txt(v, src):gsub('^%$', '')
            local base = SOURCES[nm] and { src = '$' .. nm, embedded = false }
                or tainted[nm]
            if base then
                local emb = base.embedded or embedded_at(v, node)
                if emb then return { src = base.src, embedded = true } end
                best = best or { src = base.src, embedded = false }
            end
        end
    end
    return best
end

-- forward taint over one scope's own assignments (fixpoint; carries the root
-- source AND whether it has been embedded in SQL string text yet)
local function scope_taint(scope, src)
    local assigns = collect_scoped(scope,
        { 'assignment_expression', 'augmented_assignment_expression' })
    local tainted, changed = {}, true
    while changed do
        changed = false
        for _, a in ipairs(assigns) do
            local lhs, rhs = a:field('left')[1], a:field('right')[1]
            if lhs and rhs and lhs:type() == 'variable_name' then
                local nm = txt(lhs, src):gsub('^%$', '')
                local w = embed_witness(rhs, src, tainted)
                local cur = tainted[nm]
                -- monotone: take taint, and upgrade to embedded if newly so
                if w and (not cur or (w.embedded and not cur.embedded)) then
                    tainted[nm] = w; changed = true
                end
            end
        end
    end
    return tainted
end

local function scope_findings(scope, src, file, out)
    local tainted = scope_taint(scope, src)
    for _, call in ipairs(collect_scoped(scope,
        { 'member_call_expression', 'function_call_expression', 'scoped_call_expression' })) do
        local namef = call:field('name')[1] or call:field('function')[1]
        local callee = namef and txt(namef, src) or '?'
        local objf = call:field('object')[1]
        local argsn = call:field('arguments')[1]
        if callee ~= '?' and argsn and sink_reason({ callee = callee,
            receiver = objf and txt(objf, src) or nil }) then
            for arg in argsn:iter_children() do
                if arg:named() and arg:type() == 'argument' then
                    local w = embed_witness(arg:named_child(0) or arg, src, tainted)
                    -- only STRING-EMBEDDED taint is injection; a bare tainted
                    -- value passed standalone is a bound parameter
                    if w and w.embedded then
                        out[#out + 1] = { file = file, line = select(1, call:range()) + 1,
                            source = w.src, callee = callee }
                        break -- one finding per sink call
                    end
                end
            end
        end
    end
end

--- Lint findings: a request source reaches a SQL sink, unsanitized (rung 1).
function M.source_findings(store)
    local out = {}
    for _, file in ipairs(store.files or {}) do
        if file:match('%.php$') then
            local path = store.abs(file)
            local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path)
            if lines then
                local s = table.concat(lines, '\n')
                local ok, parser = pcall(vim.treesitter.get_string_parser, s, 'php')
                if ok and parser then
                    local root = parser:parse()[1]:root()
                    -- top-level scope (function-less scripts) + each function
                    local scopes = { root }
                    for _, fn in ipairs(collect(root,
                        { 'function_definition', 'method_declaration' })) do
                        scopes[#scopes + 1] = fn
                    end
                    for _, sc in ipairs(scopes) do scope_findings(sc, s, file, out) end
                end
            end
        end
    end
    local fs = {}
    for _, c in ipairs(out) do
        fs[#fs + 1] = { file = store.abs(c.file), line = c.line,
            message = ('possible SQL injection (~, sink unconfirmed): request '
                .. 'input %s reaches SQL sink %s() with no sanitizer on the path')
                :format(c.source, c.callee) }
    end
    return fs
end

return M
