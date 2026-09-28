-- identity — THE LOSSLESS READER'S AUDIT over a corpus (plan step 6): for every file of a language (the graph's own
-- path -> parser rule), `cst_print(read(src)) == src` byte for byte, and every refusal counted BY REASON. A second
-- grammar is not a wider `@langs` line, it is this audit passing on real trees.
--
--   nvim --headless -u NONE -l tools/identity.lua <dir> <lang> [<lang> …]
-- Reads the tree only. Refusals are counted, not failures of the law: a file with an ERROR node is one tree-sitter
-- could not parse, and the reader refuses it by name rather than minting a term (the law is about what IS read).
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local R = require 'cartograph.algebraread'
local dir = assert(arg[1], 'usage: <dir> <lang>…')
for i = 2, #arg do
    local lang = arg[i]
    pcall(vim.treesitter.language.add, lang)
    local t0 = vim.uv.hrtime()
    local r = R.identity(vim.fn.fnamemodify(dir, ':p'):gsub('/$', ''), lang)
    local reasons, mism = {}, 0
    for _, b in ipairs(r.bad) do
        local why = tostring(b[2])
        if why:find('print(read', 1, true) then mism = mism + 1 end
        local k = why:match('^(does not parse)') or why:match('^(the tree is missing)') or why:match('(collides)') or why:sub(1, 40)
        reasons[k] = (reasons[k] or 0) + 1
    end
    local parts = {}
    for k, n in pairs(reasons) do parts[#parts + 1] = ('%s: %d'):format(k, n) end
    table.sort(parts)
    io.write(('%-11s %5d files %8.1f KB  identical %5d  refused %4d  PRINT MISMATCH %d  (%.1f s)%s\n'):format(lang, r.files,
        r.bytes / 1024, r.ok, #r.bad - mism, mism, (vim.uv.hrtime() - t0) / 1e9, #parts > 0 and ('\n            ' .. table.concat(parts, ' · ')) or ''))
    for _, b in ipairs(r.bad) do if tostring(b[2]):find('print(read', 1, true) then io.write('            MISMATCH ', b[1], '\n') end end
end