-- retained fixture: another file that RESETS a container of growth.lua by its field name
local growth = require 'growth'
local function reset() growth.handlers = {} end
-- a reassignment of a LOCAL named like growth.lua's module table: says nothing about growth.lua
local M = {}
local function renew() M = {} end
return { reset = reset, renew = renew }
