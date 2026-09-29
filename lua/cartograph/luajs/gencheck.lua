-- cartograph.luajs.gencheck — BOUNDED-EXHAUSTIVE DIFFERENTIAL for the Lua→JS transliteration (CART-1206).
--
-- Every program of a FRAGMENT up to a size (cartograph.grammargen: productions DERIVED from a corpus, atoms supplied
-- by the fragment) is run under real Lua (tests/fixtures/luaref.lua: the standard print) and, transliterated
-- (cartograph.luajs), under node; each program's output is compared. The claim it earns is labelled with all four of
-- its parameters — "exhaustive to size N over the productions of CORPUS ∩ fragment F, atoms P" — and is never a claim
-- about Lua at large, nor promoted to proven by raising N (CART-0494).
--
-- ★ THE FUNNEL IS THE RESULT, NOT THE DIVERGENCE COUNT. A broken printer or harness makes every program fail to load,
-- and "0 diverged" prints just the same; so every stage is counted:
--   generated → parses (tree-sitter, no error) → loads (Lua's own `load`) → terminates (in-process screen: fuel on
--   every p()/c() call, an instruction-count hook with the JIT off) → emitted without refusal → compared → diverged
-- plus one column beside the funnel: programs Lua REJECTS that the emitter translates without a refusal (the emitter
-- is not a validator — a finding class, not a divergence).
--
-- THE HARNESS (the PRELUDE below, transliterated WITH the programs): p(k) prints its site number, c() returns the next
-- value of a fixed boolean sequence; both spend FUEL and raise a TABLE when it runs out (a table, so Lua's error
-- position prefix — a known gap — never enters the comparison); f0/f1/f2 return 0/1/2 values, pk returns its argument
-- count and its arguments; show(pcall(P[k], 'x', nil)) prints status, value count and values (tables by sorted
-- contents, functions by type, strings with a position prefix stripped).
local M = {}

M.PRELUDE = [[
local FUEL, CI = 0, 0
local SEQ = { true, false, true, true, false, false, true, false }
local function spend() FUEL = FUEL - 1; if FUEL < 0 then error({ fuel = true }) end end
local function p(k) spend(); print('p', k) end
local function c() spend(); CI = CI % #SEQ + 1; return SEQ[CI] end
local function F0() end
local function F1() return 1 end
local function F2() return 1, 2 end
local function PK(...) return select('#', ...), ... end
local f0, f1, f2, pk -- RESET before every program: a generated `f0 = {}` must not leak into the next one
local function val(v)
  local t = type(v)
  if t == 'string' then return (v:gsub('^[^:]*:%d+: ', '')) end
  if t == 'table' then
    if v.fuel == true then return 'FUEL' end
    local ks = {}
    for k in pairs(v) do ks[#ks + 1] = k end
    -- a KEY is shown by val too (a function key by its type, never its address — measured: 640 false divergences)
    table.sort(ks, function (a, b) return val(a) < val(b) end)
    local out = {}
    for _, k in ipairs(ks) do out[#out + 1] = val(k) .. '=' .. val(v[k]) end
    return '{' .. table.concat(out, ',') .. '}'
  end
  if t == 'function' then return t end
  return tostring(v)
end
local function show(ok, ...)
  local parts = { tostring(ok), tostring(select('#', ...)) }
  for i = 1, select('#', ...) do parts[#parts + 1] = val((select(i, ...))) end
  print(table.concat(parts, ' '))
end
local P = {}
]]
M.RUNNER = "for k = 1, #P do f0, f1, f2, pk = F0, F1, F2, PK; FUEL = 40; CI = 0; print('#' .. k); show(pcall(P[k], 'x', nil)) end\n"

local function set(l) local s = {} for _, k in ipairs(l) do s[k] = true end return s end

--- the FRAGMENTS (a measurement's own choice: which kinds, which atoms — the productions are the corpus's)
M.FRAGMENTS = {
    -- control flow: every nesting of if/elseif/else, loops, do, goto/labels, break, return; conditions opaque
    control = {
        root = 'block',
        kinds = set { 'block', 'if_statement', 'elseif_statement', 'else_statement', 'while_statement', 'repeat_statement',
            'do_statement', 'goto_statement', 'label_statement', 'break_statement', 'return_statement', 'expression_list',
            'for_statement', 'for_numeric_clause', 'true' },
        atoms = { identifier = { 'L', 'M' }, function_call = { 'p(#)', 'c()' }, unary_expression = { 'not c()' },
            number = { '0', '1', '2' } }, -- 0: a zero step counts UP in LuaJIT (the sign bit), a case the hand tests missed
    },
    -- value count: 0/1/2/n values through calls, argument lists, table tails, parentheses, varargs, locals, returns
    values = {
        root = 'block',
        kinds = set { 'block', 'return_statement', 'expression_list', 'function_call', 'arguments', 'parenthesized_expression',
            'vararg_expression', 'table_constructor', 'field', 'variable_declaration', 'assignment_statement', 'variable_list',
            'nil' },
        atoms = { identifier = { 'f0', 'f1', 'f2', 'pk' } },
    },
    -- coercion: arithmetic, concatenation, comparison, length, negation over numbers, numeric strings, nil, booleans
    coercion = {
        root = 'block',
        kinds = set { 'block', 'return_statement', 'expression_list', 'binary_expression', 'unary_expression',
            'parenthesized_expression', 'nil', 'true' },
        atoms = { number = { '1', '2.5' }, string = { '"10"', '"0x10"', '"a"' } },
    },
}

--- one program's text as a batch member (a single line: the generator's printer joins tokens with spaces)
local function member(i, body) return ('P[%d] = function (...) %s end\n'):format(i, body) end

--- the in-process screen: parses? loads? terminates? -> 'ok' | 'noparse' | 'noload' | 'nonterm'
local function screen(body)
    local wrapped = 'local P = {}\n' .. member(1, body)
    local okp, tree = pcall(function () return vim.treesitter.get_string_parser(wrapped, 'lua'):parse()[1] end)
    if not okp or not tree or tree:root():has_error() then return 'noparse' end
    local chunk = load('local p, c, f0, f1, f2, pk = ...\nreturn function (...) ' .. body .. ' end', '=gen', 't', {
        select = select, error = error })
    if not chunk then return 'noload' end
    local fuel = 40
    local function spend() fuel = fuel - 1; if fuel < 0 then error({ fuel = true }) end end
    local seq, ci = { true, false, true, true, false, false, true, false }, 0
    local fn = chunk(function () spend() end, function () spend(); ci = ci % #seq + 1; return seq[ci] end,
        function () end, function () return 1 end, function () return 1, 2 end,
        function (...) return select('#', ...), ... end)
    local jit_ = rawget(_G, 'jit')
    if jit_ then jit_.off() end
    local STEP = {}
    debug.sethook(function () error(STEP) end, '', 200000)
    local _, e = pcall(fn, 'x', nil)
    debug.sethook()
    if jit_ then jit_.on() end
    if e == STEP then return 'nonterm' end
    return 'ok'
end
M.screen = screen

local function run_cmd(cmd, env, timeout)
    local r = vim.system(cmd, { text = true, env = env, timeout = timeout }):wait()
    return r
end

--- split a batch's output into { [k] = text } by its `#k` markers
local function sections(out)
    local S, cur = {}, nil
    for line in (out .. '\n'):gmatch('(.-)\n') do
        local k = line:match('^#(%d+)$')
        if k then cur = tonumber(k); S[cur] = {}
        elseif cur then S[cur][#S[cur] + 1] = line end
    end
    for k, v in pairs(S) do S[k] = table.concat(v, '\n') end
    return S
end

--- run a fragment. opts: { G (grammargen.derive), name, fragment, max, min, batch (default 400), dir (scratch dir),
--- repo (for the pack and luaref), limit (stop after this many divergences) }
--- -> { funnel = { [size] = {...} }, total = {...}, diverged = { {size, text, lua, js, class} }, label }
function M.run(opts)
    local GG, L = require 'cartograph.grammargen', require 'cartograph.luajs'
    local frag = opts.fragment
    local F = GG.fragment(opts.G, frag)
    local dead = F.dead()
    if #dead > 0 then return nil, 'the fragment selects kinds with no derived production: ' .. table.concat(dead, ' ') end
    local dir, repo = opts.dir, opts.repo
    L.install_pack(dir)
    local env = L.run_env(dir, repo .. '/lua')
    local luaref = repo .. '/tests/fixtures/luaref.lua'
    local prelude_lines = select(2, M.PRELUDE:gsub('\n', ''))
    local res = { funnel = {}, total = {}, diverged = {}, rejects_translated = {}, tokens = {} }
    local COLS = { 'generated', 'parses', 'loads', 'terminates', 'emitted', 'compared', 'diverged', 'rejects_translated' }
    for _, c in ipairs(COLS) do res.total[c] = 0 end
    local function bump(size, col)
        res.funnel[size] = res.funnel[size] or {}
        res.funnel[size][col] = (res.funnel[size][col] or 0) + 1
        res.total[col] = res.total[col] + 1
    end
    local seq = 0
    local function write(path, s) local fd = assert(io.open(path, 'w')); fd:write(s); fd:close() end
    -- compare one batch of screened programs { {size, body} }: emit, drop refused, run both, bisect a failed JS run
    local function compare(items)
        if #items == 0 then return end
        seq = seq + 1
        local src = { M.PRELUDE }
        for i, it in ipairs(items) do src[#src + 1] = member(i, it.body) end
        src[#src + 1] = M.RUNNER
        local text = table.concat(src)
        local js, refusals = L.emit(text, 'gen.lua', { pack = './$pack.js' })
        if #refusals > 0 then
            local bad = {}
            for _, r in ipairs(refusals) do bad[r.line - prelude_lines] = true end
            local keep = {}
            for i, it in ipairs(items) do if not bad[i] then keep[#keep + 1] = it end end
            if #keep < #items then return compare(keep) end
            -- a refusal outside every program (the prelude or runner): report it once
            error('gencheck: the harness itself was refused: ' .. vim.inspect(refusals[1]))
        end
        for _, it in ipairs(items) do bump(it.size, 'emitted') end
        local lf, jf = ('%s/b%d.lua'):format(dir, seq), ('%s/b%d.js'):format(dir, seq)
        write(lf, text); write(jf, js)
        local lr = run_cmd({ 'nvim', '--headless', '-u', 'NONE', '-l', luaref, lf }, nil, 120000)
        local LS = sections(lr.stdout or '')
        local function js_run(list)
            -- a JS run covers `list` (batch indexes); a failed run (non-zero exit: a LuaBreak escapes pcall by design,
            -- a JS error, a timeout) is bisected down to the program that causes it
            local sub = { M.PRELUDE }
            for i, ix in ipairs(list) do sub[#sub + 1] = member(i, items[ix].body) end
            sub[#sub + 1] = M.RUNNER
            local sjs = #list == #items and js or L.emit(table.concat(sub), 'gen.lua', { pack = './$pack.js' })
            local sf = ('%s/b%d_%d.js'):format(dir, seq, list[1])
            write(sf, sjs)
            local jr = run_cmd({ 'node', sf }, env, 30000)
            local JS = sections(jr.stdout or '')
            if jr.code ~= 0 or jr.signal ~= 0 then
                if #list == 1 then
                    local it = items[list[1]]
                    bump(it.size, 'compared'); bump(it.size, 'diverged')
                    local why = (jr.stderr or ''):match('[%w]*Error[^\n]*') or (jr.stderr or ''):match('[^\n]+') or ('signal ' .. tostring(jr.signal))
                    res.diverged[#res.diverged + 1] = { size = it.size, text = it.body, lua = LS[list[1]], js = why,
                        class = (jr.signal ~= 0 or jr.code == 124) and 'hang' or 'crash' }
                    return
                end
                local mid = math.floor(#list / 2)
                js_run({ unpack(list, 1, mid) })
                js_run({ unpack(list, mid + 1) })
                return
            end
            for i, ix in ipairs(list) do
                local it = items[ix]
                bump(it.size, 'compared')
                -- the POPULATION census: how many compared programs hold each keyword/punctuation token (a claim about
                -- gotos needs gotos in the compared set — a uniform zero here is a fragment that never reached them)
                local seen = {}
                for tok in it.body:gmatch('%S+') do
                    if not seen[tok] and (tok:match('^%a+$') or tok:match('^%p+$')) then
                        seen[tok] = true
                        res.tokens[tok] = (res.tokens[tok] or 0) + 1
                    end
                end
                local a, b = LS[ix], JS[i]
                if a ~= b then
                    bump(it.size, 'diverged')
                    local class = 'value'
                    if a and b then
                        local sa, sb = a:match('([^\n]*)$'), b:match('([^\n]*)$')
                        if sa:match('^false 1 ') and sb:match('^false 1 ') and a:gsub('[^\n]*$', '') == b:gsub('[^\n]*$', '') then
                            class = 'message'
                        end
                    end
                    res.diverged[#res.diverged + 1] = { size = it.size, text = it.body, lua = a, js = b, class = class }
                end
            end
        end
        local all = {}
        for i = 1, #items do all[i] = i end
        js_run(all)
    end
    local pending, rejected = {}, {}
    local function flush()
        compare(pending); pending = {}
        if #rejected > 0 then
            -- programs Lua REJECTS: does the emitter translate them without a refusal? (one emit for the lot)
            local src = { M.PRELUDE }
            for i, it in ipairs(rejected) do src[#src + 1] = member(i, it.body) end
            local _, refusals = L.emit(table.concat(src), 'gen.lua', {})
            local bad = {}
            for _, r in ipairs(refusals) do bad[r.line - prelude_lines] = true end
            for i, it in ipairs(rejected) do
                if not bad[i] then
                    bump(it.size, 'rejects_translated')
                    if #res.rejects_translated < 20 then res.rejects_translated[#res.rejects_translated + 1] = it.body end
                end
            end
            rejected = {}
        end
    end
    local batch = opts.batch or 400
    for n = opts.min or 1, opts.max do
        F.each(frag.root, n, function (tokens)
            local body = GG.print(tokens)
            bump(n, 'generated')
            local s = screen(body)
            if s == 'noparse' then return end
            bump(n, 'parses')
            if s == 'noload' then rejected[#rejected + 1] = { size = n, body = body }; if #rejected >= batch then flush() end return end
            bump(n, 'loads')
            if s == 'nonterm' then return end
            bump(n, 'terminates')
            pending[#pending + 1] = { size = n, body = body }
            if #pending >= batch then flush() end
        end)
        flush()
        if opts.limit and #res.diverged >= opts.limit then break end
    end
    -- ★ THE GATE on the census: every token of every production of a selected kind must appear in at least one
    -- COMPARED program, or the claim is vacuous for it (measured: `goto` was generated 2012 times and compared 0)
    res.unreached = {}
    for k in pairs(frag.kinds) do
        for _, p in ipairs((opts.G.kinds[k] or { prods = {} }).prods) do
            for _, it in ipairs(p.items) do
                if it.tok and not res.tokens[it.tok] then res.unreached[it.tok] = true end
            end
        end
    end
    res.unreached = vim.tbl_keys(res.unreached)
    table.sort(res.unreached)
    -- the label must let a later reader RE-CHECK it: the corpus at a revision (its content changes every commit), and
    -- that the productions are WIDENED (runs + alternation), not the corpus's raw ones
    res.label = ('exhaustive to size %d over the productions (runs + alternation widened) of %s%s ∩ fragment %s, atoms %s'):format(opts.max,
        opts.corpus or '?', opts.rev and (' @' .. opts.rev) or '', opts.name or '?', vim.inspect(frag.atoms, { newline = '', indent = '' }))
    res.cols = COLS
    return res
end

return M
