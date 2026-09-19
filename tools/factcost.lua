-- FACT COST: what a file's references RESOLVE to, as a histogram — the measurement
-- behind the extraction price (CART-0876/0878).
--
--   nvim --headless -u NONE -l tools/factcost.lua <file.lua> [<file.lua> ...]
--   nvim --headless -u NONE -l tools/factcost.lua --diff <before.lua> <after.lua>
--
-- ★★★ WHY A HISTOGRAM AND NOT A BINDING CHECK. The donor's own guard for a move is
-- BINDING PRESERVATION: resolve every free name before and after, and refuse if any
-- one ends somewhere new (~/tools/templates/experiments/resolve_census.lua §4). That
-- cannot see the failure this measures. An extraction that replaces `require('m').f`
-- with `require(mod)[fn]` changes what NO reference means — `require`, `live`,
-- `mat_df` all still resolve exactly as before. It makes six references STOP
-- EXISTING, because the algebra mints a module reference only for a string literal.
-- ⇒ A PER-REFERENCE EQUALITY CHECK IS BLIND TO A REFERENCE THAT WAS NEVER CREATED.
-- The class counts are not, and the census was already printing them beside the
-- number it compared.
--
-- ★★ AND IT IS A SECOND OPINION, NOT OUR OWN ANSWER REPEATED. This reads the algebra's
-- scope graph over the lossless reader's terms; `providers/treesitter` reads its own
-- IR and mints import edges. On commands/analysis.lua across the CART-0878 variants
-- the two agree exactly — module class 31 / 25 / 31, import edges 17 / 11 / 17 —
-- which is what makes either number worth quoting.
--
-- ⚠ IT IS A MEASUREMENT, NOT A CAPABILITY. It lives in tools/ for the reason the
-- absorption ledger states: an arrow used only from tools/ is a measurement. Nothing
-- shipped calls it; `clones.extract_proposal` carries the PRICE, derived
-- syntactically from the expression IR, and this is how that price was checked.
local repo = vim.fn.getcwd()
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local alg = require 'cartograph.algebra'
local A, why = alg.load()
if not A then print('the algebra is unavailable: ' .. tostring(why)); os.exit(2) end
local R = require 'cartograph.algebraread'

--- @return table|nil hist, number|nil refs, string|nil why
local function classify(path)
    local fd = io.open(path, 'rb')
    if not fd then return nil, nil, 'cannot read ' .. path end
    local src = fd:read('*a'); fd:close()
    local t, rwhy = R.read(src)
    if not t then return nil, nil, rwhy end
    local G = A.scope_graph()
    local okg, gwhy = pcall(A.lua_scope_graph, t, G, { file = path })
    if not okg then return nil, nil, 'scope graph: ' .. tostring(gwhy) end
    pcall(A.sg_link, G)
    local hist, n = {}, 0
    for id in pairs(G.refs) do
        local okr, T = pcall(A.resolve_through, G, id)
        local cls = okr and A.resolution_class(G, T) or 'ERROR'
        hist[cls] = (hist[cls] or 0) + 1
        n = n + 1
    end
    return hist, n
end

local function show(hist)
    local ks = {}
    for k in pairs(hist) do ks[#ks + 1] = k end
    table.sort(ks)
    local t = {}
    for _, k in ipairs(ks) do t[#t + 1] = ('%s=%d'):format(k, hist[k]) end
    return table.concat(t, ' ')
end

local args = {}
for i = 1, #arg do args[#args + 1] = arg[i] end
if #args == 0 then
    print('usage: tools/factcost.lua <file.lua> [...]  |  --diff <before> <after>')
    os.exit(1)
end

if args[1] == '--diff' then
    local a1, a2 = args[2], args[3]
    if not (a1 and a2) then print('--diff needs two files'); os.exit(1) end
    local h1, n1, w1 = classify(a1)
    local h2, n2, w2 = classify(a2)
    if not h1 then print('before: ' .. tostring(w1)); os.exit(2) end
    if not h2 then print('after: ' .. tostring(w2)); os.exit(2) end
    print(('before  refs=%-5d %s'):format(n1, show(h1)))
    print(('after   refs=%-5d %s'):format(n2, show(h2)))
    local keys, seen = {}, {}
    for k in pairs(h1) do if not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
    for k in pairs(h2) do if not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
    table.sort(keys)
    local lost = 0
    for _, k in ipairs(keys) do
        local d = (h2[k] or 0) - (h1[k] or 0)
        if d ~= 0 then
            print(('  %-12s %+d'):format(k, d))
            -- ⚠ ONLY THE RESOLVING CLASSES ARE A LOSS. `opaque` and `lexical` fall
            -- simply because duplicated code was removed, which is the POINT of an
            -- extraction; `module` and `field` falling means the resolver stopped
            -- seeing something it used to see.
            if (k == 'module' or k == 'field') and d < 0 then lost = lost - d end
        end
    end
    print(lost > 0
        and ('★ %d resolving reference(s) LOST — the extraction costs facts'):format(lost)
        or '✓ no resolving reference lost')
    os.exit(lost > 0 and 1 or 0)
end

for _, f in ipairs(args) do
    local h, n, w = classify(f)
    if h then print(('%-52s refs=%-5d %s'):format(f, n, show(h)))
    else print(('%-52s %s'):format(f, tostring(w))) end
end
