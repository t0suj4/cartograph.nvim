-- cartograph.prefilter — GENERAL PREFILTERING (USER, 2026-10-03: "I think we need a general prefiltering"): a SOUND
-- necessary condition derived from a TEMPLATE, checked on raw TEXT before anything is parsed.
--
-- ★ WHY IT IS SOUND, NOT A HEURISTIC: a lossless reader prints a term back to its source byte for byte
-- (algebraread's audited claim, `A.cst_print(read(src)) == src`), and an instance of T is T with its holes filled —
-- every FIXED leaf of T is a leaf of every instance, so its text is a substring of every instance's text, and of the
-- text of any file holding one. A file missing one fixed leaf cannot hold a match; nothing is guessed. (The ad-hoc
-- prefilters elsewhere — spec parent types, the C++ text prefilter, greenspun's index — are each one hand-written list;
-- a shortlist built by a heuristic has its blind spot exactly where the thing sought is unusual: CART-0933.)
--
-- WHAT IS NOT REQUIRED, each because some instance can lack it: a HOLE's subtree (filled by anything) — except a
-- PINNED hole, whose one value every instance carries; an OPTIONAL pair (`opt` under an aligned node: it may be absent);
-- anything under an EMBED boundary (an inner grammar's text can be ESCAPED inside the outer source); WHITESPACE leaves
-- (sound to require for today's exact matching, but useless as a filter and wrong the day matching ignores trivia).
-- A grammar whose reader is not proven lossless gets no filter (`lossless` false: everything passes).
local M = {}


--- the strings every instance of template T contains -> { string … } (deduplicated, longest first)
function M.tokens(T)
    local seen, out = {}, {}
    local function add(s)
        if type(s) == 'string' and s:find('%S') and not seen[s] then seen[s] = true; out[#out + 1] = s end
    end
    local function walk(t)
        if t.k == 'hole' then
            local d = T.holes and T.holes[t.h] and T.holes[t.h].domain
            if d and d.kind == 'closed' then walk(d.value) end
            return
        end
        if t.k == 'embed' then return end
        if t.k == 'lit' then add(t.v); return end
        for _, c in ipairs(t.kids or {}) do
            if not (t.align and c.opt) then walk(c) end
        end
    end
    walk(T.body or T)
    table.sort(out, function (x, y) if #x ~= #y then return #x > #y end return x < y end)
    return out
end

--- the ANCHORS of T: every fixed, non-whitespace leaf with its DEPTH below the template's root -> { { token, depth } … }.
--- ★ The depth is FIXED in every instance: the path from the root to a fixed leaf runs through fixed nodes only (no
--- hole above it), a repetition hole splices its hedge into the parent's children without a level of its own, and a
--- CONTEXT hole — the one hole that adds depth — keeps its subtree out of the anchors (as do optional pairs and embeds)
function M.anchors(T)
    local out = {}
    local function walk(t, depth)
        if t.k == 'hole' or t.k == 'embed' then return end
        if t.k == 'lit' then
            if type(t.v) == 'string' and t.v:find('%S') then out[#out + 1] = { token = t.v, depth = depth } end
            return
        end
        for _, c in ipairs(t.kids or {}) do
            if not (t.align and c.opt) then walk(c, depth + 1) end
        end
    end
    walk(T.body or T, 0)
    return out
end

--- POSITION-LEVEL PREFILTERING: the only positions of term t where T can match, given t's source text — every match
--- root has each anchor leaf exactly `depth` levels below it, so the candidates are, for the anchor whose token occurs
--- LEAST in the text (any anchor is sound; the rarest is the fewest), the ancestors at that distance of its occurrences.
--- -> { { path, node } … } in PRE-ORDER (A.positions' order and paths) | nil when T has no anchor (try every position)
function M.candidates(t, T, text)
    local best, count = nil, math.huge
    for _, an in ipairs(M.anchors(T)) do
        local n, at = 0, 1
        for _ = 1, #text do
            local s = text:find(an.token, at, true)
            if not s then at = nil end
            if at then n = n + 1; at = s + 1 end
        end
        if n < count then best, count = an, n end
    end
    if not best then return nil end
    local A = require('cartograph.algebra').load()
    -- ONE mutable stack of nodes, steps and kid indices; a path is copied only when a candidate is recorded
    local nodes, steps, idx, seen, out = {}, {}, {}, {}, {}
    local function walk(x)
        nodes[#nodes + 1] = x
        if x.k == 'lit' and x.v == best.token and #nodes > best.depth then
            local d = #nodes - best.depth -- (the root's place in the stack: its path is steps[1 .. d - 1])
            local ip = {}
            for j = 1, d - 1 do ip[j] = idx[j] end
            local key = table.concat(ip, ',')
            if not seen[key] then
                seen[key] = true
                local p = {}
                for j = 1, d - 1 do p[j] = steps[j] end
                out[#out + 1] = { node = nodes[d], path = p, ipath = ip }
            end
        end
        for i, c in ipairs(x.kids or {}) do
            steps[#steps + 1] = A.step(x, i)
            idx[#idx + 1] = i
            walk(c)
            steps[#steps] = nil
            idx[#idx] = nil
        end
        nodes[#nodes] = nil
    end
    walk(t)
    -- (pre-order = the kid INDEX paths in lexicographic order, a prefix before its extensions)
    table.sort(out, function (a, b)
        for i = 1, math.min(#a.ipath, #b.ipath) do if a.ipath[i] ~= b.ipath[i] then return a.ipath[i] < b.ipath[i] end end
        return #a.ipath < #b.ipath
    end)
    local res = {}
    for i, r in ipairs(out) do res[i] = { path = r.path, node = r.node } end
    return res
end

--- a text filter for template T -> function (text) -> admits (true when the text may hold a match), the tokens
--- opts.lossless = false: the reader is not proven lossless for this grammar — no filter, everything admitted
function M.text(T, opts)
    opts = opts or {}
    if opts.lossless == false then return function () return true end, {} end
    local toks = M.tokens(T)
    return function (text)
        for _, s in ipairs(toks) do if not text:find(s, 1, true) then return false end end
        return true
    end, toks
end

return M
