local M = {}

function M.pick(x)
  return x + 1
end

-- a GLOBAL, also defined in beta.lua; called BARE (roll(x)) in user.lua, so the
-- call is genuinely ambiguous: whichever file loads last owns the global. (It was
-- `M.roll` in both until CART-1487 — a bare call cannot reach a field function.)
function roll(n)
  return n
end

return M
