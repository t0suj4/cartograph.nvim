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
    local data = vim.json.decode(txt)
    -- a dump carries no file stamps; record disk state AT LOAD. Drift
    -- between dump generation and now is undetectable (the photograph's
    -- honest limitation); drift after load is caught by stale().
    if not data.stamps and data.root then
        data.stamps = {}
        local seen = {}
        for _, n in ipairs(data.nodes or {}) do
            if n.file and not seen[n.file] then
                seen[n.file] = true
                local st = vim.uv.fs_stat(M.abs_in(data, n.file))
                if st then
                    data.stamps[n.file] = ('%d:%d:%d')
                        :format(st.mtime.sec, st.mtime.nsec, st.size)
                end
            end
        end
    end
    return M.ingest(data)
end

--- Build all indexes from a decoded graph (schema #1). Split out from load() so
--- it can be driven directly from in-memory graphs (tests, non-file providers).
---@param data table
-- Per-item index builders, shared by the full ingest and the incremental
-- streaming step (M.ingest_step) so the two produce identical indexes by
-- construction — the step is just these applied to the delta on top of what's
-- already built. by_id overwrites (a real module node replaces its stub);
-- by_file/calls/edges append.
-- The builders write into T (= M for the live indexes) so M.audit can derive
-- a fresh scratch bundle through the SAME code and diff it against the live
-- tables — the derive logic exists exactly once.
local function idx_node(T, n)
    T.by_id[n.id] = n
    -- NAME axis (the LSP name→node index, [[cartograph-slice-api]]): every
    -- named node, keyed by its bare name → id list (overloads/same-named
    -- locals across files legitimately collide, so it's a list). Served
    -- through Band:named so workspaceSymbol has one home, not a special.
    if n.name then
        T.by_name[n.name] = T.by_name[n.name] or {}
        table.insert(T.by_name[n.name], n.id)
    end
    if n.kind ~= 'module' then
        T.by_file[n.file] = T.by_file[n.file] or {}
        table.insert(T.by_file[n.file], n)
    end
end
local function idx_call(T, c)
    if c.to then
        T.calls_to[c.to] = T.calls_to[c.to] or {}
        table.insert(T.calls_to[c.to], c)
    end
    if c.fn then
        T.calls_by_fn[c.fn] = T.calls_by_fn[c.fn] or {}
        table.insert(T.calls_by_fn[c.fn], c)
    end
    -- FILE axis (Band:calls_of): the call rows made from a file — the
    -- refresh / LSP re-extraction unit
    if c.file then
        T.calls_by_file[c.file] = T.calls_by_file[c.file] or {}
        table.insert(T.calls_by_file[c.file], c)
    end
    -- PROV axis (Band:by_prov): which resolution pass/pack landed this call —
    -- pass-value accounting without ablation ([[cartograph-provenance-surfacing]])
    if c.prov then
        T.calls_by_prov[c.prov] = T.calls_by_prov[c.prov] or {}
        table.insert(T.calls_by_prov[c.prov], c)
    end
end
local function idx_edge(T, e)
    if e.kind == 'ref' then
        -- self edges (recursion) carry occurrences only: they must not
        -- inflate usedby/uses (dead-function lint, heat, tints)
        if e.from ~= e.to then
            T.uses[e.from]   = T.uses[e.from]   or {}; table.insert(T.uses[e.from], e.to)
            T.usedby[e.to]   = T.usedby[e.to]   or {}; table.insert(T.usedby[e.to], e.from)
        end
        T.occ[e.from .. '\31' .. e.to] = e.at
        if e.inferred then T.edge_inferred[e.from .. '\31' .. e.to] = true end
        if e.tinf then T.edge_tinf[e.from .. '\31' .. e.to] = true end
    elseif e.kind == 'import' then
        T.imports_in[e.to] = T.imports_in[e.to] or {}
        table.insert(T.imports_in[e.to], { from = e.from, sideeffect = e.sideeffect == true })
        T.imports_out[e.from] = T.imports_out[e.from] or {}
        table.insert(T.imports_out[e.from], e.to)
    elseif e.kind == 'use' then
        -- rw = the write axis (1 read / 2 write / 3 both); ABSENT when the
        -- language ships no classifier — unknown, never a claimed "read"
        T.var_usedby[e.to] = T.var_usedby[e.to] or {}
        table.insert(T.var_usedby[e.to],
            { from = e.from, at = e.at or {}, rw = e.rw, gw = e.gw, gp = e.gp,
                flds = e.flds })
        T.var_uses[e.from] = T.var_uses[e.from] or {}
        table.insert(T.var_uses[e.from],
            { to = e.to, at = e.at or {}, rw = e.rw, gw = e.gw, gp = e.gp,
                flds = e.flds })
    elseif e.kind == 'reg' then
        -- a registration: the fn is kept alive by `from` (a module,
        -- dispatch table). The alibi both ways — a fn's registrants,
        -- a registrant's roster.
        T.reg_by[e.to] = T.reg_by[e.to] or {}
        table.insert(T.reg_by[e.to], { from = e.from, at = e.at or {} })
        T.registers[e.from] = T.registers[e.from] or {}
        table.insert(T.registers[e.from], e.to)
    end
end

-- reset every derived index to empty (full ingest starts here)
local function reset_indexes()
    M.by_id, M.by_file, M.files = {}, {}, {}
    M.by_name = {} -- NAME axis: node name -> id list (Band:named)
    M.calls_to, M.calls_by_fn = {}, {}
    M.calls_by_file, M.calls_by_prov = {}, {} -- FILE + PROV call axes
    M.uses, M.usedby, M.occ, M.edge_inferred = {}, {}, {}, {}
    M.edge_tinf = {}
    M.cone, M._cone_set, M._cone_files = nil, nil, nil -- ids churn on re-ingest
    M._territory = nil
    M.marks = {} -- node marks (char -> id); ids churn, so reset with the graph
    M.var_usedby, M.var_uses = {}, {}
    M.imports_in, M.imports_out = {}, {}
    M.reg_by, M.registers = {}, {}
end

function M.ingest(data)
    M.data    = data
    M.toc     = nil -- load-order manifest; cartograph.toc.attach() sets it
    M._frontier_cache = {}
    M._content_cache = {}
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
    reset_indexes()
    local seen = {}
    for _, n in ipairs(M.data.nodes) do
        idx_node(M, n)
        if not seen[n.file] then seen[n.file] = true; table.insert(M.files, n.file) end
    end
    table.sort(M.files)
    M._fileset = seen -- files already in M.files (an incremental step extends it)
    for _, list in pairs(M.by_file) do
        table.sort(list, function (a, b) return a.order < b.order end)
    end
    for _, c in ipairs(M.data.calls or {}) do idx_call(M, c) end
    for _, e in ipairs(M.data.edges or {}) do idx_edge(M, e) end
    -- baseline for a subsequent incremental step (see M.ingest_step)
    M._ing = { n = #M.data.nodes, c = #(M.data.calls or {}), e = #(M.data.edges or {}) }
    -- ARGV FOLD (eager-but-folded): resolution is done by now (it runs in
    -- extract, before ingest), so a.to is set — collapse the fat per-call
    -- argv/args tables into one columnar store. Every argv reader goes
    -- through the dual-mode accessor, so post-passes (xlang/sql/… re-run on
    -- the folded graph, incl. refresh's whole-graph re-attach) read columns
    -- transparently. Idempotent; refresh's fresh per-file argv re-folds.
    require('cartograph.argv').fold(M.data)
    -- DF-STRANGLER STEP 6: df is now a COARSE PROJECTION OF FLOW derived AT
    -- EXTRACT (treesitter extract_defs sets n.df = flow.coarse(fl) for every
    -- generic body_field lang — no separate dfreg build, the double walk
    -- retired). So ingest no longer rebuilds df; it just folds the coarse
    -- records below. (The legacy dfreg df survives only under opts.legacy_df,
    -- the dfparity oracle path, which never runs through ingest.) `defr` is
    -- gone entirely — trace + extract.plan read flow.reaching_cfg (steps 5).
    -- DF FOLD (same lifecycle): the nested per-fn statement records — the
    -- LARGEST foldable datum — collapse into one columnar store; every df
    -- reader goes through the dual-mode df.lua accessors, so views
    -- materialize raw-shaped on demand. Cache shards encoded BEFORE ingest
    -- stay raw; refresh's fresh per-file df reads raw via dual mode.
    require('cartograph.df').fold(M.data)
    -- FLOW FOLD (df-strangler step 4, same lifecycle as df): collapse the eager
    -- per-fn fine flow rows into one shape-interned columnar store; dual-mode
    -- flow.lua accessors materialize rows raw-shaped on demand. Cache shards
    -- encoded pre-ingest stay raw; refresh's fresh per-file flow reads raw. The
    -- coarse projection of this store == df (dfgate/guards parity oracle).
    require('cartograph.flow').fold(M.data)
    -- RANGE FOLD (the 128MB half): every c.at / e.at element / n.range
    -- interns BY TABLE IDENTITY into four coordinate columns (the c.at↔e.at
    -- addref aliasing folds to one index for free) and becomes an index;
    -- e.at lists mutate in place so occ references stay valid. Readers all
    -- go through at.lua's dual-mode accessors; post-fold arrivals (refresh
    -- files, oracle callers, literal highlight ranges) stay raw tables.
    require('cartograph.at').fold(M.data)
    -- REFUSED INTERNING: identical refusals (same rule/cands/n/witness)
    -- share ONE record — 8x dedup on server, shape unchanged, readers
    -- untouched. Records are immutable post-resolution (resolution clears
    -- the FIELD, never edits the record), so sharing is safe.
    require('cartograph.refused').intern(M.data)
    -- extraction-peak Stage 0: LuaJIT traces compiled DURING a big extract
    -- pin extraction-era objects as GC trace constants — measured on the
    -- server corpus: 151.9MB of dead extraction garbage held resident,
    -- 0.8MB after a flush. Traces recompile in ms; the pinned garbage
    -- never collects on its own. Small graphs skip it (nothing pinned
    -- worth the re-warm).
    if #M.data.nodes > 20000 and rawget(_G, 'jit') and jit.flush then
        jit.flush()
        collectgarbage(); collectgarbage()
    end
    return M.data
end

-- The resident TOPOLOGY view: a fold-backed Band, built lazily on first
-- query and cached until the next ingest (generation-keyed). This is rung
-- (c) — the fold becomes the resident representation consumers read
-- topology through; the wide uses/usedby/… tables stay for the detail
-- readers (at/sideeffect) until rung (d) migrates and drops them. Lazy so
-- ingest_step (streaming) pays nothing until the graph settles and a
-- consumer asks.
function M.topo()
    if M._topo_gen ~= M.generation then
        M._fold = require('cartograph.fold').build(M.data)
        -- pass the store as the identity/detail handle so the resident Band
        -- answers the name/file/site axes too (topology folded, identity wide)
        M._topo = require('cartograph.band').from_fold(M._fold, M)
        M._topo_gen = M.generation
    end
    return M._topo
end

--- Repoint the store at a growing accumulator for INCREMENTAL streaming. The
--- (stub) full ingest already built the base indexes + the complete file list;
--- this just marks the baseline so ingest_step folds in only what arrives
--- after. M.files is NOT reset — steps never shrink the roster.
function M.begin_stream(acc)
    M.data = acc
    M._ing = { n = 0, c = 0, e = 0 }
    M._fileset = {}
    for _, f in ipairs(M.files) do M._fileset[f] = true end
end

--- Fold newly-arrived nodes/edges/calls into the live indexes — O(delta), not
--- a full O(graph) rebuild every update. Identical per-item logic to M.ingest,
--- so the indexes match a full ingest of the same accumulator; the final
--- on_done still does one authoritative full ingest. Does NOT bump generation
--- or reset nav (same graph, growing).
function M.ingest_step(acc)
    M.data = acc
    local ing = M._ing or { n = 0, c = 0, e = 0 }
    M._fileset = M._fileset or {}
    local dirty, newfiles = {}, false
    for i = ing.n + 1, #acc.nodes do
        local n = acc.nodes[i]
        idx_node(M, n)
        if n.kind ~= 'module' then dirty[n.file] = true end
        if not M._fileset[n.file] then -- a file not in the roster yet: add it
            M._fileset[n.file] = true
            M.files[#M.files + 1] = n.file
            newfiles = true
        end
    end
    if newfiles then table.sort(M.files) end
    for f in pairs(dirty) do
        table.sort(M.by_file[f], function (a, b) return a.order < b.order end)
    end
    for i = (ing.c or 0) + 1, #(acc.calls or {}) do idx_call(M, acc.calls[i]) end
    for i = (ing.e or 0) + 1, #(acc.edges or {}) do idx_edge(M, acc.edges[i]) end
    M._ing = { n = #acc.nodes, c = #(acc.calls or {}), e = #(acc.edges or {}) }
    return M.data
end

-- audit comparison: a list reduced to a multiset of canonical keys, so append
-- order (which in-place writers legitimately change) never false-positives
local function audit_multiset(list, keyf)
    local m = {}
    for _, v in ipairs(list or {}) do
        local k = keyf and keyf(v) or tostring(v)
        m[k] = (m[k] or 0) + 1
    end
    return m
end
local function audit_lists(out, name, live, derived, keyf)
    local keys = {}
    for k in pairs(live or {}) do keys[k] = true end
    for k in pairs(derived or {}) do keys[k] = true end
    for k in pairs(keys) do
        local a = audit_multiset((live or {})[k], keyf)
        local b = audit_multiset((derived or {})[k], keyf)
        for kk, n in pairs(a) do
            if b[kk] ~= n then
                out[#out + 1] = ('%s[%s]: live %dx %s, derived %dx')
                    :format(name, k, n, kk, b[kk] or 0)
            end
        end
        for kk, n in pairs(b) do
            if a[kk] == nil then
                out[#out + 1] = ('%s[%s]: derived %dx %s, live 0x')
                    :format(name, k, n, kk)
            end
        end
    end
end
local function audit_keyset(out, name, live, derived)
    for k in pairs(live or {}) do
        if (derived or {})[k] == nil then
            out[#out + 1] = ('%s: live has %s, a fresh derive does not'):format(name, k)
        end
    end
    for k in pairs(derived or {}) do
        if (live or {})[k] == nil then
            out[#out + 1] = ('%s: derive produces %s, live lacks it'):format(name, k)
        end
    end
end

--- Re-derive every index from M.data into a scratch bundle through the SAME
--- per-item builders and diff against the live tables — the Log/View rule made
--- executable: any in-place writer that lets a derived View drift from what a
--- full derive produces shows up as a named divergence. Order-insensitive
--- (writers may reorder lists); presence and multiplicity are the contract.
--- Returns a list of divergence strings (empty = clean); nil, why when there
--- is no graph or a streaming extraction is mid-append.
function M.audit()
    if not M.data then return nil, 'no graph' end
    if M.data.partial then return nil, 'streaming — audit after the stream settles' end
    local T = { by_id = {}, by_file = {}, by_name = {}, calls_to = {}, calls_by_fn = {},
        calls_by_file = {}, calls_by_prov = {},
        uses = {}, usedby = {}, occ = {}, edge_inferred = {}, edge_tinf = {},
        var_usedby = {}, var_uses = {}, imports_in = {}, imports_out = {},
        reg_by = {}, registers = {} }
    for _, n in ipairs(M.data.nodes or {}) do idx_node(T, n) end
    for _, c in ipairs(M.data.calls or {}) do idx_call(T, c) end
    for _, e in ipairs(M.data.edges or {}) do idx_edge(T, e) end
    local out = {}
    audit_keyset(out, 'by_id', M.by_id, T.by_id)
    audit_keyset(out, 'occ', M.occ, T.occ)
    audit_keyset(out, 'edge_inferred', M.edge_inferred, T.edge_inferred)
    local id = function (v) return v.id end
    audit_lists(out, 'by_file', M.by_file, T.by_file, id)
    audit_lists(out, 'by_name', M.by_name, T.by_name) -- values are id strings

    audit_lists(out, 'uses', M.uses, T.uses)
    audit_lists(out, 'usedby', M.usedby, T.usedby)
    audit_lists(out, 'imports_out', M.imports_out, T.imports_out)
    audit_lists(out, 'registers', M.registers, T.registers)
    local from = function (v) return v.from end
    audit_lists(out, 'imports_in', M.imports_in, T.imports_in,
        function (v) return v.from .. (v.sideeffect and '!' or '') end)
    audit_lists(out, 'var_usedby', M.var_usedby, T.var_usedby, from)
    audit_lists(out, 'var_uses', M.var_uses, T.var_uses, function (v) return v.to end)
    audit_lists(out, 'reg_by', M.reg_by, T.reg_by, from)
    local site = function (c) return (c.file or '?') .. ':' .. tostring(c.line) end
    audit_lists(out, 'calls_to', M.calls_to, T.calls_to, site)
    audit_lists(out, 'calls_by_fn', M.calls_by_fn, T.calls_by_fn, site)
    audit_lists(out, 'calls_by_file', M.calls_by_file, T.calls_by_file, site)
    audit_lists(out, 'calls_by_prov', M.calls_by_prov, T.calls_by_prov, site)
    table.sort(out)
    return out
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
--- Skipped while streaming (rebuilding data.nodes under the step's prefix
--- baseline would corrupt it; landings stay one round stale instead).
function M.frontier_evict(file)
    if M.data.partial then return end
    local keep = {}
    for _, n in ipairs(M.data.nodes) do
        if n.file == file and n.unparsed and n.kind ~= 'module' then
            M.by_id[n.id] = nil
            local b = n.name and M.by_name[n.name] -- keep the NAME axis in sync
            if b then
                for i = #b, 1, -1 do if b[i] == n.id then table.remove(b, i) end end
            end
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
    local path = M.abs(file)
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

-- ── the working set: what the user is working ON ────────────────────────────
-- Marked nodes, held as REFS (the durable identity — survives refresh
-- remaps, follows renames with a note) and persisted per project root in
-- the STATE dir: user intent, not derived data, so it outlives cache
-- wipes and sessions. `ids` is the session-resolved view; `pending` are
-- refs that did not resolve against the current graph (kept, reported,
-- retried after every splice).

M.workset = { ids = {}, refs = {}, pending = {}, last = nil }

--- The per-root working-set state file (public: tests, cleanup).
function M.ws_file(root)
    local dir = vim.fn.stdpath('state') .. '/cartograph'
    vim.fn.mkdir(dir, 'p')
    root = (root or (M.data and M.data.root) or ''):gsub('/+$', '')
    return dir .. '/' .. root:gsub('[/\\:]', '%%') .. '.set.json'
end
local function ws_state_file() return M.ws_file(nil) end

--- Peek the persisted working set's FILES without loading it — the
--- parallel cold open puts them at the head of the extraction queue.
function M.ws_peek(root)
    local fd = io.open(M.ws_file(root), 'r')
    if not fd then return {} end
    local txt = fd:read('a')
    fd:close()
    local ok, saved = pcall(vim.json.decode, txt)
    local out, seen = {}, {}
    if ok and type(saved) == 'table' then
        for _, r in ipairs(saved.refs or {}) do
            if r.file and not seen[r.file] then
                seen[r.file] = true
                out[#out + 1] = r.file
            end
        end
    end
    return out
end

local function ws_persist()
    local fd = io.open(ws_state_file(), 'w')
    if not fd then return end
    local refs = {}
    for _, r in ipairs(M.workset.refs) do refs[#refs + 1] = r end
    for _, r in ipairs(M.workset.pending) do refs[#refs + 1] = r end
    fd:write(vim.json.encode({ version = 1, refs = refs }))
    fd:close()
end

--- Toggle a node in/out of the working set. Returns membership.
function M.ws_toggle(id)
    local n = M.node(id)
    if not n then return nil end
    if M.workset.ids[id] then
        M.workset.ids[id] = nil
        for i, r in ipairs(M.workset.refs) do
            if r._id == id then table.remove(M.workset.refs, i) break end
        end
    else
        M.workset.ids[id] = true
        local ref = M.ref_of(id)
        ref._id = id -- session pointer; refs are the durable half
        table.insert(M.workset.refs, ref)
    end
    M.workset.rev = (M.workset.rev or 0) + 1
    ws_persist()
    return M.workset.ids[id] == true
end

function M.ws_has(id) return M.workset.ids[id] == true end

--- Members ordered by (file, source order) — the ]w/[w cycle order.
function M.ws_list()
    local out = {}
    for id in pairs(M.workset.ids) do out[#out + 1] = M.node(id) end
    table.sort(out, function (a, b)
        if a.file ~= b.file then return a.file < b.file end
        return (a.order or 0) < (b.order or 0)
    end)
    return out
end

--- Resolve refs (loaded or pending) against the CURRENT graph. Renames
--- are followed — the working set is attention, not a transaction — but
--- each note is surfaced. Returns the notes.
function M.ws_resolve()
    local refs = {}
    for _, r in ipairs(M.workset.refs) do refs[#refs + 1] = r end
    for _, r in ipairs(M.workset.pending) do refs[#refs + 1] = r end
    M.workset.ids, M.workset.refs, M.workset.pending = {}, {}, {}
    M.workset.rev = (M.workset.rev or 0) + 1
    local notes = {}
    for _, ref in ipairs(refs) do
        ref._id = nil
        local id, note = M.resolve_ref(ref)
        if id then
            if not M.workset.ids[id] then
                M.workset.ids[id] = true
                ref._id = id
                if note and note:match('^renamed') then
                    -- attention follows the rename; the ref is renewed
                    ref = M.ref_of(id)
                    ref._id = id
                end
                table.insert(M.workset.refs, ref)
            end
            if note then
                notes[#notes + 1] = ('%s %s: %s'):format(ref.name, ref.file, note)
            end
        else
            table.insert(M.workset.pending, ref)
            notes[#notes + 1] = ('%s %s: %s'):format(ref.name, ref.file,
                note or 'missing')
        end
    end
    return notes
end

--- Load the persisted set for the current root and resolve it.
function M.ws_load()
    M.workset = { ids = {}, refs = {}, pending = {}, last = nil }
    local fd = io.open(ws_state_file(), 'r')
    if not fd then return {} end
    local txt = fd:read('a')
    fd:close()
    local ok, saved = pcall(vim.json.decode, txt)
    if not (ok and type(saved) == 'table' and saved.refs) then return {} end
    M.workset.pending = saved.refs
    local notes = M.ws_resolve()
    ws_persist()
    return notes
end

--- Orientation against the index: the shortest graph route from `id`
--- to the nearest working-set member, expressed as the NAVIGATION the
--- user would perform ('→' descend into a callee, '↖' up through the
--- callers view). Multi-source BFS from all members over uses ∪ usedby,
--- cached per (graph generation, index revision).
--- Returns { dist, path = { {id, name, dir}, ... } } or nil.
function M.ws_route(id)
    if not next(M.workset.ids) then return nil end
    local key = tostring(M.generation or 0) .. ':' .. tostring(M.workset.rev or 0)
    local bfs = M._ws_bfs
    if not bfs or bfs.key ~= key then
        local dist, step, q, qi = {}, {}, {}, 1
        for mid in pairs(M.workset.ids) do
            dist[mid] = 0
            q[#q + 1] = mid
        end
        while q[qi] do
            local v = q[qi]
            qi = qi + 1
            local d = dist[v]
            for _, x in ipairs(M.usedby[v] or {}) do -- x calls v: x descends
                if not dist[x] then
                    dist[x] = d + 1
                    step[x] = { id = v, dir = '→' }
                    q[#q + 1] = x
                end
            end
            for _, x in ipairs(M.uses[v] or {}) do -- v calls x: x goes ↖
                if not dist[x] then
                    dist[x] = d + 1
                    step[x] = { id = v, dir = '↖' }
                    q[#q + 1] = x
                end
            end
        end
        bfs = { key = key, dist = dist, step = step }
        M._ws_bfs = bfs
    end
    local d = bfs.dist[id]
    if not d then return nil end
    local path, cur = {}, id
    while cur and bfs.dist[cur] > 0 do
        local s = bfs.step[cur]
        local n = M.node(s.id)
        path[#path + 1] = { id = s.id, dir = s.dir,
            name = (n and n.name or s.id):gsub('[\n\r]+', ' ') }
        cur = s.id
    end
    return { dist = d, path = path }
end

--- The RETURN path: the nearest indexed object in the jump history and
--- how many back-steps (<C-o>) lead to it. nil if no member is behind.
function M.ws_back()
    for i = #M._nav_back, 1, -1 do
        local e = M._nav_back[i]
        if e.id and M.workset.ids[e.id] then
            local n = M.node(e.id)
            return { id = e.id, steps = #M._nav_back - i + 1,
                name = (n and n.name or e.id):gsub('[\n\r]+', ' ') }
        end
    end
    return nil
end

--- Register a ref edge created after ingest (pins), mirroring the
--- indexing ingest does (self edges carry occurrences only, as at ingest).
--- Refuses (nil) while a streaming extraction is appending to the same
--- arrays — the step's prefix baseline (M._ing) can't survive interleaved
--- writers.
function M.add_edge(e)
    if M.data.partial then return nil end
    table.insert(M.data.edges, e)
    if e.kind == 'ref' then
        if e.from ~= e.to then
            M.uses[e.from] = M.uses[e.from] or {}
            table.insert(M.uses[e.from], e.to)
            M.usedby[e.to] = M.usedby[e.to] or {}
            table.insert(M.usedby[e.to], e.from)
        end
        M.occ[e.from .. '\31' .. e.to] = e.at -- raw, exactly as idx_edge derives it
        if e.inferred then M.edge_inferred[e.from .. '\31' .. e.to] = true end
    end
    return e
end

--- Replace the ref-edges INTO `to` with a PROVEN caller set — the clangd
--- demand oracle resolving one function's callers. Drops the name-matched (~)
--- ref edges into `to` (preserving cross-language xlang refs), adds the proven
--- ones, and keeps usedby/uses/occ consistent (self-edges excluded from
--- usedby, as at ingest). callers = { {from=id, at=ranges}, ... }.
function M.set_callers(to, callers)
    if M.data.partial then return end -- streaming append owns the arrays
    local keep, survivors = {}, {}
    for _, e in ipairs(M.data.edges) do
        if e.kind == 'ref' and e.to == to and not e.xlang then
            local u = M.uses[e.from]
            if u then for i = #u, 1, -1 do if u[i] == to then table.remove(u, i) end end end
            M.occ[e.from .. '\31' .. to] = nil
            M.edge_inferred[e.from .. '\31' .. to] = nil -- the ~ dies with the edge
        else
            keep[#keep + 1] = e
            if e.kind == 'ref' and e.to == to and e.from ~= to then
                survivors[#survivors + 1] = e.from -- an xlang caller, kept
            end
        end
    end
    M.data.edges = keep
    M.usedby[to] = survivors
    for _, c in ipairs(callers) do
        M.data.edges[#M.data.edges + 1] = { from = c.from, to = to, kind = 'ref',
            proven = true, at = c.at, self = (c.from == to) or nil }
        if c.from ~= to then
            M.uses[c.from] = M.uses[c.from] or {}
            table.insert(M.uses[c.from], to)
            table.insert(M.usedby[to], c.from)
        end
        M.occ[c.from .. '\31' .. to] = c.at -- raw, exactly as idx_edge derives it
    end
end

--- Register a node created after ingest (frontier landings). Refuses (nil)
--- while a streaming extraction is appending (see add_edge).
function M.add_node(n)
    if M.data.partial then return nil end
    if M.by_id[n.id] then return n end
    table.insert(M.data.nodes, n)
    M.by_id[n.id] = n
    if n.name then
        M.by_name[n.name] = M.by_name[n.name] or {}
        table.insert(M.by_name[n.name], n.id)
    end
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
    -- the working set remembers the member you were last at, so
    -- returning from a dive lands where you left off
    if id and M.workset and M.workset.ids[id] then M.workset.last = id end
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
-- redraw channel: "the graph changed under the current view, re-render it"
-- (a background oracle splicing edges into the focused node, say). Panes
-- subscribe and re-render their CURRENT view; no focus change, no re-ingest.
M._redraw_subs = {}
--- Subscribe to redraws (fired on every navigation/re-render). Returns an
--- unsubscribe function, like M.facts — a live projection detaches with it.
function M.on_redraw(fn)
    table.insert(M._redraw_subs, fn)
    return function ()
        for i, f in ipairs(M._redraw_subs) do
            if f == fn then table.remove(M._redraw_subs, i); return end
        end
    end
end
function M.redraw()
    for _, fn in ipairs(M._redraw_subs) do pcall(fn) end
end

-- ── reachability cone (mark-a-node, follow-the-glow navigation) ─────────────
-- One transient anchored cone at a time: { id, dir }. dir 'in' = ancestors
-- (who reaches it — "the path toward it"), 'out' = descendants (what it
-- reaches — its blast radius). Toggling the same id+dir clears it; a new
-- anchor re-cones. Cleared on re-ingest (ids churn). NOT the working set —
-- that's a persistent bag; this is a throwaway highlight over the graph.
M.cone = nil

--- Toggle the cone on `id` in `dir` ('in'|'out'). Pure state — the caller
--- repaints (the glow is eol dots, not a re-render). Returns the reachable
--- count (0 when toggled off), so the caller can report it.
function M.set_cone(id, dir)
    if not (id and M.by_id[id]) then return 0 end
    if M.cone and M.cone.id == id and M.cone.dir == dir then
        M.cone, M._cone_set, M._cone_files = nil, nil, nil
        return 0
    end
    M.cone = { id = id, dir = dir }
    local adj = dir == 'in' and M.usedby or M.uses
    M._cone_set = require('cartograph.cone').reachable(id, adj)
    M._cone_files = nil -- lazily derived
    local n = 0; for _ in pairs(M._cone_set) do n = n + 1 end
    return n
end

--- Is `id` inside the active cone (excludes the anchor itself)?
function M.in_cone(id) return M._cone_set ~= nil and M._cone_set[id] == true end

-- ── node marks (vim-mark idiom, keyed by node not line) ────────────────────
M.marks = {}
--- Remember `id` under mark `ch` (m{a-z}).
function M.set_mark(ch, id) M.marks[ch] = id end
--- The node id marked `ch`, if it still exists (`{a-z} jumps to it).
function M.get_mark(ch)
    local id = M.marks[ch]
    return (id and M.by_id[id]) and id or nil
end

-- ── territorial decomposition (which entry points reach each node) ──────────
M._territory = nil

--- The territory partition, computed on demand and cached (cleared on
--- re-ingest). Roots = declared entry points (n.entry) if any exist, else the
--- call graph's APPARENT sources (function nodes with no callers) — tagged via
--- `.declared`. nil until a graph is open.
function M.territory()
    if M._territory then return M._territory end
    if not M.data then return nil end
    local roots, declared = {}, false
    for _, n in ipairs(M.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.entry then
            roots[#roots + 1] = n.id; declared = true
        end
    end
    if #roots == 0 then -- fall back to apparent sources (no callers)
        for _, n in ipairs(M.data.nodes) do
            if (n.kind == 'function' or n.kind == 'method')
                and not (M.usedby[n.id] and #M.usedby[n.id] > 0) then
                roots[#roots + 1] = n.id
            end
        end
    end
    local t = require('cartograph.territory').compute(roots, M.uses, M.usedby)
    t.declared = declared
    M._territory = t
    return t
end

--- Per-file territory class (union of the file's nodes' entry-sets), for the
--- files-level overlay. file -> { class, entry?, n }.
function M.territory_files()
    local t = M.territory(); if not t then return nil end
    if t._files then return t._files end
    local acc = {}
    for _, node in ipairs(M.data.nodes) do
        local info = t.node[node.id]
        if info and node.file then
            local s = acc[node.file]; if not s then s = {}; acc[node.file] = s end
            for e in pairs(info.entries) do s[e] = true end
        end
    end
    local files = {}
    for file, set in pairs(acc) do
        local n, only = 0, nil
        for e in pairs(set) do n = n + 1; only = e end
        files[file] = { class = (n == 1 and 'territory') or (n == t.k and 'core') or 'commons',
            entry = n == 1 and only or nil, n = n }
    end
    t._files = files
    return files
end

--- Files containing at least one cone member (for the files-level glow),
--- derived once per cone and cached.
function M.cone_files()
    if not M._cone_set then return nil end
    if not M._cone_files then
        local f = {}
        for id in pairs(M._cone_set) do
            local n = M.by_id[id]
            if n and n.file then f[n.file] = true end
        end
        M._cone_files = f
    end
    return M._cone_files
end

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
--- Subscribe to context (hover) changes. Returns an unsubscribe function,
--- like M.on_redraw / M.facts — a live projection follows the cursor with it.
function M.on_context(fn)
    table.insert(M._ctx_subs, fn)
    return function ()
        for i, f in ipairs(M._ctx_subs) do
            if f == fn then table.remove(M._ctx_subs, i); return end
        end
    end
end
---@param ctx {node:string, ranges:table?}?
function M.set_context(ctx)
    M.context = ctx
    for _, fn in ipairs(M._ctx_subs) do pcall(fn, ctx) end
end

--- Occurrences of `to_id` inside `from_id` (the uses-edge call sites).
function M.occurrences(from_id, to_id)
    return M.occ[(from_id or '') .. '\31' .. (to_id or '')]
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

--- The staged TRANSACTION (clone-merge etc.): at most one, freezes
--- refresh and graph swaps like the move-set does. nil clears.
M.txn = nil
function M.set_txn(plan)
    M.txn = plan
    fire_plan()
end

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
--- Resolve a graph file key to a real path. A multi-root corpus (self://
--- loaded) carries a `roots` map: the key's first segment is a plugin
--- label (telescope.nvim/lua/…) that names the real directory. A plain
--- single-root graph just joins the key onto the root.
function M.abs(file) return M.abs_in(M.data, file) end

--- Same resolution against an explicit graph (load-time stamping runs before
--- the graph becomes M.data).
function M.abs_in(data, file)
    local roots = data and data.roots
    if roots then
        local label, rest = file:match('^([^/]+)/(.*)$')
        local base = label and roots[label]
        if base then return base .. '/' .. rest end
    end
    return data.root .. '/' .. file
end

function M.abspath(node) return M.abs(node.file) end

--- A node's file content, as lines — the ONE seam every DISPLAY read goes
--- through, so content acquisition is a single point a transport can later plug
--- into (disk now; a fetch/stream over the wire eventually). This is the
--- synchronous, pull-once case of the planned store.facts observable: it
--- resolves NOW when the bytes are local. Cached by mtime+size (re-reads free;
--- a save re-reads via the changed stamp), nil when unreadable.
function M.content(node)
    if not (node and node.file) then return nil end
    local file = node.file
    local path = M.abs(file)
    local st = vim.uv.fs_stat(path)
    local stamp = st and ('%d:%d:%d'):format(st.mtime.sec, st.mtime.nsec, st.size) or 'gone'
    local e = M._content_cache[file]
    if e and e.stamp == stamp then return e.lines or nil end
    local lines = false
    if st then local ok, r = pcall(vim.fn.readfile, path); lines = ok and r or false end
    M._content_cache[file] = { stamp = stamp, lines = lines }
    return lines or nil
end

-- content-type of a file, for the (future) surface router — text goes to an
-- nvim buffer, markdown/html/… to a browser, etc.
local CTYPE = {
    lua = 'text/x-lua', c = 'text/x-c', h = 'text/x-c', cpp = 'text/x-c++',
    hpp = 'text/x-c++', cc = 'text/x-c++', py = 'text/x-python',
    js = 'text/javascript', ts = 'text/typescript', rb = 'text/x-ruby',
    php = 'text/x-php', hs = 'text/x-haskell', scm = 'text/x-scheme',
    go = 'text/x-go', rs = 'text/x-rust', java = 'text/x-java',
    md = 'text/markdown', html = 'text/html', json = 'application/json',
}
local function content_type(file)
    local ext = file and file:match('%.([%w]+)$')
    return (ext and CTYPE[ext:lower()]) or 'text/plain'
end

-- ── the facts observable ─────────────────────────────────────────────────────
-- store.facts(node, on_fact) is the ONE seam a context surface subscribes to.
-- A FACT is { kind, ctype?, data, state, provenance } where state ∈ present |
-- pending | failed | stale. Producers emit facts about a node — content now,
-- later live value / callers / runtime / etc. — SYNCHRONOUSLY when the answer is
-- local (the pull-once-synchronous case) or later on the main loop when a
-- transport has to fetch. pull-once = a producer that emits then stops; push =
-- one that keeps emitting; cancellation = unsubscribe. One primitive, all cases.
M._fact_producers = {}

--- Register a fact producer: { kind, produce = fn(node, emit) -> cancel? }.
--- `produce` calls emit(fact) zero or more times and may return a cancel fn.
function M.register_fact(p) M._fact_producers[#M._fact_producers + 1] = p end

--- Observe a node's facts. on_fact(fact) fires per fact as it arrives/updates
--- (inline for synchronous producers; later on the main loop for async ones).
--- Returns an unsubscribe fn (idempotent) — which IS cancellation: after it, no
--- producer can emit (a late async emit is dropped), so navigate-away cancels
--- in-flight work for free.
function M.facts(node, on_fact)
    if not (node and on_fact) then return function () end end
    local cancels, dead = {}, false
    local function emit(fact) if not dead then on_fact(fact) end end
    for _, p in ipairs(M._fact_producers) do
        local ok, cancel = pcall(p.produce, node, emit)
        if ok and type(cancel) == 'function' then cancels[#cancels + 1] = cancel end
    end
    return function ()
        if dead then return end
        dead = true
        for _, c in ipairs(cancels) do pcall(c) end
    end
end

-- the content producer: synchronous, disk-backed — the pull-once-sync case
M.register_fact {
    kind = 'content',
    produce = function (node, emit)
        if not (node and node.file) then return end
        local lines = M.content(node)
        emit {
            kind = 'content',
            ctype = content_type(node.file),
            state = lines and 'present' or 'failed',
            data = lines or nil,
            provenance = { source = (M.data and M.data.provider) or 'disk',
                fresh = true },
        }
    end,
}

--- Files whose identifier mention-index contains `name` (the id pass
--- records each file's identifier set). Empty when the graph predates
--- the index or the file's language opted out (spec.name_index = false).
function M.mentioning(name)
    local out = {}
    local needle = '\31' .. name .. '\31'
    for f, s in pairs((M.data and M.data.names) or {}) do
        if s:find(needle, 1, true) then out[#out + 1] = f end
    end
    table.sort(out)
    return out
end

--- Has a parsed file changed on disk since its graph was made?
--- true/false when a stamp exists; nil = unknown (no stamp — MCP graphs,
--- frontier files, which validate through their own machinery).
function M.stale(file)
    local s = M.data and M.data.stamps and M.data.stamps[file]
    if not s then return nil end
    -- non-filesystem substrates (mcp://…) validate through their own
    -- transport at open time; a stat against their keys means nothing
    if (M.data.root or ''):match('^%w+://') then return nil end
    local st = vim.uv.fs_stat(M.abs(file))
    local now = st and ('%d:%d:%d'):format(st.mtime.sec, st.mtime.nsec, st.size)
        or 'gone'
    return now ~= s
end

return M
