-- ANNOTATIONS AS A TIER (CART-0240): a human's CLAIM about a type, read as one
-- neutral row shape whatever carrier it arrived in.
--
--     { kind = 'param'|'return'|'type'|'class'|'field'|'alias'|'vararg',
--       name = <what it is about, or nil>,       -- param/field/class/alias
--       type = <OPAQUE STRING>,                  -- nil for a bare @class
--       opt  = true|nil,                         -- `x?` / `string?`
--       parents = { … },                         -- @class Foo: A, B
--       line = <0-based>, carrier = 'comment' }
--
-- THREE THINGS THIS DELIBERATELY IS NOT:
--
-- 1. NOT A TYPE SYSTEM. The type is an opaque string with a tiny structured core
--    (nullability, and later "is this a name the graph knows"). Unions,
--    `fun(a: X): Y`, generics and @overload stay strings — the same refusal the
--    expression IR makes for a construct it cannot model. Modelling them is the
--    rabbit hole this ticket was written to avoid.
--
-- 2. NOT A FACT. An annotation is worth exactly what the comment is worth, so
--    every consumer must be able to say "by annotation" (uniform honesty). The
--    rows carry no authority of their own; whoever stores them assigns the tier.
--
-- 3. NOT A PARSER FOR "WHATEVER FOLLOWS @". The tag set is a WHITELIST, because
--    the fuel corpus (~/.local/share/nvim/lazy: 25k annotation lines) carries
--    436 @brief, 45 @toc, 39 @text and friends from nvim's own gen_vimdoc, which
--    are documentation and name no types at all. An unknown tag is IGNORED BY
--    NAME, never guessed at.
--
-- THE SEPARATOR IS THE REAL TRAP, and it is live in the wild:
--     ---@param char string @The input character.      (EmmyLua: @ ends the type)
--     ---@param char string The input character.       (LuaLS: no marker at all)
-- Both mean `string`. "Everything after the name" reads the first as
-- `string @The input character.` — so the type is SCANNED as one token, with
-- bracket nesting respected because `fun(a: string, b: number)` and
-- `table<integer, dap.bp>` contain spaces that DO belong to the type.

local M = {}

-- the tags that carry a type (or declare one). Everything else is prose.
M.TAGS = {
    param = 'param', ['return'] = 'return', type = 'type', class = 'class',
    field = 'field', alias = 'alias', vararg = 'vararg',
    -- the EmmyLua/JSDoc spelling of @return: marginal (55 lines in the fuel
    -- corpus) but free to accept, and silently dropping it would under-report
    returns = 'return',
}

-- @field's optional visibility word, which sits BEFORE the field name
local FIELD_SCOPE = { public = true, private = true, protected = true,
    package = true }

--- Scan ONE type off the front of `s`: up to the first unnested whitespace.
--- Whitespace inside (), <>, {} or [] belongs to the type. Returns (type, rest).
--- UNBALANCED brackets fall back to the plain first token — a prose comment that
--- happens to contain `<` must not swallow the line (`---@param n integer < 5`).
function M.scan_type(s)
    s = s:gsub('^%s+', '')
    if s == '' then return nil, '' end
    local depth, i, n = 0, 1, #s
    while i <= n do
        local ch = s:sub(i, i)
        if ch == '(' or ch == '<' or ch == '{' or ch == '[' then
            depth = depth + 1
        elseif ch == ')' or ch == '>' or ch == '}' or ch == ']' then
            depth = depth - 1
            if depth < 0 then break end -- a stray closer ends the type too
        elseif depth == 0 and ch:match('%s') then
            break
        end
        i = i + 1
    end
    if depth ~= 0 then
        local tok, rest = s:match('^(%S+)%s*(.*)$')
        return tok, rest or ''
    end
    return s:sub(1, i - 1), (s:sub(i + 1):gsub('^%s+', ''))
end

--- Split `s` on TOP-LEVEL occurrences of `sep` (brackets protect their contents).
local function split_top(s, sep)
    local out, depth, from = {}, 0, 1
    for i = 1, #s do
        local ch = s:sub(i, i)
        if ch:match('[%(<{%[]') then depth = depth + 1
        elseif ch:match('[%)>}%]]') then depth = depth - 1
        elseif ch == sep and depth == 0 then
            out[#out + 1] = s:sub(from, i - 1)
            from = i + 1
        end
    end
    out[#out + 1] = s:sub(from)
    return out
end

--- `X|nil` is LuaLS's OTHER SPELLING of `X?` — a nullability marker, not a union
--- to model, and it is the single most common shape in the fuel corpus (nio's
--- generated LSP client types are `Foo|nil` throughout). Collapsing it is a
--- spelling equivalence, which is not the same thing as modelling unions: a union
--- with two real members stays OPAQUE and its consumers refuse it.
local function denull_union(t)
    if not t or not t:find('|', 1, true) then return t, nil end
    local keep, hadnil = {}, false
    for _, p in ipairs(split_top(t, '|')) do
        p = p:gsub('^%s+', ''):gsub('%s+$', '')
        if p == 'nil' then hadnil = true
        elseif p ~= '' then keep[#keep + 1] = p end
    end
    if hadnil and #keep == 1 then return keep[1], true end
    return t, nil
end

--- Split the nullability marker off a type or a name: `string?` / `x?` / `X|nil`.
--- Declared BELOW denull_union deliberately: a `local function` is not in scope
--- inside a function defined above it, and reading one as a nil global is how a
--- guard ships silently disabled (CART-0234's fix nearly did).
local function nullable(t)
    if not t then return nil, nil end
    local base = t:match('^(.-)%?$')
    if base and base ~= '' then
        return (nullable(base)), true -- `X|nil?` occurs, harmlessly
    end
    local u, wasnil = denull_union(t)
    if wasnil then return u, true end
    return t, nil
end

--- A comma-separated multi-return (`---@return function?, string? msg`) is ONE
--- tag naming several values. We keep the FIRST and mark the row, rather than
--- inventing positions the row shape has no slot for.
local function first_of_list(t)
    if not t or not t:find(',', 1, true) then return t, nil end
    -- only a TOP-LEVEL comma splits: `table<integer, dap.bp>` is one type
    local parts = split_top(t, ',')
    if #parts < 2 then return t, nil end
    return parts[1], true
end

--- Parse ONE tag body (everything after `@tag`) into a row, or nil.
--- `kind` is the normalized tag name.
function M.parse_body(kind, body)
    body = body or ''
    if kind == 'param' or kind == 'field' then
        local rest = body
        if kind == 'field' then
            -- an optional visibility word precedes the name
            local w, tail = rest:match('^(%a+)%s+(.*)$')
            if w and FIELD_SCOPE[w] then rest = tail end
        end
        local name, tail = rest:match('^([%w_%.%[%]]+%??)%s*(.*)$')
        if not name then return nil end
        local nm, opt1 = nullable(name)
        local first, multi = first_of_list((M.scan_type(tail)))
        local t2, opt2 = nullable(first)
        return { kind = kind, name = nm, type = (t2 and t2 ~= '') and t2 or nil,
            opt = opt1 or opt2 or nil, multi = multi }
    elseif kind == 'return' or kind == 'type' or kind == 'vararg' then
        -- split the list FIRST: in `@return function?, string? msg` the `?`
        -- belongs to `function`, and stripping nullability before the comma is
        -- gone leaves the marker attached to a type that no longer ends the token
        local first, multi = first_of_list((M.scan_type(body)))
        local t2, opt = nullable(first)
        if not t2 or t2 == '' then return nil end
        return { kind = kind, type = t2, opt = opt, multi = multi }
    elseif kind == 'class' then
        -- `@class (exact) Foo: A, B`
        local rest = body:gsub('^%s*%b()%s*', '')
        local name, tail = rest:match('^([%w_%.%-]+)%s*(.*)$')
        if not name then return nil end
        local parents
        local sup = tail:match('^:%s*(.*)$')
        if sup then
            parents = {}
            for p in sup:gmatch('[%w_%.%-<>,%s]+') do
                p = p:gsub('^%s+', ''):gsub('%s+$', '')
                if p ~= '' then parents[#parents + 1] = p end
            end
            if #parents == 0 then parents = nil end
        end
        return { kind = 'class', name = name, parents = parents }
    elseif kind == 'alias' then
        local name, tail = body:match('^([%w_%.%-]+)%s*(.*)$')
        if not name then return nil end
        local ty = tail ~= '' and (M.scan_type(tail)) or nil
        return { kind = 'alias', name = name, type = ty }
    end
    return nil
end

--- Read every annotation row out of a COMMENT BLOCK.
--- `lines` = the block's lines in order, `first` = the 0-based line number of
--- lines[1]. `pat` = the language's tag-line pattern, capturing (tag, body).
function M.read_block(lines, first, pat)
    local rows = {}
    for i, l in ipairs(lines) do
        local tag, body = l:match(pat)
        local kind = tag and M.TAGS[tag]
        if kind then
            local r = M.parse_body(kind, body)
            if r then
                r.line = first + i - 1
                r.carrier = 'comment'
                rows[#rows + 1] = r
            end
        end
    end
    return rows
end

return M
