-- scenarios/dv_dual_sf.lua
-- Distance-vector routing on routing_sf with per-hop dual-SF data delivery
-- on data_sf via RTS/CTS/DATA. See docs/superpowers/specs/2026-05-06-s01-dv-dual-sf-scenario-design.md.

-- ---------- wire format helpers (private to this file) ----------------------

local function pack_beacon(node)
  local entries = {}
  for dest_id, e in pairs(node.rt) do
    table.insert(entries, { dest = dest_id, next = e.next_hop, score = e.score, hops = e.hops })
  end
  local out = "B" .. string.char(node.id) .. string.char(#entries)
  for _, e in ipairs(entries) do
    local s = math.floor(e.score + 0.5)
    if s < -128 then s = -128 end
    if s >  127 then s =  127 end
    if s < 0 then s = s + 256 end  -- two's-complement byte
    out = out .. string.char(e.dest) .. string.char(e.next) .. string.char(s) .. string.char(e.hops)
  end
  return out
end

local function parse_beacon(frame)
  if #frame < 3 or frame:sub(1,1) ~= "B" then return nil end
  local src = frame:byte(2)
  local n   = frame:byte(3)
  if #frame < 3 + 4*n then return nil end
  local entries = {}
  local pos = 4
  for _ = 1, n do
    local dest = frame:byte(pos)
    local nxt  = frame:byte(pos + 1)
    local sb   = frame:byte(pos + 2)
    local score = (sb >= 128) and (sb - 256) or sb
    local hops = frame:byte(pos + 3)
    table.insert(entries, { dest = dest, next = nxt, score = score, hops = hops })
    pos = pos + 4
  end
  return { src = src, entries = entries }
end

local function pack_rts(origin, src, dst, next_hop, msg_id, data_sf)
  return "R" .. string.char(origin) .. string.char(src) .. string.char(dst)
              .. string.char(next_hop)
              .. string.char(msg_id % 256)
              .. string.char(math.floor(msg_id / 256) % 256)
              .. string.char(data_sf)
end

local function parse_rts(frame)
  if #frame < 8 or frame:sub(1,1) ~= "R" then return nil end
  return {
    origin  = frame:byte(2),
    src     = frame:byte(3),
    dst     = frame:byte(4),
    next    = frame:byte(5),
    msg_id  = frame:byte(6) + frame:byte(7) * 256,
    data_sf = frame:byte(8),
  }
end

local function pack_cts(src, msg_id)
  return "C" .. string.char(src)
              .. string.char(msg_id % 256)
              .. string.char(math.floor(msg_id / 256) % 256)
end

local function parse_cts(frame)
  if #frame < 4 or frame:sub(1,1) ~= "C" then return nil end
  return {
    src    = frame:byte(2),
    msg_id = frame:byte(3) + frame:byte(4) * 256,
  }
end

local function pack_data(origin, src, dst, next_hop, msg_id, payload)
  return "D" .. string.char(origin) .. string.char(src) .. string.char(dst)
              .. string.char(next_hop)
              .. string.char(msg_id % 256)
              .. string.char(math.floor(msg_id / 256) % 256)
              .. payload
end

local function parse_data(frame)
  if #frame < 7 or frame:sub(1,1) ~= "D" then return nil end
  return {
    origin  = frame:byte(2),
    src     = frame:byte(3),
    dst     = frame:byte(4),
    next    = frame:byte(5),
    msg_id  = frame:byte(6) + frame:byte(7) * 256,
    payload = frame:sub(8),
  }
end

-- ---------- routing helpers --------------------------------------------------

local function rt_count(rt)
  local c = 0
  for _ in pairs(rt) do c = c + 1 end
  return c
end

local function maybe_emit_rt_full(self)
  if self.rt_full_emitted then return end
  if rt_count(self.rt) >= self.peer_count then
    self:emit("rt_full", { peers = self.peer_count })
    self.rt_full_emitted = true
  end
end

-- ---------- script lifecycle ------------------------------------------------

local function beacon_fire(self)
  local frame = pack_beacon(self)
  self:emit("beacon_tx", { n_entries = rt_count(self.rt) })
  self:tx(frame, { sf = self.routing_sf })
  self:after(self.beacon_period_ms, function() beacon_fire(self) end)
end

function on_init(self, config)
  self.routing_sf       = config.routing_sf      or 7
  self.data_sf          = config.data_sf         or 12
  self.beacon_period_ms = config.beacon_period_ms or 5000

  self.rt              = {}
  self.next_msg_id     = 1
  self.pending_tx      = nil
  self.pending_rx      = nil
  self.rt_full_emitted = false

  self.name_to_id = {}
  self.id_to_name = {}
  local nodes = sim:nodes()
  for _, n in ipairs(nodes) do
    self.name_to_id[n.name] = n.id
    self.id_to_name[n.id]   = n.name
  end
  self.peer_count = #nodes - 1

  -- ID-staggered first beacon to avoid collisions on first round.
  self:after(self.id * 100, function() beacon_fire(self) end)
end

function on_recv(self, frame, meta)
  if #frame == 0 then return end
  local tag = frame:sub(1, 1)

  if tag == "B" then
    local b = parse_beacon(frame)
    if not b then return end
    self:emit("beacon_rx", { src = b.src, n_entries = #b.entries })

    -- Direct entry first.
    self.rt[b.src] = {
      next_hop = b.src,
      score    = meta.snr,
      hops     = 1,
      last_seen_ms = self:now(),
    }
    self:emit("rt_update", { dest = b.src, next = b.src, score = meta.snr, hops = 1 })

    -- DV merge: each entry in the beacon (other than self) is a candidate
    -- route via the beacon's sender.
    for _, e in ipairs(b.entries) do
      if e.dest ~= self.id and e.next ~= self.id then
        local combined_score = math.min(meta.snr, e.score)
        local combined_hops  = e.hops + 1
        if combined_hops <= 8 then
          local cur = self.rt[e.dest]
          local better = (cur == nil)
            or (combined_score > cur.score)
            or (combined_score == cur.score and combined_hops < cur.hops)
          if better then
            self.rt[e.dest] = {
              next_hop = b.src,
              score    = combined_score,
              hops     = combined_hops,
              last_seen_ms = self:now(),
            }
            self:emit("rt_update", {
              dest = e.dest, next = b.src,
              score = combined_score, hops = combined_hops,
            })
          end
        end
      end
    end

    maybe_emit_rt_full(self)
    return
  end
end

function on_command(self, cmd_str)
  -- Filled in in Task 4.
  return "ERROR: protocol not yet wired"
end
