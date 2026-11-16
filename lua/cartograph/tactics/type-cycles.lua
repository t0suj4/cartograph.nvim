-- TYPE-CYCLES (discovery, CART-0697): the TYPE GRAPH — a class -> the classes its INSTANCE fields refer to (base,
-- generic arguments, array elements; data.typerefs, java) — its recursive components, and which equals / hashCode /
-- toString TRAVERSE a cycle: the precondition of the structural-recursion bug families (equals/hashCode recursion,
-- toString stack overflow, a JPA bidirectional link printed both ways).
--
-- A NODE IS (class, file). A field's type binds to the class of that simple name in the SAME file when it is written
-- unqualified, else to the ONE file that defines the name; anything else is ambiguous and dropped, so every count is a
-- LOWER BOUND. Static fields are not part of an instance (`static final TimeValue ONE_MINUTE`). ⚠ A class is KNOWN by a
-- method or a typed field (java has no class node): one with neither does not make its name ambiguous.
--
-- Measured 2026-11-16 on elasticsearch/server (8,069 files, batched under the 3 GB cap): 11,423 types, 103 recursive in
-- 64 components (largest 6); 28 struct methods read a cycle-closing field; a COMPLETE cycle — every type on it
-- traversing the next field with the same method — for equals / hashCode 9 types, toString 1, all tree- or chain-shaped
-- (children lists, nested builders, linked `child` / `nestedSort`): recursion over them terminates. The ticket's first
-- count (487 recursive, a 143-type component, 282 candidates) was simple-name collisions (hundreds of nested
-- `Request` classes) and static constants. A back-pointer (a child holding its parent) traversed both ways is the
-- bug; the graph cannot tell a back-pointer from nesting by shape alone, so this reports, it does not accuse.
-- params: top = rows of each list (default 40).
-- CLAIM: the tree has a type graph (typerefs rows) — and says how many cycles are traversed completely.

local STRUCT = { equals = true, hashCode = true, toString = true }

local function measure(store, p)
    local d = store.data or {}
    local top = tonumber(p.top) or 40
    local rows = d.typerefs or {}
    local cfiles = {}
    local function addc(c, f) cfiles[c] = cfiles[c] or {}; cfiles[c][f] = true end
    for _, r in ipairs(rows) do addc(r.typename, r.file) end
    local smethods = {}
    for _, n in ipairs(d.nodes or {}) do
        if n.kind == 'method' and n.name and n.file then
            local c, m = n.name:match('([%w_$]+)::([%w_$]+)$')
            if c then addc(c, n.file) end
            if c and STRUCT[m] then smethods[#smethods + 1] = { cls = c, m = m, file = n.file, id = n.id } end
        end
    end
    local function only_file(c)
        local one, k = nil, 0
        for f in pairs(cfiles[c] or {}) do one = f; k = k + 1 end
        return k == 1 and one or nil
    end
    -- the graph, and each field's targets
    local adj, fieldto, kept, dropped, statics = {}, {}, 0, 0, 0
    for _, r in ipairs(rows) do
        if r.static then statics = statics + 1
        else
            local me = r.typename .. '@' .. r.file
            adj[me] = adj[me] or {}
            for _, ref in ipairs(r.refs or {}) do
                local simple = ref:match('([%w_$]+)$')
                if simple and cfiles[simple] then
                    local t
                    if not ref:find('.', 1, true) and cfiles[simple][r.file] then t = simple .. '@' .. r.file
                    else local f = only_file(simple); if f then t = simple .. '@' .. f end end
                    if t then
                        adj[me][t] = true; kept = kept + 1
                        local k = me .. '\31' .. r.field
                        fieldto[k] = fieldto[k] or {}; fieldto[k][t] = true
                    else dropped = dropped + 1 end
                end
            end
        end
    end
    -- strongly connected components (iterative Tarjan)
    local index, low, on, st, comp, cnt, ncomp = {}, {}, {}, {}, {}, 0, 0
    local ids = {}
    for c in pairs(adj) do ids[#ids + 1] = c end
    table.sort(ids)
    for _, root in ipairs(ids) do
        if not index[root] then
            local work = { { v = root } }
            index[root], low[root] = cnt, cnt; cnt = cnt + 1; st[#st + 1] = root; on[root] = true
            while #work > 0 do
                local fr = work[#work]
                if not fr.ns then
                    local ns = {}
                    for w in pairs(adj[fr.v] or {}) do ns[#ns + 1] = w end
                    table.sort(ns); fr.ns = ns; fr.i = 1
                end
                local pushed = false
                while fr.i <= #fr.ns do
                    local w = fr.ns[fr.i]; fr.i = fr.i + 1
                    if not index[w] then
                        index[w], low[w] = cnt, cnt; cnt = cnt + 1; st[#st + 1] = w; on[w] = true
                        work[#work + 1] = { v = w }; pushed = true; break
                    elseif on[w] then low[fr.v] = math.min(low[fr.v], index[w]) end
                end
                if not pushed then
                    if low[fr.v] == index[fr.v] then
                        ncomp = ncomp + 1
                        repeat local w = table.remove(st); on[w] = false; comp[w] = ncomp until w == fr.v
                    end
                    table.remove(work)
                    if #work > 0 then local pv = work[#work].v; low[pv] = math.min(low[pv], low[fr.v]) end
                end
            end
        end
    end
    local size = {}
    for _, k in pairs(comp) do size[k] = (size[k] or 0) + 1 end
    local function recursive(v) return comp[v] ~= nil and (size[comp[v]] > 1 or (adj[v] and adj[v][v]) or false) end
    local comps, largest = {}, 0
    for v in pairs(adj) do
        if recursive(v) then
            local c = comp[v]
            comps[c] = comps[c] or {}; table.insert(comps[c], v)
            largest = math.max(largest, size[c])
        end
    end
    local complist = {}
    for _, members in pairs(comps) do table.sort(members); complist[#complist + 1] = members end
    table.sort(complist, function (a, b) if #a ~= #b then return #a > #b end return a[1] < b[1] end)
    -- the struct methods' field reads (use edges into a var of the method's own file)
    local byid = {}
    for _, n in ipairs(d.nodes or {}) do byid[n.id] = n end
    local reads = {}
    for _, e in ipairs(d.edges or {}) do
        if e.kind == 'use' then
            local v = byid[e.to]
            if v and v.kind == 'var' then
                local r = reads[e.from]; if not r then r = {}; reads[e.from] = r end
                r[#r + 1] = v
            end
        end
    end
    local touching, gm = {}, {}
    for _, sm in ipairs(smethods) do
        local me = sm.cls .. '@' .. sm.file
        if recursive(me) then
            for _, v in ipairs(reads[sm.id] or {}) do
                if v.file == sm.file then
                    for t in pairs(fieldto[me .. '\31' .. v.name] or {}) do
                        if comp[t] == comp[me] then
                            touching[#touching + 1] = { method = sm.id, field = v.name, to = t }
                            gm[sm.m] = gm[sm.m] or {}
                            gm[sm.m][me] = gm[sm.m][me] or {}
                            gm[sm.m][me][t] = true
                        end
                    end
                end
            end
        end
    end
    -- COMPLETE cycles: a type that reaches itself in the graph of edges ITS OWN method name traverses
    local complete = {}
    for m, g in pairs(gm) do
        local on_cycle = {}
        for v in pairs(g) do
            local seen, stack = {}, {}
            for w in pairs(g[v]) do stack[#stack + 1] = w end
            while #stack > 0 do
                local x = table.remove(stack)
                if x == v then on_cycle[#on_cycle + 1] = v; break end
                if not seen[x] then seen[x] = true; for y in pairs(g[x] or {}) do stack[#stack + 1] = y end end
            end
        end
        table.sort(on_cycle)
        if #on_cycle > 0 then complete[m] = on_cycle end
    end
    table.sort(touching, function (a, b) if a.method ~= b.method then return a.method < b.method end return a.field < b.field end)
    local function clip(l) local o = {}; for i = 1, math.min(#l, top) do o[i] = l[i] end; return o end
    local nrec = 0
    for _, members in ipairs(complist) do nrec = nrec + #members end
    local ncomplete = 0
    for _, l in pairs(complete) do ncomplete = ncomplete + #l end
    return { typeref_rows = #rows, static_fields = statics, refs_kept = kept, refs_ambiguous = dropped,
        recursive_types = nrec, components = #complist, largest = largest, component_list = clip(complist),
        traversing = clip(touching), n_traversing = #touching, complete = complete, n_complete = ncomplete }
end

local E = {
    name = 'type-cycles',
    kind = 'discovery',
    tags = { 'find', 'code', 'types' },
    measures = 'CART-0697',
    summary = 'the type graph (class -> the classes its instance fields refer to, generics and arrays included; java): its recursive components, the equals / hashCode / toString that read a cycle-closing field, and the cycles a method traverses COMPLETELY (a lower bound: a type name two files define is dropped)',
    params = { top = 'number?' },
    measure = measure,
    claim = function (v)
        if v.typeref_rows == 0 then return false, 'no type references: this tree has no java fields (data.typerefs is empty)' end
        return true, ('%d recursive types in %d components (largest %d); %d struct-method reads of a cycle-closing field; %d types on a completely traversed cycle'):format(
            v.recursive_types, v.components, v.largest, v.n_traversing, v.n_complete)
    end,
}

E.examples = {
    {
        name = 'a tree whose equals walks its children is a completely traversed cycle; a static constant is no cycle',
        files = {
            ['p/Node.java'] = table.concat({
                'package p;',
                'import java.util.List;',
                'public class Node {',
                '  private List<Node> children;',
                '  private String name;',
                '  public boolean equals(Object o) { return children.equals(((Node) o).children); }',
                '}', '' }, '\n'),
            ['p/Unit.java'] = table.concat({
                'package p;',
                'public class Unit {',
                '  public static final Unit ONE = new Unit();',
                '  private int n;',
                '  public boolean equals(Object o) { return n == ((Unit) o).n; }',
                '}', '' }, '\n'),
        },
        params = function () return {} end,
        expect = { holds = true, check = function (v)
            local ok = v.recursive_types == 1 and v.static_fields == 1
                and v.complete.equals and v.complete.equals[1] == 'Node@p/Node.java'
                and v.traversing[1] and v.traversing[1].field == 'children'
            return ok, vim.inspect({ v.recursive_types, v.static_fields, v.complete, v.traversing })
        end },
    },
    {
        name = 'two files defining the same simple name: a qualified reference to it binds nothing (a lower bound)',
        files = {
            ['a/Request.java'] = 'package a;\npublic class Request { private b.Request inner; }\n',
            ['b/Request.java'] = 'package b;\npublic class Request { private int x; int get() { return x; } }\n',
        },
        params = function () return {} end,
        expect = { holds = true, check = function (v)
            return v.recursive_types == 0 and v.refs_ambiguous == 1, vim.inspect({ v.recursive_types, v.refs_ambiguous })
        end },
    },
}

return E
