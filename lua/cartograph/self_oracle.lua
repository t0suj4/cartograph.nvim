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

local MAXDEPTH = 5   -- table nesting we descend when snapshotting a value
local MAXN     = 300 -- entries per table (dispatch tables can be large)

--- Resolve a graph file key to a real absolute path (mirrors store.abs, but
--- pure over `data` so the engine is testable without a live store).
local function abs_of(file, data)
    local roots = data and data.roots
    if roots then
        local label, rest = file:match('^([^/]+)/(.*)$')
        if label and roots[label] then return roots[label] .. '/' .. rest end
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
            and n.file == key and n.range.start.line == line then
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

--- Snapshot a live Lua value into the render tree litval produces (scalars
--- raw, tables nested, functions as { ref, id, live_fn }, the rest as honest
--- { expr }). `hint` names the key this value sits under (fn disambiguation).
function M.to_data(val, data, hint, depth, seen)
    depth, seen = depth or 0, seen or {}
    local t = type(val)
    if t == 'string' or t == 'number' or t == 'boolean' then return val end
    if t == 'function' then
        local r = M.resolve_fn(val, data, hint)
        if r then
            return { ref = r.name, id = r.id, live_fn = true, at = r.at,
                external = r.external }
        end
        return { expr = 'function' }
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
        seen[val] = nil
        return out
    end
    return { expr = '<' .. t .. '>' } -- userdata, thread
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

--- Cheap gate: does this node have a live value worth offering? (Avoids
--- building the full tree just to decide whether to show the lens.)
function M.observable(node, data)
    return M.raw_value(node, data) ~= nil
end

return M
