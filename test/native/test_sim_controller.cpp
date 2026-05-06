// test/native/test_sim_controller.cpp
//
// Exercises the SimController API in isolation. Loads test/t01_flooder.json
// (the same 2-node alice/bob flooder topology used by run_tests.sh), then
// walks through:
//
//   - step()        — single-tick advance (default = step_ms = 1)
//   - runUntil()    — advance until target_ms reached
//   - runUntilNextEvent() — advance to first event delta or end_ms
//   - ended()       — completion check after exhausting duration
//   - finalize()    — emit sim_end + run ExpectRunner
//   - fireCommand() — unknown-node error string
//
// No assertions on event content (run_tests.sh regression suite covers
// that); this test is purely about the stepper API contract.

#include "core/topology/JsonConfig.h"
#include "orchestrator/runtime/SimController.h"

#include <cassert>
#include <cstdio>
#include <sstream>

int main() {
    // t01_flooder.json points at examples/flooder.lua via the
    // <config-dir>/../<script> resolver branch — works regardless of cwd.
    SimConfig cfg = JsonConfig::loadFromFile(
        "/home/staszek/lora-universal-simulator/test/t01_flooder.json");

    std::ostringstream out;
    SimController ctrl(cfg, out);
    ctrl.initialize();

    // step() with default advance — uses cfg.simulation.step_ms.
    auto r1 = ctrl.step();
    assert(r1.now_ms > 0);
    assert(!r1.ended);

    // runUntil(target_ms) — advances until now_ms >= target_ms.
    auto r2 = ctrl.runUntil(500);
    assert(r2.now_ms >= 500);

    // runUntilNextEvent — either runs to end (no events fire) or stops
    // on first non-zero delta. now_ms must not regress.
    auto r3 = ctrl.runUntilNextEvent();
    assert(r3.now_ms >= r2.now_ms);

    // Drive past end_ms — ended() should latch.
    auto r4 = ctrl.runUntil(cfg.simulation.duration_ms + 1000);
    assert(r4.ended);
    assert(ctrl.ended());

    // finalize emits sim_end + runs ExpectRunner.
    int failures = ctrl.finalize();
    (void)failures;

    // Idempotence check — second finalize is a no-op.
    int failures2 = ctrl.finalize();
    assert(failures2 == 0);

    // fireCommand on unknown node returns the documented error string.
    std::string reply = ctrl.fireCommand("nonexistent_node_xyz", "ping");
    assert(reply == "ERROR: unknown node");

    std::printf("test_sim_controller: OK\n");
    return 0;
}
