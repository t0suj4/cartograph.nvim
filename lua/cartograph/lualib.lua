-- cartograph.lualib — the DATA-STAGE LUALIB pass (CART-0651 (b)). The distiller
-- (tools/lualibdistill.lua) runs it over a game install; portability runs it over a
-- project to find the keys the project writes on globals itself. See the tool's
-- header for what a member set means and when a global is OPEN.

local M = {}

-- children by index (the repo convention, CART-1453: no single-variable iter_children)
local inext = require('cartograph.spec.tsutil').inext

local function readfile(p)
    local fd = io.open(p, 'rb'); if not fd then return nil end
    local s = fd:read('*a'); fd:close(); return s
end
local function exists(p) return vim.uv.fs_stat(p) ~= nil end

-- a whole-value read of a global as one of these calls' arguments cannot add a key
local READONLY_CALLS = { pairs = true, ipairs = true, next = true, type = true,
    table_size = true, log = true, tostring = true, print = true }

--- Distil the data stage under `data_dir` (a Factorio `data/` directory holding
--- core/ and base/). Returns the artifact table, or nil and why.
--- THE PASS over one tree: its state and `load_file`. `flat` = the tree is ONE mod
--- (a project), so its root is every file's mod root; otherwise each top directory
--- is a mod (a game's data/).
local function pass(data_dir, flat)
    -- TABLES. A binding (a global name, a module's return value, a chunk local holding
    -- a constructor) points at a table record; aliasing two bindings to one table is a
    -- union of their records. A record: { members = set, open = why|nil }.
    local parent = {}
    local function find(t) while parent[t] do t = parent[t] end return t end
    local function newtab() local t = { members = {} }; return t end
    local function union(a, b)
        a, b = find(a), find(b)
        if a == b then return a end
        for k in pairs(b.members) do a.members[k] = true end
        a.open = a.open or b.open
        parent[b] = a
        return a
    end
    local function addm(t, k) find(t).members[k] = true end
    local function open(t, why) t = find(t); t.open = t.open or why end

    local globals = {}      -- name -> { tab = table, kind = 'table'|'function'|'value', files = set }
    local modret = {}       -- resolved path -> table | false (returns a non-table) | 'busy'
    local files_read = {}
    -- a require the pass could not follow: the file it names may define globals or
    -- add members, so any entry here makes the whole artifact INCOMPLETE
    local unresolved = {}
    -- a require at a COMPUTED path (util.sprite_load's `require(path)`): any file
    -- could be loaded, so every core/base file not reached otherwise is walked too
    -- — a superset of the keys written, which keeps an absence sound
    local computed = {}

    local function gtab(name, file)
        local g = globals[name]
        if not g then g = { tab = newtab(), files = {} }; globals[name] = g end
        g.files[file] = true
        return g
    end

    local function resolve_req(spec, file, modroot)
        local function try(p) if exists(p) then return p end end
        -- `__base__/prototypes/x` AND `__base__.prototypes.x` — base 2.0.77 writes
        -- both (cargo-hatch.lua: __base__.prototypes.entity.sounds)
        local mod, rest = spec:match('^__([%w%-_]+)__[/.](.+)$')
        local function path(s) if not s:find('/') then s = s:gsub('%.', '/') end return s end
        if mod then return try(data_dir .. '/' .. mod .. '/' .. path(rest):gsub('%.lua$', '') .. '.lua') end
        local p = path(spec):gsub('%.lua$', '')
        local dir = file:match('^(.*)/[^/]+$')
        return try(dir .. '/' .. p .. '.lua') or try(modroot .. '/' .. p .. '.lua')
            or try(data_dir .. '/core/lualib/' .. p .. '.lua')
    end

    local load_file -- forward

    local function text(n, src) return vim.treesitter.get_node_text(n, src) end
    local function strval(n, src)
        if n:type() ~= 'string' then return nil end
        local c = n:field('content')[1]
        return c and text(c, src) or ''
    end

    local function walk_file(file, modroot)
        local src = readfile(file)
        if not src then return nil end
        files_read[#files_read + 1] = file:sub(#data_dir + 2)
        local tree = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]
        local root = tree:root()
        -- scope stack: each frame maps a local name -> table record or true (a local
        -- the pass does not track)
        local scopes = { {} }
        local function lookup(name)
            for i = #scopes, 1, -1 do
                local v = scopes[i][name]; if v ~= nil then return v, i end
            end
        end
        local function declare(name, v) scopes[#scopes][name] = v or true end

        local visit -- forward

        -- the table a value expression evaluates to, when the pass can name one
        local function value_table(e)
            local t = e:type()
            if t == 'table_constructor' then
                local tab = newtab()
                for _, f in inext, e, -1 do
                    if f:type() == 'field' then
                        local nm, val = f:field('name')[1], f:field('value')[1]
                        local bracket = text(f, src):match('^%s*%[') ~= nil
                        if nm and not bracket and nm:type() == 'identifier' then
                            addm(tab, text(nm, src))
                        elseif nm and bracket and strval(nm, src) then
                            addm(tab, strval(nm, src))
                        elseif nm and bracket then
                            open(tab, 'a constructor field at a computed key')
                        end
                        if nm and bracket then visit(nm) end
                        if val then visit(val) end
                    elseif f:named() then visit(f) end
                end
                return tab
            elseif t == 'function_call' then
                local fn = e:field('name')[1]
                if fn and fn:type() == 'identifier' and text(fn, src) == 'require'
                    and not lookup('require') then
                    local args = e:field('arguments')[1]
                    local a = args and args:named_child(0)
                    local spec = a and strval(a, src)
                    if spec then
                        local p = resolve_req(spec, file, modroot)
                        if p then return load_file(p) or nil end
                        unresolved[#unresolved + 1] = file:sub(#data_dir + 2) .. ': ' .. spec
                    else
                        computed[#computed + 1] = file:sub(#data_dir + 2)
                    end
                end
            elseif t == 'identifier' then
                local v = lookup(text(e, src))
                if type(v) == 'table' then return v end
            elseif t == 'parenthesized_expression' then
                local inner = e:named_child(0)
                return inner and value_table(inner)
            end
            return nil
        end

        -- the binding an identifier names: a local's record, or a global
        local function binding(id)
            local name = text(id, src)
            local v = lookup(name)
            if v ~= nil then return (type(v) == 'table') and v or nil, false, name end
            return gtab(name, file).tab, true, name
        end

        -- a whole-value read of an identifier: an escape unless a read-only call
        -- receives it
        local function escape_read(id)
            local tab, isg = binding(id)
            if not tab then return end
            local p = id:parent()
            if p and p:type() == 'arguments' then
                local call = p:parent()
                local fn = call and call:field('name')[1]
                local fname = fn and text(fn, src)
                if fname and (READONLY_CALLS[fname] or fname:match('^serpent%.'))
                    and not lookup(fname:match('^[%w_]+')) then return end
            end
            open(tab, isg and 'the global escapes as a whole value' or
                'the table escapes as a whole value')
        end

        -- a write to `target` (an lvalue node) of value expression `val` (or nil)
        local function write(target, val)
            local t = target:type()
            if t == 'identifier' then
                local name = text(target, src)
                local v = lookup(name)
                if v ~= nil then
                    -- assignment to a local: retarget it (untracked unless a table)
                    local vt = val and value_table(val)
                    if val and not vt then visit(val) end
                    for i = #scopes, 1, -1 do
                        if scopes[i][name] ~= nil then scopes[i][name] = vt or true; break end
                    end
                    return
                end
                local g = gtab(name, file)
                local vt = val and value_table(val)
                if vt then
                    g.kind = g.kind or 'table'
                    g.tab = union(g.tab, vt)
                elseif val and (val:type() == 'function_definition') then
                    g.kind = g.kind or 'function'
                    visit(val)
                else
                    g.kind = g.kind or 'value'
                    if val then visit(val) end
                    open(g.tab, 'assigned a value that is not a constructor or a resolved require')
                end
                return
            end
            local base = target:field('table')[1]
            if (t == 'dot_index_expression' or t == 'method_index_expression')
                and base and base:type() == 'identifier' then
                local tab = binding(base)
                local f = target:field('field')[1] or target:field('method')[1]
                if tab and f then addm(tab, text(f, src)) end
            elseif t == 'bracket_index_expression' and base and base:type() == 'identifier' then
                local tab = binding(base)
                local f = target:field('field')[1]
                local s = f and strval(f, src)
                if tab and s then addm(tab, s)
                elseif tab then open(tab, 'a write at a computed key') end
                if f then visit(f) end
            elseif base then
                visit(base)
                local f = t == 'bracket_index_expression' and target:field('field')[1]
                if f then visit(f) end
            end
            if val then visit(val) end
        end

        local function func_body(n, params_extra)
            scopes[#scopes + 1] = {}
            for _, p in ipairs(params_extra or {}) do declare(p) end
            local ps = n:field('parameters')[1]
            if ps then
                for _, c in inext, ps, -1 do
                    if c:type() == 'identifier' then declare(text(c, src)) end
                end
            end
            local body = n:field('body')[1]
            if body then visit(body) end
            scopes[#scopes] = nil
        end

        local BLOCKS = { block = true, do_statement = true, while_statement = true,
            repeat_statement = true, if_statement = true, elseif_statement = true,
            else_statement = true }

        visit = function (n)
            local t = n:type()
            if t == 'variable_declaration' then
                -- `local a, b = x, y` or `local a` — values are evaluated BEFORE the
                -- names come into scope
                local asg = n:named_child(0)
                if asg and asg:type() == 'assignment_statement' then
                    local vl = asg:named_child(0)
                    local el = asg:named_child(1)
                    local names, vals = {}, {}
                    for _, c in inext, vl, -1 do if c:named() then names[#names + 1] = c end end
                    for _, c in inext, el, -1 do if c:named() then vals[#vals + 1] = c end end
                    local vts = {}
                    for i, v in ipairs(vals) do
                        vts[i] = value_table(v) or false
                        if not vts[i] then visit(v) end
                    end
                    for i, nm in ipairs(names) do
                        if nm:type() == 'identifier' then declare(text(nm, src), vts[i] or nil) end
                    end
                else
                    for _, c in inext, n, -1 do
                        if c:type() == 'identifier' then declare(text(c, src)) end
                        if c:type() == 'variable_list' then
                            for _, d in inext, c, -1 do
                                if d:type() == 'identifier' then declare(text(d, src)) end
                            end
                        end
                    end
                end
                return
            elseif t == 'assignment_statement' then
                local vl, el = n:named_child(0), n:named_child(1)
                local targets, vals = {}, {}
                for _, c in inext, vl, -1 do if c:named() then targets[#targets + 1] = c end end
                if el then for _, c in inext, el, -1 do if c:named() then vals[#vals + 1] = c end end end
                for i, tg in ipairs(targets) do write(tg, vals[i]) end
                for i = #targets + 1, #vals do visit(vals[i]) end
                return
            elseif t == 'function_declaration' then
                local nm = n:field('name')[1]
                local is_local = text(n, src):match('^%s*local%s') ~= nil
                if nm and nm:type() == 'identifier' then
                    local name = text(nm, src)
                    if is_local or lookup(name) ~= nil then
                        declare(name)
                    else
                        local g = gtab(name, file); g.kind = g.kind or 'function'
                    end
                    func_body(n)
                elseif nm then
                    write(nm, nil)
                    func_body(n, nm:type() == 'method_index_expression' and { 'self' } or nil)
                end
                return
            elseif t == 'function_definition' then
                func_body(n); return
            elseif t == 'for_statement' then
                -- the clause's expressions are evaluated OUTSIDE the loop scope, its
                -- names bound inside it
                local clause = n:field('clause')[1]
                local names = {}
                if clause and clause:type() == 'for_numeric_clause' then
                    for _, f in ipairs({ 'start', 'end', 'step' }) do
                        local e = clause:field(f)[1]
                        if e then visit(e) end
                    end
                    local nm = clause:field('name')[1]
                    if nm then names[1] = text(nm, src) end
                elseif clause then
                    for _, c in inext, clause, -1 do
                        if c:type() == 'variable_list' then
                            for _, d in inext, c, -1 do
                                if d:type() == 'identifier' then names[#names + 1] = text(d, src) end
                            end
                        elseif c:named() then visit(c) end
                    end
                end
                scopes[#scopes + 1] = {}
                for _, nm in ipairs(names) do declare(nm) end
                local body = n:field('body')[1]
                if body then visit(body) end
                scopes[#scopes] = nil
                return
            elseif t == 'field' then
                -- a constructor that is not a binding's value: its keys are no
                -- variable reads, only a bracket key expression and the value are
                local nm, val = n:field('name')[1], n:field('value')[1]
                if nm and text(n, src):match('^%s*%[') then visit(nm) end
                if val then visit(val) end
                return
            elseif t == 'goto_statement' or t == 'label_statement' then
                return
            elseif t == 'return_statement' and #scopes == 1 then
                -- a module's return value: record it (handled by the caller)
                for _, c in inext, n, -1 do if c:named() then visit(c) end end
                return
            elseif t == 'identifier' then
                escape_read(n); return
            elseif t == 'dot_index_expression' or t == 'method_index_expression' then
                local base = n:field('table')[1]
                if base and base:type() ~= 'identifier' then visit(base) end
                return
            elseif t == 'bracket_index_expression' then
                local base = n:field('table')[1]
                if base and base:type() ~= 'identifier' then visit(base) end
                local f = n:field('field')[1]
                if f then visit(f) end
                return
            elseif t == 'function_call' then
                local fn = n:field('name')[1]
                if fn and fn:type() == 'identifier' and text(fn, src) == 'require'
                    and not lookup('require') then
                    value_table(n) -- loads the module for its side effects
                    return
                end
                if fn and fn:type() ~= 'identifier' then visit(fn) end
                local args = n:field('arguments')[1]
                if args then visit(args) end
                return
            elseif BLOCKS[t] then
                scopes[#scopes + 1] = {}
                for _, c in inext, n, -1 do if c:named() then visit(c) end end
                scopes[#scopes] = nil
                return
            end
            for _, c in inext, n, -1 do if c:named() then visit(c) end end
        end

        -- the chunk: visit statements in the chunk scope, then read the return
        local ret
        for _, c in inext, root, -1 do
            if c:named() then
                if c:type() == 'return_statement' then
                    local el = c:named_child(0)
                    local e = el and (el:type() == 'expression_list' and el:named_child(0) or el)
                    if e then
                        local id = e:type() == 'identifier' and e or nil
                        ret = value_table(e)
                        -- a returned LOCAL table is shared with every requirer and is
                        -- tracked by identity; a returned GLOBAL is an escape (the
                        -- requirer gets it under a name the pass does not follow)
                        if not id or not ret then visit(e) end
                    end
                else
                    visit(c)
                end
            end
        end
        return ret
    end

    load_file = function (p)
        local st = modret[p]
        if st == 'busy' then return nil end -- a require cycle: the value is not known yet
        if st ~= nil then return st or nil end
        modret[p] = 'busy'
        local modroot = flat and data_dir or p:match('^(' .. vim.pesc(data_dir) .. '/[^/]+)')
        local r = walk_file(p, modroot or data_dir)
        modret[p] = r or false
        return r
    end

    return { load_file = load_file, globals = globals, find = find, modret = modret,
        files_read = files_read, unresolved = unresolved, computed = computed }
end

function M.distill(data_dir)
    data_dir = data_dir:gsub('/+$', '')
    local info = readfile(data_dir .. '/base/info.json')
    if not info then return nil, 'no base/info.json under ' .. data_dir end
    local ok, ij = pcall(vim.json.decode, info)
    if not ok or type(ij) ~= 'table' or type(ij.version) ~= 'string' then
        return nil, 'base/info.json carries no version'
    end
    local version = ij.version

    local P = pass(data_dir)
    local load_file, globals, find, modret = P.load_file, P.globals, P.find, P.modret
    local files_read, unresolved, computed = P.files_read, P.unresolved, P.computed

    -- THE DATA STAGE, IN ENGINE ORDER. core first (the dataloader defines `data`),
    -- then base's three data files.
    local entries = { 'core/lualib/dataloader.lua', 'core/data.lua',
        'base/data.lua', 'base/data-updates.lua', 'base/data-final-fixes.lua' }
    local loaded = {}
    for _, e in ipairs(entries) do
        local p = data_dir .. '/' .. e
        if exists(p) then load_file(p); loaded[#loaded + 1] = e end
    end
    if #loaded == 0 then return nil, 'no data-stage entry file under ' .. data_dir end
    local function census()
        local ng, nm = 0, 0
        for _, g in pairs(globals) do
            if g.kind then ng = ng + 1; for _ in pairs(find(g.tab).members) do nm = nm + 1 end end
        end
        return ng, nm
    end
    local extra
    -- what the REAL load graph defined, before the conservative walk: a name or key
    -- that only the extra walk adds is MAYBE defined, never a presence
    local main = {}
    for name, g in pairs(globals) do
        if g.kind then main[name] = vim.deepcopy(find(g.tab).members) end
    end
    if #computed > 0 then
        local g0, m0 = census()
        local more = vim.fs.find(function (n) return n:match('%.lua$') ~= nil end,
            { path = data_dir .. '/core', type = 'file', limit = math.huge })
        vim.list_extend(more, vim.fs.find(function (n) return n:match('%.lua$') ~= nil end,
            { path = data_dir .. '/base', type = 'file', limit = math.huge }))
        table.sort(more)
        -- RUNTIME-ONLY trees are no data-stage file a computed require could reach:
        -- campaigns, scenarios, tutorials, menu simulations, migrations, script
        local RUNTIME = { campaigns = true, scenarios = true, tutorials = true,
            ['menu-simulations'] = true, migrations = true, script = true }
        local n = 0
        for _, p in ipairs(more) do
            local top = p:sub(#data_dir + 2):match('^[^/]+/([^/]+)/')
            if modret[p] == nil and not (top and RUNTIME[top]) then n = n + 1; load_file(p) end
        end
        local g1, m1 = census()
        table.sort(computed)
        extra = { sites = computed, files = n, added_globals = g1 - g0, added_members = m1 - m0 }
    end

    local out = {}
    for name, g in pairs(globals) do
        if g.kind then
            local t = find(g.tab)
            local fl = {}
            for f in pairs(g.files) do fl[#fl + 1] = f:sub(#data_dir + 2) end
            table.sort(fl)
            local maybe_m
            for k in pairs(t.members) do
                if main[name] and not main[name][k] then
                    maybe_m = maybe_m or {}; maybe_m[k] = true
                end
            end
            out[name] = { kind = g.kind, members = next(t.members) and t.members or nil,
                open = t.open, files = fl,
                -- defined, or keyed, only by a file a computed require MIGHT load
                maybe = (not main[name]) or nil, maybe_members = maybe_m }
        end
    end
    -- THE GLOBAL SET ITSELF. `_G.x = …` / `_G["x"] = …` defines a global the pass
    -- can name (its members unknown); a computed key or `_G` escaping means globals
    -- may exist that no name records, and then an absent GLOBAL decides nothing.
    local genv, globals_open = globals['_G'], nil
    if genv then
        local t = find(genv.tab)
        for k in pairs(t.members) do
            if not out[k] then
                out[k] = { kind = 'value', open = 'written through _G', files = {} }
            end
        end
        globals_open = t.open
        out['_G'] = nil
    end
    table.sort(files_read)
    local minor = version:match('^(%d+)%.(%d+)')
    local maj, min = version:match('^(%d+)%.(%d+)')
    return {
        schema = 1, ingredient = true, kind = 'lualib', lang = 'lua',
        runtime = ('lua-factorio-lualib-%s%s'):format(maj, min),
        version = version, minor = minor and (maj .. '.' .. min) or nil,
        globals = out, globals_open = globals_open,
        -- INCOMPLETE: a literal require resolved to no file. The engine would have
        -- loaded something there, so no absence is decidable from this artifact.
        incomplete = #unresolved > 0 and unresolved or nil,
        computed = extra,
        stamp = { input = data_dir, entries = loaded, files = #files_read,
            note = 'globals the base game data stage defines; a member set is the'
                .. ' UNION of every key written, so only an ABSENCE from a CLOSED'
                .. ' global is a claim' },
    }
end


--- THE KEYS A PROJECT WRITES ON GLOBALS ITSELF — a local shim
--- (`circuit_connector_definitions.create = circuit_connector_definitions.create_vector`)
--- is the project's own definition, and no lualib absence may call it porting work.
--- `files` are paths relative to `root`. Returns { global -> set of keys written }.
function M.global_writes(root, files)
    root = root:gsub('/+$', '')
    local P = pass(root, true)
    for _, f in ipairs(files) do P.load_file(root .. '/' .. f) end
    local out = {}
    for name, g in pairs(P.globals) do
        local m = P.find(g.tab).members
        if next(m) then out[name] = m end
    end
    return out
end

return M
