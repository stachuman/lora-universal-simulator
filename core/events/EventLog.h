#pragma once

#include "json/json.hpp"

#include <cstdio>
#include <cstdint>
#include <ostream>
#include <string>
#include <functional>
#include <vector>

// NDJSON event logger — writes one JSON object per line to the configured
// output stream (defaults to stdout).
//
// Originally derived from meshcore_real_sim/orchestrator/EventLog. The
// MeshCore-specific packet-header decoding (advert/req/ack/etc. payload
// type labels, route-type labels) and the adversarial event helpers
// have been stripped to keep the universal simulator protocol-agnostic.
// Adapters can layer protocol-specific fields on top by emitting their
// own NDJSON lines through setOutputStream().
namespace EventLog {

// Compute 8-char hex packet fingerprint (FNV-1a hash) — protocol-agnostic
// helper, useful for correlating tx/rx of the same byte buffer.
void packetHashHex(char out[9], const uint8_t* data, int len);
uint32_t packetHash(const uint8_t* data, int len);

// Output routing. Pass nullptr to revert to stdout (the default).
// The stream is borrowed; the caller owns its lifetime.
void setOutputStream(std::ostream* os);

// Event hook: if set, called with the raw NDJSON line for every event.
using EventHook = std::function<void(const std::string&)>;
void setEventHook(EventHook hook);

// --- core simulator lifecycle / link events ----------------------------

void simStart(unsigned long time_ms, int n_nodes, int step_ms,
              unsigned long warmup_ms = 0, bool hot_start = false);
void simEnd(unsigned long time_ms);

void nodeReady(unsigned long time_ms, const char* node, const char* role,
               const uint8_t* pub_key, int key_len,
               bool has_location = false, double lat = 0.0, double lon = 0.0,
               const char* firmware = nullptr);

// Generic radio events. `data` is the raw on-air bytes; the logger only
// uses them for the FNV fingerprint and an optional hex dump (tx only).
// `label` and `info` are optional script-supplied annotations (passed via
// self:tx({label=, info=}) in Lua). When non-null and non-empty they are
// emitted as fields in the NDJSON. The simulator never decodes packet
// bytes; these strings are how scripts expose protocol semantics.
void tx(unsigned long time_ms, const char* node,
        const uint8_t* data, int len, uint32_t airtime_ms,
        const char* label = nullptr, const char* info = nullptr);
void rx(unsigned long time_ms, const char* from, const char* to,
        float snr, float rssi,
        const uint8_t* data, int len, uint32_t airtime_ms = 0);

void collision(unsigned long time_ms, const char* from, const char* to,
               float snr, float rssi,
               const uint8_t* data, int len,
               const char* interferer = nullptr,
               float interferer_snr = 0.0f,
               float snr_margin = 0.0f);
void dropHalfDuplex(unsigned long time_ms, const char* from, const char* to,
                    const uint8_t* data, int len, uint32_t airtime_ms = 0);
void dropWeak(unsigned long time_ms, const char* from, const char* to,
              float snr, float threshold,
              const uint8_t* data, int len);
void dropLoss(unsigned long time_ms, const char* from, const char* to,
              float loss_prob,
              const uint8_t* data, int len);

// SF mismatch — receiver isn't tuned to the packet's spreading factor
// (single-SF LoRa hardware). `rx_sf` is the receiver's currently
// configured SF when its sf_rx_set has exactly one entry, or -1 to
// flag "scanner / multi-SF" receivers.
void dropSfMismatch(unsigned long time_ms, const char* from, const char* to,
                    int packet_sf, int rx_sf,
                    const uint8_t* data, int len);

// TX failure events
void txFail(unsigned long time_ms, const char* node, uint32_t count);

// Listen-Before-Talk: a node tried to transmit but the channel was busy
// (per LbtModel::isChannelBusy). The pending TX is dropped and the script
// is notified via on_radio_busy; retry policy is left to the script.
void txDeferred(unsigned long time_ms, const char* node,
                int len, const char* reason);

// Command/reply round-trip (e.g. orchestrator → node CLI)
void cmdReply(unsigned long time_ms, const char* node,
              const char* command, const char* reply);

// Per-node stats (post-simulation). `json_data` is already-serialized JSON
// text and is spliced verbatim into the `data` field.
void nodeStats(unsigned long time_ms, const char* node,
               const char* stats_type, const char* json_data);

// Lua callback event
void luaCallback(unsigned long time_ms, const char* fn_name);

// --- script-side events (new in lora-universal-simulator) --------------

// Free-text log line emitted by a node-side script.
void logScriptLog(int node_id, uint64_t sim_ms, const std::string& msg);

// Custom script-emitted event. `json_data` is already-serialized JSON
// text (object or value); it is spliced verbatim into the `data` field.
void logScriptEmit(int node_id, uint64_t sim_ms,
                   const std::string& type, const std::string& json_data);

// --- in-memory buffer (for ExpectRunner / test harnesses) --------------
//
// When the buffer is enabled, every emitted event is also captured (parsed
// back into an `nlohmann::json` value) into an internal vector accessible
// via events(). The runtime simulator (Loop.cpp) calls enableBuffer() +
// clearBuffer() at the start of each run and feeds the resulting buffer
// into ExpectRunner at the end.
//
// The buffer is independent of setOutputStream(); you can have both, or
// either alone. Disabled by default to avoid any cost in non-test usage.
void enableBuffer();
void disableBuffer();
void clearBuffer();
const std::vector<nlohmann::json>& events();

} // namespace EventLog
