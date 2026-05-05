#pragma once
#include <cstdint>

// Orchestrator-controlled clock: getMillis()/getCurrentTime() return
// values driven by advanceMillis() rather than wall-time.
//
// Originally derived from MeshCore's SimClock (mesh::MillisecondClock +
// mesh::RTCClock). The base classes are stripped here to keep the
// universal simulator protocol-agnostic; the public API is preserved
// so adapters can wire this into protocol-specific clock interfaces.
class VirtualClock {
    unsigned long _virtual_millis = 0;
    uint32_t _epoch_base;

public:
    explicit VirtualClock(uint32_t epoch_base = 1700000000)
        : _epoch_base(epoch_base) {}

    unsigned long getMillis() { return _virtual_millis; }
    uint32_t getCurrentTime() { return _epoch_base + (uint32_t)(_virtual_millis / 1000); }
    void setCurrentTime(uint32_t epoch) { _epoch_base = epoch - (uint32_t)(_virtual_millis / 1000); }
    void tick() {}

    void advanceMillis(unsigned long delta) { _virtual_millis += delta; }
};
