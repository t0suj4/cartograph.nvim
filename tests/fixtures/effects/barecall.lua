-- a bare call statement at load time (result discarded) -> side effect
local M = {}

print('cartograph: loaded barecall fixture')

function M.noop() end

return M
