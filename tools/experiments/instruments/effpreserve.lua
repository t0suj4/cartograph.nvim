-- a PRESERVATION ORACLE (CART-1557): does an algebra derivation's ALL-DYNAMIC residual keep its source's effects
-- label? The residual is a semantically equivalent variant of the source, so a DETERMINATE disagreement is a bug on
-- one side — effects or mix. Run over the graph of lua/cartograph (the source labels):
--   nvim --headless -u NONE -l tools/toolbelt.lua run @tools/experiments/instruments/effpreserve.lua lua/cartograph
-- -> `ROW\t<op>\t<source label> -> <residual label>` per derivation, then `EP <tally>` and every determinate
-- disagreement. FIRST RUN (2026-10-08): 34 residuals, 0 determinate disagreements; 22 `writes~ -> pure~` — the
-- source's writes were the ambiguous JOIN's false candidates (D.sites "wrote" panes/symbols.lua UI state), which is
-- how CART-1565 was found.
return { measure = function (store)
    local MA, MX, R, E = require 'cartograph.mixalg', require 'cartograph.mix', require 'cartograph.algebraread', require 'cartograph.effects'
    local A = require('cartograph.algebra').load()
    local D = require 'cartograph.algebra.derive'
    D.apply_to(A, 'all') -- (as derive-accept: the derivations bound to the basis)
    local src = {}
    for _, n in ipairs(store.data.nodes) do
        if n.file == 'algebra/derive.lua' and tostring(n.name):match('^D%.') then src[n.name:sub(3)] = E.purity(store, n.id) end
    end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local made, failed = {}, 0
    for _, op in ipairs(D.OPERATORS) do
        local key = 'derive.lua::D.' .. op
        local okp, text, _, lines, knowns, mreport, prims = pcall(MA.program, key, nil, { snapshot = true })
        local okl, prog = false, nil
        if okp then okl, prog = pcall(MX.lower, R.read(text, 'lua'), { lines = lines }) end
        local entry = MA.mangle(key)
        local res
        if okl and prog.funcs[entry] then
            local div = {}
            for i = 1, #prog.funcs[entry].params do div[i] = 'D' end
            local G = { ['M.grammars'] = A.grammars }
            for k, v in pairs(knowns or {}) do G[k] = v end
            local oks
            oks, res = pcall(MX.specialize, prog, entry, div, {}, { budget = 5e6, globals = G, prims = prims, single_prims = mreport and mreport.single_prims })
            if not oks then res = nil end
        end
        if res then
            local f = assert(io.open(dir .. '/' .. op .. '.lua', 'w'))
            f:write((MX.print(res, prog.where)))
            f:close()
            made[op] = res.entry
        else
            failed = failed + 1
        end
    end
    local st = require 'cartograph.store'
    st.ingest(require('cartograph.providers.treesitter').extract(dir))
    local rl = {}
    for _, n in ipairs(st.data.nodes) do
        local op = tostring(n.file):match('^(.-)%.lua$')
        if op and made[op] and n.name == made[op] then rl[op] = E.purity(st, n.id) end
    end
    vim.fn.delete(dir, 'rf')
    local tally, bad, ops = {}, {}, vim.tbl_keys(made)
    table.sort(ops)
    for _, op in ipairs(ops) do
        local a, b = src[op] or '?', rl[op] or '?'
        io.write('ROW\t', op, '\t', a, ' -> ', b, '\n')
        tally[a .. ' -> ' .. b] = (tally[a .. ' -> ' .. b] or 0) + 1
        if not a:find('~') and not b:find('~') and a ~= b then bad[#bad + 1] = op .. ': ' .. a .. ' -> ' .. b end
    end
    io.write(('EP %d residuals, %d not specialized, %d determinate disagreements %s\n'):format(#ops, failed, #bad, vim.inspect(tally):gsub('%s+', ' ')))
    for _, b in ipairs(bad) do io.write('EP DISAGREE ', b, '\n') end
    return {}
end }