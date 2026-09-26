-- erlfeatures — FUNCTIONALITY THE TREE CONTAINS BUT COMPILES OUT BY DEFAULT, and how to turn it on (erlang + rebar +
-- autoconf). User, 2026-09-26: "finding disabled functionality would be nice as otherwise user would be tempted to
-- implement it or search elsewhere".
-- @langs erlang
--
-- ★★ THE CHAIN, measured on ejabberd (SIP):
--   configure.ac:258    AC_ARG_ENABLE(sip, [AS_HELP_STRING([--enable-sip],[enable SIP support (default: no)])])
--   vars.config.in:40   {sip, @sip@}                         configure's choice becomes a rebar VARIABLE
--   rebar.config:128    {if_var_true, sip, {d, 'SIP'}}       the variable defines a MACRO …
--   rebar.config:38     {if_var_true, sip, {esip, …}}        … and pulls in a DEPENDENCY
--   src/mod_sip.erl     -ifndef(SIP). <stub> -else. <the real implementation, lines 45-477> -endif.
-- So mod_sip's implementation is IN the tree and compiled out by default; `--enable-sip` turns it on. Without this,
-- a reader sees `-behaviour(esip)` with no esip on the machine and concludes SIP is missing.
--
-- WHAT IT READS (each link cited by file:line; a link it cannot read is left out, never guessed):
--   M.configure(root) -> { [feature] = { name, flag, default = true|false|nil, desc, file, line } }
--   M.vars(root)      -> { [rebar var] = configure feature name }   ({var, @feature@} in vars.config.in; else same name)
--   M.rebar(root)     -> { macros = { [MACRO] = {var, when_ = true|false, file, line} },
--                          deps = { {name, var, when_, file, line} }, always = { [MACRO] = {file, line} } }
--   M.regions(file)   -> { {macro, kind = 'ifdef'|'ifndef', start, else_, stop}… }  preprocessor branches, nested
--   M.features(root)  -> per gated macro: its variable, the configure feature and its DEFAULT, the dependencies the
--                        variable pulls in, and every region whose default-compiled branch EXCLUDES code (with the
--                        disabled line range and the functions defined in it)
--   M.disabled_at(F, file, line) -> the feature that compiles `file:line` out by default, or nil
local M = {}

local function read(p)
    local fd = io.open(p, 'rb'); if not fd then return nil end
    local s = fd:read('a'); fd:close(); return s
end

local function lines_of(src)
    local out, n = {}, 0
    for l in (src .. '\n'):gmatch('([^\n]*)\n') do n = n + 1; out[n] = l end
    return out
end

--- configure.ac feature switches and their DEFAULT, read from the help string the maintainers wrote
function M.configure(root)
    local path = root .. '/configure.ac'
    local src = read(path)
    local out = {}
    if not src then return out end
    local L = lines_of(src)
    for i, l in ipairs(L) do
        local name = l:match('AC_ARG_ENABLE%(%s*%[?([%w_-]+)%]?%s*,')
        if name then
            -- the help string may sit on this line or the next few
            local block = table.concat(L, '\n', i, math.min(#L, i + 3))
            local flag, desc = block:match('AS_HELP_STRING%(%[(%-%-[%w_-]+)%]%s*,%s*%[(.-)%]%)')
            local default
            local d = desc and desc:match('default:%s*(%a+)')
            if d then default = (d == 'yes' or d == 'on' or d == 'true')
            elseif flag and flag:match('^%-%-disable%-') then default = true
            elseif flag and flag:match('^%-%-enable%-') then default = false end
            out[name] = { name = name, flag = flag, default = default, desc = desc, file = path, line = i }
        end
    end
    return out
end

--- rebar variable -> configure feature ({var, @feature@} in vars.config.in)
function M.vars(root)
    local out = {}
    local src = read(root .. '/vars.config.in')
    if not src then return out end
    for var, feat in src:gmatch('{%s*([%w_]+)%s*,%s*@([%w_]+)@%s*}') do out[var] = feat end
    return out
end

local function atom(t) return t and t.t == 'atom' and t.v or nil end

--- what rebar.config's if_var_true / if_var_false wrappers gate: macros (erl_opts {d, 'M'}) and dependencies
function M.rebar(root)
    local path = root .. '/rebar.config'
    local out = { macros = {}, deps = {}, always = {} }
    local src = read(path)
    if not src then return out end
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'erlang')
    if not ok then return out end
    local XS = require 'cartograph.xmppspec'
    local troot = parser:parse()[1]:root()
    local terms = {}
    local function collect(n)
        for c in n:iter_children() do
            if c:named() then
                local t = c:type()
                if t == 'tuple' or t == 'list' then terms[#terms + 1] = XS.term(c, src) else collect(c) end
            end
        end
    end
    collect(troot)
    -- `in_deps`: inside the {deps, […]} section — only there is a gated {Name, Vsn, Src} a DEPENDENCY (a provider
    -- hook `{compile, {elixir, compile}}` elsewhere has the same shape)
    local function walk(x, gate, in_deps)
        if type(x) ~= 'table' then return end
        if x.t == 'tuple' then
            local head = atom(x.items[1])
            if (head == 'if_var_true' or head == 'if_var_false') and atom(x.items[2]) then
                local g = { var = atom(x.items[2]), when_ = head == 'if_var_true' }
                for i = 3, #x.items do walk(x.items[i], g, in_deps) end
                return
            end
            if head == 'deps' and x.items[2] and x.items[2].t == 'list' then
                for _, c in ipairs(x.items[2].items) do walk(c, gate, true) end
                return
            end
            if head == 'd' and atom(x.items[2]) then
                local m = atom(x.items[2])
                if gate then out.macros[m] = { var = gate.var, when_ = gate.when_, file = path, line = x.line }
                else out.always[m] = { file = path, line = x.line } end
                return
            end
            -- a dependency tuple under a gate: {name, Vsn, Source} with a version/source after the name
            if gate and in_deps and head and x.items[2] and (x.items[2].t == 'bin' or x.items[2].t == 'expr' or x.items[2].t == 'tuple'
                    or (x.items[2].text or ''):match('^"')) then
                out.deps[#out.deps + 1] = { name = head, var = gate.var, when_ = gate.when_, file = path, line = x.line }
                return
            end
        end
        for _, c in ipairs(x.items or {}) do walk(c, gate, in_deps) end
    end
    for _, t in ipairs(terms) do walk(t, nil, false) end
    return out
end

--- the preprocessor branches of one erlang file, nested: -ifdef/-ifndef … [-else] … -endif (an -if(Expr) is
--- tracked for nesting only)
function M.regions(file)
    local src = read(file)
    local out = {}
    if not src then return out end
    local stack = {}
    for i, l in ipairs(lines_of(src)) do
        local kind, m = l:match("^%-(ifn?def)%(%s*'?([%w_]+)'?%s*%)")
        if kind then
            stack[#stack + 1] = { macro = m, kind = kind, start = i }
        elseif l:match('^%-if%(') then
            stack[#stack + 1] = { macro = nil, kind = 'if', start = i }
        elseif l:match('^%-else%.') then
            if stack[#stack] then stack[#stack].else_ = i end
        elseif l:match('^%-endif%.') then
            local r = table.remove(stack)
            if r and r.macro then r.stop = i; out[#out + 1] = r end
        end
    end
    return out
end

-- the functions DEFINED on lines [a, b] of a file (a clause head at column 0: `name(`), distinct, in order
local function functions_in(L, a, b)
    local out, seen = {}, {}
    for i = a, b do
        local nm = (L[i] or ''):match('^([a-z][%w_]*)%(')
        if nm and not seen[nm] then seen[nm] = true; out[#out + 1] = nm end
    end
    return out
end

--- per gated macro: the chain from configure to the code it compiles out by default
function M.features(root)
    local conf, vars, rb = M.configure(root), M.vars(root), M.rebar(root)
    local feats = {}
    for macro, g in pairs(rb.macros) do
        local fname = vars[g.var] or g.var
        local cf = conf[fname]
        -- the macro is DEFINED by default when the variable's default makes the gate fire
        local var_default = cf and cf.default
        local defined = nil
        if var_default ~= nil then defined = (var_default == g.when_) end
        local f = { macro = macro, var = g.var, gate = g, configure = cf, defined_by_default = defined,
            deps = {}, regions = {} }
        for _, d in ipairs(rb.deps) do if d.var == g.var then f.deps[#f.deps + 1] = d end end
        feats[macro] = f
    end
    for _, dir in ipairs({ 'src', 'include' }) do
        for _, file in ipairs(vim.fn.glob(root .. '/' .. dir .. '/*.[eh]rl', false, true)) do
            local L
            for _, r in ipairs(M.regions(file)) do
                local f = feats[r.macro]
                if f and f.defined_by_default ~= nil then
                    L = L or lines_of(read(file) or '')
                    -- the branch compiled when the macro is NOT defined (default off): ifndef's THEN, ifdef's ELSE
                    local on_a, on_b -- the branch that needs the feature ON
                    local then_a, then_b = r.start + 1, (r.else_ or r.stop) - 1
                    local else_a, else_b = r.else_ and (r.else_ + 1) or nil, r.else_ and (r.stop - 1) or nil
                    if r.kind == 'ifdef' then on_a, on_b = then_a, then_b else on_a, on_b = else_a, else_b end
                    local off_default = f.defined_by_default == false
                    if on_a and on_b and on_b >= on_a then
                        f.regions[#f.regions + 1] = { file = file, directive = r.start, kind = r.kind,
                            first = on_a, last = on_b, lines = on_b - on_a + 1, compiled_by_default = not off_default,
                            functions = functions_in(L, on_a, on_b) }
                    end
                end
            end
        end
    end
    local out = {}
    for _, f in pairs(feats) do out[#out + 1] = f end
    table.sort(out, function (a, b) return a.macro < b.macro end)
    return out
end

--- the feature that compiles `file:line` out by default, or nil
function M.disabled_at(feats, file, line)
    for _, f in ipairs(feats or {}) do
        for _, r in ipairs(f.regions) do
            if not r.compiled_by_default and r.file == file and line >= r.first and line <= r.last then return f, r end
        end
    end
    -- the directive line itself (`-behaviour(esip)` sits inside the else branch; a line ON the branch counts too)
    return nil
end

return M
