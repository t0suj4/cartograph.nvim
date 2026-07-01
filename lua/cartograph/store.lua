-- Shared state store. Panes are independent widgets that subscribe here; they
-- never talk to each other. This is seam #3 (the UI contract): panes READ state,
-- interactions WRITE it. Keeping it tiny on purpose — it's what makes swappable
-- layouts possible later without touching the panes.

local M = {
    data    = nil,   -- decoded dump (GraphProvider output, schema #1)
    focused = nil,   -- focused node id (drives the source pane)
    _subs   = {},    -- focus subscribers
}

--- Load a graph dump (neutral schema) from disk.
---@param path string
function M.load(path)
    local f = assert(io.open(path, 'r'), 'cartograph: cannot open ' .. path)
    local txt = f:read('a')
    f:close()
    return M.ingest(vim.json.decode(txt))
end

--- Build all indexes from a decoded graph (schema #1). Split out from load() so
--- it can be driven directly from in-memory graphs (tests, non-file providers).
---@param data table
function M.ingest(data)
    M.data    = data
    M.by_id   = {}
    M.by_file = {}
    M.files   = {}
    local seen = {}
    for _, n in ipairs(M.data.nodes) do
        M.by_id[n.id] = n
        if n.kind ~= 'module' then
            M.by_file[n.file] = M.by_file[n.file] or {}
            table.insert(M.by_file[n.file], n)
        end
        if not seen[n.file] then seen[n.file] = true; table.insert(M.files, n.file) end
    end
    table.sort(M.files)
    for _, list in pairs(M.by_file) do
        table.sort(list, function (a, b) return a.order < b.order end)
    end

    -- edge indexes for the dependency tree (symbol-level `ref` edges)
    M.uses   = {} -- id -> { to_id, ... }   (functions this one references)
    M.usedby = {} -- id -> { from_id, ... } (functions that reference this one)
    M.occ    = {} -- "from\31to" -> { {start,end}, ... }  reference sites in `from`
    M.imports_in = {} -- file -> { {from=file, sideeffect=bool}, ... }  inbound requires
    for _, e in ipairs(M.data.edges or {}) do
        if e.kind == 'ref' then
            M.uses[e.from]   = M.uses[e.from]   or {}; table.insert(M.uses[e.from], e.to)
            M.usedby[e.to]   = M.usedby[e.to]   or {}; table.insert(M.usedby[e.to], e.from)
            M.occ[e.from .. '\31' .. e.to] = e.at
        elseif e.kind == 'import' then
            M.imports_in[e.to] = M.imports_in[e.to] or {}
            table.insert(M.imports_in[e.to], { from = e.from, sideeffect = e.sideeffect == true })
        end
    end
    return M.data
end

--- Classify a file's usage. Crucially separates "loaded for side effects" from
--- "truly unused" — and, within discarded requires, a module that actually DOES
--- something at load time from a pure module whose discarded require is dead.
---   'used'       a symbol in the file is referenced somewhere
---   'value'      imported and its return value is bound (symbol uses unresolved)
---   'sideeffect' discarded require(s) only, and the module has load-time effects
---   'deadimport' discarded require(s) only, but the module is pure → the require
---                is pointless (real dead code, not a benign side-effect load)
---   'orphan'     nothing imports or references it (incl. entry points)
function M.classify(file)
    for _, n in ipairs(M.by_file[file] or {}) do
        if M.usedby[n.id] and #M.usedby[n.id] > 0 then return 'used' end
    end
    local ins = M.imports_in[file]
    if not ins or #ins == 0 then return 'orphan' end
    for _, imp in ipairs(ins) do
        if not imp.sideeffect then return 'value' end
    end
    -- all inbound requires discard the result: a genuine side-effect load only if
    -- the module does something at load time; otherwise the require is dead.
    local mod = M.by_id[file]
    if mod and mod.effects then return 'sideeffect' end
    return 'deadimport'
end

---@param fn fun(id: string)
function M.on_focus(fn) table.insert(M._subs, fn) end

---@param id string?
function M.set_focus(id)
    if id == M.focused then return end
    M.focused = id
    for _, fn in ipairs(M._subs) do pcall(fn, id) end
end

-- occurrence highlight channel: a lighter signal than focus. Panes publish "the
-- reference sites for this uses-edge" and the source pane draws them, without
-- changing the rooted node. This drives the TOP source view (highlights the call
-- site inside the focused function, for a `uses` edge).
M._hl_subs = {}
---@param fn fun(hl: {file:string, ranges:table}?)
function M.on_highlight(fn) table.insert(M._hl_subs, fn) end
---@param hl {file:string, ranges:table}?
function M.set_highlight(hl)
    M.highlight = hl
    for _, fn in ipairs(M._hl_subs) do pcall(fn, hl) end
end

-- context channel: "the other end of the hovered edge" to show in the BOTTOM
-- source view. For a `uses` entry that's the callee's definition; for a `used by`
-- entry it's the caller's body, and `ranges` are the call site(s) inside it.
M._ctx_subs = {}
---@param fn fun(ctx: {node:string, ranges:table?}?)
function M.on_context(fn) table.insert(M._ctx_subs, fn) end
---@param ctx {node:string, ranges:table?}?
function M.set_context(ctx)
    M.context = ctx
    for _, fn in ipairs(M._ctx_subs) do pcall(fn, ctx) end
end

--- Occurrences of `to_id` inside `from_id` (the uses-edge call sites).
function M.occurrences(from_id, to_id)
    return M.occ[(from_id or '') .. '\31' .. (to_id or '')]
end

function M.node(id) return id and M.by_id[id] or nil end
function M.abspath(node) return M.data.root .. '/' .. node.file end

return M
