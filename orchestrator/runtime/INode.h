// orchestrator/runtime/INode.h
//
// Abstract node interface that SimController drives each step. INode declares
// EXACTLY the surface SimController calls on a node — the dispatch callbacks
// (on_init / on_recv / on_command / on_radio_busy / on_preamble_detected), the
// per-step tick + tx drain, the lifecycle gate, identity, the one-time wiring
// setters, and the radio-state / duty-cycle queries.
//
// ScriptedNode (Lua-backed) is the current sole implementation. A FirmwareNode
// that runs the MeshRoute C++ firmware in-loop will be added later (MeshRoute
// port, sim-integration track — see ~/MeshRoute/docs/PORT_PLAN.md §2.1).
//
// NOTE: the self:* runtime methods scripts call (api_tx / api_after / api_rand
// / ...) are NOT part of this interface — they are Lua-binding-specific and
// stay private to ScriptedNode. SimController never calls them.

#pragma once

#include "json/json.hpp"

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

class LbtModel;

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
    uint16_t    tag = 0;    // R4.5b opaque frame-type token (firmware-set); echoed in RadioBusyInfo for heap-free retry match
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
    uint16_t    tag = 0;       // R4.5b PendingTx::tag, echoed back (firmware heap-free retry match)
};

class INode {
public:
    virtual ~INode() = default;

    // ---- dispatch (host -> node logic) ---------------------------------
    virtual void onInit(const nlohmann::json& config) = 0;
    virtual void onRecv(std::string_view bytes, float snr, float rssi,
                        int link_id, int src_id, uint64_t sim_ms) = 0;
    virtual std::string onCommand(std::string_view cmd_str) = 0;
    virtual void onRadioBusy(const RadioBusyInfo& info) = 0;
    virtual void onPreambleDetected(uint64_t time_ms, int from_id,
                                    float snr_db) = 0;

    // ---- per-step ------------------------------------------------------
    virtual void tickTimers(uint64_t sim_ms) = 0;
    virtual std::vector<PendingTx> drainPendingTxs() = 0;   // moves out + clears

    // ---- lifecycle gate ------------------------------------------------
    virtual void markInitialized() = 0;
    virtual bool isInitialized() const = 0;

    // ---- identity ------------------------------------------------------
    virtual int  protocolId() const = 0;
    virtual void setProtocolId(int protocol_id) = 0;
    virtual const std::string& name() const = 0;

    // ---- one-time wiring set by SimController::initialize() -------------
    virtual void attachSfRxSet(std::vector<int>* slot) = 0;
    // Live per-node RX BANDWIDTH slot (Hz), the BW twin of attachSfRxSet.
    // Seeded by SimController from nodes[i].bw and moved by a runtime retune
    // (Hal::set_rx_bw -> ISimHal::simSetRxBw / self:set_rx_bw), so the
    // delivery path can reject frames whose BW the modem isn't tuned to.
    virtual void attachRxBwSlot(int* slot) = 0;
    virtual void attachTxInFlightSlot(uint64_t* slot) = 0;
    virtual void attachLbtModel(LbtModel* lbt) = 0;
    virtual void setClockDriftPpm(float ppm) = 0;
    virtual void setSfSwitchDelayMs(float ms) = 0;

    // ---- radio-state / duty-cycle queried by the per-step pipeline -----
    virtual void     recordTxAirtime(uint64_t end_ms, uint32_t airtime_ms) = 0;
    virtual uint64_t airtimeUsedInWindow(uint64_t now, uint64_t window_ms) = 0;
    virtual uint64_t oldestTxEndMs() const = 0;
    virtual uint64_t rxBlindUntilMs() const = 0;

    // Whether the sim's Listen-Before-Talk defer applies to this node. Default
    // true (real-hardware behaviour); a FirmwareNode may disable it via the
    // "lbt_enabled" host config so the R3.x lossy gate runs without an LBT
    // backoff perturbing the firmware's rand stream. Non-pure so ScriptedNode
    // and any future node inherit the true default unchanged.
    virtual bool lbtEnabled() const { return true; }
};
