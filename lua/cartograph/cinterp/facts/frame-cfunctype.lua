-- FRAME as an argument array WITH ITS COUNT: a FUNCTION TYPE of the tree — `typedef R NAME(…);` or `typedef R
-- (*NAME)(…);` — whose parameters hold an integer COUNT beside a pointer to the very type it RETURNS: the registered C
-- function's signature (QuickJS' JSCFunction: `int argc, JSValue *argv`; CPython's fast call: `PyObject *const *args,
-- Py_ssize_t nargs`). The positions are the ones most such types share; the count is the element's own (TAG@count).
-- Where the tree's call path FILLS the array past the count — `for (i = <count>; i < <n>; i++) <buf>[i] = <constant>;`
-- — the slots past the count hold that constant (`pad`, its text), up to the registration's length.
local function split(list)
    local out, depth, cur = {}, 0, {}
    for c in list:sub(2, -2):gmatch('.') do
        if c == '(' then depth = depth + 1 elseif c == ')' then depth = depth - 1 end
        if c == ',' and depth == 0 then out[#out + 1] = vim.trim(table.concat(cur)); cur = {} else cur[#cur + 1] = c end
    end
    local last = vim.trim(table.concat(cur))
    if last ~= '' and last ~= 'void' then out[#out + 1] = last end
    return out
end

--- a parameter's text -> base type, pointer depth, name (nil when unnamed: `Py_ssize_t`, `unsigned int`)
local KW = { int = true, char = true, long = true, short = true, unsigned = true, signed = true, double = true, float = true, void = true, _Bool = true, bool = true }
local function param(p, tds)
    p = p:gsub('%f[%w_]const%f[^%w_]', ' '):gsub('%f[%w_]restrict%f[^%w_]', ' '):gsub('%f[%w_]struct%f[^%w_]', ' ')
    local stars = select(2, p:gsub('%*', ''))
    local words = {}
    for w in p:gmatch('[%w_]+') do words[#words + 1] = w end
    if #words == 0 then return nil end
    local name
    if #words >= 2 and not KW[words[#words]] and not (tds and tds[words[#words]]) then name = table.remove(words) end
    return words[#words], stars, name
end

return {
    fact = 'frame',
    needs = { 'sources', 'units' },
    summary = 'an argument array with its count, from a function type whose parameters are a count and an array of what it returns',
    split = split, param = param,
    derive = function (_, got)
        local CI = require 'cartograph.cinterp'
        local tds = got.units.typedefs
        local function integer(base) local t = base and CI.ctype(base, tds); return t and t.k == 'i' end
        local tally, seen = {}, {}
        for _, s in ipairs(got.sources.units) do
            for ret, rstars, name, plist in s.text:gmatch('typedef%s+([%w_]+)%s*(%**)%s*%(?%s*%*?%s*([%w_]+)%s*%)?%s*(%b())%s*;') do
                if not seen[name] then
                    seen[name] = true
                    local ps = split(plist)
                    for i = 1, #ps do
                        local b, st, nm = param(ps[i], tds)
                        if b == ret and st == #rstars + 1 then
                            for _, j in ipairs({ i - 1, i + 1 }) do
                                local cb, cst, cn = param(ps[j] or '', tds)
                                if cb and cst == 0 and integer(cb) then
                                    local key = i .. ':' .. j
                                    local t = tally[key] or { arrayat = i, countat = j, array = nm, count = cn, types = {}, slot = ret, n = 0 }
                                    t.n = t.n + 1
                                    t.types[#t.types + 1] = name
                                    t.array, t.count = t.array or nm, t.count or cn
                                    tally[key] = t
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
        local best
        for _, t in pairs(tally) do if not best or t.n > best.n or (t.n == best.n and t.arrayat < best.arrayat) then best = t end end
        if not best then return nil, 'no function type takes an integer count beside an array of the type it returns' end
        -- (the PADDING: a loop of the call path filling the array from the count on — a count variable of that name)
        local pad
        for _, s in ipairs(got.sources.units) do
            for i, from, buf, val in s.text:gmatch('for%s*%(%s*([%w_]+)%s*=%s*([%w_]+)%s*;%s*[%w_]+%s*<%s*[%w_]+%s*;[^)]*%)%s*([%w_]+)%s*%[%s*[%w_]+%s*%]%s*=%s*([^;]+);') do
                if from == best.count and not pad then pad = { text = vim.trim(val), buf = buf, unit = s.name } end
                local _ = i
            end
            if pad then break end
        end
        table.sort(best.types)
        return { kind = 'array', array = best.array, count = best.count, arrayat = best.arrayat, countat = best.countat, slot = best.slot, types = best.types, pad = pad }
    end,
}
