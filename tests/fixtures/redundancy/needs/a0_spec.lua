-- the FIRST unit: nothing anywhere sets the parser dir up before this
test('a0: needs cpp, and nothing sets it up first', function()
    if not pcall(vim.treesitter.get_string_parser, '', 'cpp') then return end   -- missing
end)
