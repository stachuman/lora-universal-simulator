// orchestrator/test_runner/ExpectRunner.cpp
//
// T13 stub. Real assertion evaluation arrives in T15.

#include "orchestrator/test_runner/ExpectRunner.h"

int ExpectRunner::evaluate(const std::vector<SimConfig::Assertion>& expects,
                           std::ostream& /*events_out*/) {
    (void)expects;
    // TODO(T15): implement assertion evaluation.
    //   - count(node?, event_type) >= count / between [min,max]
    //   - cmd_reply(node, command) == value
    //   - etc.
    return 0;
}
