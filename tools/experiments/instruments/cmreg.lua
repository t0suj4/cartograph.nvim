-- compiled-matcher regression: every luajs rule template compiled speculatively; compile time, residual bytes, match
-- time over a fixed population, and equality with A.match
return { measure = function (_, p)
    local MA = require 'cartograph.mixalg'
    local rules = require 'cartograph.luajs.rules'
    local R = require 'cartograph.algebraread'
    local A = require('cartograph.algebra').load()
    local ASSUME = require('cartograph.compiledverb').ASSUME
    local by = {}
    for _, rel in ipairs({ 'lua/cartograph/mix.lua', 'lua/cartograph/luajs/rules.lua' }) do
        local path = rel
        local term = assert(R.read(io.open(path):read('a'), 'lua'))
        local memo = {}
        local function walk(t)
            local pr = rules.project(t, memo)
            local h = rules.head(pr)
            by[h] = by[h] or {}
            by[h][#by[h] + 1] = pr
            for _, c in ipairs(t.kids or {}) do if c.k ~= 'lit' then walk(c) end end
        end
        walk(term)
    end
    local ctime, bytes, n, refused, differ, subjects = 0, 0, 0, 0, 0, 0
    local mtime = 0
    for _, r in ipairs(rules.all()) do
        local t0 = vim.uv.hrtime()
        local ok, m, text = pcall(MA.compile_match, r.lhs, { assume = ASSUME })
        ctime = ctime + (vim.uv.hrtime() - t0)
        if not ok then refused = refused + 1
        else
            n = n + 1; bytes = bytes + #text
            local pop = by[r.key] or {}
            for _, s in ipairs(pop) do
                subjects = subjects + 1
                local okm, got = pcall(m, s)
                if okm and not vim.deep_equal(got, A.match(r.lhs, s)) then differ = differ + 1 end
            end
            local t1 = vim.uv.hrtime()
            for _ = 1, 5 do for _, s in ipairs(pop) do pcall(m, s) end end
            mtime = mtime + (vim.uv.hrtime() - t1)
        end
    end
    io.write(('CMREG %d compiled, %d refused; compile %.2f s; residual %d KB; %d subjects, %d differ; match 5x pop %.2f s\n')
        :format(n, refused, ctime / 1e9, math.floor(bytes / 1024), subjects, differ, mtime / 1e9))
    return {}
end }
