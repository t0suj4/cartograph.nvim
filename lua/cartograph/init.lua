-- cartograph.nvim — a dependency/definition cockpit for navigating a codebase's
-- symbol graph and staging multi-file function moves. Early / experimental.
--
-- Public entry point. The real machinery lives behind three seams (see README):
-- a GraphProvider (data in), an ImpactEngine (transforms), and the pane/store UI.
-- None of those exist yet — this is the skeleton.

local M = {}

---@class cartograph.Config
local defaults = {}

---@param opts cartograph.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend('force', defaults, opts or {})
end

return M
