-- The ZIG language spec (L0 grammar binding + L1 name model) — the FIRST
-- per-language module extracted from the engine ([[cartograph-spec-layering]]
-- P1 step 2, the proof move). zig was chosen for its dense typed hooks (the
-- TYPES capability group). PURE MOTION from providers/treesitter.lua: the
-- zig_* helpers + the M.spec.zig entry, verbatim; the engine now does
-- `M.spec.zig = require('cartograph.spec.zig')`. Shared node primitives come
-- from the tsutil substrate (the only cross-module dependency); everything
-- else is zig-local. Gate: matrix-identical (gate zig).

local node_text = require('cartograph.spec.tsutil').node_text

-- zig_base_type peels *, ?, [], [N] wrappers to the base type identifier,
-- returning it only when PascalCase (Zig convention: types are PascalCase,
-- values camelCase — so `u32`/`usize`/`bool` builtins never key a struct).
local function zig_base_type(node, src)
    if not node then return nil end
    local t = node:type()
    if t == 'pointer_type' or t == 'optional_type'
        or t == 'slice_type' or t == 'array_type' then
        for c in node:iter_children() do
            if c:named() then
                local inner = zig_base_type(c, src)
                if inner then return inner end
            end
        end
        return nil
    end
    if t == 'identifier' then
        local nm = node_text(node, src)
        return nm:match('^%u') and nm or nil
    end
    return nil -- builtin_type / error_union / anonymous struct → not keyable
end

-- Def-side companion to zig_recv_type: the receiver type of a TOP-LEVEL fn is
-- its first parameter's type, when that param is a POINTER to a PascalCase
-- struct (`fn m(self: *T, ...)` — the Zig method convention; `x.m()` resolves
-- `m` in x's type namespace passing x first). Keying the def `T.m` here meets
-- the call `x.m()` (x:*T) keyed `T.m` on zig_recv_type's side, so `@This()`
-- aliasing (`const Func = @This()`) is irrelevant: both use the type NAME as
-- written in the receiver param. Gated to POINTER receivers (`self: *T`) on
-- BOTH sides — symmetric, and measured the best config: value-receiver methods
-- stay bare (keeping their same-file tail reach), which both resolves MORE
-- (they'd otherwise strand on cross-module exact misses) and avoids keying the
-- constructor's value first-param (`gpa: Allocator`) as a bogus method owner.
-- Receiver-less (static) fns and non-struct first params stay bare.
local function zig_method_owner(defn, src)
    for c in defn:iter_children() do
        if c:type() == 'parameters' then
            for pc in c:iter_children() do
                if pc:type() == 'parameter' then
                    -- parameter = (identifier <name>) <type>; the receiver
                    -- type is the second named child.
                    local seen_name, tynode
                    for cc in pc:iter_children() do
                        if cc:named() then
                            if not seen_name then seen_name = true
                            else tynode = cc break end
                        end
                    end
                    if tynode and tynode:type() == 'pointer_type' then
                        return zig_base_type(tynode, src)
                    end
                    return nil -- first param isn't a pointer receiver
                end
            end
            return nil -- no params → static/free fn
        end
    end
end

-- Value-receiver dual-key (the sound half zig_method_owner leaves out). A
-- top-level `fn eql(self: Foo, ...)` takes its receiver BY VALUE, so qualify
-- keeps it bare (its same-file `eql()` reach). But a POINTER-typed caller
-- (`p.eql()`, p:*Foo) keys `Foo.eql` exact — and exact-only refuses rather
-- than fall back to bare, so today that call misses its own value-recv method.
-- alt_keys adds the `Foo.eql` exact key IN ADDITION to the bare one: unique
-- cross-file → resolves, same-named across modules → honest ambiguous-refuse,
-- same-file → same-file priority picks it. Gated to a GENUINE receiver — the
-- first param named `self` (the @This file-struct idiom; `Self` is never
-- unique so those keys only ever resolve same-file) OR the lowercased type
-- (`symbol: Symbol`) — which dodges the constructor trap (`init(gpa: Allocator)`
-- keys nothing: gpa is neither `self` nor `allocator`... it's an arg, not a
-- receiver). Value (identifier) type ONLY — pointers are zig_method_owner's.
local function zig_value_owner(defn, src)
    for c in defn:iter_children() do
        if c:type() == 'parameters' then
            for pc in c:iter_children() do
                if pc:type() == 'parameter' then
                    local nm, tynode
                    for cc in pc:iter_children() do
                        if cc:named() then
                            if not nm then nm = node_text(cc, src)
                            else tynode = cc break end
                        end
                    end
                    if tynode and tynode:type() == 'identifier' then
                        local ty = node_text(tynode, src)
                        if ty:match('^%u') and nm
                            and (nm == 'self' or nm == ty:lower()) then
                            return ty
                        end
                    end
                    return nil -- first param isn't a value receiver
                end
            end
            return nil
        end
    end
end

local function zig_recv_type(calln, recv, src)
    local p = calln:parent()
    while p do
        local t = p:type()
        if t == 'function_declaration' then
            for c in p:iter_children() do
                if c:type() == 'parameters' then
                    for pc in c:iter_children() do
                        if pc:type() == 'parameter' then
                            local nm, tynode
                            for cc in pc:iter_children() do
                                if cc:named() then
                                    if cc:type() == 'identifier' and not nm then
                                        nm = node_text(cc, src)
                                    elseif nm and not tynode then
                                        tynode = cc
                                    end
                                end
                            end
                            if nm == recv then
                                -- symmetric with zig_method_owner (def side):
                                -- type ONLY pointer receivers (`recv: *T`). A
                                -- value receiver (`mir: Mir`) is left bare so
                                -- it takes the same-file tail path — otherwise
                                -- a value-receiver call would key `T.method`
                                -- and mis-match a DIFFERENT file's pointer-
                                -- receiver `T` (same-named type, other module).
                                if tynode and tynode:type() == 'pointer_type' then
                                    return zig_base_type(tynode, src)
                                end
                                return nil
                            end
                        end
                    end
                end
            end
            return nil -- reached the fn; recv is not one of its params
        end
        if t == 'source_file' then return nil end
        p = p:parent()
    end
end

-- The base TYPE of an identifier `name` declared as a parameter of node's
-- enclosing function (ANY receiver form — value or pointer, unlike zig_recv_type
-- which is pointer-only). Used to type an instance-chain ROOT (`analysis` in
-- `analysis.air.extraData()`, from `fn f(analysis: *Analysis)`). `self` is a
-- normal param (`fn m(self: *Foo)`), so it is covered too. Returns a PascalCase
-- base or nil (a builtin/generic/unknown param type is not keyable).
local function zig_ident_type(node, name, src)
    local p = node:parent()
    while p do
        local t = p:type()
        if t == 'function_declaration' then
            for c in p:iter_children() do
                if c:type() == 'parameters' then
                    for pc in c:iter_children() do
                        if pc:type() == 'parameter' then
                            local pn, tynode
                            for cc in pc:iter_children() do
                                if cc:named() then
                                    if not pn then pn = node_text(cc, src)
                                    else tynode = cc break end
                                end
                            end
                            if pn == name then return zig_base_type(tynode, src) end
                        end
                    end
                end
            end
            return nil
        end
        if t == 'source_file' then return nil end
        p = p:parent()
    end
end

-- LOCAL FIELD-ACCESS TYPING (one hop): a local `const x = ROOT.field` where ROOT
-- is a parameter of the enclosing fn. So a call `x.method()` is treated as the
-- field chain `ROOT.field.method()` and resolved by resolve_field_chain (no new
-- post-pass). The dominant local idiom (`const sema = …; sema.typeOf()`).
-- PERF: the map is built ONCE PER FILE (a single traversal, fn-scoped) and cached
-- on the src string — a per-call body walk was O(calls×body) and blew extraction
-- from 90s to >400s. zig_local_field then does an O(depth) walk-up + O(1) lookup.
-- Single-binding only: a name declared >1× in a fn → false (ambiguous, sound).
local function build_zig_lf_map(tsroot, src)
    local map = {} -- fn:id() -> { localname -> {ptype, field} | false }
    local function walk(n, curfn)
        local t = n:type()
        if t == 'function_declaration' then curfn = n end
        if t == 'variable_declaration' and curfn then
            local nm, rhs, seen
            for c in n:iter_children() do
                if c:named() then
                    if not seen and c:type() == 'identifier' then
                        nm = node_text(c, src); seen = true
                    elseif seen and not rhs then rhs = c end
                end
            end
            if nm and rhs and rhs:type() == 'field_expression' then
                local ro = rhs:field('object')[1]
                local fld = rhs:field('member')[1]
                if ro and ro:type() == 'identifier' and fld then
                    local pt = zig_ident_type(rhs, node_text(ro, src), src)
                    if pt then
                        local fid = curfn:id()
                        map[fid] = map[fid] or {}
                        if map[fid][nm] == nil then
                            map[fid][nm] = { ptype = pt, field = node_text(fld, src) }
                        else map[fid][nm] = false end -- redeclared → ambiguous
                    end
                end
            end
        end
        for c in n:iter_children() do walk(c, curfn) end
    end
    walk(tsroot, nil)
    return map
end
local zig_lf_src, zig_lf_map
local function zig_local_field(calln, name, src)
    if src ~= zig_lf_src then
        local r = calln
        while r:parent() do r = r:parent() end
        zig_lf_map = build_zig_lf_map(r, src)
        zig_lf_src = src
    end
    local p = calln:parent()
    while p do
        local t = p:type()
        if t == 'function_declaration' then
            local e = zig_lf_map[p:id()]
            local rec = e and e[name]
            if rec then return rec.ptype, rec.field end
            return nil
        end
        if t == 'source_file' then return nil end
        p = p:parent()
    end
end

-- Zig @import module binding: scan `const NAME = @import("path.zig")` binds so
-- the module-alias pass (resolve_module_alias) can resolve `NAME.member()` to
-- that file's export — binding beats name-match ([[cartograph-linker]] layer 1).
-- Returns {alias, path} per bind; only `.zig` paths (a project file); std/
-- builtin imports ("std", "builtin") are left for resolve_import to reject.
-- A file-duplicated alias (two imports, same name) is dropped — ambiguous.
local function zig_imports(tsroot, src)
    local seen, dup = {}, {}
    local function walk(n)
        if n:type() == 'variable_declaration' then
            local alias, bf
            for c in n:iter_children() do
                local t = c:type()
                if t == 'identifier' and not alias then alias = node_text(c, src)
                elseif t == 'builtin_function' then bf = c end
            end
            if alias and bf then
                local bi, path
                for c in bf:iter_children() do
                    local t = c:type()
                    if t == 'builtin_identifier' then bi = node_text(c, src)
                    elseif t == 'arguments' then
                        for a in c:iter_children() do
                            if a:type() == 'string' then
                                path = node_text(a, src):gsub('^["\']', '')
                                    :gsub('["\']$', '')
                                break
                            end
                        end
                    end
                end
                if bi == '@import' and path then
                    if seen[alias] and seen[alias] ~= path then dup[alias] = true
                    else seen[alias] = path end
                end
            end
        end
        for c in n:iter_children() do walk(c) end
    end
    walk(tsroot)
    local out = {}
    for alias, path in pairs(seen) do
        if not dup[alias] then out[#out + 1] = { alias = alias, path = path } end
    end
    return out
end

return {
        exts = { 'zig' },
        functions = [=[
            (function_declaration name: (identifier) @name) @def
        ]=],
        calls = [=[
            (call_expression function: (identifier) @name) @call
            (call_expression
                function: (field_expression member: (identifier) @name)) @call
        ]=],
        params_field = 'parameters',
        body_field = 'body',
        -- a fn nested in a struct_declaration is a member (of the enclosing
        -- `const T = struct`); a top-level fn is free
        is_method = function (_, def)
            local p = def:parent()
            while p do
                local t = p:type()
                if t == 'struct_declaration' then return true end
                if t == 'source_file' then break end
                p = p:parent()
            end
            return false
        end,
        -- member fn → T.method (T = the const the struct value is bound to)
        qualify = function (name, defn, src)
            local p = defn:parent()
            while p do
                local t = p:type()
                if t == 'struct_declaration' then
                    local vd = p:parent()
                    if vd and vd:type() == 'variable_declaration' then
                        for c in vd:iter_children() do
                            if c:type() == 'identifier' then
                                return node_text(c, src) .. '.' .. name
                            end
                        end
                    end
                    return name
                end
                if t == 'source_file' then break end
                p = p:parent()
            end
            -- R5 method keying: a top-level fn whose first param is a pointer
            -- receiver (`fn fail(func: *Func, ...)`) is a method of that type →
            -- key `Func.fail`. It lands in exact['Func.fail'] (so a receiver
            -- call `func.fail()` resolves) AND in tail['fail'] (so same-file
            -- bare `fail()` calls keep their file-local reach). The type is
            -- taken from the receiver param (not the filename), so the
            -- `const Func = @This()` alias pattern keys consistently with the
            -- call side. Receiver-less / value-receiver fns stay bare.
            local owner = zig_method_owner(defn, src)
            if owner then return owner .. '.' .. name end
            return name
        end,
        -- value-receiver dual-key: a bare (value-receiver) top-level method also
        -- gets a `Type.method` exact key so a pointer-typed receiver call finds
        -- it (see zig_value_owner). Only bare names (top-level, non-pointer);
        -- struct-nested / pointer-receiver defs already carry a dotted key.
        alt_keys = function (name, defn, src)
            if name:find('.', 1, true) then return {} end
            local owner = zig_value_owner(defn, src)
            return owner and { owner .. '.' .. name } or {}
        end,
        -- R5 receiver typing (call side): `recv.method()` keys `Type.method`
        -- exact. A PascalCase receiver IS the type (`Foo.init` → `Foo.init`); a
        -- lowercase receiver is an instance typed from the enclosing fn's params
        -- (`sema: *Sema` → `sema.x()` = `Sema.x`). The def side (qualify above +
        -- struct methods) keys the same `Type.method`, so the two meet. Hedged
        -- (~): dispatch is static-nearest; a comptime-generic call could differ.
        qualify_call = function (calln, name, src)
            if calln:type() ~= 'call_expression' then return nil end
            local fe = calln:field('function')[1]
            if not fe or fe:type() ~= 'field_expression' then return nil end
            local obj = fe:field('object')[1]
            -- a multi-level chain `root.Type.method()` (obj is itself a
            -- field_expression) is NOT keyed here: it already resolves via the
            -- bare-tail + same-file path, and diverting it to an exact-only
            -- `Type.method` key LOSES those same-file hits on a miss. The
            -- cross-file chains (bare tail refuses) are upgraded additively by
            -- resolve_chain_type (a post-pass, unresolved-only).
            if not obj or obj:type() ~= 'identifier' then return nil end
            local recv = node_text(obj, src)
            if recv:match('^%u') then -- PascalCase receiver = the type itself
                return recv .. '.' .. name, { rule = 'type-recv' }
            end
            local ty = zig_recv_type(calln, recv, src)
            if ty then return ty .. '.' .. name, { rule = 'recv-typed' } end
            return nil
        end,
        -- a typed receiver key (`Type.method`) is exact-or-nothing: a miss is an
        -- honest frontier (an external/std method, or file-as-struct not in the
        -- corpus), NEVER a promiscuous tail guess onto some unrelated `X.method`.
        exact_only_key = function (name)
            return name:match('^%u[%w_]*%.') ~= nil
        end,
        entry_names = { main = true },
        -- a .zig file is a namespace (imported by @import path); bare names are
        -- file-local, struct-qualified `T.method` cross files via the type name
        scope = function (file, _) return file end,
        -- `pub` = exported (visible through @import); no in-file caller says nothing
        exported_def = function (defn, src)
            return node_text(defn, src):match('^pub%f[%A]') ~= nil
        end,
        id_fn_refs = false,
        -- Zig builtins are @-prefixed (their own node, not identifier calls);
        -- these are common std/method verbs that must not absorb a project def
        stdlib_names = { init = true, deinit = true, alloc = true, free = true,
            create = true, destroy = true, append = true, print = true,
            format = true, expect = true, expectEqual = true, len = true,
            deref = true, ptr = true, items = true, slice = true, next = true,
            reset = true, deinitialize = true, allocator = true, dupe = true,
            writeAll = true, write = true, read = true, close = true,
            toOwnedSlice = true, ensuretotal = true, get = true, put = true,
            contains = true, count = true, clone = true, resize = true,
            -- std.io.Writer verbs — a `writer.writeInt()` names the std writer,
            -- never a project method (kept out of the receiver-typed index)
            writeInt = true, writeByte = true, writeByteNTimes = true,
            writeStruct = true, flush = true },
        -- @import module binding: `const Foo = @import("foo.zig")` binds Foo to
        -- that file; a `Foo.member()` call then resolves to foo.zig's export via
        -- resolve_module_alias (binding beats name-match). scan_imports collects
        -- the binds; resolve_import maps a `.zig` path (relative to the importing
        -- file) to a corpus file; recv_local preserves the single-identifier
        -- receiver so a LOWERCASE alias (`const bar = @import(…); bar.run()`,
        -- which R5 leaves bare) is still recognized by the alias pass.
        scan_imports = zig_imports,
        resolve_import = function (path, files, from)
            if not path:match('%.zig$') then return nil end -- std/builtin → ext
            local dir = from and from:match('^(.*)/[^/]*$') or ''
            local rel = (dir ~= '' and dir .. '/' or '') .. path
            rel = rel:gsub('/%./', '/')                 -- collapse /./
            while rel:find('/[^/]+/%.%./') do           -- collapse a/../
                rel = rel:gsub('/[^/]+/%.%./', '/', 1)
            end
            rel = rel:gsub('^%./', '')
            while rel:find('^%.%./') do rel = rel:gsub('^%.%./', '') end
            if files[rel] then return rel end
        end,
        recv_local = function (calln, src)
            if calln:type() ~= 'call_expression' then return nil end
            local fe = calln:field('function')[1]
            if not fe or fe:type() ~= 'field_expression' then return nil end
            local obj = fe:field('object')[1]
            if obj and obj:type() == 'identifier' then
                return node_text(obj, src)
            end
        end,
        -- multi-level chain type: `root.Type.method()` — the segment right
        -- before the method (this field_expression's object's member). When
        -- PascalCase it names the method's TYPE namespace (`link.File.open` →
        -- File), persisted as c.chainty for the additive chain post-pass
        -- (resolve_chain_type). A lowercase penult (`l.air_instructions.items`)
        -- is an instance field → left nil (needs field-type inference).
        chain_type = function (calln, src)
            if calln:type() ~= 'call_expression' then return nil end
            local fe = calln:field('function')[1]
            if not fe or fe:type() ~= 'field_expression' then return nil end
            local obj = fe:field('object')[1]
            if not obj or obj:type() ~= 'field_expression' then return nil end
            local pmem = obj:field('member')[1]
            if pmem and pmem:type() == 'identifier' then
                local ty = node_text(pmem, src)
                if ty:match('^%u') then return ty end
            end
        end,
        -- instance chain `root.field.method()` (LOWERCASE penult = a struct
        -- field, not a type). Returns (root TYPE, field name): the root's type
        -- from the enclosing fn's params (`fn f(a: *Analysis)` → a → Analysis),
        -- the field name verbatim (`air`). Persisted as c.chainroot / c.chainfield
        -- so resolve_field_chain can look the field's type up in the global field
        -- map and resolve the method on it. Root type unknown (a local, not a
        -- param) → nil (needs local type inference, a separate arc).
        chain_root = function (calln, src)
            if calln:type() ~= 'call_expression' then return nil end
            local fe = calln:field('function')[1]
            if not fe or fe:type() ~= 'field_expression' then return nil end
            local obj = fe:field('object')[1]
            if not obj then return nil end
            if obj:type() == 'field_expression' then -- `root.field.method()`
                local penult = obj:field('member')[1]
                local robj = obj:field('object')[1]
                if not (penult and penult:type() == 'identifier'
                    and robj and robj:type() == 'identifier') then return nil end
                local field = node_text(penult, src)
                if field:match('^%u') then return nil end -- PascalCase → chain_type's job
                local rt = zig_ident_type(calln, node_text(robj, src), src)
                if rt then return rt, field end
                return nil
            end
            -- LOCAL FIELD-ACCESS typing: `const x = P.field; x.method()` — x is a
            -- local (NOT a param — params are qualify_call/R5's job), bound to a
            -- param's field. Treat as the field chain `P.field.method` so
            -- resolve_field_chain resolves it (the dominant `const sema=…; sema.x()`
            -- idiom). obj is the bare receiver identifier here.
            if obj:type() == 'identifier' then
                local x = node_text(obj, src)
                if zig_ident_type(calln, x, src) then return nil end -- x is a param → R5
                local pt, field = zig_local_field(calln, x, src)
                if pt and field then return pt, field end
            end
        end,
        -- struct field types: `const T = struct { air: Air, count: u32, p: *Bar }`
        -- → {typename=T, field, ftype} per field with a keyable (PascalCase, base-
        -- peeled) type. Feeds data.fieldtypes; a generic/builtin field (u32,
        -- std.MultiArrayList(x)) yields no base → skipped (not keyable).
        scan_fields = function (tsroot, src)
            local out = {}
            local function walk(n)
                if n:type() == 'struct_declaration' then
                    local vd, tn = n:parent(), nil
                    if vd and vd:type() == 'variable_declaration' then
                        for c in vd:iter_children() do
                            if c:type() == 'identifier' then
                                tn = node_text(c, src) break
                            end
                        end
                    end
                    if tn then
                        for c in n:iter_children() do
                            if c:type() == 'container_field' then
                                local fname, tynode
                                for cc in c:iter_children() do
                                    if cc:named() then
                                        if not fname and cc:type() == 'identifier' then
                                            fname = node_text(cc, src)
                                        elseif fname and not tynode then tynode = cc end
                                    end
                                end
                                local b = tynode and zig_base_type(tynode, src)
                                if fname and b then
                                    out[#out + 1] = { typename = tn,
                                        field = fname, ftype = b }
                                end
                            end
                        end
                    end
                end
                for c in n:iter_children() do walk(c) end
            end
            walk(tsroot)
            return out
        end,
        -- declared RETURN TYPE of a fn def (the per-def summary n.ret feeds
        -- local-type inference / return-typing, [[cartograph-local-type-inference]]).
        -- Zig writes the return type in the signature: `fn f(...) RET { }` — the
        -- named child after `parameters`, before the block. SYNTAX-read, not
        -- inference: Self/@This() → the receiver's own type (zig_method_owner /
        -- zig_value_owner); peel error-union/optional/pointer wrappers to a
        -- keyable PascalCase payload; anything else (builtin, anon struct,
        -- generic) → nil (honest — no keyable summary).
        def_ret = function (defn, src)
            local params_seen, rt
            for c in defn:iter_children() do
                local t = c:type()
                if t == 'parameters' then params_seen = true
                elseif params_seen and c:named() and t ~= 'block' then
                    rt = c; break
                end
            end
            if not rt then return nil end
            local function resolve_rt(node, depth)
                if not node or depth > 4 then return nil end
                local txt = node_text(node, src)
                if txt == 'Self' or txt == '@This()' then
                    return zig_method_owner(defn, src) or zig_value_owner(defn, src)
                end
                local t = node:type()
                if t == 'error_union_expression' or t == 'error_union'
                    or t == 'optional_type' or t == 'pointer_type'
                    or t == 'slice_type' or t == 'array_type' then
                    for c in node:iter_children() do
                        if c:named() then
                            local r = resolve_rt(c, depth + 1)
                            if r then return r end
                        end
                    end
                    return nil
                end
                return zig_base_type(node, src)
            end
            return resolve_rt(rt, 0)
        end,
}
