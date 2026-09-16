-- membercensus — WHAT TEMPLATE DO A CORPUS'S CONTAINER MEMBERS SHARE, when the
-- members are gathered ACROSS containers rather than within one?
--
--   nvim --headless -u NONE -l tools/membercensus.lua <corpus|dir>
--        [--call NAME] [--group KEY] [--top N] [--min N]
--
-- ★★★ THE SELECTION IS THE MISSING PIECE, NOT THE ALGORITHM (CART-0949). Two
-- instruments already align things and NEITHER selects this population:
--   · the clone tiers align STATEMENT SEQUENCES inside one function body;
--   · `element_template` aligns the MEMBERS OF ONE CONTAINER.
-- Factorio's prototypes are neither. MEASURED on se: 171 of 293 `data:extend`
-- calls carry exactly ONE member, so `element_template` on any of them returns
-- "a single member is a shape, not yet a template" -- the repetition is ACROSS
-- calls, one prototype per statement, spread over 392 files. Gathering those
-- 1839 members and grouping them by their own `type` field is a selection
-- nothing shipped offers, and once made, the n-ary lgg needs no changes at all.
--
-- ⚠ AND IT IS WHY THE CLONE KEY WAS THE WRONG SUSPECT. CART-0949 was filed on
-- `expr.key` collapsing every table literal to `T`, which puts all
-- `data:extend{...}` rows over POST_CAP. Fixing that key would not help: 171
-- single-member containers in 171 separate statements give 171 DISTINCT row
-- keys under any structural key, no two identical, so the exact tier still finds
-- nothing and the near tier needs 6+ rows inside one function.
--
-- ⚠⚠ THE ACCESSOR. `A.generalize` returns
--     { template = { body, edits, holes }, values, env, notes }
-- and the TERM is `template.body`. Reading `.template` as the term reports
-- nodes=1 / rootk=nil for EVERY input, which reads exactly like "the lgg
-- degenerated to a bare hole" -- a clean, wrong, three-corpus finding. Nothing
-- in-tree documents it because `elemdrive` never renders the template.
--
-- ⚠⚠⚠ REPORT COVERAGE, NOT A HOLE COUNT. `generalize` hedges a differing-arity
-- child list unconditionally (`align` is `join`'s option, not its -- elemdrive's
-- header), so a heterogeneous group yields a HEADER plus one repetition hole
-- swallowing the body. That template has few holes and describes almost nothing.
-- se's recipes: 17 template nodes against a mean member of 110 = 15% covered,
-- hedged. Its item-subgroups: 13 against 13 = 98%, NOT hedged -- a complete
-- template over 120 members. The hole count is 5 and 3; the coverage is what
-- separates them.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local here = repo .. '/tools/'
dofile(here .. 'bench.lua').bootstrap()

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local expr = require 'cartograph.expr'
local alg = require 'cartograph.algebra'
local A = alg.load()

local target, callname, groupkey, top, minn = arg[1], 'extend', 'type', 12, 2
local i = 2
while arg[i] do
    local a = arg[i]
    if a == '--call' then callname = arg[i + 1]; i = i + 2
    elseif a == '--group' then groupkey = arg[i + 1]; i = i + 2
    elseif a == '--top' then top = tonumber(arg[i + 1]); i = i + 2
    elseif a == '--min' then minn = tonumber(arg[i + 1]); i = i + 2
    else print('unknown argument: ' .. a); os.exit(2) end
end
if not target then
    print('usage: membercensus.lua <corpus|dir> [--call NAME] [--group KEY]'
        .. ' [--top N] [--min N]')
    os.exit(2)
end

local reg = dofile(here .. 'corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) ~= 1 then print('not a directory: ' .. root); os.exit(2) end
local data = ts.extract(root, c and c.packs and { packs = c.packs } or nil)
store.ingest(data)

-- the group discriminator: a member's own `<groupkey> = "literal"` field.
-- ★ A MEMBER THAT IS NOT A CONTAINER IS NOT UNGROUPED, IT IS A DIFFERENT THING.
-- Counting every non-answer under one "untyped" label hid that 212 of se's 226
-- were `data:extend{ some_name }` -- a variable, not a literal prototype.
local function group_of(m)
    if m.k ~= 'table' then return nil, 'member is ' .. tostring(m.k) end
    for _, kid in ipairs(m.kids or {}) do
        if kid.k == 'pair' and kid.kids and kid.kids[1] and kid.kids[1].k == 'lit'
            and tostring(kid.kids[1].v) == groupkey then
            local v = kid.kids[2]
            if v and v.k == 'lit' then return tostring(v.v) end
            return nil, ('`%s` value is %s'):format(groupkey, tostring(v and v.k))
        end
    end
    return nil, ('no `%s` key'):format(groupkey)
end

local groups, skipped, ncalls, nmembers = {}, {}, 0, 0
local function harvest(e)
    expr.walk(e, function (x)
        if x.k ~= 'call' or not x.f then return end
        local nm = x.f.n
        if nm ~= callname then return end
        local a1 = (x.a or {})[1]
        if not (a1 and a1.k == 'table') then
            skipped['argument is ' .. tostring(a1 and a1.k)] =
                (skipped['argument is ' .. tostring(a1 and a1.k)] or 0) + 1
            return
        end
        ncalls = ncalls + 1
        for _, m in ipairs(a1.kids or {}) do
            nmembers = nmembers + 1
            local g, why = group_of(m)
            if g then groups[g] = groups[g] or {}; table.insert(groups[g], m)
            else skipped[why] = (skipped[why] or 0) + 1 end
        end
    end)
end

-- BOTH NODE POPULATIONS (CART-0946): a factorio data-stage file is almost
-- entirely module level, so walking functions alone sees nearly none of this
for _, n in ipairs(data.nodes) do
    local eo
    if n.kind == 'function' or n.kind == 'method' then
        local ok, r = pcall(expr.of, store, n.id); eo = ok and r or nil
    elseif n.kind == 'module' and not n.unparsed then
        local ok, r = pcall(expr.of_module, store, n.id); eo = ok and r or nil
    end
    if eo and eo.fl then
        for _, r in ipairs(eo.fl.stmts or {}) do
            if r.expr then
                for _, side in ipairs({ 'lhs', 'rhs' }) do
                    for _, e in ipairs(r.expr[side] or {}) do harvest(e) end
                end
                harvest(r.expr.cond)
            end
        end
    end
end

local function size(x)
    if type(x) ~= 'table' then return 0 end
    local n = 1
    for _, k in ipairs(x.kids or {}) do n = n + size(k) end
    return n
end
local function has_hedge(x)
    if type(x) ~= 'table' then return false end
    if x.k == 'hole' and x.rep then return true end
    for _, k in ipairs(x.kids or {}) do if has_hedge(k) then return true end end
    return false
end

local names = {}
for g in pairs(groups) do if #groups[g] >= minn then names[#names + 1] = g end end
table.sort(names, function (a, b) return #groups[a] > #groups[b] end)

print(('%s — %d `%s` call(s) with a container argument, %d member(s), %d group(s)'
    .. ' with n>=%d (grouped by `%s`)')
    :format(target, ncalls, callname, nmembers, #names, minn, groupkey))
print(('  %-24s %5s %6s %6s %6s %5s %-6s %s')
    :format('group', 'n', 'bound', 'tmplN', 'memN', 'cov', 'hedge', 'template'))
local complete, header = 0, 0
for k = 1, math.min(#names, top) do
    local g, ms = names[k], groups[names[k]]
    local terms, msize = {}, 0
    for _, m in ipairs(ms) do
        local tm = alg.term(m, {})
        if tm then terms[#terms + 1] = tm; msize = msize + size(tm) end
    end
    if #terms < 2 then
        print(('  %-24s %5d  (fewer than 2 buildable terms)'):format(g:sub(1, 24), #ms))
    else
        local ok, res = pcall(A.generalize, terms, { linear = true, align = 'none' })
        if not (ok and res and res.template) then
            print(('  %-24s %5d  generalize REFUSED: %s')
                :format(g:sub(1, 24), #ms, tostring(res)))
        else
            local body = res.template.body      -- ⚠ .body, not .template
            local tn = size(body)
            local mean = msize / #terms
            local cov = tn * 100 / math.max(1, mean)
            local hedge = has_hedge(body)
            if not hedge and cov >= 60 then complete = complete + 1 else header = header + 1 end
            local okS, sh = pcall(A.show, body)
            print(('  %-24s %5d %6d %6d %6.0f %4.0f%% %-6s %s'):format(
                g:sub(1, 24), #ms, #(res.values or {}), tn, mean, cov,
                tostring(hedge),
                okS and sh:gsub('%s+', ' '):sub(1, 54) or '<show failed>'))
        end
    end
end
print(('  ⇒ of the %d shown: %d COMPLETE templates (no hedge, >=60%% covered)'
    .. ', %d header-plus-hedge'):format(math.min(#names, top), complete, header))
if next(skipped) then
    print('  members that did not group, by cause:')
    local ks = {}
    for w in pairs(skipped) do ks[#ks + 1] = w end
    table.sort(ks, function (a, b) return skipped[a] > skipped[b] end)
    for _, w in ipairs(ks) do print(('     %-34s %5d'):format(w, skipped[w])) end
end
