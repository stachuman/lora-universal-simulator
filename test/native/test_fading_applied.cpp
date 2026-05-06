// test/native/test_fading_applied.cpp
//
// Unit test for advanceFading() (Phase R.1, Task R.1.5).
//
// Covers four behaviours:
//   1. i.i.d. mode (snr_coherence_ms == 0) — consecutive draws are
//      independent.
//   2. snr_std_dev == 0 — always returns 0.0f, no random draws.
//   3. OU mode (snr_coherence_ms >> dt) — consecutive draws are
//      correlated; the new offset stays close to the previous one.
//   4. Monte Carlo sanity — i.i.d. samples have empirical mean ~0 and
//      std dev ~snr_std_dev (4.0 dB here).
//
// The actual signature, per core/link/LinkFadingState.h:
//   float advanceFading(LinkFadingState& s,
//                       float    snr_std_dev,
//                       uint64_t snr_coherence_ms,
//                       uint64_t step_ms,         // current time (NOT dt)
//                       std::mt19937& rng);

#include "core/link/LinkFadingState.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <random>

int main() {
    std::mt19937 rng(42);

    // 1) i.i.d. mode (coherence=0): consecutive draws are independent.
    LinkFadingState s_iid{};
    float a = advanceFading(s_iid, 4.0f, /*coh*/0, /*step*/1, rng);
    float b = advanceFading(s_iid, 4.0f, /*coh*/0, /*step*/2, rng);
    assert(a != b);  // very unlikely to be exactly equal

    // 2) zero std_dev → zero offset, regardless of mode.
    LinkFadingState s_zero{};
    float z_iid = advanceFading(s_zero, 0.0f, /*coh*/0,    /*step*/1, rng);
    float z_ou  = advanceFading(s_zero, 0.0f, /*coh*/1000, /*step*/1, rng);
    assert(z_iid == 0.0f);
    assert(z_ou  == 0.0f);

    // 3) OU mode: high coherence and small dt → consecutive draws are
    // correlated (close to each other). The OU helper takes step_ms
    // as an absolute timestamp, so we pass increasing values and rely
    // on the internal `dt = step - last_update` arithmetic.
    LinkFadingState ou{};
    float prev = advanceFading(ou, 4.0f, /*coh*/1000, /*step*/10, rng);
    float curr = advanceFading(ou, 4.0f, /*coh*/1000, /*step*/20, rng);
    // With dt=10 over coherence=1000, alpha = exp(-0.01) ≈ 0.99,
    // sqrt(1 - alpha²) * 4 ≈ 0.566 — small noise term.
    // Loose bound: |curr - prev| should be within 1 std_dev (4 dB).
    // Note: the FIRST OU sample sees dt = step - 0 = 10 (since
    // last_update_ms starts at 0), so prev itself is i.i.d.-like. The
    // SECOND sample is what's correlated to prev. We test the
    // prev→curr transition, not the 0→prev one.
    assert(std::fabs(curr - prev) < 4.0f);

    // 4) Monte Carlo sanity: 1000 i.i.d. draws should have mean ~0 and
    // sigma ~snr_std_dev. Generous tolerances — the test just needs to
    // catch a dropped multiplier or a unit error.
    LinkFadingState s_mc{};
    float sum = 0.0f, sum_sq = 0.0f;
    const int N = 1000;
    for (int i = 0; i < N; ++i) {
        float x = advanceFading(s_mc, 4.0f, /*coh*/0,
                                /*step*/static_cast<uint64_t>(i + 1), rng);
        sum    += x;
        sum_sq += x * x;
    }
    const float mean  = sum / static_cast<float>(N);
    const float var   = sum_sq / static_cast<float>(N) - mean * mean;
    const float sigma = std::sqrt(var);
    // Expected: mean ≈ 0, sigma ≈ 4. Allow generous tolerance.
    assert(std::fabs(mean) < 0.5f);
    assert(sigma > 3.0f && sigma < 5.0f);

    std::printf("test_fading_applied: OK (iid=[%f, %f], ou=[%f -> %f], "
                "mean=%f sigma=%f)\n",
                a, b, prev, curr, mean, sigma);
    return 0;
}
