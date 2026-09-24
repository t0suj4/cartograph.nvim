-- lua_costs.lua — WHAT A BUILTIN CALL COSTS, for loopcost (CART-1057). `spec.lua.call_costs`.
--
-- USER (2026-09-24): "do it, we need to come up with how unknowns aggregate with other values".
-- A call with no graph node contributed depth 0 to loopcost, so `table.sort(bucket)` inside a loop
-- over every call site read like a constant. This table gives a builtin its cost; a call with no
-- entry is a HOLE (loopcost's unknowns), never a zero.
--
-- ── AN ENTRY ─────────────────────────────────────────────────────────────────────
--   cost   'const' | 'n' | 'nlogn'       the growth in ONE argument (nlogn counts as one loop level)
--   arg    which argument grows it: 1-based; 0 = the method's RECEIVER (`s:gsub(...)`)
--   arity  { [nargs] = <entry> }         an arity decides the shape (`table.insert(t, v)` appends,
--                                         `table.insert(t, pos, v)` shifts)
--   calls  { arg = k, per = 'element' | 'once' }   a function argument this builtin INVOKES:
--                                         per element (sort's comparator, gsub's replacement) adds its
--                                         cost under the builtin's own level; once (pcall) adds it flat
--   src    the citation. ★ A 'const' ENTRY SUPPRESSES A FINDING and must cite why it is constant
--          ([[cartograph-stdlib-profile]]: a fact that suppresses is a promise and needs a travelling
--          citation; one that produces is safe). 'n'/'nlogn' entries produce and cite what they read.
--   by_name  the entry matches a METHOD by its name alone (`x:match(p)`): the receiver's type is not
--          known, so the cost is believed by name and loopcost says so on the finding.
-- Keyed by the call's spelled name (`c.full`): 'table.sort', 'vim.tbl_contains'; a method by ':name'.
-- ⚠ vim.* ENTRIES ARE AN ENVIRONMENT (neovim 0.11.5's runtime), not the language. Each cites its
-- implementation line in runtime/lua/vim/shared.lua; derive them from that source instead of
-- declaring them (loopcost over the runtime) is the next rung.

local LUA51 = 'Lua 5.1 reference manual §5.5 (table manipulation)'
local SHARED = 'neovim 0.11.5 runtime/lua/vim/shared.lua:'
local FAST = 'LuaJIT fast function (a fixed number of VM operations; not measured here)'

return {
    -- ── table ──
    ['table.insert'] = { cost = 'n', arg = 1, src = LUA51 .. ': "shifting up other elements to open space"',
        arity = { [2] = { cost = 'const', src = LUA51 .. ': "The default value for pos is n+1" — an append shifts nothing' } } },
    ['table.remove'] = { cost = 'n', arg = 1, src = LUA51 .. ': "shifting down other elements to close up the space"',
        arity = { [1] = { cost = 'const', src = LUA51 .. ': "The default value for pos is n" — the last element, nothing shifts' } } },
    ['table.concat'] = { cost = 'n', arg = 1, src = LUA51 .. ': concatenates list[i..j], every element read' },
    ['table.sort'] = { cost = 'nlogn', arg = 1, calls = { arg = 2, per = 'element' },
        src = LUA51 .. ': sorts list elements in place (a comparison sort); comp is called per comparison' },
    ['table.maxn'] = { cost = 'n', arg = 1, src = LUA51 .. ': "the largest positive numerical index" — a traversal' },
    ['unpack'] = { cost = 'n', arg = 1, src = 'Lua 5.1 manual §5.1: returns the elements t[i..j]' },
    ['table.unpack'] = { cost = 'n', arg = 1, src = 'Lua 5.2+ manual §6.6: returns the elements t[i..j]' },
    -- ── string (functions and methods; the method is believed by NAME) ──
    ['string.find'] = { cost = 'n', arg = 1, src = 'Lua 5.1 manual §5.4.1: pattern matching scans the subject' },
    ['string.match'] = { cost = 'n', arg = 1, src = 'Lua 5.1 manual §5.4.1: pattern matching scans the subject' },
    ['string.gmatch'] = { cost = 'n', arg = 1, src = 'Lua 5.1 manual §5.4.1: iterates over the subject' },
    ['string.gsub'] = { cost = 'n', arg = 1, calls = { arg = 3, per = 'element' },
        src = 'Lua 5.1 manual §5.4.1: every match replaced; a function repl is called per match' },
    ['string.rep'] = { cost = 'n', arg = 2, src = 'Lua 5.1 manual §5.4: n copies of s' },
    ['string.lower'] = { cost = 'n', arg = 1, src = 'Lua 5.1 manual §5.4: a copy, every character' },
    ['string.upper'] = { cost = 'n', arg = 1, src = 'Lua 5.1 manual §5.4: a copy, every character' },
    ['string.reverse'] = { cost = 'n', arg = 1, src = 'Lua 5.1 manual §5.4: a copy, every character' },
    [':find'] = { cost = 'n', arg = 0, by_name = true, src = 'as string.find, believed by the method name' },
    [':match'] = { cost = 'n', arg = 0, by_name = true, src = 'as string.match, believed by the method name' },
    [':gmatch'] = { cost = 'n', arg = 0, by_name = true, src = 'as string.gmatch, believed by the method name' },
    [':gsub'] = { cost = 'n', arg = 0, by_name = true, calls = { arg = 2, per = 'element' },
        src = 'as string.gsub, believed by the method name' },
    [':rep'] = { cost = 'n', arg = 1, by_name = true, src = 'as string.rep, believed by the method name' },
    [':lower'] = { cost = 'n', arg = 0, by_name = true, src = 'as string.lower, believed by the method name' },
    [':upper'] = { cost = 'n', arg = 0, by_name = true, src = 'as string.upper, believed by the method name' },
    -- ── constant: each SUPPRESSES, each cites ──
    ['type'] = { cost = 'const', src = FAST },
    ['tostring'] = { cost = 'const', src = FAST .. '; a number or a __tostring metamethod aside' },
    ['tonumber'] = { cost = 'const', src = FAST },
    ['select'] = { cost = 'const', src = FAST .. " (select('#', ...) and small n)" },
    ['rawget'] = { cost = 'const', src = FAST }, ['rawset'] = { cost = 'const', src = FAST },
    ['rawequal'] = { cost = 'const', src = FAST }, ['rawlen'] = { cost = 'const', src = FAST },
    ['setmetatable'] = { cost = 'const', src = FAST }, ['getmetatable'] = { cost = 'const', src = FAST },
    ['assert'] = { cost = 'const', src = FAST }, ['error'] = { cost = 'const', src = FAST },
    ['next'] = { cost = 'const', src = FAST .. ' (one step of a traversal)' },
    ['ipairs'] = { cost = 'const', src = 'Lua 5.1 manual §5.1: returns an iterator; the WALK is the loop, which loopcost counts' },
    ['pairs'] = { cost = 'const', src = 'Lua 5.1 manual §5.1: returns next, t, nil; the WALK is the loop' },
    ['require'] = { cost = 'const', src = 'Lua 5.1 manual §5.3: "first checks package.loaded" — a loaded module is a lookup' },
    ['pcall'] = { cost = 'const', calls = { arg = 1, per = 'once' }, src = 'Lua 5.1 manual §5.1: calls f in protected mode' },
    ['xpcall'] = { cost = 'const', calls = { arg = 1, per = 'once' }, src = 'Lua 5.1 manual §5.1: calls f in protected mode' },
    ['string.byte'] = { cost = 'const', src = FAST .. ' (a few characters)' },
    ['string.char'] = { cost = 'const', src = FAST .. ' (a few characters)' },
    ['string.len'] = { cost = 'const', src = 'Lua strings carry their length (lstring.h TString.len)' },
    ['string.sub'] = { cost = 'const', src = FAST .. ' (proportional to the SLICE, usually short)' },
    [':sub'] = { cost = 'const', by_name = true, src = 'as string.sub, believed by the method name' },
    [':byte'] = { cost = 'const', by_name = true, src = 'as string.byte, believed by the method name' },
    [':len'] = { cost = 'const', by_name = true, src = 'as string.len, believed by the method name' },
    ['math.floor'] = { cost = 'const', src = FAST }, ['math.ceil'] = { cost = 'const', src = FAST },
    ['math.min'] = { cost = 'const', src = FAST .. ' (a few arguments)' },
    ['math.max'] = { cost = 'const', src = FAST .. ' (a few arguments)' },
    ['math.abs'] = { cost = 'const', src = FAST },
    ['math.random'] = { cost = 'const', src = FAST }, ['math.sqrt'] = { cost = 'const', src = FAST },
    ['os.time'] = { cost = 'const', src = FAST }, ['os.clock'] = { cost = 'const', src = FAST },
    -- ── neovim runtime (an ENVIRONMENT; each line read in shared.lua) ──
    ['vim.tbl_contains'] = { cost = 'n', arg = 1, src = SHARED .. '309 (a loop over t)' },
    ['vim.list_contains'] = { cost = 'n', arg = 1, src = SHARED .. '339 (a loop over t)' },
    ['vim.tbl_keys'] = { cost = 'n', arg = 1, src = SHARED .. '218 (pairs over t)' },
    ['vim.tbl_values'] = { cost = 'n', arg = 1, src = SHARED .. '235 (pairs over t)' },
    ['vim.tbl_count'] = { cost = 'n', arg = 1, src = SHARED .. '714 (pairs over t)' },
    ['vim.tbl_map'] = { cost = 'n', arg = 2, calls = { arg = 1, per = 'element' }, src = SHARED .. '253 (func per element)' },
    ['vim.tbl_filter'] = { cost = 'n', arg = 2, calls = { arg = 1, per = 'element' }, src = SHARED .. '271 (func per element)' },
    ['vim.tbl_extend'] = { cost = 'n', arg = 2, src = SHARED .. '429 (copies every argument table)' },
    ['vim.tbl_deep_extend'] = { cost = 'n', arg = 2, src = SHARED .. '450 (copies every argument table, deep)' },
    ['vim.deepcopy'] = { cost = 'n', arg = 1, src = SHARED .. '63 (every reachable value)' },
    ['vim.list_extend'] = { cost = 'n', arg = 2, src = SHARED .. '557 (appends src[start..finish])' },
    ['vim.list_slice'] = { cost = 'n', arg = 1, src = SHARED .. '732 (copies the slice)' },
    ['vim.split'] = { cost = 'n', arg = 1, src = SHARED .. '202 (gsplit over s)' },
    ['vim.gsplit'] = { cost = 'n', arg = 1, src = SHARED .. '106 (iterates s)' },
    ['vim.trim'] = { cost = 'n', arg = 1, src = SHARED .. '791 (a match over s)' },
    ['vim.islist'] = { cost = 'n', arg = 1, src = SHARED .. '682 (pairs over t)' },
    ['vim.tbl_islist'] = { cost = 'n', arg = 1, src = SHARED .. '667 (pairs over t)' },
    ['vim.isarray'] = { cost = 'n', arg = 1, src = SHARED .. '636 (pairs over t)' },
    ['vim.tbl_flatten'] = { cost = 'n', arg = 1, src = SHARED .. '576 (every nested element)' },
    ['vim.tbl_isempty'] = { cost = 'const', src = SHARED .. '357 (next(t) == nil: one step)' },
    ['vim.startswith'] = { cost = 'const', src = SHARED .. '811 (compares the prefix only)' },
    ['vim.endswith'] = { cost = 'const', src = SHARED .. '822 (compares the suffix only)' },
    ['vim.pesc'] = { cost = 'const', src = SHARED .. '801 (a gsub over the PATTERN, usually short)' },
    ['vim.uv.hrtime'] = { cost = 'const', src = 'libuv uv_hrtime: one clock read' },
}
