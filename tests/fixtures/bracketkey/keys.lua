-- bracket keys, and the one that nearly fabricated a field name (CART-0533).
local t = {}
local function use(k)
    t.named = 1          -- a DOT member: the field is `named`
    t['lit'] = 2         -- a string-literal key: the field is `lit`
    t[k] = 3             -- a dynamic key: '[]', because the key is an expression
    t[''] = 4            -- ★ an EMPTY string literal. It has no content child, so
                         -- reading the node's own text would hand back the QUOTES,
                         -- and the un-quoted reading is the empty string — which is
                         -- the WHOLE-VAR sentinel. Either way a lie; the honest
                         -- answer is the dynamic one.
    return t
end
return use
