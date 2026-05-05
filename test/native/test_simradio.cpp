// test/native/test_simradio.cpp
#include "core/radio/SimRadio.h"
#include "core/clock/VirtualClock.h"
#include <cassert>
#include <cstdio>

int main() {
    VirtualClock clock;
    SimRadio radio(clock);

    // Reconfigure to SF11 / BW250kHz / CR4-5.
    radio.setRadioParams(/*sf=*/11, /*bw_hz=*/250000, /*cr=*/5);
    assert(radio.getSF() == 11);
    assert(radio.getBwHz() == 250000);
    assert(radio.getCR() == 5);

    // Airtime for a 50-byte payload at SF11/BW250/CR4-5 should be ~1 s.
    uint32_t airtime = radio.getEstAirtimeFor(50);
    assert(airtime > 100);
    assert(airtime < 5000);

    // Airtime monotonicity: longer payload → longer airtime.
    uint32_t airtime_long = radio.getEstAirtimeFor(200);
    assert(airtime_long > airtime);

    // ---- Half-duplex bookkeeping ---------------------------------------
    // Initial state: not receiving.
    assert(!radio.isReceiving());

    // Mark RX active for 200 ms (preamble lock from a peer's TX).
    radio.notifyRxStart(/*duration_ms=*/200);
    assert(radio.isReceiving());

    // Still receiving partway through the window.
    clock.advanceMillis(100);
    assert(radio.isReceiving());

    // After the window expires the radio is idle again.
    clock.advanceMillis(150);  // total 250 ms — past the 200 ms window
    assert(!radio.isReceiving());

    // ---- LBT / channel-busy windows ------------------------------------
    unsigned long now = clock.getMillis();
    radio.notifyChannelBusy(now + 50, now + 150);  // future window
    assert(!radio.isReceiving());                  // not yet active

    clock.advanceMillis(75);                       // now inside [50,150)
    assert(radio.isReceiving());

    clock.advanceMillis(100);                      // now past 150 ms
    assert(!radio.isReceiving());

    std::printf("test_simradio: OK (airtime=%u ms, long=%u ms)\n",
                airtime, airtime_long);
    return 0;
}
