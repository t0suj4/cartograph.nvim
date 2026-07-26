-- The self ORACLE: the running instance answering what IS. Where the graph
-- (tree-sitter) says what the SOURCE declares, this reads the live process —
-- the top rung of the epistemics ladder (see live.lua for the same idea over
-- MCP; here the "wire" is in-process, because the system being asked is us).
--
-- Its first answer is CONCRETE VALUES: a module's runtime export table, a
-- dispatch table's actual contents. The static graph can only show what a
-- literal spells out — `local M = {} … return M` reads as an EMPTY table —
-- but at runtime M holds everything assembled across the file. And every
-- function value carries its definition site (debug.getinfo), which reverses
-- to a graph node: so a dispatch table's live entries resolve to the concrete
-- functions they dispatch to, closing a frontier the source left `⊘`.
--
-- A live read is a SAMPLE — true at the moment asked, like live.lua's tick —
-- never cached into the persisted graph.

local M = {}
local argv = require 'cartograph.argv'
local atr = require 'cartograph.at'
local callrec = require 'cartograph.callrec'

local MAXDEPTH = 5   -- table nesting we descend when snapshotting a value
local MAXN     = 300 -- entries per table (dispatch tables can be large)

--- Resolve a graph file key to a real absolute path (mirrors store.abs, but
--- pure over `data` so the engine is testable without a live store).
local function abs_of(file, data)
    local roots = data and data.roots
    if roots then
        local label, rest = file:match('^([^/]+)/(.*)$')
        if label and roots[label] then
            return require('cartograph.transport').join(roots[label], rest)
        end
    end
    return ((data and data.root) or '') .. '/' .. file
end

--- Reverse: a real absolute path back to the graph's file key (nil if the
--- path is outside every root — e.g. a $VIMRUNTIME file not in the corpus).
local function key_for_abs(abs, data)
    local roots = data and data.roots
    if roots then
        for label, dir in pairs(roots) do
            if abs == dir or abs:sub(1, #dir + 1) == dir .. '/' then
                return label .. '/' .. abs:sub(#dir + 2)
            end
        end
        return nil
    end
    local root = data and data.root
    if root and (abs == root or abs:sub(1, #root + 1) == root .. '/') then
        return abs:sub(#root + 2)
    end
    return nil
end
M.key_for_abs = key_for_abs -- the confirmed tier ([[confirm]]) reuses it

--- abs file path -> loaded module name, for every module this instance has
--- actually required. Built from package.loaded (the runtime's own record)
--- resolved through the loader's own search, so it doubles as the honest
--- "which files ran" signal. Cached on `data` (a live sample, one per open).
function M.loaded_index(data)
    if data and data._live_index then return data._live_index end
    local idx = {}
    for name in pairs(package.loaded) do
        if type(name) == 'string' then
            local rel = 'lua/' .. name:gsub('%.', '/')
            local hits = vim.api.nvim_get_runtime_file(rel .. '.lua', true)
            vim.list_extend(hits,
                vim.api.nvim_get_runtime_file(rel .. '/init.lua', true))
            for _, f in ipairs(hits) do
                idx[(vim.fn.fnamemodify(f, ':p')):gsub('/+$', '')] = name
            end
        end
    end
    if data then data._live_index = idx end
    return idx
end

--- The set of graph file keys that this instance actually RAN this session —
--- required Lua modules (loaded_index) plus sourced scripts (getscriptinfo,
--- which also catches .vim files and plugin/ scripts). Everything else in a
--- loaded plugin's tree is present-but-never-loaded: the honest "dead this
--- session" signal. Cached on `data` (a sample).
function M.loaded_files(data)
    if data and data._loaded_files then return data._loaded_files end
    local out = {}
    for abs in pairs(M.loaded_index(data)) do
        local key = key_for_abs(abs, data)
        if key then out[key] = true end
    end
    for _, s in ipairs(vim.fn.getscriptinfo()) do
        if type(s.name) == 'string' and s.name ~= '' then
            local abs = (vim.fn.fnamemodify(s.name, ':p')):gsub('/+$', '')
            local key = key_for_abs(abs, data)
            if key then out[key] = true end
        end
    end
    if data then data._loaded_files = out end
    return out
end

--- The definition site of a live function, as "abs:line" (1-based), or nil.
function M.fn_loc(fn)
    local info = debug.getinfo(fn, 'S')
    if not (info and info.source and info.source:sub(1, 1) == '@') then
        return nil
    end
    return info.source:sub(2), info.linedefined or 0
end

--- Map a live function VALUE back to the graph node that defines it. Same
--- line can hold several definitions (a `{ open = fn, close = fn }` literal)
--- and debug.getinfo has no column, so `hint` (the table key we found it
--- under) disambiguates by name. Returns { id, name, at } or nil.
function M.resolve_fn(fn, data, hint)
    local src, line1 = M.fn_loc(fn)
    if not src then return nil end
    local abs = (vim.fn.fnamemodify(src, ':p')):gsub('/+$', '')
    local key = key_for_abs(abs, data)
    local line = (line1 or 1) - 1 -- graph ranges are 0-based
    if not key then
        return { id = nil, name = ('fn@%s:%d'):format(abs, line1 or 0),
            at = ('%s:%d'):format(abs, line1 or 0), external = true }
    end
    local same = {}
    for _, n in ipairs(data.nodes) do
        if (n.kind == 'function' or n.kind == 'method')
            and n.file == key and atr.sl(n.range) == line then
            same[#same + 1] = n
        end
    end
    local pick = same[1]
    if hint then
        for _, n in ipairs(same) do
            if n.name == hint or n.name:match('[^.]+$') == hint then
                pick = n; break
            end
        end
    end
    if pick then
        return { id = pick.id, name = pick.name,
            at = ('%s:%d'):format(key, line + 1) }
    end
    -- a closure whose def line has no top-level node (defined inside another
    -- function): name it by location, still honest, just not a pivot target
    return { id = nil, name = ('fn@%s:%d'):format(key, line1 or 0),
        at = ('%s:%d'):format(key, line1 or 0) }
end

--- Resolve `require` edges the way the LIVE loader did. In a self graph the
--- static path-match can't resolve requires (its file keys are plugin-labelled
--- — telescope.nvim/lua/… — so `require 'telescope.finders'` finds nothing),
--- but package.loaded knows exactly which file each module is. For every
--- `require(<literal>)` call whose module the loader resolved to a file in the
--- corpus, add a PROVEN import edge the path-match missed. Mutates `data.edges`;
--- returns { added }. The caller re-ingests (rebuilds imports_in/out).
function M.resolve_requires(data)
    local mod2key = {}
    for abs, modname in pairs(M.loaded_index(data)) do
        local key = key_for_abs(abs, data)
        if key then mod2key[modname] = key end
    end
    local have = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'import' then have[e.from .. '\31' .. e.to] = true end
    end
    local added = 0
    for _, c in callrec.each(data) do
        local a1 = callrec.callee(c) == 'require' and callrec.file(c) and argv.str(c, 1)
        if a1 and a1 ~= '' then
            local key = mod2key[a1]
            if key and key ~= callrec.file(c) and not have[callrec.file(c) .. '\31' .. key] then
                data.edges[#data.edges + 1] = { from = callrec.file(c), to = key,
                    kind = 'import', proven = true, mod = a1,
                    at = c.at }
                have[callrec.file(c) .. '\31' .. key] = true
                added = added + 1
            end
        end
    end
    return { added = added }
end

--- Snapshot a live Lua value into the render tree litval produces (scalars
--- raw, tables nested, functions as { ref, id, live_fn }, the rest as honest
--- { expr }). `hint` names the key this value sits under (fn disambiguation).
function M.to_data(val, data, hint, depth, seen)
    depth, seen = depth or 0, seen or {}
    local t = type(val)
    if t == 'string' or t == 'number' or t == 'boolean' then return val end
    if t == 'function' then
        local r = M.resolve_fn(val, data, hint)
        local nups = (debug.getinfo(val, 'u') or {}).nups or 0
        -- keep the raw fn + upvalue count so the live lens can descend into
        -- its captured state on demand (NOT expanded here — one level only)
        return { ref = r and r.name or 'ƒ (anonymous)', id = r and r.id,
            live_fn = true, at = r and r.at, external = r and r.external,
            fn = val, up = nups > 0 and nups or nil }
    end
    if t == 'table' then
        if seen[val] then return { expr = '<cycle>' } end
        if depth >= MAXDEPTH then return { expr = '{…}' } end
        seen[val] = true
        local out, n = {}, 0
        for i, v in ipairs(val) do
            out[i] = M.to_data(v, data, nil, depth + 1, seen)
            n = n + 1; if n >= MAXN then break end
        end
        for k, v in pairs(val) do
            if type(k) == 'string' and out[k] == nil and n < MAXN then
                out[k] = M.to_data(v, data, k, depth + 1, seen)
                n = n + 1
            end
        end
        -- metatable: the OOP dispatch the source can't follow. __index (the
        -- class/prototype) makes an instance's methods + its inheritance chain
        -- reachable; __call makes a callable "table" honest. Skip the ubiquitous
        -- M.__index = M self idiom (its methods are already the table's fields).
        -- rawget avoids triggering the metatable; the cycle guard bounds chains.
        local mt = getmetatable(val)
        if type(mt) == 'table' then
            local idx = rawget(mt, '__index')
            if (type(idx) == 'table' and idx ~= val) or type(idx) == 'function' then
                out['↑ __index'] = M.to_data(idx, data, '__index', depth + 1, seen)
            end
            local call = rawget(mt, '__call')
            if type(call) == 'function' then
                out['↑ __call'] = M.to_data(call, data, '__call', depth + 1, seen)
            end
        end
        seen[val] = nil
        return out
    end
    return { expr = '<' .. t .. '>' } -- userdata, thread
end

--- A function's upvalues (captured closure state) as a render tree, keyed by
--- name. Captured coupling static analysis can't see — it's closed over, not
--- required/called. One level: captured functions stay leaf refs (to_data
--- doesn't recurse them), captured tables are snapshotted (cycle/depth-guarded),
--- so this can't recurse infinitely even on a self-referential closure.
function M.upvalues(fn, data)
    local out = {}
    if type(fn) ~= 'function' then return out end
    local i = 1
    while true do
        local name, val = debug.getupvalue(fn, i)
        if not name then break end
        if name ~= '' then out[name] = M.to_data(val, data, name) end
        i = i + 1
    end
    return out
end

--- The raw live value backing a node, plus a display name for it. Only what
--- the process can actually observe from outside: a module's return value,
--- an exported field, or a global. A non-exported local is invisible (honest
--- nil) — the running process doesn't hand out its upvalues.
function M.raw_value(node, data)
    if not (node and node.file) then return nil end
    local idx = M.loaded_index(data)
    local abs = abs_of(node.file, data)
    local modname = idx[abs]
    if node.kind == 'module' then
        if not modname then return nil end
        return package.loaded[modname], modname
    elseif node.kind == 'var' then
        if _G[node.name] ~= nil then return _G[node.name], node.name end
        local seg = node.name:match('[^.]+$')
        local mod = modname and package.loaded[modname]
        if type(mod) == 'table' and seg and mod[seg] ~= nil then
            return mod[seg], modname .. '.' .. seg
        end
    end
    return nil
end

--- The live value of a node as a render tree, plus its display name. nil when
--- the node isn't observable in this instance (not loaded, or a hidden local).
function M.live_value(node, data)
    local val, name = M.raw_value(node, data)
    if val == nil then return nil end
    if type(val) ~= 'table' then
        -- a scalar export: wrap so the caller always gets a walkable tree
        return { value = M.to_data(val, data) }, name, true
    end
    return M.to_data(val, data), name
end

--- normalize a keymap lhs for comparison: expand leader, resolve termcodes
--- (so a declared `<leader>x` / `<CR>` matches what nvim_get_keymap reports).
local function norm_lhs(lhs)
    local ml = vim.g.mapleader or '\\'
    local mll = vim.g.maplocalleader or '\\'
    lhs = lhs:gsub('<[lL]eader>', ml):gsub('<[lL]ocal[lL]eader>', mll)
    local ok, out = pcall(vim.api.nvim_replace_termcodes, lhs, true, true, true)
    return ok and out or lhs
end

--- Registrations: what the source DECLARES (user commands, keymaps — the
--- literal ones; dynamic names computed at register time are invisible, and
--- honestly skipped) vs what this instance ACTUALLY registered. Returns report
--- lines + a structured diff. `missing` = declared but not live (its module
--- never ran, or a guard fired) — the actionable finding.
function M.registrations(data)
    local cmds, maps = {}, {}
    for _, c in callrec.each(data) do
        local n = callrec.full(c) or callrec.callee(c) or ''
        local a1, a2 = argv.str(c, 1), argv.str(c, 2)
        if n:find('nvim_create_user_command', 1, true) and a1 ~= '' then
            cmds[a1] = cmds[a1] or callrec.file(c)
        elseif n:find('keymap.set', 1, true) and a2 ~= '' then
            local mode = a1 ~= '' and a1 or 'n'
            maps[mode .. '\31' .. norm_lhs(a2)] = { lhs = a2, mode = mode, file = callrec.file(c) }
        end
    end
    local live_cmd = vim.api.nvim_get_commands({})
    local c_ok, c_miss = 0, {}
    for name, file in pairs(cmds) do
        if live_cmd[name] then c_ok = c_ok + 1
        else c_miss[#c_miss + 1] = { name = name, file = file } end
    end
    local live_map = {}
    local function ensure(mode)
        if live_map[mode] then return end
        local s = {}
        for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
            local ok, k = pcall(vim.api.nvim_replace_termcodes, m.lhs, true, true, true)
            s[ok and k or m.lhs] = true
        end
        live_map[mode] = s
    end
    local m_ok, m_miss = 0, {}
    for key, d in pairs(maps) do
        ensure(d.mode)
        if live_map[d.mode][key:match('\31(.*)$')] then m_ok = m_ok + 1
        else m_miss[#m_miss + 1] = d end
    end
    table.sort(c_miss, function (a, b) return a.name < b.name end)
    table.sort(m_miss, function (a, b) return a.lhs < b.lhs end)

    local lines = { ('registrations — declared (literal) vs live @ %s')
        :format(os.date('%H:%M:%S')) }
    lines[#lines + 1] = ('user commands: %d declared, %d registered ✓, %d missing')
        :format(c_ok + #c_miss, c_ok, #c_miss)
    for _, m in ipairs(c_miss) do
        lines[#lines + 1] = ('  ✗ :%s   %s'):format(m.name, m.file)
    end
    lines[#lines + 1] = ('keymaps: %d declared (literal), %d in the global table ✓,'
        .. ' %d not global'):format(m_ok + #m_miss, m_ok, #m_miss)
    for _, d in ipairs(m_miss) do
        lines[#lines + 1] = ('  ? %s %s   %s'):format(d.mode, d.lhs, d.file)
    end
    lines[#lines + 1] = '(✗ = declared but not registered now — its module never ran,'
    lines[#lines + 1] = ' or a guard fired. ? keymaps may be buffer-local or dynamic —'
    lines[#lines + 1] = ' the global table can\'t see those. Dynamic (computed) names are'
    lines[#lines + 1] = ' not checked at all.)'
    return lines, { commands = { ok = c_ok, missing = c_miss },
        keymaps = { ok = m_ok, missing = m_miss } }
end

--- Cheap gate: does this node have a live value worth offering? (Avoids
--- building the full tree just to decide whether to show the lens.)
function M.observable(node, data)
    return M.raw_value(node, data) ~= nil
end

return M
