acquire_lock('db')
acquire_lock('cache')
acquire_lock('tmp')

release_lock('db')
release_lock('cahce')  -- transposed: never acquired

local handles = {}
open_file('log')
open_file('data')
close_file(handles.name) -- dynamic release: leak checks must stay quiet

local states = { idle = 1, run = 2, halt = 3, done = 4, retry = 5 }
local labels = { idle = 'Idle', run = 'Run', halt = 'Halt', done = 'Done', abort = 'Abort' }

local flow = {
  transitions = {
    { name = 'go', from = 'idle', to = 'run' },
    { name = 'halt', from = 'run', to = 'idle' },
    { name = 'die', from = '*', to = 'dead' },
  },
}
