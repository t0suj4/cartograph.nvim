local M = {}
function M.run(xs) return pcall(function() return #xs end) end
function M.each(xs) return vim.tbl_map(function(x) return x end, xs) end
return M
