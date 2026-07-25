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

// ---------------------------------------------------------------------------
// Two LBT models (config `simulation.radio.lbt_model`):
//
//   Cad    — the historical probabilistic model (kept VERBATIM for A/B):
//            one CAD-miss roll per in-flight frame at the frame's TX-start
//            per observer; a hit records a busy window until the frame's
//            end_ms; busy is then a boolean lookup against that stored
//            window. Consumes the model's own RNG (shouldNotifyBusy).
//
//   Energy — the DEVICE's noise-floor energy detect (bench-validated,
//            DEFAULT): busy(observer) is evaluated at ASK TIME as "is any
//            in-flight frame's SNR-at-observer >= energy_threshold_snr_db",
//            deterministic, with ZERO RNG draws. Nothing is pre-rolled at
//            TX-start; the defer/retry machinery re-asks and gets a fresh
//            verdict for free. LbtModel does not own the in-flight frame
//            set / SNR matrix, so the owner (SimController) supplies the
//            ask-time query via setEnergyBusyProvider().
// ---------------------------------------------------------------------------
#include <cstdint>
#include <functional>
#include <random>
#include <vector>

enum class LbtMode { Cad, Energy };

struct LbtConfig {
    // CAD-mode probabilistic gating.
    float cad_miss_prob    = 0.05f;
    float cad_reliable_snr = 0.0f;
    float cad_marginal_snr = -15.0f;
    // Which model is active. Struct-level default = Cad so the historical
    // aggregate-init call sites (and the scalar convenience ctor) stay on the
    // old model byte-for-byte; the scenario-level default (energy) is applied
    // in JsonConfig / SimController where the `lbt_model` key is honoured.
    LbtMode mode = LbtMode::Cad;
    // Energy-mode noise-floor threshold: an in-flight frame counts as "channel
    // busy" for an observer iff its SNR-at-observer >= this (dB). Default 0.0
    // mirrors the device's noise-floor + margin rule; bench-tunable.
    float energy_threshold_snr_db = 0.0f;
};

class LbtModel {
public:
    explicit LbtModel(int n_nodes,
                      LbtConfig cfg = {},
                      uint64_t  rng_seed = 0xCAFEBABEull);

    // Convenience matching the plan's sketch — same defaults, scalar miss prob.
    // Explicitly CAD-mode (the historical behaviour this ctor has always had).
    LbtModel(int n_nodes, float cad_miss_prob, uint64_t rng_seed = 0xCAFEBABEull);

    LbtMode mode() const { return _cfg.mode; }

    // Energy-mode ask-time query. The owner (SimController) supplies a functor
    // that returns the latest end_ms among in-flight frames whose SNR at
    // `observer` >= `threshold_db`, evaluated at the owner's CURRENT sim-time,
    // or 0 if the channel is idle for that observer. Pure lookup — no RNG.
    using EnergyBusyProvider = std::function<uint64_t(int observer, float threshold_db)>;
    void setEnergyBusyProvider(EnergyBusyProvider p) { _energy_provider = std::move(p); }

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

    // CAD mode: true iff the observer's recorded busy_until (a hit window
    // pre-rolled at TX-start) is strictly greater than now_ms.
    // ENERGY mode: true iff the ask-time provider reports an above-threshold
    // in-flight frame ending after now_ms (fresh on every call; no caching).
    bool isChannelBusy(int observer_node, uint64_t now_ms) const;

    // Absolute simtime when the observer's busy window ends, or 0 if idle.
    // CAD mode: the max recorded busy_until. ENERGY mode: the ask-time
    // provider's latest above-threshold in-flight end_ms (uses the owner's
    // current sim-time — busyUntil takes no now_ms). Used by the runtime to
    // populate RadioBusyInfo.busy_until_ms when a TX is deferred.
    uint64_t busyUntil(int observer_node) const;

    int  numNodes() const { return (int)_busy_until.size(); }

    // Test/inspection accessors.
    const LbtConfig&    config() const { return _cfg; }
    const std::mt19937& rng()    const { return _rng; }  // zero-draw probe (energy mode)

private:
    LbtConfig             _cfg;
    std::mt19937          _rng;
    std::vector<uint64_t> _busy_until;      // per-observer-node max(until_ms); CAD mode only
    EnergyBusyProvider    _energy_provider; // energy mode: owner-supplied ask-time query
};
