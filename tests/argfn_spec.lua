-- CART-1969: in java a bare identifier ARGUMENT is a variable — a local, parameter, field, record component — and names
-- a function only when its VALUE is one: a lambda bound to the name (a `vfn` def). The callback upgrade linked by NAME to
-- any unique function, so a FIELD passed as an argument reached a same-named declared method or record accessor
-- (elasticsearch libs: 28 of 81 upgrades — swisshash's `new Status(growCount, capacity, …)` -> Status::capacity(),
-- EntitlementRule's accessors). The 53 others pass a lambda constant / local, and must stay.
-- Fixture minimised from those real rows; on the tree before the fix it yields both false refs.

local ts = require 'cartograph.providers.treesitter'

local function edges()
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/a', 'p')
    local function w(rel, t) local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close() end
    w('a/Base.java', table.concat({ 'package a;', 'public abstract class Base {', '  protected int capacity;',
        '  protected String methodKey;', '  protected static int limit;',
        '  static final java.util.function.IntFunction<int[]> MAKE_FUNC = n -> new int[n];',
        '  public static class Status {', '    public int capacity() { return 0; }', '    public int limit() { return 0; }',
        '  }', '}' }, '\n'))
    w('a/Rule.java', 'package a;\npublic record Rule(String methodKey) {}\n')
    w('a/Impl.java', table.concat({ 'package a;', 'public class Impl extends Base {',
        '  static final Object BUILT = Helpers.build(MAKE_FUNC);', -- a LOAD-TIME pass of an inherited lambda constant: reg
        '  static final Object CAP = Helpers.cap(limit);', -- a LOAD-TIME pass of a static FIELD: no reg, no cbarg mark
        '  Object report() {', '    Runnable tick = () -> {};', '    Helpers.run(tick);', -- a local lambda
        '    Helpers.use(MAKE_FUNC);', -- an inherited lambda constant, another file
        '    return Helpers.wrap(capacity, methodKey);', -- inherited FIELDS: never the method / the accessor
        '  }', '}' }, '\n'))
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local byid, out = {}, {}
    for _, n in ipairs(data.nodes) do
        byid[n.id] = n
        -- the cbarg pre-scan's mark ("alive: passed as a callback") on a declared method is the same false link
        if n.cbarg and n.name and (n.name:match('limit$') or n.name:match('capacity$')) then out[#out + 1] = 'cbarg ' .. n.id end
    end
    for _, e in ipairs(data.edges) do
        local t = byid[e.to]
        if (e.kind == 'ref' or e.kind == 'reg') and t and (t.kind == 'method' or t.kind == 'function') then
            out[#out + 1] = e.kind .. ' ' .. tostring(e.from) .. ' -> ' .. e.to
        end
    end
    table.sort(out)
    return out
end

test('java: a field passed as an argument never links to a same-named method or record accessor; a lambda value still does (CART-1969)', function ()
    if not parser_available('java') then skip 'no java parser' end
    eq({
        'ref a/Impl.java::Impl::report@4 -> a/Base.java::Base::MAKE_FUNC@5', -- the inherited lambda constant
        'ref a/Impl.java::Impl::report@4 -> a/Impl.java::Impl::tick@5',      -- the local lambda
        'reg a/Impl.java -> a/Base.java::Base::MAKE_FUNC@5',                  -- passed at load time
    }, edges(), 'no Status::capacity, no Rule::methodKey, no Status::limit — neither as an edge nor as a cbarg mark')
end)

test('go and lua still pass functions by bare NAME: the upgrade reaches declared functions there (CART-1969)', function ()
    local ran = 0
    local function linked(files, name)
        local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
        for rel, t in pairs(files) do local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close() end
        local data = ts.extract(root)
        vim.fn.delete(root, 'rf')
        for _, e in ipairs(data.edges) do if e.kind == 'ref' and e.to:find('::' .. name, 1, true) then return true end end
        return false
    end
    if parser_available('go') then
        ok(linked({ ['h.go'] = 'package m\n\nfunc handler() {}\n\nfunc main() {\n\tregister("/", handler)\n}\n' }, 'handler'),
            'go: register("/", handler) links the declared function')
        ran = ran + 1
    end
    if parser_available('lua') then
        ok(linked({ ['m.lua'] = 'local function cb() end\nlocal M = {}\nfunction M.go() register(cb) end\nreturn M\n' }, 'cb'),
            'lua: register(cb) links the declared function')
        ran = ran + 1
    end
    ok(ran > 0, 'a control language ran')
end)
