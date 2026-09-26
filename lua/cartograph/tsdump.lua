-- tsdump — print a tree-sitter parse WITH FIELD NAMES and ANONYMOUS TOKENS, and diff two builds of a grammar.
--
-- WHY IT EXISTS. The nvim 0.12 / nvim-treesitter main migration (CART-1087) broke six languages, and every one was
-- settled by the same throwaway script: parse a snippet, print the tree. TSNode:sexpr() is not enough — it drops the
-- anonymous tokens (Lua 5.5's `global` keyword, python's `except` `*`), and a field is only visible where it labels a
-- named child. Two of the tickets' stated tree shapes were WRONG until someone dumped the real one (the C++ requires
-- clause sat in an ERROR node, not inside the declarator; python has no `except*` token, it has `except` then `*`).
-- And the decisive move twice was comparing the SAME snippet under the OLD and the NEW parser build (bob keeps the
-- previous nvim's bundled parsers), which no tool did.
--
--   M.lines(src, lang, opts)   -> { "field: type [text]", ... } indented; opts.anon (default true) shows anonymous
--                                 tokens, opts.parser = path to a parser .so to use instead of the runtimepath one,
--                                 opts.view = parse the luadialect view (lua: `global` masked for pre-5.5 dialects)
--   M.diff(src, lang, a, b)    -> a unified diff of the dumps under two parser builds (paths, nil = runtimepath)
local M = {}

local seq = 0
-- a parser .so registered under a fresh name, so two builds of one grammar can be loaded side by side
local function lang_for(lang, path)
    if not path then return lang end
    seq = seq + 1
    local alias = ('tsdump_%s_%d'):format(lang, seq)
    vim.treesitter.language.add(alias, { path = path, symbol_name = lang })
    return alias
end

local function short(s, n)
    s = s:gsub('\n', '\\n')
    if #s > n then s = s:sub(1, n - 3) .. '...' end
    return s
end

function M.lines(src, lang, opts)
    opts = opts or {}
    local anon = opts.anon ~= false
    local bytes = src
    if opts.view then bytes = require('cartograph.luadialect').view(src, lang, opts.dialect) end
    local plang = lang_for(lang, opts.parser)
    local root = vim.treesitter.get_string_parser(bytes, plang):parse()[1]:root()
    local out = {}
    local function walk(node, field, depth)
        local named = node:named()
        if named or anon then
            local t = node:type()
            local label = named and t or ('"' .. t .. '"')
            if node:missing() then label = 'MISSING ' .. label end
            local line = string.rep('  ', depth) .. (field and (field .. ': ') or '') .. label
            -- leaves show their text (read from the ORIGINAL bytes, as every cartograph consumer does)
            if node:named_child_count() == 0 and named and not node:missing() then
                line = line .. ' [' .. short(vim.treesitter.get_node_text(node, src), 40) .. ']'
            end
            out[#out + 1] = line
        end
        for child, fname in node:iter_children() do
            walk(child, fname, (named or anon) and depth + 1 or depth)
        end
    end
    walk(root, nil, 0)
    if root:has_error() then table.insert(out, 1, '-- has_error') end
    return out
end

function M.diff(src, lang, a, b, opts)
    local la = M.lines(src, lang, vim.tbl_extend('force', opts or {}, { parser = a }))
    local lb = M.lines(src, lang, vim.tbl_extend('force', opts or {}, { parser = b }))
    local ta, tb = table.concat(la, '\n') .. '\n', table.concat(lb, '\n') .. '\n'
    if ta == tb then return '' end
    return vim.diff(ta, tb, { ctxlen = 2 })
end

return M
