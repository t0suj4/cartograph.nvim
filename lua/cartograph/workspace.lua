local atr = require 'cartograph.at'
-- The workspace — the Smalltalk "doit" for cartograph: evaluate ad-hoc Lua
-- against the LOADED graph. Every detector in this repo (spines, territory,
-- greenspun) started as a throwaway probe against `store`; this makes that
-- iteration first-class and in-cockpit instead of headless-nvim scripts.
--
-- In the band → perspective → surface model ([[cartograph-terminology]]):
-- a doit is a CODE-authored perspective. A doit that returns a node / a list
-- or set of node-ids renders as a browsable list you can pivot into — so code
-- becomes a first-class perspective source, beside navigation.

local M = {}

--- The evaluation environment: the graph handle + the pure modules in scope,
--- with _G behind them (vim, string, table, … all work).
function M.env()
    local store = require 'cartograph.store'
    local function opt(m) local ok, r = pcall(require, m); return ok and r or nil end
    return setmetatable({
        store = store,
        spines = opt('cartograph.spines'),
        territory = opt('cartograph.territory'),
        cone = opt('cartograph.cone'),
        lint = opt('cartograph.lint'),
        heat = opt('cartograph.heat'),
        ladder = opt('cartograph.ladder'),
        refs = opt('cartograph.refs'),
        ts = opt('cartograph.providers.treesitter'),
        data = store.data,
        node = function(id) return store.node(id) end,
        uses = store.uses,
        usedby = store.usedby,
    }, { __index = _G })
end

--- Evaluate `src` (an expression OR a chunk that `return`s). Returns
--- (result, nil) or (nil, error-string).
function M.eval(src)
    local f, err = load('return ' .. src, '=workspace') -- try as an expression
    if not f then f, err = load(src, '=workspace') end   -- else a full chunk
    if not f then return nil, 'compile: ' .. tostring(err) end
    if setfenv then setfenv(f, M.env()) end
    local ok, res = pcall(f)
    if not ok then return nil, 'error: ' .. tostring(res) end
    return res, nil
end

--- If `res` is a node, a sequence of nodes/ids, or a set { id = true }, return
--- the resolved node list; else nil. Sets (cone/territory results) and arrays
--- both count — that's the common shape of a graph query.
function M.as_nodes(res)
    if type(res) ~= 'table' then return nil end
    local store = require 'cartograph.store'
    if res.id and res.kind and res.name then return { res } end -- a single node
    local out = {}
    for i, v in ipairs(res) do -- array of ids or node tables
        if type(v) == 'string' then
            local n = store.node(v); if not n then return nil end; out[#out + 1] = n
        elseif type(v) == 'table' and v.id and v.kind and v.name then
            out[#out + 1] = v
        else
            return nil
        end
        if i ~= #out then return nil end
    end
    if #out > 0 then return out end
    for k, v in pairs(res) do -- set { id = true }
        if type(k) == 'string' and v and store.node(k) then out[#out + 1] = store.node(k)
        else return nil end
    end
    return #out > 0 and out or nil
end

-- the shared read-only bottom-split scratch (cartograph.ui.scratch); the close
-- key now rides config.keys.close (was a hardcoded 'q') so a user remap holds
local function scratch(lines, ft)
    return require('cartograph.ui').scratch(lines, ft)
end

--- Render a node-list result as a jumpable list: <CR> pivots the browser to
--- the node, gf opens its file. This is the code-authored perspective.
function M.render_nodes(nodes)
    local store = require 'cartograph.store'
    local lines = { ('%d node%s  ·  <CR> pivot · gf open · q close')
        :format(#nodes, #nodes == 1 and '' or 's') }
    local ids = {}
    for _, n in ipairs(nodes) do
        local loc = n.file and (n.file .. (n.range and (':' .. (atr.sl(n.range) + 1)) or '')) or ''
        lines[#lines + 1] = ('%-8s %-32s %s'):format(n.kind or '?', (n.name or n.id):sub(1, 32), loc)
        ids[#lines] = n.id
    end
    local buf = scratch(lines, nil)
    vim.keymap.set('n', '<CR>', function ()
        local id = ids[vim.api.nvim_win_get_cursor(0)[1]]
        if id and store.node(id) then vim.cmd('close'); store.pivot(id) end
    end, { buffer = buf, desc = 'cartograph: pivot to this node' })
    vim.keymap.set('n', 'gf', function ()
        local n = ids[vim.api.nvim_win_get_cursor(0)[1]]
        n = n and store.node(n)
        if n and n.file then
            local path = (store.abs and store.abs(n.file)) or n.file
            vim.cmd('tab drop ' .. vim.fn.fnameescape(path))
            if n.range then pcall(vim.api.nvim_win_set_cursor, 0, { atr.sl(n.range) + 1, 0 }) end
        end
    end, { buffer = buf, desc = 'cartograph: open this node\'s file' })
    return buf
end

--- Render a result by type: node-list → browsable list; scalar → notify;
--- other table → vim.inspect scratch.
function M.render(res, err)
    if err then return vim.notify('cartograph: ' .. err, vim.log.levels.WARN) end
    if res == nil then return vim.notify('cartograph: (no value)', vim.log.levels.INFO) end
    local t = type(res)
    if t == 'string' or t == 'number' or t == 'boolean' then
        return vim.notify('cartograph: ' .. tostring(res), vim.log.levels.INFO)
    end
    local nodes = M.as_nodes(res)
    if nodes then return M.render_nodes(nodes) end
    scratch(vim.split(vim.inspect(res), '\n', { plain = true }), 'lua')
end

--- Evaluate `src` and render the result (the doit).
function M.run(src)
    if not src or src:match('^%s*$') then return end
    M.render(M.eval(src))
end

--- Run the current visual selection (called from the workspace's x-mode <CR>,
--- entered via `:` so the '< '> marks are set to the selection).
function M.run_marks()
    M.run(table.concat(vim.fn.getline(vim.fn.line("'<"), vim.fn.line("'>")), '\n'))
end

local SEED = {
    '-- cartograph workspace — ad-hoc Lua against the loaded graph.',
    '-- in scope: store, spines, territory, cone, lint, heat, ladder, refs, ts,',
    '--           node(id), uses, usedby   (+ all of _G: vim, string, …)',
    '-- normal <CR> runs the whole buffer; visual <CR> runs the selection.',
    '-- a returned node / list / set of ids renders as a browsable list.',
    '',
    '-- return cone.reachable(store.focused, usedby)   -- who reaches the focused fn',
    '',
}

--- Open (or reuse) the persistent workspace buffer, with the doit keymaps.
function M.open()
    local buf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b)
            and vim.api.nvim_buf_get_name(b):match('cartograph://workspace$') then
            buf = b; break
        end
    end
    if not buf then
        buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, 'cartograph://workspace')
        vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'hide', false
        vim.bo[buf].filetype = 'lua'
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, SEED)
    end
    vim.cmd('botright split')
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_height(0, 12)
    vim.keymap.set('n', '<CR>', function ()
        M.run(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
    end, { buffer = buf, desc = 'cartograph: run the workspace (doit)' })
    vim.keymap.set('x', '<CR>', ":<C-u>lua require('cartograph.workspace').run_marks()<cr>",
        { buffer = buf, silent = true, desc = 'cartograph: run the selection (doit)' })
    return buf
end

return M
