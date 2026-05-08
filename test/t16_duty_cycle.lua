-- test/t16_duty_cycle.lua
-- Verifies duty-cycle accounting at both layers:
--   * Lua pre-check (script self-regulates by querying self:airtime_used_ms)
--   * Runtime hard-block (safety net; on_radio_busy reason=duty_cycle_exceeded)
--
-- Scenario sets duty_cycle = 0.02 (2%) and window = 10s → budget 200 ms.
-- Each SF8/30-byte TX is ~150 ms airtime. So:
--   TX #1: 0  + 150 = 150 ≤ 200 → fits, succeeds
--   TX #2: 150 + 150 = 300 > 200 → Lua pre-check defers, emits duty_cycle_blocked
-- The deferred TX retries when the window slides past TX #1's expiry,
-- making forward progress without burning retries.

-- Local airtime estimator (matches the C++ Semtech AN1200.13 form). Used
-- by the script to anticipate whether `(used + this_tx)` would breach.
-- This is the same pattern firmware ports use — modem driver tracks
-- airtime, app prechecks before invoking driver.
local function airtime_ms(sf, bw_hz, cr, preamble_sym, len_bytes)
  local t_sym = (2 ^ sf) / (bw_hz / 1000)
  local t_pre = (preamble_sym + 4.25) * t_sym
  local de    = (t_sym >= 16) and 1 or 0
  local num   = 8 * len_bytes - 4 * sf + 44
  local den   = 4 * (sf - 2 * de)
  local pay_sym = 8 + math.max(math.ceil(num / den) * cr, 0)
  return math.floor(t_pre + pay_sym * t_sym)
end

function on_init(self, config)
  self.duty_cycle           = config.duty_cycle           or config._sim_duty_cycle           or 0.01
  self.duty_cycle_window_ms = config.duty_cycle_window_ms or config._sim_duty_cycle_window_ms or 3600000
  self.budget_ms            = math.floor(self.duty_cycle * self.duty_cycle_window_ms)
  self.bw_hz                = (config._sim_bw_hz or 250000)
  self.cr                   = config.cr or config._sim_cr or 5
  self.preamble_sym         = config.preamble_sym or 16
  self.sf                   = config.sf or 8
  self:log(string.format("init id=%d name=%s duty=%.3f window=%dms budget=%dms",
    self.id, self.name, self.duty_cycle, self.duty_cycle_window_ms, self.budget_ms))
end

local function tx_burn(self, idx)
  local payload = string.rep("X", 30)
  local this_air = airtime_ms(self.sf, self.bw_hz, self.cr, self.preamble_sym, #payload)
  local used = self:airtime_used_ms(self.duty_cycle_window_ms)
  if used + this_air > self.budget_ms then
    local oldest = self:oldest_tx_end_ms()
    local now    = self:now()
    local wait   = (oldest > 0)
                   and (oldest + self.duty_cycle_window_ms - now)
                   or self.duty_cycle_window_ms
    if wait < 1 then wait = 1 end
    self:emit("duty_cycle_blocked", {
      idx = idx, this_airtime_ms = this_air,
      used_ms = used, budget_ms = self.budget_ms,
      window_ms = self.duty_cycle_window_ms, wait_ms = wait,
      source = "tx_burn",
    })
    self:log(string.format("burn idx=%d would_use=%dms+%dms>%dms defer %dms",
      idx, used, this_air, self.budget_ms, wait))
    self:after(wait, function() tx_burn(self, idx) end)
    return
  end
  self:emit("burn_tx", { idx = idx, used_ms_pre = used, this_airtime_ms = this_air })
  self:log(string.format("burn idx=%d ok used=%dms+%dms<=%dms",
    idx, used, this_air, self.budget_ms))
  self:tx(payload, { label = "BURN", sf = self.sf })
end

function on_command(self, cmd)
  if cmd == "burn" then
    -- Schedule 4 TXes with 50ms gaps. Budget=200ms, each ~150ms.
    -- #1 fits; #2 is too big → deferred; #3 fits when #1 ages out, etc.
    for i = 1, 4 do
      self:after(50 * (i - 1) + 1, function() tx_burn(self, i) end)
    end
    return "ok"
  end
  return "ERROR: unknown cmd: " .. cmd
end

function on_radio_busy(self, info)
  self:emit("runtime_block", {
    reason = info.reason, label = info.label,
    busy_until_ms = info.busy_until_ms,
  })
end
