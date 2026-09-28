-- cartograph.decisions — REMEMBERED DECISIONS: policy over views, the first kind (CART-1160 step 6, CART-1120).
--
-- A tactic stops only on a decision, and resuming used to mean editing the term: the answer went into the step's
-- `accept` list. A remembered decision is that answer recorded ONCE, by the user, and consulted on every later run.
-- Two forms, and the lookup tries them in this order:
--   EXACT   this very question: its identity `key` (kind + verb + evidence + the files it is about + the target world,
--           hashed; the prose is not part of it). The same question asked again is answered; a different one is not.
--   VIEW    every decision of one KIND whose subjects lie in a view: `{ dir = abs }` or `{ file = abs }`. The views are
--           mounts (cartograph.namespace) and the lookup is resolve: a plan is covered only when EVERY file it touches
--           is inside the view, and the most specific covering view is the one recorded as the reason.
-- ★ THE STORE IS THE USER'S (CART-1120 item 6: the tree selects, it never supplies): a file in the state directory,
-- beside the journals, written only by `remember` — never by a run, never from inside the analysed tree, and there is
-- NO MCP verb that writes it: an agent that could remember an answer could grant itself standing permission (a
-- `target-write` into another world, a promotion). The CLI (tools/decisions.lua) and this module are the only doors.
-- ★ PROVENANCE: a remembered answer is never silent — the step's residue says which entry answered, and when.
-- ⚠ ANSWERS ARE `accept` ONLY. A remembered "no" has no meaning for a runner that stops on the question anyway, so
-- there is no conflict between entries and no AMBIGUOUS case yet; precedence only picks which entry is CITED.
local M = {}

--- where the record lives (tests point it elsewhere)
M.path = vim.fn.stdpath('state') .. '/cartograph/decisions.json'

local function load()
    local fd = io.open(M.path)
    if not fd then return { version = 1, entries = {} } end
    local txt = fd:read('a'); fd:close()
    local ok, t = pcall(vim.json.decode, txt)
    if not ok or type(t) ~= 'table' or type(t.entries) ~= 'table' then return { version = 1, entries = {} } end
    return t
end

local function save(t)
    vim.fn.mkdir(vim.fn.fnamemodify(M.path, ':h'), 'p')
    local tmp = M.path .. '.tmp'
    local fd = assert(io.open(tmp, 'w')); fd:write(vim.json.encode(t)); fd:close()
    assert(os.rename(tmp, M.path))
end

--- a canonical text for a value: keys sorted, functions and metatables dropped — the stable part of a question
local function canon(v)
    local ty = type(v)
    if ty == 'table' then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function (a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do
            if type(v[k]) ~= 'function' then parts[#parts + 1] = tostring(k) .. '=' .. canon(v[k]) end
        end
        return '{' .. table.concat(parts, ',') .. '}'
    elseif ty == 'function' then return 'fn'
    else return ty .. ':' .. tostring(v) end
end

--- the absolute files a plan's decision is ABOUT: every touched file, in the world it writes
function M.subjects(store, plan)
    local root = require('cartograph.txn').target_root(store, plan)
    local out = {}
    for _, rel in ipairs(plan.touched or {}) do out[#out + 1] = root .. '/' .. rel end
    table.sort(out)
    return out
end

--- the identity of ONE decision a plan asks: -> 'sha256:…'
function M.key(store, plan, h)
    local target = type(plan.target) == 'table' and plan.target.root or nil
    return 'sha256:' .. vim.fn.sha256(canon {
        kind = h.kind, verb = plan.verb, evidence = h.evidence, subjects = M.subjects(store, plan), target = target })
end

--- Record an answer. `what` is one of:
---   { key = <an option's key>, kind, text? }            EXACT: this question
---   { kind, dir = abs } | { kind, file = abs }          VIEW: every `kind` decision about files inside it
--- plus `why` (the user's reason, shown back as provenance). -> entry | nil, why, class
function M.remember(what)
    what = what or {}
    if type(what.kind) ~= 'string' or what.kind == '' then return nil, 'remember which decision? (`kind`)', 'ill-posed' end
    local scope
    if what.key then scope = { exact = what.key }
    elseif what.dir then scope = { dir = (vim.fn.fnamemodify(what.dir, ':p'):gsub('/+$', '')) }
    elseif what.file then scope = { file = vim.fn.fnamemodify(what.file, ':p') }
    else return nil, 'remember it for what? (`key` for this question, or `dir` / `file` for a view)', 'ill-posed' end
    local t = load()
    for _, e in ipairs(t.entries) do
        if e.kind == what.kind and canon(e.scope) == canon(scope) then return e end -- already remembered
    end
    local e = { id = ('d%d-%s'):format(os.time(), vim.fn.sha256(canon(scope) .. what.kind):sub(1, 8)), kind = what.kind,
        scope = scope, answer = 'accept', text = what.text, why = what.why, at = os.date('!%Y-%m-%dT%H:%M:%SZ') }
    t.entries[#t.entries + 1] = e
    save(t)
    return e
end

--- forget one entry by id -> true | nil, why
function M.forget(id)
    local t = load()
    for i, e in ipairs(t.entries) do
        if e.id == id then table.remove(t.entries, i); save(t); return true end
    end
    return nil, ('no remembered decision %s'):format(tostring(id)), 'ill-posed'
end

function M.list() return load().entries end

--- does a remembered answer cover this decision? -> entry, provenance text | nil
function M.lookup(key, kind, subjects)
    local entries = load().entries
    for _, e in ipairs(entries) do
        if e.scope.exact and e.scope.exact == key and e.kind == kind then
            return e, ('remembered for this exact question (%s, %s)'):format(e.id, e.at)
        end
    end
    -- views of this kind, as mounts: a file is covered by the LONGEST view containing it
    local namespace = require 'cartograph.namespace'
    local ns = namespace.empty()
    for _, e in ipairs(entries) do
        if e.kind == kind and (e.scope.dir or e.scope.file) then
            ns = namespace.mount(ns, e.scope.dir or e.scope.file, e, { union = 'after' })
        end
    end
    if #subjects == 0 then return nil end
    -- every file is answered by its own most specific view; the answer cites EACH entry that covered some file,
    -- most specific first (a plan spanning two views was answered by both, and saying one would hide the other)
    local by_id, cites = {}, {}
    for _, f in ipairs(subjects) do
        local hit = namespace.resolve(ns, f)
        if not hit then return nil end -- one file outside every view: the plan is not covered
        local e = hit.layers[1].target
        if not by_id[e.id] then by_id[e.id] = #hit.point; cites[#cites + 1] = e end
    end
    table.sort(cites, function (a, b) return by_id[a.id] > by_id[b.id] or (by_id[a.id] == by_id[b.id] and a.id < b.id) end)
    local parts = {}
    for _, e in ipairs(cites) do parts[#parts + 1] = ('%s (%s, %s)'):format(e.scope.dir or e.scope.file, e.id, e.at) end
    return cites[1], ('remembered for every `%s` decision under %s'):format(kind, table.concat(parts, ' and '))
end

return M
