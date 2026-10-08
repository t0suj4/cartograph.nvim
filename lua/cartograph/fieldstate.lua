-- fieldstate — INSTANCE STATE on the write axis (CART-1575): the fields a method reads and writes through its
-- RECEIVER — python `self.f`, javascript / typescript `this.f`, lua `self.f` in a `T:m` / `T.m(self)` method — per
-- CLASS. OOP code keeps its state, its memos (`if self._cache is None:`, `this.cache ??= …`) and its false sharing on
-- instances, and the write axis modelled module variables only: django-oscar has 60 module-var write edges.
--
-- A per-file collector over the syntax tree, run by the extractor's definition pass: every mention of a method's
-- receiver whose first member is a NAMED field is a record { class, field, fn (the method's tree node), node (the
-- receiver mention), parent }. The extractor mints one `field` node per (file, class, field) and a `use` edge from
-- the method to it carrying rw and the guard class (providers/treesitter.lua M._mint_fields). The receiver is bound
-- only where the language binds it — a closure nested in a method has no receiver of its own (missed, never guessed).
-- Every node type is DATA in the language's own table (the language fence: a comparison names one grammar's type).
--
-- @langs lua python javascript typescript tsx ruby
local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text

local M = {}

-- per language, as data:
--   member   { [member-access type] = the field naming the member }        (`self.f`)
--   recv     'first_param' (the method's first parameter, python) | 'name' (a fixed name, lua `self`) | 'node'
--            (a node type of its own, js `this`); recv_name / recv_type for the last two
--   stop     the function types a receiver search stops at; method: those of them that bind a receiver
--   through  wrappers between a method and its class body (python's decorator); body: the class body type
--   class    'parent' (the class is the body's parent, its `name` field) | 'fn_name' (lua: `T:m` / `T.m(self)`)
--   calls    { [call type] = the field naming its callee } — a member that is a CALLEE is no field
--   ident    the identifier type
local LANGS = {
    python = {
        member = { attribute = 'attribute' }, recv = 'first_param', ident = { identifier = true },
        stop = { function_definition = true, lambda = true }, method = { function_definition = true },
        through = { decorated_definition = true }, body = { block = true }, class = 'parent',
        class_types = { class_definition = true }, calls = { call = 'function' },
    },
    javascript = {
        member = { member_expression = 'property' }, recv = 'node', recv_type = { this = true }, ident = { identifier = true },
        -- (arrow functions do not bind `this`: not a stop)
        stop = { method_definition = true, function_declaration = true, function_expression = true,
            generator_function_declaration = true },
        method = { method_definition = true },
        through = {}, body = { class_body = true }, class = 'parent', class_types = nil, calls = { call_expression = 'function' },
    },
    lua = {
        member = { dot_index_expression = 'field' }, recv = 'name', recv_name = 'self', ident = { identifier = true },
        stop = { function_declaration = true, function_definition = true }, method = { function_declaration = true },
        class = 'fn_name', calls = { function_call = 'name' },
    },
}
-- ruby: the receiver is IMPLICIT — `@x` is the field itself (CART-1584), inside a method of a class or module; a block
-- does not rebind self, so it is no stop
LANGS.ruby = {
    recv = 'ivar', ivar = { instance_variable = true }, ident = { identifier = true },
    stop = { method = true, singleton_method = true }, method = { method = true },
    through = {}, body = { body_statement = true }, class = 'parent', class_types = { class = true, module = true },
    member = {}, calls = {},
}
LANGS.typescript = LANGS.javascript
LANGS.tsx = LANGS.javascript
M.LANGS = LANGS

local function first_param_name(L, fn, src)
    local ps = fn:field('parameters')[1]
    if not ps then return nil end
    for _, c in tsutil.inext, ps, -1 do
        if c:named() then
            if L.ident[c:type()] then return node_text(c, src) end
            local id = c:field('name')[1] or c:named_child(0) -- (a typed / default parameter wraps the name)
            if id and L.ident[id:type()] then return node_text(id, src) end
            return nil
        end
    end
    return nil
end

-- is `n` a receiver mention? -> the method's tree node and the class name | nil
local function receiver(L, n, src)
    local t = n:type()
    if L.recv == 'ivar' then if not L.ivar[t] then return nil end
    elseif L.recv == 'node' then if not L.recv_type[t] then return nil end
    elseif not L.ident[t] then return nil
    elseif L.recv == 'name' and node_text(n, src) ~= L.recv_name then return nil end
    local fn = n:parent()
    while fn and not L.stop[fn:type()] do fn = fn:parent() end
    if not (fn and L.method[fn:type()]) then return nil end
    if L.class == 'fn_name' then -- lua: `T:m` binds self; `T.m(self, …)` names it
        local name = fn:field('name')[1]
        if not name then return nil end
        local nt = node_text(name, src)
        local cls = nt:match('^(.+):[%w_]+$')
        if not cls then
            cls = nt:match('^(.+)%.[%w_]+$')
            if not (cls and first_param_name(L, fn, src) == L.recv_name) then return nil end
        end
        return fn, cls
    end
    if L.recv == 'first_param' and first_param_name(L, fn, src) ~= node_text(n, src) then return nil end
    local p = fn:parent()
    while p and L.through[p:type()] do p = p:parent() end
    if not (p and L.body[p:type()]) then return nil end
    local cls = p:parent()
    if not cls or (L.class_types and not L.class_types[cls:type()]) then return nil end
    local nm = cls:field('name')[1]
    return fn, nm and node_text(nm, src)
end

--- the receiver-field mentions of a parsed file -> { { class, field, fn, node, parent } … } (no write test here: the
--- extractor runs the language's own is_write on node / parent, so the write rule is the write axis's, not a copy)
function M.collect(lang, tsroot, src)
    local L = LANGS[lang]
    if not L then return {} end
    local out = {}
    local function walk(n)
        local p = n:parent()
        if p and L.ivar and L.ivar[n:type()] then -- (`@x`: the mention is the field)
            local fn, cls = receiver(L, n, src)
            if fn and cls then out[#out + 1] = { class = cls, field = (node_text(n, src):gsub('^@', '')), fn = fn, node = n, parent = p } end
        elseif p then
            local fld_field = L.member[p:type()]
            -- (`this.build()` / `self.helper(x)` CALLS a method: the member is a callee, not a field — it had minted a
            -- `Panel.build` field shadowing the method)
            local gp = fld_field and p:parent()
            local callee = gp and L.calls[gp:type()] and gp:field(L.calls[gp:type()])[1] == p
            if fld_field and not callee and p:named_child(0) == n then
                local fn, cls = receiver(L, n, src)
                local f = fn and cls and p:field(fld_field)[1]
                if f then out[#out + 1] = { class = cls, field = node_text(f, src), fn = fn, node = n, parent = p } end
            end
        end
        for _, c in tsutil.inext, n, -1 do walk(c) end
    end
    walk(tsroot)
    return out
end

return M