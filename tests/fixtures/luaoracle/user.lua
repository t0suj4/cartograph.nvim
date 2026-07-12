local a = require 'alpha'

-- module-alias: `a` is require('alpha'), so a.pick resolves to ALPHA's M.pick
-- (inferred ~), which the lua-ls oracle then upgrades to solid.
local function choose()
  return a.pick(3)
end

-- BARE call to a doubly-defined name: genuinely ambiguous (no require-alias
-- receiver), so it stays refused — the refusal-as-a-place / ladder contract.
local function guess(x)
  return roll(x)
end

return choose, guess
