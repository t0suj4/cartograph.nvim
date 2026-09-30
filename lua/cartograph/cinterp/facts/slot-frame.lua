-- SLOT: the type a frame slot has — what the thread struct's TOP field points to (`TValue *top`)
-- @langs c
return {
    fact = 'slot',
    needs = { 'frame', 'units', 'sources' },
    summary = 'the slot type: what the thread\'s top field points to',
    derive = function (_, got)
        local fr, td = got.frame, got.units.typedefs
        if not fr.top then return nil, 'the frame has no top field' end
        local tags = { [fr.thread] = true }
        local t = td[fr.thread]
        if t then local s = t:match('struct%s+([%w_]+)'); if s then tags[s] = true end end
        local q = vim.treesitter.query.parse('c', '(struct_specifier name: (type_identifier) @n body: (field_declaration_list) @b)')
        for _, s in ipairs(got.sources.units) do
            if s.text:find(fr.top, 1, true) then
                local root = vim.treesitter.get_string_parser(s.text, 'c'):parse()[1]:root()
                local nm
                for id, node in q:iter_captures(root, s.text, 0, -1) do
                    if q.captures[id] == 'n' then nm = vim.treesitter.get_node_text(node, s.text)
                    elseif tags[nm] then
                        for fd in node:iter_children() do
                            if fd:type() == 'field_declaration' then
                                for _, d in ipairs(fd:field('declarator')) do
                                    local ptr = d:type() == 'pointer_declarator'
                                    while d and d:type() == 'pointer_declarator' do d = d:field('declarator')[1] end
                                    if ptr and d and vim.treesitter.get_node_text(d, s.text) == fr.top then
                                        return { type = vim.treesitter.get_node_text(fd:field('type')[1], s.text), struct = nm }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        return nil, ('no struct %s with a pointer field %s'):format(fr.thread, fr.top)
    end,
}
