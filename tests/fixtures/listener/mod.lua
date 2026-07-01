-- wiretap-style listener bugs, for the listener-audit golden test.
local wiretap = require 'wiretap'

wiretap:register_listener("on_tick", function () end)
wiretap:register_listener("on_build", function () end)   -- registered, never subscribed

wiretap:subscribe("event", "on_tikc")   -- typo: never registered -> runtime error
wiretap:subscribe("event", "on_tick")   -- subscribed, never unsubscribed -> leak

local function setup()
    -- registered inside a function, not at load -> may register after init
    wiretap:register_listener("on_lazy", function () end)
end

return setup
