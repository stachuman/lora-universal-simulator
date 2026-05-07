-- test/t13_radio_busy_info.lua
-- Exercises the enriched on_radio_busy(self, info) callback and the two
-- query methods self:channel_busy_until() / self:tx_in_flight().
--
-- Flow:
--   on_command "long"  -> tx a long-airtime packet (label=LONG, info=ping)
--   on_command "short" -> tx a short packet         (label=SHORT, info=pong)
--   on_radio_busy      -> echo every info field into a "busy_observed" emit
--                         along with the two query-method readbacks. The
--                         test asserts on substrings of these emits.

function on_init(self, config)
  self:log(string.format("init id=%d name=%s", self.id, self.name))
end

function on_command(self, cmd)
  if cmd == "long" then
    self:tx(string.rep("X", 30), { label = "LONG", info = "ping" })
    return "ok"
  end
  if cmd == "short" then
    self:tx("hi", { label = "SHORT", info = "pong" })
    return "ok"
  end
  return "ERROR: unknown cmd: " .. cmd
end

function on_radio_busy(self, info)
  -- Echo what we received so the test can substring-match it.
  self:emit("busy_observed", {
    reason        = info.reason,
    len           = info.len,
    sf            = info.sf,
    label         = info.label,
    tx_info       = info.tx_info,
    busy_until_ms = info.busy_until_ms,
    cb_until      = self:channel_busy_until(),
    own_tx_until  = self:tx_in_flight(),
  })
  self:log(string.format(
    "busy: reason=%s sf=%d label=%s tx_info=%s busy_until=%d cb_until=%d own_tx_until=%d",
    info.reason, info.sf, info.label, info.tx_info,
    info.busy_until_ms, self:channel_busy_until(), self:tx_in_flight()))
end
