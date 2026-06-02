// orchestrator/runtime/FirmwareNode.cpp
#include "orchestrator/runtime/FirmwareNode.h"

#include "core/events/EventLog.h"
#include "core/physics/LbtModel.h"

#include <string>
#include <utility>

// Node-clock delay -> wall-clock delay, identical to ScriptedNode's helper so
// the C++ firmware experiences the same crystal-drift semantics as the Lua
// model (node clock runs at (1 + drift) x wall).
static inline uint64_t nodeDelayToWallDelay(uint64_t delay_ms, float drift_ppm) {
    if (drift_ppm == 0.0f || delay_ms == 0) return delay_ms;
    const double scale = 1.0 + (double)drift_ppm * 1e-6;
    if (scale <= 0.0) return delay_ms;
    const double wall = (double)delay_ms / scale;
    if (wall < 0.0) return 0;
    return (uint64_t)(wall + 0.5);
}

FirmwareNode::FirmwareNode(int id, std::string name, uint32_t key_hash32,
                           SimRadio& radio, std::ostream& events_out,
                           VirtualClock& clock, std::mt19937& sim_rng)
    : _id(id),
      _protocol_id(id),
      _name(std::move(name)),
      _key_hash32(key_hash32),
      _radio(radio),
      _events_out(events_out),
      _clock(clock),
      _sim_rng(sim_rng) {
    (void)_radio;        // TX goes via _pending_txs (drained by SimController), not SimRadio directly
    (void)_events_out;   // EventLog owns its output stream
}

// =============================================================================
// INode — driven by SimController; forwards into the owned meshroute::Node
// =============================================================================

void FirmwareNode::onInit(const nlohmann::json& config) {
    meshroute::NodeConfig cfg;  // defaults from node.h
    if (config.is_object()) {
        cfg.routing_sf          = config.value("routing_sf",          cfg.routing_sf);
        cfg.beacon_period_ms    = config.value("beacon_period_ms",    cfg.beacon_period_ms);
        cfg.beacon_max_idle_ms  = config.value("beacon_max_idle_ms",  cfg.beacon_max_idle_ms);
        cfg.quiet_threshold_ms  = config.value("quiet_threshold_ms",  cfg.quiet_threshold_ms);
        cfg.beacon_silence_jitter_ms = config.value("beacon_silence_jitter_ms", cfg.beacon_silence_jitter_ms);  // R4.3
        cfg.seen_bitmap_enabled = config.value("seen_bitmap_enabled", cfg.seen_bitmap_enabled);
        cfg.is_gateway          = config.value("is_gateway",          cfg.is_gateway);
        cfg.is_mobile           = config.value("is_mobile",           cfg.is_mobile);
        cfg.leaf_id             = config.value("leaf_id",             cfg.leaf_id);
        // R2 route-aging TTLs (config-overridable so a gate can shrink 45min/3h to seconds).
        cfg.rt_aging_ttl_neighbor_ms = config.value("rt_aging_ttl_neighbor_ms", cfg.rt_aging_ttl_neighbor_ms);
        cfg.rt_aging_ttl_remote_ms   = config.value("rt_aging_ttl_remote_ms",   cfg.rt_aging_ttl_remote_ms);
        cfg.rt_aging_check_period_ms = config.value("rt_aging_check_period_ms", cfg.rt_aging_check_period_ms);
        cfg.data_sf                  = config.value("data_sf",                  cfg.data_sf);   // R3 data plane
        // allowed_data_sfs: [7,9] -> allowed_sf_bitmap (bit = sf), matching the Lua config key. The DATA-SF
        // selector picks the fastest SF in this set the link SNR supports; absent/empty -> the single data_sf.
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
        // SimController injects _sim_duty_cycle = simulation.radio.duty_cycle (default 0.01) into every
        // node's config, so a scenario that sets only the GLOBAL radio.duty_cycle leaves Lua nodes ENABLED
        // (0.01) — the meshroute node MUST inherit the same, or the engines disagree on the budget and a
        // node crossing CRITICAL would NACK on one engine but CTS on the other (lua-vs-meshroute review #00).
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
        // lbt_enabled gates BOTH the HOST channel_busy_until() primitive (off => reports idle, so the firmware
        // LBT never defers) AND, from R4.5, the FIRMWARE's own tx_initiating/tx_flood LBT pre-check. Both read the
        // same config key (matching the Lua's config.lbt_enabled, default true). Off => no LBT-backoff rand.
        _lbt_enabled            = config.value("lbt_enabled",         _lbt_enabled);
        cfg.lbt_enabled         = config.value("lbt_enabled",         cfg.lbt_enabled);   // R4.5 firmware LBT
        cfg.lbt_backoff_ms      = config.value("lbt_backoff_ms",      cfg.lbt_backoff_ms);        // 0 = derive
        cfg.flood_lbt_max_defer_ms = config.value("flood_lbt_max_defer_ms", cfg.flood_lbt_max_defer_ms);  // 0 = derive
    }
    _node = std::make_unique<meshroute::Node>(
        *this, static_cast<uint8_t>(_protocol_id), _key_hash32, _name.c_str());
    _node->on_init(cfg);
}

void FirmwareNode::onRecv(std::string_view bytes, float snr, float rssi,
                          int link_id, int src_id, uint64_t sim_ms) {
    (void)link_id;
    // god-view sender id intentionally discarded: real LoRa carries no link source,
    // so the firmware must run with src_hint = -1 (unknown) exactly as it does on metal.
    (void)src_id;
    if (!_initialized || !_node) return;
    meshroute::RxMeta meta{snr, rssi, sim_ms, /*src_hint=*/-1};
    _node->on_recv(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size(), meta);
}

std::string FirmwareNode::onCommand(std::string_view cmd_str) {
    if (!_initialized || !_node) return "ERROR: node not initialized yet";
    std::string cmd(cmd_str);
    // The sim TRANSPORT parses its command string into a TYPED meshroute::Command
    // (a device backend parses its binary frames into the SAME Command). lib/core
    // never sees a command string. SimController has already resolved name -> id.
    if (cmd.rfind("send ", 0) == 0) {
        size_t s = 5; while (s < cmd.size() && cmd[s] == ' ') ++s;
        unsigned dst = 0; size_t e = s; bool got = false;
        while (e < cmd.size() && cmd[e] >= '0' && cmd[e] <= '9') { dst = dst * 10 + (cmd[e] - '0'); ++e; got = true; }
        if (got && dst <= 254 && e < cmd.size() && cmd[e] == ' ') {
            const std::string body = cmd.substr(e + 1);
            meshroute::Command c{};
            c.kind = meshroute::CmdKind::send;
            c.u.send.dst_id = static_cast<uint8_t>(dst);
            c.u.send.flags  = 0;
            const size_t cap = 233;   // max_payload_bytes_hard_cap - 2
            c.body = reinterpret_cast<const uint8_t*>(body.data());   // borrowed during the call
            c.body_len = static_cast<uint8_t>(body.size() > cap ? cap : body.size());
            const meshroute::CmdResult r = _node->on_command(c);
            const char* code = (r.code == meshroute::CmdCode::queued) ? "queued" : "error";
            return std::string("OK ") + code + " ctr=" + std::to_string(r.ctr) +
                   " depth=" + std::to_string(r.queue_depth);
        }
    }
    return "ERROR: unparsed command";
}

void FirmwareNode::onRadioBusy(const RadioBusyInfo& info) {
    if (!_initialized || !_node) return;
    meshroute::BusyReason reason = meshroute::BusyReason::channel_busy;
    if      (info.reason == "self_tx_in_flight")    reason = meshroute::BusyReason::self_tx_in_flight;
    else if (info.reason == "oversized")            reason = meshroute::BusyReason::oversized;
    else if (info.reason == "duty_cycle_exceeded")  reason = meshroute::BusyReason::duty_cycle_exceeded;
    meshroute::BusyInfo bi{reason, /*tag=*/info.tag,
                           static_cast<int16_t>(info.sf), info.busy_until_ms};
    _node->on_radio_busy(bi);
}

void FirmwareNode::onPreambleDetected(uint64_t time_ms, int from_id, float snr_db) {
    (void)from_id; (void)snr_db;
    if (!_initialized || !_node) return;
    _node->on_preamble_detected(time_ms);
}

void FirmwareNode::tickTimers(uint64_t sim_ms) {
    TimerEntry e{};
    while (_timers.popDue(sim_ms, e)) {
        auto it = _handle_to_id.find(e.handle);
        if (it == _handle_to_id.end()) continue;   // cancelled/stale
        const uint32_t timer_id = it->second;
        if (e.period_ms == 0) {                      // one-shot: clear the maps before firing
            _handle_to_id.erase(it);
            _id_to_handle.erase(timer_id);
        }
        if (_node) _node->on_timer(timer_id);
    }
    drainPushes();   // surface the Node's async app-channel pushes as telemetry
}

void FirmwareNode::drainPushes() {
    if (!_node) return;
    meshroute::Push p;
    while (_node->next_push(p)) {
        const char* kind = (p.kind == meshroute::PushKind::msg_recv)   ? "msg_recv"
                         : (p.kind == meshroute::PushKind::send_acked) ? "send_acked"
                                                                       : "send_failed";
        nlohmann::json j;
        j["kind"] = kind;
        j["ctr"]  = p.ctr;
        j["dst"]  = p.dst;
        if (p.kind == meshroute::PushKind::msg_recv) {
            j["origin"]  = p.origin;
            j["payload"] = std::string(reinterpret_cast<const char*>(p.body), p.body_len);
        }
        EventLog::logScriptEmit(_id, _clock.getMillis(), "push", j.dump());
    }
}

std::vector<PendingTx> FirmwareNode::drainPendingTxs() {
    std::vector<PendingTx> out;
    out.swap(_pending_txs);
    return out;
}

void FirmwareNode::recordTxAirtime(uint64_t end_ms, uint32_t airtime_ms) {
    _tx_airtime_log.push_back({end_ms, airtime_ms});
}

uint64_t FirmwareNode::airtimeUsedInWindow(uint64_t now, uint64_t window_ms) {
    if (window_ms == 0) return 0;
    const uint64_t cutoff = (now > window_ms) ? (now - window_ms) : 0;
    while (!_tx_airtime_log.empty() && _tx_airtime_log.front().end_ms <= cutoff) {
        _tx_airtime_log.pop_front();
    }
    uint64_t sum = 0;
    for (const auto& e : _tx_airtime_log) sum += e.airtime_ms;
    return sum;
}

uint64_t FirmwareNode::oldestTxEndMs() const {
    if (_tx_airtime_log.empty()) return 0;
    return _tx_airtime_log.front().end_ms;
}

void FirmwareNode::armSfSwitchBlindWindow() {
    if (_sf_switch_delay_ms <= 0.0f) return;
    const uint64_t now = _clock.getMillis();
    const uint64_t blind_end = now + (uint64_t)(_sf_switch_delay_ms + 0.5f);
    if (blind_end > _rx_blind_until_ms) _rx_blind_until_ms = blind_end;
}

// =============================================================================
// meshroute::Hal — called by the owned meshroute::Node
// =============================================================================

meshroute::TxResult FirmwareNode::tx(const uint8_t* bytes, size_t len,
                                     const meshroute::TxParams& p) {
    if (len > 255) return meshroute::TxResult::too_long;  // SX1262 length register
    PendingTx t;
    t.bytes.assign(reinterpret_cast<const char*>(bytes), len);
    t.sf           = p.sf;
    t.bw_hz        = p.bw_hz;
    t.cr           = p.cr;
    t.power_dbm    = (p.power_dbm == -127) ? -127 : p.power_dbm;
    t.preamble_sym = p.preamble_sym;
    if (p.label) t.label = p.label;
    if (p.info)  t.info  = p.info;
    t.tag = p.tag;                                  // R4.5b: carry the frame-type tag for on_radio_busy
    _pending_txs.push_back(std::move(t));
    return meshroute::TxResult::ok;
}

void FirmwareNode::set_rx_sf(int sf) {
    if (!_sf_rx_set) return;
    if (sf < 5) sf = 5;
    if (sf > 12) sf = 12;
    *_sf_rx_set = { sf };
    armSfSwitchBlindWindow();
}

uint64_t FirmwareNode::channel_busy_until() {
    // Gate-1 (inert at R3.x — the Node doesn't call this until R4): honour the
    // lbt_enabled host knob so a disabled-LBT gate reports an idle channel.
    return (_lbt_enabled && _lbt) ? _lbt->busyUntil(_id) : 0;
}

uint64_t FirmwareNode::airtime_used_ms(uint64_t window_ms) {
    return airtimeUsedInWindow(_clock.getMillis(), window_ms);
}

uint64_t FirmwareNode::oldest_tx_end_ms() { return oldestTxEndMs(); }

uint64_t FirmwareNode::now() {
    const uint64_t wall = _clock.getMillis();
    if (_clock_drift_ppm == 0.0f) return wall;
    const double drifted = (double)wall * (1.0 + (double)_clock_drift_ppm * 1e-6);
    if (drifted < 0.0) return 0;
    return (uint64_t)(drifted + 0.5);
}

bool FirmwareNode::after(uint32_t delay_ms, uint32_t timer_id) {
    // Re-arm semantics: arming an already-pending id reschedules it.
    auto existing = _id_to_handle.find(timer_id);
    if (existing != _id_to_handle.end()) {
        _timers.cancel(existing->second);
        _handle_to_id.erase(existing->second);
        _id_to_handle.erase(existing);
    }
    if (_id_to_handle.size() >= kMaxTimers) return false;
    const uint64_t wall = nodeDelayToWallDelay(delay_ms, _clock_drift_ppm);
    TimerHandle h = _timers.scheduleAfter(_clock.getMillis(), wall, /*period=*/0);
    _id_to_handle[timer_id] = h;
    _handle_to_id[h] = timer_id;
    return true;
}

void FirmwareNode::cancel(uint32_t timer_id) {
    auto it = _id_to_handle.find(timer_id);
    if (it == _id_to_handle.end()) return;
    _timers.cancel(it->second);
    _handle_to_id.erase(it->second);
    _id_to_handle.erase(it);
}

void FirmwareNode::set_protocol_id(int id) {
    if (id < 0) id = 0;
    if (id > 255) id = 255;
    _protocol_id = id;
}

int FirmwareNode::rand_range(int lo, int hi) {
    if (hi <= lo) return lo;
    std::uniform_int_distribution<int> dist(lo, hi - 1);
    return dist(_sim_rng);
}

void FirmwareNode::emit(const char* type, const meshroute::EventField* fields, size_t n) {
    // Serialize the structured fields to JSON byte-identically to
    // ScriptedNode::api_emit (nlohmann::json::dump) so S3 NDJSON parity holds.
    nlohmann::json j = nlohmann::json::object();
    for (size_t k = 0; k < n; ++k) {
        const auto& f = fields[k];
        switch (f.type) {
            case meshroute::EventField::T::i64:     j[f.key] = f.i; break;
            case meshroute::EventField::T::f64:     j[f.key] = f.f; break;
            case meshroute::EventField::T::str:     j[f.key] = (f.s ? f.s : ""); break;
            case meshroute::EventField::T::boolean: j[f.key] = f.b; break;
        }
    }
    EventLog::logScriptEmit(_id, _clock.getMillis(), type, j.dump());
}

void FirmwareNode::log(const char* msg) {
    EventLog::logScriptLog(_id, _clock.getMillis(), msg ? msg : "");
}

void FirmwareNode::panic(const char* why) {
    EventLog::logScriptLog(_id, _clock.getMillis(),
                           std::string("PANIC: ") + (why ? why : "?"));
}
