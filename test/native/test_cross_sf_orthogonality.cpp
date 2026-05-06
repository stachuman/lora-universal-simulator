// test/native/test_cross_sf_orthogonality.cpp
//
// Native unit test for cross-SF quasi-orthogonality in CollisionModel.
//
// LoRa transmissions on the same channel using different spreading factors
// can be demodulated independently by their respective receivers (Croce
// et al. 2018), so they do not collide. evaluateCollision must early-return
// "clean" when primary.sf != interferer.sf, BEFORE running the existing
// 3-stage capture/grace/FEC decision tree.
//
// Asserts both directions:
//   (negative regression check) same-SF, low SNR margin → still collides
//   (positive new behavior)     cross-SF (SF7 vs SF10) overlap → survives

#include "core/physics/CollisionModel.h"

#include <cassert>
#include <cstdio>

// SF7 / 250 kHz: t_sym = 128/250 = 0.512 ms, preamble (8+4.25)*t_sym ≈ 6.27 ms
static constexpr float kTsymMs_SF7  = 0.512f;
static constexpr float kTpreMs_SF7  = (8.0f + 4.25f) * kTsymMs_SF7;

// SF10 / 250 kHz: t_sym = 1024/250 = 4.096 ms, preamble ≈ 50.18 ms
static constexpr float kTsymMs_SF10 = 4.096f;
static constexpr float kTpreMs_SF10 = (8.0f + 4.25f) * kTsymMs_SF10;

static void test_same_sf_low_margin_still_collides() {
    // Negative / regression: same SF, low SNR margin, heavy overlap →
    // primary must still be destroyed.  This guards against accidentally
    // turning the early-return into a blanket "all overlaps survive".
    CollisionConfig cfg;
    CapturedSignal a{0, 5.0f, 100, 500, 5, 8, kTsymMs_SF7, kTpreMs_SF7, 7};
    CapturedSignal b{1, 4.0f, 110, 510, 5, 8, kTsymMs_SF7, kTpreMs_SF7, 7};
    auto d = evaluateCollision(cfg, a, b);
    // 5 dB - 4 dB = 1 dB margin, below both 3 dB locked and 6 dB unlocked
    // capture thresholds; preamble grace is short and overlap reaches deep
    // into payload; CR4/5 has no FEC tolerance → primary destroyed.
    assert(!d.survived);
    assert(d.reason_code == 4);  // destroyed
}

static void test_cross_sf_survives_overlap() {
    // Positive / new behavior: SF7 primary vs SF10 interferer with full
    // temporal overlap and an SNR DISADVANTAGE for the primary.  Without
    // the cross-SF early return this would have been "destroyed" (reason 4);
    // with quasi-orthogonality it survives cleanly (reason 0).
    CollisionConfig cfg;
    CapturedSignal a{0, 4.0f, 100, 500, 5, 8, kTsymMs_SF7,  kTpreMs_SF7,  7};
    CapturedSignal b{1, 5.0f, 110, 510, 5, 8, kTsymMs_SF10, kTpreMs_SF10, 10};
    auto d = evaluateCollision(cfg, a, b);
    assert(d.survived);
    assert(d.reason_code == 0);  // clean: different SF, no collision

    // And symmetrically: SF10 primary vs SF7 interferer also survives.
    auto d_rev = evaluateCollision(cfg, b, a);
    assert(d_rev.survived);
    assert(d_rev.reason_code == 0);
}

int main() {
    test_same_sf_low_margin_still_collides();
    test_cross_sf_survives_overlap();
    std::printf("test_cross_sf_orthogonality: OK\n");
    return 0;
}
