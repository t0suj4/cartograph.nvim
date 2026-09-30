-- REGISTRATIONS: which C function is which library name — the LJLIB_* markers of the tree's lib_*.c
-- (cartograph.luajs.packmap.registrations), their `#if` blocks gated by the RUNNING LuaJIT's configuration (the witness)
return {
    fact = 'registrations',
    needs = { 'compdb' },
    summary = 'library name -> C function, from the LJLIB_* markers',
    derive = function (_, got)
        local F = require 'cartograph.cinterp.facts'
        local any
        for _, u in ipairs(got.compdb.units) do if (F.readfile(u.file) or ''):find('LJLIB_CF(', 1, true) then any = true; break end end
        if not any then return nil, 'no unit carries an LJLIB_CF marker' end
        local config = { LJ_52 = table.pack ~= nil, LJ_HASJIT = jit and jit.status ~= nil, LJ_HASFFI = (pcall(require, 'ffi')), LJ_HASBUFFER = (pcall(require, 'string.buffer')) }
        return require('cartograph.luajs.packmap').registrations(got.compdb.dir, config)
    end,
}
