-- ScopeModel core (cartograph.scope): chain semantics over a real java parse.
-- The spec table is defined HERE — the model is language-blind; harvesters and
-- policy are the caller's. What's pinned: nearest-first order, the shadow
-- chain, position-checked visibility, the `only` kind filter, and the
-- reused-chain contract (count governs, consume before the next resolve).

local scope = require 'cartograph.scope'

local SRC = [[
public class C {
    VisitService visits;
    public void m(String s) {
        use(early);
        int early = 1;
        int x = 1;
        use(x);
        Object visits = null;
        use(visits);
    }
}
]]

local function text(n)
    return SRC:sub(select(3, n:start()) + 1, select(3, n:end_()))
end

-- mini harvesters (type = raw type-node text; nil handling is policy, not ours)
local function locals(node, _, out)
    for c in node:iter_children() do
        if c:type() == 'local_variable_declaration' then
            local ty, row = c:field('type')[1], select(1, c:range())
            for d in c:iter_children() do
                if d:type() == 'variable_declarator' then
                    local nm = d:field('name')[1]
                    if nm then out[text(nm)] = { ty = ty and text(ty), row = row } end
                end
            end
        end
    end
end
local function params(node, _, out)
    local ps = node:field('parameters')[1]
    if not ps then return end
    for c in ps:iter_children() do
        if c:type() == 'formal_parameter' then
            local nm = c:field('name')[1]
            if nm then out[text(nm)] = { ty = text(c:field('type')[1]) } end
        end
    end
end
local function fields(node, _, out)
    for c in node:iter_children() do
        if c:type() == 'field_declaration' then
            for d in c:iter_children() do
                if d:type() == 'variable_declarator' then
                    local nm = d:field('name')[1]
                    if nm then out[text(nm)] = { ty = text(c:field('type')[1]) } end
                end
            end
        end
    end
end
local SPEC = {
    block = { kind = 'local', harvest = locals },
    method_declaration = { kind = 'param', harvest = params },
    class_body = { kind = 'field', harvest = fields },
}

-- all identifier nodes spelled `name`, in document order
local function idents(root, name, acc)
    acc = acc or {}
    for c in root:iter_children() do
        if c:type() == 'identifier' and text(c) == name then acc[#acc + 1] = c end
        idents(c, name, acc)
    end
    return acc
end

local function setup()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    local okp, parser = pcall(vim.treesitter.get_string_parser, SRC, 'java')
    if not okp then return nil end
    local root = parser:parse()[1]:root()
    return scope.model(SRC, SPEC), root
end

test('scope: nearest binder first, shadowed field after', function ()
    local sm, root = setup()
    if not sm then skip 'no java parser' end
    local use = idents(root, 'visits')[3] -- field decl, local decl, USE
    local chain, k = sm.resolve('visits', use)
    eq(2, k)
    eq('local', chain[1].kind)
    eq('Object', chain[1].ty)
    eq('field', chain[2].kind)
    eq('VisitService', chain[2].ty)
end)

test('scope: position check — a later local is not visible', function ()
    local sm, root = setup()
    if not sm then skip 'no java parser' end
    local use = idents(root, 'early')[1] -- use BEFORE the declaration
    local _, k = sm.resolve('early', use)
    eq(0, k)
    local after = idents(root, 'x')[2] -- x's use, after early's declaration
    local chain, k2 = sm.resolve('early', after)
    eq(1, k2)
    eq('int', chain[1].ty)
end)

test('scope: only-kind filter (the this.field case)', function ()
    local sm, root = setup()
    if not sm then skip 'no java parser' end
    local use = idents(root, 'visits')[3]
    local chain, k = sm.resolve('visits', use, 'field')
    eq(1, k)
    eq('field', chain[1].kind)
    eq('VisitService', chain[1].ty)
end)

test('scope: params are visible method-wide; chain is reused, count governs', function ()
    local sm, root = setup()
    if not sm then skip 'no java parser' end
    local at = idents(root, 'x')[2]
    local chain, k = sm.resolve('s', at)
    eq(1, k)
    eq('param', chain[1].kind)
    eq('String', chain[1].ty)
    -- the reuse contract: after a wider resolve, a narrower one still returns
    -- the right count and prefix (stale tail entries are none of our business)
    sm.resolve('visits', idents(root, 'visits')[3]) -- k=2 fills chain[1..2]
    local c2, k2 = sm.resolve('x', at)
    eq(1, k2)
    eq('int', c2[1].ty)
end)
