#pragma once

#include "core/clock/VirtualClock.h"

#include <queue>
#include <vector>
#include <cstdint>
#include <functional>

// Incoming packet entry queued by the orchestrator after delivery checks.
// `enqueue()` pushes one; `recvRaw()` pops the front.
struct IncomingPacket {
    std::vector<uint8_t> data;
    float snr;
    float rssi;
};

// TX-side delivery callback: invoked by startSendRaw() on a successful
// transmit start. The orchestrator wires this to its delivery pipeline
// (collision check → enqueue on receivers).
//
//   data       — raw on-air bytes
//   len        — byte count
//   airtime_ms — pure RF airtime (no PA-ramp / settling delay)
using TxCallback = std::function<void(const uint8_t* data, int len, uint32_t airtime_ms)>;

// SimRadio — half-duplex LoRa physical-layer model.
//
// Originally derived from meshcore_real_sim/shims/platform_shim/SimRadio.
// In the source it inherited from `mesh::Radio` and consumed
// `mesh::MillisecondClock`. Both base-class couplings are stripped here:
// SimRadio is now a free-standing class that takes a `VirtualClock&`,
// keeping the universal simulator protocol-agnostic. Adapters can layer
// a `mesh::Radio`-flavored shim on top if a MeshCore build needs it.
//
// What's modeled:
//   - LoRa airtime (Semtech AN1200.13)
//   - Half-duplex: notifyRxStart() arms an "RX active" window during
//     which isReceiving() returns true and a concurrent TX would be
//     considered a collision by the orchestrator.
//   - LBT / preamble-delayed channel-busy windows
//   - SX1262-style hardware turnaround delays (RX→TX, TX→RX)
//   - Optional TX-failure injection (xorshift32 RNG)
//
// What was dropped from the source:
//   - The stdout JSON `{"type":"tx",...}` path (MeshCore standalone build).
//     Orchestrator integration uses TxCallback exclusively.
//   - `override` annotations on methods that were virtuals in mesh::Radio.
class SimRadio {
public:
    enum class RadioState : uint8_t {
        IDLE,      // Standby — not listening, not transmitting
        RX,        // Continuous receive mode
        TX_WAIT,   // Transmitting, waiting for completion
    };

    SimRadio(VirtualClock& clock,
             int sf = 8, int bw_hz = 62500, int cr = 1,
             float rx_to_tx_delay_ms = 1.0f,
             float tx_to_rx_delay_ms = 5.0f);

    // ---- LoRa parameters ------------------------------------------------
    void setRadioParams(int sf, int bw_hz, int cr);

    int    getSF() const { return _sf; }
    int    getBwHz() const { return _bw_hz; }
    int    getCR() const { return _cr; }
    double getSymbolMs() const { return (double)(1 << _sf) / (_bw_hz / 1000.0); }
    int    getPreambleSymbols() const { return _preamble_len; }
    double getPreambleMs() const { return (getPreambleSymbols() + 4.25) * getSymbolMs(); }

    uint32_t getEstAirtimeFor(int len_bytes);
    float    getSnrThreshold() const;
    float    packetScore(float snr, int packet_len);

    // ---- Half-duplex / LBT bookkeeping ----------------------------------
    void notifyRxStart(uint32_t duration_ms);
    void notifyChannelBusy(unsigned long from_ms, unsigned long until_ms);
    uint32_t getPreambleDetectMs() const;
    void resetHardwareDelays();
    bool isReceiving();
    bool isInRecvMode() const { return _state == RadioState::RX; }

    // ---- Incoming packet queue (orchestrator → radio) -------------------
    void enqueue(const uint8_t* data, int len, float snr, float rssi);
    int  recvRaw(uint8_t* bytes, int sz);

    // ---- TX path --------------------------------------------------------
    bool startSendRaw(const uint8_t* bytes, int len);
    bool isSendComplete();
    void onSendFinished();

    // ---- Last-RX metrics ------------------------------------------------
    float getLastSNR()  const { return _last_snr;  }
    float getLastRSSI() const { return _last_rssi; }

    // ---- Stats ----------------------------------------------------------
    uint32_t getPacketsRecv() const { return _packets_recv; }
    uint32_t getPacketsSent() const { return _packets_sent; }
    uint32_t getPacketsRecvErrors() const { return _packets_recv_errors; }
    void resetStats() { _packets_recv = _packets_sent = _packets_recv_errors = 0; }

    // ---- TX failure injection (models SPI/HW errors) --------------------
    void setTxFailProb(float p) { _tx_fail_prob = p; }
    void seed(uint64_t s) { _rng_state = static_cast<uint32_t>(s) | 1u; } // ensure non-zero
    uint32_t getTxFailCount() const { return _tx_fail_count_stat; }

    // ---- Rx boosted gain mode (no-op in simulator) ----------------------
    void setRxBoostedGainMode(bool enable) { _rx_boosted_gain = enable; }
    bool getRxBoostedGainMode() const { return _rx_boosted_gain; }

    // ---- Orchestrator hookup --------------------------------------------
    void setTxCallback(TxCallback cb) { _tx_callback = std::move(cb); }

private:
    VirtualClock& _clock;

    // RX queue
    std::queue<IncomingPacket> _rx_queue;
    float _last_snr   = 0.0f;
    float _last_rssi  = -100.0f;

    RadioState _state = RadioState::RX;  // Radio starts in receive mode
    unsigned long _rx_active_until = 0;

    // LBT: channel activity windows (preamble detection delay)
    struct LbtWindow {
        unsigned long from_ms;
        unsigned long until_ms;
    };
    std::vector<LbtWindow> _lbt_windows;

    // LoRa parameters
    int _sf;
    int _bw_hz;
    int _cr;
    int _preamble_len = 16;  // MeshCore configures SX1262 with preambleLength=16

    // Hardware turnaround delays (configured per simulation)
    float _rx_to_tx_delay_ms;
    float _tx_to_rx_delay_ms;

    // Hardware readiness tracking
    uint32_t _earliest_tx_ms;   // Cannot start TX before this time
    uint32_t _earliest_rx_ms;   // Cannot return to RX before this time

    unsigned long _tx_done_at = 0;

    // Packet counters
    uint32_t _packets_recv = 0;
    uint32_t _packets_sent = 0;
    uint32_t _packets_recv_errors = 0;

    // TX failure simulation (xorshift32)
    float _tx_fail_prob = 0.0f;
    uint32_t _rng_state = 1;
    uint32_t _tx_fail_count_stat = 0;

    // Rx boosted gain mode (no-op in simulator)
    bool _rx_boosted_gain = false;

    TxCallback _tx_callback;
};
