// orchestrator/test_runner/ExpectRunner.h
//
// Evaluates the `expect[]` block from the JSON scenario after a simulation
// has finished. T13 ships this as a stub: the entry point exists and returns
// 0 (no failures) so Loop can call it unconditionally. The real evaluator
// lands in T15, once the flooder example (T14) gives us assertions to
// exercise it against.

#pragma once

#include "core/topology/JsonConfig.h"

#include <ostream>
#include <vector>

class ExpectRunner {
public:
    // Returns the number of failed assertions. Stub for T13: always 0.
    // The `events_out` stream is taken so that T15 can re-read NDJSON
    // (or hold a hook) without changing the public surface again.
    static int evaluate(const std::vector<SimConfig::Assertion>& expects,
                        std::ostream& events_out);
};
