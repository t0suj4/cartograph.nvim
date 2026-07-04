-- Cross-language linking (pure post-pass over a neutral-schema graph).
-- Engine boundaries dispatch by STRING KEY: JS calls chrome.send('x') and
-- the C++ handler registered under "x" runs; C exports a scheme-callable
-- with scm_c_define_gsubr("name", ...); lua_register binds a Lua global to
-- a C function. The key is the edge — this pass finds export calls, resolves
-- their handler, and links every import site to it, across languages.
--
-- Confidence: these edges are string-key matched — the same mechanism the
-- engine itself dispatches by — so they are NOT marked `~`. They carry
-- xlang = true. Handlers that don't resolve stay honest frontiers.

local M = {}

--- A binding declares one boundary. `export` names the registering verb and
--- which (logical) arg is the key; `import` either names the sending verb
--- (chrome.send) or `any_call = true` (the exported key becomes a callable
--- name in the other language, as with gsubr/lua_register).
M.default_bindings = {
    -- chromium WebUI (fire-and-forget + request/response)
    { export = { verb = 'RegisterMessageCallback', name = 1 },
      import = { verb = { 'chrome.send', 'sendWithPromise' }, name = 1 } },
    -- guile: C function exported under a scheme name
    { export = { verb = 'scm_c_define_gsubr', name = 1 },
      import = { any_call = true } },
    -- lua C API
    { export = { verb = 'lua_register', name = 2 },
      import = { any_call = true } },
    -- wordpress hooks: handlers register by NAME STRING (or Class::method);
    -- one hook fans out to many handlers
    { export = { verb = { 'add_action', 'add_filter' }, name = 1, fn = 2 },
      import = { verb = { 'do_action', 'do_action_ref_array',
          'apply_filters', 'apply_filters_ref_array' }, name = 1 } },
}

local function verb_matches(c, verb)
    if type(verb) == 'table' then
        for _, v in ipairs(verb) do
            if verb_matches(c, v) then return true end
        end
        return false
    end
    return c.callee == verb or c.full == verb
        or (c.full and c.full:sub(-#verb - 1) == '.' .. verb)
end

local function logical_arg(c, i)
    return c.args and c.args[i + (c.method and 1 or 0)]
end

--- Resolve the handler of an export call: a resolved function argv first,
--- then a textual scan of the call's source for a qualified/plain function
--- name (the &Class::Method inside base::BindRepeating spans lines).
local function find_handler(c, root, exact, export)
    if export.fn then
        local a = c.argv and c.argv[export.fn + (c.method and 1 or 0)]
        if a then
            if a.k == 'func' and a.to then return a.to end
            local name = a.k == 'lit' and a.v or a.k == 'local' and a.name
            if name and exact[name] and #exact[name] == 1 then
                return exact[name][1].id
            end
            -- an inline closure or unresolvable callable: don't fall through
            -- to the textual scan, it would grab neighbouring names
            if a.k ~= 'expr' then return nil end
        end
    end
    for _, a in ipairs(c.argv or {}) do
        if a.k == 'func' and a.to then return a.to end
    end
    for _, a in ipairs(c.argv or {}) do
        if a.k == 'local' and a.name and exact[a.name]
            and #exact[a.name] == 1 then
            return exact[a.name][1].id
        end
    end
    local fd = io.open(root .. '/' .. c.file, 'r')
    if not fd then return nil end
    local lines = vim.split(fd:read('a'), '\n', { plain = true })
    fd:close()
    -- take exactly the CALL's text: accumulate lines until the paren that
    -- opened it closes (scanning past the statement would pick up the next
    -- definition as a phantom handler)
    local text, depth, opened = '', 0, false
    for l = c.line + 1, math.min(c.line + 12, #lines) do
        local chunk = lines[l]
        text = text .. chunk .. '\n'
        for ch in chunk:gmatch('[()]') do
            if ch == '(' then
                depth = depth + 1
                opened = true
            else
                depth = depth - 1
            end
        end
        if opened and depth <= 0 then break end
    end
    for _, pat in ipairs({ '&([%w_]+::[%w_]+)', '([%w_]+::[%w_]+)', '&([%w_]+)' }) do
        for name in text:gmatch(pat) do
            local hit = exact[name]
            if hit and #hit == 1 then return hit[1].id end
        end
    end
    return nil
end

--- The bindings actually in force for a graph: config (or defaults) plus
--- discovered registries (config.discover), deduped by export verb.
function M.effective_bindings(data)
    local cfg = require('cartograph.config')
    local bindings = vim.list_extend({}, cfg.bindings or M.default_bindings)
    if cfg.discover ~= false then
        local have = {}
        for _, b in ipairs(bindings) do
            for _, v in ipairs(type(b.export.verb) == 'table'
                and b.export.verb or { b.export.verb }) do
                have[v] = true
            end
        end
        for _, b in ipairs(require('cartograph.greenspun').registries(data)) do
            if not have[b.export.verb] then bindings[#bindings + 1] = b end
        end
    end
    return bindings
end

--- Link a graph's cross-language boundaries in place.
---@param data table  neutral-schema graph (mutated)
---@param bindings table?  defaults to config.bindings or M.default_bindings
---@return { links:integer, exports:integer, unresolved:integer }
function M.link(data, bindings)
    bindings = bindings or require('cartograph.config').bindings
        or M.default_bindings
    local exact = {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            exact[n.name] = exact[n.name] or {}
            table.insert(exact[n.name], n)
        end
    end
    local refEdge = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' then refEdge[e.from .. '\31' .. e.to] = e end
    end
    local function addref(from, to, at)
        local k = from .. '\31' .. to
        local e = refEdge[k]
        if not e then
            e = { from = from, to = to, kind = 'ref', at = {}, xlang = true }
            refEdge[k] = e
            data.edges[#data.edges + 1] = e
        end
        e.inferred = nil -- the key match outranks a name hypothesis
        if at then e.at[#e.at + 1] = at end
    end
    -- precise site range: the key literal on the call line, when findable
    local line_cache = {}
    local function key_range(c, key)
        if line_cache[c.file] == nil then
            local fd = io.open(data.root .. '/' .. c.file, 'r')
            line_cache[c.file] = fd and vim.split(fd:read('a'), '\n', { plain = true }) or false
            if fd then fd:close() end
        end
        local lines = line_cache[c.file]
        for l = c.line, math.min(c.line + 3, lines and #lines - 1 or c.line) do
            local text = lines and lines[l + 1] or ''
            local s, e = text:find(key, 1, true)
            if s then
                return { start = { line = l, char = s - 1 },
                    ['end'] = { line = l, char = e } }
            end
        end
        return { start = { line = c.line, char = 0 },
            ['end'] = { line = c.line, char = 0 } }
    end

    local stats = { links = 0, exports = 0, unresolved = 0, pinned = 0 }
    -- human declarations outrank everything: a pin names the target of one
    -- dynamic call site the analysis cannot see
    for _, pin in ipairs(require('cartograph.config').pins or {}) do
        local target = exact[pin.to]
        target = target and #target == 1 and target[1]
        if target then
            for _, c in ipairs(data.calls or {}) do
                if c.file == pin.file and c.line == pin.line - 1 then
                    c.to = target.id
                    c.dynamic = nil
                    if c.fn then addref(c.fn, target.id,
                        key_range(c, pin.to)) end
                    stats.pinned = stats.pinned + 1
                end
            end
        end
    end
    for _, b in ipairs(bindings) do
        local exports = {}
        for _, c in ipairs(data.calls or {}) do
            if verb_matches(c, b.export.verb) then
                local key = logical_arg(c, b.export.name)
                if key and key ~= '' then
                    local h = find_handler(c, data.root, exact, b.export)
                    if h then
                        exports[key] = exports[key] or {}
                        table.insert(exports[key], h)
                        stats.exports = stats.exports + 1
                        -- the registration itself references the handler
                        if c.fn then addref(c.fn, h, key_range(c, key)) end
                    else
                        stats.unresolved = stats.unresolved + 1
                    end
                end
            end
        end
        if next(exports) then
            for _, c in ipairs(data.calls or {}) do
                local hs, key
                if b.import.verb and verb_matches(c, b.import.verb) then
                    key = logical_arg(c, b.import.name or 1)
                    hs = key and key ~= '' and exports[key]
                elseif b.import.any_call and not c.to and exports[c.callee] then
                    key = c.callee
                    hs = exports[key]
                end
                if hs then
                    -- a single handler is a descend target; a fan-out keeps
                    -- c.to empty (edges carry it, callers views show sites)
                    if #hs == 1 then c.to = c.to or hs[1] end
                    if c.fn then
                        for _, h in ipairs(hs) do
                            addref(c.fn, h, key_range(c, key))
                        end
                    end
                    stats.links = stats.links + 1
                end
            end
        end
    end
    return stats
end

return M
