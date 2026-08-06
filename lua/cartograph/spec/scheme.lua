-- The SCHEME language spec (L0 grammar binding + L1 name model)
-- extracted from the engine ([[cartograph-spec-layering]] P1). Pure motion.

-- @langs scheme — a spec IS one grammar's mapping, so every node type here is
-- scheme's by construction.

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text

-- Forms whose keyword arguments are DECLARATIONS (import/export specs), not
-- expressions — so a list after a #:keyword inside them is data, never a call.
local DECL_FORM = { ['define-module'] = true, ['define-library'] = true,
    library = true }

return {
        exts = { 'scm' },
        functions = [=[
            ((list . (symbol) @_kw . (list . (symbol) @name)) @def
                (#eq? @_kw "define"))
            ((list . (symbol) @_kw . (symbol) @name . (list . (symbol) @_l)) @def
                (#eq? @_kw "define") (#eq? @_l "lambda"))
            ((list . (symbol) @_kw . (list . (symbol) @name)) @def
                (#eq? @_kw "define-public"))
            ((list . (symbol) @_kw . (symbol) @name . (list . (symbol) @_l)) @def
                (#eq? @_kw "define-public") (#eq? @_l "lambda"))
        ]=],
        -- every list head is application — special forms opt out below
        calls = [=[ (list . (symbol) @name) @call ]=],
        vars = [=[
            ((list . (symbol) @_kw . (symbol) @vname . (number) @value) @vdef
                (#eq? @_kw "define"))
            ((list . (symbol) @_kw . (symbol) @vname . (string) @value) @vdef
                (#eq? @_kw "define"))
        ]=],
        body_field = nil,
        mention_types = { symbol = true },
        toplevel_parent = 'program', -- internal defines are a function's interior
        is_method = function () return false end,
        entry_names = { main = true },
        -- the R5RS core + named-let idiom names: guile DEFINES apply/map in
        -- scheme (self-hosted), but a call to `apply` means the primitive
        stdlib_names = { apply = true, map = true, error = true, list = true,
            cons = true, car = true, cdr = true, append = true, filter = true,
            assoc = true, assq = true, assv = true, member = true, memq = true,
            length = true, reverse = true, vector = true, string = true,
            format = true, display = true, write = true, equal = true,
            loop = true, lp = true, iter = true, recur = true, rec = true,
            fold = true, reduce = true, cont = true, ['for-each'] = true },
        call_skip = { define = true, ['define*'] = true, ['define-public'] = true,
            ['define-syntax'] = true, ['define-module'] = true,
            ['define-record-type'] = true, lambda = true, ['lambda*'] = true,
            let = true, ['let*'] = true, letrec = true, ['letrec*'] = true,
            ['if'] = true, cond = true, case = true, when = true, unless = true,
            begin = true, ['and'] = true, ['or'] = true, ['else'] = true,
            ['set!'] = true, quote = true, quasiquote = true, unquote = true,
            ['do'] = true, delay = true, parameterize = true,
            ['with-syntax'] = true, ['syntax-rules'] = true, ['syntax-case'] = true,
            ['use-modules'] = true, export = true, import = true },
        -- the signature/param list of a define/lambda is NOT an application:
        -- `(define (f x) …)` / `(lambda (x) …)` — the `(f x)` / `(x)` is the
        -- form's SECOND element, and treating it as a call made every fn its
        -- own (bogus) caller. Real calls are the body forms (3rd+ elements).
        skip_call = function (calln, src)
            local p = calln:parent()
            if not (p and p:type() == 'list') then return false end
            -- Inside a DECLARATION form, a list following a #:keyword is that
            -- keyword's DATA: `#:export (step limit)` names two exports, and only
            -- looks like a call because scheme writes code and data alike. Latent
            -- until v107 gave module-level calls an owner — before that the bogus
            -- call resolved and was dropped for having no enclosing fn, and the
            -- graph gate caught it as `step` acquiring a second caller.
            --
            -- SCOPED TO DECLARATION FORMS, and measured why: keyword arguments
            -- elsewhere are ordinary expressions, so a blanket rule LOSES real
            -- calls. `#:on-error (repl-option-ref repl 'on-error)`
            -- (guile system/repl/repl.scm:204) is a keyword whose value IS a call —
            -- the scheme gate reported it as the one edge removed.
            local phead = p:named_child(0)
            if phead and phead:type() == 'symbol' and DECL_FORM[node_text(phead, src)] then
                for i = 0, p:named_child_count() - 1 do
                    if p:named_child(i) == calln then
                        local prev = i > 0 and p:named_child(i - 1)
                        if prev and prev:type() == 'keyword' then return true end
                        break
                    end
                end
            end
            local head = p:named_child(0)
            if not (head and head:type() == 'symbol') then return false end
            local kw = node_text(head, src)
            local sig = kw == 'lambda' or kw == 'lambda*' or kw:match('^define')
            return sig and calln == p:named_child(1) or false
        end,
        -- a call runs at load unless its OUTERMOST form is a define
        is_top = function (calln, src)
            local n, outer = calln, calln
            while n:parent() do
                if n:parent():type() == 'program' then outer = n break end
                n = n:parent()
            end
            if outer == calln then return true end
            local head = outer:named_child(0)
            local t = head and node_text(head, src) or ''
            return not t:match('^define')
        end,
        import_query = [=[
            ((list . (symbol) @_kw (list) @path) (#eq? @_kw "use-modules"))
            ((keyword) @_k . (list) @path (#eq? @_k "#:use-module"))
        ]=],
        resolve_import = function (mod, files)
            local parts = {}
            for w in mod:gmatch('[^%s()]+') do parts[#parts + 1] = w end
            local suffix, hit = table.concat(parts, '/') .. '.scm', nil
            for f in pairs(files) do
                local m = f == suffix
                    or f:sub(-#suffix - 1) == '/' .. suffix
                    or suffix:sub(-#f - 1) == '/' .. f
                if m then
                    if hit then return nil end
                    hit = f
                end
            end
            return hit
        end,
}
