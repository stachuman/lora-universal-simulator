-- examples/sf_toggle_rx.lua
-- Receiver that toggles its RX SF on a fixed schedule. The SF-switch
-- delay (sf_switch_delay_ms) creates a blind window after each toggle —
-- frames whose preamble lands inside the window become drop_rx_blind
-- on the runtime side. Used by t20_sf_switch_blind.

function on_init(self, config)
  self.sf_a = config.sf_a or 7
  self.sf_b = config.sf_b or 8
  self.toggle_interval_ms = config.toggle_interval_ms or 50
  self:set_rx_sf(self.sf_a)
  local function flip()
    if self.cur == self.sf_a then
      self:set_rx_sf(self.sf_b); self.cur = self.sf_b
    else
      self:set_rx_sf(self.sf_a); self.cur = self.sf_a
    end
    self:after(self.toggle_interval_ms, flip)
  end
  self.cur = self.sf_a
  self:after(self.toggle_interval_ms, flip)
end

function on_recv(self, frame, meta) end
