-- :Cartograph command group — opening, sessions and the LSP read surface (|cartograph-cmd-open|)
--
-- Registered by cartograph.commands, which owns the shared helpers and passes
-- them in: this module rebinds them as locals under the SAME names, so every
-- callback body reads exactly as it did when they all lived in one function.

local M = {}

function M.register(H)
    local cmd, live, whole_graph, mat_df, scratch, txn_module, reveal_at =
        H.cmd, H.live, H.whole_graph, H.mat_df, H.scratch, H.txn_module,
        H.reveal_at
    -- not every group uses every helper; keep the binding uniform
    local _ = cmd and live and whole_graph and mat_df and scratch


    -- ── live refresh ────────────────────────────────────────────────
    cmd('CartographRefresh', function (o)
        local store = live() if not store then return end
        local r = require 'cartograph.refresh'
        local stats, why
        if o.bang then
            stats, why = r.all()
        else
            local abs = vim.api.nvim_buf_get_name(0)
            local root = store.data.root
            if abs:sub(1, #root + 1) == root .. '/' then
                stats, why = r.file(abs:sub(#root + 2))
            else
                stats, why = r.all()
            end
        end
        vim.notify(stats and ('cartograph: refreshed (' .. vim.inspect(stats):gsub('%s+', ' ') .. ')')
            or ('cartograph: ' .. tostring(why)),
            stats and vim.log.levels.INFO or vim.log.levels.WARN)
    end, { bang = true,
        desc = 'cartograph: refresh the graph (current file; ! = whole project)' })

    -- ── LSP read surface (T1 in-process) ────────────────────────────
    -- attach a REAL LSP client to the current buffer, served from the open
    -- graph — gd / gr / K / documentSymbol / workspaceSymbol answer from the
    -- common core (cross-language, honesty-on-hover). Read-only.
    -- INDEX-ONLY open ([[cartograph-thin-index]]): the thin symbol index for cheap
    -- LSP/nav (workspace/symbol, documentSymbol, definition-on-a-def, hover). Calls-
    -- dependent features are honestly empty until a full :Cartograph open.
    cmd('CartographIndexOnly', function (o)
        local root = (o.args ~= '' and o.args) or vim.fn.getcwd()
        local ok, err = pcall(require('cartograph').open_index_only, root)
        if not ok then
            vim.notify('cartograph: ' .. tostring(err), vim.log.levels.ERROR)
            return
        end
        local store = require 'cartograph.store'
        vim.notify(('cartograph: index-only — %d symbols indexed (:CartographLspAttach for nav)')
            :format(#(store.data.nodes or {})), vim.log.levels.INFO)
    end, { nargs = '?', complete = 'dir',
        desc = 'cartograph: open a directory in index-only mode (thin symbol index for LSP/nav)' })

    cmd('CartographLspAttach', function ()
        local store = live() if not store then return end
        local id, why = require('cartograph.lsp').attach()
        vim.notify(id and 'cartograph: LSP attached (client ' .. id .. ')'
            or ('cartograph: LSP attach failed — ' .. tostring(why)),
            id and vim.log.levels.INFO or vim.log.levels.WARN)
    end, { desc = 'cartograph: attach the in-process LSP read surface to this buffer' })

    cmd('CartographLspDetach', function ()
        for _, c in ipairs(vim.lsp.get_clients({ name = 'cartograph' })) do
            vim.lsp.stop_client(c.id)
        end
        vim.notify('cartograph: LSP detached', vim.log.levels.INFO)
    end, { desc = 'cartograph: stop the in-process LSP read surface' })

    -- ── multi-band session ──────────────────────────────────────────
    -- :Cartograph <root> ADDS a band (never clobbers); these list + switch.
    cmd('CartographBands', function ()
        local rows = require('cartograph.session').list()
        if #rows == 0 then
            return vim.notify('cartograph: no bands open', vim.log.levels.INFO)
        end
        local lines = { 'cartograph bands (● = active):' }
        for _, b in ipairs(rows) do
            lines[#lines + 1] = ('  %s %-16s %-8s %s'):format(
                b.active and '●' or ' ', b.name, b.kind, b.root)
        end
        scratch(lines)
    end, { desc = 'cartograph: list the open bands (multi-band session)' })

    cmd('CartographSwitch', function (o)
        local session = require 'cartograph.session'
        require('cartograph.store').record_crossing() -- so <C-o> returns here
        local ok, why = session.switch(o.args)
        if not ok then
            return vim.notify('cartograph: ' .. tostring(why), vim.log.levels.WARN)
        end
        -- repaint the cockpit for the now-active band (the lens was swapped);
        -- the browser re-scopes off the restored focus, source/plan off redraw
        local store = require 'cartograph.store'
        pcall(require('cartograph.panes.symbols').render)
        if store.focused and store.node(store.focused) then store.set_focus(store.focused) end
        store.redraw()
        vim.notify('cartograph: switched to ' .. o.args, vim.log.levels.INFO)
    end, { nargs = 1, desc = 'cartograph: switch the active band',
        complete = function ()
            local names = {}
            for _, b in ipairs(require('cartograph.session').list()) do names[#names + 1] = b.name end
            return names
        end })

    -- ── the self oracle: declared vs actually-registered ────────────
    cmd('CartographSelf', function ()
        local store = live() if not store then return end
        if store.data.provider ~= 'self' then
            return vim.notify('cartograph: :CartographSelf needs a self:// graph'
                .. ' — open :Cartograph self://loaded', vim.log.levels.WARN)
        end
        scratch(require('cartograph.self_oracle').registrations(store.data))
    end, { desc = 'cartograph: declared vs live registrations (self:// oracle)' })
end

return M
