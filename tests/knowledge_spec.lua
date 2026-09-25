-- CART-1053: the MEASURED knowledge about YAML/XML implementations, serialized WITH PROVENANCE
-- (lua/cartograph/spec/knowledge/ambiguity.jsonl, written by tools/ambiguity.lua --write).
-- ★ Every stored WITNESS (one implementation, one version, one input, one site, one outcome) is
-- re-checked against what the CODE's profile predicts today — offline, with none of the
-- implementations installed. A change to yamlvalue/xmlvalue that contradicts a measured fact fails
-- here, and the failure names the implementation, the version, the input and the site.

local Y = require 'cartograph.yamlvalue'
local X = require 'cartograph.xmlvalue'

local function ready()
    if not parser_available('yaml') then skip('no yaml tree-sitter parser') end
end

local function rows()
    local path = vim.api.nvim_get_runtime_file('lua/cartograph/spec/knowledge/ambiguity.jsonl', false)[1]
        or (vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h') .. '/lua/cartograph/spec/knowledge/ambiguity.jsonl')
    local out = {}
    for line in io.lines(path) do out[#out + 1] = vim.json.decode(line) end
    return out
end

local function flatten(v, path, out)
    out = out or {}
    if type(v) ~= 'table' then out[path] = v; return out end
    if v.a then for i, x in ipairs(v.a) do flatten(x, path .. '[' .. i .. ']', out) end return out end
    for i, k in ipairs(v.keys) do flatten(v.o[k], path .. '.' .. k, out); out[path .. '#' .. i] = k end
    return out
end

test('knowledge: ★ PROVENANCE is complete — every witness names a measured implementation and an input whose hash matches', function ()
    local R = rows()
    local impls, inputs, witnesses = {}, {}, {}
    for _, r in ipairs(R) do
        if r.kind == 'implementation' then impls[r.id] = r
        elseif r.kind == 'input' then inputs[r.id] = r
        elseif r.kind == 'witness' then witnesses[r.id] = r end
    end
    local n = 0
    for _, inp in pairs(inputs) do eq(inp.sha256, vim.fn.sha256(inp.text), 'input ' .. inp.id .. ' hash') end
    for _, w in pairs(witnesses) do
        n = n + 1
        ok(impls[w.impl] and impls[w.impl].version and impls[w.impl].version ~= '', 'witness ' .. w.id .. ' names a versioned implementation')
        ok(inputs[w.input], 'witness ' .. w.id .. ' names a stored input')
        ok(w.observed_at and w.observed_at:match('^%d%d%d%d%-'), 'witness ' .. w.id .. ' is dated')
    end
    ok(n > 400, ('%d witnesses'):format(n))
    for _, r in ipairs(R) do
        if r.kind == 'promise' then
            ok(#r.warrants > 0, r.subject .. ' has a warrant')
            for _, wr in ipairs(r.warrants) do
                if wr.type == 'witnesses' then
                    for _, id in ipairs(wr.ids) do ok(witnesses[id], r.subject .. ' cites ' .. id) end
                end
            end
        end
    end
end)

test('knowledge: ★★★ every YAML WITNESS is still predicted by the code\'s profile (none refuted)', function ()
    ready()
    local R = rows()
    local inputs, impl_version, pred = {}, {}, {}
    for _, r in ipairs(R) do
        if r.kind == 'input' then inputs[r.id] = r.text end
        if r.kind == 'implementation' then impl_version[r.id] = r.version end
    end
    local checked, refuted = 0, {}
    for _, w in ipairs(R) do
        if w.kind == 'witness' and inputs[w.input] and w.input:match('^yaml/') then
            local key = w.impl .. '\0' .. w.input
            if not pred[key] then
                local t = Y.typed_stream(assert(Y.read(inputs[w.input])), Y.IMPLEMENTATIONS[w.impl])
                pred[key] = t == nil and { ['$'] = 'rejected' } or flatten(t, '$')
            end
            checked = checked + 1
            if pred[key][w.site] ~= w.outcome then
                refuted[#refuted + 1] = ('%s (%s) %s %s: witnessed %s, predicted %s'):format(w.impl, impl_version[w.impl],
                    w.input, w.site, tostring(w.outcome), tostring(pred[key][w.site]))
            end
        end
    end
    ok(checked > 300, ('%d YAML witnesses checked'):format(checked))
    eq(0, #refuted, table.concat(refuted, '\n'))
end)

test('knowledge: every XML WITNESS is still predicted by the code\'s profile', function ()
    local checked, refuted = 0, {}
    for _, w in ipairs(rows()) do
        if w.kind == 'witness' and w.input:match('^xml/') then
            checked = checked + 1
            local want = X.IMPLEMENTATIONS[w.impl] and X.IMPLEMENTATIONS[w.impl][w.site]
            if want ~= w.outcome then refuted[#refuted + 1] = ('%s %s: witnessed %s, predicted %s'):format(w.impl, w.input, w.outcome, tostring(want)) end
        end
    end
    eq(15, checked)
    eq(0, #refuted, table.concat(refuted, '\n'))
end)
