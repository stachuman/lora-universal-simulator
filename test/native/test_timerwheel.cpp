// test/native/test_timerwheel.cpp
#include "orchestrator/runtime/TimerWheel.h"
#include <cassert>
#include <cstdio>

int main() {
    TimerWheel w;
    TimerEntry e;

    // Empty heap.
    assert(!w.peek(0, e));

    // One-shot at t=100.
    auto h1 = w.scheduleAfter(/*now=*/0, /*delay=*/100);
    assert(w.peek(0, e));
    assert(e.deadline_ms == 100);
    assert(!w.popDue(50, e));    // not due yet
    assert(w.popDue(150, e));
    assert(e.handle == h1);
    assert(e.period_ms == 0);

    // Recurring every 50, starting at t=0.
    auto h2 = w.scheduleAfter(/*now=*/0, /*delay=*/0, /*period=*/50);
    int fired = 0;
    for (uint64_t t = 0; t <= 200; t++) {
        while (w.popDue(t, e)) { fired++; }
    }
    // Should fire at 0, 50, 100, 150, 200 -> 5 times.
    assert(fired == 5);

    // Cancellation. (First stop the recurring h2 from above so it can't
    // mask whether h3 was suppressed.)
    w.cancel(h2);
    auto h3 = w.scheduleAfter(/*now=*/0, /*delay=*/300);
    w.cancel(h3);
    assert(!w.popDue(500, e));   // cancelled, not popped

    std::printf("test_timerwheel: OK (h1=%lu h2=%lu h3=%lu)\n",
                (unsigned long)h1, (unsigned long)h2, (unsigned long)h3);
    return 0;
}
