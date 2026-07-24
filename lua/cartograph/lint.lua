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
local argv = require 'cartograph.argv'
local atr = require 'cartograph.at'
local callrec = require 'cartograph.callrec'

local function exported(n)
    if n.exported ~= nil then return n.exported end -- provider's verdict
    return n.kind == 'method' or (n.name and n.name:find('%.') ~= nil)
end

-- metamethods (__index, __call, __newindex, …) are invoked via the metatable,
-- never called by name, so "no caller" says nothing about them.
local function metamethod(n) return n.name and n.name:find('__') ~= nil end

-- Tarjan SCC over an adjacency map (id -> {neighbour ids}). Iterative — a
-- deep call chain (2M-line corpora) must not blow the Lua stack; the explicit
-- work stack replays each frame at its saved neighbour cursor.
local function sccs(ids, adj)
    local index, low, onstack, stack, counter, comps = {}, {}, {}, {}, 0, {}
    local function strongconnect(root)
        local work = { { v = root, i = 1 } }
        index[root], low[root] = counter, counter
        counter = counter + 1
        stack[#stack + 1] = root; onstack[root] = true
        while #work > 0 do
            local fr = work[#work]
            local v, nbrs = fr.v, adj[fr.v] or {}
            local descended = false
            while fr.i <= #nbrs do
                local w = nbrs[fr.i]
                fr.i = fr.i + 1
                if index[w] == nil then
                    index[w], low[w] = counter, counter
                    counter = counter + 1
                    stack[#stack + 1] = w; onstack[w] = true
                    work[#work + 1] = { v = w, i = 1 }
                    descended = true
                    break
                elseif onstack[w] then
                    low[v] = math.min(low[v], index[w])
                end
            end
            if not descended then
                if low[v] == index[v] then
                    local comp = {}
                    repeat
                        local w = stack[#stack]; stack[#stack] = nil; onstack[w] = false
                        comp[#comp + 1] = w
                    until w == v
                    comps[#comps + 1] = comp
                end
                work[#work] = nil
                local up = work[#work]
                if up then low[up.v] = math.min(low[up.v], low[v]) end
            end
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
    local function abs(c) return store.abs(callrec.file(c)) end
    local function keyname(c, spec)
        local a = argv.str(c, spec.at + (callrec.method(c) and 1 or 0))
        return (a and a ~= '') and a or nil
    end

    local reg, reg_site, subL, sub_site, subDyn, unsubL, unsubDyn = {}, {}, {}, {}, false, {}, false
    local out = {}
    for _, c in ipairs(calls) do
        if callrec.callee(c) == cfg.register.verb then
            local n = keyname(c, cfg.register)
            if n then reg[n] = true; reg_site[n] = reg_site[n] or c end
            if not c.top then
                out[#out + 1] = { file = abs(c), line = callrec.line(c) + 1,
                    message = ("listener '%s' is registered inside a function, not at load — may register after init"):format(n or '?') }
            end
        elseif callrec.callee(c) == cfg.subscribe.verb then
            local n = keyname(c, cfg.subscribe)
            if n then subL[n] = true; sub_site[n] = sub_site[n] or c else subDyn = true end
        elseif callrec.callee(c) == cfg.unsubscribe.verb then
            local n = keyname(c, cfg.unsubscribe)
            if n then unsubL[n] = true else unsubDyn = true end
        end
    end
    if not next(reg) then return out end -- no register_listener anywhere: not a listener project

    -- subscribe/unsubscribe to a name that's never registered -> runtime error
    for _, c in ipairs(calls) do
        local spec = (callrec.callee(c) == cfg.subscribe.verb and cfg.subscribe)
            or (callrec.callee(c) == cfg.unsubscribe.verb and cfg.unsubscribe) or nil
        local n = spec and keyname(c, spec)
        if n and not reg[n] then
            out[#out + 1] = { file = abs(c), line = callrec.line(c) + 1,
                message = ("%s to '%s', which is never registered (would error: 'Could not find listener')"):format(callrec.callee(c), n) }
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
        if callrec.to(c) and not c.inferred then
            local k = callrec.file(c) .. ':' .. callrec.line(c)
            resolved_at[k] = resolved_at[k] or {}
            table.insert(resolved_at[k], c)
        end
    end

    local sites = {}
    for _, c in ipairs(calls) do
        local tn = c.inferred and callrec.to(c) and store.node(callrec.to(c))
        local class = tn and class_of(tn.name)
        if class then
            local recv = callrec.method(c) and argv.at(c, 1)
            local file, line, fix, label
            if recv and recv.k == 'local' and recv.l then
                file, line = callrec.file(c), recv.l
                for _, g in ipairs(resolved_at[callrec.file(c) .. ':' .. recv.l] or {}) do
                    local gn = store.node(g.to)
                    if gn and class_of(gn.name) == class then
                        file, line = gn.file, atr.sl(gn.range)
                        fix   = { file = store.abs(file), line = line,
                                  text = '---@return ' .. class }
                        label = ('---@return %s on %s'):format(class, gn.name)
                        break
                    end
                end
                if not fix then
                    fix   = { file = store.abs(file), line = line,
                              text = '---@type ' .. class }
                    label = '---@type ' .. class
                end
            else
                file, line = callrec.file(c), callrec.line(c) -- receiver isn't a simple local: no fix offered
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
            file = store.abs(s.file), line = s.line + 1,
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
    for _, c in callrec.each(store.data) do
        if c.top and callrec.to(c) then
            local callee = store.node(callrec.to(c))
            local ci = callee and t.index[callee.file]
            local fi = t.index[callrec.file(c)]
            if ci and fi and ci > fi then
                out[#out + 1] = { file = store.abs(callrec.file(c)), line = callrec.line(c) + 1,
                    message = ("load-time call to '%s', but %s loads later (#%d, this file is #%d)%s"):format(
                        callee.name, callee.file, ci, fi,
                        c.inferred and ' — name-matched' or '') }
            end
        end
    end
    for _, f in ipairs(t.unlisted or {}) do
        out[#out + 1] = { file = store.abs(f), line = 1,
            message = ("'%s' is not reachable from %s — it never loads"):format(f, t.toc) }
    end
    for _, m in ipairs(t.missing or {}) do
        out[#out + 1] = { file = store.abs(t.toc), line = 1,
            message = ("%s lists '%s' (via %s), which does not exist"):format(t.toc, m.file, m.via) }
    end

    -- cross-addon: the surrounding addons folder is itself ordered by
    -- ## Dependencies. Hard failures first, then the order hazard: a
    -- load-time call into an UNDECLARED sibling — the client guarantees
    -- nothing about who loads first, so it works or nils by alphabet.
    local fol, me = t.folder, t.folder and t.folder.addons[(t.self or ''):lower()]
    if me then
        local tocline = { file = store.abs(t.toc), line = 1 }
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
            for _, c in callrec.each(store.data) do
                local who = c.top and not callrec.to(c) and not own[callrec.callee(c)] and sib[callrec.callee(c)]
                if who and not declared[who:lower()] then
                    out[#out + 1] = { file = store.abs(callrec.file(c)), line = callrec.line(c) + 1,
                        message = ("load-time call to '%s', defined by addon '%s' — undeclared dependency: load order is not guaranteed"):format(callrec.callee(c), who) }
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
    for _, c in callrec.each(store.data) do
        if (c.dynamic or ((callrec.callee(c) == 'call_user_func'
            or callrec.callee(c) == 'call_user_func_array') and not callrec.to(c))) then
            if not per[callrec.file(c)] then
                per[callrec.file(c)] = { n = 0, line = callrec.line(c) }
                order[#order + 1] = callrec.file(c)
            end
            per[callrec.file(c)].n = per[callrec.file(c)].n + 1
            per[callrec.file(c)].line = math.min(per[callrec.file(c)].line, callrec.line(c))
        end
    end
    local out = {}
    for _, f in ipairs(order) do
        out[#out + 1] = { file = store.abs(f), line = per[f].line + 1,
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
        out[#out + 1] = { file = store.abs(t.var.file),
            line = atr.sl(t.var.range) + 1,
            message = ("ad-hoc funcall table: '%s' maps %d of %d entries to functions")
                :format(t.var.name, t.fns, t.entries) }
    end
    for _, f in ipairs(g.factories(store.data)) do
        out[#out + 1] = { file = store.data.root, line = 1,
            message = ("string-keyed factory: '%s' resolves %d distinct keys over %d sites (e.g. %q)")
                :format(f.verb, f.keys, f.sites, f.example or '?') }
    end
    for _, c in ipairs(g.evals(store.data)) do
        out[#out + 1] = { file = store.abs(callrec.file(c)), line = c.line + 1,
            message = ("the interpreter itself: %s()"):format(callrec.callee(c)) }
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
        out[#out + 1] = { file = store.abs(m.node.file),
            line = atr.sl(m.node.range) + 1, message = msg }
    end
    return out
end

-- Access points: a trivial function everyone calls (getWorld, get,
-- instance) is a NAMESPACE, not a hotspot — mark it so views and readers
-- treat its fan-in as plumbing. Marks node.access as a side effect.
local function access_point_findings(store)
    local out = {}
    local band = store.topo() -- fan-in through the resident Band, not raw usedby
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') then
            local callers = band:n_callers(n.id)
            local stmts = require('cartograph.df').count(n)
            local gettish = n.name:match('[Gg]et[%u_]?') or n.name:match('instance')
                or n.name:match('current')
            if callers >= 15 and stmts > 0
                and (stmts <= 2 or (gettish and stmts <= 4)) then
                n.access = true
                out[#out + 1] = { file = store.abspath(n),
                    line = atr.sl(n.range) + 1,
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
                n.name, n.file, atr.sl(n.range) + 1)
        end
        out[#out + 1] = { file = store.abspath(g[1]),
            line = atr.sl(g[1].range) + 1,
            message = ('possible clones (%d statements, same shape and callees): %s')
                :format(require('cartograph.df').count(g[1]), table.concat(names, ' ~ ')) }
    end
    return out
end

-- Layering: imports running against a pair's dominant direction.
local function layering_findings(store)
    local out = {}
    for _, v in ipairs(require('cartograph.greenspun').layering(store.data)) do
        for _, e in ipairs(v.edges or {}) do
            out[#out + 1] = { severity = 'warn',
                file = store.abs(e.from), line = 1,
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
            out[#out + 1] = { file = store.abs(first.file),
                line = first.line + 1,
                message = ("table '%s': %d read(s), %d write(s)%s across %d raw SQL sites")
                    :format(t, e.reads, e.writes,
                        e.ddl > 0 and (', %d ddl'):format(e.ddl) or '',
                        #e.sites) }
        end
    end
    return out
end

-- ── DEVELOPMENT GUARDS: lints for building graph tools honestly ─────────
-- (dogfooding rules born from cartograph's own development; generic
-- mechanisms, project-specific declarations via config)

-- seam-guard: a project can declare REPRESENTATION SEAMS (config.seams):
--   { name = 'at', patterns = { '%.start%.line', ... },
--     owners = { '^lua/x/providers/', 'store%.lua$' } }
-- Any source line matching a pattern outside the owner allowlist is a
-- violation: the representation behind an accessor seam may change at
-- any time, and a raw read is a latent break. Line-tier scan (~).
local function seam_findings(store)
    local seams = require('cartograph.config').seams
    if not seams or #seams == 0 then return {} end
    local out = {}
    for _, file in ipairs(store.files) do
        if file:match('%.lua$') then
            local owned = {}
            for si, seam in ipairs(seams) do
                for _, o in ipairs(seam.owners or {}) do
                    if file:match(o) then owned[si] = true break end
                end
            end
            local fd = io.open(store.abs(file), 'r')
            if fd then
                local ln = 0
                for line in fd:lines() do
                    ln = ln + 1
                    local code = line:gsub('%-%-.*$', '')
                    for si, seam in ipairs(seams) do
                        if not owned[si] then
                            for _, pat in ipairs(seam.patterns) do
                                if code:find(pat) then
                                    out[#out + 1] = { file = store.abs(file), line = ln,
                                        message = ("raw '%s'-seam read (%s) — go through the accessor; the representation may be folded")
                                            :format(seam.name, pat) }
                                    break
                                end
                            end
                        end
                    end
                end
                fd:close()
            end
        end
    end
    return out
end

-- multi-return truncation: `local a, b = x and f() or y` adjusts f's
-- returns to ONE value (b = nil silently). Three real bugs in one day
-- of cartograph's own development. AST-precise: 2+ targets, ONE rhs
-- expression that is an and/or chain whose operand is a call.
local function truncation_findings(store)
    local out = {}
    local okts = pcall(vim.treesitter.language.add, 'lua')
    if not okts then return out end
    for _, file in ipairs(store.files) do
        if file:match('%.lua$') then
            local fd = io.open(store.abs(file), 'r')
            if fd then
                local src = fd:read('*a')
                fd:close()
                local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
                local tree = okp and parser and parser:parse()[1]
                if tree then
                    local function has_call(n) -- a call anywhere in the and/or chain
                        local t = n:type()
                        if t == 'function_call' then return true end
                        if t == 'binary_expression' or t == 'parenthesized_expression' then
                            for c in n:iter_children() do
                                if c:named() and has_call(c) then return true end
                            end
                        end
                        return false
                    end
                    local function walk(n)
                        local t = n:type()
                        if t == 'assignment_statement' then
                            local vl, el = n:named_child(0), n:named_child(1)
                            if vl and el and vl:named_child_count() >= 2
                                and el:named_child_count() == 1 then
                                local e = el:named_child(0)
                                if e:type() == 'binary_expression' then
                                    local isao = false
                                    for i = 0, e:child_count() - 1 do
                                        local ch = e:child(i)
                                        if not ch:named() then
                                            local ct = ch:type()
                                            if ct == 'and' or ct == 'or' then isao = true break end
                                        end
                                    end
                                    if isao and has_call(e) then
                                        local l = select(1, n:range())
                                        out[#out + 1] = { file = store.abs(file), line = l + 1,
                                            message = 'and/or ADJUSTS a call to one value — the extra targets are silently nil (use an explicit if)' }
                                    end
                                end
                            end
                        end
                        for c in n:iter_children() do
                            if c:named() and c:child(0) then walk(c) end
                        end
                    end
                    walk(tree:root())
                end
            end
        end
    end
    return out
end

-- require cycles: SCCs over the import edges. HEDGED: import edges do
-- not record load-time vs lazy (an in-function require breaks the cycle
-- at runtime), so a cycle is "fragile IF load-time", not a certain bug.
local function cycle_findings(store)
    local scc = require 'cartograph.scc'
    local ids, adj = {}, {}
    for f, tos in pairs(store.imports_out) do
        ids[#ids + 1] = f
        adj[f] = tos
    end
    table.sort(ids)
    local con = scc.condense(adj, ids)
    local out = {}
    for ci = 1, con.n do
        local m = con.members[ci]
        if #m > 1 then
            table.sort(m)
            out[#out + 1] = { file = store.abs(m[1]), line = 1,
                message = ('require cycle (%d modules): %s — fragile if any require is load-time (lazy requires break it; load-time-ness unrecorded)')
                    :format(#m, table.concat(m, ' → ')) }
        end
    end
    return out
end

-- SILENT HONESTY GAP (the uniform-honesty invariant, read as a lint): a BARE
-- call whose callee is a LOCAL or PARAM of the enclosing function, yet resolved
-- to NOTHING and was NOT refused — resolution silently gave up on a callable it
-- can see the binding for. This is the function-value-flow / forward-decl class
-- (`local g = f; g()`, `local ra; ra = function…; ra()`): the engine should
-- either RESOLVE it (fn-value alias) or SPEAK a refusal; silence violates the
-- invariant. Bare-only (a qualified `obj.m` receiver-typing drop is the separate
-- narrowable-refusal work-list); local-only (a free external name resolving to
-- nil is an honest "not ours", not a gap). Gated on UNBOUND-ness (the fn_locals
-- membership IS the boundedness test), NOT length: the resolver's honesty pass
-- (resolve_local_callable) now resolves-or-refuses these regardless of name
-- length, so a residual finding of ANY length is a real regression — the old
-- `#callee >= 3` guard would have hidden a short one (a `nm`/`go` re-broken).
local function silent_drop_findings(store)
    local calls = store.data.calls
    if not calls or #calls == 0 then return {} end
    local df = require 'cartograph.df'
    local at = require 'cartograph.at'
    local locals, seen, out = {}, {}, {}
    local function fn_locals(id) -- params ∪ df-def names of the enclosing fn
        local s = locals[id]
        if s then return s end
        s = {}
        local n = store.node(id)
        if n then
            for _, p in ipairs(n.params or {}) do s[p] = true end
            for _, st in ipairs(df.stmts(n)) do
                for _, d in ipairs(st.def or {}) do s[d] = true end
            end
        end
        locals[id] = s
        return s
    end
    for _, c in ipairs(calls) do
        if not callrec.to(c) and not c.refused and not c.dynamic and not callrec.full(c)
            and callrec.fn(c) and callrec.callee(c)
            and fn_locals(callrec.fn(c))[callrec.callee(c)] then
            local k = callrec.fn(c) .. '\31' .. callrec.callee(c) -- one finding per (fn, local)
            if not seen[k] then
                seen[k] = true
                local fn = store.node(callrec.fn(c))
                out[#out + 1] = {
                    file = fn and store.abs(fn.file) or (callrec.file(c) and store.abs(callrec.file(c))) or '',
                    line = c.at and at.sl(c.at) + 1 or ((callrec.line(c) or 0) + 1),
                    message = ("call to local '%s' resolved to nothing and was not refused — a silent honesty gap (the local is a callable in scope: resolution neither linked it nor spoke a refusal)")
                        :format(callrec.callee(c)),
                }
            end
        end
    end
    return out
end

-- Resource leak — the manual-pair regime ([[cartograph-resource-pairing]]).
-- A raw `p = new T()` acquire whose reference is KILLED by a later REDEFINITION
-- of `p` with no release (`p->drop()` / `delete p`) in between leaks the
-- previously-allocated object. C++ manual-refcount / raw-pointer code only: the
-- `= new` acquire gate skips RAII smart pointers (a `unique_ptr` reassign has no
-- raw `new`, and its old value auto-releases). The REASSIGN case is sound WITHOUT
-- escape analysis — a redefinition definitively kills the old reference, so unlike
-- a scope-exit-without-release it cannot have escaped via return/store/grab. Reads
-- the shipped substrate: flow.rows def-positions (cpp pointer-declarator fix) pick
-- out the acquire + the kill; a per-line source scan classifies the RHS/release
-- (hedged `~` — a macro or an aliased pointer could fool the text match). Member/
-- object-graph leaks (release belongs in a destructor) are a separate harder regime
-- (banked). Validated on the luanti wieldmesh oracle: catches the extrusion-mesh
-- leak, 0 false positives on 14 fns / 9 correct release sites.
local LEAK_CPP_EXT = { cpp = true, cc = true, cxx = true, hpp = true, hxx = true, h = true }
local function resource_leak_findings(store)
    local out = {}
    local flow = require 'cartograph.flow'
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.file
            and LEAK_CPP_EXT[(n.file:match('%.([%w]+)$') or ''):lower()] then
            local rows = flow.rows(n)
            if rows and #rows > 0 then
                local lines = store.content(n) or {}
                local acq = {} -- var -> acquire line, while a live un-released raw `new` holds
                for _, r in ipairs(rows) do
                    local text = lines[r.l] or '' -- flow line() is 1-based; content is 1-based
                    for v in pairs(acq) do -- a release of a tracked var clears it
                        if text:find(v .. '%s*->%s*drop%s*%(')
                            or text:find(v .. '%s*->%s*remove%s*%(')
                            or text:find('delete%s+%[?%]?%s*' .. v .. '%f[^%w_]') then
                            acq[v] = nil
                        end
                    end
                    for _, v in ipairs(r.def or {}) do
                        if acq[v] then -- redefinition of a live acquire, no release since → leak
                            out[#out + 1] = { file = store.abspath(n), line = r.l,
                                message = ("resource leak (~): '%s' was allocated with `new` at line %d and is reassigned here without a release (`->drop()`/`delete`) — the previous allocation leaks")
                                    :format(v, acq[v]) }
                            acq[v] = nil
                        end
                        if text:find('=%s*new%s') or text:find('=%s*%b()%s*new%s') then
                            acq[v] = r.l -- a fresh raw-`new` acquire on the LHS var
                        end
                    end
                end
            end
        end
    end
    return out
end

-- Member leak — the OBJECT-GRAPH regime of resource-pairing
-- ([[cartograph-resource-pairing]], the class-lifetime sibling of the intra-fn
-- reassign leak). A pointer MEMBER `m_x = new T()` acquired somewhere but with NO
-- release (`delete m_x` / `m_x->drop()`) ANYWHERE in the program leaks for the
-- object's lifetime (the release belongs in the destructor or a cleanup). Whole-
-- program: accumulate acquires + frees across every C++ file, then flag members
-- acquired-but-never-freed. Keyed GLOBALLY by member name = SOUND-CONSERVATIVE on
-- the free side: a name freed in ANY class excludes it (a safe false-negative on a
-- collision, never a false-positive). Hedged (~): OWNERSHIP-TRANSFER is not modeled
-- — a member handed to another object (a setter/ctor arg that takes ownership) is
-- freed by that owner, not this class, so it can be a false positive; the finding
-- is a review candidate, not a definite leak. `m_` member convention (irrlicht/
-- luanti); raw `= new` only (a unique_ptr member is `.reset(new…)`, auto-released).
-- Validated on luanti: recovers BOTH member-leak oracles (m_mapper ebe7b3153,
-- m_minimap_mapblock 88a6b9f52), 6 candidates whole-codebase (56 freed excluded).
local function member_leak_findings(store)
    local acquired, freed = {}, {} -- member name -> {file,line} first acquire / freed-anywhere
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'module' and n.file and LEAK_CPP_EXT[(n.file:match('%.([%w]+)$') or ''):lower()] then
            local lines = store.content({ file = n.file })
            if lines then
                local src = table.concat(lines, '\n')
                local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'cpp')
                if okp and parser then
                    local root = parser:parse()[1]:root()
                    local function txt(t) return vim.treesitter.get_node_text(t, src) end
                    local function walk(t)
                        local ty = t:type()
                        if ty == 'assignment_expression' then
                            local l, r = t:field('left')[1], t:field('right')[1]
                            if l and r and r:type() == 'new_expression' then
                                -- a member LHS: bare `m_x` or `this->m_x`
                                local nm = txt(l):match('^m_[%w_]+$') or txt(l):match('->%s*(m_[%w_]+)$')
                                if nm and not acquired[nm] then
                                    acquired[nm] = { file = n.file, line = (select(1, t:range())) + 1 }
                                end
                            end
                        elseif ty == 'delete_expression' then
                            local nm = txt(t):match('m_[%w_]+'); if nm then freed[nm] = true end
                        elseif ty == 'call_expression' then
                            local f = t:field('function')[1]
                            if f and f:type() == 'field_expression' then
                                local base = f:field('argument')[1]
                                local mem = txt(f:field('field')[1])
                                if base and (mem == 'drop' or mem == 'remove') then
                                    local nm = txt(base):match('^m_[%w_]+$')
                                    if nm then freed[nm] = true end
                                end
                            end
                        end
                        for c in t:iter_children() do walk(c) end
                    end
                    walk(root)
                end
            end
        end
    end
    local out = {}
    for m, a in pairs(acquired) do
        if not freed[m] then
            out[#out + 1] = { file = store.abs(a.file), line = a.line,
                message = ("possible member leak (~): '%s' is assigned `new` here but never released (`delete`/`->drop()`) anywhere — a class-lifetime leak unless ownership transfers to another object"):format(m) }
        end
    end
    table.sort(out, function (x, y) return (x.file .. x.line) < (y.file .. y.line) end)
    return out
end

-- Null dereference — the reverse-guards_over reading ([[cartograph-nil-flow]] N1,
-- [[cartograph-luanti-corpus]] oracle). A deref `p->x` whose base was assigned from
-- a NULLABLE-returning call (`p = m->getBlockNoCreateNoEx(...)`) and is NOT narrowed
-- non-nil by a dominating guard (`if(p)` / `if(!p) return|continue` / `assert(p)`)
-- can crash. The nullness seed is PER-DEF (nilflow tracks the last assignment in tree
-- order), so a `p` param — which has no nullable-return def — never fires: the fix for
-- the name-global seed that gave 50:1 FP in the probe. Hedged (~): the nullable-return
-- set is a name heuristic and tree-order tracking isn't branch-merge precise. Validated
-- on the luanti environment.cpp oracle (fix 67997af67): flags the unguarded emergeBlock
-- deref, 0 FP across the file (params, if(block), assert, `if(!block) continue` all excl).
local function null_deref_findings(store)
    local nilflow = require 'cartograph.nilflow'
    local files, out, seen = {}, {}, {}
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'module' and n.file and LEAK_CPP_EXT[(n.file:match('%.([%w]+)$') or ''):lower()] then
            files[n.file] = true
        end
    end
    for file in pairs(files) do
        local lines = store.content({ file = file })
        if lines then
            for _, d in ipairs(nilflow.null_derefs(table.concat(lines, '\n'))) do
                local k = file .. '\31' .. (d.fn or '') .. '\31' .. d.var -- one finding per (fn,var)
                if not seen[k] then
                    seen[k] = true
                    out[#out + 1] = { file = store.abs(file), line = d.line,
                        message = ("possible null dereference (~): '%s' was assigned from a nullable-returning call and is dereferenced here with no null-guard (`if`/`assert`) — can crash if the call returned null")
                            :format(d.var) }
                end
            end
        end
    end
    return out
end

M.rules = {
    { name = 'resource-leak', severity = 'warn', run = resource_leak_findings },
    { name = 'member-leak', severity = 'warn', run = member_leak_findings },
    { name = 'null-deref', severity = 'warn', run = null_deref_findings },
    { name = 'silent-drop', severity = 'warn', run = silent_drop_findings },
    { name = 'seam-guard', severity = 'warn', run = seam_findings },
    { name = 'truncation', severity = 'info', run = truncation_findings },
    { name = 'require-cycle', severity = 'info', run = cycle_findings },
    { name = 'sql', severity = 'info', run = sql_findings },
    { name = 'sink-concat', severity = 'warn',
        run = function (store) return require('cartograph.sinkflow').findings(store) end },
    { name = 'sink-source', severity = 'warn',
        run = function (store) return require('cartograph.sinkflow').source_findings(store) end },
    { name = 'sink-reach', severity = 'warn',
        run = function (store) return require('cartograph.sinkflow').reach_findings(store) end },
    {
        -- the state atlas's lint face: state that is written but never
        -- read is dead weight — or reached dynamically in a way the graph
        -- cannot see, so the hedge is spoken, severity stays info
        name = 'dead-state', severity = 'info',
        run = function (store)
            local out = {}
            local census = require('cartograph.atlas').census(store)
            for _, v in ipairs(census.vars.dead) do
                local n = store.node(v.id)
                out[#out + 1] = {
                    file = n and store.abs(n.file) or '',
                    line = n and require('cartograph.at').sl(n.range) + 1 or 1,
                    message = ("'%s' is written (%d fn%s) but never read — dead state, or dynamic access")
                        :format(v.name or '?', v.nw, v.nw == 1 and '' or 's'),
                }
            end
            return out
        end,
    },
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
                    file = n and (store.abs(n.file)) or '',
                    line = n and atr.sl(n.range) + 1 or 1,
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
    {
        -- the wiretap audit at the URL boundary: a {% url %} or reverse()
        -- naming an unregistered route is a render-time error waiting; a
        -- registered route nothing names is dead surface; a cross-file
        -- name collision resolves silently in Django and loudly here
        name = 'route-audit', severity = 'warn',
        run = function (store)
            local out = {}
            -- django and symfony feed the same URL-boundary audit; the only
            -- difference is the runtime symptom named for each ecosystem
            local sources = {
                { d = store.data.django, sym = 'NoReverseMatch' },
                { d = store.data.symfony, sym = 'RouteNotFoundException' },
            }
            for _, s in ipairs(sources) do
                local d = s.d
                if d then
                    for _, u in ipairs(d.unregistered) do
                        out[#out + 1] = { file = store.abs(u.file),
                            line = u.line + 1,
                            message = ("route '%s' is named here but never"
                                .. ' registered (renders as %s)')
                                :format(u.name, s.sym) }
                    end
                    for _, name in ipairs(d.duplicate) do
                        out[#out + 1] = { file = '', line = 1,
                            message = ("route name %s is registered in more than"
                                .. ' one place — the router picks one silently')
                                :format(name) }
                    end
                    for _, name in ipairs(d.unused) do
                        out[#out + 1] = { file = '', line = 1, severity = 'info',
                            message = ("route '%s' is registered but nothing names"
                                .. ' it (dead surface?)'):format(name) }
                    end
                end
            end
            return out
        end,
    },
    {
        -- Ansible's URL-boundary equivalent: a notify naming no handler is a
        -- SILENT no-op (the handler never runs, no error); a handler nothing
        -- notifies is dead; an include pointing at a missing file breaks at
        -- runtime. The notify no-op is the classic footgun (a typo'd name).
        name = 'ansible-audit', severity = 'warn',
        run = function (store)
            local a = store.data.ansible
            if not a then return {} end
            local out = {}
            for _, u in ipairs(a.noop) do
                out[#out + 1] = { file = store.abs(u.file),
                    line = u.line + 1,
                    message = ("notify '%s' names no handler — a SILENT no-op"
                        .. ' (the handler never runs)'):format(u.name) }
            end
            for _, b in ipairs(a.broken) do
                out[#out + 1] = { file = store.abs(b.file),
                    line = b.line + 1,
                    message = ("include target '%s' does not exist"):format(b.target) }
            end
            for _, name in ipairs(a.dead) do
                out[#out + 1] = { file = '', line = 1, severity = 'info',
                    message = ("handler '%s' is defined but nothing notifies"
                        .. ' it (dead?)'):format(name) }
            end
            return out
        end,
    },
    {
        -- dead config: a role variable declared in defaults/ or vars/ whose
        -- name appears nowhere else in the role (tasks, handlers, jinja). A
        -- soft signal — a var could still be read via hostvars/lookup — so
        -- INFO, but on a large role it surfaces accumulated cruft.
        name = 'ansible-vars', severity = 'info',
        run = function (store)
            local a = store.data.ansible
            if not a then return {} end
            local out = {}
            for _, name in ipairs(a.unused_vars or {}) do
                out[#out + 1] = { file = '', line = 1, severity = 'info',
                    message = ("role variable '%s' is declared but referenced"
                        .. ' nowhere in the role (dead config?)'):format(name) }
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
            -- topology through the RESIDENT fold-backed Band (rung c)
            local band = store.topo()
            -- manifest projects: XML-referenced handlers are engine-dispatched
            local xmlh = store.toc and store.toc.handlers or {}
            for _, n in ipairs(store.data.nodes) do
                if (n.kind == 'function' or n.kind == 'method')
                    and not n.decl -- a prototype is a declaration, not dead code
                    and not exported(n) and not metamethod(n) and not n.cbarg
                    and not n.entry and not xmlh[n.name]
                    and band:n_callers(n.id) == 0
                    -- a registration is an alibi: a dispatch table keeps it alive
                    and band:n_registrants(n.id) == 0 then
                    out[#out + 1] = { file = store.abspath(n), line = atr.sl(n.range) + 1,
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
                    out[#out + 1] = { file = store.abs(file), line = 1,
                        message = ("'%s' is required only for effect, but has none — the require is redundant"):format(file) }
                end
            end
            return out
        end,
    },
    {
        name = 'call-cycle', severity = 'warn',
        run = function (store)
            local band = store.topo()
            local ids, adj = {}, {}
            for _, n in ipairs(store.data.nodes) do
                if n.kind ~= 'module' then ids[#ids + 1] = n.id; adj[n.id] = band:callees(n.id) end
            end
            local out = {}
            for _, comp in ipairs(sccs(ids, adj)) do
                if #comp > 1 then -- size-1 (plain recursion) is not a smell
                    local names = {}
                    for _, id in ipairs(comp) do names[#names + 1] = store.node(id).name end
                    table.sort(names)
                    local n0 = store.node(comp[1])
                    out[#out + 1] = { file = store.abspath(n0), line = atr.sl(n0.range) + 1,
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
