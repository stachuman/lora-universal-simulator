-- test/native/bw_probe.lua
-- Receive-only probe for the BW-mismatch delivery gate (test_bw_mismatch).
--
-- A node optionally retunes its RX BANDWIDTH once at init via
-- self:set_rx_bw(config.rx_bw_hz) — the Lua-side twin of the firmware's
-- Hal::set_rx_bw -> ISimHal::simSetRxBw retune, writing the same live
-- SimController::_node_rx_bw_hz slot the delivery gate reads. That lets one
-- scenario cover both retune directions (250k->125k flips drop->decode,
-- 125k->250k flips decode->drop) without any TX from a receiver, so the
-- half-duplex and LBT paths stay out of the picture.
--
-- Receivers NEVER transmit (no forwarding) — the only TX in the scenario is
-- the originator's single `ping`, keeping the run analytically deterministic.

function on_init(self, config)
  if config.rx_bw_hz then self:set_rx_bw(config.rx_bw_hz) end
end

function on_recv(self, frame, meta)
  self:emit("heard", { len = #frame })
end

function on_command(self, cmd_str)
  if cmd_str ~= "ping" then return "ERROR: usage: ping" end
  self:tx("PING")
  return "sent"
end
