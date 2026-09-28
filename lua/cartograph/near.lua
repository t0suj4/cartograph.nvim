-- cartograph.near — HOW CLOSE IS ONE NAME TO ANOTHER: the bounded edit distance under every "did you mean" (greenspun's
-- registry typos, the tactic runner's corrections — CART-1152). One copy, so a slip counts the same everywhere.
local M = {}

--- bounded Damerau-Levenshtein (optimal string alignment): a transposition counts 1 — 'on_tikc' is one slip from
--- 'on_tick', and that slip is THE typo. Returns cap + 1 as soon as the lengths alone exceed the cap.
function M.dist(a, b, cap)
    if math.abs(#a - #b) > cap then return cap + 1 end
    local prev2, prev = nil, {}
    for j = 0, #b do prev[j] = j end
    for i = 1, #a do
        local cur = { [0] = i }
        for j = 1, #b do
            local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
            cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if prev2 and i > 1 and j > 1
                and a:sub(i, i) == b:sub(j - 1, j - 1)
                and a:sub(i - 1, i - 1) == b:sub(j, j) then
                cur[j] = math.min(cur[j], prev2[j - 2] + 1)
            end
        end
        prev2, prev = prev, cur
    end
    return prev[#b]
end

--- the slip budget for a key: two edits from five characters up, one below (greenspun's rule, measured on registry keys)
function M.cap(key) return #key >= 5 and 2 or 1 end

--- EVERY member of `set` (a key-set or a list) within the cap of `key`, nearest first then by name: { { value, d } }.
--- ★ ALL of them, not the best: a tie is AMBIGUITY, and a caller that picks one hides the choice.
function M.within(key, set, cap)
    cap = cap or M.cap(key)
    local out = {}
    local function consider(k)
        if type(k) == 'string' and k ~= key then
            local d = M.dist(key, k, cap)
            if d <= cap then out[#out + 1] = { value = k, d = d } end
        end
    end
    if #set > 0 then for _, k in ipairs(set) do consider(k) end else for k in pairs(set) do consider(k) end end
    table.sort(out, function (x, y) if x.d ~= y.d then return x.d < y.d end return x.value < y.value end)
    return out
end

return M
