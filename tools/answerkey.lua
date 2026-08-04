-- THE ANSWER-KEY LOOP (CART-0265, step 4 and the last leaf of the CART-0260 arc).
--
--   nvim --headless -u NONE -l tools/answerkey.lua <corpus|path> [--show N] [--cap N]
--
-- THE ARC POINTS BACK AT THE ANALYZER. Every step so far ASKED questions: what is unknown about
-- this function, what does the environment supply, what does this condition decide. This step
-- turns the answers around and uses them to GRADE US — because a recorded run is the strongest
-- tier there is, and every weaker tier made a claim about the same thing.
--
--   OUR CLAIM                          THE ANSWER KEY
--   `---@return string`                the TYPE of the value the run actually returned
--   `---@param n number`               the type of the literal a real call site passes
--   effects.purity says `pure`         the effect log a sandboxed run recorded
--
-- A DISAGREEMENT IS A BUG ON ONE SIDE, AND THIS TOOL DOES NOT SAY WHICH. CART-0240 shipped
-- `annotation-mismatch` precisely because docblocks lie, so a clash between an annotation and a
-- run may be a stale comment — or our analysis may be wrong. Both are findings; asserting which
-- would be inventing evidence, and the whole ladder exists to avoid that. What the tool does is
-- RANK them, because a claim contradicted 40 times is a different problem from one contradicted
-- once.
--
-- ── THE HONEST PART: THIS GRADES A SUBSET, AND SAYS WHICH ────────────────────
-- An answer key only exists where a function could be RUN, which is the population with concrete
-- inputs. That is a SMALL minority — measured on `self`: 3.7% emittable through the emitter's full
-- hole set, 3.2% RUNNABLE, against the census's 18.0% headline (see the three populations below).
-- So the coverage is REPORTED, not implied.
-- A survey that graded 3% of a corpus and printed a percentage without saying so would be the
-- most confident number in the repo and the least meaningful.
--
-- AND THE ASYMMETRY MATTERS. "purity says io, the log is empty" is an OVER-approximation: sound,
-- imprecise, expected, and NOT a bug. "purity says pure, the log shows io.open" is UNSOUND — the
-- analysis missed a channel. Reporting those as one number would bury the only half that is a
-- defect, so they are separate rows with separate names.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local ch = require 'cartograph.characterize'
local ro = require 'cartograph.runoracle'
local annot = require 'cartograph.annot'
local effects = require 'cartograph.effects'
local txn = require 'cartograph.txn'
local at = require 'cartograph.at'

local target = arg[1]
local show, cap = 12, 400
for i = 1, #(arg or {}) do
    if arg[i] == '--show' then show = tonumber(arg[i + 1]) or show end
    if arg[i] == '--cap' then cap = tonumber(arg[i + 1]) or cap end
end
if not target then
    print('usage: tools/answerkey.lua <corpus|path> [--show N] [--cap N]')
    os.exit(2)
end
local reg = dofile(here .. '/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) == 0 then print('not a directory: ' .. root); os.exit(2) end
local data = ts.extract(root)
data.root = data.root or root
store.ingest(data)

--- The declared @return / @param types of a function, from the docblock above it.
local function declared(node, lines, pat, pats)
    if not (pat and lines) then return nil end
    local s0 = at.sl(node.range)
    local first = txn.attach_above(lines, s0, pats)
    if not first or first >= s0 then return nil end
    local rows = annot.read_block(lines, first, pat)
    if not rows or #rows == 0 then return nil end
    local out = { params = {}, rets = {} }
    for _, r in ipairs(rows) do
        if r.kind == 'param' and r.name then out.params[r.name] = r.type
        elseif r.kind == 'return' then out.rets[#out.rets + 1] = r.type end
    end
    return out
end

--- Does a Lua source literal LOOK like the declared type? A deliberately COARSE check: the
--- declared type is an opaque string (annot.lua models unions and generics as text, on purpose),
--- so anything beyond "does the obvious case agree" would be inventing a type system. A type we
--- cannot read yields `nil` = NO OPINION, never a disagreement — the difference between "we
--- checked and it clashes" and "we could not check" is the whole value of the row.
local function agrees(decl, src)
    if not (decl and src) then return nil end
    local d = decl:lower():gsub('%s', '')
    if d:find('|') or d:find('%?') or d:find('<') or d:find('fun%(') then return nil end
    local kind
    if src:match('^%-?%d+$') or src:match('^%-?%d*%.%d+$') then kind = 'number'
    elseif src:match('^".*"$') or src:match("^'.*'$") then kind = 'string'
    elseif src == 'true' or src == 'false' then kind = 'boolean'
    elseif src == 'nil' then kind = 'nil'
    elseif src:match('^{') then kind = 'table'
    else return nil end
    if d == 'any' or d == 'unknown' then return nil end
    if d == kind then return true end
    -- integer/number are the same runtime type in Lua; a declared `integer` met by 3 agrees
    if (d == 'integer' or d == 'number') and kind == 'number' then return true end
    return false, kind
end

local FN = {}
for _, n in ipairs(store.data.nodes or {}) do
    if n.kind == 'function' and n.file and n.file:match('%.lua$') and n.range then
        FN[#FN + 1] = n
    end
end

-- THREE POPULATIONS, AND THEY ARE NOT THE SAME NUMBER — which is this tool's first finding and
-- a good one, since step 4 of the arc exists to grade the earlier steps:
--   census EMITTABLE   no blocking hole among the kinds tools/holecensus knows (input, oracle,
--                      dependency, fixture). Reported as 18.0% on `self`.
--   emitter EMITTABLE  no blocking hole among the kinds the EMITTER adds too — reach, load, env,
--                      inspect. Measured 3.7%.
--   RUNNABLE           every hole carries a VALUE, which is what "we can generate and run a spec"
--                      actually means. Measured 3.2%.
-- The census's headline is not wrong about what it measures; it is stale about what an emittable
-- function NEEDS, because the emitter learned four more hole kinds after that number was set. A
-- TIER is not a VALUE: an `@param number` makes a hole non-blocking and supplies nothing to call
-- the function with.
local stat = { total = #FN, tried = 0, ran = 0, norun = {}, emit = 0, runnable = 0 }
local rows = { ret = {}, param = {}, unsound = {}, over = {} }
local function bump(list, key, ex)
    local e = list[key]
    if not e then e = { n = 0, ex = {} }; list[key] = e end
    e.n = e.n + 1
    if #e.ex < 3 then e.ex[#e.ex + 1] = ex end
end

for i = 1, math.min(cap, #FN) do
    local node = FN[i]
    stat.tried = stat.tried + 1
    local lines = store.content(node)
    local plan = select(1, ch.plan(store, node.id))
    if plan then
        -- ONLY WHAT ALREADY HAS ITS INPUTS. We do not invent a value to grade ourselves with:
        -- an answer key built on a guessed input grades the guess.
        local holes = require 'cartograph.holes'
        local blocking, unblocking = 0, 0
        for _, h in ipairs(plan.holes) do
            if h.kind ~= 'oracle' and h.kind ~= 'effects' and not (h.value or h.satisfied_by) then
                blocking = blocking + 1
            end
            if holes.blocking(h) then unblocking = unblocking + 1 end
        end
        if unblocking == 0 then stat.emit = stat.emit + 1 end
        if blocking == 0 then stat.runnable = stat.runnable + 1 end
        if blocking > 0 then
            stat.norun.holes = (stat.norun.holes or 0) + 1
        else
            local okr, why = ro.fill_oracle(store, plan, {})
            if not okr then
                local k = tostring(why):gsub('%s+', ' '):sub(1, 46)
                stat.norun[k] = (stat.norun[k] or 0) + 1
            else
                stat.ran = stat.ran + 1
                local ret, eff
                for _, h in ipairs(plan.holes) do
                    if h.kind == 'oracle' then ret = h end
                    if h.kind == 'effects' then eff = h end
                end
                local pat = ts.annot_tag and ts.annot_tag(node.file)
                local pats = ts.attach_pats and ts.attach_pats(node.file)
                local d = declared(node, lines, pat, pats)

                -- 1. THE DECLARED RETURN vs THE OBSERVED ONE
                if d and d.rets[1] and ret and ret.raw_value then
                    local ok, got = agrees(d.rets[1], ret.raw_value)
                    if ok == false then
                        bump(rows.ret, ('@return %s but returned %s'):format(d.rets[1], got),
                            ('%s (%s) -> %s'):format(node.name, node.file,
                                ret.raw_value:sub(1, 24)))
                    end
                end

                -- 2. THE DECLARED PARAM vs THE VALUE A REAL CALL SITE PASSES (measured tier only:
                --    an agent-supplied or asserted value grades nothing but itself)
                for _, h in ipairs(plan.holes) do
                    if h.kind == 'input' and h.value and h.by == 'observed'
                        and d and d.params[h.name] then
                        local ok, got = agrees(d.params[h.name], h.value)
                        if ok == false then
                            bump(rows.param, ('@param %s %s but a call site passes %s'):format(
                                h.name, d.params[h.name], got),
                                ('%s (%s)'):format(node.name, node.file))
                        end
                    end
                end

                -- 3. THE PURITY LABEL vs THE EFFECT LOG — and the two directions are DIFFERENT
                --    findings, so they are different rows.
                local label = effects.purity and effects.purity(store, node.id)
                local logged = eff and eff.value and eff.value ~= '""' and eff.value ~= '"'
                if label then
                    local bare = label:gsub('~$', '')
                    if bare == 'pure' and logged then
                        -- UNSOUND: we said pure and the run touched the world.
                        bump(rows.unsound, ('purity says %s but the run logged effects'):format(
                            label), ('%s (%s) %s'):format(node.name, node.file,
                            tostring(eff.value):sub(1, 40)))
                    elseif bare == 'io' and not logged then
                        -- OVER-APPROXIMATION: sound, imprecise, expected. Not a bug.
                        bump(rows.over, ('purity says %s but the run logged nothing'):format(
                            label), ('%s (%s)'):format(node.name, node.file))
                    end
                end
            end
        end
    else
        stat.norun.plan = (stat.norun.plan or 0) + 1
    end
end

local function dump(title, list, note)
    local ks = {}
    for k, v in pairs(list) do ks[#ks + 1] = { k = k, n = v.n, ex = v.ex } end
    table.sort(ks, function (a, b) if a.n ~= b.n then return a.n > b.n end return a.k < b.k end)
    local tot = 0
    for _, e in ipairs(ks) do tot = tot + e.n end
    print('')
    print(('  %s — %d finding(s) over %d distinct claim(s)'):format(title, tot, #ks))
    if note then print('    ' .. note) end
    for i = 1, math.min(show, #ks) do
        print(('    %4d  %s'):format(ks[i].n, ks[i].k))
        for _, ex in ipairs(ks[i].ex) do print(('            %s'):format(ex)) end
    end
    if #ks > show then print(('    … %d more distinct'):format(#ks - show)) end
    return tot
end

print(('answerkey %s — %s'):format(target, root))
print(('  %d lua function(s); %d tried (cap %d); %d RAN'):format(stat.total, stat.tried, cap,
    stat.ran))
-- THE COVERAGE IS THE FIRST NUMBER, not a footnote: an answer key exists only where a function
-- could be run, and a survey that graded 3% while printing a percentage would be the most
-- confident and least meaningful number here.
print(('  COVERAGE: %.1f%% of the functions tried could be graded at all'):format(
    stat.tried > 0 and 100 * stat.ran / stat.tried or 0))
-- BOTH POPULATIONS, so the gap between "we know something about every hole" and "we can run it"
-- is visible rather than collapsed into one word.
print(('  EMITTABLE (no blocking hole, the emitter\'s full hole set): %d (%.1f%%)'):format(
    stat.emit, stat.tried > 0 and 100 * stat.emit / stat.tried or 0))
print(('  RUNNABLE  (every hole carries a VALUE):                    %d (%.1f%%)'):format(
    stat.runnable, stat.tried > 0 and 100 * stat.runnable / stat.tried or 0))
print('  a TIER is not a VALUE: an `@param number` makes a hole non-blocking and gives us')
print('  nothing to call the function with, so those two numbers must not share a word.')
local nr = {}
for k, v in pairs(stat.norun) do nr[#nr + 1] = { k = k, n = v } end
table.sort(nr, function (a, b) return a.n > b.n end)
print('  why the rest could not be graded:')
for i = 1, math.min(6, #nr) do print(('    %5d  %s'):format(nr[i].n, nr[i].k)) end

local a = dump('ANNOTATION vs OBSERVED RETURN', rows.ret,
    'a bug on ONE side: the docblock may be stale (CART-0240 exists because they lie) or we ran'
    .. ' it wrong. This does not say which.')
local b = dump('ANNOTATION vs A REAL CALL SITE\'S ARGUMENT', rows.param,
    'measured-tier inputs only — an agent-supplied value grades nothing but itself.')
local u = dump('UNSOUND PURITY (we said pure, the run had effects)', rows.unsound,
    'THE DEFECT DIRECTION: the effect analysis missed a channel.')
local o = dump('OVER-APPROXIMATED PURITY (we said io, the run had none)', rows.over,
    'sound and imprecise, which is the SAFE direction — reported separately so it cannot bury'
    .. ' the row above.')
print('')
print(('  TOTALS: %d annotation-vs-return, %d annotation-vs-argument, %d UNSOUND, %d'
    .. ' over-approximated'):format(a, b, u, o))
print('  a recorded run is the strongest tier there is, so where it disagrees with a weaker one')
print('  the pair is worth a look — ranked, because a claim contradicted 40 times is a different')
print('  problem from one contradicted once.')
