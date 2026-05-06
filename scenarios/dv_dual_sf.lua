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

local function gen_msg_id(self)
  -- Pack node id into upper 8 bits to keep ids globally unique-ish for diagnostics.
  local mid = (self.id * 256 + self.next_msg_id) % 65536
  self.next_msg_id = self.next_msg_id + 1
  if self.next_msg_id > 255 then self.next_msg_id = 1 end
  return mid
end

-- ---------- script lifecycle ------------------------------------------------

local function beacon_fire(self)
  -- Skip beacon TX while a data exchange is in progress. Any TX (even on
  -- routing_sf) ties up the half-duplex radio and the pending CTS or DATA
  -- on data_sf would be missed. The re-arm below is unconditional so beacon
  -- cadence stays stable; at most one fire is suppressed per exchange.
  if self.pending_tx == nil and self.pending_rx == nil then
    local frame = pack_beacon(self)
    self:emit("beacon_tx", { n_entries = rt_count(self.rt) })
    self:tx(frame, { sf = self.routing_sf })
  end
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

  if tag == "R" then
    local r = parse_rts(frame)
    if not r then return end
    if r.next ~= self.id then return end  -- not for us; silent discard
    if self.pending_rx ~= nil then
      -- Already mid-exchange as a receiver; surfacing this so it's visible
      -- if it ever happens (scenario A: never; B/C with concurrency: maybe).
      self:emit("rts_rejected_busy", { from = r.src, msg_id = r.msg_id })
      return
    end

    self:emit("rts_rx", { from = r.src, origin = r.origin, dst = r.dst, msg_id = r.msg_id })
    -- Remember the RTS context so we can match the incoming DATA.
    self.pending_rx = {
      from    = r.src,
      origin  = r.origin,
      dst     = r.dst,
      msg_id  = r.msg_id,
    }
    self:set_rx_sf(self.data_sf)
    self:emit("retune_for_data", { sf = self.data_sf })

    local cts = pack_cts(self.id, r.msg_id)
    self:emit("cts_tx", { to = r.src, msg_id = r.msg_id })
    self:tx(cts, { sf = self.data_sf })
    return
  end

  if tag == "C" then
    local c = parse_cts(frame)
    if not c then return end
    if self.pending_tx == nil then return end
    if c.msg_id ~= self.pending_tx.msg_id then return end

    self:emit("cts_rx", { from = c.src, msg_id = c.msg_id })
    local d = pack_data(
      self.pending_tx.origin,
      self.id,
      self.pending_tx.dst,
      self.pending_tx.next,
      self.pending_tx.msg_id,
      self.pending_tx.payload
    )
    self:emit("data_tx", {
      origin = self.pending_tx.origin,
      dst    = self.pending_tx.dst,
      next   = self.pending_tx.next,
      msg_id = self.pending_tx.msg_id,
      len    = #self.pending_tx.payload,
    })
    self:tx(d, { sf = self.data_sf })
    self:set_rx_sf(self.routing_sf)
    self.pending_tx = nil
    return
  end

  if tag == "D" then
    local d = parse_data(frame)
    if not d then return end
    if d.next ~= self.id then return end
    if self.pending_rx == nil or d.msg_id ~= self.pending_rx.msg_id then return end

    self:emit("data_rx", {
      from   = d.src,
      origin = d.origin,
      dst    = d.dst,
      msg_id = d.msg_id,
      len    = #d.payload,
    })
    self:set_rx_sf(self.routing_sf)
    self.pending_rx = nil

    if d.dst == self.id then
      self:emit("delivered", { origin = d.origin, payload = d.payload })
    else
      local route = self.rt[d.dst]
      if route == nil then
        self:emit("forward_fail", { dst = d.dst, reason = "no_route" })
      elseif self.pending_tx ~= nil then
        -- Forwarder already busy with another in-flight TX. Cannot occur in
        -- scenario A (sequential hops) but possible under concurrent loads.
        self:emit("forward_fail", { dst = d.dst, reason = "tx_busy" })
      else
        -- TODO(scenario-B): factor this six-step launch into start_dance(self,
        -- origin, dst, next_hop, payload) — same pattern is duplicated below
        -- in on_command. Holding off until scenario B forces a signature that
        -- accommodates timeout/retry.
        local mid = gen_msg_id(self)
        self.pending_tx = {
          origin  = d.origin,           -- preserve originator across hops
          dst     = d.dst,
          next    = route.next_hop,
          msg_id  = mid,
          payload = d.payload,
        }
        local rts = pack_rts(d.origin, self.id, d.dst, route.next_hop, mid, self.data_sf)
        self:emit("rts_tx", {
          origin = d.origin, dst = d.dst, next = route.next_hop, msg_id = mid,
        })
        self:tx(rts, { sf = self.routing_sf })
        self:set_rx_sf(self.data_sf)
        self:emit("retune_for_cts", { sf = self.data_sf })
      end
    end
    return
  end
end

function on_command(self, cmd_str)
  local dst_name, text = cmd_str:match("^send (%S+) (.+)$")
  if not dst_name then return "ERROR: usage: send <dst_name> <text>" end
  local dst_id = self.name_to_id[dst_name]
  if dst_id == nil then return "ERROR: unknown dst: " .. dst_name end
  local route = self.rt[dst_id]
  if route == nil then return "ERROR: no route to " .. dst_name end
  if self.pending_tx ~= nil then return "ERROR: busy" end

  local mid = gen_msg_id(self)
  self.pending_tx = {
    origin   = self.id,
    dst      = dst_id,
    next     = route.next_hop,
    msg_id   = mid,
    payload  = text,
  }

  local frame = pack_rts(self.id, self.id, dst_id, route.next_hop, mid, self.data_sf)
  self:emit("rts_tx", { origin = self.id, dst = dst_id, next = route.next_hop, msg_id = mid })
  self:tx(frame, { sf = self.routing_sf })

  self:set_rx_sf(self.data_sf)
  self:emit("retune_for_cts", { sf = self.data_sf })

  return string.format("sent RTS msg_id=%d to %s via %d", mid, dst_name, route.next_hop)
end
