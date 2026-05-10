-- scenarios/dv_dual_sf.lua
-- Distance-vector routing on routing_sf with per-hop dual-SF data delivery
-- on data_sf via RTS/CTS/DATA. See docs/superpowers/specs/2026-05-06-s01-dv-dual-sf-scenario-design.md.
--
-- Wire format:
-- | Tag   | Frame  | Layout                                                                          |
-- | ----- | ------ | ------------------------------------------------------------------------------- |
-- | `'B'` | Beacon | `B`, [network_id(4)|reserved(4)](1), src(1), n(1), entries × n × {dest(1), next(1), score_i8(1), hops(1)}  →  4+4n B |
-- | `'R'` | RTS    | `R`, origin(1), src(1), dst(1), next(1), [network_id(4)|msg_id(4)](1), sf_bitmap(1), payload_len(1)  →  8 B |
-- | `'C'` | CTS    | `C`, [msg_id(4)|(sf-5)(3)|reserved(1)](1)  →  2 B                              |
-- | `'D'` | DATA   | `D`, origin(1), src(1), dst(1), next(1), [reserved(4)|msg_id(4)](1), payload(n)  →  6+n B |
-- | `'K'` | ACK    | `K`, [msg_id(4)|snr_bucket(4)](1)  →  2 B                                       |
-- | `'N'` | NACK   | `N`, [reserved(4)|msg_id(4)](1), busy_for_ms_lo(1), busy_for_ms_hi(1)  →  4 B  |
--
-- All control frames carry a 4-bit msg_id (per-(originator) flight
-- counter, wraps at 16; dedup tolerated by last_acked_from's 10s TTL).
-- network_id (4 bits, externally managed) appears in BCN and RTS — the
-- two frames that gate routing decisions. Receivers reject foreign-
-- network BCN/RTS before doing any work, preventing duplicate-CTS,
-- routing-table-pollution, and wasted-flight failure modes during
-- enhanced RF propagation events. CTS/DATA/ACK/NACK don't carry
-- network_id because they're matched against pending_tx/pending_rx
-- state set by an already-validated RTS (the check is implicit).
--
-- RTS's sf_bitmap byte (offset 7) is a per-flight bitmap of allowed data SFs:
--   bit i = SF (5+i) is acceptable for the DATA leg; the receiver picks one.
--   bit 0 = SF5 (fastest), bit 7 = SF12 (most robust). e.g. 0b01000010 = SF6+SF12.
-- RTS's payload_len byte (offset 8) is the byte count of the upcoming DATA
-- payload (origin-seq header + user_text). Lets the receiver size
-- pending_rx_expiry to actual airtime instead of max_payload_bytes
-- worst-case — important when payloads vary 10–200 bytes, since the
-- worst-case budget would freeze pending_rx ~2× longer than needed.
-- CTS's last byte is the receiver's chosen data SF (single value, 5..12),
-- selected from the RTS bitmap. The SNR fed into select_data_sf is the
-- per-neighbour inbound EWMA (`snr_ewma_in[r.src]`), updated at the top
-- of every on_recv with the most recent meta.snr from that neighbour —
-- so the SF pick rides on a smoothed ~10-sample estimate instead of a
-- single noisy snapshot. This makes the data-plane SF per-hop adaptive
-- without any wire-format negotiation round-trip beyond the existing
-- RTS/CTS handshake.
--
-- ACK's 4th byte's low nibble is a 4-bit SNR bucket (2 dB bins, range
-- -20..+10 dB) — the receiver's measurement of the just-received DATA's
-- decode SNR. The originator/forwarder feeds this into a separate
-- per-neighbour `snr_ewma_out` so it knows how its own outbound DATA
-- arrives at each neighbour. The high nibble is reserved (currently 0).
-- Use cases for `_out`: future routing-cost weighting, per-link RTS
-- bitmap trimming, link-asymmetry detection. SF picks today still read
-- `_in` only.
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
--     adaptive throttle: skip emission if `now - last_rx_routing_sf_ms <
--       quiet_threshold_ms` (default 30s). last_rx is set at the top of
--       on_recv on every successful decode (broadcast OR unicast). Net
--       effect: a node that hears recent traffic stays quiet rather than
--       adding to the congestion. On s02 sparse this drops BCN airtime
--       from ~91% of total to ~21% with delivery rate slightly improved.
--     silence-trigger jitter: when the throttle gate passes, defer the
--       actual TX by rand(0, beacon_silence_jitter_ms) (default 10s) and
--       re-check silence at the deferred fire time. Defends against
--       thundering herd when many nodes simultaneously detect the same
--       busy→quiet transition. Set quiet_threshold_ms=0 to disable both
--       the throttle AND the silence-jitter (used by unit tests that
--       depend on rapid-fire beacon mechanics in tight time windows).
--     → tx 'B' with all rt entries → ±20% jittered re-arm
--   triggered beacons: any rt mutation (new/promote/3cycle-prune)
--     schedules a one-shot beacon within rand(50,500)ms (coalesced into
--     a single armed trigger). NOT subject to the adaptive throttle —
--     triggered beacons exist to propagate routing changes urgently;
--     suppressing them on busy channels would defeat the purpose. This
--     is what makes convergence fast when the operational period is
--     minutes-long; periodic beacons are just a slow keep-alive.
--     Half-duplex skip applies — busy nodes drop the trigger and rely on
--     the next mutation (or periodic) to retry.
--   on_recv 'B' from N at rx_snr
--     install rt[N] = {direct, snr, hops=1, n2_hop=nil}
--     for each entry e in beacon (e.dest != self.id):
--       if e.next == self.id (N routes e.dest via me):
--         3-cycle prune — if any of my rt[e.dest].candidates has
--         n2_hop == N, that slot is part of cycle me→X→N→me; drop it
--         (remove entry if all candidates are looped)
--       else:
--         cand = {via=N, n2_hop=e.next, score=min(rx_snr, e.score),
--                 hops=e.hops+1}
--         adopt if hops<=8 AND (no current OR better score OR same score & fewer hops)
--     emit rt_full once rt covers all peers
--   The stored n2_hop (N's claimed next-hop for that dest) is the only
--   reason a 3-cycle can be detected without enlarging the wire format —
--   the byte was already in the beacon entry, we just hadn't been keeping it.
--
-- Bootstrap UX (cold-start joiners)
--   Goal: a new user opening the app and tapping "send" should see clear
--   feedback ("connecting... sending... delivered") rather than a silent
--   drop. Two pieces:
--
--   1. Cold-start fast first beacon. If on_init runs AFTER warmup_ms
--      (single new joiner, mesh already converged), schedule the first
--      beacon at rand(1, 200) ms instead of rand(0, beacon_period_warmup).
--      Neighbours' triggered beacons bring this node into routing tables
--      within ~hundreds of ms instead of waiting up to a full operational
--      beacon period (5 min default).
--
--   2. Defer queue for originator sends with no route. Instead of
--      dropping with send_no_route, hold the send for up to
--      send_defer_ttl_ms (default 30 s) in self.deferred_sends. Drain
--      triggered by:
--        - on_recv 'B' (after rt mutations) — fastest case, route just
--          arrived; deferred send fires within ~hundreds of ms of boot.
--        - Periodic 1 s timer — fallback for TTL pruning when no
--          routing traffic flows.
--      Events: send_deferred (initial hold; app should show "connecting"),
--      send_drained (route appeared; app updates to "sending"),
--      send_giveup (TTL elapsed; app surfaces real failure).
--
--   Forwarders (mid-flight, previous_hop != nil) NEVER defer — a route
--   gone mid-flight is a real failure (originator's app-layer end-to-end
--   retry is the recovery), so they keep the legacy send_no_route emit.
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
--     • retries_left>0  → after rand(0, retry_jitter_ms): tx_rts_retry
--                          ("cts_timeout"). The random backoff prevents
--                          synchronized re-fires across nodes whose CTSes
--                          collided in the same window.
--     • retries_left==0 → emit rts_giveup, clear pending_tx, become_free
--   ack_timeout_fire — ACK didn't arrive within DATA_air + ACK_air:
--     • pending_rx set  → reschedule self after rts_busy_retry_ms
--     • retries_left>0  → after rand(0, retry_jitter_ms): tx_rts_retry
--                          ("ack_timeout"). Same random backoff as cts.
--     • retries_left==0 → emit data_ack_giveup, clear pending_tx, become_free
--   pending_rx_expiry_fire — DATA didn't arrive after CTS:
--     • clear pending_rx, retune to routing_sf, emit data_rx_timeout, become_free
--   tx_rts_retry: re-tx RTS with same msg_id (via tx_initiating, so still
--   LBT-gated) and re-arm rts_timeout. The receiver's rts_already_acked /
--   rts_rx_dup paths handle whatever state it's in (still expecting DATA,
--   or already acked).
--
-- TX policy classes (three categories with different timing constraints):
--
--   1. RESPONSE-DIRECTED  (CTS, DATA, ACK) — peer's timer (rts_timeout /
--      ack_timeout / pending_rx_expiry) is already running and was sized
--      to the *minimum* round-trip airtime. Any LBT defer here pushes us
--      past the peer's deadline, burning a retry. So these go straight
--      through tx_with_retry; the simulator's reactive radio_busy stash
--      is the only safety net.
--
--   2. INITIATING-DIRECTED  (RTS, NACK) — sender owns the schedule.
--      Routed through tx_initiating, which pre-checks
--      self:channel_busy_until() and, if busy, schedules the actual emit
--      at busy_until + rand(0, retry_jitter_ms). Reduces head-on collisions
--      on tight links and decorrelates retry storms across nodes whose
--      timers fire on the same step. Bounded by rts_max_retries on the
--      RTS side; a missing NACK just means the peer keeps retrying RTS.
--
--   3. FLOOD  (Beacon) — no specific peer waiting; lost beacons are
--      recovered by the next periodic / triggered fire. Routed through
--      tx_flood, which LBT-defers up to flood_lbt_max_defer_ms and drops
--      the page (tx_flood_skipped emit) past that threshold — a stale
--      routing announcement isn't worth queueing when a fresher one will
--      fire shortly.
--
--   Knobs on self: lbt_enabled (default true), retry_jitter_ms (default
--   = one RTS-airtime, scales with BW/SF), flood_lbt_max_defer_ms
--   (default = one beacon's airtime).
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
--     candidates = {
--       { next_hop, score, hops, last_seen_ms, n2_hop },  -- primary (slot 1)
--       { next_hop, score, hops, last_seen_ms, n2_hop },  -- alt 1   (slot 2)
--       { next_hop, score, hops, last_seen_ms, n2_hop },  -- alt 2   (slot 3)
--     },
--   }
--   #candidates is in [1, MAX_RT_CANDIDATES] (K=3 today). Sorted
--   descending by score (route_strictly_better comparator). All
--   candidates[i].next_hop are distinct.
--
-- DV merge (rt_merge): for each candidate cand from a beacon-sender:
--   • match-by-next_hop (any slot) → refresh in place if cand is
--                                     strictly better; sort
--   • new next_hop AND #candidates < K → insert + sort
--   • new next_hop AND #candidates == K
--                                  → if cand strictly beats worst,
--                                    replace worst + sort; else drop
-- Beacons advertise only candidates[1] (single best route per dest).
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
--   • mark NACK sender blind for busy_for_ms (so concurrent retries
--     against the same next-hop defer via classify_blind)
--   • if busy_for_ms ≤ NACK_WAIT_THRESHOLD_MS (2000 ms default)
--     → after(busy_for_ms + 1 + rand(0, retry_jitter_ms),
--             tx_rts_retry("nack_wait"))   -- same next-hop
--   • else (very long busy)
--     → push pending_tx back into tx_queue; pending_tx=nil; become_free
--       (DV may converge or the queue may surface other work meanwhile)
--
-- We never path-switch on a NACK. The protocol's NACK carries only
-- busy_for_ms — a transient receiver-busy signal — so the receiver
-- freeing up is the natural event we should wait for. Path-switching
-- on busy NACK is harmful when next == dst (alice busy as originator
-- ⇒ every alt forwarder also gets NACKed; observed cost was 2 extra
-- hops on s04 dave→alice flights).
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
--   • alts_tried (set keyed by next_hop id) clears on successful delivery
--     (pending_tx → nil via on_recv "K"); fresh send via issue_send always
--     starts with an empty set (modulo F1 blind-skipped primary).
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
-- F1 mitigation: receiver-blind-window awareness via passive CTS overhearing
-- ============================================================================
--
-- The data plane has an asymmetry: when relay R post-CTS-tx retunes to
-- data_sf to receive DATA, R is deaf on routing_sf for the duration of
-- (cts_to_data_gap + DATA airtime). Concurrent senders RTSing R during
-- this window land as drop_sf_mismatch — silent at runtime, no NACK, so
-- the sender wastes rts_max_retries before rts_giveup.
--
-- Mitigation: every node maintains self.blind_until[node_id] →
-- absolute_ms, populated by overhearing every CTS frame on routing_sf
-- (whether addressed to us or not). meta.src on the on_recv callback
-- gives us the CTS-sender's id; the CTS payload carries chosen_data_sf
-- so we can compute the upper-bound blind window:
--   blind_window = cts_to_data_gap_ms
--                + airtime(chosen_data_sf, max DATA frame)
--
-- Three call sites consult the table before TX'ing an RTS:
--   • issue_send       (proactive — first attempt)
--   • tx_rts_retry     (proactive — every retry)
--   • rts_timeout_fire (reactive — when timeout fires, re-check)
--
-- When the next-hop is blind, the decision is:
--   • have alt route + alt not yet tried + alt not also blind
--                                          → switch to alt (free budget)
--   • else                                  → defer until blind window ends
--
-- Plus exponential backoff on rts_timeout_ms (×2 per attempt, capped at
-- ×RTS_TIMEOUT_BACKOFF_CAP) so the existing retry budget covers a full
-- receiver blind window even when the CTS itself is lost in flight and
-- the overhearing mechanism never fires.
--
-- New emits: blind_observed (every CTS overheard whose chosen_data_sf
-- extends our recorded blind window for that sender), tx_blind_defer
-- (every defer fired), tx_blind_alt (every alt-switch from blind state,
-- distinct from NACK-driven path_switch).
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
--     STATUS: addressed via passive CTS overhearing — see "F1 mitigation"
--     section above. Residual case: CTS lost in flight (overhearing
--     mechanism never fires). Partially covered by exponential
--     rts_timeout backoff (I-section), giving the receiver's
--     pending_rx_expiry time to fire and clear, after which a late
--     retry succeeds.
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
--     STATUS: I1 (separate retry budgets) still future work.
--
-- F3. rts_timeout is dimensioned for one-shot RTS+CTS, not for "wait for
--     the network to free up"
--     With short SFs (SF8 routing → ~44ms RTS, SF9 data → ~78ms CTS) the
--     rts_timeout is ~122ms. Three retries cover ~366ms — much shorter
--     than a 4-hop SF9 flight (~hundreds of ms × 4 hops). When the chosen
--     next-hop is mid-relay, this budget always expires first.
--
--     STATUS: partially addressed by the exponential rts_timeout
--     backoff added with the F1 mitigation. Cumulative wait now
--     scales (122 → 244 → 488ms cap) instead of staying flat.
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
--     STATUS: superseded by both NACK (already implemented) and the
--     F1 mitigation's passive blind_until table.
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
--     STATUS: superseded by NACK; the queue-extension path is no
--     longer needed because NACK already gives senders a busy-feedback
--     signal and the F1 blind_until lets them avoid the deaf-hop
--     entirely.
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
-- BCN — 4-byte header + n × 4-byte entries:
--   byte 0 : tag 'B'
--   byte 1 : network_id (4 hi nibble) | reserved (4 lo nibble)
--   byte 2 : src (8)
--   byte 3 : n (8)
--   entries (4 B each): dest(8) + next(8) + score_i8(8) + hops(8)
-- network_id (4 bits): same field as RTS. Receivers reject foreign-
-- network beacons before rt_merge so foreign nodes don't pollute our
-- routing tables.
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
  local nid_byte = (node.network_id & 0xf) << 4
  local total = #all_dests
  if total == 0 then
    return "B" .. string.char(nid_byte) .. string.char(node.id) .. string.char(0), 0
  end

  -- Take a contiguous page starting at offset, wrapping around.
  local n = math.min(max_entries, total)
  local page = {}
  for i = 0, n - 1 do
    local idx = ((offset + i) % total) + 1
    table.insert(page, all_dests[idx])
  end

  local out = "B" .. string.char(nid_byte) .. string.char(node.id) .. string.char(n)
  for _, dest_id in ipairs(page) do
    local p = node.rt[dest_id].candidates[1]
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
  if #frame < 4 or frame:sub(1,1) ~= "B" then return nil end
  local nid = (frame:byte(2) >> 4) & 0xf
  local src = frame:byte(3)
  local n   = frame:byte(4)
  if #frame < 4 + 4*n then return nil end
  local entries = {}
  local pos = 5
  for _ = 1, n do
    local dest = frame:byte(pos)
    local nxt  = frame:byte(pos + 1)
    local sb   = frame:byte(pos + 2)
    local score = (sb >= 128) and (sb - 256) or sb
    local hops = frame:byte(pos + 3)
    table.insert(entries, { dest = dest, next = nxt, score = score, hops = hops })
    pos = pos + 4
  end
  return { network_id = nid, src = src, entries = entries }
end

-- Quantize an SNR (dB) to a 4-bit bucket [0..15] for byte-tight ACK
-- piggyback. 16 buckets, 2 dB per bin, range -20..+10 dB:
--   bucket  0: snr <= -20 dB
--   bucket 15: snr >= +10 dB
-- Range chosen to span LoRa demod thresholds (SF12 = -20, SF7 = -7.5)
-- with 5 buckets of headroom above SF7 for "easy decode" signal.
-- The decode helper returns the BIN CENTER so EWMAs/comparisons treat
-- quantization as fair rounding, not systematic bias toward bin lower edge.
local function bucket_of_snr_4b(snr_db)
  local b = math.floor((snr_db + 20) / 2)
  if b < 0 then b = 0 end
  if b > 15 then b = 15 end
  return b
end

local function snr_of_bucket_4b(bucket)
  return -19 + bucket * 2  -- -19, -17, ..., +9, +11 (bin centers)
end

-- Update a per-neighbor SNR EWMA in-place. First sample seeds the EWMA
-- (no warmup ramp); subsequent samples blend with `alpha`. Default alpha
-- 0.3 → ~10-sample effective window.
local function update_snr_ewma(table_, nbr_id, snr_db, alpha)
  local prev = table_[nbr_id]
  if prev == nil then
    table_[nbr_id] = snr_db
  else
    table_[nbr_id] = alpha * snr_db + (1 - alpha) * prev
  end
end

-- payload_len is the exact byte count the upcoming DATA frame will carry
-- in its variable-length suffix (origin-seq header + user_text). The
-- receiver uses it to size pending_rx_expiry to actual airtime instead
-- of the worst-case (max_payload_bytes), which mattered when payloads
-- range 10–200 bytes — real protocols can't afford to budget every
-- flight at the absolute upper bound.
-- RTS — 8 bytes, bit-packed:
--   byte 0 : tag 'R'
--   byte 1 : origin (8)
--   byte 2 : src    (8)
--   byte 3 : dst    (8)
--   byte 4 : next   (8)
--   byte 5 : network_id (4 hi nibble) | msg_id (4 lo nibble)
--   byte 6 : sf_bitmap (8)
--   byte 7 : payload_len (8)
local function pack_rts(network_id, origin, src, dst, next_hop, msg_id, sf_bitmap, payload_len)
  local b5 = ((network_id & 0xf) << 4) | (msg_id & 0xf)
  return "R" .. string.char(origin) .. string.char(src) .. string.char(dst)
              .. string.char(next_hop)
              .. string.char(b5)
              .. string.char(sf_bitmap)
              .. string.char(payload_len % 256)
end

local function parse_rts(frame)
  if #frame < 8 or frame:sub(1,1) ~= "R" then return nil end
  local b5 = frame:byte(6)
  return {
    network_id  = (b5 >> 4) & 0xf,
    origin      = frame:byte(2),
    src         = frame:byte(3),
    dst         = frame:byte(4),
    next        = frame:byte(5),
    msg_id      = b5 & 0xf,
    sf_bitmap   = frame:byte(7),
    payload_len = frame:byte(8),
  }
end

-- CTS — 2 bytes, bit-packed:
--   byte 0 : tag 'C'
--   byte 1 : msg_id (4 hi nibble) | (chosen_data_sf - 5) (3) | reserved (1)
local function pack_cts(msg_id, chosen_data_sf)
  local sf_off = (chosen_data_sf - 5) & 0x7
  local b1 = ((msg_id & 0xf) << 4) | (sf_off << 1)
  return "C" .. string.char(b1)
end

local function parse_cts(frame)
  if #frame < 2 or frame:sub(1,1) ~= "C" then return nil end
  local b1 = frame:byte(2)
  return {
    msg_id         = (b1 >> 4) & 0xf,
    chosen_data_sf = ((b1 >> 1) & 0x7) + 5,
  }
end

-- ACK — 2 bytes, bit-packed:
--   byte 0 : tag 'K'
--   byte 1 : msg_id (4 hi nibble) | snr_bucket (4 lo nibble)
local function pack_ack(msg_id, snr_db)
  local bucket = (snr_db ~= nil) and bucket_of_snr_4b(snr_db) or 15
  local b1 = ((msg_id & 0xf) << 4) | (bucket & 0xf)
  return "K" .. string.char(b1)
end

local function parse_ack(frame)
  if #frame < 2 or frame:sub(1,1) ~= "K" then return nil end
  local b1 = frame:byte(2)
  local bucket = b1 & 0xf
  return {
    msg_id      = (b1 >> 4) & 0xf,
    snr_db      = snr_of_bucket_4b(bucket),
    snr_bucket  = bucket,
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

-- NACK — 4 bytes:
--   byte 0 : tag 'N'
--   byte 1 : reserved (4 hi nibble) | msg_id (4 lo nibble)
--   byte 2-3 : busy_for_ms (16-bit, lo first)
local function pack_nack(msg_id, busy_for_ms)
  if busy_for_ms < 0 then busy_for_ms = 0 end
  if busy_for_ms > 65535 then busy_for_ms = 65535 end
  return "N" .. string.char(msg_id & 0xf)
              .. string.char(busy_for_ms % 256)
              .. string.char(math.floor(busy_for_ms / 256) % 256)
end

local function parse_nack(frame)
  if #frame < 4 or frame:sub(1,1) ~= "N" then return nil end
  return {
    msg_id      = frame:byte(2) & 0xf,
    busy_for_ms = frame:byte(3) + frame:byte(4) * 256,
  }
end

-- DATA — 6-byte header + payload:
--   byte 0 : tag 'D'
--   byte 1 : origin (8)
--   byte 2 : src    (8)
--   byte 3 : dst    (8)
--   byte 4 : next   (8)
--   byte 5 : reserved (4 hi nibble) | msg_id (4 lo nibble)
--   byte 6+: payload
local function pack_data(origin, src, dst, next_hop, msg_id, payload)
  return "D" .. string.char(origin) .. string.char(src) .. string.char(dst)
              .. string.char(next_hop)
              .. string.char(msg_id & 0xf)
              .. payload
end

local function parse_data(frame)
  if #frame < 6 or frame:sub(1,1) ~= "D" then return nil end
  return {
    origin  = frame:byte(2),
    src     = frame:byte(3),
    dst     = frame:byte(4),
    next    = frame:byte(5),
    msg_id  = frame:byte(6) & 0xf,
    payload = frame:sub(7),
  }
end

-- ---------- airtime + retry plumbing ----------------------------------------

-- Frame-header lengths (excluding payload). Computed from the wire-format
-- table at top of file so airtime predictions stay precise as we extend the
-- protocol — bump these if the frame layout changes.
local RTS_LEN = 8       -- 'R' + origin + src + dst + next + (network_id<<4|msg_id) + sf_bitmap + payload_len
local CTS_LEN = 2       -- 'C' + (msg_id<<4 | (sf-5)<<1 | reserved_1)
local DATA_HDR_LEN = 6  -- 'D' + origin + src + dst + next + (reserved_4|msg_id_4) (payload follows)
local ACK_LEN = 2       -- 'K' + (msg_id<<4 | snr_bucket)
local NACK_LEN = 4      -- 'N' + (reserved_4|msg_id_4) + busy_for_ms_lo + busy_for_ms_hi

-- LoRa on-air time in milliseconds (Semtech AN1200.13). This is intentionally
-- in Lua (not exposed via a runtime binding) so the same code can be ported
-- to firmware later without depending on a host helper.
--
-- Maximum number of routes per destination kept in the routing table.
-- candidates[1] is the current primary; candidates[2..K] are alts
-- consulted by classify_blind (blind-window mitigation) and the
-- failure cascade in rts_timeout_fire / ack_timeout_fire.
local MAX_RT_CANDIDATES = 3

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
-- previous_hop, when non-nil (forwarder context), is the upstream node we
-- received the DATA from — never alt-switch back through it (that would
-- create a 2-hop loop).
local function classify_blind(self, dst_id, current_next_hop, alts_tried, previous_hop)
  local blind, remaining = is_blind(self, current_next_hop)
  if not blind then return "ok" end
  local entry = self.rt[dst_id]
  if not entry then return "defer", remaining + 1 end
  -- Walk the candidates list; skip the current next_hop, the previous_hop
  -- loop guard, any next_hop already tried (per pending_tx.alts_tried),
  -- and any candidate currently in a blind window. alts_tried is a
  -- table-as-set keyed by next_hop id; nil/empty means "nothing tried
  -- yet" so the first non-blind alt qualifies.
  for _, c in ipairs(entry.candidates) do
    if c.next_hop ~= current_next_hop
       and not (alts_tried and alts_tried[c.next_hop])
       and c.next_hop ~= previous_hop
       and not is_blind(self, c.next_hop) then
      return "alt", c.next_hop
    end
  end
  return "defer", remaining + 1
end

-- Duty-cycle pre-check. Returns (ok, wait_ms). When ok=true, the TX may
-- proceed; the runtime's airtime log will absorb it. When ok=false, the
-- caller should self:after(wait_ms, retry_callback) and re-check on fire.
-- The runtime also hard-blocks via on_radio_busy(reason="duty_cycle_exceeded")
-- as a safety net; this pre-check exists so the script defers proactively
-- instead of waiting for the round-trip and retrying via on_radio_busy.
-- Pre-check uses the same data the runtime uses, queried via the
-- self:airtime_used_ms / self:oldest_tx_end_ms primitives — composes for free.
local function check_duty_cycle(self, this_airtime_ms)
  if not self.duty_cycle or self.duty_cycle <= 0
     or not self.duty_cycle_window_ms or self.duty_cycle_window_ms <= 0 then
    return true, 0   -- disabled
  end
  local used = self:airtime_used_ms(self.duty_cycle_window_ms)
  if used + this_airtime_ms <= self.duty_cycle_budget_ms then
    return true, 0
  end
  -- Over budget. Compute when the oldest in-window entry falls out
  -- (oldest_end_ms + window_ms). That's the earliest moment a fresh TX
  -- of any size could fit — under-estimate when severely over budget,
  -- script will recheck on retry.
  local oldest = self:oldest_tx_end_ms()
  local now = self:now()
  local wait_ms = (oldest > 0)
                  and (oldest + self.duty_cycle_window_ms - now)
                  or self.duty_cycle_window_ms
  if wait_ms < 1 then wait_ms = 1 end   -- guarantee forward progress
  return false, wait_ms, used
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
  -- Pre-check duty cycle. If over budget, defer via self:after — the
  -- on_radio_busy retry path handles the late retry too (runtime
  -- hard-block fires the same way), but pre-checking saves the wasted
  -- runtime round-trip and surfaces a clean telemetry event.
  local sf_used = opts.sf or self.routing_sf
  local airtime = airtime_ms(sf_used, self.bw_hz, self.cr,
                              self.preamble_sym, #bytes)
  local ok, wait_ms, used_ms = check_duty_cycle(self, airtime)
  if not ok then
    self:emit("duty_cycle_blocked", {
      label      = label,
      airtime_ms = airtime,
      used_ms    = used_ms,
      budget_ms  = self.duty_cycle_budget_ms,
      window_ms  = self.duty_cycle_window_ms,
      wait_ms    = wait_ms,
      source     = "tx_with_retry",
    })
    self:after(wait_ms, function() tx_with_retry(self, bytes, opts) end)
    return
  end
  self:tx(bytes, opts)
end

-- ---------- TX policy classes -----------------------------------------------
-- Three policy classes for outgoing frames:
--
--   1. RESPONSE-DIRECTED  (CTS, DATA, ACK)
--      The peer's timer (rts_timeout, ack_timeout, pending_rx_expiry) is
--      already running and was sized to the *minimum* round-trip airtime.
--      Any LBT defer here pushes us past the peer's timeout → flight burns
--      a retry. So these go straight through tx_with_retry; the simulator's
--      reactive radio_busy stash is the only safety net.
--
--   2. INITIATING-DIRECTED  (RTS, NACK)
--      Sender owns the schedule. We can defer freely — RTS retries are
--      bounded by rts_max_retries; NACK is informational and a missing one
--      just means the peer keeps retrying RTS (which we'll catch next
--      time). Pre-checks self:channel_busy_until() and, if busy, schedules
--      the actual emit at busy_until + rand(0, retry_jitter_ms). Reduces
--      the head-on-collision rate on tight links and decorrelates retry
--      storms across nodes whose timers fire on the same step.
--
--   3. FLOOD  (Beacon)
--      No specific peer is waiting; lost beacons are recovered by the next
--      periodic / triggered fire. Pre-checks the channel like (2). If the
--      busy window exceeds flood_lbt_max_defer_ms, the page is dropped
--      entirely (tx_flood_skipped) — no point queueing a stale routing
--      announcement when a fresher one will fire shortly.
--
-- All three still set pending_tx (where applicable) BEFORE the actual emit,
-- so peer NACK / busy-replies still match the right msg_id; the LBT defer
-- only delays when the bits hit the air.

-- Used by INITIATING-DIRECTED frames (RTS, NACK). LBT-gated, but only as
-- a SINGLE politeness wait — at saturated load (s03 @ 62.5 kHz) the
-- channel-busy window never clears, so a "wait until clear" loop just
-- locks pending_tx forever. Real LoRa CSMA-CA behaves the same way:
-- sense once, defer briefly, then commit even if still busy. Implemented
-- via opts.__lbt_done so the recursive after-callback skips the re-check.
-- Optional `after_tx` fires the instant the bytes are handed to the radio
-- — RTS callers use this to start rts_timeout from the *actual* TX time,
-- otherwise the timer can fire mid-defer and burn a retry for nothing.
local function tx_initiating(self, bytes, opts, after_tx)
  if self.lbt_enabled and not opts.__lbt_done then
    local busy_until = self:channel_busy_until() or 0
    if busy_until > self:now() then
      opts.__lbt_done = true
      local delay = self:rand(1, self.retry_jitter_ms + 1)
      self:emit("tx_lbt_defer", {
        label = opts.label, kind = "initiating",
        defer_ms = delay, busy_until_ms = busy_until,
      })
      self:after(delay, function() tx_initiating(self, bytes, opts, after_tx) end)
      return
    end
  end
  tx_with_retry(self, bytes, opts)
  if after_tx then after_tx() end
end

-- Used by FLOOD frames (beacons). Same LBT pre-check as initiating, but
-- with a max-defer cap: if the channel will be busy longer than
-- flood_lbt_max_defer_ms, drop this page (tx_flood_skipped emit). The
-- next periodic / triggered fire rotates the offset and re-broadcasts.
local function tx_flood(self, bytes, opts)
  -- Duty-cycle pre-check. Beacons are FLOOD-class — non-critical; if we'd
  -- breach budget, drop this page and rely on the next periodic /
  -- triggered fire. Matches the existing flood_lbt_max_defer_ms drop
  -- semantics: stale routing info is worse than a missed beacon.
  do
    local sf_used = opts.sf or self.routing_sf
    local airtime = airtime_ms(sf_used, self.bw_hz, self.cr,
                                self.preamble_sym, #bytes)
    local ok, wait_ms, used_ms = check_duty_cycle(self, airtime)
    if not ok then
      self:emit("duty_cycle_blocked", {
        label = opts.label, airtime_ms = airtime,
        used_ms = used_ms, budget_ms = self.duty_cycle_budget_ms,
        window_ms = self.duty_cycle_window_ms, wait_ms = wait_ms,
        source = "tx_flood", action = "skip",
      })
      return false
    end
  end
  if self.lbt_enabled then
    local now        = self:now()
    local busy_until = self:channel_busy_until() or 0
    local wait       = busy_until - now
    if wait > self.flood_lbt_max_defer_ms then
      self:emit("tx_flood_skipped", {
        label = opts.label, busy_for_ms = wait,
      })
      return false
    end
    if wait > 0 then
      local delay = wait + self:rand(0, self.retry_jitter_ms + 1)
      self:emit("tx_lbt_defer", {
        label = opts.label, kind = "flood",
        defer_ms = delay, busy_until_ms = busy_until,
      })
      self:after(delay, function() self:tx(bytes, opts) end)
      return true
    end
  end
  self:tx(bytes, opts)
  return true
end

-- ---------- routing helpers --------------------------------------------------

local function rt_count(rt)
  local c = 0
  for _ in pairs(rt) do c = c + 1 end
  return c
end

-- Strict-better comparison on routes. Two-tier ordering:
--   1. Viability: a route's chain-min SNR (`score`) must clear the routing-
--      plane demod threshold + margin to be considered "decodable end-to-
--      end" on the control plane. A viable route always beats a non-viable
--      one regardless of hops — a 1-hop link that can't actually decode is
--      worse than an 8-hop chain whose every link can.
--   2. Within the same viability tier: fewer hops wins, score breaks ties.
--      Hops-first matches standard DV ordering (RIP/OSPF/AODV) and LoRa-
--      mesh reality — each hop is another full RTS/CTS/DATA/ACK exchange,
--      so a longer path is materially more failure-prone even at a
--      marginally better per-link SNR.
-- Returns false on full tie (caller decides via slot/n2_hop logic).
local function route_strictly_better(a, b, viab_db)
  local av = a.score >= viab_db
  local bv = b.score >= viab_db
  if av and not bv then return true end
  if bv and not av then return false end
  if av and bv then
    -- both viable: hops-first, score breaks ties (RIP/OSPF/AODV order)
    if a.hops < b.hops then return true end
    if a.hops > b.hops then return false end
    return a.score > b.score
  else
    -- both non-viable: score-first (least-worst link), hops breaks ties.
    -- Hops-first here would prefer a 1-hop dead link over a 2-hop slightly-
    -- less-dead path; that's worse, so flip the order in this tier.
    if a.score > b.score then return true end
    if a.score < b.score then return false end
    return a.hops < b.hops
  end
end

-- Top-K DV merge (K = MAX_RT_CANDIDATES). Caller has already filtered
-- cand for hop-cap and split-horizon. Returns one of:
--   "new"             — first route to this destination
--   "promote"         — cand became candidates[1] (was new or moved up)
--   "primary_refresh" — cand has same next_hop as candidates[1] and is
--                        better; refreshed in place
--   "alt_install"     — cand landed in candidates[2..K] (was lower or new)
--   "no_change"       — cand can't displace anything
local function rt_merge(rt, dest_id, cand, viab_db)
  local entry = rt[dest_id]
  if entry == nil then
    rt[dest_id] = { candidates = { cand } }
    return "new"
  end

  -- Match-by-next_hop: refresh in place if cand strictly better.
  for i, c in ipairs(entry.candidates) do
    if c.next_hop == cand.next_hop then
      if route_strictly_better(cand, c, viab_db) then
        local was_primary = (i == 1)
        entry.candidates[i] = cand
        table.sort(entry.candidates, function(a, b)
          return route_strictly_better(a, b, viab_db) or
                 (not route_strictly_better(b, a, viab_db) and a.score > b.score)
        end)
        local now_primary = (entry.candidates[1].next_hop == cand.next_hop)
        if now_primary then
          return "primary_refresh"
        elseif was_primary then
          return "promote"  -- some other candidate is now primary
        end
        return "alt_install"
      end
      -- Equal/worse but same next_hop: refresh metadata, no order change.
      c.last_seen_ms = cand.last_seen_ms
      c.n2_hop       = cand.n2_hop
      return "no_change"
    end
  end

  -- New next_hop, room to spare.
  if #entry.candidates < MAX_RT_CANDIDATES then
    table.insert(entry.candidates, cand)
    table.sort(entry.candidates, function(a, b)
      return route_strictly_better(a, b, viab_db) or
             (not route_strictly_better(b, a, viab_db) and a.score > b.score)
    end)
    if entry.candidates[1].next_hop == cand.next_hop then
      return "promote"
    end
    return "alt_install"
  end

  -- Full table — replace the worst (last in sorted order) only if cand
  -- strictly beats it.
  local worst = entry.candidates[#entry.candidates]
  if not route_strictly_better(cand, worst, viab_db) then
    return "no_change"
  end
  entry.candidates[#entry.candidates] = cand
  table.sort(entry.candidates, function(a, b)
    return route_strictly_better(a, b, viab_db) or
           (not route_strictly_better(b, a, viab_db) and a.score > b.score)
  end)
  if entry.candidates[1].next_hop == cand.next_hop then
    return "promote"
  end
  return "alt_install"
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
  -- 4-bit per-(originator) flight counter, wraps at 16. The 4-bit RTS
  -- field can no longer carry the historic node_id<<8 prefix; per-msg
  -- uniqueness is recoverable from (node, msg_id, time) tuples in event
  -- logs. Hop-level dedup uses last_acked_from with a TTL to handle
  -- wraparound at any realistic send rate.
  local mid = self.next_msg_id & 0xf
  self.next_msg_id = (self.next_msg_id + 1) & 0xf
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
-- claims to route D through me. If any of my own rt[D] candidates stores
-- n2_hop == N, that slot is part of a 3-cycle me→X→N→me — invalidate it.
-- Walks the candidates list, dropping any whose n2_hop == sender_id; if
-- all candidates are pruned, the entry is removed entirely (no route is
-- better than a looped one — packets give up at source instead of wasting
-- airtime). On any actual mutation, schedule a triggered beacon so
-- neighbors discover the change quickly.
local function rt_prune_cycle(self, dest_id, sender_id)
  local entry = self.rt[dest_id]
  if entry == nil then return end
  local mutated = false
  local kept = {}
  for i, c in ipairs(entry.candidates) do
    if c.n2_hop == sender_id then
      local slot = (i == 1) and "primary" or "alt"
      self:emit("rt_prune", {
        dest = dest_id, slot = slot, reason = "3cycle",
        via = c.next_hop, n2 = sender_id,
      })
      self:log(string.format("rt[%s] %s pruned (3cycle via %s→%s)",
        name_of(self, dest_id), slot,
        name_of(self, c.next_hop), name_of(self, sender_id)))
      mutated = true
    else
      table.insert(kept, c)
    end
  end
  if mutated then
    if #kept == 0 then
      self.rt[dest_id] = nil
    else
      entry.candidates = kept
    end
    schedule_triggered_beacon(self)
  end
end

-- Forward decls so the timeout-fire callbacks can refer to peers in the
-- retry/queue cluster (Lua needs the local in scope first).
local start_rts_timeout
local start_ack_timeout
local start_pending_rx_expiry
local issue_send
local become_free
local try_drain_deferred

-- Look up the next non-tried, non-blind candidate for this pending_tx
-- destination. Returns the next_hop id if found, or nil if every
-- candidate has been tried / is blind / is the upstream we came from.
-- Used by the failure cascade in rts_timeout_fire and ack_timeout_fire
-- to walk through K=MAX_RT_CANDIDATES alternatives.
local function pick_next_cascade_hop(self, px)
  local entry = self.rt[px.dst]
  if not entry then return nil end
  for _, c in ipairs(entry.candidates) do
    if c.next_hop ~= px.previous_hop
       and not px.alts_tried[c.next_hop]
       and not is_blind(self, c.next_hop) then
      return c.next_hop
    end
  end
  return nil
end

-- Count entries in a table-as-set (keys are next_hop ids, values true).
-- Used to populate the path_cascade event's "attempt" field.
local function set_size(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- Re-send the current pending_tx's RTS with the same msg_id. Shared by
-- rts_timeout_fire (CTS lost) and ack_timeout_fire (DATA-ACK lost): both
-- recover by re-running the dance from the beginning. Caller must have
-- already decremented retries_left and confirmed the giveup case.
local function tx_rts_retry(self, reason)
  local px = self.pending_tx
  -- pending_tx can be cleared between when a blind-defer was scheduled
  -- and when its self:after callback fires (e.g., the ACK arrived during
  -- the defer window). Bail out gracefully — no flight to retry.
  if px == nil then return end

  -- F1 mitigation: if next-hop is now known-blind, defer the retry or
  -- switch to alt. Reset retries budget on alt-switch (fresh path).
  local action_b, val_b = classify_blind(self, px.dst, px.next, px.alts_tried,
                                          px.previous_hop)
  if action_b == "defer" then
    self:emit("tx_blind_defer", {
      origin = px.origin, payload = px.user_text, origin_seq = px.origin_seq,
      msg_id = px.msg_id, next_hop = px.next, delay_ms = val_b,
      source = "tx_rts_retry", reason = reason,
    })
    self:log(string.format("tx_blind_defer (tx_rts_retry) msg=%d -> %s deferred %dms",
      px.msg_id, name_of(self, px.next), val_b))
    self:after(val_b, function() tx_rts_retry(self, reason) end)
    return
  elseif action_b == "alt" then
    self:emit("tx_blind_alt", {
      origin = px.origin, payload = px.user_text, origin_seq = px.origin_seq,
      msg_id = px.msg_id, from_next = px.next, to_next = val_b,
    })
    self:log(string.format("tx_blind_alt (tx_rts_retry) msg=%d %s -> %s",
      px.msg_id, name_of(self, px.next), name_of(self, val_b)))
    px.alts_tried[px.next] = true   -- mark previous next_hop as tried
    px.next = val_b
    px.retries_left = self.rts_max_retries
  end

  -- payload_len lets the receiver size its pending_rx_expiry to the
  -- actual DATA airtime instead of max_payload_bytes worst-case.
  local rts = pack_rts(self.network_id, px.origin, self.id, px.dst, px.next, px.msg_id,
                       self.allowed_sf_bitmap, #px.payload)
  self:emit("rts_retry", {
    origin = px.origin, payload = px.user_text, origin_seq = px.origin_seq,
    dst = px.dst, next = px.next,
    msg_id = px.msg_id, retries_left = px.retries_left, reason = reason,
  })
  self:log(string.format("rts_retry -> %s msg_id=%d (retries_left=%d reason=%s)",
    name_of(self, px.next), px.msg_id, px.retries_left, reason))
  tx_initiating(self, rts, {
    sf    = self.routing_sf,
    label = "RTS-rty",
    info  = string.format("retry next=%s msg=%d retries_left=%d reason=%s",
      name_of(self, px.next), px.msg_id, px.retries_left, reason),
  }, function() start_rts_timeout(self) end)
  -- RX stays on routing_sf — both CTS and NACK are control-plane responses
  -- on routing_sf now, no retune needed until DATA is about to TX.
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

  -- F1 mitigation: receiver may have just become blind (we overheard a
  -- CTS to a different sender after our RTS-tx and before the timeout).
  -- Defer or alt-switch instead of wasting a retry attempt against a
  -- deaf hop.
  local action_b, val_b = classify_blind(self,
                                          self.pending_tx.dst,
                                          self.pending_tx.next,
                                          self.pending_tx.alts_tried,
                                          self.pending_tx.previous_hop)
  if action_b == "defer" then
    self:emit("tx_blind_defer", {
      origin = self.pending_tx.origin, payload = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      msg_id = captured_msg_id, next_hop = self.pending_tx.next,
      delay_ms = val_b, source = "rts_timeout",
    })
    self:log(string.format("tx_blind_defer (rts_timeout) msg=%d -> %s deferred %dms",
      captured_msg_id, name_of(self, self.pending_tx.next), val_b))
    self:after(val_b, function()
      rts_timeout_fire(self, captured_msg_id)
    end)
    return
  elseif action_b == "alt" then
    self:emit("tx_blind_alt", {
      origin = self.pending_tx.origin, payload = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      msg_id = captured_msg_id,
      from_next = self.pending_tx.next, to_next = val_b,
    })
    self:log(string.format("tx_blind_alt (rts_timeout) msg=%d %s -> %s",
      captured_msg_id, name_of(self, self.pending_tx.next), name_of(self, val_b)))
    self.pending_tx.alts_tried[self.pending_tx.next] = true
    self.pending_tx.next = val_b
    self.pending_tx.retries_left = self.rts_max_retries
    tx_rts_retry(self, "blind_alt")
    return
  end

  if self.pending_tx.retries_left <= 0 then
    -- K=3 failure cascade: mark the current next_hop tried, walk to
    -- the next non-tried candidate. If found, switch + reset retries.
    -- Else emit path_cascade_exhausted alongside the legacy rts_giveup
    -- event and clear pending_tx (true giveup).
    self.pending_tx.alts_tried[self.pending_tx.next] = true
    local next_hop = pick_next_cascade_hop(self, self.pending_tx)
    if next_hop ~= nil then
      local prev_next = self.pending_tx.next
      self:emit("path_cascade", {
        origin     = self.pending_tx.origin,
        payload    = self.pending_tx.user_text,
        origin_seq = self.pending_tx.origin_seq,
        dst        = self.pending_tx.dst, msg_id = captured_msg_id,
        from_next  = prev_next, to_next = next_hop,
        attempt    = set_size(self.pending_tx.alts_tried),
        trigger    = "rts_giveup",
      })
      self:log(string.format("path_cascade msg=%d %s -> %s (rts_giveup)",
        captured_msg_id, name_of(self, prev_next), name_of(self, next_hop)))
      self.pending_tx.next         = next_hop
      self.pending_tx.retries_left = self.rts_max_retries
      tx_rts_retry(self, "cascade_rts")
      return
    end
    -- All K candidates exhausted. Emit the tracking event + the legacy
    -- giveup event for compatibility, then clear pending_tx.
    local tried_list = {}
    for nh, _ in pairs(self.pending_tx.alts_tried) do
      table.insert(tried_list, nh)
    end
    self:emit("path_cascade_exhausted", {
      origin     = self.pending_tx.origin,
      payload    = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      dst        = self.pending_tx.dst, msg_id = captured_msg_id,
      tried      = tried_list, trigger = "rts_giveup",
    })
    self:emit("rts_giveup", {
      origin     = self.pending_tx.origin,
      payload    = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      dst        = self.pending_tx.dst,
      next       = self.pending_tx.next,
      msg_id     = captured_msg_id,
    })
    self:log(string.format("path_cascade_exhausted msg=%d dst=%s tried=%d (rts_giveup)",
      captured_msg_id, name_of(self, self.pending_tx.dst), #tried_list))
    self.pending_tx = nil
    become_free(self)
    return
  end

  self.pending_tx.retries_left = self.pending_tx.retries_left - 1
  -- Random backoff before re-firing the RTS. Without this, every node
  -- whose CTS got clobbered in the same collision will retry on the same
  -- step (rts_timeout = exact RTS+CTS airtime, deterministic), so the
  -- collision repeats. self:rand(0, retry_jitter_ms) decorrelates retries
  -- across nodes by up to one RTS-airtime worth of slack.
  local captured = captured_msg_id
  local jitter = self:rand(0, self.retry_jitter_ms + 1)
  if jitter == 0 then
    tx_rts_retry(self, "cts_timeout")
  else
    self:after(jitter, function()
      if self.pending_tx ~= nil and self.pending_tx.msg_id == captured then
        tx_rts_retry(self, "cts_timeout")
      end
    end)
  end
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
    -- K=3 failure cascade — same logic as the rts_timeout giveup branch
    -- but triggered by ack-loss. Walk the candidates list for a
    -- non-tried alternative; emit path_cascade or path_cascade_exhausted.
    self.pending_tx.alts_tried[self.pending_tx.next] = true
    local next_hop = pick_next_cascade_hop(self, self.pending_tx)
    if next_hop ~= nil then
      local prev_next = self.pending_tx.next
      self:emit("path_cascade", {
        origin     = self.pending_tx.origin,
        payload    = self.pending_tx.user_text,
        origin_seq = self.pending_tx.origin_seq,
        dst        = self.pending_tx.dst, msg_id = captured_msg_id,
        from_next  = prev_next, to_next = next_hop,
        attempt    = set_size(self.pending_tx.alts_tried),
        trigger    = "ack_giveup",
      })
      self:log(string.format("path_cascade msg=%d %s -> %s (ack_giveup)",
        captured_msg_id, name_of(self, prev_next), name_of(self, next_hop)))
      self.pending_tx.next         = next_hop
      self.pending_tx.retries_left = self.rts_max_retries
      tx_rts_retry(self, "cascade_ack")
      return
    end
    local tried_list = {}
    for nh, _ in pairs(self.pending_tx.alts_tried) do
      table.insert(tried_list, nh)
    end
    self:emit("path_cascade_exhausted", {
      origin     = self.pending_tx.origin,
      payload    = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      dst        = self.pending_tx.dst, msg_id = captured_msg_id,
      tried      = tried_list, trigger = "ack_giveup",
    })
    self:emit("data_ack_giveup", {
      origin     = self.pending_tx.origin,
      payload    = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      dst        = self.pending_tx.dst,
      next       = self.pending_tx.next,
      msg_id     = captured_msg_id,
    })
    self:log(string.format("path_cascade_exhausted msg=%d dst=%s tried=%d (ack_giveup)",
      captured_msg_id, name_of(self, self.pending_tx.dst), #tried_list))
    self.pending_tx = nil
    become_free(self)
    return
  end

  self.pending_tx.retries_left = self.pending_tx.retries_left - 1
  -- Same random backoff as cts_timeout — see comment there.
  local captured = captured_msg_id
  local jitter = self:rand(0, self.retry_jitter_ms + 1)
  if jitter == 0 then
    tx_rts_retry(self, "ack_timeout")
  else
    self:after(jitter, function()
      if self.pending_tx ~= nil and self.pending_tx.msg_id == captured then
        tx_rts_retry(self, "ack_timeout")
      end
    end)
  end
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
  -- F1 mitigation safety net: exponential backoff per retry attempt.
  -- attempt_idx = how many retries we've already burned on this msg_id.
  -- Fresh budget (issue_send / NACK alt / blind alt) → attempt_idx = 0
  -- → base timeout. Each subsequent retry doubles up to RTS_TIMEOUT_BACKOFF_CAP.
  local attempt_idx = self.rts_max_retries - self.pending_tx.retries_left
  local timeout_ms = rts_timeout_for_attempt(self.rts_timeout_ms, attempt_idx)
  local captured_msg_id = self.pending_tx.msg_id
  self.rts_timeout_handle = self:after(timeout_ms, function()
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
  -- Use the actual payload_len carried by RTS (set in pending_rx by the
  -- RTS handler). Falls back to max_payload_bytes for older callers /
  -- malformed frames. Sizing the expiry to actual airtime instead of
  -- worst-case avoids freezing pending_rx for ~2× longer than needed
  -- when payloads are small (10–50 bytes) — the worst-case budget
  -- otherwise blocks other flights from being received.
  local pl = self.pending_rx.payload_len or self.max_payload_bytes
  local data_air = airtime_ms(chosen, self.bw_hz, self.cr,
                              self.preamble_sym, DATA_HDR_LEN + pl)
  local expiry_ms = cts_air + self.cts_to_data_gap_ms + data_air
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
-- Walk self.deferred_sends. For each entry: if rt[dst] now exists, push
-- back to head of tx_queue (preserves user-issued order across multiple
-- deferred sends) and emit send_drained. If TTL elapsed, drop and emit
-- send_giveup. Called from on_recv 'B' (after merges) and from a 1s
-- periodic timer scheduled in on_init.
try_drain_deferred = function(self)
  if #self.deferred_sends == 0 then return end
  local now = self:now()
  local kept = {}
  local drained = {}
  for _, d in ipairs(self.deferred_sends) do
    if self.rt[d.dst_id] ~= nil then
      table.insert(drained, d)
    elseif (now - d.queued_at_ms) >= self.send_defer_ttl_ms then
      self:emit("send_giveup", {
        origin     = d.origin, dst = d.dst_id, dst_name = d.dst_name,
        payload    = d.user_text, origin_seq = d.origin_seq,
        waited_ms  = now - d.queued_at_ms,
        reason     = "defer_ttl",
      })
      self:log(string.format(
        "send_giveup dst=%s waited=%dms (defer TTL %dms expired without route)",
        d.dst_name, now - d.queued_at_ms, self.send_defer_ttl_ms))
    else
      table.insert(kept, d)
    end
  end
  self.deferred_sends = kept
  if #drained > 0 then
    -- Re-queue head-first so the original order is preserved.
    for i = #drained, 1, -1 do
      local d = drained[i]
      self:emit("send_drained", {
        origin     = d.origin, dst = d.dst_id, dst_name = d.dst_name,
        payload    = d.user_text, origin_seq = d.origin_seq,
        waited_ms  = now - d.queued_at_ms,
      })
      self:log(string.format(
        "send_drained dst=%s waited=%dms (route appeared) → tx_queue",
        d.dst_name, now - d.queued_at_ms))
      table.insert(self.tx_queue, 1, d)
    end
    become_free(self)
  end
end

-- payload here is the FULL bytes (origin-seq header + user_text) — what
-- goes on the wire. user_text is what the user / visualizer sees in
-- emit data. origin_seq is the 16-bit per-origin counter (set at
-- on_command for new sends, preserved across forwards).
issue_send = function(self, origin, dst_id, dst_name, payload, user_text, origin_seq, previous_hop)
  local entry = self.rt[dst_id]
  if not entry then
    -- Forwarder mid-flight with no route: real failure (route went stale
    -- between when we accepted the DATA and when we tried to forward it).
    -- Drop with the existing send_no_route — the originator's app-layer
    -- end-to-end retry is the recovery path here.
    if previous_hop ~= nil then
      self:emit("send_no_route", {
        origin = origin, payload = user_text, origin_seq = origin_seq, dst = dst_id,
      })
      self:log(string.format("send_no_route dst=%s (forwarder, route gone mid-flight)",
        dst_name))
      return
    end
    -- Originator with no route: defer up to send_defer_ttl_ms for the
    -- route to appear (e.g., new node still bootstrapping). The drain
    -- loop (periodic + on_recv 'B' hook) will retry on rt_update.
    table.insert(self.deferred_sends, {
      origin       = origin, dst_id = dst_id, dst_name = dst_name,
      payload      = payload, user_text = user_text, origin_seq = origin_seq,
      queued_at_ms = self:now(),
    })
    self:emit("send_deferred", {
      origin     = origin, dst = dst_id, dst_name = dst_name,
      payload    = user_text, origin_seq = origin_seq,
      ttl_ms     = self.send_defer_ttl_ms,
      depth      = #self.deferred_sends,
    })
    self:log(string.format(
      "send_deferred dst=%s (no route yet; holding for up to %dms; depth=%d)",
      dst_name, self.send_defer_ttl_ms, #self.deferred_sends))
    return
  end
  local primary_next = entry.candidates[1].next_hop
  -- F1 mitigation: if the chosen next-hop is currently blind on
  -- routing_sf (we overheard its CTS), either alt-switch or defer
  -- the issue. Defer re-queues at the head so ordering is preserved.
  -- previous_hop (forwarder context) prevents alt-switching back to
  -- the upstream node that just gave us the DATA — that would loop.
  local action_b, val_b = classify_blind(self, dst_id, primary_next, nil, previous_hop)
  -- Captures the original primary if F1 blind-alt fires below; that
  -- next_hop is then pre-populated into pending_tx.alts_tried so a
  -- later cascade doesn't bounce back to it before the blind window
  -- clears.
  local blind_skipped_primary = nil
  if action_b == "defer" then
    self:emit("tx_blind_defer", {
      origin = origin, payload = user_text, origin_seq = origin_seq,
      dst = dst_id, next_hop = primary_next, delay_ms = val_b,
      source = "issue_send",
    })
    self:log(string.format("tx_blind_defer (issue_send) -> %s deferred %dms",
      name_of(self, primary_next), val_b))
    table.insert(self.tx_queue, 1, {
      origin = origin, dst_id = dst_id, dst_name = dst_name,
      payload = payload, user_text = user_text, origin_seq = origin_seq,
      previous_hop = previous_hop,
    })
    self:after(val_b, function() become_free(self) end)
    return
  elseif action_b == "alt" then
    self:emit("tx_blind_alt", {
      origin = origin, payload = user_text, origin_seq = origin_seq,
      dst = dst_id, from_next = primary_next, to_next = val_b,
    })
    self:log(string.format("tx_blind_alt (issue_send) dst=%s %s -> %s",
      dst_name, name_of(self, primary_next), name_of(self, val_b)))
    blind_skipped_primary = primary_next
    primary_next = val_b
  end
  local mid = gen_msg_id(self)
  -- alts_tried: set keyed by next_hop id, cleared on successful ACK
  -- (pending_tx → nil via on_recv "K"). Pre-populate with the original
  -- primary if F1 blind-alt fired so the cascade doesn't try it again
  -- before the blind window clears.
  local initial_alts_tried = {}
  if blind_skipped_primary ~= nil then
    initial_alts_tried[blind_skipped_primary] = true
  end
  self.pending_tx = {
    origin       = origin,
    dst          = dst_id,
    next         = primary_next,
    msg_id       = mid,
    payload      = payload,        -- full bytes (origin-seq hdr + user_text)
    user_text    = user_text,      -- for emit + log clarity
    origin_seq   = origin_seq,     -- end-to-end message id (with origin)
    retries_left = self.rts_max_retries,
    alts_tried   = initial_alts_tried,
    chosen_data_sf = nil,        -- set when CTS arrives carrying the receiver's pick
    previous_hop = previous_hop, -- upstream node (nil at originator); blocks alt-loops
  }
  -- payload_len includes the 2-byte origin-seq header — see pack_rts.
  local rts = pack_rts(self.network_id, origin, self.id, dst_id, primary_next, mid,
                       self.allowed_sf_bitmap, #payload)
  local label = (origin == self.id) and "RTS" or "RTS-fwd"
  self:emit("rts_tx", {
    origin = origin, payload = user_text, origin_seq = origin_seq,
    dst = dst_id, next = primary_next, msg_id = mid,
    sf_bitmap = self.allowed_sf_bitmap,
  })
  self:log(string.format("rts_tx -> %s msg_id=%d origin=%s seq=%d (sf_bitmap=0x%02x)",
    name_of(self, primary_next), mid, name_of(self, origin), origin_seq,
    self.allowed_sf_bitmap))
  tx_initiating(self, rts, {
    sf    = self.routing_sf,
    label = label,
    info  = string.format("origin=%s dst=%s next=%s msg=%d seq=%d sf_bitmap=0x%02x payload=%q",
      name_of(self, origin), dst_name, name_of(self, primary_next),
      mid, origin_seq, self.allowed_sf_bitmap, user_text),
  }, function() start_rts_timeout(self) end)
  -- RX stays on routing_sf — CTS and NACK both ride on routing_sf now.
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
             item.payload, item.user_text, item.origin_seq, item.previous_hop)
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
  return tx_flood(self, frame, {
    sf    = self.routing_sf,
    label = "BCN",
    info  = string.format("rt=%d/%d off=%d kind=%s", page_n, total, self.beacon_offset, kind),
  })
end

-- Periodic beacon fire. Two-stage gate:
--   1. send_beacon_page handles the half-duplex skip (in a data exchange).
--   2. Adaptive throttle: if the channel has been busy within the last
--      `quiet_threshold_ms`, suppress this beacon entirely. Lets the
--      network self-throttle BCN airtime during dense traffic — analyzer
--      on s02 sparse showed BCN at 91% of all airtime; throttling expects
--      to claw most of that back.
-- After the throttle gate passes, the actual emission is deferred by
-- rand(0, beacon_silence_jitter_ms) and the silence is re-checked at the
-- deferred fire time. Defends against thundering herd when many nodes
-- simultaneously detect a busy→quiet transition.
local function beacon_fire(self)
  if self.pending_tx ~= nil or self.pending_rx ~= nil then
    -- Existing data-exchange skip — preserved verbatim from send_beacon_page's
    -- guard (we still call send_beacon_page below in the unthrottled path
    -- which double-checks; this branch logs the same reason).
    self:log("beacon_tx skipped (busy in data exchange)")
  elseif self.quiet_threshold_ms <= 0 then
    -- Throttle disabled (e.g., legacy tests that depend on rapid-fire
    -- beacons). Bypass both the gate AND the silence-jitter; behaviour
    -- is exactly what it was before the adaptive throttle was added.
    send_beacon_page(self, "periodic")
  else
    local since_rx = (self.last_rx_routing_sf_ms ~= nil)
                     and (self:now() - self.last_rx_routing_sf_ms)
                     or  math.huge   -- never received → effectively "quiet forever"
    if since_rx < self.quiet_threshold_ms then
      self:emit("beacon_skipped_busy", {
        since_rx_ms  = since_rx,
        threshold_ms = self.quiet_threshold_ms,
        stage        = "pre_jitter",
      })
      self:log(string.format(
        "beacon_tx skipped (channel busy: last RX %dms ago, threshold %dms)",
        since_rx, self.quiet_threshold_ms))
    else
      local jitter = (self.beacon_silence_jitter_ms > 0)
                     and self:rand(0, self.beacon_silence_jitter_ms + 1)
                     or  0
      if jitter == 0 then
        send_beacon_page(self, "periodic")
      else
        self:after(jitter, function()
          if self.pending_tx ~= nil or self.pending_rx ~= nil then
            self:log("beacon_tx skipped after jitter (busy in data exchange)")
            return
          end
          local since = (self.last_rx_routing_sf_ms ~= nil)
                        and (self:now() - self.last_rx_routing_sf_ms)
                        or  math.huge
          if since < self.quiet_threshold_ms then
            -- Someone else's beacon (or other RX) landed during our jitter
            -- window. Stand down — they "won" the silence-trigger race.
            self:emit("beacon_skipped_busy", {
              since_rx_ms  = since,
              threshold_ms = self.quiet_threshold_ms,
              stage        = "post_jitter",
            })
            self:log(string.format(
              "beacon_tx skipped after jitter (channel busy: last RX %dms ago)",
              since))
            return
          end
          send_beacon_page(self, "periodic")
        end)
      end
    end
  end

  -- Always re-arm the periodic timer, regardless of whether we actually
  -- emitted. Jittered ±20% to avoid phase-lock between co-booting nodes.
  -- During warmup we use a fast rate so the network learns routes quickly;
  -- afterwards we drop to the operational rate (minutes apart).
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
  -- Viability floor for rt entries: a route is "viable" iff its chain-min
  -- SNR clears the routing-plane (RTS/CTS/ACK ride on routing_sf) demod
  -- threshold + sf_margin_db. route_strictly_better treats viable routes
  -- as strictly preferred over non-viable ones; within each group it's
  -- hops-first. A non-viable rt entry is still kept (better than no entry —
  -- the data SF can fall back to a slower one if the routing-plane SNR is
  -- borderline) but never preferred over an actually-decodable path.
  self.routing_snr_floor_db = (SF_DEMOD_THRESHOLD[self.routing_sf] or -15.0)
                              + self.sf_margin_db
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
  -- Adaptive beacon throttle. Suppress periodic beacon emission when the
  -- node has heard ANY frame on the channel within the last
  -- `quiet_threshold_ms` window — "the network is busy, don't add to the
  -- noise." Mirrors what real LoRa firmware does to honor duty cycle and
  -- avoid swamping dense neighborhoods.
  --
  -- last_rx_routing_sf_ms is `nil` until the first RX; the throttle treats
  -- nil as "no recent activity, fire freely." Needed so the first periodic
  -- beacon goes out at cold start before any neighbor has TX'd. (Using 0
  -- as a sentinel doesn't work — `now() - 0` is small at boot, fooling the
  -- throttle into thinking the channel was just busy.)
  --
  -- When the gate passes, the actual TX is deferred by an extra jitter
  -- in [0, beacon_silence_jitter_ms] before firing, and the silence
  -- check is re-run at deferred-fire time. Reason: if many nodes
  -- simultaneously detect the busy→quiet transition (e.g., end of a
  -- data exchange), they would all fire on the same step without this
  -- jitter — a thundering herd. The wider this jitter, the better the
  -- spread, at the cost of slightly delayed beacon delivery.
  self.last_rx_routing_sf_ms     = nil
  self.quiet_threshold_ms        = config.quiet_threshold_ms        or 30000
  self.beacon_silence_jitter_ms  = config.beacon_silence_jitter_ms  or 10000

  -- Per-neighbor SNR EWMA. `snr_ewma_in[nbr_id]` is fed by every successful
  -- RX from that neighbor — RTS, beacons, CTS-as-listener, etc. Used by
  -- select_data_sf to pick a data SF off a smoothed signal estimate
  -- instead of one noisy snapshot. Initial-sample seeds the EWMA, then
  -- each new sample blends with `snr_ewma_alpha` (default 0.3 → ~10
  -- effective samples). See update_snr_ewma. `snr_ewma_out[nbr_id]` is
  -- separately fed by ACK piggyback (the receiver's measurement of OUR
  -- DATA reception, decoded from the ACK's 4-bit SNR bucket); kept apart
  -- from `_in` because asymmetric links would otherwise pollute the
  -- inbound estimate. `_out` is exposed for future routing/RTS-bitmap
  -- use; SF picks today still read `_in` only.
  self.snr_ewma_alpha = config.snr_ewma_alpha or 0.3
  self.snr_ewma_in    = {}
  self.snr_ewma_out   = {}
  -- Cap the size of each beacon to fit in a single LoRa frame. Header
  -- is 3 bytes ('B' + src + n), each entry is 4 bytes — so for the
  -- 255-byte LoRa max, (255-3)/4 = 63 entries fits theoretically. We
  -- default to 200 bytes (≈ 49 entries) to leave headroom for any
  -- future header growth and to stay well under the wire limit. Networks
  -- with more nodes than max_entries get a rotating page each fire,
  -- driven by self.beacon_offset; rt_merge at receivers fills in entries
  -- as it hears them across rounds.
  self.beacon_max_bytes   = config.beacon_max_bytes   or 200
  -- Header is 4 bytes ('B' + network_id_byte + src + n); entries 4 bytes each.
  self.beacon_max_entries = math.max(1,
    math.floor((self.beacon_max_bytes - 4) / 4))
  -- Radio params for airtime calculation. The runtime injects per-node
  -- resolved values via `_sim_bw_hz` and `_sim_cr` so the script's
  -- airtime math matches what the radio actually does (otherwise s03's
  -- 62.5 kHz BW would compute timeouts against 250 kHz airtime — 4× too
  -- short). User config keys (bw_hz / cr) still win if explicitly set.
  -- Final fallbacks match MeshCore SX1262 defaults.
  self.bw_hz            = config.bw_hz           or config._sim_bw_hz or 250000
  self.cr               = config.cr              or config._sim_cr    or 5
  self.preamble_sym     = config.preamble_sym    or 16
  -- Regulatory duty cycle. Default 1% / 1h matches ETSI EN 300 220
  -- (Europe 868 MHz ISM sub-band g1). The runtime hard-blocks TXes that
  -- breach this; this script also self-regulates pre-TX so we defer
  -- proactively rather than wait for the runtime block + on_radio_busy
  -- retry round trip. Per-node override via config.duty_cycle / window;
  -- inherited from radio block via _sim_duty_cycle / _sim_..._window_ms.
  self.duty_cycle           = config.duty_cycle           or config._sim_duty_cycle           or 0.01
  self.duty_cycle_window_ms = config.duty_cycle_window_ms or config._sim_duty_cycle_window_ms or 3600000
  self.duty_cycle_budget_ms = math.floor(self.duty_cycle * self.duty_cycle_window_ms)
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
  -- TX-policy controls (see "TX policy classes" section above).
  --   lbt_enabled            — pre-check channel_busy_until before TX of
  --                            initiating-directed (RTS / NACK) and flood
  --                            (beacons). DEFAULT OFF: at saturated load
  --                            (s03 @ 62.5 kHz, where beacon airtime alone
  --                            exceeds channel capacity) "wait for clear"
  --                            never returns and just locks pending_tx.
  --                            Enable for moderately-loaded networks where
  --                            collision avoidance is the bottleneck.
  --   retry_jitter_ms        — bound for random backoff added to (a) RTS
  --                            retries on cts_timeout / ack_timeout and (b)
  --                            LBT-deferred sends. Default = one RTS-airtime
  --                            so it scales naturally at 62.5 vs 250 kHz.
  --   flood_lbt_max_defer_ms — if the channel will be busy for longer than
  --                            this, drop the beacon page entirely (the next
  --                            periodic / triggered fire rotates to the
  --                            next page anyway, so queueing a stale page
  --                            is wasteful). Default = airtime(routing_sf,
  --                            beacon_max_bytes) — i.e. one beacon-air's
  --                            worth; if we'd wait longer than the page we
  --                            were going to send, just skip.
  self.lbt_enabled        = config.lbt_enabled
  if self.lbt_enabled == nil then self.lbt_enabled = false end
  self.retry_jitter_ms    = config.retry_jitter_ms    or
    airtime_ms(self.routing_sf, self.bw_hz, self.cr, self.preamble_sym, RTS_LEN)
  self.flood_lbt_max_defer_ms = config.flood_lbt_max_defer_ms or
    airtime_ms(self.routing_sf, self.bw_hz, self.cr, self.preamble_sym,
               self.beacon_max_bytes)
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
  -- Originator-only defer queue. When the user issues a send to a
  -- destination not yet in rt[], we hold the send for up to
  -- send_defer_ttl_ms instead of dropping it on the floor. Any rt_update
  -- (or the periodic 1s drain) walks this list; entries whose dst is
  -- now reachable get pushed back to tx_queue + emit send_drained;
  -- entries past TTL emit send_giveup. Forwarders never defer (they're
  -- mid-flight; lost-route mid-flight is a real failure).
  self.deferred_sends     = {}    -- array of {origin, dst_id, dst_name, payload, user_text, origin_seq, queued_at_ms}
  self.send_defer_ttl_ms  = config.send_defer_ttl_ms or 30000
  -- Hop-level RTS-retry dedup. {sender_id → {msg_id, t_ms}}; lookups
  -- treat entries older than self.last_acked_ttl_ms as missing so the
  -- 4-bit msg_id wrap (every 16 sends per sender) doesn't false-pos
  -- at slow send rates. TTL well above any flight-retry window
  -- (rts_max_retries × rts_timeout ≈ 1.5 s) and well below the wrap
  -- interval at any plausible per-sender send rate.
  self.last_acked_from    = {}
  self.last_acked_ttl_ms  = config.last_acked_ttl_ms or 10000
  -- 4-bit network identifier — externally managed (admin sets per node).
  -- Receivers reject foreign-network BCN/RTS at the routing layer
  -- before doing CTS/DATA work. 0 = default mesh; 1..15 = distinct meshes.
  self.network_id        = config.network_id or 0
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

  -- First-beacon scheduling, two cases:
  --   1. Boot at t=0 OR within warmup window: mass-boot scenario, MUST
  --      jitter across the warmup beacon period (default 5 s) so the
  --      first round doesn't collide. Same as before.
  --   2. Boot AFTER warmup ended (start_at_ms set, single new joiner
  --      coming up after the mesh has converged): no storm risk —
  --      fire ASAP with tiny jitter so neighbours' triggered beacons
  --      bring us into the routing table within ~hundreds of ms instead
  --      of waiting up to a full operational beacon period.
  local boot_at = self:now()
  if boot_at < self.warmup_ms or self.warmup_ms == 0 then
    -- Case 1: mass-boot or no-warmup-configured. Jitter across warmup period.
    local first_period = self.beacon_period_warmup_ms
    self:after(self:rand(0, first_period), function() beacon_fire(self) end)
  else
    -- Case 2: cold-start joiner past warmup. Fire fast (~100ms avg).
    self:after(self:rand(1, 200), function() beacon_fire(self) end)
  end

  -- Periodic 1s drain of self.deferred_sends — fires regardless of
  -- beacon traffic, so deferred originator sends have a deterministic
  -- TTL-pruning + retry loop independent of the radio.
  local function drain_loop()
    try_drain_deferred(self)
    self:after(1000, drain_loop)
  end
  self:after(1000, drain_loop)
end

function on_recv(self, frame, meta)
  if #frame == 0 then return end
  -- Channel-activity detector for adaptive beacon throttle: any successful
  -- decode means the channel was busy at this moment. The throttle in
  -- beacon_fire reads this to decide whether to suppress the next beacon.
  -- Updated unconditionally (broadcast OR unicast, beacon OR data plane).
  self.last_rx_routing_sf_ms = self:now()
  -- Per-neighbor inbound SNR EWMA. Smooths the noisy single-sample SNR
  -- that select_data_sf would otherwise see, so SF picks ride on a
  -- ~10-sample running estimate instead of one snapshot. Same EWMA covers
  -- every frame type (beacon/RTS/CTS/DATA/ACK/NACK) since SNR is a
  -- physical link property, not frame-type-specific.
  if meta.src ~= nil and meta.snr ~= nil then
    update_snr_ewma(self.snr_ewma_in, meta.src, meta.snr, self.snr_ewma_alpha)
  end
  local tag = frame:sub(1, 1)

  if tag == "B" then
    local b = parse_beacon(frame)
    if not b then return end
    -- Cross-network filter — drop foreign-network beacons before they
    -- pollute our routing table. Same field as RTS, same admin-managed
    -- 4-bit space. Silent drop (no event spam — expected during
    -- enhanced propagation events).
    if b.network_id ~= self.network_id then return end
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
      local action = rt_merge(self.rt, b.src, cand, self.routing_snr_floor_db)
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
          local action = rt_merge(self.rt, e.dest, cand, self.routing_snr_floor_db)
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
    -- Bootstrap UX: any rt mutation may have populated routes that
    -- previously-deferred originator sends were waiting for. Drain now
    -- so the user's "send" delivers as soon as the route appears,
    -- without waiting for the periodic 1s drain timer.
    if rt_changed then try_drain_deferred(self) end
    return
  end

  if tag == "R" then
    local r = parse_rts(frame)
    if not r then return end
    if r.next ~= self.id then return end  -- not for us; silent discard
    -- Cross-network filter — drop foreign-network RTSes before any CTS
    -- work. Without this, two networks merging during enhanced RF
    -- propagation would waste airtime on duplicate CTSes and pollute
    -- routing decisions.
    if r.network_id ~= self.network_id then return end

    -- Sender is retrying an RTS for a DATA we already received and acked
    -- (their previous ACK was lost in flight). Re-send the ACK directly
    -- — no CTS, no DATA — so they can clear pending_tx without us
    -- reprocessing/duplicating the message. last_acked_from holds the
    -- most recent acked msg_id per sender, scoped by TTL so the 4-bit
    -- msg_id wrap (every 16 sends per sender) doesn't false-positive at
    -- slow send rates.
    local cached = self.last_acked_from[r.src]
    if cached and cached.msg_id == r.msg_id
       and (self:now() - cached.t_ms) < self.last_acked_ttl_ms then
      self:emit("rts_already_acked", {
        origin = r.origin,    -- payload unknown — RTS frame doesn't carry it
        from = r.src, msg_id = r.msg_id,
      })
      self:log(string.format("rts_already_acked <- %s msg_id=%d -> re-sending ACK",
        name_of(self, r.src), r.msg_id))
      -- Piggyback the current RTS's SNR — this isn't the original DATA's
      -- SNR (we don't have it any more), but it's a valid fresh sample of
      -- the same link, so the sender's outbound EWMA still benefits.
      local ack = pack_ack(r.msg_id, meta.snr)
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
      tx_initiating(self, nack, {
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
      tx_initiating(self, nack, {
        sf    = self.routing_sf,
        label = "NACK",
        info  = string.format("to=%s msg=%d busy_for=%dms reason=pending_tx",
          name_of(self, r.src), r.msg_id, busy_for),
      })
      return
    end

    -- Pick a data SF from the RTS's allowed-SF bitmap based on the
    -- per-neighbor inbound SNR EWMA (smoothed across recent RXes from
    -- this sender, not just this single RTS). Falls back to the raw
    -- meta.snr if we have no EWMA yet — but the on_recv top-of-function
    -- hook just updated `_in[r.src]` with `meta.snr`, so the EWMA is
    -- always populated for any neighbor we just received from. Empty
    -- bitmap → nothing we can do; silent drop (sender's rts_timeout will
    -- handle it).
    local snr_for_sf = self.snr_ewma_in[r.src] or meta.snr
    local chosen_sf  = select_data_sf(snr_for_sf, r.sf_bitmap, self.sf_margin_db)
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
      sf_bitmap = r.sf_bitmap, chosen_data_sf = chosen_sf,
      rx_snr = meta.snr, ewma_snr = snr_for_sf,
    })
    self:log(string.format(
      "rts_rx <- %s (origin=%s dst=%s msg_id=%d sf_bitmap=0x%02x snr=%.1fdB) -> chose SF%d",
      name_of(self, r.src), name_of(self, r.origin), name_of(self, r.dst),
      r.msg_id, r.sf_bitmap, meta.snr, chosen_sf))
    self.pending_rx = {
      from        = r.src,
      origin      = r.origin,
      dst         = r.dst,
      msg_id      = r.msg_id,
      set_at_ms   = self:now(),       -- for NACK busy_for_ms calc
      chosen_data_sf = chosen_sf,     -- DATA leg's SF; receiver retunes after CTS-tx
      payload_len = r.payload_len,    -- size pending_rx_expiry to actual DATA airtime
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

    -- F1 mitigation: every CTS — addressed to us or not — tells us its
    -- sender will be deaf on routing_sf for one DATA-RX window
    -- (cts_to_data_gap + airtime of the chosen data_sf, max payload).
    -- Stash that absolute end-time so future RTS attempts toward this
    -- sender either alt-switch or defer instead of hitting drop_sf_mismatch.
    if meta.src ~= nil then
      local now = self:now()
      local blind_window = self.cts_to_data_gap_ms +
        airtime_ms(c.chosen_data_sf, self.bw_hz, self.cr,
                   self.preamble_sym,
                   DATA_HDR_LEN + self.max_payload_bytes)
      local end_ms = now + blind_window
      local prev = self.blind_until[meta.src]
      if prev == nil or end_ms > prev then
        self.blind_until[meta.src] = end_ms
        self:emit("blind_observed", {
          node           = meta.src,
          until_ms       = end_ms,
          chosen_data_sf = c.chosen_data_sf,
        })
      end
    end

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
    -- ACK piggyback: receiver included its measurement of OUR DATA's
    -- decode SNR (4-bit bucket, low nibble of byte 4). Update our
    -- outbound-EWMA estimate of how this neighbour hears us. Kept
    -- separate from snr_ewma_in (which tracks the inbound direction
    -- from RTSes/beacons) so asymmetric links don't pollute the per-
    -- direction estimates. Today the outbound EWMA is read by no other
    -- code path — it's instrumentation for upcoming routing/RTS-bitmap
    -- decisions; without recording it now, the data wouldn't be there
    -- when those changes land.
    local ack_src = self.pending_tx.next
    if ack_src ~= nil and k.snr_db ~= nil then
      update_snr_ewma(self.snr_ewma_out, ack_src, k.snr_db, self.snr_ewma_alpha)
      self:emit("ack_snr_feedback", {
        from = ack_src, msg_id = k.msg_id,
        data_snr_db = k.snr_db, snr_bucket = k.snr_bucket,
        ewma_out = self.snr_ewma_out[ack_src],
      })
    end
    self:emit("ack_rx", {
      origin = self.pending_tx.origin,
      payload = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      from = self.pending_tx.next, msg_id = k.msg_id,
      data_snr_db = k.snr_db,
    })
    self:log(string.format("ack_rx <- %s msg_id=%d data_snr=%.1fdB -> hop complete",
      name_of(self, self.pending_tx.next), k.msg_id, k.snr_db or 0))
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

    -- Mark the NACK sender as blind for the busy_for_ms window. F1 already
    -- populates blind_until from overheard CTS; NACK is even more
    -- authoritative ("I am busy") so it belongs here too. Without this,
    -- once we requeue + drain, classify_blind has no reason to defer the
    -- next attempt to the same neighbour and the pair locks into a NACK
    -- ping-pong (RTS → NACK → requeue → RTS → NACK → …) at ~RTS-air
    -- cadence with zero progress.
    if n.busy_for_ms and n.busy_for_ms > 0 then
      local from_id = self.pending_tx.next
      local end_ms  = self:now() + n.busy_for_ms
      local prev    = self.blind_until[from_id]
      if prev == nil or end_ms > prev then
        self.blind_until[from_id] = end_ms
        self:emit("blind_observed", {
          node     = from_id,
          until_ms = end_ms,
          reason   = "nack",
        })
      end
    end

    -- Two strategies, in order of preference:
    --   (a) wait busy_for_ms then retry the same next-hop
    --   (b) requeue if busy is too long to wait inline — the queue might
    --       pop a different send, or DV beacons may converge meanwhile
    --
    -- We never path-switch on a NACK. Rationale: this protocol's NACK
    -- carries only busy_for_ms (a transient receiver-busy signal); there
    -- is no "no route" / link-quality variant. The receiver freeing up
    -- is the natural event we should wait for. Path-switching to a
    -- different forwarder doesn't help — particularly when the next-hop
    -- IS the destination (alice rejects Ballard's RTS because alice
    -- is busy as originator; switching to N7TOERPTR just makes
    -- N7TOERPTR also discover alice is busy). Always-wait-and-retry
    -- collapses several wasted RTS-CTS-NACK cycles onto a single
    -- successful exchange once the receiver is free.
    local NACK_WAIT_THRESHOLD_MS = 2000
    if n.busy_for_ms <= NACK_WAIT_THRESHOLD_MS then
      local captured = self.pending_tx.msg_id
      -- Add small jitter on top of busy_for_ms to decorrelate multiple
      -- senders all NACKed by the same receiver — without it they
      -- thunder back in unison the moment the receiver frees up.
      local wait_ms = n.busy_for_ms + 1 + self:rand(0, self.retry_jitter_ms + 1)
      self:log(string.format("nack_wait msg_id=%d for %dms (busy_for=%d, same next-hop)",
        captured, wait_ms, n.busy_for_ms))
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
      previous_hop = self.pending_tx.previous_hop,
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

    self.last_acked_from[d.src] = { msg_id = d.msg_id, t_ms = self:now() }
    -- Piggyback our measurement of THIS DATA's SNR into the ACK's 4-bit
    -- bucket. Sender uses it to maintain its outbound link-quality EWMA
    -- to us (which we can't see because we're at the receiving end);
    -- gives the sender a closed-loop signal for routing decisions and
    -- (future) per-neighbor RTS bitmap trimming.
    local ack = pack_ack(d.msg_id, meta.snr)
    self:emit("ack_tx", {
      origin = d.origin, payload = user_text, origin_seq = origin_seq,
      to = d.src, msg_id = d.msg_id, data_snr = meta.snr,
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
    local d_src        = d.src              -- predecessor (for forward loop guard)
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
          previous_hop = d_src,               -- forward loop guard
        })
        self:emit("forward_queued", {
          origin = d_origin, payload = d_user_text, origin_seq = d_origin_seq,
          dst = d_dst, depth = #self.tx_queue,
        })
        return
      end
      issue_send(self, d_origin, d_dst, dst_name,
                 d_payload, d_user_text, d_origin_seq, d_src)
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

-- on_preamble_detected fires when a transmission would start arriving at
-- our radio at our current SF — the SX1262 PreambleDetected IRQ. Crucially,
-- this fires regardless of whether the rest of the packet decodes, so it's
-- a faithful "the channel is busy with someone at our SF right now" signal
-- even when per-packet shadow variance pushes individual frames below the
-- demod floor. Doesn't filter by sync word — any LoRa traffic at our SF
-- (other mesh networks, jammers, anything) would collide with our TX
-- regardless of who sent it.
--
-- Wired into the throttle's witness: updating last_rx_routing_sf_ms here
-- means beacon_fire's "channel-quiet?" check sees real channel activity,
-- not the decode-success-biased view it had before. Fixes the spiral
-- where high sigma_db caused decoded RXes to drop, throttle thought the
-- channel was quiet, fired more beacons that collided.
function on_preamble_detected(self, info)
  self.last_rx_routing_sf_ms = info.time_ms
end
