-- Move-apply: the founding verb finally writes. The staged move-set
-- (dd cuts, p sets the destination) becomes a transaction: each
-- symbol's text leaves its file and lands in the destination —
-- journal-first, behind the same refusal ladder as clone-merge.
--
-- What this verb deliberately does NOT write: call-site
-- requalification and import wiring. Both are language-specific
-- guesses (which alias names the dest module here? what does an import
-- line look like?), and a transaction that guesses is a transaction
-- that lies. The ImpactEngine's findings — call sites naming the old
-- home, imports each side should gain — ride the plan as HAZARDS with
-- counts and file names: the human finishes what the tool can prove
-- but not spell.

local M = {}

-- where inserted code lands in dest: before a trailing `return M`-ish
-- line (the lua module idiom), else after the last nonblank line.
-- Returns a 0-based insert-before line index.
local function insert_point(lines)
    local last
    for i = #lines, 1, -1 do
        if lines[i]:match('%S') then last = i break end
    end
    if not last then return 0 end
    if lines[last]:match('^%s*return%s+[%w_%.]+%s*$') then
        return last - 1 -- 0-based index OF the return line
    end
    return last -- 0-based slot just after the last nonblank
end

-- the shared plan core: collect the staged symbols (kind gate, comment
-- adhesion, cbarg disclosure), fold in the ImpactEngine's findings as
-- disclosure hazards, stamp the touched set. Both verbs (move,
-- extract-module) build on it.
local function collect(store, ids, dest, plan)
    local txn = require 'cartograph.txn'
    local root = store.data.root
    local okp, ts = pcall(require, 'cartograph.providers.treesitter')
    local lines_cache = {}
    local function file_lines(rel)
        if lines_cache[rel] == nil then
            local t = txn.read_file(root, rel)
            lines_cache[rel] = t and vim.split(t, '\n', { plain = true }) or false
        end
        return lines_cache[rel]
    end
    local touched = { [dest] = true }
    for _, id in ipairs(ids) do
        local n = store.node(id)
        if not n then return nil, 'staged symbol vanished: ' .. tostring(id) end
        if n.kind ~= 'function' and n.kind ~= 'method' then
            return nil, ('%s is a %s — only functions and methods move')
                :format(n.name, n.kind)
        end
        if n.file == dest then
            return nil, n.name .. ' already lives in ' .. dest
        end
        -- comment adhesion: the doc lines directly above travel too —
        -- unless the block touches the top of the file (a license /
        -- file header belongs to the FILE; disclosed, left behind)
        local s, header = n.range.start.line, false
        local ls = file_lines(n.file)
        if ls then
            s, header = txn.attach_above(ls, s,
                okp and ts.attach_pats(n.file) or {})
        end
        plan.moves[#plan.moves + 1] = { id = id, name = n.name, file = n.file,
            lines = { s = s, e = n.range['end'].line },
            ref = store.ref_of(id) }
        touched[n.file] = true
        if header then
            plan.hazards[#plan.hazards + 1] = ('the comment block above %s'
                .. ' touches the top of %s (file header) — left behind')
                :format(n.name, n.file)
        end
        if n.cbarg then
            plan.hazards[#plan.hazards + 1] = ('%s is referenced from data'
                .. ' (dispatch table / registry) — those references are NOT'
                .. ' rewritten'):format(n.name)
        end
    end
    -- the ImpactEngine's analysis: WRITE what is provably complete,
    -- disclose the rest. A caller site rewrites only when its token is
    -- exactly <srcAlias>.<name> (the alias its import BINDS) and a dest
    -- alias exists or a new import line can introduce one — the pair is
    -- written together or not at all. Bare names, exotic forms and
    -- shadowed aliases stay hazards; the moved code's own body is never
    -- rewritten (dest_requires stays spoken).
    local imp = require('cartograph.impact').compute(store, ids, dest)
    for _, h in ipairs(imp.hazards) do
        if h.kind ~= 'noop' then
            plan.hazards[#plan.hazards + 1] = h.kind .. ': ' .. h.msg
        end
    end
    plan.rewrites, plan.imports_add = {}, {}
    local in_move = {}
    for _, id in ipairs(ids) do in_move[id] = true end
    local binds = {} -- file -> { target file -> local alias }
    for _, e in ipairs(store.data.edges or {}) do
        if e.kind == 'import' and e.bind then
            binds[e.from] = binds[e.from] or {}
            binds[e.from][e.to] = e.bind
        end
    end
    local function import_at(ls, pats)
        local last = -1
        for i, l in ipairs(ls) do
            for _, p in ipairs(pats or {}) do
                if l:match(p) then last = i - 1 break end
            end
        end
        return last
    end
    local imports, rw_left = {}, {} -- per-file: planned import / leftovers
    for _, m in ipairs(plan.moves) do
        local tailname = m.name:match('([%w_]+)$')
        for _, c in ipairs(store.calls_to[m.id] or {}) do
            local F = c.file
            if F ~= dest and not (c.fn and in_move[c.fn]) then
                local ls = file_lines(F)
                local at = c.at
                local token = at and ls and at.start.line == at['end'].line
                    and (ls[at.start.line + 1] or '')
                        :sub(at.start.char + 1, at['end'].char)
                local srcAlias = binds[F] and binds[F][m.file]
                local ok_site = srcAlias and token
                    and token == (srcAlias .. '.' .. tailname)
                local destAlias = ok_site and binds[F] and binds[F][dest]
                if ok_site and not destAlias then
                    local imp2 = imports[F]
                    if imp2 == nil and okp and ls then
                        local line, alias = ts.import_line(F, dest)
                        -- decline an alias the file already uses
                        if line and alias and not table.concat(ls, '\n')
                            :find('%f[%w_]' .. alias .. '%f[^%w_]') then
                            imp2 = { text = line, alias = alias,
                                after = import_at(ls, ts.import_pats(F)) }
                        else
                            imp2 = false
                        end
                        imports[F] = imp2
                    end
                    destAlias = imp2 and imp2.alias or nil
                end
                if ok_site and destAlias then
                    plan.rewrites[#plan.rewrites + 1] = { file = F, at = at,
                        to = destAlias .. '.' .. tailname }
                    touched[F] = true
                else
                    rw_left[F] = (rw_left[F] or 0) + 1
                end
            end
        end
    end
    for F, imp2 in pairs(imports) do
        if imp2 then
            plan.imports_add[#plan.imports_add + 1] = { file = F,
                after = imp2.after, text = imp2.text }
            touched[F] = true
        end
    end
    table.sort(plan.imports_add, function (a, b) return a.file < b.file end)
    for _, F in ipairs((function ()
        local out = {}
        for f in pairs(rw_left) do out[#out + 1] = f end
        table.sort(out)
        return out
    end)()) do
        plan.hazards[#plan.hazards + 1] = ('%d call site(s) in %s still'
            .. ' reference the old home — requalify them yourself')
            :format(rw_left[F], F)
    end
    for _, f in ipairs(imp.requires_add) do
        if not (imports[f] and imports[f] ~= false) then
            plan.hazards[#plan.hazards + 1] = f .. ' should import ' .. dest
        end
    end
    for _, f in ipairs(imp.dest_requires) do
        plan.hazards[#plan.hazards + 1] = dest .. ' should import ' .. f
    end
    for f in pairs(touched) do
        plan.touched[#plan.touched + 1] = f
        plan.stamps[f] = txn.disk_stamp(root, f)
    end
    table.sort(plan.touched)
    return plan
end

--- Build the MOVE plan from the staged move-set + destination.
--- Everything the apply verifies rides along: refs, stamps, the
--- generation, the insertion point (pinned by the dest stamp).
function M.plan(store)
    local ids = store.staged_ids()
    if #ids == 0 then
        return nil, 'nothing staged — dd cuts a function into the move-set'
    end
    local dest = store.dest
    if not dest then
        return nil, 'no destination — p on a file row sets it'
    end
    local txn = require 'cartograph.txn'
    local dtext = txn.read_file(store.data.root, dest)
    if not dtext then return nil, 'cannot read ' .. dest end
    local plan = {
        verb = 'move', generation = store.generation, dest = dest,
        moves = {}, hazards = {}, stamps = {}, touched = {},
        dest_at = insert_point(vim.split(dtext, '\n', { plain = true })),
    }
    return collect(store, ids, dest, plan)
end

--- Build the EXTRACT-MODULE plan: the staged move-set leaves for a
--- file that does not exist yet. The destination is created from a
--- language header plus the moved text; its undo is deletion.
function M.plan_extract(store, relpath)
    local ids = store.staged_ids()
    if #ids == 0 then
        return nil, 'nothing staged — dd cuts a function into the move-set'
    end
    relpath = (relpath or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if relpath == '' then
        return nil, 'usage: :CartographExtractModule <new-file-path>'
    end
    if relpath:match('^/') or relpath:match('%.%.') then
        return nil, 'the new file must be a plain path inside the project root'
    end
    local txn = require 'cartograph.txn'
    if txn.disk_stamp(store.data.root, relpath) then
        return nil, relpath .. ' already exists — that is a MOVE (:CartographMove)'
    end
    local okp, ts = pcall(require, 'cartograph.providers.treesitter')
    if okp and not ts.lang_of(relpath) then
        return nil, ('no language spec for %s — the graph could never'
            .. ' see the new file'):format(relpath)
    end
    local plan = {
        verb = 'extract-module', generation = store.generation,
        dest = relpath, creates = { [relpath] = true }, dest_at = 0,
        header = okp and ts.file_header(relpath) or {},
        moves = {}, hazards = {}, stamps = {}, touched = {},
    }
    if okp and ts.lang_of(relpath) == 'go' then
        plan.hazards[#plan.hazards + 1] = relpath
            .. ' will need its package clause — cartograph wrote none'
    end
    return collect(store, ids, relpath, plan)
end

--- Apply: the shared ladder plus one verb-specific rung — the LIVE
--- move-set must still be exactly the plan's moves. On success the
--- move-set is consumed (cleared before the splice, which a staged
--- set would freeze).
function M.apply(store, plan)
    local ids = store.staged_ids()
    local want = {}
    for _, m in ipairs(plan.moves) do want[m.id] = true end
    local same = #ids == #plan.moves
    if same then
        for _, id in ipairs(ids) do
            if not want[id] then same = false end
        end
    end
    if not same then
        return nil, 'the move-set changed since planning — re-run :CartographMove'
    end
    local txn = require 'cartograph.txn'
    local refspecs = {}
    for _, m in ipairs(plan.moves) do
        refspecs[#refspecs + 1] = { id = m.id, name = m.name,
            ref = m.ref, what = 'move' }
    end
    local bad = txn.verify(store, plan, refspecs)
    if bad then return nil, bad end
    -- consumed: the splice after the writes must not see a frozen graph
    store.clear_stage()
    return txn.execute(store, plan, {
        moves = vim.tbl_map(function (m) return m.ref end, plan.moves),
        dest = plan.dest,
    }, M.edits_for(plan))
end

--- What :CartographApply would write, nothing written: the dry-run
--- feeding the pre-apply diff.
function M.preview(store, plan)
    local txn = require 'cartograph.txn'
    return txn.dryrun(store, plan, M.edits_for(plan))
end

--- The verb's edit callback — shared verbatim by apply and preview.
function M.edits_for(plan)
    return function (rel, before, all)
        if plan.creates and plan.creates[rel] then
            -- a NEW file: language header + the moved text, from the
            -- same before-bytes the journal holds
            local out = {}
            vim.list_extend(out, plan.header or {})
            for mi, m in ipairs(plan.moves) do
                if mi > 1 then out[#out + 1] = '' end
                local src = vim.split(all[m.file], '\n', { plain = true })
                for i = m.lines.s + 1, m.lines.e + 1 do
                    out[#out + 1] = src[i]
                end
            end
            out[#out + 1] = ''
            return table.concat(out, '\n')
        end
        local lines = vim.split(before, '\n', { plain = true })
        if rel == plan.dest then
            -- the moved blocks, lifted from each source's BEFORE content
            -- (the same bytes the journal holds)
            local ins = {}
            local at = plan.dest_at
            if at > 0 and (lines[at] or ''):match('%S') then
                ins[#ins + 1] = ''
            end
            for mi, m in ipairs(plan.moves) do
                if mi > 1 then ins[#ins + 1] = '' end
                local src = vim.split(all[m.file], '\n', { plain = true })
                for i = m.lines.s + 1, m.lines.e + 1 do
                    ins[#ins + 1] = src[i]
                end
            end
            if (lines[at + 1] or ''):match('%S') then
                ins[#ins + 1] = ''
            end
            for i = #ins, 1, -1 do
                table.insert(lines, at + 1, ins[i])
            end
        else
            -- a source/caller file: departures, requalified call
            -- sites and new import lines — one pass, bottom-up,
            -- through the shared editor
            local dels, reps, ins = {}, {}, {}
            for _, m in ipairs(plan.moves) do
                if m.file == rel then dels[#dels + 1] = m.lines end
            end
            for _, r in ipairs(plan.rewrites or {}) do
                if r.file == rel then reps[#reps + 1] = r end
            end
            for _, i in ipairs(plan.imports_add or {}) do
                if i.file == rel then
                    ins[#ins + 1] = { after = i.after, lines = { i.text } }
                end
            end
            return require('cartograph.txn').edit_file(before, dels, reps, ins)
        end
        return table.concat(lines, '\n')
    end
end

return M
