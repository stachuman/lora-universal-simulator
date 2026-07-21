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

#include <array>
#include <cstdint>
#include <limits>
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

    // Optional scenario-wide script config defaults. These are merged into
    // every node's on_init config before nodes[i].config, so per-node config
    // can still override a global default.
    nlohmann::json config = nlohmann::json::object();

    struct RadioConfig {
        // Global LoRa defaults. Per-node overrides merge in below.
        //
        // ★ ONE bw CONVENTION (2026-07-20 realism review §1.1): bw is stored INTERNALLY IN Hz.
        //   The JSON `bw` field is authored in kHz as a DOUBLE and multiplied ×1000 at parse time
        //   (JsonConfig.cpp), so `"bw": 62.5` yields exactly 62500 Hz (the old `get<int>()` truncated
        //   it to 62 kHz → 62000 Hz). SimController no longer multiplies — bw is Hz end-to-end.
        //
        // sf / bw / cr / duty_cycle are REQUIRED (sentinel -1 = unset → validateConfig fails loud).
        // The old silent defaults (sf 8 / bw 62500-as-kHz i.e. 62.5 MHz / cr 1 which is outside the
        // [5..8] validator range) are gone: absence is now a named error, not a surprise physics run.
        int sf = -1;
        int bw = -1;   // Hz (see convention above); -1 = REQUIRED-and-unset
        int cr = -1;

        // Capture / CAD physics tuning.
        float capture_locked_db   = 3.0f;
        float capture_unlocked_db = 6.0f;
        float cad_miss_prob       = 0.05f;
        // Maximum total LoRa packet size in bytes. SX126x / SX1276 hardware
        // tops out at 255 (8-bit length register) — that's the byte-count
        // of the *entire* PHY payload going on the air, not just the
        // application-level payload inside a protocol frame. Anything bigger
        // is unphysical: the chip would refuse to TX, or RX would garble.
        // Enforced in SimController; oversized TXes emit `tx_oversized` and
        // skip the InFlight push.
        int   max_packet_bytes    = 255;
        float cad_reliable_snr    = 0.0f;
        float cad_marginal_snr    = -15.0f;
        float snr_coherence_ms    = 0.0f;

        // SX1262-style hardware turnaround delays. After an RX completes,
        // the radio cannot TX for rx_to_tx_delay_ms (PA ramp + PLL); after
        // a TX, cannot RX for tx_to_rx_delay_ms (LNA + PLL relock).
        // ★ DEFAULTS = the metal-measured SX1262 turnaround 27/27 ms (2026-07-21
        //   realism ruling 2.1: "simulations need to be as realistic as possible").
        //   These are the one hardware datapoint we have (s09_two_layer_gateway_metal
        //   sets exactly these); the old 1/5 ms idealized values simulated a radio
        //   5–27× faster at turnaround, where the CTS-wait metal bug hid. A scenario
        //   may still override per radio.hardware for a deliberately-idealized run.
        float rx_to_tx_delay_ms = 27.0f;
        float tx_to_rx_delay_ms = 27.0f;
        // Time to retune the receiver to a new SF (PLL relock + sync). Real
        // SX1262 takes ~200 µs; we round up to 1 ms. Modelled as an "RX
        // blind window" after self:set_rx_sf(): incoming frames whose
        // start lands inside the window are dropped (drop_sf_switching).
        float sf_switch_delay_ms = 1.0f;

        // RX-side preamble miss probability. Real LoRa receivers occasionally
        // drop preambles even of decodable frames — AGC settling on a strong
        // adjacent signal, internal FIFO scheduling, transient interference
        // below the demod floor. Distinct from cad_miss_prob (which is the
        // LBT-side "did CAD detect the busy window"). Modeled as a per-RX
        // Bernoulli roll after threshold + probabilistic decode pass; misses
        // emit drop_preamble_miss. Default 0.02 ≈ 2% — conservative for
        // SX1262-grade chips at moderate SNR. Set to 0 to disable.
        float rx_preamble_miss_prob = 0.02f;

        // Probabilistic decode at marginal SNR. Real Semtech chips don't
        // present a hard cliff at the demod threshold — PER follows a
        // sigmoid that's ~50 % at threshold and falls off ~3 dB per decade.
        // Without this, a frame at threshold + epsilon decodes with prob 1
        // and at threshold − epsilon with prob 0; that masks bugs around
        // marginal links that real hardware would expose. Modeled as
        //   PER(margin) = 1 / (1 + exp(margin / decode_margin_steepness_db))
        // where margin = snr_at_rcv − threshold. Frames below threshold
        // still drop deterministically (drop_weak); frames above pass the
        // sigmoid roll. Set to 0 for the legacy hard-cliff behaviour
        // (analytic tests).
        float decode_margin_steepness_db = 1.5f;

        // Receiver-REPORT SNR ceiling (dB). A real SX126x never *reports* SNR
        // above ~+10..+13 dB regardless of how strong the channel actually is
        // (the SnrPkt register saturates). The sim's PathLossModel computes the
        // TRUE channel SNR (rx_dbm - noise_floor), which for co-located links
        // reaches tens of dB — a value no real firmware would ever observe.
        // FirmwareNode saturates the SNR the firmware SEES to this ceiling
        // (then quantizes to the chip's 0.25 dB q4 grid). REPORT-ONLY: the
        // delivery/collision/demod physics in SimController stay on the true
        // channel SNR; this only shapes what the Node is told. Default +12.0.
        // A very large value (e.g. 1e9) effectively DISABLES the saturation —
        // the A/B-debug escape hatch to recover the old inflated-SNR behaviour.
        float snr_report_ceiling_db = 12.0f;

        // Regulatory duty cycle. ★ UNIT = PERCENT (2026-07-21 realism ruling 2.2:
        // "percent everywhere, 1 = 1%"): this field stores the value AS AUTHORED in
        // the scenario JSON — a PERCENT (1 => 1%, 0.1 => 0.1%), matching the device
        // console's `duty=` (which is already percent). The old scenario convention
        // was a FRACTION (0.01 = 1%) while the device took percent — a 100× trap;
        // that is now unified. Consumers divide by 100 to get the fraction at the
        // point of use (SimController: the enforcement budget `duty*window/100` and
        // the `_sim_duty_cycle` injection into the firmware NodeConfig, whose field
        // keeps its FRACTION semantic — see SimController). Default 1 (=1%) / 1 h
        // matches ETSI EN 300 220 (European 868 MHz ISM sub-band g1). 0 < duty <= 100.
        // The runtime tracks per-node TX airtime in a sliding window of
        // `duty_cycle_window_ms`; if a fresh TX would push the window's airtime sum
        // past `(duty/100) * window_ms`, it is deferred (reason="duty_cycle_exceeded").
        // Lua scripts self-regulate off the injected fraction. ⚠ Per-node override
        // nodes[].config.duty_cycle stays a raw JSON passthrough read by BOTH the Lua
        // script (as a fraction) and the C++ enforcement net (as a fraction) — it is
        // NOT re-scaled here (Lua-parity), so a per-node override is authored as a
        // fraction; the MeshRoute corpus uses none. The GLOBAL knob is percent.
        float         duty_cycle           = -1.0f;   // REQUIRED (sentinel <0 = unset); PERCENT in (0,100]
        unsigned long duty_cycle_window_ms = 3600000UL;
    };

    // Optional log-distance path-loss block. When `present` is true the
    // SimController computes the link matrix from per-node lat/lon at
    // sim init (see Phase R.2 plan). When false, only explicit
    // topology.links entries apply.
    struct PathLossSpec {
        bool        present        = false;
        std::string model          = "log_distance";
        double      alpha          = 3.0;
        double      ref_distance_m = 1.0;
        double      ref_loss_db    = 40.0;
        double      noise_floor_db = -120.0;
        double      tx_power_dbm   = 20.0;
        // When true, path-loss is used only for links where at least one
        // endpoint is mobile. Static-static links remain governed by the
        // explicit topology.links matrix.
        bool        mobile_only    = false;

        // Asymmetry / shadowing model. Real LoRa links routinely show
        // SNR(A→B) ≠ SNR(B→A) — TX-power variability across hardware,
        // antenna gain differences, and per-direction shadowing all
        // contribute. Three independent components, each sampled once
        // at init (and the per-pair shadow optionally re-sampled every
        // asymmetry_coherence_ms for slow time variation):
        //
        //   sigma_db                — per-(sender→receiver) shadow
        //                             stddev. Captures permanent
        //                             obstruction differences along the
        //                             two directions.
        //   node_tx_offset_sigma_db — per-node TX-power offset stddev.
        //                             "Node A's PA chain runs hot/cold
        //                             vs spec." Applies to every flight
        //                             where this node is the sender.
        //   node_rx_offset_sigma_db — per-node RX-sensitivity offset
        //                             stddev. "Node A's LNA / antenna
        //                             pattern attenuates incoming."
        //                             Applies to every flight where
        //                             this node is the receiver.
        //   asymmetry_coherence_ms  — 0 → static (sample once at init).
        //                             >0 → re-sample per-pair shadow
        //                             every coherence_ms. Models slow
        //                             environmental change (foliage
        //                             moves, weather, etc.). Per-node
        //                             offsets stay constant across
        //                             the run since they represent
        //                             hardware, not environment.
        double      sigma_db                = 3.0;
        double      node_tx_offset_sigma_db = 2.0;
        double      node_rx_offset_sigma_db = 1.5;
        // Default 60_000 ms (1 minute) — slow environmental change is the
        // realistic baseline for LoRa fixed installations (foliage,
        // weather, slow drift). Set to 0 in scenario JSON for fully
        // static asymmetry (useful for analytic tests).
        uint64_t    asymmetry_coherence_ms  = 60000;

        // Authoring-time only: used by the webapp's SRTM+ITM
        // topology generator. The runtime path-loss model ignores
        // this field. Default 868 MHz (EU LoRa).
        double frequency_mhz = 868.0;
    };

    struct SimulationConfig {
        unsigned long duration_ms = 300000;
        int           step_ms     = 1;
        unsigned long warmup_ms   = 0;
        // Per-node clock drift sigma in ppm. Real LoRa nodes use crystal
        // oscillators that drift ±20–50 ppm over temperature; over a
        // multi-hour run two nodes drift apart by 100s of ms, so any
        // protocol with tight timing (rts_timeout_ms / pending_rx_expiry)
        // needs slack the simulator never demands without this. Sampled
        // once per node at init from N(0, sigma); ScriptedNode::api_now /
        // api_after scale by (1 + drift_ppm * 1e-6) so the script sees
        // a slightly skewed clock relative to wall time. Per-node override
        // via nodes[].clock_drift_ppm (NaN = sample). Set sigma to 0 for
        // perfectly synchronized clocks (analytic tests).
        double        clock_drift_ppm_sigma = 25.0;
        // TODO Y2: revisit if MeshCore-coupled. In the source this seeded a
        // simulated RTC for firmware that wanted wall-clock time. Harmless
        // as a generic field; scripts may choose to consume it or ignore it.
        uint32_t      epoch_start = 1700000000;
        uint64_t      seed        = 42;
        // Per-node `on_init` is staged at a uniform random offset in
        // [0, node_startup_jitter_ms] drawn from the seeded RNG, modeling
        // real-hardware boot-time variability. Default 0 = all nodes init
        // synchronously at sim time 0 (legacy behavior). The radio is
        // gated until on_init fires — pre-init packets are silently
        // dropped script-side.
        int           node_startup_jitter_ms = 0;
        std::string   rx_window_slop = "metal";   // §metal-fidelity: DEFAULT "metal" (device turnaround/RX-window slop formula in FirmwareNode — 2026-07-21 realism ruling 2.1); "idealized" (RX-window slop 0) is now the explicit opt-in for a deliberately-idealized run

        RadioConfig  radio;
        PathLossSpec path_loss;
    };
    SimulationConfig simulation;

    struct NodeDef {
        std::string name;
        // Protocol-visible short address. When unset (-1), legacy scenarios
        // use the node's array index as the protocol id. Future firmware-mode
        // join scenarios can leave this unset until the join state machine
        // assigns a layer-local lease.
        int node_id = -1;
        // Simulated permanent identity. public_key is a human/test fixture
        // string for now; key_hash32 is the compact protocol identity marker
        // exposed to Lua. If absent in JSON, JsonConfig derives a stable
        // deterministic hash from the node name.
        std::string public_key;
        uint32_t key_hash32 = 0;
        // Slice A2: a 32-byte identity seed (hex, zero-padded). When present, the harness
        // DERIVES key_hash32 = ed_pub[:4] via the device's lib/core/identity (so sim and
        // device share one derivation) and feeds the derived value to BOTH engines. The
        // literal key_hash32 above stays as a transitional fallback for un-migrated scenarios.
        std::array<uint8_t, 32> seed{};
        bool                    has_seed = false;

        // New: script + config (replace firmware/role from MeshCore).
        std::string    script_path;
        nlohmann::json config = nlohmann::json::object();

        // Node engine: "lua" (default) -> ScriptedNode runs script_path;
        // "meshroute" -> FirmwareNode (the C++ port run in-loop in the sim).
        // See ~/MeshRoute/docs/PORT_PLAN.md §2.1 (sim-integration track).
        std::string    engine = "lua";

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

        // Per-node asymmetry overrides. NaN means "sample from the
        // simulation-level path_loss.node_*_offset_sigma_db". Set
        // explicitly to deterministically pin a node's TX/RX bias —
        // useful for unit tests and for reproducing field-measured
        // hardware where you know the offsets a priori.
        float tx_power_offset_db   = std::numeric_limits<float>::quiet_NaN();
        float rx_offset_db         = std::numeric_limits<float>::quiet_NaN();
        // Per-node crystal drift in ppm. NaN means "sample from
        // simulation.clock_drift_ppm_sigma". Set explicitly to pin a
        // node's clock skew (e.g. one slow + one fast node to stress
        // protocol timing tolerances).
        float clock_drift_ppm      = std::numeric_limits<float>::quiet_NaN();

        // Mobility — most nodes don't move (default 0). Set
        // velocity_mps > 0 + direction_deg to make a specific node
        // travel at constant speed in a fixed compass heading. Position
        // is updated each asymmetry_coherence_ms tick (so a 1 m/s walker
        // shifts ~60 m per update at the default coherence). Path-loss
        // for pairs involving the moving node is recomputed at each
        // update — mobile sensors test the routing layer's prune +
        // triggered-beacon convergence speed under topology change.
        // direction_deg follows compass convention: 0 = north, 90 = east.
        float velocity_mps         = 0.0f;
        float direction_deg        = 0.0f;
        // Lifecycle scheduling. 0 = "not scheduled" sentinels (today's
        // behavior). When start_at_ms > 0, the orchestrator keeps the
        // node fully off (no rx, tx, scripts, on_init) until that
        // sim-time. When dies_at_ms > 0, the orchestrator stops the
        // node fully at that sim-time. Each is enforced by
        // SimController via _node_alive + processLifecycleAtStep().
        unsigned long start_at_ms = 0;
        unsigned long dies_at_ms  = 0;

        // Authoring-time only: used by the webapp's SRTM+ITM
        // topology generator. The runtime physics model ignores
        // this field.
        float antenna_height_m = 1.5f;
    };
    std::vector<NodeDef> nodes;

    struct LinkDef {
        std::string from;
        std::string to;
        // snr + snr_std_dev are REQUIRED per explicit link (2026-07-20 review §1.3): an omitted snr
        // used to silently become a healthy 8 dB link, and the VARIANCE half silently became 0 (no
        // fading) — both the silent-optimism class. NaN sentinel = unset → validateConfig fails loud.
        float snr         = std::numeric_limits<float>::quiet_NaN();
        float rssi        = -80.0f;
        float snr_std_dev = std::numeric_limits<float>::quiet_NaN();
        float loss        = 0.0f;
        bool  bidir       = true;
    };

    struct TopologyConfig {
        std::vector<LinkDef> links;
    };
    TopologyConfig topology;

    // Deterministic forced-frame drops (R3.x lossy gate). Each directive
    // drops the matching frame(s) just before delivery to the receiver —
    // AFTER all physics gates — so it composes with, and is independent of,
    // sigma_db / Bernoulli `loss`. This is the only seed/sigma-independent
    // way to fire EXACTLY one protocol retry. Empty => OFF (zero overhead,
    // zero RNG draws; existing scenarios are byte-identical). Parsed from the
    // top-level "forced_drops" array. A drop emits a distinct `drop_forced`
    // event (not an RF-loss masquerade).
    //   from / to : sender / receiver node name ("" = any)
    //   label     : the TX frame label, e.g. "RTS"/"CTS"/"DATA"/"ACK" ("" = any)
    //   nth       : 1-based index of the first matching FRAME to drop
    //   count     : how many consecutive matching frames to drop
    // The counter advances once per physical FRAME (not per receiver): a
    // broadcast that reaches M nodes consumes 1 from `count`, and a frame in the
    // drop window is dropped to every receiver matching `to`. With a specific
    // `to`, that is the one reception by `to`.
    struct DropDirective {
        std::string from;
        std::string to;
        std::string label;
        int nth   = 1;
        int count = 1;
    };
    std::vector<DropDirective> drop_directives;

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
