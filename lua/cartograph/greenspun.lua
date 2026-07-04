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
