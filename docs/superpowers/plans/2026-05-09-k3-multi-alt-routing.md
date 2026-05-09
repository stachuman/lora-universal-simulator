# K=3 Multi-Alt Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize `dv_dual_sf.lua`'s routing table from 2 routes per destination (primary + 1 alt) to K=3 (primary + 2 alts), and add a sequential failure cascade so `rts_giveup` and `ack_giveup` walk through alternatives instead of dropping the message.

**Architecture:** Replace `rt[dst] = {primary, alt}` with `rt[dst] = {candidates}` — a sorted list of up to K=3 routes. `rt_merge` maintains top-K. The `pending_tx.alt_tried` boolean becomes a `pending_tx.alts_tried` set keyed by next-hop id. On `rts_giveup` or `data_ack_giveup`, look up the next non-tried candidate from `rt[dst].candidates`; switch + retry. After all K tried, emit `path_cascade_exhausted` and become_free.

**Tech Stack:** Lua 5.x (`scenarios/dv_dual_sf.lua` is a single ~2700-line file), JSON test scenarios.

**Spec:** `docs/superpowers/specs/2026-05-09-k3-multi-alt-routing-design.md`

**Prerequisite:** `docs/superpowers/plans/2026-05-09-node-lifecycle.md` must be implemented first (the cascade test in Task 7 uses `dies_at_ms`).

---

## File Structure

| Path | Action | Purpose |
|---|---|---|
| `scenarios/dv_dual_sf.lua` | Modify | Refactor rt structure, rt_merge, classify_blind, pending_tx field, rts_giveup + data_ack_giveup cascade. Update header docstring. |
| `test/t26_k3_cascade.json` | Create | Integration test: 5-node mesh, primary forwarder dies mid-flight, cascade falls through to alt. |

The whole feature lives in one Lua file. The test scenario depends on the kill-node feature from the sibling plan.

---

## Constants and naming

Tasks below use these names consistently:

- `MAX_RT_CANDIDATES = 3` — K. Hardcoded local at top of `dv_dual_sf.lua` (near the other `local function`s like `airtime_ms`).
- `entry.candidates` — sorted list (descending by score) of up to K route entries. Each entry has the same shape as today's `primary` / `alt`: `{next_hop, score, hops, last_seen_ms, n2_hop, ...}`. Length 1..K.
- `entry.candidates[1]` — the current primary (highest score).
- `pending_tx.alts_tried` — Lua table used as a set: keys are next-hop ids that have been tried for THIS pending_tx; values are `true`. Replaces today's `alt_tried` boolean.

Existing comparator `route_strictly_better(cand, current, viab_db)` is reused unchanged.

---

## Task 1: Refactor `rt[dst]` data layout — primary/alt → candidates list

This is the foundation. Mechanical rename across all readers/writers; no behavior change yet (top-K logic comes in Task 2; cascade in Tasks 5-6).

**Files:**
- Modify: `scenarios/dv_dual_sf.lua`

**Touched call sites** (find by `grep -n "entry\.primary\|entry\.alt\|\.primary\|\.alt\b" scenarios/dv_dual_sf.lua`):

| Function / context | Line range (approx) | What changes |
|---|---|---|
| Header docstring | 220-263 | Update prose to describe `candidates` list |
| `pack_beacon` | 462-475 | `node.rt[dest_id].primary` → `node.rt[dest_id].candidates[1]` |
| `classify_blind` | 800-822 | Walk candidates list (full rewrite — see Task 3) |
| `rt_merge` | 1037-1080 | Full rewrite — see Task 2 |
| 3-cycle prune (`prune_two_hop_via`) | 1115-1155 | Walk + remove from candidates list |
| `issue_send` | 1485-1494 | `entry.primary.next_hop` → `entry.candidates[1].next_hop` |
| Forward-path lookup | 2580-2585 | `self.rt[d_dst]` (just an existence check — no change) |

- [ ] **Step 1.1: Update the header docstring**

In `scenarios/dv_dual_sf.lua` find this block (around lines 227-240):

```lua
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
```

Replace with:

```lua
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
```

- [ ] **Step 1.2: Add `MAX_RT_CANDIDATES` constant near `airtime_ms`**

Find `local function airtime_ms` (around line 687). Just before it, add:

```lua
-- Maximum number of routes per destination kept in the routing table.
-- candidates[1] is the current primary; candidates[2..K] are alts
-- consulted by classify_blind (blind-window mitigation) and the
-- failure cascade in rts_timeout_fire / ack_timeout_fire.
local MAX_RT_CANDIDATES = 3
```

- [ ] **Step 1.3: Update `pack_beacon` to read from candidates[1]**

Find (around line 467):

```lua
    local p = node.rt[dest_id].primary
```

Replace with:

```lua
    local p = node.rt[dest_id].candidates[1]
```

- [ ] **Step 1.4: Update `issue_send`'s primary lookup**

Find (around line 1494):

```lua
  local primary_next = entry.primary.next_hop
```

Replace with:

```lua
  local primary_next = entry.candidates[1].next_hop
```

- [ ] **Step 1.5: Stub `rt_merge` to populate the new shape (Task 2 generalizes)**

Find the `rt_merge` function (around line 1037). For now, replace the body with a minimal version that preserves K=2 behavior using the new shape:

```lua
local function rt_merge(rt, dest_id, cand, viab_db)
  local entry = rt[dest_id]
  if entry == nil then
    rt[dest_id] = { candidates = { cand } }
    return "new"
  end
  -- Check for match by next_hop in any slot.
  for i, c in ipairs(entry.candidates) do
    if c.next_hop == cand.next_hop then
      if route_strictly_better(cand, c, viab_db) then
        entry.candidates[i] = cand
        -- Re-sort by score descending.
        table.sort(entry.candidates, function(a, b)
          return route_strictly_better(a, b, 0.0)
        end)
        if i == 1 or entry.candidates[1].next_hop == cand.next_hop then
          return "primary_refresh"
        end
        return "alt_install"
      end
      c.last_seen_ms = cand.last_seen_ms
      c.n2_hop       = cand.n2_hop
      return "no_change"
    end
  end
  -- New next_hop. Insert + sort + truncate to K.
  table.insert(entry.candidates, cand)
  table.sort(entry.candidates, function(a, b)
    return route_strictly_better(a, b, 0.0)
  end)
  -- Did the new candidate become primary?
  local promoted = (entry.candidates[1].next_hop == cand.next_hop)
  -- Truncate to K.
  while #entry.candidates > MAX_RT_CANDIDATES do
    entry.candidates[#entry.candidates] = nil
  end
  -- If after truncation cand is no longer in the list, return no_change.
  local kept = false
  for _, c in ipairs(entry.candidates) do
    if c.next_hop == cand.next_hop then kept = true; break end
  end
  if not kept then return "no_change" end
  if promoted then return "promote" end
  return "alt_install"
end
```

(Task 2 will refine this with proper viab_db handling and clearer return values, but this lands the data shape.)

- [ ] **Step 1.6: Update `prune_two_hop_via` to walk the candidates list**

Find the function around line 1115. Today it looks at `entry.primary` and `entry.alt` separately. Replace its body with logic that filters the candidates list:

```lua
local function prune_two_hop_via(self, sender_id)
  for dest_id, entry in pairs(self.rt) do
    local removed_any = false
    local kept = {}
    for _, c in ipairs(entry.candidates) do
      if c.n2_hop == sender_id then
        self:emit("rt_prune_2hop", {
          dest = dest_id, via = c.next_hop, n2 = sender_id,
        })
        self:log(string.format("rt_prune_2hop dest=%s via=%s n2=%s",
          name_of(self, dest_id),
          name_of(self, c.next_hop), name_of(self, sender_id)))
        removed_any = true
      else
        table.insert(kept, c)
      end
    end
    if removed_any then
      entry.candidates = kept
      if #entry.candidates == 0 then
        self.rt[dest_id] = nil
      end
    end
  end
end
```

(Original semantics: prune any candidate whose 2-hop passes through `sender_id`. The new code does the same, just in a list-walk shape.)

- [ ] **Step 1.7: Update `classify_blind` to walk candidates (interim — Task 3 generalizes for cascade)**

Find around line 803:

```lua
local function classify_blind(self, dst_id, current_next_hop, alt_already_tried, previous_hop)
  local blind, remaining = is_blind(self, current_next_hop)
  if not blind then return "ok" end
  local entry = self.rt[dst_id]
  local alt = entry and entry.alt or nil
  if alt and (not alt_already_tried) and (not is_blind(self, alt.next_hop))
     and alt.next_hop ~= previous_hop then
    return "alt", alt.next_hop
  end
  return "defer", remaining
end
```

Replace with:

```lua
local function classify_blind(self, dst_id, current_next_hop, alt_already_tried, previous_hop)
  local blind, remaining = is_blind(self, current_next_hop)
  if not blind then return "ok" end
  if alt_already_tried then return "defer", remaining end
  local entry = self.rt[dst_id]
  if not entry then return "defer", remaining end
  -- Walk candidates 2..K (skip the current primary at index 1 and any
  -- candidate matching current_next_hop, in case current_next_hop is
  -- not the primary).
  for _, c in ipairs(entry.candidates) do
    if c.next_hop ~= current_next_hop
       and c.next_hop ~= previous_hop
       and not is_blind(self, c.next_hop) then
      return "alt", c.next_hop
    end
  end
  return "defer", remaining
end
```

(Note: the `alt_already_tried` boolean stays for now; Task 4 replaces it with the `alts_tried` set.)

- [ ] **Step 1.8: Build + run the full integration suite**

The change so far is pure refactoring — no behavior change. All existing tests should pass.

```bash
bash test/run_tests.sh
```

Expected: 32/32 passed (assuming Plan 1 has landed; if running Plan 2 standalone, 30/30). If anything fails, the refactor missed a `entry.primary` / `entry.alt` reader. Re-grep:

```bash
grep -n "entry\.primary\|entry\.alt\|\.primary\b\|\.alt\b" scenarios/dv_dual_sf.lua | grep -v "^--"
```

Any non-comment hit indicates a missed call site.

- [ ] **Step 1.9: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
refactor(dv_dual_sf): rt[dst] = {candidates} list (no behavior change)

Replace the old rt[dst] = {primary, alt} shape with a sorted
candidates list (length 1..K). Behavior is preserved at K=2 for
this commit; Task 2 generalizes rt_merge to top-K and Task 3
refines classify_blind. Subsequent tasks add the failure cascade
on rts_giveup / data_ack_giveup that consumes the new alt slots.

Touched: pack_beacon (read primary), classify_blind (walk list),
rt_merge (rebuilt), prune_two_hop_via (filter list), issue_send
(read primary), header docstring.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Generalize `rt_merge` for top-K with proper viab_db handling

Task 1's stub uses `viab_db = 0.0` in the table.sort comparator, which is too loose. This task tightens the comparator and refines return values.

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` (rt_merge body)

- [ ] **Step 2.1: Tighten the rt_merge comparator and return values**

Replace the rt_merge body from Task 1.5 with:

```lua
local function rt_merge(rt, dest_id, cand, viab_db)
  local entry = rt[dest_id]
  if entry == nil then
    rt[dest_id] = { candidates = { cand } }
    return "new"
  end

  -- Match-by-next_hop: refresh in place.
  for i, c in ipairs(entry.candidates) do
    if c.next_hop == cand.next_hop then
      if route_strictly_better(cand, c, viab_db) then
        entry.candidates[i] = cand
        local was_primary = (i == 1)
        -- Re-sort and detect promotion / demotion.
        table.sort(entry.candidates, function(a, b)
          return route_strictly_better(a, b, viab_db) or
                 (not route_strictly_better(b, a, viab_db) and a.score > b.score)
        end)
        local now_primary = (entry.candidates[1].next_hop == cand.next_hop)
        if now_primary then
          return "primary_refresh"
        elseif was_primary then
          return "promote"  -- some other entry is now primary
        end
        return "alt_install"
      end
      c.last_seen_ms = cand.last_seen_ms
      c.n2_hop       = cand.n2_hop
      return "no_change"
    end
  end

  -- New next_hop.
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

  -- Full table — replace the worst (last in sorted order) only if
  -- cand strictly beats it.
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
```

The trick in the comparator: `route_strictly_better` requires a margin (`viab_db`) so it returns false on ties. To get a stable total order for sorting we add the `a.score > b.score` tie-breaker — keeps the comparator transitive while preserving the strict-better semantics for promotion decisions.

- [ ] **Step 2.2: Run integration tests — all should still pass**

```bash
bash test/run_tests.sh
```

Expected: still 32/32 (or 30/30). The new merge logic admits up to 3 candidates per dst now, but no scenario relies on K=2 vs K=3 outcomes — the existing tests all use convergence-correct topologies.

- [ ] **Step 2.3: Smoke-check that K=3 actually populates on a dense scenario**

```bash
./build/orchestrator/lus scenarios/s04_seattle_dense.json /tmp/s04_k3.ndjson 2>&1 | tail -2
grep '"emit_type":"rt_full"' /tmp/s04_k3.ndjson | head -3
```

The rt_full event fires after convergence. Pick one; the underlying rt[] table is internal to scripts but the `peers` count should match the scenario's node count. (No new assertion — just a sanity look that the protocol still converges.)

- [ ] **Step 2.4: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(dv_dual_sf): rt_merge maintains top-3 candidates per dst

Generalizes rt_merge to handle K=MAX_RT_CANDIDATES (currently 3)
candidates per destination instead of just primary + 1 alt.

- Match-by-next_hop refreshes in place; re-sort, return based on
  whether the refreshed slot is now (or was) primary.
- New next_hop + room: insert + sort.
- New next_hop + full: replace worst only if strictly better.

Sort uses route_strictly_better with viab_db plus a score
tie-breaker to keep the comparator transitive.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: classify_blind walks all alts and respects alts_tried

`classify_blind` today still takes `alt_already_tried` (boolean). To support the cascade, it needs to skip ALL already-tried next-hops, not just one.

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` (classify_blind signature + body, callers)

- [ ] **Step 3.1: Change classify_blind signature**

Replace the function (the version from Task 1.7 — find the version with `alt_already_tried` parameter):

```lua
local function classify_blind(self, dst_id, current_next_hop, alts_tried, previous_hop)
  local blind, remaining = is_blind(self, current_next_hop)
  if not blind then return "ok" end
  local entry = self.rt[dst_id]
  if not entry then return "defer", remaining end
  -- Walk candidates list; skip the current next-hop, the previous_hop
  -- (loop guard), any next-hop already tried for this pending_tx, and
  -- any candidate currently in a blind window.
  for _, c in ipairs(entry.candidates) do
    if c.next_hop ~= current_next_hop
       and c.next_hop ~= previous_hop
       and not (alts_tried and alts_tried[c.next_hop])
       and not is_blind(self, c.next_hop) then
      return "alt", c.next_hop
    end
  end
  return "defer", remaining
end
```

Note the parameter rename: `alt_already_tried` → `alts_tried` (now expected to be a table-as-set, not a boolean).

- [ ] **Step 3.2: Update callers**

Find all four call sites of `classify_blind`:

```bash
grep -n "classify_blind(" scenarios/dv_dual_sf.lua
```

Expected hits at approximately:
- Line 1171 (`tx_rts_retry`)
- Line 1235 (`rts_timeout_fire`)
- Line 1500 (`issue_send`)
- (and possibly one more — verify by greping)

For each, the third positional argument is the boolean `alt_tried`. **Adapt for now to wrap it as a set:** if the caller passes `false`, pass `{}`; if `true`, pass `{ [px.next] = true }`. This keeps semantics until Task 4 makes the field-level change.

Example transform at line 1171 (`tx_rts_retry`):

```lua
  local action_b, val_b = classify_blind(self, px.dst, px.next, px.alt_tried,
                                          px.previous_hop)
```

becomes:

```lua
  local alts_tried_set = px.alt_tried and { [px.next] = true } or {}
  local action_b, val_b = classify_blind(self, px.dst, px.next, alts_tried_set,
                                          px.previous_hop)
```

Apply the analogous wrap at every call site. This is intentional intermediate-state code; Task 4 unifies on a real `alts_tried` field on `pending_tx` and removes the wrappers.

- [ ] **Step 3.3: Run integration tests**

```bash
bash test/run_tests.sh
```

Expected: 32/32 (or 30/30) — no behavior change yet.

- [ ] **Step 3.4: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
refactor(dv_dual_sf): classify_blind walks K candidates, takes set

classify_blind now walks the full candidates list and skips
already-tried next-hops via a set parameter (alts_tried). Callers
wrap their boolean alt_tried as a single-entry set for now;
Task 4 promotes alts_tried to a real pending_tx field.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Replace `pending_tx.alt_tried` boolean with `alts_tried` set

**Files:**
- Modify: `scenarios/dv_dual_sf.lua`

- [ ] **Step 4.1: Find every occurrence of `alt_tried`**

```bash
grep -n "alt_tried" scenarios/dv_dual_sf.lua
```

Expected hits include (line numbers approximate; verify):
- Pending_tx initialization in `issue_send` — sets `alt_tried = false`.
- Reads in `tx_rts_retry`, `rts_timeout_fire`, `issue_send` (the wrappers from Task 3.2).
- Writes in `tx_rts_retry`, `rts_timeout_fire` — set to `true` when alt-switch happens.
- Header docstring at lines 290-291 (mentions `alt_tried clears on successful delivery`).

- [ ] **Step 4.2: Convert initialization**

In `issue_send`, find the pending_tx struct creation. Find:

```lua
    alt_tried = false,
```

Replace with:

```lua
    alts_tried = {},  -- set keyed by next_hop id; populated as cascade fires
```

- [ ] **Step 4.3: Convert writes**

For every write of the form `pending_tx.alt_tried = true` or `px.alt_tried = true`, replace with adding the current next-hop to the set:

```lua
    px.alts_tried[px.next] = true  -- mark current next-hop as tried
```

The exact spots are immediately after the alt-switch (before changing `px.next` to the new alt). Around lines 1191 (`tx_rts_retry`), 1271 (`rts_timeout_fire`).

- [ ] **Step 4.4: Convert reads in classify_blind callers**

Replace the `alts_tried_set` wrap from Task 3.2 with direct field reads:

```lua
  local action_b, val_b = classify_blind(self, px.dst, px.next, px.alts_tried,
                                          px.previous_hop)
```

(Drop the wrapper variable.)

- [ ] **Step 4.5: Update header docstring**

Find around line 290-291:

```lua
--   • alt_tried clears on successful delivery (pending_tx → nil via on_recv
--     "K"); fresh send via issue_send always sets alt_tried=false.
```

Replace with:

```lua
--   • alts_tried is the set of next-hops already attempted for this
--     pending_tx; cleared implicitly on successful delivery (pending_tx
--     → nil via on_recv "K") or new send (issue_send creates a fresh
--     empty set).
```

- [ ] **Step 4.6: Run integration tests**

```bash
bash test/run_tests.sh
```

Expected: 32/32 (or 30/30).

- [ ] **Step 4.7: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
refactor(dv_dual_sf): pending_tx.alt_tried (bool) -> alts_tried (set)

Field-level change so the failure cascade in Tasks 5-6 can record
multiple already-tried next-hops on a single pending_tx. classify_blind
already takes a set; this commit removes the per-callsite wrappers.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Cascade on `rts_giveup` instead of dropping

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` (`rts_timeout_fire`, around lines 1218-1303)

The current rts_giveup path drops the message after `retries_left <= 0`. Replace with: try the next non-tried candidate; if exhausted, emit `path_cascade_exhausted` and giveup as before.

- [ ] **Step 5.1: Add helper function near `tx_rts_retry`**

Just above the existing `tx_rts_retry` definition (around line 1162), add:

```lua
-- Look up the next non-tried, non-blind candidate for this pending_tx
-- destination. Returns the next_hop id if found, or nil if every
-- candidate has been tried / is blind / is the upstream we came from.
-- Used by the failure cascade in rts_timeout_fire and ack_timeout_fire
-- to walk through K=3 alternatives.
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
```

- [ ] **Step 5.2: Replace rts_giveup branch with cascade**

Find the rts_giveup branch in `rts_timeout_fire` (around lines 1277-1283):

```lua
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
```

Replace with:

```lua
  if self.pending_tx.retries_left <= 0 then
    -- Failure cascade: mark current next-hop tried, walk to next
    -- non-tried candidate. If found, switch + reset retries. Else
    -- emit path_cascade_exhausted + rts_giveup (legacy event for
    -- compatibility) and clear pending_tx.
    self.pending_tx.alts_tried[self.pending_tx.next] = true
    local next_hop = pick_next_cascade_hop(self, self.pending_tx)
    if next_hop ~= nil then
      local prev_next = self.pending_tx.next
      self:emit("path_cascade", {
        origin = self.pending_tx.origin,
        payload = self.pending_tx.user_text,
        origin_seq = self.pending_tx.origin_seq,
        dst = self.pending_tx.dst, msg_id = captured_msg_id,
        from_next = prev_next, to_next = next_hop,
        attempt = (function()
          local n = 0
          for _ in pairs(self.pending_tx.alts_tried) do n = n + 1 end
          return n
        end)(),
        trigger = "rts_giveup",
      })
      self:log(string.format("path_cascade msg=%d %s -> %s (rts_giveup)",
        captured_msg_id, name_of(self, prev_next), name_of(self, next_hop)))
      self.pending_tx.next         = next_hop
      self.pending_tx.retries_left = self.rts_max_retries
      tx_rts_retry(self, "cascade_rts")
      return
    end
    -- Exhausted.
    local tried_list = {}
    for nh, _ in pairs(self.pending_tx.alts_tried) do
      table.insert(tried_list, nh)
    end
    self:emit("path_cascade_exhausted", {
      origin     = self.pending_tx.origin,
      payload    = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      dst        = self.pending_tx.dst, msg_id = captured_msg_id,
      tried      = tried_list,
    })
    self:emit("rts_giveup", {
      origin     = self.pending_tx.origin,
      payload    = self.pending_tx.user_text,
      origin_seq = self.pending_tx.origin_seq,
      dst        = self.pending_tx.dst,
      next       = self.pending_tx.next,
      msg_id     = captured_msg_id,
    })
    self:log(string.format("path_cascade_exhausted msg=%d dst=%s tried=%d",
      captured_msg_id, name_of(self, self.pending_tx.dst), #tried_list))
    self.pending_tx = nil
    become_free(self)
    return
  end
```

- [ ] **Step 5.3: Run integration tests**

```bash
bash test/run_tests.sh
```

Expected: 32/32 (or 30/30). No existing scenario forces an rts_giveup with viable alts present, so the cascade branch shouldn't change any current outcome.

- [ ] **Step 5.4: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(dv_dual_sf): cascade through alts on rts_giveup (K=3)

When the primary next-hop's RTS budget exhausts, instead of
dropping the message, walk the candidates list for the next
non-tried, non-blind, non-upstream alternative. Emit path_cascade
with attempt count + trigger; switch pending_tx.next; reset
retries; tx_rts_retry. After all K candidates fail, emit
path_cascade_exhausted alongside the legacy rts_giveup event and
clear pending_tx (true giveup).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Cascade on `data_ack_giveup`

Same pattern as Task 5, but in `ack_timeout_fire` (around lines 1320-1348).

**Files:**
- Modify: `scenarios/dv_dual_sf.lua` (`ack_timeout_fire`)

- [ ] **Step 6.1: Replace data_ack_giveup branch with cascade**

Find (around lines 1334-1347):

```lua
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
```

Replace with:

```lua
  if self.pending_tx.retries_left <= 0 then
    -- Failure cascade — same logic as the rts_timeout giveup branch
    -- but triggered by ack-loss. Walk the candidates list for a
    -- non-tried alternative; emit path_cascade or path_cascade_exhausted.
    self.pending_tx.alts_tried[self.pending_tx.next] = true
    local next_hop = pick_next_cascade_hop(self, self.pending_tx)
    if next_hop ~= nil then
      local prev_next = self.pending_tx.next
      self:emit("path_cascade", {
        origin = self.pending_tx.origin,
        payload = self.pending_tx.user_text,
        origin_seq = self.pending_tx.origin_seq,
        dst = self.pending_tx.dst, msg_id = captured_msg_id,
        from_next = prev_next, to_next = next_hop,
        attempt = (function()
          local n = 0
          for _ in pairs(self.pending_tx.alts_tried) do n = n + 1 end
          return n
        end)(),
        trigger = "ack_giveup",
      })
      self:log(string.format("path_cascade msg=%d %s -> %s (ack_giveup)",
        captured_msg_id, name_of(self, prev_next), name_of(self, next_hop)))
      self.pending_tx.next         = next_hop
      self.pending_tx.retries_left = self.rts_max_retries
      -- Restart the dance from RTS on the new next-hop.
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
      tried      = tried_list,
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
```

- [ ] **Step 6.2: Run integration tests**

```bash
bash test/run_tests.sh
```

Expected: 32/32 (or 30/30).

- [ ] **Step 6.3: Commit**

```bash
git add scenarios/dv_dual_sf.lua
git commit -m "$(cat <<'EOF'
feat(dv_dual_sf): cascade through alts on data_ack_giveup (K=3)

Mirrors the rts_giveup cascade: when a DATA flight gives up after
ack-timeout retries, walk the candidates list for the next
alternative and restart the dance from RTS. Emits path_cascade
or path_cascade_exhausted alongside the legacy data_ack_giveup
event.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Integration test — K=3 cascade with kill-node

Depends on Plan 1's `dies_at_ms` feature being in place.

**Files:**
- Create: `test/t26_k3_cascade.json`

- [ ] **Step 7.1: Create the scenario**

The test needs a topology where alice has 3 distinct next-hops to dave (so the routing table populates 3 candidates) and the primary forwarder dies mid-flight.

Create `test/t26_k3_cascade.json`:

```json
{
  "_name": "t26_k3_cascade",
  "_desc": "K=3 cascade test. alice has 3 separate 1-hop relays to dave (relay1=best, relay2, relay3). relay1 dies at t=25000, forcing alice's pending tx to cascade to relay2. Cascade exhaust = path_cascade_exhausted; here only one cascade step is needed (msg1) — both relays alive when msg1 sends but relay1 has just died.",
  "simulation": {
    "duration_ms": 60000,
    "step_ms": 1,
    "warmup_ms": 0,
    "seed": 42,
    "node_startup_jitter_ms": 0,
    "radio": { "sf": 8, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice",  "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 10, "allowed_data_sfs": [8,9,10], "beacon_period_ms": 5000 } },
    { "name": "relay1", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 10, "allowed_data_sfs": [8,9,10], "beacon_period_ms": 5000 },
      "dies_at_ms": 25000 },
    { "name": "relay2", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 10, "allowed_data_sfs": [8,9,10], "beacon_period_ms": 5000 } },
    { "name": "relay3", "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 10, "allowed_data_sfs": [8,9,10], "beacon_period_ms": 5000 } },
    { "name": "dave",   "script": "scenarios/dv_dual_sf.lua",
      "config": { "routing_sf": 10, "allowed_data_sfs": [8,9,10], "beacon_period_ms": 5000 } }
  ],
  "topology": {
    "links": [
      { "from": "alice",  "to": "relay1", "snr": 12.0, "rssi": -78.0, "bidir": true },
      { "from": "alice",  "to": "relay2", "snr": 10.0, "rssi": -82.0, "bidir": true },
      { "from": "alice",  "to": "relay3", "snr":  8.0, "rssi": -86.0, "bidir": true },
      { "from": "relay1", "to": "dave",   "snr": 12.0, "rssi": -78.0, "bidir": true },
      { "from": "relay2", "to": "dave",   "snr": 10.0, "rssi": -82.0, "bidir": true },
      { "from": "relay3", "to": "dave",   "snr":  8.0, "rssi": -86.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 27000, "node": "alice", "command": "send dave msg1 cascade-test" }
  ],
  "expect": [
    { "type": "event_count",         "event_type": "node_died", "count": 1 },
    { "type": "script_emit_contains","node": "dave",  "emit_type": "delivered", "value": "msg1" },
    { "type": "script_emit_contains","node": "alice", "emit_type": "path_cascade", "value": "" }
  ]
}
```

The link SNRs are tuned so relay1 is the strict primary (highest score), relay2 is alt1, relay3 is alt2 — DV converges to that order during 25 s of pre-traffic time. The send fires at t=27000 (after relay1 has died at t=25000), so alice's first RTS goes to relay1, gets no CTS, retries hit the budget, cascade fires, switches to relay2, delivers.

- [ ] **Step 7.2: Run**

```bash
bash test/run_tests.sh test/t26_k3_cascade.json
```

Expected: `t26_k3_cascade ... PASS`. The three assertions match: relay1 died, msg1 delivered, alice fired path_cascade.

If the test fails on the path_cascade assertion, alice's RTS to relay1 might be succeeding before the cascade fires (relay1 is dead but in-flight TX from relay1 might leak — confirm Plan 1 Task 3.3 cleared `_in_flight` on death). Cross-check by inspecting `test/t26_k3_cascade_events.ndjson`.

- [ ] **Step 7.3: Commit**

```bash
git add test/t26_k3_cascade.json
git commit -m "$(cat <<'EOF'
test(t26): K=3 cascade integration test using dies_at_ms

5-node mesh: alice has 3 parallel relays to dave. relay1 dies at
t=25000; alice sends at t=27000. RTS to dead relay1 hits its retry
budget, path_cascade fires switching to relay2, delivery succeeds.

Asserts: node_died fires once, dave received msg1, alice emitted
at least one path_cascade event.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Verify no regressions

This task runs only — no code changes.

- [ ] **Step 8.1: Full integration suite**

```bash
bash test/run_tests.sh
```

Expected: 33/33 passed (was 32 from Plan 1 + 1 for t26). All previous tests still pass.

- [ ] **Step 8.2: Native C++ tests**

```bash
bash test/native/build_test.sh
```

Expected: all pass.

- [ ] **Step 8.3: Webapp pytest suite**

```bash
cd webapp && python -m pytest tests/ -q
```

Expected: all green.

- [ ] **Step 8.4: Quality check on s04**

```bash
cd "$(git rev-parse --show-toplevel)"
./tools/analyze.py ./scenarios/s04_seattle_dense.json --run 2>&1 | sed -n '/=== headline/,$p; /=== (1)/,/=== (2)/p' | head -25
```

Expected: delivery rate ≥ 94% (the level after the prior NACK fix). Mean Δ should not regress meaningfully. Some additional scenarios may now show `path_cascade` events for transient failures — the cascade's expected to help, not hurt.

If delivery rate regresses below 94%, investigate before declaring done. Possible cause: the cascade is firing in cases where waiting was the right move (e.g., a transient blind-window).

No commit needed for this task.

---

## Self-Review Notes

- **Spec coverage:** Routing-table layout (Task 1), rt_merge top-K (Task 2), classify_blind walks list (Task 3), pending_tx field (Task 4), rts_giveup cascade (Task 5), data_ack_giveup cascade (Task 6), integration test (Task 7), regression checks (Task 8). All spec sections covered.
- **Out of scope per spec:** configurable K (hardcoded 3), parallel forwarding, beacon-advertised alts, requeue-on-exhaustion — none appear in this plan, matching the spec's "Out of scope" list.
- **No placeholders:** All commands, code blocks, file paths, and expected outputs are concrete. The mechanical refactor in Task 1 calls out a `grep` to verify completeness.
- **Type consistency:** `MAX_RT_CANDIDATES` declared in Task 1.2; `entry.candidates` introduced in Task 1.5 and used through; `pending_tx.alts_tried` introduced in Task 4 and used in Tasks 5/6; `pick_next_cascade_hop` defined in Task 5.1 and used in Tasks 5/6.
- **Frequent commits:** 7 commits across 8 tasks (Task 8 is verification-only). Each commit is independently buildable + green (the protocol behavior at intermediate commits is K=2-equivalent until the cascade lands in Tasks 5/6).
- **Caveat on the comparator in Task 2:** the table.sort comparator combines `route_strictly_better` with a score tie-breaker. Edge cases where `route_strictly_better(a, b, viab) == route_strictly_better(b, a, viab) == false` AND `a.score == b.score` will get unstable order from sort, but Lua's table.sort doesn't crash on a non-strict comparator — just produces undefined order between equal elements. That's acceptable for a routing table.
