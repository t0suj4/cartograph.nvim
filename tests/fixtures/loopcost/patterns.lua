-- loopcost fixture (CART-1057): what a search PATTERN adds to a string builtin's price.
local M = {}

-- (p1) the trim idiom on a parameter, per element: certified 2 + a BACKTRACK hole (degree 3, an upper bound)
function M.trim_each(xs, text)
    for _, x in ipairs(xs) do
        x.t = text:match('^%s*(.-)%s*$')
    end
end

-- (p2) a PLAIN find: no pattern, no hole
function M.plain_each(xs, text)
    for _, x in ipairs(xs) do
        x.at = text:find(x.needle, 1, true)
    end
end

-- (p3) an anchored single run of a class: degree 1, no hole
function M.digits_each(xs, text)
    for _, x in ipairs(xs) do
        x.ok = text:match('^%d+$')
    end
end

-- (p4) a pattern held in a variable: not known, a DYNAMIC hole
function M.dyn_each(xs, text, pat)
    for _, x in ipairs(xs) do
        x.m = string.match(text, pat)
    end
end

-- (p5) gmatch over an unanchored run: every start scans the spaces after it — degree 2
-- (a leading ^ in gmatch is a LITERAL character in 5.1/LuaJIT, not an anchor)
function M.words_each(xs, text)
    for _, x in ipairs(xs) do
        for w in text:gmatch('%s*x') do x.w = w end
    end
end

-- (p6) the same pattern on a BOUNDED subject (the loop binder, the current element): backtracking
-- multiplies the SUBJECT's length, so there is no hole and no finding
function M.trim_lines(lines)
    local out = {}
    for _, line in ipairs(lines) do
        out[#out + 1] = line:match('^%s*(.-)%s*$')
    end
    return out
end

-- (p7) a CHAINED receiver: `text:sub(1, 10)` is a call result of unknown size — a hole, not certified
function M.slice_each(xs, text)
    for _, x in ipairs(xs) do
        x.t = text:sub(1, 10):match('^%s*(.-)%s*$')
    end
end

-- (p8) a FIELD receiver is classed by its base name, as a loop head is: `cfg.path` of a param
function M.field_each(xs, cfg)
    for _, x in ipairs(xs) do
        x.base = cfg.path:match('([^/]+)$')
    end
end

return M
