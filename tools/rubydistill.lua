-- rubydistill — mint a `cruby` L2 profile by asking a REAL ruby interpreter what
-- it provides, the same measurement-over-transcription move as tools/luadistill
-- ([[cartograph-portability-lever]]). Where luadistill introspects the LuaJIT it
-- runs inside, this shells out to the `ruby` on PATH.
--
-- WHY this profile in particular: it gives `ruby-rails` a comparable sibling, so
-- the portability move diff can answer the question the lever was designed for —
-- "will this run WITHOUT Rails, and if not, where does it break?". Before it, no
-- two shipped ruby profiles could be compared (ruby-core is signature-keyed).
--
-- WHAT IT MEASURES, stated because a provides-set is a promise:
--   · the core surface of the interpreter on PATH, recorded in `version`.
--   · plus the DEFAULT-GEM stdlib listed in STDLIB below, required explicitly.
--     Those ship with every CRuby, so a codebase may use them with no Gemfile —
--     leaving them out would report `URI.parse` as unavailable on plain ruby,
--     which is false. The stamp records exactly which were loaded.
--   · nothing else. No Rails, no bundler, no gems: that is the entire point.
--
--   nvim --headless -u NONE -l tools/rubydistill.lua
--   ... --show    print the counts, write nothing

local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local OUT = REPO .. '/lua/cartograph/spec/profile/cruby.mpack'

local SHOW = false
for _, a in ipairs(arg or {}) do
    if a == '--show' then SHOW = true
    else print('rubydistill: unknown argument ' .. a); os.exit(2) end
end

if vim.fn.executable('ruby') ~= 1 then
    print('rubydistill: no `ruby` on PATH — nothing to measure, refusing to guess')
    os.exit(2)
end

-- default gems: shipped with CRuby, usable without a Gemfile
local STDLIB = { 'uri', 'json', 'set', 'time', 'date', 'fileutils', 'logger',
    'digest', 'base64', 'securerandom', 'erb', 'ostruct', 'stringio', 'tempfile',
    'open3', 'benchmark', 'pathname', 'forwardable', 'singleton', 'observer',
    'timeout', 'socket', 'etc', 'shellwords', 'csv', 'yaml', 'zlib' }

-- The probe. Emits one record per line: F=free fn, N=namespace, M=type member.
-- Enumerated from the live interpreter, never from a list in this file.
local PROBE = ([[
%s
core = [String, Symbol, Integer, Float, Numeric, Array, Hash, Range, Struct,
        Time, File, IO, Dir, Proc, Method, Module, Class, Exception, Thread,
        Mutex, Enumerator, Comparable, Enumerable, Kernel, Object, NilClass,
        TrueClass, FalseClass, Regexp, MatchData, Random, Rational, Complex]
seen_ns = {}
# free functions: what you can call with no receiver
(Kernel.private_instance_methods(false) + Kernel.methods).uniq.each do |m|
  puts "F\t#{m}"
end
# namespaces: constants that answer to methods (modules/classes)
Object.constants.sort.each do |c|
  next if seen_ns[c]
  seen_ns[c] = true
  begin
    v = Object.const_get(c)
  rescue StandardError, LoadError
    next
  end
  next unless v.is_a?(Module)
  puts "N\t#{c}"
  begin
    v.singleton_methods(false).each { |m| puts "M\t#{c}\t#{m}" }
  rescue StandardError
  end
end
# instance methods of the core types, which is what a receiver-less tail match
# has to be able to find
core.each do |k|
  begin
    k.instance_methods(false).each { |m| puts "M\t#{k.name}\t#{m}" }
  rescue StandardError
  end
end
]]):format(table.concat(vim.tbl_map(function (m)
    return ("begin; require '%s'; rescue LoadError; end"):format(m)
end, STDLIB), '\n'))

local script = vim.fn.tempname() .. '.rb'
local fd = assert(io.open(script, 'w'))
fd:write(PROBE)
fd:close()

local out = vim.fn.systemlist({ 'ruby', script })
local rc = vim.v.shell_error
vim.fn.delete(script)
if rc ~= 0 then
    print('rubydistill: the probe failed (exit ' .. rc .. ')')
    for i = 1, math.min(5, #out) do print('  ' .. out[i]) end
    os.exit(1)
end

local version = (vim.fn.systemlist({ 'ruby', '-e', 'print RUBY_VERSION' })[1]) or '?'
local free, nsset, namespaces, types, vocab = {}, {}, {}, {}, {}
local n_members, loaded = 0, {}
for _, line in ipairs(out) do
    local kind, a, b = line:match('^(%a)\t([^\t]*)\t?(.*)$')
    if kind == 'F' and a ~= '' then
        free[a] = true
        vocab[a] = true
    elseif kind == 'N' and a ~= '' then
        nsset[a] = true
        namespaces[a] = true
        vocab[a] = true
    elseif kind == 'M' and a ~= '' and b ~= '' then
        types[a] = types[a] or { members = {} }
        types[a].members[b] = true
        vocab[b] = true
        n_members = n_members + 1
    end
end
for _, m in ipairs(STDLIB) do loaded[#loaded + 1] = m end

local prof = {
    schema = 1, runtime = 'cruby', lang = 'ruby', version = version,
    stamp = ('introspected from ruby %s; default gems loaded: %s')
        :format(version, table.concat(loaded, ' ')),
    free = free, nsset = nsset, namespaces = namespaces, types = types,
    vocab = vocab,
}

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
print(('rubydistill — ruby %s'):format(version))
print(('  free functions   %d'):format(count(free)))
print(('  namespaces       %d'):format(count(nsset)))
print(('  typed members    %d across %d types'):format(n_members, count(types)))
print(('  vocab (total)    %d'):format(count(vocab)))
if SHOW then print('  --show: nothing written'); return end

local blob = vim.mpack.encode(prof)
local wfd = assert(io.open(OUT, 'wb'))
wfd:write(blob)
wfd:close()
print(('  wrote %s (%d bytes)'):format(OUT:sub(#REPO + 2), #blob))
print('  pairs with ruby-rails: :CartographPortability ruby-rails cruby')
