-- CART-1057 / CART-1056: input-sized loop nesting across calls, and the fn_at index it led to.
-- ★ ACCEPTANCE ON A REAL TREE (tools/perfscan.lua lua/cartograph): the per-function lenses scored
-- 0 of 57 on the hot spot that made hive's extraction run for hours; loopcost reports it BLIND as a
-- `hidden-shared` scan (the pre-fix tree: fn_at at #28 and #29 of 105 in that class, 5,127 findings
-- over 4,549 functions in all). A shape, not a cost: ranking the true hot spot first needs a workload.
-- builtins.lua: what builtin calls cost (spec/lua_costs.lua) and how an UNKNOWN aggregates (a hole).
-- patterns.lua: what a search PATTERN adds (spec/lua_patterns.lua): a backtracking bound, as a hole.
-- Fixture: tests/fixtures/loopcost/shapes.lua, one arm per shape.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local loopcost = require 'cartograph.loopcost'

local FIX = vim.fn.getcwd() .. '/tests/fixtures/loopcost'

local function has_lua()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

local R
local function analyze()
    if R then return R end
    local data = ts.extract(FIX)
    store.ingest(data)
    R = loopcost.analyze(store, data)
    return R
end

-- the findings whose call reaches a callee named `name`
local function to(name)
    local out = {}
    for _, f in ipairs(analyze().findings) do
        if f.callee and f.callee:match('::' .. name .. '@') then out[#out + 1] = f end
    end
    return out
end

test('loopcost: ★ the fn_at shape — a scan of shared state per element of an accumulator is hidden-shared, found through LEXICAL scope', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = to('owner')
    eq(1, #f)
    eq('hidden-shared', f[1].kind)
    eq('lexical', f[1].how, 'two local `owner`s: name matching refuses, the enclosing function decides')
    -- ids carry 0-based lines: owner@15 is M.attribute's (line 16), M.other's is owner@28
    eq('shapes.lua::owner@15', f[1].callee)
    eq({ 'byfile' }, f[1].shared)
    eq('pending', f[1].accumulator)
    eq(2, f[1].depth)
end)

test('loopcost: a FAN-OUT over the element\'s own parts is hidden, never shared (the loop binder is subtracted)', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = to('count_parts')
    eq(1, #f)
    eq('hidden', f[1].kind)
end)

test('loopcost: a WHILE over a counter reads shared state but is never SHARED', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = to('uid')
    eq(1, #f)
    eq('hidden', f[1].kind)
end)

test('loopcost: the iterator FUNCTION of lua\'s explicit triple is not what is iterated', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = to('walk')
    eq(1, #f)
    eq('hidden', f[1].kind, 'inext is an upvalue; counted as the collection it would read as shared')
end)

test('loopcost: a constant list and an ALL-CAPS constant are bounded: no finding', function ()
    if not has_lua() then skip 'no lua parser' end
    eq(0, #to('flags'))
    -- the vacuity guard: the lens did analyse the fixture's loops
    local st = analyze().stats
    ok(st.analysed >= 10 and st.input_loops >= 8, vim.inspect(st))
end)

test('loopcost: a call OUTSIDE every loop still carries its callee\'s depth (a wrapper around a looping helper)', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = to('wrapped')
    eq(1, #f)
    eq(2, f[1].depth)
end)

test('loopcost: the cockpit report names the caller that multiplies the focused fn, and the fn\'s own nesting', function ()
    if not has_lua() then skip 'no lua parser' end
    analyze()
    local txt = table.concat(loopcost.report(store, 'shapes.lua::owner@15'), '\n')
    ok(txt:find('CALLED INSIDE INPUT%-SIZED LOOPS %(1%)'), txt)
    ok(txt:find('shapes.lua:24 ', 1, true) and txt:find('hidden-shared', 1, true), txt)
    local own = table.concat(loopcost.report(store, 'shapes.lua::M.attribute@6'), '\n')
    ok(own:find('ITS OWN NESTING %(1%)'), own)
end)

-- the findings made inside function `fnname` (a builtins.lua function id prefix)
local function in_fn(fnname)
    local out = {}
    for _, f in ipairs(analyze().findings) do
        if f.fn:match('^builtins%.lua::' .. fnname:gsub('%.', '%%.') .. '@') then out[#out + 1] = f end
    end
    return out
end

test('builtins: table.sort of an input-sized list per element is CERTIFIED depth 2 (n log n counts one level)', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = in_fn('M.sort_each')
    eq(1, #f)
    eq('hidden', f[1].kind); eq(2, f[1].depth); eq('table.sort', f[1].builtin)
    ok(f[1].inner.log, 'nlogn is recorded')
end)

test('builtins: the ARITY decides — table.remove(q, 1) shifts (depth 2), table.insert(out, x) appends (nothing)', function ()
    if not has_lua() then skip 'no lua parser' end
    local d = in_fn('M.drain')
    eq(1, #d); eq('table.remove', d[1].builtin); eq(2, d[1].depth)
    eq(0, #in_fn('M.collect'), 'an append is a cited constant: no finding, no hole')
end)

test('builtins: ★ an UNKNOWN call is a HOLE — depth >=1 with the name and class, never a zero and never a guess', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = in_fn('M.scan_all')
    eq(1, #f)
    eq('possible', f[1].kind); eq(1, f[1].depth)
    eq('unknown_lib.scan', f[1].holes[1].name); eq('uncosted', f[1].holes[1].class)
    eq('>=1', loopcost.depth_text(f[1]))
    -- the work list the unknowns make
    local wl
    for _, w in ipairs(analyze().worklist) do if w.name == 'unknown_lib.scan' then wl = w end end
    ok(wl and wl.findings == 1 and wl.class == 'uncosted', vim.inspect(analyze().worklist))
end)

test('builtins: vim.tbl_contains over SHARED state per element of an accumulator is hidden-shared: the fn_at shape without a user callee', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = in_fn('M.dedupe')
    eq(1, #f)
    eq('hidden-shared', f[1].kind); eq({ 'registry' }, f[1].shared); eq('pending', f[1].accumulator)
end)

test('builtins: pcall INVOKES its function argument: a looping helper passed by name costs through it', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = in_fn('M.guarded')
    eq(1, #f)
    eq('hidden', f[1].kind); eq(2, f[1].depth); eq('pcall', f[1].builtin)
end)

test('builtins: a string METHOD on the loop binder is bounded; on a parameter scanned per element it is linear BY NAME', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = in_fn('M.words')
    eq(1, #f)
    eq(':find', f[1].builtin); ok(f[1].inner.by_name); eq('text', f[1].inner.argname)
end)

test('builtins: a METHOD\'s argv carries its receiver first — `sep:rep(3)` is bounded by its literal', function ()
    if not has_lua() then skip 'no lua parser' end
    eq(0, #in_fn('M.pad'))
end)

test('builtins: ★ holes AGGREGATE — a hole tied at the callee\'s certified depth travels to the caller as >=', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = in_fn('M.outer_scan')
    eq(1, #f)
    eq(2, f[1].depth); eq('>=2', loopcost.depth_text(f[1]))
    eq('unknown_lib.scan', f[1].holes[1].name)
end)

test('builtins: ★ RECURSION is a hole, decided by the call graph\'s components — the same answer in any visiting order', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = in_fn('M.walk_forest')
    eq(1, #f)
    eq(2, f[1].depth, 'the forest loop x the kids loop')
    -- INSIDE the component a call costs only the hole: walk_kids' loop over a call to walk_tree
    -- (which has a loop of its own) is >=1, not a certified 2 — a recursive walk is linear
    local wk = in_fn('walk_kids')
    eq(1, #wk)
    eq('possible', wk[1].kind); eq('>=1', loopcost.depth_text(wk[1]))
    local cy = in_fn('M.cycle_each')
    eq(1, #cy)
    eq(2, cy[1].depth, 'entering the 3-cycle at B runs C\'s loop: ' .. loopcost.chain(cy[1]))
    local rec = false
    for _, h in ipairs(f[1].holes or {}) do if h.class == 'recursive' then rec = true end end
    ok(rec, 'the recursion it closes is a named hole: ' .. loopcost.chain(f[1]))
    -- determinism: reverse the node order and ask again
    local data = ts.extract(FIX)
    local rev = {}
    for i = #data.nodes, 1, -1 do rev[#rev + 1] = data.nodes[i] end
    data.nodes = rev
    store.ingest(data)
    local R2 = loopcost.analyze(store, data)
    local a, b = {}, {}
    for _, x in ipairs(analyze().findings) do a[#a + 1] = x.fn .. '|' .. x.line .. '|' .. x.kind .. '|' .. loopcost.depth_text(x) end
    for _, x in ipairs(R2.findings) do b[#b + 1] = x.fn .. '|' .. x.line .. '|' .. x.kind .. '|' .. loopcost.depth_text(x) end
    table.sort(a); table.sort(b)
    eq(a, b)
end)

-- the findings made inside patterns.lua function `fnname`
local function in_pat(fnname)
    local out = {}
    for _, f in ipairs(analyze().findings) do
        if f.fn:match('^patterns%.lua::' .. fnname:gsub('%.', '%%.') .. '@') then out[#out + 1] = f end
    end
    return out
end
local function hole_classes(f)
    local out = {}
    for _, h in ipairs(f.holes or {}) do out[#out + 1] = h.class end
    table.sort(out)
    return out
end

test('patterns: the backtracking DEGREE of a Lua pattern (an upper bound; overlap decided by Lua\'s own matcher)', function ()
    local deg = require('cartograph.spec.lua_patterns').degree
    local cases = {
        { 'abc', 1 }, { '^abc', 1 }, { '%s*x', 2 }, { '^%s*x', 1 }, { '^(.-)%s*$', 2 },
        { '^%s*(.-)%s*$', 3 }, { '^%d+%.%d+$', 1 }, { '(%w+)=(%w+)', 2 }, { '%b()', 2 },
        { '^[%w_]+$', 1 }, { '.*,.*', 3 }, { '^([^=]+)=(.*)$', 1 }, { '%f[%w]foo', 1 },
        { '([^/]+)$', 2 }, { '%.([%w]+)$', 1 }, { 'x.-y', 2 },
    }
    for _, c in ipairs(cases) do eq(c[2], deg(c[1]), c[1]) end
    -- gmatch (5.1/LuaJIT): a leading ^ is a LITERAL character (measured: '^%s*x' over '^ x ab ^x' yields
    -- '^ x' and '^x'), so it is a bounded first item disjoint from %s — degree 1; unanchored %s*x is 2
    eq(1, deg('^%s*x', true)); eq(2, deg('%s*x', true))
    eq(1, deg('^.*x')); eq(2, deg('^.*x', true), 'a literal ^ that `.` swallows: the scan stays')
end)

test('patterns: ★ the trim idiom per element is certified 2 PLUS a backtrack hole — the bound is a hole, never certified', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = in_pat('M.trim_each')
    eq(1, #f)
    eq(2, f[1].depth); eq({ 'backtrack' }, hole_classes(f[1])); eq(3, f[1].holes[1].degree)
    -- a backtrack hole is BOUNDED: certified 2, at most 2 + (3 - 1)
    eq(4, loopcost.upper(f[1])); eq('2..4', loopcost.depth_text(f[1]))
    -- an unbounded hole keeps the bound open
    eq(math.huge, loopcost.upper(in_pat('M.dyn_each')[1])); eq('>=2', loopcost.depth_text(in_pat('M.dyn_each')[1]))
end)

test('patterns: a PLAIN find and an anchored single run add no hole; a pattern in a variable is a dynamic hole', function ()
    if not has_lua() then skip 'no lua parser' end
    eq({}, hole_classes(in_pat('M.plain_each')[1]))
    local d = in_pat('M.digits_each')[1]
    eq({}, hole_classes(d)); eq(1, d.inner.degree)
    eq({ 'dynamic' }, hole_classes(in_pat('M.dyn_each')[1]))
    eq(0, #in_pat('M.trim_lines'), 'a bounded subject: backtracking multiplies nothing input-sized')
end)

test('patterns: ★ a receiver is classed by its TEXT — a call result is a hole, a field of a param is certified', function ()
    if not has_lua() then skip 'no lua parser' end
    local sl = in_pat('M.slice_each')[1]
    eq('possible', sl.kind); eq(1, sl.depth); eq({ 'dynamic' }, hole_classes(sl))
    local fe = in_pat('M.field_each')[1]
    eq(2, fe.depth); eq({ 'backtrack' }, hole_classes(fe)); eq('2..3', loopcost.depth_text(fe))
    eq('cfg', fe.inner.argname)
    eq('(.-)\n%-', require('cartograph.spec.lua_patterns').unescape('(.-)\\n%-'), 'short-string escapes decoded')
end)

test('patterns: gmatch scans every start of an unanchored run — degree 2, a hole', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = in_pat('M.words_each')[1]
    eq({ 'backtrack' }, hole_classes(f)); eq(2, f.holes[1].degree)
end)

test('builtins: a constructor of non-literal elements is BOUNDED (as many as it spells); a deep module call is not the collection', function ()
    if not has_lua() then skip 'no lua parser' end
    eq(0, #in_fn('M.decl_like'), vim.inspect(vim.tbl_map(function(f) return loopcost.chain(f) end, in_fn('M.decl_like'))))
end)

test('builtins: ★ a MAYBE-LOOP (over a call result nobody sized) is a hole — the caller reads >=2, not 3 and not 2', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = in_fn('M.per_buf_each')
    eq(1, #f)
    eq(2, f[1].depth, loopcost.chain(f[1]))
    local maybe = false
    for _, h in ipairs(f[1].holes or {}) do
        if h.name == 'loop over vim.api.nvim_list_bufs()' and h.class == 'dynamic' then maybe = true end
    end
    ok(maybe, loopcost.chain(f[1]))
end)

test('fn_at index: innermost_index answers exactly what the linear scan answered (random nested ranges, columns, ties)', function ()
    local idx = ts._innermost_index
    ok(idx, 'treesitter exposes _innermost_index')
    -- the two scans it replaced, verbatim in behaviour
    local function scan_col(ranges, line, col)
        local best
        for _, r in ipairs(ranges) do
            local starts_before = r.s < line or (r.s == line and (col == nil or (r.sc or 0) <= col))
            if starts_before and line <= r.e and (not best or r.s >= best.s) then best = r end
        end
        return best
    end
    local function scan_line(ranges, line)
        local best
        for _, r in ipairs(ranges) do
            if r.s <= line and line <= r.e and (not best or r.s >= best.s) then best = r end
        end
        return best
    end
    math.randomseed(1056)
    local checked = 0
    for _ = 1, 200 do
        -- a random tree of ranges; siblings may SHARE a boundary line and a start line (same-line
        -- callbacks), and the list order is shuffled so the tie rule is exercised
        local ranges = {}
        local function gen(s, e, depth)
            local at = s
            while at < e and #ranges < 40 do
                local len = math.random(0, math.max(0, math.floor((e - at) / 2)))
                local r = { s = at, sc = math.random(0, 6), e = at + len, id = #ranges + 1 }
                ranges[#ranges + 1] = r
                if depth < 3 and len > 1 then gen(r.s, r.e, depth + 1) end
                at = r.e + math.random(0, 2)
            end
        end
        gen(0, 60, 0)
        for i = #ranges, 2, -1 do local j = math.random(i); ranges[i], ranges[j] = ranges[j], ranges[i] end
        local a, b = idx(ranges, true), idx(ranges, false)
        for line = -1, 62 do
            for _, col in ipairs({ false, 0, 3, 7 }) do
                local c = col or nil
                eq(scan_col(ranges, line, c), a(line, c))
                checked = checked + 1
            end
            eq(scan_line(ranges, line), b(line))
        end
    end
    ok(checked > 40000, 'queries compared: ' .. checked)
end)

-- concat.lua: an ACCUMULATING CONCATENATION (`s = s .. x`) is an operator with a cost — its target's size
local function in_concat(fnname)
    local out = {}
    for _, f in ipairs(analyze().findings) do
        if f.fn:match('^concat%.lua::' .. fnname:gsub('[%.:]', '%%%0') .. '@') then out[#out + 1] = f end
    end
    return out
end
local function concat_depth(fnname)
    for _, n in ipairs(store.data.nodes) do
        if n.id:match('^concat%.lua::' .. fnname:gsub('[%.:]', '%%%0') .. '@') then return analyze().depth_of(n.id) end
    end
end

test('concat: a local grown per element is VISIBLE depth 2; reset per outer element and grown per inner, depth 3', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = in_concat('M.join')
    eq(1, #f)
    eq('visible', f[1].kind)
    eq(2, f[1].depth)
    eq('s', f[1].concat.target)
    ok(loopcost.chain(f[1]):find('concat@10 grows s', 1, true), loopcost.chain(f[1]))
    local r = in_concat('M.rows')
    eq(1, #r)
    eq(3, r[1].depth, 'the outer loop re-declares s: it runs n times, it does not grow s')
end)

test('concat: a flushed buffer, a constant loop, a per-element field — no size grows, no finding', function ()
    if not has_lua() then skip 'no lua parser' end
    eq(0, #in_concat('M.wrap'))
    eq(0, #in_concat('M.pair'))
    eq(0, #in_concat('M.mark'))
    eq(1, concat_depth('M.wrap').c, 'the loop alone')
    eq(0, concat_depth('M.pair').c, 'a constant loop grows nothing: the concat costs nothing either')
    eq(0, #in_concat('M.shadow'))
    eq(1, concat_depth('M.shadow').c, '`local s = s .. x` binds anew each trip: the loop alone')
end)

test('concat: ★ an upvalue grown in a LOOP-FREE function, called per element, is hidden-shared depth 2', function ()
    if not has_lua() then skip 'no lua parser' end
    local f = to('note')
    eq(1, #f)
    eq('hidden-shared', f[1].kind)
    eq(2, f[1].depth)
    eq({ 'log' }, f[1].shared)
    local d = concat_depth('note')
    eq(1, d.c)
    ok(d.concat and d.concat.shared, 'the upvalue is state outliving the call')
end)

test('concat: a field of a PARAMETER arrives input-sized (depth 1) but is not shared state', function ()
    if not has_lua() then skip 'no lua parser' end
    local d = concat_depth('Buf:push')
    eq(1, d.c)
    eq('self.buf', d.concat.target)
    eq(nil, d.concat.shared)
end)

-- alloc.lua: the BYTES unit — one algebra, allocation sites for events, builtins priced by `alloc`
local RB
local function bytes()
    if RB then return RB end
    analyze()
    RB = loopcost.analyze(store, store.data, { unit = 'bytes' })
    return RB
end
local function alloc_depth(fnname, R)
    for _, n in ipairs(store.data.nodes) do
        if n.id:match('^alloc%.lua::' .. fnname:gsub('[%.:]', '%%%0') .. '@') then return (R or bytes()).depth_of(n.id) end
    end
end
-- THE ORACLE: run the fixture and measure the bytes it allocates at two sizes (GC stopped, JIT off,
-- distinct strings so nothing is interned twice); the growth exponent is log2 of the ratio
local function measured(fnname, extra)
    local F = dofile(FIX .. '/alloc.lua')
    local f = assert(F[fnname:match('[%w_]+$')])
    local function run(n)
        local xs = {}
        for i = 1, n do xs[i] = 'v' .. i end
        local arg2 = extra and extra(n) -- built OUTSIDE the measured window
        collectgarbage('collect'); collectgarbage('stop')
        local before = collectgarbage('count')
        local keep = f(xs, arg2)
        local kb = collectgarbage('count') - before
        collectgarbage('restart')
        return kb, keep
    end
    local jit_on = jit and jit.status and jit.status()
    if jit then jit.off() end
    local a, b = run(200), run(400)
    if jit and jit_on then jit.on() end
    if a <= 0 and b <= 0 then return 0 end -- nothing allocated at either size: bounded
    return math.log(b / a) / math.log(2)
end

test('bytes: ★ the static degree MATCHES the measured allocation growth, function by function', function ()
    if not has_lua() then skip 'no lua parser' end
    local cases = {
        { 'M.pairs_of', 2 },
        { 'M.members', 1, function(n) local ys = {} for i = 1, n do ys[i] = 'w' .. i end return ys end }, { 'M.grid', 2 }, { 'M.thunks', 1 }, { 'M.snapshots', 2 },
        { 'M.finds', 0, function(n) return ('x'):rep(n) end },
        { 'M.stepped', 1 }, { 'M.opts_once', 1 },
    }
    for _, cs in ipairs(cases) do
        local d = alloc_depth(cs[1])
        local e = measured(cs[1], cs[3])
        ok(math.abs(e - cs[2]) < 0.35, ('%s measured n^%.2f, expected %d'):format(cs[1], e, cs[2]))
        eq(cs[2], d.c, cs[1] .. ' static bytes degree')
        eq(0, d.holes and #d.holes or 0, cs[1] .. ' certified whole')
    end
end)

test('bytes: a scan that allocates nothing is time 2 but bytes 1 — the two units disagree where they should', function ()
    if not has_lua() then skip 'no lua parser' end
    eq(2, analyze().depth_of((function ()
        for _, n in ipairs(store.data.nodes) do if n.id:match('^alloc%.lua::M%.members@') then return n.id end end
    end)()).c)
    eq(1, alloc_depth('M.members').c)
end)

test('bytes: findings carry the unit and name the allocation site; a helper allocating per element is hidden', function ()
    if not has_lua() then skip 'no lua parser' end
    local got
    for _, f in ipairs(bytes().findings) do
        if f.callee and f.callee:match('^alloc%.lua::row@') then got = f end
    end
    ok(got, 'the call to row() per element')
    eq('hidden', got.kind)
    eq('bytes', got.unit)
    eq(2, got.depth)
    ok(loopcost.chain(got):find('alloc@29 table', 1, true), loopcost.chain(got))
end)

test('loopcost: a constructor KEY in a loop head is not an iterated name (time unit too)', function ()
    if not has_lua() then skip 'no lua parser' end
    for _, n in ipairs(store.data.nodes) do
        if n.id:match('^alloc%.lua::M%.opts_once@') then eq(1, analyze().depth_of(n.id).c, 'the inner loop walks a one-key constructor') end
        if n.id:match('^alloc%.lua::M%.stepped@') then eq(2, analyze().depth_of(n.id).c, 'time counts both loops') end
    end
end)

-- bounded.lua (CART-1065): a numeric for's trips bounded by its own start (math.min(X + K, n))
local function bounded_depth(fnname)
    for _, n in ipairs(store.data.nodes) do
        if n.id:match('^bounded%.lua::' .. fnname:gsub('[%.:]', '%%%0') .. '@') then return analyze().depth_of(n.id) end
    end
end

test('bounded: a numeric for bounded by math.min(start + K, n), or by start + K, is not input-sized', function ()
    if not has_lua() then skip 'no lua parser' end
    eq(0, bounded_depth('M.window').c)
    eq(0, bounded_depth('M.window_call').c, 'the same base through a call')
    eq(0, bounded_depth('M.four').c)
    eq(0, bounded_depth('M.window').holes and #bounded_depth('M.window').holes or 0, 'not a maybe-loop either')
end)

test('bounded: a min whose arguments both grow, or a non-literal step, stays input-sized', function ()
    if not has_lua() then skip 'no lua parser' end
    eq(1, bounded_depth('M.prefix').c)
    eq(1, bounded_depth('M.stepped').c)
end)

test('bounded: a caller running the bounded window per element is linear — no hidden finding', function ()
    if not has_lua() then skip 'no lua parser' end
    eq(1, bounded_depth('M.all').c)
    for _, f in ipairs(analyze().findings) do
        ok(not (f.callee and f.callee:match('^bounded%.lua::M%.window@')), 'finding through window: ' .. loopcost.chain(f))
    end
end)
