// orchestrator/runtime/Loop.h
//
// Main simulation loop. Given a parsed SimConfig and an output stream for
// NDJSON events, runs the per-step pipeline (commands -> deliver in-flight
// receptions -> tick timers -> register new transmissions -> advance the
// virtual clock) until the configured duration elapses, then evaluates the
// assertion list.
//
// Returns a small result struct so callers (main.cpp / future test runners)
// can decide on exit code and reporting.

#pragma once

#include "core/topology/JsonConfig.h"

#include <ostream>

struct LoopResult {
    bool ok                = true;
    int  events_emitted    = 0;
    int  assertion_failures = 0;
};

// Run the simulation described by `cfg`. NDJSON events are written to
// `events_out` via EventLog.
LoopResult runSimulation(const SimConfig& cfg, std::ostream& events_out);
