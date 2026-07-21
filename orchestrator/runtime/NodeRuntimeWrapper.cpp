// orchestrator/runtime/NodeRuntimeWrapper.cpp
//
// Slice 5 (faithful two-lib): the per-variant bridge between the namespace-neutral
// sim interfaces (mrsim::ISimHal / mrsim::INodeRuntime) and ONE firmware namespace
// (MESHROUTE_NS = meshroute | meshroute_gw). This TU is compiled TWICE — once into
// meshroute_core_normal (ns meshroute, MR_N_LAYERS=1) and once into meshroute_core_gw
// (ns meshroute_gw, MR_N_LAYERS=2 + the gateway caps). Each compilation provides:
//   - HalAdapter   : IS-A MESHROUTE_NS::Hal, forwards every Hal call to mrsim::ISimHal.
//   - NodeRuntime  : IS-A mrsim::INodeRuntime, owns a HalAdapter + a MESHROUTE_NS::Node,
//                    and does ALL firmware-struct work (NodeConfig build, Command parse,
//                    RxMeta/BusyInfo build, Push->NDJSON drain) in its own namespace.
//   - the factory  : exactly ONE of makeNodeRuntimeNormal / makeNodeRuntimeGw, keyed on
//                    MR_GATEWAY_BUILD, so lus (which links BOTH libs) sees no dup symbol.
//
// FirmwareNode.cpp stays namespace-neutral (no NS:: type ever crosses into it); the two
// ODR-distinct firmware libs never meet in one TU. See [[session_handover_slice5_sim]].

#include "orchestrator/runtime/ISimHal.h"
#include "orchestrator/runtime/INodeRuntime.h"

#include "hal.h"         // MESHROUTE_NS::Hal / TxParams / EventField / TxResult / BusyInfo / RxMeta
#include "node.h"        // MESHROUTE_NS::Node / NodeConfig / LayerConfig
#include "command.h"     // MESHROUTE_NS::Command / CmdKind / CmdResult / CmdCode / Push / PushKind
#include "frame_codec.h" // MESHROUTE_NS::DATA_FLAG_E2E_ACK_REQ (the wrapper is C++20 -> the canonical flag, not a literal)
#include "identity.h"    // §enc: MESHROUTE_NS::Identity / identity_from_seed — install a real E2E crypto identity from a per-node seed

#include "json/json.hpp"

#include <cstdint>
#include <random>      // std::mt19937 — the per-node crypto-bytes stream (rand_bytes), separate from rand_range
#include <set>         // §1.2 (2026-07-20 review): the node.config key whitelist (unknown key -> fail loud)
#include <string>
#include <string_view>
#include <vector>

namespace {

// ===========================================================================
// HalAdapter — MESHROUTE_NS::Hal forwarded to the neutral mrsim::ISimHal.
// The Node sees a real NS::Hal; every call is translated to ISimHal (which the
// FirmwareNode implements over the sim's TimerWheel/SimRadio/_sim_rng/EventLog).
// ===========================================================================
class HalAdapter : public MESHROUTE_NS::Hal {
public:
    HalAdapter(mrsim::ISimHal& sim, uint32_t crypto_seed) : _sim(sim), _rng_bytes(crypto_seed) {}

    MESHROUTE_NS::TxResult tx(const uint8_t* bytes, size_t len,
                              const MESHROUTE_NS::TxParams& p) override {
        mrsim::SimTxParams sp;
        sp.sf           = p.sf;
        sp.bw_hz        = p.bw_hz;
        sp.cr           = p.cr;
        sp.power_dbm    = p.power_dbm;
        sp.preamble_sym = p.preamble_sym;
        sp.tag          = p.tag;
        sp.label        = p.label;
        sp.info         = p.info;
        switch (_sim.simTx(bytes, len, sp)) {
            case mrsim::kSimTxOk:      return MESHROUTE_NS::TxResult::ok;
            case mrsim::kSimTxBusy:    return MESHROUTE_NS::TxResult::busy;
            case mrsim::kSimTxTooLong: return MESHROUTE_NS::TxResult::too_long;
            default:                   return MESHROUTE_NS::TxResult::radio_error;
        }
    }
    void     set_rx_sf(int sf) override                   { _sim.simSetRxSf(sf); }
    void     set_rx_bw(uint32_t bw_hz) override           { _sim.simSetRxBw(bw_hz); }   // §metal-fidelity: per-layer bw retune (device _def_bw mirror) -> the slop follows the active layer
    uint64_t channel_busy_until() override                { return _sim.simChannelBusyUntil(); }
    uint64_t airtime_used_ms(uint64_t window_ms) override { return _sim.simAirtimeUsedMs(window_ms); }
    uint64_t oldest_tx_end_ms() override                  { return _sim.simOldestTxEndMs(); }
    uint32_t rx_window_slop_ms(int sf) const override     { return _sim.simRxWindowSlopMs(sf); }
    uint64_t now() override                               { return _sim.simNow(); }
    bool     after(uint32_t delay_ms, uint32_t id) override { return _sim.simAfter(delay_ms, id); }
    void     cancel(uint32_t id) override                 { _sim.simCancel(id); }
    void     set_protocol_id(int id) override             { _sim.simSetProtocolId(id); }
    int      rand_range(int lo, int hi) override          { return _sim.simRandRange(lo, hi); }
    // rand_bytes (Crypto phase 1): crypto-strength entropy on metal; in the sim a DETERMINISTIC, per-node-seeded
    // stream that is DISTINCT from rand_range — so a run reproduces AND it never advances simRandRange's jitter
    // draw-order (the lua/meshroute alignment contract). Most scenarios never call it (e2e_dm off), so it's inert
    // for the baseline; an e2e-on scenario gets reproducible nonces/keys.
    void     rand_bytes(uint8_t* out, size_t n) override  { for (size_t i = 0; i < n; ++i) out[i] = static_cast<uint8_t>(_rng_bytes()); }
    void     emit(const char* type, const MESHROUTE_NS::EventField* fields, size_t n) override {
        // Sim-side glue (never on metal) → a heap vector is fine; no truncation, no per-field cap.
        std::vector<mrsim::SimEventField> v(n);
        for (size_t k = 0; k < n; ++k) {
            const auto& f = fields[k];
            v[k].key  = f.key;
            v[k].type = static_cast<uint8_t>(f.type);   // EventField::T order == SimEventField type codes (0=i64..3=bool)
            v[k].i    = f.i;
            v[k].f    = f.f;
            v[k].s    = f.s;
            v[k].b    = f.b;
        }
        _sim.simEmit(type, v.data(), n);
    }
    void     log(const char* msg) override               { _sim.simLog(msg); }
    void     panic(const char* why) override             { _sim.simPanic(why); }

private:
    mrsim::ISimHal& _sim;
    std::mt19937    _rng_bytes;   // rand_bytes ONLY — a stream separate from rand_range (simRandRange); seeded per-node from key_hash32
};

// ===========================================================================
// NodeRuntime — mrsim::INodeRuntime over a MESHROUTE_NS::Node. Owns the
// HalAdapter (declared BEFORE _node so it constructs first; _node borrows it).
// ===========================================================================
class NodeRuntime : public mrsim::INodeRuntime {
public:
    NodeRuntime(int id, const char* name, uint32_t key_hash32, mrsim::ISimHal& hal)
        : _hal(hal, key_hash32),   // seed the per-node rand_bytes crypto stream (distinct from rand_range)
          _node(_hal, static_cast<uint8_t>(id), key_hash32, name) {}

    bool onInit(const nlohmann::json& config) override;

    void onRecv(const uint8_t* bytes, size_t len,
                float snr_db, float rssi_dbm, int16_t src_hint, uint64_t recv_ms) override {
        MESHROUTE_NS::RxMeta meta{snr_db, rssi_dbm, recv_ms, src_hint};
        _node.on_recv(bytes, len, meta);
    }

    void onTimer(uint32_t timer_id) override { _node.on_timer(timer_id); }

    std::string onCommand(std::string_view cmd_str) override;

    void onPreambleDetected(uint64_t time_ms, int from_id, float snr_db) override {
        (void)from_id; (void)snr_db;
        _node.on_preamble_detected(time_ms);
    }

    void onRadioBusy(const char* reason, uint16_t tag, int16_t sf, uint64_t busy_until_ms) override {
        MESHROUTE_NS::BusyReason r = MESHROUTE_NS::BusyReason::channel_busy;
        const std::string_view rs(reason ? reason : "");
        if      (rs == "self_tx_in_flight")   r = MESHROUTE_NS::BusyReason::self_tx_in_flight;
        else if (rs == "oversized")           r = MESHROUTE_NS::BusyReason::oversized;
        else if (rs == "duty_cycle_exceeded") r = MESHROUTE_NS::BusyReason::duty_cycle_exceeded;
        MESHROUTE_NS::BusyInfo bi{r, tag, sf, busy_until_ms};
        _node.on_radio_busy(bi);
    }

    void drainPushes(const PushSink& sink) override;

private:
    HalAdapter         _hal;
    MESHROUTE_NS::Node _node;
};

// ---- onInit: JSON -> NS::NodeConfig + Node::on_init ------------------------
// Verbatim port of the legacy FirmwareNode::onInit cfg-build (meshroute:: -> MESHROUTE_NS::),
// PLUS the new dual-layer (n_layers + layers[]) parse. Returns the on_init bool (false = REFUSED).
bool NodeRuntime::onInit(const nlohmann::json& config) {
    MESHROUTE_NS::NodeConfig cfg;  // defaults from node.h
    if (config.is_object()) {
        // §1.2 (2026-07-20 realism review): whitelist-validate EVERY top-level node.config key. An unknown
        // key used to be silently ignored (a typo, or an unported knob, quietly became a C++ struct default).
        // Now an unrecognized key FAILS LOUD (named in the log + return false -> FirmwareNode nulls the node).
        // The whitelist has four groups: (A) keys mapped below, (B) NodeConfig fields newly mapped this slice,
        // (C) SimController-injected _sim_* runtime fields, (D) known LEGACY sim-only keys that were NEVER
        // ported to the C++ NodeConfig (no field to map) but ride shipped corpus scenarios — accepted-and-
        // ignored (as before) so those scenarios stay valid, while a genuine typo in any mapped key still fails.
        // Nested layers[]/gateway_layers sub-objects are NOT strictly validated here (their parse stays
        // permissive — s27's layers carry scheduler sub-keys the parse ignores); freq_mhz IS mapped below.
        static const std::set<std::string> kAllowedKeys = {
            // (A) mapped scalars/keys read in this function
            "routing_sf","beacon_period_ms","team_beacon_period_ms","beacon_max_idle_ms","quiet_threshold_ms",
            "beacon_silence_jitter_ms","seen_bitmap_enabled","is_gateway","gateway_only","is_mobile","team_id",
            "mobile_autoregister","e2e_dm","leaf_id","layer_id","rt_aging_ttl_neighbor_ms","rt_aging_ttl_remote_ms",
            "rt_aging_check_period_ms","dv_hop_cap","channel_dirty_max_advertisements","channel_pull_jitter_ms",
            "channel_active_fraction","channel_min_interval_ms","dm_min_interval_ms","channel_origin_window_ms",
            "cap_route_request_last","cap_id_bind","id_bind_ttl_ms","allowed_data_sfs","duty_cycle",
            "duty_cycle_window_ms","bw_hz","cr","originator_max_per_window","peer_count","lbt_enabled",
            "lbt_backoff_ms","flood_lbt_max_defer_ms","nav_enabled","nav_ignore_rts","n_layers","layers","seed",
            // (B) NodeConfig fields newly mapped in §1.2 (previously ignored)
            "host_mobiles","join_required","req_sync_on_boot","req_sync_min_routes","sync_response_enabled",
            "sync_response_min_routes","lineage_id","config_epoch","leaf_name","gw_announce_duty_pct",
            "gw_announce_min_interval_ms","gw_herd_slack","intra_layer_relay","lat_e7","lon_e7","loc_in_dm",
            "loc_in_m","intro_attach",
            // (C) SimController-injected runtime fields (merged into every node's config)
            "_sim_warmup_ms","_sim_bw_hz","_sim_cr","_sim_duty_cycle","_sim_duty_cycle_window_ms",
            "_sim_rx_window_slop","_sim_snr_report_ceiling_db",
            // (D) known LEGACY sim-only keys never ported to the C++ NodeConfig — accepted-and-ignored (no
            //     field exists to map); they ride shipped scenarios (s09/s15 join+gateway-schedule tuning,
            //     top-level debug_* windows). Kept accepted so those scenarios validate; typos still fail.
            "discovery_beacon_period_ms","discovery_min_routes","gateway_layers","join_claim_guard_ms",
            "join_discover_jitter_ms","join_listen_ms","join_offer_backoff_min_ms","join_offer_backoff_max_ms",
            "state_snapshot_period_ms","sync_response_requester_mobile_penalty_ms","debug_start_ms","debug_end_ms",
        };
        for (auto it = config.begin(); it != config.end(); ++it) {
            if (kAllowedKeys.count(it.key()) == 0) {
                const std::string msg = "FATAL: meshroute config: unknown key \"" + it.key()
                    + "\" (typo or unported knob) — refusing config";
                _hal.log(msg.c_str());
                return false;
            }
        }
        cfg.routing_sf          = config.value("routing_sf",          cfg.routing_sf);
        cfg.beacon_period_ms    = config.value("beacon_period_ms",    cfg.beacon_period_ms);
        cfg.team_beacon_period_ms = config.value("team_beacon_period_ms", cfg.team_beacon_period_ms);   // §team-multihop Change A: a team member's steady cadence (default 5 min; sims set a faster value)
        cfg.beacon_max_idle_ms  = config.value("beacon_max_idle_ms",  cfg.beacon_max_idle_ms);
        cfg.quiet_threshold_ms  = config.value("quiet_threshold_ms",  cfg.quiet_threshold_ms);
        cfg.beacon_silence_jitter_ms = config.value("beacon_silence_jitter_ms", cfg.beacon_silence_jitter_ms);  // R4.3
        cfg.seen_bitmap_enabled = config.value("seen_bitmap_enabled", cfg.seen_bitmap_enabled);
        cfg.is_gateway          = config.value("is_gateway",          cfg.is_gateway);
        cfg.gateway_only        = config.value("gateway_only",        cfg.gateway_only);   // §7 pure-bridge switch
        cfg.is_mobile           = config.value("is_mobile",           cfg.is_mobile);
        cfg.team_id             = config.value("team_id",             cfg.team_id);             // §mobile 6.1: team overlay (0 = no team). A team member (is_mobile + team_id) team-DADs a _team_local_id + runs the team plane. Absent -> 0 -> static/lone unchanged (s18 byte-identical).
        cfg.mobile_autoregister = config.value("mobile_autoregister", cfg.mobile_autoregister); // §mobile: also seek a static home; a pure off-grid team leaves it default and just team-DADs.
        cfg.e2e_dm              = config.value("e2e_dm",              cfg.e2e_dm);              // §enc: default-crypt app DMs (CryptIntent::def follows this); send_hashx forces crypt regardless. Absent -> default -> unchanged.
        // leaf_id = the low 4 bits of the node's layer_id (frames.md: leaf_id IS the layer id, 0..15). The
        // multi-layer scenarios configure each node's layer via `layer_id` (1/2/3 here), so DERIVE the firmware
        // leaf from it — else every node defaults to leaf_id=0 and the byte-0 leaf gate (e.g. the channel-M
        // cross-leaf leak gate) is inert. An explicit `leaf_id` still overrides (single-layer / direct tests).
        cfg.leaf_id             = config.value("leaf_id",             cfg.leaf_id);
        if (config.contains("layer_id"))
            cfg.leaf_id = static_cast<uint8_t>(config.value("layer_id", 0) & 0x0F);
        // R2 route-aging TTLs (config-overridable so a gate can shrink 45min/3h to seconds).
        cfg.rt_aging_ttl_neighbor_ms = config.value("rt_aging_ttl_neighbor_ms", cfg.rt_aging_ttl_neighbor_ms);
        cfg.rt_aging_ttl_remote_ms   = config.value("rt_aging_ttl_remote_ms",   cfg.rt_aging_ttl_remote_ms);
        cfg.rt_aging_check_period_ms = config.value("rt_aging_check_period_ms", cfg.rt_aging_check_period_ms);
        cfg.dv_hop_cap               = config.value("dv_hop_cap",               cfg.dv_hop_cap); // network-wide (J-join distributes it in Slice 3)
        cfg.channel_dirty_max_advertisements = config.value("channel_dirty_max_advertisements", cfg.channel_dirty_max_advertisements); // K: BCN-digest retire count (Lua per-node; t68 shrinks it to 2)
        cfg.channel_pull_jitter_ms           = config.value("channel_pull_jitter_ms",           cfg.channel_pull_jitter_ms);           // digest-pull backoff (t69 shrinks it to pin pull order)
        // anti-spam v2 (2026-06-30): the flat channel_origin_max_per_window cap was REMOVED — replaced by the
        // duty-aware channel_cap_origin() (D/(frac·N·T_ch)). The per-leaf knobs below drive it; scenarios set them optionally.
        cfg.channel_active_fraction          = config.value("channel_active_fraction",          cfg.channel_active_fraction);          // per-origin channel-cap fairness divisor (default 0.125)
        cfg.channel_min_interval_ms          = config.value("channel_min_interval_ms",          cfg.channel_min_interval_ms);          // channel burst floor (default 10000)
        cfg.dm_min_interval_ms               = config.value("dm_min_interval_ms",               cfg.dm_min_interval_ms);               // own-DM burst floor (default 3000)
        cfg.channel_origin_window_ms         = config.value("channel_origin_window_ms",         cfg.channel_origin_window_ms);
        cfg.cap_route_request_last           = config.value("cap_route_request_last",           cfg.cap_route_request_last);           // per-dst RREQ table cap (t61 shrinks to 2 to exercise table_cap_hit refuse)
        cfg.cap_id_bind                      = config.value("cap_id_bind",                      cfg.cap_id_bind);                      // hash-locate id_bind cap (a gate shrinks it to exercise the refuse)
        cfg.id_bind_ttl_ms                   = config.value("id_bind_ttl_ms",                   cfg.id_bind_ttl_ms);                   // hash-locate binding TTL (a gate shrinks the 48h default to exercise aging)
        // allowed_data_sfs: [7,9] -> allowed_sf_bitmap (bit = sf), matching the Lua config key. The DATA-SF
        // selector picks the fastest SF in this set the link SNR supports; absent/empty -> NO data SF (the node
        // refuses to originate data — the single-SF data_sf fallback was removed, sf_list is now mandatory).
        if (config.contains("allowed_data_sfs") && config["allowed_data_sfs"].is_array()) {
            uint16_t bm = 0;
            for (const auto& v : config["allowed_data_sfs"]) {
                const int s = v.get<int>();
                if (s >= 5 && s <= 12) bm |= static_cast<uint16_t>(1u << s);
            }
            cfg.allowed_sf_bitmap = bm;
        }
        // R4.0 duty-cycle budget. Mirror the Lua precedence EXACTLY (dv_dual_sf.lua:8495-8496):
        //   self.duty_cycle = config.duty_cycle or config._sim_duty_cycle or 0.01
        // The NodeConfig field is a FRACTION (0.01 = 1%). SimController injects _sim_duty_cycle already
        // divided /100 from the PERCENT global simulation.radio.duty_cycle (§2.2 realism ruling — the
        // authoring unit moved to percent; this boundary value stays the fraction both engines expect),
        // so a scenario that sets only the GLOBAL radio.duty_cycle leaves nodes ENABLED at the same
        // budget on both engines (lua-vs-meshroute review #00). A per-node `duty_cycle` override is a raw
        // FRACTION passthrough (unscaled — the MeshRoute corpus uses none).
        cfg.duty_cycle               = config.value("duty_cycle",
                                          config.value("_sim_duty_cycle", 0.01));
        cfg.duty_cycle_window_ms     = config.value("duty_cycle_window_ms",
                                          config.value("_sim_duty_cycle_window_ms", 3600000u));
        // Radio bw/cr seam (cleanup #C, [[project_firmwarenode_sim_config_seam]]): mirror the Lua precedence
        // (dv_dual_sf.lua:8490-8491) `config.bw_hz or config._sim_bw_hz or 250000` / `config.cr or config._sim_cr
        // or 5`. SimController injects _sim_bw_hz (= node.bw*1000) + _sim_cr; without this the firmware uses the
        // struct-default 250000/5 and a NON-default-bw scenario diverges on every airtime calc (_flood_lbt_max_defer,
        // rts/ack-timeout, the #2 duty pre-check). Gate-inert (the gates run bw=250kHz/cr=5 = the defaults).
        // preamble_sym is NOT sim-injected -> a fixed protocol constant on both engines, no plumb needed.
        cfg.radio_bw_hz              = config.value("bw_hz", config.value("_sim_bw_hz", cfg.radio_bw_hz));
        cfg.radio_cr                 = config.value("cr",    config.value("_sim_cr",    cfg.radio_cr));
        // R4.4 anti-spam threshold (T-class, Lua on_init `config.originator_max_per_window or 6`).
        cfg.originator_max_per_window = config.value("originator_max_per_window", cfg.originator_max_per_window);
        // peer_count is a host-set sim-telemetry knob (N-1); the device has no
        // sim:nodes(), so rt_full convergence is sim-only. 0 = no rt_full emit.
        cfg.peer_count          = config.value("peer_count",          cfg.peer_count);
        // lbt_enabled gates the FIRMWARE's own tx_initiating/tx_flood LBT pre-check (R4.5). The HOST-side
        // channel_busy_until() primitive is gated by FirmwareNode's own _lbt_enabled (read separately there).
        cfg.lbt_enabled         = config.value("lbt_enabled",         cfg.lbt_enabled);   // R4.5 firmware LBT
        cfg.lbt_backoff_ms      = config.value("lbt_backoff_ms",      cfg.lbt_backoff_ms);        // 0 = derive
        cfg.flood_lbt_max_defer_ms = config.value("flood_lbt_max_defer_ms", cfg.flood_lbt_max_defer_ms);  // 0 = derive
        // NAV (virtual carrier sense). Inherit the firmware default (NodeConfig::nav_enabled = true) so the
        // sim and the device agree; set "nav_enabled": false in a scenario for an off comparison or to keep
        // a differential scenario lua-parity. C++-only feature; the Lua has no NAV.
        cfg.nav_enabled         = config.value("nav_enabled",         cfg.nav_enabled);
        cfg.nav_ignore_rts      = config.value("nav_ignore_rts",      cfg.nav_ignore_rts);   // tuning knob (firmware default false = answer)
        // §1.2 (2026-07-20 review): map the NodeConfig fields the wrapper NEVER read (they silently took the
        // C++ struct default — the proven-live `join_required` bug). Now a scenario can actually set them.
        // Absent -> the field's own default -> byte-identical to before (no corpus scenario sets most of these).
        cfg.host_mobiles             = config.value("host_mobiles",             cfg.host_mobiles);
        cfg.join_required            = config.value("join_required",            cfg.join_required);
        cfg.req_sync_on_boot         = config.value("req_sync_on_boot",         cfg.req_sync_on_boot);
        cfg.req_sync_min_routes      = config.value("req_sync_min_routes",      cfg.req_sync_min_routes);
        cfg.sync_response_enabled    = config.value("sync_response_enabled",    cfg.sync_response_enabled);
        cfg.sync_response_min_routes = config.value("sync_response_min_routes", cfg.sync_response_min_routes);
        cfg.lineage_id               = config.value("lineage_id",               cfg.lineage_id);
        cfg.config_epoch             = config.value("config_epoch",             cfg.config_epoch);
        cfg.gw_announce_duty_pct     = config.value("gw_announce_duty_pct",     cfg.gw_announce_duty_pct);
        cfg.gw_announce_min_interval_ms = config.value("gw_announce_min_interval_ms", cfg.gw_announce_min_interval_ms);
        cfg.gw_herd_slack            = config.value("gw_herd_slack",            cfg.gw_herd_slack);
        cfg.intra_layer_relay        = config.value("intra_layer_relay",        cfg.intra_layer_relay);
        cfg.loc_in_dm                = config.value("loc_in_dm",                cfg.loc_in_dm);
        cfg.loc_in_m                 = config.value("loc_in_m",                 cfg.loc_in_m);
        cfg.intro_attach             = config.value("intro_attach",             cfg.intro_attach);
        cfg.lat_e7                   = config.value("lat_e7",                   cfg.lat_e7);
        cfg.lon_e7                   = config.value("lon_e7",                   cfg.lon_e7);
        // leaf_name: string -> char[]+len (in the config_hash; a change re-fingerprints the leaf).
        if (config.contains("leaf_name") && config["leaf_name"].is_string()) {
            const std::string ln = config.value("leaf_name", std::string());
            const size_t m = ln.size() < MESHROUTE_NS::protocol::leaf_name_max
                                 ? ln.size() : MESHROUTE_NS::protocol::leaf_name_max;
            for (size_t i = 0; i < m; ++i) cfg.leaf_name[i] = ln[i];
            cfg.leaf_name_len = static_cast<uint8_t>(m);
        }
        // ---- dual-layer gateway (Slice 5 sim): n_layers + a layers[] array map 1:1 to cfg.n_layers /
        //      cfg.layers[0..1] (LayerConfig). A gateway scenario node sets n_layers=2 + two layer objects;
        //      on_init validates + REFUSES a bad config (§3.2, fail-loud). Single-layer nodes omit both
        //      (n_layers defaults to 1; on_init mirrors the legacy scalars into layers[0]). cfg.layers[] is
        //      sized 2, so any entries past the first two are unrepresentable — on_init validates the two we set.
        cfg.n_layers = static_cast<uint8_t>(config.value("n_layers", static_cast<unsigned>(cfg.n_layers)));
        if (config.contains("layers") && config["layers"].is_array()) {
            const auto& arr = config["layers"];
            const size_t nl = arr.size() < 2 ? arr.size() : 2;
            for (size_t i = 0; i < nl; ++i) {
                const auto& lj = arr[i];
                if (!lj.is_object()) continue;
                MESHROUTE_NS::LayerConfig& L = cfg.layers[i];
                L.layer_id         = static_cast<uint8_t>(lj.value("layer_id", 0));
                L.node_id          = static_cast<uint8_t>(lj.value("node_id", 0));
                L.routing_sf       = static_cast<uint8_t>(lj.value("routing_sf", 0));
                L.beacon_period_ms = lj.value("beacon_period_ms", L.beacon_period_ms);
                L.window_period_ms = lj.value("window_period_ms", L.window_period_ms);
                L.window_ms        = lj.value("window_ms",        L.window_ms);          // 0 = DERIVE SF-weighted (on_init §4)
                L.window_offset_ms = lj.value("window_offset_ms", L.window_offset_ms);   // 0 = DERIVE anti-phase
                L.bw_hz            = static_cast<uint32_t>(lj.value("bw_hz", 0u));       // §metal-fidelity: per-layer BW override (0 = inherit global) -> active_bw_hz() differs per layer -> set_rx_bw drives the slop
                L.cr               = static_cast<uint8_t>(lj.value("cr", 0u));           //   per-layer CR override (0 = inherit)
                L.freq_mhz         = lj.value("freq_mhz", L.freq_mhz);                   // §1.2: per-layer RF carrier (0 = inherit); previously unmapped

                if (lj.contains("allowed_data_sfs") && lj["allowed_data_sfs"].is_array()) {
                    uint16_t bm = 0;
                    for (const auto& v : lj["allowed_data_sfs"]) {
                        const int s = v.get<int>();
                        if (s >= 5 && s <= 12) bm |= static_cast<uint16_t>(1u << s);
                    }
                    L.allowed_sf_bitmap = bm;
                }
            }
        }
    }
    // Structural fail-loud (§3.2): a `layers` array is meaningful ONLY for a dual-layer gateway (n_layers==2).
    // Reject a contradictory shape rather than silently mis-parsing — a single-layer node's layers[0] is
    // overwritten by the scalar-mirror in on_init, and a gateway needs EXACTLY two layer objects. (n_layers
    // itself is already bounded to {1,2} at the FirmwareNode sim boundary before this runs.)
    {
        const bool has_layers = config.is_object() && config.contains("layers") && config["layers"].is_array();
        const size_t n_layer_objs = has_layers ? config["layers"].size() : 0;
        if (cfg.n_layers == 2) {
            if (n_layer_objs != 2) return false;     // gateway: exactly two layer objects required
        } else if (has_layers) {
            return false;                            // single-layer must NOT carry a layers[] (it would be ignored)
        }
    }
    // §enc (2026-07-12): install a real E2E crypto identity from a per-node 32-byte "seed" (64 hex chars).
    // identity_from_seed derives ed_pub/x_secret; set_crypto_identity installs them (unset -> _crypto_ready=false ->
    // seals FAIL LOUD, never cleartext). The scenario's key_hash32 MUST equal LE(ed_pub[0..3]) of this seed (peer-key
    // caching self-consistency) -> derive it offline. Absent -> no identity -> plaintext-only (s18 has no seed -> unchanged).
    if (config.is_object() && config.contains("seed")) {
        const std::string sh = config.value("seed", std::string());
        if (sh.size() >= 64) {
            uint8_t seed[32] = {};
            for (int i = 0; i < 32; ++i)
                seed[i] = static_cast<uint8_t>(std::stoul(sh.substr(static_cast<size_t>(i) * 2, 2), nullptr, 16));
            MESHROUTE_NS::Identity id{};
            MESHROUTE_NS::identity_from_seed(id, seed);
            _node.set_crypto_identity(id.x_secret, id.ed_pub);
        }
    }
    return _node.on_init(cfg);
}

// ---- onCommand: the sim command-string transport -> typed NS::Command ------
// Verbatim port of the legacy FirmwareNode::onCommand parse (the `_initialized`/`_node`
// guard stays in FirmwareNode; this is only reached once initialized).
std::string NodeRuntime::onCommand(std::string_view cmd_str) {
    std::string cmd(cmd_str);
    // The sim TRANSPORT parses its command string into a TYPED MESHROUTE_NS::Command
    // (a device backend parses its binary frames into the SAME Command). lib/core
    // never sees a command string. SimController has already resolved name -> id.
    // node_id auto-assignment (DAD): `join` kicks off the claim state machine (the node must be
    // unprovisioned — node_id 0 — for this to pick an id).
    if (cmd == "join") {
        MESHROUTE_NS::Command c{}; c.kind = MESHROUTE_NS::CmdKind::join;
        const MESHROUTE_NS::CmdResult r = _node.on_command(c);
        const char* code = (r.code == MESHROUTE_NS::CmdCode::queued) ? "queued" : "error";
        return std::string("OK ") + code;
    }
    // ROADMAP §3 channel gossip: send_channel[_g|_b] <channel_id 0-255> <text>. The first arg is a numeric
    // channel id (not a node name), so SimController's name->id resolution leaves it untouched.
    // §S7 T-B plane select (the sim verb-split — mirrors the send/send_layerx precedent; the firmware CONSOLE uses
    //   -t/-g flags, plain=>GLOBAL per §S7. The SIM keeps its plain verb at the node's NATURAL plane so the QA-owned
    //   team-channel scenarios [s22/s28 plain send_channel] stay green without editing their commands):
    //     send_channel   <ch> <text> => NATURAL: a team member posts TEAM (-t), a static/leaf node posts its leaf.
    //     send_channel_g <ch> <text> => GLOBAL (a registered mobile delegates to its home; off-grid fails loud).
    //     send_channel_b <ch> <text> => BOTH (team origination + delegated global).
    {
        const bool ch_b = (cmd.rfind("send_channel_b ", 0) == 0);
        const bool ch_g = (cmd.rfind("send_channel_g ", 0) == 0);
        const bool ch_p = (cmd.rfind("send_channel ", 0) == 0);
        const size_t cpfx = (ch_b || ch_g) ? 15 : (ch_p ? 13 : 0);
        if (cpfx) {
            size_t s = cpfx; while (s < cmd.size() && cmd[s] == ' ') ++s;
            unsigned ch = 0; size_t e = s; bool got = false;
            while (e < cmd.size() && cmd[e] >= '0' && cmd[e] <= '9') { ch = ch * 10 + (cmd[e] - '0'); ++e; got = true; }
            if (got && ch <= 255 && e < cmd.size() && cmd[e] == ' ') {
                const std::string body = cmd.substr(e + 1);
                MESHROUTE_NS::Command c{};
                c.kind = MESHROUTE_NS::CmdKind::send_channel;
                c.u.channel.channel_id = static_cast<uint8_t>(ch);
                const bool team_member = _node.config().is_mobile && _node.config().team_id != 0;
                if (ch_b)      { c.u.channel.team = true;  c.u.channel.global = true;  }   // BOTH
                else if (ch_g) { c.u.channel.team = false; c.u.channel.global = true;  }   // GLOBAL
                else           { c.u.channel.team = team_member; c.u.channel.global = false; }   // NATURAL (plain): TEAM for a team member, leaf for a static
                const size_t cap = MESHROUTE_NS::protocol::channel_msg_max_payload_bytes;   // derived from the protocol constant (was a 200 literal)
                c.body = reinterpret_cast<const uint8_t*>(body.data());   // borrowed during the call
                c.body_len = static_cast<uint8_t>(body.size() > cap ? cap : body.size());
                const MESHROUTE_NS::CmdResult r = _node.on_command(c);
                const char* code = (r.code == MESHROUTE_NS::CmdCode::queued) ? "queued" : "error";
                return std::string("OK ") + code + " ctr=" + std::to_string(r.ctr) +
                       " depth=" + std::to_string(r.queue_depth);
            }
            return "ERROR: usage: send_channel[_g|_b] <channel_id 0-255> <text>";
        }
    }
    // Hash-locate (H plane): send_hash <key_hash32 hex> <text>. Address by the target's stable
    // key_hash32 instead of its short id — lib/core resolves it (id_bind cache or an H flood) before
    // sending. The first arg is hex (not a node name) so SimController's name->id pass leaves it alone.
    if (cmd.rfind("send_hash ", 0) == 0) {
        size_t s = 10; while (s < cmd.size() && cmd[s] == ' ') ++s;
        if (s + 1 < cmd.size() && cmd[s] == '0' && (cmd[s + 1] == 'x' || cmd[s + 1] == 'X')) s += 2;  // optional 0x
        uint32_t h = 0; size_t e = s; int ndig = 0; bool got = false;
        while (e < cmd.size()) {
            const char ch = cmd[e];
            int v;
            if (ch >= '0' && ch <= '9')      v = ch - '0';
            else if (ch >= 'a' && ch <= 'f') v = ch - 'a' + 10;
            else if (ch >= 'A' && ch <= 'F') v = ch - 'A' + 10;
            else break;
            h = (h << 4) | static_cast<uint32_t>(v); ++e; ++ndig; got = true;
        }
        // Reject >8 hex digits: a key_hash32 is 32 bits, and silently truncating the high nibbles
        // would mis-address the DM to a DIFFERENT (but valid) hash with a success-looking reply.
        if (got && ndig <= 8 && h != 0 && e < cmd.size() && cmd[e] == ' ') {
            std::string body = cmd.substr(e + 1);
            MESHROUTE_NS::Command c{};
            c.kind = MESHROUTE_NS::CmdKind::send;
            c.u.send.dst_hash = h;                 // the address-by-hash path (dst_id ignored when dst_hash != 0)
            c.u.send.flags    = 0;
            // §F-TR-1: an optional TRAILING " -t" selects the TEAM plane (mirrors the firmware console's `send ... -t`
            // => Plane::TEAM). The body is greedy (rest of line) so the flag rides as a SUFFIX token, keeping the message
            // text intact; strip it before the send. Absent -> plane stays 0 (AUTO) -> byte-identical to the plain verb.
            if (body.size() >= 3 && body.compare(body.size() - 3, 3, " -t") == 0) {
                c.u.send.plane = static_cast<uint8_t>(MESHROUTE_NS::Plane::TEAM);
                body.erase(body.size() - 3);
            }
            const size_t cap = MESHROUTE_NS::protocol::max_payload_bytes_hard_cap;   // the SAME cap the firmware console applies (console_parse.cpp) — was a stale 233 literal
            c.body = reinterpret_cast<const uint8_t*>(body.data());   // borrowed during the call
            c.body_len = static_cast<uint8_t>(body.size() > cap ? cap : body.size());
            const MESHROUTE_NS::CmdResult r = _node.on_command(c);
            const char* code = (r.code == MESHROUTE_NS::CmdCode::queued) ? "queued" : "error";
            return std::string("OK ") + code + " ctr=" + std::to_string(r.ctr) +
                   " depth=" + std::to_string(r.queue_depth);
        }
        return "ERROR: usage: send_hash <key_hash32 hex> [-t] <text>";
    }
    // §enc: send_hashx <key_hash32 hex> <text> = a CRYPTED (sealed) DM by hash (Command.crypt = CryptIntent::on).
    // Requires the recipient's pubkey already cached (reqpubkey first) + our own crypto identity (seed) — else FAIL
    // LOUD (e2e_no_pubkey, NEVER cleartext). For a team member the pubkey arrives via the team-scoped WANT_PUBKEY.
    if (cmd.rfind("send_hashx ", 0) == 0) {
        size_t s = 11; while (s < cmd.size() && cmd[s] == ' ') ++s;
        if (s + 1 < cmd.size() && cmd[s] == '0' && (cmd[s + 1] == 'x' || cmd[s + 1] == 'X')) s += 2;  // optional 0x
        uint32_t h = 0; size_t e = s; int ndig = 0; bool got = false;
        while (e < cmd.size()) {
            const char ch = cmd[e]; int v;
            if (ch >= '0' && ch <= '9')      v = ch - '0';
            else if (ch >= 'a' && ch <= 'f') v = ch - 'a' + 10;
            else if (ch >= 'A' && ch <= 'F') v = ch - 'A' + 10;
            else break;
            h = (h << 4) | static_cast<uint32_t>(v); ++e; ++ndig; got = true;
        }
        if (got && ndig <= 8 && h != 0 && e < cmd.size() && cmd[e] == ' ') {
            const std::string body = cmd.substr(e + 1);
            MESHROUTE_NS::Command c{};
            c.kind = MESHROUTE_NS::CmdKind::send;
            c.u.send.dst_hash = h;
            c.u.send.flags    = 0;
            c.crypt           = MESHROUTE_NS::CryptIntent::on;   // §enc: force CRYPTED (seal) for this DM
            const size_t cap = MESHROUTE_NS::protocol::max_payload_bytes_hard_cap;   // the SAME cap the firmware console applies (console_parse.cpp) — was a stale 233 literal
            c.body = reinterpret_cast<const uint8_t*>(body.data());
            c.body_len = static_cast<uint8_t>(body.size() > cap ? cap : body.size());
            const MESHROUTE_NS::CmdResult r = _node.on_command(c);
            const char* code = (r.code == MESHROUTE_NS::CmdCode::queued) ? "queued" : "error";
            return std::string("OK ") + code + " ctr=" + std::to_string(r.ctr) + " depth=" + std::to_string(r.queue_depth);
        }
        return "ERROR: usage: send_hashx <key_hash32 hex> <text>";
    }
    // §enc: reqpubkey <key_hash32 hex> = fetch the owner's E2E pubkey on-air (a HARD WANT_PUBKEY H). For a team member
    // the query is team-scoped (H_FLAG_TEAM) so a same-team owner answers directly -> peer_key_cached. Precedes send_hashx.
    if (cmd.rfind("reqpubkey ", 0) == 0) {
        size_t s = 10; while (s < cmd.size() && cmd[s] == ' ') ++s;
        if (s + 1 < cmd.size() && cmd[s] == '0' && (cmd[s + 1] == 'x' || cmd[s + 1] == 'X')) s += 2;  // optional 0x
        uint32_t h = 0; size_t e = s; int ndig = 0; bool got = false;
        while (e < cmd.size()) {
            const char ch = cmd[e]; int v;
            if (ch >= '0' && ch <= '9')      v = ch - '0';
            else if (ch >= 'a' && ch <= 'f') v = ch - 'a' + 10;
            else if (ch >= 'A' && ch <= 'F') v = ch - 'A' + 10;
            else break;
            h = (h << 4) | static_cast<uint32_t>(v); ++e; ++ndig; got = true;
        }
        if (got && ndig <= 8 && h != 0) {
            MESHROUTE_NS::Command c{};
            c.kind = MESHROUTE_NS::CmdKind::reqpubkey;
            c.u.resolve.dst_hash = h; c.u.resolve.dst_id = 0; c.u.resolve.hard = true;
            const MESHROUTE_NS::CmdResult r = _node.on_command(c);
            const char* code = (r.code == MESHROUTE_NS::CmdCode::queued) ? "queued" : "error";
            return std::string("OK reqpubkey ") + code;
        }
        return "ERROR: usage: reqpubkey <key_hash32 hex>";
    }
    // §metal-fidelity (2026-07-07): the cross-layer `send_layer` transport (was the deferred Slice-5-step-6 stub).
    // Syntax `send_layer <target_layer_id> <dst_hash> <text>` (mirrors the s09/s15 scenario commands); the E2E variant
    // `send_layer_e2e …` sets DATA_FLAG_E2E_ACK_REQ so the recipient acks over the reversed 4e path (round-trip test).
    {
        // §S4: send_layerx = a CRYPTED (sealed) cross-layer DM (Command.crypt = CryptIntent::on), mirroring send_hashx.
        // It rides DATA_TYPE_SEALED_RELAY (the body is sealed to dst_hash HERE, before the frame ctr exists). The plain
        // send_layer/_e2e stay plaintext. send_layerx_e2e = sealed + request the reversed-path E2E ack (round-trip test).
        const bool xl_x_e2e = (cmd.rfind("send_layerx_e2e ", 0) == 0);
        const bool xl_x     = xl_x_e2e || (cmd.rfind("send_layerx ", 0) == 0);
        const bool xl_e2e   = (cmd.rfind("send_layer_e2e ", 0) == 0);
        const size_t xpfx   = xl_x_e2e ? 16 : ((cmd.rfind("send_layerx ", 0) == 0) ? 12
                            : (xl_e2e ? 15 : (cmd.rfind("send_layer ", 0) == 0 ? 11 : 0)));
        const bool xl_ack   = xl_e2e || xl_x_e2e;
        if (xpfx) {
            size_t p = xpfx; while (p < cmd.size() && cmd[p] == ' ') ++p;
            unsigned layer = 0; bool gl = false;                                    // target destination layer id
            while (p < cmd.size() && cmd[p] >= '0' && cmd[p] <= '9') { layer = layer * 10 + (cmd[p] - '0'); ++p; gl = true; }
            while (p < cmd.size() && cmd[p] == ' ') ++p;
            uint32_t hash = 0; bool gh = false;                                     // dst key_hash32: 0x-hex or decimal
            if (p + 1 < cmd.size() && cmd[p] == '0' && (cmd[p + 1] == 'x' || cmd[p + 1] == 'X')) {
                p += 2;
                int ndig = 0;
                for (; p < cmd.size(); ++p) {
                    const char ch = cmd[p]; uint32_t d;
                    if      (ch >= '0' && ch <= '9') d = static_cast<uint32_t>(ch - '0');
                    else if (ch >= 'a' && ch <= 'f') d = static_cast<uint32_t>(ch - 'a' + 10);
                    else if (ch >= 'A' && ch <= 'F') d = static_cast<uint32_t>(ch - 'A' + 10);
                    else break;
                    hash = hash * 16u + d; ++ndig; gh = true;
                }
                // Reject >8 hex digits: a key_hash32 is 32 bits, and silently truncating the high nibbles
                // would mis-address the DM to a DIFFERENT (but valid) hash with a success-looking reply.
                if (ndig > 8) gh = false;
            } else {
                while (p < cmd.size() && cmd[p] >= '0' && cmd[p] <= '9') { hash = hash * 10u + static_cast<uint32_t>(cmd[p] - '0'); ++p; gh = true; }
            }
            if (gl && gh && layer >= 1 && layer <= 255 && p < cmd.size() && cmd[p] == ' ') {
                const std::string body = cmd.substr(p + 1);
                MESHROUTE_NS::Command c{};
                c.kind = MESHROUTE_NS::CmdKind::send_layer;
                c.u.layer.hop_count = 1;
                c.u.layer.hops[0]   = static_cast<uint8_t>(layer);   // the DESTINATION layer (originate_layer_path prepends our own)
                c.u.layer.dst_hash  = hash;
                c.u.layer.flags     = static_cast<uint8_t>(xl_ack ? MESHROUTE_NS::DATA_FLAG_E2E_ACK_REQ : 0);
                c.crypt             = xl_x ? MESHROUTE_NS::CryptIntent::on : MESHROUTE_NS::CryptIntent::def;   // §S4: send_layerx seals
                const size_t cap = MESHROUTE_NS::protocol::max_payload_bytes_hard_cap;   // the SAME cap the firmware console applies (console_parse.cpp) — was a stale 233 literal
                c.body = reinterpret_cast<const uint8_t*>(body.data());   // borrowed during the call
                c.body_len = static_cast<uint8_t>(body.size() > cap ? cap : body.size());
                const MESHROUTE_NS::CmdResult r = _node.on_command(c);
                const char* code = (r.code == MESHROUTE_NS::CmdCode::queued) ? "queued" : "error";
                return std::string("OK ") + code + " ctr=" + std::to_string(r.ctr) +
                       " depth=" + std::to_string(r.queue_depth);
            }
            return "ERROR: usage: send_layer[x][_e2e] <target_layer_id> <dst_hash 0xHEX|decimal> <text>";
        }
    }
    const bool is_e2e = (cmd.rfind("send_e2e ", 0) == 0);
    const size_t pfx  = is_e2e ? 9 : (cmd.rfind("send ", 0) == 0 ? 5 : 0);
    if (pfx) {
        size_t s = pfx; while (s < cmd.size() && cmd[s] == ' ') ++s;
        unsigned dst = 0; size_t e = s; bool got = false;
        while (e < cmd.size() && cmd[e] >= '0' && cmd[e] <= '9') { dst = dst * 10 + (cmd[e] - '0'); ++e; got = true; }
        if (got && dst <= 254 && e < cmd.size() && cmd[e] == ' ') {
            const std::string body = cmd.substr(e + 1);
            MESHROUTE_NS::Command c{};
            c.kind = MESHROUTE_NS::CmdKind::send;
            c.u.send.dst_id = static_cast<uint8_t>(dst);
            c.u.send.flags  = static_cast<uint8_t>(is_e2e ? MESHROUTE_NS::DATA_FLAG_E2E_ACK_REQ : 0);  // the wire bit the RX acts on (was 0x08, a dead bit -> sim send_e2e ack never fired)
            const size_t cap = MESHROUTE_NS::protocol::max_payload_bytes_hard_cap;   // the SAME cap the firmware console applies (console_parse.cpp) — was a stale 233 literal
            c.body = reinterpret_cast<const uint8_t*>(body.data());   // borrowed during the call
            c.body_len = static_cast<uint8_t>(body.size() > cap ? cap : body.size());
            const MESHROUTE_NS::CmdResult r = _node.on_command(c);
            const char* code = (r.code == MESHROUTE_NS::CmdCode::queued) ? "queued" : "error";
            return std::string("OK ") + code + " ctr=" + std::to_string(r.ctr) +
                   " depth=" + std::to_string(r.queue_depth);
        }
    }
    return "ERROR: unparsed command";
}

// ---- drainPushes: NS::Push ring -> NDJSON payload -> sink ------------------
// Byte-identical to the legacy FirmwareNode::drainPushes JSON (insertion order kind,ctr,dst[,origin,payload]);
// FirmwareNode wraps the payload as a "push" script_emit. §metal-fidelity (2026-07-07): an E2E-ACK receipt
// (PushKind::send_e2e_acked) is now mapped to its own "send_e2e_acked" kind — it is a SUCCESS, not a send_failed.
// (It was previously folded into the send_failed default to keep s18 byte-stable; CORRECTNESS wins over byte-identity.)
void NodeRuntime::drainPushes(const PushSink& sink) {
    MESHROUTE_NS::Push p;
    while (_node.next_push(p)) {
        const char* kind = (p.kind == MESHROUTE_NS::PushKind::msg_recv)       ? "msg_recv"
                         : (p.kind == MESHROUTE_NS::PushKind::send_acked)     ? "send_acked"
                         : (p.kind == MESHROUTE_NS::PushKind::send_e2e_acked) ? "send_e2e_acked"
                                                                              : "send_failed";
        nlohmann::json j;
        j["kind"] = kind;
        j["ctr"]  = p.ctr;
        j["dst"]  = p.dst;
        if (p.kind == MESHROUTE_NS::PushKind::msg_recv) {
            j["origin"]  = p.origin;
            j["payload"] = std::string(reinterpret_cast<const char*>(p.body), p.body_len);
        }
        sink(j.dump());
    }
}

}  // namespace

// ---- the per-variant factory (exactly one symbol per lib; keyed on MR_GATEWAY_BUILD) ----
#ifdef MR_GATEWAY_BUILD
mrsim::INodeRuntime* mrsim::makeNodeRuntimeGw(int id, const char* name, uint32_t key_hash32, mrsim::ISimHal& hal) {
    return new NodeRuntime(id, name, key_hash32, hal);
}
#else
mrsim::INodeRuntime* mrsim::makeNodeRuntimeNormal(int id, const char* name, uint32_t key_hash32, mrsim::ISimHal& hal) {
    return new NodeRuntime(id, name, key_hash32, hal);
}
#endif
