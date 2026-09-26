-- THE PARSE VIEW: the bytes a grammar is handed for a source, when the grammar misreads valid code in that language.
-- @langs lua scheme cpp
--
-- One lever, TSGAP's lever 1 (a pre-lex normalization): a LENGTH-PRESERVING rewrite that the grammar parses correctly,
-- while every consumer keeps reading node TEXT from the original bytes, so names and ranges are the file's own. It is
-- only sound where the rewrite cannot change meaning, which is why each view below states its argument.
--   lua     luadialect.view: a pre-5.5 root has no `global` keyword, so `global` -> `_lobal` (TSGAP-0012)
--   scheme  a symbol that starts with `@` (Guile's module references `(@ (m) f)` / `(@@ (m) f)`, and `@prompt`,
--           `@apply`, ...) is REJECTED by the tree-sitter-scheme nvim 0.12 installs: ONE of them turned the whole of
--           language/tree-il.scm (726 lines) into an ERROR node and hid every definition in it; 55 of guile's 280
--           module files use them. `@` -> `_` at a symbol START parses as an ordinary symbol, and reading the text from
--           the original bytes gives the name back. `,@` / `#,@` (unquote-splicing) are grammar syntax and untouched.
--   cpp     a DEFAULTED or DELETED special member at namespace scope, `X::X() = default;` / `void f(int) = delete;`,
--           is misread by the tree-sitter-cpp nvim 0.12 installs: `= default` becomes an assignment_expression (the
--           definition is gone: colobot lost two ctors/dtors, v8 ~96 lines) and `= delete` a delete_expression that
--           SWALLOWS THE NEXT DECLARATION. Only THOSE spans become `{}` padded to the same length (a definition with an
--           empty body, which is what a defaulted function is to a call graph). ★ THE VIEW IS TREE-AWARE, NOT A REGEX:
--           the same text INSIDE a class body parses correctly (a method with a default/delete clause), and `{}` there
--           turns `X& operator=(const X&) = delete;` into a brace-initialised FIELD: the first cut was a regex and lost 16
--           methods on colobot. So the file is parsed once, the misread shapes are found at namespace scope, and only
--           their bytes change. `= 0;` (pure virtual) is never touched.
-- Every parse site routes through M.view: providers/treesitter.lua M.parse_view, and the analysis re-parses (expr,
-- lens, write verbs, lints) that used to call luadialect.view directly.
local M = {}

-- a guile EXTENDED symbol `#{any text}#` (psyntax, the elisp compiler, autofrisk's 13-line one) is rejected too, and
-- one of them turned scripts/autofrisk.scm into a single ERROR: every character between `#{` and `}#` (the delimiters
-- included) becomes `_` except newlines, so line positions hold. It is a quoted literal, so the few symbols it becomes
-- mean nothing; text is still read from the original bytes.
local function mask_extended(src)
    if not src:find('#{', 1, true) then return src end
    local out, i = {}, 1
    while true do
        local a = src:find('#{', i, true)
        local b = a and src:find('}#', a + 2, true)
        if not b then break end
        out[#out + 1] = src:sub(i, a - 1)
        out[#out + 1] = (src:sub(a, b + 1):gsub('[^\n]', '_'))
        i = b + 2
    end
    out[#out + 1] = src:sub(i)
    return table.concat(out)
end

local function scheme_view(src)
    src = mask_extended(src)
    if not src:find('@', 1, true) then return src end
    -- a symbol STARTS after an opening paren/bracket, whitespace, or a quote; `,@` and `#,@` are preceded by `,`
    -- the whole RUN: `@@` (a private module reference) is one symbol start, both characters masked
    return (src:gsub('([%(%[%s\'`])(@+)', function (pre, ats) return pre .. string.rep('_', #ats) end))
end

-- the misread shapes, looked for only where the grammar misreads them: at namespace scope (a class or function body
-- is never entered). Each yields the byte span [s, e) from the `=` through the keyword.
local CPP_NO_DESCEND = { field_declaration_list = true, compound_statement = true }
-- the cpp node types the two misread shapes are made of, tabled (this module also speaks lua and scheme)
local CPP_ASSIGN = { assignment_expression = true }
local CPP_CALL = { call_expression = true }
local CPP_FDECL = { function_declarator = true }
local CPP_DELETE = { delete_expression = true }
local function cpp_misreads(root, src)
    local spans = {}
    local function kw_span(eq, kw)
        if eq and kw then
            local _, _, s = eq:start()
            local _, _, e = kw:end_()
            spans[#spans + 1] = { s, e }
        end
    end
    local function walk(n)
        local t = n:type()
        if t == 'expression_statement' then
            -- `X::X() = default;` -> (expression_statement (assignment_expression left: (call_expression) right: default))
            local a = n:named_child(0)
            local r = a and CPP_ASSIGN[a:type()] and a:field('right')[1]
            local l = a and a:field('left')[1]
            if r and l and CPP_CALL[l:type()] and vim.treesitter.get_node_text(r, src) == 'default' then
                local eq
                for c in a:iter_children() do if not c:named() and c:type() == '=' then eq = c end end
                kw_span(eq, r)
            end
            return
        end
        if t == 'init_declarator' then
            -- `void f(int) = delete;` -> (init_declarator declarator: (function_declarator) value: (delete_expression ...))
            local d, v = n:field('declarator')[1], n:field('value')[1]
            if d and v and CPP_FDECL[d:type()] and CPP_DELETE[v:type()] then
                local eq, kw
                for c in n:iter_children() do if not c:named() and c:type() == '=' then eq = c end end
                for c in v:iter_children() do if not c:named() and c:type() == 'delete' then kw = c; break end end
                kw_span(eq, kw)
            end
            return
        end
        if CPP_NO_DESCEND[t] then return end
        for c in n:iter_children() do if c:named() then walk(c) end end
    end
    walk(root)
    return spans
end

-- apply the spans of one pass
local function cpp_mask(src, spans)
    table.sort(spans, function (x, y) return x[1] < y[1] end)
    local out, i = {}, 1
    for _, sp in ipairs(spans) do
        local s, e = sp[1] + 1, sp[2] -- 1-based inclusive
        local seg = src:sub(s, e)
        -- `{` + the whitespace as written (newlines stay) + `}` + spaces to the keyword's length
        local ws = seg:match('^=(%s*)')
        out[#out + 1] = src:sub(i, s - 1)
        out[#out + 1] = '{' .. ws .. '}' .. string.rep(' ', #seg - #ws - 2)
        i = e + 1
    end
    out[#out + 1] = src:sub(i)
    return table.concat(out)
end

-- ★ TO A FIXED POINT, because the misread is CONTEXT-DEPENDENT: `A::A() = default;` parses correctly at the top of a
-- file and as an assignment after a class, and a swallowing `= delete` hides the misread after it inside its own
-- ERROR, so it only shows once the delete is masked. Each pass masks at least one span or stops; the bound is a guard.
local function cpp_view(src)
    if not (src:find('=%s*default%s*;') or src:find('=%s*delete%s*;')) then return src end
    local v = src
    for _ = 1, 8 do
        local ok, parser = pcall(vim.treesitter.get_string_parser, v, 'cpp')
        local tree = ok and parser:parse()[1]
        if not tree then return v end
        local spans = cpp_misreads(tree:root(), v)
        if #spans == 0 then return v end
        v = cpp_mask(v, spans)
    end
    return v
end

local VIEWS = {
    lua = function (src, v) return require('cartograph.luadialect').view(src, 'lua', v) end,
    scheme = scheme_view,
    cpp = cpp_view,
}

--- The bytes to PARSE for `src` in `lang` (identity for every language without a view). `v` is lua's dialect override.
function M.view(src, lang, v)
    local f = type(src) == 'string' and VIEWS[lang]
    if not f then return src end
    return f(src, v)
end

--- The languages that have a view (for a test that asserts one did not silently stop existing).
function M.languages()
    local out = {}
    for k in pairs(VIEWS) do out[#out + 1] = k end
    table.sort(out)
    return out
end

return M
