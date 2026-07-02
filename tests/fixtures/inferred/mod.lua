-- Fixture for the unique-method-name fallback: receivers vm cannot type
-- (fetched out of an opaque storage table, the Factorio pattern).
local Thing = {}
Thing.__index = Thing

function Thing.get(name)
    return storage.things[name] -- opaque: vm cannot type the return
end

function Thing:zap()
    return 1
end

function Thing:dup() return 1 end

local Other = {}
function Other:dup() return 2 end -- ambiguous with Thing:dup

local M = { Other = Other }

function M.fire(name)
    local t = Thing.get(name)
    t:zap()          -- unique method name -> inferred edge to Thing:zap
    t:dup()          -- ambiguous (Thing:dup / Other:dup) -> NO edge
    local z = t.zap  -- field READ, not a call -> NO edge
    return z
end

return M
