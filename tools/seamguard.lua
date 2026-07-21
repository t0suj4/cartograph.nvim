-- The RECORD-FIELD SEAM GUARD — the fence that keeps a seamed field CLOSED
-- (record-fold arc step 2, [[cartograph-record-fold-arc]]). The Band index seam
-- has a regex guard (dogfood.BAND_SEAM); a record field like `c.file` is
-- OVERLOADED (c.file on unrelated records), so regex can't fence it. This runs
-- the taint ROSTER (consumers.lua) over the CALL producers and fails if a raw
-- read of any SEAMED field (consumers.SEAMED) reappears in a non-owner file —
-- a genuine call-record deref that isn't going through the accessor. Empty =
-- every seamed field is fully behind its accessor, so step 3 may fold it.
--
--   nvim --headless -u NONE -l tools/seamguard.lua [<root>]
-- exits non-zero on any breach (a pre-push fence; add new closed fields to
-- consumers.SEAMED as they complete).

vim.opt.rtp:prepend('.')
local consumers = require 'cartograph.consumers'

local root = arg[1] or '.'
local files = {}
for _, f in ipairs(vim.fn.glob(root .. '/lua/**/*.lua', false, true)) do
    files[#files + 1] = f:sub(#root + 2)
end

local breaches = consumers.guard(root, files)

local fields = {}
for field in pairs(consumers.SEAMED) do fields[#fields + 1] = field end
table.sort(fields)
io.write(('seam guard: %d seamed field(s) [%s], %d file(s)\n'):format(
    #fields, table.concat(fields, ', '), #files))

if #breaches == 0 then
    io.write('OK — every seamed field is fully behind its accessor (foldable)\n')
    vim.cmd('qall!')
else
    io.write(('BREACH — %d raw read(s) of a seamed field crept back:\n'):format(#breaches))
    table.sort(breaches, function (a, b)
        return a.file < b.file or (a.file == b.file and a.line < b.line)
    end)
    for _, s in ipairs(breaches) do
        io.write(('  %s:%d:%d  %s  (via %s) → route through %s\n'):format(
            s.file, s.line, s.col, s.path, s.via or '?',
            consumers.SEAMED[s.path]))
    end
    vim.cmd('cquit 1')
end
