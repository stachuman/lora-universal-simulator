-- test/t14_startup_jitter.lua
-- Captures the sim time at which on_init fires for each node so the test
-- harness can assert nodes are staggered (rather than all firing at t=0).

function on_init(self, config)
  self:emit("init_at", { time_ms = self:now() })
end
