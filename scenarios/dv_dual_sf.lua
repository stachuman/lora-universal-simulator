-- scenarios/dv_dual_sf.lua
-- Distance-vector routing on routing_sf with per-hop dual-SF data delivery
-- on data_sf via RTS/CTS/DATA. See docs/superpowers/specs/2026-05-06-s01-dv-dual-sf-scenario-design.md.
--
-- Wire format:
-- | Tag   | Frame  | Layout                                                                          |
-- | ----- | ------ | ------------------------------------------------------------------------------- |
-- | `'B'` | Beacon | `B`, src(1), n(1), entries × n × {dest(1), next(1), score_i8(1), hops(1)}       |
-- | `'R'` | RTS    | `R`, origin(1), src(1), dst(1), next(1), msg_id_lo(1), msg_id_hi(1), data_sf(1) |
-- | `'C'` | CTS    | `C`, src(1), msg_id_lo(1), msg_id_hi(1)                                         |
-- | `'D'` | DATA   | `D`, origin(1), src(1), dst(1), next(1), msg_id_lo(1), msg_id_hi(1), payload(n) |
-- | `'K'` | ACK    | `K`, msg_id_lo(1), msg_id_hi(1)                                                 |
-- | `'N'` | NACK   | `N`, msg_id_lo(1), msg_id_hi(1), busy_for_ms_lo(1), busy_for_ms_hi(1)           |
--
-- RTS's last byte is a per-flight bitmap of allowed data SFs:
--   bit i = SF (5+i) is acceptable for the DATA leg; the receiver picks one.
--   bit 0 = SF5 (fastest), bit 7 = SF12 (most robust). e.g. 0b01000010 = SF6+SF12.
-- CTS's last byte is the receiver's chosen data SF (single value, 5..12),
-- selected from the RTS bitmap based on the link SNR + safety margin.
-- This makes the data-plane SF per-hop adaptive without any wire-format
-- negotiation round-trip beyond the existing RTS/CTS handshake.
--
-- DATA's payload(n) bytes carry an APPLICATION-LAYER header followed by the
-- user text:
--   payload = [origin_seq_lo(1)] [origin_seq_hi(1)] [user_text(N)]
-- The originator stamps a 16-bit per-origin sequence number; mesh layer
-- treats the entire `payload` as opaque bytes (forwarders relay verbatim).
-- Every receiving node parses the first 2 bytes to derive the globally-
-- unique end-to-end message id (origin_id from the mesh frame, origin_seq
-- from the payload header) and uses it for duplicate detection — see
-- "Origin-level dedup" in the protocol-flow notes below. This is exactly
-- how a real firmware port would do it: the application generates seq +
-- text, hands the bytes to the mesh layer, the mesh layer treats opaque,
-- and the receiver's app strips the header on delivery.
--
-- Protocol flow (per node):
--
-- on_init
--   build name↔id maps from sim:nodes(); peer_count = N-1
--   RX defaults to routing_sf; schedule first beacon at rand(0, period)
--
-- Beacon plane (routing_sf)
--   beacon_fire (skipped if pending_tx or pending_rx; re-arm always)
--     → tx 'B' with all rt entries → ±20% jittered re-arm
--   triggered beacons: any rt mutation (new/promote/3cycle-prune)
--     schedules a one-shot beacon within rand(50,500)ms (coalesced into
--     a single armed trigger). This is what makes convergence fast when
--     the operational period is minutes-long; periodic beacons are just
--     a slow keep-alive. Half-duplex skip applies — busy nodes drop the
--     trigger and rely on the next mutation (or periodic) to retry.
--   on_recv 'B' from N at rx_snr
--     install rt[N] = {direct, snr, hops=1, n2_hop=nil}
--     for each entry e in beacon (e.dest != self.id):
--       if e.next == self.id (N routes e.dest via me):
--         3-cycle prune — if my own rt[e.dest].primary or .alt has
--         n2_hop == N, that slot is part of cycle me→X→N→me; drop it
--         (collapse alt→primary, or remove entry if both slots looped)
--       else:
--         cand = {via=N, n2_hop=e.next, score=min(rx_snr, e.score),
--                 hops=e.hops+1}
--         adopt if hops<=8 AND (no current OR better score OR same score & fewer hops)
--     emit rt_full once rt covers all peers
--   The stored n2_hop (N's claimed next-hop for that dest) is the only
--   reason a 3-cycle can be detected without enlarging the wire format —
--   the byte was already in the beacon entry, we just hadn't been keeping it.
--
-- Data plane (RTS on routing_sf, CTS+DATA on data_sf, ACK on routing_sf)
--   tx_queue is a FIFO of {origin, dst_id, dst_name, payload}; both
--   originators (on_command) and forwarders (on_recv 'D' relay branch)
--   enqueue, never call issue_send directly. become_free pops one whenever
--   the node becomes idle (pending_tx == pending_rx == nil) — that's the
--   single drain point. Forwarders defer the post-ACK action one
--   ack_air_ms tick so the ACK and the next RTS don't share a step.
--
--   ORIGINATOR (on_command "send <dst> <text>"): enqueue + become_free
--   FORWARDER (on_recv 'D' relay): enqueue + after(ack_air_ms+1, become_free)
--   issue_send (called by become_free for both): builds RTS, sets
--     pending_tx, retunes RX to data_sf, starts rts_timeout
--
--   NEXT-HOP (on_recv 'R' with next == self.id):
--     • last_acked_from[r.src] == r.msg_id  → re-tx ACK on routing_sf,
--                                              return (sender retried after
--                                              losing previous ACK)
--     • pending_rx busy + same (from,msg_id) → re-tx CTS-dup, restart
--                                              pending_rx_expiry, return
--     • pending_rx busy + different sender   → emit rts_rejected_busy
--     • else: set_rx_sf(data_sf); pending_rx = {from,origin,dst,msg_id};
--             start_pending_rx_expiry; tx 'C' on data_sf
--
--   ORIGINATOR/FORWARDER (on_recv 'C' matching pending_tx.msg_id):
--     1. cancel rts_timeout (avoid spurious retry on the same tick)
--     2. after cts_to_data_gap_ms: tx 'D' on data_sf, set_rx_sf(routing_sf),
--                                   start_ack_timeout (covers DATA airtime
--                                   + ACK airtime). Keep pending_tx until
--                                   ACK or ack_timeout fires.
--
--   NEXT-HOP (on_recv 'D' matching pending_rx.msg_id, next == self.id):
--     1. parse application-layer origin-seq header from d.payload to get
--        (origin_seq, user_text)
--     2. cancel pending_rx_expiry; set_rx_sf(routing_sf); pending_rx = nil
--     3. cache last_acked_from[d.src] = d.msg_id; tx 'K' on routing_sf
--     4. ORIGIN-LEVEL DEDUP: if (d.origin, origin_seq) seen recently,
--        emit dup_drop and return — ACK was already sent; we just don't
--        deliver-twice or forward-twice. Catches DV routing loops and
--        legitimate same-payload retries via different paths.
--     5. record the (origin, origin_seq) in seen_origins with a TTL
--     6. if dst == self.id → emit "delivered" (payload = user_text)
--        else (forward) → after ack_air_ms+1: enqueue forward (preserving
--        the full payload bytes incl. the seq header), become_free
--
--   ORIGINATOR/FORWARDER (on_recv 'K' matching pending_tx.msg_id):
--     • cancel ack_timeout; pending_tx = nil; become_free
--
-- Retries (per-hop):
--   rts_timeout_fire — CTS didn't arrive within rts_timeout_ms:
--     • pending_rx set  → reschedule self after rts_busy_retry_ms
--     • retries_left>0  → tx_rts_retry("cts_timeout"), restart
--     • retries_left==0 → emit rts_giveup, clear pending_tx, become_free
--   ack_timeout_fire — ACK didn't arrive within DATA_air + ACK_air:
--     • pending_rx set  → reschedule self after rts_busy_retry_ms
--     • retries_left>0  → tx_rts_retry("ack_timeout"), restart
--     • retries_left==0 → emit data_ack_giveup, clear pending_tx, become_free
--   pending_rx_expiry_fire — DATA didn't arrive after CTS:
--     • clear pending_rx, retune to routing_sf, emit data_rx_timeout, become_free
--   tx_rts_retry: re-tx RTS with same msg_id and re-arm rts_timeout. The
--   receiver's rts_already_acked / rts_rx_dup paths handle whatever state
--   it's in (still expecting DATA, or already acked).
--
-- Airtime + dynamic timeouts:
--   airtime_ms(sf, bw_hz, cr, preamble_sym, len) — Semtech AN1200.13 in Lua
--   so the same code is firmware-portable. cr is the RadioLib/MeshCore
--   multiplier (5..8 = CR4/5..CR4/8) used directly in the formula.
--   on_init computes:
--     rts_timeout_ms       = airtime(routing_sf, RTS) + airtime(data_sf, CTS)
--     ack_air_ms           = airtime(routing_sf, ACK)
--     pending_rx_expiry_ms = cts_to_data_gap + airtime(data_sf, max DATA)
--   start_ack_timeout uses pending_tx.payload's actual length to compute
--   the precise DATA-airtime contribution. No safety pads: step ordering
--   (deliveries → timers → registrations) makes the precise minimum safe.
--
-- on_radio_busy(self, info): runtime fires this when the LBT/half-duplex
-- check defers a TX (the bytes are dropped runtime-side). The script keeps
-- a per-label tx_stash so it can re-issue the dropped frame:
--   • BCN                       → drop (periodic; next fire retries)
--   • RTS / RTS-fwd / RTS-rty   → drop (rts_timeout is the retry path)
--   • CTS / CTS-dup / DATA / ACK / K-dup → reschedule at info.busy_until_ms;
--                                  max TX_DEFER_MAX_RETRIES per slot
--
-- ============================================================================
-- Routing (K=2 with alt) + busy NACK
-- ============================================================================
--
-- Each destination carries up to two candidate routes. The protocol picks
-- a busy receiver via NACK feedback so the sender can immediately switch
-- to an alt path or wait, instead of grinding through rts_timeout retries
-- on a path we already know is blocked. Beacons unchanged on the wire —
-- alt is local-only, computed by each receiver from its own per-neighbor
-- candidate set.
--
-- Routing table:
--   rt[dest_id] = {
--     primary = { next_hop, score, hops, last_seen_ms },
--     alt     = { next_hop, score, hops, last_seen_ms },  -- or nil
--   }
--   primary.next_hop ≠ alt.next_hop (we never store both in the same slot)
--
-- DV merge (rt_merge): for each candidate cand from a beacon-sender:
--   • new dest             → cand → primary
--   • same next_hop as P   → primary refresh in place
--   • beats P              → cand → primary, previous P → alt (different hop)
--   • beats A              → cand → alt
--   • else                 → drop
-- Beacons advertise only primary (single best route per dest, as before).
--
-- Receiver-side NACK triggers (in on_recv 'R' with next == self.id):
--   1. last_acked_from[r.src] == r.msg_id  → re-ACK on routing_sf, return
--   2. pending_rx busy + same (from,msg_id) → CTS-dup, restart expiry
--   3. pending_rx busy + different sender   → NACK on data_sf, busy_for =
--      max(0, set_at + pending_rx_expiry_ms − now)
--   4. pending_tx in flight                  → NACK on data_sf, busy_for =
--      pessimistic-full-flight estimate
--   5. otherwise                              → normal RTS handling
-- NACK rides on data_sf (not routing_sf) because the sender's RX is
-- already retuned to data_sf after its RTS-tx, awaiting CTS. NACK and CTS
-- share the channel logically — they're the two possible admissions.
--
-- Sender-side NACK (on_recv 'N' matching pending_tx.msg_id):
--   • cancel rts_timeout
--   • can_try_alt = rt[dst].alt exists AND not pending_tx.alt_tried
--     → flip pending_tx.next = alt.next_hop; alt_tried=true; retries_left
--       reset to fresh budget; tx_rts_retry("nack_alt")
--   • else if busy_for_ms ≤ NACK_WAIT_THRESHOLD_MS (200 ms default)
--     → after(busy_for_ms+1, tx_rts_retry("nack_wait"))
--   • else (long wait + no alt)
--     → push pending_tx back into tx_queue; pending_tx=nil; become_free
--
-- Limitation we live with (dual-SF asymmetry):
--   When the busy node is on data_sf RX (mid-flight as receiver, after CTS-tx
--   awaiting DATA, OR mid-flight as sender, between RTS-tx and CTS-rx) an
--   incoming RTS on routing_sf lands as drop_sf_mismatch and is silently
--   discarded by the runtime. The receiver never gets the RTS, so cannot
--   NACK. NACK only helps in narrower windows: pending_tx in the post-DATA
--   ACK-wait phase (RX on routing_sf), or pending_rx after DATA-rx (very
--   short — between data_rx and pending_rx clear). For the s01 concurrent-
--   flight case where two flights overlap on data_sf, NACK doesn't fire;
--   the originator falls back to rts_timeout retries (or rts_giveup if the
--   busy window outlasts retries × rts_timeout_ms).
--
-- Composes with existing pieces:
--   • rts_timeout still fires for "no response at all" (RTS lost or NACK
--     lost) — independent of NACK path.
--   • on_radio_busy retries are still LBT-deferral-only — orthogonal.
--   • last_acked_from short-circuit fires BEFORE the NACK paths so we don't
--     NACK a sender we already acked; we re-ACK them.
--   • alt_tried clears on successful delivery (pending_tx → nil via on_recv
--     "K"); fresh send via issue_send always sets alt_tried=false.
--
-- Future tuning hooks (not yet implemented):
--   • alt freshness expiry: currently alt sticks around as long as no
--     better candidate replaces it. Stale alts (e.g., 3+ missed beacon
--     rounds) should be pruned.
--   • busy_for_ms cap on sender side — currently we trust the receiver's
--     value; a malicious / buggy receiver could announce 65 s to stall us.
--   • Beacon advertise alt too (would double beacon size; tradeoff).
--
-- ============================================================================
-- Findings & open improvements (notes for future work)
-- ============================================================================
--
-- F1. Concurrent multi-hop flights collide at shared relay nodes
--     Observed in s01 with a 15-node mesh, two concurrent 4-hop sends. When
--     the first flight (e.g. n05→n13) is mid-flight and an intermediate node
--     (e.g. n02) is on data_sf RX expecting CTS/DATA, a second flight
--     (e.g. n06→n15) routed via the same intermediate will keep losing its
--     RTS to drop_sf_mismatch — the busy node simply isn't listening on
--     routing_sf. Result: rts_giveup at the second originator after
--     rts_max_retries.
--
-- F2. Retry budget conflates two failure modes
--     rts_max_retries (default 3) is consumed by both (a) "CTS didn't come
--     back" — i.e., RTS reached but no response — and (b) on_radio_busy
--     deferrals where our own TX was held off by LBT/half-duplex. The two
--     have different timescales: (a) is a wire-level loss recovery (~CTS
--     airtime), (b) is local channel contention (~one airtime). Combining
--     them exhausts the budget quickly under load and gives rts_giveup
--     semantics on what should be a "wait a bit" condition.
--
-- F3. rts_timeout is dimensioned for one-shot RTS+CTS, not for "wait for
--     the network to free up"
--     With short SFs (SF8 routing → ~44ms RTS, SF9 data → ~78ms CTS) the
--     rts_timeout is ~122ms. Three retries cover ~366ms — much shorter
--     than a 4-hop SF9 flight (~hundreds of ms × 4 hops). When the chosen
--     next-hop is mid-relay, this budget always expires first.
--
-- I1. Separate retry budgets for the two failure modes (addresses F2)
--     • rts_max_retries (cts-timeout retries) stays bounded — a true CTS
--       loss past N retries ⇒ giveup
--     • channel_busy_max_retries (on_radio_busy retries) is independent;
--       deferral while LBT says busy is *not* a delivery failure
--     Implementation: split self.tx_stash[label].retries_left into two
--     counters, tracked per-pending_tx.
--
-- I2. Bump rts_max_retries OR scale it from estimated network round-trip
--     A useful default would scale with topology depth: e.g.,
--     rts_max_retries ≈ 2 × estimated_hops × airtime(DATA)/rts_timeout.
--     For the 15-node mesh that's ~10–15 retries. Trivial config change
--     for now; a self-tuning version is future work.
--
-- I3. NACK / busy-feedback on routing_sf (addresses F1, the core gap)
--     Today, when a node receives RTS while busy with someone else's
--     pending_rx, it emits rts_rejected_busy (script-side event only) and
--     stays silent on-air. The sender has no signal — only the absent CTS,
--     leading to rts_timeout retries on the same dead path. A small
--     "BSY" frame on routing_sf carrying the requesting msg_id would let
--     the sender immediately switch tactics: pick an alternate next-hop,
--     queue locally, or back off longer than rts_busy_retry_ms.
--     This needs (a) a second-best route in self.rt[dest] (today the table
--     stores only the primary), or (b) ACK/CTS carrying enough load info
--     for senders to make routing decisions before committing. Both are
--     real protocol-design choices — see the routing-topic block below
--     for the discussion.
--
-- I4. Drop the "if pending_rx ~= nil" rejection path in favor of a queued
--     forward-as-receiver
--     Currently rts_rejected_busy is fatal-on-air. With the script-side
--     tx_queue we already have, an RTS we can't accept now could be
--     queued (alongside pending forwards) and answered when we're free.
--     Tradeoff: extends the receiver's commitment window — its CTS may
--     come back well after the RTS, requiring much longer rts_timeout on
--     the originator side. Couples cleanly with I3's busy NACK: the
--     receiver could send "busy, try again in N ms" instead of silent.
--
-- ---------- wire format helpers (private to this file) ----------------------

-- Beacons advertise only the PRIMARY route per destination. Alts are
-- computed locally at each receiver from its own per-neighbor candidate
-- set — no need to bloat the beacon (and no protocol-level negotiation
-- about which path is "alt" anyway, that's a per-receiver judgement).
--
-- The full routing table can blow past LoRa's 255-byte frame limit on
-- networks with > ~63 destinations (3-byte header + 4 bytes per entry).
-- pack_beacon takes a `max_entries` cap and a sliding `offset`: it emits
-- a contiguous page of up to `max_entries` entries starting at `offset`
-- in a deterministic ordering of the rt[] table. The caller (beacon_fire)
-- bumps the offset every fire so successive beacons cycle through the
-- whole table. Receivers don't need to track pages — every entry they
-- hear gets merged via rt_merge as before.
local function pack_beacon(node, max_entries, offset)
  -- Deterministic ordering: sort by dest_id so successive beacons walk
  -- a stable sequence (otherwise pairs() iteration order is undefined
  -- and the rotation degenerates to "random subset" — that still works
  -- but takes longer to cover the table on average).
  local all_dests = {}
  for dest_id, _ in pairs(node.rt) do
    table.insert(all_dests, dest_id)
  end
  table.sort(all_dests)
  local total = #all_dests
  if total == 0 then
    return "B" .. string.char(node.id) .. string.char(0), 0
  end

  -- Take a contiguous page starting at offset, wrapping around.
  local n = math.min(max_entries, total)
  local page = {}
  for i = 0, n - 1 do
    local idx = ((offset + i) % total) + 1
    table.insert(page, all_dests[idx])
  end

  local out = "B" .. string.char(node.id) .. string.char(n)
  for _, dest_id in ipairs(page) do
    local p = node.rt[dest_id].primary
    local s = math.floor(p.score + 0.5)
    if s < -128 then s = -128 end
    if s >  127 then s =  127 end
    if s < 0 then s = s + 256 end  -- two's-complement byte
    out = out .. string.char(dest_id)
              .. string.char(p.next_hop)
              .. string.char(s)
              .. string.char(p.hops)
  end
  -- Return the new offset so the caller can advance for the next fire.
  return out, (offset + n) % total
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

local function pack_rts(origin, src, dst, next_hop, msg_id, sf_bitmap)
  return "R" .. string.char(origin) .. string.char(src) .. string.char(dst)
              .. string.char(next_hop)
              .. string.char(msg_id % 256)
              .. string.char(math.floor(msg_id / 256) % 256)
              .. string.char(sf_bitmap)
end

local function parse_rts(frame)
  if #frame < 8 or frame:sub(1,1) ~= "R" then return nil end
  return {
    origin    = frame:byte(2),
    src       = frame:byte(3),
    dst       = frame:byte(4),
    next      = frame:byte(5),
    msg_id    = frame:byte(6) + frame:byte(7) * 256,
    sf_bitmap = frame:byte(8),    -- bit (sf-5) = SF allowed for DATA
  }
end

-- CTS dropped the redundant src field (the rx event already gives sender
-- via radio metadata, and the originator already knows pending_tx.next).
-- In its place: chosen_data_sf, picked by the receiver from the RTS's
-- allowed-SF bitmap based on the link SNR + sf_margin_db.
local function pack_cts(msg_id, chosen_data_sf)
  return "C" .. string.char(msg_id % 256)
              .. string.char(math.floor(msg_id / 256) % 256)
              .. string.char(chosen_data_sf)
end

local function parse_cts(frame)
  if #frame < 4 or frame:sub(1,1) ~= "C" then return nil end
  return {
    msg_id         = frame:byte(2) + frame:byte(3) * 256,
    chosen_data_sf = frame:byte(4),
  }
end

local function pack_ack(msg_id)
  return "K" .. string.char(msg_id % 256)
              .. string.char(math.floor(msg_id / 256) % 256)
end

local function parse_ack(frame)
  if #frame < 3 or frame:sub(1,1) ~= "K" then return nil end
  return {
    msg_id = frame:byte(2) + frame:byte(3) * 256,
  }
end

-- NACK ('N'): receiver tells the sender "I can't accept this RTS right now,
-- I'll be free in busy_for_ms milliseconds". 16-bit relative duration is
-- clock-sync-free; 65 s is plenty for any flight estimate.
-- Application-layer header inside the DATA frame's payload bytes:
--   [seq_lo(1)] [seq_hi(1)] [user_text(N)]
-- 16-bit origin-local sequence number prepended by the ORIGINATOR. Mesh
-- layer (RTS/CTS/DATA frames) treats payload as opaque; only the script
-- (acting as the application layer) reads / writes this header. The
-- tuple (mesh's origin field, seq from this header) is the globally-
-- unique end-to-end message id used for dedup at every receiving node.
-- This is how a real firmware port works: app generates seq + text,
-- hands bytes to mesh, mesh treats opaque, app strips on receive.
local ORIGIN_SEQ_HDR_LEN = 2

local function pack_origin_seq(seq)
  return string.char(seq % 256)
              .. string.char(math.floor(seq / 256) % 256)
end

local function parse_origin_seq(payload)
  if #payload < ORIGIN_SEQ_HDR_LEN then return nil end
  return {
    seq = payload:byte(1) + payload:byte(2) * 256,
    user_text = payload:sub(ORIGIN_SEQ_HDR_LEN + 1),
  }
end

local function pack_nack(msg_id, busy_for_ms)
  if busy_for_ms < 0 then busy_for_ms = 0 end
  if busy_for_ms > 65535 then busy_for_ms = 65535 end
  return "N" .. string.char(msg_id % 256)
              .. string.char(math.floor(msg_id / 256) % 256)
              .. string.char(busy_for_ms % 256)
              .. string.char(math.floor(busy_for_ms / 256) % 256)
end

local function parse_nack(frame)
  if #frame < 5 or frame:sub(1,1) ~= "N" then return nil end
  return {
    msg_id      = frame:byte(2) + frame:byte(3) * 256,
    busy_for_ms = frame:byte(4) + frame:byte(5) * 256,
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

-- ---------- airtime + retry plumbing ----------------------------------------

-- Frame-header lengths (excluding payload). Computed from the wire-format
-- table at top of file so airtime predictions stay precise as we extend the
-- protocol — bump these if the frame layout changes.
local RTS_LEN = 8       -- 'R' + origin + src + dst + next + msg_id_lo + msg_id_hi + data_sf
local CTS_LEN = 4       -- 'C' + src + msg_id_lo + msg_id_hi
local DATA_HDR_LEN = 7  -- 'D' + origin + src + dst + next + msg_id_lo + msg_id_hi (payload follows)
local ACK_LEN = 3       -- 'K' + msg_id_lo + msg_id_hi
local NACK_LEN = 5      -- 'N' + msg_id_lo + msg_id_hi + busy_for_ms_lo + busy_for_ms_hi

-- LoRa on-air time in milliseconds (Semtech AN1200.13). This is intentionally
-- in Lua (not exposed via a runtime binding) so the same code can be ported
-- to firmware later without depending on a host helper.
--
-- Convention notes:
--   • cr is the RadioLib/MeshCore multiplier (5 = CR4/5, 8 = CR4/8). The
--     legacy AN1200.13 form uses CR ∈ [1..4] with a (CR+4) shift; we use cr
--     directly so the formula matches the C++ side post-bug-fix.
--   • DE (low data rate optimize) is auto-enabled when t_sym >= 16 ms,
--     matching SX126x recommendations. SF12 BW=125 (t_sym=32 ms) and SF12
--     BW=250 (t_sym=16.384 ms) both trip DE; SF11 BW=125 trips it as well.
--   • Result is floored to integer ms to match SimRadio's (uint32_t) cast.
local function airtime_ms(sf, bw_hz, cr, preamble_sym, len_bytes)
  local t_sym = (2 ^ sf) / (bw_hz / 1000)            -- ms per symbol
  local t_pre = (preamble_sym + 4.25) * t_sym        -- preamble + sync
  local de    = (t_sym >= 16) and 1 or 0
  local num   = 8 * len_bytes - 4 * sf + 44
  local den   = 4 * (sf - 2 * de)
  local pay_sym = 8 + math.max(math.ceil(num / den) * cr, 0)
  return math.floor(t_pre + pay_sym * t_sym)
end

-- Semtech AN1200.22 demodulator SNR floors per SF (CR4/5). Each SF step
-- buys ~2.5 dB of sensitivity at the cost of 2× symbol time. SF5/SF6 extend
-- the linear pattern at the high-data-rate end. Mirrors the C++
-- SimRadio::getSnrThreshold table so script and runtime agree on what
-- "decodable" means.
local SF_DEMOD_THRESHOLD = {
  [5]  =  -2.5, [6]  =  -5.0, [7]  =  -7.5, [8]  = -10.0,
  [9]  = -12.5, [10] = -15.0, [11] = -17.5, [12] = -20.0,
}

-- Bitmap helpers. bit (sf-5) of `bm` = SF acceptable for the DATA leg.
local function sf_set_to_bitmap(sf_set)
  local bm = 0
  for _, sf in ipairs(sf_set) do
    if sf >= 5 and sf <= 12 then
      bm = bm | (1 << (sf - 5))
    end
  end
  return bm
end

local function sf_in_bitmap(bm, sf)
  if sf < 5 or sf > 12 then return false end
  return ((bm >> (sf - 5)) & 1) == 1
end

-- Choose the fastest (lowest) SF in the bitmap whose demod threshold leaves
-- at least `margin_db` of headroom against the measured link SNR. Falls
-- back to the most-robust (highest) allowed SF if nothing meets the
-- margin — the link is borderline but we still try. Returns nil only on
-- empty bitmap (caller should reject the RTS).
local function select_data_sf(rx_snr_db, sf_bitmap, margin_db)
  -- Ascending pass: prefer fastest SF that has the SNR headroom.
  for sf = 5, 12 do
    if sf_in_bitmap(sf_bitmap, sf) and
       rx_snr_db >= SF_DEMOD_THRESHOLD[sf] + margin_db then
      return sf
    end
  end
  -- Descending pass: nothing meets margin; pick most-robust available SF.
  for sf = 12, 5, -1 do
    if sf_in_bitmap(sf_bitmap, sf) then
      return sf
    end
  end
  return nil   -- empty bitmap
end

-- Labels eligible for on_radio_busy retry. BCN is periodic — the next
-- beacon-fire will retry naturally, no point re-queuing. RTS-class frames
-- have their own rts_timeout retry path; running on_radio_busy retries on
-- top would race the timeout. Only the receiver-side / DATA labels (where
-- there is no other recovery mechanism) get rescheduled.
local RETRY_ELIGIBLE = {
  ["CTS"]     = true,
  ["CTS-dup"] = true,
  ["DATA"]    = true,
  ["ACK"]     = true,
  ["K-dup"]   = true,
  ["NACK"]    = true,
}
local TX_DEFER_MAX_RETRIES = 3

-- Exponential backoff cap on rts_timeout. The timeout doubles per retry
-- attempt and saturates at this multiple of the base. With s01's
-- SF8 base (~122 ms) the timeouts walk 122, 244, 488, 488, ... covering
-- ~3.3 s across rts_max_retries=8 — well past the ~250 ms blind window
-- for SF9 data and the ~1.5 s worst case for SF12 data.
local RTS_TIMEOUT_BACKOFF_CAP = 4

local function rts_timeout_for_attempt(base_ms, attempt_idx)
  local mult = 1
  for _ = 1, attempt_idx do
    mult = mult * 2
    if mult >= RTS_TIMEOUT_BACKOFF_CAP then
      mult = RTS_TIMEOUT_BACKOFF_CAP
      break
    end
  end
  return base_ms * mult
end

-- F1 mitigation: blind_until tracks when each 1-hop neighbour will
-- finish its data_sf RX window (deaf on routing_sf). Populated by
-- overhearing CTS frames; consulted before issuing or retrying RTS.
-- Returns (is_blind: bool, remaining_ms: int). Opportunistically prunes
-- expired entries so the table stays bounded.
local function is_blind(self, node_id)
  local until_ms = self.blind_until[node_id]
  if until_ms == nil then return false, 0 end
  local now = self:now()
  if until_ms <= now then
    self.blind_until[node_id] = nil
    return false, 0
  end
  return true, until_ms - now
end

-- Decision helper used at issue_send / tx_rts_retry / rts_timeout_fire.
-- Returns one of:
--   "ok"                -- proceed with current next_hop
--   "alt", new_next_hop -- caller should switch to alt route + re-tx
--   "defer", delay_ms   -- caller should re-schedule after delay_ms
local function classify_blind(self, dst_id, current_next_hop, alt_already_tried)
  local blind, remaining = is_blind(self, current_next_hop)
  if not blind then return "ok" end
  local entry = self.rt[dst_id]
  local alt = entry and entry.alt or nil
  if alt and (not alt_already_tried) and (not is_blind(self, alt.next_hop)) then
    return "alt", alt.next_hop
  end
  return "defer", remaining + 1
end

-- Stash + send. Saves the frame so on_radio_busy can re-issue it after
-- info.busy_until_ms (the runtime drops the deferred PendingTx — see
-- SimController defer sites). Stash is keyed by label so concurrent
-- distinct-label flights don't overwrite each other.
local function tx_with_retry(self, bytes, opts)
  local label = opts.label or ""
  if RETRY_ELIGIBLE[label] then
    self.tx_stash[label] = {
      bytes        = bytes,
      opts         = opts,
      retries_left = TX_DEFER_MAX_RETRIES,
    }
  end
  self:tx(bytes, opts)
end

-- ---------- routing helpers --------------------------------------------------

local function rt_count(rt)
  local c = 0
  for _ in pairs(rt) do c = c + 1 end
  return c
end

-- Strict-better comparison on routes: higher score wins; on ties, fewer
-- hops wins; on full tie, returns false (caller decides). Used by rt_merge
-- to decide promote vs alt-install.
local function route_strictly_better(a, b)
  if a.score > b.score then return true end
  if a.score < b.score then return false end
  return a.hops < b.hops
end

-- K=2 DV merge. Caller has already filtered cand for hop-cap and
-- split-horizon. Returns one of:
--   "new"             — first route to this destination (cand → primary)
--   "promote"         — cand beats existing primary; previous primary
--                        becomes alt (only if next_hop differs)
--   "primary_refresh" — cand has same next_hop as primary and is better;
--                        primary's score/hops/last_seen updated in place
--   "alt_install"     — cand beats existing alt (or there was none) and
--                        differs from primary's next_hop; cand → alt
--   "no_change"       — cand can't displace anything
local function rt_merge(rt, dest_id, cand)
  local entry = rt[dest_id]
  if entry == nil then
    rt[dest_id] = { primary = cand, alt = nil }
    return "new"
  end

  local P = entry.primary
  if cand.next_hop == P.next_hop then
    -- Same next-hop: refresh primary if cand is better. We don't bother
    -- demoting a "stale primary" to alt in this case — it'd be a
    -- same-next_hop alt, which is redundant.
    if route_strictly_better(cand, P) then
      entry.primary = cand
      return "primary_refresh"
    end
    -- Even on equal score/hops, refresh last_seen_ms + n2_hop so age-out
    -- works and the loop-prune sees the neighbor's most recent claim.
    P.last_seen_ms = cand.last_seen_ms
    P.n2_hop       = cand.n2_hop
    return "no_change"
  end

  -- Different next-hop than primary
  if route_strictly_better(cand, P) then
    entry.alt     = P     -- demote previous primary (next_hop differs by branch)
    entry.primary = cand
    return "promote"
  end

  -- cand can't beat primary. Try as alt (must differ from primary's next_hop,
  -- which it does by branch).
  local A = entry.alt
  if A == nil or route_strictly_better(cand, A) then
    entry.alt = cand
    return "alt_install"
  end
  if A.next_hop == cand.next_hop then
    -- Same alt next_hop, refresh last_seen + n2_hop (see primary path).
    A.last_seen_ms = cand.last_seen_ms
    A.n2_hop       = cand.n2_hop
  end
  return "no_change"
end

local function maybe_emit_rt_full(self)
  if self.rt_full_emitted then return end
  if rt_count(self.rt) >= self.peer_count then
    self:emit("rt_full", { peers = self.peer_count })
    self:log(string.format("rt_full: %d peers known, table converged", self.peer_count))
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

-- Human-readable id resolver for log lines. Falls back to "#N" if a frame
-- somehow carries an id we don't have a name for (shouldn't happen in
-- well-formed scenarios but keeps logs from blowing up).
local function name_of(self, id)
  return self.id_to_name[id] or ("#" .. tostring(id))
end

-- Forward decl: rt_prune_cycle calls schedule_triggered_beacon (defined
-- below alongside beacon_fire) so a cycle-busting prune propagates within
-- ~hundreds of ms instead of waiting for the next periodic beacon.
local schedule_triggered_beacon

-- 3-cycle prune: when a beacon entry says (D, next=self.id), the sender N
-- claims to route D through me. If any of my own rt[D] slots stores
-- n2_hop == N, that slot is part of a 3-cycle me→X→N→me — invalidate it.
-- Collapses primary↔alt afterwards: if alt survives, it's promoted; if
-- both die, the entry is removed entirely (no route is better than a
-- looped one — packets give up at source instead of wasting airtime).
-- On any actual mutation, schedule a triggered beacon so neighbors
-- discover the change quickly.
local function rt_prune_cycle(self, dest_id, sender_id)
  local entry = self.rt[dest_id]
  if entry == nil then return end
  local mutated = false

  if entry.primary and entry.primary.n2_hop == sender_id then
    self:emit("rt_prune", {
      dest = dest_id, slot = "primary", reason = "3cycle",
      via = entry.primary.next_hop, n2 = sender_id,
    })
    self:log(string.format("rt[%s] primary pruned (3cycle via %s→%s)",
      name_of(self, dest_id),
      name_of(self, entry.primary.next_hop), name_of(self, sender_id)))
    entry.primary = nil
    mutated = true
  end
  if entry.alt and entry.alt.n2_hop == sender_id then
    self:emit("rt_prune", {
      dest = dest_id, slot = "alt", reason = "3cycle",
      via = entry.alt.next_hop, n2 = sender_id,
    })
    self:log(string.format("rt[%s] alt pruned (3cycle via %s→%s)",
      name_of(self, dest_id),
      name_of(self, entry.alt.next_hop), name_of(self, sender_id)))
    entry.alt = nil
    mutated = true
  end

  if entry.primary == nil and entry.alt ~= nil then
    entry.primary = entry.alt
    entry.alt = nil
  end
  if entry.primary == nil then
    self.rt[dest_id] = nil
  end

  if mutated then schedule_triggered_beacon(self) end
end

-- Forward decls so the timeout-fire callbacks can refer to peers in the
-- retry/queue cluster (Lua needs the local in scope first).
local start_rts_timeout
local start_ack_timeout
local start_pending_rx_expiry
local issue_send
local become_free

-- Re-send the current pending_tx's RTS with the same msg_id. Shared by
-- rts_timeout_fire (CTS lost) and ack_timeout_fire (DATA-ACK lost): both
-- recover by re-running the dance from the beginning. Caller must have
-- already decremented retries_left and confirmed the giveup case.
local function tx_rts_retry(self, reason)
  local px = self.pending_tx
  local rts = pack_rts(px.origin, self.id, px.dst, px.next, px.msg_id,
                       self.allowed_sf_bitmap)
  self:emit("rts_retry", {
    origin = px.origin, payload = px.user_text, origin_seq = px.origin_seq,
    dst = px.dst, next = px.next,
    msg_id = px.msg_id, retries_left = px.retries_left, reason = reason,
  })
  self:log(string.format("rts_retry -> %s msg_id=%d (retries_left=%d reason=%s)",
    name_of(self, px.next), px.msg_id, px.retries_left, reason))
  self:tx(rts, {
    sf    = self.routing_sf,
    label = "RTS-rty",
    info  = string.format("retry next=%s msg=%d retries_left=%d reason=%s",
      name_of(self, px.next), px.msg_id, px.retries_left, reason),
  })
  -- RX stays on routing_sf — both CTS and NACK are control-plane responses
  -- on routing_sf now, no retune needed until DATA is about to TX.
  start_rts_timeout(self)
end

-- Fires after rts_timeout_ms with no CTS. Decides retry vs giveup vs
-- defer (when busy as receiver of someone else's data).
local function rts_timeout_fire(self, captured_msg_id)
  if self.pending_tx == nil then return end
  if self.pending_tx.msg_id ~= captured_msg_id then return end

  if self.pending_rx ~= nil then
    self:log(string.format("rts_retry_deferred (busy as receiver) msg=%d",
      captured_msg_id))
    self:after(self.rts_busy_retry_ms, function()
      rts_timeout_fire(self, captured_msg_id)
    end)
    return
  end

  if self.pending_tx.retries_left <= 0 then
    self:emit("rts_giveup", {
      origin     = self.pending_tx.origin,
      payload    = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      dst        = self.pending_tx.dst,
      next       = self.pending_tx.next,
      msg_id     = captured_msg_id,
    })
    self:log(string.format("rts_giveup msg=%d (max retries exhausted, dst=%s)",
      captured_msg_id, name_of(self, self.pending_tx.dst)))
    self.pending_tx = nil
    become_free(self)
    return
  end

  self.pending_tx.retries_left = self.pending_tx.retries_left - 1
  tx_rts_retry(self, "cts_timeout")
  -- (rts_retry emit happens inside tx_rts_retry — adds origin/payload there)
end

-- Fires after ack_timeout_ms with no DATA-ACK. The DATA was likely lost
-- in flight (collision, drop_weak, etc.). Recover by re-running the dance
-- from RTS — receiver's pending_rx may still be alive (its expiry covers
-- the whole DATA airtime + cts_to_data_gap), in which case the duplicate
-- RTS is detected as rts_rx_dup and a fresh CTS comes back; if the
-- receiver expired and cleared, our duplicate-RTS dedup re-ACKs from
-- last_acked_from cache (or a fresh dance starts cleanly).
local function ack_timeout_fire(self, captured_msg_id)
  if self.pending_tx == nil then return end
  if self.pending_tx.msg_id ~= captured_msg_id then return end

  if self.pending_rx ~= nil then
    -- Mid-RX of someone else's flight; defer briefly.
    self:log(string.format("ack_retry_deferred (busy as receiver) msg=%d",
      captured_msg_id))
    self:after(self.rts_busy_retry_ms, function()
      ack_timeout_fire(self, captured_msg_id)
    end)
    return
  end

  if self.pending_tx.retries_left <= 0 then
    self:emit("data_ack_giveup", {
      origin     = self.pending_tx.origin,
      payload    = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      dst        = self.pending_tx.dst,
      next       = self.pending_tx.next,
      msg_id     = captured_msg_id,
    })
    self:log(string.format("data_ack_giveup msg=%d (max retries exhausted, dst=%s)",
      captured_msg_id, name_of(self, self.pending_tx.dst)))
    self.pending_tx = nil
    become_free(self)
    return
  end

  self.pending_tx.retries_left = self.pending_tx.retries_left - 1
  tx_rts_retry(self, "ack_timeout")
end

-- Schedule a CTS-wait timeout for the currently in-flight pending_tx.
-- Cancels any prior handle so RTS-rty doesn't pile up multiple concurrent
-- timers, and so on_recv "C" can cancel cleanly the moment the CTS is
-- matched (without cancellation the timer fires on the same tick the CTS
-- arrives — rts_timeout_ms is the precise minimum — and triggers a
-- spurious retry before pending_tx clears via the cts-to-data-gap path).
start_rts_timeout = function(self)
  if not self.pending_tx then return end
  if self.rts_timeout_handle then
    self:cancel(self.rts_timeout_handle)
    self.rts_timeout_handle = nil
  end
  local captured_msg_id = self.pending_tx.msg_id
  self.rts_timeout_handle = self:after(self.rts_timeout_ms, function()
    self.rts_timeout_handle = nil
    rts_timeout_fire(self, captured_msg_id)
  end)
end

-- Schedule a DATA-ACK wait. Cancelled by on_recv "K" on a matching ACK.
-- Called inside the cts_to_data_gap after-callback right after self:tx
-- queues the DATA, so "now" for the timer is the moment DATA hits the
-- PendingTx queue. The wire timeline that follows is:
--   now ──[airtime(data_sf, DATA)]── DATA tx-end
--       ──[airtime(routing_sf, ACK)]── ACK arrives at sender
-- so the precise wait is data_air + ack_air. No pad: step ordering
-- (deliveries → timers) means the on_recv "K" fires before the timer
-- when both land on the same tick.
start_ack_timeout = function(self)
  if not self.pending_tx then return end
  if not self.pending_tx.chosen_data_sf then return end  -- DATA hasn't gone out yet
  if self.ack_timeout_handle then
    self:cancel(self.ack_timeout_handle)
    self.ack_timeout_handle = nil
  end
  local data_air = airtime_ms(self.pending_tx.chosen_data_sf, self.bw_hz, self.cr,
                              self.preamble_sym,
                              DATA_HDR_LEN + #self.pending_tx.payload)
  local delay = data_air + self.ack_air_ms
  local captured_msg_id = self.pending_tx.msg_id
  self.ack_timeout_handle = self:after(delay, function()
    self.ack_timeout_handle = nil
    ack_timeout_fire(self, captured_msg_id)
  end)
end

-- Receiver-side: if DATA never arrives after we sent CTS, clear pending_rx
-- so future flights through us can proceed. Without this, a single lost
-- DATA freezes the receiver permanently.
local function pending_rx_expiry_fire(self, captured_msg_id)
  if self.pending_rx == nil then return end
  if self.pending_rx.msg_id ~= captured_msg_id then return end
  self:emit("data_rx_timeout", {
    origin = self.pending_rx.origin,
    -- payload + origin_seq unknown — DATA never arrived
    from = self.pending_rx.from, msg_id = captured_msg_id,
  })
  self:log(string.format("data_rx_timeout from=%s msg_id=%d -> clearing pending_rx",
    name_of(self, self.pending_rx.from), captured_msg_id))
  self:set_rx_sf(self.routing_sf)
  self.pending_rx = nil
  become_free(self)
end

-- Per-flight expiry: from "we received the RTS" to "we should have heard
-- DATA by now", the wire timeline is:
--   T₀ ──[airtime(routing_sf, CTS)]── CTS tx-end (sender now hears CTS)
--      ──[cts_to_data_gap_ms]── sender starts DATA tx
--      ──[airtime(chosen_sf, max DATA)]── DATA tx-end (we receive it)
-- Sum of all three is the upper bound on how long pending_rx may
-- legitimately sit unfilled. Earlier code used only the last two terms
-- and the worst-case "slowest allowed SF" — which made the timer fire
-- ~CTS-airtime ms before the DATA could possibly arrive whenever the
-- chosen SF was the slowest one. Now we use the per-flight chosen_sf
-- and include the CTS airtime explicitly.
start_pending_rx_expiry = function(self)
  if not self.pending_rx then return end
  if self.pending_rx_expiry_handle then
    self:cancel(self.pending_rx_expiry_handle)
    self.pending_rx_expiry_handle = nil
  end
  local chosen = self.pending_rx.chosen_data_sf
  local cts_air = airtime_ms(self.routing_sf, self.bw_hz, self.cr,
                              self.preamble_sym, CTS_LEN)
  local max_data_air = airtime_ms(chosen, self.bw_hz, self.cr,
                                    self.preamble_sym,
                                    DATA_HDR_LEN + self.max_payload_bytes)
  local expiry_ms = cts_air + self.cts_to_data_gap_ms + max_data_air
  self.pending_rx.expiry_ms = expiry_ms   -- stash for NACK busy_for_ms calc
  local captured_msg_id = self.pending_rx.msg_id
  self.pending_rx_expiry_handle = self:after(expiry_ms, function()
    self.pending_rx_expiry_handle = nil
    pending_rx_expiry_fire(self, captured_msg_id)
  end)
end

-- Issue a send (originating or forwarding). Caller has already verified
-- we're free (pending_tx and pending_rx both nil). The `origin` arg is
-- kept verbatim across hops — at the originator hop origin == self.id,
-- at every forwarder hop origin is the original sender's id from the
-- inbound DATA. Both paths use exactly the same RTS frame, so this
-- function unifies what was previously duplicated between on_command and
-- the on_recv "D" forward branch.
-- payload here is the FULL bytes (origin-seq header + user_text) — what
-- goes on the wire. user_text is what the user / visualizer sees in
-- emit data. origin_seq is the 16-bit per-origin counter (set at
-- on_command for new sends, preserved across forwards).
issue_send = function(self, origin, dst_id, dst_name, payload, user_text, origin_seq)
  local entry = self.rt[dst_id]
  if not entry then
    self:emit("send_no_route", {
      origin = origin, payload = user_text, origin_seq = origin_seq, dst = dst_id,
    })
    self:log(string.format("send_no_route dst=%s (queue drain skipped this entry)",
      dst_name))
    return
  end
  local primary_next = entry.primary.next_hop
  local mid = gen_msg_id(self)
  self.pending_tx = {
    origin       = origin,
    dst          = dst_id,
    next         = primary_next,
    msg_id       = mid,
    payload      = payload,        -- full bytes (origin-seq hdr + user_text)
    user_text    = user_text,      -- for emit + log clarity
    origin_seq   = origin_seq,     -- end-to-end message id (with origin)
    retries_left = self.rts_max_retries,
    alt_tried    = false,        -- on_recv "N" flips this when we move to alt
    chosen_data_sf = nil,        -- set when CTS arrives carrying the receiver's pick
  }
  local rts = pack_rts(origin, self.id, dst_id, primary_next, mid,
                       self.allowed_sf_bitmap)
  local label = (origin == self.id) and "RTS" or "RTS-fwd"
  self:emit("rts_tx", {
    origin = origin, payload = user_text, origin_seq = origin_seq,
    dst = dst_id, next = primary_next, msg_id = mid,
    sf_bitmap = self.allowed_sf_bitmap,
  })
  self:log(string.format("rts_tx -> %s msg_id=%d origin=%s seq=%d (sf_bitmap=0x%02x)",
    name_of(self, primary_next), mid, name_of(self, origin), origin_seq,
    self.allowed_sf_bitmap))
  self:tx(rts, {
    sf    = self.routing_sf,
    label = label,
    info  = string.format("origin=%s dst=%s next=%s msg=%d seq=%d sf_bitmap=0x%02x payload=%q",
      name_of(self, origin), dst_name, name_of(self, primary_next),
      mid, origin_seq, self.allowed_sf_bitmap, user_text),
  })
  -- RX stays on routing_sf — CTS and NACK both ride on routing_sf now.
  start_rts_timeout(self)
end

-- Drain one queued send if we're free. Called at every state-cleanup
-- point: ack_rx, ack_timeout giveup, rts_timeout giveup, on_recv "D"
-- delivered branch, pending_rx_expiry. Forwarders don't drain because
-- forwarding sets pending_tx synchronously in the same handler.
become_free = function(self)
  if self.pending_tx ~= nil or self.pending_rx ~= nil then return end
  if #self.tx_queue == 0 then return end
  local item = table.remove(self.tx_queue, 1)
  self:emit("tx_dequeue", {
    origin = item.origin, payload = item.user_text, origin_seq = item.origin_seq,
    dst = item.dst_id, depth = #self.tx_queue,
  })
  issue_send(self, item.origin, item.dst_id, item.dst_name,
             item.payload, item.user_text, item.origin_seq)
end

-- ---------- script lifecycle ------------------------------------------------

-- Shared core: send a single beacon page. Skipped (returns false) if the
-- node is in a data exchange — half-duplex radio means a TX would clobber
-- pending RX of CTS/DATA/ACK. Used by both periodic and triggered fires.
local function send_beacon_page(self, kind)
  if self.pending_tx ~= nil or self.pending_rx ~= nil then
    self:log(string.format("beacon_tx skipped (busy in data exchange) kind=%s", kind))
    return false
  end
  local frame, new_offset = pack_beacon(self,
                                        self.beacon_max_entries,
                                        self.beacon_offset)
  local total = rt_count(self.rt)
  local page_n = frame:byte(3)    -- entries in this page
  self:emit("beacon_tx", {
    n_entries = page_n, rt_total = total,
    offset = self.beacon_offset, next_offset = new_offset,
    kind = kind,
  })
  self:log(string.format("beacon_tx kind=%s page=%d/%d offset %d→%d",
    kind, page_n, total, self.beacon_offset, new_offset))
  self.beacon_offset = new_offset
  self:tx(frame, {
    sf    = self.routing_sf,
    label = "BCN",
    info  = string.format("rt=%d/%d off=%d kind=%s", page_n, total, self.beacon_offset, kind),
  })
  return true
end

local function beacon_fire(self)
  send_beacon_page(self, "periodic")
  -- Pick a period: fast learning-phase rate during warmup, slow
  -- operational rate afterwards. Crossover happens at sim time
  -- self.warmup_ms — once we're past it, every subsequent beacon is
  -- spaced minutes apart instead of seconds, matching how real mesh
  -- networks operate. In real deployment the operational period is
  -- 30+ minutes; convergence after that point relies on triggered
  -- updates (see schedule_triggered_beacon), not on the periodic timer.
  -- ±20% jitter on top, same as before, to avoid phase-lock between
  -- nodes that booted at the same time.
  local period = (self:now() < self.warmup_ms)
                 and self.beacon_period_warmup_ms
                 or  self.beacon_period_ms
  local lo = period * 4 // 5
  local hi = period * 6 // 5
  self:after(self:rand(lo, hi + 1), function() beacon_fire(self) end)
end

-- Triggered beacon: schedule a one-shot beacon within
-- [trigger_jitter_min_ms, trigger_jitter_max_ms]. Called whenever the
-- routing table changes meaningfully (new entry, primary promote, or a
-- 3-cycle prune). Coalesces: if a trigger is already armed, subsequent
-- triggers are no-ops — the first scheduled fire carries whatever state
-- has accumulated in the meantime. Periodic beacons keep their own
-- independent schedule; triggered fires don't reset it.
schedule_triggered_beacon = function(self)
  if self.triggered_beacon_pending then return end
  self.triggered_beacon_pending = true
  local lo = self.beacon_trigger_jitter_min_ms or 50
  local hi = self.beacon_trigger_jitter_max_ms or 500
  self:after(self:rand(lo, hi + 1), function()
    self.triggered_beacon_pending = false
    send_beacon_page(self, "triggered")
  end)
end

function on_init(self, config)
  self.routing_sf       = config.routing_sf      or 7
  -- Per-flight DATA SF is now negotiated via the RTS bitmap → CTS choice.
  -- self.allowed_data_sfs is the list this node will offer when ORIGINATING
  -- or FORWARDING; receivers pick from it based on link SNR + margin.
  -- Default keeps old single-SF behaviour by listing one SF.
  self.allowed_data_sfs = config.allowed_data_sfs or { 12 }
  self.sf_margin_db     = config.sf_margin_db    or 5.0
  self.allowed_sf_bitmap = sf_set_to_bitmap(self.allowed_data_sfs)
  -- Two beacon periods: a fast one used during warmup so the network
  -- learns its routes quickly (in real LoRa deployment this represents
  -- the early hours of network bring-up — we compress that here), and a
  -- much slower one for steady-state operation. The runtime injects
  -- _sim_warmup_ms into config so we know when to switch. Without
  -- _sim_warmup_ms (older scenarios or non-lus harnesses) we just stay
  -- at the operational rate.
  self.beacon_period_warmup_ms = config.beacon_period_warmup_ms or 5000
  self.beacon_period_ms        = config.beacon_period_ms        or 300000
  self.warmup_ms               = config._sim_warmup_ms          or 0
  -- Triggered beacons: fire a one-shot re-beacon ~hundreds of ms after any
  -- meaningful rt mutation (new entry, primary promote, 3-cycle prune) so
  -- routing changes propagate within the data plane's reaction window
  -- instead of waiting for the next periodic beacon (5 min in this sim,
  -- 30+ min in real deployment). Jitter [min,max] ms picks a random fire
  -- delay per trigger; coalesced — at most one trigger armed at a time.
  self.beacon_trigger_jitter_min_ms = config.beacon_trigger_jitter_min_ms or 50
  self.beacon_trigger_jitter_max_ms = config.beacon_trigger_jitter_max_ms or 500
  self.triggered_beacon_pending     = false
  -- Cap the size of each beacon to fit in a single LoRa frame. Header
  -- is 3 bytes ('B' + src + n), each entry is 4 bytes — so for the
  -- 255-byte LoRa max, (255-3)/4 = 63 entries fits theoretically. We
  -- default to 200 bytes (≈ 49 entries) to leave headroom for any
  -- future header growth and to stay well under the wire limit. Networks
  -- with more nodes than max_entries get a rotating page each fire,
  -- driven by self.beacon_offset; rt_merge at receivers fills in entries
  -- as it hears them across rounds.
  self.beacon_max_bytes   = config.beacon_max_bytes   or 200
  self.beacon_max_entries = math.max(1,
    math.floor((self.beacon_max_bytes - 3) / 4))
  -- Radio params for airtime calculation. Defaults match the simulator's
  -- runtime defaults (250 kHz, CR4/5, 16-symbol preamble — same as
  -- MeshCore SX1262 init). Override per-node via config block when needed.
  self.bw_hz            = config.bw_hz           or 250000
  self.cr               = config.cr              or 5
  self.preamble_sym     = config.preamble_sym    or 16
  -- Inter-frame gap between CTS RX and DATA TX (originator side). The
  -- simulator's set_rx_sf is instantaneous, but real hardware needs a
  -- handful of µs to settle on the new SF — pad with 5ms by default.
  self.cts_to_data_gap_ms = config.cts_to_data_gap_ms or 5
  -- RTS retry policy. rts_timeout_ms is the precise minimum for a CTS to
  -- arrive: airtime(routing_sf, RTS) + airtime(routing_sf, CTS) — both
  -- frames now ride on routing_sf. Step ordering (deliveries → timers →
  -- registrations) means a CTS landing on the same tick as the timeout
  -- still clears pending_tx before the timer fires; no safety margin
  -- needed. Override via config for stress tests.
  -- rts_busy_retry_ms is used when our retry timer fires while we're mid-RX
  -- of someone else's flight (pending_rx set) — short reschedule rather
  -- than TX over their incoming data plane.
  self.rts_timeout_ms = config.rts_timeout_ms or
    (airtime_ms(self.routing_sf, self.bw_hz, self.cr, self.preamble_sym, RTS_LEN)
     + airtime_ms(self.routing_sf, self.bw_hz, self.cr, self.preamble_sym, CTS_LEN))
  self.rts_busy_retry_ms  = config.rts_busy_retry_ms  or 30
  self.rts_max_retries    = config.rts_max_retries    or 8
  -- Maximum payload byte length the protocol carries; sets pending_rx_expiry
  -- (we don't know the actual payload yet, so we budget the max). Tighten in
  -- config if you've capped your payloads, loosen if you allow longer ones.
  self.max_payload_bytes  = config.max_payload_bytes  or 50
  -- Per-hop DATA-ACK on routing_sf. The timer is set at DATA-queue time
  -- (inside the cts_to_data_gap after-callback) so it must cover the full
  -- DATA airtime + ACK airtime. start_ack_timeout computes the exact
  -- delay from the actual payload length AND chosen DATA SF when it
  -- fires; ack_air_ms is the ACK frame's own airtime on routing_sf.
  self.ack_air_ms = airtime_ms(self.routing_sf, self.bw_hz, self.cr,
                                self.preamble_sym, ACK_LEN)
  -- Receiver gives up on a DATA that never arrives after this much sim
  -- time post-CTS-tx: cts_to_data_gap (sender's wait) + airtime(slowest
  -- allowed data SF, max DATA frame) — pessimistic upper bound. Without
  -- expiry, a single lost DATA freezes the receiver's pending_rx slot.
  -- The actual expiry is computed per-flight in start_pending_rx_expiry
  -- using the chosen_data_sf for that flight (set during on_recv "R"
  -- when we picked the SF). on_init still computes a worst-case bound
  -- below for the init log + for NACK busy_for_ms estimation when we
  -- don't have a specific flight context.
  local slowest_sf = self.allowed_data_sfs[1] or 12
  for _, sf in ipairs(self.allowed_data_sfs) do
    if sf > slowest_sf then slowest_sf = sf end
  end
  local cts_air = airtime_ms(self.routing_sf, self.bw_hz, self.cr,
                              self.preamble_sym, CTS_LEN)
  self.pending_rx_expiry_max_ms = cts_air + self.cts_to_data_gap_ms +
    airtime_ms(slowest_sf, self.bw_hz, self.cr, self.preamble_sym,
               DATA_HDR_LEN + self.max_payload_bytes)

  self.rt              = {}
  self.next_msg_id     = 1
  self.pending_tx      = nil
  self.pending_rx      = nil
  self.rt_full_emitted = false
  self.tx_stash         = {}    -- label → {bytes, opts, retries_left} for on_radio_busy
  self.blind_until      = {}    -- {node_id → absolute_ms} for F1 mitigation
  self.rts_timeout_handle      = nil  -- so on_recv "C" can cancel
  self.ack_timeout_handle      = nil  -- so on_recv "K" can cancel
  self.pending_rx_expiry_handle = nil  -- so on_recv "D" can cancel
  self.tx_queue          = {}   -- queued user sends, drained at every "free" point
  self.last_acked_from   = {}   -- {sender_id: msg_id} for RTS-retry dedup after we already acked
  self.beacon_offset     = 0    -- sliding page offset for bounded beacons
  -- Origin-level dedup. Every node that receives DATA records the
  -- (origin_id, origin_seq) tuple and rejects subsequent arrivals of the
  -- same id (after still ACKing the previous hop, so it clears its
  -- pending_tx). This catches routing loops + legitimate same-payload
  -- retransmissions in real firmware. TTL is generous (30s default)
  -- because a flight at SF10 can take a few seconds with retries.
  self.seen_origins       = {}
  self.seen_origin_ttl_ms = config.seen_origin_ttl_ms or 30000
  self.next_origin_seq    = 1   -- 16-bit per-origin counter for new sends

  self.name_to_id = {}
  self.id_to_name = {}
  local nodes = sim:nodes()
  for _, n in ipairs(nodes) do
    self.name_to_id[n.name] = n.id
    self.id_to_name[n.id]   = n.name
  end
  self.peer_count = #nodes - 1

  -- Build a human-readable list of allowed data SFs for the init log.
  local sf_list_str = table.concat(self.allowed_data_sfs, ",")
  self:log(string.format(
    "init: id=%d (%s) routing_sf=%d allowed_data_sfs=[%s] (bitmap=0x%02x) "
    .. "sf_margin=%.1fdB period=%dms peers=%d "
    .. "(airtime: RTS=%dms CTS=%dms ACK=%dms all@SF%d, "
    .. "rts_timeout=%dms pending_rx_expiry=%dms)",
    self.id, self.name, self.routing_sf, sf_list_str, self.allowed_sf_bitmap,
    self.sf_margin_db, self.beacon_period_ms, self.peer_count,
    airtime_ms(self.routing_sf, self.bw_hz, self.cr, self.preamble_sym, RTS_LEN),
    airtime_ms(self.routing_sf, self.bw_hz, self.cr, self.preamble_sym, CTS_LEN),
    self.ack_air_ms, self.routing_sf,
    self.rts_timeout_ms, self.pending_rx_expiry_max_ms))

  -- Random first-fire offset within one period — spreads the first
  -- round of beacons so they don't all hit the air on the same step.
  -- Use the warmup-rate period for the first beacon so we don't end up
  -- waiting up to 5 minutes for a node to first announce itself.
  local first_period = (self:now() < self.warmup_ms)
                       and self.beacon_period_warmup_ms
                       or  self.beacon_period_ms
  self:after(self:rand(0, first_period), function() beacon_fire(self) end)
end

function on_recv(self, frame, meta)
  if #frame == 0 then return end
  local tag = frame:sub(1, 1)

  if tag == "B" then
    local b = parse_beacon(frame)
    if not b then return end
    self:emit("beacon_rx", { src = b.src, n_entries = #b.entries })

    local now = self:now()

    -- Track whether anything in our rt actually changed during this beacon
    -- so we can fire a single triggered re-beacon at the end (one trigger
    -- per beacon RX, not one per entry — coalesced anyway, but cheaper).
    local rt_changed = false

    -- Direct entry: candidate is via the beacon-sender at hops=1, score=rx_snr.
    -- rt_merge handles whether this becomes primary, alt, or no-change. We
    -- log only when something interesting changed (new or promotion to
    -- primary) to avoid spamming on every refresh round.
    do
      local cand = { next_hop = b.src, score = meta.snr, hops = 1, last_seen_ms = now }
      local action = rt_merge(self.rt, b.src, cand)
      if action == "new" or action == "promote" then
        self:emit("rt_update", { dest = b.src, next = b.src, score = meta.snr, hops = 1, slot = "primary" })
        self:log(string.format("rt[%s] direct → primary, snr=%.1f dB hops=1",
          name_of(self, b.src), meta.snr))
        rt_changed = true
      elseif action == "alt_install" then
        self:emit("rt_update", { dest = b.src, next = b.src, score = meta.snr, hops = 1, slot = "alt" })
      end
    end

    -- DV merge: each entry in the beacon (other than self / our split-horizon)
    -- is a candidate route via the beacon-sender. K=2 rt_merge slots it as
    -- primary, alt, or drops it.
    for _, e in ipairs(b.entries) do
      if e.dest == self.id then
        -- nothing: split horizon, beacon-sender's view of how to reach me
        -- isn't a route I install for myself.
      elseif e.next == self.id then
        -- Beacon-sender N claims to reach e.dest via me. That alone is fine
        -- (it'd be 1-hop on N's side, "direct via me"), but it also lets us
        -- detect any 3-cycle me→X→N→me already cached in our own rt[e.dest]:
        -- prune slots whose stored n2_hop equals N.
        rt_prune_cycle(self, e.dest, b.src)
      else
        local combined_score = math.min(meta.snr, e.score)
        local combined_hops  = e.hops + 1
        if combined_hops <= 8 then
          local cand = {
            next_hop = b.src,
            n2_hop   = e.next,   -- N's claimed next-hop for e.dest; used by rt_prune_cycle
            score    = combined_score,
            hops     = combined_hops,
            last_seen_ms = now,
          }
          local action = rt_merge(self.rt, e.dest, cand)
          if action == "new" or action == "promote" then
            self:emit("rt_update", {
              dest = e.dest, next = b.src,
              score = combined_score, hops = combined_hops, slot = "primary",
            })
            self:log(string.format("rt[%s] via %s, hops=%d score=%.1f dB (primary)",
              name_of(self, e.dest), name_of(self, b.src), combined_hops, combined_score))
            rt_changed = true
          elseif action == "alt_install" then
            self:emit("rt_update", {
              dest = e.dest, next = b.src,
              score = combined_score, hops = combined_hops, slot = "alt",
            })
            self:log(string.format("rt[%s] via %s, hops=%d score=%.1f dB (alt)",
              name_of(self, e.dest), name_of(self, b.src), combined_hops, combined_score))
          end
        end
      end
    end

    if rt_changed then schedule_triggered_beacon(self) end

    maybe_emit_rt_full(self)
    return
  end

  if tag == "R" then
    local r = parse_rts(frame)
    if not r then return end
    if r.next ~= self.id then return end  -- not for us; silent discard

    -- Sender is retrying an RTS for a DATA we already received and acked
    -- (their previous ACK was lost in flight). Re-send the ACK directly
    -- — no CTS, no DATA — so they can clear pending_tx without us
    -- reprocessing/duplicating the message. last_acked_from holds the
    -- most recent acked msg_id per sender.
    if self.last_acked_from[r.src] == r.msg_id then
      self:emit("rts_already_acked", {
        origin = r.origin,    -- payload unknown — RTS frame doesn't carry it
        from = r.src, msg_id = r.msg_id,
      })
      self:log(string.format("rts_already_acked <- %s msg_id=%d -> re-sending ACK",
        name_of(self, r.src), r.msg_id))
      local ack = pack_ack(r.msg_id)
      tx_with_retry(self, ack, {
        sf    = self.routing_sf,
        label = "K-dup",
        info  = string.format("re-ACK to=%s msg=%d", name_of(self, r.src), r.msg_id),
      })
      return
    end

    if self.pending_rx ~= nil then
      -- Duplicate RTS from the same originator for the same msg_id: their
      -- previous CTS may have been lost, or DATA was sent and ACK was
      -- lost (and our pending_rx hasn't expired yet). Re-send the CTS so
      -- they can re-attempt DATA.
      if self.pending_rx.from == r.src and self.pending_rx.msg_id == r.msg_id then
        self:emit("rts_rx_dup", {
          origin = r.origin,    -- payload unknown at RTS phase
          from = r.src, msg_id = r.msg_id,
        })
        self:log(string.format("rts_rx_dup <- %s msg_id=%d -> resending CTS (sf=%d)",
          name_of(self, r.src), r.msg_id, self.pending_rx.chosen_data_sf))
        local cts = pack_cts(r.msg_id, self.pending_rx.chosen_data_sf)
        self:emit("cts_tx", {
          origin = r.origin, to = r.src, msg_id = r.msg_id, dup = true,
          chosen_data_sf = self.pending_rx.chosen_data_sf,
        })
        tx_with_retry(self, cts, {
          sf    = self.routing_sf,
          label = "CTS-dup",
          info  = string.format("re-CTS to=%s msg=%d sf=%d",
            name_of(self, r.src), r.msg_id, self.pending_rx.chosen_data_sf),
        })
        -- Reset pending_rx_expiry — the sender is still trying, so give
        -- DATA another full window to arrive.
        start_pending_rx_expiry(self)
        return
      end
      -- A different in-flight wants us as next-hop while we're holding
      -- pending_rx for someone else. Send a NACK back so the sender can
      -- pick an alternate path or wait — replaces the old silent
      -- rts_rejected_busy. busy_for_ms = how long until our pending_rx
      -- expiry is expected to fire (worst case for THIS receiver).
      local now = self:now()
      local expiry = self.pending_rx.expiry_ms or self.pending_rx_expiry_max_ms
      local busy_for = self.pending_rx.set_at_ms + expiry - now
      if busy_for < 0 then busy_for = 0 end
      if busy_for > 65535 then busy_for = 65535 end
      local nack = pack_nack(r.msg_id, busy_for)
      self:emit("nack_tx", {
        origin = r.origin,    -- the inbound RTS's flight, not our pending_rx's
        to = r.src, msg_id = r.msg_id, busy_for_ms = busy_for, reason = "pending_rx",
      })
      self:log(string.format("nack_tx -> %s msg_id=%d busy_for=%dms (busy with pending_rx from %s/%d)",
        name_of(self, r.src), r.msg_id, busy_for,
        name_of(self, self.pending_rx.from), self.pending_rx.msg_id))
      tx_with_retry(self, nack, {
        sf    = self.routing_sf,
        label = "NACK",
        info  = string.format("to=%s msg=%d busy_for=%dms reason=pending_rx",
          name_of(self, r.src), r.msg_id, busy_for),
      })
      return
    end

    if self.pending_tx ~= nil then
      -- We're mid-flight ourselves (originating or forwarding). Tell the
      -- sender we're busy. Estimate busy_for using the slowest SF in our
      -- allowed bitmap as a pessimistic upper bound on DATA airtime; if
      -- our flight uses a faster SF the sender's wait+retry just fires
      -- a bit early from on_recv "K" → become_free path.
      local slowest = 5
      for sf = 12, 5, -1 do
        if sf_in_bitmap(self.allowed_sf_bitmap, sf) then slowest = sf; break end
      end
      local busy_for = airtime_ms(slowest, self.bw_hz, self.cr,
                                   self.preamble_sym,
                                   DATA_HDR_LEN + self.max_payload_bytes)
                       + self.ack_air_ms
      if busy_for > 65535 then busy_for = 65535 end
      local nack = pack_nack(r.msg_id, busy_for)
      self:emit("nack_tx", {
        origin = r.origin,    -- the inbound RTS's flight, not our pending_tx
        to = r.src, msg_id = r.msg_id, busy_for_ms = busy_for, reason = "pending_tx",
      })
      self:log(string.format("nack_tx -> %s msg_id=%d busy_for=%dms (busy with pending_tx msg=%d)",
        name_of(self, r.src), r.msg_id, busy_for, self.pending_tx.msg_id))
      tx_with_retry(self, nack, {
        sf    = self.routing_sf,
        label = "NACK",
        info  = string.format("to=%s msg=%d busy_for=%dms reason=pending_tx",
          name_of(self, r.src), r.msg_id, busy_for),
      })
      return
    end

    -- Pick a data SF from the RTS's allowed-SF bitmap based on the link
    -- SNR (rx_snr from radio metadata) and our configured margin. Empty
    -- bitmap → nothing we can do; silent drop (sender's rts_timeout will
    -- handle it).
    local chosen_sf = select_data_sf(meta.snr, r.sf_bitmap, self.sf_margin_db)
    if chosen_sf == nil then
      self:emit("rts_drop_no_sf", {
        origin = r.origin, from = r.src, msg_id = r.msg_id,
        sf_bitmap = r.sf_bitmap,
      })
      self:log(string.format("rts_drop_no_sf <- %s msg_id=%d (empty sf_bitmap)",
        name_of(self, r.src), r.msg_id))
      return
    end

    self:emit("rts_rx", {
      origin = r.origin,    -- payload unknown at RTS phase
      from = r.src, dst = r.dst, msg_id = r.msg_id,
      sf_bitmap = r.sf_bitmap, chosen_data_sf = chosen_sf, rx_snr = meta.snr,
    })
    self:log(string.format(
      "rts_rx <- %s (origin=%s dst=%s msg_id=%d sf_bitmap=0x%02x snr=%.1fdB) -> chose SF%d",
      name_of(self, r.src), name_of(self, r.origin), name_of(self, r.dst),
      r.msg_id, r.sf_bitmap, meta.snr, chosen_sf))
    self.pending_rx = {
      from      = r.src,
      origin    = r.origin,
      dst       = r.dst,
      msg_id    = r.msg_id,
      set_at_ms = self:now(),       -- for NACK busy_for_ms calc
      chosen_data_sf = chosen_sf,   -- DATA leg's SF; receiver retunes after CTS-tx
    }
    -- Arm the expiry timer so a never-arriving DATA can't freeze us.
    start_pending_rx_expiry(self)

    local cts = pack_cts(r.msg_id, chosen_sf)
    self:emit("cts_tx", {
      origin = r.origin, to = r.src, msg_id = r.msg_id,
      chosen_data_sf = chosen_sf,
    })
    self:log(string.format("cts_tx -> %s msg_id=%d chose SF%d (on routing SF%d)",
      name_of(self, r.src), r.msg_id, chosen_sf, self.routing_sf))
    tx_with_retry(self, cts, {
      sf    = self.routing_sf,
      label = "CTS",
      info  = string.format("to=%s msg=%d chosen_sf=%d",
        name_of(self, r.src), r.msg_id, chosen_sf),
    })
    -- After CTS-tx completes, the runtime resumes RX on whatever we set
    -- here. Retune now so DATA on chosen_sf will land cleanly.
    self:set_rx_sf(chosen_sf)
    self:emit("retune_for_data", { sf = chosen_sf })
    return
  end

  if tag == "C" then
    local c = parse_cts(frame)
    if not c then return end
    if self.pending_tx == nil then return end
    if c.msg_id ~= self.pending_tx.msg_id then return end

    -- CTS matched — cancel the rts_timeout. Without this, the timer fires
    -- on the same tick (rts_timeout_ms = exact RTS+CTS airtime) before the
    -- after-callback below clears pending_tx, triggering a needless retry.
    if self.rts_timeout_handle then
      self:cancel(self.rts_timeout_handle)
      self.rts_timeout_handle = nil
    end

    -- Receiver picked a DATA SF — record it so the after-callback uses
    -- it for the DATA TX and start_ack_timeout uses it for the airtime
    -- estimate. Reject if the receiver's pick isn't in our allowed
    -- bitmap (defends against a malformed CTS).
    if not sf_in_bitmap(self.allowed_sf_bitmap, c.chosen_data_sf) then
      self:emit("cts_invalid_sf", {
        origin = self.pending_tx.origin, payload = self.pending_tx.payload,
        from = c.src or self.pending_tx.next, msg_id = c.msg_id,
        chosen_data_sf = c.chosen_data_sf,
      })
      return
    end
    self.pending_tx.chosen_data_sf = c.chosen_data_sf

    self:emit("cts_rx", {
      origin = self.pending_tx.origin,
      payload = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      from = self.pending_tx.next, msg_id = c.msg_id,
      chosen_data_sf = c.chosen_data_sf,
    })

    local gap = self.cts_to_data_gap_ms or 5
    self:log(string.format("cts_rx <- %s msg_id=%d chose SF%d -> waiting %dms then DATA",
      name_of(self, self.pending_tx.next), c.msg_id, c.chosen_data_sf, gap))
    -- Capture the snapshot so the timer fire still has the right
    -- pending_tx context if anything mutates it (e.g., a forward dance
    -- starting concurrently — shouldn't happen in scenario A, but be safe).
    local px = self.pending_tx
    self:after(gap, function()
      -- pending_tx may have been cleared by an ack_timeout giveup or
      -- another path between cts_rx and the gap-expiry; bail if so.
      if self.pending_tx == nil or self.pending_tx.msg_id ~= px.msg_id then
        return
      end
      local d = pack_data(px.origin, self.id, px.dst, px.next, px.msg_id, px.payload)
      self:emit("data_tx", {
        origin = px.origin, payload = px.user_text, origin_seq = px.origin_seq,
        dst = px.dst, next = px.next, msg_id = px.msg_id, len = #px.payload,
        sf = px.chosen_data_sf,
      })
      self:log(string.format("data_tx -> %s msg_id=%d payload=%q on SF%d (ACK on SF%d)",
        name_of(self, px.next), px.msg_id, px.payload, px.chosen_data_sf, self.routing_sf))
      tx_with_retry(self, d, {
        sf    = px.chosen_data_sf,
        label = "DATA",
        info  = string.format("origin=%s dst=%s next=%s msg=%d sf=%d payload=%q",
          name_of(self, px.origin), name_of(self, px.dst),
          name_of(self, px.next), px.msg_id, px.chosen_data_sf, px.payload),
      })
      -- Sender's RX has been on routing_sf throughout — no retune needed.
      -- DATA TX uses the per-tx sf override; the modem's RX state is
      -- independent of TX SF. Keep pending_tx for ack_timeout matching.
      start_ack_timeout(self)
    end)
    return
  end

  if tag == "K" then
    local k = parse_ack(frame)
    if not k then return end
    if self.pending_tx == nil then return end
    if k.msg_id ~= self.pending_tx.msg_id then return end

    -- ACK matched. Cancel the ack_timeout, clear pending_tx, drain the
    -- queue. The ack_timeout retry path (re-RTS on ack-loss) is what
    -- recovers concurrent-flight DATA collisions; this is the happy
    -- path where DATA was decoded cleanly at the next-hop.
    if self.ack_timeout_handle then
      self:cancel(self.ack_timeout_handle)
      self.ack_timeout_handle = nil
    end
    self:emit("ack_rx", {
      origin = self.pending_tx.origin,
      payload = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      from = self.pending_tx.next, msg_id = k.msg_id,
    })
    self:log(string.format("ack_rx <- %s msg_id=%d -> hop complete",
      name_of(self, self.pending_tx.next), k.msg_id))
    self.pending_tx = nil
    become_free(self)
    return
  end

  if tag == "N" then
    local n = parse_nack(frame)
    if not n then return end
    if self.pending_tx == nil then return end
    if n.msg_id ~= self.pending_tx.msg_id then return end

    -- NACK matched: chosen next-hop can't take us right now. Cancel the
    -- rts_timeout (NACK is a faster, definitive signal). NACK rides on
    -- data_sf — same channel as CTS would have come back on — so the
    -- sender's RX (already retuned to data_sf after the RTS TX) hears
    -- it without another retune.
    if self.rts_timeout_handle then
      self:cancel(self.rts_timeout_handle)
      self.rts_timeout_handle = nil
    end

    self:emit("nack_rx", {
      origin = self.pending_tx.origin,
      payload = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      from = self.pending_tx.next, msg_id = n.msg_id, busy_for_ms = n.busy_for_ms,
    })
    self:log(string.format("nack_rx <- %s msg_id=%d busy_for=%dms",
      name_of(self, self.pending_tx.next), n.msg_id, n.busy_for_ms))

    -- Decide what to do. Three strategies, in order of preference:
    --   (a) try the alt path if we have one and haven't tried it yet
    --   (b) if busy_for_ms is short, wait it out on the same path
    --   (c) requeue and become_free — the queue might pop a different
    --       send, or DV beacons may converge to a new primary
    local entry = self.rt[self.pending_tx.dst]
    local alt = entry and entry.alt or nil
    local can_try_alt = alt ~= nil and (not self.pending_tx.alt_tried)

    if can_try_alt then
      local prev_next = self.pending_tx.next
      self.pending_tx.next      = alt.next_hop
      self.pending_tx.alt_tried = true
      self.pending_tx.retries_left = self.rts_max_retries  -- fresh budget for alt path
      self:emit("path_switch", {
        origin = self.pending_tx.origin,
        payload = self.pending_tx.user_text,
        origin_seq = self.pending_tx.origin_seq,
        dst = self.pending_tx.dst, msg_id = self.pending_tx.msg_id,
        from_next = prev_next, to_next = alt.next_hop,
      })
      self:log(string.format("path_switch dst=%s msg_id=%d %s → %s (alt)",
        name_of(self, self.pending_tx.dst), self.pending_tx.msg_id,
        name_of(self, prev_next), name_of(self, alt.next_hop)))
      tx_rts_retry(self, "nack_alt")
      return
    end

    local NACK_WAIT_THRESHOLD_MS = 200
    if n.busy_for_ms <= NACK_WAIT_THRESHOLD_MS then
      local captured = self.pending_tx.msg_id
      local wait_ms = n.busy_for_ms + 1
      self:log(string.format("nack_wait msg_id=%d for %dms (no alt or alt already tried)",
        captured, wait_ms))
      self:after(wait_ms, function()
        if self.pending_tx ~= nil and self.pending_tx.msg_id == captured then
          tx_rts_retry(self, "nack_wait")
        end
      end)
      return
    end

    -- Long busy + no useful alt: drop pending_tx back into the queue so
    -- the node can do something else meanwhile (next queued send, or
    -- forward someone else's flight). The originator's command-side
    -- retry policy is implicit: it'll fire again from the queue once
    -- DV may have updated routes.
    table.insert(self.tx_queue, {
      origin     = self.pending_tx.origin,
      dst_id     = self.pending_tx.dst,
      dst_name   = name_of(self, self.pending_tx.dst),
      payload    = self.pending_tx.payload,        -- full bytes
      user_text  = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
    })
    self:emit("tx_requeued", {
      origin = self.pending_tx.origin,
      payload = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      dst = self.pending_tx.dst, msg_id = self.pending_tx.msg_id,
      busy_for_ms = n.busy_for_ms, depth = #self.tx_queue,
    })
    self:log(string.format("tx_requeued msg_id=%d busy_for=%dms (no alt, long wait)",
      self.pending_tx.msg_id, n.busy_for_ms))
    self.pending_tx = nil
    become_free(self)
    return
  end

  if tag == "D" then
    local d = parse_data(frame)
    if not d then return end
    if d.next ~= self.id then return end
    if self.pending_rx == nil or d.msg_id ~= self.pending_rx.msg_id then return end

    -- Parse the application-layer origin-seq header from the payload
    -- bytes. Forwarders peek at the first 2 bytes to get the
    -- (origin, origin_seq) end-to-end message id for dedup; the rest
    -- is the user text the originator actually sent. A real-firmware
    -- port works the same way: app prepends seq, mesh treats opaque,
    -- app strips on receive. If parsing fails (truncated payload),
    -- treat the whole payload as user_text and skip dedup.
    local oh = parse_origin_seq(d.payload)
    local user_text = oh and oh.user_text or d.payload
    local origin_seq = oh and oh.seq or nil

    self:emit("data_rx", {
      origin     = d.origin,
      payload    = user_text,
      origin_seq = origin_seq,
      from       = d.src,
      dst        = d.dst,
      msg_id     = d.msg_id,
      len        = #d.payload,
    })
    self:log(string.format(
      "data_rx <- %s (origin=%s seq=%s dst=%s msg_id=%d, %d bytes) -> back to SF%d",
      name_of(self, d.src), name_of(self, d.origin),
      tostring(origin_seq), name_of(self, d.dst),
      d.msg_id, #d.payload, self.routing_sf))

    -- DATA decoded. Cancel the pending_rx_expiry, retune RX, clear
    -- pending_rx. Then immediately TX the per-hop ACK on routing_sf and
    -- cache (sender, msg_id) so future retried RTS-from-this-sender
    -- short-circuits to a re-ACK without re-processing the DATA.
    if self.pending_rx_expiry_handle then
      self:cancel(self.pending_rx_expiry_handle)
      self.pending_rx_expiry_handle = nil
    end
    self:set_rx_sf(self.routing_sf)
    self.pending_rx = nil

    self.last_acked_from[d.src] = d.msg_id
    local ack = pack_ack(d.msg_id)
    self:emit("ack_tx", {
      origin = d.origin, payload = user_text, origin_seq = origin_seq,
      to = d.src, msg_id = d.msg_id,
    })
    self:log(string.format("ack_tx -> %s msg_id=%d (on routing SF%d)",
      name_of(self, d.src), d.msg_id, self.routing_sf))
    tx_with_retry(self, ack, {
      sf    = self.routing_sf,
      label = "ACK",
      info  = string.format("to=%s msg=%d", name_of(self, d.src), d.msg_id),
    })

    -- Origin-level dedup. Now that the ACK is on its way (the
    -- previous hop will clear pending_tx whether or not we forward),
    -- check whether we've already seen this (origin, origin_seq).
    -- If so: don't deliver-twice and don't forward-twice. Catches DV
    -- routing loops and legitimate same-payload retries from the
    -- originator that found a different path.
    if origin_seq ~= nil then
      local seen_key = string.format("%d|%d", d.origin, origin_seq)
      local now_ms = self:now()
      local exp = self.seen_origins[seen_key]
      if exp and exp > now_ms then
        self:emit("dup_drop", {
          origin = d.origin, payload = user_text, origin_seq = origin_seq,
          from = d.src, msg_id = d.msg_id,
        })
        self:log(string.format(
          "dup_drop <- %s (origin=%s seq=%d, already seen — ACK only)",
          name_of(self, d.src), name_of(self, d.origin), origin_seq))
        return
      end
      -- Opportunistic prune of expired entries (cheap; bounded set).
      for k, e in pairs(self.seen_origins) do
        if e <= now_ms then self.seen_origins[k] = nil end
      end
      self.seen_origins[seen_key] = now_ms + self.seen_origin_ttl_ms
    end

    -- Capture the data we need for the post-ack action; the next-step
    -- callback runs after the ACK has cleared the radio so two TXes from
    -- the same script-tick don't race the runtime's self_tx_in_flight
    -- check (which would defer the forward-RTS via on_radio_busy retry —
    -- correct but wasteful; this is real-hardware behaviour anyway).
    local d_origin     = d.origin
    local d_dst        = d.dst
    local d_payload    = d.payload          -- full bytes for re-forwarding
    local d_user_text  = user_text
    local d_origin_seq = origin_seq
    local is_delivered = (d.dst == self.id)

    if is_delivered then
      self:emit("delivered", {
        origin = d_origin, payload = d_user_text, origin_seq = d_origin_seq,
      })
      self:log(string.format("DELIVERED from %s: %q (seq=%s)",
        name_of(self, d_origin), d_user_text, tostring(d_origin_seq)))
    end

    self:after(self.ack_air_ms + 1, function()
      if is_delivered then
        become_free(self)
        return
      end
      -- Forward path. If we picked up a new flight during the ack-air
      -- window (or the queue advanced via some other event), enqueue
      -- the forward instead of stomping on the in-progress flight.
      local dst_name = name_of(self, d_dst)
      local route = self.rt[d_dst]
      if route == nil then
        self:emit("forward_fail", {
          origin = d_origin, payload = d_user_text, origin_seq = d_origin_seq,
          dst = d_dst, reason = "no_route",
        })
        self:log(string.format("forward_fail: no route to %s", dst_name))
        become_free(self)
        return
      end
      if self.pending_tx ~= nil or self.pending_rx ~= nil then
        table.insert(self.tx_queue, {
          origin     = d_origin,
          dst_id     = d_dst,
          dst_name   = dst_name,
          payload    = d_payload,             -- full bytes (preserves the seq header)
          user_text  = d_user_text,
          origin_seq = d_origin_seq,
        })
        self:emit("forward_queued", {
          origin = d_origin, payload = d_user_text, origin_seq = d_origin_seq,
          dst = d_dst, depth = #self.tx_queue,
        })
        return
      end
      issue_send(self, d_origin, d_dst, dst_name,
                 d_payload, d_user_text, d_origin_seq)
    end)
    return
  end
end

-- on_command "send <dst_name> <text>": enqueue a user-originated send into
-- the TX queue and try to drain immediately. Even if we're busy now (mid-RX,
-- mid-TX, or queued forwards ahead), the queue ensures the message will fire
-- as soon as we're free — no more "ERROR: busy" rejection.
function on_command(self, cmd_str)
  local dst_name, text = cmd_str:match("^send (%S+) (.+)$")
  if not dst_name then return "ERROR: usage: send <dst_name> <text>" end
  local dst_id = self.name_to_id[dst_name]
  if dst_id == nil then return "ERROR: unknown dst: " .. dst_name end
  -- Stamp this user-message with our 16-bit per-origin sequence number.
  -- Combined with our origin_id (carried by the mesh DATA frame), the
  -- pair (origin_id, origin_seq) is the globally-unique end-to-end
  -- message id used by every receiving node for dedup.
  local seq = self.next_origin_seq
  self.next_origin_seq = (seq + 1) % 65536
  local full_payload = pack_origin_seq(seq) .. text
  table.insert(self.tx_queue, {
    origin     = self.id,
    dst_id     = dst_id,
    dst_name   = dst_name,
    payload    = full_payload,    -- full bytes that go on the wire
    user_text  = text,            -- emit / log clarity
    origin_seq = seq,
  })
  self:emit("tx_enqueue", {
    origin = self.id, payload = text, origin_seq = seq,
    dst = dst_id, depth = #self.tx_queue,
  })
  self:log(string.format("send: queued dst=%s payload=%q seq=%d (queue depth=%d)",
    dst_name, text, seq, #self.tx_queue))
  become_free(self)
  return string.format("queued (depth=%d, seq=%d)", #self.tx_queue, seq)
end

-- on_radio_busy fires when the runtime defers a TX (LBT channel_busy or
-- own-TX in flight). The deferred PendingTx bytes are dropped runtime-side
-- so we re-issue from the per-label tx_stash. Policy:
--   • BCN          → drop (periodic; next beacon-fire retries naturally)
--   • RTS / RTS-fwd / RTS-rty → drop (rts_timeout is the retry path; running
--                                     a second timer here would race it)
--   • CTS / CTS-dup / DATA    → reschedule at info.busy_until_ms; max
--                                TX_DEFER_MAX_RETRIES then tx_giveup
function on_radio_busy(self, info)
  self:emit("radio_busy", {
    reason        = info.reason,
    label         = info.label,
    sf            = info.sf,
    busy_until_ms = info.busy_until_ms,
  })

  local stash = self.tx_stash[info.label]
  if not stash then
    -- Either a non-retry-eligible label or a retry-eligible one whose stash
    -- was cleared by a more recent same-label TX.
    self:log(string.format("radio_busy %s reason=%s busy_until=%d (no retry)",
      info.label, info.reason, info.busy_until_ms))
    return
  end
  if stash.retries_left <= 0 then
    self:emit("tx_giveup", { label = info.label, reason = info.reason })
    self:log(string.format("tx_giveup %s reason=%s (max retries exhausted)",
      info.label, info.reason))
    self.tx_stash[info.label] = nil
    return
  end
  stash.retries_left = stash.retries_left - 1

  local now   = self:now()
  local delay = info.busy_until_ms - now
  if delay < 0 then delay = 0 end  -- channel already free; fire next step
  self:log(string.format(
    "radio_busy %s reason=%s busy_until=%d -> retry in %dms (retries_left=%d)",
    info.label, info.reason, info.busy_until_ms, delay, stash.retries_left))
  self:after(delay, function()
    self:tx(stash.bytes, stash.opts)
  end)
end
