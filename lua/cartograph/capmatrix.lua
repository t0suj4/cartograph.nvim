-- THE DERIVED CAPABILITY MATRIX (CART-0693) — which capture names each language's
-- query slots actually BIND, read from the specs and the provider rather than
-- declared, plus the PROJECTING direction: which languages have the GRAMMAR for a
-- slot's node types and leave the slot empty.
--
-- @langs any
-- It reads node types OUT of the specs' own queries and compares them with each
-- grammar's symbol table; it never names a grammar's node type itself.
--
-- ★ WHY CAPTURE NAMES AND NOT SLOTS. The provider runs its query passes and
-- dispatches every one of them on CAPTURE NAME (providers/treesitter.lua: the
-- concatenated defs query, import_query, iface_query, reg_read/reg_invoke, calls,
-- aperture_query). The seven slot names concatenated into the defs pass are
-- editorial — nothing enforces that `super_query` binds @child+@parent; handle_super
-- fires on the co-occurrence wherever it comes from. So the real interface is the
-- dispatched capture set per pass, and this module DERIVES that set from the
-- provider's source (`M.passes`), so a provider refactor moves the matrix with it.
-- An unrecognised non-underscore capture in the defs or aperture pass is NOT dead:
-- it becomes the node's CATEGORY (c/cpp `macro`/`struct`, ts `tsiface`/`tsenum`).
--
-- ⚠⚠ THE PROJECTING HALF IS A WORK LIST, NOT A GATE. "The grammar has the node
-- types this slot's donor names" is a weak proxy for "the slot means something in
-- this language": `super_query go` may be a correct refusal (embedding is not
-- inheritance), and a donor query built from ubiquitous types (`identifier`,
-- `arguments`) proves nothing — which is why coverage is also reported over the
-- DISTINCTIVE types only (present in at most half the grammars) and a vocabulary
-- with no distinctive type is never a candidate. Same status gramdiff's DIRECTION 2
-- declares about itself.
--
-- ⚠ WHAT IT CANNOT SEE (CART-0693's own ledger, stated so the fence declares its
-- reach): it counts which captures a language binds, so it catches an UNFILLED slot
-- (CART-0692: iface_query absent for typescript/tsx) and an UNBOUND capture
-- (CART-0671: import_query binds @path and never @bind). It does NOT catch a capture
-- that IS bound but only for some of the node shapes the grammar produces there
-- (CART-0672 / CART-0690, super_query binding @parent for 1 of 3 shapes) — that
-- needs the grammar's node-types JSON and is a different instrument.

local M = {}

--- The provider's query passes, DERIVED from its source text: which spec slots each
--- pass parses, which capture names its dispatch compares against, and whether it
--- has a catch-all (a non-underscore capture that becomes a category / a rule).
--- A pass starts at a `parse_query(<lang>, spec.<slot>)` (or the concatenated
--- `combined` defs query) and owns every capture comparison up to the next one.
--- @param src string  providers/treesitter.lua
--- @return table[] { slots = {slot...}, captures = {name -> true}, catchall = bool, line = n }
function M.passes(src)
    local combined_slots = {}
    local concat = src:match('combined%s*=%s*table%.concat%(%s*(%b{})')
    for slot in (concat or ''):gmatch('spec%.([%w_]+)') do
        combined_slots[#combined_slots + 1] = slot
    end
    local passes, cur = {}, nil
    local ln = 0
    for line in (src .. '\n'):gmatch('([^\n]*)\n') do
        ln = ln + 1
        local slot = line:match('parse_query%(%s*[%w_]+%s*,%s*spec%.([%w_]+)%s*%)')
        if slot then
            cur = { slots = { slot }, captures = {}, catchall = false, line = ln }
            passes[#passes + 1] = cur
        elseif line:match('parse_query%(%s*[%w_]+%s*,%s*combined%s*%)') then
            cur = { slots = combined_slots, captures = {}, catchall = false, line = ln }
            passes[#passes + 1] = cur
        elseif line:match('parse_query%(') then
            cur = nil -- a literal query (html script_element): not a spec slot
        elseif cur then
            for lhs, name in line:gmatch("([%w_%.%[%]]+)%s*==%s*'([%w_]+)'") do
                -- only comparisons of a CAPTURE NAME variable: the dispatch idioms in
                -- the provider are capn / cn / cap / X.captures[id]. (The first cut
                -- required a word character right before `==` and so never saw
                -- `rq.captures[id] == 'rcls'` — reg_read's pass read as dispatching
                -- nothing.)
                if lhs and (lhs == 'capn' or lhs == 'cn' or lhs == 'cap'
                    or lhs:match('captures%[[%w_]+%]$')) then
                    cur.captures[name] = true
                end
            end
            if line:match("capn?:sub%(1,%s*1%)%s*~=%s*'_'") then cur.catchall = true end
        end
    end
    return passes
end

--- Top-level patterns of a query string: balanced () / [] groups at depth 0, with
--- strings and `;` comments skipped. A pattern carries its trailing @captures.
function M.patterns(q)
    local out, depth, start, i, n = {}, 0, nil, 1, #q
    while i <= n do
        local ch = q:sub(i, i)
        if ch == '"' then
            local j = i + 1
            while j <= n and q:sub(j, j) ~= '"' do
                if q:sub(j, j) == '\\' then j = j + 1 end
                j = j + 1
            end
            i = j
        elseif ch == ';' then
            local j = q:find('\n', i, true)
            i = j or n
        elseif ch == '(' or ch == '[' then
            if depth == 0 then start = i end
            depth = depth + 1
        elseif ch == ')' or ch == ']' then
            depth = depth - 1
            if depth == 0 and start then
                -- extend over the trailing quantifier and captures of this pattern
                local j = i + 1
                while true do
                    local s, e = q:find('^%s*[%*%+%?]', j)
                    if not s then s, e = q:find('^%s*@[%w_%.%-]+', j) end
                    if not s then break end
                    j = e + 1
                end
                out[#out + 1] = q:sub(start, j - 1)
                i = j - 1
                start = nil
            end
        end
        i = i + 1
    end
    return out
end

--- Node types a query text names: what follows an open paren. `_` is the wildcard.
function M.node_types(text)
    local set = {}
    for s in text:gmatch('%(%s*([a-z_][a-z0-9_]*)') do
        if s ~= '_' then set[s] = true end
    end
    return set
end

local function captures_in(text)
    local set = {}
    for c in text:gmatch('@([%w_%.%-]+)') do set[c] = true end
    return set
end

local function sorted(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--- The matrix. Pure: every external fact is an argument.
--- @param specs table   lang -> spec
--- @param passes table  M.passes(provider source)
--- @param opts table    { captures = fn(lang, query) -> list|nil, err,
---                        provides = fn(lang) -> set of named node types | nil }
function M.derive(specs, passes, opts)
    local langs = sorted(specs)
    local slot_pass, dispatched = {}, {}
    for pi, p in ipairs(passes) do
        for _, s in ipairs(p.slots) do slot_pass[s] = pi end
        for c in pairs(p.captures) do dispatched[c] = dispatched[c] or {}; dispatched[c][pi] = true end
    end
    local R = { langs = langs, passes = passes, slot_pass = slot_pass,
        bind = {},          -- lang -> pass index -> capture -> true
        bound_by = {},      -- capture -> lang -> true   (dispatched captures only)
        category = {},      -- lang -> capture -> true   (catch-all: a node CATEGORY)
        unconsumed = {},    -- lang -> { query-shaped fields no provider pass parses }
        broken = {},        -- { lang, slot, err }  a slot whose query does not compile
        filled = {},        -- slot -> lang -> query
        provides = {}, have = {} }
    for _, lang in ipairs(langs) do
        local spec = specs[lang]
        R.bind[lang], R.category[lang], R.unconsumed[lang] = {}, {}, {}
        for field, v in pairs(spec) do
            if type(v) == 'string' and v:find('@', 1, true) and v:match('^%s*[%(%[]') then
                local pi = slot_pass[field]
                if not pi then
                    R.unconsumed[lang][#R.unconsumed[lang] + 1] = field
                else
                    R.filled[field] = R.filled[field] or {}
                    R.filled[field][lang] = v
                    local caps, err = opts.captures(lang, v)
                    if not caps then
                        R.broken[#R.broken + 1] = { lang = lang, slot = field, err = err }
                        caps = sorted(captures_in(v)) -- the text still says what it meant
                    end
                    local b = R.bind[lang][pi] or {}
                    R.bind[lang][pi] = b
                    for _, c in ipairs(caps) do
                        if c:sub(1, 1) ~= '_' then
                            b[c] = true
                            if passes[pi].captures[c] then
                                R.bound_by[c] = R.bound_by[c] or {}
                                R.bound_by[c][lang] = true
                            elseif passes[pi].catchall then
                                R.category[lang][c] = true
                            end
                        end
                    end
                end
            end
        end
        table.sort(R.unconsumed[lang])
        local have = opts.provides(lang)
        if have then R.provides[lang] = have; R.have[#R.have + 1] = lang end
    end
    -- how many grammars have each node type: the DISTINCTIVE vocabulary is what a
    -- coverage claim can rest on (a type in most grammars is not evidence)
    R.freq = {}
    for _, lang in ipairs(R.have) do
        for t in pairs(R.provides[lang]) do R.freq[t] = (R.freq[t] or 0) + 1 end
    end
    R.distinctive_max = math.floor(#R.have / 2)
    -- DEAD KERNEL: a dispatched capture no language binds
    R.dead = {}
    for c, ps in pairs(dispatched) do
        if not R.bound_by[c] then
            local where = {}
            for pi in pairs(ps) do where[#where + 1] = table.concat(passes[pi].slots, '+') end
            table.sort(where)
            R.dead[#R.dead + 1] = { capture = c, passes = where }
        end
    end
    table.sort(R.dead, function (a, b) return a.capture < b.capture end)
    return R
end

--- coverage of a vocabulary in a grammar: all types, and the distinctive ones
local function coverage(R, vocab, have)
    local n, k, dn, dk, hit = 0, 0, 0, 0, {}
    for t in pairs(vocab) do
        n = n + 1
        local distinct = (R.freq[t] or 0) <= R.distinctive_max
        if distinct then dn = dn + 1 end
        if have[t] then
            k = k + 1
            if distinct then dk = dk + 1; hit[#hit + 1] = t end
        end
    end
    table.sort(hit)
    return { n = n, k = k, dn = dn, dk = dk, hit = hit }
end

--- A candidate is worth a look when the donor names at least one DISTINCTIVE type
--- and the grammar has at least half of them. Anything weaker is noise by design.
local function candidate(cv) return cv.dn > 0 and cv.dk * 2 >= cv.dn end

local function rank(a, b)
    if a.cv.dk ~= b.cv.dk then return a.cv.dk > b.cv.dk end
    local fa, fb = a.cv.dk / a.cv.dn, b.cv.dk / b.cv.dn
    if fa ~= fb then return fa > fb end
    if a.cv.k ~= b.cv.k then return a.cv.k > b.cv.k end
    return (a.slot or a.capture) .. a.lang < (b.slot or b.capture) .. b.lang
end

--- PROJECTING, per SLOT: for each slot some language fills, every language with a
--- grammar that leaves it empty, scored by the best-covering donor's vocabulary.
function M.project_slots(R)
    local out = {}
    for slot, fillers in pairs(R.filled) do
        for _, lang in ipairs(R.have) do
            if not fillers[lang] then
                -- the best-covering donor; donors walked in name order so a tie is stable
                local best
                for _, donor in ipairs(sorted(fillers)) do
                    local cv = coverage(R, M.node_types(fillers[donor]), R.provides[lang])
                    local c = { slot = slot, lang = lang, donor = donor, cv = cv }
                    if candidate(cv) and (not best or rank(c, best)) then best = c end
                end
                if best then out[#out + 1] = best end
            end
        end
    end
    table.sort(out, rank)
    return out
end

--- The unweighted count, for comparison with the 2026-09-02 prototype's rule: every
--- (slot, empty language) pair where SOME donor's types are at least half present.
function M.count_unweighted(R)
    local n = 0
    for _, fillers in pairs(R.filled) do
        for _, lang in ipairs(R.have) do
            if not fillers[lang] then
                for _, q in pairs(fillers) do
                    local cv = coverage(R, M.node_types(q), R.provides[lang])
                    if cv.n > 0 and cv.k * 2 >= cv.n then n = n + 1; break end
                end
            end
        end
    end
    return n
end

--- PROJECTING, per CAPTURE: a dispatched capture exactly ONE language binds, and
--- the languages whose grammar has the node types of the patterns that bind it.
function M.project_captures(R)
    local out, single = {}, {}
    for c, ls in pairs(R.bound_by) do
        local only, n = nil, 0
        for l in pairs(ls) do only = l; n = n + 1 end
        if n == 1 then
            single[#single + 1] = { capture = c, lang = only }
            -- the donor's vocabulary: node types of the top-level patterns carrying @c
            local vocab = {}
            for slot, fillers in pairs(R.filled) do
                local q = fillers[only]
                if q then
                    for _, p in ipairs(M.patterns(q)) do
                        if captures_in(p)[c] then
                            for t in pairs(M.node_types(p)) do vocab[t] = true end
                        end
                    end
                end
            end
            for _, lang in ipairs(R.have) do
                if lang ~= only then
                    local cv = coverage(R, vocab, R.provides[lang])
                    if candidate(cv) then
                        out[#out + 1] = { capture = c, lang = lang, donor = only, cv = cv }
                    end
                end
            end
        end
    end
    table.sort(single, function (a, b) return a.capture < b.capture end)
    table.sort(out, rank)
    return out, single
end

--- The report, as lines.
function M.report(R, opts)
    opts = opts or {}
    local lines = {}
    local function say(s) lines[#lines + 1] = s end
    say('DERIVED CAPABILITY MATRIX (CART-0693) — capture names each spec binds, per provider pass')
    say('⚠ THE PROJECTING SECTIONS ARE A WORK LIST, NOT A GATE: "the grammar has the node types"')
    say('  is a weak proxy for "the slot means something here". Read a candidate before filing it.')
    say('  Blind to a capture bound for only SOME node shapes (CART-0672/0690) — see the module header.')
    say('')
    say(('passes derived from the provider: %d'):format(#R.passes))
    for pi, p in ipairs(R.passes) do
        local n = 0
        for _, lang in ipairs(R.langs) do if R.bind[lang][pi] then n = n + 1 end end
        say(('  pass %d  %-60s dispatch {%s}%s  bound by %d/%d spec(s)'):format(pi,
            table.concat(p.slots, '+'), table.concat(sorted(p.captures), ' '),
            p.catchall and ' +catch-all' or '', n, #R.langs))
    end
    say('')
    say('MATRIX — capture: languages binding it')
    local caps = sorted(R.bound_by)
    for _, c in ipairs(caps) do
        local ls = sorted(R.bound_by[c])
        say(('  %-10s %2d  %s'):format(c, #ls, table.concat(ls, ' ')))
    end
    say('')
    say(('DEAD KERNEL — a dispatched capture NO language binds: %d'):format(#R.dead))
    for _, d in ipairs(R.dead) do
        say(('  @%-10s dispatched in %s'):format(d.capture, table.concat(d.passes, ', ')))
    end
    say('')
    say('CATEGORY CAPTURES (catch-all: they become a node category — NOT dead):')
    for _, lang in ipairs(R.langs) do
        local cs = sorted(R.category[lang])
        if #cs > 0 then say(('  %-11s %s'):format(lang, table.concat(cs, ' '))) end
    end
    if #R.broken > 0 then
        say('')
        say('SLOTS THAT DO NOT COMPILE against their grammar (captures read from the text):')
        for _, b in ipairs(R.broken) do say(('  %s.%s  %s'):format(b.lang, b.slot, tostring(b.err))) end
    end
    local unc = {}
    for _, lang in ipairs(R.langs) do
        if #R.unconsumed[lang] > 0 then
            unc[#unc + 1] = ('  %-11s %s'):format(lang, table.concat(R.unconsumed[lang], ' '))
        end
    end
    if #unc > 0 then
        say('')
        say('QUERY-SHAPED FIELDS NO PROVIDER PASS PARSES (read elsewhere, or by nothing):')
        for _, l in ipairs(unc) do say(l) end
    end
    if opts.slots_registered then
        local drift = {}
        for slot in pairs(R.slot_pass) do
            if not opts.slots_registered[slot] then drift[#drift + 1] = slot end
        end
        table.sort(drift)
        say('')
        say(('DECLARED vs DERIVED — pass slots contract.lua does not register: %d%s'):format(#drift,
            #drift > 0 and ('  (' .. table.concat(drift, ' ') .. ')') or ''))
    end
    local ps = M.project_slots(R)
    say('')
    say(('PROJECTING BY SLOT — %d candidate(s): the slot is empty, the grammar has the donor\'s'):format(#ps))
    say(('  node types. dk/dn = DISTINCTIVE types (in <= %d of %d grammars) the grammar has;'):format(
        R.distinctive_max, #R.have))
    say('  k/n = all types. Ranked by dk, then dk/dn.')
    say(('  (%d under the UNWEIGHTED rule — any donor, k/n >= 1/2 over all types — which is'
        .. ' what ubiquitous types like `identifier` inflate)'):format(M.count_unweighted(R)))
    for i, c in ipairs(ps) do
        if opts.top and i > opts.top then say(('  … %d more'):format(#ps - opts.top)); break end
        say(('  %-16s %-11s from %-11s %d/%d distinctive  %d/%d all   %s'):format(c.slot, c.lang,
            c.donor, c.cv.dk, c.cv.dn, c.cv.k, c.cv.n, table.concat(c.cv.hit, ' ')))
    end
    local pc, single = M.project_captures(R)
    say('')
    say(('SINGLE-LANGUAGE CAPTURES — dispatched, bound by exactly one spec: %d'):format(#single))
    for _, s in ipairs(single) do say(('  @%-10s %s'):format(s.capture, s.lang)) end
    say(('PROJECTING BY CAPTURE — %d candidate(s): languages whose grammar has the node types'):format(#pc))
    say('  of the patterns that bind it')
    for i, c in ipairs(pc) do
        if opts.top and i > opts.top then say(('  … %d more'):format(#pc - opts.top)); break end
        say(('  @%-10s %-11s from %-11s %d/%d distinctive  %d/%d all   %s'):format(c.capture, c.lang,
            c.donor, c.cv.dk, c.cv.dn, c.cv.k, c.cv.n, table.concat(c.cv.hit, ' ')))
    end
    return lines
end

--- The live inputs: the running provider's source, tree-sitter's own capture list
--- and symbol table. Kept here so the tool and the spec cannot read them differently.
function M.live_opts()
    return {
        captures = function (lang, q)
            local okp, parsed = pcall(vim.treesitter.query.parse, lang, q)
            if not okp or not parsed then return nil, parsed end
            return parsed.captures
        end,
        provides = function (lang)
            local okl, loaded = pcall(vim.treesitter.language.add, lang)
            if not (okl and loaded) then return nil end
            local oki, info = pcall(vim.treesitter.language.inspect, lang)
            if not (oki and info and info.symbols) then return nil end
            local have = {}
            for s, named in pairs(info.symbols) do
                if named == true and not s:match('^"') then have[s] = true end
            end
            return have
        end,
    }
end

return M
