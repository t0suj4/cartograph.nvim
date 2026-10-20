-- HOST MODEL SOURCES (CART-1785 H2): where a runtime's host functions ARE Lua, its own source is the model — walked as
-- code, with no transcription. Per profile runtime: files relative to the profile's `sig_source` (the runtime the
-- profile was distilled from, so the model is that same version). A source the tree itself holds is the tree's, not a
-- model (the corpus IS the runtime). Scoped configuration: which of a runtime's files hold its pure, always-present core.
return {
    -- (vim/_core/shared.lua: "pure lua functions not depending of the state of the editor … always available whenever
    -- nvim-related lua code is run" — vim.split, vim.tbl_*, vim.deepcopy, vim.trim …)
    nvim = { 'lua/vim/_core/shared.lua' },
}
