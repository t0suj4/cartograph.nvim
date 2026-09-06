-- dtsread — read TypeScript DECLARATION files into one surface accumulator.
--
-- ★★ WHY A MODULE AND NOT A SECOND COPY (CART-0805). `tools/npmdistill.lua` grew a
-- .d.ts reader for npm packages; the BROWSER surface is the same job over
-- TypeScript's own `lib.dom.d.ts`, and the walker that reads a declaration file is
-- exactly the kind of thing this repo has copied before and paid for — probe.lua's
-- header records six hand-rolled kid descents sharing one bug. So the walk lives
-- here once and the two distillers differ only in where the text comes from and in
-- what counts as a NAMESPACE.
--
--   PACKAGE mode (npmdistill): the package name IS the namespace, and every named
--   declaration anywhere in its file is reachable as `pkg.member`, because a
--   package's entry declaration is what an import of it yields.
--   AMBIENT mode (domdistill): a namespace is `declare var document: Document`,
--   and its members are Document's — the file describes a GLOBAL ENVIRONMENT, so
--   nothing is reachable except through a global the environment declares.
--
-- A .d.ts has no executable body by construction; this reads names, never runs
-- anything ([[cartograph-stdlib-profile]]).

local M = {}

-- a primitive types nothing a member can be resolved on, and a generic type
-- VARIABLE is not a type at all (npmdistill's measured rule, kept verbatim:
-- `bookshelf.at -> T` and `knex.before -> any` could only match by accident)
local PRIM = { void = 1, any = 1, unknown = 1, never = 1, ['this'] = 1,
    boolean = 1, string = 1, number = 1, object = 1, symbol = 1, bigint = 1,
    null = 1, undefined = 1, Object = 1, Function = 1 }

--- The BASE NAME of a type expression, or nil when the expression is not one
--- named type.
--- ★ `Promise<X>` unwraps to X: a member typed `Promise<T>` is awaited at the call
--- site far more often than it is held.
--- ★ `SinonStub<TArgs, R>` -> SinonStub: the type arguments decide the types of a
--- member's PARAMETERS, never WHICH members exist, and members are all this
--- surface answers about.
--- ★★ AN INTERSECTION YIELDS ITS FIRST KNOWN COMPONENT AND A UNION YIELDS NIL, and
--- the asymmetry is the whole point. `Window & typeof globalThis` HAS every member
--- of Window, so naming Window is a subset claim and sound. `HTMLElement | null`
--- has only what BOTH sides have, so naming HTMLElement would claim members the
--- value may not carry.
function M.base_of(txt)
    txt = (txt or ''):gsub('%s+', ' '):gsub('^:%s*', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if txt == '' then return nil end
    if txt:find('|', 1, true) then return nil end -- a union: only common members
    if txt:find('&', 1, true) then
        for part in txt:gmatch('[^&]+') do
            local b = M.base_of(part)
            if b then return b end
        end
        return nil
    end
    local inner = txt:match('^Promise%s*<%s*(.+)%s*>$')
    if inner then return M.base_of(inner) end
    local plain = txt:match('^([%w_$]+)%s*<.*>$') or txt:match('^([%w_$]+)$')
    if not plain or PRIM[plain] then return nil end
    -- a type VARIABLE by convention: one or two characters, capitalised. Being too
    -- strict here yields a MISSING return type, never a wrong one.
    if #plain <= 2 and plain:match('^%u') then return nil end
    return plain
end

--- a fresh accumulator; several sources absorb into one
function M.new()
    return {
        sigs = {}, vocab = {}, nsset = {}, free = {},
        owner_members = {},   -- interface -> { member -> true }
        prop_type = {},       -- sig key -> the declared type of that property
        call_sigs = {},       -- interface -> { arity -> return base name }
        alias = {},           -- alias name -> { mentioned type names }
        ext = {},             -- interface -> { base interface names }
        gvar = {},            -- ambient global -> its declared type
        nmem = 0, nret = 0,
    }
end

local function text(n, src) return vim.treesitter.get_node_text(n, src) end

-- ⚠⚠ ONLY THESE HAVE A RETURN TYPE. The `type_annotation` fallback below is a
-- convenience for grammars that do not name the field — and applied to a
-- PROPERTY it reads the property's own type as if it were a return, which is a
-- WRONG FACT, not a missing one: `sinon.assert` does not RETURN a SinonAssert, it
-- IS one, and `sinon.stub` does not return a SinonStubStatic. The first cut of
-- this shared reader did exactly that and the tell was two numbers moving in
-- opposite directions — declared return types 1167 -> 2530 while callable
-- properties typed by arity went 391 -> 0, because a property that had wrongly
-- acquired a `ret` no longer qualified for the arity pass that would have given
-- it the right one.
local RETURNING = { method_signature = true, function_signature = true,
    function_declaration = true, call_signature = true, method_definition = true }

--- the declared RETURN type of a signature; nil when it is not one named type
local function ret_of(n, src)
    if not RETURNING[n:type()] then return nil end
    local rt = n:field('return_type')[1]
    if not rt then
        for ch in n:iter_children() do
            if ch:type() == 'type_annotation' then rt = ch end
        end
    end
    if not rt then return nil end
    return M.base_of(text(rt, src))
end

--- the declared TYPE of a property or variable — NOT a return type, and never
--- stored as one: `sinon.assert` does not RETURN a SinonAssert, it IS one.
local function type_of(n, src)
    local t = n:type()
    if t ~= 'property_signature' and t ~= 'public_field_definition'
        and t ~= 'variable_declarator' then return nil end
    local tn = n:field('type')[1]
    if not tn then return nil end
    return M.base_of(text(tn, src))
end

local NAMED = { function_signature = true, function_declaration = true,
    class_declaration = true, interface_declaration = true,
    variable_declarator = true, method_signature = true,
    property_signature = true }

--- Absorb one declaration source. `opts.ns` names the PACKAGE mode's namespace;
--- `opts.ambient` selects AMBIENT mode. Returns the number of namespace-level
--- members found (package mode) or of globals declared (ambient mode).
function M.absorb(acc, src, opts)
    opts = opts or {}
    local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'typescript')
    if not okp then return 0 end
    local okt, tree = pcall(function () return parser:parse()[1] end)
    if not okt or not tree then return 0 end
    local nsname, found = opts.ns, 0

    -- ⚠ AMBIENT IS NOT INHERITED THROUGH A BODY (CART-0805). `declare` opens ONE
    -- declaration, and letting the flag ride every descendant made
    -- `declare namespace CSS { function Hz(value: number) }` register `Hz`, `Q`,
    -- `cap` and `ch` as callable GLOBALS — names that would then claim any
    -- unresolved project function sharing them. It rides only the variable
    -- container that stands between `declare` and its declarator.
    -- the nodes `declare` reaches through: the variable container, the declarator
    -- it holds, and a bare `declare function`. An interface or namespace BODY is
    -- deliberately absent, which is the whole fix.
    local AMBIENT_THROUGH = { variable_declaration = true, lexical_declaration = true,
        variable_declarator = true, function_signature = true }

    local function walk(n, owner, ambient)
        local t = n:type()
        ambient = (t == 'ambient_declaration') or (ambient and AMBIENT_THROUGH[t]) or false
        -- a callable interface is how a .d.ts spells an OVERLOADED function, and
        -- the overloads may return different types — one per arity
        if t == 'call_signature' and owner then
            local params, rtn
            for ch in n:iter_children() do
                local ct = ch:type()
                if ct == 'formal_parameters' then params = ch
                elseif ct == 'type_annotation' then rtn = ch end
            end
            local base = rtn and M.base_of(text(rtn, src))
            if base then
                acc.call_sigs[owner] = acc.call_sigs[owner] or {}
                local arity = params and params:named_child_count() or 0
                -- the FIRST signature at an arity wins: declarations list the
                -- specific overloads before the catch-alls
                if acc.call_sigs[owner][arity] == nil then
                    acc.call_sigs[owner][arity] = base
                end
            end
        end
        if t == 'type_alias_declaration' then
            local anm = n:field('name')[1]
            local at = anm and text(anm, src)
            if at and at:match('^[%w_$]+$') then
                local set = {}
                local function names(x)
                    if x:type() == 'type_identifier' then
                        local nm = text(x, src)
                        if nm and nm:match('^[%w_$]+$') and nm ~= at then set[nm] = true end
                    end
                    for ch in x:iter_children() do if ch:named() then names(ch) end end
                end
                names(n)
                acc.alias[at] = set
            end
        end
        if t == 'interface_declaration' or t == 'class_declaration' then
            local onm = n:field('name')[1]
            if onm then
                local ot = text(onm, src)
                if ot and ot:match('^[%w_$]+$') then
                    owner = ot
                    -- ★ THE BASES, because a member of `Document` is mostly NOT
                    -- declared on Document: `document.appendChild` lives on Node,
                    -- seven interfaces up the extends clause.
                    for ch in n:iter_children() do
                        if ch:type() == 'extends_type_clause'
                            or ch:type() == 'class_heritage' then
                            local bases = acc.ext[ot] or {}
                            local function collect(x)
                                if x:type() == 'type_identifier' then
                                    local b = text(x, src)
                                    if b and b:match('^[%w_$]+$') and b ~= ot then
                                        bases[#bases + 1] = b
                                    end
                                end
                                for c2 in x:iter_children() do
                                    if c2:named() then collect(c2) end
                                end
                            end
                            collect(ch)
                            acc.ext[ot] = bases
                        end
                    end
                end
            end
        end
        if NAMED[t] then
            local nm = n:field('name')[1]
            local nmt = nm and text(nm, src)
            if nmt and nmt:match('^[%w_$]+$') then
                -- AMBIENT: `declare var document: Document` declares a GLOBAL
                if ambient and t == 'variable_declarator' then
                    local ty = type_of(n, src)
                    if ty then acc.gvar[nmt] = ty; found = found + 1 end
                elseif ambient and t == 'function_signature' then
                    -- a callable global with no receiver
                    local ps = n:field('parameters')[1]
                    acc.free[nmt] = acc.free[nmt] or {}
                    local ar = ps and ps:named_child_count() or 0
                    acc.free[nmt][#acc.free[nmt] + 1] = ar
                    acc.vocab[nmt] = true
                    found = found + 1
                end
                -- the INTERFACE-keyed entry, so a return type can chain
                if owner and owner ~= nmt then
                    local ok2 = owner .. '.' .. nmt
                    acc.owner_members[owner] = acc.owner_members[owner] or {}
                    acc.owner_members[owner][nmt] = true
                    if not acc.sigs[ok2] then
                        acc.sigs[ok2] = { arities = {}, ret = ret_of(n, src) }
                        acc.nmem = acc.nmem + 1
                        if acc.sigs[ok2].ret then acc.nret = acc.nret + 1 end
                        local pt = type_of(n, src)
                        if pt then acc.prop_type[ok2] = pt end
                    end
                end
                -- the PACKAGE-keyed entry: an import of the package yields this
                if nsname then
                    local key = nsname .. '.' .. nmt
                    if not acc.sigs[key] then
                        acc.sigs[key] = { arities = {}, ret = ret_of(n, src) }
                        acc.vocab[nmt] = true
                        acc.nmem = acc.nmem + 1
                        found = found + 1
                        if acc.sigs[key].ret then acc.nret = acc.nret + 1 end
                        local pt = type_of(n, src)
                        if pt then acc.prop_type[key] = pt end
                    end
                end
            end
        end
        for ch in n:iter_children() do if ch:named() then walk(ch, owner, ambient) end end
    end
    walk(tree:root(), nil, opts.ambient or false)
    if nsname and found > 0 then acc.nsset[nsname] = true end
    return found
end

--- an alias resolves when its definition mentions exactly ONE type this surface
--- knows as an interface: `type SinonStubbedFunction<T> = T extends (...) ?
--- SinonStub<A,R> : SinonStub` names SinonStub on both branches, so the
--- conditional never has to be evaluated. Two candidates or none, and it stays
--- unresolved rather than guessed.
local function resolve_alias(acc, name, depth)
    if not name or (depth or 0) > 3 then return name end
    if acc.owner_members[name] then return name end
    local set = acc.alias[name]
    if not set then return name end
    local one
    for n2 in pairs(set) do
        if acc.owner_members[n2] then
            if one and one ~= n2 then return name end
            one = n2
        end
    end
    if one then return resolve_alias(acc, one, (depth or 0) + 1) end
    return name
end
M.resolve_alias = resolve_alias

--- every member of `owner`, its extends chain included, memoised
local function all_members(acc, owner, seen, out, depth)
    out = out or {}
    seen = seen or {}
    if not owner or seen[owner] or (depth or 0) > 8 then return out end
    seen[owner] = true
    for m in pairs(acc.owner_members[owner] or {}) do out[m] = out[m] or owner end
    for _, b in ipairs(acc.ext[owner] or {}) do
        all_members(acc, resolve_alias(acc, b), seen, out, (depth or 0) + 1)
    end
    return out
end
M.all_members = all_members

--- Resolve everything that needs the WHOLE surface: arity-keyed return types,
--- nested namespace paths, and the ambient globals' member sets. Returns a report
--- table of counts.
function M.finish(acc)
    local rep = { rets = 0, flat = 0, globals = 0, gmembers = 0 }

    -- the return type of a CALLABLE PROPERTY, keyed by arity. A single answer
    -- would be a guess and the wrong one fabricates; the call site states its
    -- argument count, so store the map and let the call decide. `ret` is filled
    -- only when every overload agrees, which is what a caller with no argument
    -- count can honestly use.
    for key, ty in pairs(acc.prop_type) do
        local cs = acc.call_sigs[resolve_alias(acc, ty)]
        if cs and not acc.sigs[key].ret then
            local rets, one, unanimous = {}, nil, true
            for arity, r in pairs(cs) do
                local rr = resolve_alias(acc, r)
                rets[arity] = rr
                if one and one ~= rr then unanimous = false end
                one = one or rr
            end
            if next(rets) then
                acc.sigs[key].rets = rets
                if unanimous then acc.sigs[key].ret = one end
                rep.rets = rep.rets + 1
            end
        end
    end

    -- FLATTEN ONE LEVEL of property-type indirection: sinon declares `assert:
    -- SinonAssert` and `calledOnce` on SinonAssert, two facts with no key joining
    -- them, while the corpus writes `sinon.assert.calledOnce`. Joined here rather
    -- than in mint_path, which would otherwise claim a path the .d.ts never stated.
    local flat = {}
    for key, ty in pairs(acc.prop_type) do
        for member, decl in pairs(all_members(acc, resolve_alias(acc, ty))) do
            local k = key .. '.' .. member
            if not acc.sigs[k] then
                flat[k] = acc.sigs[decl .. '.' .. member]
                acc.vocab[member] = true
                rep.flat = rep.flat + 1
            end
        end
    end
    for k, from in pairs(flat) do
        acc.sigs[k] = { arities = {}, ret = from and from.ret or nil,
            rets = from and from.rets or nil }
    end

    -- the AMBIENT globals: `declare var document: Document` makes `document` a
    -- namespace whose members are Document's, extends chain included.
    for g, ty in pairs(acc.gvar) do
        local members = all_members(acc, resolve_alias(acc, ty))
        if next(members) then
            acc.nsset[g] = true
            acc.vocab[g] = true
            rep.globals = rep.globals + 1
            for m, decl in pairs(members) do
                local k = g .. '.' .. m
                if not acc.sigs[k] then
                    local from = acc.sigs[decl .. '.' .. m]
                    acc.sigs[k] = { arities = {}, ret = from and from.ret or nil,
                        rets = from and from.rets or nil }
                    acc.vocab[m] = true
                    rep.gmembers = rep.gmembers + 1
                end
            end
        end
    end
    return rep
end

return M
