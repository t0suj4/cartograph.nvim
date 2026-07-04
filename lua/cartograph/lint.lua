-- Graph-aware linter (pure). Whole-program checks luacheck can't make because it
-- doesn't have the cross-file symbol graph: dead functions (no caller anywhere),
-- redundant requires (a pure module required only for effect), and call cycles
-- (mutual recursion / load-order risk). Each rule is pure over the store and
-- emits findings; the driver turns them into a quickfix list.
--
-- Honest scoping mirrors the rest of the tool: a no-caller function is only
-- flagged when it's a LOCAL (an exported one is public surface, not dead), and
-- the checks are structural — they surface smells, they don't prove bugs.

local M = {}

local function exported(n)
    return n.kind == 'method' or (n.name and n.name:find('%.') ~= nil)
end

-- metamethods (__index, __call, __newindex, …) are invoked via the metatable,
-- never called by name, so "no caller" says nothing about them.
local function metamethod(n) return n.name and n.name:find('__') ~= nil end

-- Tarjan SCC over an adjacency map (id -> {neighbour ids}).
local function sccs(ids, adj)
    local index, low, onstack, stack, counter, comps = {}, {}, {}, {}, 0, {}
    local function strongconnect(v)
        index[v], low[v] = counter, counter
        counter = counter + 1
        stack[#stack + 1] = v; onstack[v] = true
        for _, w in ipairs(adj[v] or {}) do
            if index[w] == nil then
                strongconnect(w); low[v] = math.min(low[v], low[w])
            elseif onstack[w] then
                low[v] = math.min(low[v], index[w])
            end
        end
        if low[v] == index[v] then
            local comp = {}
            repeat
                local w = stack[#stack]; stack[#stack] = nil; onstack[w] = false
                comp[#comp + 1] = w
            until w == v
            comps[#comps + 1] = comp
        end
    end
    for _, v in ipairs(ids) do if index[v] == nil then strongconnect(v) end end
    return comps
end

-- Paired-key listener audit (wiretap-style register/subscribe/unsubscribe). The
-- listener NAME is a call argument; `at` is its logical index (self is skipped
-- automatically for method calls via the call's `method` flag). Generalises to
-- any register/acquire/release keyed by an argument.
M.listener_config = {
    register    = { verb = 'register_listener', at = 1 },
    subscribe   = { verb = 'subscribe',   at = 2 },
    unsubscribe = { verb = 'unsubscribe', at = 2 },
}

local function listener_findings(store)
    local cfg, calls = M.listener_config, store.data.calls
    if not calls or #calls == 0 then return {} end
    local function abs(c) return store.data.root .. '/' .. c.file end
    local function keyname(c, spec)
        local a = c.args[spec.at + (c.method and 1 or 0)]
        return (a and a ~= '') and a or nil
    end

    local reg, reg_site, subL, sub_site, subDyn, unsubL, unsubDyn = {}, {}, {}, {}, false, {}, false
    local out = {}
    for _, c in ipairs(calls) do
        if c.callee == cfg.register.verb then
            local n = keyname(c, cfg.register)
            if n then reg[n] = true; reg_site[n] = reg_site[n] or c end
            if not c.top then
                out[#out + 1] = { file = abs(c), line = c.line + 1,
                    message = ("listener '%s' is registered inside a function, not at load — may register after init"):format(n or '?') }
            end
        elseif c.callee == cfg.subscribe.verb then
            local n = keyname(c, cfg.subscribe)
            if n then subL[n] = true; sub_site[n] = sub_site[n] or c else subDyn = true end
        elseif c.callee == cfg.unsubscribe.verb then
            local n = keyname(c, cfg.unsubscribe)
            if n then unsubL[n] = true else unsubDyn = true end
        end
    end
    if not next(reg) then return out end -- no register_listener anywhere: not a listener project

    -- subscribe/unsubscribe to a name that's never registered -> runtime error
    for _, c in ipairs(calls) do
        local spec = (c.callee == cfg.subscribe.verb and cfg.subscribe)
            or (c.callee == cfg.unsubscribe.verb and cfg.unsubscribe) or nil
        local n = spec and keyname(c, spec)
        if n and not reg[n] then
            out[#out + 1] = { file = abs(c), line = c.line + 1,
                message = ("%s to '%s', which is never registered (would error: 'Could not find listener')"):format(c.callee, n) }
        end
    end
    -- registered but never subscribed — suppressed if any dynamic subscribe could cover it
    if not subDyn then
        local names = {}; for n in pairs(reg) do names[#names + 1] = n end; table.sort(names)
        for _, n in ipairs(names) do
            if not subL[n] then
                out[#out + 1] = { file = abs(reg_site[n]), line = reg_site[n].line + 1,
                    message = ("listener '%s' is registered but never subscribed"):format(n) }
            end
        end
    end
    -- subscribed but never unsubscribed — suppressed if any dynamic unsubscribe could cover it
    if not unsubDyn then
        local names = {}; for n in pairs(subL) do names[#names + 1] = n end; table.sort(names)
        for _, n in ipairs(names) do
            if not unsubL[n] then
                out[#out + 1] = { file = abs(sub_site[n]), line = sub_site[n].line + 1,
                    message = ("'%s' is subscribed but never unsubscribed (leak-prone)"):format(n) }
            end
        end
    end
    return out
end

-- Which class does a function belong to? 'BnwForce:clean_landing' -> 'BnwForce'
local function class_of(name)
    return name and name:match('^(.-)[:%.][%w_]+$')
end

-- Swallowed types: every `inferred` call IS a type swallowed somewhere — the
-- receiver's class got laundered to `unknown` (usually through an untyped
-- container) and the call only resolved by unique method name. Point the
-- finding at the ROOT CAUSE when possible: if the receiver's def line calls a
-- resolved function of the same class (a getter), one `---@return CLASS` there
-- fixes every caller at once; otherwise offer `---@type CLASS` on the local.
local function swallowed_findings(store)
    local calls = store.data.calls
    if not calls or #calls == 0 then return {} end
    -- the FIX this rule offers is a lua-ls annotation (---@return /
    -- ---@type): on other languages every name-matched call would fire
    -- it with no repair to offer — noise, not findings
    local any_lua = false
    for _, f in ipairs(store.files) do
        if f:match('%.lua$') then any_lua = true break end
    end
    if not any_lua then return {} end

    -- vm-resolved calls by file:line, to find the getter behind a def site
    local resolved_at = {}
    for _, c in ipairs(calls) do
        if c.to and not c.inferred then
            local k = c.file .. ':' .. c.line
            resolved_at[k] = resolved_at[k] or {}
            table.insert(resolved_at[k], c)
        end
    end

    local sites = {}
    for _, c in ipairs(calls) do
        local tn = c.inferred and c.to and store.node(c.to)
        local class = tn and class_of(tn.name)
        if class then
            local recv = c.method and c.argv and c.argv[1]
            local file, line, fix, label
            if recv and recv.k == 'local' and recv.l then
                file, line = c.file, recv.l
                for _, g in ipairs(resolved_at[c.file .. ':' .. recv.l] or {}) do
                    local gn = store.node(g.to)
                    if gn and class_of(gn.name) == class then
                        file, line = gn.file, gn.range.start.line
                        fix   = { file = store.data.root .. '/' .. file, line = line,
                                  text = '---@return ' .. class }
                        label = ('---@return %s on %s'):format(class, gn.name)
                        break
                    end
                end
                if not fix then
                    fix   = { file = store.data.root .. '/' .. file, line = line,
                              text = '---@type ' .. class }
                    label = '---@type ' .. class
                end
            else
                file, line = c.file, c.line -- receiver isn't a simple local: no fix offered
            end
            local key = ('%s:%d:%s'):format(file, line, class)
            local s = sites[key]
            if not s then
                s = { class = class, file = file, line = line, fix = fix, label = label,
                      methods = {}, n = 0 }
                sites[key] = s
            end
            s.methods[tn.name:match('[:%.]([%w_]+)$') or tn.name] = true
            s.n = s.n + 1
        end
    end

    local out = {}
    for _, s in pairs(sites) do
        local ms = {}
        for m in pairs(s.methods) do ms[#ms + 1] = m end
        table.sort(ms)
        local shown = table.concat(ms, ', ', 1, math.min(#ms, 4))
        if #ms > 4 then shown = shown .. (' +%d more'):format(#ms - 4) end
        out[#out + 1] = {
            file = store.data.root .. '/' .. s.file, line = s.line + 1,
            message = ('%s type is swallowed — %d call(s) to %s resolve by name only%s'):format(
                s.class, s.n, shown, s.label and (' — quick fix: ' .. s.label) or ''),
            fix = s.fix,
        }
    end
    return out
end

-- Manifest load order (WoW .toc, via store.toc): the file list IS the load
-- order, so a load-time call into a file that loads LATER hits nil — the
-- classic addon bug. Also surfaces files no manifest path reaches (never
-- load) and listed files that don't exist.
local function load_order_findings(store)
    local t = store.toc
    if not t then return {} end
    local out = {}
    for _, c in ipairs(store.data.calls or {}) do
        if c.top and c.to then
            local callee = store.node(c.to)
            local ci = callee and t.index[callee.file]
            local fi = t.index[c.file]
            if ci and fi and ci > fi then
                out[#out + 1] = { file = store.data.root .. '/' .. c.file, line = c.line + 1,
                    message = ("load-time call to '%s', but %s loads later (#%d, this file is #%d)%s"):format(
                        callee.name, callee.file, ci, fi,
                        c.inferred and ' — name-matched' or '') }
            end
        end
    end
    for _, f in ipairs(t.unlisted or {}) do
        out[#out + 1] = { file = store.data.root .. '/' .. f, line = 1,
            message = ("'%s' is not reachable from %s — it never loads"):format(f, t.toc) }
    end
    for _, m in ipairs(t.missing or {}) do
        out[#out + 1] = { file = store.data.root .. '/' .. t.toc, line = 1,
            message = ("%s lists '%s' (via %s), which does not exist"):format(t.toc, m.file, m.via) }
    end

    -- cross-addon: the surrounding addons folder is itself ordered by
    -- ## Dependencies. Hard failures first, then the order hazard: a
    -- load-time call into an UNDECLARED sibling — the client guarantees
    -- nothing about who loads first, so it works or nils by alphabet.
    local fol, me = t.folder, t.folder and t.folder.addons[(t.self or ''):lower()]
    if me then
        local tocline = { file = store.data.root .. '/' .. t.toc, line = 1 }
        for _, dep in ipairs(me.req) do
            if not fol.addons[dep:lower()] then
                out[#out + 1] = { file = tocline.file, line = 1,
                    message = ("requires addon '%s', which is not installed — this addon will NOT load"):format(dep) }
            end
        end
        for _, cy in ipairs(fol.cycles or {}) do
            if cy.addon == me.name or cy.dep == me.name then
                out[#out + 1] = { file = tocline.file, line = 1,
                    message = ("dependency cycle: '%s' <-> '%s' — the client disables both"):format(cy.addon, cy.dep) }
            end
        end
        local sib = require('cartograph.toc').sibling_defs(t)
        if next(sib) then
            local declared = {}
            for _, d in ipairs(me.req) do declared[d:lower()] = true end
            for _, d in ipairs(me.opt) do declared[d:lower()] = true end
            local own = {}
            for _, n in ipairs(store.data.nodes) do own[n.name or ''] = true end
            for _, c in ipairs(store.data.calls or {}) do
                local who = c.top and not c.to and not own[c.callee] and sib[c.callee]
                if who and not declared[who:lower()] then
                    out[#out + 1] = { file = store.data.root .. '/' .. c.file, line = c.line + 1,
                        message = ("load-time call to '%s', defined by addon '%s' — undeclared dependency: load order is not guaranteed"):format(c.callee, who) }
                end
            end
        end
    end
    return out
end

-- The dynamic-dispatch frontier, surfaced: one finding per file with the
-- count of call sites whose callee is runtime state ($fn(), unresolved
-- call_user_func). The graph knows what it can't see; so should you.
local function dynamic_findings(store)
    local per, order = {}, {}
    for _, c in ipairs(store.data.calls or {}) do
        if (c.dynamic or ((c.callee == 'call_user_func'
            or c.callee == 'call_user_func_array') and not c.to)) then
            if not per[c.file] then
                per[c.file] = { n = 0, line = c.line }
                order[#order + 1] = c.file
            end
            per[c.file].n = per[c.file].n + 1
            per[c.file].line = math.min(per[c.file].line, c.line)
        end
    end
    local out = {}
    for _, f in ipairs(order) do
        out[#out + 1] = { file = store.data.root .. '/' .. f, line = per[f].line + 1,
            message = ("%d dynamic dispatch site(s) — callees are runtime state; pin known targets via setup{ pins = ... }"):format(per[f].n) }
    end
    return out
end

-- Greenspun's tenth rule, surfaced: the ad-hoc lisp halves a codebase grew.
local function greenspun_findings(store)
    local g = require 'cartograph.greenspun'
    local out = {}
    local _, registries = g.registries(store.data)
    for _, r in ipairs(registries) do
        local via = #r.imports > 0
            and (' — dispatched via ' .. table.concat(r.imports, ', '))
            or ' — no dispatch verb found (dead registry, or dispatched dynamically)'
        out[#out + 1] = { file = store.data.root, line = 1,
            message = ("ad-hoc registry: '%s' interns %d keys over %d sites (e.g. %q)%s")
                :format(r.verb, r.keys, r.sites, r.example or '?', via) }
    end
    for _, t in ipairs(g.dispatch_tables(store.data)) do
        out[#out + 1] = { file = store.data.root .. '/' .. t.var.file,
            line = t.var.range.start.line + 1,
            message = ("ad-hoc funcall table: '%s' maps %d of %d entries to functions")
                :format(t.var.name, t.fns, t.entries) }
    end
    for _, f in ipairs(g.factories(store.data)) do
        out[#out + 1] = { file = store.data.root, line = 1,
            message = ("string-keyed factory: '%s' resolves %d distinct keys over %d sites (e.g. %q)")
                :format(f.verb, f.keys, f.sites, f.example or '?') }
    end
    for _, c in ipairs(g.evals(store.data)) do
        out[#out + 1] = { file = store.data.root .. '/' .. c.file, line = c.line + 1,
            message = ("the interpreter itself: %s()"):format(c.callee) }
    end
    return out
end

-- The registry consistency audit, auto-configured: every binding in force
-- (hand-written or discovered) gets the wiretap treatment — typo'd keys
-- named with their probable intent.
local function registry_audit_findings(store)
    local xl = require 'cartograph.xlang'
    return require('cartograph.greenspun').audit(store.data,
        xl.effective_bindings(store.data))
end

-- discovered acquire/release pairs get the imbalance audit; discovered
-- vocabulary mirrors get the drift report
local function pair_audit_findings(store)
    local g = require 'cartograph.greenspun'
    return g.pair_audit(store.data, g.verb_pairs(store.data))
end

local function mirror_findings(store)
    local g = require 'cartograph.greenspun'
    local mirrors, note = g.mirrors(store.data)
    local out = {}
    if note then
        out[#out + 1] = { file = store.data.root, line = 1, message = note }
    end
    local function short(list)
        local t = {}
        for i = 1, math.min(#list, 4) do t[#t + 1] = list[i] end
        local txt = table.concat(t, ', ')
        if #list > 4 then txt = txt .. (' +%d more'):format(#list - 4) end
        return txt
    end
    for _, m in ipairs(mirrors) do
        local parts = {}
        for x, label in ipairs(m.members) do
            if m.extras[x] then
                parts[#parts + 1] = ('%s adds: %s'):format(label, short(m.extras[x]))
            end
        end
        local msg
        if m.core >= 2 then
            msg = ('vocabulary family (%d core): %s — %s')
                :format(m.core, table.concat(m.members, ' ~ '),
                    #parts > 0 and table.concat(parts, '; ') or 'perfect mirror')
        else
            -- pairwise-linked but no common core: a CHAIN, not a mirror
            msg = ('vocabulary chain (pairwise overlaps, no common core): %s')
                :format(table.concat(m.members, ' ~ '))
        end
        out[#out + 1] = { file = store.data.root .. '/' .. m.node.file,
            line = m.node.range.start.line + 1, message = msg }
    end
    return out
end

-- Access points: a trivial function everyone calls (getWorld, get,
-- instance) is a NAMESPACE, not a hotspot — mark it so views and readers
-- treat its fan-in as plumbing. Marks node.access as a side effect.
local function access_point_findings(store)
    local out = {}
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') then
            local callers = #(store.usedby[n.id] or {})
            local stmts = n.df and #n.df.stmts or 0
            local gettish = n.name:match('[Gg]et[%u_]?') or n.name:match('instance')
                or n.name:match('current')
            if callers >= 15 and stmts > 0
                and (stmts <= 2 or (gettish and stmts <= 4)) then
                n.access = true
                out[#out + 1] = { file = store.abspath(n),
                    line = n.range.start.line + 1,
                    message = ("access point: '%s' — %d callers, %d statement(s); its fan-in is plumbing, not coupling")
                        :format(n.name, callers, stmts) }
            end
        end
    end
    return out
end

-- Clone candidates: same data-flow shape, same callees — the dedup list.
local function clone_findings(store)
    local out = {}
    for _, g in ipairs(require('cartograph.greenspun').clones(store.data)) do
        local names = {}
        for _, n in ipairs(g) do
            names[#names + 1] = ('%s (%s:%d)'):format(
                n.name, n.file, n.range.start.line + 1)
        end
        out[#out + 1] = { file = store.abspath(g[1]),
            line = g[1].range.start.line + 1,
            message = ('possible clones (%d statements, same shape and callees): %s')
                :format(#g[1].df.stmts, table.concat(names, ' ~ ')) }
    end
    return out
end

-- Layering: imports running against a pair's dominant direction.
local function layering_findings(store)
    local out = {}
    for _, v in ipairs(require('cartograph.greenspun').layering(store.data)) do
        for _, e in ipairs(v.edges or {}) do
            out[#out + 1] = { severity = 'warn',
                file = store.data.root .. '/' .. e.from, line = 1,
                message = ("layering: %s -> %s dominates (%d imports); '%s' -> '%s' runs against it")
                    :format(v.dom_from, v.dom_to, v.dom, e.from, e.to) }
        end
        out[#out + 1] = { file = store.data.root, line = 1,
            message = ("layer pair %s/%s: %d with the current, %d against")
                :format(v.dom_from, v.dom_to, v.dom, v.against) }
    end
    return out
end

-- Embedded SQL: per-table read/write footprint (tables touched from
-- more than one site — a single query is not a pattern).
local function sql_findings(store)
    local scanned = require('cartograph.sql').scan(store.data)
    local out, names = {}, {}
    for t in pairs(scanned.tables) do names[#names + 1] = t end
    table.sort(names)
    for _, t in ipairs(names) do
        local e = scanned.tables[t]
        if #e.sites >= 2 then
            local first = e.sites[1].call
            out[#out + 1] = { file = store.data.root .. '/' .. first.file,
                line = first.line + 1,
                message = ("table '%s': %d read(s), %d write(s)%s across %d raw SQL sites")
                    :format(t, e.reads, e.writes,
                        e.ddl > 0 and (', %d ddl'):format(e.ddl) or '',
                        #e.sites) }
        end
    end
    return out
end

M.rules = {
    { name = 'sql', severity = 'info', run = sql_findings },
    {
        -- the code<->database audit (needs setup{ db = ... }): tables the
        -- code queries but the database lacks are typos or missing
        -- migrations; tables the database holds but nothing queries are
        -- dead weight. The wiretap shape, at the schema boundary.
        name = 'db-audit', severity = 'warn',
        run = function (store)
            local d = store.data.dblink
            if not d then return {} end
            local out = {}
            for _, m in ipairs(d.missing) do
                local n = store.node('sql::table:' .. m.name)
                out[#out + 1] = {
                    file = n and (store.data.root .. '/' .. n.file) or '',
                    line = n and n.range.start.line + 1 or 1,
                    message = ("table '%s' is queried in code but %s")
                        :format(m.name, m.why
                            and ('ambiguous in the database (' .. m.why .. ')')
                            or 'absent from the database'),
                }
            end
            for _, t in ipairs(d.unused) do
                out[#out + 1] = { file = '', line = 1, severity = 'info',
                    message = ("table '%s' exists in the database but no"
                        .. " code queries it"):format(t) }
            end
            return out
        end,
    },
    { name = 'layering', severity = 'info', run = layering_findings },
    { name = 'clone', severity = 'info', run = clone_findings },
    { name = 'access-point', severity = 'info', run = access_point_findings },
    { name = 'registry-audit', severity = 'warn', run = registry_audit_findings },
    { name = 'pair-audit', severity = 'warn', run = pair_audit_findings },
    { name = 'schema-mirror', severity = 'info', run = mirror_findings },
    { name = 'greenspun', severity = 'info', run = greenspun_findings },
    { name = 'dynamic-dispatch', severity = 'info', run = dynamic_findings },
    { name = 'load-order', severity = 'warn', run = load_order_findings },
    { name = 'listener-audit', severity = 'warn', run = listener_findings },
    { name = 'swallowed-type', severity = 'info', run = swallowed_findings },
    {
        name = 'dead-function', severity = 'warn',
        run = function (store)
            local out = {}
            -- manifest projects: XML-referenced handlers are engine-dispatched
            local xmlh = store.toc and store.toc.handlers or {}
            for _, n in ipairs(store.data.nodes) do
                if (n.kind == 'function' or n.kind == 'method')
                    and not exported(n) and not metamethod(n) and not n.cbarg
                    and not n.entry and not xmlh[n.name]
                    and #(store.usedby[n.id] or {}) == 0 then
                    out[#out + 1] = { file = store.abspath(n), line = n.range.start.line + 1,
                        message = ("local function '%s' has no callers (possibly dead)"):format(n.name) }
                end
            end
            return out
        end,
    },
    {
        name = 'redundant-require', severity = 'warn',
        run = function (store)
            local out = {}
            for _, file in ipairs(store.files) do
                if store.classify(file) == 'deadimport' then
                    out[#out + 1] = { file = store.data.root .. '/' .. file, line = 1,
                        message = ("'%s' is required only for effect, but has none — the require is redundant"):format(file) }
                end
            end
            return out
        end,
    },
    {
        name = 'call-cycle', severity = 'warn',
        run = function (store)
            local ids, adj = {}, {}
            for _, n in ipairs(store.data.nodes) do
                if n.kind ~= 'module' then ids[#ids + 1] = n.id; adj[n.id] = store.uses[n.id] end
            end
            local out = {}
            for _, comp in ipairs(sccs(ids, adj)) do
                if #comp > 1 then -- size-1 (plain recursion) is not a smell
                    local names = {}
                    for _, id in ipairs(comp) do names[#names + 1] = store.node(id).name end
                    table.sort(names)
                    local n0 = store.node(comp[1])
                    out[#out + 1] = { file = store.abspath(n0), line = n0.range.start.line + 1,
                        message = 'call cycle: ' .. table.concat(names, ' <-> ') }
                end
            end
            return out
        end,
    },
}

--- Run all (enabled) rules over the store. Returns a flat findings list.
---@param store table
---@param opts { only:table? }?  optional set of rule names to include
---@return table[]  { {rule, severity, file, line, message}, ... }
function M.run(store, opts)
    local only = opts and opts.only
    local findings = {}
    for _, rule in ipairs(M.rules) do
        if not only or only[rule.name] then
            for _, f in ipairs(rule.run(store)) do
                f.rule, f.severity = rule.name, f.severity or rule.severity
                findings[#findings + 1] = f
            end
        end
    end
    table.sort(findings, function (a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.line < b.line
    end)
    return findings
end

return M
