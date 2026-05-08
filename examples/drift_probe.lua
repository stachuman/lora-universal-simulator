-- examples/drift_probe.lua
-- Schedules a timer for `delay_ms` and records the wall-time at which it
-- actually fires. The script's `:now()` should match `delay_ms` exactly
-- (that's its perceived clock); the wall-time the runtime fires at gets
-- captured by emitting the script_emit at fire time so the test can
-- assert the wall delta vs. expected drift.

function on_init(self, config)
  self.delay_ms = config.delay_ms or 10000
  self:after(self.delay_ms, function()
    self:emit("drift_check", {
      script_now    = self:now(),       -- node-perceived time
      expected_node = self.delay_ms,    -- node-time we asked to fire at
    })
  end)
end

function on_recv(self, frame, meta) end
