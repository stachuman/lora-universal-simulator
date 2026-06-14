// orchestrator/runtime/INodeRuntime.h
//
// Slice 5 (faithful two-lib): a NAMESPACE-NEUTRAL handle to a firmware Node, so FirmwareNode can drive
// EITHER a meshroute::Node (normal lib) or a meshroute_gw::Node (gateway lib) without naming either type.
//
// The boundary is deliberately JSON/string/primitive so NO firmware struct (NodeConfig, Command, CmdResult,
// Push, RxMeta, BusyInfo) crosses it: the per-variant wrapper TU does the JSON->NodeConfig build, the
// command-string parse + ack format, the RxMeta/BusyInfo construction, and the push->telemetry drain — all
// in its own namespace. Each lib exports a distinct factory; FirmwareNode picks per scenario node.
#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <string_view>

#include "json/json.hpp"   // vendored amalgamated nlohmann (third_party/json/json.hpp); defines nlohmann::json

namespace mrsim {

class ISimHal;

class INodeRuntime {
public:
    virtual ~INodeRuntime() = default;

    // Build the per-namespace NodeConfig from the scenario JSON + Node::on_init. false = config REFUSED (a bad
    // dual-layer gateway config, §3.2) — FirmwareNode surfaces it.
    virtual bool onInit(const nlohmann::json& config) = 0;

    // Inbound frame. The wrapper builds NS::RxMeta{snr_db, rssi_dbm, recv_ms, src_hint} + Node::on_recv.
    virtual void onRecv(const uint8_t* bytes, size_t len,
                        float snr_db, float rssi_dbm, int16_t src_hint, uint64_t recv_ms) = 0;

    virtual void onTimer(uint32_t timer_id) = 0;

    // App command (console line). The wrapper parses it -> NS::Command, runs Node::on_command, formats the ack
    // JSON. Returns the ack line (or empty for the streamed commands the wrapper handles itself).
    virtual std::string onCommand(std::string_view cmd) = 0;

    // SX1262 preamble-detect IRQ equivalent (the wrapper forwards the time to Node::on_preamble_detected).
    virtual void onPreambleDetected(uint64_t time_ms, int from_id, float snr_db) = 0;

    // Radio refused our TX. The wrapper maps reason -> NS::BusyReason + builds NS::BusyInfo for Node::on_radio_busy.
    virtual void onRadioBusy(const char* reason, uint16_t tag, int16_t sf, uint64_t busy_until_ms) = 0;

    // Drain the Node's async push ring; each push is formatted to one NDJSON line (per-namespace) + handed to
    // `sink` (FirmwareNode logs it). Keeps the firmware Push struct off the boundary.
    using PushSink = std::function<void(std::string_view ndjson_line)>;
    virtual void drainPushes(const PushSink& sink) = 0;
};

// Each lib exports its OWN factory symbol (ODR-distinct); FirmwareNode binds the variant the scenario asks for.
// Defined in the per-variant wrapper TU compiled into meshroute_core_{normal,gw}.
INodeRuntime* makeNodeRuntimeNormal(int id, const char* name, uint32_t key_hash32, ISimHal& hal);
INodeRuntime* makeNodeRuntimeGw    (int id, const char* name, uint32_t key_hash32, ISimHal& hal);

}  // namespace mrsim
