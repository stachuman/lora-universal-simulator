-- scenarios/dv_dual_sf.lua
-- Distance-vector routing on routing_sf with per-hop dual-SF data delivery
-- on data_sf via RTS/CTS/DATA. See docs/superpowers/specs/2026-05-06-s01-dv-dual-sf-scenario-design.md.
--
-- Wire format:
-- | Tag   | Frame  | Layout                                                                          |
-- | ----- | ------ | ------------------------------------------------------------------------------- |
-- | `'B'` | Beacon | `B`, [leaf_id(4)|has_schedule(1)|self_gateway(1)|is_mobile(1)|rsv(1)](1), src(1), n_entries(1), [layer_count(1)+sched×L×4B]?, entries × n × {dest(1), next(1), [bucket(4)|(hops-1)(3)|is_gateway(1)](1)}  →  4 + [1+4L]? + 3n B |
-- | `'R'` | RTS    | `R`, src(1), next(1), [addr_len(3)|rsv(1)|leaf_id(4)](1), dst(1 when addr_len=0), [ctr_lo(4)|rsv(4)](1), sf_bitmap(1), payload_len(1)  →  8 B (in-leaf) |
-- | `'C'` | CTS    | `C`, [ctr_lo(4)|(sf-5)(3)|reserved(1)](1)  →  2 B                              |
-- | `'D'` | DATA   | `D`, [addr_len(3)\|rsv(1)\|E2E_ACK_REQ(1)\|E2E_IS_ACK(1)\|IS_MULTICAST(1)\|rsv(1)](1), next(1), dst(1 when addr_len=0), ctr_lo(1), ctr_hi(1), ciphertext(n+2), MAC(4)  →  10+n B (in-leaf) |
-- | `'K'` | ACK    | `K`, [ctr_lo(4)|snr_bucket(4)](1)  →  2 B                                       |
-- | `'N'` | NACK   | `N`, [reason(4)|ctr_lo(4)](1), payload(1)  →  3 B  |
-- | `'Q'` | RREQ-route | `Q`, src(1), dest(1), [leaf_id(4)|reserved(4)](1)  →  4 B (one-hop route query) |
--
-- All control frames carry a 4-bit ctr_lo (per-(originator) flight
-- counter, wraps at 16; dedup tolerated by last_acked_from's 10s TTL).
-- leaf_id (4 bits, externally managed) appears in BCN and RTS — the
-- two frames that gate routing decisions. Receivers reject foreign-
-- network BCN/RTS before doing any work, preventing duplicate-CTS,
-- routing-table-pollution, and wasted-flight failure modes during
-- enhanced RF propagation events. CTS/DATA/ACK/NACK don't carry
-- leaf_id because they're matched against pending_tx/pending_rx
-- state set by an already-validated RTS (the check is implicit).
--
-- RTS's sf_bitmap byte (offset 7) is a per-flight bitmap of allowed data SFs:
--   bit i = SF (5+i) is acceptable for the DATA leg; the receiver picks one.
--   bit 0 = SF5 (fastest), bit 7 = SF12 (most robust). e.g. 0b01000010 = SF6+SF12.
-- RTS's payload_len byte (offset 8) is the byte count of the upcoming DATA
-- frame after its 6-byte header: inner overhead (src_addr_len + src_addr,
-- 2 B today) + body + MAC (4 B). Lets the receiver size pending_rx_expiry
-- to actual airtime instead of max_payload_bytes worst-case — important
-- when bodies vary 10–200 bytes, since the worst-case budget would freeze
-- pending_rx ~2× longer than needed.
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
-- DATA (10+n bytes in-leaf): wire-level E2E flags on byte 1, 16-bit ctr on
-- bytes 4-5, ciphertext slot (= plaintext today) carries the inner payload:
--   inner = src_addr_len(1) | src_addr(1) | body
-- followed by a 4-byte zero MAC placeholder (§8 crypto stub). The pair
-- (origin from inner.src_addr, ctr from wire bytes 4-5) is the globally-
-- unique end-to-end message id used for duplicate detection at every
-- receiving node. Forwarders relay the inner bytes verbatim (ciphertext
-- is opaque; only the destination / originator parse it). Wire-level flags
-- (E2E_ACK_REQ, E2E_IS_ACK) are plaintext so intermediate nodes could
-- apply QoS without breaking future encryption — an intentional design
-- choice matching WireGuard / MLS envelope patterns.
--
-- Protocol flow (per node):
--
-- on_init
--   build name↔id maps from sim:nodes(); peer_count = N-1
--   RX defaults to routing_sf
--   first-beacon scheduling (cold-start aware):
--     boot_at < warmup_ms OR warmup_ms == 0 → rand(0, beacon_period_warmup_ms)
--                                              (mass-boot, jitter to avoid storm)
--     else (single late joiner past warmup)  → rand(1, 200) ms
--                                              (cold-start; bootstrap ASAP)
--   periodic 1s drain timer → try_drain_deferred (TTL pruning + retry
--                                                  for originator defer queue)
--   See "Bootstrap UX (cold-start joiners)" section below.
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
--     differential emission: pack_beacon emits dirty routes (changed
--       since their last advertisement) BEFORE filling remaining slots
--       from the sliding-offset rotation. Routes are marked dirty by
--       rt_merge on "new"/"promote"/"primary_refresh" and by
--       rt_prune_cycle when the primary is pruned. Dirty flag cleared
--       once the route is included in an emitted beacon. Steady state
--       with no churn → no dirty entries → byte-for-byte identical to
--       the pre-differential rotation. Active state → recent route
--       changes propagate within ONE beacon period instead of waiting
--       for the rotation window to come around. Telemetry:
--       beacon_diff_breakdown emits {dirty_n, stable_n, total_dirty}.
--     → tx 'B' (dirty entries first, then stable rotation fill) → ±20% jittered re-arm
--   triggered beacons: any rt mutation (new/promote/3cycle-prune/age-out)
--     schedules a one-shot beacon within rand(50,500)ms (coalesced into
--     a single armed trigger). NOT subject to the adaptive throttle —
--     triggered beacons exist to propagate routing changes urgently;
--     suppressing them on busy channels would defeat the purpose.
--     With differential emission, the triggered beacon naturally
--     carries the freshly-mutated routes in its dirty slots — they
--     always make the next on-air beacon. This is what makes
--     convergence fast when the operational period is minutes-long;
--     periodic beacons are just a slow keep-alive that catches anything
--     missed by triggered fires.
--     Half-duplex skip applies — busy nodes drop the trigger and rely on
--     the next mutation (or periodic) to retry.
--   stale-route aging: every rt_aging_check_period_ms (default 60s),
--     walk rt[]; evict candidates whose last_seen_ms exceeded a
--     hop-class-specific TTL:
--       hops == 1  → rt_aging_ttl_neighbor_ms  (default 30 min)
--       hops >= 2  → rt_aging_ttl_remote_ms    (default 90 min)
--     Two-tier rationale: direct neighbour entries refresh on every
--     received frame from that neighbour (rt_merge top-of-on_recv hook),
--     so they tolerate a shorter TTL — death detection for moving /
--     dying neighbours stays responsive. Multi-hop entries only
--     refresh when their advertiser's beacon-rotation slot comes up,
--     so they need a much longer TTL to survive normal rotation gaps
--     without false-eviction.
--     When primary evicted: mark entry.dirty for differential beacon.
--     When all candidates evicted: drop entry + trigger beacon (no
--     wire-format way to advertise "deleted route" — receivers' own
--     aging eventually catches up via the absence of advertisement).
--     Telemetry: rt_aged event per evicted candidate.
--     ► Real-deployment tuning formula in on_init's aging block.
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
--   tx_queue is a SCHEDULED queue of items shaped
--   {origin, dst_id, dst_name, payload, user_text, ctr, flags, previous_hop,
--    next_attempt_ms, requeue_count, enqueue_time_ms}; both originators
--   (on_command) and forwarders (on_recv 'D' relay branch) enqueue,
--   never call issue_send directly. become_free pops the earliest-ready
--   item (smallest next_attempt_ms <= now, FIFO tie-break) whenever the
--   node becomes idle (pending_tx == pending_rx == nil) — that's the
--   single drain point. If no item is ready, become_free arms a single
--   self.queue_wakeup_handle and returns. Forwarders defer the post-ACK
--   action one ack_air_ms tick so the ACK and the next RTS don't share
--   a step.
--
--   Cascade-exhaustion requeue: when pending_tx exhausts all K alts (true
--   path_cascade_exhausted), instead of dropping immediately the item is
--   pushed back into tx_queue with exponential backoff (cascade_requeue
--   emit). Hard cap on retries (cascade_requeue_max) and on total wallclock
--   (cascade_requeue_total_max_ms) → if either is exceeded the message is
--   truly dropped with the legacy path_cascade_exhausted + rts_giveup
--   (or data_ack_giveup) emits. Goal: a single stuck destination must
--   not block deliverable items behind it in the queue.
--
--   Adaptive back-pressure: when local tx_queue depth exceeds
--   cascade_requeue_load_threshold, the effective requeue budget shrinks
--   1:1 with each additional queued item — so a stressed node sheds
--   retry load instead of piling on. Drops fire as cascade_load_skip
--   diagnostically; the terminal emits stay path_cascade_exhausted +
--   rts_giveup so existing analyzers stay compatible.
--
--   ORIGINATOR (on_command "send <dst> <text>"): enqueue + become_free
--   FORWARDER (on_recv 'D' relay): enqueue + after(ack_air_ms+1, become_free)
--   issue_send (called by become_free for both): builds RTS, sets
--     pending_tx, retunes RX to data_sf, starts rts_timeout
--
--   NEXT-HOP (on_recv 'R' with next == self.id):
--     • last_acked_from[r.src] == r.ctr_lo  → re-tx ACK on routing_sf,
--                                              return (sender retried after
--                                              losing previous ACK)
--     • pending_rx busy + same (from,ctr_lo) → re-tx CTS-dup, restart
--                                              pending_rx_expiry, return
--     • pending_rx busy + different sender   → emit rts_rejected_busy
--     • else: set_rx_sf(data_sf); pending_rx = {from,dst,ctr_lo,...};
--             start_pending_rx_expiry; tx 'C' on data_sf
--             (origin learned later from DATA inner payload — not on RTS wire)
--
--   ORIGINATOR/FORWARDER (on_recv 'C' matching pending_tx.ctr_lo):
--     1. cancel rts_timeout (avoid spurious retry on the same tick)
--     2. after cts_to_data_gap_ms: tx 'D' on data_sf, set_rx_sf(routing_sf),
--                                   start_ack_timeout (covers DATA airtime
--                                   + ACK airtime). Keep pending_tx until
--                                   ACK or ack_timeout fires.
--
--   NEXT-HOP (on_recv 'D' matching pending_rx.ctr_lo, next == self.id):
--     1. parse_data gives d.origin, d.ctr, d.flags, d.body, d.inner directly
--        (no inner-payload header to strip; origin + ctr are on the wire)
--     2. cancel pending_rx_expiry; set_rx_sf(routing_sf); pending_rx = nil
--     3. cache last_acked_from[pending_rx.from] = d.ctr_lo; tx 'K' on routing_sf
--     4. ORIGIN-LEVEL DEDUP: if (d.origin, d.ctr) seen recently,
--        emit dup_drop and return — ACK was already sent; we just don't
--        deliver-twice or forward-twice. Catches DV routing loops and
--        legitimate same-payload retries via different paths.
--     5. record the (origin, ctr) in seen_origins with a TTL
--     6. if dst == self.id → emit "delivered" (payload = d.body)
--        else (forward) → after ack_air_ms+1: enqueue forward (d.inner
--        verbatim, d.ctr, d.flags), become_free
--
--   ORIGINATOR/FORWARDER (on_recv 'K' matching pending_tx.ctr_lo):
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
--   tx_rts_retry: re-tx RTS with same ctr_lo (via tx_initiating, so still
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
--   1. last_acked_from[r.src] == r.ctr_lo  → re-ACK on routing_sf, return
--   2. pending_rx busy + same (from,ctr_lo) → CTS-dup, restart expiry
--   3. pending_rx busy + different sender   → NACK on data_sf, busy_for =
--      max(0, set_at + pending_rx_expiry_ms − now)
--   4. pending_tx in flight                  → REMOVED. Used to NACK with a
--      pessimistic estimate, but the estimate lied in failure cases (a node
--      stuck in an ACK-loss retry loop predicts ~5 s but is actually busy
--      60+ s). Silent drop now (rts_drop_pending_tx emit only); senders
--      rely on rts_timeout + cascade machinery instead.
--   5. otherwise                              → normal RTS handling
-- NACK rides on data_sf (not routing_sf) because the sender's RX is
-- already retuned to data_sf after its RTS-tx, awaiting CTS. NACK and CTS
-- share the channel logically — they're the two possible admissions.
--
-- Sender-side NACK (on_recv 'N' matching pending_tx.ctr_lo):
-- After the pending_tx receiver-side trigger was removed, this only fires
-- for pending_rx NACKs (case 3 above). Behaviour unchanged:
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
-- End-to-end delivery ACK (per-message opt-in)
-- ============================================================================
--
-- The hop-by-hop K-frame ACK only tells the originator "the next forwarder
-- received my DATA." If a forwarder mid-path drops the message after
-- ACKing, the originator's K-ack still succeeded — silent loss. For
-- important user messages (payments, status confirmations), the
-- originator needs end-to-end confirmation.
--
-- DESIGN PRINCIPLES.
--   • Opt-in per message — bulk chat doesn't pay the round-trip; only
--     send_e2e marks a message as "I want confirmation."
--   • Tiny ACK frame — body 2 bytes ([acked_ctr_lo, acked_ctr_hi]) carried
--     inside a normal 10-byte DATA wire frame. Routed via normal DATA
--     mechanics so no new frame type, no new forwarding logic.
--   • Reuses existing routing — destination acts as originator of a new
--     short DATA flight back to the original origin. Forwarders see the
--     E2E ACK as a normal DATA frame; only origin/destination know it's
--     an ACK (via the IS_ACK flag on DATA wire byte 1).
--
-- WIRE FORMAT.
--   E2E flags live on DATA wire byte 1 (ROADMAP §7.0.1):
--     bit 3 (DATA_FLAG_E2E_ACK_REQ) — origin wants end-to-end confirmation
--                                     of this message.
--     bit 2 (DATA_FLAG_E2E_IS_ACK)  — this DATA frame IS an E2E ACK
--                                     (body = [acked_ctr_lo, acked_ctr_hi]).
--
--   `ctr` (DATA wire bytes 4-5) is the 16-bit per-(origin, dst) counter
--   that triple-duties as crypto-nonce entropy, replay protection, and
--   E2E flight identifier (replaces the pre-Phase-4 origin_seq).
--
-- FLOW.
--   1. Originator calls "send_e2e <dst> <text>". on_command:
--        - allocates ctr via self:next_ctr(dst)
--        - records pending_e2e[ctr] = {sent_at, dst, text}
--        - emits e2e_ack_pending
--        - enqueues the send with DATA_FLAG_E2E_ACK_REQ set on the wire flags
--   2. The send travels via normal RTS-CTS-DATA-ACK chain to destination.
--   3. Destination's on_recv "D" delivered branch:
--        - reads d.flags, d.ctr, d.body directly from parse_data
--        - emits "delivered" with body as user_text (unchanged)
--        - if d.e2e_ack_req: allocates its own return_ctr, builds a return
--          DATA with DATA_FLAG_E2E_IS_ACK set and body =
--          [d.ctr & 0xff, (d.ctr >> 8) & 0xff], enqueues it as a new
--          send to d.origin
--        - emits e2e_ack_tx_enqueued for analyzer/diagnostic
--   4. The return DATA travels normally back to origin.
--   5. Origin's on_recv "D" delivered branch:
--        - sees d.e2e_is_ack
--        - extracts acked_ctr = body:byte(1) | (body:byte(2) << 8)
--        - looks up pending_e2e[acked_ctr]
--          - if present: emit delivered_confirmed, clear pending entry
--          - if not: emit e2e_ack_unmatched (duplicate or already timed out)
--        - does NOT emit "delivered" (this is an ACK, not user content)
--        - does NOT trigger another E2E ACK (no recursion — IS_ACK and
--          ACK_REQ are independent bits; an E2E ACK never sets ACK_REQ
--          on its return frame)
--   6. If origin's pending_e2e entry ages past e2e_ack_ttl_ms (default
--      60 s) without seeing the ACK, the 1-s drain_loop emits
--      e2e_ack_timeout for the app's "no answer received" UX.
--
-- COST.
--   ~10-byte E2E ACK frame × (N hops × RTS-CTS-DATA-ACK chain) ≈
--   significant but bounded airtime. For a 3-hop route at SF8 BW250,
--   approximately 600 ms total round-trip airtime. Why opt-in: at scale,
--   ACKing every flight doubles the airtime budget consumed per message.
--
-- COMPOSITION.
--   • §1 anti-spam: an E2E ACK is itself a send-from-destination. It
--     counts toward destination's own origination quota. If the
--     destination is heavily rate-limited as an originator, its E2E
--     ACKs are subject to the same enforcement — design feature, not
--     bug (a heavy responder can't avoid its own rate cap).
--   • §9 privacy T2: when origin moves into encrypted payload, the
--     destination still has the origin's identity from decryption, so
--     can construct the return E2E ACK. The forwarders carrying the
--     ACK don't need to know it's an ACK — they just see DATA.
--
-- Tuning knob:
--   e2e_ack_ttl_ms — how long pending_e2e entries live before
--                    timeout (default 60 s).
--
-- ============================================================================
-- Anti-spam: 1st-hop statistical rate-limit via passive RTS/CTS counting
-- ============================================================================
--
-- A chatty originator can monopolise network capacity: at ~1% duty cycle,
-- every forwarder along the multi-hop path also burns its own budget
-- relaying. One node sending 200 messages/hr effectively crowds out
-- everyone else even though the spammer only has its own 1% local budget.
--
-- WHO ENFORCES.  Only the 1st-hop neighbour of the originator. NOT the
-- originator itself (a malicious modified firmware can't be trusted to
-- self-limit). NOT deeper forwarders (they see aggregated traffic from
-- many origins and would over-trigger on the heaviest-loaded forwarders
-- — exactly the nodes doing the right thing). The 1st-hop invariant is
-- structural: a node N is entitled to police direct sender X only when
-- N observes traffic that physically came from X's radio.
--
-- HOW IT WORKS (privacy-preserving, no origin needed).  We never read
-- the `origin` field — it may be encrypted away in §9 T2. Instead we
-- count what we OBSERVE on routing_sf from each direct sender X over a
-- sliding window (default 5 min):
--
--   R[X] = total RTS-tx events from X (any tag 'R' — RTS, RTS-fwd,
--          RTS-rty all count, they're indistinguishable on the wire)
--   C[X] = total CTS-tx events from X (tag 'C')
--
-- A legitimate forwarder emits one CTS per inbound flight and one RTS
-- per outbound forward, so R[X] ≈ C[X] over time. An originator emits
-- RTS without ever responding to inbound RTS, so C[X] ≈ 0 and the
-- difference R[X] − C[X] is the "apparent origination count":
--
--   apparent_origination[X] = max(0, R[X] - C[X])
--
-- ENFORCEMENT.  When N receives an RTS from sender X, N evaluates:
--   • Is apparent_origination[X] > originator_max_per_window
--     (default 6 originations / 5 min)?
--   • OR is total observed airtime > originator_airtime_share × N's
--     own duty-cycle budget (default 0.25)?
-- If either: SILENTLY DROP the RTS — no CTS reply, no NACK. The sender
-- experiences rts_timeout, cascades to alt next-hops, all 1st-hop
-- neighbours independently converge on the same rate-limit decision,
-- so the spammer is effectively capped at ~72 originations/hr (the
-- threshold) regardless of how many next-hops they try.
--
-- WHY SILENT DROP, NOT NACK.  A NACK costs N ~50 ms of N's own budget
-- per attack frame — paying airtime to a spammer. Silent drop costs
-- zero. The spammer's rts_timeout (~5 s) provides the rate-limit
-- pressure for free. The diagnostic event `rts_drop_originator_throttle`
-- fires so the analyzer can measure mechanism activity without the
-- protocol paying airtime.
--
-- ORIGINATOR FEEDBACK.  Without a NACK signal, the spammer can't be
-- explicitly told "you're rate-limited." Instead each originator
-- self-monitors: track own_origination_count over the same window.
-- On any terminal failure (path_cascade_exhausted / rts_giveup),
-- if own_origination_count is high (over half the inbound threshold)
-- OR own duty-cycle tier is STRAINED+, emit
-- `originator_self_over_budget` for the app to surface as "your
-- send may have failed because you're over your fair-share budget."
-- This is best-effort UX, not authoritative.
--
-- WHY COUNT-BASED, NOT PER-RTS DETERMINISTIC.  A per-RTS rule like
-- "look back 300 ms for CTS+ACK from this sender" was the first
-- proposal but is broken by collisions: if N misses a forwarder's
-- ACK due to a collision on that frame, N would classify the next
-- forwarder-RTS as origination and false-positive. The count-based
-- rule absorbs single-event noise statistically — a missed CTS
-- shifts R-C by 1, which the threshold tolerates.
--
-- EVASION ARITHMETIC.  A spammer trying to dodge the classifier by
-- emitting fake CTS-tx before each spam RTS pays ~50 ms additional
-- airtime per attack. The total-airtime backstop (originator_airtime_share)
-- catches the evader at lower volumes than legitimate origination,
-- so evasion is sub-economic.
--
-- KNOWN LIMITATIONS.
--   • Statistical false-positives: a legitimate forwarder hit by a
--     collision burst can briefly exceed threshold; window decay
--     recovers them automatically.
--   • Statistical false-negatives: a clever low-rate spammer can
--     evade the origination-count metric. The airtime backstop
--     catches extreme volumes; low-rate spam is harder to detect.
--   • Move-and-reset: a spammer changing neighbourhoods resets each
--     new 1st-hop's per-sender window. Mitigations (gossip,
--     cryptographic identity binding) deferred to §8 frame-auth.
--
-- COMPOSITION.
--   • §9 privacy (T2): the classifier doesn't read origin → fully
--     compatible with origin encrypted in payload.
--   • §8 cryptography (frame-auth MAC): would eliminate
--     false-positives/negatives at cost of per-frame MAC verify;
--     this script's behavioral classifier is what works before §8.
--   • Existing budget NACK (§ duty-cycle tier): different mechanism,
--     different state — composes cleanly.
--
-- Tuning knobs (config-level overrides; defaults in on_init):
--   originator_window_ms          (300000 = 5 min)
--   originator_max_per_window     (6 originations)
--   originator_airtime_share      (0.25 = 25% of N's own budget)
--   originator_self_warn_fraction (0.5  = self-warn at 3 originations)
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
--     "BSY" frame on routing_sf carrying the requesting ctr_lo would let
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
-- BCN — 4-byte header + optional schedule block + n × 3-byte entries:
--   byte 0 : tag 'B'
--   byte 1 : leaf_id(4 hi) | has_schedule(1) | self_gateway(1) | is_mobile(1) | rsv(1)
--   byte 2 : src (8)
--   byte 3 : n_entries (8)
--   if has_schedule == 1:
--     byte 4 : layer_count (8)
--     layer_count × 4-byte schedule records (parser skips today — runtime
--                                            path for inter-layer TDM deferred
--                                            to §7.3)
--   entries (3 B each):
--     byte 0 : dest (8)
--     byte 1 : next (8)
--     byte 2 : score_bucket(4 hi) | (hops - 1)(3) | is_gateway(1 lo)
-- leaf_id (4 bits): same field as RTS. Receivers reject foreign-leaf
-- beacons before rt_merge so foreign nodes don't pollute our routing
-- tables.
-- Per-entry score is the 4-bit SNR bucket (16 levels, 2 dB resolution,
-- range -20..+10 dB) — same encoding used by the ACK piggyback for
-- consistency. Hops are encoded on-wire as `hops - 1` (3 bits, range 0..7)
-- to free 1 bit for `is_gateway`; the in-memory hops value stays 1..8 so
-- the protocol's 8-hop cap is preserved. `is_gateway` is per-(dest, advertiser)
-- and rides on each rt[] candidate so different advertisers' claims stay
-- separate.

-- Quantize an SNR (dB) to a 4-bit bucket [0..15]. 16 buckets, 2 dB per
-- bin, range -20..+10 dB:
--   bucket  0: snr <= -20 dB
--   bucket 15: snr >= +10 dB
-- Range chosen to span LoRa demod thresholds (SF12 = -20, SF7 = -7.5)
-- with 5 buckets of headroom above SF7 for "easy decode" signal.
-- Used by both ACK piggyback (DATA-leg SNR feedback) and BCN entries
-- (chain-min SNR score). The decode helper returns the BIN CENTER so
-- EWMAs / comparisons treat quantization as fair rounding, not
-- systematic bias toward bin lower edge.
local function bucket_of_snr_4b(snr_db)
  local b = math.floor((snr_db + 20) / 2)
  if b < 0 then b = 0 end
  if b > 15 then b = 15 end
  return b
end

local function snr_of_bucket_4b(bucket)
  return -19 + bucket * 2  -- -19, -17, ..., +9, +11 (bin centers)
end

-- Differential pack_beacon — two-tier emission.
--
-- Phase 1 (priority): every rt[dest] with .dirty=true (set by rt_merge
--   on "new" / "promote" / "primary_refresh", and by rt_prune_cycle when
--   the primary was pruned). Sorted by dest_id for determinism. Capped at
--   max_entries — overflow waits for the next beacon (no information loss).
--
-- Phase 2 (background): the existing sliding-offset rotation fills any
--   remaining slots, skipping destinations already in the dirty page so
--   we never duplicate within a single beacon.
--
-- After emission: dirty flags for sent routes are cleared. The stable
-- offset advances ONLY by the number of stable slots used — so when
-- dirty fills the beacon, stable progress isn't lost.
--
-- Steady state with no churn → all flags clean → only Phase 2 runs →
-- byte-for-byte identical to the pre-differential pack_beacon.
local function pack_beacon_byte1(node)
  local b = (node.leaf_id & 0xf) << 4
  if node.has_schedule  then b = b | 0x08 end
  if node.self_gateway  then b = b | 0x04 end
  if node.is_mobile     then b = b | 0x02 end
  -- bit 0 reserved (zero)
  return b
end

local function pack_beacon(node, max_entries, offset)
  local all_dests = {}
  for dest_id, _ in pairs(node.rt) do
    table.insert(all_dests, dest_id)
  end
  table.sort(all_dests)
  local byte1 = pack_beacon_byte1(node)
  local total = #all_dests
  if total == 0 then
    return "B" .. string.char(byte1) .. string.char(node.id) .. string.char(0),
           0,
           { dirty_n = 0, stable_n = 0, total_dirty = 0 }
  end

  -- Phase 1: dirty routes (sorted, deterministic).
  local dirty_in_order = {}
  local dirty_set = {}                     -- O(1) skip lookup for Phase 2
  for _, dest_id in ipairs(all_dests) do
    if node.rt[dest_id].dirty then
      table.insert(dirty_in_order, dest_id)
      dirty_set[dest_id] = true
    end
  end
  local total_dirty = #dirty_in_order
  local dirty_n = math.min(total_dirty, max_entries)

  -- Phase 2: stable rotation — walk from offset, skip dirty, fill remaining.
  local stable_page = {}
  local remaining = max_entries - dirty_n
  local new_offset = offset
  if remaining > 0 then
    local idx = offset
    local steps = 0
    while #stable_page < remaining and steps < total do
      local d = all_dests[(idx % total) + 1]
      if not dirty_set[d] then
        table.insert(stable_page, d)
      end
      idx = idx + 1
      steps = steps + 1
    end
    new_offset = idx % total
  end
  local stable_n = #stable_page

  -- Build frame: dirty entries first, then stable.
  local n_total = dirty_n + stable_n
  local out = "B" .. string.char(byte1) .. string.char(node.id) .. string.char(n_total)
  local function pack_one(dest_id)
    local p = node.rt[dest_id].candidates[1]
    local b = bucket_of_snr_4b(p.score)               -- 4-bit bucket
    local hops_wire = (p.hops - 1) & 0x7              -- wire stores hops-1 (range 0..7)
    local is_gw     = (p.is_gateway == true) and 1 or 0
    local entry_byte2 = ((b & 0xf) << 4) | (hops_wire << 1) | is_gw
    out = out .. string.char(dest_id)
              .. string.char(p.next_hop)
              .. string.char(entry_byte2)
  end
  for i = 1, dirty_n do pack_one(dirty_in_order[i]) end
  for _, d  in ipairs(stable_page) do pack_one(d) end

  -- Clear dirty for routes that landed in this beacon (those that overflowed
  -- stay dirty for the next one).
  for i = 1, dirty_n do
    node.rt[dirty_in_order[i]].dirty = nil
  end

  return out, new_offset, {
    dirty_n     = dirty_n,
    stable_n    = stable_n,
    total_dirty = total_dirty,
  }
end

local function parse_beacon(frame)
  if #frame < 4 or frame:sub(1,1) ~= "B" then return nil end
  local b1  = frame:byte(2)
  local out = {
    leaf_id      = (b1 >> 4) & 0xf,
    has_schedule = (b1 & 0x08) ~= 0,
    self_gateway = (b1 & 0x04) ~= 0,
    is_mobile    = (b1 & 0x02) ~= 0,
    src          = frame:byte(3),
    entries      = {},
  }
  local n   = frame:byte(4)   -- n_entries (unchanged 8-bit width)
  local pos = 5               -- next byte after n_entries
  if out.has_schedule then
    if #frame < pos then return nil end           -- need at least the layer_count byte
    local layer_count = frame:byte(pos)
    pos = pos + 1
    -- skip layer_count × 4 bytes (schedule records — runtime path not implemented yet)
    pos = pos + layer_count * 4
  end
  if #frame < pos - 1 + 3*n then return nil end   -- length check (accounts for schedule skip)
  for _ = 1, n do
    local dest        = frame:byte(pos)
    local nxt         = frame:byte(pos + 1)
    local sh          = frame:byte(pos + 2)
    local score_bucket = (sh >> 4) & 0xf
    local hops_wire    = (sh >> 1) & 0x7
    local hops         = hops_wire + 1             -- decode hops-1 → hops
    local is_gateway   = (sh & 0x01) ~= 0
    table.insert(out.entries, {
      dest       = dest,
      next       = nxt,
      score      = snr_of_bucket_4b(score_bucket),
      score_bucket = score_bucket,
      hops       = hops,
      is_gateway = is_gateway,
    })
    pos = pos + 3
  end
  return out
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
-- after its 6-byte header — inner overhead (src_addr_len + src_addr =
-- 2 B at addr_len=0) + body + MAC (4 B). The receiver uses it to size
-- pending_rx_expiry to actual airtime instead of the worst-case
-- (max_payload_bytes), which mattered when bodies range 10–200 bytes —
-- real protocols can't afford to budget every flight at the absolute
-- upper bound.
-- RTS — 8 bytes (in-leaf, addr_len=0):
--   byte 0 : tag 'R'
--   byte 1 : src   (previous-hop, kept since first hop-level frame)
--   byte 2 : next  (immediate next-hop receiver)
--   byte 3 : addr_len(3 hi) | rsv(1) | leaf_id(4 lo)
--   byte 4 : dst   (final destination; single byte when addr_len=0)
--   byte 5 : ctr_lo(4 hi) | rsv(4 lo)
--   byte 6 : sf_bitmap (8)
--   byte 7 : payload_len (8)
local function pack_rts(leaf_id, src, dst, next_hop, ctr_lo, sf_bitmap, payload_len)
  local addr_len = 0
  local b3 = ((addr_len & 0x07) << 5) | (leaf_id & 0x0f)
  local b5 = (ctr_lo & 0x0f) << 4
  return "R" .. string.char(src)
              .. string.char(next_hop)
              .. string.char(b3)
              .. string.char(dst)
              .. string.char(b5)
              .. string.char(sf_bitmap)
              .. string.char(payload_len % 256)
end

local function parse_rts(frame)
  if #frame < 8 or frame:sub(1,1) ~= "R" then return nil end
  local b3 = frame:byte(4)
  local addr_len = (b3 >> 5) & 0x07
  if addr_len ~= 0 then return nil end          -- hierarchy support deferred
  local leaf_id = b3 & 0x0f
  local b5 = frame:byte(6)
  return {
    leaf_id     = leaf_id,
    src         = frame:byte(2),
    next        = frame:byte(3),
    dst         = frame:byte(5),
    ctr_lo      = (b5 >> 4) & 0x0f,
    sf_bitmap   = frame:byte(7),
    payload_len = frame:byte(8),
  }
end

-- CTS — 2 bytes, bit-packed:
--   byte 0 : tag 'C'
--   byte 1 : ctr_lo (4 hi nibble) | (chosen_data_sf - 5) (3) | reserved (1)
local function pack_cts(ctr_lo, chosen_data_sf)
  local sf_off = (chosen_data_sf - 5) & 0x7
  local b1 = ((ctr_lo & 0xf) << 4) | (sf_off << 1)
  return "C" .. string.char(b1)
end

local function parse_cts(frame)
  if #frame < 2 or frame:sub(1,1) ~= "C" then return nil end
  local b1 = frame:byte(2)
  return {
    ctr_lo         = (b1 >> 4) & 0xf,
    chosen_data_sf = ((b1 >> 1) & 0x7) + 5,
  }
end

-- ACK — 2 bytes, bit-packed:
--   byte 0 : tag 'K'
--   byte 1 : ctr_lo (4 hi nibble) | snr_bucket (4 lo nibble)
local function pack_ack(ctr_lo, snr_db)
  local bucket = (snr_db ~= nil) and bucket_of_snr_4b(snr_db) or 15
  local b1 = ((ctr_lo & 0xf) << 4) | (bucket & 0xf)
  return "K" .. string.char(b1)
end

local function parse_ack(frame)
  if #frame < 2 or frame:sub(1,1) ~= "K" then return nil end
  local b1 = frame:byte(2)
  local bucket = b1 & 0xf
  return {
    ctr_lo      = (b1 >> 4) & 0xf,
    snr_db      = snr_of_bucket_4b(bucket),
    snr_bucket  = bucket,
  }
end

-- NACK ('N'): receiver tells the sender "I can't accept this RTS right now,
-- I'll be free in busy_for_ms milliseconds". 16-bit relative duration is
-- clock-sync-free; 65 s is plenty for any flight estimate.
-- DATA wire layout (post-Phase-4, per ROADMAP §7.0.1):
--   byte 0   : tag 'D'
--   byte 1   : addr_len(3 hi) | rsv(1) | E2E_ACK_REQ | E2E_IS_ACK | IS_MULTICAST | rsv
--   byte 2   : next (immediate next-hop receiver)
--   byte 3   : dst  (final destination — single byte when addr_len==0)
--   bytes 4-5: ctr (16-bit LE, per-(origin, dst) counter)
--   bytes 6..(5+n): ciphertext slot (plaintext placeholder until §8 crypto).
--                    Inner layout: src_addr_len(1) | src_addr(src_addr_len+1) | body
--                    For addr_len=0: src_addr_len=0, src_addr=[origin_id].
--                    body = user_text (normal) OR [acked_ctr_lo,acked_ctr_hi]
--                           (when E2E_IS_ACK is set on byte 1)
--   last 4   : MAC — 4-byte zero placeholder until §8 lands (Poly1305-truncated then)
--
-- `ctr` is allocated by self:next_ctr(peer_id) per outbound (self → peer).
-- It triple-duties as crypto-nonce entropy (when §8 lands), replay
-- protection (today: TTL-based seen_origins dedup; strict-monotonic NV
-- counters land with §8), and the (origin, ctr) key used by seen_origins
-- dedup and pending_e2e lookup. CTS/ACK/NACK echo only the LOW NIBBLE
-- (ctr_lo = ctr & 0xf) for hop-level matching.
--
-- Frame design rationale (see §5 in docs/ROADMAP.md):
--   • Per-message opt-in via DATA_FLAG_E2E_ACK_REQ — bulk chat doesn't
--     pay the round-trip; explicitly-marked important sends do.
--   • E2E ACK is just a tiny DATA flight back to origin, routed via the
--     normal data-plane mechanics. No new frame type needed; only
--     wire-flag discrimination via DATA_FLAG_E2E_IS_ACK.
--   • E2E ACK on-wire size ≈ 10 (header+MAC) + 2 (body=acked_ctr) = 12 B
--     per hop.
--   • Under §9 T2 privacy + §8 crypto, the "ciphertext slot" actually
--     gets encrypted; src_addr + body move INSIDE the ciphertext, and
--     forwarders can no longer read origin from the wire. The wire
--     LAYOUT stays unchanged — only encryption gets enabled.
-- DATA wire-level E2E flag bits (byte 1 of the DATA frame, bits 2-3).
-- These replaced the old inner-payload origin header flags in §7.0.1.
local DATA_FLAG_E2E_ACK_REQ = 0x08   -- bit 3 of byte 1 (E2E_ACK_REQ)
local DATA_FLAG_E2E_IS_ACK  = 0x04   -- bit 2 of byte 1 (E2E_IS_ACK)
local DATA_FLAG_IS_MCAST    = 0x02   -- bit 1 of byte 1 (IS_MULTICAST, always 0 this phase)
local MAC_LEN = 4                    -- 4-byte zero MAC placeholder until §8 crypto lands

-- NACK — 3 bytes:
--   byte 0 : tag 'N'
--   byte 1 : reason (4 hi nibble) | ctr_lo (4 lo nibble)
--   byte 2 : payload (reason-specific)
--
-- Reasons:
--   NACK_REASON_BUSY_RX (0): pending_rx-busy signal.
--     payload = busy_for_ms / 16  (quantized, 16 ms granularity, range 0..4080 ms)
--     CEILING-divide so the reported window is never shorter than actual.
--   NACK_REASON_BUDGET (1): duty-cycle budget is exhausted at the
--     receiver. Don't keep retrying me — route around.
--     payload = tier(4 hi) | headroom_buckets(4 lo)
--     tier 0..15; headroom_buckets 0..15 → 0..100% (value/15 × 100%).
--
-- Shrunk from 4→3 bytes per ROADMAP §7.0.5. busy_for_ms quantum = 16 ms
-- (well below the 50 ms natural retry-jitter floor). Max range 4080 ms
-- covers SF12 worst-case with 4× headroom.
local NACK_REASON_BUSY_RX = 0
local NACK_REASON_BUDGET  = 1

local NACK_BUSY_QUANTUM_MS = 16   -- granularity of BUSY_RX payload

-- NACK — 3 bytes:
--   byte 0 : tag 'N'
--   byte 1 : reason (4 hi) | ctr_lo (4 lo)
--   byte 2 : payload (reason-specific)
--             BUSY_RX:  busy_for_ms / 16  (0..4080 ms, 16 ms granularity)
--             BUDGET:   tier (4 hi) | headroom_buckets (4 lo)
local function pack_nack(ctr_lo, reason, payload)
  reason  = reason or NACK_REASON_BUSY_RX
  payload = payload or 0
  if payload < 0 then payload = 0 elseif payload > 255 then payload = 255 end
  local byte1 = ((reason & 0xf) << 4) | (ctr_lo & 0xf)
  return "N" .. string.char(byte1) .. string.char(payload)
end

local function parse_nack(frame)
  if #frame < 3 or frame:sub(1,1) ~= "N" then return nil end
  local b1 = frame:byte(2)
  local payload = frame:byte(3)
  local reason = (b1 >> 4) & 0xf
  local out = {
    reason  = reason,
    ctr_lo  = b1 & 0xf,
    payload = payload,
  }
  if reason == NACK_REASON_BUSY_RX then
    out.busy_for_ms = payload * NACK_BUSY_QUANTUM_MS
  elseif reason == NACK_REASON_BUDGET then
    out.budget_tier             = (payload >> 4) & 0xf
    out.budget_headroom_buckets = payload & 0xf
  end
  return out
end

-- Q — RREQ-route, 4 bytes:
--   byte 0 : tag 'Q'
--   byte 1 : src (8) — the requester
--   byte 2 : dest (8) — destination they want a route for
--   byte 3 : leaf_id (4 hi nibble) | reserved (4 lo nibble)
-- One-hop route query. Direct neighbours that have rt[dest] mark it
-- dirty + schedule a triggered beacon (the differential beacon
-- mechanism then prioritises that dest in the next emission).
-- Receivers without rt[dest] silent-drop. Dedup at responder via
-- self.q_responded_to keyed by (src, dest); dedup at sender via
-- self.q_queried keyed by dest.
local function pack_q(leaf_id, src, dest)
  local b3 = (leaf_id & 0xf) << 4
  return "Q" .. string.char(src) .. string.char(dest) .. string.char(b3)
end

local function parse_q(frame)
  if #frame < 4 or frame:sub(1,1) ~= "Q" then return nil end
  return {
    src        = frame:byte(2),
    dest       = frame:byte(3),
    leaf_id = (frame:byte(4) >> 4) & 0xf,
  }
end

-- DATA — 10 + n bytes (in-leaf, addr_len=0):
--   byte 0   : tag 'D'
--   byte 1   : addr_len(3 hi) | rsv(1) | E2E_ACK_REQ(1) | E2E_IS_ACK(1) | IS_MULTICAST(1) | rsv(1)
--   byte 2   : next (immediate next-hop receiver)
--   byte 3   : dst  (final destination — single byte when addr_len==0)
--   bytes 4-5: ctr (16-bit LE, per-(origin,dst) counter)
--   bytes 6..(5+n): ciphertext (= plaintext placeholder for now;
--                    carries src_addr_len(1) | src_addr(1) | body)
--   last 4   : MAC (4-byte zero placeholder until §8 crypto lands)
--
-- Inner payload (ciphertext slot, plaintext today):
--   byte 6   : src_addr_len (= 0 for in-leaf / flat addresses)
--   byte 7   : src_addr (origin's 8-bit mesh id; 1 byte when src_addr_len=0)
--   bytes 8+  : body (user_text for normal DATA; [acked_ctr_lo, acked_ctr_hi] for E2E ACK)
local function pack_data(origin, next_hop, dst, ctr, flags, inner)
  -- inner = pre-assembled bytes: src_addr_len(1) | src_addr(1) | body
  local addr_len = 0                                      -- in-leaf only this phase
  local byte1 = ((addr_len & 0x7) << 5) | (flags & 0x0e) -- flags: bits 1-3 only
  local ctr_lo_byte = ctr & 0xff
  local ctr_hi_byte = (ctr >> 8) & 0xff
  local mac = string.rep("\0", MAC_LEN)
  return "D" .. string.char(byte1)
              .. string.char(next_hop)
              .. string.char(dst)
              .. string.char(ctr_lo_byte)
              .. string.char(ctr_hi_byte)
              .. inner
              .. mac
end

local function parse_data(frame)
  if #frame < 10 or frame:sub(1,1) ~= "D" then return nil end
  local b1 = frame:byte(2)
  local addr_len = (b1 >> 5) & 0x07
  if addr_len ~= 0 then return nil end        -- hierarchy deferred
  local flags    = b1 & 0x0e                  -- bits 1-3
  local next_hop = frame:byte(3)
  local dst      = frame:byte(4)
  local ctr_lo_byte = frame:byte(5)
  local ctr_hi_byte = frame:byte(6)
  local ctr      = ctr_lo_byte | (ctr_hi_byte << 8)
  -- inner spans byte 7 .. (#frame - MAC_LEN)
  local inner_end = #frame - MAC_LEN
  if inner_end < 7 then return nil end
  local inner    = frame:sub(7, inner_end)
  if #inner < 2 then return nil end           -- need src_addr_len + src_addr
  local src_addr_len = inner:byte(1)
  if src_addr_len ~= 0 then return nil end    -- flat addresses only this phase
  local origin   = inner:byte(2)
  local body     = inner:sub(3)
  return {
    flags         = flags,
    e2e_ack_req   = (flags & DATA_FLAG_E2E_ACK_REQ) ~= 0,
    e2e_is_ack    = (flags & DATA_FLAG_E2E_IS_ACK) ~= 0,
    is_multicast  = (flags & DATA_FLAG_IS_MCAST) ~= 0,
    next          = next_hop,
    dst           = dst,
    ctr           = ctr,
    ctr_lo        = ctr & 0xf,               -- low nibble for hop-level match
    origin        = origin,
    body          = body,
    -- 'inner' kept for verbatim relay by forwarders
    inner         = inner,
  }
end

-- ---------- airtime + retry plumbing ----------------------------------------

-- Frame-header lengths (excluding payload). Computed from the wire-format
-- table at top of file so airtime predictions stay precise as we extend the
-- protocol — bump these if the frame layout changes.
local RTS_LEN = 8       -- 'R' + src + next + [addr_len|rsv|leaf_id] + dst + [ctr_lo<<4|rsv] + sf_bitmap + payload_len
local CTS_LEN = 2       -- 'C' + (ctr_lo<<4 | (sf-5)<<1 | reserved_1)
local DATA_HDR_LEN = 6  -- 'D' + byte1 + next + dst + ctr_lo + ctr_hi (inner+MAC follow)
-- DATA wire overhead beyond inner body: 2 inner-header bytes (src_addr_len + src_addr) + MAC_LEN.
-- RTS payload_len = #body + DATA_INNER_OVERHEAD for in-leaf frames.
local DATA_INNER_OVERHEAD = 2 + MAC_LEN  -- src_addr_len(1) + src_addr(1) + MAC(4) = 6
local ACK_LEN = 2       -- 'K' + (ctr_lo<<4 | snr_bucket)
local NACK_LEN = 3      -- 'N' + (reason_4|ctr_lo_4) + payload (reason-specific encoding)
local Q_LEN    = 4      -- 'Q' + src + dest + (leaf_id_4|reserved_4)

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

-- Per-message retry budget. The effective rts_max_retries for a message
-- shrinks by its requeue_count: a fresh message (requeue_count=0) gets
-- the full base budget; each subsequent cascade-requeue cycle gives it
-- one fewer RTS retry per next-hop. Combined with the K=3 cascade alts,
-- this means a retried-once message tries 3 alts × 2 retries = 6 RTS
-- attempts/cycle vs 9 for a fresh one; a retried-twice gets 3 alts × 1
-- retry = 3; a retried-thrice gets 3 alts × 0 retries = 3 (the alt
-- cascade itself still walks the K candidates, just with no rty per).
-- Channel time per cycle shrinks accordingly, letting zombie messages
-- die faster and freeing capacity for fresh ones.
local function effective_rts_max_retries(self, requeue_count)
  local n = self.rts_max_retries - (requeue_count or 0)
  if n < 0 then n = 0 end
  return n
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

-- Anti-spam observation: append an event to per_sender_originator[X]'s
-- sliding window, prune old entries. Called from on_recv when we observe
-- an RTS or CTS frame from direct sender X. `kind` is "rts" or "cts".
-- airtime_ms is the observed frame's airtime (estimated from frame
-- bytes + the SF/BW the runtime gives us). ctr_lo is the frame's 4-bit
-- ctr_lo — used for retry deduplication.
--
-- DEDUP. RTS frames are retried (RTS-rty) with the SAME ctr_lo as the
-- original attempt. Counting retries as fresh originations would inflate
-- the apparent rate dramatically (a legitimate originator with
-- rts_max_retries=3 across K=3 alts = up to 12 R observations per
-- message). We dedup by (kind, ctr_lo) within a retry window
-- (default 10 s, longer than rts_max_retries × rts_timeout ≈ 6 s):
-- repeated (kind, ctr_lo) inside the window refreshes the existing
-- entry's timestamp, no new event added. Outside the window we treat
-- it as a fresh observation (handles ctr_lo 4-bit wraparound at high
-- send rates).
--
-- The mechanism doesn't reach into the wire `origin` field — works
-- equally well under §9 T2 privacy where origin is encrypted in the
-- payload. We only need to know who PHYSICALLY transmitted the frame
-- (meta.src on the on_recv callback, which the LoRa runtime provides
-- from the modem's RX metadata, not from the frame body).
local function track_originator_observation(self, sender_id, kind, ctr_lo, airtime_ms)
  if sender_id == nil then return end
  if not self.per_sender_originator then return end   -- tracking disabled
  local now = self:now()
  local entry = self.per_sender_originator[sender_id]
  if entry == nil then
    entry = { events = {} }
    self.per_sender_originator[sender_id] = entry
  end
  -- Prune events older than window.
  local cutoff = now - self.originator_window_ms
  local retry_window = self.originator_retry_dedup_ms or 10000
  local kept = {}
  local dedup_hit = nil
  for _, ev in ipairs(entry.events) do
    if ev.t >= cutoff then
      if dedup_hit == nil and ev.kind == kind and ev.ctr_lo == ctr_lo
         and (now - ev.t) < retry_window then
        -- Same kind+ctr_lo within retry window — this is a retry of the
        -- earlier observation, not a new origination. Refresh timestamp
        -- (so the entry decays from the most recent observation, not
        -- the first) and DON'T add a new event.
        ev.t = now
        dedup_hit = ev
      end
      table.insert(kept, ev)
    end
  end
  if dedup_hit == nil then
    table.insert(kept, {
      t = now, kind = kind, ctr_lo = ctr_lo, air = airtime_ms or 0,
    })
  end
  entry.events = kept
end

-- Compute the current state of sender X over the active sliding window.
-- Returns (apparent_origination, total_airtime_ms, rts_count, cts_count).
-- apparent_origination = max(0, rts_count - cts_count) — a legitimate
-- forwarder has rts_count ≈ cts_count (one CTS per inbound flight, one
-- RTS per outbound forward) so this is near 0; an originator has lots
-- of RTS without CTS so it climbs.
local function compute_originator_metric(self, sender_id)
  if not self.per_sender_originator then return 0, 0, 0, 0 end
  local entry = self.per_sender_originator[sender_id]
  if entry == nil then return 0, 0, 0, 0 end
  local now = self:now()
  local cutoff = now - self.originator_window_ms
  local rts, cts, air = 0, 0, 0
  for _, ev in ipairs(entry.events) do
    if ev.t >= cutoff then
      air = air + (ev.air or 0)
      if ev.kind == "rts" then rts = rts + 1
      elseif ev.kind == "cts" then cts = cts + 1
      end
    end
  end
  local app_orig = rts - cts
  if app_orig < 0 then app_orig = 0 end
  return app_orig, air, rts, cts
end

-- Originator self-rate-monitor: track count of this node's own
-- issue_send calls in the sliding window. Used by the on-failure
-- check that emits originator_self_over_budget so the app can surface
-- "your send may have failed because you're over fair-share budget."
local function self_originate_observe(self)
  if not self.own_origination_events then return end
  local now = self:now()
  local cutoff = now - self.originator_window_ms
  local kept = {}
  for _, t in ipairs(self.own_origination_events) do
    if t >= cutoff then table.insert(kept, t) end
  end
  table.insert(kept, now)
  self.own_origination_events = kept
end

local function self_originate_count(self)
  if not self.own_origination_events then return 0 end
  local now = self:now()
  local cutoff = now - self.originator_window_ms
  local n = 0
  for _, t in ipairs(self.own_origination_events) do
    if t >= cutoff then n = n + 1 end
  end
  return n
end

-- Duty-cycle pre-check. Returns (ok, wait_ms). When ok=true, the TX may
-- proceed; the runtime's airtime log will absorb it. When ok=false, the
-- caller should self:after(wait_ms, retry_callback) and re-check on fire.
-- The runtime also hard-blocks via on_radio_busy(reason="duty_cycle_exceeded")
-- as a safety net; this pre-check exists so the script defers proactively
-- instead of waiting for the round-trip and retrying via on_radio_busy.
-- Pre-check uses the same data the runtime uses, queried via the
-- self:airtime_used_ms / self:oldest_tx_end_ms primitives — composes for free.
-- Budget tier — coarse 4-level summary of remaining duty-cycle budget.
-- Used both locally (gate own BCN emission) and at the wire (NACK reason
-- = budget_low + tier so senders can deprioritize this neighbour).
-- Returns one of:
--   0 = HEALTHY       (>=50% budget remaining; normal operation)
--   1 = STRAINED      (20-50% remaining; emit BCN sparingly)
--   2 = CRITICAL      (5-20% remaining; refuse forwards via NACK)
--   3 = EXHAUSTED     (<5% remaining; duty_cycle_blocked is imminent)
local BUDGET_TIER_HEALTHY   = 0
local BUDGET_TIER_STRAINED  = 1
local BUDGET_TIER_CRITICAL  = 2
local BUDGET_TIER_EXHAUSTED = 3

local function compute_budget_tier(self)
  if not self.duty_cycle or self.duty_cycle <= 0
     or not self.duty_cycle_budget_ms or self.duty_cycle_budget_ms <= 0 then
    return BUDGET_TIER_HEALTHY    -- duty-cycle disabled
  end
  local used = self:airtime_used_ms(self.duty_cycle_window_ms)
  local pct_used = 100.0 * used / self.duty_cycle_budget_ms
  if pct_used >= self.budget_exhausted_pct then return BUDGET_TIER_EXHAUSTED end
  if pct_used >= self.budget_critical_pct  then return BUDGET_TIER_CRITICAL  end
  if pct_used >= self.budget_strained_pct  then return BUDGET_TIER_STRAINED  end
  return BUDGET_TIER_HEALTHY
end

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
-- so peer NACK / busy-replies still match the right ctr_lo; the LBT defer
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
-- Budget-tier score penalty (dB). Subtracts from the candidate's SNR
-- margin so a CRITICAL route has to be substantially better than a
-- HEALTHY alt to win the primary slot. Tier 0 = HEALTHY (no penalty),
-- 1 = STRAINED, 2 = CRITICAL, 3 = EXHAUSTED.
local TIER_SCORE_PENALTY_DB = { [0] = 0.0, [1] = 2.0, [2] = 5.0, [3] = 20.0 }

-- Read this node's belief about neighbour `node_id`'s budget tier.
-- Returns 0 (HEALTHY) if no mark or TTL expired. Updated by the budget
-- NACK reception handler; expires via neighbor_budget_tier_ttl_ms so
-- a saturated neighbour eventually returns to the primary pool if no
-- fresh NACKs arrive. Self-defence against ossifying out a peer that
-- recovered without us hearing it.
local function get_neighbor_tier(self, node_id)
  if node_id == nil or not self.neighbor_budget_tier then return 0 end
  local tier = self.neighbor_budget_tier[node_id]
  if not tier or tier == 0 then return 0 end
  local set_at = (self.neighbor_budget_tier_set_at
                  and self.neighbor_budget_tier_set_at[node_id]) or 0
  local ttl = self.neighbor_budget_tier_ttl_ms or 300000
  if self:now() - set_at >= ttl then
    self.neighbor_budget_tier[node_id] = nil
    if self.neighbor_budget_tier_set_at then
      self.neighbor_budget_tier_set_at[node_id] = nil
    end
    return 0
  end
  return tier
end

-- Tier-aware effective score: c.score minus the dB penalty for its
-- next_hop's known budget tier. Use this anywhere we previously
-- compared raw c.score, so the routing table tracks usable capacity
-- not just radio quality.
local function effective_score(self, c)
  local tier = get_neighbor_tier(self, c.next_hop)
  return c.score - (TIER_SCORE_PENALTY_DB[tier] or 0)
end

local function route_strictly_better(self, a, b, viab_db)
  local a_score = effective_score(self, a)
  local b_score = effective_score(self, b)
  local av = a_score >= viab_db
  local bv = b_score >= viab_db
  if av and not bv then return true end
  if bv and not av then return false end
  if av and bv then
    -- both viable: hops-first, effective_score breaks ties (RIP/OSPF/AODV order)
    if a.hops < b.hops then return true end
    if a.hops > b.hops then return false end
    return a_score > b_score
  else
    -- both non-viable: effective_score-first (least-worst link), hops breaks ties.
    if a_score > b_score then return true end
    if a_score < b_score then return false end
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
-- Sets entry.dirty = true on every mutation that changes the route this
-- node would advertise (i.e., changes candidates[1]). pack_beacon
-- prioritises dirty entries for the next emission so route changes
-- propagate within one beacon period instead of waiting for the
-- sliding-offset rotation to come around.
local function rt_merge(self, rt, dest_id, cand, viab_db)
  -- Sort callback (closure over self/viab_db). Uses effective_score
  -- inside route_strictly_better so neighbour tier penalties shape
  -- the routing table itself, not just runtime next-hop selection.
  local function sort_fn(a, b)
    return route_strictly_better(self, a, b, viab_db) or
           (not route_strictly_better(self, b, a, viab_db)
            and effective_score(self, a) > effective_score(self, b))
  end
  local entry = rt[dest_id]
  if entry == nil then
    rt[dest_id] = { candidates = { cand }, dirty = true }   -- new dest
    return "new"
  end

  -- Match-by-next_hop: refresh in place if cand strictly better.
  for i, c in ipairs(entry.candidates) do
    if c.next_hop == cand.next_hop then
      if route_strictly_better(self, cand, c, viab_db) then
        local was_primary = (i == 1)
        entry.candidates[i] = cand
        table.sort(entry.candidates, sort_fn)
        local now_primary = (entry.candidates[1].next_hop == cand.next_hop)
        if now_primary then
          entry.dirty = true                                  -- primary refresh
          return "primary_refresh"
        elseif was_primary then
          entry.dirty = true                                  -- another took over
          return "promote"
        end
        return "alt_install"
      end
      -- Equal/worse but same next_hop: refresh metadata, no order change.
      c.last_seen_ms = cand.last_seen_ms
      c.n2_hop       = cand.n2_hop
      c.is_gateway   = cand.is_gateway      -- identity metadata, not a ranking input
      return "no_change"
    end
  end

  -- New next_hop, room to spare.
  if #entry.candidates < MAX_RT_CANDIDATES then
    table.insert(entry.candidates, cand)
    table.sort(entry.candidates, sort_fn)
    if entry.candidates[1].next_hop == cand.next_hop then
      entry.dirty = true                                      -- new candidate became primary
      return "promote"
    end
    return "alt_install"
  end

  -- Full table — replace the worst (last in sorted order) only if cand
  -- strictly beats it.
  local worst = entry.candidates[#entry.candidates]
  if not route_strictly_better(self, cand, worst, viab_db) then
    return "no_change"
  end
  entry.candidates[#entry.candidates] = cand
  table.sort(entry.candidates, sort_fn)
  if entry.candidates[1].next_hop == cand.next_hop then
    entry.dirty = true                                        -- displaced into primary
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
  local primary_pruned = false
  local kept = {}
  for i, c in ipairs(entry.candidates) do
    if c.n2_hop == sender_id then
      local slot = (i == 1) and "primary" or "alt"
      if i == 1 then primary_pruned = true end
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
      -- If we lost the primary, the new candidates[1] is what we'd
      -- advertise — re-mark dirty so the next beacon carries it.
      if primary_pruned then entry.dirty = true end
    end
    schedule_triggered_beacon(self)
  end
end

-- Stale-route aging. Walk every rt[dest], evict candidates whose
-- last_seen_ms is older than the TTL for their hop class:
--
--   c.hops == 1   →  rt_aging_ttl_neighbor_ms     (direct neighbour)
--   c.hops >= 2   →  rt_aging_ttl_remote_ms       (multi-hop)
--
-- Two-tier rationale: direct neighbours get refreshed by EVERY received
-- frame (rt_merge top-of-on_recv hook updates last_seen_ms whenever
-- this neighbour TXes anything we hear), so 1-hop entries can have a
-- shorter TTL — death detection for moving / dying neighbours stays
-- responsive. Multi-hop entries only refresh when their advertiser's
-- rotation slot comes up, so they need a much longer TTL to survive
-- normal rotation gaps without being false-evicted.
--
-- If primary evicted, mark entry.dirty so the differential beacon ships
-- the new primary. If all candidates evicted, drop the entry entirely
-- + schedule a triggered beacon (no wire-format way to say "I no
-- longer route to X", but the trigger ensures the rest of our table
-- propagates without the gone-dest, so neighbours' own aging eventually
-- catches up).
local function age_out_stale_routes(self)
  if next(self.rt) == nil then return end
  local now = self:now()
  local ttl_n = self.rt_aging_ttl_neighbor_ms
  local ttl_r = self.rt_aging_ttl_remote_ms
  if (ttl_n <= 0) and (ttl_r <= 0) then return end       -- aging disabled
  local any_evicted = false
  -- Collect dest_ids first (Lua's pairs+modify is OK in 5.3+ but only
  -- for removal of the current key; we want bulk-safe iteration).
  local dests = {}
  for dest_id, _ in pairs(self.rt) do
    table.insert(dests, dest_id)
  end
  for _, dest_id in ipairs(dests) do
    local entry = self.rt[dest_id]
    if entry then
      local kept = {}
      local primary_evicted = false
      for i, c in ipairs(entry.candidates) do
        local ttl = (c.hops and c.hops <= 1) and ttl_n or ttl_r
        local age = now - c.last_seen_ms
        if ttl <= 0 or age < ttl then
          -- TTL ≤ 0 disables aging for this hop class; keep the entry.
          table.insert(kept, c)
        else
          if i == 1 then primary_evicted = true end
          self:emit("rt_aged", {
            dest = dest_id, slot = (i == 1) and "primary" or "alt",
            next_hop = c.next_hop, hops = c.hops,
            age_ms = age, ttl_ms = ttl,
          })
          self:log(string.format(
            "rt_aged dst=%s %s via %s hops=%d (age %dms > ttl %dms)",
            name_of(self, dest_id), (i == 1) and "primary" or "alt",
            name_of(self, c.next_hop), c.hops or -1, age, ttl))
          any_evicted = true
        end
      end
      if #kept == 0 then
        self.rt[dest_id] = nil
      elseif #kept < #entry.candidates then
        entry.candidates = kept
        if primary_evicted then entry.dirty = true end
      end
    end
  end
  if any_evicted then schedule_triggered_beacon(self) end
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

-- Re-send the current pending_tx's RTS with the same ctr_lo. Shared by
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
      origin = px.origin, payload = px.user_text, ctr = px.ctr,
      ctr_lo = px.ctr_lo, next_hop = px.next, delay_ms = val_b,
      source = "tx_rts_retry", reason = reason,
    })
    self:log(string.format("tx_blind_defer (tx_rts_retry) msg=%d -> %s deferred %dms",
      px.ctr_lo, name_of(self, px.next), val_b))
    self:after(val_b, function() tx_rts_retry(self, reason) end)
    return
  elseif action_b == "alt" then
    self:emit("tx_blind_alt", {
      origin = px.origin, payload = px.user_text, ctr = px.ctr,
      ctr_lo = px.ctr_lo, from_next = px.next, to_next = val_b,
    })
    self:log(string.format("tx_blind_alt (tx_rts_retry) msg=%d %s -> %s",
      px.ctr_lo, name_of(self, px.next), name_of(self, val_b)))
    px.alts_tried[px.next] = true   -- mark previous next_hop as tried
    px.next = val_b
    px.retries_left = effective_rts_max_retries(self, px.requeue_count)
  end

  -- payload_len lets the receiver size its pending_rx_expiry to the
  -- actual DATA airtime instead of max_payload_bytes worst-case.
  local rts = pack_rts(self.leaf_id, self.id, px.dst, px.next, px.ctr_lo,
                       self.allowed_sf_bitmap, #px.payload + MAC_LEN)
  self:emit("rts_retry", {
    origin = px.origin, payload = px.user_text, ctr = px.ctr,
    dst = px.dst, next = px.next,
    ctr_lo = px.ctr_lo, retries_left = px.retries_left, reason = reason,
  })
  self:log(string.format("rts_retry -> %s ctr_lo=%d (retries_left=%d reason=%s)",
    name_of(self, px.next), px.ctr_lo, px.retries_left, reason))
  tx_initiating(self, rts, {
    sf    = self.routing_sf,
    label = "RTS-rty",
    info  = string.format("retry next=%s msg=%d retries_left=%d reason=%s",
      name_of(self, px.next), px.ctr_lo, px.retries_left, reason),
  }, function() start_rts_timeout(self) end)
  -- RX stays on routing_sf — both CTS and NACK are control-plane responses
  -- on routing_sf now, no retune needed until DATA is about to TX.
end

-- Helper: when pending_tx exhausts all K cascade alts, try to push the
-- item back into tx_queue with exponential backoff so other queued items
-- can rotate through. Returns true if the item was requeued (caller
-- should clear pending_tx and become_free without emitting the legacy
-- giveup events). Returns false when the requeue caps are hit (caller
-- emits the legacy path_cascade_exhausted + rts_giveup / data_ack_giveup
-- and truly drops). trigger arg is "rts_giveup" or "ack_giveup" — used
-- only for the cascade_requeue emit's diagnostics, NOT for the legacy
-- emits in the false branch (caller still owns those).
-- Originator self-monitoring: when a flight truly fails at the originator
-- (cascade-requeue caps exhausted; all alts tried), emit a UX hint that
-- the failure MAY be because this node is over its fair-share budget.
-- The app layer can surface this as "your send may have been rate-limited
-- — try again in a few minutes." It's a best-effort signal, not
-- authoritative (the actual cause could be anything from radio drop to
-- destination offline), but high own_origination_count + recent failure
-- is a useful correlation.
--
-- Emitted only when:
--   • px is ours (origin == self.id, previous_hop == nil)
--   • own_origination_count > originator_self_warn_fraction × inbound threshold
--     (default 0.5 × 6 = 3 originations in last 5 min)
--     OR own duty-cycle tier is STRAINED+
local function maybe_emit_self_over_budget(self, px, trigger)
  if px == nil then return end
  if px.origin ~= self.id then return end       -- not our own send
  if px.previous_hop ~= nil then return end     -- we were forwarding
  local own_count = self_originate_count(self)
  local warn_count = math.max(1, math.floor(
    self.originator_self_warn_fraction * (self.originator_max_per_window or 6)))
  local tier = compute_budget_tier(self)
  if own_count >= warn_count or tier >= BUDGET_TIER_STRAINED then
    self:emit("originator_self_over_budget", {
      origin        = self.id,
      ctr           = px.ctr,
      dst           = px.dst,
      ctr_lo        = px.ctr_lo,
      trigger       = trigger,                  -- "rts_giveup" / "ack_giveup" / etc.
      own_originate_count_in_window = own_count,
      warn_threshold_count          = warn_count,
      duty_cycle_tier               = tier,
      window_ms                     = self.originator_window_ms,
      hint = "your send may have failed because you're over fair-share budget",
    })
    self:log(string.format(
      "originator_self_over_budget msg=%d trigger=%s own_count=%d/%d tier=%d",
      px.ctr_lo, trigger, own_count, warn_count, tier))
  end
end

local function try_cascade_requeue(self, trigger)
  local px = self.pending_tx
  if px == nil then return false end
  local now = self:now()
  local enq = px.enqueue_time_ms or now
  local total_age_ms = now - enq
  local next_count = (px.requeue_count or 0) + 1

  -- Hard caps come first — these are operator-set ceilings nothing can
  -- override. Below them, the adaptive load gate may also skip.
  if next_count > self.cascade_requeue_max then return false end
  if total_age_ms >= self.cascade_requeue_total_max_ms then return false end

  -- Load-adaptive back-pressure: shrink the effective requeue budget
  -- when this node's tx_queue is already deep. Each item beyond
  -- cascade_requeue_load_threshold subtracts 1 from the budget. At
  -- queue depth = threshold + cascade_requeue_max, the budget hits 0
  -- and new failures drop immediately instead of being requeued.
  -- Rationale: cascade-requeue is helpful when capacity is available
  -- (giving messages multiple chances), but counterproductive when
  -- the network is overloaded (retries themselves choke the channel,
  -- so messages that COULD have succeeded under lighter load also
  -- fail). On s04 60 min we observed exhausted messages consuming
  -- 30x more channel-time than delivered ones — the "cascade-waste"
  -- pathology. By tying budget to local queue depth, each node
  -- self-throttles: when stressed, drop fast and free capacity for
  -- healthy flights elsewhere. See analyzer section (14) for the
  -- ratio metric that detects this failure mode.
  local queue_depth = #self.tx_queue
  local load_excess = math.max(0,
    queue_depth - self.cascade_requeue_load_threshold)
  local effective_max = math.max(0,
    self.cascade_requeue_max - load_excess)
  if next_count > effective_max then
    -- Diagnostic emit distinguishes load-induced drops from hard-cap
    -- exhaustion. Caller (rts_timeout_fire / ack_timeout_fire) still
    -- emits the legacy path_cascade_exhausted + rts_giveup so existing
    -- analyzers stay backward-compatible.
    self:emit("cascade_load_skip", {
      origin         = px.origin,
      payload        = px.user_text,
      ctr            = px.ctr,
      dst            = px.dst,
      ctr_lo         = px.ctr_lo,
      requeue_count  = next_count,
      queue_depth    = queue_depth,
      load_threshold = self.cascade_requeue_load_threshold,
      effective_max  = effective_max,
      total_age_ms   = total_age_ms,
      trigger        = trigger,
    })
    self:log(string.format(
      "cascade_load_skip msg=%d dst=%s queue=%d eff_max=%d/%d (load adaptive drop, trigger=%s)",
      px.ctr_lo, name_of(self, px.dst), queue_depth,
      effective_max, self.cascade_requeue_max, trigger))
    return false
  end
  -- Exponential backoff: base * 2^(requeue_count - 1), capped. Using
  -- (next_count - 1) so the first requeue waits exactly base_ms (not
  -- base*2). Math.huge guard not needed because cap clips before overflow.
  local backoff_ms = self.cascade_requeue_base_ms * (2 ^ (next_count - 1))
  if backoff_ms > self.cascade_requeue_backoff_cap_ms then
    backoff_ms = self.cascade_requeue_backoff_cap_ms
  end
  backoff_ms = math.floor(backoff_ms)
  table.insert(self.tx_queue, {
    origin     = px.origin,
    dst_id     = px.dst,
    dst_name   = name_of(self, px.dst),
    payload    = px.payload,
    user_text  = px.user_text,
    ctr        = px.ctr,
    flags      = px.flags or 0,
    previous_hop    = px.previous_hop,
    enqueue_time_ms = enq,                         -- preserve original
    requeue_count   = next_count,                  -- bump
    next_attempt_ms = now + backoff_ms,            -- exponential delay
  })
  self:emit("cascade_requeue", {
    origin        = px.origin,
    payload       = px.user_text,
    ctr           = px.ctr,
    dst           = px.dst,
    ctr_lo        = px.ctr_lo,
    requeue_count = next_count,
    backoff_ms    = backoff_ms,
    total_age_ms  = total_age_ms,
    trigger       = trigger,
  })
  self:log(string.format(
    "cascade_requeue msg=%d dst=%s -> back of queue (#%d, age=%dms, backoff=%dms, trigger=%s)",
    px.ctr_lo, name_of(self, px.dst), next_count, total_age_ms, backoff_ms, trigger))
  return true
end

-- Fires after rts_timeout_ms with no CTS. Decides retry vs giveup vs
-- defer (when busy as receiver of someone else's data).
local function rts_timeout_fire(self, captured_ctr_lo)
  if self.pending_tx == nil then return end
  if self.pending_tx.ctr_lo ~= captured_ctr_lo then return end

  if self.pending_rx ~= nil then
    self:log(string.format("rts_retry_deferred (busy as receiver) msg=%d",
      captured_ctr_lo))
    self:after(self.rts_busy_retry_ms, function()
      rts_timeout_fire(self, captured_ctr_lo)
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
      ctr = self.pending_tx.ctr,
      ctr_lo = captured_ctr_lo, next_hop = self.pending_tx.next,
      delay_ms = val_b, source = "rts_timeout",
    })
    self:log(string.format("tx_blind_defer (rts_timeout) msg=%d -> %s deferred %dms",
      captured_ctr_lo, name_of(self, self.pending_tx.next), val_b))
    self:after(val_b, function()
      rts_timeout_fire(self, captured_ctr_lo)
    end)
    return
  elseif action_b == "alt" then
    self:emit("tx_blind_alt", {
      origin = self.pending_tx.origin, payload = self.pending_tx.user_text,
      ctr = self.pending_tx.ctr,
      ctr_lo = captured_ctr_lo,
      from_next = self.pending_tx.next, to_next = val_b,
    })
    self:log(string.format("tx_blind_alt (rts_timeout) msg=%d %s -> %s",
      captured_ctr_lo, name_of(self, self.pending_tx.next), name_of(self, val_b)))
    self.pending_tx.alts_tried[self.pending_tx.next] = true
    self.pending_tx.next = val_b
    self.pending_tx.retries_left = effective_rts_max_retries(self, self.pending_tx.requeue_count)
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
        ctr = self.pending_tx.ctr,
        dst        = self.pending_tx.dst, ctr_lo = captured_ctr_lo,
        from_next  = prev_next, to_next = next_hop,
        attempt    = set_size(self.pending_tx.alts_tried),
        trigger    = "rts_giveup",
      })
      self:log(string.format("path_cascade msg=%d %s -> %s (rts_giveup)",
        captured_ctr_lo, name_of(self, prev_next), name_of(self, next_hop)))
      self.pending_tx.next         = next_hop
      self.pending_tx.retries_left = effective_rts_max_retries(self, self.pending_tx.requeue_count)
      tx_rts_retry(self, "cascade_rts")
      return
    end
    -- All K candidates exhausted. Phase C: try to push the item back
    -- into tx_queue with exponential backoff first (cascade_requeue) so
    -- other deliverable items can rotate through. Only when
    -- requeue_count or total_age_ms caps are hit do we truly drop and
    -- emit the legacy path_cascade_exhausted + rts_giveup.
    if try_cascade_requeue(self, "rts_giveup") then
      self.pending_tx = nil
      become_free(self)
      return
    end
    local tried_list = {}
    for nh, _ in pairs(self.pending_tx.alts_tried) do
      table.insert(tried_list, nh)
    end
    self:emit("path_cascade_exhausted", {
      origin     = self.pending_tx.origin,
      payload    = self.pending_tx.user_text,
      ctr = self.pending_tx.ctr,
      dst        = self.pending_tx.dst, ctr_lo = captured_ctr_lo,
      tried      = tried_list, trigger = "rts_giveup",
    })
    self:emit("rts_giveup", {
      origin     = self.pending_tx.origin,
      payload    = self.pending_tx.user_text,
      ctr = self.pending_tx.ctr,
      dst        = self.pending_tx.dst,
      next       = self.pending_tx.next,
      ctr_lo     = captured_ctr_lo,
    })
    self:log(string.format("path_cascade_exhausted msg=%d dst=%s tried=%d (rts_giveup)",
      captured_ctr_lo, name_of(self, self.pending_tx.dst), #tried_list))
    maybe_emit_self_over_budget(self, self.pending_tx, "rts_giveup")
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
  local captured = captured_ctr_lo
  local jitter = self:rand(0, self.retry_jitter_ms + 1)
  if jitter == 0 then
    tx_rts_retry(self, "cts_timeout")
  else
    self:after(jitter, function()
      if self.pending_tx ~= nil and self.pending_tx.ctr_lo == captured then
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
local function ack_timeout_fire(self, captured_ctr_lo)
  if self.pending_tx == nil then return end
  if self.pending_tx.ctr_lo ~= captured_ctr_lo then return end

  if self.pending_rx ~= nil then
    -- Mid-RX of someone else's flight; defer briefly.
    self:log(string.format("ack_retry_deferred (busy as receiver) msg=%d",
      captured_ctr_lo))
    self:after(self.rts_busy_retry_ms, function()
      ack_timeout_fire(self, captured_ctr_lo)
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
        ctr = self.pending_tx.ctr,
        dst        = self.pending_tx.dst, ctr_lo = captured_ctr_lo,
        from_next  = prev_next, to_next = next_hop,
        attempt    = set_size(self.pending_tx.alts_tried),
        trigger    = "ack_giveup",
      })
      self:log(string.format("path_cascade msg=%d %s -> %s (ack_giveup)",
        captured_ctr_lo, name_of(self, prev_next), name_of(self, next_hop)))
      self.pending_tx.next         = next_hop
      self.pending_tx.retries_left = effective_rts_max_retries(self, self.pending_tx.requeue_count)
      tx_rts_retry(self, "cascade_ack")
      return
    end
    -- Phase C: cascade_requeue first; only when caps are hit do we
    -- emit the legacy path_cascade_exhausted + data_ack_giveup.
    if try_cascade_requeue(self, "ack_giveup") then
      self.pending_tx = nil
      become_free(self)
      return
    end
    local tried_list = {}
    for nh, _ in pairs(self.pending_tx.alts_tried) do
      table.insert(tried_list, nh)
    end
    self:emit("path_cascade_exhausted", {
      origin     = self.pending_tx.origin,
      payload    = self.pending_tx.user_text,
      ctr = self.pending_tx.ctr,
      dst        = self.pending_tx.dst, ctr_lo = captured_ctr_lo,
      tried      = tried_list, trigger = "ack_giveup",
    })
    self:emit("data_ack_giveup", {
      origin     = self.pending_tx.origin,
      payload    = self.pending_tx.user_text,
      ctr = self.pending_tx.ctr,
      dst        = self.pending_tx.dst,
      next       = self.pending_tx.next,
      ctr_lo     = captured_ctr_lo,
    })
    self:log(string.format("path_cascade_exhausted msg=%d dst=%s tried=%d (ack_giveup)",
      captured_ctr_lo, name_of(self, self.pending_tx.dst), #tried_list))
    maybe_emit_self_over_budget(self, self.pending_tx, "ack_giveup")
    self.pending_tx = nil
    become_free(self)
    return
  end

  self.pending_tx.retries_left = self.pending_tx.retries_left - 1
  -- Same random backoff as cts_timeout — see comment there.
  local captured = captured_ctr_lo
  local jitter = self:rand(0, self.retry_jitter_ms + 1)
  if jitter == 0 then
    tx_rts_retry(self, "ack_timeout")
  else
    self:after(jitter, function()
      if self.pending_tx ~= nil and self.pending_tx.ctr_lo == captured then
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
  -- attempt_idx = how many retries we've already burned on this ctr_lo.
  -- Fresh budget (issue_send / NACK alt / blind alt) → attempt_idx = 0
  -- → base timeout. Each subsequent retry doubles up to RTS_TIMEOUT_BACKOFF_CAP.
  local attempt_idx = self.rts_max_retries - self.pending_tx.retries_left
  local timeout_ms = rts_timeout_for_attempt(self.rts_timeout_ms, attempt_idx)
  local captured_ctr_lo = self.pending_tx.ctr_lo
  self.rts_timeout_handle = self:after(timeout_ms, function()
    self.rts_timeout_handle = nil
    rts_timeout_fire(self, captured_ctr_lo)
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
                              DATA_HDR_LEN + #self.pending_tx.payload + MAC_LEN)
  local delay = data_air + self.ack_air_ms
  local captured_ctr_lo = self.pending_tx.ctr_lo
  self.ack_timeout_handle = self:after(delay, function()
    self.ack_timeout_handle = nil
    ack_timeout_fire(self, captured_ctr_lo)
  end)
end

-- Receiver-side: if DATA never arrives after we sent CTS, clear pending_rx
-- so future flights through us can proceed. Without this, a single lost
-- DATA freezes the receiver permanently.
local function pending_rx_expiry_fire(self, captured_ctr_lo)
  if self.pending_rx == nil then return end
  if self.pending_rx.ctr_lo ~= captured_ctr_lo then return end
  self:emit("data_rx_timeout", {
    -- origin unknown at RTS phase; populated from DATA on arrival
    from = self.pending_rx.from, ctr_lo = captured_ctr_lo,
  })
  self:log(string.format("data_rx_timeout from=%s ctr_lo=%d -> clearing pending_rx",
    name_of(self, self.pending_rx.from), captured_ctr_lo))
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
  -- +2 ms guard so the DATA on_recv wins the sim tie-break if DATA arrives
  -- at exactly the expiry boundary (can happen with exact-integer airtimes).
  local expiry_ms = cts_air + self.cts_to_data_gap_ms + data_air + 2
  self.pending_rx.expiry_ms = expiry_ms   -- stash for NACK busy_for_ms calc
  local captured_ctr_lo = self.pending_rx.ctr_lo
  self.pending_rx_expiry_handle = self:after(expiry_ms, function()
    self.pending_rx_expiry_handle = nil
    pending_rx_expiry_fire(self, captured_ctr_lo)
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
        payload    = d.user_text, ctr = d.ctr,
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
    -- Re-queue head-first so the original order is preserved. Stamp the
    -- new tx_queue fields: preserve the original send-issue time
    -- (queued_at_ms) as enqueue_time_ms — the deferred wait counts toward
    -- the cascade-requeue total wallclock cap so a long-deferred message
    -- doesn't get extra free retries beyond the global e2e budget.
    for i = #drained, 1, -1 do
      local d = drained[i]
      self:emit("send_drained", {
        origin     = d.origin, dst = d.dst_id, dst_name = d.dst_name,
        payload    = d.user_text, ctr = d.ctr,
        waited_ms  = now - d.queued_at_ms,
      })
      self:log(string.format(
        "send_drained dst=%s waited=%dms (route appeared) → tx_queue",
        d.dst_name, now - d.queued_at_ms))
      d.enqueue_time_ms = d.queued_at_ms
      d.requeue_count   = 0
      d.next_attempt_ms = 0
      table.insert(self.tx_queue, 1, d)
    end
    become_free(self)
  end
end

-- payload here is the inner bytes (src_addr_len | src_addr | body) that go into the
-- DATA frame's ciphertext slot. user_text is what the user / visualizer sees in
-- emit data. ctr is the full 16-bit per-(origin,dst) outbound counter (set at
-- on_command for new sends, preserved across forwards). flags carries wire-level
-- DATA_FLAG_* bits. queue_meta is an optional table {enqueue_time_ms, requeue_count}
-- threaded from the tx_queue item through to pending_tx for cascade-requeue
-- accounting; when nil (forwarder direct path) we treat this as a fresh hop.
issue_send = function(self, origin, dst_id, dst_name, payload, user_text, ctr, flags, previous_hop, queue_meta)
  -- Anti-spam self-monitoring: count our own originations (origin ==
  -- self.id; previous_hop == nil means we're not forwarding for someone
  -- else). Used to emit originator_self_over_budget on terminal failure
  -- so the app can surface "you may be over fair-share budget" UX.
  if origin == self.id and previous_hop == nil then
    self_originate_observe(self)
  end
  local entry = self.rt[dst_id]
  if not entry then
    -- Forwarder mid-flight with no route: real failure (route went stale
    -- between when we accepted the DATA and when we tried to forward it).
    -- Drop with the existing send_no_route — the originator's app-layer
    -- end-to-end retry is the recovery path here.
    if previous_hop ~= nil then
      self:emit("send_no_route", {
        origin = origin, payload = user_text, ctr = ctr, dst = dst_id,
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
      payload      = payload, user_text = user_text, ctr = ctr, flags = flags,
      queued_at_ms = self:now(),
    })
    self:emit("send_deferred", {
      origin     = origin, dst = dst_id, dst_name = dst_name,
      payload    = user_text, ctr = ctr,
      ttl_ms     = self.send_defer_ttl_ms,
      depth      = #self.deferred_sends,
    })
    self:log(string.format(
      "send_deferred dst=%s (no route yet; holding for up to %dms; depth=%d)",
      dst_name, self.send_defer_ttl_ms, #self.deferred_sends))
    -- Q escalation: alongside the passive defer, actively request the
    -- route from neighbours via a one-hop Q frame. Whichever brings
    -- the route in faster (passive wait or Q response) wins. Dedup so
    -- repeated sends to the same unknown dst don't spam Q.
    local now_q = self:now()
    local last_q = self.q_queried[dst_id]
    if not last_q or (now_q - last_q) >= self.q_query_ttl_ms then
      self.q_queried[dst_id] = now_q
      self:emit("q_tx", { dst = dst_id, dst_name = dst_name })
      self:log(string.format("q_tx -> dst=%s (route query)", dst_name))
      tx_initiating(self, pack_q(self.leaf_id, self.id, dst_id), {
        sf    = self.routing_sf,
        label = "Q",
        info  = string.format("dst=%s", dst_name),
      })
    end
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
      origin = origin, payload = user_text, ctr = ctr,
      dst = dst_id, next_hop = primary_next, delay_ms = val_b,
      source = "issue_send",
    })
    self:log(string.format("tx_blind_defer (issue_send) -> %s deferred %dms",
      name_of(self, primary_next), val_b))
    table.insert(self.tx_queue, 1, {
      origin = origin, dst_id = dst_id, dst_name = dst_name,
      payload = payload, user_text = user_text, ctr = ctr, flags = flags,
      previous_hop = previous_hop,
      enqueue_time_ms = (queue_meta and queue_meta.enqueue_time_ms) or self:now(),
      requeue_count   = (queue_meta and queue_meta.requeue_count) or 0,
      next_attempt_ms = 0,
    })
    self:after(val_b, function() become_free(self) end)
    return
  elseif action_b == "alt" then
    self:emit("tx_blind_alt", {
      origin = origin, payload = user_text, ctr = ctr,
      dst = dst_id, from_next = primary_next, to_next = val_b,
    })
    self:log(string.format("tx_blind_alt (issue_send) dst=%s %s -> %s",
      dst_name, name_of(self, primary_next), name_of(self, val_b)))
    blind_skipped_primary = primary_next
    primary_next = val_b
  end
  -- hop-level ctr_lo = low nibble of origin-level ctr, so DATA's ctr & 0xf
  -- matches pending_rx.ctr_lo at the receiver without a separate wire field.
  local mid = ctr & 0xf
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
    ctr_lo       = mid,
    payload      = payload,        -- inner bytes (src_addr_len|src_addr|body) for DATA frame
    user_text    = user_text,      -- for emit + log clarity
    ctr          = ctr,            -- full 16-bit per-(origin,dst) counter
    flags        = flags,          -- wire-level DATA_FLAG_* bits
    retries_left = effective_rts_max_retries(self,
      (queue_meta and queue_meta.requeue_count) or 0),
    alts_tried   = initial_alts_tried,
    chosen_data_sf = nil,        -- set when CTS arrives carrying the receiver's pick
    previous_hop = previous_hop, -- upstream node (nil at originator); blocks alt-loops
    -- Cascade-requeue accounting: enqueue_time_ms is the original tx_queue
    -- enqueue time (preserved across requeues); requeue_count is how many
    -- times this same e2e message has bounced through the cascade-requeue
    -- path. queue_meta is supplied by become_free from the popped item;
    -- forwarders calling issue_send directly pass nil → fresh hop.
    enqueue_time_ms = (queue_meta and queue_meta.enqueue_time_ms) or self:now(),
    requeue_count   = (queue_meta and queue_meta.requeue_count) or 0,
  }
  -- payload_len = inner overhead (src_addr_len + src_addr + MAC) + body size.
  -- Body size = #payload - 2 (stripping the 2-byte inner header from inner bytes).
  -- Equivalently: #payload + MAC_LEN (since payload already has 2-byte inner hdr).
  local payload_len = #payload + MAC_LEN
  local rts = pack_rts(self.leaf_id, self.id, dst_id, primary_next, mid,
                       self.allowed_sf_bitmap, payload_len)
  local label = (origin == self.id) and "RTS" or "RTS-fwd"
  self:emit("rts_tx", {
    origin = origin, payload = user_text, ctr = ctr,
    dst = dst_id, next = primary_next, ctr_lo = mid,
    sf_bitmap = self.allowed_sf_bitmap,
  })
  self:log(string.format("rts_tx -> %s ctr_lo=%d origin=%s ctr=%d (sf_bitmap=0x%02x)",
    name_of(self, primary_next), mid, name_of(self, origin), ctr,
    self.allowed_sf_bitmap))
  tx_initiating(self, rts, {
    sf    = self.routing_sf,
    label = label,
    info  = string.format("origin=%s dst=%s next=%s msg=%d ctr=%d sf_bitmap=0x%02x payload=%q",
      name_of(self, origin), dst_name, name_of(self, primary_next),
      mid, ctr, self.allowed_sf_bitmap, user_text),
  }, function() start_rts_timeout(self) end)
  -- RX stays on routing_sf — CTS and NACK both ride on routing_sf now.
end

-- Drain one queued send if we're free. Called at every state-cleanup
-- point: ack_rx, ack_timeout giveup, rts_timeout giveup, on_recv "D"
-- delivered branch, pending_rx_expiry. Forwarders don't drain because
-- forwarding sets pending_tx synchronously in the same handler.
--
-- Pops the highest-priority ready item: among items with
-- next_attempt_ms <= now, prefer LOWEST requeue_count (fresh msgs jump
-- ahead of zombies), tie-break on lowest next_attempt_ms, then on FIFO
-- order (lowest array index). If no item is ready, arms
-- self.queue_wakeup_handle for the earliest pending next_attempt_ms so
-- the queue advances when its delay elapses, then returns without
-- dequeuing. The single wakeup handle is cancelled at the start of any
-- successful pop (it's stale).
--
-- Why requeue_count first: a fresh message has the best chance of
-- delivering quickly (its destination route is probably still valid;
-- the channel hasn't yet been polluted by its retries). A high-retry
-- message has already failed K alts × N retries × multiple cycles —
-- giving it priority over fresh traffic spends channel time on a
-- low-probability outcome. The (effective_rts_max_retries) helper
-- already gives zombies fewer RTS attempts per cycle; this ordering
-- compounds that by giving them lower scheduling priority too.
become_free = function(self)
  if self.pending_tx ~= nil or self.pending_rx ~= nil then return end
  if #self.tx_queue == 0 then return end
  local now = self:now()
  -- Scan: find the ready item with (lowest requeue_count, lowest
  -- next_attempt_ms) (ties broken by FIFO via iteration order). Also
  -- remember the earliest not-yet-ready item so we can arm a wakeup
  -- if nothing is ready.
  local best_idx          = nil
  local best_rcnt         = nil
  local best_next         = nil
  local earliest_unready  = nil
  for i, it in ipairs(self.tx_queue) do
    local nxt = it.next_attempt_ms or 0
    if nxt <= now then
      local rcnt = it.requeue_count or 0
      if best_idx == nil
         or rcnt < best_rcnt
         or (rcnt == best_rcnt and nxt < best_next) then
        best_idx  = i
        best_rcnt = rcnt
        best_next = nxt
      end
    else
      if earliest_unready == nil or nxt < earliest_unready then
        earliest_unready = nxt
      end
    end
  end
  if best_idx == nil then
    -- Nothing ready. Arm a single wakeup at the earliest unready
    -- next_attempt_ms (cancel any prior to avoid stacking).
    if self.queue_wakeup_handle then
      self:cancel(self.queue_wakeup_handle)
      self.queue_wakeup_handle = nil
    end
    if earliest_unready ~= nil then
      local wait_ms = earliest_unready - now
      if wait_ms < 1 then wait_ms = 1 end
      self.queue_wakeup_handle = self:after(wait_ms, function()
        self.queue_wakeup_handle = nil
        become_free(self)
      end)
    end
    return
  end
  -- A ready item exists; cancel any pending wakeup as it's stale.
  if self.queue_wakeup_handle then
    self:cancel(self.queue_wakeup_handle)
    self.queue_wakeup_handle = nil
  end
  local item = table.remove(self.tx_queue, best_idx)
  self:emit("tx_dequeue", {
    origin = item.origin, payload = item.user_text, ctr = item.ctr,
    dst = item.dst_id, depth = #self.tx_queue,
  })
  issue_send(self, item.origin, item.dst_id, item.dst_name,
             item.payload, item.user_text, item.ctr, item.flags or 0, item.previous_hop,
             { enqueue_time_ms = item.enqueue_time_ms,
               requeue_count   = item.requeue_count })
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
  -- Budget-aware skip: when our duty-cycle tier is CRITICAL or EXHAUSTED,
  -- a BCN is luxury — we should preserve every remaining ms of budget
  -- for forwards that have already arrived in our queue. Triggered BCNs
  -- after rt mutations are also gated so the protocol degrades gracefully
  -- as the duty-cycle ceiling approaches. Neighbours don't NEED our BCN
  -- to discover us — passive last_seen refresh from any received frame
  -- (RTS/CTS/ACK we send) keeps us in their tables.
  if compute_budget_tier(self) >= BUDGET_TIER_CRITICAL then
    self:emit("beacon_skipped_budget", {
      tier = compute_budget_tier(self),
      kind = kind,
    })
    self:log(string.format(
      "beacon_tx skipped (budget tier=%d) kind=%s",
      compute_budget_tier(self), kind))
    return false
  end
  local frame, new_offset, diff = pack_beacon(self,
                                              self.beacon_max_entries,
                                              self.beacon_offset)
  local total  = rt_count(self.rt)
  local page_n = frame:byte(4)              -- byte 4 = n (post-leaf_id-header)
  self:emit("beacon_tx", {
    n_entries = page_n, rt_total = total,
    offset = self.beacon_offset, next_offset = new_offset,
    kind = kind,
  })
  -- Differential breakdown: how many of the n_entries were dirty (priority)
  -- vs stable (background rotation), and how many dirty routes overflowed
  -- this beacon (will surface in the next one).
  self:emit("beacon_diff_breakdown", {
    dirty_n     = diff.dirty_n,
    stable_n    = diff.stable_n,
    total_dirty = diff.total_dirty,
    rt_total    = total,
    kind        = kind,
  })
  self:log(string.format(
    "beacon_tx kind=%s page=%d/%d (dirty=%d stable=%d, overflow=%d) offset %d→%d",
    kind, page_n, total, diff.dirty_n, diff.stable_n,
    diff.total_dirty - diff.dirty_n,
    self.beacon_offset, new_offset))
  self.beacon_offset = new_offset
  -- Track when this node last committed a BCN to air. Consulted by the
  -- max-idle override (beacon_fire) to break out of long throttle
  -- windows: in dense channels the quiet_threshold gate suppresses
  -- periodic beacons indefinitely, starving neighbours' routing tables
  -- past the rt_aging_ttl_* TTLs. The override fires a BCN regardless of
  -- channel-busy state once this node has been quiet for too long.
  self.last_beacon_tx_ms = self:now()
  return tx_flood(self, frame, {
    sf    = self.routing_sf,
    label = "BCN",
    info  = string.format("rt=%d/%d off=%d dirty=%d kind=%s",
      page_n, total, self.beacon_offset, diff.dirty_n, kind),
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
    -- Max-idle override: if this node hasn't BCN'd in beacon_max_idle_ms,
    -- the channel-busy throttle would otherwise suppress us indefinitely
    -- in dense meshes (channel never quiets for 30s once 100+ nodes are
    -- active). Override fires anyway — but with a B+C composite filter
    -- to avoid synchronized BCN bursts from 138 nodes hitting max_idle
    -- in lockstep:
    --
    --   (B) defer if a neighbour BCN landed within max_idle/3
    --       — they're carrying the refresh load right now
    --   (C) skip if our RT has zero dirty entries AND the network
    --       is actively beaconing — we'd add nothing new
    --
    -- The combined filter creates a cascade: first nodes (with dirty
    -- entries OR no recent neighbour BCN) fire; their BCNs land at
    -- neighbours which then defer; spread is ~max_idle/3 instead of
    -- the silence-jitter's ~10s. Heartbeat preserved: dirty=0 nodes
    -- whose neighbours have ALSO gone silent will fire (both filter
    -- conditions fail).
    --
    -- See deployment-tuning block in on_init for how to scale these
    -- knobs to hours for real LoRa hardware.
    local force_idle = false
    if self.beacon_max_idle_ms and self.beacon_max_idle_ms > 0 then
      local since_tx = (self.last_beacon_tx_ms ~= nil)
                       and (self:now() - self.last_beacon_tx_ms)
                       or  math.huge
      if since_tx >= self.beacon_max_idle_ms then
        -- Override eligible. Apply B+C filter.
        local since_bcn_rx = (self.last_rx_bcn_ms ~= nil)
                             and (self:now() - self.last_rx_bcn_ms)
                             or  math.huge
        local defer_window_ms = self.beacon_max_idle_ms // 3
        local dirty_n = 0
        for _, entry in pairs(self.rt) do
          if entry.dirty then dirty_n = dirty_n + 1 end
        end
        if dirty_n == 0 and since_bcn_rx < defer_window_ms then
          -- Combined B+C: nothing new to advertise AND a neighbour
          -- recently beaconed → skip. The next periodic timer fire
          -- will re-evaluate (and by then either a neighbour BCN has
          -- aged past defer_window_ms, or we have new dirty entries).
          self:emit("beacon_max_idle_skip_clean", {
            since_tx_ms     = since_tx,
            since_bcn_rx_ms = since_bcn_rx,
            defer_window_ms = defer_window_ms,
            dirty_n         = 0,
          })
          self:log(string.format(
            "beacon_max_idle_skip_clean (silent %dms but neighbour BCN %dms ago, dirty=0)",
            since_tx, since_bcn_rx))
          -- Fall through to normal throttle path; the throttle will
          -- skip too (channel busy) so net effect is no BCN this
          -- cycle. We don't directly return so the existing skip
          -- emit / log still happens for diagnostics consistency.
        else
          force_idle = true
          self:emit("beacon_max_idle_force", {
            since_tx_ms     = since_tx == math.huge and -1 or since_tx,
            max_idle_ms     = self.beacon_max_idle_ms,
            since_rx_ms     = since_rx == math.huge and -1 or since_rx,
            since_bcn_rx_ms = since_bcn_rx == math.huge and -1 or since_bcn_rx,
            dirty_n         = dirty_n,
          })
          self:log(string.format(
            "beacon_max_idle_force (silent for %dms ≥ %dms, dirty=%d, last_bcn_rx=%dms ago)",
            since_tx == math.huge and -1 or since_tx,
            self.beacon_max_idle_ms,
            dirty_n,
            since_bcn_rx == math.huge and -1 or since_bcn_rx))
        end
      end
    end
    if since_rx < self.quiet_threshold_ms and not force_idle then
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
          -- Same B+C filter on the post-jitter re-check: a neighbour
          -- BCN may have landed during our jitter window — if it did
          -- AND we have nothing new to advertise, defer. force_idle
          -- was true at pre-jitter time, but recompute since_tx /
          -- since_bcn_rx here against the (possibly updated) clock.
          local force_idle_post = false
          if self.beacon_max_idle_ms and self.beacon_max_idle_ms > 0 then
            local since_tx = (self.last_beacon_tx_ms ~= nil)
                             and (self:now() - self.last_beacon_tx_ms)
                             or  math.huge
            if since_tx >= self.beacon_max_idle_ms then
              local since_bcn_rx = (self.last_rx_bcn_ms ~= nil)
                                   and (self:now() - self.last_rx_bcn_ms)
                                   or  math.huge
              local defer_window_ms = self.beacon_max_idle_ms // 3
              local dirty_n = 0
              for _, entry in pairs(self.rt) do
                if entry.dirty then dirty_n = dirty_n + 1 end
              end
              -- B+C composite: skip the override only if BOTH (network
              -- is beaconing) AND (we have nothing new). Otherwise force.
              if not (dirty_n == 0 and since_bcn_rx < defer_window_ms) then
                force_idle_post = true
              end
            end
          end
          if since < self.quiet_threshold_ms and not force_idle_post then
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
  -- Node-level identity flags (BCN byte 1 bits 3:1).
  -- Defaults false; no current scenario sets these config keys.
  -- has_schedule: reserved until §7.3 inter-layer TDM lands.
  -- self_gateway: true if this node bridges to internet/backbone.
  -- is_mobile:    true if this node is mobile (relaxes route aging etc.).
  self.has_schedule = false
  self.self_gateway = (config.is_gateway == true)
  self.is_mobile    = (config.is_mobile  == true)

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

  -- Max-idle override: bypass the quiet_threshold gate if this node
  -- hasn't BCN'd in beacon_max_idle_ms. In dense meshes the channel
  -- never goes quiet for the throttle's threshold, so periodic beacons
  -- are suppressed indefinitely — neighbours' RT entries age out at
  -- the rt_aging_ttl_* TTLs and the network collapses around the
  -- TTL boundary. Default 480000 ms (8 min) sits well below the
  -- rt_aging_ttl_neighbor_ms default (30 min) so 1-hop entries get
  -- refreshed before they age out, and 1/3 of rt_aging_ttl_remote_ms
  -- (90 min) so multi-hop rotation cycles complete in time. Set to 0
  -- to disable. See on_init's aging block for the deployment-scaling
  -- formula.
  --
  -- last_beacon_tx_ms is `nil` until the first BCN; the override treats
  -- nil as "never beaconed → fire freely" (matches the throttle's
  -- nil-last_rx semantics so cold-start behaviour is preserved).
  self.beacon_max_idle_ms        = config.beacon_max_idle_ms        or 480000
  self.last_beacon_tx_ms         = nil
  -- Time of the most recent BCN reception from any neighbour (separate
  -- from last_rx_routing_sf_ms, which is set on every routing-plane RX
  -- including RTS/CTS/ACK). The override path defers when a neighbour
  -- BCN was heard within beacon_max_idle_ms / 3 — this turns the
  -- previously-synchronized override burst (138 nodes all hitting
  -- max_idle in a 10s silence-jitter window) into a cascade: first
  -- nodes fire, their BCNs land at neighbours, neighbours see fresh
  -- last_rx_bcn_ms and defer. Spread becomes ~max_idle/3 instead of
  -- ~10s, making BCN airtime per-window manageable.
  self.last_rx_bcn_ms            = nil

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
  -- Default 151 bytes = 4-byte header + 49 × 3-byte entries. Pre-bit-pack
  -- the default was 200 bytes (49 × 4-byte entries). Keeping the 49-entry
  -- count parity AND realising the per-entry shrink (4→3 B) means each
  -- beacon is now ~24.5% smaller airtime. Scenarios that want more
  -- entries per page can bump beacon_max_bytes (e.g., 200 → 65 entries).
  self.beacon_max_bytes   = config.beacon_max_bytes   or 151
  -- Header is 4 bytes ('B' + leaf_id_byte + src + n); entries 3 bytes each.
  self.beacon_max_entries = math.max(1,
    math.floor((self.beacon_max_bytes - 4) / 3))
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
  -- Budget-tier thresholds. compute_budget_tier(self) returns one of
  -- BUDGET_TIER_HEALTHY (0), STRAINED (1), CRITICAL (2), EXHAUSTED (3)
  -- based on (airtime_used / budget). The protocol uses the tier in
  -- three places:
  --   • compute_budget_tier called at RTS-RX → if >= CRITICAL emit a
  --     budget-reason NACK back to sender instead of CTS — sender
  --     learns the saturated state from the unicast reply rather than
  --     waiting for a BCN advertisement that costs more airtime.
  --   • compute_budget_tier called at our own beacon_fire → skip the
  --     emit when >= CRITICAL (preserve remaining budget for forwards
  --     that already arrived in our queue).
  --   • sender-side: on receiving a budget-NACK, mark the responder
  --     blind for a tier-proportional window, naturally rerouting via
  --     the existing classify_blind machinery.
  self.budget_strained_pct  = config.budget_strained_pct  or 50    -- ≤50% used = HEALTHY ; >50% = STRAINED
  self.budget_critical_pct  = config.budget_critical_pct  or 80    -- >80% used = CRITICAL
  self.budget_exhausted_pct = config.budget_exhausted_pct or 95    -- >95% used = EXHAUSTED
  -- Sender-side: when we receive a budget NACK, mark the peer blind
  -- for this duration (per tier). After it expires we'll try again;
  -- if the peer is still saturated it'll NACK us again.
  self.budget_blind_strained_ms  = config.budget_blind_strained_ms  or  60000   -- 1 min
  self.budget_blind_critical_ms  = config.budget_blind_critical_ms  or 180000   -- 3 min
  self.budget_blind_exhausted_ms = config.budget_blind_exhausted_ms or 300000   -- 5 min
  -- Anti-spam — per-sender RTS/CTS counts over sliding window for the
  -- 1st-hop statistical classifier. See header doc block "Anti-spam:
  -- 1st-hop statistical rate-limit". Tracked here, enforced (silent
  -- drop) inside the RTS handler. Thresholds tuned for chat-app
  -- traffic (~10 msg/hr) being comfortably under, and 200 msg/hr
  -- spam being caught immediately.
  self.per_sender_originator        = {}
  self.own_origination_events       = {}
  self.originator_window_ms         = config.originator_window_ms         or 300000   -- 5 min
  self.originator_max_per_window    = config.originator_max_per_window    or 6        -- ≈ 72/hr
  self.originator_airtime_share     = config.originator_airtime_share     or 0.25     -- backstop
  self.originator_self_warn_fraction = config.originator_self_warn_fraction or 0.5    -- emit self-warning at half threshold
  self.originator_retry_dedup_ms    = config.originator_retry_dedup_ms    or 10000    -- 10s — longer than typical RTS-rty cycle so retries dedup; <<window so ctr_lo wrap counts as fresh

  -- Proactive tier-aware routing: route_strictly_better applies
  -- TIER_SCORE_PENALTY_DB on top of raw SNR margin so candidates via
  -- saturated neighbours get demoted from primary at rt_merge time —
  -- not just temporarily skipped by classify_blind. Set on budget NACK
  -- reception; expires after neighbor_budget_tier_ttl_ms so a peer
  -- that recovers without us hearing it eventually returns to the
  -- primary pool.
  self.neighbor_budget_tier         = {}
  self.neighbor_budget_tier_set_at  = {}
  self.neighbor_budget_tier_ttl_ms  = config.neighbor_budget_tier_ttl_ms or 300000   -- 5 min
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
  -- rts_max_retries: 3 retries × K=3 alts caps a stuck send at ~3-4 retry
  -- intervals × ~5 s = ~15-20 s per next-hop and ~45-60 s total wallclock.
  -- Previously 8 (×3 alts = 24 retries) which could exceed 2 minutes
  -- wallclock — too slow to free pending_tx when a next-hop is genuinely
  -- stuck in an ACK-loss loop.
  self.rts_timeout_ms = config.rts_timeout_ms or
    (airtime_ms(self.routing_sf, self.bw_hz, self.cr, self.preamble_sym, RTS_LEN)
     + airtime_ms(self.routing_sf, self.bw_hz, self.cr, self.preamble_sym, CTS_LEN))
  self.rts_busy_retry_ms  = config.rts_busy_retry_ms  or 30
  self.rts_max_retries    = config.rts_max_retries    or 3
  -- Cascade-requeue knobs (Phase C): when pending_tx exhausts all K alts
  -- (true path_cascade_exhausted), instead of dropping immediately we push
  -- the item back into tx_queue with exponential backoff so other
  -- deliverable items behind it in the queue can rotate through. Hard
  -- caps on requeue_count and total_age_ms prevent stuck messages from
  -- clogging the queue forever.
  --   cascade_requeue_max            — max times an item can be requeued
  --                                     after cascade exhaustion (default 3
  --                                     = 4 total attempts: original + 3).
  --   cascade_requeue_base_ms        — first requeue backoff (default 5s).
  --   cascade_requeue_backoff_cap_ms — exponential cap (default 30s).
  --   cascade_requeue_total_max_ms   — hard wallclock cap on per-message
  --                                     age (default 120s; matches the
  --                                     longest acceptable e2e latency).
  --   cascade_requeue_load_threshold — adaptive back-pressure (default 2).
  --                                     Effective max scales down as local
  --                                     tx_queue depth exceeds this value:
  --                                     each item beyond threshold drops
  --                                     the effective requeue budget by 1.
  --                                     Lets stressed nodes shed retry
  --                                     load instead of choking the
  --                                     channel — the network "feels" its
  --                                     own backpressure. See section (14)
  --                                     of tools/analyze.py for the
  --                                     cascade-waste detector this knob
  --                                     was added to mitigate.
  self.cascade_requeue_max            = config.cascade_requeue_max            or 3
  self.cascade_requeue_base_ms        = config.cascade_requeue_base_ms        or 5000
  self.cascade_requeue_backoff_cap_ms = config.cascade_requeue_backoff_cap_ms or 30000
  -- Wallclock cap. Successful deliveries on s04 take median 10 s, p95
  -- 54 s, max 163 s — so a 60 s cap keeps most legitimate slow paths
  -- alive while killing failed cascades that would otherwise dwell for
  -- 3-13 min. Together with the load_threshold adaptation below this
  -- forms a two-axis cap (per-message wallclock + node-local pressure)
  -- on cascade-requeue dwell time.
  self.cascade_requeue_total_max_ms   = config.cascade_requeue_total_max_ms   or 60000
  self.cascade_requeue_load_threshold = config.cascade_requeue_load_threshold or 0
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
               DATA_HDR_LEN + self.max_payload_bytes + DATA_INNER_OVERHEAD)

  self.rt              = {}
  self.next_ctr_lo     = 1
  self.pending_tx      = nil
  self.pending_rx      = nil
  self.rt_full_emitted = false
  self.tx_stash         = {}    -- label → {bytes, opts, retries_left} for on_radio_busy
  self.blind_until      = {}    -- {node_id → absolute_ms} for F1 mitigation
  self.rts_timeout_handle      = nil  -- so on_recv "C" can cancel
  self.ack_timeout_handle      = nil  -- so on_recv "K" can cancel
  self.pending_rx_expiry_handle = nil  -- so on_recv "D" can cancel
  self.tx_queue          = {}   -- queued user sends, drained at every "free" point
  self.queue_wakeup_handle = nil  -- single self:after handle armed by become_free
                                  -- when nothing is ready; cancelled on successful pop
  -- Originator-only defer queue. When the user issues a send to a
  -- destination not yet in rt[], we hold the send for up to
  -- send_defer_ttl_ms instead of dropping it on the floor. Any rt_update
  -- (or the periodic 1s drain) walks this list; entries whose dst is
  -- now reachable get pushed back to tx_queue + emit send_drained;
  -- entries past TTL emit send_giveup. Forwarders never defer (they're
  -- mid-flight; lost-route mid-flight is a real failure).
  self.deferred_sends     = {}    -- array of {origin, dst_id, dst_name, payload, user_text, ctr, flags, queued_at_ms}
  self.send_defer_ttl_ms  = config.send_defer_ttl_ms or 30000
  -- Hop-level RTS-retry dedup. {sender_id → {ctr_lo, t_ms}}; lookups
  -- treat entries older than self.last_acked_ttl_ms as missing so the
  -- 4-bit ctr_lo wrap (every 16 sends per sender) doesn't false-pos
  -- at slow send rates. TTL well above any flight-retry window
  -- (rts_max_retries × rts_timeout ≈ 1.5 s) and well below the wrap
  -- interval at any plausible per-sender send rate.
  self.last_acked_from    = {}
  self.last_acked_ttl_ms  = config.last_acked_ttl_ms or 10000
  -- 4-bit network identifier — externally managed (admin sets per node).
  -- Receivers reject foreign-network BCN/RTS at the routing layer
  -- before doing CTS/DATA work. 0 = default mesh; 1..15 = distinct meshes.
  self.leaf_id        = config.leaf_id or 0
  -- Stale-route aging — two-tier TTL by hop class.
  --
  -- Per-candidate last_seen_ms is refreshed by rt_merge whenever a
  -- beacon advertises that exact (dest, next_hop) combination, AND
  -- for direct-neighbour entries on every on_recv frame from that
  -- neighbour. Direct-neighbour entries (c.hops == 1) refresh on
  -- every received frame from that node — so they can carry a shorter
  -- TTL without false-eviction risk. Multi-hop entries (c.hops >= 2)
  -- only refresh when their advertiser's rotation slot comes up; they
  -- need a TTL multiple of the full-rotation cycle to survive.
  --
  -- The aging loop runs every rt_aging_check_period_ms (default 60 s).
  --
  -- ┌─────────────────────────────────────────────────────────────────┐
  -- │ DEPLOYMENT TUNING (real LoRa hardware, mostly-static nodes):    │
  -- │                                                                 │
  -- │ Both refresh and aging should scale to HOURS for real           │
  -- │ deployments. The simulation defaults below are tuned for a      │
  -- │ 30-minute s04 stress run, not for production.                   │
  -- │                                                                 │
  -- │ Formula:                                                        │
  -- │   per_entry_refresh_max_ms                                      │
  -- │     = ceil(RT_size / beacon_max_entries) × beacon_max_idle_ms   │
  -- │                                                                 │
  -- │   rt_aging_ttl_neighbor_ms                                      │
  -- │     = M × beacon_max_idle_ms       (M = 2..3, loss tolerance)   │
  -- │                                                                 │
  -- │   rt_aging_ttl_remote_ms                                        │
  -- │     = N × per_entry_refresh_max_ms (N = 4..8, loss tolerance)   │
  -- │                                                                 │
  -- │ Worked example — 50-node mostly-static deployment:              │
  -- │   beacon_max_idle_ms        = 30 min  (low ambient airtime)     │
  -- │   beacon_period_ms          = 30 min  (matches max_idle)        │
  -- │   RT_size = 50, beacon_max_entries ≈ 50 → 1 rotation page       │
  -- │   per_entry_refresh_max_ms  = 1 × 30 = 30 min                   │
  -- │   rt_aging_ttl_neighbor_ms  = 2 × 30 = 60 min                   │
  -- │   rt_aging_ttl_remote_ms    = 4 × 30 = 120 min  (2 hours)       │
  -- │                                                                 │
  -- │ Caveat for very large RTs: per_entry_refresh grows linearly     │
  -- │ with RT_size, so at scale you should either (a) cap RT to       │
  -- │ "important" destinations, (b) shrink per-entry encoding to      │
  -- │ fit more in one beacon, or (c) switch distant destinations to   │
  -- │ reactive (Q-frame) lookup instead of proactive flooding.        │
  -- └─────────────────────────────────────────────────────────────────┘
  --
  -- Simulation defaults (tuned for s04, not production):
  --   beacon_max_idle_ms = 8 min  (set in beacon-throttle block above)
  --   RT_size ≈ 140 (s04), beacon_max_entries ≈ 50 → 3 rotation pages
  --   per_entry_refresh_max_ms = 3 × 8 = 24 min
  --   rt_aging_ttl_neighbor_ms = 2 × 8 = 16 min  →  rounded to 30 min
  --                                                  (jitter headroom)
  --   rt_aging_ttl_remote_ms   = 4 × 24 = 96 min →  rounded to 90 min
  --                                                  (covers 3.75 cycles
  --                                                   ≈ 2-3 missed cycles)
  self.rt_aging_ttl_neighbor_ms = config.rt_aging_ttl_neighbor_ms or 1800000   -- 30 min
  self.rt_aging_ttl_remote_ms   = config.rt_aging_ttl_remote_ms   or 5400000   -- 90 min
  self.rt_aging_check_period_ms = config.rt_aging_check_period_ms or 60000     -- 1 min
  -- Q (RREQ-route) dedup tracking. Sender side: don't re-fire Q for
  -- same dest within q_query_ttl_ms (default 5s). Responder side: don't
  -- respond to same (src,dest) Q within q_respond_ttl_ms (default 10s).
  -- Both prevent Q-storm amplification on lossy links / large meshes.
  self.q_queried       = {}                                  -- {dest_id → t_ms_last_queried}
  self.q_responded_to  = {}                                  -- {(src,dest)_str → t_ms_last_responded}
  self.q_query_ttl_ms   = config.q_query_ttl_ms   or 5000
  self.q_respond_ttl_ms = config.q_respond_ttl_ms or 10000
  -- Diagnostic-only: periodic node_state_snapshot emit cadence.
  -- Captures blind_until count, tx_queue depth, deferred_sends count,
  -- rt size — anything that could grow unboundedly under stress, so
  -- analysers can spot late-window failure modes without replaying
  -- every observation event. Default 60 s. Set 0 to disable.
  self.state_snapshot_period_ms = config.state_snapshot_period_ms or 60000
  self.beacon_offset     = 0    -- sliding page offset for bounded beacons
  -- Origin-level dedup. Every node that receives DATA records the
  -- (origin_id, ctr) pair and rejects subsequent arrivals of the same id
  -- (after still ACKing the previous hop, so it clears its pending_tx).
  -- This catches routing loops + legitimate same-payload retransmissions
  -- in real firmware. TTL is generous (30s default) because a flight at
  -- SF10 can take a few seconds with retries.
  self.seen_origins       = {}
  self.seen_origin_ttl_ms = config.seen_origin_ttl_ms or 30000
  -- Per-(self → peer) outbound 16-bit counter. Replaces the old flat next_origin_seq.
  -- RAM-only this phase; NV persistence deferred to §8 crypto. Keyed by peer_id.
  self.peer_send_counter  = {}   -- [peer_id] → last sent ctr value (0 = never sent)
  -- End-to-end ACK state. Originator-side per-message pending map keyed
  -- by ctr (the outbound counter for this (self,dst) pair). Set on send_e2e;
  -- cleared when matching E2E ACK arrives (emit delivered_confirmed); pruned
  -- on TTL expiry (emit e2e_ack_timeout).
  self.pending_e2e        = {}
  self.e2e_ack_ttl_ms     = config.e2e_ack_ttl_ms or 60000   -- 1 min default

  -- next_ctr: per-(self, peer) outbound counter, wraps at 65535→1.
  -- NV persistence deferred; RAM-only until §8 crypto lands.
  function self:next_ctr(peer_id)
    local c = (self.peer_send_counter[peer_id] or 0) + 1
    if c > 65535 then c = 1 end
    self.peer_send_counter[peer_id] = c
    return c
  end

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
  -- TTL-pruning + retry loop independent of the radio. Also prunes
  -- pending_e2e entries that aged past e2e_ack_ttl_ms (emits
  -- e2e_ack_timeout).
  local function drain_loop()
    try_drain_deferred(self)
    local now = self:now()
    for ctr, info in pairs(self.pending_e2e) do
      if now - info.sent_at_ms >= self.e2e_ack_ttl_ms then
        self:emit("e2e_ack_timeout", {
          origin     = self.id,
          ctr        = ctr,
          dst        = info.dst_id,
          payload    = info.user_text,
          ttl_ms     = self.e2e_ack_ttl_ms,
          elapsed_ms = now - info.sent_at_ms,
        })
        self:log(string.format(
          "e2e_ack_timeout ctr=%d dst=%s elapsed=%dms (no E2E ACK in %dms)",
          ctr, info.dst_name, now - info.sent_at_ms, self.e2e_ack_ttl_ms))
        self.pending_e2e[ctr] = nil
      end
    end
    self:after(1000, drain_loop)
  end
  self:after(1000, drain_loop)

  -- Periodic stale-route aging — every rt_aging_check_period_ms,
  -- evict candidates whose last_seen_ms exceeded the hop-class TTL
  -- (rt_aging_ttl_neighbor_ms for 1-hop, rt_aging_ttl_remote_ms for
  -- multi-hop). See age_out_stale_routes for the full mechanism.
  local function aging_loop()
    age_out_stale_routes(self)
    self:after(self.rt_aging_check_period_ms, aging_loop)
  end
  self:after(self.rt_aging_check_period_ms, aging_loop)

  -- Periodic node-state snapshot — diagnostic-only, every
  -- state_snapshot_period_ms (default 60 s, set 0 to disable).
  -- Emits a single event per node per period with the size of every
  -- per-node accumulator that could grow unboundedly under stress
  -- (blind_until, tx_queue, deferred_sends, rt). Lets analyzers spot
  -- monotonically-growing state without per-event reconstruction.
  if self.state_snapshot_period_ms > 0 then
    local function snapshot_loop()
      local now = self:now()
      -- Count currently-active blind_until entries (until_ms > now).
      -- Expired entries are pruned on lookup but may linger in the
      -- table between is_blind() calls; count only active ones.
      local blind_n = 0
      for _, until_ms in pairs(self.blind_until) do
        if until_ms > now then blind_n = blind_n + 1 end
      end
      local rt_n = 0
      local rt_cands = 0
      for _, entry in pairs(self.rt) do
        rt_n = rt_n + 1
        if entry.candidates then rt_cands = rt_cands + #entry.candidates end
      end
      -- Current duty-cycle position: included so analyze.py §21 can
      -- compute tier residence time via sample-and-hold across snapshots.
      -- pct_used is the same fraction compute_budget_tier checks against
      -- budget_strained_pct / budget_critical_pct / budget_exhausted_pct;
      -- carrying both is cheap and avoids having to reconstruct one from
      -- the other in the analyzer when thresholds change.
      local pct_used = 0
      if self.duty_cycle_budget_ms and self.duty_cycle_budget_ms > 0 then
        local used = self:airtime_used_ms(self.duty_cycle_window_ms)
        pct_used = 100.0 * used / self.duty_cycle_budget_ms
      end
      self:emit("node_state_snapshot", {
        blind_count         = blind_n,
        queue_depth         = #self.tx_queue,
        deferred_count      = #self.deferred_sends,
        has_pending_tx      = self.pending_tx ~= nil,
        has_pending_rx      = self.pending_rx ~= nil,
        rt_dst_count        = rt_n,
        rt_total_candidates = rt_cands,
        budget_tier         = compute_budget_tier(self),
        pct_used            = pct_used,
      })
      self:after(self.state_snapshot_period_ms, snapshot_loop)
    end
    self:after(self.state_snapshot_period_ms, snapshot_loop)
  end
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
  -- Per-RX direct-neighbour liveness refresh for stale-route aging:
  -- any frame from meta.src counts as proof they're alive. Without this,
  -- direct neighbours whose periodic beacons are throttle-suppressed
  -- (heavy-traffic scenarios) would age out incorrectly even though
  -- they're still actively sending RTS/CTS/DATA/ACK. Multi-hop entries
  -- still refresh only on beacon advertisements (the multi-hop info
  -- IS stale if not re-advertised, regardless of intermediate-node
  -- traffic).
  if meta.src ~= nil and self.rt[meta.src] ~= nil then
    for _, c in ipairs(self.rt[meta.src].candidates) do
      if c.next_hop == meta.src and c.hops == 1 then
        c.last_seen_ms = self:now()
        break
      end
    end
  end
  local tag = frame:sub(1, 1)

  if tag == "B" then
    local b = parse_beacon(frame)
    if not b then return end
    -- Cross-network filter — drop foreign-network beacons before they
    -- pollute our routing table. Same field as RTS, same admin-managed
    -- 4-bit space. Silent drop (no event spam — expected during
    -- enhanced propagation events).
    if b.leaf_id ~= self.leaf_id then return end
    self:emit("beacon_rx", { src = b.src, n_entries = #b.entries })

    local now = self:now()
    -- Track time of last BCN-RX (separate from last_rx_routing_sf_ms,
    -- which catches every routing-plane RX including RTS/CTS/ACK).
    -- The max-idle override consults this specifically — when a
    -- neighbour just beaconed, our routing-info refresh need is
    -- already covered, so we defer our own override even if the
    -- generic channel-busy throttle would fire it. See beacon_fire.
    self.last_rx_bcn_ms = now

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
      local action = rt_merge(self, self.rt, b.src, cand, self.routing_snr_floor_db)
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
            next_hop   = b.src,
            n2_hop     = e.next,   -- N's claimed next-hop for e.dest; used by rt_prune_cycle
            score      = combined_score,
            hops       = combined_hops,
            is_gateway = (e.is_gateway == true),
            last_seen_ms = now,
          }
          local action = rt_merge(self, self.rt, e.dest, cand, self.routing_snr_floor_db)
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
    -- Anti-spam observation FIRST: track this RTS in r.src's sliding
    -- window even when the RTS isn't addressed to us (we're overhearing
    -- broadcasts on routing_sf). All 1st-hop neighbours of an originator
    -- accumulate independent evidence this way, so the spammer can't
    -- evade by picking next-hops who don't observe enough.
    track_originator_observation(self, meta.src, "rts", r.ctr_lo,
      airtime_ms(self.routing_sf, self.bw_hz, self.cr,
                 self.preamble_sym, #frame))
    if r.next ~= self.id then return end  -- not for us; silent discard
    -- Cross-network filter — drop foreign-network RTSes before any CTS
    -- work. Without this, two networks merging during enhanced RF
    -- propagation would waste airtime on duplicate CTSes and pollute
    -- routing decisions.
    if r.leaf_id ~= self.leaf_id then return end

    -- Sender is retrying an RTS for a DATA we already received and acked
    -- (their previous ACK was lost in flight). Re-send the ACK directly
    -- — no CTS, no DATA — so they can clear pending_tx without us
    -- reprocessing/duplicating the message. last_acked_from holds the
    -- most recent acked ctr_lo per sender, scoped by TTL so the 4-bit
    -- ctr_lo wrap (every 16 sends per sender) doesn't false-positive at
    -- slow send rates.
    local cached = self.last_acked_from[r.src]
    if cached and cached.ctr_lo == r.ctr_lo
       and (self:now() - cached.t_ms) < self.last_acked_ttl_ms then
      self:emit("rts_already_acked", {
        from = r.src, ctr_lo = r.ctr_lo,
      })
      self:log(string.format("rts_already_acked <- %s ctr_lo=%d -> re-sending ACK",
        name_of(self, r.src), r.ctr_lo))
      -- Piggyback the current RTS's SNR — this isn't the original DATA's
      -- SNR (we don't have it any more), but it's a valid fresh sample of
      -- the same link, so the sender's outbound EWMA still benefits.
      local ack = pack_ack(r.ctr_lo, meta.snr)
      tx_with_retry(self, ack, {
        sf    = self.routing_sf,
        label = "K-dup",
        info  = string.format("re-ACK to=%s msg=%d", name_of(self, r.src), r.ctr_lo),
      })
      return
    end

    if self.pending_rx ~= nil then
      -- Duplicate RTS from the same originator for the same ctr_lo: their
      -- previous CTS may have been lost, or DATA was sent and ACK was
      -- lost (and our pending_rx hasn't expired yet). Re-send the CTS so
      -- they can re-attempt DATA.
      if self.pending_rx.from == r.src and self.pending_rx.ctr_lo == r.ctr_lo then
        self:emit("rts_rx_dup", {
          from = r.src, ctr_lo = r.ctr_lo,
        })
        self:log(string.format("rts_rx_dup <- %s ctr_lo=%d -> resending CTS (sf=%d)",
          name_of(self, r.src), r.ctr_lo, self.pending_rx.chosen_data_sf))
        local cts = pack_cts(r.ctr_lo, self.pending_rx.chosen_data_sf)
        self:emit("cts_tx", {
          to = r.src, ctr_lo = r.ctr_lo, dup = true,
          chosen_data_sf = self.pending_rx.chosen_data_sf,
        })
        tx_with_retry(self, cts, {
          sf    = self.routing_sf,
          label = "CTS-dup",
          info  = string.format("re-CTS to=%s msg=%d sf=%d",
            name_of(self, r.src), r.ctr_lo, self.pending_rx.chosen_data_sf),
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
      local busy_payload = math.floor((busy_for + NACK_BUSY_QUANTUM_MS - 1) / NACK_BUSY_QUANTUM_MS)
      if busy_payload > 255 then busy_payload = 255 end
      local nack = pack_nack(r.ctr_lo, NACK_REASON_BUSY_RX, busy_payload)
      self:emit("nack_tx", {
        to = r.src, ctr_lo = r.ctr_lo, busy_for_ms = busy_for, reason = "pending_rx",
      })
      self:log(string.format("nack_tx -> %s ctr_lo=%d busy_for=%dms (busy with pending_rx from %s/%d)",
        name_of(self, r.src), r.ctr_lo, busy_for,
        name_of(self, self.pending_rx.from), self.pending_rx.ctr_lo))
      tx_initiating(self, nack, {
        sf    = self.routing_sf,
        label = "NACK",
        info  = string.format("to=%s msg=%d busy_for=%dms reason=pending_rx",
          name_of(self, r.src), r.ctr_lo, busy_for),
      })
      return
    end

    if self.pending_tx ~= nil then
      -- We're mid-flight ourselves. Used to NACK back with a busy_for_ms
      -- estimate, but the estimate was a lie in the failure case (a node
      -- stuck in an ACK-loss retry loop predicts ~5 s but is actually
      -- busy for 60+ s). The NACK chain cost up to 28 s of airtime per
      -- stuck node on s03_seattle_medium. Silent drop is cheaper: the
      -- sender's rts_timeout fires after ~5 s and the existing
      -- tx_blind_alt / cascade machinery walks to the next-hop.
      self:emit("rts_drop_pending_tx", {
        from = r.src, ctr_lo = r.ctr_lo,
        our_pending_ctr_lo = self.pending_tx.ctr_lo,
      })
      return
    end

    -- Anti-spam 1st-hop check: if this sender's apparent-origination
    -- rate (R-C over the sliding window) is over threshold, silently
    -- drop the RTS — no CTS, no NACK. The sender experiences
    -- rts_timeout, the cascade tries other next-hops, all 1st-hop
    -- neighbours converge on the same rate-limit, and the spammer is
    -- effectively capped at ~72 originations/hr regardless of how
    -- many next-hops they try. Emit rts_drop_originator_throttle so
    -- the analyzer can measure activity without the protocol paying
    -- airtime. See header doc block "Anti-spam: 1st-hop statistical
    -- rate-limit" for the full argument.
    do
      local app_orig, total_air, rts_n, cts_n =
        compute_originator_metric(self, meta.src)
      local airtime_cap_ms = math.floor(
        self.originator_airtime_share * (self.duty_cycle_budget_ms or 36000))
      if app_orig > self.originator_max_per_window
         or total_air > airtime_cap_ms then
        self:emit("rts_drop_originator_throttle", {
          from = meta.src, ctr_lo = r.ctr_lo,
          apparent_origination = app_orig,
          airtime_ms           = total_air,
          rts_count            = rts_n,
          cts_count            = cts_n,
          threshold_count      = self.originator_max_per_window,
          threshold_airtime_ms = airtime_cap_ms,
          window_ms            = self.originator_window_ms,
        })
        self:log(string.format(
          "rts_drop_originator_throttle <- %s ctr_lo=%d (R-C=%d/%d over %dms, air=%dms/%dms)",
          name_of(self, meta.src), r.ctr_lo,
          app_orig, self.originator_max_per_window,
          self.originator_window_ms, total_air, airtime_cap_ms))
        return  -- silent drop; no CTS, no NACK
      end
    end

    -- Budget-aware NACK: if our duty-cycle budget is tier CRITICAL or
    -- EXHAUSTED, we likely can't carry this flight to completion (CTS
    -- + DATA-RX has no cost but ACK does, and we'd consume more budget
    -- on subsequent forwards if we accept). Reply with a budget NACK
    -- so the sender immediately reroutes via the existing classify_blind
    -- machinery instead of doing a full RTS-CTS-DATA-ACK cycle that
    -- stalls when we get duty_cycle_blocked partway through.
    --
    -- We still pay the NACK airtime (a few ms at SF8) but save the
    -- much larger CTS+ACK round-trip. Net positive when the alternative
    -- is a stalled flight that the sender must rts_timeout out of.
    local my_tier = compute_budget_tier(self)
    if my_tier >= BUDGET_TIER_CRITICAL then
      local nack = pack_nack(r.ctr_lo, NACK_REASON_BUDGET, ((my_tier & 0xf) << 4) | 0)
      self:emit("nack_tx", {
        to = r.src, ctr_lo = r.ctr_lo,
        reason = "budget_low", tier = my_tier,
      })
      self:log(string.format(
        "nack_tx -> %s ctr_lo=%d reason=budget_low tier=%d",
        name_of(self, r.src), r.ctr_lo, my_tier))
      tx_initiating(self, nack, {
        sf    = self.routing_sf,
        label = "NACK",
        info  = string.format("to=%s msg=%d reason=budget tier=%d",
          name_of(self, r.src), r.ctr_lo, my_tier),
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
        from = r.src, ctr_lo = r.ctr_lo,
        sf_bitmap = r.sf_bitmap,
      })
      self:log(string.format("rts_drop_no_sf <- %s ctr_lo=%d (empty sf_bitmap)",
        name_of(self, r.src), r.ctr_lo))
      return
    end

    self:emit("rts_rx", {
      from = r.src, dst = r.dst, ctr_lo = r.ctr_lo,
      sf_bitmap = r.sf_bitmap, chosen_data_sf = chosen_sf,
      rx_snr = meta.snr, ewma_snr = snr_for_sf,
    })
    self:log(string.format(
      "rts_rx <- %s (dst=%s ctr_lo=%d sf_bitmap=0x%02x snr=%.1fdB) -> chose SF%d",
      name_of(self, r.src), name_of(self, r.dst),
      r.ctr_lo, r.sf_bitmap, meta.snr, chosen_sf))
    self.pending_rx = {
      from        = r.src,
      dst         = r.dst,
      ctr_lo      = r.ctr_lo,
      set_at_ms   = self:now(),       -- for NACK busy_for_ms calc
      chosen_data_sf = chosen_sf,     -- DATA leg's SF; receiver retunes after CTS-tx
      payload_len = r.payload_len,    -- size pending_rx_expiry to actual DATA airtime
    }
    -- Arm the expiry timer so a never-arriving DATA can't freeze us.
    start_pending_rx_expiry(self)

    local cts = pack_cts(r.ctr_lo, chosen_sf)
    self:emit("cts_tx", {
      to = r.src, ctr_lo = r.ctr_lo,
      chosen_data_sf = chosen_sf,
    })
    self:log(string.format("cts_tx -> %s ctr_lo=%d chose SF%d (on routing SF%d)",
      name_of(self, r.src), r.ctr_lo, chosen_sf, self.routing_sf))
    tx_with_retry(self, cts, {
      sf    = self.routing_sf,
      label = "CTS",
      info  = string.format("to=%s msg=%d chosen_sf=%d",
        name_of(self, r.src), r.ctr_lo, chosen_sf),
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
    -- Anti-spam: track this CTS in meta.src's sliding window. CTS is the
    -- forwarder fingerprint — a legitimate forwarder emits ~1 CTS per
    -- inbound flight, so over the window R[X] ≈ C[X] for forwarders;
    -- an originator never CTSes (no inbound RTS to respond to) so
    -- C[X] ≈ 0. See header doc block "Anti-spam: 1st-hop statistical
    -- rate-limit".
    track_originator_observation(self, meta.src, "cts", c.ctr_lo,
      airtime_ms(self.routing_sf, self.bw_hz, self.cr,
                 self.preamble_sym, #frame))

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
                   DATA_HDR_LEN + self.max_payload_bytes + DATA_INNER_OVERHEAD)
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
    if c.ctr_lo ~= self.pending_tx.ctr_lo then return end

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
        origin = self.pending_tx.origin, payload = self.pending_tx.user_text,
        from = c.src or self.pending_tx.next, ctr_lo = c.ctr_lo,
        chosen_data_sf = c.chosen_data_sf,
      })
      return
    end
    self.pending_tx.chosen_data_sf = c.chosen_data_sf

    self:emit("cts_rx", {
      origin = self.pending_tx.origin,
      payload = self.pending_tx.user_text,
      ctr = self.pending_tx.ctr,
      from = self.pending_tx.next, ctr_lo = c.ctr_lo,
      chosen_data_sf = c.chosen_data_sf,
    })

    local gap = self.cts_to_data_gap_ms or 5
    self:log(string.format("cts_rx <- %s ctr_lo=%d chose SF%d -> waiting %dms then DATA",
      name_of(self, self.pending_tx.next), c.ctr_lo, c.chosen_data_sf, gap))
    -- Capture the snapshot so the timer fire still has the right
    -- pending_tx context if anything mutates it (e.g., a forward dance
    -- starting concurrently — shouldn't happen in scenario A, but be safe).
    local px = self.pending_tx
    self:after(gap, function()
      -- pending_tx may have been cleared by an ack_timeout giveup or
      -- another path between cts_rx and the gap-expiry; bail if so.
      if self.pending_tx == nil or self.pending_tx.ctr_lo ~= px.ctr_lo then
        return
      end
      -- pack_data(origin, next_hop, dst, ctr, flags, inner)
      local d = pack_data(px.origin, px.next, px.dst, px.ctr, px.flags or 0, px.payload)
      self:emit("data_tx", {
        origin = px.origin, payload = px.user_text, ctr = px.ctr,
        dst = px.dst, next = px.next, ctr_lo = px.ctr_lo, len = #px.payload,
        sf = px.chosen_data_sf,
      })
      self:log(string.format("data_tx -> %s ctr_lo=%d ctr=%d payload=%q on SF%d (ACK on SF%d)",
        name_of(self, px.next), px.ctr_lo, px.ctr, px.user_text, px.chosen_data_sf, self.routing_sf))
      tx_with_retry(self, d, {
        sf    = px.chosen_data_sf,
        label = "DATA",
        info  = string.format("origin=%s dst=%s next=%s msg=%d ctr=%d sf=%d payload=%q",
          name_of(self, px.origin), name_of(self, px.dst),
          name_of(self, px.next), px.ctr_lo, px.ctr, px.chosen_data_sf, px.user_text),
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
    if k.ctr_lo ~= self.pending_tx.ctr_lo then return end

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
        from = ack_src, ctr_lo = k.ctr_lo,
        data_snr_db = k.snr_db, snr_bucket = k.snr_bucket,
        ewma_out = self.snr_ewma_out[ack_src],
      })
    end
    self:emit("ack_rx", {
      origin = self.pending_tx.origin,
      payload = self.pending_tx.user_text,
      ctr = self.pending_tx.ctr,
      from = self.pending_tx.next, ctr_lo = k.ctr_lo,
      data_snr_db = k.snr_db,
    })
    self:log(string.format("ack_rx <- %s ctr_lo=%d data_snr=%.1fdB -> hop complete",
      name_of(self, self.pending_tx.next), k.ctr_lo, k.snr_db or 0))
    self.pending_tx = nil
    become_free(self)
    return
  end

  if tag == "N" then
    local n = parse_nack(frame)
    if not n then return end
    if self.pending_tx == nil then return end
    if n.ctr_lo ~= self.pending_tx.ctr_lo then return end

    -- NACK matched: chosen next-hop can't take us right now. Cancel the
    -- rts_timeout (NACK is a faster, definitive signal). NACK rides on
    -- data_sf — same channel as CTS would have come back on — so the
    -- sender's RX (already retuned to data_sf after the RTS TX) hears
    -- it without another retune.
    if self.rts_timeout_handle then
      self:cancel(self.rts_timeout_handle)
      self.rts_timeout_handle = nil
    end

    -- Budget NACK (new reason). The peer is duty-cycle-saturated; mark
    -- them blind for a tier-proportional window so classify_blind
    -- naturally reroutes the next attempt via the cascade alts. No
    -- wait-and-retry — budget recovery is on the order of minutes, not
    -- the NACK_WAIT_THRESHOLD's 2 seconds.
    if n.reason == NACK_REASON_BUDGET then
      local tier = n.budget_tier or BUDGET_TIER_CRITICAL
      local blind_ms = self.budget_blind_critical_ms
      if tier >= BUDGET_TIER_EXHAUSTED then
        blind_ms = self.budget_blind_exhausted_ms
      elseif tier <= BUDGET_TIER_STRAINED then
        blind_ms = self.budget_blind_strained_ms
      end
      local from_id = self.pending_tx.next
      local end_ms  = self:now() + blind_ms
      local prev    = self.blind_until[from_id]
      if prev == nil or end_ms > prev then
        self.blind_until[from_id] = end_ms
        self:emit("blind_observed", {
          node = from_id, until_ms = end_ms, reason = "nack_budget", tier = tier,
        })
      end
      -- Persistent tier mark: drives route_strictly_better's tier
      -- penalty so candidates via this neighbour get demoted in the
      -- routing table beyond the blind_until window. The blind window
      -- is short-term ("don't try right now"); the tier mark is
      -- routing-grade ("this peer is congested, prefer alternates
      -- when comparing routes"). TTL on neighbor_budget_tier_ttl_ms
      -- so a recovered peer eventually climbs back.
      self.neighbor_budget_tier[from_id] = tier
      self.neighbor_budget_tier_set_at[from_id] = self:now()
      self:emit("nack_rx", {
        origin = self.pending_tx.origin,
        payload = self.pending_tx.user_text,
        ctr = self.pending_tx.ctr,
        from = self.pending_tx.next, ctr_lo = n.ctr_lo,
        reason = "budget_low", tier = tier, blind_ms = blind_ms,
      })
      self:log(string.format(
        "nack_rx <- %s ctr_lo=%d reason=budget_low tier=%d -> blind for %dms",
        name_of(self, self.pending_tx.next), n.ctr_lo, tier, blind_ms))
      -- Push pending_tx back to the queue via the existing cascade-requeue
      -- helper. That gives us the full cap suite (cascade_requeue_max,
      -- cascade_requeue_total_max_ms wallclock, load-adaptive shrink) so
      -- a message ping-ponging between saturated peers can't live forever.
      -- When the helper returns false (caps exhausted), fall through to a
      -- final drop with the existing path_cascade_exhausted emit pair.
      if try_cascade_requeue(self, "budget_low") then
        self.pending_tx = nil
        become_free(self)
        return
      end
      -- Caps hit — true drop.
      self:emit("path_cascade_exhausted", {
        origin     = self.pending_tx.origin,
        payload    = self.pending_tx.user_text,
        ctr = self.pending_tx.ctr,
        dst        = self.pending_tx.dst, ctr_lo = self.pending_tx.ctr_lo,
        tried      = {}, trigger = "budget_low",
      })
      self:emit("rts_giveup", {
        origin = self.pending_tx.origin,
        payload = self.pending_tx.user_text,
        ctr = self.pending_tx.ctr,
        dst    = self.pending_tx.dst,
        next   = self.pending_tx.next, ctr_lo = self.pending_tx.ctr_lo,
      })
      self:log(string.format(
        "rts_giveup msg=%d dst=%s (budget_low caps hit)",
        self.pending_tx.ctr_lo, name_of(self, self.pending_tx.dst)))
      maybe_emit_self_over_budget(self, self.pending_tx, "budget_low")
      self.pending_tx = nil
      become_free(self)
      return
    end

    -- Legacy busy_rx NACK path (reason 0).
    self:emit("nack_rx", {
      origin = self.pending_tx.origin,
      payload = self.pending_tx.user_text,
      ctr = self.pending_tx.ctr,
      from = self.pending_tx.next, ctr_lo = n.ctr_lo, busy_for_ms = n.busy_for_ms,
    })
    self:log(string.format("nack_rx <- %s ctr_lo=%d busy_for=%dms",
      name_of(self, self.pending_tx.next), n.ctr_lo, n.busy_for_ms))

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
      local captured = self.pending_tx.ctr_lo
      -- Add small jitter on top of busy_for_ms to decorrelate multiple
      -- senders all NACKed by the same receiver — without it they
      -- thunder back in unison the moment the receiver frees up.
      local wait_ms = n.busy_for_ms + 1 + self:rand(0, self.retry_jitter_ms + 1)
      self:log(string.format("nack_wait ctr_lo=%d for %dms (busy_for=%d, same next-hop)",
        captured, wait_ms, n.busy_for_ms))
      self:after(wait_ms, function()
        if self.pending_tx ~= nil and self.pending_tx.ctr_lo == captured then
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
      payload    = self.pending_tx.payload,        -- inner bytes
      user_text  = self.pending_tx.user_text,
      ctr        = self.pending_tx.ctr,
      flags      = self.pending_tx.flags or 0,
      previous_hop = self.pending_tx.previous_hop,
      -- Preserve original tx_queue accounting: this is a busy-NACK requeue,
      -- NOT a cascade-requeue, so requeue_count stays at the pending_tx's
      -- value (which is what was inherited when the item was first popped).
      -- enqueue_time_ms is preserved so the wallclock cap still applies.
      enqueue_time_ms = self.pending_tx.enqueue_time_ms or self:now(),
      requeue_count   = self.pending_tx.requeue_count or 0,
      next_attempt_ms = 0,
    })
    self:emit("tx_requeued", {
      origin = self.pending_tx.origin,
      payload = self.pending_tx.user_text,
      ctr = self.pending_tx.ctr,
      dst = self.pending_tx.dst, ctr_lo = self.pending_tx.ctr_lo,
      busy_for_ms = n.busy_for_ms, depth = #self.tx_queue,
    })
    self:log(string.format("tx_requeued ctr_lo=%d busy_for=%dms (no alt, long wait)",
      self.pending_tx.ctr_lo, n.busy_for_ms))
    self.pending_tx = nil
    become_free(self)
    return
  end

  if tag == "D" then
    local d = parse_data(frame)
    if not d then return end
    if d.next ~= self.id then return end
    if self.pending_rx == nil or d.ctr_lo ~= self.pending_rx.ctr_lo then return end

    -- parse_data already extracted origin, body, ctr, flags from the new
    -- wire format. E2E flag bits are on wire byte 1 (not inner payload).
    local is_e2e_ack  = d.e2e_is_ack
    local e2e_ack_req = d.e2e_ack_req
    local user_text   = d.body         -- body = text for normal DATA, or acked-ctr bytes for E2E ACK

    self:emit("data_rx", {
      origin     = d.origin,
      payload    = user_text,
      ctr        = d.ctr,
      from       = self.pending_rx.from,  -- inbound sender (from pending_rx; d has no src field)
      dst        = d.dst,
      ctr_lo     = d.ctr_lo,
      len        = #d.inner,
    })
    self:log(string.format(
      "data_rx <- %s (origin=%s ctr=%d dst=%s ctr_lo=%d, %d inner bytes) -> back to SF%d",
      name_of(self, self.pending_rx.from), name_of(self, d.origin),
      d.ctr, name_of(self, d.dst),
      d.ctr_lo, #d.inner, self.routing_sf))

    -- DATA decoded. Cancel the pending_rx_expiry, retune RX, clear
    -- pending_rx. Then immediately TX the per-hop ACK on routing_sf and
    -- cache (sender, ctr_lo) so future retried RTS-from-this-sender
    -- short-circuits to a re-ACK without re-processing the DATA.
    local rx_from = self.pending_rx.from
    if self.pending_rx_expiry_handle then
      self:cancel(self.pending_rx_expiry_handle)
      self.pending_rx_expiry_handle = nil
    end
    self:set_rx_sf(self.routing_sf)
    self.pending_rx = nil

    self.last_acked_from[rx_from] = { ctr_lo = d.ctr_lo, t_ms = self:now() }
    -- Piggyback our measurement of THIS DATA's SNR into the ACK's 4-bit
    -- bucket. Sender uses it to maintain its outbound link-quality EWMA
    -- to us (which we can't see because we're at the receiving end);
    -- gives the sender a closed-loop signal for routing decisions and
    -- (future) per-neighbor RTS bitmap trimming.
    local ack = pack_ack(d.ctr_lo, meta.snr)
    self:emit("ack_tx", {
      origin = d.origin, payload = user_text, ctr = d.ctr,
      to = rx_from, ctr_lo = d.ctr_lo, data_snr = meta.snr,
    })
    self:log(string.format("ack_tx -> %s ctr_lo=%d (on routing SF%d)",
      name_of(self, rx_from), d.ctr_lo, self.routing_sf))
    tx_with_retry(self, ack, {
      sf    = self.routing_sf,
      label = "ACK",
      info  = string.format("to=%s msg=%d", name_of(self, rx_from), d.ctr_lo),
    })

    -- Origin-level dedup. Now that the ACK is on its way (the
    -- previous hop will clear pending_tx whether or not we forward),
    -- check whether we've already seen this (origin, ctr).
    -- Re-keyed from (origin, origin_seq) → (origin, ctr) per §7.0.1.
    do
      local seen_key = string.format("%d|%d", d.origin, d.ctr)
      local now_ms = self:now()
      local exp = self.seen_origins[seen_key]
      if exp and exp > now_ms then
        self:emit("dup_drop", {
          origin = d.origin, payload = user_text, ctr = d.ctr,
          from = rx_from, ctr_lo = d.ctr_lo,
        })
        self:log(string.format(
          "dup_drop <- %s (origin=%s ctr=%d, already seen — ACK only)",
          name_of(self, rx_from), name_of(self, d.origin), d.ctr))
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
    local d_origin    = d.origin
    local d_src       = rx_from            -- predecessor (for forward loop guard)
    local d_dst       = d.dst
    local d_inner     = d.inner            -- inner bytes verbatim for forwarding
    local d_ctr       = d.ctr
    local d_flags     = d.flags
    local d_user_text = user_text
    local is_delivered = (d.dst == self.id)

    if is_delivered then
      if is_e2e_ack then
        -- This DATA is an end-to-end ACK delivered to us as the original
        -- originator. Body carries [acked_ctr_lo, acked_ctr_hi] (2 bytes) —
        -- match against pending_e2e and emit delivered_confirmed. Do NOT
        -- emit "delivered" (not user data). Do NOT trigger another E2E ACK.
        if #d_user_text >= 2 then
          local acked_ctr = d_user_text:byte(1) | (d_user_text:byte(2) << 8)
          local info = self.pending_e2e[acked_ctr]
          if info ~= nil then
            self:emit("delivered_confirmed", {
              origin     = self.id,         -- the original originator (us)
              ctr        = acked_ctr,
              dst        = info.dst_id,
              payload    = info.user_text,
              elapsed_ms = self:now() - info.sent_at_ms,
              via_ack_from = d_origin,      -- the destination that ACK'd
            })
            self:log(string.format(
              "delivered_confirmed acked_ctr=%d dst=%s elapsed=%dms (E2E ACK from %s)",
              acked_ctr, info.dst_name, self:now() - info.sent_at_ms,
              name_of(self, d_origin)))
            self.pending_e2e[acked_ctr] = nil
          else
            -- No matching pending_e2e — either we already received this
            -- ACK (duplicate), already timed out, or never sent the
            -- corresponding e2e. Cheap diagnostic emit for the analyzer.
            self:emit("e2e_ack_unmatched", {
              ctr = acked_ctr, from = d_origin,
            })
          end
        end
      else
        self:emit("delivered", {
          origin = d_origin, payload = d_user_text, ctr = d_ctr,
        })
        self:log(string.format("DELIVERED from %s: %q (ctr=%d%s)",
          name_of(self, d_origin), d_user_text, d_ctr,
          e2e_ack_req and " [E2E-ack requested]" or ""))
        if e2e_ack_req then
          -- Schedule an E2E ACK send back to d_origin. The return flight
          -- carries DATA_FLAG_E2E_IS_ACK on wire byte 1. Its body is the
          -- 2-byte acked ctr [ctr_lo, ctr_hi] (the originator's ctr we're
          -- confirming). Goes through normal RTS-CTS-DATA-ACK mechanics.
          local return_ctr = self:next_ctr(d_origin)
          local return_body = string.char(d_ctr & 0xff) .. string.char((d_ctr >> 8) & 0xff)
          local return_inner = string.char(0)               -- src_addr_len = 0
                             .. string.char(self.id)        -- src_addr
                             .. return_body
          table.insert(self.tx_queue, {
            origin     = self.id,
            dst_id     = d_origin,
            dst_name   = name_of(self, d_origin),
            payload    = return_inner,
            user_text  = string.format("[E2E-ACK ctr=%d]", d_ctr),
            ctr        = return_ctr,
            flags      = DATA_FLAG_E2E_IS_ACK,
            enqueue_time_ms = self:now(),
            requeue_count   = 0,
            next_attempt_ms = 0,
          })
          self:emit("e2e_ack_tx_enqueued", {
            origin = self.id, ctr = return_ctr,
            dst = d_origin, acked_ctr = d_ctr,
            depth = #self.tx_queue,
          })
          self:log(string.format(
            "e2e_ack_tx_enqueued ctr=%d acked=%d dst=%s",
            return_ctr, d_ctr, name_of(self, d_origin)))
        end
      end
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
          origin = d_origin, payload = d_user_text, ctr = d_ctr,
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
          payload    = d_inner,             -- inner bytes (verbatim relay)
          user_text  = d_user_text,
          ctr        = d_ctr,
          flags      = d_flags,
          previous_hop = d_src,               -- forward loop guard
          enqueue_time_ms = self:now(),       -- fresh hop attempt
          requeue_count   = 0,
          next_attempt_ms = 0,
        })
        self:emit("forward_queued", {
          origin = d_origin, payload = d_user_text, ctr = d_ctr,
          dst = d_dst, depth = #self.tx_queue,
        })
        return
      end
      issue_send(self, d_origin, d_dst, dst_name,
                 d_inner, d_user_text, d_ctr, d_flags, d_src)
    end)
    return
  end

  if tag == "Q" then
    local q = parse_q(frame)
    if not q then return end
    -- Cross-network filter — drop foreign Q before any work.
    if q.leaf_id ~= self.leaf_id then return end
    -- Don't respond to ourselves (loop guard).
    if q.src == self.id then return end
    -- Dedup: if we recently responded to the same (src, dest), skip.
    -- The originator's defer queue still has timer-based retry; if our
    -- response was lost, the next Q-firing window will re-enable us.
    local key = q.src * 256 + q.dest
    local last = self.q_responded_to[key]
    local now = self:now()
    if last and (now - last) < self.q_respond_ttl_ms then return end
    self.q_responded_to[key] = now

    self:emit("q_rx", { from = q.src, dest = q.dest })

    if q.dest == self.id then
      -- Special case: someone wants a route to us. Mark our own direct-
      -- entry dirty (which is rt[self.id] if it exists; but rt typically
      -- doesn't include self). The cleanest signal: just send a triggered
      -- beacon so they get our identity (direct entry rt[self.id] from
      -- our point of view doesn't exist; receivers learn us via the BCN
      -- src field, not entries).
      schedule_triggered_beacon(self)
      self:log(string.format(
        "q_rx <- %s asking for me; triggered beacon scheduled",
        name_of(self, q.src)))
      return
    end

    local entry = self.rt[q.dest]
    if entry == nil then
      -- We don't know the route either — silent (someone else might).
      self:log(string.format(
        "q_rx <- %s asking for %s; no route, silent",
        name_of(self, q.src), name_of(self, q.dest)))
      return
    end

    -- We have it. Mark dirty + schedule triggered beacon — the
    -- differential beacon mechanism will prioritise this dest in the
    -- priority slots of the next emission.
    entry.dirty = true
    schedule_triggered_beacon(self)
    self:log(string.format(
      "q_rx <- %s asking for %s; marked dirty + triggered beacon",
      name_of(self, q.src), name_of(self, q.dest)))
    return
  end
end

-- on_command "send <dst_name> <text>": enqueue a user-originated send into
-- the TX queue and try to drain immediately. Even if we're busy now (mid-RX,
-- mid-TX, or queued forwards ahead), the queue ensures the message will fire
-- as soon as we're free — no more "ERROR: busy" rejection.
function on_command(self, cmd_str)
  -- Two send variants:
  --   send     <dst> <text>   — best-effort, no end-to-end confirmation
  --   send_e2e <dst> <text>   — request end-to-end ACK from destination;
  --                              originator gets delivered_confirmed or
  --                              e2e_ack_timeout. See E2E ACK design block
  --                              in the header — wire format is the same,
  --                              just one bit set in the payload header.
  local want_e2e = false
  local dst_name, text = cmd_str:match("^send_e2e (%S+) (.+)$")
  if dst_name then
    want_e2e = true
  else
    dst_name, text = cmd_str:match("^send (%S+) (.+)$")
  end
  if not dst_name then
    return "ERROR: usage: send <dst_name> <text>  or  send_e2e <dst_name> <text>"
  end
  local dst_id = self.name_to_id[dst_name]
  if dst_id == nil then return "ERROR: unknown dst: " .. dst_name end
  -- Stamp this user-message with a per-(self,dst) 16-bit outbound counter.
  -- The pair (origin_id, ctr) is the globally-unique e2e message id used
  -- by every receiving node for dedup. Replaces the old flat next_origin_seq.
  local ctr = self:next_ctr(dst_id)
  local wire_flags = want_e2e and DATA_FLAG_E2E_ACK_REQ or 0
  -- inner = src_addr_len(1) | src_addr(1) | body
  local inner = string.char(0) .. string.char(self.id) .. text
  if want_e2e then
    -- Register pending_e2e BEFORE enqueueing the send so a fast E2E ACK
    -- (e.g. test scenario with 1-hop path) doesn't arrive before the
    -- bookkeeping is in place.
    self.pending_e2e[ctr] = {
      sent_at_ms = self:now(),
      dst_id     = dst_id,
      dst_name   = dst_name,
      user_text  = text,
    }
    self:emit("e2e_ack_pending", {
      origin = self.id, ctr = ctr, dst = dst_id,
      ttl_ms = self.e2e_ack_ttl_ms,
    })
    self:log(string.format("send_e2e: pending_e2e[%d] dst=%s ttl=%dms",
      ctr, dst_name, self.e2e_ack_ttl_ms))
  end
  table.insert(self.tx_queue, {
    origin     = self.id,
    dst_id     = dst_id,
    dst_name   = dst_name,
    payload    = inner,           -- inner bytes (src_addr_len|src_addr|body)
    user_text  = text,            -- emit / log clarity
    ctr        = ctr,
    flags      = wire_flags,
    enqueue_time_ms = self:now(), -- first enqueue; cap reference for cascade-requeue
    requeue_count   = 0,
    next_attempt_ms = 0,
  })
  self:emit("tx_enqueue", {
    origin = self.id, payload = text, ctr = ctr,
    dst = dst_id, depth = #self.tx_queue,
    e2e_ack_requested = want_e2e,
  })
  self:log(string.format("send: queued dst=%s payload=%q ctr=%d e2e=%s (queue depth=%d)",
    dst_name, text, ctr, tostring(want_e2e), #self.tx_queue))
  become_free(self)
  return string.format("queued (depth=%d, ctr=%d, e2e=%s)",
    #self.tx_queue, ctr, tostring(want_e2e))
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
