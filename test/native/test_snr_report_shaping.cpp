// test/native/test_snr_report_shaping.cpp
// Author: Stanislaw Kozicki <cgpsmapper@gmail.com>
//
// §signal-strength-unification Slice A: unit coverage for the report-SNR shaper
// (mrsim::shapeReportedSnr) — the pure clamp+quantize applied to every SNR a firmware
// Node sees (FirmwareNode::onRecv + ::onPreambleDetected). Locks the contract:
//   - saturate to the ceiling (upper bound only),
//   - quantize to 0.25 dB, ROUNDING to nearest (q4 register model),
//   - a huge ceiling disables the clamp (A/B-debug escape hatch),
//   - the function is PURE (same input -> same output; no hidden state / no RNG).

#include "orchestrator/runtime/SnrReport.h"

#include <cassert>
#include <cmath>
#include <cstdio>

using mrsim::shapeReportedSnr;

static bool approx(float a, float b) { return std::fabs(a - b) < 1e-6f; }

int main() {
    const float CEIL = 12.0f;   // the default caller ceiling

    // --- saturation to the ceiling (the s18/s27 inflation fix) ---------------
    assert(approx(shapeReportedSnr(82.0f, CEIL), 12.0f));   // s18 top-end (+82) flattens to +12
    assert(approx(shapeReportedSnr(55.0f, CEIL), 12.0f));   // s27 "strong" link
    assert(approx(shapeReportedSnr(12.0f, CEIL), 12.0f));   // exactly at the ceiling
    assert(approx(shapeReportedSnr(12.4f, CEIL), 12.0f));   // just above -> clamped first, then quantized

    // --- values below the ceiling pass through, quantized to 0.25 dB --------
    assert(approx(shapeReportedSnr(11.9f, CEIL), 12.0f));   // rounds up to nearest 0.25
    assert(approx(shapeReportedSnr(11.8f, CEIL), 11.75f));  // rounds down to nearest 0.25
    assert(approx(shapeReportedSnr(-11.76f, CEIL), -11.75f)); // s18 bottom-end, nearest quarter
    assert(approx(shapeReportedSnr(0.0f, CEIL), 0.0f));
    assert(approx(shapeReportedSnr(-20.0f, CEIL), -20.0f)); // no lower clamp (window floor is not saturated)
    assert(approx(shapeReportedSnr(3.1f, CEIL), 3.0f));
    assert(approx(shapeReportedSnr(3.13f, CEIL), 3.25f));   // 3.13*4=12.52 -> round 13 -> 3.25

    // --- quantize is ROUND-to-nearest, not floor ----------------------------
    // 7.6 dB: floor would give 7.5; nearest gives 7.5 (7.6*4=30.4 -> 30). 7.7*4=30.8 -> 31 -> 7.75.
    assert(approx(shapeReportedSnr(7.7f, CEIL), 7.75f));
    // A negative value must round to nearest too (not toward zero / not floor).
    assert(approx(shapeReportedSnr(-4.1f, CEIL), -4.0f));   // -4.1*4=-16.4 -> -16 -> -4.0
    assert(approx(shapeReportedSnr(-4.2f, CEIL), -4.25f));  // -4.2*4=-16.8 -> -17 -> -4.25

    // --- huge ceiling disables saturation (A/B-debug escape hatch) ----------
    const float HUGE = 1e9f;
    assert(approx(shapeReportedSnr(82.0f, HUGE), 82.0f));   // quantized-but-not-clamped (82 already on grid)
    assert(approx(shapeReportedSnr(55.3f, HUGE), 55.25f));  // 55.3*4=221.2 -> 221 -> 55.25

    // --- purity: repeated calls are identical, and every output is on the grid
    for (float x = -30.0f; x <= 20.0f; x += 0.013f) {
        const float y1 = shapeReportedSnr(x, CEIL);
        const float y2 = shapeReportedSnr(x, CEIL);
        assert(approx(y1, y2));                     // deterministic
        assert(y1 <= 12.0f + 1e-6f);                // never above the ceiling
        const float grid = y1 * 4.0f;               // must land exactly on the 0.25 grid
        assert(approx(grid, std::round(grid)));
    }

    std::printf("[ok] test_snr_report_shaping: report SNR clamp+quantize contract holds\n");
    return 0;
}
