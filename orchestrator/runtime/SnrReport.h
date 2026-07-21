// orchestrator/runtime/SnrReport.h
// Author: Stanislaw Kozicki <cgpsmapper@gmail.com>
//
// §signal-strength-unification Slice A (2026-07-19): the ONE pure function that shapes
// the SNR a firmware Node SEES to what a real SX126x would REPORT.
//
// The sim's PathLossModel computes the TRUE channel SNR (rx_dbm - noise_floor), which
// for co-located links reaches tens of dB (+82 in s18) — a value no real receiver ever
// reports. A real SX126x SnrPkt register saturates around +10..+13 dB and reports in
// 0.25 dB units (a signed int8: snr = PktSnr/4). This function models that report:
//
//   1. SATURATE to `ceiling_db` (upper bound only). Default caller passes +12.0.
//      A very large ceiling (e.g. 1e9) makes the clamp inert — the A/B-debug escape
//      hatch that recovers the old inflated-SNR behaviour.
//   2. QUANTIZE to the chip's q4 (0.25 dB) grid, ROUNDING to the nearest quarter-dB
//      (the register rounds; not floor). Quantize AFTER clamping.
//
// REPORT-ONLY: this NEVER touches the delivery/collision/demod physics — those run on
// the true channel SNR upstream in SimController, before the report path is reached.
//
// PURE + draw-free: no RNG. The sim's shared mt19937 is draw-order-coupled (one extra
// draw phantom-shifts unrelated scenarios), so the report path MUST make zero draws.

#pragma once

#include <cmath>

namespace mrsim {

inline float shapeReportedSnr(float snr_db, float ceiling_db) {
    if (snr_db > ceiling_db) snr_db = ceiling_db;   // saturate high (report ceiling)
    return std::round(snr_db * 4.0f) / 4.0f;        // quantize to 0.25 dB (q4), nearest
}

}  // namespace mrsim
