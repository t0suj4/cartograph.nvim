-- CART-1075: a parser guard must read language.add's RESULT. In nvim 0.11 a missing parser makes
-- vim.treesitter.language.add return nil WITHOUT raising, so `if not pcall(vim.treesitter.language.add, 'x')` never
-- skips: 37 test guards and one production refusal (erlreg) were that form.

test('parserguard: the raw pcall guard is vacuous, parser_available is not', function ()
    local okp, loaded = pcall(vim.treesitter.language.add, 'cg_no_such_language')
    ok(okp and loaded == nil, 'the premise: a missing parser returns nil and does not raise (if this fails, nvim changed)')
    eq(true, parser_available('lua'), 'a bundled parser')
    eq(false, parser_available('cg_no_such_language'), 'a missing one')
end)

test('parserguard: FENCE — no pcall(language.add, <non-bundled>) is used as a boolean anywhere', function ()
    local bundled = require('cartograph.spec.lua').bundled_parsers
    local files = vim.fn.glob('tests/*.lua', false, true)
    vim.list_extend(files, vim.fn.glob('lua/**/*.lua', false, true))
    local bad = {}
    for _, f in ipairs(files) do
        for i, l in ipairs(vim.fn.readfile(f)) do
            for q, lang in l:gmatch("pcall%(vim%.treesitter%.language%.add,%s*(['\"])([%w_]+)%1%)") do
                local captured = l:match('local%s+[%w_]+%s*,%s*[%w_]+%s*=%s*pcall%(vim%.treesitter%.language%.add')
                if not bundled[lang] and not captured and not f:find('parserguard_spec', 1, true) then
                    bad[#bad + 1] = ('%s:%d  %s'):format(f, i, vim.trim(l))
                end
                local _ = q
            end
        end
    end
    eq({}, bad, 'read the result: parser_available(lang) in tests, `local ok, loaded = pcall(...)` elsewhere')
end)

test('parserguard: erlreg REFUSES by name when the erlang parser is missing (it could not before)', function ()
    local real = vim.treesitter.language.add
    vim.treesitter.language.add = function(lang, ...)
        if lang == 'erlang' then return nil, 'no parser for erlang (simulated)' end
        return real(lang, ...)
    end
    local okc, stats = pcall(require('cartograph.erlreg').attach, { root = vim.fn.tempname(), nodes = {}, calls = {} })
    vim.treesitter.language.add = real
    ok(okc, tostring(stats))
    eq({ 'no erlang parser' }, stats.refused)
end)
