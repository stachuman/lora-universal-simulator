// orchestrator/runtime/ScriptedNode.h
//
// ★★ DEPRECATED + UNSUPPORTED (2026-07-25 ruling) — the Lua engine.
// ScriptedNode is the Lua half of the simulator. The Lua engine is DEPRECATED
// and UNSUPPORTED: it is far behind the MeshRoute firmware and no longer tracks
// it. It is RETAINED, deliberately, as the FROZEN PARITY REFERENCE the C++ port
// was validated against (scenarios/dv_dual_sf.lua) — deleting it would destroy
// that historical record. Do not add features here, and do not "fix" it to match
// current firmware behaviour.
// Nodes now default to engine "meshroute"; a node resolving to engine "lua" is
// REFUSED at SimController::initialize() unless the run opts in via
// simulation.allow_deprecated_lua / `lus --allow-deprecated-lua`.
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
// SimRadio is held by reference for parameter lookups the scripts may need and
// for the api_set_rx_bw retune (which moves the radio's default TX bandwidth,
// mirroring the device's _def_bw); actual TX dispatch is deferred — scripts
// queue a PendingTx via api_tx() and the main loop drains it via
// drainPendingTxs().

#pragma once

#include "core/clock/VirtualClock.h"
#include "core/radio/SimRadio.h"
#include "json/json.hpp"
#include "sol/sol.hpp"
#include "orchestrator/runtime/INode.h"
#include "orchestrator/runtime/TimerWheel.h"

#include <cstdint>
#include <deque>
#include <ostream>
#include <random>
#include <string>
#include <string_view>
#include <vector>

class LuaHost;

// PendingTx and RadioBusyInfo moved to INode.h — they are part of the
// host<->node contract shared by every INode implementation, not Lua-specific.

class ScriptedNode : public INode {
public:
    ScriptedNode(int id, std::string name,
                 LuaHost& host, SimRadio& radio, std::ostream& events_out,
                 VirtualClock& clock, std::mt19937& sim_rng);

    // Lifecycle: dispatched through LuaHost.
    void onInit(const nlohmann::json& config) override;
    void onRecv(std::string_view bytes, float snr, float rssi,
                int link_id, int src_id, uint64_t sim_ms) override;
    std::string onCommand(std::string_view cmd_str) override;
    void onRadioBusy(const RadioBusyInfo& info) override;
    // Mirrors the SX1262 PreambleDetected IRQ: fires when a TX would start
    // arriving at this receiver while it's tuned to a matching SF, AND the
    // CAD model decides the radio would have detected the preamble at this
    // SNR (probabilistic per cad_miss_prob / cad_reliable_snr / cad_marginal_snr).
    // Fires regardless of whether the rest of the packet decodes — so the
    // signal stays valid even when per-packet shadow variance pushes
    // individual frames below the demod floor. `from_id` and `snr_db` are
    // optional debug context; `time_ms` is the TX start (preamble-arrival)
    // timestamp.
    void onPreambleDetected(uint64_t time_ms, int from_id, float snr_db) override;

    // Called by the main loop each step:
    void tickTimers(uint64_t sim_ms) override;
    std::vector<PendingTx> drainPendingTxs() override;   // moves out + clears

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
    void     api_set_protocol_id(int protocol_id);
    void     api_set_rx_sf(int sf);                      // single-SF retune
    void     api_set_rx_sf_set(sol::table sf_set);       // multi-SF retune (opt-in)
    void     api_set_rx_bw(int bw_hz);                   // RX-bandwidth retune (Hz)
    uint64_t api_channel_busy_until() const;             // LBT busy_until or 0
    uint64_t api_tx_in_flight() const;                   // own pending TX end_ms or 0
    // Sum of TX airtime in the last `window_ms` ms. Used by scripts that
    // self-regulate against duty-cycle limits. 0 if window_ms <= 0.
    uint64_t api_airtime_used_ms(uint64_t window_ms) const;
    // end_ms of the oldest currently-in-window TX log entry, or 0 if no
    // entries exist. Lets Lua compute exact wait time before headroom is
    // freed (oldest_end_ms + window_ms is when it falls out of the window).
    uint64_t api_oldest_tx_end_ms() const { return oldestTxEndMs(); }
    // SimController calls this to record a completed TX dispatch in the
    // per-node sliding-window log. Called immediately after the TX is
    // pushed to the InFlight queue (so end_ms is the canonical TX end time).
    void recordTxAirtime(uint64_t end_ms, uint32_t airtime_ms) override;
    // Helper for the runtime's own duty-cycle hard-block check. Returns
    // current sum airtime within `window_ms` ending at `now`. Prunes
    // expired entries as a side effect.
    uint64_t airtimeUsedInWindow(uint64_t now, uint64_t window_ms) override;
    // Earliest end_ms of any entry currently in the log (post-prune).
    // 0 if log is empty. Used by the runtime to compute when a deferred
    // duty-cycle-blocked TX could earliest fit.
    uint64_t oldestTxEndMs() const override;

    int                id()   const { return _id; }
    int                protocolId() const override { return _protocol_id; }
    void               setProtocolId(int protocol_id) override { _protocol_id = protocol_id; }
    const std::string& name() const override { return _name; }

    // Set by SimController after onInit returns (whether at t=0 or via
    // jitter-staged timer). Once true, onRecv / onCommand / onRadioBusy
    // dispatch through to the script.
    void markInitialized() override { _initialized = true; }
    bool isInitialized() const override { return _initialized; }

    // Called by SimController during init to point this node at its slot in
    // SimController::_node_sf_rx_set. The pointed-to vector is stable for the
    // lifetime of the controller (the outer vector is sized once via
    // assign(n, {}) and never reallocates).
    void attachSfRxSet(std::vector<int>* slot) override { _sf_rx_set = slot; }

    // Live RX-bandwidth slot in SimController::_node_rx_bw_hz — the BW twin
    // of attachSfRxSet, same stable-pointer discipline.
    void attachRxBwSlot(int* slot) override { _rx_bw_hz = slot; }

    // Per-node slot updated by SimController: set to the TX end_ms when an
    // InFlight is pushed for this sender, cleared to 0 when the InFlight is
    // compacted out. Read by api_tx_in_flight (no allocation, no scan).
    void attachTxInFlightSlot(uint64_t* slot) override { _tx_in_flight_until = slot; }

    // Pointer to the LbtModel owned by SimController. Borrowed; SimController
    // outlives ScriptedNode. Used by api_channel_busy_until.
    void attachLbtModel(LbtModel* lbt) override { _lbt = lbt; }

    // Per-node crystal drift in ppm (signed). Set once at init by
    // SimController. ScriptedNode::api_now scales wall time by
    // (1 + drift_ppm * 1e-6); api_after divides the requested delay by
    // the same factor so a "100 ms in node-time" timer fires at
    // 100 / (1 + drift) ms in wall-time, matching the protocol's
    // intent under a skewed clock.
    void setClockDriftPpm(float ppm) override { _clock_drift_ppm = ppm; }
    float clockDriftPpm() const { return _clock_drift_ppm; }

    // SF-retune settling window in ms. Set by SimController at init from
    // simulation.radio.sf_switch_delay_ms. When the script calls
    // self:set_rx_sf(...), the radio is "blind" for this duration and
    // any frame whose preamble arrives during the window is dropped
    // (drop_rx_blind). 0 disables.
    void setSfSwitchDelayMs(float ms) override { _sf_switch_delay_ms = ms; }
    float sfSwitchDelayMs() const { return _sf_switch_delay_ms; }

    // Mark the receiver as "blind" for the SF-switch settling window.
    // Frames whose start_ms lands inside [now, now + sf_switch_delay_ms)
    // are dropped (drop_sf_switching). Set by api_set_rx_sf and
    // api_set_rx_sf_set; consulted in deliverReceptionsForStep.
    void setRxBlindUntil(uint64_t until_ms) { _rx_blind_until_ms = until_ms; }
    uint64_t rxBlindUntilMs() const override { return _rx_blind_until_ms; }

private:
    void armSfSwitchBlindWindow();
    int               _id;
    int               _protocol_id = -1;
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
    int*              _rx_bw_hz  = nullptr;  // borrowed; set via attachRxBwSlot
    uint64_t*         _tx_in_flight_until = nullptr;  // borrowed; SimController owns
    class LbtModel*   _lbt = nullptr;                  // borrowed; SimController owns
    float             _clock_drift_ppm = 0.0f;         // set by SimController at init
    uint64_t          _rx_blind_until_ms = 0;          // SF-switch settling window
    float             _sf_switch_delay_ms = 0.0f;      // ms added by api_set_rx_sf
    // Sliding-window TX airtime log for duty-cycle accounting. Each entry
    // is (end_ms, airtime_ms). Pruned lazily on read. Bounded in size by
    // the duty-cycle window (1h default = 36 s of cumulative airtime
    // ÷ shortest TX ≈ a few thousand entries worst case — fine).
    struct TxAirtimeRec { uint64_t end_ms; uint32_t airtime_ms; };
    mutable std::deque<TxAirtimeRec> _tx_airtime_log;
    // Note: timer callbacks are stored Lua-side under _LUS.nodes[id].timers[handle].
    // We don't keep them in C++ to avoid double-bookkeeping.
};
