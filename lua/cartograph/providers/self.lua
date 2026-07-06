-- The self provider: the RUNNING nvim instance as a graph source. Where
-- the tree-sitter provider scans a directory you name, `self` asks the
-- runtime what it has actually loaded — `nvim_list_runtime_paths()` is
-- the loaded-plugin roster (lazy, packer, native `packadd` all add a
-- plugin to the runtimepath exactly when it loads it, so rtp is the
-- manager-agnostic truth of what's live), unioned into ONE corpus under
-- a synthetic `self://loaded` root so a require from your config into a
-- plugin — or one plugin into another — resolves in a single graph.
--
-- $VIMRUNTIME is held back as a LAZY node: it's huge and rarely the thing
-- you're exploring, but edges into it (require 'vim.lsp') must still land
-- somewhere real, so it's present and descendable — its subtree extracts
-- only when you go in. See store `lazy_roots` / init's descend hook.
--
-- This is the base graph; the self ORACLE (resolve requires, loaded-vs-not,
-- dynamic dispatch, runtime registrations) enriches it on top — the same
-- role clangd/lua-ls play for on-disk projects, but in-process.

local M = {}

local function norm(p)
    return (vim.fn.fnamemodify(p, ':p') or p):gsub('/+$', '')
end

--- Partition the runtimepath into extractable plugin roots and the runtime
--- roots we hold lazy. Returns (roots, vimruntime):
---   roots      = { { label, dir }, ... }  (config + loaded plugins)
---   vimruntime = absolute $VIMRUNTIME dir  ('' if unset)
--- rtp entries nested inside a kept root (a plugin's own `after/`, bundled
--- opt plugins) are dropped — the parent's tree walk already covers them.
function M.roots()
    local vr = norm(vim.env.VIMRUNTIME or '')
    local raw = {}
    for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
        raw[#raw + 1] = norm(p)
    end
    -- shortest first, so a parent is always seen before its nested dirs
    table.sort(raw)
    table.sort(raw, function (a, b) return #a < #b end)
    local function under(p, base)
        return p == base or p:sub(1, #base + 1) == base .. '/'
    end
    local kept, seen = {}, {}
    for _, p in ipairs(raw) do
        -- $VIMRUNTIME, its bundled dirs, and the sibling C-runtime lib dir
        -- all fold into the one lazy runtime node — skip them here
        if not (vr ~= '' and under(p, vr)) and not p:match('/lib/nvim$')
            and not seen[p] then
            local nested = false
            for _, k in ipairs(kept) do
                if under(p, k.dir) then nested = true break end
            end
            if not nested then
                seen[p] = true
                kept[#kept + 1] = { dir = p }
            end
        end
    end
    -- label each root by basename, disambiguating collisions
    local used = {}
    for _, r in ipairs(kept) do
        local base = vim.fn.fnamemodify(r.dir, ':t')
        if base == '' then base = 'root' end
        local label, i = base, 1
        while used[label] do i = i + 1; label = base .. '~' .. i end
        used[label] = true
        r.label = label
    end
    return kept, vr
end

--- Build the roster: labelled file keys + the label→dir map. `abs` turns
--- a key back into a real path. Returns nil,why if nothing is loaded.
function M.roster()
    local ts = require 'cartograph.providers.treesitter'
    local kept, vr = M.roots()
    local roots, files = {}, {}
    for _, r in ipairs(kept) do
        local list = ts.list_files(r.dir)
        if #list > 0 then
            roots[r.label] = r.dir
            for _, rel in ipairs(list) do
                files[#files + 1] = r.label .. '/' .. rel
            end
        end
    end
    if #files == 0 then
        return nil, 'no loaded source on the runtimepath'
    end
    return { root = 'self://loaded', roots = roots, files = files, vimruntime = vr }
end

--- The lazy $VIMRUNTIME placeholder: present so edges into the runtime land
--- somewhere descendable, but not extracted until asked. `lazy` carries the
--- dir to extract when descended.
function M.lazy_node(vr)
    return { id = '$VIMRUNTIME', name = '$VIMRUNTIME', kind = 'module',
        file = '$VIMRUNTIME', lazy = vr, order = -1,
        range = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } } }
end

--- Descended the lazy $VIMRUNTIME node: extract its tree NOW (small — ~170
--- files, so synchronous), splice it into the live graph under a VIMRUNTIME
--- label, drop the placeholder, and relink so requires into `vim.*` resolve
--- against the freshly-present files. Returns (data, added) or (nil, why).
--- The caller re-ingests.
function M.load_runtime(store, node)
    local vr = node and node.lazy
    if type(vr) ~= 'string' or vr == '' then return nil, 'not a lazy runtime node' end
    local ts = require 'cartograph.providers.treesitter'
    local files = {}
    for _, rel in ipairs(ts.list_files(vr)) do
        files[#files + 1] = 'VIMRUNTIME/' .. rel
    end
    if #files == 0 then return nil, '$VIMRUNTIME has no extractable source' end
    local sub = ts.extract('self://loaded', { files = files,
        abs = function (f) return vr .. '/' .. (f:gsub('^VIMRUNTIME/', '')) end })
    local data = store.data
    data.roots = data.roots or {}
    data.roots['VIMRUNTIME'] = vr
    -- drop the placeholder, splice the real files in
    local kept = {}
    for _, n in ipairs(data.nodes) do
        if n.id ~= node.id then kept[#kept + 1] = n end
    end
    data.nodes = kept
    vim.list_extend(data.nodes, sub.nodes)
    vim.list_extend(data.edges, sub.edges)
    vim.list_extend(data.calls, sub.calls)
    for f, s in pairs(sub.stamps or {}) do data.stamps[f] = s end
    data.vimruntime = nil -- consumed
    data._live_index, data._loaded_files = nil, nil -- invalidate oracle caches
    -- re-resolve refs + requires against the now-present runtime (require 'vim.*')
    ts.relink(data)
    require('cartograph.self_oracle').resolve_requires(data)
    return data, #sub.nodes
end

--- Extract the loaded-plugin corpus as one neutral-schema graph.
---@return table? data, string? err
function M.extract()
    local roster, why = M.roster()
    if not roster then return nil, why end
    local absmap = roster.roots
    local function abs(file)
        local label, rest = file:match('^([^/]+)/(.*)$')
        return (absmap[label] or '') .. '/' .. (rest or file)
    end
    local ts = require 'cartograph.providers.treesitter'
    local data = ts.extract(roster.root, { files = roster.files, abs = abs })
    -- a session-scoped SAMPLE, not a cacheable tree: `self` is whatever this
    -- instance loaded, which the next launch may not match. Stamp when true.
    data.provider = 'self'
    data.root = roster.root
    data.roots = roster.roots
    data.vimruntime = roster.vimruntime ~= '' and roster.vimruntime or nil
    data.fetched_at = os.time()
    return data
end

return M
