// test/native/test_eventlog.cpp
//
// Exercises the EventLog NDJSON emit pipeline against a captured ostream.
// The actual API is a free-function namespace (matching meshcore_real_sim's
// EventLog), with setOutputStream() rerouting output away from stdout for
// tests. The plan's illustrative `EventLog log(out); log.logTx(...)` class
// shape was adapted to the real free-function signatures.
#include "core/events/EventLog.h"

#include <cassert>
#include <cstdio>
#include <cstdint>
#include <sstream>
#include <string>

int main() {
    std::ostringstream out;
    EventLog::setOutputStream(&out);

    // Real signatures (from core/events/EventLog.h):
    //   void tx(unsigned long time_ms, const char* node,
    //           const uint8_t* data, int len, uint32_t airtime_ms,
    //           int sf, int bw_hz, int cr,
    //           const char* label = nullptr, const char* info = nullptr);
    //   void rx(unsigned long time_ms, const char* from, const char* to,
    //           float snr, float rssi,
    //           const uint8_t* data, int len, uint32_t airtime_ms,
    //           int sf, int bw_hz, int cr);
    const uint8_t pkt_bytes[] = {0xab, 0xcd};
    EventLog::tx(/*time_ms=*/100, /*node=*/"n0",
                 pkt_bytes, (int)sizeof(pkt_bytes), /*airtime_ms=*/120,
                 /*sf=*/7, /*bw_hz=*/125000, /*cr=*/5);
    EventLog::rx(/*time_ms=*/220, /*from=*/"n0", /*to=*/"n1",
                 /*snr=*/8.0f, /*rssi=*/-80.0f,
                 pkt_bytes, (int)sizeof(pkt_bytes), /*airtime_ms=*/120,
                 /*sf=*/7, /*bw_hz=*/125000, /*cr=*/5);

    EventLog::logScriptLog(/*node_id=*/0, /*sim_ms=*/300, "hello");
    EventLog::logScriptEmit(/*node_id=*/0, /*sim_ms=*/400,
                            /*type=*/"my_event",
                            /*json_data=*/"{\"k\":1}");

    // Restore default stream so we don't leak the local ostringstream.
    EventLog::setOutputStream(nullptr);

    const std::string s = out.str();
    // tx / rx
    assert(s.find("\"type\":\"tx\"") != std::string::npos);
    assert(s.find("\"type\":\"rx\"") != std::string::npos);
    assert(s.find("\"node\":\"n0\"") != std::string::npos);
    assert(s.find("\"from\":\"n0\"") != std::string::npos);
    assert(s.find("\"to\":\"n1\"") != std::string::npos);
    // The hex dump on tx should contain the raw bytes.
    assert(s.find("\"hex\":\"abcd\"") != std::string::npos);
    // RF params on tx/rx
    assert(s.find("\"sf\":7") != std::string::npos);
    assert(s.find("\"bw_hz\":125000") != std::string::npos);
    assert(s.find("\"cr\":5") != std::string::npos);

    // script_log
    assert(s.find("\"type\":\"script_log\"") != std::string::npos);
    assert(s.find("\"msg\":\"hello\"") != std::string::npos);
    assert(s.find("\"node\":0") != std::string::npos);
    assert(s.find("\"time_ms\":300") != std::string::npos);

    // script_emit — `data` must be spliced as JSON, NOT re-stringified.
    assert(s.find("\"type\":\"script_emit\"") != std::string::npos);
    assert(s.find("\"emit_type\":\"my_event\"") != std::string::npos);
    assert(s.find("\"data\":{\"k\":1}") != std::string::npos);
    // Defensive: make sure we did NOT accidentally JSON-encode the payload
    // into a string (i.e. "data":"{\"k\":1}").
    assert(s.find("\"data\":\"{\\\"k\\\":1}\"") == std::string::npos);

    std::printf("test_eventlog: OK\n");
    return 0;
}
