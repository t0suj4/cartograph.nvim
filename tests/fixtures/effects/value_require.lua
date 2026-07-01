-- requires another module for its VALUE (bound to a local) and returns it.
-- A value require is not a bare call, so this stays pure -> no load-time effects.
local pure = require 'pure'

local M = {}
function M.sum(a, b)
    return pure.add(a, b)
end

return M
