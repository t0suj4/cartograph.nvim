-- Greenspun's tenth rule, as a detector (pure, over the neutral schema):
-- "any sufficiently complicated program contains an ad hoc, informally-
-- specified, bug-ridden, slow implementation of half of Common Lisp."
-- The halves it finds here:
--
--   REGISTRIES   a verb called many times with a string KEY and a CALLABLE —
--                an ad-hoc symbol table (add_action, register_listener,
--                RegisterMessageCallback). Verbs whose literal keys overlap a
--                registry's keys are its DISPATCH side (do_action). Found
--                pairs are proposed as xlang bindings: the hand-written
--                per-project binding config becomes discoverable structure.
--   DISPATCH TABLES  literal data tables whose values name functions —
--                an ad-hoc funcall table (FSM callback specs, handler maps).
--   EVAL         the last resort (eval/load/dlsym): the interpreter itself.
--
-- Heuristics guard against printf-shaped false positives: an export verb
-- must carry a callable argument; an import verb must share keys with an
-- export. Everything reported is countable and jumpable, not vibes.

local M = {}

local argv = require 'cartograph.argv'
local df = require 'cartograph.df'
local atr = require 'cartograph.at'
local callrec = require 'cartograph.callrec'

local EVAL_VERBS = {
    eval = true, exec = true, load = true, loadstring = true, dofile = true,
    create_function = true, Function = true, dlsym = true,
}

local function fn_names(data)
    local names = {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            names[n.name] = true
            local tail = n.name:match('([%w_]+)$')
            if tail then names[tail] = true end
        end
    end
    return names
end

-- bounded Damerau-Levenshtein: transposition counts 1 — 'on_tikc' is one
-- slip from 'on_tick', and that slip is THE registry typo
local function editdist(a, b, cap)
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

local function nearest(key, set)
    local cap = #key >= 5 and 2 or 1
    local best, bestd
    for k in pairs(set) do
        if k ~= key then
            local d = editdist(key, k, cap)
            if d <= cap and (not bestd or d < bestd) then best, bestd = k, d end
        end
    end
    return best
end

-- logical arg positions where most sites carry a nonempty literal;
-- first return = the most-covered one, second = all candidates
local function key_positions(calls)
    local counts, total = {}, 0
    for _, c in ipairs(calls) do
        total = total + 1
        for i = 1, argv.n(c) do
            local a = argv.str(c, i)
            local li = i - (c.method and 1 or 0)
            if li >= 1 and a ~= '' then counts[li] = (counts[li] or 0) + 1 end
        end
    end
    local best, bestn, all = nil, nil, {}
    for i, n in pairs(counts) do
        if n >= total * 0.6 then
            all[#all + 1] = i
            if not bestn or n > bestn then best, bestn = i, n end
        end
    end
    table.sort(all)
    return best, all
end

-- deep tier: read the call's own source for callable SHAPES the argv
-- classifier can't see (array callables, inline closures). Expensive --
-- one file read per undecided site -- hence button, not default.
local CALLABLE_PATS = {
    [=[%[[^%]]-,%s*['"][%w_]+['"]%s*%]]=],
    [=[array%s*%([^%)]-,%s*['"][%w_]+['"]]=],
    '&[%w_:]+',
    'function%s*%(',
    '=>',
}
local function read_lines(root, file, cache)
    if cache[file] == nil then
        local fd = io.open(root .. '/' .. file, 'r')
        if fd then
            cache[file] = vim.split(fd:read('a'), '\n', { plain = true })
            fd:close()
        else
            cache[file] = false
        end
    end
    return cache[file]
end
local function deep_callable(root, c, cache)
    local lines = read_lines(root, callrec.file(c), cache)
    if not lines then return false end
    local text = require('cartograph.xlang').call_text(root, c, lines)
    for _, pat in ipairs(CALLABLE_PATS) do
        if text:find(pat) then return true end
    end
    return false
end

-- deep tier: a non-literal key built by concatenation yields a PREFIX
-- family ('save_' . $type covers every key starting save_)
local function deep_prefix(root, c, cache)
    local lines = read_lines(root, callrec.file(c), cache)
    if not lines then return nil end
    local text = require('cartograph.xlang').call_text(root, c, lines)
    return text:match([=[['"]([%w_%-]+)['"]%s*[%.%+]]=])
end

-- registry keys look like NAMES: short, no format directives or control
-- chars, at most two spaces. Test titles ('handles multibyte characters
-- in a macro') and format strings are string+callable SHAPED but intern
-- prose, not symbols.
local function name_like(k)
    if #k < 2 or #k > 48 or k:find('[%c%%]') then return false end
    local _, spaces = k:gsub(' ', '')
    return spaces <= 2
end

local function name_like_ratio(keys)
    local ok, total = 0, 0
    for k in pairs(keys) do
        total = total + 1
        if name_like(k) then ok = ok + 1 end
    end
    return total > 0 and ok / total or 0
end

local function keys_at(calls, pos)
    local keys = {}
    for _, c in ipairs(calls) do
        local a = argv.str(c, pos + (c.method and 1 or 0))
        if a and a ~= '' then keys[a] = true end
    end
    return keys
end

--- Discover registry/dispatch verb pairs. Returns (bindings, report):
--- bindings in xlang shape, report entries for the lint.
function M.registries(data, opts)
    local min_sites = opts and opts.min_sites or 2
    local known = fn_names(data)
    local coop = require 'cartograph.coop' -- tick() chunks this off the main
    local by_verb = {}                     -- loop when run under coop.run; else no-op
    for i, c in callrec.each(data) do
        if not c.dynamic then
            by_verb[callrec.callee(c)] = by_verb[callrec.callee(c)] or {}
            table.insert(by_verb[callrec.callee(c)], c)
        end
        if i % 8192 == 0 then coop.tick() end
    end

    -- exports: literal key + a callable argument somewhere
    local exports = {}
    for verb, calls in pairs(by_verb) do
        coop.tick()
        if #calls >= min_sites then
            local kpos = key_positions(calls)
            if kpos then
                local callable, fnpos, deep_hits = 0, nil, 0
                local cache = opts and opts.deep and (opts._cache or {}) or nil
                for _, c in ipairs(calls) do
                    local hit = false
                    for i = 1, argv.n(c) do
                        local a = argv.at(c, i)
                        local li = i - (c.method and 1 or 0)
                        if li >= 1 and li ~= kpos
                            and (a.k == 'func' or a.k == 'callable'
                                or (a.k == 'lit' and known[a.v])
                                or (a.k == 'local' and known[a.name])) then
                            hit = true
                            fnpos = fnpos or li
                            break
                        end
                    end
                    if not hit and cache and deep_callable(data.root, c, cache) then
                        hit = true
                        deep_hits = deep_hits + 1
                    end
                    if hit then callable = callable + 1 end
                end
                if callable >= math.max(min_sites, #calls * 0.5) then
                    local keys = keys_at(calls, kpos)
                    local nkeys = 0
                    for _ in pairs(keys) do nkeys = nkeys + 1 end
                    -- a registry with one key is not a registry
                    if nkeys >= 2 and name_like_ratio(keys) >= 0.6 then
                        exports[verb] = { verb = verb, name = kpos, fn = fnpos,
                            sites = #calls, keys = keys,
                            deep = deep_hits > 0 and deep_hits or nil }
                    end
                end
            end
        end
    end

    -- imports: literal key overlapping an export's keys (and not itself
    -- carrying the callables — that would be the registry again)
    local bindings, report = {}, {}
    for verb, ex in pairs(exports) do
        coop.tick()
        local imports = {}
        for iverb, calls in pairs(by_verb) do
            coop.tick()
            if iverb ~= verb and not exports[iverb] and #calls >= min_sites then
                local _, positions = key_positions(calls)
                local bestpos, bestshared, besttotal
                for _, pos in ipairs(positions) do
                    local shared, totalk = 0, 0
                    for k in pairs(keys_at(calls, pos)) do
                        totalk = totalk + 1
                        if ex.keys[k] then shared = shared + 1 end
                    end
                    if shared >= 1 and totalk > 0 and shared / totalk >= 0.5
                        and (not bestshared or shared > bestshared) then
                        bestpos, bestshared, besttotal = pos, shared, totalk
                    end
                end
                if bestpos then
                    imports[#imports + 1] = { verb = iverb, name = bestpos,
                        sites = #calls, shared = bestshared }
                end
            end
        end
        local nkeys = 0
        for _ in pairs(ex.keys) do nkeys = nkeys + 1 end
        if #imports > 0 then
            local iverbs = {}
            for _, im in ipairs(imports) do iverbs[#iverbs + 1] = im.verb end
            table.sort(iverbs)
            bindings[#bindings + 1] = {
                export = { verb = verb, name = ex.name, fn = ex.fn },
                import = { verb = iverbs, name = imports[1].name },
                discovered = true, deep = ex.deep,
            }
            -- micro-registries still LINK, but the report tier needs
            -- vocabulary: parametrized helper pairs are not findings
            if nkeys >= 3 then
                report[#report + 1] = { kind = 'registry', verb = verb,
                    imports = iverbs, sites = ex.sites, keys = nkeys,
                    example = next(ex.keys) }
            end
        elseif ex.sites >= 3 and nkeys >= 3 then
            report[#report + 1] = { kind = 'registry', verb = verb,
                imports = {}, sites = ex.sites, keys = nkeys,
                example = next(ex.keys) }
        end
    end
    return bindings, report
end

--- Why did discovery (not) find a registry? Re-runs the analysis with
--- every gate's verdict spelled out, numbers included. verb = nil gives
--- the one-line verdict for every candidate. Returns display lines.
function M.explain(data, verb, opts)
    local min_sites = opts and opts.min_sites or 2
    local known = fn_names(data)
    local by_verb = {}
    for _, c in callrec.each(data) do
        if not c.dynamic then
            by_verb[callrec.callee(c)] = by_verb[callrec.callee(c)] or {}
            table.insert(by_verb[callrec.callee(c)], c)
        end
    end
    local exports, import_of = {}, {}
    local bindings = M.registries(data, opts)
    do
        local _, report = M.registries(data, opts)
        for _, b in ipairs(bindings) do
            exports[b.export.verb] = b
            for _, iv in ipairs(b.import.verb or {}) do
                import_of[iv] = b.export.verb
            end
        end
        for _, r in ipairs(report) do exports[r.verb] = exports[r.verb] or true end
    end

    local function verdict(v)
        local calls = by_verb[v]
        if not calls then return nil end
        if import_of[v] then
            return ("IMPORT of '%s' (%d sites)"):format(import_of[v], #calls)
        end
        if #calls < min_sites then
            return ('rejected: %d site(s), %d required'):format(#calls, min_sites)
        end
        local kpos, positions = key_positions(calls)
        if not kpos then
            return 'rejected: no argument position is a literal at 60% of sites'
        end
        local callable, by_k = 0, {}
        for _, c in ipairs(calls) do
            local hit
            for i = 1, argv.n(c) do
                local a = argv.at(c, i)
                local li = i - (c.method and 1 or 0)
                if li >= 1 and li ~= kpos then
                    if a.k == 'func' or a.k == 'callable'
                        or (a.k == 'lit' and known[a.v])
                        or (a.k == 'local' and known[a.name]) then
                        hit = true
                    elseif not hit then
                        by_k[a.k] = (by_k[a.k] or 0) + 1
                    end
                end
            end
            if hit then callable = callable + 1 end
        end
        local need = math.max(min_sites, math.ceil(#calls * 0.5))
        if callable < need then
            local ks = {}
            for k, n in pairs(by_k) do ks[#ks + 1] = ('%s ×%d'):format(k, n) end
            table.sort(ks)
            local msg = ('rejected as export: callables at %d/%d sites, %d needed — other args classify as %s')
                :format(callable, #calls, need, table.concat(ks, ', '))
            if not (opts and opts.deep) then
                local cache, deep_ok = {}, 0
                for _, c in ipairs(calls) do
                    if deep_callable(data.root, c, cache) then deep_ok = deep_ok + 1 end
                end
                if callable + deep_ok >= need then
                    msg = msg .. ' — would PASS with deep heuristics (:CartographDiscover!)'
                end
            end
            return msg
        end
        if exports[v] then
            return ('EXPORT (key = arg %d, %d sites)'):format(kpos, #calls)
        end
        local ratio = name_like_ratio(keys_at(calls, kpos))
        if ratio < 0.6 then
            return ('rejected: keys are prose, not names (%d%% name-like — test titles / format strings?)')
                :format(math.floor(ratio * 100))
        end
        return ('export-shaped but unreported (key = arg %d, callables %d/%d)')
            :format(kpos, callable, #calls)
    end

    local lines = {}
    if not verb then
        local names = {}
        for v, calls in pairs(by_verb) do
            if #calls >= min_sites then names[#names + 1] = v end
        end
        table.sort(names, function (a, b) return #by_verb[a] > #by_verb[b] end)
        lines[#lines + 1] = ('discovery verdicts (%d candidate verbs, %d+ sites each)')
            :format(#names, min_sites)
        for _, v in ipairs(names) do
            lines[#lines + 1] = ('  %-28s %s'):format(v, verdict(v) or '?')
        end
        return lines
    end

    local calls = by_verb[verb]
    lines[#lines + 1] = ("discovery: '%s'"):format(verb)
    if not calls then
        lines[#lines + 1] = '  no calls with this callee name'
        local similar, names = {}, {}
        for v in pairs(by_verb) do names[v] = true end
        local near = nearest(verb, names)
        if near then similar[#similar + 1] = ('%s (%d calls)'):format(near, #by_verb[near]) end
        for v, cs in pairs(by_verb) do
            if v ~= near and (v:lower():find(verb:lower(), 1, true)
                or verb:lower():find(v:lower(), 1, true)) then
                similar[#similar + 1] = ('%s (%d calls)'):format(v, #cs)
            end
        end
        if #similar > 0 then
            lines[#lines + 1] = '  similar callees seen: ' .. table.concat(similar, ', ')
        end
        lines[#lines + 1] = '  note: the inventory names the TAIL (chrome.send -> send)'
        return lines
    end
    lines[#lines + 1] = ('  sites: %d (%d required) %s')
        :format(#calls, min_sites, #calls >= min_sites and '✓' or '✗')
    local kpos, positions = key_positions(calls)
    if kpos then
        for _, pos in ipairs(positions) do
            local n = 0
            for _ in pairs(keys_at(calls, pos)) do n = n + 1 end
            lines[#lines + 1] = ('  key position: arg %d — %d distinct literal key(s)%s')
                :format(pos, n, pos == kpos and ' ✓ (chosen)' or '')
        end
    else
        lines[#lines + 1] = '  key position: none — no argument is a literal at 60% of sites ✗'
        return lines
    end
    lines[#lines + 1] = '  ' .. (verdict(verb) or '?')
    if exports[verb] and type(exports[verb]) == 'table' then
        local b = exports[verb]
        lines[#lines + 1] = ('  PAIRED imports: %s')
            :format(table.concat(b.import.verb, ', '))
    end
    -- import pairing attempts against every export (not itself)
    lines[#lines + 1] = '  as an import candidate:'
    local any = false
    for _, b in ipairs(bindings) do
      if b.export.verb ~= verb then
        local ex_keys = keys_at(by_verb[b.export.verb] or {}, b.export.name)
        local best, bestshared, besttotal
        for _, pos in ipairs(positions) do
            local shared, total = 0, 0
            for k in pairs(keys_at(calls, pos)) do
                total = total + 1
                if ex_keys[k] then shared = shared + 1 end
            end
            if total > 0 and (not bestshared or shared > bestshared) then
                best, bestshared, besttotal = pos, shared, total
            end
        end
        if best then
            any = true
            local okp = bestshared >= 1 and bestshared / besttotal >= 0.5
            lines[#lines + 1] = ('    vs %-24s arg %d shares %d/%d keys (%d%%) %s')
                :format(b.export.verb, best, bestshared, besttotal,
                    besttotal > 0 and math.floor(bestshared / besttotal * 100) or 0,
                    okp and '✓' or '✗ (need ≥50% and ≥1)')
        end
      end
    end
    if not any then
        lines[#lines + 1] = '    (no discovered exports to pair against)'
    end
    return lines
end

--- Literal data tables whose values name functions: funcall tables.
function M.dispatch_tables(data)
    local known = fn_names(data)
    local out = {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'var' and type(n.data) == 'table' then
            local fns, total = 0, 0
            local function walk(t, depth)
                if depth > 4 then return end
                for _, v in pairs(t) do
                    total = total + 1
                    if type(v) == 'table' then
                        if v.ref and known[v.ref] then
                            fns = fns + 1
                        elseif v.expr == 'function' then
                            fns = fns + 1
                        elseif not v.ref and not v.expr then
                            walk(v, depth + 1)
                        end
                    elseif type(v) == 'string' and known[v] then
                        fns = fns + 1
                    end
                end
            end
            walk(n.data, 0)
            -- pair-shaped vtables ({ "name", fn }) run one fn per 2-3
            -- entries; require a third, not half
            if fns >= 2 and fns * 3 >= total then
                out[#out + 1] = { var = n, fns = fns, entries = total }
            end
        end
    end
    return out
end


-- callee/full → sorted call indices, memoized per data table (weak: dies with
-- the graph). The audits below used to re-sweep ALL calls once per binding /
-- per pair — O(B×C); pre-filtering through this index visits only the calls
-- whose callee (or full name) can possibly match, in original call order.
local CALLEE_IDX = setmetatable({}, { __mode = 'k' })
local function callee_index(data)
    local idx = CALLEE_IDX[data]
    if not idx then
        idx = {}
        for i, c in callrec.each(data) do
            if callrec.callee(c) then
                local b = idx[callrec.callee(c)]; if not b then b = {}; idx[callrec.callee(c)] = b end
                b[#b + 1] = i
            end
            if callrec.full(c) and callrec.full(c) ~= callrec.callee(c) then
                local b = idx[callrec.full(c)]; if not b then b = {}; idx[callrec.full(c)] = b end
                b[#b + 1] = i
            end
        end
        CALLEE_IDX[data] = idx
    end
    return idx
end

-- iterate the calls whose callee/full is in `names` (a set), in call order —
-- callers re-check their own match conditions, this is purely a pre-filter
local function matching_calls(data, names)
    local idx, seen, order = callee_index(data), {}, {}
    for name in pairs(names) do
        for _, i in ipairs(idx[name] or {}) do
            if not seen[i] then seen[i] = true; order[#order + 1] = i end
        end
    end
    table.sort(order)
    local calls, j = data.calls or {}, 0
    return function () j = j + 1; return order[j] and calls[order[j]] end
end

--- The registry consistency audit, auto-configured from the bindings in
--- force (hand-written and discovered alike). Two directions, both
--- suppressed when the respective side has dynamic (non-literal) keys:
--- a dispatched key never registered, a registered key never dispatched —
--- and when an unmatched key sits within edit distance of a real one,
--- the finding names the probable typo. Returns lint-shaped findings.
function M.audit(data, bindings, opts)
    local out = {}
    local cache = opts and opts.deep and {} or nil
    local function verbs_of(v)
        return type(v) == 'table' and v or { v }
    end
    for _, b in ipairs(bindings or {}) do
        if b.import and (b.import.verb or b.import.any_call) then
            local evs, ivs = {}, {}
            for _, v in ipairs(verbs_of(b.export.verb)) do evs[v] = true end
            for _, v in ipairs(verbs_of(b.import.verb or {})) do ivs[v] = true end
            local reg, reg_site, disp, disp_site = {}, {}, {}, {}
            local reg_dyn, disp_dyn, prefixes = false, false, {}
            local names = {}
            for v in pairs(evs) do names[v] = true end
            for v in pairs(ivs) do names[v] = true end
            for c in matching_calls(data, names) do
                local shift = c.method and 1 or 0
                if evs[callrec.callee(c)] or (c.full and evs[c.full]) then
                    local k = argv.str(c, (b.export.name or 1) + shift)
                    if k and k ~= '' then
                        reg[k] = true
                        reg_site[k] = reg_site[k] or c
                    else
                        reg_dyn = true
                    end
                elseif ivs[callrec.callee(c)] or (c.full and ivs[c.full]) then
                    local k = argv.str(c, (b.import.name or 1) + shift)
                    if k and k ~= '' then
                        disp[k] = true
                        disp_site[k] = disp_site[k] or c
                    else
                        -- a concatenated key is a PREFIX FAMILY, which keeps
                        -- the dead-key check alive for uncovered keys. The
                        -- provider classifies it at parse time; the deep
                        -- file scan is only a fallback for graphs without
                        -- argv kinds (lua-ls dumps)
                        local pfx
                        local a = argv.at(c, (b.import.name or 1) + shift)
                        if a and a.k == 'concat' and a.prefix then
                            pfx = a.prefix
                        elseif cache then
                            pfx = deep_prefix(data.root, c, cache)
                        end
                        if pfx then
                            prefixes[#prefixes + 1] = pfx
                        else
                            disp_dyn = true
                        end
                    end
                end
            end
            local function prefix_covered(k)
                for _, pf in ipairs(prefixes) do
                    if k:sub(1, #pf) == pf then return true end
                end
                return false
            end
            if next(reg) then
                local miss_d, miss_r = 0, 0
                for k in pairs(disp) do
                    if not reg[k] then
                        miss_d = miss_d + 1
                        local near = nearest(k, reg)
                        if near then
                            local c = disp_site[k]
                            out[#out + 1] = { severity = 'warn',
                                file = data.root .. '/' .. callrec.file(c), line = c.line + 1,
                                message = ("'%s' is dispatched but never registered — did you mean '%s'?")
                                    :format(k, near) }
                        end
                    end
                end
                if not disp_dyn then
                    for k in pairs(reg) do
                        if not disp[k] and not prefix_covered(k) then
                            miss_r = miss_r + 1
                            local near = nearest(k, disp)
                            if near then
                                local c = reg_site[k]
                                out[#out + 1] = { severity = 'warn',
                                    file = data.root .. '/' .. callrec.file(c), line = c.line + 1,
                                    message = ("'%s' is registered but never dispatched — did you mean '%s'?")
                                        :format(k, near) }
                            end
                        end
                    end
                end
                if miss_d + miss_r > 0 then
                    local vname = verbs_of(b.export.verb)[1]
                    out[#out + 1] = { severity = 'info',
                        file = data.root, line = 1,
                        message = ("registry '%s': %d key(s) dispatched but never registered, %d registered but never dispatched%s%s")
                            :format(vname, miss_d, miss_r,
                                reg_dyn and ' (dynamic registrations exist)' or '',
                                disp_dyn and ' (dynamic dispatch exists — dead-key check suppressed)'
                                    or (#prefixes > 0 and (' (%d prefix famil%s honored)')
                                        :format(#prefixes, #prefixes == 1 and 'y' or 'ies') or '')) }
                end
            end
        end
    end
    return out
end

-- ── paired verbs: ad-hoc RAII ────────────────────────────────────────────────
-- acquire/release pairs found by NAME MORPHOLOGY (unX, removeX, close/open)
-- and confirmed by shared keys where both sides carry literals. The audit
-- that needed listener_config now configures itself.

local PAIR_PREFIXES = {
    { 'add', 'remove' }, { 'add', 'delete' }, { 'register', 'unregister' },
    { 'register', 'deregister' }, { 'open', 'close' }, { 'start', 'stop' },
    { 'begin', 'end' }, { 'create', 'destroy' }, { 'push', 'pop' },
    { 'acquire', 'release' }, { 'lock', 'unlock' }, { 'attach', 'detach' },
    { 'bind', 'unbind' }, { 'connect', 'disconnect' }, { 'enable', 'disable' },
    { 'show', 'hide' }, { 'alloc', 'free' }, { 'ref', 'unref' },
    { 'retain', 'release' }, { 'subscribe', 'unsubscribe' },
}

local function release_names(v)
    local out, seen = {}, {}
    local function add(x, weak)
        if not seen[x] then
            seen[x] = true
            out[#out + 1] = x
            if weak then out[x] = true end -- un-/de- morphology is WEAK:
            -- 'unsafe' is not the release of 'safe' — these pairs must
            -- confirm by shared keys
        end
    end
    add('un' .. v, true)
    add('de' .. v, true)
    for _, pp in ipairs(PAIR_PREFIXES) do
        local a, b = pp[1], pp[2]
        if v == a then
            add(b)
        elseif v:sub(1, #a + 1) == a .. '_' then
            add(b .. v:sub(#a + 1))
        elseif #v > #a and v:sub(1, #a) == a
            and v:sub(#a + 1, #a + 1):match('%u') then
            add(b .. v:sub(#a + 1)) -- addFoo -> removeFoo
        end
    end
    return out
end

--- Acquire/release verb pairs. Each entry:
--- { acquire = { verb, key }, release = { verb, key? }, shared? }
--- release.key nil = the release side has no literal keys (dynamic).
function M.verb_pairs(data, opts)
    local min_sites = opts and opts.min_sites or 2
    local by_verb = {}
    for _, c in callrec.each(data) do
        if not c.dynamic then
            by_verb[callrec.callee(c)] = by_verb[callrec.callee(c)] or {}
            table.insert(by_verb[callrec.callee(c)], c)
        end
    end
    local out = {}
    for v, calls in pairs(by_verb) do
        if #calls >= min_sites then
            for _, r in ipairs(release_names(v)) do
                local rc = by_verb[r]
                if rc then
                    local akey = key_positions(calls)
                    if akey then
                        local _, rposs = key_positions(rc)
                        -- release key = the position sharing most keys
                        local rkey, shared
                        local akeys = keys_at(calls, akey)
                        for _, pos in ipairs(rposs or {}) do
                            local sh = 0
                            for k in pairs(keys_at(rc, pos)) do
                                if akeys[k] then sh = sh + 1 end
                            end
                            if sh > 0 and (not shared or sh > shared) then
                                rkey, shared = pos, sh
                            end
                        end
                        -- both sides literal but ZERO overlap: unrelated
                        -- verbs that happen to rhyme — refuse. Weak (un-/de-)
                        -- morphology refuses without POSITIVE key overlap.
                        local names = release_names(v)
                        local weak = names[r] == true
                        if not (rposs and #rposs > 0 and not rkey)
                            and not (weak and not rkey) then
                            out[#out + 1] = { acquire = { verb = v, key = akey },
                                release = { verb = r, key = rkey },
                                shared = shared,
                                sites = #calls + #rc }
                        end
                    end
                end
            end
        end
    end
    return out
end

--- The imbalance audit over discovered pairs: released-but-never-acquired
--- (typos get a suggestion), acquired-but-never-released (leak-prone;
--- suppressed when the release side is dynamic).
function M.pair_audit(data, vpairs)
    local out = {}
    for _, pr in ipairs(vpairs or {}) do
        local acq, rel, acq_site, rel_sites = {}, {}, {}, {}
        local acq_dyn, rel_dyn = false, false
        local found = #out
        local names = { [pr.acquire.verb] = true }
        if pr.release.verb then names[pr.release.verb] = true end
        for c in matching_calls(data, names) do
            local shift = c.method and 1 or 0
            if callrec.callee(c) == pr.acquire.verb then
                local k = argv.str(c, pr.acquire.key + shift)
                if k and k ~= '' then
                    acq[k] = true
                    acq_site[k] = acq_site[k] or c
                else
                    acq_dyn = true
                end
            elseif callrec.callee(c) == pr.release.verb then
                if pr.release.key then
                    local k = argv.str(c, pr.release.key + shift)
                    if k and k ~= '' then
                        rel[k] = true
                        rel_sites[k] = rel_sites[k] or c
                    else
                        rel_dyn = true
                    end
                else
                    rel_dyn = true
                end
            end
        end
        -- released but never acquired: with a near-miss it is a typo
        -- (strong evidence, dynamic acquires or not); without one it is
        -- only a finding when the acquire side is fully literal
        for k in pairs(rel) do
            if not acq[k] then
                local near = nearest(k, acq)
                if near or not acq_dyn then
                    local c = rel_sites[k]
                    out[#out + 1] = { severity = 'warn',
                        file = data.root .. '/' .. callrec.file(c), line = c.line + 1,
                        message = ("%s('%s') releases a key never acquired%s")
                            :format(pr.release.verb, k,
                                near and (" — did you mean '" .. near .. "'?") or '') }
                end
            end
        end
        if not rel_dyn then
            for k in pairs(acq) do
                if not rel[k] then
                    local c = acq_site[k]
                    out[#out + 1] = { severity = 'warn',
                        file = data.root .. '/' .. callrec.file(c), line = c.line + 1,
                        message = ("%s('%s') is never %sd — leak-prone")
                            :format(pr.acquire.verb, k, pr.release.verb) }
                end
            end
        end
        -- the inventory line only when there is something to say: findings,
        -- or literal acquires whose leak check had to stand down
        if #out > found or (rel_dyn and next(acq)) then
            out[#out + 1] = { severity = 'info', file = data.root, line = 1,
                message = ("ad-hoc RAII: %s/%s%s"):format(pr.acquire.verb,
                    pr.release.verb,
                    rel_dyn and ' (release keys dynamic — leak check suppressed)' or '') }
        end
    end
    return out
end

-- ── schema mirrors: parallel vocabularies in literal data ────────────────────
-- Tables that share a key/value vocabulary are MIRRORS of one schema; the
-- divergence between them is the change-one-forget-the-other bug class.

local function string_sets(node, val, path, out, depth)
    if depth > 4 or type(val) ~= 'table' then return end
    local keys, strs, nk, ns = {}, {}, 0, 0
    for k, v in pairs(val) do
        if type(k) == 'string' then
            keys[k] = true
            nk = nk + 1
        end
        if type(v) == 'string' then
            strs[v] = true
            ns = ns + 1
        end
    end
    local label = node.name .. path
    if nk >= 3 then
        out[#out + 1] = { label = label .. ' (keys)', set = keys, node = node }
    end
    if ns >= 3 then
        out[#out + 1] = { label = label .. ' (values)', set = strs, node = node }
    end
    -- columns: a LIST of tables sharing a field yields that field's value set
    local nlist, cols = 0, {}
    for _, v in ipairs(val) do
        if type(v) == 'table' and not v.ref and not v.expr then
            nlist = nlist + 1
            for f, fv in pairs(v) do
                if type(f) == 'string' then
                    cols[f] = cols[f] or {}
                    if type(fv) == 'string' then
                        cols[f][fv] = true
                    elseif type(fv) == 'table' then
                        for _, x in ipairs(fv) do
                            if type(x) == 'string' then cols[f][x] = true end
                        end
                    end
                end
            end
        end
    end
    if nlist >= 3 then
        for f, set in pairs(cols) do
            local n = 0
            for _ in pairs(set) do n = n + 1 end
            if n >= 3 then
                out[#out + 1] = { label = ('%s%s[].%s'):format(node.name, path, f),
                    set = set, node = node }
            end
        end
    end
    for k, v in pairs(val) do
        if type(v) == 'table' and type(k) == 'string' then
            string_sets(node, v, path .. '.' .. k, out, depth + 1)
        end
    end
end

--- Divergent mirrors between literal data tables, clustered into
--- vocabulary FAMILIES (N tables sharing one vocabulary is one finding,
--- not N² pairs). Candidate pairs come from an inverted index — only
--- sets that actually share a member are compared, so scale costs what
--- the sharing costs, not |sets|². Returns
--- { {members = {label...}, core = n, extras = {label -> {strings}},
---    node}, ... }, note?
function M.mirrors(data, opts)
    local min_shared = opts and opts.min_shared or 4
    local sets = {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'var' and type(n.data) == 'table' then
            string_sets(n, n.data, '', sets, 0)
        end
    end
    -- inverted index: member -> set indices. Ubiquitous members (a string
    -- in more than 25 vocabularies) are stopwords — stated, not silent.
    local index, stop = {}, 0
    for i, sd in ipairs(sets) do
        for k in pairs(sd.set) do
            index[k] = index[k] or {}
            table.insert(index[k], i)
        end
    end
    local shared_count = {}
    for k, list in pairs(index) do
        if #list > 25 then
            stop = stop + 1
        elseif #list > 1 then
            for x = 1, #list do
                for y = x + 1, #list do
                    local key = list[x] .. '\31' .. list[y]
                    shared_count[key] = (shared_count[key] or 0) + 1
                end
            end
        end
    end
    -- qualifying pairs -> union-find into families
    local parent = {}
    local function find(i)
        parent[i] = parent[i] or i
        if parent[i] ~= i then parent[i] = find(parent[i]) end
        return parent[i]
    end
    local qualified = false
    for key, inter in pairs(shared_count) do
        if inter >= min_shared then
            local i, j = key:match('^(%d+)\31(%d+)$')
            i, j = tonumber(i), tonumber(j)
            local a, b = sets[i], sets[j]
            if a.node.id ~= b.node.id then
                local na, nb = 0, 0
                for _ in pairs(a.set) do na = na + 1 end
                for _ in pairs(b.set) do nb = nb + 1 end
                if inter / math.min(na, nb) >= 0.6
                    and (na > inter or nb > inter) then
                    parent[find(i)] = find(j)
                    qualified = true
                end
            end
        end
    end
    if not qualified then
        return {}, stop > 0
            and ('%d ubiquitous member string(s) skipped'):format(stop) or nil
    end
    local families = {}
    for i in pairs(parent) do
        local r = find(i)
        families[r] = families[r] or {}
        table.insert(families[r], i)
    end
    local out = {}
    for _, members in pairs(families) do
        if #members >= 2 then
            table.sort(members)
            -- the family CORE is the intersection of all member sets;
            -- each member's extras are its divergence from the core
            local core = {}
            for k in pairs(sets[members[1]].set) do core[k] = true end
            for m = 2, #members do
                for k in pairs(core) do
                    if not sets[members[m]].set[k] then core[k] = nil end
                end
            end
            local ncore = 0
            for _ in pairs(core) do ncore = ncore + 1 end
            -- labels + per-member extras, BY INDEX (same-named vars in
            -- different files would collide as table keys)
            local labels, extras, seen_l = {}, {}, {}
            for x, m in ipairs(members) do
                local sd = sets[m]
                local label = sd.label
                if seen_l[label] then
                    label = ('%s@%s:%d'):format(label,
                        sd.node.file:match('[^/]+$'), atr.sl(sd.node.range) + 1)
                end
                seen_l[sd.label] = true
                labels[x] = label
                local ex = {}
                for k in pairs(sd.set) do
                    if not core[k] then ex[#ex + 1] = k end
                end
                table.sort(ex)
                extras[x] = #ex > 0 and ex or nil
            end
            out[#out + 1] = { members = labels, core = ncore,
                extras = extras, node = sets[members[1]].node }
        end
    end
    table.sort(out, function (a, b) return a.core > b.core end)
    return out, stop > 0
        and ('%d ubiquitous member string(s) skipped'):format(stop) or nil
end

--- Clone candidates: functions whose data-flow SHAPE and callee set are
--- identical (names normalized away). Exact-shape only — near-misses are
--- a later tier. Returns groups of >= 2 nodes.
function M.clones(data, opts)
    local min_stmts = opts and opts.min_stmts or 3
    local callees = {}
    for _, c in callrec.each(data) do
        if callrec.fn(c) then
            callees[callrec.fn(c)] = callees[callrec.fn(c)] or {}
            table.insert(callees[callrec.fn(c)], callrec.callee(c))
        end
    end
    local groups = {}
    for _, n in ipairs(data.nodes) do
        if (n.kind == 'function' or n.kind == 'method')
            and df.count(n) >= min_stmts
            and not n.name:match('^[%u_%d]+$') then -- TEST/BENCHMARK macros
            local sig = { tostring(#(n.params or {})) }
            for _, st in ipairs(df.stmts(n)) do
                local deps = {}
                for _, d in ipairs(st.dep or {}) do deps[#deps + 1] = d.from end
                table.sort(deps)
                sig[#sig + 1] = ('%d/%d/%s'):format(
                    #(st.def or {}), #(st.use or {}), table.concat(deps, ','))
            end
            local cs = {}
            for _, x in ipairs(callees[n.id] or {}) do cs[#cs + 1] = x end
            table.sort(cs)
            sig[#sig + 1] = table.concat(cs, ',')
            local key = table.concat(sig, ';')
            groups[key] = groups[key] or { callees = #cs > 0 }
            table.insert(groups[key], n)
        end
    end
    local out = {}
    for _, g in pairs(groups) do
        -- shared CALLEES are the real clone signal; a callee-less shape
        -- match is coincidence unless the shape is substantial
        if #g >= 2 and (g.callees or df.count(g[1]) >= 5) then
            table.sort(g, function (a, b)
                if a.file ~= b.file then return a.file < b.file end
                return a.order < b.order
            end)
            out[#out + 1] = g
        end
    end
    table.sort(out, function (a, b) return df.count(a[1]) > df.count(b[1]) end)
    return out
end

--- Layering: when imports between two top-level directories flow
--- overwhelmingly one way, the stragglers running against the current
--- are layering violations. Returns { {dom_from, dom_to, dom, against,
--- edges = {against-edges}}, ... }.
function M.layering(data, opts)
    local max_ratio = opts and opts.max_ratio or 0.25
    local function dir_of(f) return f:match('^([^/]+)/') or '.' end
    local mat, samples = {}, {}
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'import' then
            local a, b = dir_of(e.from), dir_of(e.to)
            if a ~= b then
                local k = a .. '\31' .. b
                mat[k] = (mat[k] or 0) + 1
                samples[k] = samples[k] or {}
                if #samples[k] < 6 then table.insert(samples[k], e) end
            end
        end
    end
    local out = {}
    for k, n in pairs(mat) do
        local a, b = k:match('^(.-)\31(.*)$')
        local rk = b .. '\31' .. a
        local m = mat[rk] or 0
        -- visit each unordered pair once, from the dominant side
        if m < n or (m == n and a < b) then
            if m > 0 and m <= n * max_ratio then
                out[#out + 1] = { dom_from = a, dom_to = b, dom = n,
                    against = m, edges = samples[rk] }
            end
        end
    end
    table.sort(out, function (x, y) return x.dom > y.dom end)
    return out
end

--- String-keyed FACTORIES: the lookup half of the symbol table — verbs
--- resolving many distinct literal keys to objects (Mage::getModel,
--- helper, getTable) with no callable in sight. Not linkable (the target
--- is data), but the vocabulary is real structure.
function M.factories(data, opts)
    local min_sites = opts and opts.min_sites or 30
    local min_keys = opts and opts.min_keys or 10
    local by_verb = {}
    for _, c in callrec.each(data) do
        if not c.dynamic and not callrec.to(c) then
            by_verb[callrec.callee(c)] = by_verb[callrec.callee(c)] or {}
            table.insert(by_verb[callrec.callee(c)], c)
        end
    end
    local out = {}
    for verb, calls in pairs(by_verb) do
        if #calls >= min_sites then
            local kpos = key_positions(calls)
            if kpos then
                local keys = keys_at(calls, kpos)
                -- factory keys are PATHS/IDENTIFIERS, stricter than the
                -- registry gate: SQL fragments carry operators
                local n, strict = 0, 0
                for k in pairs(keys) do
                    n = n + 1
                    if name_like(k) and not k:find('[=<>%(%)!?,]') then
                        strict = strict + 1
                    end
                end
                if n >= min_keys and strict / n >= 0.8 then
                    out[#out + 1] = { verb = verb, sites = #calls, keys = n,
                        example = next(keys) }
                end
            end
        end
    end
    table.sort(out, function (a, b) return a.sites > b.sites end)
    return out
end

--- eval and friends: the interpreter itself.
function M.evals(data)
    local out = {}
    for _, c in callrec.each(data) do
        if EVAL_VERBS[callrec.callee(c)] and not callrec.to(c) then
            out[#out + 1] = c
        end
    end
    return out
end

return M
