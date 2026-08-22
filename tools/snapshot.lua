-- Snapshot: save/load an extract's data table so a 55s extract is paid once
-- per version, then diffed repeatedly (graphdiff) and censused for free.
-- SLIM profile: keeps exactly what the instruments read (graphdiff: node ids,
-- edge endpoints/kind/trust attrs, call sites/outcomes; census: kinds, tiers,
-- refusal rules, unparsed) and drops the fat (argv/args, ranges, df) — a
-- server snapshot lands in tens of MB, not hundreds. The invariant the spec
-- pins: graphdiff(data, load(save(data))) is EMPTY — a snapshot is faithful
-- for the instruments, by construction.
-- mpack on disk, tmp+rename write (a torn snapshot is a loud load error, not
-- a silently wrong baseline).
--
-- Use from a headless driver (the CLI wrappers are tools/gate.lua and matrix):
--   local snap = dofile('tools/snapshot.lua')
--   snap.save(name, data, { corpus = name, rev = rev })  -- writes the SLIM baseline
--   local base, meta = snap.load(name)                    -- nil if none saved yet
--   -- diff a fresh extract against the baseline (both slim):
--   local delta = require('cartograph.graphdiff').diff(base, snap.slim(data))
--   -- snap.slim(data) alone yields the instrument-faithful projection

local M = {}

M.dir = vim.fn.expand('~/.cache/cartograph-tools')

local REPO = (function ()
    local src = debug.getinfo(1, 'S').source:sub(2)
    return src:match('^(.*)/tools/snapshot%.lua$') or vim.fn.getcwd()
end)()

--- The slim projection of a data table (pure; input untouched).
function M.slim(data)
    local nodes, edges, calls = {}, {}, {}
    for i, n in ipairs(data.nodes or {}) do
        nodes[i] = { id = n.id, name = n.name, kind = n.kind, file = n.file,
            unparsed = n.unparsed or nil }
    end
    for i, e in ipairs(data.edges or {}) do
        edges[i] = { from = e.from, to = e.to, kind = e.kind,
            inferred = e.inferred or nil, proven = e.proven or nil,
            xlang = e.xlang or nil, sideeffect = e.sideeffect or nil,
            -- IMPORT KIND (CART-0510). Carried because the faithfulness
            -- invariant demands it: a field no gate can see is a field whose
            -- regression is invisible — the instrument lesson from the scope
            -- model's step 2, where hedges were absent from slim and the gate
            -- read vacuously identical.
            -- ★ NO `or nil` HERE, unlike every field above. Those are two-state,
            -- so collapsing false to absent loses nothing. `once` is TRI-STATE:
            -- false means "asked, and it re-executes" and nil means "this
            -- language's syntax does not discriminate". `e.once or nil` would
            -- erase the positive answer and make the two indistinguishable.
            once = e.once, soft = e.soft, site = e.site }
    end
    for i, c in ipairs(data.calls or {}) do
        calls[i] = { file = c.file, line = c.line, callee = c.callee,
            full = c.full, fn = c.fn, to = c.to, dynamic = c.dynamic or nil,
            hedge = c.hedge and { rule = c.hedge.rule } or nil,
            refused = c.refused and { rule = c.refused.rule, n = c.refused.n } or nil,
            -- the call disposition ([[cartograph-graph-improvements]] #1) so
            -- the D-census / specaudit gap query reads it off the snapshot
            ext = c.ext and { disp = c.ext.disp, why = c.ext.why } or nil }
    end
    return { schema = data.schema, root = data.root, provider = data.provider,
        nodes = nodes, edges = edges, calls = calls }
end

local function path_for(name)
    return M.dir .. '/' .. name .. '.snapshot.mpack'
end

--- Save a slim snapshot under a name. Records the repo rev so a later diff
--- can say WHICH version the baseline came from. Returns the path.
function M.save(name, data, meta)
    vim.fn.mkdir(M.dir, 'p')
    local rev = vim.fn.systemlist({ 'git', '-C', REPO,
        'rev-parse', '--short', 'HEAD' })[1]
    local blob = vim.mpack.encode({
        version = 1,
        meta = vim.tbl_extend('force', { rev = rev, when = os.date('!%Y-%m-%dT%H:%M:%SZ') },
            meta or {}),
        data = M.slim(data),
    })
    local path = path_for(name)
    local tmp = path .. '.tmp.' .. vim.fn.getpid()
    local fd = assert(io.open(tmp, 'wb'), 'snapshot: cannot write ' .. tmp)
    fd:write(blob)
    fd:close()
    assert(os.rename(tmp, path), 'snapshot: rename failed for ' .. path)
    return path
end

--- Load a snapshot: returns data, meta — or nil, why (missing/corrupt = a
--- clean miss, never a half-trusted baseline).
function M.load(name)
    local fd = io.open(path_for(name), 'rb')
    if not fd then return nil, 'no snapshot: ' .. path_for(name) end
    local blob = fd:read('a'); fd:close()
    local ok, t = pcall(vim.mpack.decode, blob)
    if not ok or type(t) ~= 'table' or t.version ~= 1 or type(t.data) ~= 'table' then
        return nil, 'corrupt/unknown snapshot: ' .. path_for(name)
    end
    return t.data, t.meta
end

return M
