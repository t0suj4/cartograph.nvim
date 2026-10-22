-- cartograph.hostsummary — ONE SUMMARY OF A RUNTIME'S OWN LUA, read by flowtype and by effects (CART-1786; the user:
-- "build one shared summary of shared.lua for both"). Where a runtime's host functions ARE Lua — nvim's
-- vim/_core/shared.lua: vim.split, vim.tbl_*, vim.deepcopy — their summary is computed from that source, never listed:
-- flowtype solves the file ALONE once per public function, that function's parameters seeded with PLACEHOLDERS
-- (opts.phseed), and reads off the solved heap what it returns, what it stores into its parameters' paths, what it calls
-- through them, and which functions it reaches that the file does not hold (R.phsummary). effects reads a PROJECTION
-- of the same record (M.effects_sig). Keyed by profile signature key (`vim#split`, `vim.list#unique`).
--
-- PROVENANCE: the runtime's version and every source file's hash — the stamp a memo is keyed on; a source the tree
-- itself holds is no host (the corpus IS the runtime: the caller passes `have`).

local M = {}

local function sha(s) return vim.fn.sha256(s) end

--- the sources of `runtime` (spec/hostmodel/sources.lua under the profile's sig_source): { { rel, src } … }, the
--- profile, and the stamp of them — or nil
function M.sources(runtime)
    local P = require 'cartograph.spec.profile'
    local pr = P.load(runtime)
    if not (pr and pr.sig_source) then return nil end
    local list = {}
    for _, hs in ipairs(require('cartograph.flowtype').hostmodel_sources(runtime, pr.sig_source)) do
        list[#list + 1] = { hs[1]:match('^hostmodel:[^:]+:(.*)$'), hs[2] }
    end
    if #list == 0 then return nil end
    local parts = { runtime, tostring(pr.version) }
    for _, x in ipairs(list) do parts[#parts + 1] = x[1] .. '=' .. sha(x[2]) end
    return list, pr, table.concat(parts, ' ')
end

local MEMO = {}
M.stats = { memo = 0, disk = 0, computed = 0 } -- (how a summary was served: the tests read it)

-- ★ PERSISTED BY STAMP (CART-1789): every fresh process recomputed shared.lua's 37 records (~2 s; effects.summaries
-- paid it on every run). A summary depends on the runtime's SOURCES (the stamp: version + file hashes) and on the code
-- that derives it — flowtype, the extractor, the specs: the whole lua/cartograph tree this process LOADED (pinned,
-- CART-1431: never filed under an edit it has not run; ~110 ms). Stored in the stamp cache's blob store, which refuses a
-- value that would not round-trip; CARTOGRAPH_STAMPCACHE=0 turns it off
local function disk_key(stamp)
    local SC = require 'cartograph.stampcache'
    local here = vim.fn.fnamemodify((debug.getinfo(1, 'S').source:gsub('^@', '')), ':p:h')
    return SC.key({ 'hostsummary', stamp, tostring(SC.loaded_tree(here)) })
end

--- the summaries of `runtime`'s own Lua: { stamp, version, fns = { [sig key] = summary } } — nil when the runtime has
--- no Lua sources here. A summary: R.phsummary's record plus `name` and `fn` (the function's id in the private tree)
function M.of(runtime)
    local list, pr, stamp = M.sources(runtime)
    if not list then return nil end
    if MEMO[stamp] then M.stats.memo = M.stats.memo + 1; return MEMO[stamp] end
    local blob = require('cartograph.stampcache').blob('hostsummary')
    local key = disk_key(stamp)
    local got, found = blob.get(key)
    if found and type(got) == 'table' and got.stamp == stamp then
        M.stats.disk = M.stats.disk + 1
        MEMO[stamp] = got
        return got
    end
    M.stats.computed = M.stats.computed + 1
    local ts = require 'cartograph.providers.treesitter'
    local flowtype = require 'cartograph.flowtype'
    local dir = vim.fn.tempname()
    for _, x in ipairs(list) do
        local path = dir .. '/' .. x[1]
        vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
        local fd = assert(io.open(path, 'wb')); fd:write(x[2]); fd:close()
    end
    local data = ts.extract(dir)
    data.root = data.root or dir
    data.profile = runtime
    local byid = {}
    for _, n in ipairs(data.nodes or {}) do byid[n.id] = n end
    -- (a private store: the caller's graph is untouched — flowtype reads only these fields)
    local S = { data = data, generation = 1, node = function (id) return byid[id] end }
    local out = { stamp = stamp, version = pr.version, fns = {} }
    for _, n in ipairs(data.nodes or {}) do
        local nm = type(n.name) == 'string' and n.name
        -- (a PUBLIC function: a field of a namespace table, `vim.split` / `vim.list.unique` — its signature key)
        local owner, mm
        if nm then owner, mm = nm:match('^([%a_][%w_%.]*)%.([%a_][%w_]*)$') end
        if owner and (n.kind == 'function' or n.kind == 'method') and not mm:match('^_') then
            local R = flowtype.solve(S, { open = false, ctx = false, hostmodels = false, phseed = n.id })
            local sm = R.phsummary and R.phsummary()
            if sm then
                sm.name, sm.fn = nm, n.id
                out.fns[owner .. '#' .. mm] = sm
            end
        end
    end
    vim.fn.delete(dir, 'rf')
    MEMO[stamp] = out
    local _, why = blob.put(key, out)
    M.last_put = why -- (a refusal named, never silent: nil when stored)
    return out
end

function M._forget() MEMO = {} end -- (the process memo only: the next M.of reads the disk)

local MMEMO = {}

--- the summaries of a KEYED host model (spec/hostmodel/<runtime>.lua, a spec's opts.hostmodels): { [sig key] =
--- summary } — each function of its table solved alone with placeholder parameters, as a runtime's own Lua is. Memoized
--- by the model's text: flowtype applies these per call as edges instead of walking the model as one shared body
function M.of_model(name, src)
    local stamp = name .. ' ' .. sha(src)
    if MMEMO[stamp] then return MMEMO[stamp] end
    local ts = require 'cartograph.providers.treesitter'
    local flowtype = require 'cartograph.flowtype'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(dir .. '/x.lua', 'wb')); fd:write('return nil\n'); fd:close()
    local data = ts.extract(dir)
    data.root = data.root or dir
    local byid = {}
    for _, n in ipairs(data.nodes or {}) do byid[n.id] = n end
    local S = { data = data, generation = 1, node = function (id) return byid[id] end }
    local base = { open = false, ctx = false, phmodel = { name = name, src = src } }
    local R0 = flowtype.solve(S, base)
    local out = {}
    for _, key in ipairs(R0.hostkeys and R0.hostkeys() or {}) do
        local R = flowtype.solve(S, { open = false, ctx = false, phmodel = { name = name, src = src, key = key } })
        local sm = R.phsummary and R.phsummary()
        if sm then sm.name = key; out[key] = sm end
    end
    vim.fn.delete(dir, 'rf')
    MMEMO[stamp] = out
    return out
end

--- the EFFECTS projection of one summary: { pwx = { [j] = true }, calls = { [j] = true }, ext = { name… } } — the
--- positions it writes through, the positions it calls, and the functions it reaches that its file does not hold
function M.effects_sig(sm)
    local pwx, calls = {}, {}
    for _, st in ipairs(sm.stores or {}) do
        local at = st.at
        if at[1] == 'param' and type(at[2]) == 'number' then pwx[at[2]] = true end
    end
    -- (a call of anything the argument holds — `f(v)`, `opts.key(v)` — in the function's OWN run; a method call on the
    -- argument is its type's — `s:find()` — and a closure it returns calls later, when that closure runs)
    for _, c in ipairs(sm.calls or {}) do
        local cs = c.callee
        if cs[1] == 'param' and type(cs[2]) == 'number' and c.now and not c.method then calls[cs[2]] = true end
    end
    return { pwx = pwx, calls = calls, ext = sm.ext or {} }
end

return M
