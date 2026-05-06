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
    // Absolute path of the JSON file we were loaded from (empty if loaded
    // from a string). Used by the orchestrator to resolve relative paths
    // (e.g. nodes[i].script) against the config's own directory rather
    // than the current working directory.
    std::string source_path;

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

    // Optional log-distance path-loss block. When `present` is true the
    // SimController computes the link matrix from per-node lat/lon at
    // sim init (see Phase R.2 plan). When false, only explicit
    // topology.links entries apply.
    struct PathLossSpec {
        bool        present        = false;
        std::string model          = "log_distance";
        double      alpha          = 3.0;
        double      sigma_db       = 0.0;
        double      ref_distance_m = 1.0;
        double      ref_loss_db    = 40.0;
        double      noise_floor_db = -120.0;
        double      tx_power_dbm   = 20.0;
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

        RadioConfig  radio;
        PathLossSpec path_loss;
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

        // Per-node receive-SF set. Empty means "default to [node.sf]" at
        // SimController init time (single-SF reception, matching real
        // Semtech LoRa hardware: SX1262/SX1276/LR1110/SX1280 all decode
        // only one SF at a time per Semtech datasheets + AN1200.85).
        // Configurable to >1 entry for opt-in idealized multi-SF
        // reception (e.g. paper reproduction or scanner-repeater
        // experiments). Each entry must be in [5, 12]; out-of-range
        // values are warn-and-clamped at parse time.
        std::vector<int> sf_rx_set;

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

    // End-of-run assertions. The evaluation engine lives in
    // orchestrator/test_runner/ExpectRunner. The fields below are the
    // union of everything the six supported assertion types may need;
    // each type uses only the subset that applies to it.
    //
    // Supported `type` values (see ExpectRunner::evaluate):
    //   - cmd_reply_contains       (node, command, value)
    //   - cmd_reply_not_contains   (node, command, value)
    //   - event_count              (event_type, [node], count   OR min..max)
    //   - event_count_min          (event_type, [node], min)
    //   - tx_airtime_between       (time_ms_min, time_ms_max, min, [max])
    //   - script_emit_contains     (node, emit_type, value)
    struct Assertion {
        std::string type;
        std::string node;
        std::string command;
        std::string value;
        std::string event_type;
        std::string emit_type;
        int count = 0;
        int min   = -1;
        int max   = -1;
        // tx_airtime_between window (millisecond-of-sim).
        long time_ms_min = -1;
        long time_ms_max = -1;
    };
    std::vector<Assertion> assertions;
};

namespace JsonConfig {

// Load + parse + validate. Throws std::runtime_error on any failure
// (missing required field, type mismatch, validation error, etc.).
SimConfig loadFromFile(const std::string& path);
SimConfig loadFromString(const std::string& json_str);

}  // namespace JsonConfig
