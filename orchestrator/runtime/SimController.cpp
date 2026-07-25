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
#ifdef MESHROUTE_ENABLED
#include "orchestrator/runtime/FirmwareNode.h"
#include "identity.h"                          // Slice A2: seed -> key_hash32 derivation (shared with device)
#endif
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

// §1.5 tx-power link-budget delta: txPowerDeltaDb() is defined in SimController.h (shared with the
// sim-native unit test); used at the delivery + collision link-budget sites below.

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

// ---- send-by-name resolution (`send <name>` / `send_e2e <name>`) --------------
// A scenario writes a readable node NAME; meshroute firmware takes a numeric dst.
// Which number is correct is a PLANE question, not a timing question — see
// resolveAddresseeOnSenderLayer() below for the window-phase trap this replaces.

// The layer a node's top-level config places it on. Mirrors the derivation in
// JsonConfig::validateConfig()'s duplicate-effective-id check (`leaf_id` is the
// legacy spelling of `layer_id`) — keep the two in step. Absent => 0, which is what
// every single-layer scenario means: no node in one writes layer_id at all, so they
// all share layer 0 and resolution stays exactly as it was.
static int layerIdForNode(const SimConfig::NodeDef& node) {
    if (node.config.is_object()) {
        auto lit = node.config.find("layer_id");
        if (lit != node.config.end() && lit->is_number_integer()) return lit->get<int>();
        auto fit = node.config.find("leaf_id");
        if (fit != node.config.end() && fit->is_number_integer()) return fit->get<int>();
    }
    return 0;
}

// config.layers[] iff the node is MULTI-LAYER (a dual-layer gateway). Each entry
// carries its own layer_id AND its own node_id, i.e. such a node wears a DIFFERENT
// protocol id on each of its layers.
static const nlohmann::json* layersForNode(const SimConfig::NodeDef& node) {
    if (!node.config.is_object()) return nullptr;
    auto it = node.config.find("layers");
    if (it == node.config.end() || !it->is_array() || it->empty()) return nullptr;
    return &(*it);
}

// "layer 4" for a single-layer node; "layers {4:10, 5:111}" for a gateway. Used only
// to build the refusal message, so it names layers AND the per-layer ids the author
// can pick from.
static std::string describeLayersOf(const SimConfig::NodeDef& node) {
    const nlohmann::json* layers = layersForNode(node);
    if (!layers) return "layer " + std::to_string(layerIdForNode(node));
    std::string out = "layers {";
    bool first = true;
    for (const auto& e : *layers) {
        if (!e.is_object()) continue;
        auto lit = e.find("layer_id");
        auto nit = e.find("node_id");
        if (lit == e.end() || !lit->is_number_integer()) continue;
        if (!first) out += ", ";
        first = false;
        out += std::to_string(lit->get<int>()) + ":";
        out += (nit != e.end() && nit->is_number_integer())
                   ? std::to_string(nit->get<int>()) : std::string("?");
    }
    return out + "}";
}

enum class AddresseeIdSource {
    LiveProtocolId,     // single-layer addressee: it wears exactly one id -> its LIVE id
    PerLayerNodeId,     // multi-layer addressee: the id it wears on the sender's layer
    RefuseNoShared,     // sender and addressee are on no common layer
    RefuseAmbiguousSender,  // the SENDER is multi-layer: "its" layer is window-dependent
};

struct AddresseeId {
    AddresseeIdSource src = AddresseeIdSource::LiveProtocolId;
    int               node_id = 0;   // meaningful only for PerLayerNodeId
};

// Resolve a same-layer `send <name>` addressee to the id it wears ON THE SENDER'S
// LAYER — the fix for the window-phase bug recorded in MeshRoute
// simulation/BASELINE.md note 2026-07-25d.
//
// ★ THE TRAP THIS REPLACES. The obvious resolution is the addressee's LIVE
// INode::protocolId(). For a single-layer node that is right and stays right (it
// wears one id, and the live value also tracks a DAD/join/mobile lease that config
// cannot know). For a dual-layer GATEWAY it is a coin flip: the gateway
// time-multiplexes its two leaves, and MeshRoute's Node::activate_layer() re-stamps
// the HAL short id to the ENTERING leaf's node_id on every window swap
// (lib/core/node.cpp:493 -> NodeRuntimeWrapper::set_protocol_id ->
// FirmwareNode::simSetProtocolId). So protocolId() ALTERNATES with the window phase,
// and a layer-4 `send gw_4` issued during the gateway's layer-5 window was addressed
// to a layer-5-only id — unroutable from layer 4, so the DM died in
// send_deferred_giveup. Whether a scenario passed depended on WHEN its command fired.
//
// A same-layer DM is addressed within one layer's id namespace, so the resolution is
// a static plane property: match the sender's layer against the addressee's layers[].
static AddresseeId resolveAddresseeOnSenderLayer(const SimConfig::NodeDef& sender,
                                                 const SimConfig::NodeDef& addressee) {
    // ★ A MULTI-LAYER SENDER is refused, not guessed. Its own "current" layer is
    // whichever leaf its window scheduler has active at command time — i.e. exactly
    // the timing accident this function exists to remove, now on the sender side (the
    // firmware enqueues the DM on _active). Resolving against its home leaf would be
    // well-defined but still silently wrong in the other window. A gateway that must
    // DM a leaf has to name the layer, which only the scenario knows.
    if (layersForNode(sender) != nullptr) {
        return {AddresseeIdSource::RefuseAmbiguousSender, 0};
    }

    const int sender_layer = layerIdForNode(sender);

    if (const nlohmann::json* layers = layersForNode(addressee)) {
        for (const auto& e : *layers) {
            if (!e.is_object()) continue;
            auto lit = e.find("layer_id");
            auto nit = e.find("node_id");
            if (lit == e.end() || !lit->is_number_integer()) continue;
            if (lit->get<int>() != sender_layer) continue;
            if (nit == e.end() || !nit->is_number_integer()) break;   // entry exists but unusable
            return {AddresseeIdSource::PerLayerNodeId, nit->get<int>()};
        }
        return {AddresseeIdSource::RefuseNoShared, 0};
    }

    // Single-layer addressee: the live id is unambiguous, but the two must actually
    // share a layer — a cross-layer DM's verb is send_layer, not send.
    if (layerIdForNode(addressee) != sender_layer) {
        return {AddresseeIdSource::RefuseNoShared, 0};
    }
    return {AddresseeIdSource::LiveProtocolId, 0};
}

// C2 refusal text, built once so the pre-flight and the fire site cannot drift.
static std::string sendByNameRefusal(const SimConfig::NodeDef& sender,
                                     const SimConfig::NodeDef& addressee,
                                     const std::string&        command,
                                     AddresseeIdSource         why) {
    std::string msg = "REFUSED: cannot resolve the same-layer send `" + command
                    + "` issued by node '" + sender.name + "' ("
                    + describeLayersOf(sender) + ") to node '" + addressee.name + "' ("
                    + describeLayersOf(addressee) + "): ";
    if (why == AddresseeIdSource::RefuseAmbiguousSender) {
        msg += "the SENDER is a multi-layer gateway, so which layer it sends on depends "
               "on which window its scheduler has active at command time. Name the "
               "layer explicitly with `send_layer <layer> <key_hash32> <text>`, or "
               "issue the send from a single-layer node.";
    } else {
        msg += "they share NO layer, so `" + addressee.name
             + "` has no id in the sender's layer-" + std::to_string(layerIdForNode(sender))
             + " namespace. A cross-layer DM's verb is `send_layer <layer> <key_hash32> "
               "<text>`; a same-layer `send <name>` only addresses nodes on the sender's "
               "own layer.";
    }
    return msg + " (Refusing rather than falling back to the addressee's momentary "
                 "protocolId(): that fallback is the window-phase bug recorded in "
                 "MeshRoute simulation/BASELINE.md note 2026-07-25d.)";
}

// The two SAME-LAYER unicast verbs are the only ones that take a node NAME. Every
// other send verb (`send_layer`/`send_layerx`, `send_hash`/`send_hashx`,
// `send_channel`) is addressed by layer+key_hash32 or by channel and is left verbatim.
struct SendByName {
    size_t verb_len = 0;                        // 0 => not a send-by-name command
    size_t name_end = std::string::npos;        // index of the space ending the name
    std::string name;
    bool named() const { return verb_len != 0 && name_end != std::string::npos; }
};

static SendByName parseSendByName(const std::string& command) {
    SendByName p;
    if      (command.rfind("send_e2e ", 0) == 0) p.verb_len = 9;
    else if (command.rfind("send ", 0) == 0)     p.verb_len = 5;
    if (p.verb_len == 0) return p;
    size_t s = p.verb_len;
    while (s < command.size() && command[s] == ' ') ++s;
    p.name_end = command.find(' ', s);
    if (p.name_end != std::string::npos) p.name = command.substr(s, p.name_end - s);
    return p;
}

}  // namespace

SimController::SimController(const SimConfig& cfg, std::ostream& events_out)
    : _cfg(cfg),
      _events_out(events_out),
      _clock(cfg.simulation.epoch_start),
      // Dedicated path-loss stream (see header). _node_rng / _link_rng are
      // sized/populated in initialize() once the node count is known.
      _pathloss_rng(mrsim::makeStream(cfg.simulation.seed, mrsim::RngDomain::PathLoss, 0)) {}

SimController::~SimController() = default;

// Lazily materialize (and deterministically seed) the physics stream for a
// directed link. Reference stability across inserts is guaranteed by
// unordered_map (node-based container), so a returned reference stays valid.
std::mt19937& SimController::linkRng(uint64_t link_idx) {
    auto it = _link_rng.find(link_idx);
    if (it == _link_rng.end()) {
        it = _link_rng.emplace(
            link_idx,
            mrsim::makeStream(_cfg.simulation.seed, mrsim::RngDomain::Link, link_idx)).first;
    }
    return it->second;
}

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

    // ---- ★ DEPRECATED LUA ENGINE — fail-loud refusal (2026-07-25 ruling) ----
    // The Lua engine is deprecated and unsupported: it is far behind the
    // firmware, and it is kept only as the frozen parity reference the C++ port
    // was validated against. Running it by accident produces a plausible-looking
    // NDJSON stream that answers a question nobody asked — which is exactly what
    // used to happen, because "lua" was the DEFAULT engine and most of the
    // corpus carries no engine key.
    //
    // ★ This is the choke point BECAUSE it sees the engine AFTER every override:
    //   - config          -> JsonConfig sets NodeDef::engine;
    //   - CLI --engine    -> main.cpp rewrites n.engine after loadFromFile();
    //   - a native test   -> constructs SimController(cfg, out) directly and
    //                        never touches the lus CLI at all.
    // A JsonConfig::validateConfig check would miss the last two. Placed at the
    // very top of initialize(), before the first EventLog write, so a refused
    // run emits NOTHING rather than a truncated stream. (Same fail-loud-in-
    // initialize discipline as the `bw <= 0` throw further down.)
    //
    // ★ The predicate is `engine != "meshroute"`, NOT `engine == "lua"`: the node
    // dispatch below builds a ScriptedNode for ANY non-"meshroute" value (its
    // `else` branch), so anything unrecognised is silently a Lua node. Config and
    // CLI both reject unknown engine strings, so on every reachable path this is
    // exactly equivalent to `== "lua"` — but it means a hand-built SimConfig can
    // never sneak a Lua node past this gate under a misspelt name.
    {
        size_t      lua_nodes = 0;
        std::string first_lua_name;
        std::string first_lua_engine;
        for (const auto& nd : _cfg.nodes) {
            if (nd.engine == "meshroute") continue;
            if (lua_nodes == 0) { first_lua_name = nd.name; first_lua_engine = nd.engine; }
            ++lua_nodes;
        }
        if (lua_nodes > 0 && !_cfg.simulation.allow_deprecated_lua) {
            throw std::runtime_error(
                "REFUSED: the Lua engine is DEPRECATED and UNSUPPORTED — it is far "
                "behind the MeshRoute firmware and is retained only as the frozen "
                "parity reference the C++ port was validated against. Node '"
                + first_lua_name + "' resolves to engine \"" + first_lua_engine + "\" ("
                + std::to_string(lua_nodes) + " of "
                + std::to_string(_cfg.nodes.size())
                + " node(s) do). Run the firmware engine instead (drop `--engine lua`, "
                  "or tag the node \"engine\":\"meshroute\" — \"meshroute\" is now the "
                  "DEFAULT, so an untagged node needs no flag at all). To run the "
                  "frozen Lua reference deliberately, opt in: pass "
                  "`--allow-deprecated-lua` on the lus command line, or set "
                  "\"allow_deprecated_lua\": true in the scenario's \"simulation\" block.");
        }
        if (lua_nodes > 0) {
            // Sanctioned, but a sanctioned run must still be impossible to
            // mistake for a supported one. One line, once per run.
            std::fprintf(stderr,
                "lus: warning — DEPRECATED LUA ENGINE in use on %zu of %zu node(s) "
                "(first: '%s', engine \"%s\") via allow_deprecated_lua. The Lua engine "
                "is UNSUPPORTED and far behind the firmware; it is kept only as the "
                "frozen parity reference. Results are NOT firmware behaviour.\n",
                lua_nodes, _cfg.nodes.size(), first_lua_name.c_str(),
                first_lua_engine.c_str());
        }
    }

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

    // ---- Pre-flight: every `send <name>` must resolve on the sender's layer ---
    // Runs here (needs _name_to_id, still before the first EventLog WRITE — the calls
    // above only wire the stream/buffer up) so an unresolvable scenario refuses with
    // ZERO bytes instead of dying mid-run with a truncated stream. Same fail-loud-in-
    // initialize discipline as the Lua refusal above and the `bw <= 0` throw below.
    validateSendByNameCommands();

    // Forced-drop match tally (R3.x). Zeroed; empty when no forced_drops.
    _drop_match_count.assign(_cfg.drop_directives.size(), 0);

    // ---- Per-node RNG streams (Wave-4 Slice C) ------------------------------
    // Build BEFORE any node/path-loss construction: nodes capture a reference
    // to their stream (must outlive them), and the per-node path-loss offset
    // draws below read from these. reserve() guarantees no reallocation so the
    // references stay valid for the controller's lifetime. Keyed by the stable
    // runtime index i (node_id is NOT unique — fresh nodes boot id 0).
    _node_rng.clear();
    _node_rng.reserve(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) {
        _node_rng.emplace_back(
            mrsim::makeStream(_cfg.simulation.seed, mrsim::RngDomain::Node,
                              static_cast<uint64_t>(i)));
    }
    _link_rng.clear();

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
        // Path-loss draws (per-node offsets, per-pair shadows, coherence
        // resamples) run off a dedicated stream — fixed-count / fixed-cadence,
        // so isolated from node runtime draw counts and the per-link physics.
        _path_loss = std::make_unique<PathLossModel>(plc, _pathloss_rng);
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
    // §1.1 (2026-07-20 review): bw is now stored INTERNALLY IN Hz (JsonConfig converts the kHz-double
    // JSON field ×1000 at parse). SimRadio takes Hz, so pass _cfg.nodes[i].bw straight through.
    _radios.clear();
    _nodes.clear();
    _radios.reserve(static_cast<size_t>(n));
    _nodes.reserve(static_cast<size_t>(n));

    // Resolve per-node sf_rx_set: empty config -> [node.sf] (single-SF,
    // matches real Semtech LoRa hardware). See SimController.h note.
    _node_sf_rx_set.assign(static_cast<size_t>(n), {});
    _node_rx_bw_hz.assign(static_cast<size_t>(n), 0);
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
        // §bw-gating: seed the LIVE RX bandwidth from the node's configured bw
        // (Hz; kHz-double x1000 at parse). FAIL LOUD rather than invent a
        // fallback — validateConfig already rejects bw <= 0 (JsonConfig.cpp
        // "bw must be > 0"), so reaching here with 0 means the config path was
        // bypassed and every delivery verdict downstream would be garbage.
        if (_cfg.nodes[i].bw <= 0) {
            throw std::runtime_error(
                "node '" + _cfg.nodes[i].name + "': bw must be > 0 Hz (got "
                + std::to_string(_cfg.nodes[i].bw)
                + ") — the RX-bandwidth gate has no default to fall back on");
        }
        _node_rx_bw_hz[i] = _cfg.nodes[i].bw;
    }

    // Slice A2: resolve key_hash32 for every node BEFORE constructing either engine, so the C++
    // FirmwareNode and the Lua ScriptedNode receive the SAME value. With an identity `seed`, DERIVE
    // key_hash32 = ed_pub[:4] via the device's lib/core/identity (sim+device share one derivation);
    // otherwise keep the const _cfg's literal/fnv fallback. Stored here, never mutating const _cfg.
    _resolved_key_hash32.assign(static_cast<size_t>(n), 0u);
    for (int i = 0; i < n; ++i) {
        _resolved_key_hash32[i] = _cfg.nodes[i].key_hash32;     // literal / fnv-of-name fallback
        if (!_cfg.nodes[i].has_seed) continue;
#ifdef MESHROUTE_ENABLED
        meshroute::Identity id{};
        meshroute::identity_from_seed(id, _cfg.nodes[i].seed.data());
        _resolved_key_hash32[i] = id.key_hash32;
#else
        throw std::runtime_error("node '" + _cfg.nodes[i].name +
            "': field \"seed\" requires the MeshRoute identity module (build with MeshRoute present)");
#endif
    }

    for (int i = 0; i < n; ++i) {
        const int sf = _cfg.nodes[i].sf;        // already merged with global defaults
        const int bw_hz = _cfg.nodes[i].bw;   // already Hz (JsonConfig kHz-double -> Hz)
        const int cr = _cfg.nodes[i].cr;
        _radios.emplace_back(std::make_unique<SimRadio>(
            _clock, sf, bw_hz, cr,
            _cfg.simulation.radio.rx_to_tx_delay_ms,
            _cfg.simulation.radio.tx_to_rx_delay_ms));
        // §tx-fail (2026-07-25) — DONE (was: "TODO(Y2): plumb cfg.nodes[i].
        // tx_fail_prob through SimRadio::setTxFailProb once the loop honours
        // startSendRaw failure paths"). The key is now plumbed WITHOUT that
        // precondition: the TX loop calls SimRadio::rollTxFail() directly at
        // the point startSendRaw would have rolled it (see §tx-fail there).
        // Until this landed a scenario could set tx_fail_prob, have it parsed
        // and range-validated by JsonConfig, and have it silently discarded.
        _radios[i]->setTxFailProb(_cfg.nodes[i].tx_fail_prob);
        // Per-node, independent-of-everything-else roll stream (Slice C): its
        // own RngDomain, so enabling tx_fail_prob perturbs neither _node_rng[i]
        // (the node's firmware draws) nor any link stream. Seeding makes no
        // draw, so this line is inert while every node is at prob 0.
        _radios[i]->seed(mrsim::deriveSeed(_cfg.simulation.seed,
                                           mrsim::RngDomain::TxFail,
                                           static_cast<uint64_t>(i)));

        if (_cfg.nodes[i].engine == "meshroute") {
#ifdef MESHROUTE_ENABLED
            // FirmwareNode: the MeshRoute C++ firmware (lib/core meshroute::Node)
            // run in-loop, implementing meshroute::Hal over the sim's services.
            _nodes.emplace_back(std::make_unique<FirmwareNode>(
                i, _cfg.nodes[i].name, _resolved_key_hash32[i],
                *_radios[i], _events_out, _clock, _node_rng[(size_t)i]));
#else
            throw std::runtime_error(
                "node '" + _cfg.nodes[i].name + "': engine \"meshroute\" requires "
                "building with MeshRoute (not found at configure time; set -DMESHROUTE_DIR)");
#endif
        } else {
            _nodes.emplace_back(std::make_unique<ScriptedNode>(
                i, _cfg.nodes[i].name,
                _host, *_radios[i], _events_out, _clock, _node_rng[(size_t)i]));
        }
        // Hand the node a stable pointer to its sf_rx_set slot so scripts
        // can retune at runtime via self:set_rx_sf(...). _node_sf_rx_set
        // was sized once via assign() above; the outer vector never
        // reallocates, so &_node_sf_rx_set[i] stays valid for the lifetime
        // of this controller.
        _nodes[i]->attachSfRxSet(&_node_sf_rx_set[i]);
        // §bw-gating: same stable-pointer contract for the live RX-BW slot —
        // _node_rx_bw_hz was sized by the assign() above and never reallocates,
        // so &_node_rx_bw_hz[i] outlives every retune.
        _nodes[i]->attachRxBwSlot(&_node_rx_bw_hz[i]);
        _nodes[i]->attachTxInFlightSlot(&_node_tx_in_flight_until[i]);
        // _lbt is constructed below; defer the LBT attach until then.
    }

    // Per-node clock drift + SF-switch delay. MUST be set before any
    // onInit fires because the script's first self:after() call (made
    // from on_init) reads _clock_drift_ppm to scale the wall delay; if
    // drift is still 0 at that moment, the very first timer of every
    // node is misscheduled.
    {
        for (int i = 0; i < n; ++i) {
            // Fresh distribution per node: std::normal_distribution caches the
            // second Box-Muller value, so a single shared instance would leak a
            // draw from node i's stream into node i+1's — a local instance keeps
            // the per-node streams truly independent.
            std::normal_distribution<double> drift_dist(
                0.0, _cfg.simulation.clock_drift_ppm_sigma);
            float ppm = _cfg.nodes[i].clock_drift_ppm;
            if (std::isnan(ppm)) {
                ppm = (_cfg.simulation.clock_drift_ppm_sigma > 0.0)
                          ? static_cast<float>(drift_dist(_node_rng[(size_t)i]))
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
        // Protocol id defaults to a 1-BASED slot (i+1), reserving 0 as the "unprovisioned"
        // sentinel (a fresh device boots node_id=0 until cfg/join; the C++ on_command refuses
        // a send from id 0). An explicit config node_id (>=0) still wins. Runtime/registry/link
        // indices stay the 0-based `i`; only the on-wire protocol id shifts.
        const int protocol_node_id = _cfg.nodes[i].node_id >= 0
            ? _cfg.nodes[i].node_id
            : i + 1;
        _nodes[i]->setProtocolId(protocol_node_id);
        // Lua-only wiring: bind the self:* methods + load the script.
        // FirmwareNode (engine=="meshroute") runs C++ logic and skips both.
        // The static_cast is safe inside this branch — the node was built as a
        // ScriptedNode by the engine switch above.
        if (_cfg.nodes[i].engine == "lua") {
            _host.registerNode(i, static_cast<ScriptedNode*>(_nodes[i].get()),
                               protocol_node_id, _resolved_key_hash32[i]);
            std::string resolved =
                resolveScriptPath(_cfg.nodes[i].script_path, _cfg.source_path);
            _host.loadScript(i, resolved);
        }
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
    // simulation.node_startup_jitter_ms > 0, draw each from [0, jitter] using
    // the node's own stream. The jitter==0 path makes ZERO draws so nodes with
    // no jitter don't advance their stream.
    _node_init_at_ms.assign(static_cast<size_t>(n), 0);
    if (_cfg.simulation.node_startup_jitter_ms > 0) {
        std::uniform_int_distribution<int> jdist(
            0, _cfg.simulation.node_startup_jitter_ms);
        for (int i = 0; i < n; ++i) {
            _node_init_at_ms[i] = static_cast<uint64_t>(jdist(_node_rng[(size_t)i]));
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
        cfg["_sim_bw_hz"]     = _cfg.nodes[i].bw;         // bw stored in Hz (JsonConfig kHz-double -> Hz)
        cfg["_sim_cr"]        = _cfg.nodes[i].cr;
        // §2.2 (realism ruling 2.2): simulation.radio.duty_cycle is a PERCENT (1 = 1%); the injected
        // _sim_duty_cycle keeps the firmware/Lua NodeConfig FRACTION semantic (0.01 = 1%), so divide /100
        // at this boundary — firmware behavior is unchanged (only the authoring unit moved to percent).
        cfg["_sim_duty_cycle"]           = _cfg.simulation.radio.duty_cycle / 100.0;
        cfg["_sim_duty_cycle_window_ms"] = _cfg.simulation.radio.duty_cycle_window_ms;
        cfg["_sim_rx_window_slop"]       = _cfg.simulation.rx_window_slop;   // §metal-fidelity (2026-07-07): opt-in metal RX-window slop
        cfg["_sim_snr_report_ceiling_db"] = _cfg.simulation.radio.snr_report_ceiling_db;   // §snr-unification A: FirmwareNode saturates the SNR the firmware sees to this ceiling (report-only)
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
    LbtConfig lbt_cfg;
    lbt_cfg.cad_miss_prob    = _cfg.simulation.radio.cad_miss_prob;
    lbt_cfg.cad_reliable_snr = _cfg.simulation.radio.cad_reliable_snr;
    lbt_cfg.cad_marginal_snr = _cfg.simulation.radio.cad_marginal_snr;
    // §1A-1: scenario-level default is "energy" (validated to energy|cad in JsonConfig).
    lbt_cfg.mode = (_cfg.simulation.radio.lbt_model == "cad") ? LbtMode::Cad : LbtMode::Energy;
    lbt_cfg.energy_threshold_snr_db = _cfg.simulation.radio.lbt_energy_threshold_snr_db;
    _lbt = std::make_unique<LbtModel>(
        n, lbt_cfg, _cfg.simulation.seed ^ 0xCAFEBABEull);

    // Energy mode: the busy verdict is computed at ASK TIME from the live
    // in-flight frame set + the SNR matrix (which LbtModel doesn't own).
    // This functor walks _in_flight and returns the latest end_ms among
    // frames whose SNR-at-observer >= threshold, at the current sim-time
    // (_now_ms), or 0 if idle. Pure matrix lookup — ZERO RNG draws, and it
    // reads the MATRIX SNR (same source the CAD pre-roll uses; fading-in-
    // verdicts is a separate future slice). Fresh on every call, so the
    // firmware's defer/retry re-asks always get a current verdict.
    if (lbt_cfg.mode == LbtMode::Energy) {
        _lbt->setEnergyBusyProvider(
            [this](int observer, float threshold_db) -> uint64_t {
                uint64_t busy_until = 0;
                for (const auto& f : _in_flight) {
                    if (f.sender_id == observer) continue;   // self-TX handled separately
                    if (f.end_ms <= _now_ms) continue;       // already ended this step
                    LinkParams lp;
                    if (!_links->getLink(f.sender_id, observer, lp)) continue;
                    if (lp.snr <= -100.0f) continue;         // no link
                    if (lp.snr < threshold_db) continue;     // below the energy floor
                    if (f.end_ms > busy_until) busy_until = f.end_ms;
                }
                return busy_until;
            });
    }

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
        cfg["_sim_bw_hz"]     = _cfg.nodes[i].bw;         // bw stored in Hz (JsonConfig kHz-double -> Hz)
        cfg["_sim_cr"]        = _cfg.nodes[i].cr;
        // §2.2 (realism ruling 2.2): simulation.radio.duty_cycle is a PERCENT (1 = 1%); the injected
        // _sim_duty_cycle keeps the firmware/Lua NodeConfig FRACTION semantic (0.01 = 1%), so divide /100
        // at this boundary — firmware behavior is unchanged (only the authoring unit moved to percent).
        cfg["_sim_duty_cycle"]           = _cfg.simulation.radio.duty_cycle / 100.0;
        cfg["_sim_duty_cycle_window_ms"] = _cfg.simulation.radio.duty_cycle_window_ms;
        cfg["_sim_rx_window_slop"]       = _cfg.simulation.rx_window_slop;   // §metal-fidelity (2026-07-07): opt-in metal RX-window slop
        cfg["_sim_snr_report_ceiling_db"] = _cfg.simulation.radio.snr_report_ceiling_db;   // §snr-unification A: FirmwareNode saturates the SNR the firmware sees to this ceiling (report-only)
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

void SimController::validateSendByNameCommands() const {
    // Mirrors processCommandsAtStep()'s guards exactly (lua_fn deferred, unknown node
    // name skipped, meshroute-only rewrite) so the pre-flight can never accept a
    // command the fire site would refuse, or vice versa. Both call the one
    // resolveAddresseeOnSenderLayer().
    for (const auto& cmd : _cfg.commands) {
        if (!cmd.lua_fn.empty()) continue;
        const auto sit = _name_to_id.find(cmd.node);
        if (sit == _name_to_id.end()) continue;
        const SimConfig::NodeDef& sender = _cfg.nodes[sit->second];
        if (sender.engine != "meshroute") continue;
        const SendByName p = parseSendByName(cmd.command);
        if (!p.named()) continue;
        const auto ait = _name_to_id.find(p.name);
        if (ait == _name_to_id.end()) continue;   // a numeric/unknown dst passes through
        const SimConfig::NodeDef& addressee = _cfg.nodes[ait->second];
        const AddresseeId r = resolveAddresseeOnSenderLayer(sender, addressee);
        if (r.src == AddresseeIdSource::RefuseNoShared
            || r.src == AddresseeIdSource::RefuseAmbiguousSender) {
            throw std::runtime_error(
                sendByNameRefusal(sender, addressee, cmd.command, r.src)
                + " [scenario command at_ms=" + std::to_string(cmd.at_ms) + "]");
        }
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
        // R3 (Q1=b): meshroute nodes take a NUMERIC dst (no name map on-device); the
        // host resolves "send <name> <text>" -> "send <id> <text>" here so scenarios
        // stay readable and dm_delivery's configured_pairs still resolves the pair.
        std::string command = cmd.command;
        if (_cfg.nodes[target].engine == "meshroute") {
            // Resolve "send <name>" / "send_e2e <name>" -> "<verb> <id>", rebuilding with the SAME verb.
            // ★ The id is the one the addressee wears ON THIS SENDER'S LAYER, which for a
            // dual-layer gateway is NOT its momentary protocolId() — see
            // resolveAddresseeOnSenderLayer() for the window-phase trap. Single-layer
            // addressees keep the LIVE protocol id (not the array index, and not the
            // configured node_id: they differ whenever a scenario sets node_id != slot, or
            // the node takes a DAD/join/mobile lease at runtime).
            const SendByName p = parseSendByName(command);
            if (p.named()) {
                const auto nit = _name_to_id.find(p.name);
                if (nit != _name_to_id.end()) {
                    const SimConfig::NodeDef& sender    = _cfg.nodes[target];
                    const SimConfig::NodeDef& addressee = _cfg.nodes[nit->second];
                    const AddresseeId r = resolveAddresseeOnSenderLayer(sender, addressee);
                    int dst = 0;
                    switch (r.src) {
                        case AddresseeIdSource::PerLayerNodeId: dst = r.node_id; break;
                        case AddresseeIdSource::LiveProtocolId:
                            dst = _nodes[nit->second]->protocolId();
                            break;
                        default:
                            // Unreachable: validateSendByNameCommands() refuses these at
                            // initialize(), before a single event is emitted. Kept as a
                            // hard stop so a future caller cannot re-introduce the silent
                            // protocolId() fallback (C2).
                            throw std::runtime_error(
                                sendByNameRefusal(sender, addressee, cmd.command, r.src));
                    }
                    command = command.substr(0, p.verb_len) + std::to_string(dst)
                              + command.substr(p.name_end);
                }
            }
        }
        std::string reply = _nodes[target]->onCommand(command);
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

        // Forced-drop bookkeeping (R3.x): a directive's counter must advance
        // ONCE per physical frame, not once per (frame,receiver) — else a
        // broadcast reaching M receivers (or a wildcard `to`) would consume M
        // from `count`. Per-frame: dd_counted[k] = this frame already advanced
        // directive k; dd_drop[k] = this frame fell in k's drop window (so drop
        // it to EVERY receiver matching `to`). Only sized when directives exist.
        const size_t n_dd = _cfg.drop_directives.size();
        std::vector<uint8_t> dd_counted(n_dd, 0), dd_drop(n_dd, 0);

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

            // §1.5: shift the received signal by the frame's explicit-TX-power delta BEFORE fading /
            // threshold / collision-consult / rx-event, so every downstream verdict sees the adjusted
            // budget. Inert when the frame carries the -127 sentinel (the whole corpus today).
            {
                const float pdelta = txPowerDeltaDb(tx.power_dbm,
                                                    _cfg.simulation.path_loss.tx_power_dbm);
                lp.snr  += pdelta;
                lp.rssi += pdelta;
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
            // All physics rolls for this directed link draw from its own
            // stream (Slice C) — fading, PER sigmoid, preamble-miss and
            // per-link loss below — so link B's traffic can never perturb
            // link A's fading/loss sequence, and node draw counts can't
            // perturb the physics at all.
            std::mt19937& lrng = linkRng(static_cast<uint64_t>(link_idx));
            _fading_last_update_ms[link_idx] = now;
            const uint64_t coh_ms = static_cast<uint64_t>(
                _cfg.simulation.radio.snr_coherence_ms);
            const float fade_offset =
                advanceFading(_fading[link_idx],
                              lp.snr_std_dev,
                              coh_ms,
                              /*step_ms=*/now,
                              lrng);
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

            // BW-mismatch gate (§bw-gating, 2026-07-25 realism review §6.1.1).
            // The SF gate's twin on the other PHY axis: a LoRa modem
            // demodulates only the BANDWIDTH its registers are set to, so a
            // receiver listening on 125 kHz cannot decode a 250 kHz frame at
            // any SNR (nor the reverse) — confirmed across the SX126x/SX127x
            // families. Before this gate the sim decoded such a frame
            // perfectly, which made a dual-BW gateway's layers RF-CONNECTED in
            // sim while they are RF-ISOLATED on metal.
            // _node_rx_bw_hz[rcv] is the receiver's LIVE bandwidth (seeded from
            // nodes[i].bw, moved by Hal::set_rx_bw / self:set_rx_bw) — NOT
            // _radios[rcv]->getBwHz(), which tracks the last TRANSMISSION.
            // Placed AFTER the SF gate so an SF-mismatched frame keeps
            // reporting as drop_sf_mismatch (no event reclassification), and
            // BEFORE drop_weak because "not tuned to this signal" outranks
            // "signal too weak".
            // NOTE: this is a DECODE-path gate only. A BW-mismatched frame
            // still deposits in-band energy, so it deliberately keeps feeding
            // the collision verdict and the energy-LBT / preamble-detect
            // provider — bandwidth grants NO orthogonality (unlike the
            // cross-SF chirp-rate property in CollisionModel.cpp).
            // No fallback on a bad rx bw: a non-positive value can't compare
            // equal to a real tx.bw_hz, so the frame is REFUSED, never passed
            // (and initialize() already throws on a bw <= 0 seed).
            const int rx_bw_hz = _node_rx_bw_hz[rcv];
            if (tx.bw_hz != rx_bw_hz) {
                if (!would_decode) continue;  // off-net, silent
                EventLog::dropBwMismatch(
                    static_cast<unsigned long>(now),
                    _nodes[tx.sender_id]->name().c_str(),
                    _nodes[rcv]->name().c_str(),
                    tx.bw_hz, rx_bw_hz,
                    snr_at_rcv, lp.rssi,
                    reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                    static_cast<int>(tx.bytes.size()),
                    static_cast<uint32_t>(tx.end_ms - tx.start_ms),
                    tx.sf);
                continue;
            }

            // SF + BW match and we haven't collided. drop_weak captures
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
                if (u(lrng) < per) {
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
                if (u(lrng) < miss_prob) {
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
                if (u(lrng) < lp.loss) {
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

            // Strict half-duplex enforcement + the TX->RX settling tail.
            // One receiver-side "was this radio able to hear?" question with
            // TWO answers, deliberately kept as separate events:
            //   drop_halfduplex   — rcv's own TX was CONCURRENT with
            //     [tx.start_ms, tx.end_ms]: one PA path, the modem was
            //     transmitting and never heard the frame.
            //   drop_tx_settling  — §tx-turnaround (2026-07-25) DONE: rcv's own
            //     TX had ENDED, but the radio was still in its TX->RX
            //     turnaround (LNA re-enable + PLL relock) when this frame's
            //     PREAMBLE arrived. Real hardware needs tx_to_rx_delay_ms
            //     (8 ms bench-measured) to come back; the sim used to be
            //     instantly receptive and so heard frames metal would miss.
            //     Before this, _earliest_rx_ms was set ONLY inside the
            //     bypassed startSendRaw and read ONLY by the (equally
            //     bypassed) isSendComplete, so nothing on the delivery path
            //     ever consulted it — see §startSendRaw-bypass in the TX loop.
            // Modelled by EXTENDING rcv's own-TX interval to
            // [own.start_ms, own.end_ms + settle) for the overlap test. Both
            // arms below must apply the same extension — a divergence between
            // the live-_in_flight scan and the compacted-out fallback would be
            // a latent, traffic-pattern-dependent bug.
            // The concurrent case is tested FIRST and unchanged, so the drop_
            // halfduplex classification is bit-for-bit what it always was; only
            // frames that used to be DELIVERED can become drop_tx_settling.
            //
            // Read from config, never a literal. Truncating float->int matches
            // the RX->TX side's existing convention (SimRadio's (uint32_t)
            // casts of the same pair of knobs); the >0 test is only there
            // because casting a negative float to an unsigned type is UB —
            // a negative turnaround is not a configuration this honours.
            const float settle_f = _cfg.simulation.radio.tx_to_rx_delay_ms;
            const uint64_t settle_ms =
                (settle_f > 0.0f) ? static_cast<uint64_t>(settle_f) : 0;
            bool     rcv_was_tx    = false;   // concurrent -> drop_halfduplex
            uint64_t deaf_until_ms = 0;       // settling   -> drop_tx_settling
            for (const auto& other : _in_flight) {
                if (other.sender_id != rcv) continue;
                if (other.start_ms >= tx.end_ms) continue;
                if (other.end_ms > tx.start_ms) {
                    rcv_was_tx = true;
                    break;
                }
                if (other.end_ms + settle_ms > tx.start_ms &&
                    other.end_ms + settle_ms > deaf_until_ms) {
                    deaf_until_ms = other.end_ms + settle_ms;
                }
            }
            // Also catch a receiver TX that overlapped this frame's airtime (or
            // whose settling tail did) but already ended — compacted out of
            // _in_flight before this frame is delivered at its end_ms. The
            // frame's preamble still arrived while the receiver was
            // transmitting or coming back, so the radio never locked on it.
            // end_ms == 0 means "this node has never transmitted" (a real TX
            // always ends > 0): without that guard the settling tail would
            // make every node spuriously deaf for the first settle_ms of the run.
            if (!rcv_was_tx) {
                const uint64_t own_start = _node_last_tx_start_ms[(size_t)rcv];
                const uint64_t own_end   = _node_last_tx_end_ms[(size_t)rcv];
                if (own_end != 0 && own_start < tx.end_ms) {
                    if (own_end > tx.start_ms) {
                        rcv_was_tx = true;
                    } else if (own_end + settle_ms > tx.start_ms &&
                               own_end + settle_ms > deaf_until_ms) {
                        deaf_until_ms = own_end + settle_ms;
                    }
                }
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
            if (deaf_until_ms != 0) {
                EventLog::dropTxSettling(
                    static_cast<unsigned long>(now),
                    _nodes[tx.sender_id]->name().c_str(),
                    _nodes[rcv]->name().c_str(),
                    deaf_until_ms,
                    reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                    static_cast<int>(tx.bytes.size()),
                    static_cast<uint32_t>(tx.end_ms - tx.start_ms),
                    tx.sf, tx.bw_hz);
                continue;
            }

            // Deterministic forced drop (R3.x lossy gate). Placed AFTER all
            // physics gates so it composes with (and is independent of)
            // sigma_db / Bernoulli loss: a surviving reception matching a
            // forced_drops directive is dropped here, firing exactly one
            // protocol retry reproducibly. The loop never runs when
            // drop_directives is empty (deterministic, makes no RNG draws).
            // Each directive's counter advances once per
            // physical FRAME (see dd_counted above); the Nth..Nth+count-1
            // frames are dropped to every receiver matching `to`.
            {
                bool forced_drop = false;
                for (size_t k = 0; k < n_dd; ++k) {
                    const auto& dd = _cfg.drop_directives[k];
                    if (!dd.from.empty()  && dd.from  != _nodes[tx.sender_id]->name()) continue;
                    if (!dd.to.empty()    && dd.to    != _nodes[rcv]->name())          continue;
                    if (!dd.label.empty() && dd.label != tx.label)                     continue;
                    if (!dd_counted[k]) {                           // count ONCE per physical frame
                        dd_counted[k] = 1;
                        const long long mi = ++_drop_match_count[k];   // 1-based; 64-bit window math
                        dd_drop[k] = (mi >= dd.nth &&
                                      mi < static_cast<long long>(dd.nth) + dd.count) ? 1 : 0;
                    }
                    if (dd_drop[k]) {                               // drop this frame -> this receiver
                        EventLog::dropForced(
                            static_cast<unsigned long>(now),
                            _nodes[tx.sender_id]->name().c_str(),
                            _nodes[rcv]->name().c_str(),
                            reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                            static_cast<int>(tx.bytes.size()),
                            static_cast<uint32_t>(tx.end_ms - tx.start_ms),
                            tx.sf, tx.bw_hz,
                            tx.label.empty() ? nullptr : tx.label.c_str());
                        forced_drop = true;
                        break;
                    }
                }
                if (forced_drop) continue;
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
                        bi.tag           = p.tag;            // R4.5b frame-type echo
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
                        bi.tag           = p.tag;            // R4.5b frame-type echo
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
            if (_nodes[i]->lbtEnabled() && _lbt->isChannelBusy(i, now)) {
                RadioBusyInfo bi;
                bi.reason        = "channel_busy";
                bi.len           = static_cast<int>(p.bytes.size());
                bi.sf            = sf;
                bi.label         = p.label;
                bi.tx_info       = p.info;
                        bi.tag           = p.tag;            // R4.5b frame-type echo
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
                // §2.2 (realism ruling): the GLOBAL simulation.radio.duty_cycle is a PERCENT (1 = 1%);
                // this enforcement math works in the FRACTION domain (budget = dc * window), so divide
                // /100 here. The per-node override below is a raw JSON passthrough kept as a FRACTION
                // (Lua-parity — the Lua script reads the same key as a fraction); it is NOT re-scaled.
                float dc = _cfg.simulation.radio.duty_cycle / 100.0f;   // PERCENT -> fraction
                unsigned long dc_window = _cfg.simulation.radio.duty_cycle_window_ms;
                const auto& nc = _cfg.nodes[i].config;
                if (nc.is_object()) {
                    auto it = nc.find("duty_cycle");
                    if (it != nc.end() && it->is_number())
                        dc = it->get<float>();   // per-node override: FRACTION (Lua-parity passthrough)
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
                        bi.tag           = p.tag;            // R4.5b frame-type echo
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

            // §tx-fail (2026-07-25) — DONE. Modem-level transmit failure
            // (SPI / RadioLib error path), the LAST gate before the frame goes
            // on air — exactly where startSendRaw rolls it, and after LBT and
            // the duty ledger, matching the device order (Node decides, then
            // DeviceHal::pump_tx arms the radio).
            // ★ METAL SEMANTICS, verified at lib/hal/device_hal.cpp:36-46: a
            // failed arm DROPS the frame and the protocol is NOT told ("A
            // failed arm drops the frame (rare radio_error; not retried
            // here)"); the duty ledger is debited only on success. So: emit
            // the event, push no InFlight, debit no airtime, send no
            // onRadioBusy — MAC timeouts are the recovery path, on metal and
            // here alike. NOT a silent vanish: tx_fail names the node.
            // rollTxFail() makes ZERO RNG draws while tx_fail_prob == 0, so
            // this block is byte-inert for every scenario that omits the key.
            if (_radios[i]->rollTxFail()) {
                EventLog::txFail(static_cast<unsigned long>(now),
                                 _nodes[i]->name().c_str(),
                                 _radios[i]->getTxFailCount());
                continue;
            }

            // ★★ §startSendRaw-bypass (2026-07-25) — STILL MISSING, DEFERRED
            // BY RULING. The original note here read: "TODO(Y2): plumb through
            // SimRadio::startSendRaw so half-duplex/LBT bookkeeping fires; for
            // v1 we synthesise the InFlight directly." That bypass is STILL IN
            // PLACE — everything below synthesises the InFlight by hand.
            // What this slice DID close is the two OBSERVABLE consequences of
            // the bypass, not the bypass itself:
            //   [DONE] tx_fail_prob is honoured    -> the roll just above
            //   [DONE] TX->RX deafness is modelled -> the settling arm of the
            //          half-duplex gate in deliverReceptionsForStep
            //   [DONE, 2026-07-07] RX->TX turnaround -> getEarliestTxMs below
            // What is STILL hand-mirrored (i.e. duplicated, i.e. free to
            // drift) or simply absent because startSendRaw never runs:
            //   * SimRadio's own TX state — _state/_tx_done_at/_packets_sent
            //     never move, so isSendComplete()/onSendFinished() are inert;
            //   * _earliest_rx_ms is never set, so SimRadio::notifyChannelBusy's
            //     "can't detect a preamble before the radio is back" clamp
            //     (SimRadio.cpp:63) is a no-op — CAD-mode LBT still hears
            //     preambles that arrived during the node's own TX + settling
            //     (inert under the default "energy" model, which asks the live
            //     in-flight set instead);
            //   * the deaf window is computed from _in_flight /
            //     _node_last_tx_* in the delivery gate rather than read from
            //     the radio, so the two must be kept consistent by hand.
            // WHY still deferred: unifying the two TX paths is a substantially
            // larger refactor (the whole staging/collision/LBT-notify block
            // below would have to move behind the radio), and C1 forbids
            // folding a refactor into a fix. Recorded decision, not oversight.
            InFlight f;
            f.sender_id     = i;
            // §metal-fidelity (2026-07-07): a firmware-node TX (synthesised here, bypassing startSendRaw) must still
            // honor the radio's RX->TX turnaround — the sender can't TX until _earliest_tx_ms after its last RX ends.
            // This is the metal latency the firmware's airtime math can't see (the CTS-wait bug). Idealized scenarios
            // keep the ~1ms default turnaround (near-inert); a metal scenario's ~50ms surfaces the late-CTS bug.
            const unsigned long earliest_tx = static_cast<unsigned long>(_radios[i]->getEarliestTxMs());
            f.start_ms      = (now > earliest_tx) ? now : earliest_tx;
            f.end_ms        = f.start_ms + airtime;
            f.bytes         = std::move(p.bytes);
            f.label         = p.label;
            f.info          = p.info;
            f.sf            = sf;
            f.bw_hz         = bw_hz;
            f.cr            = cr;
            f.power_dbm     = p.power_dbm;   // §1.5: carry the frame's explicit TX power (delta applied at delivery/collision)
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
                    // §1.5: each flight's collision SNR carries its own explicit-TX-power delta (inert @ -127).
                    lp_f.snr += txPowerDeltaDb(f.power_dbm, _cfg.simulation.path_loss.tx_power_dbm);
                    lp_e.snr += txPowerDeltaDb(e.power_dbm, _cfg.simulation.path_loss.tx_power_dbm);
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
            // Same loop also calls SimRadio::notifyRxStart on each observer,
            // which arms that radio's RX-active window AND — via
            // _earliest_tx_ms = rx_end + rx_to_tx_delay_ms — the observer's
            // RX->TX turnaround. ⚠ NOT merely state hygiene: f.start_ms above
            // reads getEarliestTxMs(), so this is the value that decides when
            // every RESPONDER may reply. (The `isReceiving()` flag itself is
            // still unconsulted by the delivery path, which uses the _in_flight
            // ground truth; the previous comment here claimed the whole call
            // was unconsulted, which drifted once §metal-fidelity 2026-07-07
            // started reading getEarliestTxMs.)
            //
            // ★ §rx-window-arming (2026-07-25) — FIXED HERE. notifyRxStart
            // computes `clock_now + duration`, so passing `airtime` armed the
            // window from the TX *DECISION* time. Whenever this frame's start
            // was itself deferred by the SENDER's own RX->TX turnaround
            // (f.start_ms > now — every reply leg of an RTS/CTS/DATA/ACK
            // handshake), that put every observer's rx_end — and therefore its
            // earliest_tx — a full rx_to_tx_delay_ms EARLY, exactly cancelling
            // the turnaround for the reply: the reply then began at precisely
            // this frame's end_ms, with zero turnaround. Harmless while nothing
            // modelled the TX->RX direction; LETHAL once it is (the originator
            // is deaf for tx_to_rx_delay_ms after its own TX ends, so a reply
            // starting at end_ms + 0 lands inside the deaf window and EVERY
            // ACK/CTS dies). Pass the frame's REAL remaining duration so
            // rx_end == f.end_ms. Inert for any frame that was not deferred:
            // f.start_ms == now => end_ms - now == airtime.
            const auto& just_pushed = _in_flight.back();
            const uint32_t rx_busy_ms =
                static_cast<uint32_t>(just_pushed.end_ms - now);
            for (int observer = 0; observer < n; ++observer) {
                if (observer == i) continue;
                LinkParams lp;
                if (!_links->getLink(i, observer, lp)) continue;
                if (lp.snr <= -100.0f) continue;
                _radios[observer]->notifyRxStart(rx_busy_ms);

                // "Did the observer's radio detect this transmission?"
                //   CAD mode    — probabilistic CAD-miss roll vs SNR (draws
                //                  the LBT RNG); on a hit, record the busy
                //                  window (busy is pre-rolled here at TX-start).
                //   ENERGY mode — deterministic noise-floor energy detect:
                //                  detected iff SNR-at-observer >= threshold.
                //                  NO busy window is recorded — busy is computed
                //                  at ask-time from the live in-flight set (see
                //                  the energy provider). ZERO RNG draws.
                // Either way, `detected` gates the PreambleDetected callback
                // below (the energy threshold is the RNG-free analogue of the
                // CAD-miss roll that historically gated it).
                bool detected;
                if (_lbt->mode() == LbtMode::Energy) {
                    detected = (lp.snr >= _lbt->config().energy_threshold_snr_db);
                } else {
                    detected = _lbt->shouldNotifyBusy(lp.snr);
                    if (detected) {
                        _lbt->notifyChannelBusy(observer, i,
                                                just_pushed.end_ms, lp.snr);
                    }
                }
                if (!detected) continue;
                // SX1262-PreambleDetected equivalent: fire only if the
                // observer's modem is currently tuned to a SF that includes
                // the TX's SF. LoRa SFs are quasi-orthogonal at the same BW;
                // a radio set to SF7 won't see an SF10 preamble. The detect
                // gate above already modelled the miss (CAD roll / energy
                // threshold). Fires regardless of
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
