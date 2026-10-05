-- cartograph.luajs.csig — LUA LIBRARY SIGNATURES FROM LuaJIT's OWN C (CART-1240 leaf 1), joined against the
-- lua-language-server annotations the `luajit` profile carries today.
--
-- A C library function states each argument's type where it READS the argument: `lj_lib_checknum(L, 2)` is "argument
-- 2 is a number". What each CHECKER means is read from its own body, never listed:
--   · its TYPE is the constant its own raise names — `lj_err_argt(L, narg, LUA_TNUMBER)` (lua.h's LUA_T* spelled as
--     Lua's type() names) — or, for a checker that only delegates (`optstr` → `checkstr`), the one it calls;
--   · it is OPTIONAL when its body accepts nil (`tvisnil`), and a checker whose optionality turns on one of its own
--     parameters (`checkopt`: `def >= 0 ? optstr : checkstr`) is decided at each call site by that literal;
--   · an INTEGER refinement when its C return type is an integer type and its type number (`checkint` → int32_t);
--   · its COERCIONS: the other tags it accepts on the way (`checkstr` takes a number, `checknum` a numeric string),
--     through lj_obj.h's own `tvis*` → LJ_T* → lj_obj_itypename.
-- A signature is COMPLETE only when the body reads its arguments through checkers at literal positions and nothing
-- else; a direct slot read (`L->base`, `L->top`), a position that is not a literal, or a same-unit helper handed `L`
-- makes it PARTIAL — and a partial signature is compared only at the positions it states.
local tsutil = require 'cartograph.spec.tsutil' -- (tsutil.inext: indexed child iteration, CART-1453)
local M = {}

local function readfile(p) local fd = io.open(p, 'rb'); if not fd then return nil end local s = fd:read('a'); fd:close(); return s end
local function sorted(set) local l = vim.tbl_keys(set); table.sort(l); return l end

--- Lua's type() name of each LUA_T* constant (lua.h), and of each LJ_T* tag via lj_obj_itypename (lj_obj.c):
--- -> { luat = { NUMBER = 'number', … }, tvis = { tvisstr = 'string', … } }
function M.vocabulary(src)
    local luat = {}
    local luanum = {}
    for name, n in (readfile(src .. '/lua.h') or ''):gmatch('#define%s+LUA_T(%u+)%s+(%-?%d+)') do
        if name ~= 'NONE' then luat[name] = name:lower(); luanum[tonumber(n)] = name:lower() end
    end
    local names = {}
    local itn = (readfile(src .. '/lj_obj.c') or ''):match('lj_obj_itypename%[%]%s*=%s*{(.-)}')
    for s in (itn or ''):gmatch('"([^"]*)"') do names[#names + 1] = s end
    local objh = readfile(src .. '/lj_obj.h') or ''
    local tag = {}
    for t, n in objh:gmatch('#define%s+(LJ_T[%u%d_]+)%s+%(~(%d+)u%)') do tag[t] = names[tonumber(n) + 1] end
    -- (a tag defined as ANOTHER tag: `#define LJ_TISNUM LJ_TNUMX`)
    for t, u in objh:gmatch('#define%s+(LJ_T[%u%d_]+)%s+(LJ_T[%u%d_]+)%s') do if tag[u] and not tag[t] then tag[t] = tag[u] end end
    local tvis = {}
    for fn, op, t in objh:gmatch('#define%s+(tvis[%w_]+)%(o%)%s+%(itype%(o%)%s*([<=]=?)%s*(LJ_T[%u%d_]+)%)') do
        if tag[t] and tvis[fn] == nil then tvis[fn] = tag[t] end
    end
    tvis.tvisnil = tvis.tvisnil or 'nil' -- (the GC64 form tests it64 == -1: its tag is LJ_TNIL's, index 0)
    local luanil
    for n, t in pairs(luanum) do if t == 'nil' then luanil = n end end
    return { luat = luat, luanum = luanum, luanil = luanil, tvis = tvis }
end

--- THE CHECKER TABLE: every function of the tree taking `(lua_State *L, int <pos>, …)` whose body RAISES on that
--- position — LuaJIT's own lj_lib_* (lj_lib.c) and the Lua API's luaL_* (lj_api.c) alike — what it accepts, derived
--- from its body -> { [name] = { types, opt = bool | { param = i }, integer, coerces, from_arg = i (its type is that
--- call-site argument: luaL_checktype's `tt`), named = i (a userdata NAMED by that argument: luaL_checkudata),
--- delegates, rule } }
function M.checkers(src, vocab, noret)
    local fns = {} -- name -> { ret, params = { names }, pos, body }
    for _, path in ipairs(vim.fn.globpath(src, '*.c', false, true)) do
        local text = readfile(path) or ''
        -- (a definition at column 0 — its parameter list may span lines — and its body to the next `}` at column 0)
        for ret, name, params, body in ('\n' .. text):gmatch('\n([%w_ %*]-)([%a_][%w_]*)%(([^)]*)%)%s*\n{(.-)\n}') do
            local pos = params:match('^%s*lua_State%s*%*%s*L%s*,%s*int%s+([%a_][%w_]*)')
            -- (a RAISER is the rejection itself, not a check: lj_err_argt — the tree's noreturn set)
            if pos and not fns[name] and not (noret and noret[name]) then
                local pn = {}
                for q in (params .. ','):gmatch('([^,]*),') do pn[#pn + 1] = q:match('([%a_][%w_]*)%s*$') end
                fns[name] = { ret = ret, params = pn, pos = pos, body = body }
            end
        end
    end
    local out, tested = {}, {}
    for name, f in pairs(fns) do
        local P, body = vim.pesc(f.pos), f.body
        local c = { types = {}, coerces = {}, delegates = {}, rule = {} }
        local raises = false
        -- the RAISE on the position: lj_err_argt(L, pos, <type>) / lj_err_argtype(L, pos, <name>) / lj_err_arg(L, pos, …)
        for fnm, arg in body:gmatch('(lj_err_arg[%w_]*)%(%s*L%s*,%s*' .. P .. '%s*,%s*([^)]-)%s*%)') do
            raises = true
            local t = arg:match('^LUA_T(%u+)$')
            if t and vocab.luat[t] then c.types[vocab.luat[t]] = true
            elseif arg == 'LJ_ERR_NOVAL' then c.any = true
            else
                for i, q in ipairs(f.params) do
                    if q == arg then if fnm == 'lj_err_argtype' then c.named = i else c.from_arg = i end end
                end
            end
        end
        if next(c.types) then c.rule[#c.rule + 1] = 'its raise names the type' end
        if c.any then c.rule[#c.rule + 1] = 'it raises only "value expected"' end
        if c.from_arg then c.rule[#c.rule + 1] = 'its raise takes the type from argument ' .. c.from_arg end
        if c.named then c.rule[#c.rule + 1] = 'its raise names a userdata by argument ' .. c.named end
        -- the calls handing the position on: to a checker (inherit it) or to a helper (inherit the tags it tests)
        for d in body:gmatch('([%a_][%w_]*)%(%s*L%s*,%s*%(?' .. P .. '%)?%s*[,)]') do if d ~= name and fns[d] then c.delegates[d] = true end end
        if body:find('tvisnil', 1, true) then c.opt = true; c.rule[#c.rule + 1] = 'it accepts nil' end
        -- optionality turned by one of its OWN parameters: `def >= 0 ? optX : checkX` (checkopt) or `def ? optX :
        -- checkX` (luaL_checkoption: a NULL default is required) — decided at each call site by that argument
        local cond, truthy = body:match('([%a_][%w_]*)%s*>=%s*0%s*%?%s*[%a_][%w_]*opt'), nil
        if not cond then cond = body:match('([%a_][%w_]*)%s*%?%s*[%a_][%w_]*opt'); truthy = cond ~= nil end
        -- (or a FALLBACK to it before the raise: `if (s == NULL && (s = def) == NULL) raise` — luaL_checkoption)
        if not cond then cond = body:match('%(%s*[%a_][%w_]*%s*=%s*([%a_][%w_]*)%s*%)%s*==%s*NULL'); truthy = cond ~= nil end
        if cond then
            for i, q in ipairs(f.params) do if q == cond then c.opt = { param = i, truthy = truthy } end end
            c.rule[#c.rule + 1] = 'optional when its argument ' .. cond .. (truthy and ' is not NULL' or ' >= 0')
        end
        if f.ret:find('int32_t') or f.ret:find('lua_Integer') or f.ret:match('^%s*int%s') or f.ret:match('%sint%s*$') then c.integer = true end
        local tv = {}
        for fn in body:gmatch('(tvis[%w_]+)%(') do local t = vocab.tvis[fn]; if t and t ~= 'nil' then tv[t] = true end end
        tested[name] = tv
        c.coerces = vim.deepcopy(tv)
        -- a checker that only asks for PRESENCE and then hands the slot on (`o = L->base + narg-1` into
        -- lj_cconv_ct_tv: FFI's) accepts what THAT function converts — its type is not this body's to state
        local slot = body:match('([%a_][%w_]*)%s*=%s*L%->base%s*%+%s*' .. P) or body:match('([%a_][%w_]*)%s*=%s*index2adr%(%s*L%s*,%s*' .. P .. '%s*%)')
        if slot then
            for callee, args in body:gmatch('([%a_][%w_]*)(%b())') do
                if not callee:match('^tvis') and callee ~= 'index2adr' and args:find('%f[%w_]' .. slot .. '%f[^%w_]') then c.handoff = c.handoff or callee end
            end
        end
        -- a raise with NO condition before it is the rejection itself, not a check (luaL_typerror)
        c.raises = raises and (body:find('if%s*%(') or body:find('%?') or body:find('&&') or body:find('||')) ~= nil
        if raises and not c.raises then c.raiser = true end
        out[name] = c
    end
    -- delegation to a fixed point: a checker's types are its own or its checkers'; a helper's tested tags flow up
    local changed = true
    while changed do
        changed = false
        for name, c in pairs(out) do
            for d in pairs(c.delegates) do
                local dc = out[d]
                if not dc.raiser and (dc.raises or next(dc.types) or dc.any) then
                    if not c.checker_via then c.checker_via = d; changed = true end
                    for t in pairs(dc.types) do if not c.types[t] then c.types[t] = true; changed = true end end
                    if dc.any and not c.any then c.any = true; changed = true end
                    if dc.integer and not c.integer and not c.opt and not next(tested[name]) then c.integer = true; changed = true end
                    if dc.opt == true and not c.opt then end
                end
                for t in pairs(tested[d] or {}) do if not c.coerces[t] then c.coerces[t] = true; changed = true end end
            end
        end
    end
    local final = {}
    for name, c in pairs(out) do
        if (c.raises or c.checker_via) and not c.raiser then
            if c.checker_via and #c.rule == 0 then c.rule[#c.rule + 1] = 'delegates to ' .. c.checker_via end
            if c.any and c.handoff then
                c.converts = c.handoff
                c.rule[#c.rule + 1] = 'its slot is converted by ' .. c.handoff .. ': the type is that function\'s'
            end
            if c.any then c.types = { any = true } end
            if not next(c.types) and not c.from_arg and next(c.coerces) then
                c.types, c.coerces = c.coerces, {}
                c.rule[#c.rule + 1] = 'its raise names no type: the tags it tests'
            end
            -- a userdata NAMED by an argument (luaL_checkudata: its helper tests tvisudata — and the metatable's
            -- tag, which is not the argument's)
            if c.named and c.types.userdata then c.types = { userdata = true } end
            -- a type taken from a call-site ARGUMENT (luaL_checktype's `tt`) has no coercions of its own: the tags its
            -- helper tests are the argument's, not this checker's (found by the path reading, CART-1240 leaf 2)
            if c.from_arg then c.coerces = {} end
            if not (c.types.number and vim.tbl_count(c.types) == 1) then c.integer = nil end
            for t in pairs(c.types) do c.coerces[t] = nil end
            c.types, c.coerces, c.delegates = sorted(c.types), sorted(c.coerces), sorted(c.delegates)
            final[name] = c
        end
    end
    return final
end

--- the ARGUMENTS of a C function body, read at its checker calls. `unit` = the preprocessed unit text, `body` the
--- function node (tree-sitter), `helpers` = { [name] = body text } of the unit's own functions -> {
---   params = { [position] = { types, opt, integer, coerces, checker } }, complete = bool, partial = { reasons } }
function M.signature(unit, fnode, checkers, helpers, vocab)
    local sig = { params = {}, complete = true, partial = {} }
    local function why(r) sig.complete = false; if not vim.tbl_contains(sig.partial, r) then sig.partial[#sig.partial + 1] = r end end
    local body = vim.treesitter.get_node_text(fnode, unit)
    local q = vim.treesitter.query.parse('c', '(call_expression function: (identifier) @f arguments: (argument_list) @a)')
    for id, node in q:iter_captures(fnode, unit, 0, -1) do
        if q.captures[id] == 'f' then
            local name = vim.treesitter.get_node_text(node, unit)
            local args = {}
            local al = node:next_named_sibling()
            for _, a in tsutil.inext, al, -1 do if a:named() and a:type() ~= 'comment' then args[#args + 1] = vim.treesitter.get_node_text(a, unit) end end
            local c = checkers[name]
            if c and args[1] == 'L' then
                -- (the preprocessor parenthesizes a macro's argument: `(1)`)
                local k = tonumber(((args[2] or ''):gsub('^%((.*)%)$', '%1')))
                if not k then why('a position that is not a literal (' .. tostring(args[2]) .. ')')
                else
                    local opt = c.opt == true
                    if type(c.opt) == 'table' then
                        local a = vim.trim(args[c.opt.param] or '')
                        if c.opt.truthy then
                            -- NULL preprocesses to `((void *)0)`
                            local null = a == '0' or a:gsub('%s', '') == '((void*)0)'
                            if a:match('^"') then opt = true elseif null then opt = false else why('an optionality that is not a literal') end
                        else
                            local v = tonumber(a)
                            if v == nil then why('an optionality that is not a literal') else opt = v >= 0 end
                        end
                    end
                    -- GUARDED by its own position being none or nil — `lua_type(L, k) <= <LUA_TNIL> ? default : check`
                    -- (luaL_opt's expansion): the check runs only when a value is there, so the argument is optional
                    if not opt and vocab.luanil then
                        local anc = node:parent()
                        -- (a conditional expression, or an `if` whose ELSE holds the check: lua_isnoneornil's expansion)
                        local child = node
                        while anc and anc ~= fnode do
                            local t = anc:type()
                            local guarded = t == 'conditional_expression'
                                or (t == 'if_statement' and anc:field('alternative')[1] and child:equal(anc:field('alternative')[1]))
                            if guarded then
                                local ctext = vim.treesitter.get_node_text(anc:field('condition')[1], unit):gsub('%s', '')
                                local lim = ctext:match('lua_type%(L,%(?' .. k .. '%)?%)<=(%-?%d+)')
                                if lim and tonumber(lim) >= vocab.luanil then opt = true end
                            end
                            child, anc = anc, anc:parent()
                        end
                    end
                    local types = c.types
                    if c.converts then types = { '?' } end
                    if c.from_arg then
                        local t = vocab.luanum[tonumber(args[c.from_arg] or '')]
                        if t then types = { t } else why('a type that is not a literal (' .. tostring(args[c.from_arg]) .. ')') end
                    end
                    local p = sig.params[k]
                    if p and p.checker ~= name then
                        -- the same position read twice (alternative branches): the union, optional if either is
                        local u = {}
                        for _, t in ipairs(p.types) do u[t] = true end
                        for _, t in ipairs(types) do u[t] = true end
                        p.types, p.opt, p.checker = sorted(u), p.opt or opt, p.checker .. '|' .. name
                    elseif not p then
                        local br, a2 = false, node:parent()
                        while a2 and a2 ~= fnode do
                            local t = a2:type()
                            if t == 'if_statement' or t == 'conditional_expression' or t == 'switch_statement' or t == 'case_statement' then br = true end
                            a2 = a2:parent()
                        end
                        sig.params[k] = { types = types, opt = opt, integer = c.integer, coerces = c.coerces, checker = name, branched = br,
                            named = c.named and args[c.named] and args[c.named]:match('^"(.*)"$') or nil }
                    end
                end
            elseif helpers[name] and vim.tbl_contains(args, 'L') then
                local hb = helpers[name]
                if hb:find('L%->base') or hb:find('L%->top') or hb:find('lj_lib_check') or hb:find('lj_lib_opt') then
                    why('a helper reads the arguments (' .. name .. ')')
                end
            end
        end
    end
    -- DIRECT slot reads: at a position the text names (`L->base` is argument 1, `L->base+k` / `L->base[k]` argument
    -- k+1) that argument is OPEN — the body may accept more there than its checker says (os.exit reads a boolean
    -- before it calls optint) — and is not compared; a base pointer kept in a variable names no position: every
    -- stated position is open. `L->top` alone (the argument COUNT) opens none, but the signature is not complete.
    sig.open = {}
    local b2 = body:gsub('%s+', ' ')
    -- (an offset is an EXPRESSION of literals — `L->base+3-1` is argument 3, not 4)
    local function offset(e)
        e = e:gsub('%s', '')
        if not e:match('^%d[%d%+%-]*$') then return nil end
        local v = 0
        for sign, n in ('+' .. e):gmatch('([%+%-])(%d+)') do v = v + (sign == '-' and -1 or 1) * tonumber(n) end
        return v
    end
    for e in b2:gmatch('L%->base ?%+ ?(%d[%d %+%-]*%d?)') do local v = offset(e); if v then sig.open[v + 1] = true end end
    for k in b2:gmatch('L%->base ?%[ ?(%d+) ?%]') do sig.open[tonumber(k) + 1] = true end
    local rest = b2:gsub('L%->base ?%+ ?%d[%d %+%-]*%d?', ''):gsub('L%->base ?%[ ?%d+ ?%]', '')
    for ctx in rest:gmatch('(.-)L%->base') do
        local after = rest:match('L%->base(..?.?)') or ''
        if ctx:match('[%w_]+ ?=%s*$') or ctx:match('[%w_]+ ?= ?%(?[%w_ %*]*%)? ?$') then sig.aliased = true end
    end
    if rest:find('L%->base') and not sig.aliased then sig.open[1] = true end
    if next(sig.open) or sig.aliased then why('reads an argument slot directly') end
    if body:find('L%->top') then
        why('reads the argument count')
        -- a check under a BRANCH of a body that reads the count (math.random's `if (n == 2)`, table.insert's 2-or-3
        -- arguments): whether it is required depends on how many were passed — an overload, its optionality not a fact
        for k, p in pairs(sig.params) do if p.branched and not p.opt then p.dispatch = true end end
    end
    if sig.aliased then for k in pairs(sig.params) do sig.open[k] = true end end
    return sig
end

--- a lua-ls TYPE expression as Lua's type() names -> set, or nil + the alias it could not resolve. `aliases` = M.aliases
local BASIC = { number = 'number', integer = 'number', string = 'string', boolean = 'boolean', table = 'table',
    ['function'] = 'function', ['nil'] = 'nil', thread = 'thread', userdata = 'userdata', lightuserdata = 'userdata',
    any = 'any', unknown = 'any', ['true'] = 'boolean', ['false'] = 'boolean' }
M.BASIC = BASIC -- (the annotation language's own base types: lua-ls's grammar, not a claim about any library)
function M.luals_type(t, aliases, depth)
    depth = depth or 0
    t = vim.trim(t or '')
    if t == '' then return { any = true } end
    local out, unresolved = {}, nil
    -- the top-level alternatives (a `|` inside `fun(...)` / `table<…>` / `{…}` does not split)
    local parts, lvl, cur = {}, 0, ''
    for ch in t:gmatch('.') do
        if ch == '(' or ch == '<' or ch == '{' or ch == '[' then lvl = lvl + 1 elseif ch == ')' or ch == '>' or ch == '}' or ch == ']' then lvl = lvl - 1 end
        if ch == '|' and lvl == 0 then parts[#parts + 1] = cur; cur = '' else cur = cur .. ch end
    end
    parts[#parts + 1] = cur
    for _, p in ipairs(parts) do
        p = vim.trim(p):gsub('%?$', '')
        if p:match('^["\']') or p:match('^`') then out.string = true
        elseif p:match('^%-?%d') then out.number = true
        elseif p:match('^fun%s*%(') or p:match('^async%s+fun') then out['function'] = true
        elseif p:match('%[%]$') or p:match('^table%s*<') or p:match('^{') then out.table = true
        elseif BASIC[p] then out[BASIC[p]] = true
        elseif p:match('^%u$') or p:match('^%u%d?$') then out.any = true -- a generic parameter (T, K, V)
        elseif aliases[p] and depth < 8 then
            local s, u = M.luals_type(aliases[p], aliases, depth + 1)
            if s then for k in pairs(s) do out[k] = true end else unresolved = u end
        else unresolved = unresolved or p end
    end
    if unresolved and not next(out) then return nil, unresolved end
    if out.any then return { any = true } end
    return out, unresolved
end

--- every `---@alias NAME [type]` (and the `---| alternative` lines under it) of the meta dir -> { [name] = type }
function M.aliases(meta_dir)
    local out = {}
    for _, p in ipairs(vim.fn.globpath(meta_dir, '*.lua', false, true)) do
        local cur
        for line in ((readfile(p) or '') .. '\n'):gmatch('(.-)\n') do
            local name, ty = line:match('^%-%-%-@alias%s+([%w_%.%*]+)%s*(.-)%s*$')
            if name then
                out[name] = ty ~= '' and ty or nil
                cur = name
            elseif cur and line:match('^%-%-%-%s*|') then
                local alt = vim.trim(line:match('^%-%-%-%s*|%s*([^#]*)') or '') -- (a `# …` comment may follow)
                alt = alt:gsub('^[%+>]', '') -- (`>` marks the default alternative, `+` an extensible one)
                if alt ~= '' then out[cur] = out[cur] and (out[cur] .. '|' .. alt) or alt end
            elseif not line:match('^%-%-%-') then cur = nil end
        end
    end
    return out
end

--- a profile signature (the luajit profile's `sigs[key]`) as positions -> { [k] = { types, opt } }, vararg, unresolved
function M.luals_sig(sig, aliases)
    local params, unresolved = {}, {}
    local vararg
    for i, p in ipairs(sig.params or {}) do
        if p.name == '...' then vararg = true; break end
        local s, u = M.luals_type(p.type, aliases)
        if u then unresolved[#unresolved + 1] = u end
        params[i] = { types = s and sorted(s) or nil, opt = p.opt and true or false }
    end
    return params, vararg, unresolved
end

--- a message pattern from an ERRDEF text (`%d` a number, `%s` any text) — the witness reads LuaJIT's OWN wording
function M.errpattern(text)
    local pat = text:gsub('[%^%$%(%)%.%[%]%*%+%-%?]', '%%%0'):gsub('%%d', '(%%d+)'):gsub('%%s', '(.-)')
    return '^' .. pat .. '$'
end

--- THE DYNAMIC WITNESS (a child LuaJIT per function: nvim's, the oracle). For each stated, closed position of a
--- signature: probe it with a value its derived type REJECTS (the positions before it given values of theirs), and a
--- required one with nil; read which argument LuaJIT names and what it says is expected, through its own ERRDEF texts.
--- jobs = { { q, params = { [k] = { types, opt } } } }, errs = packmap's ERRDEF texts -> { [q] = { [k] = {…} } }
local REPR = { number = '1', string = '"a"', table = '{}', ['function'] = 'function () end', boolean = 'true', ['nil'] = 'nil' }
M.REPR = REPR -- (a VALUE of each type() for the probes: the language's literals, no library claim)
function M.witness(jobs, errs, opts)
    opts = opts or {}
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local out = {}
    local badarg, badtype = M.errpattern(errs.BADARG or ''), M.errpattern(errs.BADTYPE or '')
    for _, j in ipairs(jobs) do
        local lines = {
            'local path = ' .. ('%q'):format(j.q),
            "local f = _G; for part in path:gmatch('[^.]+') do f = type(f) == 'table' and f[part] or nil end",
            "if f == nil then local mod, name = path:match('^(.*)%.([^.]+)$'); local ok, m = pcall(require, mod); f = ok and type(m) == 'table' and m[name] or nil end",
            'local res = {}',
            'local function probe(k, args, n)',
            '  local ok, err = pcall(f, unpack(args, 1, n))',
            '  res[#res + 1] = { k = k, ok = ok, err = not ok and tostring(err) or nil }',
            'end',
        }
        local ks = vim.tbl_keys(j.params); table.sort(ks)
        for _, k in ipairs(ks) do
            local p = j.params[k]
            local prefix, ok = {}, true
            for i = 1, k - 1 do
                local q = (j.prefix or {})[i] or j.params[i]
                local t = q and q.types and q.types[1]
                if not q then prefix[i] = '1' -- (an unstated position: a number, the commonest)
                elseif REPR[t] then prefix[i] = REPR[t] else ok = false end
            end
            if ok and p.types and p.types[1] ~= 'any' and p.types[1] ~= '?' and not p.dispatch then
                local acc = {}
                for _, t in ipairs(p.all or p.types) do acc[t] = true end
                local bad = (not acc.boolean and 'boolean') or (not acc.table and 'table') or nil
                if bad then
                    local a = vim.deepcopy(prefix); a[k] = REPR[bad]
                    lines[#lines + 1] = ('probe(%d, { %s }, %d)'):format(k, table.concat(a, ', '), k)
                end
            end
            if ok and not p.opt and not p.dispatch then
                -- REQUIRED: probed ABSENT (an explicit nil is a value to checkany: getfenv(nil) is legal)
                lines[#lines + 1] = ('probe(%d, { %s }, %d)'):format(k, table.concat(prefix, ', '), k - 1)
            end
        end
        lines[#lines + 1] = ('local fd = io.open(%q, "w"); fd:write(vim.json.encode(res)); fd:close()'):format(dir .. '/out.json')
        local script = dir .. '/w.lua'
        local fd = assert(io.open(script, 'w')); fd:write(table.concat(lines, '\n')); fd:close()
        os.remove(dir .. '/out.json')
        -- its own process group, killed whole on the timeout (a probe the function ACCEPTS runs it for real)
        local proc = vim.system({ 'setsid', vim.v.progpath, '--headless', '-u', 'NONE', '-l', script }, { cwd = dir, stdin = false, text = true })
        local r = proc:wait(opts.timeout or 10000)
        if not r or r.signal == 15 or r.signal == 9 then vim.system({ 'kill', '-9', '--', '-' .. proc.pid }):wait() end
        local got = io.open(dir .. '/out.json')
        local res = got and vim.json.decode(got:read('a')) or nil
        if got then got:close() end
        out[j.q] = { probes = {}, lost = res == nil and (r and ('exit ' .. tostring(r.code)) or 'timed out') or nil }
        for _, e in ipairs(res or {}) do
            local rec = { k = e.k, ok = e.ok }
            if e.err then
                local msg = e.err:gsub('^[^:]*:%d+: ', '')
                local n, _, inner = msg:match(badarg)
                if n then
                    rec.at = tonumber(n)
                    local exp = inner:match(badtype)
                    rec.expected = exp or inner
                else rec.other = msg end
            end
            table.insert(out[j.q].probes, rec)
        end
    end
    vim.fn.delete(dir, 'rf')
    return out
end

-- ── THE MEASUREMENT: read both sides, join them, witness the C side ─────────────────────────────────────────────────
-- (oraclejoin compares kv VALUES — an object is { keys = ordered, o = map }; a plain Lua table is a scalar to it)
local function kvobj(map)
    local keys = vim.tbl_keys(map); table.sort(keys)
    return { keys = keys, o = map }
end
--- a position's ACCEPTED set: its type and its coercions (lua-ls writes a coercion into the type sometimes)
local function accepted(p)
    local u = {}
    for _, t in ipairs(p.types) do u[t] = true end
    for _, t in ipairs(p.coerces or {}) do u[t] = true end
    if u.any then return { 'any' } end
    return sorted(u)
end
M.accepted = accepted

--- the join's rule, per position C states: lua-ls names C's BASE type, or its base type with its coercions; the same
--- optionality (unless C's is count-dispatched: an overload); a type either side cannot state (`?`) is not compared
function M.agree(a, b)
    for _, k in ipairs(a.keys) do
        local x, y = a.o[k].o, b.o[k] and b.o[k].o
        if not y then return false end
        if not (y.t == '?' or x.t == '?') then
            if x.opt ~= y.opt and not x.dispatch then return false end
            if (y.t == 'any') ~= (x.t == 'any') then return false end
            if y.t ~= x.t and y.t ~= x.all and y.t ~= 'any' then return false end
        end
    end
    for _, k in ipairs(b.keys) do if not a.o[k] then return false end end
    return true
end

--- the disagreement's cause, NAMED BY THE PAIR (the first position where the rule fails)
function M.cause(_, _, a, b)
    for _, k in ipairs(a.keys) do
        local x, y = a.o[k].o, b.o[k] and b.o[k].o
        if not y then return 'lua-ls declares no such argument (C reads it)' end
        if not (y.t == '?' or x.t == '?') then
            if x.t == 'any' and y.t ~= 'any' then return ('type: C any / lua-ls %s'):format(y.t) end
            if y.t == 'any' and x.t ~= 'any' then return ('type: C %s / lua-ls any'):format(x.t) end
            if y.t ~= x.t and y.t ~= x.all then return ('type: C %s%s / lua-ls %s'):format(x.t, x.all ~= x.t and (' (accepts ' .. x.all .. ')') or '', y.t) end
            if x.opt ~= y.opt and not x.dispatch then return ('optional: C %s / lua-ls %s'):format(tostring(x.opt), tostring(y.opt)) end
        end
    end
    return 'lua-ls declares an argument C never reads'
end

--- opts: { src (a BUILT LuaJIT src dir: tools/packmap.lua's tree), cflags, config (the oracle's gates), profile (the
--- luajit profile's decoded table), witness = bool } -> the whole measurement (see tools/csig.lua for its report)
function M.measure(opts)
    local PM, B, OJ = require 'cartograph.luajs.packmap', require 'cartograph.luajs.boundary', require 'cartograph.oraclejoin'
    local src = opts.src
    local reg = PM.registrations(src, opts.config)
    local oracle, where = PM.oracle_library(reg)
    local vocab = M.vocabulary(src)
    local checkers = M.checkers(src, vocab, B.noreturn(src))
    local sources = B.preprocess(src, opts.cflags)
    local defs = {}
    local fq = vim.treesitter.query.parse('c', '(function_definition declarator: (function_declarator declarator: (identifier) @n)) @f')
    for _, s in ipairs(sources) do
        local tree = vim.treesitter.get_string_parser(s.text, 'c'):parse()[1]
        local helpers, nodes, cur = {}, {}, nil
        for id, node in fq:iter_captures(tree:root(), s.text, 0, -1) do
            if fq.captures[id] == 'f' then cur = node
            else local nm = vim.treesitter.get_node_text(node, s.text); nodes[nm] = cur; helpers[nm] = vim.treesitter.get_node_text(cur, s.text) end
        end
        for nm, n in pairs(nodes) do defs[nm] = defs[nm] or { text = s.text, node = n, helpers = helpers } end
    end
    local ours, stats = {}, { complete = 0, partial = 0, nobody = 0, positions = 0, open = 0 }
    for _, f in ipairs(reg.funcs) do
        local rname = where[f.module]
        if not f.noreg and rname then
            local q = (rname == '_G' and '' or (rname .. '.')) .. f.name
            if not f.cfn then
                ours[q] = { refused = 'no C body: ' .. f.kind .. (f.kind == 'LUA' and ' (defined in Lua)' or ' (VM assembly only)') }
                stats.nobody = stats.nobody + 1
            elseif not defs[f.cfn] then
                ours[q] = { refused = 'no definition of ' .. f.cfn .. ' in the preprocessed tree' }
                stats.nobody = stats.nobody + 1
            else
                local d = defs[f.cfn]
                local sig = M.signature(d.text, d.node, checkers, d.helpers, vocab)
                ours[q] = { sig = sig }
                stats[sig.complete and 'complete' or 'partial'] = stats[sig.complete and 'complete' or 'partial'] + 1
                for k in pairs(sig.params) do stats.positions = stats.positions + 1; if sig.open[k] then stats.open = stats.open + 1 end end
            end
        end
    end
    local prof = opts.profile
    local meta = (prof.sig_source or ''):match(' at (.+)$')
    local aliases = meta and M.aliases(meta) or {}
    local function qkey(q) return (q:gsub('%.', '#', 1)) end
    local inputs, seen = {}, {}
    for q in pairs(ours) do inputs[#inputs + 1] = q; seen[q] = true end
    for k in pairs(prof.sigs or {}) do
        local q = k:gsub('#', '.', 1)
        if not seen[q] then inputs[#inputs + 1] = q; seen[q] = true end
    end
    table.sort(inputs)
    local compared, unres, refine = {}, {}, { both = 0, c_only = 0, luals_only = 0 }
    local R = OJ.run({
        inputs = inputs,
        read = function (q)
            local o = ours[q]
            if not o then
                -- WHY it is absent, from the ORACLE's live library: a function it has that no registration names (the
                -- package library registers through luaL_Reg), a lua-ls CLASS (`file`, `buf` — no library path), or a
                -- claim about a runtime that is not this one (`warn`: Lua 5.4)
                -- (the LIVE interpreter answers: packmap's oracle map covers the registered modules only, and the
                -- package library is none of them)
                local live = _G
                for part in q:gmatch('[^.]+') do live = type(live) == 'table' and rawget(live, part) or nil end
                if oracle[q] or type(live) == 'function' then return nil, 'in the oracle, but no LJLIB registration (a frontier of the registration reader)' end
                local root = q:match('^([^.]+)%.')
                if root and oracle[root] == nil and not q:find('^[%a_]+$') then
                    local any = false
                    for k in pairs(oracle) do if k:sub(1, #root + 1) == root .. '.' then any = true; break end end
                    if not any then return nil, 'a lua-ls class name, not a library path (' .. root .. ')' end
                end
                return nil, 'not in the oracle (a lua-ls claim about another runtime)'
            end
            if o.refused then return nil, o.refused end
            local pos = {}
            for k in pairs(o.sig.params) do if not o.sig.open[k] then pos[#pos + 1] = k end end
            table.sort(pos)
            if #pos == 0 then return nil, 'no argument read at a literal position (' .. (o.sig.partial[1] or 'it reads none') .. ')' end
            compared[q] = pos
            local v = {}
            for _, k in ipairs(pos) do
                local p = o.sig.params[k]
                v[tostring(k)] = kvobj({ t = table.concat(p.types, '|'), all = table.concat(accepted(p), '|'), opt = p.opt, dispatch = p.dispatch or false })
            end
            return kvobj(v)
        end,
        oracle = function (q)
            local ls = prof.sigs[qkey(q)] or prof.sigs[q]
            if not ls then return nil, 'no lua-ls signature' end
            if #(ls.params or {}) == 0 and ls.sig == '()' then return nil, 'lua-ls declares no positional parameters (overloads only, or none)' end
            local lp, vararg = M.luals_sig(ls, aliases)
            local pos = compared[q]
            if not pos then return kvobj({}) end
            local o, v = ours[q], {}
            for _, k in ipairs(pos) do
                local p = lp[k]
                if p and p.types then
                    local lsint = (ls.params[k].type or ''):find('integer') ~= nil
                    local cint = o.sig.params[k].integer == true
                    if lsint and cint then refine.both = refine.both + 1 elseif cint then refine.c_only = refine.c_only + 1 elseif lsint then refine.luals_only = refine.luals_only + 1 end
                end
                if p and not p.types then
                    unres[#unres + 1] = q .. '#' .. k .. ' (' .. tostring(ls.params[k].type) .. ')'
                    v[tostring(k)] = kvobj({ t = '?', opt = p.opt })
                elseif p then v[tostring(k)] = kvobj({ t = table.concat(p.types, '|'), opt = p.opt })
                elseif vararg then v[tostring(k)] = kvobj({ t = 'any', opt = true }) end
            end
            return kvobj(v)
        end,
        eq = M.agree,
        cause = M.cause,
        examples = 6,
    })
    local out = { checkers = checkers, ours = ours, stats = stats, join = R, refine = refine, unresolved = unres, aliases = vim.tbl_count(aliases), meta = meta }
    if opts.witness ~= false then
        local jobs = {}
        for q, o in pairs(ours) do
            if o.sig then
                local P, pre = {}, {}
                for k, p in pairs(o.sig.params) do
                    pre[k] = { types = p.types }
                    if not o.sig.open[k] then P[k] = { types = p.types, all = accepted(p), opt = p.opt, dispatch = p.dispatch } end
                end
                if next(P) then jobs[#jobs + 1] = { q = q, params = P, prefix = pre } end
            end
        end
        table.sort(jobs, function (a, b) return a.q < b.q end)
        local W = M.witness(jobs, PM.vocabulary(src))
        local tally, notes, bychecker = { confirmed = 0, contradicted = 0, accepted = 0, other = 0, lost = 0 }, {}, {}
        for _, j in ipairs(jobs) do
            local w = W[j.q]
            if w.lost then tally.lost = tally.lost + 1; notes[#notes + 1] = j.q .. ': LOST (' .. w.lost .. ')' end
            for _, pr in ipairs(w.probes) do
                local d = ours[j.q].sig.params[pr.k]
                local bc = bychecker[d.checker] or { ok = 0, bad = 0 }
                bychecker[d.checker] = bc
                local want = table.concat(d.types, '|')
                if pr.ok then
                    tally.accepted = tally.accepted + 1; bc.bad = bc.bad + 1
                    notes[#notes + 1] = ('%s #%d: ACCEPTED the probe'):format(j.q, pr.k)
                elseif pr.at == pr.k and pr.expected then
                    local exp = pr.expected:gsub(' expected$', '')
                    if exp == want or ((want == 'any' or want == '?') and exp == 'value') or exp:find(want, 1, true) then
                        tally.confirmed = tally.confirmed + 1; bc.ok = bc.ok + 1
                    else
                        tally.contradicted = tally.contradicted + 1; bc.bad = bc.bad + 1
                        notes[#notes + 1] = ('%s #%d: derived %s, LuaJIT says "%s"'):format(j.q, pr.k, want, pr.expected)
                    end
                else
                    tally.other = tally.other + 1
                    notes[#notes + 1] = ('%s #%d: %s'):format(j.q, pr.k, pr.at and ('raised at #' .. pr.at .. ': ' .. tostring(pr.expected)) or tostring(pr.other))
                end
            end
        end
        out.witness = { functions = #jobs, tally = tally, notes = notes, bychecker = bychecker, raw = W }
    end
    return out
end

return M
