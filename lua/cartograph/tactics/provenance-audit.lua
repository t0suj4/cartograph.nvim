-- PROVENANCE-AUDIT (discovery, CART-1181 — first cut: the RATIO). How much of a commit range did cartograph WRITE?
-- A commit's added lines are EXPLAINED when a journal entry added the same line to the same file (the entry's own
-- before -> after diff); every other added line is a HAND edit. The ratio is CART-0763's cartograph-in-the-loop
-- measure, taken from the record instead of estimated.
--
-- The attribution is cartograph.provenance.attribute (ONE copy, shared with the per-commit LEDGER): every journal whose
-- recorded root lies inside the repo, each entry's added lines matched as a MULTISET against each commit's added lines
-- — LINE level, so a commit mixing journaled and hand edits in one file splits honestly. Per commit it also reports
-- whether the travelling LEDGER note exists (refs/notes/cartograph, CART-1180).
-- The claim holds when ANY byte is explained (the loop is in use at all); the ratio itself is REPORTED, never a gate.
-- NOT YET: stale decisions, outstanding placeholders at the immutable boundary (they read the ledger's decisions).
local function repo_of_toolbelt()
    local here = vim.fn.fnamemodify((debug.getinfo(1, 'S').source:gsub('^@', '')), ':p')
    return (here:gsub('/lua/cartograph/tactics/[^/]*$', ''))
end

local function measure(_, p)
    local P = require 'cartograph.provenance'
    local repo = vim.fn.fnamemodify(p.repo or repo_of_toolbelt(), ':p'):gsub('/+$', '')
    local range = p.range or 'HEAD~20..HEAD'
    local v, why = P.attribute(repo, range)
    if not v then return { repo = repo, range = range, commits = {}, error = why } end
    v.repo, v.range, v.noted = repo, range, 0
    for _, c in ipairs(v.commits) do
        c.noted = P.read_note(repo, c.sha) ~= nil
        if c.noted then v.noted = v.noted + 1 end
        c.sha = c.sha:sub(1, 7)
    end
    return v
end

return {
    name = 'provenance-audit',
    kind = 'discovery',
    tags = { 'find', 'code' },
    measures = 'CART-1181',
    summary = 'how much of a commit range did cartograph WRITE? added lines explained by a journal entry vs hand edits (range = git range, default HEAD~20..HEAD; repo = default this cartograph); the ratio is reported, the claim is "any byte explained"',
    params = { range = 'string?', repo = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        return v.explained > 0, ('%.1f%% of %d added bytes over %d commit(s) were written through the journal (%d entries in %d journal(s)); %d bytes by hand; %d of %d commit(s) carry a ledger note')
            :format(v.ratio * 100, v.explained + v.hand, #v.commits, v.entries_used, v.journals, v.hand, v.noted, #v.commits)
    end,
    examples = {
        {
            name = 'a commit made through the journal is EXPLAINED, a hand commit is not — line by line',
            files = { ['m.lua'] = 'local M = {}\nreturn M\n' },
            params = function (store)
                local root = store.data.root
                local function sh(...) return vim.system({ 'git', '-C', root, ... }, { text = true }):wait() end
                sh('init', '-q'); sh('config', 'user.email', 't@t'); sh('config', 'user.name', 't')
                sh('add', '.'); sh('commit', '-qm', 'base')
                -- a HAND edit, committed
                local fd = assert(io.open(root .. '/m.lua', 'a')); fd:write('-- by hand\n'); fd:close()
                sh('commit', '-qam', 'hand')
                -- a JOURNALED edit (txn.apply writes through journal.begin/commit), committed
                local txn = require 'cartograph.txn'
                local plan = txn.protocol({ verb = 'probe', guards = {}, refspecs = {}, touched = { 'm.lua' },
                    generation = store.generation, stamps = { ['m.lua'] = txn.disk_stamp(root, 'm.lua') },
                    desc = 'journaled line', preserves = 'none' },
                    function () return function (_, before) return before .. '-- by cartograph\n' end end)
                assert(txn.apply(store, plan))
                sh('commit', '-qam', 'journaled')
                return { range = 'HEAD~2..HEAD', repo = root }
            end,
            expect = { holds = true, check = function (v)
                local hand, jour = v.commits[1], v.commits[2]
                return hand and jour and hand.explained == 0 and hand.hand > 0 and jour.explained > 0 and jour.hand == 0,
                    vim.inspect(v.commits)
            end },
        },
    },
}
