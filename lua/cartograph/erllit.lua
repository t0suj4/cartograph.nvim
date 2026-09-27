-- erllit — ERLANG TERM LITERALS AS PLAIN VALUES: a tree-sitter erlang node -> { t = atom | bin | int | list | tuple |
-- recterm | expr, … }. Nothing protocol-specific: rebar.config (erlfeatures, producers) and fxml_gen specs (xmppspec)
-- read their terms here. Split out of xmppspec (CART-1140), where generic readers had to require the XMPP module.
-- @langs erlang
local M = {}

local function unquote_atom(s)
    local q = s:match("^'(.*)'$")
    if not q then return s end
    return (q:gsub('\\(.)', '%1'))
end

--- an atom's text without its quotes ('a b' -> a b); a bare atom as it is
M.unquote_atom = unquote_atom

local function unquote_string(s)
    local q = s:match('^"(.*)"$')
    if not q then return nil end
    return (q:gsub('\\(.)', '%1'))
end

--- Any Erlang term literal as a plain value:
---   (the tags are TERM kinds, deliberately not grammar node-type names: a record term is 'recterm')
---   { t = 'atom', v = 'name' } · { t = 'bin', v = 'text' } (a `<<"…">>` of string segments) · { t = 'int', v = n }
---   { t = 'list', items } · { t = 'tuple', items } · { t = 'recterm', name, fields = { [k] = term }, keys = { k… } }
---   { t = 'expr' } for anything else (a call, a variable, a macro) — never dropped, its text is kept.
--- Every value carries `text` (the verbatim source) and `line` (1-based).
function M.term(node, src)
    local text = vim.treesitter.get_node_text(node, src)
    local out = { text = text, line = node:start() + 1 }
    local ty = node:type()
    if ty == 'atom' then
        out.t, out.v = 'atom', unquote_atom(text)
    elseif ty == 'integer' then
        out.t, out.v = 'int', tonumber((text:gsub('_', '')))
        if not out.v then out.t = 'expr' end
    elseif ty == 'binary' then
        local parts, okb = {}, true
        for _, be in ipairs(node:field('elements')) do
            local el = be:field('element')[1]
            local s = el and el:type() == 'string' and unquote_string(vim.treesitter.get_node_text(el, src))
            -- a sized or typed segment (`<<X:8>>`, `<<"a"/utf8>>`) is not a plain string literal
            if not s or be:named_child_count() ~= 1 then okb = false break end
            parts[#parts + 1] = s
        end
        if okb then out.t, out.v = 'bin', table.concat(parts) else out.t = 'expr' end
    elseif ty == 'list' then
        out.t, out.items = 'list', {}
        for _, e in ipairs(node:field('exprs')) do out.items[#out.items + 1] = M.term(e, src) end
        -- `[H | T]` has a tail field: not a proper list literal
        if node:field('tail')[1] then out.t = 'expr' end
    elseif ty == 'tuple' then
        out.t, out.items = 'tuple', {}
        for _, e in ipairs(node:field('expr')) do out.items[#out.items + 1] = M.term(e, src) end
    elseif ty == 'record_expr' then
        local rn = node:field('name')[1]
        local inner = rn and rn:field('name')[1]
        if inner and inner:type() == 'atom' then
            out.t, out.name, out.fields, out.keys = 'recterm', unquote_atom(vim.treesitter.get_node_text(inner, src)),
                {}, {}
            for _, rf in ipairs(node:field('fields')) do
                local k = rf:field('name')[1]
                local fe = rf:field('expr')[1]
                local v = fe and fe:field('expr')[1]
                if k and k:type() == 'atom' and v then
                    local key = unquote_atom(vim.treesitter.get_node_text(k, src))
                    out.fields[key] = M.term(v, src)
                    out.keys[#out.keys + 1] = key
                end
            end
        else
            out.t = 'expr'
        end
    else
        out.t = 'expr'
    end
    return out
end

return M
