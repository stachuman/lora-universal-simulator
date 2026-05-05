// test/native/test_clock.cpp
#include "core/clock/VirtualClock.h"
#include <cassert>
#include <cstdio>

int main() {
    VirtualClock c;
    assert(c.getMillis() == 0);
    c.advanceMillis(150);
    assert(c.getMillis() == 150);
    c.advanceMillis(50);
    assert(c.getMillis() == 200);

    // getCurrentTime() should reflect epoch_base + (millis / 1000).
    // Default epoch_base = 1700000000; at 200 ms that's still +0 seconds.
    assert(c.getCurrentTime() == 1700000000u);

    c.advanceMillis(800);                  // 1000 ms total
    assert(c.getMillis() == 1000);
    assert(c.getCurrentTime() == 1700000001u);

    // setCurrentTime should reset the epoch base such that getCurrentTime
    // returns the new value at the current millis.
    c.setCurrentTime(1800000000u);
    assert(c.getCurrentTime() == 1800000000u);

    std::printf("test_clock: OK\n");
    return 0;
}
