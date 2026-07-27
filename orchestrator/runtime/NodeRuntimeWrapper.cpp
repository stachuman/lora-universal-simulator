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
#include "orchestrator/runtime/ConsoleNames.h"   // §w4-#6: mrsim::pushKindName — lib/console's table, reached namespace-neutrally

#include "hal.h"         // MESHROUTE_NS::Hal / TxParams / EventField / TxResult / BusyInfo / RxMeta
#include "node.h"        // MESHROUTE_NS::Node / NodeConfig / LayerConfig
#include "command.h"     // MESHROUTE_NS::Command / CmdKind / CmdResult / CmdCode / Push / PushKind
#include "frame_codec.h" // MESHROUTE_NS::DATA_FLAG_E2E_ACK_REQ (the wrapper is C++20 -> the canonical flag, not a literal)
#include "identity.h"    // §enc: MESHROUTE_NS::Identity / identity_from_seed — install a real E2E crypto identity from a per-node seed

#include "json/json.hpp"

#include <cstdint>
#include <cstdio>      // §sim-team-verb: std::snprintf — the `team` reply's %08lX team_id (the firmware prints it the same way)
#include <random>      // std::mt19937 — the per-node crypto-bytes stream (rand_bytes), separate from rand_range
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
    // §carrier (2026-07-26): the per-layer RF-carrier retune, and ★ THE ONE MHz->kHz CONVERSION IN THE
    // SIM. It uses the FIRMWARE's own protocol::mhz_to_khz — the same helper node_mac_rx.cpp:768 uses to
    // stamp LayerRecord::freq_khz on the wire — so the sim's stored carrier and the firmware's advertised
    // one are canonicalized identically BY CONSTRUCTION and cannot drift (U2: one conversion path).
    // This TU is the right (and only) home for it: it is the per-variant bridge that already names
    // MESHROUTE_NS, so ISimHal, FirmwareNode, SimController and JsonConfig all stay both
    // namespace-neutral and MHz-free — they see only integer kHz.
    // The `mhz > 0` guard MIRRORS DeviceHal::set_rx_freq verbatim ("0/neg = inherit (core already skips;
    // guard the HAL too)") — this adapter IS the sim's HAL.
    void     set_rx_freq(double mhz) override {
        if (mhz > 0.0) _sim.simSetRxFreqKhz(MESHROUTE_NS::protocol::mhz_to_khz(mhz));
    }
    // §cr-retune (2026-07-26): the last unplumbed per-layer PHY axis. Before this, Hal::set_rx_cr's empty
    // no-op default was inherited, so `_radios[i]->getCR()` never moved and a gateway with per-layer CR
    // flew both layers at ONE cr in the sim while genuinely retuning on metal.
    void     set_rx_cr(uint8_t cr) override                { _sim.simSetRxCr(cr); }
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

// ===========================================================================
// The node.config key table (3-B item 7) — ONE source of truth for BOTH the
// §1.2 unknown-key whitelist AND the config -> NodeConfig mapping walk.
//
// Those used to be two hand-maintained lists that had to agree, and drift
// between them is SILENT in both directions: a key whitelisted but never mapped
// is accepted and quietly ignored (the proven-live `join_required` bug §1.2
// fixed), while a key mapped but not whitelisted makes the whole config FAIL
// LOUD on a knob the wrapper actually honours. That is the same defect class as
// the 2026-07-25 enum->string holes (three shipped bugs from one stale table);
// here it is now structurally impossible — the whitelist IS this table's key
// set, and the mapping walk IS this table's appliers.
//
// Each row states a DISPOSITION, so "accepted but deliberately unmapped" can
// never quietly become "mapped", nor the reverse:
//   Disp::map       — an applier writes NodeConfig. Invariant: apply != nullptr.
//   Disp::elsewhere — accepted, and genuinely CONSUMED, but not by this walk
//                     (named per row: another row's applier reads it as a
//                     fallback, onInit's post-walk crypto-identity step,
//                     FirmwareNode, or the deprecated Lua engine).
//   Disp::ignored   — accepted and read by NOTHING: legacy sim-only keys with
//                     no NodeConfig field, kept accepted so shipped corpus
//                     scenarios still validate, while a typo in any mapped key
//                     still fails loud.
// `elsewhere` is deliberately NOT folded into `ignored`: calling `_sim_bw_hz`
// "ignored" would be false, and a future reader would be entitled to delete it.
//
// ★ THE ROW ORDER IS THE PRE-SLICE SOURCE ORDER AND IS SIGNIFICANT: `layer_id`
//   OVERWRITES what the `leaf_id` row wrote, so it must follow it. Do not walk
//   the JSON object's own keys instead — nlohmann orders them alphabetically,
//   which puts "layer_id" BEFORE "leaf_id" and inverts the override.
// ===========================================================================
enum class Disp : uint8_t { map, elsewhere, ignored };

using NodeCfg = MESHROUTE_NS::NodeConfig;
using Applier = void (*)(NodeCfg& cfg, const nlohmann::json& j, const char* key);

// The plain case, once: `cfg.<member> = config.value(<key>, cfg.<member>)`.
// An absent key leaves the struct default untouched — exactly what each of the
// 51 hand-written lines did.
template <auto Member>
void map_plain(NodeCfg& cfg, const nlohmann::json& j, const char* key) {
    (cfg.*Member) = j.value(key, cfg.*Member);
}

// allowed_data_sfs: [7,9] -> an allowed_sf_bitmap (bit = sf), matching the Lua config key. The DATA-SF
// selector picks the fastest SF in this set the link SNR supports; absent/empty -> NO data SF (the node
// refuses to originate data — the single-SF data_sf fallback was removed, sf_list is now mandatory).
// Shared by the top-level cfg and every layers[] entry: those two loops were byte-for-byte twins, so the
// 5..12 bound now exists once instead of drifting on one side.
void allowed_sf_bitmap_from(const nlohmann::json& obj, const char* key, uint16_t& out) {
    if (!obj.contains(key) || !obj[key].is_array()) return;
    uint16_t bm = 0;
    for (const auto& v : obj[key]) {
        const int s = v.get<int>();
        if (s >= 5 && s <= 12) bm |= static_cast<uint16_t>(1u << s);
    }
    out = bm;
}

// ---- the bespoke appliers (everything map_plain cannot express) ------------

// §W2c WHITE-BOX TEST HOOK (0=OFF): pin the FIRST team-DAD id so a hidden-terminal collision is
// deterministic (only s30 sets it; a re-pick ignores the pin -> convergence intact). Read as `unsigned`
// and narrowed, verbatim as before — not map_plain, which would deduce uint8_t.
void map_team_dad_pin_id(NodeCfg& c, const nlohmann::json& j, const char* k) {
    c.team_dad_pin_id = static_cast<uint8_t>(j.value(k, static_cast<unsigned>(c.team_dad_pin_id)));
}

// leaf_id = the low 4 bits of the node's layer_id (frames.md: leaf_id IS the layer id, 0..15). The
// multi-layer scenarios configure each node's layer via `layer_id` (1/2/3 here), so DERIVE the firmware
// leaf from it — else every node defaults to leaf_id=0 and the byte-0 leaf gate (e.g. the channel-M
// cross-leaf leak gate) is inert. An explicit `leaf_id` still overrides (single-layer / direct tests),
// which is why this row MUST stay after the `leaf_id` row.
void map_layer_id(NodeCfg& c, const nlohmann::json& j, const char* k) {
    if (j.contains(k)) c.leaf_id = static_cast<uint8_t>(j.value(k, 0) & 0x0F);
}

void map_allowed_data_sfs(NodeCfg& c, const nlohmann::json& j, const char* k) {
    allowed_sf_bitmap_from(j, k, c.allowed_sf_bitmap);
}

// R4.0 duty-cycle budget. Mirror the Lua precedence EXACTLY (dv_dual_sf.lua:8495-8496):
//   self.duty_cycle = config.duty_cycle or config._sim_duty_cycle or 0.01
// The NodeConfig field is a FRACTION (0.01 = 1%). SimController injects _sim_duty_cycle already
// divided /100 from the PERCENT global simulation.radio.duty_cycle (§2.2 realism ruling — the
// authoring unit moved to percent; this boundary value stays the fraction both engines expect),
// so a scenario that sets only the GLOBAL radio.duty_cycle leaves nodes ENABLED at the same
// budget on both engines (lua-vs-meshroute review #00). A per-node `duty_cycle` override is a raw
// FRACTION passthrough (unscaled — the MeshRoute corpus uses none). ⚠ Both fall back to a LITERAL,
// not to the struct default, so these two cannot be map_plain.
void map_duty_cycle(NodeCfg& c, const nlohmann::json& j, const char* k) {
    c.duty_cycle = j.value(k, j.value("_sim_duty_cycle", 0.01));
}
void map_duty_cycle_window_ms(NodeCfg& c, const nlohmann::json& j, const char* k) {
    c.duty_cycle_window_ms = j.value(k, j.value("_sim_duty_cycle_window_ms", 3600000u));
}

// Radio bw/cr seam (cleanup #C, [[project_firmwarenode_sim_config_seam]]): mirror the Lua precedence
// (dv_dual_sf.lua:8490-8491) `config.bw_hz or config._sim_bw_hz or 250000` / `config.cr or config._sim_cr
// or 5`. SimController injects _sim_bw_hz (= node.bw*1000) + _sim_cr; without this the firmware uses the
// struct-default 250000/5 and a NON-default-bw scenario diverges on every airtime calc (_flood_lbt_max_defer,
// rts/ack-timeout, the #2 duty pre-check). Gate-inert (the gates run bw=250kHz/cr=5 = the defaults).
// preamble_sym is NOT sim-injected -> a fixed protocol constant on both engines, no plumb needed.
// ⚠ The JSON key and the NodeConfig field NAMES differ (bw_hz -> radio_bw_hz), a second reason these are bespoke.
void map_bw_hz(NodeCfg& c, const nlohmann::json& j, const char* k) {
    c.radio_bw_hz = j.value(k, j.value("_sim_bw_hz", c.radio_bw_hz));
}
void map_cr(NodeCfg& c, const nlohmann::json& j, const char* k) {
    c.radio_cr = j.value(k, j.value("_sim_cr", c.radio_cr));
}

// §layer-freq (2026-07-27): the node's GLOBAL RF carrier -> NodeConfig::radio_freq_mhz, the fallback
// Node::active_freq_mhz() uses to RESET the radio when a gateway enters a layer that INHERITS (freq_mhz==0)
// after one that OVERRIDES. Without this the firmware fix is unmodellable here (radio_freq_mhz would stay
// 0.0 = "no global carrier", and the reset would be a Hal no-op exactly as before).
// ★ DELIBERATELY NOT the bw_hz/cr shape (an author key with an _sim_* fallback): there is NO author-facing
// `config.freq_mhz`, because the sim ALREADY has an authoring key for a node's carrier — the node-level
// INTEGER `freq_khz` that JsonConfig parses (and SimController injects here, post-inherit). A second one
// would re-open exactly the MHz/kHz double-conversion drift 26u refused (U2). The injection is the only
// source, hence Disp::map on the `_sim_*` key itself rather than Disp::elsewhere.
// The kHz->MHz conversion is exact for every integer kHz: k/1000.0 is within ~1e-13 relative of k/1000, so
// the firmware's own protocol::mhz_to_khz (round-half-up) at the HalAdapter seam maps it back to k — the
// round trip cannot detune a node by a kHz. Same value SimController seeds _node_rx_freq_khz[i] with, so the
// firmware's inherit fallback and the sim's live tuned carrier agree by construction.
void map_sim_freq_khz(NodeCfg& c, const nlohmann::json& j, const char* k) {
    const int khz = j.value(k, 0);
    if (khz > 0) c.radio_freq_mhz = static_cast<double>(khz) / 1000.0;
}

// leaf_name: string -> char[]+len (in the config_hash; a change re-fingerprints the leaf).
void map_leaf_name(NodeCfg& c, const nlohmann::json& j, const char* k) {
    if (j.contains(k) && j[k].is_string()) {
        const std::string ln = j.value(k, std::string());
        const size_t m = ln.size() < MESHROUTE_NS::protocol::leaf_name_max
                             ? ln.size() : MESHROUTE_NS::protocol::leaf_name_max;
        for (size_t i = 0; i < m; ++i) c.leaf_name[i] = ln[i];
        c.leaf_name_len = static_cast<uint8_t>(m);
    }
}

// ---- dual-layer gateway (Slice 5 sim): n_layers + a layers[] array map 1:1 to cfg.n_layers /
//      cfg.layers[0..1] (LayerConfig). A gateway scenario node sets n_layers=2 + two layer objects;
//      on_init validates + REFUSES a bad config (§3.2, fail-loud). Single-layer nodes omit both
//      (n_layers defaults to 1; on_init mirrors the legacy scalars into layers[0]). cfg.layers[] is
//      sized 2, so any entries past the first two are unrepresentable — on_init validates the two we set.
//      The nested sub-objects are NOT whitelist-validated (their parse stays permissive — s27's layers
//      carry scheduler sub-keys the parse ignores).
void map_n_layers(NodeCfg& c, const nlohmann::json& j, const char* k) {
    c.n_layers = static_cast<uint8_t>(j.value(k, static_cast<unsigned>(c.n_layers)));
}
void map_layers(NodeCfg& c, const nlohmann::json& j, const char* k) {
    if (!j.contains(k) || !j[k].is_array()) return;
    const auto& arr = j[k];
    const size_t nl = arr.size() < 2 ? arr.size() : 2;
    for (size_t i = 0; i < nl; ++i) {
        const auto& lj = arr[i];
        if (!lj.is_object()) continue;
        MESHROUTE_NS::LayerConfig& L = c.layers[i];
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

        allowed_sf_bitmap_from(lj, "allowed_data_sfs", L.allowed_sf_bitmap);
    }
}

struct KeyRow {
    const char* name;
    Disp        disp;
    Applier     apply;   // non-null iff disp == Disp::map (static_assert'd below)
};

constexpr KeyRow kConfigKeys[] = {
    // ---- mapped, in the original source order (see the ★ order note above) ----
    { "routing_sf",                       Disp::map, map_plain<&NodeCfg::routing_sf> },
    { "beacon_period_ms",                 Disp::map, map_plain<&NodeCfg::beacon_period_ms> },
    { "team_beacon_period_ms",            Disp::map, map_plain<&NodeCfg::team_beacon_period_ms> },   // §team-multihop Change A: a team member's steady cadence (default 5 min; sims set a faster value)
    { "beacon_max_idle_ms",               Disp::map, map_plain<&NodeCfg::beacon_max_idle_ms> },
    { "quiet_threshold_ms",               Disp::map, map_plain<&NodeCfg::quiet_threshold_ms> },
    { "beacon_silence_jitter_ms",         Disp::map, map_plain<&NodeCfg::beacon_silence_jitter_ms> },  // R4.3
    { "seen_bitmap_enabled",              Disp::map, map_plain<&NodeCfg::seen_bitmap_enabled> },
    { "is_gateway",                       Disp::map, map_plain<&NodeCfg::is_gateway> },
    { "gateway_only",                     Disp::map, map_plain<&NodeCfg::gateway_only> },   // §7 pure-bridge switch
    { "is_mobile",                        Disp::map, map_plain<&NodeCfg::is_mobile> },
    { "team_id",                          Disp::map, map_plain<&NodeCfg::team_id> },        // §mobile 6.1: team overlay (0 = no team). A team member (is_mobile + team_id) team-DADs a _team_local_id + runs the team plane. Absent -> 0 -> static/lone unchanged (s18 byte-identical).
    { "mobile_autoregister",              Disp::map, map_plain<&NodeCfg::mobile_autoregister> },  // §mobile: also seek a static home; a pure off-grid team leaves it default and just team-DADs.
    { "team_dad_pin_id",                  Disp::map, map_team_dad_pin_id },
    { "e2e_dm",                           Disp::map, map_plain<&NodeCfg::e2e_dm> },         // §enc: default-crypt app DMs (CryptIntent::def follows this); send_hashx forces crypt regardless. Absent -> default -> unchanged.
    { "leaf_id",                          Disp::map, map_plain<&NodeCfg::leaf_id> },
    { "layer_id",                         Disp::map, map_layer_id },                        // ★ MUST follow "leaf_id" — it overrides it
    // R2 route-aging TTLs (config-overridable so a gate can shrink 45min/3h to seconds).
    { "rt_aging_ttl_neighbor_ms",         Disp::map, map_plain<&NodeCfg::rt_aging_ttl_neighbor_ms> },
    { "rt_aging_ttl_remote_ms",           Disp::map, map_plain<&NodeCfg::rt_aging_ttl_remote_ms> },
    { "rt_aging_check_period_ms",         Disp::map, map_plain<&NodeCfg::rt_aging_check_period_ms> },
    { "dv_hop_cap",                       Disp::map, map_plain<&NodeCfg::dv_hop_cap> },     // network-wide (J-join distributes it in Slice 3)
    { "channel_dirty_max_advertisements", Disp::map, map_plain<&NodeCfg::channel_dirty_max_advertisements> },  // K: BCN-digest retire count (Lua per-node; t68 shrinks it to 2)
    { "channel_pull_jitter_ms",           Disp::map, map_plain<&NodeCfg::channel_pull_jitter_ms> },            // digest-pull backoff (t69 shrinks it to pin pull order)
    // anti-spam v2 (2026-06-30): the flat channel_origin_max_per_window cap was REMOVED — replaced by the
    // duty-aware channel_cap_origin() (D/(frac·N·T_ch)). The knobs below drive it; scenarios set them optionally.
    { "channel_active_fraction",          Disp::map, map_plain<&NodeCfg::channel_active_fraction> },   // per-origin channel-cap fairness divisor (default 0.125)
    { "channel_min_interval_ms",          Disp::map, map_plain<&NodeCfg::channel_min_interval_ms> },   // channel burst floor (default 10000)
    { "dm_min_interval_ms",               Disp::map, map_plain<&NodeCfg::dm_min_interval_ms> },        // own-DM burst floor (default 3000)
    { "channel_origin_window_ms",         Disp::map, map_plain<&NodeCfg::channel_origin_window_ms> },
    { "cap_route_request_last",           Disp::map, map_plain<&NodeCfg::cap_route_request_last> },    // per-dst RREQ table cap (t61 shrinks to 2 to exercise table_cap_hit refuse)
    { "cap_id_bind",                      Disp::map, map_plain<&NodeCfg::cap_id_bind> },               // hash-locate id_bind cap (a gate shrinks it to exercise the refuse)
    { "id_bind_ttl_ms",                   Disp::map, map_plain<&NodeCfg::id_bind_ttl_ms> },            // hash-locate binding TTL (a gate shrinks the 48h default to exercise aging)
    { "allowed_data_sfs",                 Disp::map, map_allowed_data_sfs },
    { "duty_cycle",                       Disp::map, map_duty_cycle },
    { "duty_cycle_window_ms",             Disp::map, map_duty_cycle_window_ms },
    { "bw_hz",                            Disp::map, map_bw_hz },
    { "cr",                               Disp::map, map_cr },
    { "originator_max_per_window",        Disp::map, map_plain<&NodeCfg::originator_max_per_window> }, // R4.4 anti-spam threshold (T-class, Lua on_init `config.originator_max_per_window or 6`)
    // peer_count is a host-set sim-telemetry knob (N-1); the device has no sim:nodes(), so rt_full
    // convergence is sim-only. 0 = no rt_full emit.
    { "peer_count",                       Disp::map, map_plain<&NodeCfg::peer_count> },
    // lbt_enabled gates the FIRMWARE's own tx_initiating/tx_flood LBT pre-check (R4.5). The HOST-side
    // channel_busy_until() primitive is gated by FirmwareNode's own _lbt_enabled (read separately there).
    { "lbt_enabled",                      Disp::map, map_plain<&NodeCfg::lbt_enabled> },               // R4.5 firmware LBT
    { "lbt_backoff_ms",                   Disp::map, map_plain<&NodeCfg::lbt_backoff_ms> },            // 0 = derive
    { "flood_lbt_max_defer_ms",           Disp::map, map_plain<&NodeCfg::flood_lbt_max_defer_ms> },    // 0 = derive
    // NAV (virtual carrier sense). Inherit the firmware default (NodeConfig::nav_enabled = true) so the
    // sim and the device agree; set "nav_enabled": false in a scenario for an off comparison or to keep
    // a differential scenario lua-parity. C++-only feature; the Lua has no NAV.
    { "nav_enabled",                      Disp::map, map_plain<&NodeCfg::nav_enabled> },
    { "nav_ignore_rts",                   Disp::map, map_plain<&NodeCfg::nav_ignore_rts> },   // tuning knob (firmware default false = answer)
    // §1.2 (2026-07-20 review): the NodeConfig fields the wrapper NEVER read (they silently took the
    // C++ struct default — the proven-live `join_required` bug). Absent -> the field's own default.
    { "host_mobiles",                     Disp::map, map_plain<&NodeCfg::host_mobiles> },
    { "join_required",                    Disp::map, map_plain<&NodeCfg::join_required> },
    { "req_sync_on_boot",                 Disp::map, map_plain<&NodeCfg::req_sync_on_boot> },
    { "req_sync_min_routes",              Disp::map, map_plain<&NodeCfg::req_sync_min_routes> },
    { "sync_response_enabled",            Disp::map, map_plain<&NodeCfg::sync_response_enabled> },
    { "sync_response_min_routes",         Disp::map, map_plain<&NodeCfg::sync_response_min_routes> },
    { "lineage_id",                       Disp::map, map_plain<&NodeCfg::lineage_id> },
    { "config_epoch",                     Disp::map, map_plain<&NodeCfg::config_epoch> },
    { "gw_announce_duty_pct",             Disp::map, map_plain<&NodeCfg::gw_announce_duty_pct> },
    { "gw_announce_min_interval_ms",      Disp::map, map_plain<&NodeCfg::gw_announce_min_interval_ms> },
    { "gw_herd_slack",                    Disp::map, map_plain<&NodeCfg::gw_herd_slack> },
    { "intra_layer_relay",                Disp::map, map_plain<&NodeCfg::intra_layer_relay> },
    { "loc_in_dm",                        Disp::map, map_plain<&NodeCfg::loc_in_dm> },
    { "loc_in_m",                         Disp::map, map_plain<&NodeCfg::loc_in_m> },
    { "intro_attach",                     Disp::map, map_plain<&NodeCfg::intro_attach> },
    { "lat_e7",                           Disp::map, map_plain<&NodeCfg::lat_e7> },
    { "lon_e7",                           Disp::map, map_plain<&NodeCfg::lon_e7> },
    { "leaf_name",                        Disp::map, map_leaf_name },
    { "n_layers",                         Disp::map, map_n_layers },
    { "layers",                           Disp::map, map_layers },
    { "_sim_freq_khz",                    Disp::map, map_sim_freq_khz },   // §layer-freq: the node's global carrier -> NodeConfig::radio_freq_mhz. A `_sim_*` key that is MAPPED, not `elsewhere` — see map_sim_freq_khz for why there is no author-facing twin.

    // ---- accepted, consumed OUTSIDE this walk (each row names its consumer) ----
    { "seed",                             Disp::elsewhere, nullptr },   // onInit's post-walk §enc crypto-identity step (set_crypto_identity, not NodeConfig)
    { "_sim_warmup_ms",                   Disp::elsewhere, nullptr },   // SimController injection read only by the (deprecated) Lua engine's on_init
    { "_sim_bw_hz",                       Disp::elsewhere, nullptr },   // fallback for the "bw_hz" row; also FirmwareNode._node_bw_hz (RX-slop formula)
    { "_sim_cr",                          Disp::elsewhere, nullptr },   // fallback for the "cr" row
    { "_sim_duty_cycle",                  Disp::elsewhere, nullptr },   // fallback for the "duty_cycle" row
    { "_sim_duty_cycle_window_ms",        Disp::elsewhere, nullptr },   // fallback for the "duty_cycle_window_ms" row
    { "_sim_rx_window_slop",              Disp::elsewhere, nullptr },   // FirmwareNode._rx_window_slop_metal
    { "_sim_snr_report_ceiling_db",       Disp::elsewhere, nullptr },   // FirmwareNode._snr_report_ceiling_db

    // ---- accepted and read by NOTHING: known LEGACY sim-only keys never ported to the C++ NodeConfig
    //      (no field exists to map). They ride shipped scenarios (s09/s15 join + gateway-schedule tuning,
    //      top-level debug_* windows), so they stay accepted — while a typo in any mapped key still fails.
    { "discovery_beacon_period_ms",               Disp::ignored, nullptr },
    { "discovery_min_routes",                     Disp::ignored, nullptr },
    { "gateway_layers",                           Disp::ignored, nullptr },
    { "join_claim_guard_ms",                      Disp::ignored, nullptr },
    { "join_discover_jitter_ms",                  Disp::ignored, nullptr },
    { "join_listen_ms",                           Disp::ignored, nullptr },
    { "join_offer_backoff_min_ms",                Disp::ignored, nullptr },
    { "join_offer_backoff_max_ms",                Disp::ignored, nullptr },
    { "state_snapshot_period_ms",                 Disp::ignored, nullptr },
    { "sync_response_requester_mobile_penalty_ms",Disp::ignored, nullptr },
    { "debug_start_ms",                           Disp::ignored, nullptr },
    { "debug_end_ms",                             Disp::ignored, nullptr },
};
constexpr size_t kConfigKeyCount = sizeof(kConfigKeys) / sizeof(kConfigKeys[0]);

// BUILD-TIME tripwires on the table itself (the analogue of test_console_json.cpp's default-less
// switch): a row can never claim Disp::map without an applier, nor carry an applier while claiming to
// be unmapped, and no key may be listed twice (a duplicate would make the walk apply it twice).
constexpr bool key_table_dispositions_consistent() {
    for (size_t i = 0; i < kConfigKeyCount; ++i)
        if ((kConfigKeys[i].disp == Disp::map) != (kConfigKeys[i].apply != nullptr)) return false;
    return true;
}
constexpr bool key_table_names_unique() {
    for (size_t a = 0; a + 1 < kConfigKeyCount; ++a)
        for (size_t b = a + 1; b < kConfigKeyCount; ++b)
            if (std::string_view(kConfigKeys[a].name) == std::string_view(kConfigKeys[b].name)) return false;
    return true;
}
static_assert(key_table_dispositions_consistent(), "kConfigKeys: Disp::map <=> a non-null applier");
static_assert(key_table_names_unique(),            "kConfigKeys: duplicate key name");

// The whitelist membership test — the table IS the whitelist, so it cannot drift from the walk.
const KeyRow* find_config_key(const std::string& key) {
    for (size_t i = 0; i < kConfigKeyCount; ++i)
        if (key == kConfigKeys[i].name) return &kConfigKeys[i];
    return nullptr;
}

// ---- onInit: JSON -> NS::NodeConfig + Node::on_init ------------------------
// Verbatim port of the legacy FirmwareNode::onInit cfg-build (meshroute:: -> MESHROUTE_NS::),
// PLUS the new dual-layer (n_layers + layers[]) parse. Returns the on_init bool (false = REFUSED).
bool NodeRuntime::onInit(const nlohmann::json& config) {
    MESHROUTE_NS::NodeConfig cfg;  // defaults from node.h
    if (config.is_object()) {
        // §1.2 (2026-07-20 realism review): whitelist-validate EVERY top-level node.config key. An unknown
        // key used to be silently ignored (a typo, or an unported knob, quietly became a C++ struct default).
        // Now an unrecognized key FAILS LOUD (named in the log + return false -> FirmwareNode nulls the node).
        // ★ The whitelist is kConfigKeys itself (see the table above) — the SAME list the mapping walk below
        // runs, so "accepted" and "mapped" can no longer drift apart. Nested layers[]/gateway_layers
        // sub-objects are NOT strictly validated here (their parse stays permissive — s27's layers carry
        // scheduler sub-keys the parse ignores); freq_mhz IS mapped, inside map_layers.
        for (auto it = config.begin(); it != config.end(); ++it) {
            if (find_config_key(it.key()) == nullptr) {
                const std::string msg = "FATAL: meshroute config: unknown key \"" + it.key()
                    + "\" (typo or unported knob) — refusing config";
                _hal.log(msg.c_str());
                return false;
            }
        }
        // The mapping walk: every Disp::map row, in table order (which is the pre-slice source order —
        // "layer_id" overrides "leaf_id", so the order is load-bearing). Each applier handles an absent
        // key itself by falling back to the field's current value, exactly as the hand-written lines did.
        for (size_t i = 0; i < kConfigKeyCount; ++i)
            if (kConfigKeys[i].apply) kConfigKeys[i].apply(cfg, config, kConfigKeys[i].name);
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

// ===========================================================================
// Scenario-command token scanners (3-B item 6) — ONE implementation of each
// scan the onCommand grammar below performs (it had 4 hand-rolled decimal
// loops, 4 hex loops with 4 copies of the digit classifier, and 7 space-skips).
//
// Every helper is a SCAN-AND-ADVANCE primitive: it reads from `i`, leaves `i`
// on the first character it did NOT consume, and reports whether it consumed
// anything — the callers then inspect `s[i]` themselves (a following ' ',
// end-of-string, the next field, …). That is why these are not, and must not
// become, whole-token validating parsers.
//
// ⚠ DELIBERATELY NOT lib/console's parse_u32_tok / parse_hex32_tok. Those are
//   whole-token parsers that REJECT on overflow; the simulator does not compile
//   lib/console at all, and adopting their semantics would start refusing
//   scenario commands that parse today. Same reason scan_dec below carries NO
//   overflow or width guard: none of its four call sites ever had one, so
//   adding one would be a behaviour change, not a refactor.
// ===========================================================================

// Advance past ASCII spaces (the only separator the sim command grammar uses).
void scan_spaces(const std::string& s, size_t& i) {
    while (i < s.size() && s[i] == ' ') ++i;
}

// Is there a "0x"/"0X" radix prefix at `i`? A PREDICATE, not a skip, because the
// two callers mean different things by it: send_hash/send_hashx/reqpubkey treat
// it as an ignorable optional prefix (always hex), while send_layer uses its
// presence to SELECT the radix (0x => hex, bare => decimal). Keeping it a
// predicate keeps that divergence visible instead of unifying it away.
bool at_0x_prefix(const std::string& s, size_t i) {
    return i + 1 < s.size() && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X');
}

// Decimal digit run -> `out`. Returns true iff at least one digit was consumed.
// ⚠ 32-bit accumulation with NO overflow guard — see the note above; every
// original call site wrapped silently and each applies its own value cap after
// (channel id <= 255, node id <= 254, layer 1..255) exactly as before.
bool scan_dec(const std::string& s, size_t& i, uint32_t& out) {
    uint32_t v = 0;
    bool got = false;
    while (i < s.size() && s[i] >= '0' && s[i] <= '9') {
        v = v * 10u + static_cast<uint32_t>(s[i] - '0');
        ++i;
        got = true;
    }
    out = v;
    return got;
}

// Hex digit run -> `out` (a key_hash32). Returns false when no digit was found,
// AND when MORE than 8 were: a key_hash32 is 32 bits, and silently truncating
// the high nibbles would mis-address the DM to a DIFFERENT (but valid) hash with
// a success-looking reply. That >8 rejection is NOT new — all four hex call
// sites already applied it (§3-A.3); it now lives in exactly one place.
// `i` still advances past every hex digit present, rejected or not.
bool scan_hex32(const std::string& s, size_t& i, uint32_t& out) {
    uint32_t v = 0;
    int ndig = 0;
    for (; i < s.size(); ++i) {
        const char c = s[i];
        uint32_t d;
        if      (c >= '0' && c <= '9') d = static_cast<uint32_t>(c - '0');
        else if (c >= 'a' && c <= 'f') d = static_cast<uint32_t>(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') d = static_cast<uint32_t>(c - 'A' + 10);
        else break;
        v = (v << 4) | d;
        ++ndig;
    }
    out = v;
    return ndig > 0 && ndig <= 8;
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
    // §sim-leave-verb (2026-07-27): `leave` — the CONSOLE-PROVISIONING (REPROVISION) transport, mirroring the firmware
    // console's handle_leave (src/firmware_config.cpp:749) and the membership half of the provision_apply_live it calls
    // with do_dad=false. ★ WHY IT EXISTS: Node::clear_routing_state() and the purge_tx_carriers(PurgeAxis::reprovision)
    // sweep it now owns (§clean-join-carriers) had their ONLY callers in src/, which the sim does not compile, so no
    // scenario could execute them and the firmware native suite was their entire detector. MEASURED before adding this
    // verb, with an unconditional emit on ENTRY to both functions, over all 31 corpus scenarios / 1 857 425 events:
    // clear_routing_state 0 entries · purge_tx_carriers(reprovision) 0 entries · purge_tx_carriers(team_switch) 1 entry
    // (s34, via `team`). So the blind spot was the WHOLE function — routes / _id_bind / _deferred / gw_schedules /
    // bridged_layers / _mobile_reg / clear_team_routing_state as well as the carrier sweep. Exactly the blind spot
    // §sim-team-verb below closes for the TEAM axis; this closes the LEAF/reprovision axis. Like `team`, this is NOT a
    // CmdKind: lib/core exposes the reprovision as direct Node calls and the device console makes them the same way
    // (provision_apply_live invokes them itself — there is no Command plumbing for a reprovision), so this transport
    // calls them directly too.
    //
    // ⚠ NOT the `join` verb above, which is the PROTOCOL join (CmdKind::join = a DAD claim / J exchange) — a different
    // thing entirely, deliberately untouched. The two COMPOSE, and that is the intended idiom for a scenario wanting a
    // full managed->managed re-join: `leave` (go unprovisioned + wipe) then `join` (re-DAD onto the fresh network).
    //
    // ★ THE ORDER IS LOAD-BEARING and mirrors firmware_config.cpp:480-481 exactly: reset_join_for_reprovision() ends in
    // set_identity(protocol::unjoined_node_id, …), so _node_id is ALREADY 0 when clear_routing_state() runs. That is
    // precisely why a surviving staged/in-flight frame would air claiming src = 0 (see the RTS-builder audit in
    // node_channel.cpp's purge header), so reproducing the order is what makes the sweep the sim executes the same
    // sweep the device executes.
    //
    // ★ DELIBERATELY NOT MIRRORED — four omissions, all permanent, none an oversight:
    //   (1) **NV.** handle_leave's first act is an nv_load_stamped/save round-trip that zeroes the blob except freq.
    //       The sim has NO non-volatile store at all (no mrnv is compiled here), so there is nothing to write — the
    //       Node methods are called directly instead.
    //   (2) **THE CONFIG/PHY RE-APPLY.** provision_apply_live's *other* half (apply_radio_live plus the lc.leaf_id /
    //       routing_sf / allowed_sf_bitmap / duty / lineage_id / leaf_name / reset_leaf_epoch_state /
    //       recompute_duty_budget block) re-derives NodeConfig FROM THE ZEROED BLOB, i.e. from the board defaults
    //       LORA_BW / LORA_SF / LORA_CR / LORA_TX_POWER. Those macros do not exist in this build; the scenario JSON —
    //       not an NV blob — is the source of truth for a sim node's PHY; and the sim's radio is tuned through SimRadio,
    //       not through NodeConfig, so re-tuning here would desync the two. Worse, a faithful copy would set
    //       allowed_sf_bitmap = 0, which lib/core rightly REFUSES to send on (sf_list is mandatory, fail-loud), leaving
    //       the node mute for the rest of the run for reasons unrelated to the path under test. Hence: MEMBERSHIP ONLY.
    //   (3) **DAD.** `leave` is precisely the do_dad=**false** call site, so the absence of a re-DAD here is a MIRROR,
    //       not a simplification — and set_rediscover_pending(false) is copied for the same reason. It is also what
    //       keeps this verb RNG-free and therefore scenario-byte-reproducible (the DAD claim jitter and `create`'s
    //       random lineage_id are exactly the non-determinism §sim-team-verb refuses `team new` over). A scenario that
    //       wants the DAD half issues the existing `join` verb afterwards.
    //   (4) **THE HUMAN ACK LINE** (`> left network (kept freq=…)`): the sim's reply convention is the OK/ERROR string
    //       below, which is what cmd_reply_contains asserts against.
    // Not MR_FEAT_*-forked: every method called here is unforked in lib/core, and `leave` IS dispatched on the gateway
    // build too (firmware_commands.cpp — only join/create are MR_N_LAYERS<2-gated), so ONE implementation correctly
    // serves both sim variants (meshroute_core_normal + meshroute_core_gw).
    if (cmd == "leave" || cmd.rfind("leave ", 0) == 0) {
        size_t p = 5; scan_spaces(cmd, p);
        // C2: a TRAILING token is REFUSED, not ignored. handle_leave takes no arguments at all (its signature is
        // `handle_leave(Print&)`), so `leave 3` — someone assuming it names a leaf, or reaching for join's key=value
        // shape — must fail loud rather than silently perform a full reprovision of something else.
        if (p != cmd.size())
            return "ERROR: usage: leave   (no arguments — the console-provisioning reprovision: go unprovisioned and "
                   "idle, dropping the old network's routes/bindings and EVERY staged/in-flight TX carrier). Follow "
                   "with `join` to re-DAD. Radio/PHY and NV are deliberately not re-applied here.";
        // The reprovision, in provision_apply_live's order (firmware_config.cpp:480-481 — see the ★ note above):
        _node.reset_join_for_reprovision();            // §2 membership: drop the id AND clear _joined (set_identity(0) alone leaves _joined set -> a later `join` no-ops)
        _node.mutable_config().layers[0].node_id = 0;   // the firmware's companion line on :480 — the CONFIG copy of the id, which canonical_node_id() reads on a gateway
        _node.clear_routing_state();                   // ★ THE TARGET: routes / id-binds / deferred / gw schedules / bridged layers / hosted-mobile registry + purge_tx_carriers(PurgeAxis::reprovision)
        _node.set_rediscover_pending(false);           // do_dad=false: stay idle; do NOT restart discovery (join/create pass true here)
        // Read the state back off the NODE (not off our own assumptions) so the reply reports what lib/core actually
        // holds — the §sim-team-verb discipline. The purge itself is observed through its MR_EMIT
        // `reprovision_tx_purged` (rows/floods/queued/flight/reoffers/kept), the reprovision-axis twin of the
        // `team_channel_purged` that s34 asserts on; a void sweep has nothing to put in a reply string.
        return std::string("OK leave unprovisioned node_id=") + std::to_string(_node.canonical_node_id()) +
               " joined=" + (_node.joined() ? "1" : "0");
    }
    // §sim-team-verb (2026-07-27): `team <id>` — the TEAM-SWITCH transport, mirroring the firmware console's
    // handle_team (src/firmware_config.cpp, its tail). ★ WHY IT EXISTS: the whole §clean-team / §clean-team-channel
    // mechanism (Node::set_team_id -> clear_team_routing_state + purge_team_channel_state) had its ONLY callers in
    // src/, which the sim does not compile — so no scenario could execute it and the firmware native suite was its
    // entire detector. Unlike the send verbs this is NOT a CmdKind: lib/core exposes the switch as a direct Node
    // call and the device console calls it the same way (handle_team invokes set_team_id itself, there is no
    // Command plumbing for it), so this transport calls it directly too.
    //
    // ★ DELIBERATELY NOT IMPLEMENTED — three omissions, all permanent, none an oversight:
    //   (1) **`team new` (MINT).** The firmware mints `team_fnv1a32(key_hash32, nonce)` with a nonce from
    //       `rand_bytes` — so the id differs EVERY RUN. In the sim that is non-deterministic and would destroy the
    //       byte-reproducibility of any scenario using it (the team_id rides every team frame on the wire). A
    //       scenario that wants a fresh team simply NAMES one: `team 0xDEADBEEF` reaches the identical core path,
    //       because handle_team's mint and join branches differ ONLY in where `t` comes from. A deterministic mint
    //       (seeded nonce) would be a separate, explicit design decision — not this transport's default.
    //   (2) **`cfg set team_id`** — the firmware's second live team-switch path. The sim has no `cfg` verb at all,
    //       so there is nothing here to route through set_team_id. Out of scope.
    //   (3) **the optional PHY tail** (`team <id> freq= sf= bw=`). Scenarios set the team PHY in their node JSON,
    //       and parse_phy_tail lives in src/ (not compiled here). A tail is REFUSED, not ignored (see below).
    // Not MR_FEAT_TEAM-forked: set_team_id is unforked in lib/core, and team_dad_fire()/team_local_id() inline-stub
    // to inert on a !MR_FEAT_TEAM build (node.h), so one implementation serves both sim variants.
    if (cmd.rfind("team ", 0) == 0) {
        size_t p = 5; scan_spaces(cmd, p);
        // Radix: a leading 0x/0X SELECTS hex and a bare token is DECIMAL — the send_layer convention (U3), not
        // send_hash's "0x is an ignorable prefix, always hex". ⚠ The firmware uses strtoul(args, &endp, 0), which
        // ALSO reads a leading-zero token as OCTAL; the sim deliberately does not, because `team 010` silently
        // meaning team 8 would join the WRONG team. A deliberate divergence, not a port error.
        const size_t d0 = p;
        uint32_t id = 0; bool got;
        if (at_0x_prefix(cmd, p)) { p += 2; got = scan_hex32(cmd, p, id); }   // 0x… => hex (>8 digits rejected)
        else {
            got = scan_dec(cmd, p, id);
            // ★ C2: scan_dec has NO overflow guard (see its header note) and every OTHER decimal call site is
            // saved by a small value cap (channel <= 255 / node <= 254 / layer 1..255). A team_id spans the FULL
            // 32-bit range, so nothing downstream would catch a wrap — `team 4294967297` must NOT silently become
            // team 1 (the firmware's strtoul SATURATES rather than wrapping, so a wrap would also diverge from
            // the device). Round-trip the digit run to reject it loudly.
            std::string digits = cmd.substr(d0, p - d0);
            const size_t nz = digits.find_first_not_of('0');
            digits = (nz == std::string::npos) ? std::string("0") : digits.substr(nz);
            if (got && digits != std::to_string(id)) got = false;
        }
        scan_spaces(cmd, p);
        // C2: a TRAILING token is refused, not ignored — that is how the firmware's unsupported PHY tail
        // (`team 0x22222222 freq=869`) fails LOUD here instead of half-applying (team switched, PHY silently not).
        if (got && p == cmd.size()) {
            // The switch, in handle_team's order: set_team_id() drops the OLD team's learned plane (routes / peer
            // set / liveness / key cache / RREQ ledgers) plus the stale team-DAD id, then adopts the new id LIVE,
            // returning true ONLY on a real change. The re-DAD therefore runs only for a mobile joining a
            // non-zero team — `team 0` (leave) and a same-id no-op never re-DAD.
            const bool switched = _node.set_team_id(id);
            if (_node.config().is_mobile && id != 0 && switched) _node.team_dad_fire();
            // Read both values back off the NODE (not off `id`) so the reply reports what lib/core actually holds.
            char hex[11];
            std::snprintf(hex, sizeof hex, "0x%08lX",
                          static_cast<unsigned long>(_node.config().team_id));
            return std::string("OK team ") + (switched ? "switched" : "unchanged") +
                   " team_id=" + hex +
                   " team_local_id=" + std::to_string(_node.team_local_id());
        }
        return "ERROR: usage: team <team_id 0xHEX|decimal> (team 0 = leave). `team new` is deliberately "
               "unsupported: its random nonce would break scenario byte-reproducibility — name the id instead.";
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
            size_t e = cpfx; scan_spaces(cmd, e);
            uint32_t ch = 0; const bool got = scan_dec(cmd, e, ch);
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
        size_t e = 10; scan_spaces(cmd, e);
        if (at_0x_prefix(cmd, e)) e += 2;                          // optional 0x
        uint32_t h = 0; const bool got = scan_hex32(cmd, e, h);    // false on no-digits OR >8 digits
        if (got && h != 0 && e < cmd.size() && cmd[e] == ' ') {
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
        size_t e = 11; scan_spaces(cmd, e);
        if (at_0x_prefix(cmd, e)) e += 2;                          // optional 0x
        uint32_t h = 0; const bool got = scan_hex32(cmd, e, h);    // false on no-digits OR >8 digits
        if (got && h != 0 && e < cmd.size() && cmd[e] == ' ') {
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
        size_t e = 10; scan_spaces(cmd, e);
        if (at_0x_prefix(cmd, e)) e += 2;                          // optional 0x
        uint32_t h = 0; const bool got = scan_hex32(cmd, e, h);    // false on no-digits OR >8 digits
        if (got && h != 0) {
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
            size_t p = xpfx; scan_spaces(cmd, p);
            uint32_t layer = 0; const bool gl = scan_dec(cmd, p, layer);            // target destination layer id
            scan_spaces(cmd, p);
            // dst key_hash32: here a leading 0x/0X SELECTS the radix (unlike send_hash*/reqpubkey above,
            // where it is merely an ignorable optional prefix) — a bare token is DECIMAL.
            uint32_t hash = 0; bool gh;
            if (at_0x_prefix(cmd, p)) { p += 2; gh = scan_hex32(cmd, p, hash); }    // 0x… => hex (>8 digits rejected)
            else                      {         gh = scan_dec  (cmd, p, hash); }    // bare  => decimal
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
        size_t e = pfx; scan_spaces(cmd, e);
        uint32_t dst = 0; const bool got = scan_dec(cmd, e, dst);
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
// JSON shape unchanged (insertion order kind,ctr,dst[,origin,payload]); FirmwareNode wraps the payload as a
// "push" script_emit.
//
// ★ §w4-#6 (2026-07-26) — THE `kind` FIELD IS NOW THE FIRMWARE'S OWN TABLE, not a local ternary.
// What was here rendered only msg_recv / send_acked / send_e2e_acked and defaulted EVERYTHING ELSE to
// "send_failed". PushKind has 14 enumerators, so 11 hit that default and 10 of them were flatly WRONG:
// channel_recv, hash_resolved, peer_key_cached, config_adopted, join_refused, send_blocked, channel_sent,
// mobile_reg, team_reg and join_adopted every one reported to scenarios and analysis tools as a send FAILURE.
// The exhaustive, -Wswitch-guarded mapper already existed in lib/console (the shipped companion contract's
// own table); the oracle now CALLS it via the mrsim::pushKindName bridge, so the two audiences cannot drift.
// ⚠ ONE SPELLING CHANGED with it: send_e2e_acked used to render "send_e2e_acked" here and "e2e_acked" in the
// console. The CONSOLE spelling wins — it is the documented contract of a shipped app
// (ios-companion/INBOX_SYNC_CONTRACT.md); the oracle stream is consumed only by scenarios and our tooling.
// ⚠ STILL MISSING, DELIBERATELY — two gaps, neither an oversight, both additive whenever wanted:
//   (1) the push `reason` (SendFailReason) is not emitted at all, so no scenario can tell no_route from
//       e2e_ack_timeout, and sendfailreason_name has zero sim coverage. ConsoleNames.h says how to bridge it.
//   (2) `origin`/`payload` are still emitted for msg_recv ONLY. Now that channel_recv is named honestly a
//       reader may expect its minter + body here too — the firmware Push carries both. That would be a SCHEMA
//       change stacked on a relabel; this slice moved the `kind` VALUE and nothing else, which is what kept
//       the corpus delta 100% attributable (2319 relabelled pushes, 0 other field diffs, 0 event-count change).
void NodeRuntime::drainPushes(const PushSink& sink) {
    // Twin of the tripwire in ConsoleNames.cpp, which sees the OTHER namespace. Together they pin that both
    // ODR-distinct PushKinds carry identical enumerator values, which is what makes the uint8_t bridge sound.
    static_assert(sizeof(MESHROUTE_NS::PushKind) == 1,
                  "PushKind must stay uint8_t-backed: the sim bridges it on its underlying type");
    static_assert(static_cast<uint8_t>(MESHROUTE_NS::PushKind::join_adopted) == 13,
                  "PushKind's enumerator values moved in this namespace — re-check the twin assert in "
                  "ConsoleNames.cpp before trusting the uint8_t bridge");
    MESHROUTE_NS::Push p;
    while (_node.next_push(p)) {
        const char* kind = mrsim::pushKindName(static_cast<uint8_t>(p.kind));
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
