#pragma once

// Per-link fading state, lifted from
// meshcore_real_sim/orchestrator/Orchestrator.cpp lines ~462-488 (the
// rx_snr sampling block in `registerTransmissions`).
//
// Two regimes:
//
//   snr_coherence_ms == 0  →  i.i.d. Gaussian fading.
//                              rx_snr = N(mean=lp.snr, std=lp.snr_std_dev).
//                              Per-step independence; LinkFadingState is
//                              ignored.
//
//   snr_coherence_ms >  0  →  Ornstein-Uhlenbeck (continuous-time AR(1))
//                              correlated fading. Consecutive receptions on
//                              the same link see correlated SNR.  The state
//                              persists across calls.
//
// Upstream stores ONE state per UNDIRECTED link (n*(n-1)/2 slots, reciprocal
// fading). This header is just the per-state primitive; callers decide how
// to index — directed (n*n) or symmetric (n*(n-1)/2).
//
// The OU update (upstream lines 472-482):
//     dt        = current_ms - last_ms
//     alpha     = exp(-dt / coherence_ms)
//     alpha_sq  = clamp(alpha*alpha, 0, 1)        // float guard
//     offset'   = alpha * offset + sqrt(1 - alpha_sq) * snr_std_dev * N(0,1)
//     return mean(offset)  // caller adds to lp.snr
//
// This expresses an AR(1) with correlation exp(-dt/coherence_ms) and a
// stationary distribution N(0, snr_std_dev^2), so the per-step output
// matches the i.i.d. case in the dt → infinity limit.

#include <cstdint>
#include <random>

struct LinkFadingState {
    float    current_offset_db = 0.0f;  // upstream `offset`
    uint64_t last_update_ms    = 0;     // upstream `last_ms`
};

// Advance one step of the fading process and return the SNR offset (dB)
// to add to the link's mean SNR for this reception.
//
//   s                  in/out — OU state for this link (ignored when
//                                snr_coherence_ms == 0, but always safe to pass)
//   snr_std_dev        per-link Gaussian standard deviation
//   snr_coherence_ms   0 → i.i.d. Gaussian; >0 → O-U with this correlation time
//   step_ms            current orchestrator timestamp (NOT a delta — upstream
//                       uses the current_ms value and stores it in last_ms)
//   rng                simulator's PRNG (mt19937)
//
// Returns 0.0f when snr_std_dev <= 0 (no fading). Otherwise returns the
// offset to add to the link's nominal SNR.
float advanceFading(LinkFadingState& s,
                    float snr_std_dev,
                    uint64_t snr_coherence_ms,
                    uint64_t step_ms,
                    std::mt19937& rng);
