-- ZIP container format: the central directory + DEFLATE, over an injected range
-- reader. Knows nothing about where the archive lives.
--
-- `rr(path, off, len)` is the ONLY way this touches bytes — a NEGATIVE off is a
-- suffix range, which is how the trailer is found without pulling the archive.
-- That signature is transport.read_range's, so a zip composes over disk, over
-- another archive, or over a wire without learning which.
--
-- MEASURED on the local Factorio mods dir (195 archives, 3.2 GB), which is what
-- the shape of this file is answering to:
--   · 67% of entries (3164 of 4720 sampled) set the DATA-DESCRIPTOR flag, which
--     zeroes crc/sizes in the LOCAL header. Sizes therefore come from the CENTRAL
--     DIRECTORY, always. Reading them from the local header is the classic
--     zip-parser bug and it would have hit two entries in three.
--   · only methods 0 (stored) and 8 (deflate) appear across those 4720 entries,
--     so exactly two cases are needed.
--   · 112 of 195 archives have an internal top-directory name that DIFFERS from
--     the manifest name — identity never comes from a path here (see
--     spec/ecosystem/lua-factorio.lua); this file reports entries, nothing more.
--
-- zlib supplies inflate and crc32. Its absence is a clean `available() == false`,
-- never a hard error: transport's zip kind then returns nil and is skipped, so a
-- corpus degrades to "archives unreadable" rather than failing to open.

local M = {}

local ok_ffi, ffi = pcall(require, 'ffi')

-- one cdef for the process; another module may already have declared z_stream,
-- so a redefinition error is not fatal
local Z
if ok_ffi then
    pcall(ffi.cdef, [[
        typedef struct z_stream_s {
            const unsigned char *next_in;  unsigned int avail_in;
            unsigned long total_in;
            unsigned char *next_out;       unsigned int avail_out;
            unsigned long total_out;
            const char *msg; void *state; void *zalloc; void *zfree; void *opaque;
            int data_type; unsigned long adler; unsigned long reserved;
        } z_stream;
        int inflateInit2_(z_stream*, int windowBits, const char *ver, int size);
        int inflate(z_stream*, int flush);
        int inflateEnd(z_stream*);
        unsigned long crc32(unsigned long, const unsigned char*, unsigned int);
        const char * zlibVersion(void);
    ]])
    for _, n in ipairs { 'z', 'libz.so.1', 'libz.so', 'libz.dylib', 'zlib1' } do
        local okl, lib = pcall(ffi.load, n)
        if okl then Z = lib; break end
    end
end

--- Can this process read archive CONTENT? Enumerating and stamping need no zlib
--- (the central directory is stored uncompressed) — only inflate does, which is
--- exactly the partial capability the transport contract models.
function M.available() return Z ~= nil end

local SIG_EOCD, SIG_CD, SIG_LOCAL = 0x06054b50, 0x02014b50, 0x04034b50
local EOCD_MAX = 65557 -- 22-byte record + a 64 KB comment, the format's ceiling

local function u16(s, i)
    local a, b = s:byte(i, i + 1)
    if not b then return nil end
    return a + b * 256
end
local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

--- RAW deflate (windowBits = -15: a zip member has no zlib/gzip wrapper).
local function inflate_raw(data, outsize)
    if not Z then return nil, 'no zlib' end
    if outsize == 0 then return '' end
    local st = ffi.new('z_stream')
    if Z.inflateInit2_(st, -15, Z.zlibVersion(), ffi.sizeof('z_stream')) ~= 0 then
        return nil, 'inflateInit failed'
    end
    local out = ffi.new('unsigned char[?]', outsize)
    st.next_in, st.avail_in = ffi.cast('const unsigned char *', data), #data
    st.next_out, st.avail_out = out, outsize
    local rc = Z.inflate(st, 4) -- Z_FINISH
    Z.inflateEnd(st)
    -- 1 = Z_STREAM_END (complete), 0 = Z_OK (output filled exactly)
    if rc ~= 1 and rc ~= 0 then return nil, 'inflate rc=' .. rc end
    return ffi.string(out, outsize)
end

--- Open an archive: locate the trailer, parse the central directory. Returns a
--- handle, or (nil, why). NO zlib needed — this is the enumerable-but-maybe-not-
--- readable half.
--- `whole` (optional) is the archive's full bytes when a caller has decided to
--- read it once; entries are then served from memory instead of per-entry ranges.
function M.open(rr, path, whole)
    local read = whole
        and function (_, off, len)
            local start = (off < 0) and math.max(0, #whole + off) or off
            return whole:sub(start + 1, len and (start + len) or nil)
        end
        or rr
    local tail, err = read(path, -EOCD_MAX, EOCD_MAX)
    if not tail then return nil, err or 'unreadable' end
    if #tail < 22 then return nil, 'too small for a zip' end
    local eocd
    for i = #tail - 21, 1, -1 do
        if u32(tail, i) == SIG_EOCD then eocd = i; break end
    end
    -- no trailer: not a zip, or zip64 (which puts a different record here). Zip64
    -- is REFUSED rather than guessed — a Factorio mod cannot reach 65535 entries
    -- or 4 GB, and a wrong guess would silently mis-parse.
    if not eocd then return nil, 'no end-of-central-directory (zip64?)' end
    local count, cdsize, cdoff =
        u16(tail, eocd + 10), u32(tail, eocd + 12), u32(tail, eocd + 16)
    if not (count and cdsize and cdoff) then return nil, 'truncated trailer' end
    local cd = read(path, cdoff, cdsize)
    if not cd or #cd < cdsize then return nil, 'truncated central directory' end
    local entries, byname, p = {}, {}, 1
    for _ = 1, count do
        if u32(cd, p) ~= SIG_CD then break end
        local nlen, elen, clen = u16(cd, p + 28), u16(cd, p + 30), u16(cd, p + 32)
        if not clen then break end
        local e = {
            name = cd:sub(p + 46, p + 45 + nlen),
            method = u16(cd, p + 10),
            crc = u32(cd, p + 16),
            csize = u32(cd, p + 20), -- from the CD: the local header lies when
            usize = u32(cd, p + 24), -- the data-descriptor flag is set (67%)
            offset = u32(cd, p + 42),
        }
        entries[#entries + 1] = e
        byname[e.name] = e
        p = p + 46 + nlen + elen + clen
    end
    return { path = path, read = read, entries = entries, byname = byname }
end

--- One entry's bytes, CRC-verified. (nil, why) on any failure — including 'no
--- zlib', which is UNAVAILABLE rather than absence: the entry is there, we simply
--- cannot decompress it.
function M.read(z, name)
    local e = z.byname[name]
    if not e then return nil, 'no such entry' end
    local lh = z.read(z.path, e.offset, 30)
    if not lh or #lh < 30 then return nil, 'truncated local header' end
    if u32(lh, 1) ~= SIG_LOCAL then return nil, 'bad local header' end
    -- skip name+extra as declared LOCALLY (those lengths are honest), but the
    -- SIZES come from the central directory
    local data = z.read(z.path, e.offset + 30 + u16(lh, 27) + u16(lh, 29), e.csize)
    if not data or #data < e.csize then return nil, 'truncated entry data' end
    local out, err
    if e.method == 0 then out = data
    elseif e.method == 8 then out, err = inflate_raw(data, e.usize)
    else return nil, 'unsupported method ' .. tostring(e.method) end
    if not out then return nil, err or 'inflate failed' end
    if Z then
        local got = tonumber(Z.crc32(0, ffi.cast('const unsigned char *', out), #out))
        if got ~= e.crc then
            return nil, ('crc mismatch %08x vs %08x'):format(got, e.crc)
        end
    end
    return out
end

return M
