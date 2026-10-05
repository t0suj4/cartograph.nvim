-- OPTIMIZE (write, CART-1444): THE LOOP — measure, pick, rewrite, accept or roll back, as one tactic over the set:
--   memo:   hot-spots (unhinted: where the workload's time goes, by module field)
--             -> memo-advisor on the hottest fields of THIS world (calls vs distinct keys, the price, the key kind)
--             -> memoize the best (residence from the key kind: identity -> weak, scalar -> strong, mixed -> ASK)
--             -> ab-equivalence: the measure at HEAD vs the rewritten tree — equal output AND faster, or ROLL BACK
--   order:  sort-ties (one run: the sorts whose comparator leaves ties) -> total-order on the top site with its derived
--             separator (more than one candidate -> ASK which) -> ab-equivalence (equal output)
-- Every measurement runs in a process of its own on THIS world's code (`code` = the graph's root): the toolbelt's own
-- modules are already loaded here, and a world that is a cartograph checkout would otherwise be measured as today's
-- code. Data flows by T.bind: each discovery's VALUE builds the next term.
-- ★ STOPS ONLY ON DECISIONS ([[tactic-limit-is-a-decision]]): a mixed key kind (where does the memo live?) and more
-- than one separator (what does the order mean?). The CANDIDATE is picked mechanically (the most time saved; the most
-- ties), above `min` (a share of the workload, default 0.05) — no candidate is an `empty` stop, never a guess.
-- ★ THE A/B IS THE ORACLE, not the advisor: purity and unshared results are not established before the rewrite, they
-- are TESTED after it — a memo whose callers mutate the shared result changes the output and is rolled back.
-- ⚠ APPLY ONLY: side A is HEAD, so the world must be a git checkout with no uncommitted change to tracked files
-- (refused by name otherwise), and in a preview the rewrite is not on disk, so the A/B compares HEAD with itself and
-- (faster = 1) fails.
local T = require('cartograph.tactic').T

local function git_clean(root)
    local r = vim.system({ 'git', '-C', root, 'status', '--porcelain', '--untracked-files=no' }, { text = true }):wait()
    if r.code ~= 0 then return nil, ('%s is not a git checkout: side A of the A/B is its HEAD'):format(root) end
    if vim.trim(r.stdout or '') ~= '' then
        return nil, ('%s has uncommitted changes: side A (HEAD) would not be the state before this rewrite — commit or set them aside first'):format(root)
    end
    return true
end

local function inside(file) return type(file) == 'string' and file:sub(1, 1) ~= '/' and file:sub(1, 1) ~= '[' end

local function node_at(store, file, line)
    local at = require 'cartograph.at'
    for _, n in ipairs(store.data.nodes or {}) do
        if n.file == file and (n.kind == 'function' or n.kind == 'method') and at.sl(n.range) == line - 1 then return store.ref_of(n.id) end
    end
end

local function build(p, store)
    local root = store.data.root
    local okg, gwhy = git_clean(root)
    if not okg then return nil, gwhy, 'ill-posed' end
    local min = tonumber(p.min or 0.05)
    local ab = { repo = root, ref = 'HEAD', measure = p.measure, corpus = p.corpus, sorted = p.sorted, timeout = p.timeout }
    local rewrite = p.rewrite or 'memo'
    if p.residence == 'generation' and not p.generation then return nil, 'residence = generation needs generation = <a Lua expression>', 'ill-posed' end
    if rewrite == 'order' then
        return T.bind('sort-ties', { workload = p.workload, code = root, timeout = p.timeout }, function (v)
            local site
            for _, s in ipairs(v.sites) do if inside(s.site) then site = s; break end end
            if not site then return nil, 'no sort in this world leaves ties', 'empty' end
            if #site.separators == 0 then
                return nil, ('%s leaves ties and no element path (nor pair) separates its elements: a tie-break needs a field the elements do not carry'):format(site.site), 'unbuilt'
            end
            -- the ANSWER to the decision is `by` — one of the derived candidates (a path that ties somewhere would leave
            -- the order partial, so an answer outside them is refused by name)
            local by = site.separators[1]
            if p.by then
                by = table.concat(p.by, ',')
                if not vim.tbl_contains(site.separators, by) then
                    return nil, ('by = %s is not among the tie-breaks unique at %s: %s'):format(by, site.site, table.concat(site.separators, ' | ')), 'ill-posed'
                end
            elseif #site.separators > 1 then
                return nil, ('which tie-break makes %s total (answer with by = <one>)? candidates (each unique across every element it saw): %s'):format(site.site,
                    table.concat(site.separators, ' | ')), 'decision'
            end
            -- the A/B compares as SETS (side A's order is the nondeterminism being fixed); DETERMINISM is the second check:
            -- sort-ties again, on the rewritten tree, no longer finds the site
            local sets = vim.tbl_extend('force', ab, { sorted = '1' })
            return T.seq(T.use('total-order', { site = site.site, by = by }), T.use('ab-equivalence', sets),
                T.bind('sort-ties', { workload = p.workload, code = root, timeout = p.timeout }, function (after)
                    for _, s in ipairs(after.sites or {}) do
                        if s.site == site.site then return nil, ('%s still leaves %d ties after the rewrite'):format(s.site, s.ties), 'unbuilt' end
                    end
                    return T.seq()
                end, { ungated = true }))
        end)
    end
    if rewrite ~= 'memo' then return nil, ('rewrite = memo | order, not %q'):format(rewrite), 'ill-posed' end
    -- (candidates by INCLUSIVE time: a memo saves what the field and everything below it costs)
    return T.bind('hot-spots', { workload = p.workload, code = root, timeout = p.timeout, by = 'inclusive', top = '200' }, function (hs)
        local targets, where = {}, {}
        for _, r in ipairs(hs.rows) do
            if inside(r.file) and #targets < tonumber(p.top or 8) then
                targets[#targets + 1] = r.name; where[r.name] = r
            end
        end
        if #targets == 0 then return nil, 'no field of this world holds the workload\'s samples', 'empty' end
        return T.bind('memo-advisor', { targets = table.concat(targets, ','), workload = p.workload, code = root, timeout = p.timeout }, function (adv)
            local best = adv.rows[1]
            if not best or best.saved < min * adv.workload_seconds then
                return nil, ('no memo saves %.0f%% of the workload (best: %s, %.3f s of %.3f s)'):format(min * 100,
                    best and best.name or '-', best and best.saved or 0, adv.workload_seconds), 'empty'
            end
            -- ★ THE PRICE IS A DECISION TOO: the A/B checks output and time, never memory. CART-1427's hand process
            -- REJECTED exactly this memo (expr.of, ~91-141 MB) on its price and restructured instead; a loop that only
            -- reads time would accept it. Above `max_kb` (default 64 MB) it stops and asks
            local max_kb = tonumber(p.max_kb or 65536)
            if best.result_kb > max_kb then
                return nil, ('a memo of %s would hold ~%.0f MB of results to save %.2f s of %.2f s: accept the price (max_kb = %d or more), or restructure so the callers derive once'):format(
                    best.name, best.result_kb / 1024, best.saved, adv.workload_seconds, math.ceil(best.result_kb)), 'decision'
            end
            -- `residence` ANSWERS the decision (and overrides the derived one: an identity key into a store whose content
            -- changes per generation is CART-1430's pointer case — only the caller knows)
            if best.keys == 'mixed' and not p.residence then
                return nil, ('%s is keyed by identity AND by value: where does its memo live (answer with residence = weak | strong | generation + generation = <expr>)?'):format(best.name), 'decision'
            end
            local w = where[best.name]
            local ref = node_at(store, w.file, w.line)
            if not ref then return nil, ('%s (%s:%d) is no function of the graph'):format(best.name, w.file, w.line), 'stale' end
            local residence = p.residence or (best.keys == 'identity' and 'weak' or 'strong')
            local check = vim.tbl_extend('force', ab, { faster = '1' })
            return T.seq(T.use('memoize', { ref = ref, residence = residence, generation = p.generation }), T.use('ab-equivalence', check))
        end)
    end)
end

local function in_git() return vim.fn.executable('git') == 1, 'no git' end
local function commit(store)
    local root = store.data.root
    vim.system({ 'bash', '-c', 'cd "$1" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm base', '_', root }):wait()
end
local OPTM = table.concat({
    'local M = {}',
    'function M.slow(t) local s = 0 for i = 1, 1500000 do s = s + (#t * i) % 7 end return s end',
    'function M.work(xs) local s = 0 for _, x in ipairs(xs) do s = s + M.slow(x) end return s end',
    'return M', '' }, '\n')
-- a slow function whose RESULT its caller mutates: a memo shares it between calls, and the output drifts
local SHARED = table.concat({
    'local M = {}',
    'function M.box(t) local s = 0 for i = 1, 1500000 do s = s + (#t * i) % 7 end return { n = s } end',
    'function M.work(xs) local s = 0 for _, x in ipairs(xs) do local b = M.box(x); b.n = b.n + 1; s = s + b.n end return s end',
    'return M', '' }, '\n')
local function work(mod) return ('return function () local m = require(%q); local t = { 1, 2, 3 }; local xs = {}; for i = 1, 60 do xs[i] = t end; return m.work(xs) end'):format(mod) end
local function measure_of(mod) return ('return { measure = function () package.loaded[%q] = nil; local w = assert(load(%q))(); return tostring(w()) end }'):format(mod, work(mod)) end

return {
    name = 'optimize',
    kind = 'write',
    tags = { 'code', 'optimize' },
    on_stop = 'rollback',
    summary = 'THE OPTIMIZATION LOOP on this world: rewrite = memo (hot-spots -> memo-advisor -> memoize, residence from the key kind) | order (sort-ties -> total-order) — then ab-equivalence of `measure` on `corpus` at HEAD vs the rewritten tree (memo: equal AND faster), rolled back when it fails. workload = what the discoveries run (Lua returning function (store) or { setup, run }; @file). Apply only, on a clean git checkout; stops only on decisions (mixed key kind, several separators)',
    params = { workload = 'string', measure = 'string', corpus = 'list', sorted = 'string?', rewrite = 'string?', top = 'string?',
        min = 'string?', timeout = 'string?', by = 'list?', residence = 'string?', generation = 'string?', max_kb = 'string?' },
    build = build,
    examples = {
        {
            name = 'nothing named: the loop finds the slow field, memoizes it WEAK (its key is a table), and the A/B accepts it — equal and faster',
            files = { ['lua/optm.lua'] = OPTM }, requires = in_git,
            params = function (store) commit(store); return { workload = work('optm'), measure = measure_of('optm'), corpus = { store.data.root } } end,
            expect = { status = 'done', applied = 1, check = function (root)
                local s = io.open(root .. '/lua/optm.lua'):read('a')
                return s:find('slow_raw', 1, true) ~= nil and s:find("__mode = 'k'", 1, true) ~= nil, s
            end },
        },
        {
            name = 'a memo whose results cost more than max_kb STOPS on the price decision before anything is written',
            files = { ['lua/optm.lua'] = OPTM }, requires = in_git,
            params = function (store) commit(store); return { workload = work('optm'), measure = measure_of('optm'), corpus = { store.data.root }, max_kb = '0' } end,
            expect = { status = 'stopped', applied = 0, check = function (root)
                return io.open(root .. '/lua/optm.lua'):read('a') == OPTM, 'written past the price'
            end },
        },
        {
            name = 'a memo whose callers MUTATE the shared result changes the output: the A/B rejects it and the rewrite is ROLLED BACK',
            files = { ['lua/optb.lua'] = SHARED }, requires = in_git,
            params = function (store) commit(store); return { workload = work('optb'), measure = measure_of('optb'), corpus = { store.data.root } } end,
            expect = { status = 'failed', applied = 0, check = function (root)
                return io.open(root .. '/lua/optb.lua'):read('a') == SHARED, 'the rejected memo was left on disk'
            end },
        },
        {
            name = 'rewrite = order: the sort that leaves ties gets its one derived tie-break; same rows as a set, and the ties are gone',
            files = { ['lua/ordm.lua'] = table.concat({
                'local M = {}',
                'function M.rows()',
                '  local keep = {}',
                '  for i = 1, 6 do keep[{ id = i }] = true end',
                '  local out = {}',
                '  for k in pairs(keep) do out[#out + 1] = { len = k.id % 2, id = k.id } end',
                '  table.sort(out, function (a, b) return a.len < b.len end)',
                '  return out',
                'end',
                'return M', '' }, '\n') }, requires = in_git,
            params = function (store)
                commit(store)
                return { rewrite = 'order', workload = 'return function () require("ordm").rows() end', corpus = { store.data.root },
                    measure = 'return { measure = function () package.loaded.ordm = nil; local o = {}; for _, r in ipairs(require("ordm").rows()) do o[#o + 1] = r.len .. " " .. r.id end; return o end }' }
            end,
            expect = { status = 'done', applied = 1, check = function (root)
                local s = io.open(root .. '/lua/ordm.lua'):read('a')
                return s:find('return a.id < b.id', 1, true) ~= nil, s
            end },
        },
        {
            name = 'a world with uncommitted changes is refused before anything runs: side A would not be the state before',
            files = { ['lua/optm.lua'] = OPTM }, requires = in_git,
            params = function (store)
                commit(store)
                local fd = io.open(store.data.root .. '/lua/optm.lua', 'a'); fd:write('-- edited\n'); fd:close()
                return { workload = work('optm'), measure = measure_of('optm'), corpus = { store.data.root } }
            end,
            expect = { status = 'failed', applied = 0 },
        },
    },
}
