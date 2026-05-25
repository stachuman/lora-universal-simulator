-- scenarios/dv_dual_sf.lua
-- Distance-vector routing on routing_sf with per-hop dual-SF data delivery
-- on data_sf via RTS/CTS/DATA. See docs/superpowers/specs/2026-05-06-s01-dv-dual-sf-scenario-design.md.
--
-- Wire format:
-- | Tag   | Frame  | Layout                                                                          |
-- | ----- | ------ | ------------------------------------------------------------------------------- |
-- | `'B'` | Beacon | `B`, [leaf_id(4)|has_schedule(1)|self_gateway(1)|is_mobile(1)|rsv(1)](1), src(1), [seen_bm(1)|has_ext(1)|n_entries(6)](1), key_hash32(4), [layer_count(1)+sched×L×4B]?, entries × n × {dest(1), next(1), [bucket(4)|(hops-1)(3)|is_gateway(1)](1)}, seen_bitmap(32B)?, ext_len(1)+TLVs?  →  8 + [1+4L]? + 3n + [32]? + [1+ext]? B |
-- | `'R'` | RTS    | `R`, src(1), next(1), [addr_len(3)|rsv(1)|leaf_id(4)](1), dst(1 when addr_len=0), [ctr_lo(4)|rsv(4)](1), sf_bitmap(1), payload_len(1)  →  8 B (in-leaf) |
-- | `'C'` | CTS    | `C`, [ctr_lo(4)|(sf-5)(3)|already_received(1)](1)  →  2 B                      |
-- | `'D'` | DATA   | `D`, [addr_len(3)\|rsv(1)\|E2E_ACK_REQ(1)\|E2E_IS_ACK(1)\|IS_MULTICAST(1)\|rsv(1)](1), next(1), dst(1 when addr_len=0), ctr_lo(1), ctr_hi(1), ciphertext(n+2), MAC(4)  →  10+n B (in-leaf) |
-- | `'K'` | ACK    | `K`, [ctr_lo(4)|snr_bucket(4)](1)  →  2 B                                       |
-- | `'N'` | NACK   | `N`, [reason(4)|ctr_lo(4)](1), payload(1)  →  3 B  |
-- | `'Q'` | RREQ-route | `Q`, src(1), dest(1), [leaf_id(4)|reserved(4)](1)  →  4 B (one-hop route query) |
-- | `'H'` | hash-locate | `H`, origin(1), [leaf_id(4)|flags(4)](1), key_hash32(4 LE), ttl(1)  →  8 B (multi-hop TTL flood; only forwardable control frame; §3.7a) |
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
-- plus already_received=1 when the receiver already has this DATA from
-- a previous try whose ACK was lost. The SNR fed into select_data_sf is the
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
--   first-beacon scheduling:
--     node-local DISCOVERY state → rand(0, discovery_beacon_period_ms)
--                                  (mass-boot/joiner jitter to avoid storm)
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
--       hops == 1  → rt_aging_ttl_neighbor_ms  (default 45 min)
--       hops >= 2  → rt_aging_ttl_remote_ms    (default 3 h)
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
--   1. Node-local DISCOVERY. Every boot starts in a short discovery
--      state: fast/full BCNs with jitter, then normal dirty-only BCNs
--      after enough neighbours/routes are observed or the discovery
--      timeout expires. This is firmware state, not simulator warmup.
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
--     • last_acked_from[(r.src,r.dst,r.ctr_lo,payload_len)] hit
--                                      → tx CTS already_received=1,
--                                              return (sender retried after
--                                              losing previous ACK)
--     • pending_rx busy + same DATA identity → re-tx CTS-dup, restart
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
--     3. cache last_acked_from[(pending_rx.from,d.dst,d.ctr_lo,len)]; tx 'K' on routing_sf
--     4. ORIGIN-LEVEL DEDUP: if (d.origin, d.dst, d.ctr) seen recently,
--        emit dup_drop and return — ACK was already sent; we just don't
--        deliver-twice or forward-twice. Catches DV routing loops and
--        legitimate same-payload retries via different paths.
--     5. record the (origin, dst, ctr) in seen_origins with a TTL
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
--      at busy_until + rand(0, lbt_backoff_ms). Reduces head-on collisions
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
--   Knobs on self: lbt_enabled (default true), lbt_backoff_ms (default
--   = half RTS-airtime), retry_jitter_ms (default = one RTS-airtime,
--   scales with BW/SF), flood_lbt_max_defer_ms (default = one beacon's
--   airtime).
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
--   1. last_acked_from[(r.src,r.dst,r.ctr_lo,payload_len)] hit
--      → CTS already_received=1, return
--   2. pending_rx busy + same DATA identity → CTS-dup, restart expiry
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
--     NACK a sender we already acked; we send CTS already_received=1.
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
--        - records pending_e2e[dst|ctr] = {sent_at, dst, ctr, text}
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
--        - looks up pending_e2e[d.origin|acked_ctr]
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
-- networks with > ~82 destinations (8-byte header + 3 bytes per entry).
-- pack_beacon takes a `max_entries` cap and a sliding `offset`: it emits
-- a contiguous page of up to `max_entries` entries starting at `offset`
-- in a deterministic ordering of the rt[] table. The caller (beacon_fire)
-- bumps the offset every fire so successive beacons cycle through the
-- whole table. Receivers don't need to track pages — every entry they
-- hear gets merged via rt_merge as before.
-- BCN — 8-byte header + optional schedule block + n × 3-byte entries
--       + optional 32-byte destination-seen bitmap:
--   byte 0 : tag 'B'
--   byte 1 : leaf_id(4 hi) | has_schedule(1) | self_gateway(1) | is_mobile(1) | rsv(1)
--   byte 2 : src (8)
--   byte 3 : has_seen_bitmap(1 hi) | has_ext(1) | n_entries(6 lo)
--   bytes 4..7 : key_hash32 (LE)
--   if has_schedule == 1:
--     byte 8 : layer_count (8)
--     layer_count × 4-byte schedule records:
--       byte 0: layer_id(4 hi) | (routing_sf - 5)(3) | period_unit_5s(1)
--       byte 1: duration_100ms
--       byte 2: countdown_100ms (ms/100 from this beacon's send time until the
--               next foreign-layer window opens; receiver anchors to its own
--               BCN-receive time -- not a static boot offset)
--       byte 3: period units (seconds if unit=0, 5-second units if unit=1)
--   Mobile endpoints emit identity-only BCN: n_entries=0, no seen bitmap,
--   no route entries, no liveness extension. This refreshes id_bind without
--   advertising a mobile as a transit router.
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

-- ============================================================
-- Q4 fixed-point dB representation (pre-port hardening, ROADMAP §11.2)
--
-- All internal SNR/RSSI/score/EWMA storage and arithmetic is `int16_t`
-- Q4 — 1 unit = 1/16 dB, range -2048.0 .. +2047.9375 dB. The C++ port
-- maps this directly to `int16_t` with no FPU. Floats survive only at
-- I/O boundaries: ingress (meta.snr / meta.rssi from runtime) converts
-- via `db_to_q4` immediately; egress (events, logs) converts back via
-- `q4_to_db` for human readability. Wire buckets work in Q4.
--
-- Alpha (EWMA weight) is also Q4 — alpha=0.3 → 5 (=0.3125 dB-fraction),
-- range [0, Q4_SCALE]. Quantization noise on alpha is intentional.
-- ============================================================
Q4_SCALE = 16
Q4_MAX   =  32767   -- int16_t saturation
Q4_MIN   = -32768

function db_to_q4(db)
  if db == nil then return nil end
  local v
  if db >= 0 then v = math.floor(db * Q4_SCALE + 0.5)
  else            v = -math.floor(-db * Q4_SCALE + 0.5) end
  if v >  Q4_MAX then return  Q4_MAX end
  if v <  Q4_MIN then return  Q4_MIN end
  return v
end

function q4_to_db(q4)
  if q4 == nil then return nil end
  return q4 / Q4_SCALE
end

-- EWMA in Q4: result = (alpha * sample + (SCALE - alpha) * prev) // SCALE.
-- alpha_q4 must already be in [0, Q4_SCALE].
function q4_ewma(prev_q4, sample_q4, alpha_q4)
  return (alpha_q4 * sample_q4 + (Q4_SCALE - alpha_q4) * prev_q4) // Q4_SCALE
end

-- Wire-bucket helpers take Q4 in / return Q4 out. The bucket index
-- itself is unitless. -20 dB = -320 Q4 (bucket-0 lower edge), bucket
-- centers at -19, -17, ... +11 dB (i.e. -304, -272, ... +176 in Q4),
-- bin width = 2 dB = 32 Q4.
local function bucket_of_snr_4b(snr_q4)
  local b = (snr_q4 - (-20 * Q4_SCALE)) // (2 * Q4_SCALE)
  if b < 0 then b = 0 end
  if b > 15 then b = 15 end
  return b
end

local function snr_of_bucket_4b(bucket)
  return (-19 + bucket * 2) * Q4_SCALE
end

-- ACK 2-bit SNR bucket. -12 dB = -192 Q4, -4 dB = -64 Q4. Centers
-- (-16, -8, +4) chosen to match the prior `snr_of_bucket_2b` table.
local function bucket_of_snr_2b(snr_q4)
  if snr_q4 == nil then return 3 end
  if snr_q4 < -192 then return 0 end
  if snr_q4 <  -64 then return 1 end
  return 2
end

local function snr_of_bucket_2b(bucket)
  if bucket == 0 then return -16 * Q4_SCALE end
  if bucket == 1 then return  -8 * Q4_SCALE end
  if bucket == 2 then return   4 * Q4_SCALE end
  return nil
end

-- ============================================================================
-- RNG CONTRACT (ROADMAP §11.3)
--
-- All script-level randomness flows through `self:rand(lo, hi)`, provided
-- by the runtime (orchestrator/runtime/ScriptedNode.cpp::api_rand):
--
--   self:rand(lo, hi) → int in [lo, hi), drawn from the simulation-wide
--                       std::mt19937 PRNG seeded by simulation.seed.
--
-- The script makes ZERO calls to math.random / math.randomseed /
-- os.time / os.clock. Every random decision goes through self:rand.
--
-- For bit-identical cross-implementation tests the C++ port MUST:
--   * Use std::mt19937 seeded by the same simulation.seed.
--   * Use std::uniform_int_distribution<int> with bounds (lo, hi - 1).
--   * Issue draws in the same call-site order as the Lua model when
--     processing the same scenario timeline. The runtime steps events
--     deterministically (single-tick scheduler with stable event order),
--     so order falls out naturally given a one-to-one state-machine port.
--
-- Audit of current callsites (20 total, 2026-05-19):
--   * Jitter (collision decorrelation): LBT defer backoff (×3),
--     RTS retry (×2), NACK busy-retry (×1), beacon silence jitter,
--     gateway TX retry guard.
--   * Periodic-fire spread: beacon-fire delay (×4 — periodic / triggered
--     / overrides), first-beacon initial period.
--   * Backoff: join_retry, join_offer responder jitter.
--   * Discover jitter: join_discover_jitter.
--   * Nonce: J_CLAIM nonce (×2, uniform 0..255).
--   * Slot picker: choose-free-id during join (uniform over free set).
--
-- If a new RNG call is added: use self:rand (never math.random) and add
-- the intent to the audit list above so the C++ port maintainer has a
-- checklist for one-to-one stream alignment.
-- ============================================================================

-- ============================================================================
-- PROTOCOL — production-fixed constants (audit class "P", see CONFIG_AUDIT.md)
--
-- These are not runtime-tunable. In the C++ port they become a
-- `protocol_constants.h` header of `constexpr` values. The Lua model
-- applies them via `apply_protocol_constants(self)` at the top of
-- `on_init`. Per-scenario config can only set the ~20 T (tunable) +
-- 5 F (feature-flag) + ~8 D (debug-only) knobs that remain in on_init's
-- config-reading block. Touching anything here is a protocol-design
-- change, not a deployment choice — change the value, run the suite,
-- update the port.
-- ============================================================================
PROTOCOL = {
  -- ---- Radio / PHY (P-class only; SF/BW/CR/duty are T, set per-network) ----
  preamble_sym                   = 16,         -- SX1262 default; varying breaks interop
  sf_margin_q4                   = 80,         -- 5.0 dB Q4 — demod-threshold safety

  -- ---- MAC / channel access (P-class only) ----
  cts_to_data_gap_ms             = 5,          -- HW SF-switch settle
  rts_busy_retry_ms              = 30,         -- receiver-busy reschedule
  rts_max_retries                = 3,          -- cascade-analysis tuned

  -- ---- Beacon plane ----
  discovery_beacon_period_ms     = 5000,       -- boot-time fast cadence
  beacon_max_bytes               = 151,        -- frame size cap (LoRa ≈ 256)
  beacon_trigger_jitter_min_ms   = 2000,       -- triggered-beacon coalescing
  beacon_trigger_jitter_max_ms   = 10000,
  beacon_trigger_min_interval_ms = 120000,     -- storm-prone trigger rate limit
  quiet_threshold_ms             = 30000,      -- channel-busy throttle gate
  beacon_silence_jitter_ms       = 10000,      -- thundering-herd spread
  seen_bitmap_ttl_ms             = 1800000,    -- derived: 2× beacon period

  -- ---- Boot / discovery ----
  discovery_ms                   = 60000,
  discovery_min_bcn_rx           = 3,
  discovery_min_routes           = 8,
  beacon_boot_grace_ms           = 120000,
  req_sync_listen_ms             = 8000,
  req_sync_retry_ms              = 30000,

  -- ---- Routing (DV) ----
  rt_aging_check_period_ms       = 60000,
  next_hop_live_ttl_ms           = 1200000,    -- 20 min
  route_snr_conservatism_q4      = 0,          -- 0.0 dB Q4 — no-op today
  snr_ewma_alpha_q4              = 5,          -- 0.3 ≈ 5/16, ~10-sample window

  -- ---- Peer liveness (suspect/silent/dead tiers) ----
  peer_suspect_rts_timeouts      = 2,
  peer_silent_rts_timeouts       = 3,
  peer_dead_rts_timeouts         = 6,
  peer_suspect_ttl_ms            = 300000,     -- 5 min
  peer_silent_ttl_ms             = 900000,     -- 15 min
  peer_dead_ttl_ms               = 3600000,    -- 1 h
  peer_dead_evidence_window_ms   = 900000,     -- min elapsed for dead promotion
  peer_suspect_penalty_q4        = 192,        -- 12.0 dB Q4
  peer_silent_penalty_q4         = 640,        -- 40.0 dB Q4
  peer_dead_penalty_q4           = 1280,       -- 80.0 dB Q4
  peer_suspect_bcn_max           = 8,

  -- ---- Duty-cycle budget tiers ----
  budget_strained_pct            = 50,         -- >50% used → STRAINED
  budget_critical_pct            = 80,         -- >80% used → CRITICAL
  budget_exhausted_pct           = 95,         -- >95% used → EXHAUSTED
  budget_blind_strained_ms       = 60000,      -- per-tier blind windows
  budget_blind_critical_ms       = 180000,
  budget_blind_exhausted_ms      = 300000,
  neighbor_budget_tier_ttl_ms    = 300000,     -- 5 min

  -- ---- Anti-spam originator rate-limit (P-class only) ----
  originator_window_ms           = 300000,     -- 5 min sliding window
  originator_airtime_share       = 0.25,       -- backstop
  originator_retry_dedup_ms      = 10000,

  -- ---- Priority unicast (ROADMAP §3a) ----
  -- Hard cap on priority sends per originator AND per 1st-hop direct
  -- sender. 5 per hour × ~200 ms airtime × ~6 forwarders = ~17% of g1
  -- 1% duty budget; leaves 83% for normal traffic.
  originator_priority_max_per_window = 5,
  originator_priority_window_ms      = 3600000,  -- 1 h

  -- ---- Channel gossip (ROADMAP §3) ----
  -- Shared FIFO across all subscribed channels — no per-channel quota.
  -- 128 entries × ~200 B avg ≈ 25 KB total buffer; fits comfortably on
  -- nRF52840's 256 KB RAM.
  cap_channel_buffer            = 128,
  channel_msg_max_payload_bytes = 200,
  -- BCN extension TLV body cap is 15 bytes (4-bit length field). With
  -- 1-byte count + 4-byte IDs that's max 3 IDs per BCN digest.
  channel_dirty_max_per_bcn     = 3,
  -- Pull rate-limit at requester: after sending a pull for an id, don't
  -- re-pull the same id for this window. Pairs with the holder-side
  -- broadcast-dedup (Q handler): if the holder's broadcast collides or
  -- we miss it (half-duplex blind), recovery happens via the NEXT BCN
  -- digest cycle (~30 s) — and the window prevents the same node from
  -- flooding pulls in the meantime. Was 5000 ms; widened to 60000 ms
  -- (2 BCN cycles) so the natural cascade timing matches.
  channel_pull_window_ms        = 60000,
  -- Random delay before sending a scheduled pull. With N candidates
  -- behind the same BCN digest the only way the herd avoids a collision
  -- storm is by having enough time for ONE of them to fire first and
  -- have the others overhear-cancel via the peer-Q sniff path (see
  -- on_recv 'Q') or the M-payload promiscuous-receive path. Widened
  -- from 500 ms to 5000 ms after s12 / s13 showed the pre-widening
  -- value left ~zero room for cancellation: by the time the first
  -- pull's M-response arrived (~250 ms), most peers had already fired
  -- their own pulls.
  channel_pull_jitter_ms        = 5000,
  -- Per-BCN-cycle cap on pulls scheduled at this node (prevents pull
  -- storms when a new joiner sees many missing IDs in neighbour digests).
  cap_channel_pulls_per_bcn_cycle = 3,
  -- After K advertisements of the same dirty entry in our BCN, clear the
  -- dirty bit. Two compounding effects motivated this in s12: Fix 1
  -- (peer-Q cancel) funnels round-1 pulls to a few "winners", and those
  -- winners would otherwise advertise the dirty entry forever (the
  -- original code never cleared dirty on the channel buffer). Result was
  -- a small set of secondary holders saturating their duty cycle serving
  -- 30+ M-frames each, starving DM forwarding. With K=3 and BCN period
  -- 30 s, a holder advertises for ~90 s. Other holders (who pulled it
  -- during that window, or received via overhear) keep their own dirty
  -- bit and carry the gossip forward. Net effect is a wave of advertisers
  -- moving through the mesh instead of a permanent few.
  channel_dirty_max_advertisements = 3,

  -- ---- Cascade-requeue (Phase C) ----
  cascade_requeue_max            = 3,
  cascade_requeue_base_ms        = 5000,
  cascade_requeue_backoff_cap_ms = 30000,
  cascade_requeue_total_max_ms   = 60000,
  cascade_requeue_load_threshold = 0,

  -- ---- Q frames ----
  q_query_ttl_ms                 = 5000,
  q_respond_ttl_ms               = 10000,

  -- ---- Sync response (REQ_SYNC, P-class only) ----
  sync_response_backoff_min_ms   = 500,
  sync_response_backoff_max_ms   = 6000,
  sync_response_mobile_penalty_ms          = 8000,
  sync_response_requester_mobile_penalty_ms = 2000,
  sync_response_suppress_window_ms = 12000,

  -- ---- Defer / dedup ----
  send_defer_ttl_ms              = 30000,
  last_acked_ttl_ms              = 10000,
  seen_origin_ttl_ms             = 30000,

  -- ---- Hop budget (§7.6) ----
  hop_budget_slack               = 3,
  hop_budget_max_initial         = 15,         -- 4-bit field max

  -- ---- Bounded-state caps (§11.1 in ROADMAP) ----
  cap_seen_origins               = 256,
  cap_q_queried                  = 128,
  cap_q_responded_to             = 128,
  cap_deferred_sends             = 32,
  cap_gateway_deferred_handoffs  = 32,
  cap_id_bind                    = 256,

  -- ---- Identity binding ----
  id_bind_ttl_ms                 = 172800000,  -- 48 h

  -- ---- Gateway scheduling ----
  gateway_schedule_guard_ms      = 100,
  -- Gateway visit-schedule defaults: fallback when a gateway_layers[i] record
  -- omits the field (the per-record value always wins). Switching FREQUENCY is
  -- the lever for cross-layer delivery, not the home/visit SPLIT (which is
  -- zero-sum: doorstep<->visit loss just trade off). A 24-seed s15 sweep put
  -- 15s/7.5s (50/50) at 56%->68% vs the old 30s/15s -- a shorter period cuts
  -- the wait for the gateway to be on the right layer (doorstep + originator-
  -- stuck loss). ~10s over-shoots (visit window too short to deliver onward).
  -- Stays within the 10% radio duty budget (peak duty-budget use ~51%, zero
  -- beacon_skipped_budget). See PROTOCOL.md "Gateway schedule records".
  gateway_visit_period_ms        = 15000,
  gateway_visit_duration_ms      = 7500,       -- 50/50 split
  gateway_visit_offset_ms        = 7500,

  -- ---- Multi-hop hash-locate ('H' frame flood, PROTOCOL §3.7a) ----
  -- The gateway floods an 'H' query on the target layer to resolve a
  -- dst_key_hash32 -> node_id binding it doesn't hold. TTL bounds the
  -- flood; forwarders dedup on (origin, hash). TTL = 8 to match the
  -- DV 8-hop routing cap (hops 1..8, combined_hops>8 rejected) — a
  -- query must be able to reach any node that's routable in the layer.
  hash_query_max_ttl             = 8,
  hash_query_seen_ttl_ms         = 10000,   -- ~2× q_query_ttl_ms
  cap_hash_query_seen            = 64,

  -- ---- Same-layer route discovery ('R' RREQ/RREP flood, PROTOCOL §3.7b) ----
  -- AODV-style on-demand route discovery. Replaces the old single-hop Q
  -- ROUTE_QUERY (which couldn't reach a route known >1 hop away). Expanding
  -- ring: first attempt TTL=1 (cheap, a neighbour may answer like old Q),
  -- escalate to route_request_max_ttl on the next requery. Reverse path is
  -- learned as the RREQ floods; the RREP lays the forward path on the way back.
  route_request_max_ttl          = 8,        -- matches the DV 8-hop cap
  route_request_seen_ttl_ms      = 10000,    -- RREQ flood dedup window
  cap_route_request_seen         = 64,       -- relay-side flood-dedup table
  cap_route_request_last         = 128,      -- origination-side per-dst table (was cap_q_queried)

  -- ---- Cross-layer routing propagation (BCN TLV type=4) ----
  -- Lifetime of each (gw_id, dest_layer) entry in `self.bridged_layers`.
  -- Refreshed on every observation; pruned on access if older. Match the
  -- BCN-derived state lifetime defaults (= id_bind_ttl_ms = 48 h) so
  -- gateways that go silent age out at the same cadence as other identity
  -- bindings. Tests can shorten via config.
  gateway_bridged_layers_ttl_ms     = 172800000,  -- 48 h
  -- 4-bit TLV `len` field caps payload at 15 bytes. With the split-list
  -- form (N gw_ids + ceil(N/2) packed-nibble layer bytes), 9 entries fit
  -- (9 + 5 = 14 bytes). Larger advertisements need chained TLVs or
  -- top-K rotation across BCN cycles.
  gateway_bridged_layers_max_per_tlv = 9,

  -- ---- Join state machine (§2a) ----
  join_listen_ms                 = 3000,
  join_discover_jitter_ms        = 3000,
  join_discover_wait_ms          = 10000,
  join_discover_max_attempts     = 0,          -- 0 = unlimited
  join_offer_backoff_min_ms      = 100,
  join_offer_backoff_max_ms      = 1000,
  join_claim_guard_ms            = 3000,
  join_retry_backoff_ms          = 10000,
  join_j_rate_limit_window_ms    = 300000,     -- 5 min
  join_j_max_per_window          = 6,
}

-- Bulk-apply PROTOCOL constants onto a node. Called near the top of
-- on_init. `config` can override individual values — this is the Lua
-- model's escape hatch for dedicated tests that need accelerated
-- timings (e.g. t55 shrinks gateway_remote_bind_ttl_ms from 48 h to
-- 8 s; t61 shrinks cap_q_queried from 128 to 2). The C++ port has no
-- such escape hatch — these become `constexpr` and tests run against
-- the production values with a longer wallclock instead.
function apply_protocol_constants(self, config)
  for k, v in pairs(PROTOCOL) do
    if config ~= nil and config[k] ~= nil then
      self[k] = config[k]
    else
      self[k] = v
    end
  end
end

-- Differential pack_beacon — two-tier emission.
--
-- Phase 1 (priority): every rt[dest] with .dirty=true (set by rt_merge
--   on "new" / "promote" / "primary_refresh", and by rt_prune_cycle when
--   the primary was pruned). Sorted by dest_id for determinism. Capped at
--   max_entries — overflow waits for the next beacon (no information loss).
--
-- Phase 2 (discovery/background): the existing sliding-offset rotation fills
--   any remaining slots, skipping destinations already in the dirty page so
--   we never duplicate within a single beacon. In normal mode, periodic
--   and triggered BCNs skip this phase and rely on dirty entries plus the
--   seen bitmap for freshness.
--
-- After emission: dirty flags for sent routes are cleared. The stable
-- offset advances ONLY by the number of stable slots used — so when
-- dirty fills the beacon, stable progress isn't lost.
--
-- Steady state after discovery with no churn → all flags clean → Phase 2 is
-- skipped → BCN carries only the header plus the optional seen bitmap.
local BCN_N_HAS_SEEN_BITMAP = 0x80
local BCN_N_HAS_EXT         = 0x40
local BCN_N_ENTRIES_MASK    = 0x3f
local BCN_SEEN_BITMAP_BYTES = 32
local BCN_EXT_TYPE_SUSPECT_NODES = 1
local BCN_EXT_TYPE_LIVENESS_STATE = 2
-- ROADMAP §3 gossip channels: dirty-bit list of recent channel message IDs.
-- TLV length is 4-bit so body ≤ 15 bytes. Body layout: count(1B) + ID(4B) × N.
-- That gives 1 + 3×4 = 13 ≤ 15 → cap at 3 IDs per BCN. Multi-TLV (multiple
-- digest extensions in same BCN) is a future enhancement if propagation
-- needs more headroom; for v1 the lazy convergence model is fine with 3.
BCN_EXT_TYPE_CHANNEL_DIGEST = 3   -- global to stay under 200-locals limit
-- BCN ext TLV type 4: gateway_layer (cross-layer routing propagation).
-- Split-list: N × gw_id(8) followed by N × dest_layer(4) packed two
-- nibbles per byte. N = (2 × len) // 3. Max 9 entries per TLV.
BCN_EXT_TYPE_GATEWAY_LAYER = 4   -- global to stay under 200-locals limit
local PEER_LEVEL_SUSPECT = 1
local PEER_LEVEL_SILENT  = 2
local PEER_LEVEL_DEAD    = 3

local function bitmap_set_bit(bytes, id)
  if id < 0 or id > 254 then return end
  local byte_i = math.floor(id / 8) + 1
  local bit_i = id % 8
  bytes[byte_i] = bytes[byte_i] | (1 << bit_i)
end

local function bitmap_get_bit(bitmap, id)
  if id < 0 or id > 254 or #bitmap < BCN_SEEN_BITMAP_BYTES then return false end
  local byte_i = math.floor(id / 8) + 1
  local bit_i = id % 8
  return (bitmap:byte(byte_i) & (1 << bit_i)) ~= 0
end

local function bitmap_count_bits(bitmap)
  local n = 0
  for i = 1, #bitmap do
    local b = bitmap:byte(i)
    while b ~= 0 do
      n = n + (b & 1)
      b = b >> 1
    end
  end
  return n
end

local function build_seen_bitmap(node)
  local bytes = {}
  for i = 1, BCN_SEEN_BITMAP_BYTES do bytes[i] = 0 end
  local now = node:now()
  local ttl = node.seen_bitmap_ttl_ms or 0
  if ttl > 0 then
    for dest_id, seen_ms in pairs(node.dest_seen_ms or {}) do
      if dest_id >= 0 and dest_id <= 254 and (now - seen_ms) <= ttl then
        bitmap_set_bit(bytes, dest_id)
      end
    end
    for dest_id, entry in pairs(node.rt or {}) do
      local primary = entry.candidates and entry.candidates[1]
      if dest_id >= 0 and dest_id <= 254 and primary and primary.last_seen_ms
         and (now - primary.last_seen_ms) <= ttl then
        bitmap_set_bit(bytes, dest_id)
      end
    end
  end
  bitmap_set_bit(bytes, node.id)
  local out = {}
  for i = 1, BCN_SEEN_BITMAP_BYTES do out[i] = string.char(bytes[i]) end
  local bitmap = table.concat(out)
  return bitmap, bitmap_count_bits(bitmap)
end

local function mark_dest_seen(self, dest_id, source)
  if dest_id == nil or dest_id < 0 or dest_id > 254 then return false end
  local now = self:now()
  local prev = self.dest_seen_ms[dest_id]
  self.dest_seen_ms[dest_id] = now
  local emit_interval = math.max(1, math.floor((self.seen_bitmap_ttl_ms or 1) / 4))
  if prev == nil or (now - prev) >= emit_interval then
    self:emit("dest_seen_update", {
      dest = dest_id,
      source = source,
      age_ms = prev and (now - prev) or nil,
    })
  end
  return prev == nil
end

local function is_mobile_peer(self, node_id)
  return self.mobile_peers and self.mobile_peers[node_id] == true
end

local function route_uses_mobile_as_transit(self, dest_id, next_hop)
  return next_hop ~= nil
     and dest_id ~= nil
     and next_hop ~= dest_id
     and is_mobile_peer(self, next_hop)
end

local function refresh_bitmap_candidates(self, dest_id, next_hop)
  local entry = self.rt[dest_id]
  if not entry or not entry.candidates then return 0 end
  local refreshed = 0
  local now = self:now()
  for i, c in ipairs(entry.candidates) do
    if c.next_hop == next_hop then
      local age = c.last_seen_ms and (now - c.last_seen_ms) or nil
      c.last_seen_ms = now
      refreshed = refreshed + 1
      self:emit("rt_bitmap_refresh", {
        dest = dest_id,
        next = next_hop,
        slot = (i == 1) and "primary" or "alt",
        age_ms = age,
      })
    end
  end
  return refreshed
end

local function apply_seen_bitmap(self, bitmap, source, bitmap_src)
  if not bitmap or #bitmap < BCN_SEEN_BITMAP_BYTES then return 0, 0 end
  local n = 0
  local refreshed = 0
  for dest_id = 0, 254 do
    if dest_id ~= self.id and bitmap_get_bit(bitmap, dest_id) then
      n = n + 1
      mark_dest_seen(self, dest_id, source)
      if bitmap_src ~= nil then
        refreshed = refreshed + refresh_bitmap_candidates(self, dest_id, bitmap_src)
      end
    end
  end
  return n, refreshed
end

local function build_suspect_nodes_ext(node)
  if node.peer_suspect_bcn_max == 0 then return nil, 0 end
  local now = node:now()
  local max_ids = math.min(node.peer_suspect_bcn_max or 8, 15)
  local records = {}
  local seen = {}
  local function add_from(tbl, state)
    for node_id, until_ms in pairs(tbl or {}) do
      if node_id ~= node.id and node_id >= 0 and node_id <= 254
         and until_ms ~= nil and until_ms > now and not seen[node_id] then
        seen[node_id] = true
        table.insert(records, { node_id = node_id, state = state })
      end
    end
  end
  -- Only locally observed RTS silence is advertised. Remote suspect TLVs are
  -- applied to local routing but are not re-gossiped, otherwise one stale peer
  -- can create a beacon storm.
  add_from(node.peer_dead_advertise_until, PEER_LEVEL_DEAD)
  add_from(node.peer_suspect_advertise_until, PEER_LEVEL_SILENT)
  if #records == 0 then return nil, 0 end
  table.sort(records, function(a, b)
    if a.state ~= b.state then return a.state > b.state end
    return a.node_id < b.node_id
  end)
  while #records > max_ids do table.remove(records) end
  local payload = {}
  local any_dead = false
  for _, r in ipairs(records) do
    if r.state >= PEER_LEVEL_DEAD then any_dead = true end
  end
  if any_dead then
    for _, r in ipairs(records) do
      table.insert(payload, string.char(r.node_id))
      table.insert(payload, string.char(r.state & 0x03))
    end
    local body = table.concat(payload)
    return string.char((BCN_EXT_TYPE_LIVENESS_STATE << 4) | (#body & 0x0f)) .. body,
           #records
  end
  for _, r in ipairs(records) do
    table.insert(payload, string.char(r.node_id))
  end
  local body = table.concat(payload)
  return string.char((BCN_EXT_TYPE_SUSPECT_NODES << 4) | (#body & 0x0f)) .. body,
         #records
end

-- ROADMAP §3 channel digest TLV.
-- Picks up to channel_dirty_max_per_bcn dirty IDs (most-recently-received
-- first) and emits ONE TLV: count(1B) + ID(4B) × N. Body ≤ 13 bytes
-- (1 + 3×4) which fits the 4-bit length field. Returns (tlv_bytes, count)
-- or (nil, 0) when no dirty IDs to advertise.
function build_channel_digest_ext(node)
  if not node.channel_buffer or #node.channel_buffer == 0 then return nil, 0 end
  local max_ids = math.min(node.channel_dirty_max_per_bcn or 3, 3)
  if max_ids <= 0 then return nil, 0 end
  -- Walk buffer newest-first (we appended chronologically, so the tail is
  -- newest). Collect up to max_ids entries with `dirty == true`.
  local picked = {}
  local picked_entries = {}
  for i = #node.channel_buffer, 1, -1 do
    local e = node.channel_buffer[i]
    if e.dirty then
      table.insert(picked, e.id)
      table.insert(picked_entries, e)
      if #picked >= max_ids then break end
    end
  end
  if #picked == 0 then return nil, 0 end
  -- After picking, account each entry one advertisement. When the count
  -- reaches channel_dirty_max_advertisements (K=3 by default) the entry
  -- retires from advertising: dirty cleared, no longer included in our
  -- BCN digest. The entry stays in the buffer so we can still RESPOND
  -- to incoming Q_CHANNEL_PULL requests, but other holders (who have
  -- the same msg with their own dirty bit) carry the gossip forward.
  -- This is the s12 secondary-holder load-bounding fix; see the
  -- channel_dirty_max_advertisements constant in PROTOCOL for full
  -- background.
  --
  -- A note on accuracy: this fires from inside pack_beacon, so a BCN
  -- that's built but then deferred at the radio level (duty cycle,
  -- channel busy) still increments the count. That's a small
  -- overcount — but the alternative (post-tx callback) would require
  -- threading the entry list through to the tx-complete handler. We
  -- accept the small inaccuracy.
  local k_max = node.channel_dirty_max_advertisements or 3
  for _, e in ipairs(picked_entries) do
    e.bcn_ad_count = (e.bcn_ad_count or 0) + 1
    if e.bcn_ad_count >= k_max then
      e.dirty = false
      if debug_emit_allowed(node) then
        node:emit("channel_dirty_cleared", {
          id = e.id, channel_id = e.channel_id,
          ad_count = e.bcn_ad_count, threshold = k_max,
        })
      end
    end
  end
  local body = string.char(#picked & 0xff)
  for _, id in ipairs(picked) do
    body = body .. channel_msg_id_to_bytes(id)
  end
  return string.char((BCN_EXT_TYPE_CHANNEL_DIGEST << 4) | (#body & 0x0f)) .. body,
         #picked
end

-- Cross-layer routing TLV: prune aged entries in self.bridged_layers.
-- Called at pack time and before select_gateway_for_layer reads.
-- See PROTOCOL §3.1 type 4 (gateway_layer) for the lifetime contract.
function prune_aged_bridged_layers(self, now)
  if self.bridged_layers == nil then return end
  local ttl = self.gateway_bridged_layers_ttl_ms or 0
  if ttl <= 0 then return end
  local stale = {}
  for gw_id, rec in pairs(self.bridged_layers) do
    if rec ~= nil and rec.last_seen_ms ~= nil
       and (now - rec.last_seen_ms) > ttl then
      table.insert(stale, {gw_id = gw_id,
                          dest_layer = rec.dest_layer,
                          age_ms = now - rec.last_seen_ms})
    end
  end
  for _, s in ipairs(stale) do
    self.bridged_layers[s.gw_id] = nil
    if debug_emit_allowed(self) then
      self:emit("bridged_layers_aged", {
        gw_id = s.gw_id, dest_layer = s.dest_layer,
        age_ms = s.age_ms, ttl_ms = ttl,
      })
    end
  end
end

-- Build the BCN_EXT_TYPE_GATEWAY_LAYER (type=4) TLV. Combines:
--   - self-advertisement (gateways only): one entry per visit layer,
--     where dest_layer is the "other" layer relative to active_leaf
--   - propagated entries from self.bridged_layers (anyone who's
--     observed cross-layer info, including non-gateways)
-- Returns (tlv_bytes, count) or (nil, 0) if nothing to advertise.
function build_gateway_layer_ext(node)
  local now = node:now()
  prune_aged_bridged_layers(node, now)
  local active_leaf = (node.active_leaf_id or node.leaf_id or 0) & 0xf
  local seen_in_tlv = {}    -- spec invariant: each gw_id at most once
  local entries = {}
  -- Self-advertisement for gateways.
  if node.self_gateway and node.gateway_layer_list ~= nil then
    local home_leaf = (node.layer_id or 0) & 0xf
    for _, visit_layer in ipairs(node.gateway_layer_list) do
      local visit_leaf = visit_layer & 0xf
      local dest_layer = nil
      if active_leaf == home_leaf then
        dest_layer = visit_leaf
      elseif active_leaf == visit_leaf then
        dest_layer = home_leaf
      end
      if dest_layer ~= nil and dest_layer ~= active_leaf
         and not seen_in_tlv[node.id] then
        seen_in_tlv[node.id] = true
        table.insert(entries, {
          gw_id = node.id, dest_layer = dest_layer,
          last_seen_ms = now,
        })
      end
    end
  end
  -- Propagated entries from re-gossip. Skip dest_layer == active_leaf
  -- (would advertise the receiver's own layer — useless).
  if node.bridged_layers ~= nil then
    for gw_id, rec in pairs(node.bridged_layers) do
      if rec ~= nil and rec.dest_layer ~= nil
         and not seen_in_tlv[gw_id]
         and rec.dest_layer ~= active_leaf then
        seen_in_tlv[gw_id] = true
        table.insert(entries, {
          gw_id = gw_id, dest_layer = rec.dest_layer,
          last_seen_ms = rec.last_seen_ms or 0,
        })
      end
    end
  end
  if #entries == 0 then return nil, 0 end
  -- Top-K by recency. Rotation across BCN cycles can be added later
  -- if real deployments routinely exceed max_per_tlv.
  table.sort(entries, function(a, b)
    if a.last_seen_ms ~= b.last_seen_ms then
      return a.last_seen_ms > b.last_seen_ms
    end
    return a.gw_id < b.gw_id
  end)
  local max_per_tlv = node.gateway_bridged_layers_max_per_tlv or 9
  while #entries > max_per_tlv do table.remove(entries) end
  -- Pack split-list: N × gw_id(8), then ceil(N/2) bytes of packed
  -- layer nibbles. Low nibble = even index, high nibble = odd index.
  local N = #entries
  local gw_part = {}
  for i = 1, N do gw_part[i] = string.char(entries[i].gw_id & 0xff) end
  local nibble_byte_count = math.floor((N + 1) / 2)
  local nibble_bytes = {}
  for i = 1, nibble_byte_count do nibble_bytes[i] = 0 end
  for i = 0, N - 1 do
    local layer = entries[i + 1].dest_layer & 0xf
    local pos = math.floor(i / 2) + 1
    if (i % 2) == 0 then
      nibble_bytes[pos] = (nibble_bytes[pos] & 0xf0) | layer
    else
      nibble_bytes[pos] = (nibble_bytes[pos] & 0x0f) | (layer << 4)
    end
  end
  local nibble_part = {}
  for i, v in ipairs(nibble_bytes) do
    nibble_part[i] = string.char(v & 0xff)
  end
  local body = table.concat(gw_part) .. table.concat(nibble_part)
  -- 4-bit `len` caps body at 15 bytes. With max_per_tlv=9 this is
  -- 9 + 5 = 14 bytes, safely within the cap.
  if #body > 15 then return nil, 0 end
  if debug_emit_allowed(node) then
    local emit_entries = {}
    for _, e in ipairs(entries) do
      table.insert(emit_entries, {
        gw_id = e.gw_id, dest_layer = e.dest_layer,
        age_ms = math.max(0, now - (e.last_seen_ms or now)),
      })
    end
    node:emit("bridged_layers_advertised", {
      count = N, entries = emit_entries,
    })
  end
  return string.char((BCN_EXT_TYPE_GATEWAY_LAYER << 4) | (#body & 0x0f)) .. body,
         N
end

local function pack_beacon_byte1(node)
  local leaf_id = node.active_leaf_id or node.leaf_id
  local b = (leaf_id & 0xf) << 4
  if node.has_schedule  then b = b | 0x08 end
  if node.self_gateway  then b = b | 0x04 end
  if node.is_mobile     then b = b | 0x02 end
  -- bit 0 reserved (zero)
  return b
end

local function pack_schedule_record(rec, now)
  local layer_id = math.floor(rec.layer_id or rec.layer or 0) & 0x0f
  local sf = math.floor(rec.routing_sf or rec.sf or 7)
  local duration_100ms = math.floor((rec.duration_ms or 0) / 100)
  if duration_100ms < 1 then duration_100ms = 1 end
  if duration_100ms > 255 then duration_100ms = 255 end
  local period_ms = math.floor(rec.period_ms or 0)
  -- Byte 2 is a LIVE countdown: ms from this beacon's send time until the next
  -- foreign-layer window opens -- NOT a static boot offset. Receivers anchor it
  -- to their own BCN-receive time, so neither side needs a shared wall clock
  -- (boot jitter would otherwise desync sender prediction from gateway reality).
  -- Falls back to the configured offset before the first window is scheduled.
  local countdown_ms
  if rec.next_visit_ms ~= nil and now ~= nil and period_ms > 0 then
    countdown_ms = (rec.next_visit_ms - now) % period_ms
  else
    countdown_ms = rec.offset_ms or 0
  end
  local offset_100ms = math.floor(countdown_ms / 100)
  if offset_100ms < 0 then offset_100ms = 0 end
  if offset_100ms > 255 then offset_100ms = 255 end
  -- Period uses seconds for short cadences, and the low bit switches byte 3
  -- to 5-second units for production multi-minute sweeps.
  local period_unit_5s = 0
  local period_units = math.floor((period_ms + 999) / 1000)
  if period_units > 255 then
    period_unit_5s = 1
    period_units = math.floor((period_ms + 4999) / 5000)
  end
  if period_units < 1 then period_units = 1 end
  if period_units > 255 then period_units = 255 end
  local b0 = ((layer_id & 0x0f) << 4) | (((sf - 5) & 0x07) << 1) | period_unit_5s
  return string.char(b0, duration_100ms & 0xff, offset_100ms & 0xff, period_units & 0xff)
end

local function pack_schedule_block(node)
  if not node.self_gateway or not node.gateway_schedule_records then return "" end
  local now = node:now()
  local records = {}
  for _, rec in ipairs(node.gateway_schedule_records) do
    table.insert(records, pack_schedule_record(rec, now))
  end
  if #records == 0 then return "" end
  return string.char(#records & 0xff) .. table.concat(records)
end

local function pack_beacon_u32_le(v)
  v = math.floor(v or 0) & 0xffffffff
  return string.char(v & 0xff,
                     (v >> 8) & 0xff,
                     (v >> 16) & 0xff,
                     (v >> 24) & 0xff)
end

local function parse_beacon_u32_le(frame, off)
  return (frame:byte(off)
          | (frame:byte(off + 1) << 8)
          | (frame:byte(off + 2) << 16)
          | (frame:byte(off + 3) << 24)) & 0xffffffff
end

local function pack_beacon(node, max_entries, offset, dirty_only)
  max_entries = math.min(max_entries, BCN_N_ENTRIES_MASK)
  local all_dests = {}
  if not node.is_mobile then
    for dest_id, _ in pairs(node.rt) do
      table.insert(all_dests, dest_id)
    end
  end
  table.sort(all_dests)
  local byte1 = pack_beacon_byte1(node)
  local seen_bitmap = nil
  local seen_bits = 0
  if node.seen_bitmap_enabled and not node.is_mobile then
    seen_bitmap, seen_bits = build_seen_bitmap(node)
  end
  local ext_payload, suspect_bits = nil, 0
  if not node.is_mobile then
    ext_payload, suspect_bits = build_suspect_nodes_ext(node)
  end
  -- ROADMAP §3: append channel digest as an additional TLV in the ext
  -- block. Multiple TLVs are supported by the parser already.
  local channel_digest_tlv, channel_dirty_n = build_channel_digest_ext(node)
  if channel_digest_tlv then
    ext_payload = (ext_payload or "") .. channel_digest_tlv
  end
  -- PROTOCOL §3.1 type 4: gateway_layer TLV. Propagates per-gateway
  -- cross-layer routing hints so multi-hop nodes can pick the right
  -- gateway for send_layer.
  local gw_layer_tlv, gw_layer_n = build_gateway_layer_ext(node)
  if gw_layer_tlv then
    ext_payload = (ext_payload or "") .. gw_layer_tlv
  end
  local header = "B"
                 .. string.char(byte1)
                 .. string.char(node.id)
                 .. string.char(0)
                 .. pack_beacon_u32_le(node.key_hash32 or 0)
  local schedule_block = pack_schedule_block(node)
  local total = #all_dests
  if total == 0 then
    local n_byte = seen_bitmap and BCN_N_HAS_SEEN_BITMAP or 0
    if ext_payload then n_byte = n_byte | BCN_N_HAS_EXT end
    header = header:sub(1, 3) .. string.char(n_byte) .. header:sub(5)
    return header
           .. schedule_block
           .. (seen_bitmap or "")
           .. (ext_payload and (string.char(#ext_payload) .. ext_payload) or ""),
           0,
           {
             dirty_n = 0, stable_n = 0, total_dirty = 0,
             n_entries = 0, seen_bits = seen_bits,
             suspect_nodes = suspect_bits or 0,
             ext_len = ext_payload and #ext_payload or 0,
           }
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
  -- Normal dirty-only BCNs deliberately skip this phase: route changes travel
  -- as dirty entries, while the destination-seen bitmap refreshes existing
  -- same-next-hop candidates without paying full route-page airtime.
  local stable_page = {}
  local remaining = max_entries - dirty_n
  local new_offset = offset
  if remaining > 0 and not dirty_only then
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
  local n_byte = n_total & BCN_N_ENTRIES_MASK
  if seen_bitmap then n_byte = n_byte | BCN_N_HAS_SEEN_BITMAP end
  if ext_payload then n_byte = n_byte | BCN_N_HAS_EXT end
  local out = "B" .. string.char(byte1) .. string.char(node.id) .. string.char(n_byte)
              .. pack_beacon_u32_le(node.key_hash32 or 0)
              .. schedule_block
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
  if seen_bitmap then out = out .. seen_bitmap end
  if ext_payload then out = out .. string.char(#ext_payload) .. ext_payload end

  -- Clear dirty for routes that landed in this beacon (those that overflowed
  -- stay dirty for the next one).
  for i = 1, dirty_n do
    node.rt[dirty_in_order[i]].dirty = nil
  end

  return out, new_offset, {
    dirty_n     = dirty_n,
    stable_n    = stable_n,
    total_dirty = total_dirty,
    n_entries   = n_total,
    seen_bits   = seen_bits,
    suspect_nodes = suspect_bits or 0,
    ext_len     = ext_payload and #ext_payload or 0,
    dirty_only   = dirty_only == true,
  }
end

local function parse_beacon(frame)
  if #frame < 8 or frame:sub(1,1) ~= "B" then return nil end
  local b1  = frame:byte(2)
  local out = {
    leaf_id      = (b1 >> 4) & 0xf,
    has_schedule = (b1 & 0x08) ~= 0,
    self_gateway = (b1 & 0x04) ~= 0,
    is_mobile    = (b1 & 0x02) ~= 0,
    src          = frame:byte(3),
    key_hash32   = parse_beacon_u32_le(frame, 5),
    entries      = {},
  }
  local n_byte = frame:byte(4)
  local has_seen_bitmap = (n_byte & BCN_N_HAS_SEEN_BITMAP) ~= 0
  local has_ext = (n_byte & BCN_N_HAS_EXT) ~= 0
  local n   = n_byte & BCN_N_ENTRIES_MASK
  out.has_seen_bitmap = has_seen_bitmap
  out.has_ext = has_ext
  local pos = 9               -- next byte after fixed key_hash32
  if out.has_schedule then
    if #frame < pos then return nil end           -- need at least the layer_count byte
    local layer_count = frame:byte(pos)
    pos = pos + 1
    out.schedule = {}
    if #frame < pos - 1 + layer_count * 4 then return nil end
    for _ = 1, layer_count do
      local b0 = frame:byte(pos)
      local period_unit_5s = b0 & 0x01
      local period_unit_ms = (period_unit_5s ~= 0) and 5000 or 1000
      table.insert(out.schedule, {
	        layer_id = (b0 >> 4) & 0x0f,
	        routing_sf = ((b0 >> 1) & 0x07) + 5,
	        duration_ms = frame:byte(pos + 1) * 100,
	        offset_ms = frame:byte(pos + 2) * 100,
	        period_ms = frame:byte(pos + 3) * period_unit_ms,
	        period_unit_ms = period_unit_ms,
	      })
      pos = pos + 4
    end
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
  if has_seen_bitmap then
    if #frame < pos - 1 + BCN_SEEN_BITMAP_BYTES then return nil end
    out.seen_bitmap = frame:sub(pos, pos + BCN_SEEN_BITMAP_BYTES - 1)
    out.seen_bits = bitmap_count_bits(out.seen_bitmap)
    pos = pos + BCN_SEEN_BITMAP_BYTES
  end
  if has_ext then
    if #frame < pos then return nil end
    local ext_len = frame:byte(pos)
    pos = pos + 1
    local ext_end = pos + ext_len - 1
    if #frame < ext_end then return nil end
    while pos <= ext_end do
      local tl = frame:byte(pos)
      pos = pos + 1
      local typ = (tl >> 4) & 0x0f
      local len = tl & 0x0f
      if pos + len - 1 > ext_end then return nil end
      if typ == BCN_EXT_TYPE_SUSPECT_NODES then
        out.suspect_nodes = out.suspect_nodes or {}
        for i = 0, len - 1 do
          table.insert(out.suspect_nodes, frame:byte(pos + i))
        end
      elseif typ == BCN_EXT_TYPE_LIVENESS_STATE then
        if (len % 2) ~= 0 then return nil end
        out.liveness_states = out.liveness_states or {}
        local i = 0
        while i < len do
          table.insert(out.liveness_states, {
            node = frame:byte(pos + i),
            state = frame:byte(pos + i + 1) & 0x03,
          })
          i = i + 2
        end
      elseif typ == BCN_EXT_TYPE_CHANNEL_DIGEST then
        -- ROADMAP §3: count(1B) + ID(4B) × N. count must match (len - 1)/4.
        if len < 1 then return nil end
        local count = frame:byte(pos) & 0xff
        if len ~= 1 + count * 4 then return nil end
        out.channel_digest_ids = out.channel_digest_ids or {}
        local i = 0
        while i < count do
          local id = channel_msg_id_from_bytes(frame, pos + 1 + i * 4)
          table.insert(out.channel_digest_ids, id)
          i = i + 1
        end
      elseif typ == BCN_EXT_TYPE_GATEWAY_LAYER then
        -- PROTOCOL §3.1 type 4: split-list, N × gw_id(8) then N ×
        -- dest_layer(4) packed 2 nibbles per byte. N inferred from
        -- len as (2 * len) // 3. Valid lens: 2,3,5,6,8,9,11,12,14.
        local N = (2 * len) // 3
        if N <= 0 then return nil end
        if N + math.floor((N + 1) / 2) ~= len then return nil end
        out.gateway_layer_entries = out.gateway_layer_entries or {}
        local seen_gw = {}      -- enforce "each gw_id at most once"
        local ok = true
        for i = 0, N - 1 do
          local gw_id = frame:byte(pos + i)
          local b = frame:byte(pos + N + math.floor(i / 2))
          local nibble = (i % 2 == 0) and (b & 0xf) or ((b >> 4) & 0xf)
          if seen_gw[gw_id] then ok = false; break end
          seen_gw[gw_id] = true
          table.insert(out.gateway_layer_entries, {
            gw_id = gw_id, dest_layer = nibble,
          })
        end
        if not ok then
          -- Malformed (duplicate gw_id) — discard this TLV entirely.
          out.gateway_layer_entries = nil
        end
      end
      pos = pos + len
    end
  end
  if pos <= #frame then
    return nil
  end
  return out
end

-- Update a per-neighbor SNR EWMA in-place. First sample seeds the EWMA
-- (no warmup ramp); subsequent samples blend with `alpha`. Default alpha
-- 0.3 → Q4 5 → ~10-sample effective window. Storage is Q4; pass Q4 in.
local function update_snr_ewma(table_, nbr_id, snr_q4, alpha_q4)
  if snr_q4 == nil then return end
  local prev = table_[nbr_id]
  if prev == nil then
    table_[nbr_id] = snr_q4
  else
    table_[nbr_id] = q4_ewma(prev, snr_q4, alpha_q4)
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
-- RTS byte 6 layout: [ctr_lo(4) | flags(4)]. The low nibble was reserved
-- pre-2B. RTS_FLAG_M_BROADCAST tells non-target receivers "this DATA is
-- M-payload — arm an overhear retune to the receiver-picked chosen_data_sf".
-- ROADMAP §3.3 pathology #4, the "2B" approach.
RTS_FLAG_M_BROADCAST = 0x01
-- RTS_FLAG_RELAY marks a gateway cross-layer FORWARD (PROTOCOL §3.7/§10a). On
-- the target layer a gateway re-injects with origin=self and no preceding CTS
-- (its inbound arrived on another layer), so the §10a R−C anti-spam metric
-- mis-reads it as a runaway originator and throttles legitimate relays. This
-- flag is set ONLY by enqueue_gateway_handoff forwards; receivers skip the
-- originator throttle for flagged RTS. A gateway's OWN originations carry no
-- flag and are throttled normally.
RTS_FLAG_RELAY = 0x02

local function pack_rts(leaf_id, src, dst, next_hop, ctr_lo, sf_bitmap, payload_len, rts_flags, m_payload_id)
  local addr_len = 0
  local b3 = ((addr_len & 0x07) << 5) | (leaf_id & 0x0f)
  local b5 = ((ctr_lo & 0x0f) << 4) | ((rts_flags or 0) & 0x0f)
  local base = "R" .. string.char(src)
                   .. string.char(next_hop)
                   .. string.char(b3)
                   .. string.char(dst)
                   .. string.char(b5)
                   .. string.char(sf_bitmap)
                   .. string.char(payload_len % 256)
  -- Extension: when M_BROADCAST flag is set, append the low 16 bits of
  -- the channel msg id (2 bytes BE). Receivers use this to check their
  -- channel buffer BEFORE retuning to chosen_data_sf — if they already
  -- have a msg with matching id_lo16 they skip the arm entirely,
  -- saving ~2 s of routing-SF blindness. id_lo16 collision space is
  -- 65 k; simultaneously-active msgs in any realistic scenario are
  -- well under that, so false-positive skips are negligible.
  -- Worst case false positive: receiver wrongly assumes it has the
  -- msg and skips, doesn't decode — cascade recovery via other
  -- holders kicks in.
  if ((rts_flags or 0) & RTS_FLAG_M_BROADCAST) ~= 0 and m_payload_id ~= nil then
    local id_lo16 = m_payload_id & 0xFFFF
    base = base .. string.char((id_lo16 >> 8) & 0xff) .. string.char(id_lo16 & 0xff)
  end
  return base
end

local function parse_rts(frame)
  if #frame < 8 or frame:sub(1,1) ~= "R" then return nil end
  local b3 = frame:byte(4)
  local addr_len = (b3 >> 5) & 0x07
  if addr_len ~= 0 then return nil end          -- hierarchy support deferred
  local leaf_id = b3 & 0x0f
  local b5 = frame:byte(6)
  local out = {
    leaf_id      = leaf_id,
    src          = frame:byte(2),
    next         = frame:byte(3),
    dst          = frame:byte(5),
    ctr_lo       = (b5 >> 4) & 0x0f,
    rts_flags    = b5 & 0x0f,
    m_broadcast  = (b5 & RTS_FLAG_M_BROADCAST) ~= 0,
    relay        = (b5 & RTS_FLAG_RELAY) ~= 0,
    sf_bitmap    = frame:byte(7),
    payload_len  = frame:byte(8),
  }
  if out.m_broadcast and #frame >= 10 then
    -- 2-byte id_lo16 BE
    out.m_payload_id_lo16 = (frame:byte(9) << 8) | frame:byte(10)
  end
  return out
end

-- CTS — 3 bytes, addressed response:
--   byte 0 : tag 'C'
--   byte 1 : ctr_lo (4 hi nibble) | (chosen_data_sf - 5) (3) | already_received (1)
--   byte 2 : intended requester id
local function pack_cts(ctr_lo, chosen_data_sf, already_received, to_id)
  local sf_off = (chosen_data_sf - 5) & 0x7
  local ack_bit = already_received and 1 or 0
  local b1 = ((ctr_lo & 0xf) << 4) | (sf_off << 1) | ack_bit
  return "C" .. string.char(b1) .. string.char(to_id or 255)
end

local function parse_cts(frame)
  if #frame < 3 or frame:sub(1,1) ~= "C" then return nil end
  local b1 = frame:byte(2)
  return {
    ctr_lo         = (b1 >> 4) & 0xf,
    chosen_data_sf = ((b1 >> 1) & 0x7) + 5,
    already_received = (b1 & 0x1) ~= 0,
    to             = frame:byte(3),
  }
end

-- ACK — 3 bytes, addressed response:
--   byte 0 : tag 'K'
--   byte 1 : ctr_lo (4 hi) | budget_hint (2) | snr_bucket_coarse (2 lo)
--   byte 2 : intended previous-hop id
-- snr_q4 is Q4 SNR (1/16 dB) of the DATA leg as measured by the receiver.
local function pack_ack(ctr_lo, snr_q4, budget_hint, to_id)
  local bucket = bucket_of_snr_2b(snr_q4)
  local hint = budget_hint or 0
  if hint < 0 then hint = 0 end
  if hint > 3 then hint = 3 end
  local b1 = ((ctr_lo & 0xf) << 4) | ((hint & 0x3) << 2) | (bucket & 0x3)
  return "K" .. string.char(b1) .. string.char(to_id or 255)
end

local function parse_ack(frame)
  if #frame < 3 or frame:sub(1,1) ~= "K" then return nil end
  local b1 = frame:byte(2)
  local bucket = b1 & 0x3
  return {
    ctr_lo            = (b1 >> 4) & 0xf,
    budget_hint       = (b1 >> 2) & 0x3,
    snr_q4            = snr_of_bucket_2b(bucket),   -- Q4 (1/16 dB)
    snr_bucket        = bucket,
    snr_bucket_coarse = bucket,
    to                = frame:byte(3),
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
-- counters land with §8), and the (origin, dst, ctr) key used by
-- seen_origins dedup. CTS/ACK/NACK echo only the LOW NIBBLE (ctr_lo =
-- ctr & 0xf) for hop-level matching.
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
local DATA_FLAG_E2E_ACK_REQ    = 0x08   -- bit 3 of byte 1 (E2E_ACK_REQ)
local DATA_FLAG_E2E_IS_ACK     = 0x04   -- bit 2 of byte 1 (E2E_IS_ACK)
local DATA_FLAG_PRIORITY       = 0x02   -- bit 1 of byte 1 (PRIORITY — urgency; was IS_MULTICAST before §3 redesign)
DATA_FLAG_PAYLOAD_TYPE_M = 0x01   -- bit 0 of byte 1 (channel gossip msg; §3.4.1 layout)

-- ROADMAP §3 channel flavor byte (inside the M payload). Globals to
-- stay under the 200-locals-per-main-function limit.
CHANNEL_FLAVOR_PUBLIC  = 0   -- plaintext body
CHANNEL_FLAVOR_GROUP   = 1   -- ChaCha20 + MAC (crypto layered later)
CHANNEL_FLAVOR_PRIVATE = 2   -- ChaCha20 + Ed25519 (crypto layered later)

-- Global channel message ID layout (4 bytes, big-endian):
--   bits 31..24 : origin node_id (8 bits)
--   bits 23..8  : key_hash32 low 16 bits (mitigates id-recycle collisions)
--   bits  7..0  : ctr low 8 bits
-- See ROADMAP §3 "Message ID format" + weak-spot #3 for collision-risk
-- analysis. Acceptable for real-world network lifetimes.
function channel_msg_id(origin_id, key_hash32, ctr)
  return (((origin_id or 0) & 0xff)     << 24)
       | ((((key_hash32 or 0) & 0xffff)) << 8)
       | ((ctr or 0) & 0xff)
end

function channel_msg_id_to_bytes(id)
  return string.char((id >> 24) & 0xff)
       .. string.char((id >> 16) & 0xff)
       .. string.char((id >>  8) & 0xff)
       .. string.char( id        & 0xff)
end

function channel_msg_id_from_bytes(s, off)
  return ((s:byte(off    ) & 0xff) << 24)
       | ((s:byte(off + 1) & 0xff) << 16)
       | ((s:byte(off + 2) & 0xff) <<  8)
       |  (s:byte(off + 3) & 0xff)
end
local MAC_LEN = 4                    -- 4-byte zero MAC placeholder until §8 crypto lands
local GW_ENV_MAGIC = "\31G1"         -- gateway DATA envelope v1: magic + layer + key_hash32 + body
-- Hash-bind response body magic (PROTOCOL §3.7a). A resolver answering an
-- 'H' flood query sends a routed DATA back to the gateway whose body starts
-- with this magic, then target_layer(8) | node_id(8) | key_hash32(4 LE).
-- The DATA flag field is full (4 bits, all used) so we identify the response
-- by body magic — same pattern as GW_ENV_MAGIC, not a new flag bit.
-- Global (no `local`) to stay under the 200-locals-per-chunk Lua limit.
HASH_BIND_MAGIC = "\31H1"

local function seen_origin_key(origin_id, dst_id, ctr)
  return string.format("%d|%d|%d", origin_id or -1, dst_id or -1, ctr or -1)
end

local function pending_e2e_key(dst_id, ctr)
  return string.format("%d|%d", dst_id or -1, ctr or -1)
end

local function last_acked_key(sender_id, dst_id, ctr_lo, payload_len)
  return string.format("%d|%d|%d|%d",
    sender_id or -1, dst_id or -1, ctr_lo or -1, payload_len or -1)
end

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
--   NACK_REASON_HOP_BUDGET (2): the DATA flight's hop_budget was
--     exhausted at the forwarder before reaching destination (§7.6).
--     The flight is dead; originator needs to learn rt[dst] was too
--     short and possibly trigger Q-frame re-discovery.
--     payload = committed_hops(4 hi) | reserved(4 lo)
--     committed_hops 0..15 — how many hops the flight already walked.
--   NACK_REASON_LOOP_DUP (3): DATA was decoded, but this receiver has
--     already seen the same (origin,dst,ctr) from a different previous hop.
--     That means the packet looped back through the mesh; upstream should
--     try a different candidate rather than treating the hop as successful.
--     payload = prior previous-hop id, or 255 if unknown.
--
-- Shrunk from 4→3 bytes per ROADMAP §7.0.5. busy_for_ms quantum = 16 ms
-- (well below the 50 ms natural retry-jitter floor). Max range 4080 ms
-- covers SF12 worst-case with 4× headroom.
local NACK_REASON_BUSY_RX    = 0
local NACK_REASON_BUDGET     = 1
local NACK_REASON_HOP_BUDGET = 2   -- §7.6: flight exceeded hop budget
local NACK_REASON_LOOP_DUP   = 3   -- looped duplicate from another previous hop

local NACK_BUSY_QUANTUM_MS = 16   -- granularity of BUSY_RX payload

-- NACK — 4 bytes, addressed response:
--   byte 0 : tag 'N'
--   byte 1 : reason (4 hi) | ctr_lo (4 lo)
--   byte 2 : payload (reason-specific)
--   byte 3 : intended requester/upstream id
--             BUSY_RX:    busy_for_ms / 16  (0..4080 ms, 16 ms granularity)
--             BUDGET:     tier (4 hi) | headroom_buckets (4 lo)
--             HOP_BUDGET: committed_hops (4 hi) | reserved (4 lo)
--             LOOP_DUP:   prior previous-hop id (or 255)
local function pack_nack(ctr_lo, reason, payload, to_id)
  reason  = reason or NACK_REASON_BUSY_RX
  payload = payload or 0
  if payload < 0 then payload = 0 elseif payload > 255 then payload = 255 end
  local byte1 = ((reason & 0xf) << 4) | (ctr_lo & 0xf)
  return "N" .. string.char(byte1) .. string.char(payload) .. string.char(to_id or 255)
end

local function parse_nack(frame)
  if #frame < 4 or frame:sub(1,1) ~= "N" then return nil end
  local b1 = frame:byte(2)
  local payload = frame:byte(3)
  local reason = (b1 >> 4) & 0xf
  local out = {
    reason  = reason,
    ctr_lo  = b1 & 0xf,
    payload = payload,
    to      = frame:byte(4),
  }
  if reason == NACK_REASON_BUSY_RX then
    out.busy_for_ms = payload * NACK_BUSY_QUANTUM_MS
  elseif reason == NACK_REASON_BUDGET then
    out.budget_tier             = (payload >> 4) & 0xf
    out.budget_headroom_buckets = payload & 0xf
  elseif reason == NACK_REASON_HOP_BUDGET then
    out.committed_hops = (payload >> 4) & 0xf
  elseif reason == NACK_REASON_LOOP_DUP then
    out.prior_from = payload
  end
  return out
end

-- Opcode 0 was Q_OP_ROUTE_QUERY; the 1-hop route query was replaced by the
-- multi-hop 'R' RREQ/RREP flood frame (PROTOCOL §3.7b). Opcode 0 is now
-- free/reserved.
-- Opcode 2 was Q_OP_HASH_QUERY; the 1-hop hash query was replaced by the
-- multi-hop 'H' flood frame (PROTOCOL §3.7a). Opcode 2 is now free/reserved.
local Q_OP_REQ_SYNC     = 1
-- ROADMAP §3 channel gossip pull. Body: count(1B) + ID(4B) × N. Sent
-- unicast (Q `dest` = target neighbour we want to pull from). The 2-bit
-- opcode field has values 0,1,3 used and 2 free; a future opcode can
-- reclaim 2 or use a sub-code escape inside the body.
Q_OP_CHANNEL_PULL = 3   -- global (200-locals limit)
local Q_FLAG_MOBILE    = 0x04

-- Q — query/control:
--   byte 0 : tag 'Q'
--   byte 1 : src (8) — the requester
--   byte 2 : dest (8) — route target for ROUTE_QUERY; 0xff for REQ_SYNC/HASH_QUERY
--   byte 3 : leaf_id (4 hi) | requester flags (4 lo)
--            low bits 0..1: opcode (0=ROUTE_QUERY, 1=REQ_SYNC, 2=HASH_QUERY)
--            low bit 2: requester is mobile
--            low bit 3: reserved
--   bytes 4..7 : key_hash32 (LE), only for HASH_QUERY
--
-- ROUTE_QUERY is the legacy one-hop route query. Direct neighbours that
-- have rt[dest] mark it dirty + schedule a triggered beacon. REQ_SYNC is
-- a new-node/bootstrap request: eligible neighbours back off, suppress if
-- another useful BCN is heard first, then send a full sync BCN. HASH_QUERY
-- asks for the node whose identity hash is known but whose short ID/binding
-- is not yet known locally (gateway handoff discovery).
function q_pack_u32_le(v)
  v = v or 0
  return string.char(v & 0xff, (v >> 8) & 0xff,
                     (v >> 16) & 0xff, (v >> 24) & 0xff)
end

function q_parse_u32_le(frame, off)
  return (frame:byte(off) or 0)
       | ((frame:byte(off + 1) or 0) << 8)
       | ((frame:byte(off + 2) or 0) << 16)
       | ((frame:byte(off + 3) or 0) << 24)
end

local function pack_q(leaf_id, src, dest, opcode, requester_is_mobile)
  local flags = (opcode or 0) & 0x03
  if requester_is_mobile then flags = flags | Q_FLAG_MOBILE end
  local b3 = ((leaf_id & 0xf) << 4) | (flags & 0x0f)
  return "Q" .. string.char(src) .. string.char(dest) .. string.char(b3)
end

-- ROADMAP §3 channel-pull request. Frame: 4-byte Q header + count(1B) + ID(4B) × N.
-- dest = node we want to pull from (unicast). ids is a Lua array of 32-bit IDs.
function pack_q_channel_pull(leaf_id, src, target, ids, requester_is_mobile)
  local body = string.char(#ids & 0xff)
  for _, id in ipairs(ids) do
    body = body .. channel_msg_id_to_bytes(id)
  end
  return pack_q(leaf_id, src, target, Q_OP_CHANNEL_PULL, requester_is_mobile) .. body
end

local function parse_q(frame)
  if #frame < 4 or frame:sub(1,1) ~= "Q" then return nil end
  local flags = frame:byte(4) & 0x0f
  local out = {
    src                 = frame:byte(2),
    dest                = frame:byte(3),
    leaf_id             = (frame:byte(4) >> 4) & 0xf,
    opcode              = flags & 0x03,
    requester_is_mobile = (flags & Q_FLAG_MOBILE) ~= 0,
  }
  if out.opcode == Q_OP_CHANNEL_PULL then
    if #frame < 5 then return nil end
    local count = frame:byte(5) & 0xff
    if #frame < 5 + count * 4 then return nil end
    out.channel_ids = {}
    for i = 0, count - 1 do
      table.insert(out.channel_ids, channel_msg_id_from_bytes(frame, 6 + i * 4))
    end
  end
  return out
end

-- 'H' — multi-hop hash-locate flood query (PROTOCOL §3.7a).
--   byte 0 : tag 'H'
--   byte 1 : origin (8) — the querying gateway's node_id; PRESERVED across
--            forwards so the resolver can route the binding response home
--   byte 2 : leaf_id(4 hi) | flags(4 lo) — target layer nibble; flags rsv
--   bytes 3..6 : key_hash32 (LE) — identity hash to resolve
--   byte 7 : ttl — decremented per forward; dropped at 0
-- Unlike Q (strictly 1-hop), 'H' is the one forwardable control frame.
function pack_h_query(origin, leaf_id, key_hash32, ttl)
  local b2 = ((leaf_id & 0x0f) << 4)         -- flags nibble reserved (0)
  return "H" .. string.char(origin & 0xff)
             .. string.char(b2)
             .. q_pack_u32_le(key_hash32 or 0)
             .. string.char(ttl & 0xff)
end

function parse_h_query(frame)
  if #frame < 8 or frame:sub(1,1) ~= "H" then return nil end
  return {
    origin     = frame:byte(2),
    leaf_id    = (frame:byte(3) >> 4) & 0xf,
    key_hash32 = q_parse_u32_le(frame, 4),
    ttl        = frame:byte(8),
  }
end

-- 'F' route-Find frame (PROTOCOL §3.7b) — the second forwardable control
-- frame (alongside 'H'). Same-layer AODV-style route discovery (RREQ/RREP);
-- replaces the old single-hop Q ROUTE_QUERY opcode. NOTE: wire tag is 'F',
-- not 'R' — 'R' is the RTS frame. The RREQ/RREP/route_request naming is
-- retained in code/events (AODV-standard); only the wire byte is 'F'.
--   byte 0 : tag 'F'
--   byte 1 : origin (8) — the querier's node_id; PRESERVED across forwards so
--            the RREP can be routed home along the reverse path
--   byte 2 : leaf_id(4 hi) | flags(4 lo); flags bit0 = is_reply (0=RREQ,1=RREP)
--   byte 3 : dst_id (8) — the destination being sought
--   byte 4 : RREQ → ttl (decremented per forward, dropped at 0)
--            RREP → next_hop (8) — addressed forward target toward origin
--   byte 5 : hops (8) — RREQ: hops-from-origin (increments); RREP: hops-to-dst
function pack_r_request(origin, leaf_id, dst_id, ttl, hops)
  return "F" .. string.char(origin & 0xff)
             .. string.char((leaf_id & 0x0f) << 4)        -- flags=0 (request)
             .. string.char(dst_id & 0xff)
             .. string.char(ttl & 0xff)
             .. string.char(hops & 0xff)
end

function pack_r_reply(origin, leaf_id, dst_id, next_hop, hops)
  return "F" .. string.char(origin & 0xff)
             .. string.char(((leaf_id & 0x0f) << 4) | 0x1)  -- flags bit0=reply
             .. string.char(dst_id & 0xff)
             .. string.char(next_hop & 0xff)
             .. string.char(hops & 0xff)
end

function parse_r(frame)
  if #frame < 6 or frame:sub(1,1) ~= "F" then return nil end
  local b2 = frame:byte(3)
  return {
    origin   = frame:byte(2),
    leaf_id  = (b2 >> 4) & 0x0f,
    is_reply = (b2 & 0x1) ~= 0,
    dst_id   = frame:byte(4),
    b4       = frame:byte(5),   -- ttl (RREQ) | next_hop (RREP)
    hops     = frame:byte(6),
  }
end

-- Hash-bind response body (carried inside a routed DATA frame back to the
-- gateway). magic + target_layer(8) + node_id(8) + key_hash32(4 LE).
function pack_hash_bind_response(target_layer_id, node_id, key_hash32)
  return HASH_BIND_MAGIC
      .. string.char((target_layer_id or 0) & 0xff)
      .. string.char((node_id or 0) & 0xff)
      .. q_pack_u32_le(key_hash32 or 0)
end

function parse_hash_bind_response(body)
  if type(body) ~= "string" or #body < 9 then return nil end
  if body:sub(1, #HASH_BIND_MAGIC) ~= HASH_BIND_MAGIC then return nil end
  return {
    target_layer_id = body:byte(4),
    node_id         = body:byte(5),
    key_hash32      = q_parse_u32_le(body, 6),
  }
end

local J_OP_DISCOVER = 0
local J_OP_CLAIM    = 1
local J_OP_DENY     = 2
local J_OP_OFFER    = 3

local J_FLAG_MOBILE          = 0x04
local J_FLAG_GATEWAY_CAPABLE = 0x08

local J_DENY_REASON_CONFLICT = 1
local J_DENY_REASON_PENDING_CLAIM = 2
local J_DENY_REASON_OWN_ID_DEFENSE = 3   -- adopted-owner defends its id from a duplicate

local function pack_u16_le(v)
  v = math.floor(v or 0) & 0xffff
  return string.char(v & 0xff, (v >> 8) & 0xff)
end

local function parse_u16_le(frame, off)
  return frame:byte(off) | (frame:byte(off + 1) << 8)
end

local function pack_u32_le(v)
  v = math.floor(v or 0) & 0xffffffff
  return string.char(v & 0xff,
                     (v >> 8) & 0xff,
                     (v >> 16) & 0xff,
                     (v >> 24) & 0xff)
end

local function parse_u32_le(frame, off)
  return (frame:byte(off)
          | (frame:byte(off + 1) << 8)
          | (frame:byte(off + 2) << 16)
          | (frame:byte(off + 3) << 24)) & 0xffffffff
end

local function pack_gateway_envelope(target_layer_id, dst_key_hash32, body)
  return GW_ENV_MAGIC
      .. string.char((target_layer_id or 0) & 0xff)
      .. pack_u32_le(dst_key_hash32 or 0)
      .. (body or "")
end

local function parse_gateway_envelope(body)
  if type(body) ~= "string" or #body < 8 then return nil end
  if body:sub(1, #GW_ENV_MAGIC) ~= GW_ENV_MAGIC then return nil end
  return {
    target_layer_id = body:byte(4),
    dst_key_hash32 = parse_u32_le(body, 5),
    body = body:sub(9),
  }
end

local function pack_j_header(leaf_id, opcode, requester_is_mobile, gateway_capable)
  local flags = (opcode or J_OP_DISCOVER) & 0x03
  if requester_is_mobile then flags = flags | J_FLAG_MOBILE end
  if gateway_capable then flags = flags | J_FLAG_GATEWAY_CAPABLE end
  return ((leaf_id & 0x0f) << 4) | (flags & 0x0f)
end

-- J — join/lease control frame:
--   DISCOVER: 'J', [leaf_id|flags], key_hash32(LE)
--   OFFER:    'J', [leaf_id|flags], responder_node_id, responder_key_hash32(LE),
--             data_sf_bitmap
--   CLAIM:    'J', [leaf_id|flags], key_hash32(LE), proposed_node_id,
--             lease_age_seconds(LE), claim_epoch, nonce
--   DENY:     'J', [leaf_id|flags], denied_node_id, owner_key_hash32(LE),
--             claimant_key_hash32(LE), owner_lease_age_seconds(LE),
--             owner_claim_epoch, reason
local function pack_j_discover(leaf_id, key_hash32, requester_is_mobile, gateway_capable)
  return "J" .. string.char(pack_j_header(leaf_id, J_OP_DISCOVER,
                                          requester_is_mobile, gateway_capable))
             .. pack_u32_le(key_hash32)
end

local function pack_j_offer(leaf_id, responder_node_id, responder_key_hash32,
                            data_sf_bitmap, requester_is_mobile, gateway_capable)
  return "J" .. string.char(pack_j_header(leaf_id, J_OP_OFFER,
                                          requester_is_mobile, gateway_capable))
             .. string.char(responder_node_id & 0xff)
             .. pack_u32_le(responder_key_hash32)
             .. string.char(data_sf_bitmap & 0xff)
end

local function pack_j_claim(leaf_id, key_hash32, proposed_node_id,
                            lease_age_seconds, claim_epoch, nonce,
                            requester_is_mobile, gateway_capable)
  return "J" .. string.char(pack_j_header(leaf_id, J_OP_CLAIM,
                                          requester_is_mobile, gateway_capable))
             .. pack_u32_le(key_hash32)
             .. string.char(proposed_node_id & 0xff)
             .. pack_u16_le(lease_age_seconds)
             .. string.char((claim_epoch or 0) & 0xff, (nonce or 0) & 0xff)
end

local function pack_j_deny(leaf_id, denied_node_id, owner_key_hash32,
                           claimant_key_hash32, owner_lease_age_seconds,
                           owner_claim_epoch, reason,
                           requester_is_mobile, gateway_capable)
  return "J" .. string.char(pack_j_header(leaf_id, J_OP_DENY,
                                          requester_is_mobile, gateway_capable))
             .. string.char(denied_node_id & 0xff)
             .. pack_u32_le(owner_key_hash32)
             .. pack_u32_le(claimant_key_hash32)
             .. pack_u16_le(owner_lease_age_seconds)
             .. string.char((owner_claim_epoch or 0) & 0xff,
                            (reason or J_DENY_REASON_CONFLICT) & 0xff)
end

local function parse_j(frame)
  if #frame < 6 or frame:sub(1,1) ~= "J" then return nil end
  local h = frame:byte(2)
  local flags = h & 0x0f
  local out = {
    leaf_id             = (h >> 4) & 0x0f,
    opcode              = flags & 0x03,
    requester_is_mobile = (flags & J_FLAG_MOBILE) ~= 0,
    gateway_capable     = (flags & J_FLAG_GATEWAY_CAPABLE) ~= 0,
  }
  if out.opcode == J_OP_DISCOVER then
    if #frame ~= 6 then return nil end
    out.key_hash32 = parse_u32_le(frame, 3)
    return out
  elseif out.opcode == J_OP_OFFER then
    if #frame ~= 8 then return nil end
    out.responder_node_id = frame:byte(3)
    out.responder_key_hash32 = parse_u32_le(frame, 4)
    out.data_sf_bitmap = frame:byte(8)
    return out
  elseif out.opcode == J_OP_CLAIM then
    if #frame ~= 11 then return nil end
    out.key_hash32 = parse_u32_le(frame, 3)
    out.proposed_node_id = frame:byte(7)
    out.lease_age_seconds = parse_u16_le(frame, 8)
    out.claim_epoch = frame:byte(10)
    out.nonce = frame:byte(11)
    return out
  elseif out.opcode == J_OP_DENY then
    if #frame ~= 15 then return nil end
    out.denied_node_id = frame:byte(3)
    out.owner_key_hash32 = parse_u32_le(frame, 4)
    out.claimant_key_hash32 = parse_u32_le(frame, 8)
    out.owner_lease_age_seconds = parse_u16_le(frame, 12)
    out.owner_claim_epoch = frame:byte(14)
    out.reason = frame:byte(15)
    return out
  end
  return nil
end

function join_opcode_name(opcode)
  if opcode == J_OP_DISCOVER then return "discover" end
  if opcode == J_OP_CLAIM then return "claim" end
  if opcode == J_OP_DENY then return "deny" end
  if opcode == J_OP_OFFER then return "offer" end
  return tostring(opcode or "unknown")
end

function join_rate_limit_key(j)
  if j.opcode == J_OP_DISCOVER or j.opcode == J_OP_CLAIM then
    return j.key_hash32
  end
  return nil
end

-- NV-persistence shim. In real firmware these map to flash/EEPROM
-- read/write; in the model they map to an in-RAM table. Tests can seed
-- initial NV state via `config.nv = { claim_epoch = N, ... }`.
function nv_get(self, key, default)
  self.nv = self.nv or {}
  local v = self.nv[key]
  if v == nil then return default end
  return v
end

function nv_set(self, key, value)
  self.nv = self.nv or {}
  self.nv[key] = value
end

-- Seconds since this node adopted its current short-id. Used as
-- lease_age_seconds in J_CLAIM (own claim) and J_DENY (defender's
-- assertion). 0 means "no adoption yet" — either an unjoined node or
-- one whose adoption time is unknown. Saturates to 16-bit wire range.
function lease_age_seconds_now(self)
  if self.adopted_at_ms == nil then return 0 end
  local age = math.floor((self:now() - self.adopted_at_ms) / 1000)
  if age < 0 then age = 0 end
  if age > 65535 then age = 65535 end
  return age
end

-- Bounded-state plumbing. The C++ port will run on a Cortex-M-class MCU
-- with low-tens-of-kB RAM; any table that scales with mesh size, traffic,
-- or churn needs an explicit cap. Until the port lands these are advisory
-- — when a cap is reached we refuse the new entry and emit `table_cap_hit`
-- so pathological growth is visible in run analysis. Caps are tuned per
-- table in on_init and overridable via config.
function count_keys(t)
  if t == nil then return 0 end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- Emit + log when current_size >= cap. Returns true if at/over cap so the
-- caller can refuse the insert. `extra` is merged into the event payload
-- (typically the would-be key so the operator can see what was dropped).
function table_cap_hit(self, table_name, current_size, cap, action, extra)
  if cap <= 0 or current_size < cap then return false end
  local payload = {
    table  = table_name,
    size   = current_size,
    cap    = cap,
    action = action or "refuse",
  }
  if extra then
    for k, v in pairs(extra) do payload[k] = v end
  end
  self:emit("table_cap_hit", payload)
  self:log(string.format(
    "table_cap_hit %s size=%d cap=%d action=%s",
    table_name, current_size, cap, action or "refuse"))
  return true
end

function join_j_rate_limited(self, j, meta)
  local key_hash32 = join_rate_limit_key(j)
  if key_hash32 == nil then return false end
  local window_ms = self.join_j_rate_limit_window_ms or 0
  local max_count = self.join_j_max_per_window or 0
  if window_ms <= 0 or max_count <= 0 then return false end
  local now = self:now()
  local opcode = join_opcode_name(j.opcode)
  local key = string.format("%s|%u", opcode, key_hash32 & 0xffffffff)
  self.join_j_seen = self.join_j_seen or {}
  local seen = self.join_j_seen[key] or {}
  local kept = {}
  for _, ts in ipairs(seen) do
    if now - ts < window_ms then
      kept[#kept + 1] = ts
    end
  end
  if #kept >= max_count then
    self.join_j_seen[key] = kept
    self:emit("join_j_rate_limited", {
      from = meta and meta.src or nil,
      key_hash32 = key_hash32,
      opcode = opcode,
      count = #kept,
      window_ms = window_ms,
      max_per_window = max_count,
    })
    return true
  end
  kept[#kept + 1] = now
  self.join_j_seen[key] = kept
  return false
end

-- DATA — 12 + n bytes (in-leaf, addr_len=0); §7.6 hop-budget + rt-learning:
--   byte 0   : tag 'D'
--   byte 1   : addr_len(3 hi) | rsv(1) | E2E_ACK_REQ(1) | E2E_IS_ACK(1) | IS_MULTICAST(1) | rsv(1)
--   byte 2   : next (immediate next-hop receiver)
--   byte 3   : dst  (final destination — single byte when addr_len==0)
--   byte 4   : hop_budget byte: hops_remaining(4 hi) | committed_hops(4 lo)  (§7.6)
--   byte 5   : prev_fwd_rt_hops — previous transmitter's rt[dst].hops claim    (§7.6)
--   bytes 6-7: ctr (16-bit LE, per-(origin,dst) counter)
--   bytes 8..(7+n): ciphertext (= plaintext placeholder for now;
--                    carries src_addr_len(1) | src_addr(1) | body)
--   last 4   : MAC (4-byte zero placeholder until §8 crypto lands)
--
-- Inner payload (ciphertext slot, plaintext today):
--   byte 8   : src_addr_len (= 0 for in-leaf / flat addresses)
--   byte 9   : src_addr (origin's 8-bit mesh id; 1 byte when src_addr_len=0)
--   bytes 10+ : body (user_text for normal DATA; [acked_ctr_lo, acked_ctr_hi, ?] for E2E ACK)
local function pack_data(origin, next_hop, dst, ctr, flags, inner, hop_budget)
  -- inner = pre-assembled bytes: src_addr_len(1) | src_addr(1) | body
  -- hop_budget = optional table { remaining, committed, prev_fwd_rt_hops }
  --   remaining: hops_remaining (4 bits, 0-15); default 15 = no enforcement
  --   committed: committed_hops (4 bits, 0-15); default 0
  --   prev_fwd_rt_hops: previous fwd's claim of dst's hops (8 bits); default 0
  local addr_len = 0                                      -- in-leaf only this phase
  local byte1 = ((addr_len & 0x7) << 5) | (flags & 0x0f) -- flags: bits 0-3 (PAYLOAD_TYPE_M, PRIORITY, E2E_IS_ACK, E2E_ACK_REQ)
  local hb = hop_budget or {}
  local hb_remaining = math.min(15, math.max(0, hb.remaining or 15))
  local hb_committed = math.min(15, math.max(0, hb.committed or 0))
  local hop_budget_byte = ((hb_remaining & 0xf) << 4) | (hb_committed & 0xf)
  local prev_fwd_rt_hops = math.min(255, math.max(0, hb.prev_fwd_rt_hops or 0))
  local ctr_lo_byte = ctr & 0xff
  local ctr_hi_byte = (ctr >> 8) & 0xff
  local mac = string.rep("\0", MAC_LEN)
  return "D" .. string.char(byte1)
              .. string.char(next_hop)
              .. string.char(dst)
              .. string.char(hop_budget_byte)
              .. string.char(prev_fwd_rt_hops)
              .. string.char(ctr_lo_byte)
              .. string.char(ctr_hi_byte)
              .. inner
              .. mac
end

local function parse_data(frame)
  if #frame < 12 or frame:sub(1,1) ~= "D" then return nil end
  local b1 = frame:byte(2)
  local addr_len = (b1 >> 5) & 0x07
  if addr_len ~= 0 then return nil end        -- hierarchy deferred
  local flags    = b1 & 0x0f                  -- bits 0-3 (PAYLOAD_TYPE_M, PRIORITY, E2E_IS_ACK, E2E_ACK_REQ)
  local next_hop = frame:byte(3)
  local dst      = frame:byte(4)
  local hop_budget_byte   = frame:byte(5)
  local prev_fwd_rt_hops  = frame:byte(6)
  local hb_remaining = (hop_budget_byte >> 4) & 0xf
  local hb_committed = hop_budget_byte & 0xf
  local ctr_lo_byte = frame:byte(7)
  local ctr_hi_byte = frame:byte(8)
  local ctr      = ctr_lo_byte | (ctr_hi_byte << 8)
  -- inner spans byte 9 .. (#frame - MAC_LEN)
  local inner_end = #frame - MAC_LEN
  if inner_end < 9 then return nil end
  local inner    = frame:sub(9, inner_end)

  local out = {
    flags         = flags,
    e2e_ack_req   = (flags & DATA_FLAG_E2E_ACK_REQ) ~= 0,
    e2e_is_ack    = (flags & DATA_FLAG_E2E_IS_ACK) ~= 0,
    priority      = (flags & DATA_FLAG_PRIORITY) ~= 0,
    payload_type_m = (flags & DATA_FLAG_PAYLOAD_TYPE_M) ~= 0,
    next          = next_hop,
    dst           = dst,
    hop_remaining = hb_remaining,
    hop_committed = hb_committed,
    prev_fwd_rt_hops = prev_fwd_rt_hops,
    ctr           = ctr,
    ctr_lo        = ctr & 0xf,
    inner         = inner,
  }

  -- ROADMAP §3 M-payload inner layout: id(4B) + channel_id(1B) + flavor(1B) + body(N)
  if out.payload_type_m then
    if #inner < 6 then return nil end
    out.channel_msg_id  = channel_msg_id_from_bytes(inner, 1)
    out.channel_id      = inner:byte(5)
    out.channel_flavor  = inner:byte(6)
    out.body            = inner:sub(7)
    -- M frames don't carry an `origin` field — that's encoded inside the
    -- channel_msg_id (high 8 bits = origin node_id).
    out.origin          = (out.channel_msg_id >> 24) & 0xff
    return out
  end

  -- Normal DATA inner: src_addr_len(1) + src_addr(1) + body
  if #inner < 2 then return nil end
  local src_addr_len = inner:byte(1)
  if src_addr_len ~= 0 then return nil end    -- flat addresses only this phase
  out.origin = inner:byte(2)
  out.body   = inner:sub(3)
  return out
end

-- ---------- airtime + retry plumbing ----------------------------------------

-- Frame-header lengths (excluding payload). Computed from the wire-format
-- table at top of file so airtime predictions stay precise as we extend the
-- protocol — bump these if the frame layout changes.
local RTS_LEN = 8       -- 'R' + src + next + [addr_len|rsv|leaf_id] + dst + [ctr_lo<<4|rsv] + sf_bitmap + payload_len
local CTS_LEN = 3       -- 'C' + (ctr_lo<<4 | (sf-5)<<1 | already_received) + to
-- SX126x / SX127x LoRa PHY length register is 8-bit → 255 bytes max for
-- the *entire* on-air frame. Anything longer is physically untransmittable.
-- The runtime enforces this at TX with a `tx_oversized` event; the script
-- enforces it at send-time (see send_oversized) to fail fast at the
-- originator instead of after queueing.
LORA_MAX_FRAME_BYTES = 255

local DATA_HDR_LEN = 8  -- 'D' + byte1 + next + dst + hop_budget + prev_fwd_rt_hops + ctr_lo + ctr_hi (inner+MAC follow)
-- DATA wire overhead beyond inner body: 2 inner-header bytes (src_addr_len + src_addr) + MAC_LEN.
-- RTS payload_len = #body + DATA_INNER_OVERHEAD for in-leaf frames.
local DATA_INNER_OVERHEAD = 2 + MAC_LEN  -- src_addr_len(1) + src_addr(1) + MAC(4) = 6
local ACK_LEN = 3       -- 'K' + (ctr_lo<<4 | hint_2 | snr_bucket_2) + to
local NACK_LEN = 4      -- 'N' + (reason_4|ctr_lo_4) + payload + to
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
-- Q4 dB (1/16 dB units). SF5 = -2.5 dB → -40; SF12 = -20.0 dB → -320.
local SF_DEMOD_THRESHOLD = {
  [5]  =  -40, [6]  =  -80, [7]  = -120, [8]  = -160,
  [9]  = -200, [10] = -240, [11] = -280, [12] = -320,
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

local function sf_bitmap_to_set(bm)
  local out = {}
  for sf = 5, 12 do
    if sf_in_bitmap(bm or 0, sf) then table.insert(out, sf) end
  end
  return out
end

-- Choose the fastest (lowest) SF in the bitmap whose demod threshold leaves
-- at least `margin_q4` of headroom against the measured link SNR. Falls
-- back to the most-robust (highest) allowed SF if nothing meets the
-- margin — the link is borderline but we still try. Returns nil only on
-- empty bitmap (caller should reject the RTS). All inputs are Q4.
local function select_data_sf(rx_snr_q4, sf_bitmap, margin_q4)
  -- Ascending pass: prefer fastest SF that has the SNR headroom.
  for sf = 5, 12 do
    if sf_in_bitmap(sf_bitmap, sf) and
       rx_snr_q4 >= SF_DEMOD_THRESHOLD[sf] + margin_q4 then
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

-- All Q4 in / out.
local function data_sf_selection_snr(self, peer_id, current_snr_q4)
  local ewma_q4 = self.snr_ewma_in[peer_id]
  if ewma_q4 == nil then return current_snr_q4, nil end
  -- For marginal edges, a stale/high EWMA can make CTS advertise a DATA SF
  -- the current RTS sample cannot support. Use the conservative side of both.
  return math.min(current_snr_q4, ewma_q4), ewma_q4
end

local function route_score_from_snr(self, snr_q4)
  if snr_q4 == nil then return nil end
  return snr_q4 - (self.route_snr_conservatism_q4 or 0)
end

-- Labels eligible for on_radio_busy retry. BCN is periodic — the next
-- beacon-fire will retry naturally, no point re-queuing. RTS-class frames
-- have their own rts_timeout retry path; running on_radio_busy retries on
-- top would race the timeout. Only the receiver-side / DATA labels (where
-- there is no other recovery mechanism) get rescheduled. Q also gets a
-- runtime retry: if the initial route query is blocked before it reaches the
-- radio, the deferred-send TTL can expire without anyone learning a route.
--
-- DATA-M (channel-gossip 2B broadcast, PROTOCOL §3.4.1) is intentionally
-- NOT in RETRY_ELIGIBLE. The stash mechanism would re-fire only the DATA-M
-- leg, not the RTS announce — receivers' overhear-arm windows (sized
-- around the original RTS) would be expired by the time the deferred
-- broadcast lands. Instead, DATA-M defer is handled in on_radio_busy:
-- the full RTS+DATA-M sequence is re-emitted via fire_m_broadcast_rts so
-- receivers re-arm with fresh guards.
local RETRY_ELIGIBLE = {
  ["CTS"]     = true,
  ["CTS-dup"] = true,
  ["DATA"]    = true,
  ["ACK"]     = true,
  ["K-dup"]   = true,
  ["NACK"]    = true,
  ["Q"]       = true,
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

local function rts_timeout_base_ms(self, routing_sf)
  local sf = routing_sf or self.routing_sf
  return airtime_ms(sf, self.bw_hz, self.cr, self.preamble_sym, RTS_LEN)
       + airtime_ms(sf, self.bw_hz, self.cr, self.preamble_sym, CTS_LEN)
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

local refresh_route_order
local schedule_triggered_beacon
local get_peer_suspect_level
local is_next_hop_fresh
local next_hop_selectable

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
  local entry = refresh_route_order(self, dst_id, "blind_alt_order")
  if not entry then return "defer", remaining + 1 end
  -- Walk the candidates list; skip the current next_hop, the previous_hop
  -- loop guard, any next_hop already tried (per pending_tx.alts_tried),
  -- stale/silent next-hops, and any candidate currently in a blind window.
  -- alts_tried is a table-as-set keyed by next_hop id; nil/empty means
  -- "nothing tried yet" so the first non-blind alt qualifies.
  for _, c in ipairs(entry.candidates) do
    if next_hop_selectable(self, dst_id, c, previous_hop, alts_tried,
                           current_next_hop, "blind_alt")
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
  -- Count DISTINCT ctr_lo per kind, not raw transmissions. Retrying ONE stuck
  -- message must not look like a flood of fresh originations: the track-side
  -- dedup only collapses retries spaced < originator_retry_dedup_ms (10s), but
  -- a multi-second congestion stall (e.g. a relay hammering a busy next-hop on
  -- the cross-layer second leg) spaces them past that, so each escaped retry
  -- used to bump rts. Dedup by ctr_lo across the whole window here instead.
  -- (ctr_lo is 4-bit on the wire, so this caps at 16 distinct — far above the
  -- ~6 threshold, so a genuine spammer cycling ctr_lo still trips it.) Airtime
  -- stays cumulative: retries really do burn channel time, so the airtime
  -- backstop keeps catching high-volume spam regardless of ctr_lo reuse.
  local rts_seen, cts_seen = {}, {}
  local rts, cts, air = 0, 0, 0
  for _, ev in ipairs(entry.events) do
    if ev.t >= cutoff then
      air = air + (ev.air or 0)
      if ev.kind == "rts" then
        if not rts_seen[ev.ctr_lo] then rts_seen[ev.ctr_lo] = true; rts = rts + 1 end
      elseif ev.kind == "cts" then
        if not cts_seen[ev.ctr_lo] then cts_seen[ev.ctr_lo] = true; cts = cts + 1 end
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

-- ============================================================================
-- Priority unicast budgeting (ROADMAP §3a)
--
-- Two parallel ledgers, separate from the normal anti-spam counters:
--   * priority_send_events[]: our OWN priority originations
--   * peer_priority_observations[sender]: priority frames observed from
--     each direct sender at the 1st-hop. Used to throttle abusive
--     priority traffic that bypasses the originator self-cap.
-- Both ledgers are sliding windows of `originator_priority_window_ms`.
-- ============================================================================

-- Returns (ok, current_count). ok=false if recording would push us over
-- originator_priority_max_per_window. Does NOT mutate; caller records
-- on success. **Global** (not local) to avoid the 200-locals-per-main-
-- function limit; same trick as addr_conflict_tie_break.
function check_priority_budget(self, now)
  if not self.priority_send_events then return true, 0 end
  local cutoff = now - (self.originator_priority_window_ms or 0)
  local n = 0
  for _, t in ipairs(self.priority_send_events) do
    if t >= cutoff then n = n + 1 end
  end
  local cap = self.originator_priority_max_per_window or 0
  if cap <= 0 then return true, n end
  return n < cap, n
end

-- Append + prune. Call ONLY after check_priority_budget succeeded.
-- Global, see check_priority_budget.
function record_priority_origination(self, now)
  if not self.priority_send_events then self.priority_send_events = {} end
  local cutoff = now - (self.originator_priority_window_ms or 0)
  local kept = {}
  for _, t in ipairs(self.priority_send_events) do
    if t >= cutoff then table.insert(kept, t) end
  end
  table.insert(kept, now)
  self.priority_send_events = kept
end

-- 1st-hop peer-priority ledger. Returns (ok, current_count) where ok=false
-- means this sender has exceeded the per-direct-sender priority cap; the
-- caller should silently drop the forwarding (we already RX'd the frame).
-- Global, see check_priority_budget.
function check_peer_priority_budget(self, sender_id, now)
  if not self.peer_priority_observations then return true, 0 end
  local obs = self.peer_priority_observations[sender_id]
  if obs == nil then return true, 0 end
  local cutoff = now - (self.originator_priority_window_ms or 0)
  local n = 0
  for _, t in ipairs(obs.events or {}) do
    if t >= cutoff then n = n + 1 end
  end
  local cap = self.originator_priority_max_per_window or 0
  if cap <= 0 then return true, n end
  return n < cap, n
end

-- ============================================================================
-- Channel-buffer helpers (ROADMAP §3 gossip channels)
--
-- Shared FIFO ring across all subscribed channels (Principle 2 — no channel
-- gets dedicated bandwidth based on subscription count). Entries are appended
-- chronologically; on overflow we prefer evicting entries whose `seen_by`
-- covers all current direct neighbours (safely propagated), falling back to
-- absolute-oldest if no such entry exists.
--
-- Global functions to stay below Lua's 200-locals-per-main-chunk limit.
-- ============================================================================

function channel_buffer_find(self, id)
  if not self.channel_buffer then return nil, nil end
  for i, e in ipairs(self.channel_buffer) do
    if e.id == id then return e, i end
  end
  return nil, nil
end

function channel_buffer_mark_seen_by(self, id, neighbour_id)
  local e = channel_buffer_find(self, id)
  if e == nil or neighbour_id == nil then return false end
  e.seen_by = e.seen_by or {}
  if not e.seen_by[neighbour_id] then
    e.seen_by[neighbour_id] = true
    return true
  end
  return false
end

-- Pick the oldest entry whose seen_by covers all live direct neighbours.
-- Falls back to the absolute-oldest. Returns (index, "safe" | "fallback").
function channel_buffer_pick_eviction(self)
  if not self.channel_buffer or #self.channel_buffer == 0 then return nil, nil end
  -- Determine "current direct neighbours" = nodes in rt with hops==1.
  -- Empty set → "safe" rule trivially satisfied; just evict the oldest.
  local neighbours = {}
  if self.rt then
    for dest_id, entry in pairs(self.rt) do
      local c = entry.candidates and entry.candidates[1]
      if c and c.hops == 1 then table.insert(neighbours, dest_id) end
    end
  end
  if #neighbours == 0 then
    return 1, "fallback"   -- no neighbours observed yet
  end
  for i, e in ipairs(self.channel_buffer) do
    local all_seen = true
    for _, nbr in ipairs(neighbours) do
      if not (e.seen_by and e.seen_by[nbr]) then all_seen = false; break end
    end
    if all_seen then return i, "safe" end
  end
  return 1, "fallback"
end

-- Add a new entry to the channel buffer. If at cap, evict oldest first.
-- Returns (added, evicted_entry_or_nil).
function channel_buffer_add(self, entry)
  self.channel_buffer = self.channel_buffer or {}
  local cap = self.cap_channel_buffer or 128
  local evicted = nil
  if #self.channel_buffer >= cap then
    local idx, mode = channel_buffer_pick_eviction(self)
    if idx ~= nil then
      evicted = table.remove(self.channel_buffer, idx)
      self:emit("channel_msg_evicted", {
        id = evicted.id,
        channel_id = evicted.channel_id,
        seen_by_all_neighbours = (mode == "safe"),
        cap = cap,
      })
      self:emit("table_cap_hit", {
        table = "channel_buffer", size = cap, cap = cap, action = "evict",
        evicted_id = evicted.id, mode = mode,
      })
    end
  end
  table.insert(self.channel_buffer, entry)
  return true, evicted
end

-- ROADMAP §3 BCN digest -> Q_CHANNEL_PULL scheduler.
-- Called from on_recv 'B' when the beacon carried a CHANNEL_DIGEST TLV.
-- For each ID in the digest:
--   - If we already have it: mark seen_by[bcn_sender] (lets us evict it
--     once everyone we can reach has it).
--   - Else: schedule a Q_CHANNEL_PULL to bcn_sender after a random jitter,
--     unless we recently pulled the same ID or we've already scheduled
--     cap_channel_pulls_per_bcn_cycle pulls for this BCN.
-- Pending pulls are cancellable via channel_pull_pending[id] = nil — set
-- when an M-payload DATA frame promiscuously delivers the ID before our
-- jitter fires.
function process_channel_digest(self, b)
  if not b or not b.channel_digest_ids then return end
  -- Principle 11: gateways don't participate in channel gossip (would
  -- leak across layers via the gateway's BCN digest). Skip pull
  -- scheduling entirely. The matching skip on the merge side is in
  -- the M-payload-type DATA handler in on_recv.
  if self.self_gateway then return end
  local now = self:now()
  local pull_cap = self.cap_channel_pulls_per_bcn_cycle or 3
  local scheduled = 0
  for _, id in ipairs(b.channel_digest_ids) do
    local existing = channel_buffer_find(self, id)
    if existing ~= nil then
      if channel_buffer_mark_seen_by(self, id, b.src) and debug_emit_allowed(self) then
        self:emit("channel_msg_seen_by_neighbour", {
          id = id, channel_id = existing.channel_id, neighbour = b.src,
        })
      end
    elseif scheduled < pull_cap then
      local recent = self.channel_pull_recent and self.channel_pull_recent[id]
      local window = self.channel_pull_window_ms or 5000
      if recent == nil or (now - recent) >= window then
        local jitter = self:rand(0, (self.channel_pull_jitter_ms or 500) + 1)
        self.channel_pull_pending = self.channel_pull_pending or {}
        self.channel_pull_pending[id] = { target = b.src, scheduled_at = now }
        scheduled = scheduled + 1
        local target = b.src
        self:after(jitter, function()
          local pending = self.channel_pull_pending and self.channel_pull_pending[id]
          if pending == nil then return end
          -- Re-check: did the message arrive via promiscuous overhear?
          if channel_buffer_find(self, id) ~= nil then
            self.channel_pull_pending[id] = nil
            self:emit("channel_pull_suppressed", {
              ids = {id}, overheard_from = "promiscuous_receive",
            })
            return
          end
          -- Inline lookups: process_channel_digest is defined earlier
          -- in the chunk than `active_leaf_id`/`active_routing_sf` (both
          -- `local function` and not yet in scope at parse time), so we
          -- can't call them by name from this closure.
          local q_leaf_id = self.active_leaf_id or self.leaf_id
          local q_routing_sf = (self.gateway_layer_by_id
                                and self.gateway_layer_by_id[self.active_layer_id]
                                and self.gateway_layer_by_id[self.active_layer_id].routing_sf)
                               or self.routing_sf
          local frame = pack_q_channel_pull(q_leaf_id, self.id, target,
                                             {id}, self.is_mobile == true)
          tx_initiating(self, frame, {
            sf    = q_routing_sf,
            label = "Q",
            info  = string.format("channel_pull target=%d id=0x%08x", target, id),
          })
          self:emit("channel_pull_sent", {
            to = target, ids = {id}, trigger = "bcn_digest",
          })
          self.channel_pull_recent = self.channel_pull_recent or {}
          self.channel_pull_recent[id] = self:now()
          self.channel_pull_pending[id] = nil
        end)
      end
    end
  end
end

function record_peer_priority_observation(self, sender_id, now)
  if not self.peer_priority_observations then self.peer_priority_observations = {} end
  local obs = self.peer_priority_observations[sender_id]
  if obs == nil then obs = {events = {}} end
  local cutoff = now - (self.originator_priority_window_ms or 0)
  local kept = {}
  for _, t in ipairs(obs.events or {}) do
    if t >= cutoff then table.insert(kept, t) end
  end
  table.insert(kept, now)
  obs.events = kept
  self.peer_priority_observations[sender_id] = obs
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
  if self.join_required and not self.joined and label ~= "J" then
    self:emit("tx_unjoined_blocked", {
      label = label,
      source = "tx_with_retry",
    })
    return false
  end
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
    return false
  end
  self:tx(bytes, opts)
  if opts.on_handed then opts.on_handed() end
  return true
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
--      the actual emit at busy_until + rand(0, lbt_backoff_ms). Reduces
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
function tx_initiating(self, bytes, opts, after_tx)   -- global (referenced by process_channel_digest, defined earlier in chunk)
  local label = opts.label or ""
  if self.join_required and not self.joined and label ~= "J" then
    self:emit("tx_unjoined_blocked", {
      label = label,
      source = "tx_initiating",
    })
    return
  end
  local is_rts_label = (label == "RTS" or label == "RTS-fwd" or label == "RTS-rty")
  if is_rts_label and opts.__pending_tx_ref == nil then
    opts.__pending_tx_ref = self.pending_tx
  end
  if self.lbt_enabled and not opts.__lbt_done then
    local now = self:now()
    local busy_until = self:channel_busy_until() or 0
    if busy_until > now then
      opts.__lbt_done = true
      local wait = busy_until - now
      local delay = wait + self:rand(0, self.lbt_backoff_ms + 1)
      self:emit("tx_lbt_defer", {
        label = opts.label, kind = "initiating",
        defer_ms = delay, busy_until_ms = busy_until,
      })
      self:after(delay, function() tx_initiating(self, bytes, opts, after_tx) end)
      return
    end
  end
  if is_rts_label and opts.__pending_tx_ref ~= nil
     and self.pending_tx ~= opts.__pending_tx_ref then
    self:emit("rts_tx_cancelled_stale", {
      label = label,
      reason = "pending_tx_changed",
    })
    return
  end
  local handed_to_radio = tx_with_retry(self, bytes, opts)
  if handed_to_radio and after_tx then after_tx() end
end

-- Used by FLOOD frames (beacons). Same LBT pre-check as initiating, but
-- with a max-defer cap: if the channel will be busy longer than
-- flood_lbt_max_defer_ms, drop this page (tx_flood_skipped emit). The
-- next periodic / triggered fire rotates the offset and re-broadcasts.
local function tx_flood(self, bytes, opts)
  if self.join_required and not self.joined then
    self:emit("tx_unjoined_blocked", {
      label = opts.label,
      source = "tx_flood",
    })
    return false
  end
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
      local delay = wait + self:rand(0, self.lbt_backoff_ms + 1)
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
-- margin so a warned route has to be substantially better than a
-- HEALTHY alt to win. The penalty scales with viable alternatives:
-- no alternative = soft nudge; multiple alternatives = move load hard.
-- Tier 0 = HEALTHY (no penalty), 1 = STRAINED, 2 = CRITICAL,
-- 3 = EXHAUSTED.
-- Q4 dB penalty (1.0 dB = 16). 7 dB = 112, 14 dB = 224, etc.
local TIER_SCORE_PENALTY_BY_ALTS_DB = {
  [0] = { [0] =   0, [1] =   0, [2] =   0 },
  [1] = { [0] =  16, [1] =  64, [2] = 112 },
  [2] = { [0] = 112, [1] = 224, [2] = 336 },
  [3] = { [0] = 128, [1] = 240, [2] = 400 },
}

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

-- viab_q4 is the Q4 "viable alternative" threshold (routing SNR floor).
local function viable_alternatives_for_candidate(c, candidates, viab_q4)
  if not candidates then return 0 end
  local n = 0
  for _, alt in ipairs(candidates) do
    if alt.next_hop ~= c.next_hop and alt.score >= viab_q4 then
      n = n + 1
      if n >= 2 then return 2 end
    end
  end
  return n
end

-- Returns Q4 penalty (dB * 16) and viable-alt count.
local function budget_penalty_db(self, c, candidates, viab_q4)
  local tier = get_neighbor_tier(self, c.next_hop)
  if tier <= BUDGET_TIER_HEALTHY then return 0, 0 end
  local viable_alts = viable_alternatives_for_candidate(c, candidates, viab_q4)
  local by_alts = TIER_SCORE_PENALTY_BY_ALTS_DB[tier]
                  or TIER_SCORE_PENALTY_BY_ALTS_DB[BUDGET_TIER_EXHAUSTED]
  return by_alts[viable_alts] or by_alts[2] or 0, viable_alts
end

get_peer_suspect_level = function(self, node_id)
  if node_id == nil then return 0 end
  local now = self:now()
  local dead_until = self.peer_dead_until and self.peer_dead_until[node_id]
  if dead_until ~= nil then
    if dead_until > now then return PEER_LEVEL_DEAD end
    self.peer_dead_until[node_id] = nil
  end
  local silent_until = self.peer_silent_until and self.peer_silent_until[node_id]
  if silent_until ~= nil then
    if silent_until > now then return PEER_LEVEL_SILENT end
    self.peer_silent_until[node_id] = nil
  end
  local suspect_until = self.peer_suspect_until and self.peer_suspect_until[node_id]
  if suspect_until ~= nil then
    if suspect_until > now then return PEER_LEVEL_SUSPECT end
    self.peer_suspect_until[node_id] = nil
  end
  return 0
end

-- Returns Q4 penalty (dB * 16). Defaults: 80 dB / 40 dB / 12 dB.
local function peer_suspect_penalty_db(self, node_id)
  local level = get_peer_suspect_level(self, node_id)
  if level >= PEER_LEVEL_DEAD   then return self.peer_dead_penalty_q4    or 1280, level end
  if level >= PEER_LEVEL_SILENT then return self.peer_silent_penalty_q4  or  640, level end
  if level == PEER_LEVEL_SUSPECT then return self.peer_suspect_penalty_q4 or  192, level end
  return 0, 0
end

is_next_hop_fresh = function(self, node_id)
  if node_id == nil then return false, nil end
  if node_id == self.id then return true, 0 end
  local last_seen = self.dest_seen_ms and self.dest_seen_ms[node_id]
  if last_seen == nil then return false, nil end
  local age_ms = self:now() - last_seen
  return age_ms <= (self.next_hop_live_ttl_ms or 1200000), age_ms
end

function route_candidate_for_next(entry, next_hop)
  if entry == nil or entry.candidates == nil then return nil end
  for _, c in ipairs(entry.candidates) do
    if c.next_hop == next_hop then return c end
  end
  return nil
end

function route_candidate_layer_ok(c, tx_layer_id)
  if tx_layer_id == nil or c == nil then return true end
  -- Older route candidates and same-layer non-gateway sends may not carry
  -- learned_layer_id. Only enforce the guard when the route explicitly says
  -- it was learned while listening to a different layer.
  if c.learned_layer_id == nil then return true end
  return c.learned_layer_id == tx_layer_id
end

function emit_wrong_layer_next_skip(self, dst_id, next_hop, c, tx_layer_id, source)
  self:emit("rt_skip_wrong_layer_next", {
    dest = dst_id,
    next = next_hop,
    route_layer_id = c and c.learned_layer_id or nil,
    tx_layer_id = tx_layer_id,
    source = source or "route_select",
  })
end

local function route_mobile_touched(self, dest_id, c)
  return self.is_mobile == true
     or is_mobile_peer(self, dest_id)
     or (c ~= nil and is_mobile_peer(self, c.next_hop))
end

local function route_ttl_for_candidate(self, c)
  if c and c.hops and c.hops <= 1 then
    return self.rt_aging_ttl_neighbor_ms
  end
  return self.rt_aging_ttl_remote_ms
end

local function emit_stale_next_skip(self, dst_id, next_hop, source)
  local _, age_ms = is_next_hop_fresh(self, next_hop)
  self:emit("rt_skip_stale_next", {
    dest = dst_id,
    next = next_hop,
    age_ms = age_ms,
    ttl_ms = self.next_hop_live_ttl_ms or 1200000,
    source = source or "route_select",
  })
end

next_hop_selectable = function(self, dst_id, c, previous_hop, alts_tried,
                               current_next_hop, source)
  if not c or c.next_hop == nil then return false end
  if current_next_hop ~= nil and c.next_hop == current_next_hop then
    return false
  end
  if previous_hop ~= nil and c.next_hop == previous_hop then
    return false
  end
  if alts_tried and alts_tried[c.next_hop] then
    return false
  end
  if route_uses_mobile_as_transit(self, dst_id, c.next_hop) then
    self:emit("rt_skip_mobile_transit", {
      dest = dst_id,
      next = c.next_hop,
      source = source or "route_select",
    })
    return false
  end
  if get_peer_suspect_level(self, c.next_hop) >= PEER_LEVEL_SILENT then
    return false
  end
  local fresh = is_next_hop_fresh(self, c.next_hop)
  if not fresh then
    emit_stale_next_skip(self, dst_id, c.next_hop, source)
    return false
  end
  return true
end

-- Tier-aware effective score: c.score minus dynamic Q4 penalty for its
-- next_hop's known budget tier and temporary silence suspicion. Use this
-- anywhere we previously compared raw c.score, so the routing table tracks
-- usable capacity/liveness, not just radio quality. All Q4.
local function effective_score(self, c, candidates, viab_q4)
  local penalty = budget_penalty_db(self, c, candidates, viab_q4)
  local suspect_penalty = peer_suspect_penalty_db(self, c.next_hop)
  return c.score - penalty - suspect_penalty
end

local function route_candidate_context(self, dst_id, next_hop)
  local out = {
    candidate_rank = nil,
    candidate_count = 0,
    route_score = nil,
    route_score_eff = nil,
    route_hops = nil,
    route_age_ms = nil,
    next_tier = get_neighbor_tier(self, next_hop),
    budget_penalty_db = 0,
    next_suspect_level = get_peer_suspect_level(self, next_hop),
    suspect_penalty_db = 0,
    next_seen_age_ms = nil,
    next_seen_fresh = false,
    viable_alts = 0,
    mobile_touched = false,
    route_ttl_ms = nil,
  }
  local next_seen_fresh, next_seen_age_ms = is_next_hop_fresh(self, next_hop)
  out.next_seen_fresh = next_seen_fresh
  out.next_seen_age_ms = next_seen_age_ms
  local blind, blind_remaining = is_blind(self, next_hop)
  out.next_blind = blind
  out.next_blind_ms = blind_remaining
  local entry = self.rt[dst_id]
  if not entry or not entry.candidates then return out end
  out.candidate_count = #entry.candidates
  local now = self:now()
  for i, c in ipairs(entry.candidates) do
    if c.next_hop == next_hop then
      out.candidate_rank = i
      out.route_score = q4_to_db(c.score)
      local penalty, viable_alts = budget_penalty_db(
        self, c, entry.candidates, self.routing_snr_floor_q4)
      out.budget_penalty_db = q4_to_db(penalty)
      local suspect_penalty, suspect_level = peer_suspect_penalty_db(self, c.next_hop)
      out.suspect_penalty_db = q4_to_db(suspect_penalty)
      out.next_suspect_level = suspect_level
      out.viable_alts = viable_alts
      out.route_score_eff = q4_to_db(effective_score(self, c, entry.candidates, self.routing_snr_floor_q4))
      out.route_hops = c.hops
      out.route_age_ms = c.last_seen_ms and (now - c.last_seen_ms) or nil
      local ttl = route_ttl_for_candidate(self, c)
      out.route_ttl_ms = ttl
      out.mobile_touched = route_mobile_touched(self, dst_id, c)
      break
    end
  end
  return out
end

local function route_candidate_eligible_for_metrics(self, dst_id, c, previous_hop, alts_tried)
  if c == nil or c.next_hop == nil then return false end
  if previous_hop ~= nil and c.next_hop == previous_hop then return false end
  if alts_tried and alts_tried[c.next_hop] then return false end
  if route_uses_mobile_as_transit(self, dst_id, c.next_hop) then return false end
  if get_peer_suspect_level(self, c.next_hop) >= PEER_LEVEL_SILENT then return false end
  local fresh = is_next_hop_fresh(self, c.next_hop)
  if not fresh then return false end
  if is_blind(self, c.next_hop) then return false end
  return true
end

local function emit_route_decision(self, reason, px, ctx)
  local function cand_hops(c)
    return (c and c.hops) or 1
  end
  local entry = self.rt[px.dst]
  local best_hops = nil
  local best_next = nil
  local best_tier = nil
  local better_hop_available = 0
  local better_budget_available = 0
  local chosen_blind = ctx.next_blind and 1 or 0
  local chosen_hops = ctx.route_hops or 999
  local chosen_tier = ctx.next_tier or 0
  if entry and entry.candidates then
    for _, c in ipairs(entry.candidates) do
      if route_candidate_eligible_for_metrics(self, px.dst, c, px.previous_hop, px.alts_tried) then
        local tier = get_neighbor_tier(self, c.next_hop)
        local hops = cand_hops(c)
        if best_hops == nil
           or hops < best_hops
           or (hops == best_hops and tier < (best_tier or 99)) then
          best_hops = hops
          best_next = c.next_hop
          best_tier = tier
        end
        if c.next_hop ~= px.next and hops < chosen_hops then
          better_hop_available = 1
        end
        if c.next_hop ~= px.next and tier < chosen_tier then
          better_budget_available = 1
        end
      end
    end
  end
  local delta = (best_hops ~= nil and ctx.route_hops ~= nil)
              and (ctx.route_hops - best_hops) or 0
  local payload = {
    reason = reason or "?",
    origin = px.origin,
    payload = px.user_text,
    ctr = px.ctr,
    ctr_lo = px.ctr_lo,
    dst = px.dst,
    chosen_next = px.next,
    chosen_rank = ctx.candidate_rank,
    candidate_count = ctx.candidate_count,
    chosen_hops = ctx.route_hops,
    best_next = best_next,
    best_hops = best_hops or -1,
    chosen_minus_best_hops = delta,
    better_hop_available = better_hop_available,
    better_budget_available = better_budget_available,
    chosen_tier = chosen_tier,
    chosen_blind = chosen_blind,
    mobile_touched = ctx.mobile_touched and 1 or 0,
    route_age_ms = ctx.route_age_ms,
    route_ttl_ms = ctx.route_ttl_ms,
  }
  self:emit("route_decision", payload)
  if better_hop_available ~= 0 or better_budget_available ~= 0
     or delta >= 2 or chosen_tier >= BUDGET_TIER_CRITICAL
     or chosen_blind ~= 0 or ctx.mobile_touched then
    if debug_emit_allowed(self) then
      self:emit("route_decision_detail", payload)
    end
  end
end

local function emit_rts_attempt_detail(self, kind, px)
  self.rts_attempt_seq = (self.rts_attempt_seq or 0) + 1
  px.last_rts_attempt_seq = self.rts_attempt_seq
  local ctx = route_candidate_context(self, px.dst, px.next)
  if debug_emit_allowed(self) then
    self:emit("rts_attempt_detail", {
      attempt_seq = px.last_rts_attempt_seq,
      kind = kind,
      origin = px.origin,
      payload = px.user_text,
      ctr = px.ctr,
      ctr_lo = px.ctr_lo,
      dst = px.dst,
      next = px.next,
      retries_left = px.retries_left,
      retry_reason = px.retry_reason,
      candidate_rank = ctx.candidate_rank,
      candidate_count = ctx.candidate_count,
      route_score = ctx.route_score,
      route_score_eff = ctx.route_score_eff,
      budget_penalty_db = ctx.budget_penalty_db,
      suspect_penalty_db = ctx.suspect_penalty_db,
      viable_alts = ctx.viable_alts,
      route_hops = ctx.route_hops,
      route_age_ms = ctx.route_age_ms,
      next_tier = ctx.next_tier,
      next_suspect_level = ctx.next_suspect_level,
      next_seen_fresh = ctx.next_seen_fresh,
      next_seen_age_ms = ctx.next_seen_age_ms,
      next_blind = ctx.next_blind,
      next_blind_ms = ctx.next_blind_ms,
      mobile_touched = ctx.mobile_touched,
      route_ttl_ms = ctx.route_ttl_ms,
      previous_hop = px.previous_hop,
    })
  end
  emit_route_decision(self, px.retry_reason or kind, px, ctx)
  return px.last_rts_attempt_seq
end

local function route_strictly_better(self, a, b, viab_db, candidates)
  local a_score = effective_score(self, a, candidates, viab_db)
  local b_score = effective_score(self, b, candidates, viab_db)
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

local function sort_route_candidates(self, candidates, viab_db)
  table.sort(candidates, function(a, b)
    return route_strictly_better(self, a, b, viab_db, candidates) or
           (not route_strictly_better(self, b, a, viab_db, candidates)
            and effective_score(self, a, candidates, viab_db) > effective_score(self, b, candidates, viab_db))
  end)
end

local function resort_routes_for_neighbor_penalty(self, node_id, reason, local_only)
  if node_id == nil then return 0 end
  local changed = 0
  local stats = {
    candidate_entries = 0,
    primary_entries = 0,
    primary_no_alt = 0,
    primary_with_alt = 0,
    primary_still_primary = 0,
    primary_demoted = 0,
    nonprimary_entries = 0,
  }
  for dest_id, entry in pairs(self.rt) do
    if entry.candidates then
      local affected = false
      for _, c in ipairs(entry.candidates) do
        if c.next_hop == node_id then
          affected = true
          break
        end
      end
      if affected then
        stats.candidate_entries = stats.candidate_entries + 1
        local old_primary = entry.candidates[1].next_hop
        if old_primary == node_id then
          stats.primary_entries = stats.primary_entries + 1
          if #entry.candidates < 2 then
            stats.primary_no_alt = stats.primary_no_alt + 1
          else
            stats.primary_with_alt = stats.primary_with_alt + 1
          end
        else
          stats.nonprimary_entries = stats.nonprimary_entries + 1
        end
      end
      if affected and #entry.candidates > 1 then
        local old_primary = entry.candidates[1].next_hop
        sort_route_candidates(self, entry.candidates, self.routing_snr_floor_q4)
        local new_primary = entry.candidates[1].next_hop
        if old_primary == node_id then
          if new_primary == node_id then
            stats.primary_still_primary = stats.primary_still_primary + 1
          else
            stats.primary_demoted = stats.primary_demoted + 1
          end
        end
        if new_primary ~= old_primary then
          if not local_only then entry.dirty = true end
          changed = changed + 1
          self:emit("rt_penalty_rerank", {
            dest = dest_id,
            from_next = old_primary,
            to_next = new_primary,
            penalized = node_id,
            reason = reason or "neighbor_penalty",
            local_only = local_only or false,
          })
        end
      end
    end
  end
  if changed > 0 and not local_only then schedule_triggered_beacon(self) end
  return changed, stats
end

local function mark_neighbor_budget_tier(self, node_id, tier, source, local_only)
  if node_id == nil or tier == nil or tier <= BUDGET_TIER_HEALTHY then return 0 end
  local current = get_neighbor_tier(self, node_id)
  if current > tier then return 0 end
  self.neighbor_budget_tier[node_id] = tier
  self.neighbor_budget_tier_set_at[node_id] = self:now()
  local reranked, stats = resort_routes_for_neighbor_penalty(self, node_id, source, local_only)
  self:emit("neighbor_budget_mark", {
    node = node_id,
    tier = tier,
    source = source or "unknown",
    local_only = local_only or false,
    reranked = reranked,
    candidate_entries = stats and stats.candidate_entries or 0,
    primary_entries = stats and stats.primary_entries or 0,
    primary_no_alt = stats and stats.primary_no_alt or 0,
    primary_with_alt = stats and stats.primary_with_alt or 0,
    primary_still_primary = stats and stats.primary_still_primary or 0,
    primary_demoted = stats and stats.primary_demoted or 0,
    nonprimary_entries = stats and stats.nonprimary_entries or 0,
  })
  return reranked
end

local function clear_peer_suspect(self, node_id, source)
  if node_id == nil or node_id == self.id then return false end
  local had = false
  if self.peer_rts_timeouts and self.peer_rts_timeouts[node_id] then
    self.peer_rts_timeouts[node_id] = nil
    had = true
  end
  if self.peer_first_rts_timeout_ms and self.peer_first_rts_timeout_ms[node_id] then
    self.peer_first_rts_timeout_ms[node_id] = nil
    had = true
  end
  if self.peer_suspect_until and self.peer_suspect_until[node_id] then
    self.peer_suspect_until[node_id] = nil
    had = true
  end
  if self.peer_silent_until and self.peer_silent_until[node_id] then
    self.peer_silent_until[node_id] = nil
    had = true
  end
  if self.peer_dead_until and self.peer_dead_until[node_id] then
    self.peer_dead_until[node_id] = nil
    had = true
  end
  if self.peer_suspect_advertise_until and self.peer_suspect_advertise_until[node_id] then
    self.peer_suspect_advertise_until[node_id] = nil
    had = true
  end
  if self.peer_dead_advertise_until and self.peer_dead_advertise_until[node_id] then
    self.peer_dead_advertise_until[node_id] = nil
    had = true
  end
  if not had then return false end
  local reranked = resort_routes_for_neighbor_penalty(
    self, node_id, source or "peer_suspect_clear", true)
  self:emit("peer_suspect_clear", {
    node = node_id,
    source = source or "rx_frame",
    reranked = reranked or 0,
  })
  return true
end

local function mark_peer_suspect(self, node_id, level, source, remote_src)
  if node_id == nil or node_id == self.id then return 0 end
  local now = self:now()
  local prev_level = get_peer_suspect_level(self, node_id)
  if level >= PEER_LEVEL_DEAD then
    self.peer_dead_until[node_id] = now + (self.peer_dead_ttl_ms or 3600000)
  elseif level >= PEER_LEVEL_SILENT then
    self.peer_silent_until[node_id] = now + (self.peer_silent_ttl_ms or 900000)
  else
    self.peer_suspect_until[node_id] = now + (self.peer_suspect_ttl_ms or 300000)
  end
  if source == "rts_timeout" then
    local ttl = (level >= PEER_LEVEL_DEAD) and (self.peer_dead_ttl_ms or 3600000)
                or (level >= PEER_LEVEL_SILENT) and (self.peer_silent_ttl_ms or 900000)
                or (self.peer_suspect_ttl_ms or 300000)
    if level >= PEER_LEVEL_DEAD then
      self.peer_dead_advertise_until[node_id] = now + ttl
      self.peer_suspect_advertise_until[node_id] = nil
    else
      self.peer_suspect_advertise_until[node_id] = now + ttl
    end
  end
  local new_level = get_peer_suspect_level(self, node_id)
  local reranked = 0
  if new_level > prev_level then
    reranked = resort_routes_for_neighbor_penalty(
      self, node_id, source or "peer_suspect", true)
    if source == "rts_timeout" then
      schedule_triggered_beacon(self)
    end
  end
  self:emit("peer_suspect_mark", {
    node = node_id,
    level = new_level,
    previous_level = prev_level,
    source = source or "unknown",
    remote_src = remote_src,
    rts_timeouts = self.peer_rts_timeouts and self.peer_rts_timeouts[node_id] or nil,
    reranked = reranked or 0,
  })
  return reranked or 0
end

local function record_peer_rts_timeout(self, node_id, ctr_lo)
  if node_id == nil or node_id == self.id then return end
  self.peer_rts_timeouts[node_id] = (self.peer_rts_timeouts[node_id] or 0) + 1
  local n = self.peer_rts_timeouts[node_id]
  self:emit("peer_rts_timeout_count", {
    node = node_id,
    ctr_lo = ctr_lo,
    count = n,
  })
  if n >= (self.peer_silent_rts_timeouts or 3) then
    local first_ms = self.peer_first_rts_timeout_ms[node_id] or self:now()
    self.peer_first_rts_timeout_ms[node_id] = first_ms
    if n >= (self.peer_dead_rts_timeouts or 6)
       and (self:now() - first_ms) >= (self.peer_dead_evidence_window_ms or 900000) then
      mark_peer_suspect(self, node_id, PEER_LEVEL_DEAD, "rts_timeout")
    else
      mark_peer_suspect(self, node_id, PEER_LEVEL_SILENT, "rts_timeout")
    end
  elseif n >= (self.peer_suspect_rts_timeouts or 2) then
    mark_peer_suspect(self, node_id, PEER_LEVEL_SUSPECT, "rts_timeout")
  end
end

refresh_route_order = function(self, dest_id, reason)
  local entry = self.rt[dest_id]
  if not entry or not entry.candidates or #entry.candidates < 2 then return nil end
  local old_primary = entry.candidates[1].next_hop
  sort_route_candidates(self, entry.candidates, self.routing_snr_floor_q4)
  local new_primary = entry.candidates[1].next_hop
  if new_primary ~= old_primary then
    entry.dirty = true
    self:emit("rt_penalty_rerank", {
      dest = dest_id,
      from_next = old_primary,
      to_next = new_primary,
      reason = reason or "refresh_route_order",
    })
    schedule_triggered_beacon(self)
  end
  return entry
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
  if route_uses_mobile_as_transit(self, dest_id, cand and cand.next_hop) then
    self:emit("rt_skip_mobile_transit", {
      dest = dest_id,
      next = cand.next_hop,
      hops = cand.hops,
    })
    return "mobile_transit_skip"
  end
  local entry = rt[dest_id]
  if entry == nil then
    rt[dest_id] = { candidates = { cand }, dirty = true }   -- new dest
    if emit_rt_debug_route then emit_rt_debug_route(self, dest_id, "new") end
    return "new"
  end

  -- Match-by-next_hop: refresh in place if cand strictly better.
  for i, c in ipairs(entry.candidates) do
    if c.next_hop == cand.next_hop then
      if route_strictly_better(self, cand, c, viab_db, entry.candidates) then
        local was_primary = (i == 1)
        entry.candidates[i] = cand
        sort_route_candidates(self, entry.candidates, viab_db)
        local now_primary = (entry.candidates[1].next_hop == cand.next_hop)
        if now_primary then
          entry.dirty = true                                  -- primary refresh
          if emit_rt_debug_route then emit_rt_debug_route(self, dest_id, "primary_refresh") end
          return "primary_refresh"
        elseif was_primary then
          entry.dirty = true                                  -- another took over
          if emit_rt_debug_route then emit_rt_debug_route(self, dest_id, "promote") end
          return "promote"
        end
        if emit_rt_debug_route then emit_rt_debug_route(self, dest_id, "alt_install") end
        return "alt_install"
      end
      -- Equal/worse but same next_hop: refresh metadata, no order change.
      c.last_seen_ms = cand.last_seen_ms
      c.n2_hop       = cand.n2_hop
      c.is_gateway   = cand.is_gateway      -- identity metadata, not a ranking input
      c.learned_layer_id = cand.learned_layer_id
      return "no_change"
    end
  end

  -- New next_hop, room to spare.
  if #entry.candidates < MAX_RT_CANDIDATES then
    table.insert(entry.candidates, cand)
    sort_route_candidates(self, entry.candidates, viab_db)
    if entry.candidates[1].next_hop == cand.next_hop then
      entry.dirty = true                                      -- new candidate became primary
      if emit_rt_debug_route then emit_rt_debug_route(self, dest_id, "promote") end
      return "promote"
    end
    if emit_rt_debug_route then emit_rt_debug_route(self, dest_id, "alt_install") end
    return "alt_install"
  end

  -- Full table — replace the worst (last in sorted order) only if cand
  -- strictly beats it.
  local worst = entry.candidates[#entry.candidates]
  if not route_strictly_better(self, cand, worst, viab_db, entry.candidates) then
    return "no_change"
  end
  entry.candidates[#entry.candidates] = cand
  sort_route_candidates(self, entry.candidates, viab_db)
  if entry.candidates[1].next_hop == cand.next_hop then
    entry.dirty = true                                        -- displaced into primary
    if emit_rt_debug_route then emit_rt_debug_route(self, dest_id, "promote") end
    return "promote"
  end
  if emit_rt_debug_route then emit_rt_debug_route(self, dest_id, "alt_install") end
  return "alt_install"
end

local function maybe_emit_rt_full(self)
  if self.rt_full_emitted then return end
  if rt_count(self.rt) >= self.peer_count then
    self:emit("rt_full", { peers = self.peer_count })
    self:log(string.format("rt_full: %d peers known, table converged", self.peer_count))
    self.rt_full_emitted = true
    if self.layer_state ~= nil and self.current_layer_state_id ~= nil
       and self.layer_state[self.current_layer_state_id] ~= nil then
      self.layer_state[self.current_layer_state_id].rt_full_emitted = true
    end
  end
end

-- Human-readable id resolver for log lines. Falls back to "#N" if a frame
-- somehow carries an id we don't have a name for (shouldn't happen in
-- well-formed scenarios but keeps logs from blowing up).
local function name_of(self, id)
  return self.id_to_name[id] or ("#" .. tostring(id))
end

local function id_bind_set(self, node_id, key_hash32, source, confidence)
  if node_id == nil or key_hash32 == nil then return false end
  local now = self:now()
  self.id_bind = self.id_bind or {}
  local prev = self.id_bind[node_id]
  if prev and prev.key_hash32 ~= key_hash32 then
    prev.conflict_hash32 = key_hash32
    prev.last_seen_ms = now
    self:emit("addr_conflict_observed", {
      node = node_id,
      known_key_hash32 = prev.key_hash32,
      observed_key_hash32 = key_hash32,
      source = source or "unknown",
    })
    -- Own-id defense: if THIS node is the adopted owner of `node_id`
    -- (joined, prev.key matches our own key), send a defensive J_DENY
    -- so the impostor can run the tie-break in its J_DENY handler.
    if self.joined
       and node_id == self.id
       and prev.key_hash32 == (self.key_hash32 or 0)
       and addr_conflict_recovery_send_deny ~= nil then
      addr_conflict_recovery_send_deny(self, node_id, prev.key_hash32,
                                       key_hash32, source)
    end
    return false
  end
  local is_new = prev == nil
  if is_new
     and table_cap_hit(self, "id_bind", count_keys(self.id_bind),
                       self.cap_id_bind or 0, "refuse",
                       {node = node_id, key_hash32 = key_hash32,
                        source = source or "unknown"}) then
    return false
  end
  local rec = prev or {
    key_hash32 = key_hash32,
    first_seen_ms = now,
  }
  rec.key_hash32 = key_hash32
  rec.last_seen_ms = now
  rec.last_key_seen_ms = now
  rec.source = source or rec.source or "unknown"
  rec.confidence = confidence or rec.confidence or "weak"
  self.id_bind[node_id] = rec
  if is_new then
    self:emit("id_bind_set", {
      node = node_id,
      key_hash32 = key_hash32,
      source = rec.source,
      confidence = rec.confidence,
      layer_id = self.current_layer_state_id or self.active_layer_id or self.layer_id,
    })
  end
  return true
end

local function id_bind_refresh_plain(self, node_id, source)
  if node_id == nil then return false end
  local rec = self.id_bind and self.id_bind[node_id]
  if not rec then return false end
  rec.last_seen_ms = self:now()
  rec.last_source = source or "plain"
  return true
end

local function id_bind_expired(self, node_id, rec, now)
  local ttl = self.id_bind_ttl_ms or 0
  if ttl <= 0 or rec == nil then return false end
  if self.joined and node_id == self.id and rec.key_hash32 == (self.key_hash32 or 0) then
    return false
  end
  return (now - (rec.last_key_seen_ms or rec.last_seen_ms or rec.first_seen_ms or now)) >= ttl
end

local function id_bind_age_one(self, node_id, rec, now, source)
  self.id_bind[node_id] = nil
  self:emit("id_bind_aged", {
    node = node_id,
    key_hash32 = rec.key_hash32,
    age_ms = now - (rec.last_key_seen_ms or rec.last_seen_ms or rec.first_seen_ms or now),
    ttl_ms = self.id_bind_ttl_ms or 0,
    source = source or "age_loop",
    confidence = rec.confidence,
    layer_id = self.current_layer_state_id or self.active_layer_id or self.layer_id,
  })
end

local function id_bind_find_by_hash(self, key_hash32)
  if key_hash32 == nil or self.id_bind == nil then return nil end
  local now = self:now()
  for node_id, rec in pairs(self.id_bind) do
    if rec.key_hash32 == key_hash32 and not id_bind_expired(self, node_id, rec, now) then
      return node_id, rec
    end
  end
  return nil
end

local function gateway_layer_enabled(self, layer_id)
  if layer_id == nil then return false end
  layer_id = math.floor(layer_id)
  if layer_id == (self.layer_id or self.leaf_id or 0) then return true end
  return self.gateway_layer_set ~= nil and self.gateway_layer_set[layer_id] == true
end

local function layer_leaf_id(layer_id)
  return math.floor(layer_id or 0) & 0x0f
end

local function gateway_layer_record(self, layer_id)
  if layer_id == nil or self.gateway_layer_by_id == nil then return nil end
  return self.gateway_layer_by_id[math.floor(layer_id)]
end

local function active_leaf_id(self)
  return self.active_leaf_id or self.leaf_id
end

local function active_routing_sf(self)
  return self.active_routing_sf or self.routing_sf
end

local function active_allowed_sf_bitmap(self)
  return self.active_allowed_sf_bitmap or self.allowed_sf_bitmap
end

function ensure_layer_state(self, layer_id)
  layer_id = math.floor(layer_id or self.layer_id or 0)
  self.layer_state = self.layer_state or {}
  local st = self.layer_state[layer_id]
  if st == nil then
    st = {
      rt = {},
      id_bind = {},
      dest_seen_ms = {},
      beacon_offset = 0,
      rt_full_emitted = false,
    }
    self.layer_state[layer_id] = st
  end
  return st, layer_id
end

function use_layer_state(self, layer_id)
  if self.layer_state ~= nil and self.current_layer_state_id ~= nil then
    local cur = self.layer_state[self.current_layer_state_id]
    if cur ~= nil then
      cur.beacon_offset = self.beacon_offset or cur.beacon_offset or 0
      cur.rt_full_emitted = self.rt_full_emitted == true
    end
  end
  local st, normalized_layer_id = ensure_layer_state(self, layer_id)
  self.current_layer_state_id = normalized_layer_id
  self.rt = st.rt
  self.id_bind = st.id_bind
  self.dest_seen_ms = st.dest_seen_ms
  self.beacon_offset = st.beacon_offset or 0
  self.rt_full_emitted = st.rt_full_emitted == true
  return st
end

local function activate_gateway_layer(self, rec, reason)
  if rec == nil then return end
  use_layer_state(self, rec.layer_id)
  self.active_layer_id = rec.layer_id
  self.active_leaf_id = rec.leaf_id
  self.active_routing_sf = rec.routing_sf
  self.active_allowed_data_sfs = rec.allowed_data_sfs
  self.active_allowed_sf_bitmap = rec.allowed_sf_bitmap
  self:set_rx_sf(rec.routing_sf)
  self:emit("gateway_layer_active", {
    layer_id = rec.layer_id,
    leaf_id = rec.leaf_id,
    routing_sf = rec.routing_sf,
    duration_ms = rec.duration_ms,
    reason = reason or "schedule",
  })
  self:emit("gateway_schedule_change", {
    active_layer_id = rec.layer_id,
    active_leaf_id = rec.leaf_id,
    listen_sf = rec.routing_sf,
    data_sf_bitmap = rec.allowed_sf_bitmap,
    duration_ms = rec.duration_ms,
    reason = reason or "schedule",
  })
end

local function activate_primary_layer(self, reason)
  use_layer_state(self, self.layer_id)
  if self.active_layer_id == self.layer_id
     and self.active_leaf_id == self.leaf_id
     and self.active_routing_sf == self.routing_sf
     and self.active_allowed_sf_bitmap == self.allowed_sf_bitmap then
    return
  end
  self.active_layer_id = self.layer_id
  self.active_leaf_id = self.leaf_id
  self.active_routing_sf = self.routing_sf
  self.active_allowed_data_sfs = self.allowed_data_sfs
  self.active_allowed_sf_bitmap = self.allowed_sf_bitmap
  self:set_rx_sf(self.routing_sf)
  if self.self_gateway then
    self:emit("gateway_layer_active", {
      layer_id = self.layer_id,
      leaf_id = self.leaf_id,
      routing_sf = self.routing_sf,
      reason = reason or "primary",
    })
    self:emit("gateway_schedule_change", {
      active_layer_id = self.layer_id,
      active_leaf_id = self.leaf_id,
      listen_sf = self.routing_sf,
      data_sf_bitmap = self.allowed_sf_bitmap,
      reason = reason or "primary",
    })
  end
end

local function gateway_remote_bind_find(self, layer_id, key_hash32)
  if key_hash32 == nil or self.gateway_remote_bind == nil then return nil end
  local key = string.format("%d|%u", math.floor(layer_id or -1), key_hash32 & 0xffffffff)
  local rec = self.gateway_remote_bind[key]
  if rec ~= nil and rec.layer_id == layer_id then
    if rec.ambiguous then return nil, "ambiguous" end
    return rec
  end
  return nil
end

-- Apply observed gateway_layer TLV entries to self.bridged_layers.
-- Last-write-wins semantics (most-recent observation overrides any
-- previous dest_layer for that gw_id). Emits bridged_layers_observed
-- once per BCN and bridged_layers_replaced when an existing entry
-- changes its dest_layer. See PROTOCOL §3.1 type 4.
local function ingest_gateway_layer_entries(self, from, entries)
  if entries == nil or #entries == 0 then return end
  local now = self:now()
  self.bridged_layers = self.bridged_layers or {}
  local emit_observed = {}
  for _, e in ipairs(entries) do
    local gw_id = e.gw_id
    local new_layer = e.dest_layer
    if gw_id ~= nil and new_layer ~= nil then
      local prev = self.bridged_layers[gw_id]
      if prev ~= nil and prev.dest_layer ~= new_layer then
        if debug_emit_allowed(self) then
          self:emit("bridged_layers_replaced", {
            gw_id = gw_id, prev_layer = prev.dest_layer,
            new_layer = new_layer, from = from,
            age_ms = now - (prev.last_seen_ms or now),
          })
        end
      end
      self.bridged_layers[gw_id] = {
        dest_layer = new_layer, last_seen_ms = now,
      }
      table.insert(emit_observed, {
        gw_id = gw_id, dest_layer = new_layer,
      })
    end
  end
  if #emit_observed > 0 and debug_emit_allowed(self) then
    self:emit("bridged_layers_observed", {
      from = from, count = #emit_observed,
      entries = emit_observed,
    })
  end
end

local function remember_gateway_schedule(self, gateway_id, b)
  if gateway_id == nil or not b.self_gateway or not b.schedule or #b.schedule == 0 then return end
  self.gateway_neighbor_schedules = self.gateway_neighbor_schedules or {}
  local records = {}
  for _, rec in ipairs(b.schedule) do
    if rec.period_ms ~= nil and rec.period_ms > 0
       and rec.duration_ms ~= nil and rec.duration_ms > 0 then
      table.insert(records, {
        layer_id = rec.layer_id,
        leaf_id = layer_leaf_id(rec.layer_id),
        routing_sf = rec.routing_sf,
	        duration_ms = rec.duration_ms,
	        offset_ms = rec.offset_ms or 0,
	        period_ms = rec.period_ms,
	        period_unit_ms = rec.period_unit_ms or 1000,
	      })
    end
  end
  if #records == 0 then return end
  local layer_set = {}
  layer_set[math.floor(self.active_layer_id or self.layer_id or b.leaf_id or 0)] = true
  for _, rec in ipairs(records) do
    if rec.layer_id ~= nil then
      layer_set[math.floor(rec.layer_id)] = true
    end
  end
  local bridged_layers = {}
  for layer_id, _ in pairs(layer_set) do
    table.insert(bridged_layers, layer_id)
  end
  table.sort(bridged_layers)
  self.gateway_neighbor_schedules[gateway_id] = {
    heard_ms = self:now(),
    primary_leaf_id = b.leaf_id,
    bridged_layers = layer_set,
    records = records,
  }
	  self:emit("gateway_schedule_observed", {
	    gateway = gateway_id,
	    primary_leaf_id = b.leaf_id,
	    records = #records,
	    bridged_layers = bridged_layers,
	    schedule = records,
	  })
end

local function gateway_schedule_defer_ms(self, gateway_id)
  if self.self_gateway or gateway_id == nil or self.gateway_neighbor_schedules == nil then
    return 0
  end
  local sched = self.gateway_neighbor_schedules[gateway_id]
  if sched == nil or sched.records == nil then return 0 end
  local now = self:now()
  local heard = sched.heard_ms or now
  local our_leaf = active_leaf_id(self)
  local best_delay = 0
  for _, rec in ipairs(sched.records) do
    if rec.leaf_id ~= our_leaf and rec.period_ms ~= nil and rec.period_ms > 0 then
      local period = rec.period_ms
      local duration = rec.duration_ms or 0
      -- offset_ms is the countdown to the next foreign window measured from
      -- the beacon we heard at heard_ms (PROTOCOL: anchored to BCN receive
      -- time). visit_start + k*period covers every later window.
      local visit_start = heard + (rec.offset_ms or 0)
      local phase = (now - visit_start) % period
      if phase >= 0 and phase < duration then
        local delay = duration - phase + (self.gateway_schedule_guard_ms or 100)
        if delay > best_delay then best_delay = delay end
      end
    end
  end
  return best_delay
end

local function gateway_note_remote_binding(self, layer_id, node_id, key_hash32, source)
  if not self.self_gateway or key_hash32 == nil or node_id == nil then return end
  layer_id = math.floor(layer_id or (self.active_layer_id or self.layer_id or 0))
  if layer_id == (self.layer_id or 0) then return end
  if not gateway_layer_enabled(self, layer_id) then return end
  local now = self:now()
  local key = string.format("%d|%u", layer_id, key_hash32 & 0xffffffff)
  local prev = self.gateway_remote_bind[key]
  if prev ~= nil and prev.node_id ~= node_id then
    prev.ambiguous = true
    prev.last_seen_ms = now
    prev.conflicting_node = node_id
    prev.conflicting_source = source or "observed"
    self:emit("gateway_remote_bind_conflict", {
      layer_id = layer_id,
      key_hash32 = key_hash32,
      existing_node = prev.node_id,
      conflicting_node = node_id,
      source = source or "observed",
    })
    return
  end
  -- Preserve the ambiguous flag across same-node refreshes. Once two
  -- physical nodes have been observed claiming the same (layer,key), a
  -- later beacon from one of them does NOT resolve the ambiguity — both
  -- nodes are still alive. The ambiguous state clears only when one side
  -- ages out via gateway_remote_bind_ttl_ms (see age_out_gateway_remote_bind).
  local was_ambiguous = prev and prev.ambiguous == true
  self.gateway_remote_bind[key] = {
    layer_id = layer_id,
    node_id = node_id,
    key_hash32 = key_hash32,
    source = source or "observed",
    first_seen_ms = prev and prev.first_seen_ms or now,
    last_seen_ms = now,
    ambiguous = was_ambiguous,
    conflicting_node = prev and prev.conflicting_node or nil,
    conflicting_source = prev and prev.conflicting_source or nil,
  }
  if not was_ambiguous then
    self:emit("gateway_remote_bind_set", {
      layer_id = layer_id,
      node = node_id,
      key_hash32 = key_hash32,
      source = source or "observed",
    })
  end
end

local function age_out_gateway_remote_bind(self)
  if self.gateway_remote_bind == nil or next(self.gateway_remote_bind) == nil then return end
  local ttl = self.gateway_remote_bind_ttl_ms or self.id_bind_ttl_ms or 0
  if ttl <= 0 then return end
  local now = self:now()
  local keys = {}
  for key, _ in pairs(self.gateway_remote_bind) do
    keys[#keys + 1] = key
  end
  for _, key in ipairs(keys) do
    local rec = self.gateway_remote_bind[key]
    if rec and (now - (rec.last_seen_ms or rec.first_seen_ms or now)) >= ttl then
      self.gateway_remote_bind[key] = nil
      self:emit("gateway_remote_bind_aged", {
        layer_id = rec.layer_id,
        node = rec.node_id,
        key_hash32 = rec.key_hash32,
        age_ms = now - (rec.last_seen_ms or rec.first_seen_ms or now),
        ttl_ms = ttl,
        source = rec.source,
        ambiguous = rec.ambiguous or false,
      })
    end
  end
end

local function select_gateway_for_layer(self, target_layer_id)
  target_layer_id = math.floor(target_layer_id or -1)
  -- Prune stale propagated entries before reading. Cheap (table walk).
  prune_aged_bridged_layers(self, self:now())
  local best_gateway = nil
  local best_hops = nil
  local best_score = nil
  for dest_id, entry in pairs(self.rt or {}) do
    local c = entry.candidates and entry.candidates[1]
    if c ~= nil and dest_id ~= self.id then
      -- 1-hop path: direct neighbour parsed the schedule TLV.
      local sched = self.gateway_neighbor_schedules
                    and self.gateway_neighbor_schedules[dest_id]
      local bridges_target = sched
                             and sched.bridged_layers
                             and sched.bridged_layers[target_layer_id] == true
      -- Multi-hop path: PROTOCOL §3.1 type 4 propagated TLV.
      if not bridges_target and self.bridged_layers ~= nil then
        local prop = self.bridged_layers[dest_id]
        if prop ~= nil and prop.dest_layer == target_layer_id then
          bridges_target = true
        end
      end
      if bridges_target then
        local hops = c.hops or 99
        local score = c.score or -999
        if best_gateway == nil
           or hops < best_hops
           or (hops == best_hops and score > best_score) then
          best_gateway = dest_id
          best_hops = hops
          best_score = score
        end
      end
    end
  end
  if best_gateway ~= nil then
    return best_gateway, best_hops, best_score
  end
  -- Pass 2: no gateway with a live route. Fall back to ANY gateway known to
  -- bridge this layer (direct-neighbour schedule, or propagated type-4 TLV)
  -- even without an rt route to it. The caller enqueues toward it as a normal
  -- send; issue_send's no-route path (defer_send_for_route) then fires a
  -- ROUTE_QUERY and discovers the route -- the same reactive recovery any
  -- same-layer dst gets. Without this, a never-learned/aged gateway route
  -- silently drops the send: differential ("dirty-only") beacons don't
  -- re-advertise stable routes, so a node can persistently know a gateway
  -- exists (seen-bitmap + type-4 TLV) yet never receive a route entry to it.
  if self.gateway_neighbor_schedules ~= nil then
    for gw_id, sched in pairs(self.gateway_neighbor_schedules) do
      if gw_id ~= self.id and sched.bridged_layers
         and sched.bridged_layers[target_layer_id] == true then
        return gw_id, nil, nil
      end
    end
  end
  if self.bridged_layers ~= nil then
    local ttl = self.seen_bitmap_ttl_ms or 0
    local now2 = self:now()
    for gw_id, prop in pairs(self.bridged_layers) do
      if gw_id ~= self.id and prop.dest_layer == target_layer_id then
        -- On-layer guard: the (layer-local) seen-bitmap must have observed
        -- this gateway recently. Excludes cross-layer TLV leaks -- e.g. an
        -- L2-home bridge whose (gw->L2) TLV propagated into L1 via a
        -- dual-layer gateway: it bridges L2 but is unreachable from L1, so we
        -- must not address an envelope to it (we'd never route to it).
        local seen = self.dest_seen_ms and self.dest_seen_ms[gw_id]
        if seen ~= nil and (ttl <= 0 or (now2 - seen) <= ttl) then
          return gw_id, nil, nil
        end
      end
    end
  end
  return nil
end

-- True if we know SOME gateway bridges to target_layer_id (from a direct
-- neighbour's schedule or a propagated type-4 TLV) -- even if we currently
-- lack a route to it. Lets the send path distinguish "no gateway known" from
-- "gateway known but unreachable" (the latter = route to the gateway aged out
-- during its visit-layer absence; see select_gateway_for_layer). Global to
-- avoid the 200-local chunk limit.
function knows_gateway_for_layer(self, target_layer_id)
  target_layer_id = math.floor(target_layer_id or -1)
  if self.gateway_neighbor_schedules ~= nil then
    for _, sched in pairs(self.gateway_neighbor_schedules) do
      if sched.bridged_layers and sched.bridged_layers[target_layer_id] == true then
        return true
      end
    end
  end
  if self.bridged_layers ~= nil then
    for _, prop in pairs(self.bridged_layers) do
      if prop.dest_layer == target_layer_id then return true end
    end
  end
  return false
end

local function age_out_id_bind(self)
  if self.id_bind == nil or next(self.id_bind) == nil then return end
  if (self.id_bind_ttl_ms or 0) <= 0 then return end
  local now = self:now()
  local ids = {}
  for node_id, _ in pairs(self.id_bind) do
    ids[#ids + 1] = node_id
  end
  for _, node_id in ipairs(ids) do
    local rec = self.id_bind[node_id]
    if rec and id_bind_expired(self, node_id, rec, now) then
      id_bind_age_one(self, node_id, rec, now, "age_loop")
    end
  end
end

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
    if emit_rt_debug_route then emit_rt_debug_route(self, dest_id, "prune_3cycle") end
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
      local old_count = #(entry.candidates or {})
      for i, c in ipairs(entry.candidates) do
        local ttl = route_ttl_for_candidate(self, c)
        local mobile_touched = route_mobile_touched(self, dest_id, c)
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
            mobile_touched = mobile_touched,
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
      if #kept < old_count then
        if emit_rt_debug_route then emit_rt_debug_route(self, dest_id, "aged") end
      end
    end
  end
  if any_evicted then schedule_triggered_beacon(self) end
end

local function emit_rt_quality_snapshots(self)
  if not debug_emit_allowed(self) then return end
  local function cand_hops(c)
    return (c and c.hops) or 1
  end
  local now = self:now()
  for dest_id, entry in pairs(self.rt) do
    if entry and entry.candidates and entry.candidates[1] then
      local primary = entry.candidates[1]
      local primary_ttl = route_ttl_for_candidate(self, primary)
      local mobile_touched = route_mobile_touched(self, dest_id, primary)
      local primary_age = primary.last_seen_ms and (now - primary.last_seen_ms) or 0
      local primary_tier = get_neighbor_tier(self, primary.next_hop)
      local best = primary
      for _, c in ipairs(entry.candidates) do
        if route_candidate_eligible_for_metrics(self, dest_id, c, nil, nil) then
          if cand_hops(c) < cand_hops(best) then
            best = c
          end
        end
      end
      local delta = cand_hops(primary) - cand_hops(best)
      local reason = nil
      if primary_ttl > 0 and primary_age >= math.floor(primary_ttl * 0.8) then
        reason = "primary_stale"
      elseif primary_tier >= BUDGET_TIER_CRITICAL then
        reason = "primary_budget_tier"
      elseif delta >= 2 then
        reason = "primary_worse_than_alt"
      elseif (primary.hops or 0) >= 8 then
        reason = "primary_long"
      end
      if reason ~= nil then
        self:emit("rt_quality_snapshot", {
          reason = reason,
          dst = dest_id,
          primary_next = primary.next_hop,
          primary_hops = cand_hops(primary),
          primary_age_ms = primary_age,
          primary_ttl_ms = primary_ttl,
          primary_tier = primary_tier,
          best_next = best.next_hop,
          best_hops = cand_hops(best),
          primary_minus_best_hops = delta,
          candidate_count = #entry.candidates,
          mobile_touched = mobile_touched and 1 or 0,
        })
      end
    end
  end
end

function debug_window_active(self, now)
  if self.debug_start_ms == nil and self.debug_end_ms == nil then return false end
  now = now or self:now()
  if self.debug_start_ms ~= nil and now < self.debug_start_ms then return false end
  if self.debug_end_ms ~= nil and now > self.debug_end_ms then return false end
  return true
end

function debug_window_configured(self)
  return self.debug_start_ms ~= nil or self.debug_end_ms ~= nil
end

function debug_emit_allowed(self, now)
  if not debug_window_configured(self) then return true end
  return debug_window_active(self, now)
end

emit_rt_debug_route = function(self, dest_id, reason, detail)
  local now = self:now()
  if not debug_window_active(self, now) then return end
  local entry = self.rt and self.rt[dest_id]
  local candidates = {}
  if entry and entry.candidates then
    for slot, c in ipairs(entry.candidates) do
      local ttl = route_ttl_for_candidate(self, c)
      local age = c.last_seen_ms and (now - c.last_seen_ms) or nil
      candidates[#candidates + 1] = {
        slot = slot,
        next_hop = c.next_hop,
        n2_hop = c.n2_hop,
        hops = c.hops,
        score = q4_to_db(c.score),
        score_eff = q4_to_db(effective_score(self, c, entry.candidates, self.routing_snr_floor_q4)),
        age_ms = age,
        ttl_ms = ttl,
        expires_in_ms = (ttl and ttl > 0 and age) and (ttl - age) or nil,
        is_gateway = c.is_gateway == true,
        mobile_touched = route_mobile_touched(self, dest_id, c),
        next_tier = get_neighbor_tier(self, c.next_hop),
        next_blind = is_blind(self, c.next_hop),
        suspect_level = get_peer_suspect_level(self, c.next_hop),
      }
    end
  end
  self:emit("rt_debug_snapshot", {
    reason = reason or "debug_window",
    detail = detail,
    node_id = self.id,
    layer_id = self.layer_id,
    active_layer_id = self.active_layer_id or self.layer_id,
    leaf_id = self.leaf_id,
    active_leaf_id = active_leaf_id(self),
    dst = dest_id,
    dirty = entry and entry.dirty == true or false,
    deleted = entry == nil,
    candidate_count = #candidates,
    candidates = candidates,
  })
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
  local entry = refresh_route_order(self, px.dst, "cascade_order")
  if not entry then return nil end
  for _, c in ipairs(entry.candidates) do
    if next_hop_selectable(self, px.dst, c, px.previous_hop, px.alts_tried,
                           nil, "cascade_order")
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

local function candidate_silent_counts(self, entry, previous_hop)
  local total = 0
  local silent = 0
  if not entry or not entry.candidates then return 0, 0 end
  for _, c in ipairs(entry.candidates) do
    if c.next_hop ~= previous_hop then
      total = total + 1
      if get_peer_suspect_level(self, c.next_hop) >= 2 then
        silent = silent + 1
      end
    end
  end
  return total, silent
end

local function candidate_stale_next_counts(self, entry, previous_hop)
  local total = 0
  local stale = 0
  if not entry or not entry.candidates then return 0, 0 end
  for _, c in ipairs(entry.candidates) do
    if c.next_hop ~= previous_hop then
      total = total + 1
      local fresh = is_next_hop_fresh(self, c.next_hop)
      if not fresh then
        stale = stale + 1
      end
    end
  end
  return total, stale
end

function emit_hash_route_query(self, target_layer_id, key_hash32, reason)
  if key_hash32 == nil then return nil, false end
  target_layer_id = math.floor(target_layer_id or (self.active_layer_id or self.layer_id or 0))
  local q_key = string.format("hash:%d:%u", target_layer_id, key_hash32 & 0xffffffff)
  local now_q = self:now()
  local last_q = self.q_queried[q_key]
  if last_q and (now_q - last_q) < self.q_query_ttl_ms then
    return last_q, false
  end
  if not gateway_layer_enabled(self, target_layer_id) then
    return now_q, false
  end

  local q_leaf_id = self.leaf_id
  local q_routing_sf = self.routing_sf
  if target_layer_id == (self.layer_id or 0) then
    activate_primary_layer(self, "q_hash")
  else
    local rec = gateway_layer_record(self, target_layer_id)
    if rec == nil then return now_q, false end
    activate_gateway_layer(self, rec, "q_hash")
    q_leaf_id = rec.leaf_id
    q_routing_sf = rec.routing_sf
  end

  if self.q_queried[q_key] == nil
     and table_cap_hit(self, "q_queried", count_keys(self.q_queried),
                       self.cap_q_queried or 0, "refuse", {key = q_key}) then
    return now_q, false
  end
  self.q_queried[q_key] = now_q
  local ttl0 = self.hash_query_max_ttl or 6
  self:emit("h_tx", {
    origin = self.id,
    key_hash32 = key_hash32,
    ttl = ttl0,
    reason = reason or "hash_query",
    tx_layer_id = target_layer_id,
    tx_leaf_id = q_leaf_id,
    tx_routing_sf = q_routing_sf,
  })
  self:log(string.format(
    "h_tx -> key_hash32=%u layer=%d ttl=%d (hash-locate flood, reason=%s)",
    key_hash32, target_layer_id, ttl0, reason or "hash_query"))
  tx_initiating(self, pack_h_query(self.id, q_leaf_id, key_hash32, ttl0), {
    sf    = q_routing_sf,
    label = "H",
    info  = string.format("origin=%s hash32=%u layer=%d ttl=%d reason=%s",
                          name_of(self, self.id), key_hash32,
                          target_layer_id, ttl0, reason or "hash_query"),
  })
  return now_q, true
end

local function defer_send_for_route(self, origin, dst_id, dst_name, payload,
                                    user_text, ctr, flags, reason,
                                    previous_hop, queue_meta,
                                    candidate_total, blocked_count, blocked_kind)
  if table_cap_hit(self, "deferred_sends", #self.deferred_sends,
                   self.cap_deferred_sends or 0, "refuse",
                   {origin = origin, dst = dst_id, ctr = ctr, reason = reason}) then
    return
  end
  local deferred = {
    origin       = origin, dst_id = dst_id, dst_name = dst_name,
    payload      = payload, user_text = user_text, ctr = ctr, flags = flags,
    previous_hop = previous_hop,
    queued_at_ms = (queue_meta and queue_meta.enqueue_time_ms) or self:now(),
    reason       = reason,
    tx_layer_id  = queue_meta and queue_meta.tx_layer_id or nil,
    e2e_registered = origin == self.id and ((flags or 0) & DATA_FLAG_E2E_ACK_REQ) ~= 0,
  }
  table.insert(self.deferred_sends, deferred)
  self:emit("send_deferred", {
    origin     = origin, dst = dst_id, dst_name = dst_name,
    payload    = user_text, ctr = ctr,
    ttl_ms     = self.send_defer_ttl_ms,
    depth      = #self.deferred_sends,
    reason     = reason or "no_route",
    silent_candidates = blocked_kind == "silent" and blocked_count or nil,
    stale_next_candidates = blocked_kind == "stale_next" and blocked_count or nil,
    blocked_candidates = blocked_count,
    route_blocked_kind = blocked_kind,
    candidate_count = candidate_total,
    tx_layer_id = deferred.tx_layer_id,
  })
  self:log(string.format(
    "send_deferred dst=%s reason=%s (holding for up to %dms; depth=%d)",
    dst_name, reason or "no_route", self.send_defer_ttl_ms, #self.deferred_sends))
  if deferred.tx_layer_id ~= nil then
    if deferred.tx_layer_id == (self.layer_id or 0) then
      activate_primary_layer(self, "q_route")
    else
      local rec = gateway_layer_record(self, deferred.tx_layer_id)
      if rec ~= nil then activate_gateway_layer(self, rec, "q_route") end
    end
  end
  -- Expanding ring: first probe at ttl=1 (radius 2 — cheap, catches the common
  -- "dst is 2 hops away via a node that already has the route" case). The
  -- defer-requery tick escalates to the full flood radius if this fails.
  local q_at, q_sent = emit_route_request(self, dst_id, dst_name, reason or "no_route", 1)
  deferred.q_sent_at_ms = q_at
  if not q_sent then
    self:emit("route_request_suppressed", {
      dst = dst_id,
      dst_name = dst_name,
      reason = reason or "no_route",
      last_r_ms = q_at,
    })
  end
end

function enqueue_gateway_handoff(self, gw_env, d_origin, binding)
  local target_id = binding.node_id
  local forward_ctr = self:next_ctr(target_id)
  local forward_inner = string.char(0) .. string.char(self.id) .. gw_env.body
  table.insert(self.tx_queue, {
    origin     = self.id,
    dst_id     = target_id,
    dst_name   = name_of(self, target_id),
    payload    = forward_inner,
    user_text  = gw_env.body,
    ctr        = forward_ctr,
    flags      = 0,
    gw_relay   = true,                  -- cross-layer forward → RTS_FLAG_RELAY (§10a exempt)
    enqueue_time_ms = self:now(),
    requeue_count   = 0,
    next_attempt_ms = 0,
    tx_layer_id     = gw_env.target_layer_id,
  })
  self:emit("gateway_handoff_enqueued", {
    origin = d_origin,
    via_gateway = self.id,
    target_layer_id = gw_env.target_layer_id,
    dst = target_id,
    dst_key_hash32 = gw_env.dst_key_hash32,
    payload = gw_env.body,
    ctr = forward_ctr,
    depth = #self.tx_queue,
    binding_source = binding.source,
  })
  self:log(string.format(
    "gateway_handoff_enqueued layer=%d key_hash32=%u dst=%s ctr=%d",
    gw_env.target_layer_id, gw_env.dst_key_hash32,
    name_of(self, target_id), forward_ctr))
  -- Wake the shared queue after the current RX/TX callback unwinds. The queued
  -- item carries tx_layer_id=target_layer_id, so issue_send() will retune to
  -- the correct gateway layer/window before emitting RTS.
  self:after(1, function() become_free(self) end)
end

-- 'H'-frame flood dedup: have we already forwarded/answered this query?
-- Keyed by (origin, key_hash32) with hash_query_seen_ttl_ms aging.
-- Global (not `local function`) to stay under the 200-locals-per-chunk
-- Lua limit — same reason as the other globally-scoped helpers here.
function hash_query_seen_recently(self, origin, key_hash32)
  self.hash_query_seen = self.hash_query_seen or {}
  local key = string.format("%d|%u", origin or -1, key_hash32 & 0xffffffff)
  local now = self:now()
  local last = self.hash_query_seen[key]
  if last ~= nil and (now - last) < (self.hash_query_seen_ttl_ms or 10000) then
    return true
  end
  return false
end

function mark_hash_query_seen(self, origin, key_hash32)
  self.hash_query_seen = self.hash_query_seen or {}
  local key = string.format("%d|%u", origin or -1, key_hash32 & 0xffffffff)
  if self.hash_query_seen[key] == nil
     and table_cap_hit(self, "hash_query_seen", count_keys(self.hash_query_seen),
                       self.cap_hash_query_seen or 0, "refuse", {key = key}) then
    return
  end
  self.hash_query_seen[key] = self:now()
end

-- 'R' RREQ flood dedup, keyed (origin, dst_id). Mirrors hash_query_seen.
function route_request_seen_recently(self, origin, dst_id)
  self.route_request_seen = self.route_request_seen or {}
  local key = string.format("%d|%d", origin or -1, dst_id or -1)
  local last = self.route_request_seen[key]
  return last ~= nil and (self:now() - last) < (self.route_request_seen_ttl_ms or 10000)
end

function mark_route_request_seen(self, origin, dst_id)
  self.route_request_seen = self.route_request_seen or {}
  local key = string.format("%d|%d", origin or -1, dst_id or -1)
  if self.route_request_seen[key] == nil
     and table_cap_hit(self, "route_request_seen", count_keys(self.route_request_seen),
                       self.cap_route_request_seen or 0, "refuse", {key = key}) then
    return
  end
  self.route_request_seen[key] = self:now()
end

-- Originate a route request ('R' RREQ flood, PROTOCOL §3.7b). Expanding ring:
-- the first try (issue_send no-route path) passes ttl=1 (cheap, like the old
-- single-hop Q); the defer-requery escalates to route_request_max_ttl. Per-dst
-- rate-limit suppresses re-floods at the same-or-lower TTL inside the dedup
-- window, but allows escalation.
function emit_route_request(self, dst_id, dst_name, reason, ttl)
  ttl = ttl or self.route_request_max_ttl or 8
  self.route_request_last = self.route_request_last or {}
  local now = self:now()
  local last = self.route_request_last[dst_id]
  if last ~= nil and (now - last.t) < (self.route_request_seen_ttl_ms or 10000)
     and ttl <= last.ttl then
    return now, false
  end
  if last == nil
     and table_cap_hit(self, "route_request_last", count_keys(self.route_request_last),
                       self.cap_route_request_last or 0, "refuse",
                       {key = "dst:" .. tostring(dst_id)}) then
    return now, false
  end
  self.route_request_last[dst_id] = { t = now, ttl = ttl }
  self:emit("r_tx", {
    dst = dst_id, dst_name = dst_name, ttl = ttl, reason = reason or "route_query",
  })
  self:log(string.format("r_tx -> dst=%s ttl=%d reason=%s (RREQ)",
    dst_name, ttl, reason or "route_query"))
  tx_initiating(self, pack_r_request(self.id, active_leaf_id(self), dst_id, ttl, 0), {
    sf    = active_routing_sf(self),
    label = "F",
    info  = string.format("rreq dst=%s ttl=%d", dst_name, ttl),
  })
  return now, true
end

-- Send an RREP toward `origin` for destination `dst_id`, hops_to_dst so far.
-- Forwarded one hop at a time along the reverse path the RREQ flood laid down
-- (rt[origin]); each forwarder installs the forward route to dst. Returns false
-- if we have no reverse route to origin (RREP can't start / continue).
function send_route_reply(self, origin, dst_id, hops_to_dst)
  local entry = self.rt[origin]
  local cand = entry and entry.candidates and entry.candidates[1]
  if cand == nil then
    self:emit("rrep_drop_no_reverse", { origin = origin, dst = dst_id })
    return false
  end
  local nh = cand.next_hop
  self:emit("rrep_tx", { origin = origin, dst = dst_id, next = nh, hops = hops_to_dst })
  tx_initiating(self, pack_r_reply(origin, active_leaf_id(self), dst_id, nh, hops_to_dst), {
    sf    = active_routing_sf(self),
    label = "F",
    info  = string.format("rrep origin=%s dst=%s next=%s hops=%d",
                          name_of(self, origin), name_of(self, dst_id),
                          name_of(self, nh), hops_to_dst),
  })
  return true
end

-- Resolver reply to an 'H' query: routed unicast DATA back to the querying
-- gateway carrying the (target_layer, node_id, key_hash32) binding. Reuses
-- the normal tx_queue/issue_send path — routing already knows how to reach
-- the gateway's node_id on this layer.
function send_hash_bind_response(self, to_gateway_id, target_layer_id, resolved_node_id, key_hash32)
  local body  = pack_hash_bind_response(target_layer_id, resolved_node_id, key_hash32)
  local inner = string.char(0) .. string.char(self.id) .. body
  local ctr   = self:next_ctr(to_gateway_id)
  -- user_text is the human-readable label emitted in send-path telemetry;
  -- the binary binding rides in `payload` (inner). Keep user_text safe
  -- (the body has raw key_hash32 bytes that aren't valid UTF-8).
  table.insert(self.tx_queue, {
    origin     = self.id,
    dst_id     = to_gateway_id,
    dst_name   = name_of(self, to_gateway_id),
    payload    = inner,
    user_text  = "[hash-bind-response]",
    ctr        = ctr,
    flags      = 0,
    enqueue_time_ms = self:now(),
    requeue_count   = 0,
    next_attempt_ms = 0,
    tx_layer_id     = self.active_layer_id or self.layer_id,
  })
  self:emit("hash_bind_response_enqueued", {
    to = to_gateway_id, node = resolved_node_id,
    key_hash32 = key_hash32, target_layer_id = target_layer_id, ctr = ctr,
  })
  self:log(string.format(
    "hash_bind_response_enqueued -> %s node=%s key_hash32=%u layer=%d ctr=%d",
    name_of(self, to_gateway_id), name_of(self, resolved_node_id),
    key_hash32, target_layer_id, ctr))
  self:after(1, function() become_free(self) end)
end

function gateway_binding_for_env(self, gw_env)
  if gw_env == nil then return nil, "not_found" end
  if gw_env.target_layer_id == (self.layer_id or 0) then
    local node_id = id_bind_find_by_hash(self, gw_env.dst_key_hash32)
    if node_id ~= nil then
      return {
        layer_id = gw_env.target_layer_id,
        node_id = node_id,
        key_hash32 = gw_env.dst_key_hash32,
        source = "local_id_bind",
      }
    end
    return nil, "not_found"
  end
  local rec, err = gateway_remote_bind_find(self, gw_env.target_layer_id,
                                            gw_env.dst_key_hash32)
  if rec ~= nil then return rec end
  return nil, err or "not_found"
end

function defer_gateway_handoff(self, gw_env, d_origin, reason)
  if self.gateway_deferred_handoffs == nil then self.gateway_deferred_handoffs = {} end
  if table_cap_hit(self, "gateway_deferred_handoffs",
                   #self.gateway_deferred_handoffs,
                   self.cap_gateway_deferred_handoffs or 0, "refuse",
                   {origin = d_origin,
                    target_layer_id = gw_env.target_layer_id,
                    reason = reason}) then
    return
  end
  local now = self:now()
  local q_at, q_sent = emit_hash_route_query(self, gw_env.target_layer_id,
                                             gw_env.dst_key_hash32,
                                             reason or "gateway_no_binding")
  table.insert(self.gateway_deferred_handoffs, {
    origin = d_origin,
    gw_env = gw_env,
    queued_at_ms = now,
    q_sent_at_ms = q_at,
    reason = reason or "not_found",
  })
  self:emit("gateway_handoff_deferred", {
    origin = d_origin,
    via_gateway = self.id,
    target_layer_id = gw_env.target_layer_id,
    dst_key_hash32 = gw_env.dst_key_hash32,
    payload = gw_env.body,
    reason = reason or "not_found",
    q_sent = q_sent,
    ttl_ms = self.gateway_handoff_defer_ttl_ms,
    depth = #self.gateway_deferred_handoffs,
  })
end

function try_drain_gateway_handoffs(self)
  if self.gateway_deferred_handoffs == nil or #self.gateway_deferred_handoffs == 0 then return end
  local now = self:now()
  local kept = {}
  for _, d in ipairs(self.gateway_deferred_handoffs) do
    local binding, binding_error = gateway_binding_for_env(self, d.gw_env)
    if binding ~= nil and gateway_layer_enabled(self, d.gw_env.target_layer_id) then
      enqueue_gateway_handoff(self, d.gw_env, d.origin, binding)
      self:emit("gateway_handoff_drained", {
        origin = d.origin,
        via_gateway = self.id,
        target_layer_id = d.gw_env.target_layer_id,
        dst_key_hash32 = d.gw_env.dst_key_hash32,
        payload = d.gw_env.body,
        waited_ms = now - d.queued_at_ms,
        dst = binding.node_id,
        binding_source = binding.source,
      })
    elseif (now - d.queued_at_ms) >= self.gateway_handoff_defer_ttl_ms then
      self:emit("gateway_handoff_giveup", {
        origin = d.origin,
        via_gateway = self.id,
        target_layer_id = d.gw_env.target_layer_id,
        dst_key_hash32 = d.gw_env.dst_key_hash32,
        payload = d.gw_env.body,
        waited_ms = now - d.queued_at_ms,
        reason = binding_error or d.reason or "not_found",
      })
    else
      local q_at, q_sent = emit_hash_route_query(self, d.gw_env.target_layer_id,
                                                 d.gw_env.dst_key_hash32,
                                                 "gateway_deferred")
      if q_sent then d.q_sent_at_ms = q_at end
      table.insert(kept, d)
    end
  end
  self.gateway_deferred_handoffs = kept
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

  local px_next_fresh = is_next_hop_fresh(self, px.next)
  if not px_next_fresh then
    emit_stale_next_skip(self, px.dst, px.next, "tx_rts_retry")
    px.alts_tried[px.next] = true
    local next_hop = pick_next_cascade_hop(self, px)
    if next_hop ~= nil then
      self:emit("tx_stale_next_alt", {
        origin = px.origin, payload = px.user_text, ctr = px.ctr,
        ctr_lo = px.ctr_lo, dst = px.dst,
        from_next = px.next, to_next = next_hop,
        source = "tx_rts_retry",
      })
      self:log(string.format("tx_stale_next_alt (tx_rts_retry) msg=%d %s -> %s",
        px.ctr_lo, name_of(self, px.next), name_of(self, next_hop)))
      px.next = next_hop
      px.retries_left = effective_rts_max_retries(self, px.requeue_count)
    else
      local saved = px
      self.pending_tx = nil
      self:emit("tx_stale_next_defer", {
        origin = saved.origin, payload = saved.user_text, ctr = saved.ctr,
        ctr_lo = saved.ctr_lo, dst = saved.dst, next = saved.next,
        source = "tx_rts_retry",
      })
      defer_send_for_route(self, saved.origin, saved.dst, name_of(self, saved.dst),
                           saved.payload, saved.user_text, saved.ctr,
                           saved.flags or 0, "all_candidates_stale_next",
                           saved.previous_hop,
                           {
                             enqueue_time_ms = saved.enqueue_time_ms,
                             requeue_count = saved.requeue_count or 0,
                             tx_layer_id = saved.tx_layer_id,
                           },
                           nil, nil, "stale_next")
      become_free(self)
      return
    end
  end

  if get_peer_suspect_level(self, px.next) >= 2 then
    px.alts_tried[px.next] = true
    local next_hop = pick_next_cascade_hop(self, px)
    if next_hop ~= nil then
      self:emit("tx_silent_alt", {
        origin = px.origin, payload = px.user_text, ctr = px.ctr,
        ctr_lo = px.ctr_lo, dst = px.dst,
        from_next = px.next, to_next = next_hop,
        source = "tx_rts_retry",
      })
      self:log(string.format("tx_silent_alt (tx_rts_retry) msg=%d %s -> %s",
        px.ctr_lo, name_of(self, px.next), name_of(self, next_hop)))
      px.next = next_hop
      px.retries_left = effective_rts_max_retries(self, px.requeue_count)
    else
      local saved = px
      self.pending_tx = nil
      self:emit("tx_silent_defer", {
        origin = saved.origin, payload = saved.user_text, ctr = saved.ctr,
        ctr_lo = saved.ctr_lo, dst = saved.dst, next = saved.next,
        source = "tx_rts_retry",
      })
      defer_send_for_route(self, saved.origin, saved.dst, name_of(self, saved.dst),
                           saved.payload, saved.user_text, saved.ctr,
                           saved.flags or 0, "all_candidates_silent",
                           saved.previous_hop,
                           {
                             enqueue_time_ms = saved.enqueue_time_ms,
                             requeue_count = saved.requeue_count or 0,
                             tx_layer_id = saved.tx_layer_id,
                           },
                           nil, nil, "silent")
      become_free(self)
      return
    end
  end

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

  local gateway_delay_ms = gateway_schedule_defer_ms(self, px.next)
  if gateway_delay_ms > 0 then
    self:emit("tx_gateway_schedule_defer", {
      origin = px.origin,
      payload = px.user_text,
      ctr = px.ctr,
      ctr_lo = px.ctr_lo,
      dst = px.dst,
      next_hop = px.next,
      delay_ms = gateway_delay_ms,
      active_leaf_id = active_leaf_id(self),
      source = "tx_rts_retry",
      reason = reason,
    })
    self:log(string.format("tx_gateway_schedule_defer (tx_rts_retry) msg=%d -> %s deferred %dms",
      px.ctr_lo, name_of(self, px.next), gateway_delay_ms))
    self:after(gateway_delay_ms, function() tx_rts_retry(self, reason) end)
    return
  end

  -- payload_len lets the receiver size its pending_rx_expiry to the
  -- actual DATA airtime instead of max_payload_bytes worst-case.
  if px.tx_layer_id ~= nil and px.tx_layer_id ~= (self.active_layer_id or self.layer_id) then
    local rec = gateway_layer_record(self, px.tx_layer_id)
    if rec then activate_gateway_layer(self, rec, "tx_retry") end
  end
  local _rts_flags = (((px.flags or 0) & DATA_FLAG_PAYLOAD_TYPE_M) ~= 0) and RTS_FLAG_M_BROADCAST or 0
  local _m_id = nil
  if (_rts_flags & RTS_FLAG_M_BROADCAST) ~= 0 and px.payload and #px.payload >= 4 then
    _m_id = channel_msg_id_from_bytes(px.payload, 1)
  end
  if px.gw_relay then _rts_flags = _rts_flags | RTS_FLAG_RELAY end   -- gateway forward (§10a exempt)
  local rts = pack_rts(px.tx_leaf_id or active_leaf_id(self), self.id, px.dst, px.next, px.ctr_lo,
                       px.tx_sf_bitmap or active_allowed_sf_bitmap(self), #px.payload + MAC_LEN,
                       _rts_flags, _m_id)
  px.retry_reason = reason
  local attempt_seq = emit_rts_attempt_detail(self, "retry", px)
  px.retry_reason = nil
  self:emit("rts_retry", {
    attempt_seq = attempt_seq,
    origin = px.origin, payload = px.user_text, ctr = px.ctr,
    dst = px.dst, next = px.next,
    ctr_lo = px.ctr_lo, retries_left = px.retries_left, reason = reason,
    tx_layer_id = px.tx_layer_id,
    tx_leaf_id = px.tx_leaf_id or active_leaf_id(self),
    tx_routing_sf = px.tx_routing_sf or active_routing_sf(self),
  })
  self:log(string.format("rts_retry -> %s ctr_lo=%d (retries_left=%d reason=%s)",
    name_of(self, px.next), px.ctr_lo, px.retries_left, reason))
  tx_initiating(self, rts, {
    sf    = px.tx_routing_sf or active_routing_sf(self),
    label = "RTS-rty",
    info  = string.format("retry next=%s msg=%d retries_left=%d reason=%s attempt_seq=%d",
      name_of(self, px.next), px.ctr_lo, px.retries_left, reason, attempt_seq),
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
    tx_layer_id     = px.tx_layer_id,
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

  self:emit("rts_attempt_timeout", {
    attempt_seq = self.pending_tx.last_rts_attempt_seq,
    origin = self.pending_tx.origin,
    payload = self.pending_tx.user_text,
    ctr = self.pending_tx.ctr,
    dst = self.pending_tx.dst,
    next = self.pending_tx.next,
    ctr_lo = captured_ctr_lo,
    reason = "cts_timeout",
  })

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

  record_peer_rts_timeout(self, self.pending_tx.next, captured_ctr_lo)

  if get_peer_suspect_level(self, self.pending_tx.next) >= 2 then
    self.pending_tx.alts_tried[self.pending_tx.next] = true
    local next_hop = pick_next_cascade_hop(self, self.pending_tx)
    if next_hop ~= nil then
      local prev_next = self.pending_tx.next
      self:emit("path_cascade", {
        origin     = self.pending_tx.origin,
        payload    = self.pending_tx.user_text,
        ctr        = self.pending_tx.ctr,
        dst        = self.pending_tx.dst,
        ctr_lo     = captured_ctr_lo,
        from_next  = prev_next,
        to_next    = next_hop,
        attempt    = set_size(self.pending_tx.alts_tried),
        trigger    = "silent_next",
      })
      self:emit("tx_silent_alt", {
        origin = self.pending_tx.origin,
        payload = self.pending_tx.user_text,
        ctr = self.pending_tx.ctr,
        ctr_lo = captured_ctr_lo,
        dst = self.pending_tx.dst,
        from_next = prev_next,
        to_next = next_hop,
        source = "rts_timeout",
      })
      self:log(string.format("tx_silent_alt (rts_timeout) msg=%d %s -> %s",
        captured_ctr_lo, name_of(self, prev_next), name_of(self, next_hop)))
      self.pending_tx.next = next_hop
      self.pending_tx.retries_left = effective_rts_max_retries(self, self.pending_tx.requeue_count)
      tx_rts_retry(self, "silent_next")
      return
    end

    local saved = self.pending_tx
    self.pending_tx = nil
    self:emit("tx_silent_defer", {
      origin = saved.origin,
      payload = saved.user_text,
      ctr = saved.ctr,
      ctr_lo = captured_ctr_lo,
      dst = saved.dst,
      next = saved.next,
      source = "rts_timeout",
    })
    defer_send_for_route(self, saved.origin, saved.dst, name_of(self, saved.dst),
                         saved.payload, saved.user_text, saved.ctr,
                         saved.flags or 0, "all_candidates_silent",
                           saved.previous_hop,
                           {
                           enqueue_time_ms = saved.enqueue_time_ms,
                           requeue_count = saved.requeue_count or 0,
                           tx_layer_id = saved.tx_layer_id,
                         },
                         nil, nil, "silent")
    become_free(self)
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
-- receiver expired and cleared, our duplicate-RTS dedup replies with
-- CTS already_received=1 from last_acked_from cache (or a fresh dance
-- starts cleanly).
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
  self.pending_tx.awaiting_cts = true
  self.pending_tx.awaiting_ack = false
  if self.rts_timeout_handle then
    self:cancel(self.rts_timeout_handle)
    self.rts_timeout_handle = nil
  end
  -- F1 mitigation safety net: exponential backoff per retry attempt.
  -- attempt_idx = how many retries we've already burned on this ctr_lo.
  -- Fresh budget (issue_send / NACK alt / blind alt) → attempt_idx = 0
  -- → base timeout. Each subsequent retry doubles up to RTS_TIMEOUT_BACKOFF_CAP.
  local attempt_idx = self.rts_max_retries - self.pending_tx.retries_left
  local base_ms = self.rts_timeout_override_ms
                  or rts_timeout_base_ms(self, self.pending_tx.tx_routing_sf)
  local timeout_ms = rts_timeout_for_attempt(base_ms, attempt_idx)
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
  local ack_sf = self.pending_tx.tx_routing_sf or self.routing_sf
  local ack_air = airtime_ms(ack_sf, self.bw_hz, self.cr, self.preamble_sym, ACK_LEN)
  local delay = data_air + ack_air
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
  local cts_air = airtime_ms(active_routing_sf(self), self.bw_hz, self.cr,
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
    local d_rt = self.rt
    if d.tx_layer_id ~= nil then
      d_rt = ensure_layer_state(self, d.tx_layer_id).rt
    end
    -- TTL check must come BEFORE the route-exists branch. Previously
    -- the TTL was gated on "route absent", which meant a message that
    -- kept getting deferred with reason=all_candidates_silent (route
    -- exists, but every K=3 alt next-hop was duty-saturated and refused
    -- CTS) would cycle forever — each drain attempt found the route
    -- present, redrained, redeferred, with no TTL exit. s12 6h showed
    -- one message accumulating 477 deferrals over 5.7 hours, consuming
    -- airtime for futile retries while DMs queued behind it.
    if (now - d.queued_at_ms) >= self.send_defer_ttl_ms then
      self:emit("send_giveup", {
        origin     = d.origin, dst = d.dst_id, dst_name = d.dst_name,
        payload    = d.user_text, ctr = d.ctr,
        waited_ms  = now - d.queued_at_ms,
        reason     = "defer_ttl",
      })
      self:log(string.format(
        "send_giveup dst=%s waited=%dms (defer TTL %dms expired)",
        d.dst_name, now - d.queued_at_ms, self.send_defer_ttl_ms))
    elseif d_rt[d.dst_id] ~= nil then
      table.insert(drained, d)
    else
      local q_at, q_sent = emit_route_request(self, d.dst_id, d.dst_name,
                                            d.reason or "deferred_no_route",
                                            self.route_request_max_ttl)
      if q_sent then
        d.q_sent_at_ms = q_at
        self:emit("send_defer_requery", {
          origin = d.origin, dst = d.dst_id, dst_name = d.dst_name,
          payload = d.user_text, ctr = d.ctr,
          waited_ms = now - d.queued_at_ms,
        })
      end
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
      local next_attempt_ms = 0
      local settle_ms = 0
      if d.q_sent_at_ms ~= nil and self.q_response_settle_ms > 0 then
        local settle_until = d.q_sent_at_ms + self.q_response_settle_ms
        if now < settle_until then
          settle_ms = (settle_until - now)
                    + self:rand(0, self.lbt_backoff_ms + 1)
          next_attempt_ms = now + settle_ms
        end
      end
      self:emit("send_drained", {
        origin     = d.origin, dst = d.dst_id, dst_name = d.dst_name,
        payload    = d.user_text, ctr = d.ctr,
        waited_ms  = now - d.queued_at_ms,
        settle_ms  = settle_ms,
        next_attempt_ms = next_attempt_ms,
        tx_layer_id = d.tx_layer_id,
      })
      self:log(string.format(
        "send_drained dst=%s waited=%dms settle=%dms (route appeared) → tx_queue",
        d.dst_name, now - d.queued_at_ms, settle_ms))
      d.enqueue_time_ms = d.queued_at_ms
      d.requeue_count   = 0
      d.next_attempt_ms = next_attempt_ms
      if d.origin == self.id
         and ((d.flags or 0) & DATA_FLAG_E2E_ACK_REQ) ~= 0
         and not d.e2e_registered then
        local e2e_key = pending_e2e_key(d.dst_id, d.ctr)
        self.pending_e2e[e2e_key] = {
          sent_at_ms = self:now(),
          ctr        = d.ctr,
          dst_id     = d.dst_id,
          dst_name   = d.dst_name,
          user_text  = d.user_text,
        }
        d.e2e_registered = true
        self:emit("e2e_ack_pending", {
          origin = self.id, ctr = d.ctr, dst = d.dst_id,
          ttl_ms = self.e2e_ack_ttl_ms,
        })
      end
      table.insert(self.tx_queue, 1, d)
    end
    become_free(self)
  end
end

-- 2B-broadcast initial-RTS-emit helper. Same code path runs for the
-- initial broadcast attempt and for any on_radio_busy retry — receivers
-- always see a fresh RTS announce before the DATA-M, so their overhear-
-- arm windows are sized off the actual RTS-receive time, not stale.
-- Reads everything it needs from `px` (= self.pending_tx). Bumps the
-- attempt generation so a stale on_handed-scheduled pending_tx clear
-- from a prior attempt doesn't fire mid-retry.
function fire_m_broadcast_rts(self, px)
  px.m_broadcast_attempt_gen = (px.m_broadcast_attempt_gen or 0) + 1
  local payload_len = #px.payload + MAC_LEN
  local m_id = nil
  if px.payload and #px.payload >= 4 then
    m_id = channel_msg_id_from_bytes(px.payload, 1)
  end
  local rts = pack_rts(px.tx_leaf_id, self.id, px.dst, px.next, px.ctr_lo,
                       px.tx_sf_bitmap, payload_len,
                       RTS_FLAG_M_BROADCAST, m_id)
  local label = (px.origin == self.id) and "RTS" or "RTS-fwd"
  local kind = (px.m_broadcast_attempt_gen == 1) and "initial" or "m_retry"
  local attempt_seq = emit_rts_attempt_detail(self, kind, px)
  self:emit("rts_tx", {
    attempt_seq = attempt_seq,
    origin = px.origin, payload = px.user_text, ctr = px.ctr,
    dst = px.dst, next = px.next, ctr_lo = px.ctr_lo,
    sf_bitmap = px.tx_sf_bitmap,
    tx_layer_id = px.tx_layer_id,
    tx_leaf_id = px.tx_leaf_id,
    tx_routing_sf = px.tx_routing_sf,
    m_broadcast_attempt_gen = px.m_broadcast_attempt_gen,
  })
  self:log(string.format(
    "rts_tx (m_broadcast gen=%d) -> %s ctr_lo=%d origin=%s ctr=%d",
    px.m_broadcast_attempt_gen, name_of(self, px.next),
    px.ctr_lo, name_of(self, px.origin), px.ctr))
  tx_initiating(self, rts, {
    sf    = px.tx_routing_sf,
    label = label,
    info  = string.format(
      "origin=%s dst=%s next=%s msg=%d ctr=%d sf_bitmap=0x%02x attempt_seq=%d payload=%q m_broadcast=1 gen=%d",
      name_of(self, px.origin), name_of(self, px.dst),
      name_of(self, px.next), px.ctr_lo, px.ctr, px.tx_sf_bitmap,
      attempt_seq, px.user_text, px.m_broadcast_attempt_gen),
    on_handed = function() start_data_tx_for_broadcast(self, px) end,
  })
end

-- 2B-broadcast DATA-tx for M-payload. Mirrors the CTS-rx → DATA-tx flow
-- but skips the CTS wait (sender announced chosen_data_sf in the RTS's
-- M_BROADCAST encoding) and the ACK wait (broadcast is fire-and-forget;
-- failures recover via the next BCN-digest cascade, eventually-
-- consistent). Receivers retune to chosen_data_sf when they see the
-- M_BROADCAST RTS — no CTS needed to communicate the SF choice.
-- Triggered as opts.on_handed on the RTS-tx (which fires on actual TX
-- even after duty-cycle deferral, unlike tx_initiating's after_tx).
function start_data_tx_for_broadcast(self, px)
  -- on_handed fires when the RTS is HANDED to the radio (start of TX),
  -- not when it completes. We need to wait for the full RTS airtime
  -- before TXing the DATA-M frame, otherwise the radio rejects the
  -- DATA-tx with self_tx_in_flight. Total delay = RTS airtime +
  -- cts_to_data_gap_ms (SF settle time, mirrors the normal CTS-rx →
  -- DATA-tx gap).
  local rts_sf = px.tx_routing_sf or active_routing_sf(self)
  -- M_BROADCAST RTS carries 2 bytes id_lo16 extension (8 base + 2);
  -- regular RTS is 8 bytes. Use the larger for broadcast so we don't
  -- start DATA-M tx while RTS is still on air.
  local rts_len_eff = RTS_LEN + 2  -- broadcast always carries id_lo16
  local rts_air = airtime_ms(rts_sf, self.bw_hz, self.cr,
                              self.preamble_sym, rts_len_eff)
  local gap = rts_air + (self.cts_to_data_gap_ms or 5)
  local captured_ctr_lo = px.ctr_lo
  self:after(gap, function()
    if self.pending_tx == nil or self.pending_tx.ctr_lo ~= captured_ctr_lo then
      return
    end
    local d = pack_data(px.origin, px.next, px.dst, px.ctr, px.flags or 0,
                         px.payload, px.hop_budget)
    self:emit("data_tx", {
      origin = px.origin, payload = px.user_text, ctr = px.ctr,
      dst = px.dst, next = px.next, ctr_lo = px.ctr_lo, len = #px.payload,
      sf = px.chosen_data_sf, data_sf = px.chosen_data_sf,
      tx_layer_id = px.tx_layer_id, tx_leaf_id = px.tx_leaf_id,
      tx_routing_sf = px.tx_routing_sf or active_routing_sf(self),
      m_broadcast = true,
    })
    self:log(string.format(
      "data_tx (M-broadcast) ctr_lo=%d ctr=%d payload=%q on SF%d (no ACK expected)",
      px.ctr_lo, px.ctr, px.user_text, px.chosen_data_sf))
    local data_air = airtime_ms(px.chosen_data_sf, self.bw_hz, self.cr,
                                  self.preamble_sym, #d)
    local captured_gen = px.m_broadcast_attempt_gen or 0
    local handed = tx_with_retry(self, d, {
      sf    = px.chosen_data_sf,
      label = "DATA-M",
      info  = string.format("origin=%s m_broadcast=1 ctr=%d sf=%d payload=%q",
        name_of(self, px.origin), px.ctr, px.chosen_data_sf, px.user_text),
      on_handed = function()
        self:after(data_air + 5, function()
          -- Generation guard: an on_radio_busy retry bumps
          -- m_broadcast_attempt_gen, so this stale callback from a
          -- prior attempt must not clear pending_tx while a retry
          -- is in flight.
          if self.pending_tx ~= nil
             and self.pending_tx.ctr_lo == captured_ctr_lo
             and self.pending_tx.m_broadcast == true
             and (self.pending_tx.m_broadcast_attempt_gen or 0) == captured_gen then
            self.pending_tx = nil
            become_free(self)
          end
        end)
      end,
    })
    if not handed and self.pending_tx ~= nil
       and self.pending_tx.ctr_lo == captured_ctr_lo then
      self.pending_tx = nil
      become_free(self)
    end
  end)
end

-- payload here is the inner bytes (src_addr_len | src_addr | body) that go into the
-- DATA frame's ciphertext slot. user_text is what the user / visualizer sees in
-- emit data. ctr is the full 16-bit per-(origin,dst) outbound counter (set at
-- on_command for new sends, preserved across forwards). flags carries wire-level
-- DATA_FLAG_* bits. queue_meta is an optional table {enqueue_time_ms, requeue_count}
-- threaded from the tx_queue item through to pending_tx for cascade-requeue
-- accounting; when nil (forwarder direct path) we treat this as a fresh hop.
issue_send = function(self, origin, dst_id, dst_name, payload, user_text, ctr, flags, previous_hop, queue_meta, forward_hop_budget)
  -- Anti-spam self-monitoring: count our own originations (origin ==
  -- self.id; previous_hop == nil means we're not forwarding for someone
  -- else). Used to emit originator_self_over_budget on terminal failure
  -- so the app can surface "you may be over fair-share budget" UX.
  if origin == self.id and previous_hop == nil then
    self_originate_observe(self)
  end
  local requested_tx_layer_id = queue_meta and queue_meta.tx_layer_id or nil
  if requested_tx_layer_id ~= nil then
    if requested_tx_layer_id == (self.layer_id or 0) then
      activate_primary_layer(self, "tx_route_select")
    else
      local rec = gateway_layer_record(self, requested_tx_layer_id)
      if rec ~= nil then activate_gateway_layer(self, rec, "tx_route_select") end
    end
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
    -- Originator with no route: defer and actively ask neighbours via Q.
    defer_send_for_route(self, origin, dst_id, dst_name, payload, user_text,
                         ctr, flags, "no_route", previous_hop, queue_meta)
    return
  end
  entry = refresh_route_order(self, dst_id, "issue_send_order") or entry
  local primary_next = entry.candidates[1].next_hop
  if previous_hop ~= nil and primary_next == previous_hop then
    local replacement = nil
    for _, c in ipairs(entry.candidates) do
      if next_hop_selectable(self, dst_id, c, previous_hop, nil, nil,
                             "issue_send_previous_hop_alt")
         and route_candidate_layer_ok(c, requested_tx_layer_id)
         and not is_blind(self, c.next_hop) then
        replacement = c.next_hop
        break
      end
    end
    if replacement ~= nil then
      self:emit("tx_previous_hop_alt", {
        origin = origin, payload = user_text, ctr = ctr,
        dst = dst_id, from_next = primary_next, to_next = replacement,
      })
      self:log(string.format("tx_previous_hop_alt (issue_send) dst=%s %s -> %s",
        dst_name, name_of(self, primary_next), name_of(self, replacement)))
      primary_next = replacement
    else
      self:emit("send_no_route", {
        origin = origin, payload = user_text, ctr = ctr, dst = dst_id,
        reason = "previous_hop_only",
      })
      self:log(string.format(
        "send_no_route dst=%s (forwarder only route points back to previous hop)",
        dst_name))
      return
    end
  end
  if requested_tx_layer_id ~= nil then
    local primary_c = route_candidate_for_next(entry, primary_next)
    if not route_candidate_layer_ok(primary_c, requested_tx_layer_id) then
      emit_wrong_layer_next_skip(self, dst_id, primary_next, primary_c,
                                 requested_tx_layer_id, "issue_send_primary")
      local replacement = nil
      for _, c in ipairs(entry.candidates) do
        if next_hop_selectable(self, dst_id, c, previous_hop, nil, nil,
                               "issue_send_layer_alt")
           and route_candidate_layer_ok(c, requested_tx_layer_id)
           and not is_blind(self, c.next_hop) then
          replacement = c.next_hop
          break
        end
      end
      if replacement ~= nil then
        self:emit("tx_layer_alt", {
          origin = origin, payload = user_text, ctr = ctr,
          dst = dst_id, from_next = primary_next, to_next = replacement,
          tx_layer_id = requested_tx_layer_id,
        })
        self:log(string.format("tx_layer_alt (issue_send) dst=%s %s -> %s layer=%s",
          dst_name, name_of(self, primary_next), name_of(self, replacement),
          tostring(requested_tx_layer_id)))
        primary_next = replacement
      else
        defer_send_for_route(self, origin, dst_id, dst_name, payload, user_text,
                             ctr, flags, "all_candidates_wrong_layer", previous_hop,
                             queue_meta)
        return
      end
    end
  end
  local primary_fresh = is_next_hop_fresh(self, primary_next)
  if not primary_fresh then
    emit_stale_next_skip(self, dst_id, primary_next, "issue_send_primary")
    local total_cands, stale_cands = candidate_stale_next_counts(self, entry, previous_hop)
    local replacement = nil
    for _, c in ipairs(entry.candidates) do
      if next_hop_selectable(self, dst_id, c, previous_hop, nil, nil,
                             "issue_send_stale_alt")
         and route_candidate_layer_ok(c, requested_tx_layer_id)
         and not is_blind(self, c.next_hop) then
        replacement = c.next_hop
        break
      end
    end
    if replacement ~= nil then
      self:emit("tx_stale_next_alt", {
        origin = origin, payload = user_text, ctr = ctr,
        dst = dst_id, from_next = primary_next, to_next = replacement,
        stale_candidates = stale_cands, candidate_count = total_cands,
      })
      self:log(string.format("tx_stale_next_alt (issue_send) dst=%s %s -> %s",
        dst_name, name_of(self, primary_next), name_of(self, replacement)))
      primary_next = replacement
    else
      defer_send_for_route(self, origin, dst_id, dst_name, payload, user_text,
                           ctr, flags, "all_candidates_stale_next", previous_hop,
                           queue_meta, total_cands, stale_cands, "stale_next")
      return
    end
  end
  if get_peer_suspect_level(self, primary_next) >= 2 then
    local total_cands, silent_cands = candidate_silent_counts(self, entry, previous_hop)
    local replacement = nil
    for _, c in ipairs(entry.candidates) do
      if next_hop_selectable(self, dst_id, c, previous_hop, nil, nil,
                             "issue_send_silent_alt")
         and route_candidate_layer_ok(c, requested_tx_layer_id)
         and not is_blind(self, c.next_hop) then
        replacement = c.next_hop
        break
      end
    end
    if replacement ~= nil then
      self:emit("tx_silent_alt", {
        origin = origin, payload = user_text, ctr = ctr,
        dst = dst_id, from_next = primary_next, to_next = replacement,
        silent_candidates = silent_cands, candidate_count = total_cands,
      })
      self:log(string.format("tx_silent_alt (issue_send) dst=%s %s -> %s",
        dst_name, name_of(self, primary_next), name_of(self, replacement)))
      primary_next = replacement
    else
      defer_send_for_route(self, origin, dst_id, dst_name, payload, user_text,
                           ctr, flags, "all_candidates_silent", previous_hop,
                           queue_meta, total_cands, silent_cands, "silent")
      return
    end
  end
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
  local gateway_delay_ms = gateway_schedule_defer_ms(self, primary_next)
  if gateway_delay_ms > 0 then
    self:emit("tx_gateway_schedule_defer", {
      origin = origin,
      payload = user_text,
      ctr = ctr,
      dst = dst_id,
      next_hop = primary_next,
      delay_ms = gateway_delay_ms,
      active_leaf_id = active_leaf_id(self),
    })
    table.insert(self.tx_queue, 1, {
      origin = origin, dst_id = dst_id, dst_name = dst_name,
      payload = payload, user_text = user_text, ctr = ctr, flags = flags,
      previous_hop = previous_hop,
      enqueue_time_ms = (queue_meta and queue_meta.enqueue_time_ms) or self:now(),
      requeue_count   = (queue_meta and queue_meta.requeue_count) or 0,
      next_attempt_ms = self:now() + gateway_delay_ms,
      tx_layer_id     = queue_meta and queue_meta.tx_layer_id or nil,
    })
    self:after(gateway_delay_ms, function() become_free(self) end)
    return
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
  local tx_layer_id = queue_meta and queue_meta.tx_layer_id or nil
  local tx_layer_rec = tx_layer_id and gateway_layer_record(self, tx_layer_id) or nil
  local tx_on_primary_layer = tx_layer_id ~= nil and tx_layer_id == (self.layer_id or 0)
  local tx_leaf_id = nil
  local tx_routing_sf = nil
  local tx_sf_bitmap = nil
  if tx_on_primary_layer then
    tx_leaf_id = self.leaf_id
    tx_routing_sf = self.routing_sf
    tx_sf_bitmap = self.allowed_sf_bitmap
  else
    tx_leaf_id = tx_layer_rec and tx_layer_rec.leaf_id or active_leaf_id(self)
    tx_routing_sf = tx_layer_rec and tx_layer_rec.routing_sf or active_routing_sf(self)
    tx_sf_bitmap = tx_layer_rec and tx_layer_rec.allowed_sf_bitmap or active_allowed_sf_bitmap(self)
  end
  -- M-payload (channel gossip): broadcast variant. The RTS carries an
  -- M_BROADCAST flag PLUS the chosen_data_sf encoded in sf_bitmap (only
  -- one bit set = the SF the DATA will use). No CTS is expected — the
  -- sender announces, all in-range peers retune to chosen_data_sf and
  -- listen for the DATA. No ACK is expected either — fire-and-forget;
  -- failures recover via cascade BCN-digest re-advertisement.
  -- chosen_data_sf = max(allowed_data_sfs) for the originator's layer
  -- (largest = most robust = most receivers can decode). See ROADMAP
  -- §3.3 pathology #4, the "broadcast" variant of 2B.
  local m_broadcast = ((flags or 0) & DATA_FLAG_PAYLOAD_TYPE_M) ~= 0
  local m_chosen_data_sf = nil
  if m_broadcast then
    local sf_set = sf_bitmap_to_set(tx_sf_bitmap)
    if #sf_set > 0 then
      m_chosen_data_sf = sf_set[#sf_set]   -- list is ascending, last = max
      tx_sf_bitmap = sf_set_to_bitmap({m_chosen_data_sf})
    else
      -- Empty bitmap (shouldn't happen) — fall back to routing SF
      m_chosen_data_sf = tx_routing_sf
      tx_sf_bitmap = sf_set_to_bitmap({m_chosen_data_sf})
    end
  end
  if tx_on_primary_layer then
    activate_primary_layer(self, "tx")
  elseif tx_layer_rec then
    activate_gateway_layer(self, tx_layer_rec, "tx")
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
    gw_relay     = (queue_meta and queue_meta.gw_relay) == true,  -- gateway cross-layer forward → RTS_FLAG_RELAY
    tx_layer_id  = queue_meta and queue_meta.tx_layer_id or (self.active_layer_id or self.layer_id),
    tx_leaf_id   = tx_leaf_id,
    tx_routing_sf = tx_routing_sf,
    tx_sf_bitmap = tx_sf_bitmap,
    retries_left = effective_rts_max_retries(self,
      (queue_meta and queue_meta.requeue_count) or 0),
    alts_tried   = initial_alts_tried,
    chosen_data_sf = m_chosen_data_sf,  -- set immediately for M-broadcast; otherwise CTS fills it in
    m_broadcast  = m_broadcast,         -- triggers the no-CTS / no-ACK fire-and-forget DATA-tx path
    previous_hop = previous_hop, -- upstream node (nil at originator); blocks alt-loops
    -- Cascade-requeue accounting: enqueue_time_ms is the original tx_queue
    -- enqueue time (preserved across requeues); requeue_count is how many
    -- times this same e2e message has bounced through the cascade-requeue
    -- path. queue_meta is supplied by become_free from the popped item;
    -- forwarders calling issue_send directly pass nil → fresh hop.
    enqueue_time_ms = (queue_meta and queue_meta.enqueue_time_ms) or self:now(),
    requeue_count   = (queue_meta and queue_meta.requeue_count) or 0,
    -- §7.6 hop budget. Two paths:
    --   • Originator (forward_hop_budget == nil): initialize to
    --     rt[dst].hops + slack, capped at hop_budget_max_initial (15).
    --   • Forwarder (forward_hop_budget ~= nil): inherit the decremented
    --     budget computed at on_recv DATA time.
    -- prev_fwd_rt_hops is overwritten with self's rt view so the wire
    -- carries the current-transmitter's claim, not stale upstream info.
    hop_budget = (function()
      if forward_hop_budget ~= nil then
        return {
          remaining = forward_hop_budget.remaining,
          committed = forward_hop_budget.committed,
          prev_fwd_rt_hops = (entry.candidates[1] and entry.candidates[1].hops) or 0,
        }
      else
        local rt_hops = (entry.candidates[1] and entry.candidates[1].hops) or 1
        return {
          remaining = math.min(self.hop_budget_max_initial,
                                rt_hops + self.hop_budget_slack),
          committed = 0,
          prev_fwd_rt_hops = rt_hops,
        }
      end
    end)(),
  }
  -- payload_len = inner overhead (src_addr_len + src_addr + MAC) + body size.
  -- Body size = #payload - 2 (stripping the 2-byte inner header from inner bytes).
  -- Equivalently: #payload + MAC_LEN (since payload already has 2-byte inner hdr).
  local payload_len = #payload + MAC_LEN
  local rts_flags = (((flags or 0) & DATA_FLAG_PAYLOAD_TYPE_M) ~= 0) and RTS_FLAG_M_BROADCAST or 0
  local m_id = nil
  if (rts_flags & RTS_FLAG_M_BROADCAST) ~= 0 and payload and #payload >= 4 then
    m_id = channel_msg_id_from_bytes(payload, 1)
  end
  if self.pending_tx and self.pending_tx.gw_relay then
    rts_flags = rts_flags | RTS_FLAG_RELAY        -- gateway cross-layer forward (§10a exempt)
  end
  local rts = pack_rts(tx_leaf_id, self.id, dst_id, primary_next, mid,
                       tx_sf_bitmap, payload_len, rts_flags, m_id)
  local label = (origin == self.id) and "RTS" or "RTS-fwd"
  if m_broadcast then
    -- Initial broadcast attempt and retries share fire_m_broadcast_rts.
    -- The helper emits its own rts_attempt_detail + rts_tx so each
    -- attempt (initial or retry) shows up cleanly in the trace.
    fire_m_broadcast_rts(self, self.pending_tx)
  else
    local attempt_seq = emit_rts_attempt_detail(self, "initial", self.pending_tx)
    self:emit("rts_tx", {
      attempt_seq = attempt_seq,
      origin = origin, payload = user_text, ctr = ctr,
      dst = dst_id, next = primary_next, ctr_lo = mid,
      sf_bitmap = tx_sf_bitmap,
      tx_layer_id = self.pending_tx.tx_layer_id,
      tx_leaf_id = tx_leaf_id,
      tx_routing_sf = tx_routing_sf,
    })
    self:log(string.format("rts_tx -> %s ctr_lo=%d origin=%s ctr=%d (sf_bitmap=0x%02x)",
      name_of(self, primary_next), mid, name_of(self, origin), ctr,
      tx_sf_bitmap))
    tx_initiating(self, rts, {
      sf    = tx_routing_sf,
      label = label,
      info  = string.format("origin=%s dst=%s next=%s msg=%d ctr=%d sf_bitmap=0x%02x attempt_seq=%d payload=%q",
        name_of(self, origin), dst_name, name_of(self, primary_next),
        mid, ctr, tx_sf_bitmap, attempt_seq, user_text),
    }, function() start_rts_timeout(self) end)
  end
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
  -- Priority-aware selection (ROADMAP §3a). Among ready items, prefer:
  --   (1) DATA_FLAG_PRIORITY items over non-priority (queue precedence)
  --   (2) lower requeue_count (less-retried first)
  --   (3) lower next_attempt_ms (FIFO within tier)
  local best_idx          = nil
  local best_rcnt         = nil
  local best_next         = nil
  local best_priority     = nil
  local earliest_unready  = nil
  for i, it in ipairs(self.tx_queue) do
    local nxt = it.next_attempt_ms or 0
    if nxt <= now then
      local rcnt = it.requeue_count or 0
      local pri  = ((it.flags or 0) & DATA_FLAG_PRIORITY) ~= 0
      local replace = false
      if best_idx == nil then
        replace = true
      elseif pri ~= best_priority then
        replace = pri               -- priority always beats non-priority
      elseif rcnt < best_rcnt then
        replace = true
      elseif rcnt == best_rcnt and nxt < best_next then
        replace = true
      end
      if replace then
        best_idx, best_rcnt, best_next, best_priority = i, rcnt, nxt, pri
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
    priority = ((item.flags or 0) & DATA_FLAG_PRIORITY) ~= 0,
  })
  issue_send(self, item.origin, item.dst_id, item.dst_name,
             item.payload, item.user_text, item.ctr, item.flags or 0, item.previous_hop,
             { enqueue_time_ms = item.enqueue_time_ms,
               requeue_count   = item.requeue_count,
               tx_layer_id     = item.tx_layer_id,
               gw_relay        = item.gw_relay },
             item.forward_hop_budget)
end

-- ---------- script lifecycle ------------------------------------------------

local function in_discovery(self)
  return self.discovery_mode == true
end

local function maybe_exit_discovery(self, reason)
  if not in_discovery(self) then return end
  local now = self:now()
  local timeout_ms = self.discovery_until_ms or 0
  local heard_n = self.discovery_bcn_rx_count or 0
  local route_n = rt_count(self.rt)
  local enough_heard = heard_n >= (self.discovery_min_bcn_rx or 0)
  local enough_routes = route_n >= (self.discovery_min_routes or 0)
  local timed_out = timeout_ms > 0 and now >= timeout_ms
  if timed_out or enough_heard or enough_routes then
    self.discovery_mode = false
    self:emit("bcn_discovery_exit", {
      reason = reason or (timed_out and "timeout" or "learned"),
      heard_bcn = heard_n,
      rt_total = route_n,
      elapsed_ms = now - (self.discovery_started_ms or now),
    })
    self:log(string.format(
      "bcn_discovery_exit reason=%s heard_bcn=%d rt_total=%d elapsed=%dms",
      reason or (timed_out and "timeout" or "learned"),
      heard_n, route_n, now - (self.discovery_started_ms or now)))
  end
end

-- Takes Q4 SNR (caller converts from runtime meta.snr float).
local function learn_direct_from_frame(self, src_id, snr_q4, source)
  if src_id == nil or src_id == self.id or snr_q4 == nil then return "no_src" end
  local route_score_q4 = route_score_from_snr(self, snr_q4)
  local cand = {
    next_hop = src_id,
    score = route_score_q4,
    hops = 1,
    last_seen_ms = self:now(),
    learned_layer_id = self.active_layer_id or self.layer_id,
  }
  local action = rt_merge(self, self.rt, src_id, cand, self.routing_snr_floor_q4)
  if action == "new" or action == "promote" or action == "primary_refresh" then
    self:emit("rt_update", {
      dest = src_id,
      next = src_id,
      score = q4_to_db(route_score_q4),
      rx_snr = q4_to_db(snr_q4),
      route_snr_conservatism_db = q4_to_db(self.route_snr_conservatism_q4 or 0),
      hops = 1,
      slot = "primary",
      trigger = source or "direct_frame",
    })
    schedule_triggered_beacon(self)
  elseif action == "alt_install" then
    self:emit("rt_update", {
      dest = src_id,
      next = src_id,
      score = q4_to_db(route_score_q4),
      rx_snr = q4_to_db(snr_q4),
      route_snr_conservatism_db = q4_to_db(self.route_snr_conservatism_q4 or 0),
      hops = 1,
      slot = "alt",
      trigger = source or "direct_frame",
    })
  end
  return action
end

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
  maybe_exit_discovery(self, "before_bcn")
  local dirty_only = not (in_discovery(self) or kind == "sync")
  local frame, new_offset, diff = pack_beacon(self,
                                              self.beacon_max_entries,
                                              self.beacon_offset,
                                              dirty_only)
  local total  = rt_count(self.rt)
  local page_n = diff.n_entries or ((frame:byte(4) or 0) & BCN_N_ENTRIES_MASK)
  self:emit("beacon_tx", {
    n_entries = page_n, rt_total = total,
    key_hash32 = self.key_hash32 or 0,
    identity_only = self.is_mobile == true,
    offset = self.beacon_offset, next_offset = new_offset,
    kind = kind,
    seen_bits = diff.seen_bits or 0,
    suspect_nodes = diff.suspect_nodes or 0,
    ext_len = diff.ext_len or 0,
    dirty_only = diff.dirty_only == true,
    discovery = in_discovery(self),
    layer_id = self.active_layer_id or self.layer_id,
    leaf_id = active_leaf_id(self),
    routing_sf = active_routing_sf(self),
    has_schedule = self.has_schedule == true,
    schedule_count = #(self.gateway_schedule_records or {}),
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
    n_entries   = page_n,
    seen_bits   = diff.seen_bits or 0,
    suspect_nodes = diff.suspect_nodes or 0,
    ext_len     = diff.ext_len or 0,
    dirty_only   = diff.dirty_only == true,
    discovery    = in_discovery(self),
    layer_id     = self.active_layer_id or self.layer_id,
    leaf_id      = active_leaf_id(self),
    routing_sf   = active_routing_sf(self),
    has_schedule = self.has_schedule == true,
    schedule_count = #(self.gateway_schedule_records or {}),
  })
  if self.seen_bitmap_enabled then
    self:emit("seen_bitmap_tx", {
      bits_set = diff.seen_bits or 0,
      ttl_ms = self.seen_bitmap_ttl_ms,
    })
  end
  self:log(string.format(
    "beacon_tx kind=%s page=%d/%d (dirty=%d stable=%d, overflow=%d dirty_only=%s) offset %d→%d",
    kind, page_n, total, diff.dirty_n, diff.stable_n,
    diff.total_dirty - diff.dirty_n,
    tostring(diff.dirty_only == true),
    self.beacon_offset, new_offset))
  self.beacon_offset = new_offset
  if self.layer_state ~= nil and self.current_layer_state_id ~= nil
     and self.layer_state[self.current_layer_state_id] ~= nil then
    self.layer_state[self.current_layer_state_id].beacon_offset = new_offset
  end
  -- Track when this node last committed a BCN to air. Consulted by the
  -- max-idle override (beacon_fire) to break out of long throttle
  -- windows: in dense channels the quiet_threshold gate suppresses
  -- periodic beacons indefinitely, starving neighbours' routing tables
  -- past the rt_aging_ttl_* TTLs. The override fires a BCN regardless of
  -- channel-busy state once this node has been quiet for too long.
  self.last_beacon_tx_ms = self:now()
  return tx_flood(self, frame, {
    sf    = active_routing_sf(self),
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
  if self.join_required and not self.joined then
    -- Unjoined firmware has no valid short address yet, so it must not
    -- publish normal DV beacons. Joining is driven by J frames on control SF.
  elseif self.pending_tx ~= nil or self.pending_rx ~= nil then
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
  -- During node-local discovery, use a fast rate so routes form quickly.
  -- Afterwards drop to the operational rate.
  maybe_exit_discovery(self, "timer")
  local period = in_discovery(self)
                 and self.discovery_beacon_period_ms
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
-- has accumulated in the meantime. In steady state, triggered fires are
-- also rate-limited against the last successful BCN; discovery and boot
-- grace are exempt so joiners can converge quickly. Mobile endpoints are
-- excluded here: they still emit periodic identity-only BCNs, but route
-- mutations while moving must not trigger DV advertisements.
schedule_triggered_beacon = function(self)
  if self.is_mobile then
    return
  end
  if self.triggered_beacon_pending then return end
  self.triggered_beacon_pending = true
  local lo = self.beacon_trigger_jitter_min_ms or 2000
  local hi = self.beacon_trigger_jitter_max_ms or 10000
  local delay = self:rand(lo, hi + 1)
  local steady_state = (not in_discovery(self))
                       and (self:now() - (self.discovery_started_ms or 0)
                            >= (self.beacon_boot_grace_ms or 0))
  local min_interval = self.beacon_trigger_min_interval_ms or 0
  if steady_state and min_interval > 0 and self.last_beacon_tx_ms ~= nil then
    local earliest = self.last_beacon_tx_ms + min_interval
    if self:now() + delay < earliest then
      local old_delay = delay
      delay = earliest - self:now() + self:rand(lo, hi + 1)
      self:emit("beacon_trigger_deferred", {
        min_interval_ms = min_interval,
        old_delay_ms = old_delay,
        delay_ms = delay,
        since_last_bcn_ms = self:now() - self.last_beacon_tx_ms,
      })
    end
  end
  self:after(delay, function()
    self.triggered_beacon_pending = false
    send_beacon_page(self, "triggered")
  end)
end

local function send_req_sync_q(self, reason)
  if not self.req_sync_on_boot then return end
  local now = self:now()
  if self.last_req_sync_tx_ms
     and (now - self.last_req_sync_tx_ms) < self.req_sync_retry_ms then
    return
  end
  if rt_count(self.rt) >= (self.req_sync_min_routes or 0) then return end
  local q_leaf_id = active_leaf_id(self)
  local q_routing_sf = active_routing_sf(self)
  self.last_req_sync_tx_ms = now
  self:emit("q_tx", {
    opcode = Q_OP_REQ_SYNC,
    dst = 255,
    requester_mobile = self.is_mobile == true,
    reason = reason or "discovery",
    rt_total = rt_count(self.rt),
    tx_layer_id = self.active_layer_id or self.layer_id,
    tx_leaf_id = q_leaf_id,
    tx_routing_sf = q_routing_sf,
  })
  self:log(string.format(
    "q_tx opcode=REQ_SYNC requester_mobile=%s rt_total=%d reason=%s",
    tostring(self.is_mobile == true), rt_count(self.rt), reason or "discovery"))
  tx_initiating(self, pack_q(q_leaf_id, self.id, 255,
                             Q_OP_REQ_SYNC, self.is_mobile == true), {
    sf    = q_routing_sf,
    label = "Q",
    info  = string.format("op=req_sync mobile=%s", tostring(self.is_mobile == true)),
  })
end

local function schedule_sync_response(self, q, meta)
  if not self.sync_response_enabled then return end
  local route_n = rt_count(self.rt)
  if route_n < (self.sync_response_min_routes or 0) then
    self:emit("sync_response_skip", {
      joiner = q.src,
      reason = "rt_small",
      rt_total = route_n,
      requester_mobile = q.requester_is_mobile == true,
      responder_mobile = self.is_mobile == true,
    })
    return
  end

  local key = q.src
  if self.sync_response_pending[key] then return end

  local lo = self.sync_response_backoff_min_ms or 500
  local hi = self.sync_response_backoff_max_ms or 6000
  local delay = self:rand(lo, hi + 1)
  if self.is_mobile then
    delay = delay + (self.sync_response_mobile_penalty_ms or 0)
  end
  if q.requester_is_mobile then
    delay = delay + (self.sync_response_requester_mobile_penalty_ms or 0)
  end

  local pending = {
    requested_at = self:now(),
    fire_at = self:now() + delay,
    requester_mobile = q.requester_is_mobile == true,
    responder_mobile = self.is_mobile == true,
    suppressed = false,
  }
  self.sync_response_pending[key] = pending
  self:emit("sync_response_scheduled", {
    joiner = q.src,
    delay_ms = delay,
    rt_total = route_n,
    requester_mobile = pending.requester_mobile,
    responder_mobile = pending.responder_mobile,
    snr = meta and meta.snr or nil,
  })

  self:after(delay, function()
    local p = self.sync_response_pending[key]
    if not p then return end
    self.sync_response_pending[key] = nil
    if p.suppressed then
      self:emit("sync_response_suppressed", {
        joiner = q.src,
        reason = "heard_useful_bcn",
        requester_mobile = p.requester_mobile,
        responder_mobile = p.responder_mobile,
      })
      return
    end
    self:emit("sync_response_tx", {
      joiner = q.src,
      requester_mobile = p.requester_mobile,
      responder_mobile = p.responder_mobile,
      rt_total = rt_count(self.rt),
    })
    send_beacon_page(self, "sync")
  end)
end

local JOIN_UNJOINED_ID = 255

local function join_choose_candidate_id(self)
  local previous = id_bind_find_by_hash(self, self.key_hash32)
  if previous ~= nil
     and previous >= 0 and previous <= 254
     and (self.join_denied_ids == nil or self.join_denied_ids[previous] == nil) then
    self:emit("join_prefer_previous_id", {
      node = previous,
      key_hash32 = self.key_hash32 or 0,
    })
    return previous
  end

  local free = {}
  local expired = {}
  local now = self:now()
  for id = 0, 254 do
    if self.join_denied_ids == nil or self.join_denied_ids[id] == nil then
      local rec = self.id_bind and self.id_bind[id]
      if rec and id_bind_expired(self, id, rec, now) then
        id_bind_age_one(self, id, rec, now, "join_candidate")
        expired[id] = true
        rec = nil
      end
      if rec == nil then
        free[#free + 1] = id
      end
    end
  end
  if #free == 0 then return nil end
  local chosen = free[self:rand(1, #free + 1)]
  if expired[chosen] then
    self:emit("id_bind_reused", {
      node = chosen,
      key_hash32 = self.key_hash32 or 0,
    })
  end
  return chosen
end

local function join_claim_compare(hash_a, nonce_a, hash_b, nonce_b)
  hash_a = hash_a or 0
  hash_b = hash_b or 0
  nonce_a = nonce_a or 0
  nonce_b = nonce_b or 0
  if hash_a ~= hash_b then
    return hash_a < hash_b
  end
  return nonce_a < nonce_b
end

-- Tie-break for "two adopted nodes claim the same id" recovery.
-- Returns true if (my_lease, my_epoch, my_key) wins over the other side.
-- Rule: older lease wins; if equal, higher epoch wins (more recent boot);
-- if equal, lower key_hash wins (deterministic).
function addr_conflict_tie_break(my_lease, my_epoch, my_key,
                                 their_lease, their_epoch, their_key)
  my_lease   = my_lease   or 0
  their_lease = their_lease or 0
  if my_lease ~= their_lease then
    return my_lease > their_lease
  end
  my_epoch   = my_epoch   or 0
  their_epoch = their_epoch or 0
  if my_epoch ~= their_epoch then
    return my_epoch > their_epoch
  end
  my_key   = my_key   or 0
  their_key = their_key or 0
  return my_key < their_key
end


local function join_send_discover(self, reason)
  if not self.join_required or self.joined then return false end
  self.join_discover_attempts = (self.join_discover_attempts or 0) + 1
  local tx_leaf_id = active_leaf_id(self)
  local tx_routing_sf = active_routing_sf(self)
  local frame = pack_j_discover(tx_leaf_id, self.key_hash32 or 0,
                                self.is_mobile == true,
                                self.self_gateway == true)
  self:emit("join_discover_sent", {
    key_hash32 = self.key_hash32 or 0,
    requester_mobile = self.is_mobile == true,
    gateway_capable = self.self_gateway == true,
    reason = reason or "auto",
    attempt = self.join_discover_attempts,
    tx_layer_id = self.active_layer_id or self.layer_id,
    tx_leaf_id = tx_leaf_id,
    tx_routing_sf = tx_routing_sf,
  })
  tx_initiating(self, frame, {
    sf = tx_routing_sf,
    label = "J",
    info = string.format("op=discover reason=%s", reason or "auto"),
  })
  local wait_ms = self.join_discover_wait_ms or 10000
  self:after(wait_ms, function()
    if self.joined or self.join_claim_pending then return end
    local max_attempts = self.join_discover_max_attempts or 0
    if max_attempts > 0 and (self.join_discover_attempts or 0) >= max_attempts then
      self:emit("join_discover_exhausted", {
        key_hash32 = self.key_hash32 or 0,
        attempts = self.join_discover_attempts or 0,
        wait_ms = wait_ms,
      })
      return
    end
    local backoff = self:rand(0, (self.join_retry_backoff_ms or 10000) + 1)
    self:emit("join_discover_retry_scheduled", {
      key_hash32 = self.key_hash32 or 0,
      attempts = self.join_discover_attempts or 0,
      backoff_ms = backoff,
    })
    self:after(backoff, function()
      if not self.joined and not self.join_claim_pending then
        join_send_discover(self, "offer_timeout")
      end
    end)
  end)
  return true
end

local function join_start_claim(self, reason)
  if not self.join_required or self.joined or self.join_claim_pending then return false end
  local proposed = join_choose_candidate_id(self)
  if proposed == nil then
    self:emit("join_no_candidate", { reason = reason or "no_free_id" })
    return false
  end
  self.join_claim_epoch = ((self.join_claim_epoch or 0) + 1) & 0xff
  nv_set(self, "claim_epoch", self.join_claim_epoch)
  local nonce = self:rand(0, 256)
  local lease_age = lease_age_seconds_now(self)
  self.join_claim_pending = {
    proposed_node_id = proposed,
    key_hash32 = self.key_hash32 or 0,
    claim_epoch = self.join_claim_epoch,
    nonce = nonce,
    started_ms = self:now(),
  }
  local tx_leaf_id = active_leaf_id(self)
  local tx_routing_sf = active_routing_sf(self)
  local frame = pack_j_claim(tx_leaf_id, self.key_hash32 or 0, proposed, lease_age,
                             self.join_claim_epoch, nonce,
                             self.is_mobile == true,
                             self.self_gateway == true)
  self:emit("join_claim_sent", {
    proposed_node_id = proposed,
    key_hash32 = self.key_hash32 or 0,
    lease_age_seconds = lease_age,
    claim_epoch = self.join_claim_epoch,
    nonce = nonce,
    requester_mobile = self.is_mobile == true,
    gateway_capable = self.self_gateway == true,
    reason = reason or "auto",
    tx_layer_id = self.active_layer_id or self.layer_id,
    tx_leaf_id = tx_leaf_id,
    tx_routing_sf = tx_routing_sf,
  })
  tx_initiating(self, frame, {
    sf = tx_routing_sf,
    label = "J",
    info = string.format("op=claim node=%d reason=%s", proposed, reason or "auto"),
  })
  self:after(self.join_claim_guard_ms or 3000, function()
    local p = self.join_claim_pending
    if not p or p.proposed_node_id ~= proposed then return end
    local existing = self.id_bind and self.id_bind[proposed]
    if existing and existing.key_hash32 ~= (self.key_hash32 or 0) then
      self.join_claim_pending = nil
      self.join_denied_ids[proposed] = true
      self:emit("join_claim_denied", {
        denied_node_id = proposed,
        owner_key_hash32 = existing.key_hash32,
        claimant_key_hash32 = self.key_hash32 or 0,
        reason = "claim_guard_conflict",
      })
      self:after(self.join_retry_backoff_ms or 10000, function()
        if not self.joined then join_start_claim(self, "claim_guard_conflict") end
      end)
      return
    end
    self.join_claim_pending = nil
    local bound = id_bind_set(self, proposed, self.key_hash32 or 0,
                              "join_adopted", "authenticated")
    if not bound then
      self.join_denied_ids[proposed] = true
      self:emit("join_claim_denied", {
        denied_node_id = proposed,
        claimant_key_hash32 = self.key_hash32 or 0,
        reason = "self_bind_conflict",
      })
      self:after(self.join_retry_backoff_ms or 10000, function()
        if not self.joined then join_start_claim(self, "self_bind_conflict") end
      end)
      return
    end
    self.joined = true
    self.id = proposed
    self:set_protocol_id(proposed)
    self.adopted_at_ms = self:now()
    self.join_discover_attempts = 0
    self.name_to_id[self.name] = proposed
    self.id_to_name[proposed] = self.name
    self:emit("join_adopted", {
      node = proposed,
      key_hash32 = self.key_hash32 or 0,
      claim_epoch = p.claim_epoch,
      nonce = p.nonce,
      adopted_at_ms = self.adopted_at_ms,
    })
    send_beacon_page(self, "sync")
    send_req_sync_q(self, "join_adopted")
  end)
  return true
end

-- ---- addr_conflict recovery action (own-id defense + forced rejoin) ----
-- When this node sees a different key_hash claiming its own short id
-- (typically via a peer BCN reaching us after the duplicate's
-- adoption), id_bind_set fires `addr_conflict_observed` and then calls
-- this defense. We send a J_DENY carrying our real lease_age + epoch.
-- The duplicate (claimant) runs the tie-break in its J_DENY handler; if
-- it loses it triggers forced_rejoin to give up the id.
function addr_conflict_recovery_send_deny(self, node_id, owner_key, claimant_key, source)
  if not self.joined or self.key_hash32 == nil then return false end
  if node_id ~= self.id then return false end
  if owner_key ~= self.key_hash32 then return false end
  if claimant_key == nil or claimant_key == self.key_hash32 then return false end
  local owner_lease_age = lease_age_seconds_now(self)
  local tx_leaf_id = active_leaf_id(self)
  local tx_routing_sf = active_routing_sf(self)
  local deny = pack_j_deny(tx_leaf_id, node_id,
                           self.key_hash32, claimant_key,
                           owner_lease_age, self.join_claim_epoch or 0,
                           J_DENY_REASON_OWN_ID_DEFENSE,
                           self.is_mobile == true,
                           self.self_gateway == true)
  self:emit("addr_conflict_defense", {
    node = node_id,
    own_key_hash32 = self.key_hash32,
    claimant_key_hash32 = claimant_key,
    own_lease_age_seconds = owner_lease_age,
    own_claim_epoch = self.join_claim_epoch or 0,
    source = source or "unknown",
  })
  tx_initiating(self, deny, {
    sf = tx_routing_sf,
    label = "J",
    info = string.format("op=deny (own-id-defense) node=%d claimant=%u",
                         node_id, claimant_key & 0xffffffff),
  })
  return true
end

-- Yield current id and re-run the join state machine. Triggered when
-- this node loses the addr_conflict tie-break against a peer claiming
-- the same id with stronger lease/epoch. The contested id is added to
-- denied_ids so the random picker won't immediately re-pick it.
function forced_rejoin(self, reason, owner_key, owner_lease_age, owner_epoch)
  if not self.joined then return false end
  local prior_id = self.id
  self.joined = false
  self.adopted_at_ms = nil
  self.join_required = true
  self.join_claim_pending = nil
  self.id = JOIN_UNJOINED_ID
  self:set_protocol_id(JOIN_UNJOINED_ID)
  self.join_denied_ids = self.join_denied_ids or {}
  self.join_denied_ids[prior_id] = true
  -- Drop our own self-binding for the prior id so the local id_bind table
  -- doesn't hold a stale claim by us. Other peers' bindings refresh on
  -- their own BCN/J observation cycles.
  if self.id_bind ~= nil and self.id_bind[prior_id] ~= nil
     and self.id_bind[prior_id].key_hash32 == (self.key_hash32 or 0) then
    self.id_bind[prior_id] = nil
  end
  self:emit("addr_conflict_forced_rejoin", {
    prior_node_id = prior_id,
    reason = reason or "addr_conflict_lost",
    observed_owner_key_hash32 = owner_key,
    observed_owner_lease_age_seconds = owner_lease_age,
    observed_owner_claim_epoch = owner_epoch,
  })
  -- Re-run join immediately. The picker excludes the contested id.
  return join_start_claim(self, reason or "addr_conflict_lost")
end

local function schedule_gateway_layer_window(self, rec)
  if not self.self_gateway or rec == nil then return end
  local function fire()
    if self.pending_tx ~= nil or self.pending_rx ~= nil then
      local retry_ms = self.gateway_layer_busy_retry_ms
                       or math.max(self.rts_busy_retry_ms or 100, 1000)
      self:emit("gateway_layer_window_deferred", {
        layer_id = rec.layer_id,
        leaf_id = rec.leaf_id,
        routing_sf = rec.routing_sf,
        active_layer_id = self.active_layer_id or self.layer_id,
        active_leaf_id = active_leaf_id(self),
        listen_sf = active_routing_sf(self),
        retry_ms = retry_ms,
      })
      self:after(retry_ms, fire)
      return
    end
    activate_gateway_layer(self, rec, "schedule")
    send_beacon_page(self, "gateway_sweep")
    self:after(rec.duration_ms, function()
      if self.pending_tx == nil and self.pending_rx == nil then
        activate_primary_layer(self, "schedule_return")
      end
    end)
    -- Record when the next foreign window opens so home-layer beacons can
    -- advertise a live countdown (see pack_schedule_record). One period out.
    rec.next_visit_ms = self:now() + rec.period_ms
    self:after(rec.period_ms, fire)
  end
  rec.next_visit_ms = self:now() + rec.offset_ms
  self:after(rec.offset_ms, fire)
end

function on_init(self, config)
  -- Apply production-fixed PROTOCOL constants first. Config overrides
  -- are honored — Lua model's escape hatch for dedicated tests; the
  -- C++ port hardcodes these. See docs/CONFIG_AUDIT.md.
  apply_protocol_constants(self, config)

  -- Node-level identity flags (BCN byte 1 bits 3:1).
  -- Defaults false; no current scenario sets these config keys.
  -- has_schedule: gateways advertise their single-radio layer windows.
  -- self_gateway: true if this node bridges to internet/backbone.
  -- is_mobile:    true if this node is mobile (relaxes route aging etc.).
  self.self_gateway = (config.is_gateway == true)
  self.has_schedule = self.self_gateway and #(config.gateway_layers or {}) > 0
  self.is_mobile    = (config.is_mobile  == true)
  self.join_required = (config.join_required == true)
  self.joined = not self.join_required
  if self.join_required then
    self.id = JOIN_UNJOINED_ID
    self:set_protocol_id(JOIN_UNJOINED_ID)
  end

  self.routing_sf       = config.routing_sf      or 7
  -- Per-flight DATA SF is now negotiated via the RTS bitmap → CTS choice.
  -- self.allowed_data_sfs is the list this node will offer when ORIGINATING
  -- or FORWARDING; receivers pick from it based on link SNR + margin.
  -- Default keeps old single-SF behaviour by listing one SF.
  self.allowed_data_sfs = config.allowed_data_sfs or { 12 }
  self.allowed_sf_bitmap = sf_set_to_bitmap(self.allowed_data_sfs)
  self.join_data_sfs_locked = not self.join_required
  -- Viability floor for rt entries: a route is "viable" iff its chain-min
  -- SNR clears the routing-plane (RTS/CTS/ACK ride on routing_sf) demod
  -- threshold + sf_margin. route_strictly_better treats viable routes
  -- as strictly preferred over non-viable ones; within each group it's
  -- hops-first. A non-viable rt entry is still kept (better than no entry —
  -- the data SF can fall back to a slower one if the routing-plane SNR is
  -- borderline) but never preferred over an actually-decodable path.
  self.routing_snr_floor_q4 = (SF_DEMOD_THRESHOLD[self.routing_sf] or -240)
                              + self.sf_margin_q4
  -- Steady-state beacon period (T-class). `discovery_beacon_period_ms`
  -- is a PROTOCOL constant.
  self.beacon_period_ms        = config.beacon_period_ms        or 900000
  -- Real firmware does not know about simulator warmup. A node that just
  -- booted briefly runs discovery: fast/full BCNs until it has heard enough
  -- of the mesh or a bounded timeout expires. After that, normal BCNs are
  -- dirty-only plus the seen bitmap. Late joiners get the same local
  -- discovery window starting at their own boot time. Most discovery
  -- knobs are PROTOCOL constants; only the F-class boot toggle and the
  -- T-class `req_sync_min_routes` stay config-driven here.
  self.discovery_started_ms    = self:now()
  self.discovery_until_ms      = self.discovery_started_ms + self.discovery_ms
  self.discovery_bcn_rx_count  = 0
  self.discovery_mode          = (self.discovery_ms > 0)
  self.req_sync_on_boot        = (config.req_sync_on_boot ~= false)
  self.req_sync_min_routes     = config.req_sync_min_routes     or self.discovery_min_routes
  self.last_req_sync_tx_ms     = nil
  -- Optional destination freshness bitmap appended to BCN frames. It is
  -- not a route advertisement: receivers update dest_seen_ms only, and
  -- route candidates refresh only when the existing candidate's next_hop
  -- is the bitmap sender.
  self.seen_bitmap_enabled     = (config.seen_bitmap_enabled ~= false)
  self.dest_seen_ms            = {}
  -- Triggered beacons: coalesce route mutations for a few seconds, then
  -- emit a dirty-only BCN. All trigger-jitter / min-interval knobs are
  -- PROTOCOL constants.
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

  -- Max-idle override: bypass the quiet_threshold gate if this node
  -- hasn't BCN'd in beacon_max_idle_ms. In dense meshes the channel
  -- never goes quiet for the throttle's threshold, so periodic beacons
  -- are suppressed indefinitely — neighbours' RT entries age out at
  -- the rt_aging_ttl_* TTLs and the network collapses around the
  -- TTL boundary. Default 900000 ms (15 min) is a firmware-like slow
  -- heartbeat; keep it comfortably below route aging TTLs. Set to 0 to
  -- disable. See on_init's aging block for the deployment-scaling formula.
  --
  -- last_beacon_tx_ms is `nil` until the first BCN; the override treats
  -- nil as "never beaconed → fire freely" (matches the throttle's
  -- nil-last_rx semantics so cold-start behaviour is preserved).
  self.beacon_max_idle_ms        = config.beacon_max_idle_ms        or 900000
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
  -- alpha is a Q4 fraction in [0, Q4_SCALE]. PROTOCOL pins it to 5
  -- (=0.3125, ~10-sample effective window).
  self.snr_ewma_in    = {}
  self.snr_ewma_out   = {}
  -- beacon_max_bytes is a PROTOCOL constant (151, fits 47 entries).
  -- Header is 4 bytes ('B' + leaf_id_byte + src + n); entries 3 bytes each.
  self.beacon_max_entries = math.max(1,
    math.floor((self.beacon_max_bytes - 8) / 3))
  -- Radio params for airtime calculation. The runtime injects per-node
  -- resolved values via `_sim_bw_hz` and `_sim_cr` so the script's
  -- airtime math matches what the radio actually does (otherwise s03's
  -- 62.5 kHz BW would compute timeouts against 250 kHz airtime — 4× too
  -- short). User config keys (bw_hz / cr) still win if explicitly set.
  -- Final fallbacks match MeshCore SX1262 defaults.
  self.bw_hz            = config.bw_hz           or config._sim_bw_hz or 250000
  self.cr               = config.cr              or config._sim_cr    or 5
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
  -- Budget tier thresholds + per-tier blind windows are PROTOCOL constants.
  -- Anti-spam — per-sender RTS/CTS counts over sliding window for the
  -- 1st-hop statistical classifier. State tables only; window/threshold/
  -- airtime-share/retry-dedup are PROTOCOL constants. `originator_max_per_window`
  -- stays T (per-network fairness policy); `originator_self_warn_fraction`
  -- stays D (diagnostic hint).
  self.per_sender_originator        = {}
  self.own_origination_events       = {}
  self.originator_max_per_window    = config.originator_max_per_window    or 6
  self.originator_self_warn_fraction = config.originator_self_warn_fraction or 0.5
  -- Priority unicast (ROADMAP §3a): two parallel ledgers, keyed on the
  -- sender's role at this node.
  --   * priority_send_events[]: timestamps of our own priority originations
  --   * peer_priority_observations[meta.src]: per-direct-sender priority
  --     observations (for 1st-hop throttle). Pruned to the window at
  --     check time.
  self.priority_send_events         = {}
  self.peer_priority_observations   = {}
  -- Priority-aware TX queue: tx_queue items carry `flags` already (for
  -- E2E etc.); become_free's selection comparator prefers items with
  -- DATA_FLAG_PRIORITY set over non-priority items at any given
  -- requeue_count. No separate queue needed; ordering is purely
  -- comparator-based.

  -- ROADMAP §3 channel gossip state. Shared FIFO across all channels;
  -- entry shape: {id, channel_id, flavor, payload, received_at,
  -- seen_by (table keyed by neighbour node_id), dirty (bool)}.
  self.channel_buffer        = {}
  -- Pull rate-limit: per-ID timestamp of most recent pull from us.
  self.channel_pull_recent   = {}
  -- Pull-pending: id -> {at, target_node_id} for pulls awaiting jitter
  -- expiry. If we overhear an M-response carrying the id before `at`
  -- fires, the entry is dropped (channel_pull_suppressed).
  self.channel_pull_pending  = {}
  -- Proactive tier-aware routing: route_strictly_better applies a
  -- dynamic score penalty on top of raw SNR margin. The penalty scales
  -- with the peer's known budget tier and with how many viable
  -- alternatives exist for that destination, so single-route cases get
  -- only a nudge while well-connected routes move away from hot relays.
  -- Marks expire so a recovered peer eventually returns to the primary
  -- pool.
  self.neighbor_budget_tier         = {}
  self.neighbor_budget_tier_set_at  = {}
  -- Peer-silence suspicion. Repeated RTS timeouts against the same next-hop
  -- are local evidence that a route is stale or the peer is temporarily
  -- unreachable. We do not delete routes; we apply a temporary score penalty
  -- and advertise a compact BCN extension so nearby nodes can avoid the
  -- peer while it is silent. Any valid frame from the peer clears the mark.
  -- All thresholds + penalties + TTLs are PROTOCOL constants.
  self.peer_rts_timeouts        = {}
  self.peer_first_rts_timeout_ms = {}
  self.peer_suspect_until       = {}
  self.peer_silent_until        = {}
  self.peer_dead_until          = {}
  self.peer_suspect_advertise_until = {}
  self.peer_dead_advertise_until = {}
  -- RTS retry policy. rts_busy_retry_ms / rts_max_retries / route_snr_*
  -- / next_hop_live_ttl_ms / cts_to_data_gap_ms / neighbor_budget_tier_ttl_ms
  -- are all PROTOCOL constants. rts_timeout_ms remains a config override
  -- (debug-only, classified D); production derives it per-flight from
  -- routing_sf.
  self.rts_timeout_override_ms = config.rts_timeout_ms
  self.rts_timeout_ms = self.rts_timeout_override_ms or rts_timeout_base_ms(self, self.routing_sf)
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
  -- cascade_requeue_* are PROTOCOL constants. See PROTOCOL block at top
  -- of file for the per-knob rationale.
  -- TX-policy controls (see "TX policy classes" section above).
  --   lbt_enabled            — pre-check channel_busy_until before TX of
  --                            initiating-directed (RTS / NACK) and flood
  --                            (beacons). Default ON: firmware tries CAD
  --                            before TX; if busy, it waits until the
  --                            observed busy window ends plus a small
  --                            random LBT backoff, then commits.
  --   lbt_backoff_ms         — random slack after busy_until for LBT
  --                            defers. Default = half RTS airtime.
  --   retry_jitter_ms        — bound for random backoff added to (a) RTS
  --                            retries on cts_timeout / ack_timeout.
  --                            Default = one RTS-airtime so it scales
  --                            naturally at 62.5 vs 250 kHz.
  --   flood_lbt_max_defer_ms — if the channel will be busy for longer than
  --                            this, drop the beacon page entirely (the next
  --                            periodic / triggered fire rotates to the
  --                            next page anyway, so queueing a stale page
  --                            is wasteful). Default = airtime(routing_sf,
  --                            beacon_max_bytes) — i.e. one beacon-air's
  --                            worth; if we'd wait longer than the page we
  --                            were going to send, just skip.
  self.lbt_enabled        = config.lbt_enabled
  if self.lbt_enabled == nil then self.lbt_enabled = true end
  self.retry_jitter_ms    = config.retry_jitter_ms    or
    (3 * airtime_ms(self.routing_sf, self.bw_hz, self.cr, self.preamble_sym, RTS_LEN))
  self.lbt_backoff_ms     = config.lbt_backoff_ms     or
    math.max(1, math.floor(self.retry_jitter_ms / 2))
  self.flood_lbt_max_defer_ms = config.flood_lbt_max_defer_ms or
    airtime_ms(self.routing_sf, self.bw_hz, self.cr, self.preamble_sym,
               self.beacon_max_bytes)
  -- Maximum user-payload byte length. Network-wide convention: all nodes
  -- in a mesh MUST agree, otherwise receiver pending_rx_expiry sizing
  -- diverges and large DATAs trip premature expiries on tight-budget peers.
  -- Default 230 matches Meshtastic's max chat size; leaves 11 bytes of
  -- margin under the LoRa PHY 255-byte frame cap (DATA_HDR_LEN=8 +
  -- DATA_INNER_OVERHEAD=6 = 14 bytes of fixed overhead → 241 hard ceiling).
  -- Hard-clamped to the LoRa ceiling below; config can only tighten, not
  -- exceed.
  self.max_payload_bytes  = config.max_payload_bytes  or 230
  local payload_hard_max = LORA_MAX_FRAME_BYTES - DATA_HDR_LEN - DATA_INNER_OVERHEAD
  if self.max_payload_bytes > payload_hard_max then
    self:emit("max_payload_clamped", {
      requested = self.max_payload_bytes,
      clamped_to = payload_hard_max,
      lora_max_frame = LORA_MAX_FRAME_BYTES,
      fixed_overhead = DATA_HDR_LEN + DATA_INNER_OVERHEAD,
    })
    self:log(string.format(
      "max_payload_bytes %d exceeds LoRa frame ceiling, clamped to %d",
      self.max_payload_bytes, payload_hard_max))
    self.max_payload_bytes = payload_hard_max
  end
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

  self.layer_state     = {}
  self.current_layer_state_id = nil
  use_layer_state(self, self.layer_id)
  self.next_ctr_lo     = 1
  self.pending_tx      = nil
  self.pending_rx      = nil
  self.rt_full_emitted = false
  self.rts_attempt_seq = 0
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
  self.gateway_deferred_handoffs = {}
  self.gateway_handoff_defer_ttl_ms = config.gateway_handoff_defer_ttl_ms
                                      or self.send_defer_ttl_ms
  -- Hop-level RTS-retry dedup. {sender_id → {ctr_lo, t_ms}}; lookups
  -- treat entries older than self.last_acked_ttl_ms as missing so the
  -- 4-bit ctr_lo wrap (every 16 sends per sender) doesn't false-pos
  -- at slow send rates. TTL well above any flight-retry window
  -- (rts_max_retries × rts_timeout ≈ 1.5 s) and well below the wrap
  -- interval at any plausible per-sender send rate.
  self.last_acked_from    = {}
  -- 4-bit network identifier — externally managed (admin sets per node).
  -- Receivers reject foreign-network BCN/RTS at the routing layer
  -- before doing CTS/DATA work. 0 = default mesh; 1..15 = distinct meshes.
  self.layer_id       = config.layer_id or config.leaf_id or 0
  self.leaf_id        = config.leaf_id or (self.layer_id & 0x0f)
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
  -- Current firmware-oriented defaults:
  --   rt_aging_ttl_neighbor_ms = 45 min
  --   rt_aging_ttl_remote_ms   = 3 hours
  --
  -- Older simulation defaults (s04 stress tuning) were 30 min / 90 min.
  -- Scenario JSON can still shorten these for focused tests.
  --
  -- Simulation reference (s04):
  --   beacon_max_idle_ms = 8 min  (set in beacon-throttle block above)
  --   RT_size ≈ 140 (s04), beacon_max_entries ≈ 50 → 3 rotation pages
  --   per_entry_refresh_max_ms = 3 × 8 = 24 min
  --   45 min covers almost 2 full remote-entry rotations for direct peers;
  --   3 hours covers several missed remote rotations.
  self.rt_aging_ttl_neighbor_ms = config.rt_aging_ttl_neighbor_ms or 2700000    -- 45 min
  self.rt_aging_ttl_remote_ms   = config.rt_aging_ttl_remote_ms   or 10800000   -- 3 h
  -- Q dedup tracking. Sender side: don't re-fire route-query Q for the
  -- same dest within q_query_ttl_ms. Responder side: don't respond to the
  -- same (opcode, src, dest) Q within q_respond_ttl_ms. REQ_SYNC responses
  -- also use randomized backoff + suppression so one good neighbour can
  -- satisfy a joiner without every nearby node emitting a full BCN.
  self.q_queried       = {}                                  -- {dest_id → t_ms_last_queried}
  self.q_responded_to  = {}                                  -- {key → t_ms_last_responded}
  self.hash_query_seen = {}                                  -- {"origin|hash" → t_ms} 'H' flood dedup
  self.route_request_seen = {}                               -- {"origin|dst" → t_ms} 'R' RREQ flood dedup
  self.route_request_last = {}                               -- {dst_id → {t,ttl}} 'R' originate rate-limit/escalation
  -- After a route appears due to Q-driven BCN discovery, hold the
  -- deferred DATA briefly so nearby Q-response BCNs can finish. This
  -- avoids the first RTS colliding with late/deferred beacon responders
  -- in hidden-terminal layouts.
  -- Settle window for Q-driven send draining (see "Q response settle" use
  -- site in the deferred-send drain loop). Derived from radio params; not
  -- runtime-tunable. Jitter is shared with lbt_backoff_ms.
  self.q_response_settle_ms = self.beacon_trigger_jitter_max_ms
                            + airtime_ms(self.routing_sf, self.bw_hz, self.cr,
                                         self.preamble_sym, self.beacon_max_bytes)
                            + self.lbt_backoff_ms
  self.sync_response_enabled = (config.sync_response_enabled ~= false)
  -- backoff / penalty / suppress windows are PROTOCOL constants.
  self.sync_response_pending = {}
  -- Diagnostic-only: periodic node_state_snapshot emit cadence.
  -- Captures blind_until count, tx_queue depth, deferred_sends count,
  -- rt size — anything that could grow unboundedly under stress, so
  -- analysers can spot late-window failure modes without replaying
  -- every observation event. Default 60 s. Set 0 to disable.
  self.state_snapshot_period_ms = config.state_snapshot_period_ms or 60000
  self.debug_start_ms = (config.debug_start_ms ~= nil) and config.debug_start_ms or config.debug_start
  self.debug_end_ms = (config.debug_end_ms ~= nil) and config.debug_end_ms or config.debug_end
  self.beacon_offset     = 0    -- sliding page offset for bounded beacons
  -- Origin-level dedup. Every node that receives DATA records the
  -- (origin_id, dst_id, ctr) tuple and rejects subsequent arrivals of the
  -- same message id (after still ACKing the previous hop, so it clears its
  -- pending_tx). ctr is per-(origin,dst), so dst must be part of the key.
  -- This catches routing loops + legitimate same-payload retransmissions
  -- in real firmware. TTL is generous (30s default) because a flight at
  -- SF10 can take a few seconds with retries.
  self.seen_origins       = {}
  self.seen_origin_from   = {}
  -- Per-(self → peer) outbound 16-bit counter. Replaces the old flat next_origin_seq.
  -- RAM-only this phase; NV persistence deferred to §8 crypto. Keyed by peer_id.
  self.peer_send_counter  = {}   -- [peer_id] → last sent ctr value (0 = never sent)
  -- End-to-end ACK state. Originator-side per-message pending map keyed by
  -- (dst, ctr), because ctr is per-(self,dst). Set on send_e2e; cleared when
  -- matching E2E ACK arrives (emit delivered_confirmed); pruned on TTL expiry
  -- (emit e2e_ack_timeout).
  self.pending_e2e        = {}
  self.e2e_ack_ttl_ms     = config.e2e_ack_ttl_ms or 60000   -- 1 min default

  -- §7.6 hop budget — per-flight TTL bounds path wandering.
  -- Originator initializes hop_budget = rt[dst].hops + slack at send time.
  -- Each forwarder decrements remaining; at 0, drop with hop_budget_exceeded
  -- (and in Phase B, NACK reason=hop_budget back to upstream).
  -- slack=3 (default) catches worst-wandering flights while preserving moderate
  -- detours; calibrated against s04_seattle_realistic data showing ~4% delivery
  -- impact at slack=3.
  -- hop_budget_slack / hop_budget_max_initial are PROTOCOL constants.
  self.rt_learn_from_data     = config.rt_learn_from_data     or true

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
  self.mobile_peers = {}
  use_layer_state(self, self.layer_id)
  self.join_j_seen = {}
  self.gateway_layer_set = {}
  self.gateway_layer_list = {}
  self.gateway_layer_by_id = {}
  self.gateway_schedule_records = {}
  self.gateway_neighbor_schedules = {}
  self.gateway_remote_bind = {}
  -- PROTOCOL §3.1 type 4: cross-layer routing propagation. Map of
  -- gw_id -> { dest_layer, last_seen_ms }. Populated from peer BCNs
  -- carrying type-4 TLVs (or from our own gateway_layer_list when
  -- self_gateway, computed at pack time).
  self.bridged_layers = {}
  for _, layer in ipairs(config.gateway_layers or {}) do
    local layer_id = nil
    local routing_sf = nil
    local allowed_data_sfs = nil
    local duration_ms = nil
    local period_ms = nil
    local offset_ms = nil
    local leaf_id = nil
    if type(layer) == "table" then
      layer_id = layer.layer_id
      leaf_id = layer.leaf_id
      routing_sf = layer.routing_sf or layer.sf
      allowed_data_sfs = layer.allowed_data_sfs
      duration_ms = layer.duration_ms
      period_ms = layer.period_ms
      offset_ms = layer.offset_ms
    else
      layer_id = layer
    end
    if layer_id ~= nil then
      layer_id = math.floor(layer_id)
      -- Schedule defaults if the per-record `gateway_layers[i]` entry omits a
      -- field. No node-level config fallback — per-record values (or the
      -- gateway_visit_* PROTOCOL defaults, tuned for cross-layer delivery) are
      -- the only sources.
      local rec = {
        layer_id = layer_id,
        leaf_id = leaf_id or layer_leaf_id(layer_id),
        routing_sf = routing_sf or self.routing_sf,
        allowed_data_sfs = allowed_data_sfs or self.allowed_data_sfs,
        duration_ms = duration_ms or self.gateway_visit_duration_ms,
        period_ms = period_ms or self.gateway_visit_period_ms,
        offset_ms = offset_ms or self.gateway_visit_offset_ms,
      }
      rec.allowed_sf_bitmap = sf_set_to_bitmap(rec.allowed_data_sfs)
      self.gateway_layer_set[layer_id] = true
      table.insert(self.gateway_layer_list, layer_id)
      self.gateway_layer_by_id[layer_id] = rec
      table.insert(self.gateway_schedule_records, rec)
    end
  end
  self.key_hash32 = self.key_hash32 or config.key_hash32
  -- id_bind_ttl_ms is a PROTOCOL constant (48 h). gateway_remote_bind_ttl_ms
  -- stays D-class (config-overridable for accelerated TTL aging tests; see
  -- t55). Production: `#define = ID_BIND_TTL_MS`.
  self.gateway_remote_bind_ttl_ms = config.gateway_remote_bind_ttl_ms or self.id_bind_ttl_ms
  -- Bounded-state caps. Sized for a small (~50 node) mesh on a Cortex-M MCU.
  -- Set to 0 to disable. See `table_cap_hit` helper and §13 of PROTOCOL.md.
  -- Bounded-state caps are PROTOCOL constants — sized at port time, not
  -- in the field. See PROTOCOL block; runtime emits `table_cap_hit`
  -- (§13.6 in PROTOCOL.md) when one is reached.
  self.join_denied_ids = {}
  self.join_claim_pending = nil
  -- NV-backed state. claim_epoch is monotonic across reboots so a
  -- partition-merge tie-break can deterministically order claims by
  -- "newer boot wins" (assuming the wire field saturates at 8 bits,
  -- 256 boots before wraparound).
  self.nv = config.nv or {}
  self.join_claim_epoch = nv_get(self, "claim_epoch", 0)
  -- Pre-joined (pinned-id) nodes record their adoption time at init so
  -- their J_DENY responses carry a real lease_age_seconds. Unjoined
  -- nodes set adopted_at_ms when join_adopted fires.
  if self.joined then
    self.adopted_at_ms = self:now()
  else
    self.adopted_at_ms = nil
  end
  -- All join-state-machine timing knobs are PROTOCOL constants.
  self.join_discover_attempts = 0
  if self.key_hash32 ~= nil and self.joined then
    id_bind_set(self, self.id, self.key_hash32, "self", "authenticated")
  end
  local nodes = sim:nodes()
  for _, n in ipairs(nodes) do
    local node_layer_id = n.layer_id or n.leaf_id or 0
    if not n.join_required then
    self.name_to_id[n.name] = n.id
    self.id_to_name[n.id]   = n.name
    if n.key_hash32 ~= nil then
      local bind_layer_id = (n.id == self.id) and self.layer_id or node_layer_id
      if bind_layer_id == self.layer_id
         or (self.self_gateway and gateway_layer_enabled(self, bind_layer_id)) then
        local saved_layer_id = self.current_layer_state_id or self.layer_id
        use_layer_state(self, bind_layer_id)
        id_bind_set(self, n.id, n.key_hash32,
                    (n.id == self.id) and "self" or "sim_nodes",
                    (n.id == self.id) and "authenticated" or "claimed")
        use_layer_state(self, saved_layer_id)
      end
    end
    end
    if n.is_mobile then
      self.mobile_peers[n.id] = true
    end
  end
  if self.join_required then
    self.name_to_id[self.name] = self.id
    self.id_to_name[self.id] = self.name
  end
  activate_primary_layer(self, "init")
  if self.self_gateway then
    for _, rec in ipairs(self.gateway_schedule_records or {}) do
      schedule_gateway_layer_window(self, rec)
    end
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
    q4_to_db(self.sf_margin_q4), self.beacon_period_ms, self.peer_count,
    airtime_ms(self.routing_sf, self.bw_hz, self.cr, self.preamble_sym, RTS_LEN),
    airtime_ms(self.routing_sf, self.bw_hz, self.cr, self.preamble_sym, CTS_LEN),
    self.ack_air_ms, self.routing_sf,
    self.rts_timeout_ms, self.pending_rx_expiry_max_ms))

  self:emit("node_layer_info", {
    node_id = self.id,
    name = self.name,
    layer_id = self.layer_id,
    leaf_id = self.leaf_id,
    key_hash32 = self.key_hash32 or 0,
    is_gateway = self.self_gateway == true,
    gateway_layers = self.gateway_layer_list,
    gateway_schedule_count = #(self.gateway_schedule_records or {}),
    is_mobile = self.is_mobile == true,
    joined = self.joined == true,
    routing_sf = self.routing_sf,
    allowed_sf_bitmap = self.allowed_sf_bitmap,
  })

  if self.join_required then
    self:emit("join_listen_start", {
      key_hash32 = self.key_hash32 or 0,
      listen_ms = self.join_listen_ms,
    })
    self:after(self.join_listen_ms, function()
      if self.joined then return end
      self:emit("join_listen_end", {
        key_hash32 = self.key_hash32 or 0,
        known_bindings = self.id_bind and rt_count(self.id_bind) or 0,
      })
      local jitter = self:rand(0, (self.join_discover_jitter_ms or 0) + 1)
      self:after(jitter, function()
        if self.joined then return end
        join_send_discover(self, "listen_done")
      end)
    end)
  end

  -- First-beacon scheduling:
  --   - discovery nodes jitter across the discovery beacon period so mass
  --     boot or a small group of new joiners does not collapse into one
  --     collision burst.
  --   - if discovery is disabled, use the operational beacon period.
  local first_period = in_discovery(self)
                       and self.discovery_beacon_period_ms
                       or  self.beacon_period_ms
  self:after(self:rand(0, first_period), function() beacon_fire(self) end)
  if self.req_sync_on_boot and in_discovery(self) then
    local function req_sync_loop()
      if not in_discovery(self) then return end
      send_req_sync_q(self, "discovery")
      if in_discovery(self) and rt_count(self.rt) < (self.req_sync_min_routes or 0) then
        self:after(self.req_sync_retry_ms, req_sync_loop)
      end
    end
    self:after(self.req_sync_listen_ms, req_sync_loop)
  end

  -- Periodic 1s drain of self.deferred_sends — fires regardless of
  -- beacon traffic, so deferred originator sends have a deterministic
  -- TTL-pruning + retry loop independent of the radio. Also prunes
  -- pending_e2e entries that aged past e2e_ack_ttl_ms (emits
  -- e2e_ack_timeout).
  local function drain_loop()
    try_drain_deferred(self)
    try_drain_gateway_handoffs(self)
    local now = self:now()
    for key, info in pairs(self.pending_e2e) do
      if now - info.sent_at_ms >= self.e2e_ack_ttl_ms then
        self:emit("e2e_ack_timeout", {
          origin     = self.id,
          ctr        = info.ctr,
          dst        = info.dst_id,
          payload    = info.user_text,
          ttl_ms     = self.e2e_ack_ttl_ms,
          elapsed_ms = now - info.sent_at_ms,
        })
        self:log(string.format(
          "e2e_ack_timeout ctr=%d dst=%s elapsed=%dms (no E2E ACK in %dms)",
          info.ctr, info.dst_name, now - info.sent_at_ms, self.e2e_ack_ttl_ms))
        self.pending_e2e[key] = nil
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
    age_out_id_bind(self)
    age_out_gateway_remote_bind(self)
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
      if debug_emit_allowed(self) then
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
        -- Priority counters (ROADMAP §3a) — for debug-window tracing.
        local now_snap = self:now()
        local _, priority_self_count = check_priority_budget(self, now_snap)
        local queue_priority_n = 0
        for _, it in ipairs(self.tx_queue) do
          if ((it.flags or 0) & DATA_FLAG_PRIORITY) ~= 0 then
            queue_priority_n = queue_priority_n + 1
          end
        end
        self:emit("node_state_snapshot", {
          node_id             = self.id,
          layer_id            = self.layer_id,
          leaf_id             = self.leaf_id,
          is_gateway          = self.self_gateway == true,
          gateway_layers      = self.gateway_layer_list,
          is_mobile           = self.is_mobile == true,
          blind_count         = blind_n,
          queue_depth         = #self.tx_queue,
          queue_priority_n    = queue_priority_n,
          deferred_count      = #self.deferred_sends,
          has_pending_tx      = self.pending_tx ~= nil,
          has_pending_rx      = self.pending_rx ~= nil,
          rt_dst_count        = rt_n,
          rt_total_candidates = rt_cands,
          budget_tier         = compute_budget_tier(self),
          pct_used            = pct_used,
          priority_self_count = priority_self_count,
        })
        emit_rt_quality_snapshots(self)
      end
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
  -- Convert the runtime's float dB SNR to Q4 at ingress; all internal
  -- routing/EWMA/score math operates on Q4 from here on.
  local meta_snr_q4 = (meta.snr ~= nil) and db_to_q4(meta.snr) or nil
  if meta.src ~= nil and meta_snr_q4 ~= nil then
    update_snr_ewma(self.snr_ewma_in, meta.src, meta_snr_q4, self.snr_ewma_alpha_q4)
  end
  local learned_direct_pre = false
  -- Per-RX direct-neighbour route learning. Learn only after the frame is
  -- known to belong to the active leaf/layer, otherwise a gateway listening
  -- on one layer can pollute that layer's rt[] with a foreign-layer sender
  -- before the later per-frame leaf filter rejects the payload.
  local function learn_rx_source(source)
    if meta.src == nil or meta_snr_q4 == nil then return false end
    local pre_action = learn_direct_from_frame(self, meta.src, meta_snr_q4, source or "direct_frame")
    learned_direct_pre = (pre_action == "new"
                          or pre_action == "promote"
                          or pre_action == "primary_refresh"
                          or pre_action == "alt_install")
    id_bind_refresh_plain(self, meta.src, source or "rx_frame")
    mark_dest_seen(self, meta.src, "direct")
    clear_peer_suspect(self, meta.src, "rx_frame")
    return learned_direct_pre
  end
  local tag = frame:sub(1, 1)

  if tag == "J" then
    local j = parse_j(frame)
    if not j then return end
    if j.leaf_id ~= active_leaf_id(self) then return end
    learn_rx_source("j_frame")
    if join_j_rate_limited(self, j, meta) then return end

    if j.opcode == J_OP_DISCOVER then
      self:emit("join_discover_received", {
        from = meta.src,
        key_hash32 = j.key_hash32,
        requester_mobile = j.requester_is_mobile == true,
        gateway_capable = j.gateway_capable == true,
      })
      if meta.src ~= self.id and self.key_hash32 ~= nil then
        local delay = self:rand(self.join_offer_backoff_min_ms or 100,
                                (self.join_offer_backoff_max_ms or 1000) + 1)
        self:after(delay, function()
          local tx_leaf_id = active_leaf_id(self)
          local tx_routing_sf = active_routing_sf(self)
          local offer = pack_j_offer(tx_leaf_id, self.id, self.key_hash32,
                                     active_allowed_sf_bitmap(self) or 0,
                                     self.is_mobile == true,
                                     self.self_gateway == true)
          self:emit("join_offer_sent", {
            to = meta.src,
            responder_node_id = self.id,
            responder_key_hash32 = self.key_hash32,
            data_sf_bitmap = active_allowed_sf_bitmap(self) or 0,
            layer_id = self.active_layer_id or self.layer_id,
            requester_mobile = self.is_mobile == true,
            gateway_capable = self.self_gateway == true,
            delay_ms = delay,
            tx_layer_id = self.active_layer_id or self.layer_id,
            tx_leaf_id = tx_leaf_id,
            tx_routing_sf = tx_routing_sf,
          })
          tx_initiating(self, offer, {
            sf = tx_routing_sf,
            label = "J",
            info = string.format("op=offer to=%s data_sf_bitmap=0x%02x",
                                 tostring(meta.src), active_allowed_sf_bitmap(self) or 0),
          })
        end)
      end
      return
    elseif j.opcode == J_OP_OFFER then
      self:emit("join_offer_received", {
        from = meta.src,
        responder_node_id = j.responder_node_id,
        responder_key_hash32 = j.responder_key_hash32,
        data_sf_bitmap = j.data_sf_bitmap,
        requester_mobile = j.requester_is_mobile == true,
        gateway_capable = j.gateway_capable == true,
      })
      id_bind_set(self, j.responder_node_id, j.responder_key_hash32,
                  "j_offer", "claimed")
      if self.join_required and not self.joined
         and j.data_sf_bitmap ~= nil and j.data_sf_bitmap ~= 0 then
        if self.join_data_sfs_locked then
          self:emit("join_data_sfs_offer_ignored", {
            from = meta.src,
            data_sf_bitmap = j.data_sf_bitmap,
            adopted_data_sf_bitmap = self.allowed_sf_bitmap,
            reason = "already_adopted",
          })
        else
          self.allowed_sf_bitmap = j.data_sf_bitmap
          self.allowed_data_sfs = sf_bitmap_to_set(j.data_sf_bitmap)
          self.join_data_sfs_locked = true
          if (self.active_layer_id or self.layer_id) == self.layer_id then
            self.active_allowed_sf_bitmap = self.allowed_sf_bitmap
            self.active_allowed_data_sfs = self.allowed_data_sfs
          end
          self:emit("join_data_sfs_adopted", {
            from = meta.src,
            data_sf_bitmap = self.allowed_sf_bitmap,
            count = #self.allowed_data_sfs,
          })
        end
      end
      if self.join_required and not self.joined then
        join_start_claim(self, "offer")
      end
      return
    elseif j.opcode == J_OP_CLAIM then
      self:emit("join_claim_received", {
        from = meta.src,
        proposed_node_id = j.proposed_node_id,
        key_hash32 = j.key_hash32,
        lease_age_seconds = j.lease_age_seconds,
        claim_epoch = j.claim_epoch,
        nonce = j.nonce,
        requester_mobile = j.requester_is_mobile == true,
        gateway_capable = j.gateway_capable == true,
      })
      gateway_note_remote_binding(self, self.active_layer_id or self.layer_id,
                                  j.proposed_node_id, j.key_hash32, "j_claim")
      try_drain_gateway_handoffs(self)
      local conflict = false
      local self_pending_wins = false
      local existing = self.id_bind and self.id_bind[j.proposed_node_id]
      if j.proposed_node_id == self.id and self.joined then
        conflict = true
      elseif existing and existing.key_hash32 ~= j.key_hash32 then
        conflict = true
      elseif self.join_claim_pending
             and self.join_claim_pending.proposed_node_id == j.proposed_node_id
             and self.join_claim_pending.key_hash32 ~= j.key_hash32 then
        local p = self.join_claim_pending
        self_pending_wins = join_claim_compare(p.key_hash32, p.nonce,
                                               j.key_hash32, j.nonce)
        if self_pending_wins then
          conflict = true
        else
          self.join_claim_pending = nil
          self.join_denied_ids[j.proposed_node_id] = true
          self:emit("join_claim_denied", {
            denied_node_id = j.proposed_node_id,
            owner_key_hash32 = j.key_hash32,
            claimant_key_hash32 = p.key_hash32,
            reason = "simultaneous_claim_lost",
          })
          self:after(self.join_retry_backoff_ms or 10000, function()
            if not self.joined then join_start_claim(self, "simultaneous_claim_lost") end
          end)
        end
      end
      if conflict and self.key_hash32 ~= nil then
        local owner_key_hash32 = self.key_hash32
        local owner_claim_epoch = self.join_claim_epoch or 0
        if self_pending_wins and self.join_claim_pending then
          owner_key_hash32 = self.join_claim_pending.key_hash32
          owner_claim_epoch = self.join_claim_pending.claim_epoch or owner_claim_epoch
        elseif existing and existing.key_hash32 ~= nil then
          owner_key_hash32 = existing.key_hash32
        end
        local deny_reason = self_pending_wins
                            and J_DENY_REASON_PENDING_CLAIM
                            or J_DENY_REASON_CONFLICT
        local tx_leaf_id = active_leaf_id(self)
        local tx_routing_sf = active_routing_sf(self)
        local owner_lease_age = lease_age_seconds_now(self)
        local deny = pack_j_deny(tx_leaf_id, j.proposed_node_id,
                                 owner_key_hash32, j.key_hash32,
                                 owner_lease_age, owner_claim_epoch,
                                 deny_reason,
                                 self.is_mobile == true,
                                 self.self_gateway == true)
        self:emit("join_deny_sent", {
          denied_node_id = j.proposed_node_id,
          owner_key_hash32 = owner_key_hash32,
          claimant_key_hash32 = j.key_hash32,
          owner_lease_age_seconds = owner_lease_age,
          owner_claim_epoch = owner_claim_epoch,
          reason = deny_reason,
          requester_mobile = self.is_mobile == true,
          gateway_capable = self.self_gateway == true,
          tx_layer_id = self.active_layer_id or self.layer_id,
          tx_leaf_id = tx_leaf_id,
          tx_routing_sf = tx_routing_sf,
        })
        tx_initiating(self, deny, {
          sf = tx_routing_sf,
          label = "J",
          info = string.format("op=deny node=%d", j.proposed_node_id),
        })
      else
        id_bind_set(self, j.proposed_node_id, j.key_hash32, "j_claim", "claimed")
      end
      return
    elseif j.opcode == J_OP_DENY then
      self:emit("join_deny_received", {
        from = meta.src,
        denied_node_id = j.denied_node_id,
        owner_key_hash32 = j.owner_key_hash32,
        claimant_key_hash32 = j.claimant_key_hash32,
        owner_lease_age_seconds = j.owner_lease_age_seconds,
        owner_claim_epoch = j.owner_claim_epoch,
        reason = j.reason,
        requester_mobile = j.requester_is_mobile == true,
        gateway_capable = j.gateway_capable == true,
      })
      id_bind_set(self, j.denied_node_id, j.owner_key_hash32, "j_deny", "claimed")
      -- Joined-state recovery: a peer with the same id is asserting
      -- ownership of MY id with a competing lease/epoch. Tie-break:
      -- older lease wins; equal → higher epoch; equal → lower key.
      if self.joined and self.key_hash32 ~= nil
         and j.denied_node_id == self.id
         and j.claimant_key_hash32 == self.key_hash32
         and j.owner_key_hash32 ~= self.key_hash32 then
        local my_lease = lease_age_seconds_now(self)
        local my_epoch = self.join_claim_epoch or 0
        local i_win = addr_conflict_tie_break(
          my_lease, my_epoch, self.key_hash32,
          j.owner_lease_age_seconds or 0,
          j.owner_claim_epoch or 0,
          j.owner_key_hash32 or 0)
        self:emit("addr_conflict_tie_break", {
          node = self.id,
          i_win = i_win,
          my_lease_age_seconds = my_lease,
          my_claim_epoch = my_epoch,
          my_key_hash32 = self.key_hash32,
          their_lease_age_seconds = j.owner_lease_age_seconds or 0,
          their_claim_epoch = j.owner_claim_epoch or 0,
          their_key_hash32 = j.owner_key_hash32 or 0,
        })
        if not i_win and forced_rejoin ~= nil then
          forced_rejoin(self, "addr_conflict_lost",
                        j.owner_key_hash32,
                        j.owner_lease_age_seconds,
                        j.owner_claim_epoch)
        end
        return
      end
      local p = self.join_claim_pending
      if self.join_required and not self.joined and p
         and p.proposed_node_id == j.denied_node_id
         and j.claimant_key_hash32 == (self.key_hash32 or 0) then
        self.join_denied_ids[j.denied_node_id] = true
        self.join_claim_pending = nil
        self:emit("join_claim_denied", {
          denied_node_id = j.denied_node_id,
          owner_key_hash32 = j.owner_key_hash32,
          claimant_key_hash32 = j.claimant_key_hash32,
          reason = j.reason,
        })
        self:after(self.join_retry_backoff_ms or 10000, function()
          if not self.joined then join_start_claim(self, "deny_backoff") end
        end)
      end
      return
    end
    return
  end

  if tag == "B" then
    local b = parse_beacon(frame)
    if not b then return end
    -- Cross-network filter — drop foreign-network beacons before they
    -- pollute our routing table. Same field as RTS, same admin-managed
    -- 4-bit space. Silent drop (no event spam — expected during
    -- enhanced propagation events).
    if b.leaf_id ~= active_leaf_id(self) then return end
    learn_rx_source("beacon_frame")
    id_bind_set(self, b.src, b.key_hash32, "bcn", "claimed")
    remember_gateway_schedule(self, b.src, b)
    -- PROTOCOL §3.1 type 4: ingest propagated cross-layer routing.
    -- Skip self-references (we shouldn't be in our own re-gossip).
    if b.gateway_layer_entries ~= nil then
      local filtered = {}
      for _, e in ipairs(b.gateway_layer_entries) do
        if e.gw_id ~= self.id then
          table.insert(filtered, e)
        end
      end
      ingest_gateway_layer_entries(self, b.src, filtered)
    end
    gateway_note_remote_binding(self, self.active_layer_id or self.layer_id,
                                b.src, b.key_hash32, "bcn")
    try_drain_gateway_handoffs(self)
    if meta_snr_q4 ~= nil then
      rt_merge(self, self.rt, b.src, {
        next_hop     = b.src,
        hops         = 1,
        score        = meta_snr_q4,
        last_seen_ms = self:now(),
        n2_hop       = nil,
        is_gateway   = (b.self_gateway == true),
      }, (SF_DEMOD_THRESHOLD[active_routing_sf(self)] or -240) + self.sf_margin_q4)
    end
    if b.is_mobile then
      self.mobile_peers[b.src] = true
    end
    self:emit("beacon_rx", {
      src = b.src,
      key_hash32 = b.key_hash32,
      identity_only = b.is_mobile and #b.entries == 0,
      n_entries = #b.entries,
      seen_bits = b.seen_bits or 0,
      suspect_nodes = b.suspect_nodes and #b.suspect_nodes or 0,
      liveness_states = b.liveness_states and #b.liveness_states or 0,
      channel_digest_ids = b.channel_digest_ids and #b.channel_digest_ids or 0,
    })
    -- ROADMAP §3 channel gossip: react to CHANNEL_DIGEST TLV if present.
    process_channel_digest(self, b)
    if b.seen_bitmap then
      local seen_n, refreshed_n = apply_seen_bitmap(self, b.seen_bitmap, "bitmap", b.src)
      self:emit("seen_bitmap_rx", {
        from = b.src,
        bits_set = b.seen_bits or seen_n,
        applied = seen_n,
        refreshed = refreshed_n,
      })
    end
    if b.suspect_nodes then
      local applied = 0
      local self_marked = false
      for _, node_id in ipairs(b.suspect_nodes) do
        if node_id == self.id then
          self_marked = true
        elseif node_id ~= b.src then
          applied = applied + mark_peer_suspect(self, node_id, 1, "bcn_suspect", b.src)
        end
      end
      self:emit("peer_suspect_bcn_rx", {
        from = b.src,
        count = #b.suspect_nodes,
        applied = applied,
        self_marked = self_marked,
      })
      if self_marked then
        local tier = compute_budget_tier(self)
        self:emit("peer_suspect_self_heard", {
          from = b.src,
          budget_tier = tier,
        })
        if tier < BUDGET_TIER_CRITICAL then
          schedule_triggered_beacon(self)
        end
      end
    end
    if b.liveness_states then
      local applied = 0
      local self_marked = false
      local dead_n = 0
      for _, rec in ipairs(b.liveness_states) do
        local node_id = rec.node
        local state = rec.state or 0
        if node_id == self.id then
          self_marked = true
        elseif node_id ~= b.src and state > 0 then
          if state >= PEER_LEVEL_DEAD then dead_n = dead_n + 1 end
          applied = applied + mark_peer_suspect(self, node_id, state, "bcn_liveness", b.src)
        end
      end
      self:emit("peer_liveness_bcn_rx", {
        from = b.src,
        count = #b.liveness_states,
        applied = applied,
        dead = dead_n,
        self_marked = self_marked,
      })
      if self_marked then
        local tier = compute_budget_tier(self)
        self:emit("peer_suspect_self_heard", {
          from = b.src,
          budget_tier = tier,
          source = "bcn_liveness",
        })
        if tier < BUDGET_TIER_CRITICAL then
          schedule_triggered_beacon(self)
        end
      end
    end

    local now = self:now()
    -- Track time of last BCN-RX (separate from last_rx_routing_sf_ms,
    -- which catches every routing-plane RX including RTS/CTS/ACK).
    -- The max-idle override consults this specifically — when a
    -- neighbour just beaconed, our routing-info refresh need is
    -- already covered, so we defer our own override even if the
    -- generic channel-busy throttle would fire it. See beacon_fire.
    self.last_rx_bcn_ms = now
    if in_discovery(self) then
      self.discovery_bcn_rx_count = (self.discovery_bcn_rx_count or 0) + 1
    end
    if self.sync_response_pending then
      local useful_bcn = (#b.entries > 0) or ((b.seen_bits or 0) > 1)
      if useful_bcn then
        for _, pending in pairs(self.sync_response_pending) do
          if now <= pending.fire_at
             and (now - pending.requested_at) <= (self.sync_response_suppress_window_ms or 0) then
            pending.suppressed = true
          end
        end
      end
    end

    -- Track whether anything in our rt actually changed during this beacon
    -- so we can fire a single triggered re-beacon at the end (one trigger
    -- per beacon RX, not one per entry — coalesced anyway, but cheaper).
    local rt_changed = false

    -- Direct entry: candidate is via the beacon-sender at hops=1, score=rx_snr.
    -- rt_merge handles whether this becomes primary, alt, or no-change. We
    -- log only when something interesting changed (new or promotion to
    -- primary) to avoid spamming on every refresh round.
    do
      mark_dest_seen(self, b.src, "beacon_src")
      local direct_score_q4 = route_score_from_snr(self, meta_snr_q4)
      local cand = {
        next_hop = b.src,
        score = direct_score_q4,
        hops = 1,
        is_gateway = (b.self_gateway == true),
        last_seen_ms = now,
        learned_layer_id = self.active_layer_id or self.layer_id,
      }
      local action = rt_merge(self, self.rt, b.src, cand, self.routing_snr_floor_q4)
      if action == "new" or action == "promote" then
        self:emit("rt_update", {
          dest = b.src, next = b.src, score = q4_to_db(direct_score_q4), rx_snr = meta.snr,
          route_snr_conservatism_db = q4_to_db(self.route_snr_conservatism_q4 or 0),
          hops = 1, slot = "primary",
        })
        self:log(string.format("rt[%s] direct → primary, score=%.1f dB rx_snr=%.1f dB hops=1",
          name_of(self, b.src), q4_to_db(direct_score_q4), meta.snr))
        rt_changed = true
      elseif action == "alt_install" then
        self:emit("rt_update", {
          dest = b.src, next = b.src, score = q4_to_db(direct_score_q4), rx_snr = meta.snr,
          route_snr_conservatism_db = q4_to_db(self.route_snr_conservatism_q4 or 0),
          hops = 1, slot = "alt",
        })
      elseif learned_direct_pre and self.rt[b.src] ~= nil then
        -- The top-of-on_recv direct-frame learner already installed or
        -- promoted this direct route from the same BCN source. Treat the
        -- BCN as having changed our rt for downstream discovery/trigger
        -- bookkeeping, without double-emitting rt_update.
        rt_changed = true
      end
    end

    -- DV merge: each entry in the beacon (other than self / our split-horizon)
    -- is a candidate route via the beacon-sender. K=2 rt_merge slots it as
    -- primary, alt, or drops it.
    for _, e in ipairs(b.entries) do
      mark_dest_seen(self, e.dest, "route")
      if e.dest == self.id then
        -- nothing: split horizon, beacon-sender's view of how to reach me
        -- isn't a route I install for myself.
      elseif e.next == self.id then
        -- Beacon-sender N claims to reach e.dest via me. That alone is fine
        -- (it'd be 1-hop on N's side, "direct via me"), but it also lets us
        -- detect any 3-cycle me→X→N→me already cached in our own rt[e.dest]:
        -- prune slots whose stored n2_hop equals N.
        rt_prune_cycle(self, e.dest, b.src)
      elseif get_peer_suspect_level(self, e.next) >= 2 then
        self:emit("rt_skip_silent_n2", {
          dest = e.dest,
          via = b.src,
          advertised_next = e.next,
          suspect_level = get_peer_suspect_level(self, e.next),
        })
      else
        local rx_score_q4 = route_score_from_snr(self, meta_snr_q4)
        local combined_score_q4 = math.min(rx_score_q4, e.score)
        local combined_hops  = e.hops + 1
        if combined_hops <= 8 then
          local cand = {
            next_hop   = b.src,
            n2_hop     = e.next,   -- N's claimed next-hop for e.dest; used by rt_prune_cycle
            score      = combined_score_q4,
            hops       = combined_hops,
            is_gateway = (e.is_gateway == true),
            last_seen_ms = now,
            learned_layer_id = self.active_layer_id or self.layer_id,
          }
          local action = rt_merge(self, self.rt, e.dest, cand, self.routing_snr_floor_q4)
          if action == "new" or action == "promote" then
            self:emit("rt_update", {
              dest = e.dest, next = b.src,
              score = q4_to_db(combined_score_q4), rx_snr = meta.snr,
              route_snr_conservatism_db = q4_to_db(self.route_snr_conservatism_q4 or 0),
              advertised_score = q4_to_db(e.score), hops = combined_hops, slot = "primary",
            })
            self:log(string.format("rt[%s] via %s, hops=%d score=%.1f dB rx_snr=%.1f dB (primary)",
              name_of(self, e.dest), name_of(self, b.src), combined_hops, q4_to_db(combined_score_q4), meta.snr))
            rt_changed = true
          elseif action == "alt_install" then
            self:emit("rt_update", {
              dest = e.dest, next = b.src,
              score = q4_to_db(combined_score_q4), rx_snr = meta.snr,
              route_snr_conservatism_db = q4_to_db(self.route_snr_conservatism_q4 or 0),
              advertised_score = q4_to_db(e.score), hops = combined_hops, slot = "alt",
            })
            self:log(string.format("rt[%s] via %s, hops=%d score=%.1f dB rx_snr=%.1f dB (alt)",
              name_of(self, e.dest), name_of(self, b.src), combined_hops, q4_to_db(combined_score_q4), meta.snr))
          end
        end
      end
    end

    maybe_exit_discovery(self, rt_changed and "rt_update" or "beacon_rx")

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
    -- Cross-network filter — drop foreign-network RTSes before any routing,
    -- anti-spam, or implicit-ACK side effects.
    if r.leaf_id ~= active_leaf_id(self) then return end
    learn_rx_source("rts_frame")
    -- Anti-spam observation FIRST: track this RTS in r.src's sliding
    -- window even when the RTS isn't addressed to us (we're overhearing
    -- broadcasts on routing_sf). All 1st-hop neighbours of an originator
    -- accumulate independent evidence this way, so the spammer can't
    -- evade by picking next-hops who don't observe enough.
    -- EXCEPTION: a gateway cross-layer forward (RTS_FLAG_RELAY) is not a
    -- 1st-hop origination — on the target layer the gateway re-injects with
    -- no preceding CTS, so counting it would mis-read the gateway as a
    -- runaway originator (§10a). Don't observe it; don't throttle it.
    if not r.relay then
      track_originator_observation(self, meta.src, "rts", r.ctr_lo,
        airtime_ms(active_routing_sf(self), self.bw_hz, self.cr,
                   self.preamble_sym, #frame))
    else
      -- Gateway cross-layer forward: exempt from the §10a originator metric.
      self:emit("rts_relay_exempt", { from = meta.src, ctr_lo = r.ctr_lo })
    end
    -- If we are waiting for a hop ACK from our selected next-hop and we
    -- overhear that next-hop forwarding the same DATA onward, that RTS-fwd is
    -- an implicit ACK: the next-hop must have decoded our DATA. This prevents
    -- the upstream retry from colliding with the forwarder's downstream DATA
    -- after a lost hop ACK.
    if self.pending_tx ~= nil
       and meta.src == self.pending_tx.next
       and r.src == self.pending_tx.next
       and r.dst == self.pending_tx.dst
       and r.ctr_lo == self.pending_tx.ctr_lo
       and r.payload_len == (#self.pending_tx.payload + MAC_LEN) then
      if self.rts_timeout_handle then
        self:cancel(self.rts_timeout_handle)
        self.rts_timeout_handle = nil
      end
      if self.ack_timeout_handle then
        self:cancel(self.ack_timeout_handle)
        self.ack_timeout_handle = nil
      end
      self:emit("implicit_ack_from_forward", {
        from = meta.src,
        origin = self.pending_tx.origin,
        dst = self.pending_tx.dst,
        next = self.pending_tx.next,
        ctr = self.pending_tx.ctr,
        ctr_lo = self.pending_tx.ctr_lo,
        payload = self.pending_tx.user_text,
        forward_next = r.next,
        attempt_seq = self.pending_tx.last_rts_attempt_seq,
      })
      self:log(string.format(
        "implicit_ack_from_forward <- %s ctr_lo=%d forwarding to %s -> hop complete",
        name_of(self, meta.src), r.ctr_lo, name_of(self, r.next)))
      self.pending_tx = nil
      become_free(self)
      return
    end
    -- 2B-broadcast: M_BROADCAST RTS announces chosen_data_sf via the
    -- sf_bitmap byte (only one bit set). EVERY decoder of this RTS —
    -- including the "addressed" target r.next — must retune to
    -- chosen_data_sf for the DATA window. No CTS is expected (no
    -- channel-reservation handshake under broadcast) so the addressed
    -- target must NOT fall through to the normal CTS-response path.
    -- Eligibility: not a gateway (Principle 11), currently idle. Busy
    -- nodes silently skip — they can't retune mid-flight, and cascade
    -- BCN-digest will re-advertise the dirty id for a later pull.
    if r.m_broadcast then
      -- id_lo16 pre-arm check: if the RTS announced 16 bits of the msg
      -- id and any entry in our buffer matches, skip the arm — no
      -- retune to data SF, no ~2 s routing-SF blindness, no decode of
      -- a duplicate. Saves the bulk of the "already_present" overhead.
      -- 16-bit collisions: bounded by simultaneous-active msg count
      -- (<< 65 k), so false positives are negligible. Worst-case false
      -- positive: receiver skips a NEW msg whose id_lo16 happens to
      -- collide with a held entry; cascade recovers via other holders.
      if r.m_payload_id_lo16 ~= nil and self.channel_buffer ~= nil then
        for _, e in ipairs(self.channel_buffer) do
          if (e.id & 0xFFFF) == r.m_payload_id_lo16 then
            self:emit("channel_overhear_skipped_already_have", {
              ctr_lo = r.ctr_lo, sender = r.src,
              id_lo16 = r.m_payload_id_lo16,
            })
            return
          end
        end
      end
      if not self.self_gateway
         and self.pending_tx == nil and self.pending_rx == nil then
        local sf_set = sf_bitmap_to_set(r.sf_bitmap)
        local chosen_sf = sf_set[#sf_set] or self.routing_sf
        local data_air = airtime_ms(chosen_sf, self.bw_hz, self.cr,
          self.preamble_sym,
          DATA_HDR_LEN + r.payload_len + DATA_INNER_OVERHEAD)
        local guard_ms = (self.cts_to_data_gap_ms or 5) + data_air + 50
        self:emit("channel_overhear_armed", {
          ctr_lo = r.ctr_lo, sender = r.src, target = r.next,
          chosen_data_sf = chosen_sf, guard_ms = guard_ms,
          addressed = (r.next == self.id),
        })
        -- Track per-arm so the retune-back timer can emit a
        -- channel_overhear_missed if the DATA-M didn't decode during
        -- the window. Key by (sender, ctr_lo) which uniquely
        -- identifies the broadcast attempt for this RTS.
        self.pending_overhear_arms = self.pending_overhear_arms or {}
        local arm_key = (r.src or 0) * 256 + (r.ctr_lo or 0)
        self.pending_overhear_arms[arm_key] = {
          sender = r.src, ctr_lo = r.ctr_lo, chosen_data_sf = chosen_sf,
          armed_at = self:now(),
        }
        self:set_rx_sf(chosen_sf)
        self.overhearing_until_ms = self:now() + guard_ms
        local captured_arm_key = arm_key
        self:after(guard_ms, function()
          if self.overhearing_until_ms ~= nil
             and self:now() >= self.overhearing_until_ms - 5 then
            self.overhearing_until_ms = nil
            self:set_rx_sf(self.routing_sf)
          end
          -- Check if we actually decoded the DATA-M during the window.
          -- The M-handler clears the arm entry on successful decode.
          -- If still present here, the decode never happened.
          if self.pending_overhear_arms ~= nil
             and self.pending_overhear_arms[captured_arm_key] ~= nil then
            local arm = self.pending_overhear_arms[captured_arm_key]
            self.pending_overhear_arms[captured_arm_key] = nil
            self:emit("channel_overhear_missed", {
              sender = arm.sender, ctr_lo = arm.ctr_lo,
              chosen_data_sf = arm.chosen_data_sf,
              elapsed_ms = self:now() - arm.armed_at,
            })
          end
        end)
      end
      -- Whether or not we armed, an M_BROADCAST RTS terminates the
      -- normal addressed-receiver flow. No CTS, no pending_rx, no ACK.
      -- If we missed the retune window (busy/gateway), the M-frame
      -- arrives later via cascade.
      return
    end
    if r.next ~= self.id then return end  -- not for us; silent discard
    self:emit("rts_receiver_state", {
      from = r.src,
      dst = r.dst,
      ctr_lo = r.ctr_lo,
      rx_snr = meta.snr,
      ewma_snr = q4_to_db(self.snr_ewma_in[r.src] or meta_snr_q4),
      has_pending_tx = self.pending_tx ~= nil,
      pending_tx_ctr_lo = self.pending_tx and self.pending_tx.ctr_lo or nil,
      pending_tx_next = self.pending_tx and self.pending_tx.next or nil,
      has_pending_rx = self.pending_rx ~= nil,
      pending_rx_from = self.pending_rx and self.pending_rx.from or nil,
      pending_rx_ctr_lo = self.pending_rx and self.pending_rx.ctr_lo or nil,
      budget_tier = compute_budget_tier(self),
    })

    -- Sender is retrying an RTS for a DATA we already received and acked
    -- (their previous ACK was lost in flight). Reply with CTS carrying
    -- already_received=1: the sender clears pending_tx without sending
    -- DATA again, and we avoid reprocessing/duplicating the message.
    -- last_acked_from holds recently acked DATA identities. Scope by
    -- sender + destination + ctr_lo + payload_len so the 4-bit ctr_lo
    -- shortcut cannot match a different packet from the same sender.
    local ack_key = last_acked_key(r.src, r.dst, r.ctr_lo, r.payload_len)
    local cached = self.last_acked_from[ack_key]
    if cached and (self:now() - cached.t_ms) < self.last_acked_ttl_ms then
      self:emit("rts_already_acked", {
        from = r.src, dst = r.dst, ctr_lo = r.ctr_lo,
        payload_len = r.payload_len,
      })
      self:log(string.format("rts_already_acked <- %s dst=%s ctr_lo=%d len=%d -> CTS already_received",
        name_of(self, r.src), name_of(self, r.dst), r.ctr_lo, r.payload_len))
      local chosen_sf = cached.chosen_data_sf
      if chosen_sf ~= nil and not sf_in_bitmap(r.sf_bitmap, chosen_sf) then
        chosen_sf = nil
      end
      local sf_select_snr_q4, ewma_snr_q4 = data_sf_selection_snr(self, r.src, meta_snr_q4)
      chosen_sf = chosen_sf or select_data_sf(
        sf_select_snr_q4, r.sf_bitmap, self.sf_margin_q4)
      if chosen_sf == nil then
        for sf = 5, 12 do
          if sf_in_bitmap(r.sf_bitmap, sf) then
            chosen_sf = sf
            break
          end
        end
      end
      if chosen_sf == nil then return end
      local cts = pack_cts(r.ctr_lo, chosen_sf, true, r.src)
      self:emit("cts_tx", {
        to = r.src, ctr_lo = r.ctr_lo,
        chosen_data_sf = chosen_sf,
        already_received = true,
        rx_snr = meta.snr,
        ewma_snr = q4_to_db(ewma_snr_q4),
        sf_select_snr = q4_to_db(sf_select_snr_q4),
      })
      tx_with_retry(self, cts, {
        sf    = active_routing_sf(self),
        label = "CTS-dup",
        info  = string.format("to=%s msg=%d chosen_sf=%d already_received=1",
          name_of(self, r.src), r.ctr_lo, chosen_sf),
      })
      return
    end

    if self.pending_rx ~= nil then
      -- Duplicate RTS from the same originator for the same DATA identity: their
      -- previous CTS may have been lost, or DATA was sent and ACK was
      -- lost (and our pending_rx hasn't expired yet). Re-send the CTS so
      -- they can re-attempt DATA.
      if self.pending_rx.from == r.src
         and self.pending_rx.dst == r.dst
         and self.pending_rx.ctr_lo == r.ctr_lo
         and self.pending_rx.payload_len == r.payload_len then
        self:emit("rts_rx_dup", {
          from = r.src, dst = r.dst, ctr_lo = r.ctr_lo,
          payload_len = r.payload_len,
        })
        self:log(string.format("rts_rx_dup <- %s dst=%s ctr_lo=%d len=%d -> resending CTS (sf=%d)",
          name_of(self, r.src), name_of(self, r.dst), r.ctr_lo, r.payload_len,
          self.pending_rx.chosen_data_sf))
        local cts = pack_cts(r.ctr_lo, self.pending_rx.chosen_data_sf, false, r.src)
        self:emit("cts_tx", {
          to = r.src, ctr_lo = r.ctr_lo, dup = true,
          chosen_data_sf = self.pending_rx.chosen_data_sf,
        })
      tx_with_retry(self, cts, {
          sf    = active_routing_sf(self),
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
      local nack = pack_nack(r.ctr_lo, NACK_REASON_BUSY_RX, busy_payload, r.src)
      self:emit("nack_tx", {
        to = r.src, ctr_lo = r.ctr_lo, busy_for_ms = busy_for, reason = "pending_rx",
      })
      self:log(string.format("nack_tx -> %s ctr_lo=%d busy_for=%dms (busy with pending_rx from %s/%d)",
        name_of(self, r.src), r.ctr_lo, busy_for,
        name_of(self, self.pending_rx.from), self.pending_rx.ctr_lo))
      tx_initiating(self, nack, {
        sf    = active_routing_sf(self),
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
    -- Gateway cross-layer forwards (RTS_FLAG_RELAY) are exempt — they aren't
    -- 1st-hop originations (the gateway is relaying for the cross-layer origin),
    -- and their RTS-without-CTS on this layer would otherwise trip the metric.
    if not r.relay then
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
      local nack = pack_nack(r.ctr_lo, NACK_REASON_BUDGET, ((my_tier & 0xf) << 4) | 0, r.src)
      self:emit("nack_tx", {
        to = r.src, ctr_lo = r.ctr_lo,
        reason = "budget_low", tier = my_tier,
      })
      self:log(string.format(
        "nack_tx -> %s ctr_lo=%d reason=budget_low tier=%d",
        name_of(self, r.src), r.ctr_lo, my_tier))
      tx_initiating(self, nack, {
        sf    = active_routing_sf(self),
        label = "NACK",
        info  = string.format("to=%s msg=%d reason=budget tier=%d",
          name_of(self, r.src), r.ctr_lo, my_tier),
      })
      return
    end

    -- Pick a data SF from the RTS's allowed-SF bitmap using a conservative
    -- SNR estimate. The current RTS proves the immediate channel state;
    -- EWMA only helps when it is lower than that sample.
    -- Empty bitmap → nothing we can do; silent drop (sender's rts_timeout
    -- will handle it).
    local snr_for_sf_q4, ewma_snr_q4 = data_sf_selection_snr(self, r.src, meta_snr_q4)
    local chosen_sf  = select_data_sf(snr_for_sf_q4, r.sf_bitmap, self.sf_margin_q4)
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
      rx_snr = meta.snr, ewma_snr = q4_to_db(ewma_snr_q4), sf_select_snr = q4_to_db(snr_for_sf_q4),
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

    local cts = pack_cts(r.ctr_lo, chosen_sf, false, r.src)
    self:emit("cts_tx", {
      to = r.src, ctr_lo = r.ctr_lo,
      chosen_data_sf = chosen_sf,
      rx_snr = meta.snr,
      ewma_snr = q4_to_db(ewma_snr_q4),
      sf_select_snr = q4_to_db(snr_for_sf_q4),
    })
    self:log(string.format("cts_tx -> %s ctr_lo=%d chose SF%d (on routing SF%d)",
      name_of(self, r.src), r.ctr_lo, chosen_sf, active_routing_sf(self)))
    tx_with_retry(self, cts, {
      sf    = active_routing_sf(self),
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

    if c.to ~= self.id then
      return
    end

    if self.pending_tx == nil then return end
    if c.ctr_lo ~= self.pending_tx.ctr_lo then return end
    if self.pending_tx.awaiting_cts == false then
      self:emit("cts_drop_no_active_rts", {
        from = meta.src,
        ctr_lo = c.ctr_lo,
        origin = self.pending_tx.origin,
        dst = self.pending_tx.dst,
        next = self.pending_tx.next,
        payload = self.pending_tx.user_text,
        attempt_seq = self.pending_tx.last_rts_attempt_seq,
      })
      return
    end
    if meta.src ~= nil and meta.src ~= self.pending_tx.next then
      self:emit("cts_drop_unexpected_src", {
        expected = self.pending_tx.next,
        from = meta.src,
        ctr_lo = c.ctr_lo,
        origin = self.pending_tx.origin,
        dst = self.pending_tx.dst,
        payload = self.pending_tx.user_text,
      })
      return
    end
    learn_rx_source("cts_frame")

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
    local cts_allowed_bitmap = (self.pending_tx and self.pending_tx.tx_sf_bitmap)
                               or active_allowed_sf_bitmap(self)
    if not sf_in_bitmap(cts_allowed_bitmap, c.chosen_data_sf) then
      self:emit("cts_invalid_sf", {
        origin = self.pending_tx.origin, payload = self.pending_tx.user_text,
        from = c.src or self.pending_tx.next, ctr_lo = c.ctr_lo,
        chosen_data_sf = c.chosen_data_sf,
        allowed_sf_bitmap = cts_allowed_bitmap,
      })
      return
    end
    self.pending_tx.chosen_data_sf = c.chosen_data_sf

    self:emit("cts_rx", {
      attempt_seq = self.pending_tx.last_rts_attempt_seq,
      origin = self.pending_tx.origin,
      payload = self.pending_tx.user_text,
      ctr = self.pending_tx.ctr,
      from = self.pending_tx.next, ctr_lo = c.ctr_lo,
      chosen_data_sf = c.chosen_data_sf,
      already_received = c.already_received,
    })

    if c.already_received then
      if self.ack_timeout_handle then
        self:cancel(self.ack_timeout_handle)
        self.ack_timeout_handle = nil
      end
      self:emit("cts_already_received_rx", {
        attempt_seq = self.pending_tx.last_rts_attempt_seq,
        origin = self.pending_tx.origin,
        payload = self.pending_tx.user_text,
        ctr = self.pending_tx.ctr,
        from = self.pending_tx.next,
        ctr_lo = c.ctr_lo,
        chosen_data_sf = c.chosen_data_sf,
      })
      self:log(string.format(
        "cts_rx <- %s ctr_lo=%d already_received=1 -> hop complete without DATA",
        name_of(self, self.pending_tx.next), c.ctr_lo))
      self.pending_tx = nil
      become_free(self)
      return
    end

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
      -- pack_data(origin, next_hop, dst, ctr, flags, inner, hop_budget)
      local d = pack_data(px.origin, px.next, px.dst, px.ctr, px.flags or 0, px.payload, px.hop_budget)
      self:emit("data_tx", {
        origin = px.origin, payload = px.user_text, ctr = px.ctr,
        dst = px.dst, next = px.next, ctr_lo = px.ctr_lo, len = #px.payload,
        sf = px.chosen_data_sf,
        data_sf = px.chosen_data_sf,
        tx_layer_id = px.tx_layer_id,
        tx_leaf_id = px.tx_leaf_id,
        tx_routing_sf = px.tx_routing_sf or active_routing_sf(self),
      })
      self:log(string.format("data_tx -> %s ctr_lo=%d ctr=%d payload=%q on SF%d (ACK on SF%d)",
        name_of(self, px.next), px.ctr_lo, px.ctr, px.user_text, px.chosen_data_sf,
        px.tx_routing_sf or active_routing_sf(self)))
      local handed = tx_with_retry(self, d, {
        sf    = px.chosen_data_sf,
        label = "DATA",
        info  = string.format("origin=%s dst=%s next=%s msg=%d ctr=%d sf=%d payload=%q",
          name_of(self, px.origin), name_of(self, px.dst),
          name_of(self, px.next), px.ctr_lo, px.ctr, px.chosen_data_sf, px.user_text),
        on_handed = function()
          if self.pending_tx == nil or self.pending_tx.ctr_lo ~= px.ctr_lo then
            return
          end
          self.pending_tx.awaiting_ack = true
          -- Sender's RX has been on routing_sf throughout — no retune needed.
          -- DATA TX uses the per-tx sf override; the modem's RX state is
          -- independent of TX SF. Keep pending_tx for ack_timeout matching.
          start_ack_timeout(self)
        end,
      })
      if not handed and self.pending_tx ~= nil and self.pending_tx.ctr_lo == px.ctr_lo then
        self.pending_tx.awaiting_ack = false
      end
    end)
    return
  end

  if tag == "K" then
    local k = parse_ack(frame)
    if not k then return end
    if k.to ~= self.id then return end
    if self.pending_tx == nil then return end
    if k.ctr_lo ~= self.pending_tx.ctr_lo then return end
    if self.pending_tx.awaiting_ack ~= true then
      self:emit("ack_drop_no_active_data", {
        from = meta.src,
        ctr_lo = k.ctr_lo,
        origin = self.pending_tx.origin,
        dst = self.pending_tx.dst,
        next = self.pending_tx.next,
        payload = self.pending_tx.user_text,
        attempt_seq = self.pending_tx.last_rts_attempt_seq,
      })
      return
    end
    if meta.src ~= nil and meta.src ~= self.pending_tx.next then
      self:emit("ack_drop_unexpected_src", {
        expected = self.pending_tx.next,
        from = meta.src,
        ctr_lo = k.ctr_lo,
        origin = self.pending_tx.origin,
        dst = self.pending_tx.dst,
        payload = self.pending_tx.user_text,
      })
      return
    end
    learn_rx_source("ack_frame")

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
    if ack_src ~= nil and k.snr_q4 ~= nil then
      update_snr_ewma(self.snr_ewma_out, ack_src, k.snr_q4, self.snr_ewma_alpha_q4)
      self:emit("ack_snr_feedback", {
        from = ack_src, ctr_lo = k.ctr_lo,
        data_snr_db = q4_to_db(k.snr_q4), snr_bucket = k.snr_bucket,
        snr_bucket_coarse = k.snr_bucket_coarse,
        ewma_out = q4_to_db(self.snr_ewma_out[ack_src]),
      })
    end
    local ack_budget_reranked = 0
    if ack_src ~= nil and (k.budget_hint or 0) > BUDGET_TIER_HEALTHY then
      local tier = k.budget_hint
      if tier > BUDGET_TIER_CRITICAL then tier = BUDGET_TIER_CRITICAL end
      ack_budget_reranked = mark_neighbor_budget_tier(self, ack_src, tier, "ack_budget", true)
    end
    self:emit("ack_rx", {
      origin = self.pending_tx.origin,
      payload = self.pending_tx.user_text,
      ctr = self.pending_tx.ctr,
      from = self.pending_tx.next, ctr_lo = k.ctr_lo,
      data_snr_db = q4_to_db(k.snr_q4),
      snr_bucket_coarse = k.snr_bucket_coarse,
      budget_hint = k.budget_hint,
      budget_reranked = ack_budget_reranked,
    })
    self:log(string.format("ack_rx <- %s ctr_lo=%d data_snr=%s budget_hint=%d -> hop complete",
      name_of(self, self.pending_tx.next), k.ctr_lo,
      k.snr_q4 and string.format("%.1fdB", q4_to_db(k.snr_q4)) or "n/a",
      k.budget_hint or 0))
    self.pending_tx = nil
    become_free(self)
    return
  end

  if tag == "N" then
    local n = parse_nack(frame)
    if not n then return end
    if n.to ~= self.id then return end
    if self.pending_tx == nil then return end
    if n.ctr_lo ~= self.pending_tx.ctr_lo then return end
    if meta.src ~= nil and meta.src ~= self.pending_tx.next then
      self:emit("nack_drop_unexpected_src", {
        expected = self.pending_tx.next,
        from = meta.src,
        ctr_lo = n.ctr_lo,
        origin = self.pending_tx.origin,
        dst = self.pending_tx.dst,
        payload = self.pending_tx.user_text,
        reason = n.reason,
      })
      return
    end
    learn_rx_source("nack_frame")

    -- NACK matched: chosen next-hop can't take us right now. Cancel the
    -- rts_timeout (NACK is a faster, definitive signal). NACK rides on
    -- data_sf — same channel as CTS would have come back on — so the
    -- sender's RX (already retuned to data_sf after the RTS TX) hears
    -- it without another retune.
    if self.rts_timeout_handle then
      self:cancel(self.rts_timeout_handle)
      self.rts_timeout_handle = nil
    end
    if self.ack_timeout_handle then
      self:cancel(self.ack_timeout_handle)
      self.ack_timeout_handle = nil
    end
    self.pending_tx.awaiting_cts = false
    self.pending_tx.awaiting_ack = false

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
      local reranked = mark_neighbor_budget_tier(self, from_id, tier, "nack_budget", false)
      self:emit("nack_rx", {
        attempt_seq = self.pending_tx.last_rts_attempt_seq,
        origin = self.pending_tx.origin,
        payload = self.pending_tx.user_text,
        ctr = self.pending_tx.ctr,
        from = self.pending_tx.next, ctr_lo = n.ctr_lo,
        reason = "budget_low", tier = tier, blind_ms = blind_ms,
        reranked = reranked,
      })
      self:log(string.format(
        "nack_rx <- %s ctr_lo=%d reason=budget_low tier=%d -> blind for %dms, reranked=%d",
        name_of(self, self.pending_tx.next), n.ctr_lo, tier, blind_ms, reranked))
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

    -- Hop-budget NACK (§7.6 Phase B). A downstream forwarder ran out
    -- of hop_budget before reaching dst. The flight is dead — there's
    -- no path within the budget. Update rt[dst].hops upward (the route
    -- was longer than we thought) and drop the pending_tx.
    --
    -- Why we don't just retry: a retry with the same originator-side
    -- rt would produce the same budget calculation and same exhaustion.
    -- We need rt[dst] to update first. Tier-aware routing / Q-frame
    -- re-discovery handle that asynchronously; this flight is over.
    if n.reason == NACK_REASON_HOP_BUDGET then
      local dst_id = self.pending_tx.dst
      local committed = n.committed_hops or 0
      -- Update rt[dst].hops upward: the actual path needed at least
      -- (committed + 1) hops, but we had budgeted less. Push the rt
      -- estimate to the empirical minimum we just learned. Capped at
      -- 15 (4-bit limit) so we don't overflow the wire field.
      local entry = self.rt[dst_id]
      if entry and entry.candidates[1] then
        local old_hops = entry.candidates[1].hops
        local new_hops = math.min(15, math.max(old_hops, committed + 1))
        if new_hops ~= old_hops then
          entry.candidates[1].hops = new_hops
          self:emit("rt_update", {
            dest = dst_id, next = entry.candidates[1].next_hop,
            score = entry.candidates[1].score, hops = new_hops,
            slot = "primary", trigger = "hop_budget_nack",
          })
          self:log(string.format(
            "rt[%s].hops %d→%d (hop_budget NACK from %s, committed=%d)",
            name_of(self, dst_id), old_hops, new_hops,
            name_of(self, self.pending_tx.next), committed))
        end
      end
      self:emit("nack_rx", {
        attempt_seq = self.pending_tx.last_rts_attempt_seq,
        origin = self.pending_tx.origin,
        payload = self.pending_tx.user_text,
        ctr = self.pending_tx.ctr,
        from = self.pending_tx.next, ctr_lo = n.ctr_lo,
        reason = "hop_budget", committed_hops = committed,
      })
      self:log(string.format(
        "nack_rx <- %s ctr_lo=%d reason=hop_budget committed=%d (flight terminal)",
        name_of(self, self.pending_tx.next), n.ctr_lo, committed))
      self:emit("path_cascade_exhausted", {
        origin = self.pending_tx.origin,
        payload = self.pending_tx.user_text,
        ctr = self.pending_tx.ctr,
        dst = self.pending_tx.dst, ctr_lo = self.pending_tx.ctr_lo,
        tried = {}, trigger = "hop_budget",
      })
      self:emit("rts_giveup", {
        origin = self.pending_tx.origin,
        payload = self.pending_tx.user_text,
        ctr = self.pending_tx.ctr,
        dst = self.pending_tx.dst,
        next = self.pending_tx.next, ctr_lo = self.pending_tx.ctr_lo,
      })
      self.pending_tx = nil
      become_free(self)
      return
    end

    -- Loop-duplicate NACK. A downstream receiver decoded our DATA but had
    -- already seen the same packet identity via a different previous hop.
    -- Treat the selected next-hop as a dead branch for this flight and
    -- cascade locally instead of accepting the hop as complete.
    if n.reason == NACK_REASON_LOOP_DUP then
      local prev_next = self.pending_tx.next
      self.pending_tx.alts_tried[prev_next] = true
      self:emit("nack_rx", {
        attempt_seq = self.pending_tx.last_rts_attempt_seq,
        origin = self.pending_tx.origin,
        payload = self.pending_tx.user_text,
        ctr = self.pending_tx.ctr,
        from = prev_next,
        ctr_lo = n.ctr_lo,
        reason = "loop_duplicate",
        prior_from = n.prior_from,
      })
      local next_hop = pick_next_cascade_hop(self, self.pending_tx)
      if next_hop ~= nil then
        self:emit("path_cascade", {
          origin = self.pending_tx.origin,
          payload = self.pending_tx.user_text,
          ctr = self.pending_tx.ctr,
          dst = self.pending_tx.dst,
          ctr_lo = self.pending_tx.ctr_lo,
          from_next = prev_next,
          to_next = next_hop,
          attempt = set_size(self.pending_tx.alts_tried),
          trigger = "loop_duplicate",
        })
        self:emit("tx_loop_alt", {
          origin = self.pending_tx.origin,
          payload = self.pending_tx.user_text,
          ctr = self.pending_tx.ctr,
          ctr_lo = self.pending_tx.ctr_lo,
          dst = self.pending_tx.dst,
          from_next = prev_next,
          to_next = next_hop,
        })
        self:log(string.format("tx_loop_alt msg=%d %s -> %s",
          self.pending_tx.ctr_lo, name_of(self, prev_next), name_of(self, next_hop)))
        self.pending_tx.next = next_hop
        self.pending_tx.retries_left = effective_rts_max_retries(self, self.pending_tx.requeue_count)
        tx_rts_retry(self, "loop_duplicate")
        return
      end

      self:emit("path_cascade_exhausted", {
        origin = self.pending_tx.origin,
        payload = self.pending_tx.user_text,
        ctr = self.pending_tx.ctr,
        dst = self.pending_tx.dst,
        ctr_lo = self.pending_tx.ctr_lo,
        tried = {}, trigger = "loop_duplicate",
      })
      self:emit("rts_giveup", {
        origin = self.pending_tx.origin,
        payload = self.pending_tx.user_text,
        ctr = self.pending_tx.ctr,
        dst = self.pending_tx.dst,
        next = prev_next,
        ctr_lo = self.pending_tx.ctr_lo,
      })
      self.pending_tx = nil
      become_free(self)
      return
    end

    -- Legacy busy_rx NACK path (reason 0).
    self:emit("nack_rx", {
      attempt_seq = self.pending_tx.last_rts_attempt_seq,
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
      tx_layer_id     = self.pending_tx.tx_layer_id,
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
    learn_rx_source("data_frame")

    -- §7.6 Phase C: opportunistic rt-learning from the carried
    -- `prev_fwd_rt_hops` claim. Applies to EVERY successful DATA decode
    -- — addressed forwarders AND overhearing neighbors — same pattern
    -- the per-link snr_ewma_in update already uses.
    --
    -- Candidate { next = meta.src, hops = prev_fwd_rt_hops + 1, score
    -- = meta.snr } goes through standard rt_merge, which applies
    -- route_strictly_better with tier penalty (§5.7). No new merge
    -- logic. Bounded by MAX_HOP_LIMIT (8); claims that would yield
    -- hops > 8 are dropped (same guard BCN-merged entries face).
    if self.rt_learn_from_data and meta.src ~= nil and meta.src ~= self.id then
      local carrier = meta.src
      local carrier_claim = d.prev_fwd_rt_hops or 0
      local candidate_hops = carrier_claim + 1
      if carrier_claim > 0 and candidate_hops <= 8 and d.dst ~= self.id then
        local data_route_score_q4 = route_score_from_snr(self, meta_snr_q4)
        local cand = {
          next_hop     = carrier,
          hops         = candidate_hops,
          score        = data_route_score_q4,
          last_seen_ms = self:now(),
          learned_layer_id = self.active_layer_id or self.layer_id,
        }
        local action = rt_merge(self, self.rt, d.dst, cand, self.routing_snr_floor_q4)
        if action == "new" or action == "promote" then
          self:emit("rt_update", {
            dest = d.dst, next = carrier, score = q4_to_db(data_route_score_q4),
            rx_snr = meta.snr,
            route_snr_conservatism_db = q4_to_db(self.route_snr_conservatism_q4 or 0),
            hops = candidate_hops, slot = "primary",
            trigger = "data_rt_learn",
          })
        elseif action == "alt_install" then
          self:emit("rt_update", {
            dest = d.dst, next = carrier, score = q4_to_db(data_route_score_q4),
            rx_snr = meta.snr,
            route_snr_conservatism_db = q4_to_db(self.route_snr_conservatism_q4 or 0),
            hops = candidate_hops, slot = "alt",
            trigger = "data_rt_learn",
          })
        end
      end
    end

    -- ROADMAP §3: M-payload (channel gossip) gets a promiscuous merge
    -- early — EVERY node in radio range adds the message to its own
    -- channel_buffer regardless of `to=`. Overhearers stop here.
    -- Addressed nodes (d.next == self.id) fall through to the normal
    -- DATA path so the hop-level ACK + multi-hop forwarding work
    -- exactly like DM. Forwarders en-route to the pull requester are
    -- thus ALSO carriers of the channel message — every hop benefits
    -- from the gossip propagation.
    if d.payload_type_m then
      local id = d.channel_msg_id
      -- Principle 11: channels are local-by-design. Gateways carry DM
      -- across layers via the envelope handoff, but they do NOT
      -- participate in channel gossip — otherwise an L1 channel
      -- message would land in the gateway's buffer, get advertised in
      -- its next BCN digest (on whichever layer is currently active),
      -- and leak across the boundary. M-frames still get FORWARDED
      -- through the gateway by the normal DATA path below; only the
      -- gossip-participation steps (buffer merge, seen_by tracking,
      -- pending-pull cancellation) are skipped.
      if not self.self_gateway then
        local existing = channel_buffer_find(self, id)
        if existing == nil then
          local entry = {
            id          = id,
            channel_id  = d.channel_id,
            flavor      = d.channel_flavor,
            payload     = d.body,
            received_at = self:now(),
            seen_by     = { [meta.src] = true },
            dirty       = true,
            origin      = d.origin,
          }
          channel_buffer_add(self, entry)
          local source_label
          if d.next == self.id and d.dst == self.id then
            source_label = "pull_target"
          elseif d.next == self.id then
            source_label = "forwarder"
          else
            source_label = "overheard"
          end
          self:emit("channel_msg_received", {
            id = id, channel_id = d.channel_id, flavor = d.channel_flavor,
            source = source_label, from = meta.src,
            buffer_depth = #self.channel_buffer,
          })
          if source_label == "overheard" then
            self:emit("channel_msg_overheard", {
              id = id, channel_id = d.channel_id,
              from = meta.src, intended_to = d.next,
            })
          end
          -- Cancel any pending pull for this id (promiscuous piggyback)
          if self.channel_pull_pending and self.channel_pull_pending[id] then
            self.channel_pull_pending[id] = nil
            self:emit("channel_pull_suppressed", {
              ids = {id}, overheard_from = meta.src,
            })
          end
        else
          -- We already have this msg — the incoming broadcast reached us
          -- but we'd previously seen it (from earlier broadcast, or our
          -- own self_originate). Emit so the analyzer can count "broadcast
          -- reached a node that already had it" = wasted-for-this-node
          -- broadcast (still useful for cascade redundancy, just not new
          -- delivery). Useful for understanding cascade overlap.
          self:emit("channel_msg_already_present", {
            id = id, channel_id = d.channel_id,
            from = meta.src, intended_to = d.next,
          })
          channel_buffer_mark_seen_by(self, id, meta.src)
        end
      end

      -- Mark the per-arm overhear as decoded (if we armed for this
      -- sender/ctr_lo). Used by the retune-back timer to distinguish
      -- successful overhear from a missed one.
      if self.pending_overhear_arms ~= nil then
        local key = (meta.src or 0) * 256 + (d.ctr_lo or 0)
        if self.pending_overhear_arms[key] ~= nil then
          self.pending_overhear_arms[key] = nil
        end
      end

      -- Overhearers (not on the routed path) — done.
      if d.next ~= self.id then return end
      -- Addressed: fall through to normal DATA flow for ACK + multi-hop
      -- forward toward d.dst. If d.dst == self.id we're the pull
      -- requester, the normal path will emit `delivered` (slightly
      -- misleading label for channels but functionally correct).
    end

    if d.next ~= self.id then return end
    if self.pending_rx == nil or d.ctr_lo ~= self.pending_rx.ctr_lo then return end

    -- parse_data already extracted origin, body, ctr, flags from the new
    -- wire format. E2E flag bits are on wire byte 1 (not inner payload).
    local is_e2e_ack  = d.e2e_is_ack
    local e2e_ack_req = d.e2e_ack_req
    local user_text   = d.body         -- body = text for normal DATA, or acked-ctr bytes for E2E ACK
    local rx_gw_env   = parse_gateway_envelope(user_text)
    local rx_hash_bind = parse_hash_bind_response(user_text)
    -- event_payload is what telemetry emits as the human-readable payload.
    -- Strip binary headers: gateway-envelope events show the inner body;
    -- hash-bind responses carry raw key_hash32 bytes (non-UTF-8) so emit a
    -- safe placeholder rather than the binary body.
    local event_payload = rx_gw_env and rx_gw_env.body
                          or (rx_hash_bind and "[hash-bind-response]")
                          or user_text
    mark_dest_seen(self, d.origin, "data_origin")
    mark_dest_seen(self, d.dst, "data_dst")

    local ack_control_sf = active_routing_sf(self)
    local ack_air_ms = airtime_ms(ack_control_sf, self.bw_hz, self.cr,
                                  self.preamble_sym, ACK_LEN)

    self:emit("data_rx", {
      origin     = d.origin,
      payload    = event_payload,
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
	      d.ctr_lo, #d.inner, ack_control_sf))

    -- DATA decoded. Cancel the pending_rx_expiry, retune RX, clear
    -- pending_rx. Then immediately TX the per-hop ACK on routing_sf and
    -- cache the DATA identity so future retried RTS for this same packet
    -- short-circuits via CTS already_received without re-processing DATA.
    local rx_from = self.pending_rx.from
    local rx_chosen_sf = self.pending_rx.chosen_data_sf
    local rx_payload_len = #d.inner + MAC_LEN
    if self.pending_rx_expiry_handle then
      self:cancel(self.pending_rx_expiry_handle)
      self.pending_rx_expiry_handle = nil
    end
	    self:set_rx_sf(ack_control_sf)
    self.pending_rx = nil

    self.last_acked_from[last_acked_key(rx_from, d.dst, d.ctr_lo, rx_payload_len)] = {
      ctr_lo = d.ctr_lo,
      dst = d.dst,
      payload_len = rx_payload_len,
      t_ms = self:now(),
      chosen_data_sf = rx_chosen_sf,
    }

    -- §7.6 Phase B: hop_budget enforcement happens BEFORE the ACK is sent.
    -- If the flight's budget is exhausted at this hop AND we're not the
    -- destination, the upstream needs the NACK feedback (not the ACK).
    -- We must NOT send ACK in this case — otherwise upstream's pending_tx
    -- clears on ACK reception before our NACK arrives, and the rt-learning
    -- side-effect (rt[dst].hops upward) is lost.
    local hb_new_remaining = d.hop_remaining - 1
    local hb_new_committed = math.min(15, d.hop_committed + 1)
    local is_delivered_for_budget_check = (d.dst == self.id)
    if not is_delivered_for_budget_check and hb_new_remaining < 0 then
      self:emit("hop_budget_exceeded", {
        origin = d.origin, payload = event_payload, ctr = d.ctr,
        dst = d.dst, from = rx_from,
        committed = hb_new_committed,
      })
      self:log(string.format(
        "hop_budget_exceeded origin=%s dst=%s ctr=%d committed=%d (NACK, no forward)",
        name_of(self, d.origin), name_of(self, d.dst), d.ctr, hb_new_committed))
      -- Record (origin, dst, ctr) in seen_origins so any later duplicate
      -- arriving at us short-circuits via dup_drop. We DID receive the
      -- frame; we just can't carry it further.
      local seen_key = seen_origin_key(d.origin, d.dst, d.ctr)
      if self.seen_origins[seen_key] ~= nil
         or not table_cap_hit(self, "seen_origins", count_keys(self.seen_origins),
                              self.cap_seen_origins or 0, "refuse",
                              {key = seen_key}) then
        self.seen_origins[seen_key] = self:now() + self.seen_origin_ttl_ms
        self.seen_origin_from[seen_key] = rx_from
      end
      -- NACK back to the upstream so it learns rt[dst] was under-estimating.
      -- Use tx_with_retry (RESPONSE class, same priority as ACK would have
      -- been) so the NACK reaches upstream within its ACK-await window.
      local nack_payload = ((hb_new_committed & 0xf) << 4) | 0
      local nack = pack_nack(d.ctr_lo, NACK_REASON_HOP_BUDGET, nack_payload, rx_from)
      self:emit("nack_tx", {
        origin = d.origin, payload = event_payload, ctr = d.ctr,
        to = rx_from, ctr_lo = d.ctr_lo,
        reason = "hop_budget", committed_hops = hb_new_committed,
      })
      self:log(string.format(
        "nack_tx -> %s reason=hop_budget committed=%d (in lieu of ACK)",
        name_of(self, rx_from), hb_new_committed))
	      tx_with_retry(self, nack, {
	        sf    = ack_control_sf,
	        label = "NACK",
	        info  = string.format("to=%s reason=hop_budget committed=%d",
	          name_of(self, rx_from), hb_new_committed),
	      })
	      self:after(ack_air_ms + 1, function()
	        become_free(self)
	      end)
      return
    end

    -- Origin-level dedup. Duplicates from the same previous hop are normal
    -- lost-ACK recovery and get ACK-only. Duplicates from a different
    -- previous hop mean the packet looped back through the mesh; send a
    -- loop-duplicate NACK so upstream tries a different branch instead of
    -- treating this hop as successful.
    do
      local seen_key = seen_origin_key(d.origin, d.dst, d.ctr)
      local now_ms = self:now()
      local exp = self.seen_origins[seen_key]
      if exp and exp > now_ms then
        local prior_from = self.seen_origin_from[seen_key]
        if prior_from ~= nil and prior_from ~= rx_from then
          local nack = pack_nack(d.ctr_lo, NACK_REASON_LOOP_DUP, prior_from, rx_from)
          self:emit("nack_tx", {
            origin = d.origin, payload = event_payload, ctr = d.ctr,
            dst = d.dst, to = rx_from, ctr_lo = d.ctr_lo,
            reason = "loop_duplicate", prior_from = prior_from,
          })
          self:emit("dup_drop", {
            origin = d.origin, payload = event_payload, ctr = d.ctr,
            dst = d.dst, from = rx_from, prior_from = prior_from,
            ctr_lo = d.ctr_lo, reason = "loop_duplicate",
          })
          self:log(string.format(
            "dup_drop <- %s (origin=%s ctr=%d, prior=%s — NACK loop_duplicate)",
            name_of(self, rx_from), name_of(self, d.origin), d.ctr,
            name_of(self, prior_from)))
	          tx_with_retry(self, nack, {
	            sf    = ack_control_sf,
	            label = "NACK",
	            info  = string.format("to=%s reason=loop_duplicate prior=%s",
	              name_of(self, rx_from), name_of(self, prior_from)),
	          })
	          self:after(ack_air_ms + 1, function()
	            become_free(self)
	          end)
          return
        end
        local my_budget_tier = compute_budget_tier(self)
        local ack_budget_hint = my_budget_tier
        if ack_budget_hint > BUDGET_TIER_CRITICAL then ack_budget_hint = BUDGET_TIER_CRITICAL end
        local ack = pack_ack(d.ctr_lo, meta_snr_q4, ack_budget_hint, rx_from)
        self:emit("ack_tx", {
          origin = d.origin, payload = event_payload, ctr = d.ctr,
          to = rx_from, ctr_lo = d.ctr_lo, data_snr = meta.snr,
          budget_tier = my_budget_tier,
          budget_hint = ack_budget_hint,
          duplicate = true,
        })
	        self:log(string.format("ack_tx -> %s ctr_lo=%d budget_hint=%d duplicate (on routing SF%d)",
	          name_of(self, rx_from), d.ctr_lo, ack_budget_hint, ack_control_sf))
	        tx_with_retry(self, ack, {
	          sf    = ack_control_sf,
	          label = "ACK",
	          info  = string.format("to=%s msg=%d duplicate", name_of(self, rx_from), d.ctr_lo),
	        })
        self:emit("dup_drop", {
          origin = d.origin, payload = event_payload, ctr = d.ctr,
          dst = d.dst, from = rx_from, ctr_lo = d.ctr_lo,
        })
        self:log(string.format(
          "dup_drop <- %s (origin=%s ctr=%d, already seen — ACK only)",
          name_of(self, rx_from), name_of(self, d.origin), d.ctr))
        return
      end
      -- Opportunistic prune of expired entries (cheap; bounded set).
      for k, e in pairs(self.seen_origins) do
        if e <= now_ms then
          self.seen_origins[k] = nil
          self.seen_origin_from[k] = nil
        end
      end
      if self.seen_origins[seen_key] ~= nil
         or not table_cap_hit(self, "seen_origins", count_keys(self.seen_origins),
                              self.cap_seen_origins or 0, "refuse",
                              {key = seen_key}) then
        self.seen_origins[seen_key] = now_ms + self.seen_origin_ttl_ms
        self.seen_origin_from[seen_key] = rx_from
      end
    end

    -- Piggyback our measurement of THIS DATA's SNR into the ACK's 4-bit
    -- bucket. Sender uses it to maintain its outbound link-quality EWMA
    -- to us (which we can't see because we're at the receiving end);
    -- gives the sender a closed-loop signal for routing decisions and
    -- (future) per-neighbor RTS bitmap trimming.
    local my_budget_tier = compute_budget_tier(self)
    local ack_budget_hint = my_budget_tier
    if ack_budget_hint > BUDGET_TIER_CRITICAL then ack_budget_hint = BUDGET_TIER_CRITICAL end
    local ack = pack_ack(d.ctr_lo, meta_snr_q4, ack_budget_hint, rx_from)
    self:emit("ack_tx", {
      origin = d.origin, payload = event_payload, ctr = d.ctr,
      to = rx_from, ctr_lo = d.ctr_lo, data_snr = meta.snr,
      budget_tier = my_budget_tier,
      budget_hint = ack_budget_hint,
    })
	    self:log(string.format("ack_tx -> %s ctr_lo=%d budget_hint=%d (on routing SF%d)",
	      name_of(self, rx_from), d.ctr_lo, ack_budget_hint, ack_control_sf))
	    tx_with_retry(self, ack, {
	      sf    = ack_control_sf,
	      label = "ACK",
	      info  = string.format("to=%s msg=%d", name_of(self, rx_from), d.ctr_lo),
	    })

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
    local d_user_text = event_payload
    local d_committed_at_dst = hb_new_committed   -- §7.6: for E2E ACK actual_hops_used
    local is_delivered = (d.dst == self.id)

    -- §7.6: forward_hop_budget = the decremented values that will travel
    -- with the forwarded frame (next-hop and beyond). Already enforced
    -- above (before ACK send); if we got here, hop_budget is fine.
    local forward_hop_budget = {
      remaining = hb_new_remaining,
      committed = hb_new_committed,
      -- prev_fwd_rt_hops gets re-stamped from self.rt[d_dst] inside issue_send
      -- (the forwarder overwrite per §7.6). Pre-populate with 0; issue_send
      -- replaces it.
      prev_fwd_rt_hops = 0,
    }

    if is_delivered then
      if is_e2e_ack then
        -- This DATA is an end-to-end ACK delivered to us as the original
        -- originator. Body carries [acked_ctr_lo, acked_ctr_hi, actual_hops_used]
        -- (3 bytes per §7.6) — match against pending_e2e, emit
        -- delivered_confirmed, and use actual_hops_used to update
        -- rt[dst].hops with empirical truth. Do NOT emit "delivered"
        -- (not user data). Do NOT trigger another E2E ACK.
        if #d_user_text >= 2 then
          local acked_ctr = d_user_text:byte(1) | (d_user_text:byte(2) << 8)
          local actual_hops = (#d_user_text >= 3) and d_user_text:byte(3) or nil
          local e2e_key = pending_e2e_key(d_origin, acked_ctr)
          local info = self.pending_e2e[e2e_key]
          if info ~= nil then
            self:emit("delivered_confirmed", {
              origin     = self.id,         -- the original originator (us)
              ctr        = acked_ctr,
              dst        = info.dst_id,
              payload    = info.user_text,
              elapsed_ms = self:now() - info.sent_at_ms,
              via_ack_from = d_origin,      -- the destination that ACK'd
              actual_hops_used = actual_hops,
            })
            self:log(string.format(
              "delivered_confirmed acked_ctr=%d dst=%s elapsed=%dms actual_hops=%s (E2E ACK from %s)",
              acked_ctr, info.dst_name, self:now() - info.sent_at_ms,
              tostring(actual_hops), name_of(self, d_origin)))
            self.pending_e2e[e2e_key] = nil
            -- §7.6 Phase D: rt-cost learning from the E2E ACK's actual_hops.
            -- Update self.rt[info.dst_id].hops with empirical truth. If
            -- shorter than current rt: shave the estimate (better route).
            -- If longer: push estimate up (the path was harder than rt thought).
            -- Capped at 8 (rt_merge limit).
            if actual_hops ~= nil and actual_hops > 0 and actual_hops <= 8 then
              local entry = self.rt[info.dst_id]
              if entry and entry.candidates[1] then
                local prim = entry.candidates[1]
                local old_hops = prim.hops
                if old_hops ~= actual_hops then
                  prim.hops = actual_hops
                  self:emit("rt_update", {
                    dest = info.dst_id, next = prim.next_hop,
                    score = prim.score, hops = actual_hops,
                    slot = "primary", trigger = "e2e_ack_actual_hops",
                  })
                  self:log(string.format(
                    "rt[%s].hops %d→%d (e2e_ack actual_hops feedback)",
                    info.dst_name, old_hops, actual_hops))
                end
              end
            end
          else
            -- No matching pending_e2e — either we already received this
            -- ACK (duplicate), already timed out, or never sent the
            -- corresponding e2e. Cheap diagnostic emit for the analyzer.
            self:emit("e2e_ack_unmatched", {
              ctr = acked_ctr, from = d_origin,
              pending_key = e2e_key,
            })
          end
        end
      else
        local gw_env = rx_gw_env
        local gateway_consumed = false
        -- Hash-bind response (PROTOCOL §3.7a): a resolver answered our 'H'
        -- flood. Consume it as a binding update (not user data) and drain
        -- any handoff that was waiting on it.
        if rx_hash_bind ~= nil and self.self_gateway == true then
          gateway_consumed = true
          -- Cache both: the active-layer id_bind (if we're on the target
          -- layer now) and the cross-layer gateway_remote_bind table that
          -- gateway_binding_for_env consults for target != home.
          id_bind_set(self, rx_hash_bind.node_id, rx_hash_bind.key_hash32,
                      "h_query", "claimed")
          gateway_note_remote_binding(self, rx_hash_bind.target_layer_id,
                                      rx_hash_bind.node_id,
                                      rx_hash_bind.key_hash32, "h_query")
          try_drain_gateway_handoffs(self)
          self:emit("q_hash_binding_rx", {
            from = d_origin,
            node = rx_hash_bind.node_id,
            key_hash32 = rx_hash_bind.key_hash32,
            layer_id = rx_hash_bind.target_layer_id,
            source = "h_query",
          })
          self:log(string.format(
            "hash_bind_rx <- %s node=%s key_hash32=%u layer=%d (drain handoffs)",
            name_of(self, d_origin), name_of(self, rx_hash_bind.node_id),
            rx_hash_bind.key_hash32, rx_hash_bind.target_layer_id))
        elseif gw_env ~= nil and self.self_gateway == true then
          gateway_consumed = true
          local target, binding_error = gateway_binding_for_env(self, gw_env)

          if target == nil or not gateway_layer_enabled(self, gw_env.target_layer_id) then
            self:emit("gateway_no_binding", {
              origin = d_origin,
              via_gateway = self.id,
              target_layer_id = gw_env.target_layer_id,
              dst_key_hash32 = gw_env.dst_key_hash32,
              payload = gw_env.body,
              reason = binding_error or "not_found",
            })
            self:log(string.format(
              "gateway_no_binding layer=%d key_hash32=%u reason=%s",
              gw_env.target_layer_id, gw_env.dst_key_hash32,
              binding_error or "not_found"))
            if (binding_error or "not_found") == "not_found"
               and gateway_layer_enabled(self, gw_env.target_layer_id) then
              defer_gateway_handoff(self, gw_env, d_origin, "not_found")
            end
          else
            enqueue_gateway_handoff(self, gw_env, d_origin, target)
          end
          -- Gateway control envelope is consumed by the gateway and is not
          -- emitted as user DATA locally.
        end
        if not gateway_consumed then
          if gw_env ~= nil then
            self:emit("gateway_envelope_at_non_gateway", {
              origin = d_origin,
              dst = self.id,
              target_layer_id = gw_env.target_layer_id,
              dst_key_hash32 = gw_env.dst_key_hash32,
              payload = gw_env.body,
            })
            self:log(string.format(
              "gateway_envelope_at_non_gateway from=%s layer=%d key_hash32=%u -> drop",
              name_of(self, d_origin), gw_env.target_layer_id, gw_env.dst_key_hash32))
          else
            self:emit("delivered", {
              origin = d_origin, payload = d_user_text, ctr = d_ctr,
              dst = self.id,
            })
            self:log(string.format("DELIVERED from %s: %q (ctr=%d%s)",
              name_of(self, d_origin), d_user_text, d_ctr,
              e2e_ack_req and " [E2E-ack requested]" or ""))
            if e2e_ack_req then
          -- Schedule an E2E ACK send back to d_origin. The return flight
          -- carries DATA_FLAG_E2E_IS_ACK on wire byte 1. Body extended
          -- per §7.6:
          --   [acked_ctr_lo(1) acked_ctr_hi(1) actual_hops_used(1)] = 3 bytes
          -- actual_hops_used = hop_budget.committed of the received DATA
          -- (= how many hops the forward DATA actually walked). Originator
          -- uses this to update rt[dst].hops with empirical truth.
          local return_ctr = self:next_ctr(d_origin)
          local return_body = string.char(d_ctr & 0xff)
                            .. string.char((d_ctr >> 8) & 0xff)
                            .. string.char(d_committed_at_dst & 0xff)
          local return_inner = string.char(0)               -- src_addr_len = 0
                             .. string.char(self.id)        -- src_addr
                             .. return_body
          table.insert(self.tx_queue, {
            origin     = self.id,
            dst_id     = d_origin,
            dst_name   = name_of(self, d_origin),
            payload    = return_inner,
            user_text  = string.format("[E2E-ACK ctr=%d hops=%d]",
              d_ctr, d_committed_at_dst),
            ctr        = return_ctr,
            flags      = DATA_FLAG_E2E_IS_ACK,
            enqueue_time_ms = self:now(),
            requeue_count   = 0,
            next_attempt_ms = 0,
          })
          self:emit("e2e_ack_tx_enqueued", {
            origin = self.id, ctr = return_ctr,
            dst = d_origin, acked_ctr = d_ctr,
            actual_hops_used = d_committed_at_dst,
            depth = #self.tx_queue,
          })
          self:log(string.format(
            "e2e_ack_tx_enqueued ctr=%d acked=%d actual_hops=%d dst=%s",
            return_ctr, d_ctr, d_committed_at_dst, name_of(self, d_origin)))
            end
          end
        end
      end
    end

    self:after(self.ack_air_ms + 1, function()
      if is_delivered then
        become_free(self)
        return
      end
      -- 1st-hop priority throttle (ROADMAP §3a). When forwarding a
      -- DATA frame with DATA_FLAG_PRIORITY set, count it against the
      -- direct sender's priority budget (keyed on meta.src, the
      -- physical sender — defeats persona-rotation). Over cap: drop
      -- the forward silently. We've already RX'd + ACK'd the hop, so
      -- the immediate cost is sunk; this saves the next-hop RTS+CTS+
      -- DATA+ACK chain.
      if (d_flags & DATA_FLAG_PRIORITY) ~= 0 then
        local now_p = self:now()
        local ok, current = check_peer_priority_budget(self, d_src, now_p)
        local ctr_lo = d_ctr & 0xf
        if not ok then
          self:emit("rts_drop_originator_priority_throttle", {
            from = d_src, ctr_lo = ctr_lo,
            apparent_origination = current,
            window_ms = self.originator_priority_window_ms,
            cap = self.originator_priority_max_per_window,
          })
          self:log(string.format(
            "rts_drop_originator_priority_throttle: from=%s ctr_lo=%d count=%d cap=%d window=%dms — forward dropped",
            name_of(self, d_src), ctr_lo, current,
            self.originator_priority_max_per_window,
            self.originator_priority_window_ms))
          become_free(self)
          return
        end
        record_peer_priority_observation(self, d_src, now_p)
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
          -- §7.6: carry the post-decrement hop budget so the eventual
          -- issue_send (via become_free) has the right state to put on
          -- the outgoing wire.
          forward_hop_budget = forward_hop_budget,
        })
        self:emit("forward_queued", {
          origin = d_origin, payload = d_user_text, ctr = d_ctr,
          dst = d_dst, depth = #self.tx_queue,
        })
        return
      end
      issue_send(self, d_origin, d_dst, dst_name,
                 d_inner, d_user_text, d_ctr, d_flags, d_src, nil, forward_hop_budget)
    end)
    return
  end

  if tag == "H" then
    -- Multi-hop hash-locate flood (PROTOCOL §3.7a). The one forwardable
    -- control frame: a node that knows the hash replies via routed DATA
    -- to the querying gateway; a node that doesn't decrements TTL and
    -- rebroadcasts once (deduped on (origin, key_hash32)).
    local h = parse_h_query(frame)
    if not h then return end
    if h.leaf_id ~= active_leaf_id(self) then return end   -- foreign-layer
    learn_rx_source("h_frame")
    if h.origin == self.id then return end                  -- our own query
    self:emit("h_rx", {
      origin = h.origin, key_hash32 = h.key_hash32, ttl = h.ttl,
    })
    local matches_self = (self.key_hash32 ~= nil and h.key_hash32 == self.key_hash32)
    local node_id = matches_self and self.id
                    or id_bind_find_by_hash(self, h.key_hash32)
    if node_id ~= nil then
      -- Resolver: answer via routed unicast DATA to the gateway (h.origin)
      -- and suppress our own forward of this query.
      mark_hash_query_seen(self, h.origin, h.key_hash32)
      local target_layer = self.active_layer_id or self.layer_id
      self:emit("h_resolved", {
        origin = h.origin, key_hash32 = h.key_hash32,
        node = node_id, target_layer_id = target_layer,
      })
      send_hash_bind_response(self, h.origin, target_layer, node_id, h.key_hash32)
      return
    end
    if hash_query_seen_recently(self, h.origin, h.key_hash32) then return end
    mark_hash_query_seen(self, h.origin, h.key_hash32)
    if (h.ttl or 0) <= 0 then return end                    -- TTL exhausted
    local fwd = pack_h_query(h.origin, active_leaf_id(self),
                             h.key_hash32, h.ttl - 1)
    self:emit("h_forward", {
      origin = h.origin, key_hash32 = h.key_hash32, ttl = h.ttl - 1,
    })
    tx_initiating(self, fwd, {
      sf    = active_routing_sf(self),
      label = "H",
      info  = string.format("origin=%s hash32=%u ttl=%d forward",
                            name_of(self, h.origin), h.key_hash32, h.ttl - 1),
    })
    return
  end

  if tag == "F" then
    -- Multi-hop route discovery ('F' route-Find frame, PROTOCOL §3.7b). Reuses
    -- the 'H' flood/dedup machinery, but the reply CANNOT be opaque like 'H' (whose
    -- RREP is a routed DATA to a known-reachable gateway): here the dst is
    -- exactly the node nobody has a route to. So the RREQ flood lays a
    -- REVERSE path (toward origin) at every forwarder, and the RREP walks
    -- that reverse path one hop at a time, laying the FORWARD path (toward
    -- dst) as it goes.
    local r = parse_r(frame)
    if not r then return end
    if r.leaf_id ~= active_leaf_id(self) then return end    -- foreign-layer
    learn_rx_source("r_frame")

    if not r.is_reply then
      -- ===== RREQ =====
      if r.origin == self.id then return end                -- our own flood
      self:emit("rreq_rx", {
        origin = r.origin, dst = r.dst_id, ttl = r.b4, hops = r.hops,
      })
      -- Reverse path: we can reach origin via whoever just forwarded to us.
      local rev_hops = (r.hops or 0) + 1
      rt_merge(self, self.rt, r.origin, {
        next_hop         = meta.src,
        score            = route_score_from_snr(self, meta_snr_q4),
        hops             = rev_hops,
        is_gateway       = false,
        last_seen_ms     = self:now(),
        learned_layer_id = self.active_layer_id or self.layer_id,
      }, self.routing_snr_floor_q4)
      -- Are we the destination? Reply (hops-to-dst = 0 from our vantage).
      if r.dst_id == self.id then
        mark_route_request_seen(self, r.origin, r.dst_id)
        self:emit("rreq_resolved_self", { origin = r.origin })
        send_route_reply(self, r.origin, self.id, 0)
        return
      end
      -- Intermediate-node reply (AODV-style): if we already have a route to
      -- dst, answer on its behalf with our hop-count instead of re-flooding.
      local de = self.rt[r.dst_id]
      local dcand = de and de.candidates and de.candidates[1]
      if dcand ~= nil then
        mark_route_request_seen(self, r.origin, r.dst_id)
        self:emit("rreq_resolved_cached", {
          origin = r.origin, dst = r.dst_id, hops = dcand.hops,
        })
        send_route_reply(self, r.origin, r.dst_id, dcand.hops or 1)
        return
      end
      -- Dedup the flood (AFTER reverse-path learning, so every copy still
      -- refreshes the reverse route even when we don't re-forward).
      if route_request_seen_recently(self, r.origin, r.dst_id) then return end
      mark_route_request_seen(self, r.origin, r.dst_id)
      if (r.b4 or 0) <= 0 then return end                   -- TTL exhausted
      local fwd = pack_r_request(r.origin, active_leaf_id(self),
                                 r.dst_id, r.b4 - 1, rev_hops)
      self:emit("rreq_forward", {
        origin = r.origin, dst = r.dst_id, ttl = r.b4 - 1, hops = rev_hops,
      })
      tx_initiating(self, fwd, {
        sf    = active_routing_sf(self),
        label = "F",
        info  = string.format("rreq origin=%s dst=%s ttl=%d forward",
                              name_of(self, r.origin), name_of(self, r.dst_id), r.b4 - 1),
      })
      return
    end

    -- ===== RREP =====
    -- Addressed forward: only the named next_hop (byte 4) acts on it.
    if r.b4 ~= self.id then return end
    self:emit("rrep_rx", { origin = r.origin, dst = r.dst_id, hops = r.hops })
    -- Forward path: we reach dst via whoever just forwarded the RREP to us.
    local fwd_hops = (r.hops or 0) + 1
    rt_merge(self, self.rt, r.dst_id, {
      next_hop         = meta.src,
      score            = route_score_from_snr(self, meta_snr_q4),
      hops             = fwd_hops,
      is_gateway       = false,
      last_seen_ms     = self:now(),
      learned_layer_id = self.active_layer_id or self.layer_id,
    }, self.routing_snr_floor_q4)
    if r.origin == self.id then
      -- We originated the query. Forward route is installed; the deferred
      -- send drains on the next route-check tick.
      self:emit("rrep_arrived", { dst = r.dst_id, hops = fwd_hops })
      self:log(string.format("rrep_arrived dst=%s hops=%d — forward route installed",
        name_of(self, r.dst_id), fwd_hops))
      return
    end
    -- Relay onward toward origin along the reverse path the RREQ laid.
    send_route_reply(self, r.origin, r.dst_id, fwd_hops)
    return
  end

  if tag == "Q" then
    local q = parse_q(frame)
    if not q then return end
    -- Cross-network filter — drop foreign Q before any work.
    if q.leaf_id ~= active_leaf_id(self) then return end
    learn_rx_source("q_frame")
    -- Don't respond to ourselves (loop guard).
    if q.src == self.id then return end
    -- Dedup: if we recently responded to the same query, skip.
    -- The originator's defer queue still has timer-based retry; if our
    -- response was lost, the next Q-firing window will re-enable us.
    local key = string.format("%d|%d|%d|%u",
                              q.opcode or 0, q.src or 0, q.dest or 0,
                              q.key_hash32 or 0)
    local last = self.q_responded_to[key]
    local now = self:now()
    if last and (now - last) < self.q_respond_ttl_ms then return end
    if last == nil
       and table_cap_hit(self, "q_responded_to", count_keys(self.q_responded_to),
                         self.cap_q_responded_to or 0, "refuse", {key = key}) then
      return
    end
    self.q_responded_to[key] = now

    self:emit("q_rx", {
      from = q.src,
      dest = q.dest,
      opcode = q.opcode,
      key_hash32 = q.key_hash32,
      requester_mobile = q.requester_is_mobile == true,
    })

    if q.opcode == Q_OP_REQ_SYNC then
      schedule_sync_response(self, q, meta)
      self:log(string.format(
        "q_rx <- %s opcode=REQ_SYNC requester_mobile=%s",
        name_of(self, q.src), tostring(q.requester_is_mobile == true)))
      return
    end

    -- (HASH_QUERY removed from Q; see the 'H' flood frame handler below.)

    -- ROADMAP §3: channel-pull request. Q_CHANNEL_PULL is unicast
    -- (dest = specific target the requester wants to pull from).
    -- Non-target nodes that decoded the frame must silently ignore the
    -- request itself (don't answer on someone else's behalf). They
    -- DO get one useful signal from it though: a peer is already
    -- pulling these IDs from somewhere, so any pending pull I had
    -- queued for the same ID is now redundant — I'll get the M-payload
    -- via promiscuous overhear of the response, or pick it up from
    -- the eventual digest cycle. Cancel my pending pulls BEFORE the
    -- not-for-me short-circuit; this is the cheapest pull-storm
    -- dedupe path because it fires at the very start of the burst,
    -- before most peer jitters have expired.
    if q.opcode == Q_OP_CHANNEL_PULL then
      if self.channel_pull_pending and q.channel_ids then
        local cancelled = {}
        for _, id in ipairs(q.channel_ids) do
          if self.channel_pull_pending[id] then
            self.channel_pull_pending[id] = nil
            table.insert(cancelled, id)
          end
        end
        if #cancelled > 0 then
          self:emit("channel_pull_suppressed", {
            ids = cancelled, overheard_from = "peer_q", peer = q.src,
          })
        end
      end
      if q.dest ~= self.id then return end
      local have_ids = {}
      local missing_ids = {}
      for _, id in ipairs(q.channel_ids or {}) do
        local entry = channel_buffer_find(self, id)
        if entry ~= nil then
          table.insert(have_ids, id)
          -- Dedup: if we already have an M-payload tx in-flight (pending_tx)
          -- OR queued (tx_queue) for this same id, skip enqueueing another.
          -- The existing broadcast will satisfy this requester (it'll
          -- decode the DATA on chosen_data_sf along with everyone else
          -- in radio range). Saves the 6-7× per-msg broadcast amplification
          -- we observed on s12 6h. Still mark seen_by — we know this
          -- requester pulled, so they expect to get the msg via overhear.
          local existing_in_flight = false
          if self.pending_tx ~= nil
             and ((self.pending_tx.flags or 0) & DATA_FLAG_PAYLOAD_TYPE_M) ~= 0
             and self.pending_tx.payload
             and #self.pending_tx.payload >= 4
             and channel_msg_id_from_bytes(self.pending_tx.payload, 1) == id then
            existing_in_flight = true
          end
          if not existing_in_flight then
            for _, tq in ipairs(self.tx_queue) do
              if ((tq.flags or 0) & DATA_FLAG_PAYLOAD_TYPE_M) ~= 0
                 and tq.payload and #tq.payload >= 4
                 and channel_msg_id_from_bytes(tq.payload, 1) == id then
                existing_in_flight = true
                break
              end
            end
          end
          if existing_in_flight then
            if debug_emit_allowed(self) then
              self:emit("channel_broadcast_deduped", {
                id = id, requester = q.src,
              })
            end
          else
            -- Build M-payload-type DATA frame body. Inner layout is:
            --   id(4B) | channel_id(1B) | flavor(1B) | body(N) | mac(4B placeholder)
            local m_inner = channel_msg_id_to_bytes(id)
                          .. string.char(entry.channel_id & 0xff)
                          .. string.char(entry.flavor & 0xff)
                          .. (entry.payload or "")
            local return_ctr = self:next_ctr(q.src)
            table.insert(self.tx_queue, {
              origin       = self.id,
              dst_id       = q.src,
              dst_name     = name_of(self, q.src),
              payload      = m_inner,
              user_text    = string.format("[CH_M ch=%d id=0x%08x]",
                                            entry.channel_id, id),
              ctr          = return_ctr,
              flags        = DATA_FLAG_PAYLOAD_TYPE_M,
              enqueue_time_ms = self:now(),
              requeue_count   = 0,
              next_attempt_ms = 0,
            })
          end
          -- Mark requester as having received it (will be confirmed once
          -- the M-frame is ACK'd, but we record optimistically). Done
          -- regardless of whether we enqueued — the existing broadcast
          -- (if dedup fired) is for the same id.
          channel_buffer_mark_seen_by(self, id, q.src)
        else
          table.insert(missing_ids, id)
        end
      end
      self:emit("channel_pull_received", {
        from = q.src,
        ids = q.channel_ids or {},
      })
      if #have_ids > 0 then
        self:emit("channel_msg_pulled", {
          to = q.src, ids = have_ids, missing = missing_ids,
        })
        self:log(string.format(
          "channel_pull_received from=%s n_requested=%d n_have=%d n_missing=%d",
          name_of(self, q.src), #(q.channel_ids or {}), #have_ids, #missing_ids))
        become_free(self)
      end
      return
    end

    -- REQ_SYNC and CHANNEL_PULL are handled above; ROUTE_QUERY (opcode 0) was
    -- retired in favour of the 'R' RREQ/RREP flood (PROTOCOL §3.7b). Anything
    -- reaching here is an unrecognised opcode — stay silent.
    self:log(string.format(
      "q_rx <- %s unknown opcode=%d; silent",
      name_of(self, q.src), q.opcode))
    return
  end
end

-- on_command "send <dst_name> <text>": enqueue a user-originated send into
-- the TX queue and try to drain immediately. Even if we're busy now (mid-RX,
-- mid-TX, or queued forwards ahead), the queue ensures the message will fire
-- as soon as we're free — no more "ERROR: busy" rejection.
function on_command(self, cmd_str)
  local j_kind, j_arg1, j_arg2 = cmd_str:match("^join_test%s+(%S+)%s*(%S*)%s*(%S*)$")
  if j_kind then
    local key_hash32 = self.key_hash32 or 0
    local is_mobile = self.is_mobile == true
    local is_gateway = self.self_gateway == true
    local frame = nil
    local info = nil
    local tx_leaf_id = active_leaf_id(self)
    local tx_routing_sf = active_routing_sf(self)

    if j_kind == "discover" then
      frame = pack_j_discover(tx_leaf_id, key_hash32, is_mobile, is_gateway)
      self:emit("join_discover_sent", {
        key_hash32 = key_hash32,
        requester_mobile = is_mobile,
        gateway_capable = is_gateway,
        tx_layer_id = self.active_layer_id or self.layer_id,
        tx_leaf_id = tx_leaf_id,
        tx_routing_sf = tx_routing_sf,
      })
      info = "op=discover"
    elseif j_kind == "claim" then
      local proposed = tonumber(j_arg1 or "")
      if proposed == nil or proposed < 0 or proposed > 254 then
        return "ERROR: usage: join_test claim <node_id>"
      end
      self.join_claim_epoch = ((self.join_claim_epoch or 0) + 1) & 0xff
      nv_set(self, "claim_epoch", self.join_claim_epoch)
      local nonce = self:rand(0, 256)
      local lease_age = lease_age_seconds_now(self)
      frame = pack_j_claim(tx_leaf_id, key_hash32, proposed, lease_age,
                           self.join_claim_epoch, nonce, is_mobile, is_gateway)
      self:emit("join_claim_sent", {
        proposed_node_id = proposed,
        key_hash32 = key_hash32,
        lease_age_seconds = lease_age,
        claim_epoch = self.join_claim_epoch,
        nonce = nonce,
        requester_mobile = is_mobile,
        gateway_capable = is_gateway,
        tx_layer_id = self.active_layer_id or self.layer_id,
        tx_leaf_id = tx_leaf_id,
        tx_routing_sf = tx_routing_sf,
      })
      info = string.format("op=claim node=%d", proposed)
    elseif j_kind == "deny" then
      local denied = tonumber(j_arg1 or "")
      local claimant_hash = tonumber(j_arg2 or "")
      if denied == nil or denied < 0 or denied > 254 or claimant_hash == nil then
        return "ERROR: usage: join_test deny <denied_node_id> <claimant_key_hash32>"
      end
      self.join_claim_epoch = (self.join_claim_epoch or 0) & 0xff
      local owner_lease_age = lease_age_seconds_now(self)
      frame = pack_j_deny(tx_leaf_id, denied, key_hash32, claimant_hash,
                          owner_lease_age, self.join_claim_epoch, J_DENY_REASON_CONFLICT,
                          is_mobile, is_gateway)
      self:emit("join_deny_sent", {
        denied_node_id = denied,
        owner_key_hash32 = key_hash32,
        claimant_key_hash32 = claimant_hash,
        owner_lease_age_seconds = owner_lease_age,
        owner_claim_epoch = self.join_claim_epoch,
        reason = J_DENY_REASON_CONFLICT,
        requester_mobile = is_mobile,
        gateway_capable = is_gateway,
        tx_layer_id = self.active_layer_id or self.layer_id,
        tx_leaf_id = tx_leaf_id,
        tx_routing_sf = tx_routing_sf,
      })
      info = string.format("op=deny node=%d", denied)
    else
      return "ERROR: usage: join_test discover|claim|deny"
    end

    tx_initiating(self, frame, {
      sf = tx_routing_sf,
      label = "J",
      info = info,
    })
    return "OK: join_test " .. j_kind
  end

  -- Two send variants:
  --   send     <dst> <text>   — best-effort, no end-to-end confirmation
  --   send_e2e <dst> <text>   — request end-to-end ACK from destination;
  --                              originator gets delivered_confirmed or
  --                              e2e_ack_timeout. See E2E ACK design block
  --                              in the header — wire format is the same,
  --                              just one bit set in the payload header.
  local want_e2e = false
  local target_layer_s, target_hash_s, gateway_text =
    cmd_str:match("^send_layer (%S+) (%S+) (.+)$")
  if target_layer_s then
    local target_layer_id = tonumber(target_layer_s)
    local dst_key_hash32 = tonumber(target_hash_s)
    if target_layer_id == nil or dst_key_hash32 == nil then
      return "ERROR: usage: send_layer <layer_id> <dst_key_hash32> <text>"
    end

    local dst_id = nil
    local dst_name = nil
    local wire_body = gateway_text
    if target_layer_id == (self.layer_id or 0) then
      dst_id = id_bind_find_by_hash(self, dst_key_hash32)
      if dst_id == nil then
        return string.format("ERROR: no local binding for key_hash32=%u", dst_key_hash32)
      end
      dst_name = name_of(self, dst_id)
    else
      dst_id = select_gateway_for_layer(self, target_layer_id)
      if dst_id == nil then
        -- Silent-failure no more: this send produces no envelope and no DATA.
        -- reason distinguishes a true gap (no gateway advertised for the layer)
        -- from the route-convergence case (gateway known via TLV but no rt
        -- route to it -- typically its route aged out during a visit absence).
        self:emit("gateway_envelope_dropped", {
          origin = self.id,
          target_layer_id = target_layer_id,
          dst_key_hash32 = dst_key_hash32,
          reason = knows_gateway_for_layer(self, target_layer_id)
                   and "gateway_known_no_route" or "no_gateway_known",
        })
        return string.format("ERROR: no gateway route for layer=%d", target_layer_id)
      end
      dst_name = name_of(self, dst_id)
      wire_body = pack_gateway_envelope(target_layer_id, dst_key_hash32, gateway_text)
      self:emit("gateway_envelope_enqueued", {
        origin = self.id,
        gateway = dst_id,
        target_layer_id = target_layer_id,
        dst_key_hash32 = dst_key_hash32,
        payload = gateway_text,
      })
    end

    if #wire_body > self.max_payload_bytes then
      self:emit("send_oversized", {
        dst = dst_id, dst_name = dst_name, len = #wire_body,
        max = self.max_payload_bytes,
        target_layer_id = target_layer_id, dst_key_hash32 = dst_key_hash32,
        envelope_overhead = (target_layer_id ~= (self.layer_id or 0)) and (#wire_body - #gateway_text) or 0,
      })
      return string.format("ERROR: payload too large (%d > max %d bytes, includes %d envelope overhead)",
                           #wire_body, self.max_payload_bytes,
                           (target_layer_id ~= (self.layer_id or 0)) and (#wire_body - #gateway_text) or 0)
    end
    local ctr = self:next_ctr(dst_id)
    local inner = string.char(0) .. string.char(self.id) .. wire_body
    table.insert(self.tx_queue, {
      origin     = self.id,
      dst_id     = dst_id,
      dst_name   = dst_name,
      payload    = inner,
      user_text  = gateway_text,
      ctr        = ctr,
      flags      = 0,
      enqueue_time_ms = self:now(),
      requeue_count   = 0,
      next_attempt_ms = 0,
    })
    self:emit("tx_enqueue", {
      origin = self.id, payload = gateway_text, ctr = ctr,
      dst = dst_id, depth = #self.tx_queue,
      target_layer_id = target_layer_id,
      dst_key_hash32 = dst_key_hash32,
      via_gateway = (target_layer_id ~= (self.layer_id or 0)),
    })
    self:log(string.format(
      "send_layer: queued layer=%d key_hash32=%u via=%s payload=%q ctr=%d",
      target_layer_id, dst_key_hash32, dst_name, gateway_text, ctr))
    become_free(self)
    return string.format("queued gateway-send (depth=%d, ctr=%d)",
      #self.tx_queue, ctr)
  end

  -- ROADMAP §3 channel send: send_channel <channel_id> <text>
  -- Originator adds entry to channel_buffer with dirty=true; next BCN
  -- advertises the ID via channel_digest_ext; neighbours pull on demand.
  local ch_id_s, ch_text = cmd_str:match("^send_channel (%S+) (.+)$")
  if ch_id_s then
    local ch_id = tonumber(ch_id_s)
    if ch_id == nil or ch_id < 0 or ch_id > 255 then
      return "ERROR: usage: send_channel <channel_id 0-255> <text>"
    end
    if #ch_text > (self.channel_msg_max_payload_bytes or 200) then
      self:emit("channel_send_oversized", {
        channel_id = ch_id, len = #ch_text,
        max = self.channel_msg_max_payload_bytes,
      })
      return string.format("ERROR: channel payload too large (%d > max %d bytes)",
                           #ch_text, self.channel_msg_max_payload_bytes)
    end
    -- Build entry. Use our own next_ctr against ourselves as the
    -- per-origin ctr (cheap unique counter); only the low 8 bits go
    -- into the ID, so reuse after 256 messages on the same channel
    -- is collision-resolvable via received_at deduplication.
    local local_ctr = self:next_ctr(self.id)
    local id = channel_msg_id(self.id, self.key_hash32 or 0, local_ctr)
    -- Public flavor for v1 — group/private crypto comes later.
    local entry = {
      id           = id,
      channel_id   = ch_id,
      flavor       = CHANNEL_FLAVOR_PUBLIC,
      payload      = ch_text,
      received_at  = self:now(),
      seen_by      = {},
      dirty        = true,
      origin       = self.id,
    }
    local added, evicted = channel_buffer_add(self, entry)
    self:emit("channel_msg_received", {
      id = id, channel_id = ch_id, flavor = CHANNEL_FLAVOR_PUBLIC,
      source = "self_originate",
      payload = ch_text,
      buffer_depth = #self.channel_buffer,
    })
    self:log(string.format("send_channel: ch=%d id=0x%08x payload=%q (buffer=%d)",
      ch_id, id, ch_text, #self.channel_buffer))
    return string.format("channel msg queued (ch=%d, id=0x%08x, buffer=%d)",
                         ch_id, id, #self.channel_buffer)
  end

  -- Priority variants tried first (most specific match wins):
  --   send_e2e_priority <dst> <text>  → priority + E2E ACK
  --   send_priority     <dst> <text>  → priority, best-effort
  --   send_e2e          <dst> <text>  → E2E ACK
  --   send              <dst> <text>  → best-effort
  local want_priority = false
  local dst_name, text = cmd_str:match("^send_e2e_priority (%S+) (.+)$")
  if dst_name then
    want_e2e, want_priority = true, true
  else
    dst_name, text = cmd_str:match("^send_priority (%S+) (.+)$")
    if dst_name then
      want_priority = true
    else
      dst_name, text = cmd_str:match("^send_e2e (%S+) (.+)$")
      if dst_name then
        want_e2e = true
      else
        dst_name, text = cmd_str:match("^send (%S+) (.+)$")
      end
    end
  end
  if not dst_name then
    return "ERROR: usage: send|send_priority|send_e2e|send_e2e_priority <dst_name> <text>"
  end
  local dst_id = self.name_to_id[dst_name]
  if dst_id == nil then return "ERROR: unknown dst: " .. dst_name end
  if #text > self.max_payload_bytes then
    self:emit("send_oversized", {
      dst = dst_id, dst_name = dst_name, len = #text,
      max = self.max_payload_bytes, e2e = want_e2e, priority = want_priority,
    })
    return string.format("ERROR: payload too large (%d > max %d bytes)",
                         #text, self.max_payload_bytes)
  end
  -- Priority self-cap (ROADMAP §3a). Originator drops own priority sends
  -- silently once over `originator_priority_max_per_window`. Cap applies
  -- BEFORE counter allocation so a capped send doesn't burn a ctr slot
  -- or pending_e2e entry.
  if want_priority then
    local now = self:now()
    local ok, current_count = check_priority_budget(self, now)
    if not ok then
      self:emit("priority_send_capped", {
        dst = dst_id, dst_name = dst_name,
        window_ms = self.originator_priority_window_ms,
        cap = self.originator_priority_max_per_window,
        current_count = current_count,
      })
      self:log(string.format(
        "priority_send_capped dst=%s (count %d ≥ cap %d in last %dms)",
        dst_name, current_count, self.originator_priority_max_per_window,
        self.originator_priority_window_ms))
      return string.format("ERROR: priority cap reached (%d/%d in last %dms)",
                           current_count, self.originator_priority_max_per_window,
                           self.originator_priority_window_ms)
    end
    record_priority_origination(self, now)
  end
  -- Stamp this user-message with a per-(self,dst) 16-bit outbound counter.
  -- The pair (origin_id, ctr) is the globally-unique e2e message id used
  -- by every receiving node for dedup. Replaces the old flat next_origin_seq.
  local ctr = self:next_ctr(dst_id)
  local wire_flags = 0
  if want_e2e      then wire_flags = wire_flags | DATA_FLAG_E2E_ACK_REQ end
  if want_priority then wire_flags = wire_flags | DATA_FLAG_PRIORITY    end
  -- inner = src_addr_len(1) | src_addr(1) | body
  local inner = string.char(0) .. string.char(self.id) .. text
  if want_e2e then
    -- Register pending_e2e BEFORE enqueueing the send so a fast E2E ACK
    -- (e.g. test scenario with 1-hop path) doesn't arrive before the
    -- bookkeeping is in place.
    local e2e_key = pending_e2e_key(dst_id, ctr)
    self.pending_e2e[e2e_key] = {
      sent_at_ms = self:now(),
      ctr        = ctr,
      dst_id     = dst_id,
      dst_name   = dst_name,
      user_text  = text,
    }
    self:emit("e2e_ack_pending", {
      origin = self.id, ctr = ctr, dst = dst_id,
      ttl_ms = self.e2e_ack_ttl_ms,
    })
    self:log(string.format("send_e2e: pending_e2e[%s] dst=%s ctr=%d ttl=%dms",
      e2e_key, dst_name, ctr, self.e2e_ack_ttl_ms))
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
    priority = want_priority,
  })
  self:log(string.format("send: queued dst=%s payload=%q ctr=%d e2e=%s priority=%s (queue depth=%d)",
    dst_name, text, ctr, tostring(want_e2e), tostring(want_priority), #self.tx_queue))
  become_free(self)
  return string.format("queued (depth=%d, ctr=%d, e2e=%s, priority=%s)",
    #self.tx_queue, ctr, tostring(want_e2e), tostring(want_priority))
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

  if (info.label == "RTS" or info.label == "RTS-fwd" or info.label == "RTS-rty")
     and self.pending_tx ~= nil then
    self.pending_tx.awaiting_cts = false
    self:emit("rts_tx_blocked", {
      attempt_seq = self.pending_tx.last_rts_attempt_seq,
      origin = self.pending_tx.origin,
      dst = self.pending_tx.dst,
      next = self.pending_tx.next,
      ctr = self.pending_tx.ctr,
      ctr_lo = self.pending_tx.ctr_lo,
      payload = self.pending_tx.user_text,
      label = info.label,
      reason = info.reason,
      busy_until_ms = info.busy_until_ms,
      tx_layer_id = self.pending_tx.tx_layer_id,
      tx_leaf_id = self.pending_tx.tx_leaf_id,
      tx_routing_sf = self.pending_tx.tx_routing_sf or active_routing_sf(self),
    })
  end

  if info.label == "DATA" and self.pending_tx ~= nil then
    self.pending_tx.awaiting_ack = false
    if self.ack_timeout_handle then
      self:cancel(self.ack_timeout_handle)
      self.ack_timeout_handle = nil
    end
    self:emit("data_tx_blocked", {
      attempt_seq = self.pending_tx.last_rts_attempt_seq,
      origin = self.pending_tx.origin,
      dst = self.pending_tx.dst,
      next = self.pending_tx.next,
      ctr = self.pending_tx.ctr,
      ctr_lo = self.pending_tx.ctr_lo,
      payload = self.pending_tx.user_text,
      label = info.label,
      reason = info.reason,
      busy_until_ms = info.busy_until_ms,
      tx_layer_id = self.pending_tx.tx_layer_id,
      tx_leaf_id = self.pending_tx.tx_leaf_id,
      tx_routing_sf = self.pending_tx.tx_routing_sf or active_routing_sf(self),
    })
  end

  -- M-broadcast (DATA-M) has its own retry path: re-emit the full
  -- RTS+DATA-M sequence so receivers re-arm their overhear-arm
  -- windows from the fresh RTS. The standard stash retry would only
  -- re-fire DATA-M, which arrives after the original RTS's guard
  -- already expired.
  if info.label == "DATA-M" and self.pending_tx ~= nil
     and self.pending_tx.m_broadcast == true then
    local px = self.pending_tx
    local max_retries = self.channel_broadcast_max_retries or 3
    px.m_broadcast_retries_used = (px.m_broadcast_retries_used or 0) + 1
    if px.m_broadcast_retries_used > max_retries then
      self:emit("tx_giveup", {
        label = "DATA-M", reason = info.reason,
        origin = px.origin, dst = px.dst, ctr = px.ctr,
        retries_used = px.m_broadcast_retries_used,
      })
      self:log(string.format(
        "tx_giveup DATA-M reason=%s (m-broadcast retries exhausted: %d > %d)",
        info.reason, px.m_broadcast_retries_used, max_retries))
      self.pending_tx = nil
      become_free(self)
      return
    end
    local now = self:now()
    local wait_ms = (info.busy_until_ms or now) - now
    if wait_ms < 0 then wait_ms = 0 end
    local delay = wait_ms + 2 + self:rand(0, self.lbt_backoff_ms + 1)
    self:emit("m_broadcast_retry_scheduled", {
      origin = px.origin, dst = px.dst, ctr = px.ctr,
      delay_ms = delay,
      retries_used = px.m_broadcast_retries_used,
      max_retries = max_retries,
      reason = info.reason,
    })
    self:log(string.format(
      "m_broadcast_retry %s reason=%s busy_until=%d -> retry in %dms (used=%d/%d)",
      info.label, info.reason, info.busy_until_ms, delay,
      px.m_broadcast_retries_used, max_retries))
    self:after(delay, function()
      -- Bail if pending_tx changed (e.g. another flow cleared it).
      if self.pending_tx == nil
         or self.pending_tx.ctr_lo ~= px.ctr_lo
         or self.pending_tx.m_broadcast ~= true then
        return
      end
      fire_m_broadcast_rts(self, self.pending_tx)
    end)
    return
  end

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

  local now = self:now()
  local wait_ms = (info.busy_until_ms or now) - now
  if wait_ms < 0 then wait_ms = 0 end
  -- Runtime busy_until is the end of the currently-observed flight. Retrying
  -- at or before that exact timestamp can consume all stash retries before the
  -- channel is usable, so add a small guard plus jitter.
  local guard_ms = 2
  local delay = wait_ms + guard_ms + self:rand(0, self.lbt_backoff_ms + 1)
  self:log(string.format(
    "radio_busy %s reason=%s busy_until=%d -> retry in %dms (retries_left=%d)",
    info.label, info.reason, info.busy_until_ms, delay, stash.retries_left))
  self:after(delay, function()
    self:tx(stash.bytes, stash.opts)
    if stash.opts and stash.opts.on_handed then stash.opts.on_handed() end
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
