-- patrewrite fixture (CART-1057): catalog sites, declined sites, and a non-site.
local M = {}

-- sites
function M.trim(name) return name:match('^%s*(.-)%s*$') end
function M.trim_fn(s) return string.match(s, '^%s*(.-)%s*$') end
function M.rtrim(line) return line:match('^(.-)%s*$') end
function M.trim_gsub(needle) return (needle:gsub('^%s*(.-)%s*$', '%1')) end
function M.trim_field(t) return t.name:match('^%s*(.-)%s*$') end

-- declined: gsub in a multi-value position, a subject with a call, a suppressed site
function M.gsub_multi(s) return s:gsub('^%s*(.-)%s*$', '%1') end
function M.call_subject(s) return s:sub(2):match('^%s*(.-)%s*$') end
function M.kept(s)
    -- @cg-ignore: pattern-rewrite
    return s:match('^%s*(.-)%s*$')
end

-- not a catalog pattern
function M.word(s) return s:match('%w+') end

return M
