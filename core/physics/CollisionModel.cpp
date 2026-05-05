#include "core/physics/CollisionModel.h"

#include <algorithm>
#include <cmath>

namespace {

// FEC tolerance in symbols per coding rate (LoRa Hamming codes).
// Upstream Orchestrator.cpp line ~585.
//   CR4/5 (5,4): 1 parity bit, detection only           → 0 sym
//   CR4/6 (6,4): detection only                         → 0 sym
//   CR4/7 (7,4) Hamming: corrects 1 bit/codeword        → 1 sym (interleaved)
//   CR4/8 (8,4) extended Hamming: also 1 bit/codeword   → 1 sym
//                                                          (extra parity = detection)
constexpr int kFecSymTable[4] = {0, 0, 1, 1};

inline int fecSymbolsForCr(uint8_t cr_denom) {
    // cr_denom must be 5..8 (CR4/5..CR4/8). The upstream stores 1..4 in
    // SimRadio::getCR(); the caller is responsible for converting to the
    // denominator form.
    if (cr_denom < 5 || cr_denom > 8) return 0;
    return kFecSymTable[cr_denom - 5];
}

}  // namespace

CollisionDecision evaluateCollision(const CollisionConfig& cfg,
                                    const CapturedSignal& primary,
                                    const CapturedSignal& interferer) {
    // No temporal overlap → no interference (upstream line 242-244).
    if (interferer.end_ms <= primary.start_ms ||
        primary.end_ms   <= interferer.start_ms) {
        return {true, 0};
    }

    const double t_sym = primary.t_sym_ms;

    // Stage 1: Timing-dependent capture.
    // If primary's preamble fully locked before the interferer arrived,
    // the receiver is synchronized → locked threshold applies.
    // Otherwise, classic power-dominance with the unlocked threshold.
    const double lock_time_ms =
        (double)primary.start_ms + cfg.preamble_lock_symbols * t_sym;
    const float capture_threshold =
        ((double)interferer.start_ms >= lock_time_ms)
            ? cfg.capture_locked_db
            : cfg.capture_unlocked_db;

    if (primary.snr_db >= interferer.snr_db + capture_threshold) {
        return {true, 1};  // captured
    }

    // Stage 2: Preamble grace.
    // Primary survives if the interferer's window ends within the
    // non-critical head of primary's preamble — first (pre_sym -
    // preamble_lock_symbols) symbols, before the lock window opens.
    const double preamble_grace_ms =
        ((double)primary.pre_sym - cfg.preamble_lock_symbols) * t_sym;
    if (preamble_grace_ms > 0.0) {
        const uint64_t critical =
            primary.start_ms +
            (uint64_t)std::lround(preamble_grace_ms);
        if (interferer.end_ms <= critical) {
            return {true, 2};  // preamble grace
        }
    }

    // Stage 3: FEC overlap tolerance.
    // If overlap is small AND lies entirely within the payload, Hamming /
    // extended-Hamming codes can recover.  Per upstream, "small" means
    // overlap_ms <= fec_sym * t_sym, "within payload" means overlap starts
    // at or after primary.start_ms + t_preamble_ms.
    const int fec_sym = fecSymbolsForCr(primary.cr);
    if (fec_sym > 0) {
        const double fec_tolerance_ms = fec_sym * t_sym;
        const uint64_t overlap_start =
            std::max(primary.start_ms, interferer.start_ms);
        const uint64_t overlap_end =
            std::min(primary.end_ms, interferer.end_ms);
        const double overlap_ms = (double)(overlap_end - overlap_start);
        if (overlap_ms <= fec_tolerance_ms) {
            const uint64_t payload_start =
                primary.start_ms +
                (uint64_t)std::lround((double)primary.t_preamble_ms);
            if (overlap_start >= payload_start) {
                return {true, 3};  // FEC saved it
            }
        }
    }

    return {false, 4};  // destroyed
}
