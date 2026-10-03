-- cartograph.querylog — READ QUERIES LEAVE A RECORD (F20, CART-1387). The journal records `txn_*` writes; a read verb
-- left nothing, so "replay the same queries against the new build" (the discipline that turns two samples into a real
-- before/after pair) depended on someone keeping query files by hand. OPT-IN (mcpserve --query-log): each answered call
-- of a verb that does not mutate the tree appends one JSON line next to the journal — the REQUEST (verb, args), the
-- answer's ENVELOPE (status, absence, absence_why's premise and why, tier, graph.generation, row count, refusal rule)
-- and the STAMP it was answered under (the cartograph commit, read once, and the host flags). tools/queryreplay.lua feeds
-- the requests back through a host and diffs the envelopes: replay is one command, and every record carries the
-- version stamp a bare on-disk measurement lacks.
-- ⚠ A record is the ENVELOPE, not the rows: rows are data about the user's code and can be large; the envelope is what
-- a before/after comparison of an answer's honesty needs. The request is kept whole (it is what replays).
local M = {}

--- the log file of a root: <state>/cartograph/<escaped root>.queries.jsonl (the journal's sibling)
function M.path(root)
    local dir = vim.fn.stdpath('state') .. '/cartograph'
    vim.fn.mkdir(dir, 'p')
    return dir .. '/' .. vim.fn.fnamemodify(root, ':p'):gsub('/+$', ''):gsub('[/\\:]', '%%') .. '.queries.jsonl'
end

--- the cartograph commit this code runs from: `<sha>` or `<sha>+dirty`, or 'unknown' outside a checkout
function M.commit(repo)
    local r = vim.system({ 'git', '-C', repo, 'rev-parse', '--short=12', 'HEAD' }, { text = true }):wait(10000)
    if not r or r.code ~= 0 then return 'unknown' end
    local sha = vim.trim(r.stdout or '')
    local d = vim.system({ 'git', '-C', repo, 'status', '--porcelain', '--untracked-files=no' }, { text = true }):wait(10000)
    return sha .. ((d and d.code == 0 and vim.trim(d.stdout or '') ~= '') and '+dirty' or '')
end

--- the summary of an answer a replay compares: what the answer CLAIMS, not its rows
function M.envelope(doc, status)
    local aw = type(doc.absence_why) == 'table' and doc.absence_why or {}
    local rf = type(doc.refusal) == 'table' and doc.refusal or {}
    local g = type(doc.graph) == 'table' and doc.graph or {}
    return {
        status = status,
        absence = doc.absence ~= vim.NIL and doc.absence or nil,
        premise = aw.premise ~= vim.NIL and aw.premise or nil,
        why = aw.why ~= vim.NIL and aw.why or nil,
        tier = doc.tier ~= vim.NIL and doc.tier or nil,
        rows = type(doc.result) == 'table' and #doc.result or nil,
        refusal = rf.rule ~= vim.NIL and rf.rule or nil,
        generation = g.generation ~= vim.NIL and g.generation or nil,
    }
end

--- a logger for one host: { record(verb, args, doc, status) } appending to `path` (default M.path(roots[1]))
--- opts: roots, flags (the host's own argv flags, so a replay opens the graph the same way), repo, path
function M.open(opts)
    local path = opts.path or M.path(opts.roots[1])
    local stamp = { commit = M.commit(opts.repo), roots = opts.roots, flags = opts.flags or {} }
    local L = { path = path, stamp = stamp }
    function L.record(verb, args, doc, status)
        local rec = { ts = os.date('!%Y-%m-%dT%H:%M:%SZ'), commit = stamp.commit, roots = stamp.roots, flags = stamp.flags,
            verb = verb, args = args, answer = M.envelope(doc, status) }
        local fd = io.open(path, 'a')
        if not fd then return nil, 'cannot append to ' .. path end
        fd:write(vim.json.encode(rec), '\n')
        fd:close()
        return true
    end
    return L
end

--- every record of a log file -> { rec … } (a line that does not decode is skipped and counted)
function M.read(path)
    local out, bad = {}, 0
    local fd = io.open(path)
    if not fd then return nil, 'no query log at ' .. path end
    for line in fd:lines() do
        local ok, rec = pcall(vim.json.decode, line)
        if ok and type(rec) == 'table' and rec.verb then out[#out + 1] = rec else bad = bad + 1 end
    end
    fd:close()
    return out, bad
end

--- the fields of two envelopes that differ -> { { field, before, after } } (empty: the same answer). `generation` is a
--- counter of the session, not a claim about the code, and is never compared.
function M.diff(a, b)
    local out = {}
    for _, f in ipairs({ 'status', 'absence', 'premise', 'tier', 'rows', 'refusal' }) do
        local x, y = a and a[f], b and b[f]
        if x == vim.NIL then x = nil end
        if y == vim.NIL then y = nil end
        if x ~= y then out[#out + 1] = { field = f, before = x, after = y } end
    end
    return out
end

return M
