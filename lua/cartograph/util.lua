-- Small pure helpers shared by otherwise-unrelated modules — kept here once
-- rather than duplicated. `defaults` shallow-merges caller opts over a base
-- table (the brush / textplates projections); `file_reader` builds a memoized,
-- root-relative line reader (the django / symfony adapters read source files to
-- recover routes). Both were byte-identical local copies before this.

local M = {}

--- A fresh table = `base` overlaid by `opts` (opts win). `opts` nil = empty.
--- Shallow — nested values are shared, not copied; `base` is never mutated.
function M.defaults(base, opts)
    local o = {}
    for k, v in pairs(base) do o[k] = v end
    for k, v in pairs(opts or {}) do o[k] = v end
    return o
end

--- A memoized, root-relative line reader: reader(rel) → the file's lines (a
--- { plain } split) or false when it can't be opened. Each file is read at most
--- once; the false is cached too, so a missing file isn't retried.
function M.file_reader(root)
    local cache = {}
    return function (rel)
        if cache[rel] == nil then
            local fd = io.open(root .. '/' .. rel, 'r')
            cache[rel] = fd
                and vim.split(fd:read('a'), '\n', { plain = true }) or false
            if fd then fd:close() end
        end
        return cache[rel]
    end
end

return M
