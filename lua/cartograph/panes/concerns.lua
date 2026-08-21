-- THE CONCERN REGISTRY: one declaration per RELATION altitude.
--
-- A relation altitude's rows are other nodes referring to a subject that is
-- never itself a row (callers / occs / regfor / refused). Before this file each
-- of them open-coded the same five answers in five different places — the
-- subject in M.subject, the inverse in the ascend dispatch, the hover class in
-- NODE_HOVER, the empty note inside its renderer — and every one of those lists
-- was incomplete for at least one altitude ([[cartograph-concern-layering]],
-- the "12 resolve_* passes" diagnosis). The declaration is the single place.
--
-- WHAT AN ENTRY DECLARES
--   view_key   which M.view field holds this altitude's key
--   subject    key -> the node id the altitude is ABOUT (the FSM-anchor law:
--              every altitude must hang somewhere in the structural tree)
--   ascend     key -> (level, key) — THE INVERSE. Every one of these was
--              already reconstructing its target by PARSING THE KEY; the keys
--              were designed invertible ad hoc, four times. This names it.
--   ascend_row optional cursor row to land on after ascending
--   hover      'node' rows are node defs (preview them) | 'site' rows are
--              source positions (the site renderer previews them)
--   empty      { computed = <what an absence MEANS>,
--                uncomputed = store -> <why there is no answer> | nil }
--
-- WHY `empty` HAS TWO HALVES — "no callers found" and "callers were never
-- computed" are different facts and must never render identically. MEASURED:
-- index-only mode carries every file's DEFS and *4 edges in total* (import
-- only — no ref, no reg, no use, 0 calls), so every relation concern is
-- unavailable there. A function with 4 callers on the full graph rendered
-- "(no callers found — entry point, or dynamically dispatched)": a manufactured
-- fact, because the pane never asked. This is the uniform-honesty invariant
-- ([[cartograph-vision]] #3) reaching the navigation half, where the failure
-- mode is not a wrong answer but SILENCE that reads as a real "none".

local M = {}

--- Every relation concern is built from edges the thin index does not carry, so
--- they share one reason. Returns nil when the concern IS computable.
local function needs_edges(store)
    if store.is_index_only and store.is_index_only() then
        return ('index-only mode has no call graph — :Cartograph %s for the full graph')
            :format((store.data and store.data.root) or '<dir>')
    end
end

M.needs_edges = needs_edges

--- The rung-0 harvest READS THE FILE, and so does the suppression reader, so the
--- real precondition for anything lint-shaped is LOCAL SOURCE — not the call
--- graph. A graph served over a scheme root has no expressions to read and no
--- line to write a marker on. Index-only is NOT a blocker here. Shared by the two
--- lint altitudes so they cannot drift into disagreeing about their own frontier.
local function needs_local_source(store)
    local root = store.data and store.data.root
    if not root or root:match('^%w+://') then
        return 'this graph has no local source to read expressions from'
    end
end

M.needs_local_source = needs_local_source

M.REGISTRY = {
    -- who calls this function. Rows group per using fn; a group row descends
    -- into that fn's occurrences, a lone site row into the fn itself.
    callers = {
        view_key = 'callers',
        subject  = function (key) return key end,
        ascend   = function (key) return 'fn', key end,
        ascend_row = 2, -- the first content row of the fn altitude
        hover    = 'site',
        empty    = {
            computed   = '(no callers found — entry point, or dynamically dispatched)',
            uncomputed = needs_edges,
        },
    },

    -- one function's occurrences of an entity. key = kind \31 entity \31 using-fn.
    -- The SUBJECT is the using function (its body is what you are reading), not
    -- the entity being referred to.
    occs = {
        view_key = 'occs',
        subject  = function (key)
            local fn = key and key:match('([^\31]*)$')
            return (fn ~= '' and fn) or nil
        end,
        -- the inverse is recorded IN the key: its `kind` field says which
        -- relation you descended from, so h returns there and not to a guess
        ascend   = function (key)
            local kind, entity = (key or ''):match('^(.-)\31(.-)\31')
            if not entity or entity == '' then return nil end
            return (kind == 'var') and 'var' or 'callers', entity
        end,
        hover    = 'site',
        empty    = {
            -- there was NO note here at all: 0 ranges rendered a header
            -- counting "(0)" and not one row of explanation
            computed   = '(no occurrences in this function — the reference is elsewhere)',
            uncomputed = needs_edges,
        },
    },

    -- who keeps this function alive without calling it (a dispatch table, a
    -- load-time callback list). Rows are the REGISTERING MODULES: a module
    -- node's id IS its file path, so a registrant row is about a node like any
    -- other row — measured 80/80 resolvable, which retired a banked "needs a
    -- decision" note.
    regfor = {
        view_key = 'regfor',
        subject  = function (key) return key end,
        ascend   = function (key) return 'fn', key end,
        -- ★ A SITE, NOT A NODE. These rows name the registering MODULE, and a
        -- module node's id IS its file path -- so hovering one as a NODE
        -- previewed the top of the file, which is where a module's range starts
        -- ("the registered by rows preview the beginning of the file, it's
        -- rather confusing"). The row has the registration's exact range in
        -- line_site all along, and its own label prints `m.lua:7`. Third
        -- altitude with this defect (syms, axis, regfor): whenever a row is
        -- ABOUT a container but ANCHORED at a position, the position wins.
        hover    = 'site',
        empty    = {
            computed   = '(no registrations — nothing keeps this alive but its callers)',
            uncomputed = needs_edges,
        },
    },

    -- ONE PROTOTYPE, as a place ([[cartograph-interactive-reports]] pilot 2):
    -- rows are its ORDERED field overrides and its hedges. key = file \31 index.
    -- The subject is the DECLARING MODULE — a module node's id IS its file path,
    -- so this altitude hangs in the structural tree (the FSM-anchor law) even
    -- though a prototype is not itself a graph node. Its uncomputed half is NOT
    -- needs_edges: the reading re-parses module rows, so what makes it
    -- unavailable is the absence of a data stage, not a thin index.
    proto = {
        view_key = 'proto',
        subject  = function (key) return (key or ''):match('^(.-)\31') end,
        ascend   = function () return 'protos', nil end,
        hover    = 'site', -- rows are source positions in the declaring module
        empty    = {
            computed   = '(no field overrides — the base is taken as declared)',
            uncomputed = function (store)
                return require('cartograph.prototypes').unavailable(store)
            end,
        },
    },

    -- ONE LINT FINDING as a place: its explanation, and what can be done about it.
    -- key = fn \31 line \31 rule. Asked for directly — a finding row states WHAT is
    -- wrong in 30 columns and had nowhere to put the WHY or the actions.
    -- The uncomputed half is neither needs_edges (rung-0 lints ride the expression
    -- IR, which a thin index can re-derive per file) nor a data stage: what makes
    -- this altitude unanswerable is a language the harvest cannot read.
    lintact = {
        view_key = 'lintact',
        subject  = function (key) return (key or ''):match('^(.-)\31') end,
        ascend   = function (key) return 'fn', (key or ''):match('^(.-)\31') end,
        hover    = 'site', -- rows anchor to the reported line in the fn's source
        empty    = {
            -- reachable only from a row that WAS a finding, so an empty here means
            -- the source moved out from under the key
            computed   = '(this finding is no longer reported here — the source changed)',
            uncomputed = needs_local_source,
        },
    },

    -- THE COVERAGE DOOR. `~ 52/56 read` was the row that exists to stop "0 findings"
    -- reading as an all-clear — and it was the one row a user could not parse ("I
    -- don't know what this means"). No 30-column rewording fixes that: the ROWS are
    -- the explanation. Descending it names each construct the expression IR has no
    -- case for, at its line, with its source range.
    --
    -- Not merely "unexamined": a `?` node makes expr.is_pure false, and is_pure is
    -- the single safety gate for every key-equality rule, so the unknown propagates
    -- outward to every expression it nests inside. That is why unread ⇒ no
    -- guarantee, and why this is a FRONTIER rather than a finding.
    unread = {
        view_key = 'unread',
        subject  = function (key) return key end,
        ascend   = function (key) return 'fn', key end,
        hover    = 'site', -- rows anchor to the line carrying the unmodelled node
        empty    = {
            -- the door only appears when unknown > 0, so 0 here means the harvest
            -- now covers what it did not — a real change, but a MAY (this altitude
            -- is reachable by a trail return too)
            computed   = '(every expression here is modelled — a construct may have'
                .. ' become readable since the count was drawn)',
            uncomputed = needs_local_source,
        },
    },

    -- THE SUPPRESSION DOOR. The `N suppressed here` row on the lints lens is a
    -- COUNT, and a count you cannot open is a dead end: once you navigated away
    -- from the finding you had just silenced, its `un-suppress` was unreachable —
    -- :CartographUndo only reverses the newest journal entry, so the marker was
    -- effectively permanent from inside the browser. The count now descends into
    -- the findings it counts, each of which opens its own lintact.
    --
    -- The subject is the FUNCTION, not a finding: these rows are a set of
    -- positions in one body, exactly as `occs` is.
    suppressed = {
        view_key = 'suppressed',
        subject  = function (key) return key end,
        ascend   = function (key) return 'fn', key end,
        hover    = 'site', -- rows anchor to the silenced line in the fn's source
        empty    = {
            -- States the world, and only MAY-states the change. The door opens
            -- from a row that said N>0, so arriving at 0 usually does mean a
            -- marker went away — but this altitude is also reachable by a trail
            -- return or a restored location, where nothing was EVER suppressed,
            -- and asserting a change there would fabricate one. An empty note is
            -- exactly where that kind of invention is easiest to miss.
            computed   = '(no finding here is suppressed — a marker may have gone'
                .. ' since the count was drawn)',
            uncomputed = needs_local_source,
        },
    },

    -- a REFUSAL as a place: the rule that refused a call and the candidates it
    -- refused between. key = fn \31 line \31 callee.
    -- THE AXIS FAMILY (CART-0482): one entry for every declared relation, whose
    -- key is `<axis>\31<subject>`. The axis registry says what the members ARE;
    -- this says what the altitude IS -- and the reason it is one entry rather
    -- than six is that the five answers below do not vary per axis. Where an
    -- axis differs (row kind, cardinality, whether counting costs a traversal)
    -- it differs in panes/axes.lua, which is the whole point of the split.
    axis = {
        view_key = 'axis',
        subject  = function (key)
            local _, subject = require('cartograph.panes.axes').split(key)
            return subject
        end,
        ascend   = function (key)
            -- back to the subject's OWN altitude, whichever kind it is: a
            -- relation hangs off its subject (the FSM-anchor law)
            local axes = require 'cartograph.panes.axes'
            local name, subject = axes.split(key)
            local e = axes.AXES[name or '']
            if not e then return 'files' end
            if e.on == 'module' then return 'file', subject end
            if e.on == 'var' then return 'var', subject end
            return 'fn', subject
        end,
        hover    = 'node',
        empty    = {
            computed = 'no members on this axis — the relation holds none here',
            uncomputed = needs_edges,
        },
    },
    refused = {
        view_key = 'refused',
        -- MEASURED MISSING: M.subject returned nil here while the ascend
        -- handler derived the same answer from the same key one line away, so
        -- mark refused on every row that was not a candidate.
        subject  = function (key) return (key or ''):match('^(.-)\31') end,
        ascend   = function (key) return 'fn', (key or ''):match('^(.-)\31') end,
        hover    = 'node',
        empty    = {
            computed   = '(no candidates recorded)',
            uncomputed = needs_edges,
        },
    },
}

--- The entry for an altitude, or nil if it is not a relation concern.
--- NOT a concern (deliberately): the CONTAINMENT altitudes (files/file/fn/
--- block/region), which have no subject to declare because they ARE the
--- structural tree; the DATA altitudes (states/state/lit/live), whose rows are
--- values rather than nodes; `ws`, whose rows are a user set; and `var`/`tbl`,
--- which are def altitudes that happen to SHOW a relation. `var` shares the
--- sites renderer and so shares the empty-fabrication fix, without being an
--- entry here — its subject and inverse are structural, not relational.
function M.of(level) return M.REGISTRY[level] end

--- key -> subject, for the concern at `level`. nil when not a concern, or when
--- the key is malformed (never '' — an empty string is truthy in lua and every
--- caller would then ask store.node('')).
function M.subject_of(level, key)
    local e = M.REGISTRY[level]
    if not (e and key) then return nil end
    local id = e.subject(key)
    return (id ~= '' and id) or nil
end

--- The altitudes whose ROWS ARE NODE DEFS, derived from the declarations so a
--- new concern cannot be added to the registry and forgotten in the hover
--- dispatch — which is exactly how the working set and the candidate list ended
--- up previewing nothing.
function M.node_hover_levels()
    local out = {}
    for level, e in pairs(M.REGISTRY) do
        if e.hover == 'node' then out[level] = true end
    end
    return out
end

--- The empty row for a concern: (text, unavailable_reason). An UNAVAILABLE
--- concern states why; a computed-empty one states what the absence means.
--- Returns nil when `level` is not a concern.
function M.empty_of(level, store)
    local e = M.REGISTRY[level]
    if not (e and e.empty) then return nil end
    local why = e.empty.uncomputed and e.empty.uncomputed(store)
    if why then return why, why end
    return e.empty.computed, nil
end

return M
