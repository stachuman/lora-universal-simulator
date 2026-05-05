#pragma once

// Collision-survival physics for LoRa receptions, lifted from
// meshcore_real_sim/orchestrator/Orchestrator.cpp (function `isDestroyedBy`,
// lines ~230-280, plus the call-site at lines ~575-619 that derives
// `t_sym`, `preamble_grace_ms`, and `fec_tolerance_ms` from the receiver
// radio's parameters).
//
// The decision is a 3-stage tree applied per (primary, interferer) pair:
//   Stage 1: Timing-dependent capture effect.
//            If primary's preamble locked PREAMBLE_LOCK_SYMBOLS symbols
//            before the interferer arrived, the locked threshold applies
//            (typ. 3 dB). Otherwise the unlocked threshold (typ. 6 dB).
//            primary survives if primary.snr >= interferer.snr + threshold.
//   Stage 2: Preamble grace.
//            Primary survives if interferer ends within the non-critical
//            head of primary's preamble (i.e. before
//            rx_start + (pre_sym - PREAMBLE_LOCK_SYMBOLS) * t_sym).
//   Stage 3: FEC overlap tolerance.
//            If overlap is small AND lies entirely within the payload (past
//            the preamble), Hamming/extended-Hamming codes can recover.
//            Tolerance: CR4/5..CR4/6 → 0 sym; CR4/7..CR4/8 → 1 sym.
//
// Notes on the upstream value:
//   PREAMBLE_LOCK_SYMBOLS in Orchestrator.cpp is `6` (line 32). The plan's
//   sketch suggests `5`; the real upstream code uses 6, which we preserve.
//
// MeshCore-specific bookkeeping that lived alongside this physics in the
// source (interferer_idx tracking, snr_margin, EventLog emissions, fate
// counters, link-loss flag, halfduplex_abort) stays out of this unit —
// the caller can attach those decisions on the side.

#include <cstdint>

struct CollisionConfig {
    float capture_locked_db   = 3.0f;
    float capture_unlocked_db = 6.0f;
    int   preamble_lock_symbols = 6;
};

// One LoRa reception captured by a receiver.  All times are in the
// orchestrator/sim time domain (milliseconds).  `cr` is the LoRa coding-rate
// denominator: 5..8 corresponds to CR4/5..CR4/8 (matches SimRadio::getCR()
// returning 1..4 plus 4 — see field doc below).
struct CapturedSignal {
    int      src_node;     // sender index (purely informational)
    float    snr_db;       // sampled SNR at the receiver, post-fading
    uint64_t start_ms;     // RX start (orchestrator clock)
    uint64_t end_ms;       // RX end (start + airtime)
    uint8_t  cr;           // coding-rate denominator: 5..8 (NOT the 1..4
                           // index that SimRadio::getCR() returns; the
                           // caller must add 4 if it has the index form)
    uint16_t pre_sym;      // configured preamble symbols (typ. 16)
    float    t_sym_ms;     // symbol period in ms (= (1<<sf) / (bw_hz/1000))
    float    t_preamble_ms;// total preamble time in ms (pre_sym + 4.25)*t_sym
};

// `reason_code` semantics (lifted from upstream's branch ordering):
//   0 = clean: signals do not overlap in time
//   1 = capture: primary dominated interferer by capture_threshold dB
//   2 = preamble_grace: interferer ended in primary's non-critical preamble
//   3 = fec_tolerance: overlap was small and confined to the payload
//   4 = destroyed: primary failed all three stages
struct CollisionDecision {
    bool survived;
    int  reason_code;
};

// Returns the survival decision for `primary` against `interferer`.
//
// Mirrors the upstream `isDestroyedBy(primary, interferer, ...)` decision
// exactly; survived == !destroyed.  When both signals are present in the
// same step at the same receiver, the orchestrator calls this twice — once
// per direction — to determine which (if either) survives.
CollisionDecision evaluateCollision(const CollisionConfig& cfg,
                                    const CapturedSignal& primary,
                                    const CapturedSignal& interferer);
