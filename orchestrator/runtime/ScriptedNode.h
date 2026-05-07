// orchestrator/runtime/ScriptedNode.h
//
// Per-node container that owns the timer wheel and pending-tx queue, and
// dispatches the script lifecycle callbacks (on_init / on_recv / on_command /
// on_radio_busy) by going through LuaHost.
//
// Each ScriptedNode also exposes the runtime methods (tx/after/every/cancel/
// now/rand/log/emit/peers) that scripts call as `self:method(...)`. The
// bindings are wired into the per-node Lua `self` table by LuaHost::registerNode
// using a pointer to this object; lambdas capture the pointer by value so the
// orchestrator must guarantee the ScriptedNode outlives the Lua state (the
// natural ownership: LuaHost owns the Lua state and ScriptedNodes are created
// before scripts run and destroyed after).
//
// SimRadio is held by reference but currently used only for parameter lookups
// the scripts may need; actual TX dispatch is deferred — scripts queue a
// PendingTx via api_tx() and the main loop drains it via drainPendingTxs().

#pragma once

#include "core/clock/VirtualClock.h"
#include "core/radio/SimRadio.h"
#include "json/json.hpp"
#include "sol/sol.hpp"
#include "orchestrator/runtime/TimerWheel.h"

#include <cstdint>
#include <ostream>
#include <random>
#include <string>
#include <string_view>
#include <vector>

class LuaHost;

// A TX request queued by a script via self:tx(...). The main loop pops these
// each step and feeds them to SimRadio::startSendRaw() (after applying any
// per-tx parameter overrides).
struct PendingTx {
    std::string bytes;
    int sf = -1;            // -1 = use radio default
    int bw_hz = -1;         // -1 = use radio default (NOTE: Hz, not kHz)
    int cr = -1;            // -1 = use radio default
    int power_dbm = -127;   // -127 = use default
    int preamble_sym = -1;  // -1 = use radio default
    // Optional script-supplied annotations stamped on the tx event NDJSON.
    // Empty = not set; visualizers should treat the tx as unlabelled.
    // The simulator never decodes packet bytes itself (it can't, the wire
    // format is up to the script), so these are how scripts expose their
    // own protocol semantics to the timeline / map views.
    std::string label;      // short tag, e.g., "RTS", "CTS", "DATA"
    std::string info;       // detail string, e.g., "dst=dave via bob msg=1"
};

// Reason + context bundle passed to on_radio_busy(self, info) in Lua. Built
// by SimController at the deferral site so the script knows which packet was
// dropped, why, and how long the obstacle is expected to last. Renamed the
// PendingTx-annotation field to `tx_info` to avoid info.info on the Lua side.
struct RadioBusyInfo {
    std::string reason;        // "channel_busy" | "self_tx_in_flight"
    int         len      = 0;  // bytes of the deferred PendingTx
    int         sf       = -1; // SF the deferred TX would have used
    std::string label;         // PendingTx::label, echoed back
    std::string tx_info;       // PendingTx::info, echoed back (renamed for Lua)
    uint64_t    busy_until_ms = 0;  // absolute simtime when free
};

class ScriptedNode {
public:
    ScriptedNode(int id, std::string name,
                 LuaHost& host, SimRadio& radio, std::ostream& events_out,
                 VirtualClock& clock, std::mt19937& sim_rng);

    // Lifecycle: dispatched through LuaHost.
    void onInit(const nlohmann::json& config);
    void onRecv(std::string_view bytes, float snr, float rssi,
                int link_id, uint64_t sim_ms);
    std::string onCommand(std::string_view cmd_str);
    void onRadioBusy(const RadioBusyInfo& info);

    // Called by the main loop each step:
    void tickTimers(uint64_t sim_ms);
    std::vector<PendingTx> drainPendingTxs();   // moves out + clears

    // ---- self:* runtime methods (bound from LuaHost::registerNode) -------
    void     api_tx(std::string bytes, sol::optional<sol::table> opts);
    uint64_t api_after(uint64_t delay_ms, sol::function fn);
    uint64_t api_every(uint64_t period_ms, sol::function fn);
    void     api_cancel(uint64_t handle);
    uint64_t api_now() const;
    int      api_rand(int lo, int hi);
    void     api_log(sol::variadic_args args);
    void     api_emit(std::string type, sol::optional<sol::table> data);
    sol::table api_peers();
    void     api_set_rx_sf(int sf);                      // single-SF retune
    void     api_set_rx_sf_set(sol::table sf_set);       // multi-SF retune (opt-in)
    uint64_t api_channel_busy_until() const;             // LBT busy_until or 0
    uint64_t api_tx_in_flight() const;                   // own pending TX end_ms or 0

    int                id()   const { return _id; }
    const std::string& name() const { return _name; }

    // Set by SimController after onInit returns (whether at t=0 or via
    // jitter-staged timer). Once true, onRecv / onCommand / onRadioBusy
    // dispatch through to the script.
    void markInitialized()  { _initialized = true; }
    bool isInitialized() const { return _initialized; }

    // Called by SimController during init to point this node at its slot in
    // SimController::_node_sf_rx_set. The pointed-to vector is stable for the
    // lifetime of the controller (the outer vector is sized once via
    // assign(n, {}) and never reallocates).
    void attachSfRxSet(std::vector<int>* slot) { _sf_rx_set = slot; }

    // Per-node slot updated by SimController: set to the TX end_ms when an
    // InFlight is pushed for this sender, cleared to 0 when the InFlight is
    // compacted out. Read by api_tx_in_flight (no allocation, no scan).
    void attachTxInFlightSlot(uint64_t* slot) { _tx_in_flight_until = slot; }

    // Pointer to the LbtModel owned by SimController. Borrowed; SimController
    // outlives ScriptedNode. Used by api_channel_busy_until.
    void attachLbtModel(class LbtModel* lbt) { _lbt = lbt; }

private:
    int               _id;
    std::string       _name;
    LuaHost&          _host;
    SimRadio&         _radio;
    std::ostream&     _events_out;     // borrowed; lifetime owned by orchestrator
    VirtualClock&     _clock;
    std::mt19937&     _sim_rng;
    TimerWheel        _timers;
    std::vector<PendingTx> _pending_txs;
    // Set true once on_init has fired. Models real-hardware boot — until
    // the script has finished its init, the radio is "off" so onRecv
    // (and the on_command / on_radio_busy callbacks) are dropped silently.
    // Toggled by SimController via markInitialized() when the staged
    // on_init returns. Default false so jitter-staged nodes start dark.
    bool              _initialized = false;
    std::vector<int>* _sf_rx_set = nullptr;  // borrowed; set via attachSfRxSet
    uint64_t*         _tx_in_flight_until = nullptr;  // borrowed; SimController owns
    class LbtModel*   _lbt = nullptr;                  // borrowed; SimController owns
    // Note: timer callbacks are stored Lua-side under _LUS.nodes[id].timers[handle].
    // We don't keep them in C++ to avoid double-bookkeeping.
};
