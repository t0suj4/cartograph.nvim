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

--- THE PROJECTION VERSION (CART-0531). Distinct from BOTH the blob format
--- version (`version = 1`, the on-disk envelope) and cache.VERSION (the
--- extraction epoch). It answers a third question the other two cannot: WHICH
--- SET OF FACTS did the instrument keep?
---
--- It exists because adding `nat` proved the gap the hard way. A baseline written
--- by the previous projection lacks the field, so every edge with occurrences
--- diffs as `matched => matchedx1` — 1103 phantom changes on jquery alone — and
--- the epoch note stays SILENT, because the extractor did not change. A reader
--- would see thousands of differences with no explanation and reasonably conclude
--- extractor regression. Exactly CART-0502's failure one layer up: the baseline
--- must be able to say which INSTRUMENT wrote it, not only which extractor.
--- Bump this whenever slim's field set changes, and the gate will ask for a
--- re-save instead of printing a storm.
M.SLIM_VERSION = 3 -- v3: the WRITE AXIS (rw/gw/gp/nflds) — CART-0532

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
            once = e.once, soft = e.soft, site = e.site,
            -- HOW MANY TIMES this edge was seen (CART-0531). The `at` list itself
            -- is fat and stays dropped; its LENGTH is the cheap half and the only
            -- part an instrument reads. Without it the gate could not see v145's
            -- double-counting or v146's fix — both changed occurrence counts by
            -- thousands and every corpus reported "identical".
            -- `e.at and #e.at or nil` on purpose: nil means this edge kind carries
            -- no occurrence list, 0 means it has one and it is empty. Same
            -- tri-state trap as `once` above.
            -- ★ `atn` FIRST, and it is not a nicety: the TOKENS provider caps
            -- the kept list at 8 occurrences and records the true total in
            -- e.atn (providers/tokens.lua MAX_AT). Counting #at there would
            -- report 8 for every heavily-referenced edge in gforth /
            -- openfirmware / postscript / bwipp and hide every change above the
            -- cap — the same blindness this field exists to remove, one level
            -- down.
            nat = e.atn or (e.at and #e.at) or nil,
            -- ★ THE WRITE AXIS (CART-0532). Four facts that live or die together,
            -- because all four hang off one `if wmode then` in the reduce — so a
            -- language gaining or losing `spec.is_write` moves all of them at once
            -- and the roster must be able to see it. It could not: v147 gave
            -- python `rw` on 909 use edges and moved 575 var labels from
            -- `unclassified` to `const`, and every one of the 37 gates printed
            -- "graphs are identical".
            -- COUNTS, NOT CONTENTS, for flds — the same call `nat` makes for the
            -- occurrence list. The map's WEIGHT is the reason (84456 edges carry
            -- one on wow); its cardinality still catches capture switching on or
            -- off, which is the regression that actually happens.
            -- `gp` WITHOUT `or nil`: it is TRI-STATE like `once` above. `false`
            -- means the param predicate was computed and the writes DISAGREED,
            -- which is a measured fact, and `nil` means nobody asked.
            rw = e.rw, gw = e.gw, gp = e.gp,
            nflds = e.flds and vim.tbl_count(e.flds) or nil }
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

--- THE TOOL SIDE OF A BASELINE'S IDENTITY (CART-0502). The corpus side has three
--- recorded facts and a note for each (rev / unrecordable / dirty); the tool side
--- recorded a bare `rev-parse HEAD` and nothing else, and that asymmetry is what
--- makes a stale baseline print a diff that reads as attributable.
---
--- `cache_version` is cache.VERSION -- the EXTRACTION-BEHAVIOUR epoch, the number
--- every stale-baseline post-mortem is written in ("v134 parsed a .h header as
--- C++"). A git rev cannot answer "should this baseline still be believed?": most
--- commits do not touch extraction and VERSION is exactly the ones that do.
---
--- `tool_dirty` is the missing peer of corpus_dirty, and it is SCOPED TO lua/ +
--- tools/ on purpose. An unscoped `status --porcelain` is dirty on this machine
--- permanently (agent skill files, editor droppings), and a note that always fires
--- is the cry-wolf failure gate.lua's own comments warn about. Uncommitted
--- extraction code is the case worth naming: a baseline saved from that tree
--- stamps a CLEAN rev and is thereafter indistinguishable from a real one.
local function tool_identity()
    local rev = vim.fn.systemlist({ 'git', '-C', REPO,
        'rev-parse', '--short', 'HEAD' })[1]
    local st = vim.fn.systemlist({ 'git', '-C', REPO, 'status', '--porcelain',
        '--', 'lua', 'tools' })
    local dirty = false
    for _, l in ipairs(st or {}) do if l:match('%S') then dirty = true break end end
    local okv, cache = pcall(require, 'cartograph.cache')
    return rev, dirty, okv and cache.VERSION or nil
end

--- Save a slim snapshot under a name. Records the repo rev so a later diff
--- can say WHICH version the baseline came from. Returns the path.
function M.save(name, data, meta)
    vim.fn.mkdir(M.dir, 'p')
    local rev, dirty, cver = tool_identity()
    local blob = vim.mpack.encode({
        version = 1, -- the SNAPSHOT FORMAT version; the extraction epoch is
                     -- meta.cache_version, and conflating the two is the bug
                     -- this comment exists to prevent
        meta = vim.tbl_extend('force', { rev = rev, when = os.date('!%Y-%m-%dT%H:%M:%SZ'),
            tool_dirty = dirty or nil, cache_version = cver,
            slim_version = M.SLIM_VERSION },
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

--- THE TOOL-SIDE VERDICT on a loaded baseline: can it vouch for the extraction
--- era it was written in, and for the FIELD SET it recorded? Returns (epoch,
--- dirty, projection), each a sentence or nil.
--- Computed here rather than at each printer because gate.lua and matrix.lua were
--- already two copies of the CORPUS-side reasoning, and the second copy is where
--- a rule drifts (matrix's own comment says it MIRRORS gate's three cases).
---   epoch — the baseline predates the tree's cache.VERSION, so any diff against
---           it MIXES that extraction change with the reader's own. A MISSING
---           field is UNKNOWN, not a mismatch: every baseline written before the
---           field existed lacks it, and calling that drift would flag the whole
---           roster once, loudly, for nothing.
---   dirty — the baseline was saved from a tree with uncommitted lua/tools
---           changes, so its rev names a commit that never produced it.
function M.tool_verdict(meta)
    if type(meta) ~= 'table' then return nil, nil end
    local okv, cache = pcall(require, 'cartograph.cache')
    local nowv = okv and cache.VERSION or nil
    local epoch
    if nowv and not meta.cache_version then
        epoch = ('baseline records no extraction VERSION (tree is at %d) — written'
            .. ' before the field existed; resave to make it answerable'):format(nowv)
    elseif nowv and meta.cache_version ~= nowv then
        epoch = ('baseline written at extraction VERSION %s, tree is at %d — a diff'
            .. ' against it MIXES that change with yours')
            :format(tostring(meta.cache_version), nowv)
    end
    -- THE PROJECTION CHECK COMES FIRST, and it must, because it EXPLAINS a diff
    -- the other two notes cannot: a stale projection makes every edge with
    -- occurrences look changed while the extractor is provably untouched.
    local proj
    if (meta.slim_version or 1) ~= M.SLIM_VERSION then
        proj = ('baseline was written by snapshot projection v%s and this is v%d —'
            .. ' it records a DIFFERENT SET OF FIELDS, so the diff below is mostly'
            .. ' the missing ones and not the extractor. Re-save it')
            :format(tostring(meta.slim_version or 1), M.SLIM_VERSION)
    end
    local dirty = meta.tool_dirty and ('baseline was saved from a tree with'
        .. ' UNCOMMITTED lua/tools changes — its rev names a commit that never'
        .. ' produced it') or nil
    return epoch, dirty, proj
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
