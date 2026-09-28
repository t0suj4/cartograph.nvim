-- cartograph.intents — THE WRITE-AHEAD INTENT RECORD for effects the journal cannot hold (CART-1185). A journaled write
-- is recoverable from its own entry (journal.recover); a COMPENSABLE or IRREVERSIBLE effect (a remote commit, a deploy,
-- a message) is not — and when its apply times out or raises, nobody knows whether it happened. So before such an
-- apply runs, its INTENT is recorded { id = the edit identity, verb, args digest, where }; a clean outcome closes it;
-- an UNKNOWN outcome leaves it OPEN. A restarted runner reads the open intents, and re-running the step RECONCILES
-- each: the step is goal-checked (rerun = 'empty'), so "already took effect" is `empty` and "did not" plans again —
-- retry and reconcile are the same operation.
-- The record is the user's (the state dir, beside the journals), keyed by the world's root.
local M = {}

local function dir()
    local d = vim.fn.stdpath('state') .. '/cartograph/intents'
    vim.fn.mkdir(d, 'p')
    return d
end
local function path_of(root) return dir() .. '/' .. tostring(root):gsub('/+$', ''):gsub('[/\\:]', '%%') .. '.json' end

local function load(root)
    local fd = io.open(path_of(root))
    if not fd then return {} end
    local ok, t = pcall(vim.json.decode, fd:read('a')); fd:close()
    return (ok and type(t) == 'table') and t or {}
end
local function save(root, t)
    local p = path_of(root)
    local fd = assert(io.open(p .. '.tmp', 'w')); fd:write(vim.json.encode(t)); fd:close()
    assert(os.rename(p .. '.tmp', p))
end

--- canonical text of a value (keys sorted, functions dropped): the stable part of an invocation
local function canon(v)
    if type(v) == 'table' then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function (a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do if type(v[k]) ~= 'function' then parts[#parts + 1] = tostring(k) .. '=' .. canon(v[k]) end end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return type(v) .. ':' .. tostring(v)
end

--- the EDIT IDENTITY of an invocation: hash(verb, args) — the same invocation is the same intent, whoever retries it
function M.identity(verb, args) return 'sha256:' .. vim.fn.sha256(tostring(verb) .. '\31' .. canon(args or {})) end

--- record an intent before a non-journaled apply -> the intent row
function M.open(root, verb, args, where)
    local t = load(root)
    local id = M.identity(verb, args)
    t[id] = { id = id, verb = verb, where = where, state = 'in-flight', at = os.date('!%Y-%m-%dT%H:%M:%SZ') }
    save(root, t)
    return t[id]
end

--- close an intent: 'applied' | 'refused' | 'reconciled-done' | 'reconciled-applied'
function M.close(root, id, outcome)
    local t = load(root)
    if t[id] then t[id] = nil; save(root, t) end
    return outcome
end

--- mark an intent INDETERMINATE (left open, with why)
function M.unknown(root, id, why)
    local t = load(root)
    if t[id] then t[id].state = 'indeterminate'; t[id].why = why; save(root, t) end
end

--- the OPEN intents of a world: { rows }, oldest first
function M.open_intents(root)
    local out = {}
    for _, r in pairs(load(root)) do out[#out + 1] = r end
    table.sort(out, function (a, b) return tostring(a.at) < tostring(b.at) end)
    return out
end

function M.get(root, id) return load(root)[id] end

return M
