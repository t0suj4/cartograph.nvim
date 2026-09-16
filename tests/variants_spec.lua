-- tools/variants.lua — the concept-VARIANT finder (CART-0933).
--
-- ★★★ WHAT THESE TESTS PIN IS THE INVERSION, NOT A COUNT. The instrument's whole
-- claim is that the prefilter must require the query's COMMONEST row shapes and
-- NOT its rarest: a variant's defect is a MISSING piece of structure, so the rows
-- that make the complete implementation distinctive are exactly the ones the
-- incomplete one lacks. A test asserting "68 survivors" would pin a number that
-- moves with the tree; these assert the PROPERTY that made the number possible.
--
-- ⚠ THE FIXTURE IS SYNTHETIC ON PURPOSE. The measured run is over cartograph's own
-- lua/ (3087 functions -> 68 survivors, target ranked 42 of 67 at eeaa90c) and
-- takes minutes. A fixture reproduces the MECHANISM in under a second, and a
-- mechanism that needs a 3000-function corpus to demonstrate is one nobody can
-- debug.
--
-- ⚠ `M.index` CALLS `store.ingest`, so this spec replaces the process store, as
-- treesitter_spec's own fixtures do. Nothing here reads a store it did not build.

local variants = dofile(vim.fn.getcwd() .. '/tools/variants.lua')

local function has_parser(lang) return pcall(vim.treesitter.get_string_parser, '', lang) end

--- COMPLETE holds a row whose SHAPE the VARIANT lacks, which is what the prefilter
--- turns on. ⚠ NOT "the withdrawal loop" — that was my first story and it is false:
--- at skeleton grain `out[k] = nil` and `out[k] = true` collapse to one shape. What
--- matters is only that the query has a RARER shape the variant does not, which is
--- the general case (a shape is rare because most functions lack it). The NOISE
--- functions give the shape counts something to be counted against.
local function corpus()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local function w(rel, src)
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(src); fd:close()
    end
    w('complete.lua', [[
local M = {}
-- `resolve(...)` nests a call inside the loop head, giving this row a skeleton the
-- variant does not have. ⚠ WITHOUT IT THE FIXTURE DOES NOT EXPRESS THE MECHANISM:
-- at skeleton grain `out[k] = nil` and `out[k] = true` are the SAME shape, so a
-- bare withdrawal row is not distinctive and the variant survives rarest-first.
-- Measured that way round first; the fixture is built from the correction.
local function resolve(t) return t end
function M.complete(base, declared, withdrawn)
    local out = {}
    for k in pairs(base) do out[k] = true end
    for k in pairs(declared) do out[k] = true end
    for k in pairs(resolve(withdrawn)) do out[k] = nil end
    return out
end
return M
]])
    w('variant.lua', [[
local M = {}
function M.variant(base, declared)
    local out = {}
    for k in pairs(base) do out[k] = true end
    for k in pairs(declared) do out[k] = true end
    return out
end
return M
]])
    w('noise.lua', [[
local M = {}
function M.sum(xs)
    local n = 0
    for _, x in ipairs(xs) do n = n + x end
    return n
end
function M.greet(who)
    local s = 'hello ' .. who
    print(s)
    return s
end
function M.pick(t, key)
    local v = t[key]
    if v == nil then return nil end
    return v
end
function M.merge_list(a, b)
    local out = {}
    for _, x in ipairs(a) do out[#out + 1] = x end
    for _, x in ipairs(b) do out[#out + 1] = x end
    return out
end
return M
]])
    return root
end

local function run(order, k)
    local root = corpus()
    local r, why = variants.run(root, function (rec) return rec.name:find('complete') end,
        { k = k or 2, order = order })
    vim.fn.delete(root, 'rf')
    return r, why
end

local function names(list)
    local out = {}
    for _, r in ipairs(list) do out[#out + 1] = r.name end
    table.sort(out)
    return out
end

test('variants: the COMMONEST-first prefilter keeps the incomplete variant', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local r, why = run('commonest')
    ok(r, 'the pipeline ran: ' .. tostring(why))
    ok(r.total >= 4, 'the fixture indexed several functions: ' .. tostring(r.total))
    local kept = {}
    for _, s in ipairs(r.survivors) do kept[s.name] = true end
    local found
    for n in pairs(kept) do if n:find('variant') then found = n end end
    ok(found, 'the variant survives: kept ' .. table.concat(names(r.survivors), ' '))
    ok(#r.survivors < r.total, 'and the prefilter actually narrowed')
end)

--- ★★★★ THE TEST THAT CARRIES THE FINDING. A shape is RARE precisely because most
--- functions lack it — and the variant is one of the many that lack it. So requiring
--- the query's rare shapes excludes the variant. MEASURED on the real pair: the
--- query's three rarest shapes (df 4, 46, 154) are exactly the three the variant
--- does NOT hold, and its four commonest (157, 505, 1323, 2013) are exactly the four
--- it does — a monotone split. If this ever PASSES, either the fixture stopped
--- expressing the mechanism or someone made `rarest` the default; both need looking
--- at before this test is changed.
test('variants: the RAREST-first prefilter LOSES it — a variant lacks rare shapes',
    function ()
        if not has_parser('lua') then skip 'no lua parser' end
        local r = run('rarest')
        ok(r, 'the pipeline ran')
        local kept = {}
        for _, s in ipairs(r.survivors) do kept[s.name] = true end
        local found
        for n in pairs(kept) do if n:find('variant') then found = n end end
        ok(not found,
            'requiring the query\'s distinctive structure excludes the variant: kept '
            .. table.concat(names(r.survivors), ' '))
    end)

--- ★ THE PREFILTER MUST BE SOUND — it may over-approximate, never under. Every
--- survivor must hold every required shape; that is what "no false negatives"
--- rests on, and it is cheap to check directly rather than trust.
test('variants: every survivor holds every required shape', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local r = run('commonest')
    ok(#r.required > 0, 'some shapes were required')
    for _, s in ipairs(r.survivors) do
        for _, e in ipairs(r.required) do
            ok(s.shapes[e.k], ('%s is missing a required shape'):format(s.name))
        end
    end
end)

--- ★ A REFUSAL IS CARRIED AS nil, NOT 0 (CART-0937). Ranking callers that collapse
--- it rank declines alongside genuine mismatches.
test('variants: the ranker reports a refusal as nil, never as a zero score', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local r = run('commonest')
    for _, e in ipairs(r.scored) do
        if e.link ~= nil then
            ok(e.link > 0, 'a scored entry is a real score, not a stand-in zero')
        end
    end
    ok(true, 'no entry carried a zero masquerading as a score')
end)
