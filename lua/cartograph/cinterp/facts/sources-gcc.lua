-- SOURCES: each unit PREPROCESSED with its own compile flags (gcc -E -P, attributes erased; its directory on the
-- include path, as its build sees it); an AMALGAMATION (a unit including .c units) is skipped by name. A unit is
-- named by its path under the tree. In parallel, 16 at a time.
return {
    fact = 'sources',
    needs = { 'compdb' },
    summary = 'every unit preprocessed with its own flags',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local db = got.compdb
        local jobs, out, skipped = {}, {}, {}
        for _, u in ipairs(db.units) do
            local raw = F.readfile(u.file) or ''
            local name = u.file:sub(1, #db.dir + 1) == db.dir .. '/' and u.file:sub(#db.dir + 2) or u.file
            if raw:find('#include%s+"[%w_]+%.c"') then skipped[#skipped + 1] = name .. ' (an amalgamation: it includes .c units)'
            else
                local cmd = { 'gcc', '-E', '-P', '-D__attribute__(x)=' }
                vim.list_extend(cmd, u.flags)
                vim.list_extend(cmd, { '-I' .. vim.fn.fnamemodify(u.file, ':h'), u.file })
                jobs[#jobs + 1] = { name = name, cmd = cmd, cwd = u.cwd }
            end
        end
        local running, i = {}, 1
        local function start(j) j.h = vim.system(j.cmd, { text = true, cwd = j.cwd, env = db.env }) end
        while i <= #jobs or #running > 0 do
            while i <= #jobs and #running < 16 do start(jobs[i]); running[#running + 1] = jobs[i]; i = i + 1 end
            local j = table.remove(running, 1)
            local r = j.h:wait()
            if r.code == 0 then j.text = r.stdout else skipped[#skipped + 1] = j.name .. ' (does not preprocess)' end
        end
        for _, j in ipairs(jobs) do if j.text then out[#out + 1] = { name = j.name, text = j.text } end end
        if #out == 0 then return nil, 'no unit preprocesses: ' .. table.concat(skipped, '; '):sub(1, 300) end
        return { units = out, skipped = skipped }
    end,
}
