-- MENTIONS — the name-level evidence surface, and the first consumer of the
-- mention postings ([[cartograph-merging-strategies]] index-and-reduce steps 1-3).
--
-- WHY THIS EXISTS: "where is this name used" is only answerable through the call
-- graph today, so every form of it refuses when resolution refused — and a refused
-- call still tells you the name occurs. The postings answer the weaker question
-- truthfully, provided the answer never dresses up as references.
--
-- WHERE IT DOES NOT WORK, stated because the first version of this file claimed
-- the opposite: the THIN INDEX has no mention index. index_only sets defs_only,
-- which skips the collect pass that records each file's identifier set (measured:
-- 0 files indexed vs a full extract's 20 on the same tree). So this verb REFUSES
-- there — it does not report zero mentions, which would be the same fabricated
-- negative that lsp.lua declines referencesProvider to avoid. Making the thin index
-- carry the mention index is a real option, and a measurement, not an assumption:
-- the collect pass is a chunk of what index_only exists to skip.
--
-- So the contract is stated in the output, not just here:
--   · a mention is an IDENTIFIER OCCURRENCE. It is not a resolved reference, and
--     nothing here claims the name refers to the same thing in two files.
--   · files are what is reported, never sites — the index is per (file, name) by
--     construction (the id pass interns each name into a per-file pool), so a
--     per-line answer is not available at this altitude and is not invented.
--   · when the graph HAS calls, the resolved subset is shown as a subset, so the
--     residual — mentions the name, resolves to nothing by it — is visible rather
--     than hidden. That residual is the honest shape of name-level evidence.
--
-- SCOPE CONFINEMENT: relative to the asking file, because that is what resolution
-- does (a candidate in a different scope is dropped by the id pass). Confining
-- here shows the candidate set a resolver would actually consider, not every file
-- that happens to share a spelling.

local M = {}

local callrec = require 'cartograph.callrec'

--- Files mentioning `name`, plus what the graph can say about them.
---@param store table
---@param name string
---@param from string|nil  the asking file (scope confinement); nil = corpus-wide
---@return table  { files, confined, scope, defs, resolved, has_calls, indexed }
function M.evidence(store, name, from)
    local px = store.postings()
    local scopes = store.scopes()
    local confined = from ~= nil and scopes ~= nil
    local files = confined and store.mentioning_in(name, from)
        or store.mentioning(name)

    -- which defs bear this name at all: the reason name-level evidence is weak
    -- when there are several, and the reason it is strong when there is one
    local defs = {}
    for _, id in ipairs((store.by_name or {})[name] or {}) do
        local n = store.by_id and store.by_id[id]
        if n then defs[#defs + 1] = { id = id, kind = n.kind, file = n.file } end
    end

    -- the RESOLVED subset: files holding a call by this name that resolved to a
    -- def. Requires the call graph; absent on the thin index, and its absence is
    -- reported rather than shown as zero.
    local has_calls = not (store.is_index_only and store.is_index_only())
    local resolved = {}
    if has_calls then
        local inset = {}
        for _, f in ipairs(files) do inset[f] = true end
        for _, c in ipairs((store.data or {}).calls or {}) do
            local f = callrec.file and callrec.file(c) or c.file
            if f and inset[f] and c.to then
                local tail = callrec.callee and callrec.callee(c) or c.callee
                local full = callrec.full and callrec.full(c) or c.full
                if tail == name or full == name then resolved[f] = true end
            end
        end
    end

    return { files = files, confined = confined,
        scope = confined and (scopes or {})[from] or nil,
        defs = defs, resolved = resolved, has_calls = has_calls,
        indexed = px.n_files }
end

--- The scratch report.
function M.report(store, name, from)
    if not name or name == '' then
        return { 'cartograph: :CartographMentions <name> — no name given' }
    end
    -- REFUSE, never report zero: no index and no mentions are opposite claims
    if not store.has_mention_index() then
        return {
            ("mentions: '%s' — REFUSED, this graph has no mention index"):format(name),
            '',
            'The identifier set per file is recorded by the id pass. It is absent when',
            'the graph is the THIN INDEX (index_only skips the collect pass that builds',
            'it), when the graph predates the cache field, or when every parsed language',
            'opted out (spec.name_index = false).',
            '',
            (store.is_index_only and store.is_index_only())
                and '  This graph IS the thin index. A full :Cartograph open supplies it.'
                or '  No indexed file carries an identifier set.',
            '',
            'Reporting "0 files mention it" here would be a fabricated negative — the',
            'answer is UNKNOWN, not none.',
        }
    end
    local e = M.evidence(store, name, from)
    local out = {}
    local function add(s) out[#out + 1] = s end

    add(("mentions: '%s' — %d file%s"):format(name, #e.files,
        #e.files == 1 and '' or 's'))
    if e.confined then
        add(('  scope-confined to %s (the asking file %s)')
            :format(e.scope == '' and '<the single scope>'
                or ("'%s'"):format(tostring(e.scope)), from))
    elseif from then
        add('  NOT scope-confined: no parsed language here has a resolution boundary')
    else
        add('  NOT scope-confined: no asking file (corpus-wide)')
    end
    add(('  over %d indexed files'):format(e.indexed))
    add('')

    -- what a mention IS, said before the list rather than after it
    add('A MENTION IS AN IDENTIFIER OCCURRENCE, not a resolved reference: nothing')
    add('below claims these name the same thing. Per-FILE by construction — the')
    add('index interns each name once per file, so there is no per-line answer here.')
    add('')

    if #e.defs == 0 then
        add('DEFS bearing this name: none in the graph — so every mention below is')
        add('  either external, or a name this project never defines.')
    else
        add(('DEFS bearing this name: %d'):format(#e.defs))
        for _, d in ipairs(e.defs) do
            add(('  %-9s %s'):format(d.kind or '?', d.file or '?'))
        end
        if #e.defs > 1 then
            add(('  %d defs share the spelling, so a mention does not pick one out.')
                :format(#e.defs))
        end
    end
    add('')

    if not e.has_calls then
        add('RESOLVED SUBSET: unavailable — this is the thin index, which carries no')
        add('  call graph. Not "none": unknown. A full :Cartograph open supplies it.')
    else
        local nres = 0
        for _ in pairs(e.resolved) do nres = nres + 1 end
        add(('RESOLVED SUBSET: %d of %d files hold a call by this name that resolved')
            :format(nres, #e.files))
        if nres < #e.files then
            add(('  the other %d mention the name without a resolved call by it —')
                :format(#e.files - nres))
            add('  a variable, a comment-adjacent identifier, or a refused call.')
        end
    end
    add('')

    if #e.files == 0 then
        add('(no indexed file mentions it)')
        return out
    end
    add('FILES')
    for _, f in ipairs(e.files) do
        add(('  %s %s'):format(e.resolved[f] and '=' or (e.has_calls and '~' or '?'), f))
    end
    add('')
    add(e.has_calls and '  = resolved call by this name · ~ mention only'
        or '  ? mention only (no call graph to check against)')
    return out
end

return M
