-- OBJECTIVES (discovery, CART-0588): one pair of environment versions admits SEVERAL goals, and they are not
-- variants of each other, because each one produces a different work list. Each goal is offered with its SIZE
-- (the decision-relevant number), what it was inferred FROM, and an absence when it cannot be offered:
--   port          satisfy `to`, abandon `from`: the reads `to` no longer provides (portability.reference_diff)
--   backcompat    satisfy BOTH: the same demands, SPLIT by portability.correspond into
--                   common  the paired form is provided by both versions: one spelling, no shim
--                   shim    the paired form exists only in `to`: needs an adapter
--                   frontier  unpaired: whether a common form exists was not looked at
--                 A backcompat with unpaired rows reports its split as FRONTIER, never one number.
--   floor-raise   satisfy `to` AND USE it: unbuilt (CART-1907), answered as such
-- `corpus` (optional; JSON from tools/corpusroots.lua, `@file` reads it) is the INDEPENDENT second source: raw read
-- counts from code that already targets `to`, not adjudicated by any profile. For each paired row it reports how often
-- that corpus reads the new form's root and the old one's; a corpus that still reads the OLD root disagrees with the
-- pairing. This finding is about an artifact, not about the port.
-- ⚠ The surface is READS (what portability_move answers), not the whole port: CART-0120's Von-Neumann patch
-- changed 1027 lines for a read-surface port of 10 names. Data-stage prototype moves are a different surface.
-- CLAIM: at least one goal is offered.
local port = require 'cartograph.portability'

local function measure(store, p)
    local res, why = port.reference_diff(store, p.from, p.to)
    if not res then return { error = why } end
    local cor, cwhy = port.correspond(p.from, p.to, res.lost)
    if not cor then return { error = cwhy } end
    local corpus
    if p.corpus and p.corpus ~= '' then
        local ok, c = pcall(vim.json.decode, p.corpus)
        if not ok or type(c) ~= 'table' or type(c.roots) ~= 'table' then
            return { error = 'corpus is not a tools/corpusroots.lua JSON (no `roots`): ' .. tostring(c) }
        end
        corpus = c
    end
    local reads, common, shim, unpaired, disagree = 0, 0, 0, 0, {}
    for _, r in ipairs(cor.rows) do
        reads = reads + (r.reads or 0)
        if not r.to then unpaired = unpaired + 1
        elseif r.common then common = common + 1
        else shim = shim + 1 end
        if corpus and r.to then
            -- a ROOT rename is read at the root (the old root is gone from `to`); a MEMBER move at the name (its old
            -- root is kept, so reads of it say nothing)
            local names = corpus.names or {}
            r.corpus = r.basis == 'root-rename'
                and { at = 'root', new = corpus.roots[r.to:match('^[%w_]+')] or 0, old = corpus.roots[r.name:match('^[%w_]+')] or 0 }
                or { at = 'name', new = names[r.to] or 0, old = names[r.name] or 0 }
            if r.corpus.old > 0 then disagree[#disagree + 1] = r.name end
        end
    end
    local n = #cor.rows
    local goals = {}
    goals[#goals + 1] = n > 0
        and { goal = 'port', offered = true, size = n, reads = reads, surface = 'reads',
            from = 'portability.reference_diff(' .. p.from .. ', ' .. p.to .. ')',
            paired = common + shim, unpaired = unpaired }
        or { goal = 'port', offered = false, size = 0, absence = 'absent',
            why = ('no name this code reads is lost between %s and %s: nothing to port on the read surface'):format(p.from, p.to) }
    local bc = { goal = 'backcompat', offered = n > 0, size = n, surface = 'reads',
        from = 'portability.correspond: the lost set paired to its new form',
        common = common, shim = shim, unpaired = unpaired }
    if n == 0 then
        bc.absence, bc.why = 'absent', 'nothing is lost, so both versions are already satisfied on the read surface'
    elseif unpaired > 0 then
        bc.split = 'frontier'
        bc.why = ('%d of %d lost name(s) have no paired form, so whether one spelling can satisfy both versions was not'
            .. ' looked at for them. The demand is a correspondence for each one'):format(unpaired, n)
    else
        bc.split = 'complete'
    end
    goals[#goals + 1] = bc
    goals[#goals + 1] = { goal = 'floor-raise', offered = false, absence = 'unbuilt', ticket = 'CART-1907',
        why = 'no instrument finds code still written to the old version\'s limits (satisfy the new one AND use it)' }
    return { from = p.from, to = p.to, goals = goals, rows = cor.rows,
        corpus = corpus and { sources = corpus.sources, disagree = disagree } or nil }
end

local E = {
    name = 'objectives',
    kind = 'discovery',
    tags = { 'find', 'code' },
    measures = 'CART-0588',
    summary = 'the goals one environment move admits (port / backcompat / floor-raise), each SIZED: from/to = profiles (portability_targets); backcompat splits the lost reads into common form / needs a shim / unpaired (frontier); corpus = tools/corpusroots.lua JSON (@file) of code already on `to`, the independent check of each pairing',
    params = { from = 'string', to = 'string', corpus = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        local L = {}
        for _, g in ipairs(v.goals) do
            if g.offered then
                L[#L + 1] = g.goal == 'backcompat'
                    and ('backcompat %d (common %d / shim %d / unpaired %d)'):format(g.size, g.common, g.shim, g.unpaired)
                    or ('%s %d'):format(g.goal, g.size)
            else
                L[#L + 1] = ('%s: %s'):format(g.goal, g.absence)
            end
        end
        local offered = v.goals[1].offered or v.goals[2].offered
        return offered, ('%s -> %s: %s'):format(v.from, v.to, table.concat(L, ', '))
    end,
}

-- A 1.1 control script: `global` (a namespace 2.0 renamed to `storage`), `game.active_mods` (moved to
-- `script`, which 1.1 also has) and `game.entity_prototypes` (became prototypes.entity: a member rename the pairing
-- does not guess). Each root is read in two functions, since a root touched once is withheld from the read surface.
local FILES = { ['control.lua'] = table.concat({
    'local M = {}',
    'function M.a() global.seen = global.seen or {} return game.active_mods["x"] end',
    'function M.b() return global.seen, game.entity_prototypes["y"], game.active_mods["z"] end',
    'return M', '' }, '\n') }
local function by(v, name) for _, r in ipairs(v.rows) do if r.name == name then return r end end end
E.examples = {
    {
        name = 'a 1.1 -> 2.0 move: port 3; backcompat common 1 / shim 1 / unpaired 1, so its split is frontier',
        files = FILES,
        params = function () return { from = 'lua-factorio-11', to = 'lua-factorio' } end,
        expect = { holds = true, check = function (v)
            local p, b, f = v.goals[1], v.goals[2], v.goals[3]
            local g, a, e = by(v, 'global.seen'), by(v, 'game.active_mods'), by(v, 'game.entity_prototypes')
            return p.offered and p.size == 3 and b.common == 1 and b.shim == 1 and b.unpaired == 1
                and b.split == 'frontier' and f.absence == 'unbuilt'
                and g and g.to == 'storage.seen' and g.basis == 'root-rename' and g.common == false
                and a and a.to == 'script.active_mods' and a.basis == 'member-move' and a.common == true
                and e and e.to == nil, vim.inspect(v)
        end },
    },
    {
        name = 'the reverse move loses nothing: port and backcompat are ABSENT, with the reason, never a silent 0',
        files = FILES,
        params = function () return { from = 'lua-factorio', to = 'lua-factorio-11' } end,
        expect = { holds = false, check = function (v)
            return v.goals[1].absence == 'absent' and v.goals[2].absence == 'absent', vim.inspect(v.goals)
        end },
    },
    {
        name = 'a destination corpus that still reads the OLD form disagrees with the pairing (root for a rename, name for a move: 9 reads of the kept root `game` are no evidence)',
        files = FILES,
        params = function () return { from = 'lua-factorio-11', to = 'lua-factorio',
            corpus = vim.json.encode({ sources = { { dir = 'x' } }, roots = { storage = 5, global = 2, script = 1, game = 9 },
                names = { ['script.active_mods'] = 1 } }) } end,
        expect = { holds = true, check = function (v)
            local g, a = by(v, 'global.seen'), by(v, 'game.active_mods')
            return g.corpus.at == 'root' and g.corpus.new == 5 and g.corpus.old == 2
                and a.corpus.at == 'name' and a.corpus.new == 1 and a.corpus.old == 0
                and #v.corpus.disagree == 1 and v.corpus.disagree[1] == 'global.seen', vim.inspect(v.rows)
        end },
    },
}

return E
