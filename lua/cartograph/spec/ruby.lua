-- The RUBY language spec + its base helpers and constant tables, extracted
-- via the move-set flow ([[cartograph-spec-layering]]). close_moveset(the 5 BASE
-- helpers) → the ordered 8-symbol base cluster (+RB_ATTR/RB_REJECT_PARENT/
-- RB_BIND_PARENT); RB_ASSOC + ruby_rails_synth are RAILS-PACK-only and stay in
-- the engine with M.packs.rails. node_text is the shared dep. Pure motion.

-- @langs ruby — a spec IS one grammar's mapping, so every node type here is
-- ruby's by construction.

local node_text = require('cartograph.spec.tsutil').node_text

-- Ruby bare-call capture (the "open ceiling"): a bare identifier `save` with
-- no parens/args parses as a plain `identifier`, not a `call`, so the calls
-- query never sees it — yet most idiomatic ruby method calls (attribute reads,
-- `save`/`reload`/`params`) take this form. This scans identifiers in
-- READ/expression positions and returns those that are METHOD CALLS, applying
-- ruby's own var-vs-call rule: a bare name is a local-variable read iff a local
-- of that name is bound in the enclosing method (param, block param, or
-- assignment LHS) — otherwise it is a call on implicit self. Conservative
-- toward SOUNDNESS: any same-named local anywhere in the enclosing method
-- suppresses the call (never emit a call for what might be a var read). The
-- caller keys survivors through qualify_call (R2 → Owner#m). Only identifiers
-- inside a method body are considered (class-body bare calls are DSL = R3; the
-- top level can't key).
local RB_REJECT_PARENT = {
    call = true, method = true, singleton_method = true, alias = true,
    undef = true, scope_resolution = true, setter = true,
    method_parameters = true, block_parameters = true, lambda_parameters = true,
    keyword_parameter = true, optional_parameter = true, splat_parameter = true,
    hash_splat_parameter = true, block_parameter = true, forward_parameter = true,
    destructured_parameter = true,
}

    -- every node type that BINDS its identifier children as locals: params,
    -- block/lambda params, rescue variables (`rescue => e`), for-loop vars, and
    -- pattern-match captures. Over-marking a local only SUPPRESSES a bare call
    -- (sound: never a false call); missing a binder would emit a var read as a
    -- phantom call — so err toward listing more.
    local RB_BIND_PARENT = {
        method_parameters = true, block_parameters = true,
        lambda_parameters = true, keyword_parameter = true,
        optional_parameter = true, splat_parameter = true,
        hash_splat_parameter = true, block_parameter = true,
        destructured_parameter = true, exception_variable = true,
        array_pattern = true, find_pattern = true, hash_pattern = true,
        ['for'] = true,
    }

local function ruby_bare_calls(tsroot, src)
    -- per-method local set (params + block/rescue/for/pattern binds + assignment
    -- LHS in the whole method subtree), memoized by method node id.
    local locals = {}
    local function method_locals(mnode)
        local key = mnode:id()
        local set = locals[key]
        if set then return set end
        set = {}
        locals[key] = set
        local function harvest(n) -- all identifiers in a binding subtree
            if n:type() == 'identifier' then set[node_text(n, src)] = true end
            for c in n:iter_children() do harvest(c) end
        end
        local function scan(n)
            local t = n:type()
            if t == 'identifier' then
                local pt = n:parent() and n:parent():type()
                if pt and RB_BIND_PARENT[pt] then set[node_text(n, src)] = true end
            elseif t == 'assignment' or t == 'operator_assignment' then
                local l = n:field('left')[1]
                local lt = l and l:type()
                -- a plain / multiple / destructuring LHS binds; a call/setter/
                -- element_reference LHS (`obj.x =`, `arr[i] =`) is a WRITE call,
                -- not a binding — its identifiers are reads, leave them be
                if lt == 'identifier' then
                    set[node_text(l, src)] = true
                elseif lt and (lt:find('assignment_list')
                    or lt == 'destructured_left_assignment') then
                    harvest(l)
                end
            end
            for c in n:iter_children() do scan(c) end
        end
        local body = mnode:field('body')[1]
        if body then scan(body) end
        local params = mnode:field('parameters')[1]
        if params then scan(params) end
        return set
    end

    local out = {}
    local function enclosing_method(n)
        local p = n:parent()
        while p do
            local t = p:type()
            if t == 'method' or t == 'singleton_method' then return p end
            if t == 'class' or t == 'module' or t == 'singleton_class' then
                -- reached a class/module body without a def: not in a method
                -- (unless a singleton_class holds defs — keep walking past it)
                if t == 'singleton_class' then p = p:parent()
                else return nil end
            else
                p = p:parent()
            end
        end
        return nil
    end
    local function walk(n)
        if n:type() == 'identifier' then
            local par = n:parent()
            local pt = par and par:type()
            local ok = pt and not RB_REJECT_PARENT[pt]
            -- assignment/pair: keep only the read side (RHS / value), never
            -- the binding (LHS / key)
            if ok and (pt == 'assignment' or pt == 'operator_assignment') then
                ok = par:field('left')[1] ~= n
            elseif ok and pt == 'pair' then
                ok = par:field('key')[1] ~= n
            end
            if ok then
                local name = node_text(n, src)
                -- method names only (lowercase / _; constants are `constant`
                -- nodes, not identifiers, but guard anyway). `?`/`!`/`=` suffix
                -- predicate/bang methods stay identifiers only with `?`/`!`.
                if name:match('^[a-z_]') then
                    local m = enclosing_method(n)
                    if m and not method_locals(m)[name] then
                        out[#out + 1] = { node = n, name = name }
                    end
                end
            end
        end
        for c in n:iter_children() do walk(c) end
    end
    walk(tsroot)
    return out
end

-- Ruby attr_* def-emitters: `attr_accessor :foo` DEFINES accessor methods with
-- no `def` keyword, so nothing is extracted and every `foo` read is an
-- unresolved frontier. This synthesizes the method nodes (`C#foo` reader,
-- `C#foo=` writer) the DSL creates — base-ruby (Module#attr_*), the def-emitter
-- mechanism the rails overlay pack will reuse for associations. Returns
-- {name, node} per emitted method (node = the symbol, for go-to-def).
local RB_ATTR = { attr_reader = 'r', attr_writer = 'w', attr_accessor = 'rw',
    attr = 'r' }

local function ruby_synth_defs(tsroot, src)
    local out = {}
    local function owner_kind(callnode)
        local p, inst, owner = callnode:parent(), true, nil
        while p do
            local t = p:type()
            if t == 'singleton_class' then inst = false
            elseif t == 'class' or t == 'module' then
                local nn = p:field('name')[1]
                owner = nn and node_text(nn, src); break
            end
            p = p:parent()
        end
        return owner, inst
    end
    local function walk(n)
        if n:type() == 'call' then
            local m = n:field('method')[1]
            local mode = m and RB_ATTR[node_text(m, src)]
            local args = mode and n:field('arguments')[1]
            if args then
                local owner, inst = owner_kind(n)
                if owner then
                    local sep = inst and '#' or '.'
                    for c in args:iter_children() do
                        local sym
                        if c:type() == 'simple_symbol' then
                            sym = node_text(c, src):sub(2)
                        elseif c:type() == 'string' then
                            sym = node_text(c, src):gsub('[\'"]', '')
                        end
                        if sym and sym:match('^[%a_][%w_]*$') then
                            if mode:find('r') then
                                out[#out + 1] = { name = owner .. sep .. sym, node = c }
                            end
                            if mode:find('w') then
                                out[#out + 1] = { name = owner .. sep .. sym .. '=', node = c }
                            end
                        end
                    end
                end
            end
        end
        for ch in n:iter_children() do walk(ch) end
    end
    walk(tsroot)
    return out
end

-- Ruby R4 inheritance + mixin scan: the ancestor edges that recover R2/R3's
-- inherited-method frontiers. `class C < D` → C inherits D's instance methods
-- (D#m) and singleton methods (D.m). `include M` / `prepend M` → C gains M's
-- INSTANCE methods (M#m). `extend M` → C gains M's instance methods as its own
-- SINGLETON methods. Returns edges {c=child, p=parent, mode}: 'inst' (look up
-- p#member), 'sings' (superclass singleton, look up p.member), 'singe' (extend
-- module, look up p#member). resolve_ruby_ancestors walks these when a keyed
-- `C#m`/`C.m` misses (nearest-ancestor, unique-or-skip, hedged ~).
local function ruby_ancestors(tsroot, src)
    local out = {}
    local function tailc(node)
        return node_text(node, src):match('([%w_]+)%s*$')
    end
    local function walk(n, cls)
        local t = n:type()
        local mine = cls
        if t == 'class' then
            local nm = n:field('name')[1]
            mine = nm and tailc(nm)
            local sc = n:field('superclass')[1]
            if mine and sc then
                local par = tailc(sc)
                if par then
                    out[#out + 1] = { c = mine, p = par, mode = 'inst' }
                    out[#out + 1] = { c = mine, p = par, mode = 'sings' }
                end
            end
        elseif t == 'module' then
            local nm = n:field('name')[1]
            mine = nm and tailc(nm)
        elseif t == 'call' and cls then
            local m = n:field('method')[1]
            local mn = m and node_text(m, src)
            if mn == 'include' or mn == 'prepend' or mn == 'extend' then
                local a = n:field('arguments')[1]
                if a then
                    for ac in a:iter_children() do
                        local at = ac:type()
                        if at == 'constant' or at == 'scope_resolution' then
                            out[#out + 1] = { c = cls, p = tailc(ac),
                                mode = mn == 'extend' and 'singe' or 'inst' }
                        end
                    end
                end
            end
        end
        for ch in n:iter_children() do walk(ch, mine) end
    end
    walk(tsroot, nil)
    return out
end

-- Ruby R4 `super` keyword: bare `super` / `super(args)` inside `C#foo` calls the
-- ANCESTOR's `foo` (the enclosing method's own name), skipping C's definition.
-- Returns super sites {node, member (enclosing def name), sing (singleton
-- context), cls (enclosing class/module)}; resolve_ruby_ancestors chases the
-- ancestor chain for `member` (its chase already looks at PARENTS, so C's own
-- def is skipped). `super` is its own grammar node (bare → parent body_statement;
-- `super(x)` → the method-child of a call) — NOT captured by the calls query.
local function ruby_super_calls(tsroot, src)
    local out = {}
    local function walk(n)
        if n:type() == 'super' then
            local p, member, sing, cls = n:parent(), nil, false, nil
            while p do
                local t = p:type()
                if (t == 'method' or t == 'singleton_method') and not member then
                    local nm = p:field('name')[1]
                    member = nm and node_text(nm, src)
                    if t == 'singleton_method' then sing = true end
                elseif t == 'singleton_class' then
                    sing = true
                elseif t == 'class' or t == 'module' then
                    local nm = p:field('name')[1]
                    cls = nm and node_text(nm, src):match('([%w_]+)%s*$')
                    break
                end
                p = p:parent()
            end
            if member and cls and member:match('^[%a_]') then
                out[#out + 1] = { node = n, member = member, sing = sing, cls = cls }
            end
        end
        for c in n:iter_children() do walk(c) end
    end
    walk(tsroot)
    return out
end

-- Ruby R5 (rescoped, ADDITIVE) constructor binding scan: `u = Const.new` types
-- the local `u` to `Const`, so an unresolved `u.foo` resolves to `Const#foo`
-- (own or inherited). Restricted to `.new` on a bare constant (sound — a
-- constructor returns exactly an instance). Returns {var, cls}; a var assigned
-- more than once in the file drops to ambiguous (the single-assignment gate at
-- resolve time). This is the SAME scan the reverted exact-only R5 used — the
-- rescope is purely in HOW it's consumed (additive, `full` kept bare, only
-- unresolved calls), not in the typing.
--
-- R5b-more ([[cartograph-ruby-arc]]): `finders` (a set, threaded from the RAILS
-- pack's ctor_finders — nil for pure Ruby) extends the typing to ActiveRecord
-- class FINDERS that return a model instance (`u = User.find/find_by/find_or_*`).
-- SAME shape as `.new` (the receiver is the constant, the result is an instance
-- of it), so it rides the identical bind/gate/resolve machinery. DELIBERATELY a
-- pack input, not base ruby: `find_by` is only instance-returning under Active-
-- Record — a pure-Ruby project must not assume it. Relation-returning verbs
-- (where/all/order) are NOT finders (they yield a Relation, not an instance);
-- generic first/last/take are excluded too (measured: 0 wins, collection over-
-- reach risk — ormfinder probe 2026-07-24).
local function ruby_ctor_binds(tsroot, src, finders)
    local out = {}
    local function walk(n)
        if n:type() == 'assignment' then
            local l = n:field('left')[1]
            local r = n:field('right')[1]
            -- R5: a local `x = C.new`; R5b: an ivar `@x = C.new` (per-file keyed
            -- by `@x`; a same-named ivar across two classes in one file → the
            -- single-assignment gate drops it — conservative, no wrong type).
            local lt = l and l:type()
            if (lt == 'identifier' or lt == 'instance_variable')
                and r and r:type() == 'call' then
                local recv = r:field('receiver')[1]
                local m = r:field('method')[1]
                if recv and recv:type() == 'constant' and m then
                    local mn = node_text(m, src)
                    if mn == 'new' or (finders and finders[mn]) then
                        out[#out + 1] = { var = node_text(l, src),
                            cls = node_text(recv, src) }
                    end
                end
            end
        end
        for c in n:iter_children() do walk(c) end
    end
    walk(tsroot)
    return out
end

return {
    -- CALL POSITIONS (CART-0499): parent node type -> which child holds the
    -- CALLEE NAME, as a field name or a named-child index. Replaces a
    -- hardcoded four-name or-chain inline in the provider that php, java,
    -- bash, rust macros, ruby and haskell were all missing from -- so a call
    -- to a corpus-unique function became a fn REFERENCE and minted a `reg`
    -- edge ("kept alive by top-level DATA"), a different fact. 96.6% of
    -- mantisbt's reg occurrences were mislabelled calls.
    call_positions = {
        call = 'method', -- ★ `call` WAS in the old global list, but the old test
        -- only tried the `function` and `name` fields -- ruby names it `method`,
        -- so ruby's callees were never marked either. Not in the ticket
    },
        exts = { 'rb' },
        functions = [=[
            (method name: (_) @name) @def
            (singleton_method name: (_) @name) @def
        ]=],
        calls = [=[
            (call method: (identifier) @name) @call
            (call method: (constant) @name) @call
        ]=],
        vars = [=[
            (program (assignment
                left: (constant) @vname right: (_) @value) @vdef)
        ]=],
        params_field = 'parameters',
        body_field = 'body',
        -- `block` / `do_block` are deliberately ABSENT. A ruby block is not a
        -- function scope: it CLOSES OVER the enclosing method's locals, so
        -- treating one as a scope boundary would cut a def from its uses.
        -- `lambda` DOES introduce one — for ENCLOSURE. It is listed here and
        -- excluded from the flow stop below, and the distinction is the whole
        -- lesson of CART-0308: "which function encloses this node" and "where
        -- does the flow walk stop" are two different sets, and a stop is only
        -- sound where the extractor mints a node to receive the rows.
        fn_types = { method = true, singleton_method = true, lambda = true },
        -- `lambda` is a scope for ENCLOSURE but the `functions` query above mints
        -- only method/singleton_method, so it is not a sound flow STOP: stopping
        -- there deletes the closure's rows instead of relocating them (CART-0308).
        fn_unminted = { lambda = true },
        is_method = function (_, def)
            if def:type() == 'singleton_method' then return true end
            local p = def:parent()
            while p do
                local t = p:type()
                if t == 'class' or t == 'module'
                    or t == 'singleton_class' then return true end
                p = p:parent()
            end
            return false
        end,
        -- Owner#full_name (instance) / Owner.find_by_city (singleton).
        -- A plain `def m` inside `class << self` is a SINGLETON (class)
        -- method — key it with `.`, not `#` (else `Owner.m` calls miss it
        -- and tail-collide onto an unrelated `X#m`). Detected by a
        -- singleton_class ancestor whose receiver is `self`.
        qualify = function (name, defn, src)
            local sep = defn:type() == 'singleton_method' and '.' or '#'
            local p = defn:parent()
            while p do
                local t = p:type()
                if t == 'singleton_class' then
                    local v = p:field('value')[1]
                    if v and node_text(v, src) == 'self' then sep = '.' end
                elseif t == 'class' or t == 'module' then
                    local cn = p:field('name')[1]
                    return cn and (node_text(cn, src)
                        .. sep .. name) or name
                end
                p = p:parent()
            end
            return name
        end,
        -- classes/modules wrap the real content
        block_skip = { class = true, module = true, singleton_class = true },
        -- bare calls dispatch on self, and inheritance/mixins make the
        -- target unknowable beyond the file: ruby's scope IS the file —
        -- bare names never link cross-file. Honesty over reach: most
        -- ruby calls SHOULD stay unresolved frontiers.
        scope = function (file, _)
            return file
        end,
        id_fn_refs = false,
        -- BASE-RUBY vocabulary: the Object protocol, Enumerable, String/Array/
        -- Hash core — never absorbed by a project def. The RAILS framework verbs
        -- (save/where/find/create/params/render/…) moved OUT to the `rails`
        -- overlay pack (M.packs.rails) — a pure-Ruby project's `save` should
        -- resolve to its OWN def, not be refused as ActiveRecord vocab. The pack
        -- unions its vocab back in for a Rails corpus. ([[cartograph-modular-specs]])
        stdlib_names = { new = true,
            all = true, first = true, last = true, count = true,
            name = true, id = true, to_s = true, to_a = true, to_h = true,
            each = true, map = true, select = true, reject = true,
            include = true, empty = true,
            length = true, size = true, push = true,
            call = true, run = true, inspect = true,
            hash = true, dup = true, freeze = true, fetch = true,
            dig = true, merge = true, join = true, split = true,
            strip = true, gsub = true, sub = true, match = true,
            scan = true, upcase = true, downcase = true, key = true,
            keys = true, values = true, sort = true, uniq = true,
            flatten = true, compact = true, reduce = true, inject = true,
            title = true, body = true, value = true, type = true,
            status = true, message = true, user = true },
        -- R1 constant-receiver keying: `Foo.bar` / `A::B.baz` name a
        -- SINGLETON (class/module) method of the receiver constant, so the
        -- resolution key is `Receiver.method` — an exact match against the
        -- singleton def (`def self.bar` in `class Foo` → `Foo.bar`, per the
        -- `qualify` hook). `A::B::C.m` keys on the TAIL constant `C` (defs
        -- qualify by the innermost class name only). A constant explicitly
        -- NAMES the class, so the key legally crosses files (class reopening
        -- is corpus-wide) via the dotted-global path in resolve(). `.new` is
        -- R1b (needs constructor keying + callee preservation), not yet done.
        --
        -- R2 implicit-self keying: a bare call (no receiver) or explicit
        -- `self.m` dispatches on `self`. In an INSTANCE method body self is
        -- an instance → `Owner#m`; in a singleton context (`def self.x` /
        -- `class << self`) self is the class → `Owner.m`; at pure class-body
        -- level a bare call is class-level DSL (attr_accessor…) = R3, left
        -- bare. Corpus-wide (classes reopen). HEDGED (~): the static owner
        -- is the nearest definition, but dynamic dispatch can land on a
        -- subclass override (the B3 position).
        qualify_call = function (calln, name, src)
            local ct = calln:type()
            -- `call` = paren'd/command/receiver call; `identifier` = a bare
            -- no-paren call surfaced by scan_bare_calls (an implicit-self call).
            if ct ~= 'call' and ct ~= 'identifier' then return nil end
            if name:find('.', 1, true) or name:find(':', 1, true) then
                return nil
            end
            local recv = calln:field('receiver')[1]
            local rt = recv and recv:type()
            if rt == 'constant' or rt == 'scope_resolution' then
                local cn = rt == 'constant' and node_text(recv, src)
                    or node_text(recv, src):match('([%w_]+)%s*$')
                if not cn or cn == '' then return nil end
                if name == 'new' then return nil end -- R1b
                return cn .. '.' .. name
            end
            if recv == nil or rt == 'self' then
                local p, inst, owner = calln:parent(), nil, nil
                while p do
                    local t = p:type()
                    if t == 'method' then
                        if inst == nil then inst = true end
                    elseif t == 'singleton_method'
                        or t == 'singleton_class' then
                        inst = false
                    elseif t == 'class' or t == 'module' then
                        local nn = p:field('name')[1]
                        owner = nn and node_text(nn, src)
                        break
                    end
                    p = p:parent()
                end
                -- inst==nil → a class-body call (no enclosing def): DSL, R3.
                if not owner or inst == nil then return nil end
                -- hedge = { rule } (the documented shape): the census groups
                -- by it, and the edge caps at ~ (dynamic dispatch may hit a
                -- subclass override of this self-method).
                return owner .. (inst and '#' or '.') .. name,
                    { rule = 'self-dispatch' }
            end
            return nil
        end,
        -- receiver evidence (a constant-named class) demands an EXACT match:
        -- `Foo.bar` with no `Foo.bar` def is an honest frontier (inherited via
        -- mixin/superclass = R4, or external), NEVER a promiscuous tail guess
        -- onto some unrelated `C#bar` (arc trap #1: bare tail-match is
        -- promiscuous). The dotted-global exact path stays; only the tail
        -- fallback is suppressed for these keys.
        exact_only_key = function (name)
            return name:match('^%u[%w_]*[.#]') ~= nil
        end,
        -- `#` is ruby's instance-method separator (`Owner#m`): a qualified
        -- name that, like `.`/`::`, legally crosses files (a reopened class
        -- is corpus-wide). Gated so JS private-field `#priv` is untouched.
        hash_qualified = true,
        -- the "open ceiling" fix: surface bare no-paren calls (`save`, an
        -- attribute read) that parse as `identifier`, not `call` — the calls
        -- query can't see them. Returns {node,name} for identifiers that are
        -- METHOD CALLS (var-vs-call resolved); the caller keys each through
        -- qualify_call (R2 → Owner#m) and emits a call record.
        scan_bare_calls = ruby_bare_calls,
        -- attr_* DSL def-emitters: synthesize the accessor method nodes
        -- `attr_accessor :foo` creates (`Owner#foo` / `Owner#foo=`) so calls
        -- (esp. bare attribute reads) resolve. See ruby_synth_defs.
        synth_defs = ruby_synth_defs,
        -- R4 inheritance + mixins: ancestor edges (superclass / include / prepend
        -- / extend) so a keyed `C#m`/`C.m` that misses walks the chain. See
        -- ruby_ancestors + resolve_ruby_ancestors.
        scan_ancestors = ruby_ancestors,
        -- R4 `super` keyword: bare/paren'd super calls the ancestor's same-named
        -- method. See ruby_super_calls + resolve_ruby_ancestors (superx path).
        scan_super = ruby_super_calls,
        -- R5 (additive) receiver-typing: the identifier-receiver local of a
        -- `x.foo` call, stored as c.recv (full stays bare → heuristic intact).
        recv_local = function (calln, src)
            if calln:type() ~= 'call' then return nil end
            local r = calln:field('receiver')[1]
            -- identifier (`x.foo`) or ivar (`@x.foo`, R5b) receiver
            if r and (r:type() == 'identifier'
                or r:type() == 'instance_variable') then
                return node_text(r, src)
            end
        end,
        -- R5 constructor bindings (`u = Const.new`) → data.ruby_ctor, consumed
        -- by resolve_ruby_ancestors' recv path. See ruby_ctor_binds.
        scan_ctors = ruby_ctor_binds,
        import_call = 'require_relative',
        resolve_import = function (mod, files, from)
            local dir = from and from:match('^(.*)/[^/]*$') or ''
            local rel = (dir ~= '' and dir .. '/' or '') .. mod .. '.rb'
            -- normalize ../ segments
            while rel:find('/[^/]+/%.%./') do
                rel = rel:gsub('/[^/]+/%.%./', '/', 1)
            end
            rel = rel:gsub('^%./', '')
            if files[rel] then return rel end
        end,
}
