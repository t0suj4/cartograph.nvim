-- The NAV AUDIT — fence the NAVIGATION surface the way tools/docaudit.lua fences
-- the docs. Sibling of docaudit (our own docs) and specaudit (our own specs);
-- this one audits our own COCKPIT ([[cartograph-concern-layering]]).
--
--   nvim --headless -u NONE -l tools/navaudit.lua
--
-- WHY THIS EXISTS. The analysis half of cartograph has uniform honesty: typed
-- refusals, index-only reporting `unsupported` rather than a fabricated empty,
-- hover explaining why-refused. The NAVIGATION half did not, and its failure
-- mode is not a wrong answer but SILENCE — a missing wire renders as "nothing
-- here", which reads exactly like a real "none", so it never trips a fence and
-- only a user can find it. Three bugs in one session were that (mark refusing
-- with no subject, ws/refused hover unwired, a fn with 4 callers reading as
-- "(no callers found)"). Each was fixed by hand; this makes the class fail a
-- commit instead.
--
-- THREE CHECKS, and note the UNIT of the first one:
--
--   A. SURFACE HONESTY. A file that reads whole-graph facts must also be able to
--      say they are ABSENT. The unit is the SURFACE, not the verb — the earlier
--      ledger counted "N guarded verbs" and every guard sat on the command
--      surface, so the cockpit reached a fabricated "none" by NAVIGATING. A pane
--      is a surface; so is an LSP handler. Writing this check found the second
--      instance (source.lua's jump claiming "no known callee" on a thin index).
--   B. CONCERN DISPOSITION. Every altitude symbols.lua dispatches on must either
--      have a concerns.REGISTRY entry or be listed NOT_A_CONCERN here, with a
--      reason. A new relation altitude cannot ship undeclared, and a stale entry
--      on either side fails too.
--   C. HOVER DISPOSITION. Every altitude must be in the node-hover class or
--      listed here with why it is not. This is the "every cell filled, or
--      explicitly not-applicable" rule: the bug was never a wrong hover, it was
--      an altitude nobody had decided about.
--
-- Ratchets are 0 and are meant to STAY 0: unlike docaudit's doc-coverage floor,
-- there is no legacy backlog here — the checks were written against a clean
-- tree, and A's one finding was fixed rather than ratcheted around.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/navaudit%.lua$')
package.path = here .. '/../lua/?.lua;' .. here .. '/../lua/?/init.lua;' .. package.path
local ROOT = here .. '/..'

local function slurp(rel)
    local f = io.open(ROOT .. '/' .. rel, 'r')
    if not f then return nil end
    local s = f:read('a'); f:close(); return s
end

local function ls(dir)
    local out = {}
    local p = io.popen(('ls %s/%s/*.lua 2>/dev/null'):format(ROOT, dir))
    if p then
        for line in p:lines() do out[#out + 1] = line:gsub('.*/lua/', 'lua/') end
        p:close()
    end
    return out
end

local fails = {}
local function fail(s) fails[#fails + 1] = s end

-- ── A. SURFACE HONESTY ──────────────────────────────────────────────────────
-- Reads of facts that only exist after the WHOLE-GRAPH call fixpoint. The thin
-- index carries every file's defs and 4 edges in total (import only, 0 calls),
-- so any of these yields a confident nothing there.
local WHOLE_GRAPH_READS = {
    'topo%(%):callers', 'topo%(%):callees', 'topo%(%):registrants_detail',
    'topo%(%):var_used_by_detail', 'store%.occurrences%(',
}
-- Evidence a file can report the absence: the capability predicate, the concern
-- registry's two-halved empty, or the command-surface guard.
local GUARDS = { 'is_index_only', 'needs_edges', 'whole_graph%(', 'empty_of%(' }

local SURFACES = {}
for _, f in ipairs(ls('lua/cartograph/panes')) do SURFACES[#SURFACES + 1] = f end
for _, f in ipairs(ls('lua/cartograph/commands')) do SURFACES[#SURFACES + 1] = f end
for _, f in ipairs({ 'lua/cartograph/lsp.lua', 'lua/cartograph/textplates.lua',
                     'lua/cartograph/mentions.lua', 'lua/cartograph/commands.lua' }) do
    SURFACES[#SURFACES + 1] = f
end

print('== A. SURFACE HONESTY: a surface that reads whole-graph facts must be able'
    .. ' to say they are absent ==')
local checked, unguarded = 0, 0
for _, rel in ipairs(SURFACES) do
    local src = slurp(rel)
    if src then
        local reads = 0
        for _, pat in ipairs(WHOLE_GRAPH_READS) do
            for _ in src:gmatch(pat) do reads = reads + 1 end
        end
        if reads > 0 then
            checked = checked + 1
            local guarded = false
            for _, g in ipairs(GUARDS) do if src:find(g) then guarded = true break end end
            if guarded then
                print(('  ok    %-34s %d whole-graph read(s), guarded'):format(rel, reads))
            else
                unguarded = unguarded + 1
                fail(('SURFACE %s makes %d whole-graph read(s) and cannot report their'
                    .. ' absence — it will render a fabricated "none" on a thin index')
                    :format(rel, reads))
            end
        end
    end
end
if checked == 0 then
    fail('A found NO surface reading whole-graph facts — the patterns have rotted')
end

-- ── B. CONCERN DISPOSITION ──────────────────────────────────────────────────
-- Altitudes with no registry entry, and WHY. Keep the reasons: they are the
-- design record for what a concern is NOT.
local NOT_A_CONCERN = {
    files  = 'containment: the structural root',
    file   = 'containment',
    fn     = 'containment',
    block  = 'containment',
    region = 'containment',
    var    = 'a DEF altitude that happens to show a relation (its subject and'
        .. ' inverse are structural) — shares the empty fix, not an entry',
    tbl    = 'a def altitude, as var',
    states = 'data: the FSM model',
    state  = 'data: one state',
    lit    = 'data: a literal value tree',
    live   = 'data: runtime values, whose idiom is var_context not a node def',
    ws     = 'the working set: rows are a USER set, not a derived relation',
    protos = 'a concern INDEX and a ROOT axis (the prototype roster): its rows'
        .. ' hang from nothing, like files/states — the door is'
        .. ' :CartographPrototypes!. `proto` below it IS a registry entry',
}

print('\n== B. CONCERN DISPOSITION: every altitude declared or explicitly not a'
    .. ' concern ==')
local symsrc = assert(slurp('lua/cartograph/panes/symbols.lua'),
    'navaudit: cannot read symbols.lua')
local altitudes = {}
for lvl in symsrc:gmatch("level == '([a-z]+)'") do altitudes[lvl] = true end
local concerns = require 'cartograph.panes.concerns'

local nalt = 0
for lvl in pairs(altitudes) do
    nalt = nalt + 1
    local entry, excused = concerns.of(lvl), NOT_A_CONCERN[lvl]
    if entry and excused then
        fail(('ALTITUDE %s is BOTH a registry entry and listed NOT_A_CONCERN'):format(lvl))
    elseif not entry and not excused then
        fail(('ALTITUDE %s has no disposition: give it a concerns.REGISTRY entry, or'
            .. ' list it in navaudit NOT_A_CONCERN with a reason'):format(lvl))
    end
end
for lvl in pairs(NOT_A_CONCERN) do
    if not altitudes[lvl] then
        fail(('STALE navaudit NOT_A_CONCERN entry %q — no such altitude in symbols.lua')
            :format(lvl))
    end
end
for lvl in pairs(concerns.REGISTRY) do
    if not altitudes[lvl] then
        fail(('DEAD concerns.REGISTRY entry %q — symbols.lua never dispatches on it')
            :format(lvl))
    end
end
print(('  %d altitudes: %d concerns, %d explicitly not'):format(
    nalt, (function () local n = 0 for _ in pairs(concerns.REGISTRY) do n = n + 1 end return n end)(),
    (function () local n = 0 for _ in pairs(NOT_A_CONCERN) do n = n + 1 end return n end)()))

-- every entry must be TOTAL (the spec asserts this too; here it gates a commit)
for lvl, e in pairs(concerns.REGISTRY) do
    for _, field in ipairs({ 'view_key', 'subject', 'ascend', 'hover' }) do
        if e[field] == nil then
            fail(('CONCERN %s declares no %s'):format(lvl, field))
        end
    end
    if not (e.empty and e.empty.computed and e.empty.uncomputed) then
        fail(('CONCERN %s has an UNTYPED empty — declare both halves (what an'
            .. ' absence MEANS, and why there might be no answer)'):format(lvl))
    end
end

-- ── C. HOVER DISPOSITION ────────────────────────────────────────────────────
local NO_NODE_HOVER = {
    files  = 'file rows are not node rows (the ● taught us line_file is too wide)',
    protos = 'a prototype is not a graph node: its anchor is a module + a line,'
        .. ' so hover previews the declaring line',
    proto  = 'override rows are source positions in the declaring module, as fn',
    lintact = 'action rows are not defs: each anchors to the REPORTED line, so'
        .. ' hover highlights that line (as fn)',
    suppressed = 'silenced findings are positions in ONE body, as occs: each row'
        .. ' anchors to the line whose marker silenced it',
    unread = 'unmodelled CONSTRUCTS, not defs: each row anchors to its own source'
        .. ' byte-range (expr nodes carry .at), previewed as a site',
    fn     = 'statement rows highlight the source line instead',
    block  = 'as fn',
    callers = 'site rows: the site renderer previews the position',
    occs   = 'site rows, as callers',
    var    = 'site rows, as callers',
    states = 'transition rows preview the spec, via line_trans',
    lit    = 'literal rows are values, not defs',
    live   = 'OPEN DECISION: runtime values, idiom is var_context (bench 0b)',
}

print('\n== C. HOVER DISPOSITION: every altitude decided ==')
local symbols = require 'cartograph.panes.symbols'
for lvl in pairs(altitudes) do
    local hovers = symbols.NODE_HOVER[lvl]
    local excused = NO_NODE_HOVER[lvl]
    if hovers and excused then
        -- caught my own first draft: `region` was listed out with the reason
        -- "region rows ARE node rows", which is an argument for being IN
        fail(('ALTITUDE %s is BOTH in the node-hover class and listed'
            .. ' NO_NODE_HOVER — one of the two is a leftover'):format(lvl))
    elseif not hovers and not excused then
        fail(('ALTITUDE %s has NO hover decision: add it to the node-hover class'
            .. ' (a registry entry with hover=\'node\', or M.NODE_HOVER), or list it'
            .. ' in navaudit NO_NODE_HOVER with the reason'):format(lvl))
    end
end
for lvl in pairs(NO_NODE_HOVER) do
    if not altitudes[lvl] then
        fail(('STALE navaudit NO_NODE_HOVER entry %q'):format(lvl))
    end
end
local nh = 0
for _ in pairs(symbols.NODE_HOVER) do nh = nh + 1 end
print(('  %d altitudes in the node-hover class, %d explicitly out'):format(nh,
    (function () local n = 0 for _ in pairs(NO_NODE_HOVER) do n = n + 1 end return n end)()))

-- ── report ──────────────────────────────────────────────────────────────────
print('')
if #fails > 0 then
    print(('navaudit: FAIL — %d finding(s)'):format(#fails))
    for _, f in ipairs(fails) do print('  * ' .. f) end
    os.exit(1)
end
print('navaudit: ok')
