// test/native/test_multi_sf_reception.cpp
//
// Native unit test for SimRadio::getSnrThreshold(int sf) static overload.
//
// A single-channel LoRa receiver dynamically tunes its SF on each incoming
// preamble. The receiver's _sf only constrains what it transmits, not what
// it can receive. Delivery decisions must therefore consult the threshold
// for the PACKET's SF, not the receiver's. This test verifies the static
// overload exposes the correct per-SF table without depending on radio state
// and that the existing instance method delegates to it consistently.

#include "core/radio/SimRadio.h"
#include "core/clock/VirtualClock.h"

#include <cassert>
#include <cstdio>

static void test_static_thresholds_ordered_and_floor_below_paper_value() {
    // Higher SF → lower (more negative) threshold. This is the property the
    // delivery loop relies on: an SF12 packet is decodable at much lower SNR
    // than an SF7 packet over the same link.
    const float t7  = SimRadio::getSnrThreshold(7);
    const float t8  = SimRadio::getSnrThreshold(8);
    const float t9  = SimRadio::getSnrThreshold(9);
    const float t10 = SimRadio::getSnrThreshold(10);
    const float t11 = SimRadio::getSnrThreshold(11);
    const float t12 = SimRadio::getSnrThreshold(12);

    assert(t7  > t8);
    assert(t8  > t9);
    assert(t9  > t10);
    assert(t10 > t11);
    assert(t11 > t12);

    // Sanity floor: SF12 must be at most -15 dB. The paper (Centelles et al.
    // 2024) and Semtech's datasheet both quote -20 dB; we assert the looser
    // -15 dB bound so the test doesn't lock us into one exact table.
    assert(t12 < -15.0f);
}

static void test_out_of_range_sf_returns_tolerant_fallback() {
    // Out-of-range SF must return a very-tolerant value so the delivery loop
    // never spuriously drops packets when metadata is malformed. -100 dB is
    // far below any realistic link's SNR.
    assert(SimRadio::getSnrThreshold(0)  <= -100.0f);
    assert(SimRadio::getSnrThreshold(6)  <= -100.0f);
    assert(SimRadio::getSnrThreshold(13) <= -100.0f);
    assert(SimRadio::getSnrThreshold(99) <= -100.0f);
}

static void test_instance_method_matches_static_lookup() {
    // The instance method now delegates to the static overload — verify the
    // delegation by reconfiguring the radio and reading back via both APIs.
    VirtualClock clk;
    SimRadio radio(clk);

    radio.setRadioParams(/*sf=*/7,  /*bw_hz=*/250000, /*cr=*/5);
    assert(radio.getSnrThreshold() == SimRadio::getSnrThreshold(7));

    radio.setRadioParams(/*sf=*/10, /*bw_hz=*/250000, /*cr=*/5);
    assert(radio.getSnrThreshold() == SimRadio::getSnrThreshold(10));

    radio.setRadioParams(/*sf=*/12, /*bw_hz=*/250000, /*cr=*/5);
    assert(radio.getSnrThreshold() == SimRadio::getSnrThreshold(12));
}

int main() {
    test_static_thresholds_ordered_and_floor_below_paper_value();
    test_out_of_range_sf_returns_tolerant_fallback();
    test_instance_method_matches_static_lookup();

    std::printf("test_multi_sf_reception: OK (t7=%.1f t10=%.1f t12=%.1f)\n",
                SimRadio::getSnrThreshold(7),
                SimRadio::getSnrThreshold(10),
                SimRadio::getSnrThreshold(12));
    return 0;
}
