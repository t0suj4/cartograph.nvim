-- metaread — FUNCTION SIGNATURES OUT OF LuaLS ANNOTATION BLOCKS: the shared reader under the profile distillers
-- (tools/luadistill.lua: lua-language-server's @meta for `luajit`; tools/nvimdistill.lua: the Neovim runtime's own
-- annotations for `nvim`). Split out of luadistill so the second distiller reads blocks the same way, not by a copy.
--
-- A DECLARED source, and a CLAIM tier: an annotation says what a function takes and returns (CART-0240 — docblocks can
-- lie, which is why every consumer labels a signature `sig_kind = 'annotation'`). Nothing here decides existence.
--
--   local R = require('cartograph.metaread').new()
--   R:each_function(lines, { live = fn(i, line) -> bool, owner_of = fn(owner) -> owner | nil }, function (f) … end)
--     f = { owner, sep ('.' | ':'), member, bare (a free function's name), key ('Owner#member' | bare),
--           sig = { sig, params, returns, arity }, line (0-based, the block's first line) }
--   R.multiline — how many annotated types spanned lines and were recorded UNKNOWN
local M = {}

local annot = require 'cartograph.annot'
-- spec/lua.lua's annot_tag, with the SPACE LuaLS also accepts after `---`: Neovim's generated `_meta` files write
-- `--- @param cmd string`, and the verbatim tag read every one of their 1,000+ signatures as `()`
local TAG = '^%s*%-%-%-%s*@([%a_]+)%s*(.*)$'

function M.new()
    local R = { multiline = 0 }

    -- A TYPE THAT SPANS LINES IS NOT A TYPE THIS READER HAS. `unpack`'s param is declared as a table literal type
    -- opened on the `@param` line and closed several lines later; annot.lua reads ONE line by design, so it hands back
    -- `{`. Emitting that would put a string that is not a type into a signature, so an unbalanced type is recorded as
    -- UNKNOWN with a flag, and counted. Refusing beats truncating: `any` is honest, `{` is a lie with a shape.
    function R.usable_type(t)
        if not t then return nil end
        local depth = 0
        for ch in t:gmatch('[{}%(%)<>%[%]]') do
            if ch == '{' or ch == '(' or ch == '<' or ch == '[' then depth = depth + 1
            else depth = depth - 1 end
        end
        if depth ~= 0 then
            R.multiline = R.multiline + 1
            return nil, true
        end
        return t
    end

    --- the signature TEXT plus the machine-readable halves. `returns` is the point of the whole exercise (a
    --- return-type source); `sig` is what hover shows.
    function R.sig_of(rows, decl_params)
        local ps, rs = {}, {}
        for _, r in ipairs(rows) do
            local ty, over = R.usable_type(r.type)
            if r.kind == 'param' and r.name then
                ps[#ps + 1] = { name = r.name, type = ty, opt = r.opt or nil, multiline = over }
            elseif r.kind == 'vararg' then
                ps[#ps + 1] = { name = '...', type = ty, multiline = over }
            elseif r.kind == 'return' then
                rs[#rs + 1] = { name = r.name, type = ty, opt = r.opt or nil, multiline = over }
            end
        end
        local pt = {}
        for _, p in ipairs(ps) do
            pt[#pt + 1] = ('%s%s: %s'):format(p.name, p.opt and '?' or '',
                p.type or (p.multiline and 'any (multi-line type, unread)') or 'any')
        end
        local rt = {}
        for _, r in ipairs(rs) do
            rt[#rt + 1] = (r.type or 'any') .. (r.opt and '?' or '')
        end
        return {
            sig = ('(%s)%s'):format(table.concat(pt, ', '),
                #rt > 0 and (' -> ' .. table.concat(rt, ', ')) or ''),
            params = ps, returns = rs,
            -- THE DECLARED ARITY, kept beside the annotated one so a consumer can see them disagree rather than
            -- trusting whichever it read first
            arity = decl_params and #decl_params or nil,
        }
    end

    --- every `function Owner.member(…)` / `function Owner:member(…)` / `function name(…)` definition line in `lines`
    --- that `opts.live` admits, with the annotation block directly above it. An owner may be DOTTED (`vim.fn.system`):
    --- the member is the last segment. `opts.owner_of` maps a file-local owner to its public name (a module's `M`)
    --- and may drop it (nil).
    function R:each_function(lines, opts, cb)
        opts = opts or {}
        local blk, blk_first = {}, nil
        for i, l in ipairs(lines) do
            local live = true
            if opts.live then live = opts.live(i, l) end
            if l:match('^%s*%-%-%-') then
                if not blk_first then blk_first = i - 1 end
                blk[#blk + 1] = l
            else
                local owner, sep, member, params = l:match('^function%s+([%w_%.]+)([%.:])([%w_]+)%s*%(([^)]*)%)')
                local bare = (not owner) and l:match('^function%s+([%w_]+)%s*%(')
                if owner and opts.owner_of then owner = opts.owner_of(owner) end
                if (owner or bare) and live then
                    local rows = annot.read_block(blk, blk_first or 0, TAG)
                    local dp = {}
                    for p in (params or ''):gmatch('[%w_%.]+') do dp[#dp + 1] = p end
                    -- the KEY IS `Owner#member`, which is what lsp.lua's hover already looks up
                    -- (`<runtime>::Owner#member` → path); a free function is keyed bare, its own owner
                    cb({ owner = owner, sep = sep, member = member, bare = bare,
                        key = owner and (owner .. '#' .. member) or bare,
                        sig = R.sig_of(rows, dp), line = blk_first or (i - 1) })
                end
                if l:match('%S') then blk, blk_first = {}, nil end
            end
        end
    end

    return R
end

return M
