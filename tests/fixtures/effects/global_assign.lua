-- assigns a global at load time -> side effect
cartograph_global_probe = { version = 1 }

local function helper() end
return helper
