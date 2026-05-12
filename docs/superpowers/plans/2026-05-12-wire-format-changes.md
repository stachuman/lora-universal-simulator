# Wire-Format Changes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Roll the locked §7.0 wire-format changes (renames, NACK shrink, BCN re-pack, DATA re-pack with crypto/MAC placeholders, RTS re-pack with origin removal) into `scenarios/dv_dual_sf.lua` and supporting docs, keeping all 38 JSON integration scenarios + 36 webapp pytests green.

**Architecture:** Five sequential phases, each producing working software with no test regression. Phase 1 (renames) is mechanical. Phases 2-3 (NACK, BCN) are independent. Phase 4 (DATA) carries crypto/MAC placeholder bytes and re-keys flight dedup from `(origin, origin_seq)` to `(ctr, dst)`. Phase 5 (RTS) drops `origin` from wire — requires phase 4 to land first because origin moves into DATA's inner payload. Hierarchy support (`addr_len > 0`) is **OUT OF SCOPE** for this plan; reserved bits stay zero throughout.

**Spec:** `docs/ROADMAP.md` §7.0 (locked 2026-05-12).

**Tech Stack:** Lua 5.4 (sandboxed in C++ orchestrator), C++ orchestrator runtime, bash test harness, JSON test scenarios, pytest for webapp.

---

## Reference: locked layouts (mirror of ROADMAP §7.0)

### DATA (in-leaf, IS_MULTICAST=0, addr_len=0)
```
byte 0: 'D'
byte 1: addr_len(3 hi) | rsv(1) | E2E_ACK_REQ | E2E_IS_ACK | IS_MULTICAST | rsv  (all zero for now except the two E2E bits when relevant)
byte 2: next
byte 3: dst                            -- single byte when addr_len==0
byte 4-5: ctr (16-bit LE)
bytes 6..(5+n): ciphertext (= plaintext placeholder, contains src_address + body)
last 4: MAC (= zeros placeholder)
```
Total: 10 + n bytes (vs today's 8 + n).

### BCN
```
byte 0: 'B'
byte 1: leaf_id(4 hi) | has_schedule(1) | self_gateway(1) | is_mobile(1) | rsv(1)
byte 2: src
byte 3: n_entries
(if has_schedule==1: byte 4 = layer_count, then schedule records 4B each)
then route entries × n_entries (3 B each)
  byte 0: dest
  byte 1: next
  byte 2: score_bucket(4 hi) | (hops-1)(3) | is_gateway(1 lo)
```

### RTS (in-leaf, addr_len=0)
```
byte 0: 'R'
byte 1: src
byte 2: next
byte 3: addr_len(3 hi) | rsv(1) | leaf_id(4 lo)
byte 4: dst                            -- single byte when addr_len==0
byte 5: ctr_lo(4 hi) | rsv(4 lo)
byte 6: sf_bitmap
byte 7: payload_len
```
8 bytes (same as today).

### CTS, ACK (rename only)
```
'C' | ctr_lo(4 hi) | (sf-5)(3) | rsv(1)
'K' | ctr_lo(4 hi) | snr_bucket(4 lo)
```

### NACK (3 bytes, shrunk)
```
byte 0: 'N'
byte 1: reason(4 hi) | ctr_lo(4 lo)
byte 2: payload — BUSY_RX → busy_for_ms/16; BUDGET → tier(4 hi) | headroom_buckets(4 lo)
```

### DATA inner payload (current pseudo-encrypted blob = plaintext)
```
inner = src_addr_len(1) | src_addr(src_addr_len + 1) | body
body  = user_text                          -- normal DATA
      | [acked_ctr_lo, acked_ctr_hi]       -- if E2E_IS_ACK set on wire
```

For in-leaf addr_len=0: `src_addr_len=0`, `src_addr=[origin_id]`, so inner = `[0, origin_id, ...body bytes...]`.

---

## Files touched

| File | Role | Phases that touch |
|---|---|---|
| `scenarios/dv_dual_sf.lua` | The protocol implementation | 1, 2, 3, 4, 5 |
| `docs/PROTOCOL.md` | Frame-format reference doc | 1, 2, 3, 4, 5 |
| `test/run_tests.sh` | Integration test runner (no change expected — verifies tests stay green) | all |
| `test/native/build_test.sh` | C++ unit tests (no Lua wire-format coupling expected) | none |
| `test/*.json` | Integration scenarios — should NOT need edits (script-emit assertions don't read wire bytes); flag if any fail | all (verification only) |
| `webapp/server/models/schemas.py` | Pydantic schemas — no wire-format coupling | none |

**No new files needed.** All wire-format code already lives in `dv_dual_sf.lua`. PROTOCOL.md gets section-by-section updates.

---

## Test strategy

1. **Integration tests (primary):** `bash test/run_tests.sh` runs all 38 JSON scenarios. After each phase, this must stay 38/38 PASS. The scenarios test high-level behavior (delivery, dedup, retries, anti-spam, E2E ACK, etc.) — they don't pin wire bytes, so internal wire-format reshuffling shouldn't break them as long as semantics preserved.

2. **Webapp tests:** `cd webapp && python -m pytest tests/` runs 36 backend tests. No wire-format coupling expected, but run after each phase to catch surprises.

3. **Unit tests (per-phase):** Each phase adds a tiny scenario in `test/` whose `script` is a one-off Lua snippet exercising the pack/parse round-trip with known bytes. These give precise wire-format coverage that integration tests miss.

4. **Manual smoke:** After phases 4 and 5, eyeball `test/s01_dv_dual_sf_events.ndjson` after a fresh run to spot weird tx labels or unexpected event frequencies.

---

### Task 1: Field renames — `network_id` → `leaf_id`, `msg_id` → `ctr_lo`

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` (211 occurrences of `msg_id`, 28 of `network_id`)
- Modify: `docs/PROTOCOL.md` (frame format sections + tunables tables)
- Verify: `test/run_tests.sh` stays 38/38 PASS

**Rationale:** Pure rename. No wire-format change, no behavior change. Validates the codebase responds to renames cleanly before doing anything semantic. All tests must continue to pass exactly as today.

- [ ] **Step 1: Confirm baseline tests pass**

Run: `cd /home/staszek/lora-universal-simulator && cmake --build build -j && bash test/run_tests.sh`
Expected: 38/38 PASS. If any fail, STOP — fix or escalate before proceeding.

- [ ] **Step 2: Rename `network_id` → `leaf_id` in `scenarios/dv_dual_sf.lua`**

Replace ALL occurrences of `network_id` with `leaf_id` throughout the file, including:
- Comments (header block, inline notes)
- Local variables and field accesses
- Config key names (e.g., `self.network_id = cfg.network_id or 0` becomes `self.leaf_id = cfg.leaf_id or 0`)
- pack/parse functions and their callers

Use:
```bash
cd /home/staszek/lora-universal-simulator
sed -i 's/\bnetwork_id\b/leaf_id/g' scenarios/dv_dual_sf.lua
```

Verify no occurrences remain:
```bash
grep -n '\bnetwork_id\b' scenarios/dv_dual_sf.lua
```
Expected: no output.

- [ ] **Step 3: Rename `msg_id` → `ctr_lo` in `scenarios/dv_dual_sf.lua`**

Mechanical rename. Comments + variable names + field names everywhere.

```bash
sed -i 's/\bmsg_id\b/ctr_lo/g' scenarios/dv_dual_sf.lua
grep -n '\bmsg_id\b' scenarios/dv_dual_sf.lua
```
Expected: no output.

- [ ] **Step 4: Run tests; verify still 38/38**

Run: `bash test/run_tests.sh`
Expected: 38/38 PASS. Identical event counts to step 1 — no behavior change.

If anything fails: the rename touched something subtle (e.g., a string key in a table lookup that wasn't supposed to change). Debug, then re-test.

- [ ] **Step 5: Rename in PROTOCOL.md**

Apply the same rename to `docs/PROTOCOL.md`:
```bash
sed -i 's/\bnetwork_id\b/leaf_id/g' docs/PROTOCOL.md
sed -i 's/\bmsg_id\b/ctr_lo/g' docs/PROTOCOL.md
```

Verify the doc renders sensibly — read §3 Frame formats and §14 Configuration reference to spot weirdness.

- [ ] **Step 6: Update CONFIG_FORMAT.md if needed**

Check `docs/CONFIG_FORMAT.md` for `network_id` references in scenario config docs:
```bash
grep -n 'network_id\|msg_id' docs/CONFIG_FORMAT.md
```
If any exist, rename them.

- [ ] **Step 7: Commit**

```bash
git add scenarios/dv_dual_sf.lua docs/PROTOCOL.md docs/CONFIG_FORMAT.md
git commit -m "$(cat <<'EOF'
refactor(wire): rename network_id→leaf_id and msg_id→ctr_lo

Pure rename ahead of the wire-format changes locked in ROADMAP §7.0.
No behavior change; the 4-bit slots that today carry network_id (BCN
byte 1 hi nibble, RTS byte 5 hi nibble) and msg_id (BCN n/a, RTS byte 5
lo nibble, CTS/ACK/NACK byte 1) keep their wire positions and widths.

Phase 1 of the 5-phase wire-format refactor — see
docs/superpowers/plans/2026-05-12-wire-format-changes.md.

Tests: 38/38 JSON scenarios PASS.
EOF
)"
```

---

### Task 2: NACK 4 → 3 byte shrink, busy_for_ms quantized to 16ms

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — `pack_nack` (line ~1066), `parse_nack` (line ~1078), and all NACK senders/receivers (search for `pack_nack(`, `parse_nack(`, `NACK_REASON_BUSY_RX`, `NACK_REASON_BUDGET`)
- Modify: `docs/PROTOCOL.md` — §3.6 NACK section
- Add: `test/t35_nack_3byte.json` — integration test verifying NACK round-trip with the new encoding

**Rationale:** Shrink NACK to free 1 byte per frame. Lose precision (16ms quantum) below the natural retry-jitter floor (~50ms).

- [ ] **Step 1: Inspect current NACK encoding/decoding**

Read `scenarios/dv_dual_sf.lua` around the NACK functions to understand current callers:
```bash
grep -n 'pack_nack\|parse_nack\|NACK_REASON' scenarios/dv_dual_sf.lua
```

Note today's behavior:
- `pack_nack(ctr_lo, reason, payload_lo, payload_hi)` emits 4 bytes
- `parse_nack(frame)` returns `{reason, ctr_lo, payload_lo, payload_hi, busy_for_ms = lo + hi*256}`
- BUSY_RX callers pass `busy_for_ms` split as `lo = busy_for_ms & 0xff`, `hi = (busy_for_ms >> 8) & 0xff`
- BUDGET callers pass `tier` in `payload_lo`, `reserved` in `payload_hi`

- [ ] **Step 2: Rewrite `pack_nack` to 3-byte signature**

Replace the function with:

```lua
local NACK_BUSY_QUANTUM_MS = 16   -- granularity of BUSY_RX payload
local NACK_BUDGET_HEADROOM_BUCKETS = 16  -- headroom 0..15 → 0..100%

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
```

- [ ] **Step 3: Rewrite `parse_nack` to read 3 bytes**

```lua
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
```

- [ ] **Step 4: Update BUSY_RX senders to encode `busy_for_ms / 16`**

Search for `pack_nack(.*NACK_REASON_BUSY_RX` callers:
```bash
grep -n 'pack_nack.*BUSY_RX\|pack_nack(.*0\b' scenarios/dv_dual_sf.lua
```

For each call site emitting BUSY_RX, convert `busy_for_ms` to the quantized byte:
```lua
-- before:
-- pack_nack(ctr_lo, NACK_REASON_BUSY_RX, busy_for_ms & 0xff, (busy_for_ms >> 8) & 0xff)
-- after:
local payload = math.floor((busy_for_ms + NACK_BUSY_QUANTUM_MS - 1) / NACK_BUSY_QUANTUM_MS)
if payload > 255 then payload = 255 end
pack_nack(ctr_lo, NACK_REASON_BUSY_RX, payload)
```

The ceiling-divide (`(x + q - 1) / q`) ensures the sender's reported busy window is never SHORTER than the actual — receiver might really need a bit more time, never less.

- [ ] **Step 5: Update BUDGET senders to encode tier + headroom in one byte**

For each `pack_nack(.*NACK_REASON_BUDGET` site:
```lua
-- before:
-- pack_nack(ctr_lo, NACK_REASON_BUDGET, tier, 0)
-- after:
local payload = ((tier & 0xf) << 4) | (headroom_buckets & 0xf)
pack_nack(ctr_lo, NACK_REASON_BUDGET, payload)
```

If a call site doesn't have headroom_buckets, pass `0` for now (compatible with downstream "headroom unknown" handling).

- [ ] **Step 6: Update parse_nack receivers**

Search for `parse_nack(` in `on_recv` handlers. The returned struct's `busy_for_ms` field is still present (decoded by parse_nack), so most receiver logic should be untouched. New fields `budget_tier` and `budget_headroom_buckets` are available for BUDGET-reason handling — wire them in wherever the script reads tier from NACK today.

```bash
grep -n 'parse_nack\|\.busy_for_ms\|\.reason\b' scenarios/dv_dual_sf.lua
```

- [ ] **Step 7: Update wire-format header comment in dv_dual_sf.lua**

Edit the comment table at the top of the file:
```lua
-- | `'N'` | NACK   | `N`, [reason(4)|ctr_lo(4)](1), payload(1)  →  3 B  |
```

And update the doc block before `pack_nack` to describe the new payload encoding (see step 2 docstring).

- [ ] **Step 8: Run integration tests**

```bash
cmake --build build -j && bash test/run_tests.sh
```
Expected: 38/38 PASS.

The most likely failure: a test that relies on a NACK-driven retry timing within a tight window may shift by up to 15ms. If a scenario fails on a timing assertion, widen the assertion or accept the small shift.

- [ ] **Step 9: Add `test/t35_nack_3byte.json`**

Create a minimal scenario that forces a BUSY_RX NACK to fire and asserts the receiver got it with the right busy_for_ms value within quantization tolerance.

```json
{
  "_name": "t35_nack_3byte",
  "_desc": "Two concurrent originators race for the same forwarder. Second RTS lands while forwarder is mid-flight → forwarder NACKs with busy_for_ms. Verifies the new 3-byte NACK encoding round-trips through quantization without breaking retry behavior.",
  "simulation": {
    "duration_ms": 30000,
    "step_ms": 1,
    "warmup_ms": 2000,
    "seed": 7,
    "radio": { "sf": 8, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10],
                  "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } },
    { "name": "bob",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10],
                  "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } },
    { "name": "carol", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10],
                  "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } },
    { "name": "dave",  "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10],
                  "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob", "snr": 12.0, "rssi": -78.0, "bidir": true },
      { "from": "carol", "to": "bob", "snr": 12.0, "rssi": -78.0, "bidir": true },
      { "from": "bob",   "to": "dave", "snr": 12.0, "rssi": -78.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 8000,  "node": "alice", "command": "send dave msg-a" },
    { "at_ms": 8050,  "node": "carol", "command": "send dave msg-c" }
  ],
  "expect": [
    { "type": "script_emit_contains", "node": "dave", "emit_type": "delivered", "value": "msg-a" },
    { "type": "script_emit_exists",   "node": "carol", "emit_type": "nack_rx" }
  ]
}
```

Add `t35_nack_3byte` to the runner if needed (`test/run_tests.sh` discovers `t*.json` automatically — verify):
```bash
grep -n 't[0-9]' test/run_tests.sh | head
```

- [ ] **Step 10: Run the new test**

```bash
bash test/run_tests.sh 2>&1 | grep -E 't35|PASS|FAIL' | head -20
```
Expected: t35_nack_3byte PASS.

- [ ] **Step 11: Update PROTOCOL.md §3.6 NACK**

In `docs/PROTOCOL.md`, find section `### 3.6 NACK` and rewrite it to describe the 3-byte layout, payload quantization, and per-reason encoding. The new content should be ~30 lines and match the ROADMAP §7.0.5 spec.

- [ ] **Step 12: Commit**

```bash
git add scenarios/dv_dual_sf.lua docs/PROTOCOL.md test/t35_nack_3byte.json
git commit -m "$(cat <<'EOF'
feat(wire): shrink NACK 4→3 bytes with quantized busy_for_ms

Per ROADMAP §7.0.5. busy_for_ms quantum = 16 ms (well below the
50 ms natural retry-jitter floor); range 0..4080 ms covers SF12 worst
case with 4× headroom. BUDGET-reason NACK now packs tier+headroom in
one byte (4+4 bits each).

Phase 2 of the 5-phase wire-format refactor.

Tests: 38/38 JSON scenarios PASS + new t35_nack_3byte PASS.
EOF
)"
```

---

### Task 3: BCN header re-pack + hops-1 + is_gateway bit

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — `pack_beacon` (line ~796), `parse_beacon` (line ~868), route-entry storage in `rt[]`, `rt_merge`, `age_out_stale_routes`, anywhere `entry.hops` is set/read
- Modify: `docs/PROTOCOL.md` — §3.1 Beacon section
- Add: `test/t36_bcn_repack.json` — verifies new BCN bits parse + propagate cleanly

**Rationale:** Add the `has_schedule` / `self_gateway` / `is_mobile` flag bits to byte 1, change the route-entry encoding so byte 2 packs `score_bucket(4) | (hops-1)(3) | is_gateway(1)`. Reserved bits stay zero. Schedule records path is added but unused (no node sets `has_schedule=1` yet).

- [ ] **Step 1: Update `pack_beacon` to emit new byte 1 layout**

Replace the early body of `pack_beacon` where it constructs `nid_byte`:

```lua
-- before:
-- local nid_byte = (node.leaf_id & 0xf) << 4

-- after:
local function pack_beacon_byte1(node)
  local b = (node.leaf_id & 0xf) << 4
  if node.has_schedule then b = b | 0x08 end
  if node.self_gateway then b = b | 0x04 end
  if node.is_mobile    then b = b | 0x02 end
  -- bit 0 reserved (zero)
  return b
end
```

Then in `pack_beacon`, replace the byte-1 emission:
```lua
local byte1 = pack_beacon_byte1(node)
```

Replace ALL `string.char(nid_byte)` occurrences inside `pack_beacon` with `string.char(byte1)`.

For the empty-rt early-return path, also use `byte1`:
```lua
if total == 0 then
  return "B" .. string.char(byte1) .. string.char(node.id) .. string.char(0),
         0,
         { dirty_n = 0, stable_n = 0, total_dirty = 0 }
end
```

- [ ] **Step 2: Update route-entry packing — byte 2 = bucket | (hops-1) | is_gateway**

Find the entry packing inside `pack_beacon` body (search for `score_bucket` or `hops` mentions in the entry-emit loop):

```lua
-- before (somewhere in the entry emission):
-- local entry_byte2 = ((bucket & 0xf) << 4) | (hops & 0xf)

-- after:
local hops_wire = (hops - 1) & 0x7              -- wire encodes hops-1
local is_gw     = (rt[dest].is_gateway and 1 or 0)
local entry_byte2 = ((bucket & 0xf) << 4) | (hops_wire << 1) | is_gw
```

The exact line to modify depends on the file; locate by searching for the loop that emits `dest`, `next`, then a packed byte for `score_bucket | hops`.

- [ ] **Step 3: Update `parse_beacon` to decode new byte 1 flags**

Replace its byte 1 read with:

```lua
local b1 = frame:byte(2)
local out = {
  leaf_id       = (b1 >> 4) & 0xf,
  has_schedule  = (b1 & 0x08) ~= 0,
  self_gateway  = (b1 & 0x04) ~= 0,
  is_mobile     = (b1 & 0x02) ~= 0,
  src           = frame:byte(3),
  -- n_entries comes from byte 4 (unchanged)
}
```

- [ ] **Step 4: Skip schedule records on parse (graceful — no node emits them yet)**

After reading `n = frame:byte(4)`, if `out.has_schedule`:

```lua
local pos = 5  -- next byte after n_entries
if out.has_schedule then
  local layer_count = frame:byte(pos)
  pos = pos + 1
  -- skip layer_count × 4 bytes (schedule records — runtime path not implemented yet)
  pos = pos + layer_count * 4
end
out._entries_start = pos  -- byte index where the route entries begin
```

Then update the existing entries-loop to start at `out._entries_start` instead of byte 5. Use `pos` as the loop cursor.

If `out.has_schedule == false`, `pos` stays at 5 — matches today's behavior.

- [ ] **Step 5: Update entry parse for hops-1 + is_gateway**

In the entry decode loop:

```lua
-- byte at (pos+2) carries: score_bucket(4 hi) | hops_wire(3) | is_gateway(1)
local entry_byte2 = frame:byte(pos + 2)
local score_bucket = (entry_byte2 >> 4) & 0xf
local hops_wire    = (entry_byte2 >> 1) & 0x7
local hops         = hops_wire + 1                  -- decode hops-1 → hops
local is_gateway   = (entry_byte2 & 0x01) ~= 0
table.insert(out.entries, {
  dest          = frame:byte(pos + 0),
  next          = frame:byte(pos + 1),
  score_bucket  = score_bucket,
  score         = snr_of_bucket_4b(score_bucket),
  hops          = hops,
  is_gateway    = is_gateway,
})
pos = pos + 3
```

- [ ] **Step 6: Wire `is_gateway` into rt[] candidates**

In `rt_merge`, when assigning a candidate, copy `is_gateway` from the BCN entry to the candidate struct:

```lua
-- in rt_merge, when building cand:
cand.is_gateway = (e.is_gateway == true)  -- per-candidate storage
```

Set sensible defaults at on_init:
```lua
-- in on_init:
self.has_schedule = false           -- TBD until §7.3 lands
self.self_gateway = (cfg.is_gateway == true)
self.is_mobile    = (cfg.is_mobile == true)
```

(These are config-fed flags; default false unless the scenario sets `"is_gateway": true` or `"is_mobile": true` per node. Validate with grep that no scenario sets them today.)

- [ ] **Step 7: Update wire-format header comment in dv_dual_sf.lua**

The comment table at file top:
```lua
-- | `'B'` | Beacon | `B`, [leaf_id(4)|has_schedule(1)|self_gateway(1)|is_mobile(1)|rsv(1)](1), src(1), n(1), [layer_count(1)+sched×layer_count]?, entries × n × {dest(1), next(1), [bucket(4)|(hops-1)(3)|is_gateway(1)](1)}  →  4+(1+4×L)*S+3n B |
```

- [ ] **Step 8: Run integration tests**

```bash
cmake --build build -j && bash test/run_tests.sh
```
Expected: 38/38 PASS.

Most likely failure mode: a scenario's `delivered` count drops because the `hops` change broke route-acceptance somewhere — investigate `rt_merge` and `route_strictly_better` for any direct comparison against the wire-byte value of hops (there shouldn't be any; if found, fix).

- [ ] **Step 9: Add `test/t36_bcn_repack.json`**

A 3-node line topology that forces multi-hop routing through a single intermediate, asserting routes still propagate correctly under the new BCN format:

```json
{
  "_name": "t36_bcn_repack",
  "_desc": "Linear topology alice→bob→carol. Verifies new BCN byte-1 flags and route-entry encoding (hops-1, is_gateway bit) still propagate routes correctly via DV beacon. Asserts carol learns route to alice via bob through normal BCN propagation.",
  "simulation": {
    "duration_ms": 30000,
    "step_ms": 1,
    "warmup_ms": 2000,
    "seed": 11,
    "radio": { "sf": 8, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 3000, "quiet_threshold_ms": 0 } },
    { "name": "bob",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 3000, "quiet_threshold_ms": 0 } },
    { "name": "carol", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 3000, "quiet_threshold_ms": 0 } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob",   "snr": 12.0, "rssi": -78.0, "bidir": true },
      { "from": "bob",   "to": "carol", "snr": 12.0, "rssi": -78.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 15000, "node": "carol", "command": "send alice hello-from-carol" }
  ],
  "expect": [
    { "type": "script_emit_contains", "node": "alice", "emit_type": "delivered", "value": "hello-from-carol" }
  ]
}
```

- [ ] **Step 10: Run the new test**

```bash
bash test/run_tests.sh 2>&1 | grep -E 't36|PASS|FAIL' | head -20
```
Expected: t36_bcn_repack PASS.

- [ ] **Step 11: Update PROTOCOL.md §3.1 Beacon**

Rewrite the §3.1 frame-format diagram in `docs/PROTOCOL.md` to match the new layout (header bits + route entry + schedule-record path). Cross-reference §7.0.2 in ROADMAP.md.

- [ ] **Step 12: Commit**

```bash
git add scenarios/dv_dual_sf.lua docs/PROTOCOL.md test/t36_bcn_repack.json
git commit -m "$(cat <<'EOF'
feat(wire): BCN re-pack — flag bits, hops-1 encoding, is_gateway bit

Per ROADMAP §7.0.2:
- byte 1 packs leaf_id(4) | has_schedule(1) | self_gateway(1) | is_mobile(1) | rsv(1)
- route entry byte 2 packs score_bucket(4) | (hops-1)(3) | is_gateway(1)
- schedule-record path added to parse_beacon (skipped at runtime — no node
  sets has_schedule=1 yet)
- in-memory rt[] candidates gain .is_gateway boolean

Wire-size: 49-entry BCN unchanged at 151 B. Future gateway BCNs add
+5 B per upper layer.

Phase 3 of the 5-phase wire-format refactor.

Tests: 38/38 JSON + new t36_bcn_repack PASS.
EOF
)"
```

---

### Task 4: DATA re-pack — flags byte, ctr, ciphertext+MAC placeholders, dedup re-key

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — `pack_data` (line ~1128), `parse_data` (line ~1135), `pack_origin_hdr`/`parse_origin_hdr` (replaced/removed), `seen_origins` dedup, all `delivered` / `forward` paths, all `pending_e2e` paths, `on_command` send/send_e2e
- Modify: `docs/PROTOCOL.md` — §3.4 DATA section + §7.4 E2E ACK section
- Add: `test/t37_data_repack.json` — verifies new DATA wire format end-to-end

**Rationale:** Move E2E flags from inner payload header to wire byte 1. Replace 2-byte `origin_seq` payload header with 2-byte wire `ctr` field. Add 4-byte MAC placeholder (zeros). Place originator's address inside the "ciphertext" blob (= plaintext placeholder bytes). Re-key flight dedup from `(origin, origin_seq)` to `(ctr, dst)`.

- [ ] **Step 1: Inspect current DATA pack/parse + payload-header functions**

Read carefully:
```bash
grep -n 'pack_data\|parse_data\|pack_origin_hdr\|parse_origin_hdr\|parse_origin_seq\|seen_origins\|pending_e2e' scenarios/dv_dual_sf.lua | head -40
```

Understand:
- `pack_data(origin, src, dst, next_hop, ctr_lo, payload)` produces 6-byte header + payload
- Payload itself has its own 3-byte origin-header (`flags | seq_lo | seq_hi`) + body
- `seen_origins[(origin, origin_seq)]` dedup table

- [ ] **Step 2: Rewrite `pack_data` to new wire layout**

Define constants near the top of the file:

```lua
local DATA_FLAG_E2E_ACK_REQ = 0x08   -- bit 3 of byte 1
local DATA_FLAG_E2E_IS_ACK  = 0x04   -- bit 2
local DATA_FLAG_IS_MCAST    = 0x02   -- bit 1
local MAC_LEN = 4                    -- 4-byte zero MAC placeholder until §8 lands
```

Replace `pack_data`:

```lua
-- DATA — 10 + n bytes (in-leaf, addr_len=0):
--   byte 0 : tag 'D'
--   byte 1 : addr_len(3 hi) | rsv(1) | E2E_ACK_REQ | E2E_IS_ACK | IS_MULTICAST | rsv
--   byte 2 : next (immediate next-hop receiver)
--   byte 3 : dst  (final destination — when addr_len==0, single byte)
--   bytes 4-5: ctr (16-bit LE, per-(origin, dst) counter)
--   bytes 6..(5+n): ciphertext (= plaintext placeholder; carries
--                    src_addr_len(1) | src_addr(src_addr_len+1) | body)
--   last 4 : MAC (4-byte zero placeholder until §8 crypto lands)
local function pack_data(origin, next_hop, dst, ctr, flags, body)
  -- flags: bitmask of DATA_FLAG_* constants
  -- body:  raw body bytes (user_text OR [acked_ctr_lo,acked_ctr_hi] for IS_ACK)
  local addr_len = 0                                       -- in-leaf only this phase
  local byte1 = ((addr_len & 0x7) << 5) | (flags & 0x0f)
  local ctr_lo = ctr & 0xff
  local ctr_hi = (ctr >> 8) & 0xff
  -- inner payload (plaintext placeholder for the ciphertext slot):
  --   src_addr_len = 0   (origin is single-byte leaf-local when addr_len=0)
  --   src_addr     = [origin]
  --   body bytes follow
  local inner = string.char(0)               -- src_addr_len
                .. string.char(origin)        -- src_addr (1 byte)
                .. body
  local mac = string.rep("\0", MAC_LEN)
  return "D" .. string.char(byte1)
              .. string.char(next_hop)
              .. string.char(dst)
              .. string.char(ctr_lo)
              .. string.char(ctr_hi)
              .. inner
              .. mac
end
```

Note: today's `pack_data` takes `src` (previous-hop) but the new wire format DROPS `src` from DATA per the spec. The `src` info is still available to receivers via `pending_rx.from` (set during RTS-CTS handshake). So callers stop passing `src`.

- [ ] **Step 3: Rewrite `parse_data` to read new wire layout**

```lua
local function parse_data(frame)
  if #frame < 10 or frame:sub(1,1) ~= "D" then return nil end
  local b1 = frame:byte(2)
  local addr_len = (b1 >> 5) & 0x07
  if addr_len ~= 0 then return nil end       -- hierarchy support deferred
  local flags = b1 & 0x0f
  -- compute body slice positions
  local next_hop = frame:byte(3)
  local dst      = frame:byte(4)
  local ctr_lo   = frame:byte(5)
  local ctr_hi   = frame:byte(6)
  local ctr      = ctr_lo | (ctr_hi << 8)
  -- ciphertext spans byte 7 .. (#frame - MAC_LEN)
  local inner_end = #frame - MAC_LEN
  if inner_end < 7 then return nil end
  local inner    = frame:sub(7, inner_end)
  if #inner < 2 then return nil end           -- need at least src_addr_len + 1 byte src_addr
  local src_addr_len = inner:byte(1)
  if src_addr_len ~= 0 then return nil end    -- only flat addresses supported this phase
  local origin   = inner:byte(2)
  local body     = inner:sub(3)
  -- MAC bytes at frame:sub(inner_end + 1, #frame) — placeholder zeros, ignored
  return {
    flags         = flags,
    e2e_ack_req   = (flags & DATA_FLAG_E2E_ACK_REQ) ~= 0,
    e2e_is_ack    = (flags & DATA_FLAG_E2E_IS_ACK) ~= 0,
    is_multicast  = (flags & DATA_FLAG_IS_MCAST) ~= 0,
    next          = next_hop,
    dst           = dst,
    ctr           = ctr,
    ctr_lo        = ctr_lo & 0xf,             -- low NIBBLE for hop-level match
    origin        = origin,
    body          = body,
  }
end
```

Note: `ctr_lo` field name is overloaded — for hop-level matching only the low NIBBLE (4 bits) is used. Compute `ctr_lo_nibble = ctr & 0xf` whenever the script needs the 4-bit slot. Adjust references accordingly.

- [ ] **Step 4: Remove `pack_origin_hdr` / `parse_origin_hdr` / `pack_origin_seq` / `parse_origin_seq`**

The payload-header inner format moved into pack/parse_data directly. Delete the helpers and their callers' use:

```bash
grep -n 'pack_origin_hdr\|parse_origin_hdr\|pack_origin_seq\|parse_origin_seq\|ORIGIN_HDR_LEN\|ORIGIN_SEQ_HDR_LEN' scenarios/dv_dual_sf.lua
```

For each call site:
- `pack_origin_seq(seq)` → caller now passes `seq` as `ctr` into `pack_data`
- `pack_origin_hdr(seq, flags)` (used in E2E ACK) → caller passes `seq` as `ctr` and lifts `flags` to the new `DATA_FLAG_*` constants
- `parse_origin_seq(payload)` → `parse_data(frame).body` is the user_text; the `seq` is now `parse_data(frame).ctr`
- `parse_origin_hdr(payload)` → `parse_data(frame)` returns `flags`, `e2e_ack_req`, `e2e_is_ack` directly

- [ ] **Step 5: Update `on_command` for send / send_e2e**

The originator path today: assigns `origin_seq`, calls `pack_origin_seq(seq)` to make the payload bytes, enqueues with that as `payload`.

New path: assigns `ctr` (per-(self, dst) counter), enqueues with `body = user_text`, calls `pack_data(self.id, next, dst, ctr, flags, body)` at TX time.

```lua
-- in on_command for "send <dst> <text>":
local ctr_for_pair = self:next_ctr(dst_id)        -- new helper, see step 6
self.tx_queue:enqueue({
  origin       = self.id,
  dst_id       = dst_id,
  dst_name     = dst_name,
  body         = user_text,
  flags        = 0,                               -- no E2E ACK request
  ctr          = ctr_for_pair,
  previous_hop = nil,                             -- originator
  next_attempt_ms = self:now(),
  requeue_count = 0,
  enqueue_time_ms = self:now(),
})

-- for "send_e2e <dst> <text>":
local ctr_for_pair = self:next_ctr(dst_id)
self.pending_e2e[ctr_for_pair] = { sent_at = self:now(), dst = dst_id, text = user_text }
self.tx_queue:enqueue({
  origin = self.id, dst_id = dst_id, body = user_text,
  flags  = DATA_FLAG_E2E_ACK_REQ,
  ctr    = ctr_for_pair,
  ...
})
```

- [ ] **Step 6: Add `self:next_ctr(peer_id)` helper**

```lua
-- in on_init:
self.peer_send_counter = {}     -- per-(self → peer) outbound counter
self.peer_last_seen_ctr = {}    -- per-(peer → self) inbound highest seen

function self:next_ctr(peer_id)
  local c = (self.peer_send_counter[peer_id] or 0) + 1
  if c > 65535 then c = 1 end                    -- wrap (will trigger re-key under §8)
  self.peer_send_counter[peer_id] = c
  return c
end
```

NV persistence is out of scope for this phase — counters live in RAM. Future work flagged in ROADMAP §8.1.

- [ ] **Step 7: Re-key `seen_origins` dedup to use `(ctr, dst)` AND keep `(origin, ctr)` keying compatible**

Today's dedup key: `(d.origin, origin_seq)` where origin_seq is the 16-bit payload counter.

New dedup key: `(d.origin, d.ctr)`. Same uniqueness — `ctr` is per-(origin, dst) and we store at the originator level too, so two flights from same origin always have distinct ctr.

Search the script for `seen_origins`, identify the insertion + lookup sites, replace key construction:

```lua
-- BEFORE (somewhere in DATA delivered branch):
-- local origin_key = string.format("%d.%d", d.origin, origin_seq)
-- if self.seen_origins[origin_key] then ... end

-- AFTER:
local origin_key = string.format("%d.%d", d.origin, d.ctr)
if self.seen_origins[origin_key] then ... end
```

- [ ] **Step 8: Update `pending_e2e` keying**

Today: `pending_e2e[seq] = {...}` where seq is the 16-bit payload counter. Receiver of E2E ACK reads `acked_seq` from inner body, looks up `pending_e2e[acked_seq]`.

New: same logic, but `seq` IS `ctr` (no functional difference except the name). Renaming for clarity:

```bash
sed -i 's/\bpending_e2e\b/pending_e2e_ack/g' scenarios/dv_dual_sf.lua
```

(Or keep `pending_e2e` name — purely cosmetic.) The key (16-bit counter) and value (sent_at, dst, text) shape unchanged.

For E2E ACK return-frame construction at destination:
```lua
-- when DATA arrives at destination with e2e_ack_req:
local return_ctr = self:next_ctr(d.origin)
local return_body = string.char(d.ctr & 0xff) .. string.char((d.ctr >> 8) & 0xff)
-- enqueue a new send addressed back to d.origin
self.tx_queue:enqueue({
  origin = self.id, dst_id = d.origin, body = return_body,
  flags  = DATA_FLAG_E2E_IS_ACK,
  ctr    = return_ctr,
  previous_hop = nil,
  next_attempt_ms = self:now(),
  requeue_count = 0,
  enqueue_time_ms = self:now(),
})
self:emit("e2e_ack_tx_enqueued", { acked_ctr = d.ctr, to = d.origin })
```

- [ ] **Step 9: Update DATA tx-time call site**

Find where the script TXes DATA (search for `pack_data(`):

```bash
grep -n 'pack_data(' scenarios/dv_dual_sf.lua
```

Each call now uses the new signature:
```lua
-- before: pack_data(origin, src, dst, next, ctr_lo, payload_bytes)
-- after:  pack_data(origin, next, dst, ctr, flags, body)
local data_bytes = pack_data(item.origin, next_hop, item.dst_id, item.ctr, item.flags, item.body)
```

And update `payload_len` computation for RTS — the new on-wire DATA size includes the inner-payload `src_addr_len + src_addr` overhead (2 B) plus MAC (4 B):

```lua
-- payload_len = body length + inner overhead (2 B) + MAC (4 B)
local payload_len = #item.body + 2 + MAC_LEN
```

This is the byte count the receiver uses to size `pending_rx_expiry`.

Wait — `payload_len` in today's RTS counts bytes AFTER the 6-byte DATA header. Under new format, "everything after byte 5 (post-ctr_hi)" = `inner + MAC` = `2 + #body + MAC_LEN`. So:

```lua
local payload_len = 2 + #item.body + MAC_LEN
```

- [ ] **Step 10: Update wire-format header comment in dv_dual_sf.lua**

```lua
-- | `'D'` | DATA   | `D`, [addr_len(3)|rsv(1)|E2E_ACK_REQ(1)|E2E_IS_ACK(1)|IS_MULTICAST(1)|rsv(1)](1), next(1), dst(1 when addr_len=0), ctr_lo(1), ctr_hi(1), ciphertext(n), MAC(4)  →  10+n B (in-leaf) |
```

And remove the old payload-header table comment (`-- payload = [origin_seq_lo(1)] [origin_seq_hi(1)] [user_text(N)]` block).

- [ ] **Step 11: Run integration tests**

```bash
cmake --build build -j && bash test/run_tests.sh
```
Expected: 38/38 PASS.

Most likely failure: the E2E ACK test (t34_e2e_ack) — the inner-body / wire-flags shuffle could mis-thread. Inspect events and re-test.

- [ ] **Step 12: Add `test/t37_data_repack.json`**

```json
{
  "_name": "t37_data_repack",
  "_desc": "Validates new DATA wire format end-to-end: send alice→carol via bob succeeds with new 10+n byte DATA header (flags+ctr+ciphertext+MAC placeholder); send_e2e from alice→carol returns delivered_confirmed via the new wire format with E2E_FLAG_IS_ACK set on byte 1 (not inner payload).",
  "simulation": {
    "duration_ms": 30000,
    "step_ms": 1,
    "warmup_ms": 2000,
    "seed": 17,
    "radio": { "sf": 8, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 5000, "quiet_threshold_ms": 0, "e2e_ack_ttl_ms": 30000 } },
    { "name": "bob",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } },
    { "name": "carol", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob",   "snr": 12.0, "rssi": -78.0, "bidir": true },
      { "from": "bob",   "to": "carol", "snr": 12.0, "rssi": -78.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 8000,  "node": "alice", "command": "send carol plain-msg" },
    { "at_ms": 15000, "node": "alice", "command": "send_e2e carol important-msg" }
  ],
  "expect": [
    { "type": "script_emit_contains", "node": "carol", "emit_type": "delivered", "value": "plain-msg" },
    { "type": "script_emit_contains", "node": "carol", "emit_type": "delivered", "value": "important-msg" },
    { "type": "script_emit_contains", "node": "alice", "emit_type": "delivered_confirmed", "value": "important-msg" }
  ]
}
```

- [ ] **Step 13: Run new test**

```bash
bash test/run_tests.sh 2>&1 | grep -E 't37|PASS|FAIL' | head -20
```
Expected: t37_data_repack PASS.

- [ ] **Step 14: Update PROTOCOL.md §3.4 DATA + §7.4 E2E ACK**

Rewrite §3.4 to match the new 10+n B wire format. Update §7.4 to describe E2E flags on wire byte 1 (no longer in inner payload header), and the IS_ACK return frame's body being `[acked_ctr_lo, acked_ctr_hi]`.

- [ ] **Step 15: Commit**

```bash
git add scenarios/dv_dual_sf.lua docs/PROTOCOL.md test/t37_data_repack.json
git commit -m "$(cat <<'EOF'
feat(wire): DATA re-pack — wire-level E2E flags, ctr, ciphertext+MAC stubs

Per ROADMAP §7.0.1.

Wire changes:
- byte 1 carries addr_len(3) | rsv(1) | E2E_ACK_REQ | E2E_IS_ACK | IS_MULTICAST | rsv
- src field removed from wire (derivable from pending_rx.from)
- 16-bit ctr replaces 3-byte payload-header (flags+seq), promoted to plaintext wire bytes 4-5
- ciphertext = plaintext placeholder; inner = src_addr_len(1) | src_addr(1) | body
- 4-byte zero MAC placeholder (will carry Poly1305-truncated when §8 crypto lands)
- flight dedup re-keyed from (origin, origin_seq) → (origin, ctr); same uniqueness
- per-(self, peer) outbound counter via self:next_ctr(peer); RAM-only for now (NV
  persistence deferred to §8)

In-leaf size: 10 + n bytes (vs today's 8 + n). +2 B is the crypto/privacy stub
cost; identical bytes once §8 lands.

Phase 4 of the 5-phase wire-format refactor.

Tests: 38/38 + new t37_data_repack PASS.
EOF
)"
```

---

### Task 5: RTS re-pack — drop origin, new byte 3, ctr_lo in own byte

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` — `pack_rts` (line ~915), `parse_rts` (line ~924), all callers (`issue_send`, `tx_rts_retry`, `on_recv 'R'`), anti-spam observation hook
- Modify: `docs/PROTOCOL.md` — §3.2 RTS section
- Add: `test/t38_rts_repack.json` — verifies new RTS wire format end-to-end

**Rationale:** Drop `origin` from RTS wire — destination identifies origin via the inner DATA payload (set up in phase 4). New byte 3 packs `addr_len(3) | rsv(1) | leaf_id(4)`. ctr_lo gets its own byte. In-leaf RTS stays 8 bytes.

- [ ] **Step 1: Confirm anti-spam tracking doesn't depend on `origin`**

Search for anti-spam observation hooks:
```bash
grep -n 'track_originator_observation\|per_sender_originator' scenarios/dv_dual_sf.lua | head
```

Verify the hook uses `meta.src` (the radio-physical-layer sender ID) NOT the wire-frame `origin` field. If it does read `r.origin` anywhere, replace with `meta.src`.

- [ ] **Step 2: Rewrite `pack_rts` to new layout**

```lua
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
```

- [ ] **Step 3: Rewrite `parse_rts` to read new layout**

```lua
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
```

The returned struct **drops the `origin` field** that today's parse_rts emitted. Callers that read `r.origin` need updating (see step 4).

- [ ] **Step 4: Update `pack_rts` callers**

```bash
grep -n 'pack_rts(' scenarios/dv_dual_sf.lua
```

Each call site loses the `origin` positional argument:
```lua
-- before:
-- pack_rts(self.leaf_id, origin, src, dst, next, ctr_lo, sf_bitmap, payload_len)
-- after:
pack_rts(self.leaf_id, src, dst, next, ctr_lo, sf_bitmap, payload_len)
```

(`leaf_id` already-renamed from `network_id` in phase 1.)

- [ ] **Step 5: Update `parse_rts` callers — drop `r.origin`**

```bash
grep -n 'parse_rts\|r\.origin\b' scenarios/dv_dual_sf.lua | head -40
```

For each reader of `r.origin`:
- If used for routing toward origin (e.g., `rt[r.origin]`): the destination already gets origin from inner DATA payload (`d.origin`), so RTS handlers should NOT depend on it. Remove or fall back to "use pending_rx state at receiver" path.
- If used for dedup or seen_origins lookup at RTS time: NOT NEEDED today (dedup happens on DATA arrival). Remove.
- If used for forward-queued emit metadata: replace with `meta.src` or just omit the field.

The script's RTS handlers today set `pending_rx = {from, origin, dst, ctr_lo}`. Drop the `origin` field from pending_rx; receivers populate it from the eventual DATA arrival instead.

- [ ] **Step 6: Update wire-format header comment in dv_dual_sf.lua**

```lua
-- | `'R'` | RTS    | `R`, src(1), next(1), [addr_len(3)|rsv(1)|leaf_id(4)](1), dst(1 when addr_len=0), [ctr_lo(4)|rsv(4)](1), sf_bitmap(1), payload_len(1)  →  8 B (in-leaf) |
```

- [ ] **Step 7: Run integration tests**

```bash
cmake --build build -j && bash test/run_tests.sh
```
Expected: 38/38 PASS.

Most likely failure: somewhere in `on_recv 'R'` or anti-spam still reads `r.origin`. Fix and retry.

- [ ] **Step 8: Add `test/t38_rts_repack.json`**

```json
{
  "_name": "t38_rts_repack",
  "_desc": "Validates new RTS wire format (no origin field, byte 3 packs addr_len|rsv|leaf_id, ctr_lo in own byte). 3-node line topology; multi-hop send exercises the full RTS-CTS-DATA-ACK chain twice (alice→carol via bob).",
  "simulation": {
    "duration_ms": 30000,
    "step_ms": 1,
    "warmup_ms": 2000,
    "seed": 23,
    "radio": { "sf": 8, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } },
    { "name": "bob",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } },
    { "name": "carol", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 8, "allowed_data_sfs": [9, 10], "beacon_period_ms": 5000, "quiet_threshold_ms": 0 } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob",   "snr": 12.0, "rssi": -78.0, "bidir": true },
      { "from": "bob",   "to": "carol", "snr": 12.0, "rssi": -78.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 8000,  "node": "alice", "command": "send carol first" },
    { "at_ms": 18000, "node": "alice", "command": "send carol second" }
  ],
  "expect": [
    { "type": "script_emit_contains", "node": "carol", "emit_type": "delivered", "value": "first" },
    { "type": "script_emit_contains", "node": "carol", "emit_type": "delivered", "value": "second" }
  ]
}
```

- [ ] **Step 9: Run new test**

```bash
bash test/run_tests.sh 2>&1 | grep -E 't38|PASS|FAIL' | head -20
```
Expected: t38_rts_repack PASS.

- [ ] **Step 10: Update PROTOCOL.md §3.2 RTS**

Rewrite the §3.2 frame diagram to match the new layout. Cross-reference §7.0.3 in ROADMAP.

- [ ] **Step 11: Final full-suite verification**

```bash
cmake --build build -j
bash test/run_tests.sh
cd webapp && python -m pytest tests/ && cd ..
```
Expected: 38/38 + 36/36 = 74/74 tests PASS across both suites.

- [ ] **Step 12: Update SESSION_HANDOFF.md**

Add a note in `docs/SESSION_HANDOFF.md` (or just the "what's new" section near the top) summarizing the wire-format change. Keep it to 5-10 lines: "Phases 1-5 of ROADMAP §7.0 landed; in-leaf wire-format updated; addr_len > 0 hierarchy support still deferred to a separate plan."

- [ ] **Step 13: Commit**

```bash
git add scenarios/dv_dual_sf.lua docs/PROTOCOL.md docs/SESSION_HANDOFF.md test/t38_rts_repack.json
git commit -m "$(cat <<'EOF'
feat(wire): RTS re-pack — drop origin, new byte 3, ctr_lo own byte

Per ROADMAP §7.0.3.

Wire changes:
- origin removed from RTS wire (destination identifies origin from inner DATA payload after phase 4)
- byte 3 packs addr_len(3 hi) | rsv(1) | leaf_id(4 lo) — pattern-matches DATA byte 1
- ctr_lo lives in its own byte's high nibble (low nibble reserved for future hop-level flags)
- pending_rx no longer carries origin; receivers populate origin from DATA on arrival
- anti-spam tracking already used meta.src (radio physical layer) — unchanged

In-leaf RTS stays 8 B. Future hierarchy hops add +1 B per cross-layer boundary.

Phase 5 (final) of the 5-phase wire-format refactor. addr_len > 0 hierarchy
support deferred to a separate plan.

Tests: 38/38 + 36/36 webapp + new t38_rts_repack PASS.
EOF
)"
```

---

## Self-review

Spec coverage check:

| Spec item (ROADMAP §7.0) | Phase | Step |
|---|---|---|
| `network_id` → `leaf_id` rename | 1 | 2 |
| `msg_id` → `ctr_lo` rename | 1 | 3 |
| NACK 4→3 byte, busy_for_ms /16 | 2 | 2-3 |
| BUDGET payload tier+headroom | 2 | 5 |
| BCN byte 1 has_schedule + self_gateway + is_mobile bits | 3 | 1 |
| Route entry hops-1 encoding | 3 | 2 |
| Route entry is_gateway bit | 3 | 2 |
| Schedule-record parse path (skipped at runtime) | 3 | 4 |
| rt[] is_gateway storage | 3 | 6 |
| DATA byte 1 flag bits (E2E_ACK_REQ + E2E_IS_ACK + IS_MULTICAST + addr_len) | 4 | 2 |
| DATA 16-bit ctr in plaintext bytes 4-5 | 4 | 2 |
| Ciphertext + MAC placeholders | 4 | 2 |
| Inner src_address structure | 4 | 2 |
| seen_origins re-key (origin, ctr) | 4 | 7 |
| pending_e2e on `ctr` | 4 | 8 |
| RTS drop origin | 5 | 4-5 |
| RTS new byte 3 packing | 5 | 2 |
| RTS ctr_lo own byte | 5 | 2 |
| Reserved bits stay zero | all | always |
| §7.5 multicast (deferred) | — | — |
| Hierarchy support addr_len > 0 (deferred) | — | — |

All locked spec items map to a phase. §7.5 multicast and hierarchy support explicitly out of scope per the spec — flagged in the plan header.

Placeholder scan: no "TBD" or "fill in later" in the steps. The schedule-record runtime path in phase 3 step 4 is explicitly "skip at runtime — no node emits them yet" with placeholder zeros, which matches the spec's "wire bits committed, runtime TBD" guidance.

Type consistency: `ctr_lo` is consistently the 4-bit slot (low nibble of the 16-bit ctr) across all phases. `flags` in pack_data takes the bitmask of `DATA_FLAG_*` constants. `is_gateway` is a boolean on rt[] candidates and a bit in BCN entry byte 2. `payload_len` in RTS counts bytes after the 6-byte DATA header (= `inner_overhead + body + MAC`).

---

Plan complete. Saved to `docs/superpowers/plans/2026-05-12-wire-format-changes.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, two-stage review (spec compliance, then code quality) between tasks, fast iteration.

2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
