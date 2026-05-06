#include "core/radio/SimRadio.h"

#include <stdio.h>
#include <string.h>
#include <algorithm>
#include <cmath>

SimRadio::SimRadio(VirtualClock& clock, int sf, int bw_hz, int cr,
                   float rx_to_tx_delay_ms, float tx_to_rx_delay_ms)
    // Init-list order must match declaration order in SimRadio.h.
    : _clock(clock),
      _sf(sf), _bw_hz(bw_hz), _cr(cr),
      _rx_to_tx_delay_ms(rx_to_tx_delay_ms), _tx_to_rx_delay_ms(tx_to_rx_delay_ms),
      _earliest_tx_ms(0), _earliest_rx_ms(0)
{
    if (_bw_hz <= 0) {
        fprintf(stderr, "SimRadio: bw_hz=%d invalid, defaulting to 125000\n", _bw_hz);
        _bw_hz = 125000;
    }
    if (_sf < 7 || _sf > 12) {
        fprintf(stderr, "SimRadio: sf=%d out of range [7,12], clamping\n", _sf);
        _sf = (_sf < 7) ? 7 : 12;
    }
}

void SimRadio::setPreambleSymbols(int n) {
    // LoRa preamble must be >= 6 symbols (Semtech datasheet) and the SX1262
    // register is 16 bits wide. Clamp rather than reject so per-tx overrides
    // from scripts can never desync the airtime calculation.
    if (n < 6) n = 6;
    if (n > 65535) n = 65535;
    _preamble_len = n;
}

void SimRadio::setRadioParams(int sf, int bw_hz, int cr) {
    if (bw_hz <= 0) {
        fprintf(stderr, "SimRadio::setRadioParams: bw_hz=%d invalid, ignoring\n", bw_hz);
    } else {
        _bw_hz = bw_hz;
    }
    if (sf < 7 || sf > 12) {
        fprintf(stderr, "SimRadio::setRadioParams: sf=%d out of range [7,12], clamping\n", sf);
        _sf = (sf < 7) ? 7 : 12;
    } else {
        _sf = sf;
    }
    _cr = cr;
}

void SimRadio::notifyRxStart(uint32_t duration_ms) {
    unsigned long now = _clock.getMillis();
    unsigned long new_until = now + duration_ms;

    if (new_until > _rx_active_until) {
        _rx_active_until = new_until;
        // After active RX, need settling time before TX
        _earliest_tx_ms = new_until + (uint32_t)_rx_to_tx_delay_ms;
    }
}

void SimRadio::notifyChannelBusy(unsigned long from_ms, unsigned long until_ms) {
    // Radio can only detect preambles that are ACTIVE when it becomes ready
    unsigned long detection_start = std::max(from_ms, (unsigned long)_earliest_rx_ms);

    if (detection_start >= until_ms) {
        // Preamble ended before radio became ready - cannot detect
        return;
    }

    // Preamble is active when radio ready - store adjusted window
    _lbt_windows.push_back({detection_start, until_ms});
}

uint32_t SimRadio::getPreambleDetectMs() const {
    return (uint32_t)(6.0 * getSymbolMs());
}

void SimRadio::resetHardwareDelays() {
    _earliest_tx_ms = 0;
    _earliest_rx_ms = 0;
}

bool SimRadio::isReceiving() {
    if (_state == RadioState::TX_WAIT) return false;
    unsigned long now = _clock.getMillis();
    if (now < _rx_active_until) return true;

    // Check LBT windows (preamble-delayed channel activity)
    bool busy = false;
    auto it = _lbt_windows.begin();
    while (it != _lbt_windows.end()) {
        if (now >= it->until_ms) {
            it = _lbt_windows.erase(it);  // expired, clean up
        } else {
            if (now >= it->from_ms) busy = true;
            ++it;
        }
    }
    if (busy) return true;

    return !_rx_queue.empty();
}

void SimRadio::enqueue(const uint8_t* data, int len, float snr, float rssi) {
    IncomingPacket pkt;
    pkt.data.assign(data, data + len);
    pkt.snr  = snr;
    pkt.rssi = rssi;
    _rx_queue.push(std::move(pkt));
}

int SimRadio::recvRaw(uint8_t* bytes, int sz) {
    if (!_rx_queue.empty()) {
        // Step 1: Read packet (RadioLib: state = STATE_IDLE after read)
        IncomingPacket& front = _rx_queue.front();
        int len = (int)std::min((size_t)sz, front.data.size());
        memcpy(bytes, front.data.data(), len);
        _last_snr  = front.snr;
        _last_rssi = front.rssi;
        _rx_queue.pop();
        _packets_recv++;
        // Step 2: Restart RX (RadioLib: startRecv() → STATE_RX)
        _state = RadioState::RX;
        return len;
    }
    // No packet — ensure RX mode (RadioLib: if state != STATE_RX → startRecv)
    if (_state != RadioState::TX_WAIT) {
        _state = RadioState::RX;
    }
    return 0;
}

uint32_t SimRadio::getEstAirtimeFor(int len_bytes) {
    // Semtech AN1200.13 -- LoRa on-air time in milliseconds.
    double t_sym = getSymbolMs();
    double t_pre = (_preamble_len + 4.25) * t_sym;

    int de = (t_sym >= 16.0) ? 1 : 0;
    double num = 8.0 * len_bytes - 4.0 * _sf + 44;
    double den = 4.0 * (_sf - 2 * de);
    int pay_sym = 8 + (int)std::max(std::ceil(num / den) * (_cr + 4), 0.0);

    return (uint32_t)(t_pre + pay_sym * t_sym);
}

// Multi-SF reception: a single-channel LoRa receiver dynamically tunes its
// SF on each incoming preamble. The receiver's _sf only constrains what it
// transmits, not what it can receive. Therefore the SNR threshold lookup
// at delivery time uses the PACKET's SF, not the receiver's — call this
// overload from the loop's deliverReceptionsForStep.
//
// Values are the standard SX1276/SX1262 demodulator SNR floors per SF for
// CR4/5 (Semtech AN1200.22, Table 13): higher SF → lower threshold (more
// tolerant of noise) at the cost of longer airtime. SF12 lands at -20 dB
// which matches the paper's value (Centelles et al. 2024).
//
// Out-of-range SF returns a very-tolerant fallback (-100 dB) so callers
// never spuriously drop packets on malformed metadata. Real input
// validation lives in setRadioParams.
float SimRadio::getSnrThreshold(int sf) {
    static const float snr_threshold[] = {
        -7.5f, -10.0f, -12.5f, -15.0f, -17.5f, -20.0f  // SF7..SF12
    };
    if (sf < 7 || sf > 12) return -100.0f;
    return snr_threshold[sf - 7];
}

float SimRadio::getSnrThreshold() const {
    return getSnrThreshold(_sf);
}

float SimRadio::packetScore(float snr, int packet_len) {
    if (_sf < 7) return 0.0f;
    float thr = getSnrThreshold();
    if (snr < thr) return 0.0f;
    float snr_part = (snr - thr) / 10.0f;
    float len_part = 1.0f - (packet_len / 256.0f);
    float score = snr_part * len_part;
    return score < 0.0f ? 0.0f : (score > 1.0f ? 1.0f : score);
}

bool SimRadio::startSendRaw(const uint8_t* bytes, int len) {
    // TX failure (models SPI/hardware errors per RadioLib error path)
    if (_tx_fail_prob > 0.0f) {
        // xorshift32 PRNG — avoids <random> header (min/max macro clash)
        _rng_state ^= _rng_state << 13;
        _rng_state ^= _rng_state >> 17;
        _rng_state ^= _rng_state << 5;
        float roll = (_rng_state & 0xFFFFFFu) / (float)0x1000000u;
        if (roll < _tx_fail_prob) {
            _state = RadioState::IDLE;  // RadioLib calls idle() on failure
            _tx_fail_count_stat++;
            return false;
        }
    }

    uint32_t now = _clock.getMillis();

    // Hardware settling: absorb RX→TX delay into TX timing.
    // Real SX1262 accepts startTransmit() and handles PA ramp internally.
    // We model this by delaying the effective TX start, not rejecting the call.
    uint32_t effective_start = std::max(now, _earliest_tx_ms);

    _rx_active_until = 0;  // TX aborts any ongoing RX demodulation
    _state = RadioState::TX_WAIT;

    uint32_t airtime = getEstAirtimeFor(len);

    // Schedule earliest RX-ready time (TX end + settling delay)
    _earliest_rx_ms = effective_start + airtime + (uint32_t)_tx_to_rx_delay_ms;

    if (_tx_callback) {
        // Report pure RF airtime (not including hw_delay) so collision detection,
        // half-duplex tracking, and visualization use correct RF envelope duration.
        _tx_callback(bytes, len, airtime);
    }
    _tx_done_at = effective_start + airtime;
    _packets_sent++;
    return true;
}

bool SimRadio::isSendComplete() {
    if (_state != RadioState::TX_WAIT) return false;
    if (_clock.getMillis() < _tx_done_at) return false;
    // Don't report TX complete until hardware settles (TX→RX delay).
    // This keeps state as TX_WAIT during the settling period, preventing
    // recvRaw() from transitioning to RX mode prematurely.
    if (_clock.getMillis() < _earliest_rx_ms) return false;
    _state = RadioState::IDLE;  // TX done + settled → IDLE
    return true;
}

void SimRadio::onSendFinished() {
    // By the time this is called, isSendComplete() has already verified
    // that both TX and settling are complete, and set state to IDLE.
    _state = RadioState::IDLE;
}
