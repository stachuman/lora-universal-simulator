// orchestrator/test_runner/ExpectRunner.cpp
//
// Implementation of the six assertion types declared in ExpectRunner.h.
// See the header for the per-type contract.

#include "orchestrator/test_runner/ExpectRunner.h"

#include <climits>
#include <cstdio>
#include <string>
#include <unordered_map>

namespace {

// True iff `e["node"]` matches `node_name`, given a name->id table for
// looking up the integer form. Returns true if the assertion did not
// specify a node filter (`node_name` empty).
//
// Background: tx/rx/cmd_reply events emit `"node"` (or `"from"`/`"to"`)
// as a string name; script_emit/script_log emit it as an integer id.
// We accept either form against the assertion's name.
bool nodeMatches(const nlohmann::json& e,
                 const std::string& node_name,
                 const std::unordered_map<std::string, int>& name_to_id) {
    if (node_name.empty()) return true;
    if (!e.contains("node")) return false;
    const auto& nf = e["node"];
    if (nf.is_string()) {
        return nf.get<std::string>() == node_name;
    }
    if (nf.is_number_integer()) {
        auto it = name_to_id.find(node_name);
        if (it == name_to_id.end()) return false;
        return nf.get<int>() == it->second;
    }
    return false;
}

}  // namespace

int ExpectRunner::evaluate(const SimConfig& cfg,
                           const std::vector<nlohmann::json>& events) {
    int failures = 0;

    // node name -> id map, used for name/id reconciliation in assertions
    // that filter by node.
    std::unordered_map<std::string, int> name_to_id;
    name_to_id.reserve(cfg.nodes.size());
    for (size_t i = 0; i < cfg.nodes.size(); ++i) {
        name_to_id.emplace(cfg.nodes[i].name, static_cast<int>(i));
    }

    auto report = [&](const std::string& kind,
                      const std::string& detail,
                      bool pass) {
        if (!pass) {
            std::fprintf(stderr, "FAIL expect[%s]: %s\n",
                         kind.c_str(), detail.c_str());
            ++failures;
        }
    };

    for (const auto& a : cfg.assertions) {
        if (a.type == "cmd_reply_contains" ||
            a.type == "cmd_reply_not_contains") {
            const bool want_contains = (a.type == "cmd_reply_contains");
            // Find the most-recent cmd_reply for (node, command-prefix).
            bool found_match = false;
            std::string seen_reply;
            for (auto it = events.rbegin(); it != events.rend(); ++it) {
                const auto& e = *it;
                if (e.value("type", "") != "cmd_reply") continue;
                if (!a.node.empty() && e.value("node", "") != a.node) continue;
                const std::string cmd_field = e.value("command", "");
                // a.command is treated as a prefix: an assertion of
                // "send hello" matches a real command of "send hello world".
                if (!a.command.empty() &&
                    cmd_field.rfind(a.command, 0) != 0) continue;
                seen_reply = e.value("reply", "");
                found_match = true;
                break;  // most-recent matching reply wins
            }

            const bool contains_value =
                found_match && seen_reply.find(a.value) != std::string::npos;
            const bool pass = want_contains ? contains_value : !contains_value;

            std::string detail =
                "node=" + a.node +
                " command_prefix=\"" + a.command + "\"" +
                " expected_substr=\"" + a.value + "\"";
            if (found_match) {
                detail += " actual_reply=\"" + seen_reply + "\"";
            } else {
                detail += " (no matching cmd_reply found)";
            }
            report(a.type, detail, pass);
        }
        else if (a.type == "event_count" || a.type == "event_count_min") {
            int count = 0;
            for (const auto& e : events) {
                if (e.value("type", "") != a.event_type) continue;
                if (!nodeMatches(e, a.node, name_to_id)) continue;
                ++count;
            }
            int min_v = (a.min >= 0) ? a.min : 0;
            int max_v = (a.max >= 0) ? a.max : INT_MAX;
            // For event_count without explicit min/max, fall back to count==a.count.
            bool pass;
            if (a.type == "event_count") {
                if (a.min < 0 && a.max < 0) {
                    pass = (count == a.count);
                } else {
                    pass = (count >= min_v && count <= max_v);
                }
            } else {
                // event_count_min: require count >= min.
                pass = (count >= min_v);
            }
            std::string detail =
                "event_type=" + a.event_type +
                " node=" + a.node +
                " count=" + std::to_string(count);
            if (a.type == "event_count_min") {
                detail += " min=" + std::to_string(min_v);
            } else if (a.min < 0 && a.max < 0) {
                detail += " expected=" + std::to_string(a.count);
            } else {
                detail += " min=" + std::to_string(min_v) +
                          " max=" + std::to_string(max_v);
            }
            report(a.type, detail, pass);
        }
        else if (a.type == "tx_airtime_between") {
            const long lo = (a.time_ms_min >= 0) ? a.time_ms_min : 0;
            const long hi = (a.time_ms_max >= 0)
                                ? a.time_ms_max
                                : LONG_MAX;
            unsigned long long sum_airtime = 0;
            int matched_tx = 0;
            for (const auto& e : events) {
                if (e.value("type", "") != "tx") continue;
                long t = e.value("time_ms", 0L);
                if (t < lo || t > hi) continue;
                if (!nodeMatches(e, a.node, name_to_id)) continue;
                sum_airtime += e.value("airtime_ms", 0u);
                ++matched_tx;
            }
            const long min_v = (a.min >= 0) ? a.min : 0;
            const long max_v = (a.max >= 0) ? a.max : LONG_MAX;
            const bool pass =
                static_cast<long long>(sum_airtime) >= static_cast<long long>(min_v) &&
                static_cast<long long>(sum_airtime) <= static_cast<long long>(max_v);
            std::string detail =
                "window=[" + std::to_string(lo) + "," +
                (hi == LONG_MAX ? "inf" : std::to_string(hi)) + "]" +
                " node=" + a.node +
                " matched_tx=" + std::to_string(matched_tx) +
                " sum_airtime_ms=" + std::to_string(sum_airtime) +
                " min=" + std::to_string(min_v) +
                " max=" + (max_v == LONG_MAX ? "inf" : std::to_string(max_v));
            report(a.type, detail, pass);
        }
        else if (a.type == "script_emit_contains") {
            // At least one script_emit event from `node` with the given
            // emit_type whose `data` field, JSON-serialized, contains
            // `value` as a substring.
            bool found = false;
            std::string last_dump;
            for (const auto& e : events) {
                if (e.value("type", "") != "script_emit") continue;
                if (!nodeMatches(e, a.node, name_to_id)) continue;
                if (!a.emit_type.empty() &&
                    e.value("emit_type", "") != a.emit_type) continue;
                if (!e.contains("data")) continue;
                std::string dumped = e["data"].dump();
                last_dump = dumped;
                if (a.value.empty() ||
                    dumped.find(a.value) != std::string::npos) {
                    found = true;
                    break;
                }
            }
            std::string detail =
                "node=" + a.node +
                " emit_type=" + a.emit_type +
                " expected_substr=\"" + a.value + "\"";
            if (!last_dump.empty() && !found) {
                detail += " last_data=" + last_dump;
            }
            report(a.type, detail, found);
        }
        else {
            std::fprintf(stderr,
                         "FAIL expect[%s]: unknown assertion type\n",
                         a.type.c_str());
            ++failures;
        }
    }

    return failures;
}
