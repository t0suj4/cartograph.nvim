local M = {}
function M.guard(f) return pcall(function() return f() end) end
return M
