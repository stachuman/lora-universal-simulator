#pragma once
//
// core/topology/JsonConfig.h
//
// Parser for the universal-simulator scenario JSON.
//
// Ported from meshcore_real_sim/orchestrator/JsonConfig.{h,cpp}, with
// MeshCore-firmware-specific fields stripped (firmware plugin selection,
// node roles, hot_start, adversarial modes, message/channel schedules).
// In their place we add:
//   - nodes[i].script  (string)        -> path to a Lua file
//   - nodes[i].config  (json object)   -> arbitrary per-node init data
//                                         passed to the script's on_init
//
// All other protocol-agnostic fields (simulation timing, global radio
// defaults, radio physics tuning, hardware turnaround, links with snr/
// rssi/loss/bidir/snr_std_dev, generic commands, expectations) are
// preserved verbatim from the source schema.
//
// Entry points:
//     SimConfig JsonConfig::loadFromFile(const std::string& path);
//     SimConfig JsonConfig::loadFromString(const std::string& json_str);

#include "json/json.hpp"

#include <cstdint>
#include <string>
#include <vector>

struct SimConfig {
    // Optional human-readable name (top-level "_name" metadata). Other
    // underscore-prefixed top-level keys are intentionally ignored.
    std::string name;

    struct RadioConfig {
        // Global LoRa defaults. Per-node overrides merge in below.
        int sf = 8;
        int bw = 62500;
        int cr = 1;

        // Capture / CAD physics tuning.
        float capture_locked_db   = 3.0f;
        float capture_unlocked_db = 6.0f;
        float cad_miss_prob       = 0.05f;
        float cad_reliable_snr    = 0.0f;
        float cad_marginal_snr    = -15.0f;
        float snr_coherence_ms    = 0.0f;

        // SX1262-style hardware turnaround delays.
        float rx_to_tx_delay_ms = 1.0f;
        float tx_to_rx_delay_ms = 5.0f;
    };

    struct SimulationConfig {
        unsigned long duration_ms = 300000;
        int           step_ms     = 1;
        unsigned long warmup_ms   = 0;
        // TODO Y2: revisit if MeshCore-coupled. In the source this seeded a
        // simulated RTC for firmware that wanted wall-clock time. Harmless
        // as a generic field; scripts may choose to consume it or ignore it.
        uint32_t      epoch_start = 1700000000;
        uint64_t      seed        = 42;

        RadioConfig radio;
    };
    SimulationConfig simulation;

    struct NodeDef {
        std::string name;

        // New: script + config (replace firmware/role from MeshCore).
        std::string    script_path;
        nlohmann::json config = nlohmann::json::object();

        // Per-node radio overrides. -1 means "fall back to simulation.radio".
        int sf = -1;
        int bw = -1;
        int cr = -1;

        // Optional geo-location (passed through to events for analysis).
        double lat = 0.0;
        double lon = 0.0;
        bool   has_location = false;

        // TODO Y2: revisit if MeshCore-coupled. Models stochastic SPI/PHY
        // submit failures; protocol-agnostic in principle (any LoRa stack
        // can hit a startSendRaw failure path). Kept; scripts may surface
        // tx_fail events or ignore them.
        float tx_fail_prob = 0.0f;
    };
    std::vector<NodeDef> nodes;

    struct LinkDef {
        std::string from;
        std::string to;
        float snr         = 8.0f;
        float rssi        = -80.0f;
        float snr_std_dev = 0.0f;
        float loss        = 0.0f;
        bool  bidir       = true;
    };

    struct TopologyConfig {
        std::vector<LinkDef> links;
    };
    TopologyConfig topology;

    // Scheduled commands. Either a node command (node + command non-empty)
    // or a Lua callback (lua_fn non-empty, node/command empty). Real
    // execution is wired up in T15.
    struct CmdDef {
        unsigned long at_ms = 0;
        std::string   node;     // empty for lua-only entries
        std::string   command;  // empty for lua-only entries
        std::string   lua_fn;   // non-empty = call named Lua function
    };
    std::vector<CmdDef> commands;

    // End-of-run assertions. The actual evaluation engine is wired up in T15;
    // here we only parse and surface the shape.
    struct Assertion {
        std::string type;
        std::string node;
        std::string command;
        std::string value;
        std::string event_type;
        int count = 0;
        int min   = -1;
        int max   = -1;
    };
    std::vector<Assertion> assertions;
};

namespace JsonConfig {

// Load + parse + validate. Throws std::runtime_error on any failure
// (missing required field, type mismatch, validation error, etc.).
SimConfig loadFromFile(const std::string& path);
SimConfig loadFromString(const std::string& json_str);

}  // namespace JsonConfig
