// orchestrator/runtime/Loop.cpp
//
// Thin wrapper around SimController for the batch entry point. The actual
// per-step pipeline (commands -> receptions -> timers -> transmissions ->
// advance) lives in SimController; runSimulation simply drives it from
// initialize() to finalize().

#include "orchestrator/runtime/Loop.h"

#include "orchestrator/runtime/SimController.h"

LoopResult runSimulation(const SimConfig& cfg, std::ostream& events_out) {
    SimController ctrl(cfg, events_out);
    ctrl.initialize();
    while (!ctrl.ended()) ctrl.step();
    int failures = ctrl.finalize();

    LoopResult r;
    r.events_emitted     = ctrl.eventCount();
    r.assertion_failures = failures;
    r.ok                 = (failures == 0);
    return r;
}
