-- test/native/freq_probe.lua
-- Author: Stanislaw Kozicki <cgpsmapper@gmail.com>
--
-- Probe for the FREQUENCY-SELECTIVE PHY gate (test_freq_mismatch), §carrier 2026-07-26.
--
-- A node optionally retunes its RF CARRIER once at init via
-- self:set_rx_freq_khz(config.rx_freq_khz) — the Lua-side twin of the firmware's
-- Hal::set_rx_freq -> ISimHal::simSetRxFreqKhz retune, writing the same live
-- SimController::_node_rx_freq_khz slot that all four carrier predicates read.
-- That lets one scenario cover both retune directions (869500->868000 flips
-- drop->decode, 868000->869500 flips decode->drop).
--
-- ★ INTEGER kHz, not MHz, on purpose: the ONE MHz->kHz rounding path in this
-- project is the firmware's protocol::mhz_to_khz, applied at the HalAdapter
-- seam. A Lua MHz argument would need a second, driftable conversion.
--
-- on_preamble_detected is recorded because the carrier gate covers TWO
-- reachability predicates, not one: a node that cannot DECODE a frame must
-- equally not DETECT its preamble (that signal drives beacon throttling and
-- LBT). Asserting on `preamble` proves the second predicate directly.
--
-- Receivers never transmit; only the nodes the scenario explicitly `ping`s do,
-- so the run stays analytically deterministic.

function on_init(self, config)
  if config.rx_freq_khz then self:set_rx_freq_khz(config.rx_freq_khz) end
end

function on_recv(self, frame, meta)
  self:emit("heard", { len = #frame })
end

function on_preamble_detected(self, info)
  self:emit("preamble", { from = info.from })
end

function on_command(self, cmd_str)
  if cmd_str ~= "ping" then return "ERROR: usage: ping" end
  self:tx("PING")
  return "sent"
end
