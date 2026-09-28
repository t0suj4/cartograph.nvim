-- cartograph.toolbelt — NAMED TACTICS, discovered from lua/cartograph/tactics/, each carrying the EXAMPLES that
-- explain it and test it (CART-1152's follow-on).
--
-- USER (2026-09-28): "I think we can now create a toolbelt of tactics" · "We can always parse the lua when we need it
-- as data" · "Recording the discoveries was there because we had no way to record the tactic concept" · "an example
-- (or several) can be a part of it, which explains usage and works also as a test".
--
-- So an entry is a PLAIN LUA FILE (its source is its serialized form — lift it with qlower when it is needed as data)
-- and there is NO CENTRAL LIST: dropping a file into tactics/ adds a tactic, which lets parallel sessions add their own
-- without sharing a registry. Two kinds:
--   write      a tactic TERM over write verbs:  build(params) -> term, run by tactic.run (forward recovery, stops only
--              on a decision), optionally accepted by the entry's `oracle`
--   discovery  a FINDING kept as the procedure that produced it: measure(store, params) -> value, and claim(value) ->
--              ok, why. The prose that used to record a discovery now points here; re-running says whether it still
--              holds. `measures` names the ticket whose claim it tracks.
-- Every entry carries `examples` = { { name, files, params(store) -> params, expect } }: the usage documentation, and
-- the toolbelt fence runs every one. An example's `expect` is checked against the run's result:
--   write:      { status = 'done' | 'stopped' | ..., applied = n?, check = fn(root, result) -> ok, why }
--   discovery:  { holds = true | false, check = fn(value) -> ok, why }
local M = {}

local REQUIRED = { name = 'string', kind = 'string', summary = 'string', examples = 'table' }
local KINDS = { write = true, discovery = true }

--- the directory the entries live in, derived from this module's own path
local function dir()
    local here = debug.getinfo(1, 'S').source:gsub('^@', '')
    return (here:gsub('toolbelt%.lua$', 'tactics'))
end

--- every entry file, by name -> path (no central list: the directory IS the list). `d` overrides the directory.
function M.files(d)
    local out = {}
    for _, path in ipairs(vim.fn.globpath(d or dir(), '*.lua', false, true)) do
        out[vim.fn.fnamemodify(path, ':t:r')] = path
    end
    return out
end

--- a loaded entry, or nil, why — the SHAPE is checked here, by name, not trusted
function M.load(name, d)
    local path = M.files(d)[name]
    if not path then return nil, ('no tactic `%s` in the toolbelt (%s)'):format(tostring(name), d or dir()) end
    local okl, e = pcall(dofile, path)
    if not okl then return nil, ('the tactic file %s raised: %s'):format(path, tostring(e)) end
    if type(e) ~= 'table' then return nil, ('%s returns no entry table'):format(path) end
    for field, ty in pairs(REQUIRED) do
        if type(e[field]) ~= ty then return nil, ('%s: `%s` must be a %s'):format(path, field, ty) end
    end
    if e.name ~= name then return nil, ('%s declares name `%s` — an entry is named by its FILE'):format(path, e.name) end
    if not KINDS[e.kind] then return nil, ('%s: kind `%s` is not write | discovery'):format(path, e.kind) end
    if e.kind == 'write' and type(e.build) ~= 'function' then return nil, path .. ': a write tactic needs build(params)' end
    if e.kind == 'discovery' and (type(e.measure) ~= 'function' or type(e.claim) ~= 'function') then
        return nil, path .. ': a discovery needs measure(store, params) and claim(value)'
    end
    if #e.examples == 0 then return nil, path .. ': at least one example — it is the usage AND the test' end
    e.path = path
    return e
end

--- every entry, loaded: { entries }, { broken = { name -> why } }
function M.list(d)
    local entries, broken = {}, {}
    local names = {}
    for name in pairs(M.files(d)) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local e, why = M.load(name, d)
        if e then entries[#entries + 1] = e else broken[name] = why end
    end
    return entries, broken
end

--- run an entry against the current graph.
--- write:     -> tactic.run's result (opts: apply, on_stop, correct), with the entry's oracle as the kernel
--- discovery: -> { value, holds, why }
function M.run(store, name, params, opts)
    opts = opts or {}
    local e, why = M.load(name, opts.dir)
    if not e then return nil, why end
    if e.kind == 'discovery' then
        local okm, value = pcall(e.measure, store, params or {})
        if not okm then return nil, ('%s: the measurement raised: %s'):format(name, tostring(value)) end
        local holds, cwhy = e.claim(value)
        return { value = value, holds = holds and true or false, why = cwhy }
    end
    local term = e.build(params or {})
    local ropts = { apply = opts.apply, on_stop = opts.on_stop, correct = opts.correct, verbs = opts.verbs }
    if e.oracle then ropts.oracle = function (st, res) return e.oracle(st, res, params or {}) end end
    return require('cartograph.tactic').run(store, term, ropts)
end

--- run ONE example of an entry on a fresh temp root: -> ok, why, result
function M.example(e, ex)
    local store = require 'cartograph.store'
    local root = vim.fn.tempname()
    for rel, text in pairs(ex.files or {}) do
        local d = (root .. '/' .. rel):match('^(.*)/[^/]*$')
        vim.fn.mkdir(d, 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    vim.fn.mkdir(root, 'p')
    store.ingest(require('cartograph.providers.treesitter').extract(root))
    local params = type(ex.params) == 'function' and ex.params(store) or (ex.params or {})
    local res, why = M.run(store, e.name, params, { apply = e.kind == 'write', on_stop = ex.on_stop,
        dir = e.path and vim.fn.fnamemodify(e.path, ':h') })
    if not res then return false, why end
    local want = ex.expect or {}
    if e.kind == 'discovery' then
        if want.holds ~= nil and res.holds ~= want.holds then
            return false, ('expected the claim to %s, it %s: %s'):format(want.holds and 'hold' or 'fail',
                res.holds and 'held' or 'failed', tostring(res.why)), res
        end
        if want.check then local okc, cw = want.check(res.value); if not okc then return false, cw, res end end
    else
        if want.status and res.status ~= want.status then
            return false, ('expected status %s, got %s (%s)'):format(want.status, tostring(res.status), tostring(res.why)), res
        end
        if want.applied and res.applied ~= want.applied then
            return false, ('expected %d applied, got %d'):format(want.applied, res.applied), res
        end
        if want.check then local okc, cw = want.check(root, res); if not okc then return false, cw, res end end
    end
    return true, nil, res
end

return M
