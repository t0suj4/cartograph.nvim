-- MUTATION-CAMPAIGN (discovery, CART-1480): HOW STRONG ARE THE TESTS OF ONE MODULE? Mechanical mutants of `file`, each
-- run against exactly the specs that EXECUTE its line (a per-spec coverage map: `COVER=<map> COVER_SPEC=1 bash
-- tests/run.sh`), in a scratch copy of the repo — the working tree is never written.
--   OPERATORS (on the syntax tree, one mutant per site): == <-> ~=, < -> <=, <= -> <, > -> >=, >= -> >, and <-> or,
--   + <-> -, `not x` -> `x`, an if's condition -> true / false, a call statement deleted, `return e` -> `return nil`,
--   a number literal n -> n + 1.
--   Each mutant is GROUND and anchored on its WHOLE LINE; a line that is not unique in the file is skipped, counted.
-- CLASSES: killed (a covering spec failed) | survived (covering specs ran and passed: a WEAK ASSERTION, or an
-- EQUIVALENT mutant — a list to review, not a defect list) | unreached (no spec executes the line: no test at all) |
-- timeout (a covering spec ran past `timeout_x` times its baseline, floor 20 s: a hang is not a kill).
-- ★ GUARDS (the hand loop's failures, by name): every spec set's BASELINE runs twice in the copy, and a spec that fails
-- or disagrees with itself is excluded (a red baseline kills everything; a flaky one kills at random); the original
-- text is restored after every mutant and its HASH checked (a mutant left in place poisons the next); the copy has
-- its own XDG_CACHE_HOME. CONTROLS, both sides, before a score is trusted: `known` = a line:op the caller knows is
-- caught must read killed (`control_kill`), and an unreached mutant is run once against the module's covering specs
-- and must survive (`control_unreached`).
-- CLAIM: the campaign ran and both controls behaved.
local SF = require 'cartograph.tactics.spec-fails'

local SWAP = { ['=='] = '~=', ['~='] = '==', ['<'] = '<=', ['<='] = '<', ['>'] = '>=', ['>='] = '>', ['and'] = 'or',
    ['or'] = 'and', ['+'] = '-', ['-'] = '+' }

--- the mutants of `src` -> { { line, col0, col1, text, op, before, after } }, skipped (non-unique lines)
local function mutants_of(src)
    local lines = vim.split(src, '\n', { plain = true })
    local count = {}
    for _, l in ipairs(lines) do count[l] = (count[l] or 0) + 1 end
    local root = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    local out, skipped = {}, 0
    local inext = require('cartograph.spec.tsutil').inext
    local function add(node, replacement, op)
        local sl, sc, el, ec = node:range()
        if sl ~= el then return end -- (single-line sites: the whole-line anchor must hold the whole site)
        local line = lines[sl + 1]
        if count[line] ~= 1 then skipped = skipped + 1; return end
        local after = line:sub(1, sc) .. replacement .. line:sub(ec + 1)
        if after == line then return end
        out[#out + 1] = { line = sl + 1, op = op, before = line, after = after }
    end
    local function text(n) return vim.treesitter.get_node_text(n, src) end
    local function walk(n)
        local t = n:type()
        if t == 'binary_expression' then
            local opn = n:child(1)
            local op = opn and opn:type()
            if op and SWAP[op] then add(opn, SWAP[op], op .. '->' .. SWAP[op]) end
        elseif t == 'unary_expression' then
            local opn = n:child(0)
            if opn and opn:type() == 'not' then add(n, text(n:named_child(0)), 'drop-not') end
        elseif t == 'if_statement' or t == 'elseif_statement' then
            local c = n:field('condition')[1]
            if c then add(c, 'true', 'cond->true'); add(c, 'false', 'cond->false') end
        elseif t == 'function_call' and n:parent() and (n:parent():type() == 'block' or n:parent():type() == 'chunk') then
            add(n, 'do end', 'drop-call')
        elseif t == 'return_statement' then
            local el = n:named_child(0)
            if el and text(el) ~= 'nil' then add(el, 'nil', 'return->nil') end
        elseif t == 'number' then
            local v = tonumber(text(n))
            if v and math.floor(v) == v then add(n, tostring(v + 1), 'n->n+1') end
        end
        for _, c in inext, n, -1 do walk(c) end
    end
    walk(root)
    return out, skipped
end

-- the coverage map -> { [line] = { spec = true } } for one file
local function covering(map_path, file)
    local by = {}
    local fd = io.open(map_path)
    if not fd then return nil, 'no coverage map at ' .. tostring(map_path) .. ' (COVER=<file> COVER_SPEC=1 bash tests/run.sh)' end
    local want = '\t' .. file .. ':'
    for l in fd:lines() do
        local s, e = l:find(want, 1, true)
        if s then
            local spec = l:sub(1, s - 1)
            local ln = tonumber(l:sub(e + 1))
            if ln then by[ln] = by[ln] or {}; by[ln][spec] = true end
        end
    end
    fd:close()
    return by
end

local function keys(set) local k = vim.tbl_keys(set or {}); table.sort(k); return k end

local function measure(_, p)
    local repo = p.repo or vim.fn.fnamemodify(debug.getinfo(1, 'S').source:gsub('^@', ''), ':p'):gsub('/lua/cartograph/tactics/[^/]*$', '')
    local fd = io.open(repo .. '/' .. p.file)
    if not fd then return { error = 'cannot read ' .. p.file } end
    local src = fd:read('a'); fd:close()
    local cover, cwhy = covering(p.cover, p.file)
    if not cover then return { error = cwhy } end
    local mutants, skipped = mutants_of(src)
    if p.limit then mutants = vim.list_slice(mutants, 1, tonumber(p.limit)) end
    local MC = require 'cartograph.tactics.mutation-check'
    local root, rwhy = MC.scratch_copy(repo)
    if not root then return { error = rwhy } end
    local env = { XDG_CACHE_HOME = root .. '/.campaign-cache' }
    local target = root .. '/' .. p.file
    local original_hash = vim.fn.sha256(src)
    local function write(text) local f = assert(io.open(target, 'w')); f:write(text); f:close() end
    -- BASELINES: each spec alone, twice; a spec red or self-disagreeing is excluded by name
    local base, excluded = {}, {}
    local function baseline(spec)
        if base[spec] ~= nil or excluded[spec] then return base[spec] end
        local runs = {}
        for i = 1, 2 do
            local t0 = vim.uv.hrtime()
            local r = SF.run(root, spec, 600000, env)
            runs[i] = { r = r, ms = (vim.uv.hrtime() - t0) / 1e6 }
        end
        local a, b = runs[1].r, runs[2].r
        if not (a and b) or a.failed > 0 or b.failed > 0 or a.passed ~= b.passed then
            excluded[spec] = ('baseline %s / %s'):format(a and a.summary or '?', b and b.summary or '?')
            return nil
        end
        base[spec] = math.max(runs[1].ms, runs[2].ms)
        return base[spec]
    end
    local results, counts = {}, { killed = 0, survived = 0, unreached = 0, timeout = 0, excluded = 0, error = 0 }
    local function run_mutant(m, specs)
        -- (by LINE NUMBER: a unique line can still occur as a substring of another)
        local ls = vim.split(src, '\n', { plain = true })
        assert(ls[m.line] == m.before, 'the mutant\'s line moved')
        ls[m.line] = m.after
        write(table.concat(ls, '\n'))
        local cls, failures = 'survived', {}
        local t0 = vim.uv.hrtime()
        for _, spec in ipairs(specs) do
            local limit = math.max(20000, (base[spec] or 1000) * tonumber(p.timeout_x or 5))
            local r = SF.run(root, spec, limit, env)
            if not r then cls = 'error'; failures[#failures + 1] = spec .. ': no summary line (a run that cannot be read is no kill)'; break end
            if r.timed_out then cls = 'timeout'; break end
            if r.failed > 0 then
                cls = 'killed'
                for _, f in ipairs(r.failures or {}) do failures[#failures + 1] = spec .. ': ' .. f end
                break
            end
        end
        write(src)
        local fh = io.open(target); local now = fh:read('a'); fh:close()
        if vim.fn.sha256(now) ~= original_hash then error('the original was not restored after a mutant: ' .. target) end
        return cls, failures, (vim.uv.hrtime() - t0) / 1e9
    end
    local all_specs = {}
    for _, set in pairs(cover) do for s in pairs(set) do all_specs[s] = true end end
    local control_unreached
    for _, m in ipairs(mutants) do
        local specs = {}
        for _, s in ipairs(keys(cover[m.line])) do if baseline(s) then specs[#specs + 1] = s end end
        -- (FASTEST FIRST: a kill stops the mutant, so the cheapest covering spec usually decides it)
        table.sort(specs, function (a, b) if base[a] ~= base[b] then return base[a] < base[b] end return a < b end)
        local row = { line = m.line, op = m.op, before = vim.trim(m.before), after = vim.trim(m.after) }
        if not cover[m.line] then
            row.class = 'unreached'
            -- the control: ONE unreached mutant against every spec that covers the module must survive
            if not control_unreached then
                local cs = {}
                for _, s in ipairs(keys(all_specs)) do if baseline(s) then cs[#cs + 1] = s end end
                local cls = run_mutant(m, cs)
                control_unreached = { line = m.line, op = m.op, class = cls, held = cls == 'survived' }
            end
        elseif #specs == 0 then
            row.class = 'excluded'
        else
            row.class, row.failures, row.secs = run_mutant(m, specs)
            row.specs = specs
        end
        counts[row.class] = counts[row.class] + 1
        results[#results + 1] = row
    end
    -- the control on the other side: a site the caller KNOWS is caught (line:op)
    local control_kill
    if p.known then
        local kl, kop = p.known:match('^(%d+):(.+)$')
        for _, r in ipairs(results) do
            if tostring(r.line) == kl and r.op == kop then control_kill = { line = r.line, op = r.op, class = r.class, held = r.class == 'killed' } end
        end
        control_kill = control_kill or { held = false, missing = p.known }
    end
    vim.fn.delete(root, 'rf')
    local executed = vim.tbl_count(cover)
    local total = #results
    return { file = p.file, mutants = total, skipped_lines = skipped, counts = counts, executed_lines = executed,
        kill_rate = (counts.killed) / math.max(1, counts.killed + counts.survived), results = results,
        excluded_specs = excluded, control_kill = control_kill, control_unreached = control_unreached }
end

local E = {
    name = 'mutation-campaign',
    kind = 'discovery',
    tags = { 'accept', 'repo' },
    measures = 'CART-1480',
    summary = 'how strong are a module\'s tests? mechanical mutants of `file` (== ~=, < <=, and or, not, if-conditions, deleted calls, return nil, n+1), each run against the specs that EXECUTE its line (cover = a COVER_SPEC=1 map), in a scratch copy: killed / survived (weak assertion or equivalent: review) / unreached / timeout; baselines twice, restores hash-checked; controls: known = line:op must be killed, one unreached mutant must survive',
    params = { file = 'string', cover = 'string', known = 'string?', limit = 'string?', timeout_x = 'string?', repo = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        if v.control_kill and not v.control_kill.held then
            return false, ('the KILL control did not hold: %s read %s'):format(tostring(v.control_kill.missing or (v.control_kill.line .. ':' .. v.control_kill.op)), tostring(v.control_kill.class or 'no such mutant'))
        end
        if v.control_unreached and not v.control_unreached.held then
            return false, ('the UNREACHED control was killed (line %d %s): the coverage map misses a spec that executes it'):format(v.control_unreached.line, v.control_unreached.op)
        end
        local c = v.counts
        return true, ('%s: %d mutants — killed %d, survived %d, unreached %d, timeout %d, excluded %d; kill rate %.0f%% of the reached'):format(
            v.file, v.mutants, c.killed, c.survived, c.unreached, c.timeout, c.excluded, v.kill_rate * 100)
    end,
}

E.mutants_of = mutants_of
E.examples = {
    {
        name = 'the operators find their sites: a comparison, a boolean, a condition, a call statement, a return, a number',
        files = { ['m.lua'] = 'local M = {}\nfunction M.f(a, b)\n  if a == b and not a then print(1) end\n  return a + 2\nend\nreturn M\n' },
        params = function () return { file = 'm.lua', cover = '/nonexistent' } end,
        expect = { holds = false, check = function (v)
            local ops = {}
            for _, m in ipairs(mutants_of('local M = {}\nfunction M.f(a, b)\n  if a == b and not a then print(1) end\n  return a + 2\nend\nreturn M\n')) do ops[m.op] = (ops[m.op] or 0) + 1 end
            return ops['==->~='] == 1 and ops['and->or'] == 1 and ops['drop-not'] == 1 and ops['cond->true'] == 1 and ops['cond->false'] == 1
                and ops['drop-call'] == 1 and ops['return->nil'] == 2 and ops['+->-'] == 1 and ops['n->n+1'] == 2, vim.inspect(ops)
        end },
    },
}

return E
