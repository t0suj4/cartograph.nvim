-- RECORD-FLOW (discovery, CART-1345): where does a record SHAPE go, across files? consumers.lua's field roster
-- follows a record into a same-file helper; a record passed to ANOTHER file's function was an `arg` escape — coverage
-- stopped there. This tactic iterates to a FIXPOINT over call edges: run the roster; for every `arg` escape, find the
-- call record at that line in the graph, take its RESOLVED target, and seed "parameter k of that function carries the
-- shape" (consumers' parameter seed); run again until no new seed appears. A call the graph did not resolve is a
-- NAMED FRONTIER row (file:line callee), never a silent stop.
-- params: fields / rooted / calls — the producers, as `name=kind` (consumers.lua's spec: fields default `any`, rooted
-- and calls default `list`); files — the scope (default: every .lua file of the graph); rounds — the cap (default 8).
-- CLAIM: the fixpoint was reached within the cap.
local C = require 'cartograph.consumers'
local cr = require 'cartograph.callrec'

local function kinds(items, default)
    local out = {}
    for _, it in ipairs(items or {}) do
        local name, kind = tostring(it):match('^([%w_.]+)=?(%a*)$')
        if name then out[name] = kind ~= '' and kind or default end
    end
    return out
end
local function tail(name) return tostring(name):match('([%w_]+)$') end

local E = {
    name = 'record-flow',
    kind = 'discovery',
    measures = 'CART-1345',
    summary = 'where a record shape goes ACROSS FILES: consumers.lua\'s roster iterated to a fixpoint over the graph\'s resolved call edges (an `arg` escape seeds the callee\'s parameter); fields / rooted / calls = producers as name=kind, files = scope, rounds = cap; unresolved calls are named frontier rows',
    params = { fields = 'list?', rooted = 'list?', calls = 'list?', files = 'list?', rounds = 'string?' },
    measure = function (store, p)
        local root = store.data.root
        local spec = { fields = kinds(p.fields, 'any'), rooted = kinds(p.rooted, 'list'), calls = kinds(p.calls, 'list'), params = {} }
        local files = p.files
        if not files then
            files = {}
            for _, f in ipairs(store.files or {}) do if f:match('%.lua$') then files[#files + 1] = f end end
        end
        -- the graph's call records by file:line (read through callrec: the call-record seam)
        local at = {}
        for _, c in cr.each(store.data) do
            local k = tostring(cr.file(c)) .. ':' .. tostring(cr.line(c))
            at[k] = at[k] or {}
            local l = at[k]
            l[#l + 1] = c
        end
        local seeded, nseeds, rounds, unresolved, r = {}, 0, 0, {}, nil
        local cap = tonumber(p.rounds or '8') or 8
        local fixpoint = false
        for _ = 1, cap do
            rounds = rounds + 1
            r = C.roster(root, files, spec)
            local new = 0
            unresolved = {}
            for _, row in ipairs(r.frontier) do
                if row.kind == 'arg' and row.idx then
                    local want = tostring(row.detail):gsub('%(%)$', '')
                    local hit = false
                    -- (the graph's call records count lines from 0, consumers.lua's rows from 1)
                    for _, c in ipairs(at[row.file .. ':' .. tostring(row.call_line - 1)] or {}) do
                        local full = cr.full(c) or cr.callee(c)
                        local to = cr.to(c) and store.node(cr.to(c))
                        if to and (full == want or tail(full) == tail(want)) and to.file then
                            hit = true
                            -- (a method call `o:m(x)` to a function declared `M.m(self, x)` shifts by the receiver)
                            local idx = row.idx + ((cr.method(c) and not tostring(to.name):find(':', 1, true)) and 1 or 0)
                            local key = to.file .. '|' .. tail(to.name) .. '|' .. idx .. '|' .. tostring(row.taint)
                            if not seeded[key] then
                                seeded[key] = true
                                nseeds, new = nseeds + 1, new + 1
                                spec.params[to.file] = spec.params[to.file] or {}
                                local l = spec.params[to.file]
                                l[#l + 1] = { name = tail(to.name), idx = idx, kind = row.taint }
                                -- (a callee outside the scope joins it: the shape went there)
                                local inscope = false
                                for _, f in ipairs(files) do if f == to.file then inscope = true end end
                                if not inscope then files[#files + 1] = to.file end
                            end
                        end
                    end
                    if not hit then unresolved[#unresolved + 1] = ('%s:%s %s'):format(row.file, tostring(row.call_line), want) end
                end
            end
            if new == 0 then fixpoint = true; break end
        end
        local reached = {}
        for _, s in ipairs(r.sites) do reached[s.file] = true end
        local nfiles = 0
        for _ in pairs(reached) do nfiles = nfiles + 1 end
        return { rounds = rounds, fixpoint = fixpoint, seeds = nseeds, derefs = #r.sites, by_path = r.by_path,
            files = nfiles, sites = r.sites, unresolved = unresolved, frontier = #r.frontier }
    end,
    claim = function (v)
        if not v.fixpoint then return false, ('no fixpoint within %d rounds (%d parameter seeds so far)'):format(v.rounds, v.seeds) end
        return true, ('fixpoint after %d round(s): %d deref site(s) in %d file(s), %d parameter seed(s) across files, %d unresolved call(s)')
            :format(v.rounds, v.derefs, v.files, v.seeds, #v.unresolved)
    end,
}

-- the fixture: a record built in a.lua, its `at` handed to b.lua's function, which reads `.line` — a reach the
-- roster alone stops at (an `arg` escape), and a second call b.lua does not define (unresolved, named)
local FILES = {
    ['a.lua'] = 'local B = require(\'b\')\nlocal M = {}\nfunction M.go(r)\n  return B.show(r.at), B.nowhere(r.at)\nend\nreturn M\n',
    ['b.lua'] = 'local M = {}\nfunction M.show(a)\n  return a.line + a.col\nend\nreturn M\n',
}

E.examples = {
    {
        name = 'a shape handed to ANOTHER file\'s function is followed into it: b.lua\'s reads of `.line` / `.col` are found',
        files = FILES, params = function () return { fields = { 'at' }, files = { 'a.lua' } } end,
        expect = { holds = true, check = function (v)
            local inb = 0
            for _, s in ipairs(v.sites) do if s.file == 'b.lua' then inb = inb + 1 end end
            return inb == 2 and v.seeds == 1 and v.by_path.line == 1 and v.by_path.col == 1, ('b.lua derefs %d, seeds %d'):format(inb, v.seeds)
        end },
    },
    {
        name = 'a call the graph does not resolve is a NAMED frontier row, never a silent stop',
        files = FILES, params = function () return { fields = { 'at' }, files = { 'a.lua' } } end,
        expect = { holds = true, check = function (v)
            return #v.unresolved == 1 and v.unresolved[1]:find('nowhere', 1, true) ~= nil, table.concat(v.unresolved, '; ')
        end },
    },
    {
        name = 'without the fixpoint (one round) the roster stops at the file boundary — what this tactic adds',
        files = FILES, params = function () return { fields = { 'at' }, files = { 'a.lua' }, rounds = '1' } end,
        expect = { holds = false, check = function (v) return v.derefs == 0 or v.files == 1, ('derefs %d in %d file(s)'):format(v.derefs, v.files) end },
    },
}

return E
