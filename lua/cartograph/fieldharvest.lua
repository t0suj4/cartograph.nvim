-- fieldharvest.lua — the DISAGREEMENT HARVEST over the field linker
-- ([[cartograph-goal-vm-linker]] the success bar, operationalized). Cartograph's
-- fieldlink resolves a `self.field` READ to its `self.field = …` WRITE(s) on the
-- receiver-typed class. lua-ls answers `textDocument/definition` on the same read.
-- Where BOTH resolve, comparing them turns lua-ls from a one-way corrective oracle
-- into a PEER: they either AGREE (confidence) or CONFLICT — and a conflict is a real
-- bug on ONE side (ours or theirs), the product. Runs on the shared oracle substrate
-- (async, deadline-capped). Absence is never a conflict: lua-ls silent = not-answered.

local oracle = require 'cartograph.oracle'
local fieldlink = require 'cartograph.fieldlink'

local M = {}

local function find_bin()
    local cands = { 'lua-language-server',
        vim.fn.expand('~/.local/bin/lua-language-server'),
        vim.fn.expand('~/.local/lib/lua-language-server/bin/lua-language-server') }
    local ok, cfg = pcall(function () return require('cartograph.config').luals_bin end)
    if ok and cfg then table.insert(cands, 1, cfg) end
    for _, c in ipairs(cands) do
        if c and vim.fn.executable(c) == 1 then return c end
    end
end

-- every field resolution as an oracle work-item: the read POSITION (0-based row/col
-- of the field name) + the set of cartograph's write sites as "file\31line" keys.
local function collect(store)
    local items = {}
    for _, n in ipairs(store.data.nodes or {}) do
        if (n.kind == 'method' or n.kind == 'function') and n.file and n.file:match('%.lua$')
            and n.name and n.name:match(':') then
            local ok, r = pcall(fieldlink.fields, store, n.id)
            if ok and r and r.reads then
                for _, rd in ipairs(r.reads) do
                    if rd.row and rd.col then
                        local w = {}
                        for _, d in ipairs(rd.defs) do w[(d.file or n.file) .. '\31' .. d.line] = true end
                        items[#items + 1] = { file = n.file, row = rd.row, col = rd.col,
                            field = rd.field, line = rd.line, writes = w }
                    end
                end
            end
        end
    end
    return items
end

-- lua-ls definition result → { file (relative to root), line (1-based) } of the first
-- target, else nil. Handles LocationLink (targetSelectionRange/targetUri) + Location.
local function def_of(result, root)
    local loc = result and result[1]
    if not loc then return nil end
    local uri = loc.targetUri or loc.uri
    local rng = loc.targetSelectionRange or loc.targetRange or loc.range
    if not (uri and rng) then return nil end
    local path = vim.uri_to_fname(uri)
    local rel = path:sub(#root + 2) -- strip "root/"
    return { file = rel, line = rng.start.line + 1 }
end

--- Harvest field-resolution disagreements against lua-ls. Calls on_done(stats, why)
--- where stats = { total, agree, conflict, silent, conflicts = {{file,line,field,ls,ours}} }.
--- agree = lua-ls def ∈ our write set; conflict = lua-ls resolved elsewhere (the bug
--- product); silent = lua-ls didn't answer (never a conflict — absence isn't refutation).
function M.harvest(store, opts, on_done)
    opts = opts or {}
    local bin = opts.bin or find_bin()
    if not bin then
        return on_done and on_done(nil, 'no lua-language-server binary (config.luals_bin / PATH)')
    end
    local data = store.data
    local root = data.root
    local items = collect(store)
    if #items == 0 then return on_done and on_done(nil, 'no field resolutions to harvest') end
    local files, seen = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.file and n.file:match('%.lua$') and not seen[n.file] then
            seen[n.file] = true; files[#files + 1] = n.file
        end
    end
    local stats = { total = #items, agree = 0, conflict = 0, silent = 0, conflicts = {} }
    oracle.run({
        name = 'cartograph-fieldharvest', cmd = { bin }, root = root,
        settings = { Lua = { diagnostics = { enable = false }, telemetry = { enable = false } } },
        files = files, lang_id = function () return 'lua' end,
        items = items, concurrency = opts.concurrency or 32,
        deadline = opts.deadline, -- big corpora need > the 90s default (indexing + N queries)
        query = function (ses, it, step)
            local stepped = false
            local function done1() if not stepped then stepped = true; step() end end
            local ok = ses.client:request('textDocument/definition', {
                textDocument = { uri = vim.uri_from_fname(root .. '/' .. it.file) },
                position = { line = it.row, character = it.col },
            }, function (_, result)
                local d = def_of(result, root)
                if not d then stats.silent = stats.silent + 1
                elseif it.writes[d.file .. '\31' .. d.line] then stats.agree = stats.agree + 1
                else
                    stats.conflict = stats.conflict + 1
                    if #stats.conflicts < 60 then
                        local ours = {}
                        for k in pairs(it.writes) do ours[#ours + 1] = k:gsub('\31', ':') end
                        table.sort(ours)
                        stats.conflicts[#stats.conflicts + 1] = { file = it.file, line = it.line,
                            field = it.field, ls = d.file .. ':' .. d.line, ours = ours }
                    end
                end
                done1()
            end)
            if not ok then stats.silent = stats.silent + 1; done1() end
        end,
    }, function (_, why) if on_done then on_done(stats, why) end end)
end

--- Render the harvest stats as report lines. The agreement RATE is the north-star
--- metric (how often we're precise enough that a disagreement is signal); the
--- conflicts are the triage work-list — each a bug on our side or lua-ls's.
function M.report(stats, why)
    if not stats then return { 'field-harvest: ' .. (why or 'no result') } end
    local answered = stats.agree + stats.conflict
    -- items the deadline force-finished before a response are neither agree/conflict
    -- nor an explicit nil-answer — report them so a partial run is never read as clean
    local unanswered = stats.total - answered - stats.silent
    local L = {
        ('field-harvest: %d field resolution(s) — %d agree, %d CONFLICT, %d silent, %d unanswered (deadline)')
            :format(stats.total, stats.agree, stats.conflict, stats.silent, unanswered),
        answered > 0 and ('agreement rate (of answered): %.1f%%  — a conflict = a bug on ONE side')
            :format(100 * stats.agree / answered) or 'lua-ls answered nothing',
        '',
    }
    for _, c in ipairs(stats.conflicts or {}) do
        L[#L + 1] = ('  %s:%d self.%s   ours=[%s]   lua-ls=%s')
            :format(c.file, c.line, c.field, table.concat(c.ours, ', '), c.ls)
    end
    if stats.conflict > #(stats.conflicts or {}) then
        L[#L + 1] = ('  … +%d more conflict(s)'):format(stats.conflict - #stats.conflicts)
    end
    return L
end

return M
