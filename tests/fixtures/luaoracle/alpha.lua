local M = {}

function M.pick(x)
  return x + 1
end

-- also defined in beta.lua; called BARE (roll(1)) in user.lua so the call is
-- genuinely ambiguous — no require-alias receiver for module-alias to narrow
function M.roll(n)
  return n
end

return M
