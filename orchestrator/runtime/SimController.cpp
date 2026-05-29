// orchestrator/runtime/SimController.cpp
//
// Class-based stepper extracted from the original Loop.cpp::runSimulation.
// The per-step pipeline is byte-identical to the pre-refactor implementation:
//
//   1. processCommandsAtStep      - fire any scheduled cfg.commands[] whose
//                                    at_ms has arrived; dispatch via
//                                    ScriptedNode::onCommand and emit a
//                                    cmd_reply event with the script's reply.
//   2. deliverReceptionsForStep   - for every in-flight TX whose airtime
//                                    ends in this step, decide per-receiver
//                                    whether the packet survives loss +
//                                    collision and call ScriptedNode::onRecv
//                                    on survivors.
//   3. tickTimersForStep          - fire due timers on every node.
//   4. registerTransmissionsForStep - drain PendingTx queues, push them onto
//                                    the in-flight list, evaluate collisions
//                                    bidirectionally at TX-start time, and
//                                    emit a tx event.
//   5. advance                    - bump the virtual clock by step_ms.
//
// Several Y2 features are intentionally simplified or skipped here; the same
// TODO comments from the original Loop.cpp are preserved alongside the code.

#include "orchestrator/runtime/SimController.h"

#include "orchestrator/runtime/LuaHost.h"
#include "orchestrator/runtime/ScriptedNode.h"
#include "orchestrator/test_runner/ExpectRunner.h"

#include "core/clock/VirtualClock.h"
#include "core/events/EventLog.h"
#include "core/link/Geo.h"
#include "core/link/LinkModel.h"
#include "core/link/PathLossModel.h"
#include "core/physics/CollisionModel.h"
#include "core/physics/LbtModel.h"
#include "core/radio/SimRadio.h"
#include "core/topology/JsonConfig.h"

#include "json/json.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <random>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

// Resolve a node script path against multiple candidate locations so the
// orchestrator works regardless of the user's current working directory.
// Tried, in order:
//   1. absolute path (used as-is)
//   2. <config-dir>/<script>            (config-relative)
//   3. <config-dir>/../<script>         (sibling-of-config-dir; covers the
//                                        common test/<cfg>.json + examples/
//                                        <script>.lua repo-root layout)
//   4. <cwd>/<script>                   (backward compat for users whose
//                                        configs already assume cwd-relative)
// Returns the first existing absolute path; otherwise throws a
// std::runtime_error listing every candidate that was tried.
static std::string resolveScriptPath(const std::string& script_path,
                                     const std::string& config_source_path) {
    namespace fs = std::filesystem;
    fs::path p(script_path);
    std::vector<fs::path> candidates;

    if (p.is_absolute()) {
        candidates.push_back(p);
    } else {
        if (!config_source_path.empty()) {
            fs::path config_dir = fs::path(config_source_path).parent_path();
            candidates.push_back(config_dir / p);
            candidates.push_back(config_dir.parent_path() / p);
        }
        std::error_code cwd_ec;
        fs::path cwd = fs::current_path(cwd_ec);
        if (!cwd_ec) candidates.push_back(cwd / p);
    }

    for (const auto& c : candidates) {
        std::error_code ec;
        if (fs::exists(c, ec)) {
            std::error_code abs_ec;
            fs::path abs = fs::absolute(c, abs_ec);
            return abs_ec ? c.string() : abs.string();
        }
    }

    std::string msg = "cannot resolve script path '" + script_path + "'. Tried:\n";
    for (const auto& c : candidates) {
        msg += "  - " + c.string() + "\n";
    }
    throw std::runtime_error(msg);
}

// Build the CapturedSignal struct used by evaluateCollision().
template <typename InFlightT>
CapturedSignal toCaptured(const InFlightT& f, float snr_db_at_rcv) {
    CapturedSignal s{};
    s.src_node       = f.sender_id;
    s.snr_db         = snr_db_at_rcv;
    s.start_ms       = f.start_ms;
    s.end_ms         = f.end_ms;
    s.cr             = static_cast<uint8_t>(f.cr);
    s.pre_sym        = f.pre_sym;
    s.t_sym_ms       = f.t_sym_ms;
    s.t_preamble_ms  = f.t_preamble_ms;
    s.sf             = f.sf;
    return s;
}

static bool isMobileNode(const SimConfig::NodeDef& node) {
    return node.velocity_mps > 0.0f;
}

static bool isRtsLabel(const std::string& label) {
    return label == "RTS" || label == "RTS-fwd" || label == "RTS-rty";
}

struct NeighborSnr {
    int idx = -1;
    float snr = 0.0f;
    float rssi = 0.0f;
};

static void keepTopNeighbor(std::vector<NeighborSnr>& top, NeighborSnr value, size_t max_count) {
    top.push_back(value);
    std::sort(top.begin(), top.end(), [](const NeighborSnr& a, const NeighborSnr& b) {
        return a.snr > b.snr;
    });
    if (top.size() > max_count) top.resize(max_count);
}

static std::vector<int> visibilitySfsForNode(const SimConfig::NodeDef& node) {
    std::vector<int> sfs;
    auto add_sf = [&](int sf) {
        if (sf >= 5 && sf <= 12 && std::find(sfs.begin(), sfs.end(), sf) == sfs.end()) {
            sfs.push_back(sf);
        }
    };

    add_sf(node.sf);
    if (node.config.is_object()) {
        if (node.config.contains("routing_sf") && node.config["routing_sf"].is_number_integer()) {
            add_sf(node.config["routing_sf"].get<int>());
        }
        if (node.config.contains("allowed_data_sfs") && node.config["allowed_data_sfs"].is_array()) {
            for (const auto& v : node.config["allowed_data_sfs"]) {
                if (v.is_number_integer()) add_sf(v.get<int>());
            }
        }
    }
    std::sort(sfs.begin(), sfs.end());
    return sfs;
}

static int routingSfForNode(const SimConfig::NodeDef& node) {
    if (node.config.is_object() &&
        node.config.contains("routing_sf") &&
        node.config["routing_sf"].is_number_integer()) {
        int sf = node.config["routing_sf"].get<int>();
        if (sf >= 5 && sf <= 12) return sf;
    }
    return node.sf;
}

static bool infoNamesNextHop(const std::string& info, const std::string& node_name) {
    if (info.empty() || node_name.empty()) return false;
    return info.find("next=" + node_name) != std::string::npos;
}

}  // namespace

SimController::SimController(const SimConfig& cfg, std::ostream& events_out)
    : _cfg(cfg),
      _events_out(events_out),
      _clock(cfg.simulation.epoch_start),
      _rng(static_cast<std::mt19937::result_type>(cfg.simulation.seed)) {}

SimController::~SimController() = default;

int SimController::eventCount() const {
    return static_cast<int>(EventLog::events().size());
}

float SimController::linkSnrDb(int from, int to) const {
    if (!_links) return std::nanf("");
    LinkParams lp;
    if (!_links->getLink(from, to, lp)) return std::nanf("");
    return lp.snr;
}

int SimController::protocolNodeId(size_t runtime_id) const {
    if (runtime_id >= _nodes.size() || !_nodes[runtime_id]) {
        return static_cast<int>(runtime_id);
    }
    return _nodes[runtime_id]->protocolId();
}

void SimController::initialize() {
    if (_initialized) return;

    EventLog::setOutputStream(&_events_out);
    // Capture every emitted event into the in-memory buffer so the
    // ExpectRunner can read them at the end of the run.
    EventLog::clearBuffer();
    EventLog::enableBuffer();

    const int n = static_cast<int>(_cfg.nodes.size());

    // ---- Build node-name -> id map ------------------------------------------
    _name_to_id.clear();
    _name_to_id.reserve(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) {
        _name_to_id.emplace(_cfg.nodes[i].name, i);
    }

    // ---- Mutable per-node positions for mobility ----------------------------
    _node_lat.assign(static_cast<size_t>(n), 0.0);
    _node_lon.assign(static_cast<size_t>(n), 0.0);
    for (int i = 0; i < n; ++i) {
        _node_lat[(size_t)i] = _cfg.nodes[i].lat;
        _node_lon[(size_t)i] = _cfg.nodes[i].lon;
    }

    // ---- Link model ---------------------------------------------------------
    _links = std::make_unique<MatrixLinkModel>(n);

    // Path-loss baseline: when simulation.path_loss.present, compute
    // SNR/RSSI from haversine distance for every directed (i, j) pair
    // where both endpoints have lat/lon, including per-node TX/RX
    // offsets and per-pair shadow (so SNR(A→B) ≠ SNR(B→A) by default,
    // matching real LoRa). This populates the link matrix BEFORE the
    // explicit topology.links loop, so any explicit entries below
    // override the path-loss-derived per-pair values (useful for tests
    // that want surgical link tuning on top of automated defaults).
    // Gate the path-loss baseline on both `present` (operator wrote a
    // path_loss block at all) and model != "none" (the operator
    // explicitly wants no log-distance baseline — only pairs in
    // topology.links[] populate the link matrix). When skipped,
    // _path_loss stays nullptr; downstream code that consults it is
    // already null-guarded.
    if (_cfg.simulation.path_loss.present
        && _cfg.simulation.path_loss.model != "none") {
        PathLossConfig plc;
        plc.model                   = _cfg.simulation.path_loss.model;
        plc.alpha                   = _cfg.simulation.path_loss.alpha;
        plc.sigma_db                = _cfg.simulation.path_loss.sigma_db;
        plc.ref_distance_m          = _cfg.simulation.path_loss.ref_distance_m;
        plc.ref_loss_db             = _cfg.simulation.path_loss.ref_loss_db;
        plc.noise_floor_db          = _cfg.simulation.path_loss.noise_floor_db;
        plc.tx_power_dbm            = _cfg.simulation.path_loss.tx_power_dbm;
        plc.node_tx_offset_sigma_db = _cfg.simulation.path_loss.node_tx_offset_sigma_db;
        plc.node_rx_offset_sigma_db = _cfg.simulation.path_loss.node_rx_offset_sigma_db;
        plc.asymmetry_coherence_ms  = _cfg.simulation.path_loss.asymmetry_coherence_ms;
        _path_loss = std::make_unique<PathLossModel>(plc, _rng);
        _path_loss->initializeNodes(n);

        // Apply per-node JSON overrides AFTER initializeNodes() (which
        // sampled from the sigmas). NaN means "leave the sampled value."
        for (int i = 0; i < n; ++i) {
            _path_loss->setNodeTxOffset(i, _cfg.nodes[i].tx_power_offset_db);
            _path_loss->setNodeRxOffset(i, _cfg.nodes[i].rx_offset_db);
        }

        // Emit one node_link_profile per node so traces are reproducible
        // (asymmetry is deterministic given the seed) and debuggable —
        // a "this node has tx_offset = -4 dB" line in the log explains
        // why its packets routinely fail to land.
        for (int i = 0; i < n; ++i) {
            char json[256];
            std::snprintf(json, sizeof(json),
                "{\"tx_offset_db\":%.2f,\"rx_offset_db\":%.2f}",
                _path_loss->nodeTxOffset(i), _path_loss->nodeRxOffset(i));
            EventLog::logScriptEmit(i, 0, "node_link_profile", json);
        }

        int missing_loc_count = 0;
        for (int i = 0; i < n; ++i) {
            if (!_cfg.nodes[i].has_location) {
                ++missing_loc_count;
                continue;
            }
            for (int j = 0; j < n; ++j) {
                if (i == j) continue;
                if (!_cfg.nodes[j].has_location) continue;
                if (_cfg.simulation.path_loss.mobile_only &&
                    !isMobileNode(_cfg.nodes[i]) &&
                    !isMobileNode(_cfg.nodes[j])) {
                    continue;
                }
                const double d = lus::haversineDistanceMeters(
                    _node_lat[(size_t)i], _node_lon[(size_t)i],
                    _node_lat[(size_t)j], _node_lon[(size_t)j]);
                const auto sig = _path_loss->sampleDirectional(i, j, d);
                _links->setLink(i, j, sig.snr_db, sig.rssi_dbm,
                                /*snr_std_dev=*/static_cast<float>(
                                    _cfg.simulation.path_loss.sigma_db),
                                /*loss=*/0.0f);
            }
        }
        if (missing_loc_count > 0) {
            std::fprintf(stderr,
                "[lus] warning: %d node(s) missing lat/lon - no path-loss "
                "links computed for them\n",
                missing_loc_count);
        }

        if (plc.asymmetry_coherence_ms > 0) {
            _next_pair_shadow_resample_ms = plc.asymmetry_coherence_ms;
        }
    }

    // Explicit topology.links entries apply AFTER the path-loss baseline
    // (when present), overriding per-pair values. When path_loss is
    // absent, this is the only source of link configuration.
    //
    // Exception: links touching a mobile node stay path-loss-driven.
    // A generated/static topology.links matrix is a snapshot; applying it
    // to a moving endpoint would pin that endpoint's connectivity and
    // defeat the position-based recompute path.
    for (const auto& l : _cfg.topology.links) {
        auto fit = _name_to_id.find(l.from);
        auto tit = _name_to_id.find(l.to);
        if (fit == _name_to_id.end() || tit == _name_to_id.end()) continue;
        if (_path_loss &&
            (isMobileNode(_cfg.nodes[fit->second]) ||
             isMobileNode(_cfg.nodes[tit->second]))) {
            continue;
        }
        _links->setLink(fit->second, tit->second,
                        l.snr, l.rssi, l.snr_std_dev, l.loss);
        if (l.bidir) {
            _links->setLink(tit->second, fit->second,
                            l.snr, l.rssi, l.snr_std_dev, l.loss);
        }
    }

    // ---- Radios + nodes -----------------------------------------------------
    // bw in JSON is kHz (matches meshcore_real_sim convention); SimRadio takes Hz.
    _radios.clear();
    _nodes.clear();
    _radios.reserve(static_cast<size_t>(n));
    _nodes.reserve(static_cast<size_t>(n));

    // Resolve per-node sf_rx_set: empty config -> [node.sf] (single-SF,
    // matches real Semtech LoRa hardware). See SimController.h note.
    _node_sf_rx_set.assign(static_cast<size_t>(n), {});
    _node_tx_in_flight_until.assign(static_cast<size_t>(n), 0ULL);
    _node_last_tx_start_ms.assign(static_cast<size_t>(n), 0ULL);
    _node_last_tx_end_ms.assign(static_cast<size_t>(n), 0ULL);
    for (int i = 0; i < n; ++i) {
        if (_cfg.nodes[i].sf_rx_set.empty()) {
            const int node_sf = _cfg.nodes[i].sf;  // already merged with globals
            _node_sf_rx_set[i] = { node_sf };
        } else {
            _node_sf_rx_set[i] = _cfg.nodes[i].sf_rx_set;
        }
    }

    for (int i = 0; i < n; ++i) {
        const int sf = _cfg.nodes[i].sf;        // already merged with global defaults
        const int bw_khz = _cfg.nodes[i].bw;
        const int cr = _cfg.nodes[i].cr;
        _radios.emplace_back(std::make_unique<SimRadio>(
            _clock, sf, bw_khz * 1000, cr,
            _cfg.simulation.radio.rx_to_tx_delay_ms,
            _cfg.simulation.radio.tx_to_rx_delay_ms));
        // TODO(Y2): plumb cfg.nodes[i].tx_fail_prob through SimRadio::setTxFailProb
        // once the loop honours startSendRaw failure paths instead of always
        // staging InFlight entries unconditionally.

        _nodes.emplace_back(std::make_unique<ScriptedNode>(
            i, _cfg.nodes[i].name,
            _host, *_radios[i], _events_out, _clock, _rng));
        // Hand the node a stable pointer to its sf_rx_set slot so scripts
        // can retune at runtime via self:set_rx_sf(...). _node_sf_rx_set
        // was sized once via assign() above; the outer vector never
        // reallocates, so &_node_sf_rx_set[i] stays valid for the lifetime
        // of this controller.
        _nodes[i]->attachSfRxSet(&_node_sf_rx_set[i]);
        _nodes[i]->attachTxInFlightSlot(&_node_tx_in_flight_until[i]);
        // _lbt is constructed below; defer the LBT attach until then.
    }

    // Per-node clock drift + SF-switch delay. MUST be set before any
    // onInit fires because the script's first self:after() call (made
    // from on_init) reads _clock_drift_ppm to scale the wall delay; if
    // drift is still 0 at that moment, the very first timer of every
    // node is misscheduled.
    {
        std::normal_distribution<double> drift_dist(
            0.0, _cfg.simulation.clock_drift_ppm_sigma);
        for (int i = 0; i < n; ++i) {
            float ppm = _cfg.nodes[i].clock_drift_ppm;
            if (std::isnan(ppm)) {
                ppm = (_cfg.simulation.clock_drift_ppm_sigma > 0.0)
                          ? static_cast<float>(drift_dist(_rng))
                          : 0.0f;
            }
            _nodes[i]->setClockDriftPpm(ppm);
            _nodes[i]->setSfSwitchDelayMs(_cfg.simulation.radio.sf_switch_delay_ms);
            char json[256];
            std::snprintf(json, sizeof(json),
                "{\"clock_drift_ppm\":%.2f,\"sf_switch_delay_ms\":%.2f}",
                ppm, _cfg.simulation.radio.sf_switch_delay_ms);
            EventLog::logScriptEmit(i, 0, "node_clock_profile", json);
        }
    }

    // Register + load scripts (must precede onInit so `self` is populated).
    for (int i = 0; i < n; ++i) {
        const int protocol_node_id = _cfg.nodes[i].node_id >= 0
            ? _cfg.nodes[i].node_id
            : i;
        _nodes[i]->setProtocolId(protocol_node_id);
        // registerNode binds the Lua self:* methods to a ScriptedNode*, so it
        // needs the concrete type. Safe today: every node is a ScriptedNode.
        // TODO(S1): wrap in `if (engine == "lua")` once FirmwareNode lands —
        // firmware nodes skip Lua binding + loadScript entirely.
        _host.registerNode(i, static_cast<ScriptedNode*>(_nodes[i].get()),
                           protocol_node_id, _cfg.nodes[i].key_hash32);
        std::string resolved =
            resolveScriptPath(_cfg.nodes[i].script_path, _cfg.source_path);
        _host.loadScript(i, resolved);
    }

    // Expose the global `sim` table so scripts can drive the stepper. Bound
    // here, after script load and before on_init, so unusual scripts that
    // reach for sim:* during on_init still see it.
    _host.bindSimGlobals(*this);

    // sim_start lifecycle event — emitted before per-node onInit so
    // downstream tooling (visualisers, log analyzers) sees a clear
    // bookend marker at the start of the NDJSON stream. Matches upstream
    // Orchestrator::initSimulation (line ~1002).
    EventLog::simStart(0,
                       n,
                       _cfg.simulation.step_ms,
                       _cfg.simulation.warmup_ms,
                       /*hot_start=*/false);

    // Sanity check: warn if step_ms is coarser than the shortest LoRa
    // symbol time across all nodes. Upstream emits the same diagnostic
    // (Orchestrator::initSimulation lines ~1032-1046) — physics
    // resolution suffers when the tick clock is slower than the radio's
    // own symbol cadence. Pure diagnostic; no behavioural change.
    {
        double min_t_sym = 1e9;
        for (auto& r : _radios) {
            const double t = r->getSymbolMs();
            if (t < min_t_sym) min_t_sym = t;
        }
        if (min_t_sym < 1e9 &&
            static_cast<double>(_cfg.simulation.step_ms) > min_t_sym) {
            std::fprintf(stderr,
                "lus: warning — step_ms=%d exceeds min t_sym=%.3fms "
                "across nodes; physics resolution may be too coarse\n",
                _cfg.simulation.step_ms, min_t_sym);
        }
    }

    // Per-node startup offsets. Default 0 (synchronous init at t=0); if
    // simulation.node_startup_jitter_ms > 0, draw each from [0, jitter]
    // using _rng. The jitter==0 path makes ZERO _rng draws so existing
    // scenarios stay bit-identical.
    _node_init_at_ms.assign(static_cast<size_t>(n), 0);
    if (_cfg.simulation.node_startup_jitter_ms > 0) {
        std::uniform_int_distribution<int> jdist(
            0, _cfg.simulation.node_startup_jitter_ms);
        for (int i = 0; i < n; ++i) {
            _node_init_at_ms[i] = static_cast<uint64_t>(jdist(_rng));
        }
    }

    // Per-node lifecycle. _node_alive[i] is the runtime gate: false
    // until start_at_ms fires (then node_started + on_init), false
    // again after dies_at_ms (then node_died). For nodes with
    // start_at_ms > 0 we override the jitter assignment so on_init
    // fires precisely at the configured time (jitter doesn't apply).
    _node_alive.assign(static_cast<size_t>(n), true);
    for (int i = 0; i < n; ++i) {
        if (_cfg.nodes[i].start_at_ms > 0) {
            _node_alive[i] = false;
            _node_init_at_ms[i] =
                static_cast<uint64_t>(_cfg.nodes[i].start_at_ms);
        }
    }

    // Fire on_init at t=0 for nodes whose offset is 0; the rest are
    // deferred to processStartupAtStep, which fires them once _now_ms
    // catches up to their offset. node_ready is emitted at the actual
    // init time (not always 0), so external observers see the staggered
    // boot. Until on_init fires, ScriptedNode::onRecv/onCommand/onRadioBusy
    // early-return — modeling a powered-off radio.
    for (int i = 0; i < n; ++i) {
        if (_node_init_at_ms[i] != 0) continue;
        // Inject simulation-level fields so the script can read them in
        // on_init without per-node duplication (e.g. dv_dual_sf.lua reads
        // _sim_warmup_ms to switch between fast learning-phase beacons
        // and slow operational beacons). Underscore prefix marks these
        // as runtime-injected, not user-configured.
        nlohmann::json cfg = _cfg.config.is_object()
                              ? _cfg.config
                              : nlohmann::json::object();
        if (_cfg.nodes[i].config.is_object()) {
            cfg.update(_cfg.nodes[i].config);
        }
        cfg["_sim_warmup_ms"] = _cfg.simulation.warmup_ms;
        cfg["_sim_bw_hz"]     = _cfg.nodes[i].bw * 1000;  // bw is kHz in JSON
        cfg["_sim_cr"]        = _cfg.nodes[i].cr;
        cfg["_sim_duty_cycle"]           = _cfg.simulation.radio.duty_cycle;
        cfg["_sim_duty_cycle_window_ms"] = _cfg.simulation.radio.duty_cycle_window_ms;
        _nodes[i]->onInit(cfg);
        _nodes[i]->markInitialized();
        std::string role = "script";
        const auto& nc = _cfg.nodes[i].config;
        if (nc.is_object()) {
            auto it = nc.find("role");
            if (it != nc.end() && it->is_string()) {
                role = it->get<std::string>();
            }
        }
        EventLog::nodeReady(0,
                            _cfg.nodes[i].name.c_str(),
                            role.c_str(),
                            /*pub_key=*/nullptr, /*key_len=*/0,
                            _cfg.nodes[i].has_location,
                            _cfg.nodes[i].lat,
                            _cfg.nodes[i].lon,
                            /*firmware=*/nullptr);
    }

    // ---- Main loop state ----------------------------------------------------
    _command_fired.assign(_cfg.commands.size(), false);
    _in_flight.clear();

    // Per-link fading state (directed n*n; see SimController.h note).
    // Zero-init: first delivery on a link sees last_update_ms == 0 so dt
    // equals `now`, which in OU mode collapses alpha to ~0 → effectively
    // i.i.d. for the first sample. That's correct: there's no prior
    // history to correlate against.
    _fading.assign(static_cast<size_t>(n) * static_cast<size_t>(n), LinkFadingState{});
    _fading_last_update_ms.assign(static_cast<size_t>(n) * static_cast<size_t>(n), 0ULL);

    // LBT model — consulted by registerTransmissionsForStep before each
    // pending TX (isChannelBusy) and updated after each successful TX
    // (notifyChannelBusy per reachable observer, gated by shouldNotifyBusy
    // for the SNR-modulated CAD-miss roll). See R.1.6.
    _lbt = std::make_unique<LbtModel>(
        n,
        LbtConfig{_cfg.simulation.radio.cad_miss_prob,
                  _cfg.simulation.radio.cad_reliable_snr,
                  _cfg.simulation.radio.cad_marginal_snr},
        _cfg.simulation.seed ^ 0xCAFEBABEull);

    // Hand each ScriptedNode a borrowed pointer to the LBT model so
    // self:channel_busy_until() can answer without going through SimController.
    for (int i = 0; i < n; ++i) {
        _nodes[i]->attachLbtModel(_lbt.get());
    }

    // (clock-drift / sf-switch setup moved earlier — must precede onInit.)

    // Collision config from radio block.
    _coll_cfg = CollisionConfig{};
    _coll_cfg.capture_locked_db   = _cfg.simulation.radio.capture_locked_db;
    _coll_cfg.capture_unlocked_db = _cfg.simulation.radio.capture_unlocked_db;
    // preamble_lock_symbols stays at upstream's default (6).

    _now_ms = 0;
    _warmup_end_emitted = false;
    _initialized = true;
}

void SimController::processLifecycleAtStep() {
    const uint64_t now = _now_ms;
    const int n = static_cast<int>(_nodes.size());

    // Births: for each not-yet-alive node whose start_at_ms has been
    // reached, flip _node_alive and emit node_started. The matching
    // on_init runs in processStartupAtStep (called after this).
    for (int i = 0; i < n; ++i) {
        const uint64_t start_at =
            static_cast<uint64_t>(_cfg.nodes[i].start_at_ms);
        if (!_node_alive[i] && !_nodes[i]->isInitialized()
            && start_at > 0 && now >= start_at) {
            _node_alive[i] = true;
            EventLog::nodeStarted(static_cast<unsigned long>(now),
                                  _cfg.nodes[i].name.c_str());
        }
    }

    // Deaths: for each currently-alive node whose dies_at_ms has been
    // reached, flip _node_alive, emit node_died, and drop any in-flight
    // TX from that sender so receivers don't see ghost deliveries.
    //
    // Note: LBT busy notifications already broadcast to observers at
    // TX-start time (registerTransmissionsForStep -> notifyChannelBusy)
    // are not retracted here. Observers will continue treating the
    // channel as busy until the original TX's would-be end_ms. This is
    // physically defensible (the receiver locked the preamble before
    // the transmitter was unplugged; from its POV the channel was busy
    // for some duration before it noticed the silence) and avoids
    // having to walk the LBT model from here. If a future test exposes
    // a behavioral problem, retract via _lbt->clearBusyFor(i) here.
    for (int i = 0; i < n; ++i) {
        const uint64_t dies_at =
            static_cast<uint64_t>(_cfg.nodes[i].dies_at_ms);
        if (_node_alive[i] && dies_at > 0 && now >= dies_at) {
            _node_alive[i] = false;
            EventLog::nodeDied(static_cast<unsigned long>(now),
                               _cfg.nodes[i].name.c_str());
            _in_flight.erase(
                std::remove_if(_in_flight.begin(), _in_flight.end(),
                               [i](const InFlight& f) { return f.sender_id == i; }),
                _in_flight.end());
            // Clear the per-node "TX in flight until" slot so any later
            // reader (Lua self:tx_in_flight() via api_tx_in_flight, or
            // future code paths) sees 0 (idle) rather than a stale
            // end_ms pointing to a TX we just evaporated.
            if (i < static_cast<int>(_node_tx_in_flight_until.size())) {
                _node_tx_in_flight_until[i] = 0;
            }
        }
    }
}

void SimController::processStartupAtStep() {
    const uint64_t now = _now_ms;
    const int n = static_cast<int>(_nodes.size());
    for (int i = 0; i < n; ++i) {
        if (_nodes[i]->isInitialized()) continue;
        if (_node_init_at_ms[i] > now) continue;

        // Same _sim_* injection as the synchronous-init path above —
        // keep both paths in sync so jitter-staged nodes see the same
        // simulation-level fields.
        nlohmann::json cfg = _cfg.config.is_object()
                              ? _cfg.config
                              : nlohmann::json::object();
        if (_cfg.nodes[i].config.is_object()) {
            cfg.update(_cfg.nodes[i].config);
        }
        cfg["_sim_warmup_ms"] = _cfg.simulation.warmup_ms;
        cfg["_sim_bw_hz"]     = _cfg.nodes[i].bw * 1000;  // bw is kHz in JSON
        cfg["_sim_cr"]        = _cfg.nodes[i].cr;
        cfg["_sim_duty_cycle"]           = _cfg.simulation.radio.duty_cycle;
        cfg["_sim_duty_cycle_window_ms"] = _cfg.simulation.radio.duty_cycle_window_ms;
        _nodes[i]->onInit(cfg);
        _nodes[i]->markInitialized();

        std::string role = "script";
        const auto& nc = _cfg.nodes[i].config;
        if (nc.is_object()) {
            auto it = nc.find("role");
            if (it != nc.end() && it->is_string()) {
                role = it->get<std::string>();
            }
        }
        EventLog::nodeReady(static_cast<unsigned long>(now),
                            _cfg.nodes[i].name.c_str(),
                            role.c_str(),
                            /*pub_key=*/nullptr, /*key_len=*/0,
                            _cfg.nodes[i].has_location,
                            _cfg.nodes[i].lat,
                            _cfg.nodes[i].lon,
                            /*firmware=*/nullptr);
    }
}

void SimController::processCommandsAtStep() {
    const uint64_t now = _now_ms;
    for (size_t k = 0; k < _cfg.commands.size(); ++k) {
        if (_command_fired[k]) continue;
        if (_cfg.commands[k].at_ms > now) continue;

        const auto& cmd = _cfg.commands[k];

        // Lua-only commands (cmd.lua_fn set) are deferred to Y2.
        if (!cmd.lua_fn.empty()) {
            // TODO(Y2): dispatch cmd.lua_fn through LuaHost (it needs a
            // generic top-level callback registry; not in T13).
            _command_fired[k] = true;
            continue;
        }

        auto it = _name_to_id.find(cmd.node);
        if (it == _name_to_id.end()) {
            // Unknown node — should be caught at validation, but be safe.
            _command_fired[k] = true;
            continue;
        }
        const int target = it->second;
        if (!_node_alive[target]) {
            // If the target has DIED (dies_at_ms passed), drop the
            // command rather than retrying every step until duration_ms.
            // If it hasn't been BORN yet (start_at_ms ahead of now), keep
            // it queued — the same command should fire when it boots.
            const uint64_t dies_at =
                static_cast<uint64_t>(_cfg.nodes[target].dies_at_ms);
            if (dies_at > 0 && now >= dies_at) {
                EventLog::cmdReply(static_cast<unsigned long>(now),
                                   _nodes[target]->name().c_str(),
                                   cmd.command.c_str(),
                                   "ERROR: target node has died");
                _command_fired[k] = true;
            }
            continue;
        }
        std::string reply = _nodes[target]->onCommand(cmd.command);
        EventLog::cmdReply(static_cast<unsigned long>(now),
                           _nodes[target]->name().c_str(),
                           cmd.command.c_str(),
                           reply.c_str());
        _command_fired[k] = true;
    }
}

void SimController::deliverReceptionsForStep() {
    const uint64_t now = _now_ms;
    const int n = static_cast<int>(_cfg.nodes.size());
    const uint64_t warmup_ms = static_cast<uint64_t>(_cfg.simulation.warmup_ms);
    const bool in_warmup = (now < warmup_ms);

    // During warmup we skip the in-flight pipeline entirely (matching
    // upstream Orchestrator::executeStep — see lines ~1095-1126: the
    // `if (!in_warmup) deliverReceptions(...)` guard, and the
    // `if (in_warmup) routePackets(...) else registerTransmissions(...)`
    // branch). routePackets is the instant-delivery handler; we
    // implement its equivalent below in registerTransmissionsForStep.
    std::vector<size_t> ended;
    if (!in_warmup) {
        // Indices of in_flight entries whose airtime has elapsed by `now`.
        ended.reserve(_in_flight.size());
        for (size_t i = 0; i < _in_flight.size(); ++i) {
            if (_in_flight[i].end_ms <= now) ended.push_back(i);
        }
    }

    for (size_t idx : ended) {
        const InFlight& tx = _in_flight[idx];

        // If the SENDER died after starting this in-flight TX,
        // processLifecycleAtStep already removed its _in_flight
        // entries, so we shouldn't see this branch — defensive guard
        // only.
        if (!_node_alive[tx.sender_id]) continue;

        for (int rcv = 0; rcv < n; ++rcv) {
            if (rcv == tx.sender_id) continue;
            const bool intended_rts_next =
                isRtsLabel(tx.label) && infoNamesNextHop(tx.info, _nodes[rcv]->name());
            // Skip dead / unborn receivers. For the intended RTS next-hop,
            // emit a diagnostic mark so setup attribution can distinguish
            // "receiver inactive" from "RF loss not observed".
            if (!_node_alive[rcv]) {
                if (intended_rts_next) {
                    EventLog::dropReceiverInactive(
                        static_cast<unsigned long>(now),
                        _nodes[tx.sender_id]->name().c_str(),
                        _nodes[rcv]->name().c_str(),
                        "node_not_alive",
                        reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                        static_cast<int>(tx.bytes.size()),
                        static_cast<uint32_t>(tx.end_ms - tx.start_ms),
                        tx.sf, tx.bw_hz,
                        tx.label.empty() ? nullptr : tx.label.c_str(),
                        tx.info.empty() ? nullptr : tx.info.c_str());
                }
                continue;
            }

            LinkParams lp;
            if (!_links->getLink(tx.sender_id, rcv, lp)) {
                if (intended_rts_next) {
                    EventLog::dropNoLink(
                        static_cast<unsigned long>(now),
                        _nodes[tx.sender_id]->name().c_str(),
                        _nodes[rcv]->name().c_str(),
                        reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                        static_cast<int>(tx.bytes.size()),
                        static_cast<uint32_t>(tx.end_ms - tx.start_ms),
                        tx.sf, tx.bw_hz,
                        tx.label.empty() ? nullptr : tx.label.c_str(),
                        tx.info.empty() ? nullptr : tx.info.c_str());
                }
                continue;
            }

            // Per-link fading. advanceFading() is a no-op when
            // lp.snr_std_dev <= 0 (returns 0.0f), so configs without
            // fading remain bit-exactly deterministic. Indexing is
            // directed (sender * n + rcv) so forward/reverse links can
            // fade independently. snr_coherence_ms is a float in JSON
            // but the OU helper takes uint64_t — cast at the call site.
            const size_t link_idx =
                static_cast<size_t>(tx.sender_id) * static_cast<size_t>(n)
                + static_cast<size_t>(rcv);
            _fading_last_update_ms[link_idx] = now;
            const uint64_t coh_ms = static_cast<uint64_t>(
                _cfg.simulation.radio.snr_coherence_ms);
            const float fade_offset =
                advanceFading(_fading[link_idx],
                              lp.snr_std_dev,
                              coh_ms,
                              /*step_ms=*/now,
                              _rng);
            const float snr_at_rcv = lp.snr + fade_offset;

            // SF-dependent SNR threshold for the packet's SF. We
            // compute this once per (tx, rcv) pair and use it to gate
            // every "would-have-heard" verdict below. See
            // SimRadio::getSnrThreshold(int sf) (R.1.2) and
            // Semtech AN1200.22 Table 13 for the per-SF demodulator
            // floors. The threshold uses the PACKET's SF, not the
            // receiver's configured one — a single-channel LoRa
            // modem tunes to the packet's SF on each preamble.
            const float thr = SimRadio::getSnrThreshold(tx.sf);
            const bool would_decode = (snr_at_rcv >= thr);

            // Collision and sf_mismatch are gated by would_decode:
            // for a far-away receiver where the signal is below the
            // demodulator floor, the modem never sees the packet at
            // all (no event). drop_weak below is the legitimate
            // "wouldn't have heard" event when SF matches.
            //
            // Order: collision → sf_mismatch → drop_weak → drop_loss
            //        → drop_halfduplex → rx.

            // Collision check is resolved at TX-start time
            // (see registerTransmissionsForStep below — bidirectional
            // evaluateCollision matching upstream's behaviour). We
            // consult the per-receiver flag here. Skip silently if
            // the rcv was below threshold — both the packet and the
            // interferer were too weak to have been heard.
            if (rcv < static_cast<int>(tx.collided_at_rcv.size()) &&
                tx.collided_at_rcv[rcv]) {
                if (!would_decode) continue;  // off-net, silent
                const int   worst_interferer     = tx.interferer_at_rcv[rcv];
                const float worst_interferer_snr = tx.interferer_snr_at_rcv[rcv];
                const float snr_margin = snr_at_rcv - worst_interferer_snr;
                EventLog::collision(
                    static_cast<unsigned long>(now),
                    _nodes[tx.sender_id]->name().c_str(),
                    _nodes[rcv]->name().c_str(),
                    snr_at_rcv, lp.rssi,
                    reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                    static_cast<int>(tx.bytes.size()),
                    static_cast<uint32_t>(tx.end_ms - tx.start_ms),
                    tx.sf, tx.bw_hz,
                    worst_interferer >= 0 ? _nodes[worst_interferer]->name().c_str() : nullptr,
                    worst_interferer_snr,
                    snr_margin);
                continue;
            }

            // SF-mismatch gate (R.1.7). Real Semtech LoRa hardware
            // (SX1262/SX1276/LR1110/SX1280) decodes only the SF it is
            // currently tuned to — confirmed across all chip-family
            // datasheets and AN1200.85. If the packet's SF is not in
            // this receiver's sf_rx_set, the modem never sees it.
            // The default sf_rx_set is [node.sf] (single-SF); configs
            // can opt into multi-SF reception by listing more entries.
            // We emit drop_sf_mismatch only for receivers that would
            // have decoded the packet at the correct SF; otherwise
            // they're effectively off-net and silent.
            const auto& rx_set = _node_sf_rx_set[rcv];
            if (std::find(rx_set.begin(), rx_set.end(), tx.sf) == rx_set.end()) {
                if (!would_decode) continue;  // off-net, silent
                // -1 in the rx_sf field flags a multi-SF / scanner
                // receiver; otherwise emit the single configured SF.
                const int rx_sf_field = (rx_set.size() == 1) ? rx_set[0] : -1;
                EventLog::dropSfMismatch(
                    static_cast<unsigned long>(now),
                    _nodes[tx.sender_id]->name().c_str(),
                    _nodes[rcv]->name().c_str(),
                    tx.sf, rx_sf_field,
                    snr_at_rcv, lp.rssi,
                    reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                    static_cast<int>(tx.bytes.size()),
                    static_cast<uint32_t>(tx.end_ms - tx.start_ms),
                    tx.bw_hz);
                continue;
            }

            // SF matches and we haven't collided. drop_weak captures
            // "right SF, signal below threshold."
            if (!would_decode) {
                EventLog::dropWeak(
                    static_cast<unsigned long>(now),
                    _nodes[tx.sender_id]->name().c_str(),
                    _nodes[rcv]->name().c_str(),
                    snr_at_rcv, thr,
                    reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                    static_cast<int>(tx.bytes.size()),
                    tx.sf, tx.bw_hz);
                continue;
            }

            // Probabilistic decode at marginal SNR. Real Semtech chips
            // don't present a hard cliff at threshold — PER follows a
            // sigmoid (~50% at threshold, ~3 dB to halve PER above).
            // Without this, snr = threshold + epsilon decodes with prob 1
            // and snr = threshold − epsilon with prob 0; that masks bugs
            // around marginal links. Disabled by setting steepness to 0
            // (analytic-test escape hatch).
            const float steep = _cfg.simulation.radio.decode_margin_steepness_db;
            if (steep > 0.0f) {
                const float margin = snr_at_rcv - thr;
                const float per = 1.0f / (1.0f + std::exp(margin / steep));
                std::uniform_real_distribution<float> u(0.0f, 1.0f);
                if (u(_rng) < per) {
                    EventLog::dropWeak(
                        static_cast<unsigned long>(now),
                        _nodes[tx.sender_id]->name().c_str(),
                        _nodes[rcv]->name().c_str(),
                        snr_at_rcv, thr,
                        reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                        static_cast<int>(tx.bytes.size()),
                        tx.sf, tx.bw_hz);
                    continue;
                }
            }

            // RX-side preamble miss. Even decodable frames are missed by
            // real RFICs at a few-percent rate — AGC settling on a strong
            // adjacent signal, FIFO scheduling, transient interference
            // below the demod floor. Distinct from cad_miss_prob (LBT
            // side). Default 0.02 = 2 %; set to 0 for analytic tests.
            const float miss_prob = _cfg.simulation.radio.rx_preamble_miss_prob;
            if (miss_prob > 0.0f) {
                std::uniform_real_distribution<float> u(0.0f, 1.0f);
                if (u(_rng) < miss_prob) {
                    EventLog::dropPreambleMiss(
                        static_cast<unsigned long>(now),
                        _nodes[tx.sender_id]->name().c_str(),
                        _nodes[rcv]->name().c_str(),
                        miss_prob,
                        reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                        static_cast<int>(tx.bytes.size()),
                        static_cast<uint32_t>(tx.end_ms - tx.start_ms),
                        tx.sf, tx.bw_hz);
                    continue;
                }
            }

            // Per-link Bernoulli loss.
            if (lp.loss > 0.0f) {
                std::uniform_real_distribution<float> u(0.0f, 1.0f);
                if (u(_rng) < lp.loss) {
                    EventLog::dropLoss(
                        static_cast<unsigned long>(now),
                        _nodes[tx.sender_id]->name().c_str(),
                        _nodes[rcv]->name().c_str(),
                        lp.loss,
                        reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                        static_cast<int>(tx.bytes.size()),
                        tx.sf, tx.bw_hz);
                    continue;
                }
            }

            // SF-retune blind window. After self:set_rx_sf(...), the
            // PLL is relocking and any preamble that arrives during the
            // settling window is missed by real Semtech hardware. We
            // approximate by checking the frame's start_ms against the
            // receiver's _rx_blind_until_ms (set when api_set_rx_sf
            // fires). Disabled when sf_switch_delay_ms is 0.
            if (tx.start_ms < _nodes[rcv]->rxBlindUntilMs()) {
                EventLog::dropRxBlind(
                    static_cast<unsigned long>(now),
                    _nodes[tx.sender_id]->name().c_str(),
                    _nodes[rcv]->name().c_str(),
                    _nodes[rcv]->rxBlindUntilMs(),
                    reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                    static_cast<int>(tx.bytes.size()),
                    static_cast<uint32_t>(tx.end_ms - tx.start_ms),
                    tx.sf, tx.bw_hz);
                continue;
            }

            // Strict half-duplex enforcement: a node can't receive while
            // it's transmitting. If rcv has any of its own in-flight TX
            // overlapping [tx.start_ms, tx.end_ms] (any time during the
            // incoming packet's airtime), the radio was busy TX'ing and
            // missed the packet — emit drop_halfduplex instead of rx.
            bool rcv_was_tx = false;
            for (const auto& other : _in_flight) {
                if (other.sender_id != rcv) continue;
                if (other.start_ms < tx.end_ms && other.end_ms > tx.start_ms) {
                    rcv_was_tx = true;
                    break;
                }
            }
            // Also catch a receiver TX that overlapped this frame's airtime but
            // already ended (compacted out of _in_flight before this frame is
            // delivered at its end_ms). The frame's preamble still arrived while
            // the receiver was transmitting, so the radio never locked on it.
            if (!rcv_was_tx
                && _node_last_tx_start_ms[(size_t)rcv] < tx.end_ms
                && _node_last_tx_end_ms[(size_t)rcv]   > tx.start_ms) {
                rcv_was_tx = true;
            }
            if (rcv_was_tx) {
                EventLog::dropHalfDuplex(
                    static_cast<unsigned long>(now),
                    _nodes[tx.sender_id]->name().c_str(),
                    _nodes[rcv]->name().c_str(),
                    reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                    static_cast<int>(tx.bytes.size()),
                    static_cast<uint32_t>(tx.end_ms - tx.start_ms),
                    tx.sf, tx.bw_hz);
                continue;
            }

            // Deliver to the script.
            const int protocol_sender_id = _nodes[tx.sender_id]->protocolId();
            _nodes[rcv]->onRecv(tx.bytes, snr_at_rcv, lp.rssi,
                                /*link_id=*/0,
                                /*src_id=*/protocol_sender_id,
                                /*sim_ms=*/now);
            // Use the PACKET's sf/bw/cr (= the receiver's at demod time,
            // since LoRa requires sf+bw match for successful rx). Don't
            // read from `_radios[rcv]->getSF()` here — the script's
            // onRecv handler may have retuned the radio (e.g. back to
            // routing_sf for the next beacon) before we get here.
            EventLog::rx(static_cast<unsigned long>(now),
                         _nodes[tx.sender_id]->name().c_str(),
                         _nodes[rcv]->name().c_str(),
                         snr_at_rcv, lp.rssi,
                         reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                         static_cast<int>(tx.bytes.size()),
                         static_cast<uint32_t>(tx.end_ms - tx.start_ms),
                         tx.sf, tx.bw_hz, tx.cr);
        }
    }

    // Clear the per-sender tx-in-flight slot for any entry whose airtime
    // ended this step, so self:tx_in_flight() returns 0 again. Done before
    // the erase so we still see the ended entries.
    for (const auto& f : _in_flight) {
        if (f.end_ms <= now &&
            f.sender_id >= 0 &&
            (size_t)f.sender_id < _node_tx_in_flight_until.size()) {
            // Only clear if this is the slot's current value — guards against
            // a node that registered a new TX immediately after this one
            // ended (slot would already point at the newer end_ms).
            if (_node_tx_in_flight_until[(size_t)f.sender_id] == f.end_ms) {
                _node_tx_in_flight_until[(size_t)f.sender_id] = 0;
            }
        }
    }

    // Compact in_flight: remove ended entries.
    _in_flight.erase(
        std::remove_if(_in_flight.begin(), _in_flight.end(),
                       [now](const InFlight& f) { return f.end_ms <= now; }),
        _in_flight.end());
}

void SimController::tickTimersForStep() {
    const uint64_t now = _now_ms;
    const int n = static_cast<int>(_cfg.nodes.size());
    for (int i = 0; i < n; ++i) {
        if (!_node_alive[i]) continue;
        _nodes[i]->tickTimers(now);
    }
}

void SimController::registerTransmissionsForStep() {
    const uint64_t now = _now_ms;
    const int n = static_cast<int>(_cfg.nodes.size());
    const uint64_t warmup_ms = static_cast<uint64_t>(_cfg.simulation.warmup_ms);
    const bool in_warmup = (now < warmup_ms);

    // During warmup, route every drained TX instantly to all reachable
    // receivers — no airtime delay, no collision check, no link loss
    // (mirrors upstream routePackets at lines ~198-228). tx + rx events
    // are still emitted with the computed airtime so downstream
    // visualisers see the wire activity; only the physics path is
    // bypassed. The intent is to let scripts establish steady state
    // (route caches, advert exchanges, etc.) before the stress-test
    // physics phase starts.
    if (in_warmup) {
        for (int i = 0; i < n; ++i) {
            if (!_node_alive[i]) continue;
            for (auto& p : _nodes[i]->drainPendingTxs()) {
                const int sf    = (p.sf    >= 0) ? p.sf    : _radios[i]->getSF();
                const int bw_hz = (p.bw_hz >= 0) ? p.bw_hz : _radios[i]->getBwHz();
                const int cr    = (p.cr    >= 0) ? p.cr    : _radios[i]->getCR();
                const int pre   = (p.preamble_sym >= 0)
                                    ? p.preamble_sym
                                    : _radios[i]->getPreambleSymbols();
                _radios[i]->setRadioParams(sf, bw_hz, cr);
                _radios[i]->setPreambleSymbols(pre);

                const uint32_t airtime =
                    _radios[i]->getEstAirtimeFor(static_cast<int>(p.bytes.size()));

                EventLog::tx(static_cast<unsigned long>(now),
                             _nodes[i]->name().c_str(),
                             reinterpret_cast<const uint8_t*>(p.bytes.data()),
                             static_cast<int>(p.bytes.size()),
                             airtime,
                             sf, bw_hz, cr,
                             p.label.empty() ? nullptr : p.label.c_str(),
                             p.info.empty()  ? nullptr : p.info.c_str());

                for (int r = 0; r < n; ++r) {
                    if (r == i) continue;
                    if (!_node_alive[r]) continue;
                    LinkParams lp;
                    if (!_links->getLink(i, r, lp)) continue;
                    const int protocol_sender_id = _nodes[i]->protocolId();
                    _nodes[r]->onRecv(p.bytes, lp.snr, lp.rssi,
                                      /*link_id=*/0,
                                      /*src_id=*/protocol_sender_id,
                                      /*sim_ms=*/now);
                    // Use the packet's sf/bw/cr — see comment on the
                    // matching block in the main rx path. The receiver's
                    // sf at demod time equals the sender's; reading from
                    // _radios[r] would capture any post-onRecv retune.
                    EventLog::rx(static_cast<unsigned long>(now),
                                 _nodes[i]->name().c_str(),
                                 _nodes[r]->name().c_str(),
                                 lp.snr, lp.rssi,
                                 reinterpret_cast<const uint8_t*>(p.bytes.data()),
                                 static_cast<int>(p.bytes.size()),
                                 airtime,
                                 sf, bw_hz, cr);
                }
            }
        }
        return;
    }

    for (int i = 0; i < n; ++i) {
        if (!_node_alive[i]) continue;
        for (auto& p : _nodes[i]->drainPendingTxs()) {
            const int sf    = (p.sf    >= 0) ? p.sf    : _radios[i]->getSF();
            const int bw_hz = (p.bw_hz >= 0) ? p.bw_hz : _radios[i]->getBwHz();
            const int cr    = (p.cr    >= 0) ? p.cr    : _radios[i]->getCR();
            const int pre   = (p.preamble_sym >= 0)
                                ? p.preamble_sym
                                : _radios[i]->getPreambleSymbols();
            _radios[i]->setRadioParams(sf, bw_hz, cr);
            _radios[i]->setPreambleSymbols(pre);

            const uint32_t airtime =
                _radios[i]->getEstAirtimeFor(static_cast<int>(p.bytes.size()));

            // Half-duplex (sender side): a node can't initiate a new TX
            // while its previous TX is still in flight. Real hardware
            // has one PA path; the second TX has to wait. _in_flight is
            // already compacted (deliverReceptionsForStep ran first) so
            // any entry with sender_id == i still has end_ms > now.
            bool self_tx_in_flight = false;
            for (const auto& other : _in_flight) {
                if (other.sender_id == i) { self_tx_in_flight = true; break; }
            }
            // LoRa physical packet size limit (8-bit length register on
            // SX126x/SX1276 → 255 bytes max for the *entire* on-air frame,
            // not just the app-level payload). Anything bigger is unphysical
            // — the chip would refuse to TX, or RX would garble. Drop here
            // and surface as tx_oversized so scripts/tests see it instead
            // of getting a silent over-the-wire frame that real hardware
            // would never produce. Per-sim configurable via
            // simulation.radio.max_packet_bytes.
            if ((int)p.bytes.size() > _cfg.simulation.radio.max_packet_bytes) {
                EventLog::txOversized(static_cast<unsigned long>(now),
                                      _nodes[i]->name().c_str(),
                                      static_cast<int>(p.bytes.size()),
                                      _cfg.simulation.radio.max_packet_bytes,
                                      sf,
                                      p.label.empty() ? nullptr : p.label.c_str(),
                                      p.info.empty()  ? nullptr : p.info.c_str());
                RadioBusyInfo bi;
                bi.reason        = "oversized";
                bi.len           = static_cast<int>(p.bytes.size());
                bi.sf            = sf;
                bi.label         = p.label;
                bi.tx_info       = p.info;
                bi.busy_until_ms = 0;   // not a wait — the frame is rejected outright
                _nodes[i]->onRadioBusy(bi);
                continue;
            }

            if (self_tx_in_flight) {
                // Find this sender's still-in-flight TX so we can report
                // its end_ms as busy_until_ms. There's only ever one such
                // entry (a node already deferred can't push another).
                uint64_t busy_until = 0;
                for (const auto& f : _in_flight) {
                    if (f.sender_id == i && f.end_ms > now) {
                        busy_until = f.end_ms;
                        break;
                    }
                }
                RadioBusyInfo bi;
                bi.reason        = "self_tx_in_flight";
                bi.len           = static_cast<int>(p.bytes.size());
                bi.sf            = sf;
                bi.label         = p.label;
                bi.tx_info       = p.info;
                bi.busy_until_ms = busy_until;
                EventLog::txDeferred(static_cast<unsigned long>(now),
                                     _nodes[i]->name().c_str(),
                                     bi.len, bi.reason.c_str(),
                                     bi.sf, bi.label.c_str(), bi.tx_info.c_str(),
                                     static_cast<unsigned long>(bi.busy_until_ms));
                _nodes[i]->onRadioBusy(bi);
                continue;
            }

            // Listen-Before-Talk: if the channel is busy from this node's
            // POV (a prior reachable transmitter is still on the air and
            // its busy notification was recorded by the LbtModel), defer
            // this TX. Emit tx_deferred + notify the script via
            // on_radio_busy and skip the InFlight push entirely. The
            // script chooses retry policy.
            if (_lbt->isChannelBusy(i, now)) {
                RadioBusyInfo bi;
                bi.reason        = "channel_busy";
                bi.len           = static_cast<int>(p.bytes.size());
                bi.sf            = sf;
                bi.label         = p.label;
                bi.tx_info       = p.info;
                bi.busy_until_ms = _lbt->busyUntil(i);
                EventLog::txDeferred(static_cast<unsigned long>(now),
                                     _nodes[i]->name().c_str(),
                                     bi.len, bi.reason.c_str(),
                                     bi.sf, bi.label.c_str(), bi.tx_info.c_str(),
                                     static_cast<unsigned long>(bi.busy_until_ms));
                _nodes[i]->onRadioBusy(bi);
                continue;
            }

            // Regulatory duty-cycle hard-block. Models a real LoRa modem
            // that refuses TX when its sliding-window airtime budget is
            // exhausted (ETSI EN 300 220 default 1% / 1h). Lua scripts
            // are expected to self-regulate via self:airtime_used_ms()
            // first; this is the safety net that prevents budget breach
            // for scripts that don't. busy_until_ms = the earliest time
            // a fresh TX of this airtime could fit — i.e., when enough
            // of the oldest entries have aged out of the window.
            {
                float dc = _cfg.simulation.radio.duty_cycle;
                unsigned long dc_window = _cfg.simulation.radio.duty_cycle_window_ms;
                const auto& nc = _cfg.nodes[i].config;
                if (nc.is_object()) {
                    auto it = nc.find("duty_cycle");
                    if (it != nc.end() && it->is_number())
                        dc = it->get<float>();
                    auto wit = nc.find("duty_cycle_window_ms");
                    if (wit != nc.end() && wit->is_number_unsigned())
                        dc_window = wit->get<unsigned long>();
                }
                if (dc > 0.0f && dc <= 1.0f && dc_window > 0) {
                    const uint64_t budget_ms =
                        static_cast<uint64_t>(static_cast<double>(dc) * dc_window);
                    const uint64_t used = _nodes[i]->airtimeUsedInWindow(now, dc_window);
                    if (used + airtime > budget_ms) {
                        // Walk the log oldest-first; the earliest moment a
                        // window of `airtime` ms fits is when enough head
                        // entries have aged so that (used - aged_out + airtime)
                        // <= budget_ms. We approximate by waiting for the
                        // single oldest entry to age — sufficient in steady
                        // state and an underestimate when severely over.
                        // The scripts will recheck on retry.
                        uint64_t busy_until = now;
                        // The oldest in-window entry's end_ms + window_ms is
                        // when it falls out of the window — earliest moment
                        // any new airtime could fit (under-estimate when
                        // severely over budget; scripts recheck on retry).
                        const uint64_t oldest = _nodes[i]->oldestTxEndMs();
                        if (oldest > 0) {
                            busy_until = oldest + dc_window;
                        }
                        RadioBusyInfo bi;
                        bi.reason        = "duty_cycle_exceeded";
                        bi.len           = static_cast<int>(p.bytes.size());
                        bi.sf            = sf;
                        bi.label         = p.label;
                        bi.tx_info       = p.info;
                        bi.busy_until_ms = busy_until;
                        EventLog::txDeferred(static_cast<unsigned long>(now),
                                             _nodes[i]->name().c_str(),
                                             bi.len, bi.reason.c_str(),
                                             bi.sf, bi.label.c_str(), bi.tx_info.c_str(),
                                             static_cast<unsigned long>(bi.busy_until_ms));
                        _nodes[i]->onRadioBusy(bi);
                        continue;
                    }
                }
            }

            // TODO(Y2): plumb through SimRadio::startSendRaw so half-
            // duplex/LBT bookkeeping fires; for v1 we synthesise the
            // InFlight directly.
            InFlight f;
            f.sender_id     = i;
            f.start_ms      = now;
            f.end_ms        = now + airtime;
            f.bytes         = std::move(p.bytes);
            f.label         = p.label;
            f.info          = p.info;
            f.sf            = sf;
            f.bw_hz         = bw_hz;
            f.cr            = cr;
            f.pre_sym       = static_cast<uint16_t>(_radios[i]->getPreambleSymbols());
            f.t_sym_ms      = static_cast<float>(_radios[i]->getSymbolMs());
            f.t_preamble_ms = static_cast<float>(_radios[i]->getPreambleMs());
            f.collided_at_rcv.assign(static_cast<size_t>(n), 0);
            f.interferer_at_rcv.assign(static_cast<size_t>(n), -1);
            f.interferer_snr_at_rcv.assign(static_cast<size_t>(n), 0.0f);

            // Bidirectional collision evaluation at TX-start time.
            // Matches upstream Orchestrator.cpp::registerTransmissions
            // (lines ~590-619): for every existing in-flight `e` and
            // every receiver `r ≠ e.sender_id, ≠ f.sender_id`, run
            // evaluateCollision both directions and stamp the loser
            // with collided_at_rcv[r] = true. Once a packet is
            // delivered + popped from in_flight, no further check is
            // needed: the flag carries the verdict.
            for (auto& e : _in_flight) {
                // Time overlap?
                if (e.end_ms <= f.start_ms || e.start_ms >= f.end_ms)
                    continue;
                for (int r = 0; r < n; ++r) {
                    if (r == f.sender_id || r == e.sender_id) continue;
                    LinkParams lp_f, lp_e;
                    if (!_links->getLink(f.sender_id, r, lp_f)) continue;
                    if (!_links->getLink(e.sender_id, r, lp_e)) continue;
                    CapturedSignal sig_f = toCaptured(f, lp_f.snr);
                    CapturedSignal sig_e = toCaptured(e, lp_e.snr);

                    // f-vs-e: does the new TX get destroyed by the existing one?
                    auto df = evaluateCollision(_coll_cfg, sig_f, sig_e);
                    if (!df.survived) {
                        // Track strongest interferer (highest SNR).
                        if (f.interferer_at_rcv[r] < 0 ||
                            lp_e.snr > f.interferer_snr_at_rcv[r]) {
                            f.interferer_at_rcv[r]     = e.sender_id;
                            f.interferer_snr_at_rcv[r] = lp_e.snr;
                        }
                        f.collided_at_rcv[r] = 1;
                    }
                    // e-vs-f: does the existing TX get destroyed by the new one?
                    auto de = evaluateCollision(_coll_cfg, sig_e, sig_f);
                    if (!de.survived) {
                        if (r >= static_cast<int>(e.collided_at_rcv.size())) continue;
                        if (e.interferer_at_rcv[r] < 0 ||
                            lp_f.snr > e.interferer_snr_at_rcv[r]) {
                            e.interferer_at_rcv[r]     = f.sender_id;
                            e.interferer_snr_at_rcv[r] = lp_f.snr;
                        }
                        e.collided_at_rcv[r] = 1;
                    }
                }
            }

            EventLog::tx(static_cast<unsigned long>(now),
                         _nodes[i]->name().c_str(),
                         reinterpret_cast<const uint8_t*>(f.bytes.data()),
                         static_cast<int>(f.bytes.size()),
                         airtime,
                         sf, bw_hz, cr,
                         p.label.empty() ? nullptr : p.label.c_str(),
                         p.info.empty()  ? nullptr : p.info.c_str());

            _in_flight.push_back(std::move(f));

            // Update this sender's tx-in-flight slot so self:tx_in_flight()
            // reports the airtime end. Cleared in the compaction loop above
            // when the InFlight is removed at end_ms.
            _node_tx_in_flight_until[(size_t)i] = _in_flight.back().end_ms;
            // Persisted last-TX window for the half-duplex check (kept after
            // the TX ends / is compacted out of _in_flight).
            _node_last_tx_start_ms[(size_t)i] = _in_flight.back().start_ms;
            _node_last_tx_end_ms[(size_t)i]   = _in_flight.back().end_ms;

            // Record this TX in the per-node sliding-window airtime log so
            // both self:airtime_used_ms() (Lua) and the duty-cycle hard-block
            // (above) see the cumulative usage. Done unconditionally — every
            // accepted TX counts toward the budget regardless of label.
            _nodes[i]->recordTxAirtime(_in_flight.back().end_ms, airtime);

            // Notify LBT for every observer that can hear this sender, so
            // their next TX-time isChannelBusy() check sees this airtime.
            // Gated by shouldNotifyBusy(): the CAD-miss roll determines
            // whether the observer's hardware would actually have detected
            // the preamble at the link's SNR. Marginal/weak links may
            // miss; reliable links almost always notify.
            //
            // Same loop also calls SimRadio::notifyRxStart on each
            // observer so that any future code path checking
            // radio.isReceiving() sees the correct state. lus's loop
            // does not currently consult that flag (the in_flight
            // ground-truth check above is more robust), but keeping the
            // SimRadio state hygienic prevents downstream surprises and
            // matches meshcore_real_sim's wiring.
            const auto& just_pushed = _in_flight.back();
            for (int observer = 0; observer < n; ++observer) {
                if (observer == i) continue;
                LinkParams lp;
                if (!_links->getLink(i, observer, lp)) continue;
                if (lp.snr <= -100.0f) continue;
                _radios[observer]->notifyRxStart(static_cast<uint32_t>(airtime));
                if (!_lbt->shouldNotifyBusy(lp.snr)) continue;
                _lbt->notifyChannelBusy(observer, i,
                                        just_pushed.end_ms, lp.snr);
                // SX1262-PreambleDetected equivalent: fire only if the
                // observer's modem is currently tuned to a SF that includes
                // the TX's SF. LoRa SFs are quasi-orthogonal at the same BW;
                // a radio set to SF7 won't see an SF10 preamble. The CAD
                // gate above (shouldNotifyBusy) already modelled the
                // probabilistic miss against SNR. Fires regardless of
                // sync-word match — matches real hardware (PreambleDetected
                // IRQ is pre-SyncWordValid), and that's the right level for
                // a "channel about to be polluted by anyone at our SF"
                // signal that drives beacon-throttling decisions.
                const auto& rx_set = _node_sf_rx_set[observer];
                bool sf_match = false;
                for (int sf : rx_set) {
                    if (sf == just_pushed.sf) { sf_match = true; break; }
                }
                if (sf_match) {
                    const int protocol_sender_id = _nodes[i]->protocolId();
                    _nodes[observer]->onPreambleDetected(
                        just_pushed.start_ms, protocol_sender_id, lp.snr);
                }
            }
        }
    }
}

// Re-build every directed link in _links from the path-loss model's
// current per-node offsets and per-pair shadows, then re-apply explicit
// topology.links overrides on top (same precedence as initialize()).
// Called at coherence boundaries when asymmetry_coherence_ms > 0 — slow
// drift in the per-pair shadow component, modeling foliage / weather.
// Also advances any mobile nodes (velocity_mps > 0) along their compass
// heading by the elapsed coherence interval, then recomputes path-loss
// from the new positions — same one-tick that handles environmental
// drift now also handles bulk position change. (Cheap: positions update
// at ~1 Hz in the default 60 s coherence, and Haversine + sampleDirectional
// scale O(n²) which is fine at our scenario sizes.)
void SimController::rebuildLinksFromPathLoss() {
    if (!_path_loss || !_links) return;
    const int n = static_cast<int>(_cfg.nodes.size());

    // Advance mobile nodes. dt is the elapsed wall time since the last
    // rebuild — for the very first call (init time) elapsed is 0 so this
    // is a no-op; subsequent calls fire at asymmetry_coherence_ms cadence.
    const uint64_t coherence_ms = _cfg.simulation.path_loss.asymmetry_coherence_ms;
    if (coherence_ms > 0) {
        const double dt_s = static_cast<double>(coherence_ms) / 1000.0;
        for (int i = 0; i < n; ++i) {
            if (!_cfg.nodes[i].has_location) continue;
            const float v = _cfg.nodes[i].velocity_mps;
            if (v <= 0.0f) continue;
            const double dist_m  = static_cast<double>(v) * dt_s;
            // Compass heading → ENU bearing: north = 0°, clockwise.
            // Convert to a small lat/lon delta using the local
            // ~111 km / degree approximation. Adequate for the meter-
            // scale movement per tick we expect at LoRa-mesh velocities;
            // mobile-node simulations covering tens of km would want a
            // proper geodetic forward step.
            constexpr double kPi = 3.14159265358979323846;
            const double bearing_rad = static_cast<double>(_cfg.nodes[i].direction_deg) * kPi / 180.0;
            const double dnorth_m = dist_m * std::cos(bearing_rad);
            const double deast_m  = dist_m * std::sin(bearing_rad);
            const double dlat = dnorth_m / 111320.0;
            const double dlon = deast_m  /
                (111320.0 * std::cos(_node_lat[(size_t)i] * kPi / 180.0));
            _node_lat[(size_t)i] += dlat;
            _node_lon[(size_t)i] += dlon;
            char json[256];
            std::snprintf(json, sizeof(json),
                "{\"lat\":%.6f,\"lon\":%.6f,\"velocity_mps\":%.2f,\"direction_deg\":%.1f}",
                _node_lat[(size_t)i], _node_lon[(size_t)i], v, _cfg.nodes[i].direction_deg);
            EventLog::logScriptEmit(i, _now_ms, "node_position", json);
        }
    }

    for (int i = 0; i < n; ++i) {
        if (!_cfg.nodes[i].has_location) continue;
        for (int j = 0; j < n; ++j) {
            if (i == j) continue;
            if (!_cfg.nodes[j].has_location) continue;
            if (_cfg.simulation.path_loss.mobile_only &&
                !isMobileNode(_cfg.nodes[i]) &&
                !isMobileNode(_cfg.nodes[j])) {
                continue;
            }
            const double d = lus::haversineDistanceMeters(
                _node_lat[(size_t)i], _node_lon[(size_t)i],
                _node_lat[(size_t)j], _node_lon[(size_t)j]);
            const auto sig = _path_loss->sampleDirectional(i, j, d);
            _links->setLink(i, j, sig.snr_db, sig.rssi_dbm,
                            static_cast<float>(_cfg.simulation.path_loss.sigma_db),
                            0.0f);
        }
    }
    // Re-apply explicit overrides — same precedence as initialize().
    // Links touching mobile nodes remain path-loss-derived; static JSON link
    // snapshots must not freeze a moving endpoint's connectivity.
    for (const auto& l : _cfg.topology.links) {
        auto fit = _name_to_id.find(l.from);
        auto tit = _name_to_id.find(l.to);
        if (fit == _name_to_id.end() || tit == _name_to_id.end()) continue;
        if (isMobileNode(_cfg.nodes[fit->second]) ||
            isMobileNode(_cfg.nodes[tit->second])) {
            continue;
        }
        _links->setLink(fit->second, tit->second,
                        l.snr, l.rssi, l.snr_std_dev, l.loss);
        if (l.bidir) {
            _links->setLink(tit->second, fit->second,
                            l.snr, l.rssi, l.snr_std_dev, l.loss);
        }
    }

    constexpr size_t kTopNeighbors = 8;
    for (int i = 0; i < n; ++i) {
        if (!isMobileNode(_cfg.nodes[i])) continue;
        if (i >= static_cast<int>(_node_alive.size()) || !_node_alive[(size_t)i]) continue;

        const std::vector<int> visibility_sfs = visibilitySfsForNode(_cfg.nodes[i]);
        const int routing_sf = routingSfForNode(_cfg.nodes[i]);
        nlohmann::json counts = nlohmann::json::object();
        nlohmann::json thresholds = nlohmann::json::object();
        for (int sf : visibility_sfs) {
            counts["out_sf" + std::to_string(sf)] = 0;
            counts["in_sf" + std::to_string(sf)] = 0;
            thresholds["sf" + std::to_string(sf)] = SimRadio::getSnrThreshold(sf);
        }

        std::vector<NeighborSnr> top_out;
        std::vector<NeighborSnr> top_in;
        for (int j = 0; j < n; ++j) {
            if (i == j) continue;
            if (j < static_cast<int>(_node_alive.size()) && !_node_alive[(size_t)j]) continue;

            LinkParams lp_out;
            if (_links->getLink(i, j, lp_out)) {
                keepTopNeighbor(top_out, NeighborSnr{j, lp_out.snr, lp_out.rssi}, kTopNeighbors);
                for (int sf : visibility_sfs) {
                    if (lp_out.snr >= SimRadio::getSnrThreshold(sf)) {
                        counts["out_sf" + std::to_string(sf)] =
                            counts["out_sf" + std::to_string(sf)].get<int>() + 1;
                    }
                }
            }

            LinkParams lp_in;
            if (_links->getLink(j, i, lp_in)) {
                keepTopNeighbor(top_in, NeighborSnr{j, lp_in.snr, lp_in.rssi}, kTopNeighbors);
                for (int sf : visibility_sfs) {
                    if (lp_in.snr >= SimRadio::getSnrThreshold(sf)) {
                        counts["in_sf" + std::to_string(sf)] =
                            counts["in_sf" + std::to_string(sf)].get<int>() + 1;
                    }
                }
            }
        }

        auto encode_neighbors = [&](const std::vector<NeighborSnr>& neighbors) {
            nlohmann::json arr = nlohmann::json::array();
            for (const auto& nb : neighbors) {
                nlohmann::json item = {
                    {"node", _cfg.nodes[nb.idx].name},
                    {"snr", nb.snr},
                    {"rssi", nb.rssi}
                };
                for (int sf : visibility_sfs) {
                    item["sf" + std::to_string(sf)] =
                        nb.snr >= SimRadio::getSnrThreshold(sf);
                }
                arr.push_back(std::move(item));
            }
            return arr;
        };

        nlohmann::json payload = {
            {"lat", _node_lat[(size_t)i]},
            {"lon", _node_lon[(size_t)i]},
            {"velocity_mps", _cfg.nodes[i].velocity_mps},
            {"direction_deg", _cfg.nodes[i].direction_deg},
            {"routing_sf", routing_sf},
            {"sfs", visibility_sfs},
            {"thresholds", thresholds},
            {"counts", counts},
            {"top_out", encode_neighbors(top_out)},
            {"top_in", encode_neighbors(top_in)}
        };
        EventLog::logScriptEmit(i, _now_ms, "mobile_visibility", payload.dump());
    }
}

StepResult SimController::step(uint64_t advance_ms) {
    StepResult result;
    if (!_initialized || _finalized) {
        result.now_ms = _now_ms;
        result.ended  = ended();
        return result;
    }

    const uint64_t step_ms = (advance_ms == 0)
        ? static_cast<uint64_t>(_cfg.simulation.step_ms)
        : advance_ms;

    const int events_before = static_cast<int>(EventLog::events().size());

    // Boundary marker: emit warmup_end exactly once when _now_ms first
    // reaches simulation.warmup_ms. Skipped if warmup_ms == 0 (no
    // boundary). Position: ahead of every other per-step action so any
    // physics events generated during this same step are ordered after
    // the boundary marker, which is what readers expect.
    {
        const uint64_t warmup_ms =
            static_cast<uint64_t>(_cfg.simulation.warmup_ms);
        if (!_warmup_end_emitted && warmup_ms > 0 && _now_ms >= warmup_ms) {
            EventLog::warmupEnd(static_cast<unsigned long>(warmup_ms));
            _warmup_end_emitted = true;
        }
    }

    // Lifecycle: node_started / node_died transitions. Runs before the
    // path-loss / startup / commands / receptions / timers / TX register
    // pipeline so the rest of the step sees the correct _node_alive state.
    processLifecycleAtStep();

    // Drive the asymmetry-coherence-driven re-sample of per-pair shadows.
    // Per-node offsets stay fixed; only the pair shadow component drifts.
    if (_path_loss && _now_ms >= _next_pair_shadow_resample_ms) {
        _path_loss->resamplePairShadows();
        rebuildLinksFromPathLoss();
        _next_pair_shadow_resample_ms +=
            _cfg.simulation.path_loss.asymmetry_coherence_ms;
    }

    processStartupAtStep();
    processCommandsAtStep();
    deliverReceptionsForStep();
    tickTimersForStep();
    registerTransmissionsForStep();

    _clock.advanceMillis(step_ms);
    _now_ms += step_ms;

    const int events_after = static_cast<int>(EventLog::events().size());

    result.ended      = ended();
    result.new_events = events_after - events_before;
    result.now_ms     = _now_ms;
    return result;
}

StepResult SimController::runUntil(uint64_t target_ms) {
    StepResult last{};
    last.now_ms = _now_ms;
    last.ended  = ended();

    if (!_initialized) {
        return last;
    }

    int total_new_events = 0;
    while (_now_ms < target_ms && !_interrupted && !ended()) {
        StepResult r = step();
        total_new_events += r.new_events;
        last = r;
    }

    last.now_ms     = _now_ms;
    last.ended      = ended();
    last.new_events = total_new_events;
    return last;
}

StepResult SimController::runUntilNextEvent() {
    StepResult last{};
    last.now_ms = _now_ms;
    last.ended  = ended();

    if (!_initialized) {
        return last;
    }

    int total_new_events = 0;
    while (!_interrupted && !ended()) {
        StepResult r = step();
        total_new_events += r.new_events;
        last = r;
        if (r.new_events > 0) break;
    }

    last.now_ms     = _now_ms;
    last.ended      = ended();
    last.new_events = total_new_events;
    return last;
}

std::string SimController::fireCommand(const std::string& node_name,
                                       const std::string& cmd) {
    auto it = _name_to_id.find(node_name);
    if (it == _name_to_id.end()) {
        return std::string("ERROR: unknown node");
    }
    const int target = it->second;
    std::string reply = _nodes[target]->onCommand(cmd);
    EventLog::cmdReply(static_cast<unsigned long>(_now_ms),
                       _nodes[target]->name().c_str(),
                       cmd.c_str(),
                       reply.c_str());
    return reply;
}

int SimController::finalize() {
    if (!_initialized || _finalized) return 0;
    const uint64_t end_ms = static_cast<uint64_t>(_cfg.simulation.duration_ms);

    // sim_end lifecycle event — bookend marker at the close of the
    // NDJSON stream, before assertion evaluation. Matches upstream
    // Orchestrator::emitSummary (line ~1236).
    EventLog::simEnd(static_cast<unsigned long>(end_ms));
    _finalized = true;

    return ExpectRunner::evaluate(_cfg, EventLog::events());
}
