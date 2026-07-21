// orchestrator/test_runner/ExpectRunner.h
//
// Evaluates the `expect[]` block from the JSON scenario after a simulation
// has finished. Consumes the in-memory event buffer captured by EventLog
// (Loop.cpp wires it up) and reports failures to stderr.
//
// Seven assertion types are supported (matched on Assertion::type):
//
//   cmd_reply_contains      most-recent cmd_reply for (node, command-prefix)
//                            has its `reply` field contain `value` (substring)
//   cmd_reply_not_contains  same lookup, but the substring must NOT appear
//                            (or no matching cmd_reply exists at all)
//   event_count             count(event_type, [node]) is exactly `count`
//                            OR within [min, max] when those are provided
//   event_count_min         count(event_type, [node]) >= min
//   tx_airtime_between      sum of airtime_ms across tx events whose
//                            time_ms is in [time_ms_min, time_ms_max] is
//                            in [min, max] (max optional; defaults to MAX)
//   script_emit_contains    at least one script_emit event from `node`
//                            with emit_type==`emit_type` whose serialized
//                            `data` field contains `value` (substring)
//   script_emit_not_contains NO script_emit from `node` with emit_type==
//                            `emit_type` may have `data` containing `value`
//                            (separation gate; value REQUIRED)
//
// Node-name vs node-id: tx/rx/cmd_reply events emit `"node"` as a string
// name; script_log/script_emit emit it as an integer id. Whenever an
// assertion specifies a node by name, the evaluator accepts a match
// against either form (string or int-id) by looking the name up in cfg.

#pragma once

#include "core/topology/JsonConfig.h"
#include "json/json.hpp"

#include <vector>

class ExpectRunner {
public:
    // Returns the number of failed assertions (0 = all pass). Diagnostics
    // for each failure are written to stderr in the form
    //     FAIL expect[<type>]: <details>
    static int evaluate(const SimConfig& cfg,
                        const std::vector<nlohmann::json>& events);
};
