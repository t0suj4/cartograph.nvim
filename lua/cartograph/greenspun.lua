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
        for i, a in ipairs(c.args or {}) do
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

local function keys_at(calls, pos)
    local keys = {}
    for _, c in ipairs(calls) do
        local a = (c.args or {})[pos + (c.method and 1 or 0)]
        if a and a ~= '' then keys[a] = true end
    end
    return keys
end

--- Discover registry/dispatch verb pairs. Returns (bindings, report):
--- bindings in xlang shape, report entries for the lint.
function M.registries(data, opts)
    local min_sites = opts and opts.min_sites or 2
    local known = fn_names(data)
    local by_verb = {}
    for _, c in ipairs(data.calls or {}) do
        if not c.dynamic then
            by_verb[c.callee] = by_verb[c.callee] or {}
            table.insert(by_verb[c.callee], c)
        end
    end

    -- exports: literal key + a callable argument somewhere
    local exports = {}
    for verb, calls in pairs(by_verb) do
        if #calls >= min_sites then
            local kpos = key_positions(calls)
            if kpos then
                local callable, fnpos = 0, nil
                for _, c in ipairs(calls) do
                    for i, a in ipairs(c.argv or {}) do
                        local li = i - (c.method and 1 or 0)
                        if li >= 1 and li ~= kpos
                            and (a.k == 'func'
                                or (a.k == 'lit' and known[a.v])
                                or (a.k == 'local' and known[a.name])) then
                            callable = callable + 1
                            fnpos = fnpos or li
                            break
                        end
                    end
                end
                if callable >= math.max(min_sites, #calls * 0.5) then
                    exports[verb] = { verb = verb, name = kpos, fn = fnpos,
                        sites = #calls, keys = keys_at(calls, kpos) }
                end
            end
        end
    end

    -- imports: literal key overlapping an export's keys (and not itself
    -- carrying the callables — that would be the registry again)
    local bindings, report = {}, {}
    for verb, ex in pairs(exports) do
        local imports = {}
        for iverb, calls in pairs(by_verb) do
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
                discovered = true,
            }
            report[#report + 1] = { kind = 'registry', verb = verb,
                imports = iverbs, sites = ex.sites, keys = nkeys,
                example = next(ex.keys) }
        elseif ex.sites >= 3 then
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
    for _, c in ipairs(data.calls or {}) do
        if not c.dynamic then
            by_verb[c.callee] = by_verb[c.callee] or {}
            table.insert(by_verb[c.callee], c)
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
            for i, a in ipairs(c.argv or {}) do
                local li = i - (c.method and 1 or 0)
                if li >= 1 and li ~= kpos then
                    if a.k == 'func' or (a.k == 'lit' and known[a.v])
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
            return ('rejected as export: callables at %d/%d sites, %d needed — other args classify as %s')
                :format(callable, #calls, need, table.concat(ks, ', '))
        end
        if exports[v] then
            return ('EXPORT (key = arg %d, %d sites)'):format(kpos, #calls)
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
            if fns >= 2 and fns * 2 >= total then
                out[#out + 1] = { var = n, fns = fns, entries = total }
            end
        end
    end
    return out
end


--- The registry consistency audit, auto-configured from the bindings in
--- force (hand-written and discovered alike). Two directions, both
--- suppressed when the respective side has dynamic (non-literal) keys:
--- a dispatched key never registered, a registered key never dispatched —
--- and when an unmatched key sits within edit distance of a real one,
--- the finding names the probable typo. Returns lint-shaped findings.
function M.audit(data, bindings)
    local out = {}
    local function verbs_of(v)
        return type(v) == 'table' and v or { v }
    end
    for _, b in ipairs(bindings or {}) do
        if b.import and (b.import.verb or b.import.any_call) then
            local evs, ivs = {}, {}
            for _, v in ipairs(verbs_of(b.export.verb)) do evs[v] = true end
            for _, v in ipairs(verbs_of(b.import.verb or {})) do ivs[v] = true end
            local reg, reg_site, disp, disp_site = {}, {}, {}, {}
            local reg_dyn, disp_dyn = false, false
            for _, c in ipairs(data.calls or {}) do
                local shift = c.method and 1 or 0
                if evs[c.callee] or (c.full and evs[c.full]) then
                    local k = (c.args or {})[(b.export.name or 1) + shift]
                    if k and k ~= '' then
                        reg[k] = true
                        reg_site[k] = reg_site[k] or c
                    else
                        reg_dyn = true
                    end
                elseif ivs[c.callee] or (c.full and ivs[c.full]) then
                    local k = (c.args or {})[(b.import.name or 1) + shift]
                    if k and k ~= '' then
                        disp[k] = true
                        disp_site[k] = disp_site[k] or c
                    else
                        disp_dyn = true
                    end
                end
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
                                file = data.root .. '/' .. c.file, line = c.line + 1,
                                message = ("'%s' is dispatched but never registered — did you mean '%s'?")
                                    :format(k, near) }
                        end
                    end
                end
                if not disp_dyn then
                    for k in pairs(reg) do
                        if not disp[k] then
                            miss_r = miss_r + 1
                            local near = nearest(k, disp)
                            if near then
                                local c = reg_site[k]
                                out[#out + 1] = { severity = 'warn',
                                    file = data.root .. '/' .. c.file, line = c.line + 1,
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
                                disp_dyn and ' (dynamic dispatch exists — dead-key check suppressed)' or '') }
                end
            end
        end
    end
    return out
end

--- eval and friends: the interpreter itself.
function M.evals(data)
    local out = {}
    for _, c in ipairs(data.calls or {}) do
        if EVAL_VERBS[c.callee] and not c.to then
            out[#out + 1] = c
        end
    end
    return out
end

return M
