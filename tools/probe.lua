-- probe — "walk a corpus and count that", as an INVOCATION instead of a file.
--
--   nvim --headless -u NONE -l tools/probe.lua <corpus|dir> --expr '<chunk>'
--   nvim --headless -u NONE -l tools/probe.lua <corpus|dir> --row  '<chunk>'
--   nvim --headless -u NONE -l tools/probe.lua <corpus|dir> --spec <file.lua>
--        [--fns N] [--top N]
--
-- ★★ WHY THIS EXISTS, MEASURED (CART-0758). One day of this arc wrote 41
-- throwaway probes totalling 1579 lines, against 188 lines of durable code
-- shipped — 8.4 : 1. TWELVE of the 41 shared ONE skeleton: bootstrap, extract a
-- corpus, ingest, iterate function/method nodes, expr.of, walk the rows, tally,
-- print. Each was rewritten from scratch.
--
-- ★★ AND THE LINE COUNT IS THE SMALLER HALF. SIX of them HAND-ROLLED A KID
-- DESCENT — `for _, key in ipairs({'b','i','f','l','r',…})` — while `expr.walk`,
-- the canonical walker, already existed and is exported twice. The hand-rolled
-- copy carried a bug: `ipairs({ e.a, e.kids })` iterates ZERO times when `e.a` is
-- nil, so it descended only `call` nodes and silently truncated every
-- measurement built on it (CART-0746 — jquery's `?` count was 1133 when the true
-- figure was 13272). A COPIED WALKER IS A COPIED BUG; this harness's real job is
-- to make the canonical one the path of least resistance.
--
-- ⚠ AND ITS OWN TEST IS ERGONOMIC, NOT FUNCTIONAL: if a rewritten probe is not
-- SHORTER than the throwaway it replaces, the shape is wrong and this should be
-- changed rather than worked around.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local here = repo .. '/tools/'
dofile(here .. 'bench.lua').bootstrap()

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local expr = require 'cartograph.expr'
local shortlist = require 'cartograph.shortlist'

local target, fns, top, spec = arg[1], 400, nil, {}
local i = 2
local function chunk(src, name)
    local f, err = load('return function (a, b, emit) ' .. src .. ' end', name)
    if not f then print(('bad --%s chunk: %s'):format(name, err)); os.exit(2) end
    return f()
end
while arg[i] do
    local a = arg[i]
    if a == '--fns' then fns = tonumber(arg[i + 1]); i = i + 2
    elseif a == '--top' then top = tonumber(arg[i + 1]); i = i + 2
    elseif a == '--expr' then spec.on_expr = chunk('local e = a ' .. arg[i + 1], 'expr'); i = i + 2
    elseif a == '--row' then spec.on_row = chunk('local row, node = a, b ' .. arg[i + 1], 'row'); i = i + 2
    elseif a == '--fn' then spec.on_fn = chunk('local node = a ' .. arg[i + 1], 'fn'); i = i + 2
    elseif a == '--spec' then
        local f = assert(loadfile(vim.fn.fnamemodify(arg[i + 1], ':p')))
        local s = f()
        for k, v in pairs(s) do spec[k] = v end
        i = i + 2
    else print('unknown argument: ' .. a); os.exit(2) end
end
if not target or not (spec.on_expr or spec.on_row or spec.on_fn) then
    print('usage: probe.lua <corpus|dir> --expr|--row|--fn <chunk> [--spec f] [--fns N] [--top N]')
    os.exit(2)
end
fns = spec.fns or fns

local reg = dofile(here .. 'corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) ~= 1 then print('not a directory: ' .. root); os.exit(2) end

local data = ts.extract(root, c and c.packs and { packs = c.packs } or nil)
store.ingest(data)

local counts, order = {}, {}
local function emit(key, n)
    key = tostring(key)
    if not counts[key] then order[#order + 1] = key end
    counts[key] = (counts[key] or 0) + (n or 1)
end

local seen, total = 0, 0
for _, n in ipairs(data.nodes) do
    if n.kind == 'function' or n.kind == 'method' then
        total = total + 1
        if seen < fns then
            local ok, eo = pcall(expr.of, store, n.id)
            if ok and eo and eo.fl then
                seen = seen + 1
                if spec.on_fn then spec.on_fn(n, eo, emit) end
                for _, r in ipairs(eo.fl.stmts or {}) do
                    if spec.on_row then spec.on_row(r, n, emit) end
                    -- ★ THE CANONICAL WALKER, not a copy. `expr.walk` knows every
                    -- kind that holds children — including `assign`, which three of
                    -- the four in-tree traversals were missing until CART-0743.
                    if spec.on_expr and r.expr then
                        for _, side in ipairs({ 'lhs', 'rhs' }) do
                            for _, e in ipairs(r.expr[side] or {}) do
                                expr.walk(e, function (x) spec.on_expr(x, r, emit) end)
                            end
                        end
                        expr.walk(r.expr.cond, function (x) spec.on_expr(x, r, emit) end)
                    end
                end
            end
        end
    end
end

table.sort(order, function (a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a < b                       -- total order, or the rank is not a fact
end)
local shown = top and math.min(top, #order) or #order
local rows = {}
for k = 1, shown do rows[#rows + 1] = { key = order[k], n = counts[order[k]] } end

-- ⚠ TWO INDEPENDENT TRUNCATIONS, and either one costs exhaustiveness: the
-- FUNCTION sample (`--fns`) and the COUNTER list (`--top`). Saying so is the
-- contract (CART-0755) — a reader must not take "the top 8 of a 400-function
-- sample" for a statement about the corpus.
local complete = (seen >= total and shown == #order)
    and shortlist.EXHAUSTIVE or shortlist.RANKED_OPEN
local list, why = shortlist.new{
    subject = 'probe counters over ' .. target,
    -- the scope reads INTO the header's "N of ...", so it names the key
    -- population and the sample that produced it in one phrase
    scope = ('%d distinct key(s) over %d of %d function/method nodes')
        :format(#order, seen, total),
    complete = complete, rows = rows,
}
if not list then print('shortlist refused: ' .. tostring(why)); os.exit(2) end
print(table.concat(list:render(function (r) return ('%-8d %s'):format(r.n, r.key) end), '\n'))
