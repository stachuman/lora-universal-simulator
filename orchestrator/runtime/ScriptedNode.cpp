// orchestrator/runtime/ScriptedNode.cpp
#include "orchestrator/runtime/ScriptedNode.h"

#include "core/events/EventLog.h"
#include "core/events/JsonToSol.h"
#include "core/physics/LbtModel.h"
#include "orchestrator/runtime/LuaHost.h"

#include <sstream>
#include <utility>

ScriptedNode::ScriptedNode(int id, std::string name,
                           LuaHost& host, SimRadio& radio, std::ostream& events_out,
                           VirtualClock& clock, std::mt19937& sim_rng)
    : _id(id),
      _name(std::move(name)),
      _host(host),
      _radio(radio),
      _events_out(events_out),
      _clock(clock),
      _sim_rng(sim_rng) {
    (void)_radio;        // currently held by reference; consumed by main loop
    (void)_events_out;   // EventLog has its own output-stream registration
}

// -----------------------------------------------------------------------------
// Lifecycle dispatchers — thin pass-throughs to LuaHost. Convert nlohmann::json
// to a sol::table once, here, so LuaHost's signature stays sol-flavored.
// -----------------------------------------------------------------------------

namespace {

// Walk a sol::table and produce an nlohmann::json mirror. Keeps Lua arrays
// (consecutive 1..N integer keys) as JSON arrays; everything else becomes a
// JSON object. Pragmatic for Y1: nested tables and primitives only.
nlohmann::json sol_table_to_json(sol::table t) {
    // First pass: decide array vs. object. A table is "array-like" if every
    // key is a positive integer and the largest one equals the count.
    int64_t max_idx = 0;
    int     count   = 0;
    bool    array_like = true;
    for (auto& kv : t) {
        sol::object k = kv.first;
        ++count;
        if (k.is<int64_t>()) {
            int64_t i = k.as<int64_t>();
            if (i <= 0) { array_like = false; }
            else if (i > max_idx) max_idx = i;
        } else {
            array_like = false;
        }
    }
    if (array_like && count > 0 && max_idx == count) {
        nlohmann::json arr = nlohmann::json::array();
        for (int64_t i = 1; i <= max_idx; ++i) {
            sol::object v = t[i];
            if      (v.is<sol::table>())   arr.push_back(sol_table_to_json(v.as<sol::table>()));
            else if (v.is<bool>())         arr.push_back(v.as<bool>());
            else if (v.is<int64_t>())      arr.push_back(v.as<int64_t>());
            else if (v.is<double>())       arr.push_back(v.as<double>());
            else if (v.is<std::string>())  arr.push_back(v.as<std::string>());
            else                           arr.push_back(nullptr);
        }
        return arr;
    }
    nlohmann::json obj = nlohmann::json::object();
    for (auto& kv : t) {
        sol::object k = kv.first;
        sol::object v = kv.second;
        std::string key;
        if (k.is<std::string>())     key = k.as<std::string>();
        else if (k.is<int64_t>())    key = std::to_string(k.as<int64_t>());
        else if (k.is<double>())     key = std::to_string(k.as<double>());
        else                         key = "?";
        if      (v.is<sol::table>())  obj[key] = sol_table_to_json(v.as<sol::table>());
        else if (v.is<bool>())        obj[key] = v.as<bool>();
        else if (v.is<int64_t>())     obj[key] = v.as<int64_t>();
        else if (v.is<double>())      obj[key] = v.as<double>();
        else if (v.is<std::string>()) obj[key] = v.as<std::string>();
        else                          obj[key] = nullptr;
    }
    return obj;
}

// Best-effort stringification of a sol::object for self:log(...).
std::string sol_to_string(const sol::object& o) {
    if (o.is<std::string>()) return o.as<std::string>();
    if (o.is<bool>())        return o.as<bool>() ? "true" : "false";
    if (o.is<int64_t>())     return std::to_string(o.as<int64_t>());
    if (o.is<double>()) {
        std::ostringstream oss;
        oss << o.as<double>();
        return oss.str();
    }
    if (o.is<sol::lua_nil_t>()) return "nil";
    if (o.is<sol::table>())     return "<table>";
    if (o.is<sol::function>())  return "<function>";
    return "<?>";
}

} // namespace

void ScriptedNode::onInit(const nlohmann::json& config) {
    sol::state_view L(_host.lua());
    sol::object cfg_obj = lus::json_to_sol(L, config);
    sol::table cfg_tbl = cfg_obj.is<sol::table>()
        ? cfg_obj.as<sol::table>()
        : L.create_table();
    _host.callOnInit(_id, cfg_tbl);
}

void ScriptedNode::onRecv(std::string_view bytes, float snr, float rssi,
                          int link_id, uint64_t sim_ms) {
    if (!_initialized) return;   // radio off until on_init has fired
    _host.callOnRecv(_id, bytes, snr, rssi, link_id, sim_ms);
}

std::string ScriptedNode::onCommand(std::string_view cmd_str) {
    if (!_initialized) return "ERROR: node not initialized yet";
    return _host.callOnCommand(_id, cmd_str);
}

void ScriptedNode::onRadioBusy(const RadioBusyInfo& info) {
    if (!_initialized) return;
    _host.callOnRadioBusy(_id, info);
}

// -----------------------------------------------------------------------------
// Timer driving + pending-tx draining
// -----------------------------------------------------------------------------

void ScriptedNode::tickTimers(uint64_t sim_ms) {
    TimerEntry e{};
    while (_timers.popDue(sim_ms, e)) {
        // Fire the Lua-side timer callback (LuaHost knows where to look).
        _host.fireTimerCallback(_id, e.handle);
        // For one-shot timers, clear the Lua reference now so the closure
        // becomes GC-eligible. Recurring entries are auto-rescheduled by
        // TimerWheel and reuse the same Lua-side function.
        if (e.period_ms == 0) {
            sol::table timers = _host.lua()["_LUS"]["nodes"][_id]["timers"];
            timers[e.handle] = sol::lua_nil;
        }
    }
}

std::vector<PendingTx> ScriptedNode::drainPendingTxs() {
    std::vector<PendingTx> out;
    out.swap(_pending_txs);
    return out;
}

// -----------------------------------------------------------------------------
// self:* runtime methods
// -----------------------------------------------------------------------------

void ScriptedNode::api_tx(std::string bytes, sol::optional<sol::table> opts) {
    PendingTx p;
    p.bytes = std::move(bytes);
    if (opts) {
        sol::table o = *opts;
        // sol2 quirk: `sol::optional<int> = o["missing_key"]` returns an
        // ENGAGED optional with value 0 (lua_nil → int as 0). That silently
        // overrides PendingTx's sentinels and was clobbering preamble_sym to
        // 0 → clamped to 6 → every airtime computed with preamble=6 instead
        // of the radio's configured default 16. Probe the type explicitly to
        // distinguish absent from a literal 0.
        auto get_int = [&o](const char* key, int sentinel) -> int {
            sol::object obj = o.get<sol::object>(key);
            return obj.is<int>() ? obj.as<int>() : sentinel;
        };
        auto get_str = [&o](const char* key) -> std::string {
            sol::object obj = o.get<sol::object>(key);
            return obj.is<std::string>() ? obj.as<std::string>() : std::string();
        };
        p.sf           = get_int("sf",            -1);
        p.bw_hz        = get_int("bw",            -1);    // wire-format key is "bw" (Hz)
        p.cr           = get_int("cr",            -1);
        p.power_dbm    = get_int("power_dbm",     -127);
        // preamble_sym is the canonical name; "preamble" is accepted as an
        // alias for ergonomic Lua call-sites (`{ preamble = 16 }`).
        p.preamble_sym = get_int("preamble_sym",  -1);
        if (p.preamble_sym < 0) p.preamble_sym = get_int("preamble", -1);
        p.label        = get_str("label");
        p.info         = get_str("info");
    }
    _pending_txs.push_back(std::move(p));
}

uint64_t ScriptedNode::api_after(uint64_t delay_ms, sol::function fn) {
    TimerHandle h = _timers.scheduleAfter(_clock.getMillis(), delay_ms, /*period=*/0);
    sol::table timers = _host.lua()["_LUS"]["nodes"][_id]["timers"];
    timers[h] = fn;
    return h;
}

uint64_t ScriptedNode::api_every(uint64_t period_ms, sol::function fn) {
    TimerHandle h = _timers.scheduleAfter(_clock.getMillis(), period_ms,
                                          static_cast<uint32_t>(period_ms));
    sol::table timers = _host.lua()["_LUS"]["nodes"][_id]["timers"];
    timers[h] = fn;
    return h;
}

void ScriptedNode::api_cancel(uint64_t handle) {
    _timers.cancel(handle);
    sol::table timers = _host.lua()["_LUS"]["nodes"][_id]["timers"];
    timers[handle] = sol::lua_nil;
}

uint64_t ScriptedNode::api_now() const {
    return _clock.getMillis();
}

int ScriptedNode::api_rand(int lo, int hi) {
    if (hi <= lo) return lo;
    std::uniform_int_distribution<int> dist(lo, hi - 1);
    return dist(_sim_rng);
}

void ScriptedNode::api_log(sol::variadic_args args) {
    std::ostringstream oss;
    bool first = true;
    for (auto v : args) {
        if (!first) oss << ' ';
        first = false;
        oss << sol_to_string(static_cast<sol::object>(v));
    }
    EventLog::logScriptLog(_id, _clock.getMillis(), oss.str());
}

void ScriptedNode::api_emit(std::string type, sol::optional<sol::table> data) {
    std::string json_text = "{}";
    if (data) {
        nlohmann::json j = sol_table_to_json(*data);
        json_text = j.dump();
    }
    EventLog::logScriptEmit(_id, _clock.getMillis(), type, json_text);
}

sol::table ScriptedNode::api_peers() {
    // TODO(T13): once MatrixLinkModel is wired, return the list of physical
    // neighbours (DEBUG-only — scripts that want neighbour discovery for
    // protocol behaviour must do it on-air). For now: empty table.
    return _host.lua().create_table();
}

// Dynamic RX-SF retune. Mutates this node's slot in SimController's
// _node_sf_rx_set; the loop reads that slot at delivery time, so the change
// takes effect for subsequent packets without restarting the radio. Models
// real-hardware behaviour where retuning the modem to a different SF is a
// register write, not a reboot.
//
// Out-of-range SFs are clamped to [5,12] to match the JsonConfig sf_rx_set
// parser. If no SFs survive validation in set_rx_sf_set, the existing set is
// left untouched — scripts shouldn't be able to deafen a node by passing
// `{}` or a table of invalid entries.
void ScriptedNode::api_set_rx_sf(int sf) {
    if (!_sf_rx_set) return;  // not attached yet (shouldn't happen post-init)
    if (sf < 5) sf = 5;
    if (sf > 12) sf = 12;
    *_sf_rx_set = { sf };
}

void ScriptedNode::api_set_rx_sf_set(sol::table sf_set) {
    if (!_sf_rx_set) return;
    std::vector<int> result;
    for (auto& kv : sf_set) {
        sol::object v = kv.second;
        int sf = -1;
        if      (v.is<int64_t>()) sf = static_cast<int>(v.as<int64_t>());
        else if (v.is<double>())  sf = static_cast<int>(v.as<double>());
        else                       continue;
        if (sf >= 5 && sf <= 12) result.push_back(sf);
    }
    if (!result.empty()) *_sf_rx_set = std::move(result);
}

uint64_t ScriptedNode::api_channel_busy_until() const {
    if (!_lbt) return 0;
    return _lbt->busyUntil(_id);
}

uint64_t ScriptedNode::api_tx_in_flight() const {
    if (!_tx_in_flight_until) return 0;
    return *_tx_in_flight_until;
}
