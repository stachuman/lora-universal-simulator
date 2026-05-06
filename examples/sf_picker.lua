-- examples/sf_picker.lua
-- Minimal helper for SF-gating tests. Accepts `send_sf <sf> <text>` commands
-- and TXes the text at the requested spreading factor via the per-PendingTx
-- override. Logs every receive so the test harness sees a script_log line
-- for each delivered frame.

function on_init(self, config) end

function on_command(self, cmd_str)
  local sf, text = cmd_str:match("^send_sf (%d+) (.+)$")
  if not sf then return "ERROR: usage: send_sf <sf> <text>" end
  self:tx(text, { sf = tonumber(sf) })
  return "sent at sf=" .. sf
end

function on_recv(self, frame, meta)
  self:log("recv: " .. frame)
end
