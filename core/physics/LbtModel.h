#pragma once

// Listen-Before-Talk bookkeeping, lifted from
// meshcore_real_sim/orchestrator/Orchestrator.cpp lines ~508-535 (the LBT
// notification block in `registerTransmissions`).
//
// The upstream design has TWO halves:
//
//   (a) Per-node "busy until" channel state (lives in each node's SimRadio
//       as a stack of LbtWindow entries — see SimRadio::notifyChannelBusy).
//
//   (b) Probabilistic CAD-miss gating before the busy notification fires.
//       The miss probability is interpolated by SNR:
//          rx_snr >= cad_reliable_snr  → miss = cad_miss_prob   (typ. 0.05)
//          rx_snr <= cad_marginal_snr  → miss = 1.0  (always misses)
//          in-between                  → linear interpolation
//
// In universal-sim land the two halves separate cleanly:
//   - `LbtModel` owns (b) — the SNR-modulated CAD-miss decision and a
//     per-node busy_until vector for callers that don't have a SimRadio
//     handy. Callers with a SimRadio still use SimRadio::notifyChannelBusy
//     for the per-window tracking; LbtModel just answers "given this
//     reception, did the CAD detect it?" via shouldNotifyBusy().
//   - The upstream's preamble-detect delay is exposed by SimRadio
//     (getPreambleDetectMs); LbtModel does not duplicate it.
//
// Constants matched to upstream (Orchestrator.h lines 148-150):
//   cad_miss_prob    = 0.05
//   cad_reliable_snr = 0.0
//   cad_marginal_snr = -15.0

#include <cstdint>
#include <random>
#include <vector>

struct LbtConfig {
    float cad_miss_prob    = 0.05f;
    float cad_reliable_snr = 0.0f;
    float cad_marginal_snr = -15.0f;
};

class LbtModel {
public:
    explicit LbtModel(int n_nodes,
                      LbtConfig cfg = {},
                      uint64_t  rng_seed = 0xCAFEBABEull);

    // Convenience matching the plan's sketch — same defaults, scalar miss prob.
    LbtModel(int n_nodes, float cad_miss_prob, uint64_t rng_seed = 0xCAFEBABEull);

    // Compute the effective CAD-miss probability for a sampled reception
    // SNR. Returns a value in [cad_miss_prob, 1.0]. This is the protocol-
    // agnostic kernel of upstream's LBT decision (Orchestrator.cpp 518-526).
    float effectiveMissProb(float rx_snr_db) const;

    // Roll the CAD: returns true if the observer SHOULD record the busy
    // window, false if the CAD missed the preamble. Uses the model's
    // internal RNG.
    bool shouldNotifyBusy(float rx_snr_db);

    // Per-node busy bookkeeping. Equivalent to remembering the maximum
    // busy_until per observer; multiple notifications extend the window.
    void notifyChannelBusy(int observer_node, int sender_node,
                           uint64_t until_ms, float snr_db);

    // True if the observer's recorded busy_until is strictly greater than
    // now_ms. CAD that "missed" earlier never advanced this timestamp.
    bool isChannelBusy(int observer_node, uint64_t now_ms) const;

    // Absolute simtime when the observer's busy window ends, or 0 if no
    // busy notification has been recorded. Used by the runtime to populate
    // RadioBusyInfo.busy_until_ms when a TX is deferred.
    uint64_t busyUntil(int observer_node) const;

    int  numNodes() const { return (int)_busy_until.size(); }

    // Test/inspection accessor.
    const LbtConfig& config() const { return _cfg; }

private:
    LbtConfig             _cfg;
    std::mt19937          _rng;
    std::vector<uint64_t> _busy_until;  // per-observer-node max(until_ms)
};
