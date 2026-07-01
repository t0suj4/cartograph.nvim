-- mutates a GLOBAL-rooted table at load time -> side effect.
-- This is the case the first effects scan got wrong: lua-ls models `table` as a
-- field of the _ENV upvalue, so the setfield's base chains through getglobal to
-- _ENV. rootIsGlobal must recognise the getglobal and NOT read this as internal.
function table.cartograph_probe(t)
    return t
end

function string.cartograph_probe(s)
    return s
end
