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

-- §w4-#7 (2026-07-26): the PREAMBLE half of the BW gate, recorded for the same
-- reason freq_probe.lua records it — "can this node hear that TX" is decided by
-- MORE THAN ONE predicate, and the preamble detector is a different one from the
-- decoder. It is a correlator matched to the configured chirp rate BW/2^SF, so a
-- BW mismatch must suppress the PreambleDetected IRQ exactly as an SF mismatch
-- does. Asserting on `preamble` probes that predicate directly; the decode
-- verdict (drop_bw_mismatch) cannot see it, and the corpus never can either —
-- every one of the 29 scenarios is single-BW.
function on_preamble_detected(self, info)
  self:emit("preamble", { from = info.from })
end

function on_command(self, cmd_str)
  if cmd_str ~= "ping" then return "ERROR: usage: ping" end
  self:tx("PING")
  return "sent"
end
