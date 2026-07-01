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
    M.data    = vim.json.decode(txt)
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
    for _, e in ipairs(M.data.edges or {}) do
        if e.kind == 'ref' then
            M.uses[e.from]   = M.uses[e.from]   or {}; table.insert(M.uses[e.from], e.to)
            M.usedby[e.to]   = M.usedby[e.to]   or {}; table.insert(M.usedby[e.to], e.from)
        end
    end
    return M.data
end

---@param fn fun(id: string)
function M.on_focus(fn) table.insert(M._subs, fn) end

---@param id string?
function M.set_focus(id)
    if id == M.focused then return end
    M.focused = id
    for _, fn in ipairs(M._subs) do pcall(fn, id) end
end

function M.node(id) return id and M.by_id[id] or nil end
function M.abspath(node) return M.data.root .. '/' .. node.file end

return M
