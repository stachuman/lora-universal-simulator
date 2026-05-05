// test/native/test_physics.cpp
//
// Native unit test for the protocol-agnostic radio physics extracted from
// meshcore_real_sim/orchestrator/Orchestrator.cpp.

#include "core/physics/CollisionModel.h"
#include "core/physics/LbtModel.h"
#include "core/link/LinkFadingState.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <random>

// SF8 / 62.5 kHz LoRa: t_sym = 256/62.5 ≈ 4.096 ms. Use that as a default.
static constexpr float kTsymMs = 4.096f;
// Preamble = (16 + 4.25) * t_sym ≈ 82.94 ms — matches SimRadio default.
static constexpr float kTpreMs = (16.0f + 4.25f) * kTsymMs;

static void test_collision_clean_no_overlap() {
    CollisionConfig cfg;
    CapturedSignal a{0, 12.0f,   0,  500, 5, 16, kTsymMs, kTpreMs};
    CapturedSignal b{1, 12.0f, 600, 1100, 5, 16, kTsymMs, kTpreMs};
    auto d = evaluateCollision(cfg, a, b);
    assert(d.survived && d.reason_code == 0);
}

static void test_collision_strong_vs_weak_capture() {
    // Strong primary (12 dB) vs weak interferer (5 dB).
    // Both start at 100/110 — preambles overlap, so unlocked threshold (6 dB)
    // applies. 12 - 5 = 7 dB margin → primary captures.
    CollisionConfig cfg;
    CapturedSignal a{0, 12.0f, 100, 500, 5, 16, kTsymMs, kTpreMs};
    CapturedSignal b{1,  5.0f, 110, 510, 5, 16, kTsymMs, kTpreMs};
    auto d = evaluateCollision(cfg, a, b);
    assert(d.survived);
    assert(d.reason_code == 1);  // capture
}

static void test_collision_weak_destroyed() {
    // Weak primary (5 dB), strong interferer (12 dB), heavy overlap → primary
    // is destroyed (no FEC for CR4/5; preamble grace too short with pre=16
    // and lock=6 = 10 sym ≈ 41 ms — interferer lasts much longer than that).
    CollisionConfig cfg;
    CapturedSignal a{0,  5.0f, 100, 500, 5, 16, kTsymMs, kTpreMs};
    CapturedSignal b{1, 12.0f, 110, 510, 5, 16, kTsymMs, kTpreMs};
    auto d = evaluateCollision(cfg, a, b);
    assert(!d.survived);
    assert(d.reason_code == 4);  // destroyed
}

static void test_collision_preamble_grace() {
    // Equal-power signals; interferer ends within primary's non-critical
    // preamble (first pre_sym - lock_sym = 10 symbols ≈ 41 ms).
    // primary [100, 500), interferer [100, 130) → ends at 130 < 100+40 ≈ 141.
    CollisionConfig cfg;
    CapturedSignal a{0, 8.0f, 100, 500, 5, 16, kTsymMs, kTpreMs};
    CapturedSignal b{1, 8.0f, 100, 130, 5, 16, kTsymMs, kTpreMs};
    auto d = evaluateCollision(cfg, a, b);
    assert(d.survived);
    assert(d.reason_code == 2);  // preamble grace
}

static void test_collision_fec_tolerance() {
    // CR4/8 → 1 FEC symbol of tolerance. Place a tiny overlap inside the
    // payload (after t_preamble) shorter than t_sym ≈ 4.096 ms.
    // primary preamble ends at ~83 ms → start payload window at 100+83 = 183.
    // Make interferer overlap [200, 203) — 3 ms < 4.096 ms.
    CollisionConfig cfg;
    CapturedSignal a{0, 8.0f, 100, 500, 8, 16, kTsymMs, kTpreMs};
    CapturedSignal b{1, 8.0f, 200, 203, 8, 16, kTsymMs, kTpreMs};
    auto d = evaluateCollision(cfg, a, b);
    assert(d.survived);
    assert(d.reason_code == 3);  // FEC saved it
}

static void test_lbt_busy_decay() {
    LbtModel lbt(/*n_nodes=*/3);
    assert(!lbt.isChannelBusy(0, 100));
    lbt.notifyChannelBusy(/*observer=*/0, /*sender=*/1, /*until=*/500, /*snr=*/8.0f);
    // While inside the busy window, channel reads busy.
    assert(lbt.isChannelBusy(0, 200));
    // At t=600, the window has expired.
    assert(!lbt.isChannelBusy(0, 600));
    // Other observers are independent.
    assert(!lbt.isChannelBusy(2, 200));
}

static void test_lbt_cad_miss_interpolation() {
    LbtModel lbt(/*n_nodes=*/1);
    // High SNR → miss prob ~= cad_miss_prob (default 0.05).
    float p_high = lbt.effectiveMissProb(/*rx_snr=*/10.0f);
    assert(std::fabs(p_high - 0.05f) < 1e-6f);
    // Below marginal floor → always miss.
    float p_low = lbt.effectiveMissProb(/*rx_snr=*/-20.0f);
    assert(std::fabs(p_low - 1.0f) < 1e-6f);
    // Midway: rx=-7.5 between marginal=-15 and reliable=0 → t=0.5 →
    // miss = 1 - 0.5*(1 - 0.05) = 0.525.
    float p_mid = lbt.effectiveMissProb(/*rx_snr=*/-7.5f);
    assert(std::fabs(p_mid - 0.525f) < 1e-3f);
}

static void test_fading_iid_no_state() {
    LinkFadingState s;
    std::mt19937 rng(0xDEADBEEFu);
    // i.i.d. mode: snr_coherence_ms == 0. State should remain untouched.
    float off = advanceFading(s, /*snr_std_dev=*/2.0f,
                              /*snr_coherence_ms=*/0,
                              /*step_ms=*/100,
                              rng);
    (void)off;  // randomized; just confirm state was not advanced.
    assert(s.last_update_ms == 0);
    assert(s.current_offset_db == 0.0f);

    // Zero std-dev disables fading regardless of regime.
    float zero = advanceFading(s, /*snr_std_dev=*/0.0f,
                               /*snr_coherence_ms=*/1000,
                               /*step_ms=*/200, rng);
    assert(zero == 0.0f);
}

static void test_fading_ou_correlation() {
    LinkFadingState s;
    std::mt19937 rng(0x12345678u);
    // OU mode: large std-dev so we can see correlation. Coherence ~1000ms.
    advanceFading(s, /*snr_std_dev=*/4.0f, /*coherence=*/1000,
                  /*step=*/100, rng);
    float off1 = s.current_offset_db;
    assert(s.last_update_ms == 100);

    advanceFading(s, /*snr_std_dev=*/4.0f, /*coherence=*/1000,
                  /*step=*/110, rng);
    float off2 = s.current_offset_db;
    assert(s.last_update_ms == 110);

    // dt=10 vs coherence=1000 → alpha ≈ 0.99 → off2 should be very close
    // to off1 (heavy correlation).  Allow a generous bound to keep the
    // test deterministic across STL implementations.
    assert(std::fabs(off2 - 0.99f * off1) < 1.0f);
}

int main() {
    test_collision_clean_no_overlap();
    test_collision_strong_vs_weak_capture();
    test_collision_weak_destroyed();
    test_collision_preamble_grace();
    test_collision_fec_tolerance();
    test_lbt_busy_decay();
    test_lbt_cad_miss_interpolation();
    test_fading_iid_no_state();
    test_fading_ou_correlation();
    std::printf("test_physics: OK\n");
    return 0;
}
