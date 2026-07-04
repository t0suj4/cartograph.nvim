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
    M.toc     = nil -- load-order manifest; cartograph.toc.attach() sets it
    M._frontier_cache = {}
    M._nav_back, M._nav_fwd = {}, {}
    -- a live sample is evidence about (this graph, that moment) — any new
    -- graph state invalidates it; :CartographLive re-samples in one command
    M.live = nil
    -- staged ids belong to the previous graph; init.open refuses to swap
    -- graphs while staged, so anything left here is a ghost — drop it
    if next(M.moveset or {}) then M.clear_stage() end
    -- REENTRANCY CONTRACT: sync waits (LSP oracle, future apply) pump the
    -- event loop, so a deferred refresh can re-ingest mid-operation. Any
    -- operation spanning a wait captures M.generation before and compares
    -- after: readers re-read on mismatch, writers ABORT loudly. (The MCP
    -- wire waits fast-only and is exempt — timers can't fire there.)
    M.generation = (M.generation or 0) + 1
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

    -- call-inventory indexes: by resolved target (data tracing) and by
    -- enclosing function (the browser's per-statement callee targets)
    M.calls_to, M.calls_by_fn = {}, {}
    for _, c in ipairs(M.data.calls or {}) do
        if c.to then
            M.calls_to[c.to] = M.calls_to[c.to] or {}
            table.insert(M.calls_to[c.to], c)
        end
        if c.fn then
            M.calls_by_fn[c.fn] = M.calls_by_fn[c.fn] or {}
            table.insert(M.calls_by_fn[c.fn], c)
        end
    end

    -- edge indexes for the dependency tree (symbol-level `ref` edges)
    M.uses   = {} -- id -> { to_id, ... }   (functions this one references)
    M.usedby = {} -- id -> { from_id, ... } (functions that reference this one)
    M.occ    = {} -- "from\31to" -> { {start,end}, ... }  reference sites in `from`
    M.edge_inferred = {} -- "from\31to" -> true (resolved by unique name, not vm)
    M.var_usedby = {} -- var node id -> { {from=fn id, at=ranges}, ... }
    M.var_uses   = {} -- fn node id  -> { {to=var id,  at=ranges}, ... }
    M.imports_in  = {} -- file -> { {from=file, sideeffect=bool}, ... }  inbound requires
    M.imports_out = {} -- file -> { file, ... }  outbound requires (include tree)
    for _, e in ipairs(M.data.edges or {}) do
        if e.kind == 'ref' then
            -- self edges (recursion) carry occurrences only: they must not
            -- inflate usedby/uses (dead-function lint, heat, tints)
            if e.from ~= e.to then
                M.uses[e.from]   = M.uses[e.from]   or {}; table.insert(M.uses[e.from], e.to)
                M.usedby[e.to]   = M.usedby[e.to]   or {}; table.insert(M.usedby[e.to], e.from)
            end
            M.occ[e.from .. '\31' .. e.to] = e.at
            if e.inferred then M.edge_inferred[e.from .. '\31' .. e.to] = true end
        elseif e.kind == 'import' then
            M.imports_in[e.to] = M.imports_in[e.to] or {}
            table.insert(M.imports_in[e.to], { from = e.from, sideeffect = e.sideeffect == true })
            M.imports_out[e.from] = M.imports_out[e.from] or {}
            table.insert(M.imports_out[e.from], e.to)
        elseif e.kind == 'use' then
            M.var_usedby[e.to] = M.var_usedby[e.to] or {}
            table.insert(M.var_usedby[e.to], { from = e.from, at = e.at or {} })
            M.var_uses[e.from] = M.var_uses[e.from] or {}
            table.insert(M.var_uses[e.from], { to = e.to, at = e.at or {} })
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
---   'entry'      nothing imports it, but it matches a configured entry-point
---                pattern — a root the runtime loads directly, not dead
---   'orphan'     nothing imports or references it, and it is NOT an entry point
function M.is_entrypoint(file)
    for _, pat in ipairs(require('cartograph.config').entrypoints) do
        if file:match(pat) then return true end
    end
    return false
end

function M.classify(file)
    -- unparsed frontiers are deliberately opaque, not orphaned
    local mod = M.by_id[file]
    if mod and mod.unparsed then return 'used' end
    -- a manifest project (WoW .toc) has exact load knowledge: listed files
    -- ARE loaded (quiet), everything else genuinely never loads
    if M.toc then
        return M.toc.index[file] and 'used' or 'orphan'
    end
    -- entry first: an unimported file matching an entry-point pattern is a
    -- runtime-loaded root, and that's its salient fact even when its globals
    -- are also referenced cross-file (control.lua defines AND exports).
    local ins = M.imports_in[file]
    if (not ins or #ins == 0) and M.is_entrypoint(file) then return 'entry' end
    -- 'used' = a symbol referenced from ANOTHER file (the no-require global
    -- access pattern). Intra-file calls say nothing about how the project
    -- loads this file, so they don't count.
    for _, n in ipairs(M.by_file[file] or {}) do
        for _, from in ipairs(M.usedby[n.id] or {}) do
            local fn = M.by_id[from]
            if fn and fn.file ~= file then return 'used' end
        end
    end
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

-- ── unparsed frontiers (minified bundles) ────────────────────────────────────
-- Their content isn't in the graph; a name is found by LAZY text search on
-- demand. add_node registers the synthetic landing node so panes treat it
-- like any other. Landings are CACHE, not state: a landing is a memoized
-- text-search hit, keyed by the content of the unparsed file it points
-- into. Bundles are usually regenerated OUTSIDE nvim (no autocmd ever
-- fires), so every use revalidates: mtime+size as the fast gate, a content
-- hash as the truth. Changed content evicts the file's landings; the next
-- search re-derives them against the new bytes. Any future synthetic-node
-- type should inherit this rule: derived-on-demand nodes invalidate with
-- the content they were derived from.

M._frontier_cache = {}

local function djb2(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return h
end

--- Drop one unparsed file's landing nodes (cached hits into old bytes).
function M.frontier_evict(file)
    local keep = {}
    for _, n in ipairs(M.data.nodes) do
        if n.file == file and n.unparsed and n.kind ~= 'module' then
            M.by_id[n.id] = nil
        else
            keep[#keep + 1] = n
        end
    end
    M.data.nodes = keep
    local byf = {}
    for _, n in ipairs(M.by_file[file] or {}) do
        if M.by_id[n.id] then byf[#byf + 1] = n end
    end
    M.by_file[file] = byf
end

-- validated read of an unparsed file's text (false = unreadable)
local function frontier_text(file)
    local path = M.data.root .. '/' .. file
    local e = M._frontier_cache[file]
    local st = vim.uv.fs_stat(path)
    local stamp = st
        and ('%d:%d:%d'):format(st.mtime.sec, st.mtime.nsec, st.size)
        or 'gone'
    if e and e.stamp == stamp then return e.text end
    local fd = io.open(path, 'r')
    local text = fd and fd:read('a') or false
    if fd then fd:close() end
    local hash = text and djb2(text) or nil
    if e then
        if e.hash == hash then
            -- touched but unchanged: refresh the stamp, keep the landings
            e.stamp, e.text = stamp, text
            return text
        end
        M.frontier_evict(file)
    end
    M._frontier_cache[file] = { text = text, stamp = stamp, hash = hash }
    return text
end

--- Find `name` in the unparsed files. Returns { {file, line, char}, ... }.
function M.frontier_find(name)
    local hits = {}
    if not name or #name < 2 then return hits end
    for _, file in ipairs(M.files) do
        local mod = M.by_id[file]
        if mod and mod.unparsed then
            local text = frontier_text(file)
            if text then
                local s = text:find('%f[%w_]' .. name:gsub('([^%w])', '%%%1') .. '%f[^%w_]')
                if s then
                    local before = text:sub(1, s - 1)
                    local _, nl = before:gsub('\n', '')
                    local col = s - (before:find('\n[^\n]*$') or 0) - 1
                    hits[#hits + 1] = { file = file, line = nl, char = col }
                end
            end
        end
    end
    return hits
end

-- ── the reference layer: durable, id-free node references ───────────────────

local function callee_names(id)
    local out = {}
    for _, c in ipairs(M.calls_by_fn[id] or {}) do out[#out + 1] = c.callee end
    return out
end

--- The durable reference for a node: what pins, plans and journals hold
--- instead of a raw (line-embedding, session-lived) id.
function M.ref_of(id)
    local n = M.node(id)
    if not n then return nil end
    local sibs = {}
    for _, x in ipairs(M.by_file[n.file] or {}) do
        if x.kind == n.kind and x.name == n.name then sibs[#sibs + 1] = x end
    end
    return require('cartograph.refs').of(n, sibs, callee_names(id))
end

--- Resolve a durable reference against the CURRENT graph. Returns
--- (id, note?) — note carries drift/rename/ordinal caveats — or
--- (nil, why) for missing/ambiguous.
function M.resolve_ref(ref)
    return require('cartograph.refs').resolve(ref, M.by_file[ref.file] or {}, {
        callees = function (n) return callee_names(n.id) end,
        all = M.by_file[ref.file],
    })
end

--- Register a ref edge created after ingest (pins), mirroring the
--- indexing ingest does.
function M.add_edge(e)
    table.insert(M.data.edges, e)
    if e.kind == 'ref' then
        M.uses[e.from] = M.uses[e.from] or {}
        table.insert(M.uses[e.from], e.to)
        M.usedby[e.to] = M.usedby[e.to] or {}
        table.insert(M.usedby[e.to], e.from)
        M.occ[e.from .. '\31' .. e.to] = e.at or {}
    end
    return e
end

--- Register a node created after ingest (frontier landings).
function M.add_node(n)
    if M.by_id[n.id] then return n end
    table.insert(M.data.nodes, n)
    M.by_id[n.id] = n
    M.by_file[n.file] = M.by_file[n.file] or {}
    table.insert(M.by_file[n.file], n)
    return n
end

---@param fn fun(id: string)
function M.on_focus(fn) table.insert(M._subs, fn) end

---@param id string?
function M.set_focus(id)
    if id == M.focused then return end
    M.focused = id
    for _, fn in ipairs(M._subs) do pcall(fn, id) end
end

-- navigation history: a jumplist over LOCATIONS. Deliberate pivots (<CR>/l in
-- the browser, source <C-]>) record where they jumped from; moving the cursor
-- doesn't — the same rule as vim's own jumplist. Each entry is a snapshot:
-- the focused node plus whatever the location provider captures (the
-- browser's level/file/cursor), so back() restores the PLACE, not just the
-- focus.
M._nav_back, M._nav_fwd = {}, {}
M.loc_provider = nil -- { get = fn() -> loc, set = fn(loc) }, set by the browser

local function snapshot()
    return { id = M.focused, loc = M.loc_provider and M.loc_provider.get() or nil }
end

local function restore(entry)
    M.set_focus(entry.id)
    -- loc AFTER focus: focus subscribers may re-scope the browser; the
    -- recorded location wins
    if M.loc_provider and entry.loc then M.loc_provider.set(entry.loc) end
end

--- A deliberate jump: remember where we came from, then focus.
function M.pivot(id)
    if not id or id == M.focused then return end
    M._nav_back[#M._nav_back + 1] = snapshot()
    M._nav_fwd = {}
    M.set_focus(id)
end

-- pop entries until one whose node still exists (refresh remaps what it
-- can; a deleted node's entry is simply gone, like a closed buffer in the
-- jumplist). id = nil entries are place-only snapshots and stay valid.
local function pop_live(stack)
    while true do
        local e = table.remove(stack)
        if not e then return nil end
        if not e.id or M.by_id[e.id] then return e end
    end
end

--- <C-o> / <C-t>: return to the location of the previous pivot.
function M.back()
    local e = pop_live(M._nav_back)
    if not e then return end
    M._nav_fwd[#M._nav_fwd + 1] = snapshot()
    restore(e)
end

--- <C-i>: undo a back().
function M.forward()
    local e = pop_live(M._nav_fwd)
    if not e then return end
    M._nav_back[#M._nav_back + 1] = snapshot()
    restore(e)
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

-- lens channel: an active overlay that other panes render (e.g. 'concerns' =
-- colour the source by untangle concern). Set by whichever pane owns the toggle
-- (the source pane's <Tab>); read by the source pane.
M.lens = nil
M._lens_subs = {}
---@param fn fun(lens: string?)
function M.on_lens(fn) table.insert(M._lens_subs, fn) end
---@param lens string?
function M.set_lens(lens)
    if lens == M.lens then return end
    M.lens = lens
    for _, fn in ipairs(M._lens_subs) do pcall(fn, lens) end
end

-- staging channel: the move-set (symbols marked to move) and destination file.
-- This is what the plan bar reads; marks live in the symbol list. A separate
-- channel from focus/highlight because staging persists as you navigate.
M.moveset  = {}   -- id -> true
M._order   = {}   -- ids in staging order (for `u` / unstage-last)
M.dest     = nil  -- destination file
M._plan_subs = {}
---@param fn fun()
function M.on_plan(fn) table.insert(M._plan_subs, fn) end
local function fire_plan() for _, fn in ipairs(M._plan_subs) do pcall(fn) end end

--- Stage `id` for moving (idempotent). Cut-into-the-move-set.
function M.stage(id)
    if not id or M.moveset[id] then return end
    M.moveset[id] = true
    M._order[#M._order + 1] = id
    fire_plan()
end

--- Unstage `id`.
function M.unstage(id)
    if not id or not M.moveset[id] then return end
    M.moveset[id] = nil
    for i = #M._order, 1, -1 do
        if M._order[i] == id then table.remove(M._order, i) end
    end
    fire_plan()
end

--- Toggle whether `id` is staged. Returns the new state.
function M.toggle_stage(id)
    if not id then return false end
    if M.moveset[id] then M.unstage(id) else M.stage(id) end
    return M.moveset[id] == true
end

--- Unstage the most recently staged symbol (the `u` / undo action).
function M.unstage_last()
    local id = M._order[#M._order]
    if id then M.unstage(id) end
    return id
end

function M.is_staged(id) return M.moveset[id] == true end

--- Ordered list of staged ids (stable: by file then name).
function M.staged_ids()
    local ids = {}
    for id in pairs(M.moveset) do ids[#ids + 1] = id end
    table.sort(ids, function (a, b)
        local na, nb = M.node(a), M.node(b)
        local fa, fb = na and na.file or a, nb and nb.file or b
        if fa ~= fb then return fa < fb end
        return (na and na.name or a) < (nb and nb.name or b)
    end)
    return ids
end

--- Set (or clear, with nil) the destination file.
function M.set_dest(file)
    if file == M.dest then return end
    M.dest = file
    fire_plan()
end

--- Clear the whole move-set and destination.
function M.clear_stage()
    M.moveset = {}
    M._order = {}
    M.dest = nil
    fire_plan()
end

function M.node(id) return id and M.by_id[id] or nil end
function M.abspath(node) return M.data.root .. '/' .. node.file end

return M
