// test/native/test_sf_rx_set_parsing.cpp
//
// R.1.7 — verifies the JSON parser:
//   1. accepts an optional `nodes[i].sf_rx_set` array of integers and
//      copies values verbatim into NodeDef::sf_rx_set;
//   2. leaves NodeDef::sf_rx_set empty when the field is absent (the
//      runtime resolves the default to [node.sf]);
//   3. warn-and-clamps out-of-range entries to [5, 12];
//   4. rejects malformed shapes (non-array, non-integer entries) with
//      a descriptive runtime_error.
//
// Per-node default-resolution itself happens in SimController::initialize;
// that path is exercised by the t06* integration tests rather than here
// (this file deliberately stays focused on the parser contract).
//
// Built standalone via test/native/build_test.sh — same pattern as
// test_jsonconfig.cpp.

#include "core/topology/JsonConfig.h"

#include <cassert>
#include <cstdio>
#include <stdexcept>
#include <string>

static const char* kPresent = R"({
  "_name": "rx_set_present",
  "simulation": {
    "duration_ms": 1000,
    "step_ms": 1,
    "radio": { "sf": 7, "bw": 250, "cr": 5, "duty_cycle": 0.01 }
  },
  "nodes": [
    { "name": "alice", "script": "examples/x.lua" },
    { "name": "bob",   "script": "examples/x.lua", "sf_rx_set": [7, 8, 9, 10, 11, 12] }
  ],
  "topology": { "links": [] }
})";

static const char* kAbsent = R"({
  "_name": "rx_set_absent",
  "simulation": {
    "duration_ms": 1000,
    "step_ms": 1,
    "radio": { "sf": 7, "bw": 250, "cr": 5, "duty_cycle": 0.01 }
  },
  "nodes": [
    { "name": "alice", "script": "examples/x.lua" },
    { "name": "bob",   "script": "examples/x.lua" }
  ],
  "topology": { "links": [] }
})";

static const char* kClamp = R"({
  "_name": "rx_set_clamp",
  "simulation": {
    "duration_ms": 1000,
    "step_ms": 1,
    "radio": { "sf": 7, "bw": 250, "cr": 5, "duty_cycle": 0.01 }
  },
  "nodes": [
    { "name": "alice", "script": "examples/x.lua", "sf_rx_set": [3, 13, 7] }
  ],
  "topology": { "links": [] }
})";

static const char* kBadType = R"({
  "_name": "rx_set_bad",
  "simulation": {
    "duration_ms": 1000,
    "step_ms": 1,
    "radio": { "sf": 7, "bw": 250, "cr": 5, "duty_cycle": 0.01 }
  },
  "nodes": [
    { "name": "alice", "script": "examples/x.lua", "sf_rx_set": "not-an-array" }
  ],
  "topology": { "links": [] }
})";

static const char* kBadEntry = R"({
  "_name": "rx_set_bad_entry",
  "simulation": {
    "duration_ms": 1000,
    "step_ms": 1,
    "radio": { "sf": 7, "bw": 250, "cr": 5, "duty_cycle": 0.01 }
  },
  "nodes": [
    { "name": "alice", "script": "examples/x.lua", "sf_rx_set": [7, "8"] }
  ],
  "topology": { "links": [] }
})";

int main() {
    // 1. Present + valid — values copied verbatim.
    {
        SimConfig cfg = JsonConfig::loadFromString(kPresent);
        assert(cfg.nodes.size() == 2);
        assert(cfg.nodes[0].sf_rx_set.empty());        // alice unset
        assert(cfg.nodes[1].sf_rx_set.size() == 6);    // bob full set
        assert(cfg.nodes[1].sf_rx_set[0] == 7);
        assert(cfg.nodes[1].sf_rx_set[5] == 12);
    }

    // 2. Absent — vector remains empty (runtime defaults to [node.sf]).
    {
        SimConfig cfg = JsonConfig::loadFromString(kAbsent);
        assert(cfg.nodes.size() == 2);
        assert(cfg.nodes[0].sf_rx_set.empty());
        assert(cfg.nodes[1].sf_rx_set.empty());
    }

    // 3. Out-of-range entries clamp to [5, 12]; warning goes to stderr
    // but parsing succeeds.
    {
        SimConfig cfg = JsonConfig::loadFromString(kClamp);
        assert(cfg.nodes.size() == 1);
        const auto& s = cfg.nodes[0].sf_rx_set;
        assert(s.size() == 3);
        assert(s[0] == 5);   // clamped from 3
        assert(s[1] == 12);  // clamped from 13
        assert(s[2] == 7);   // unchanged
    }

    // 4a. Non-array rejected.
    {
        bool threw = false;
        try {
            JsonConfig::loadFromString(kBadType);
        } catch (const std::runtime_error&) {
            threw = true;
        }
        assert(threw);
    }

    // 4b. Non-integer entry rejected.
    {
        bool threw = false;
        try {
            JsonConfig::loadFromString(kBadEntry);
        } catch (const std::runtime_error&) {
            threw = true;
        }
        assert(threw);
    }

    std::printf("test_sf_rx_set_parsing: OK\n");
    return 0;
}
