-- examples/burst_sender.lua
-- Schedules a configurable burst of TXes via self:after().
-- Receivers don't need any logic — count rx / drop_* events from the
-- runtime side via expect{event_count_*} assertions.
--
-- config.role           = "sender" | "receiver"   (default "receiver")
-- config.count          = number of packets to send (default 200)
-- config.interval_ms    = ms between TX starts    (default 100)
-- config.first_ms       = ms before first TX      (default 1000)
-- config.payload_bytes  = packet length in bytes  (default 8)

function on_init(self, config)
  self.role = config.role or "receiver"
  if self.role ~= "sender" then return end
  local n        = config.count         or 200
  local interval = config.interval_ms   or 100
  local first    = config.first_ms      or 1000
  local pl_bytes = config.payload_bytes or 8
  -- Simple repeating payload — content doesn't matter, length does.
  local payload  = string.rep("A", pl_bytes)
  for i = 1, n do
    self:after(first + (i - 1) * interval, function()
      self:tx(payload, { sf = config.sf or 7, label = "BURST" })
    end)
  end
  self:log(string.format("burst scheduled: count=%d interval=%dms payload=%dB",
    n, interval, pl_bytes))
end

function on_recv(self, frame, meta)
  -- Receiver: nothing to do; rx events are emitted by the runtime.
end
