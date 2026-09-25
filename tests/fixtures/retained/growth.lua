-- retained fixture: state that outlives a call, grown by it — and the shapes that are NOT growth.
local M = {}

-- (1) a private LOG, appended per call and never shrunk: append, private
local log = {}
function M.record(x)
    log[#log + 1] = x
end

-- (2) a private MEMO cache, one slot per distinct key: keyed, private
local cache = {}
function M.memo(k)
    local v = cache[k]
    if v == nil then v = { k }; cache[k] = v end
    return v
end

-- (3) a queue that is FLUSHED (reassigned in a function): no finding
local pending = {}
function M.push(x) table.insert(pending, x) end
function M.flush() local p = pending; pending = {}; return p end

-- (4) a map with an EVICTION (`lru[k] = nil`): no finding
local lru = {}
function M.put(k, v) lru[k] = v end
function M.drop(k) lru[k] = nil end

-- (5) a WEAK table: the collector removes what nothing else holds — no finding
local weak = setmetatable({}, { __mode = 'k' })
function M.tag(o) weak[o] = true end

-- (6) the CALL'S OWN table: it dies with the call — no finding
function M.build(xs)
    local t = {}
    for _, x in ipairs(xs) do t[#t + 1] = x end
    return t
end

-- (7) a FIXED slot overwritten per call: bounded — no finding
local state = {}
function M.set(v) state[1] = v end

-- (8) a field of the RETURNED module table: exported (another file may shrink it by name)
M.registry = {}
function M.register(x) M.registry[#M.registry + 1] = x end
M.handlers = {}
function M.on(name, fn) M.handlers[name] = fn end   -- other.lua resets `handlers`: suppressed

-- (9) a GLOBAL grown by key
function M.see(x) seen_all[x] = true end

-- (10) grown through a CALL (`table.insert`), never shrunk: append, private
local events = {}
function M.emit(e) table.insert(events, e) end

-- (11) a queue drained through a CALL (`table.remove`): no finding
local q = {}
function M.enq(x) q[#q + 1] = x end
function M.deq() return table.remove(q, 1) end

-- (12) a closure appending to its BUILDER's local: lives as long as the builder's call — no finding
function M.collect(xs)
    local out = {}
    local function add(x) out[#out + 1] = x end
    for _, x in ipairs(xs) do add(x) end
    return out
end

-- (13) buckets under a container that is RESET: resetting the parent drops every bucket — no finding
local idx = {}
function M.index(k, v)
    idx[k] = idx[k] or {}
    table.insert(idx[k], v)
end
function M.reindex() idx = {} end

-- (14) a SCRATCH path written through a cursor this call starts at 0: reused slots — no finding
local path = {}
function M.depth(node)
    local np = 0
    while node do
        np = np + 1
        path[np] = node
        node = node.parent
    end
    return np
end

return M
