// test_preamble_override -- R.1.4
//
// Verifies SimRadio::setPreambleSymbols() takes effect on getEstAirtimeFor()
// and that the setter clamps to LoRa's valid 6..65535 range. The exact-delta
// check (a16 - a8 == 8 * t_sym) pins the airtime formula's preamble term to
// the Semtech AN1200.13 expression t_pre = (n + 4.25) * t_sym so any future
// regression in that calculation surfaces here rather than in physics tests
// that observe airtime only indirectly.
#include "core/radio/SimRadio.h"
#include "core/clock/VirtualClock.h"
#include <cassert>
#include <cmath>
#include <cstdio>

int main() {
    VirtualClock clk;
    SimRadio radio(clk);
    radio.setRadioParams(/*sf=*/7, /*bw_hz=*/250000, /*cr=*/5);

    radio.setPreambleSymbols(8);
    uint32_t a8  = radio.getEstAirtimeFor(50);
    radio.setPreambleSymbols(16);
    uint32_t a16 = radio.getEstAirtimeFor(50);
    radio.setPreambleSymbols(32);
    uint32_t a32 = radio.getEstAirtimeFor(50);

    // Longer preamble -> longer airtime
    assert(a16 > a8);
    assert(a32 > a16);

    // Difference between 16- and 8-sym preamble should be ~8 * t_sym
    double t_sym = radio.getSymbolMs();
    double delta = (double)a16 - (double)a8;
    double expected = 8.0 * t_sym;
    // Allow 1.5ms slack for integer-truncation in airtime calc
    assert(std::fabs(delta - expected) <= 1.5);

    // Setter should clamp invalid values (n < 6 -> 6, n > 65535 -> 65535)
    radio.setPreambleSymbols(0);
    assert(radio.getPreambleSymbols() == 6);
    radio.setPreambleSymbols(100000);
    assert(radio.getPreambleSymbols() == 65535);

    std::printf("test_preamble_override: OK (a8=%u a16=%u a32=%u t_sym=%fms)\n",
                a8, a16, a32, t_sym);
    return 0;
}
