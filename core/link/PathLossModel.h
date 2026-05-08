// core/link/PathLossModel.h
#pragma once
#include <cstdint>
#include <random>
#include <string>
#include <vector>

struct PathLossConfig {
    std::string model = "log_distance";
    double alpha = 3.0;
    // Per-(sender→receiver) shadow stddev. Captures permanent obstruction
    // differences along the two directions (so SNR(A→B) ≠ SNR(B→A) even
    // before per-node bias). Sampled once per directed pair at init,
    // re-sampled every asymmetry_coherence_ms if non-zero.
    double sigma_db = 3.0;
    double ref_distance_m = 1.0;
    double ref_loss_db = 40.0;
    double noise_floor_db = -120.0;
    double tx_power_dbm = 20.0;

    // Per-node bias stddevs — sampled once per node at init, stable for
    // the run (these represent hardware, not environment). Apply to
    // every directional sample via:
    //   SNR(i→j) = baseline(d_ij) + tx_offset[i] + rx_offset[j]
    //              + pair_shadow[i,j]
    double node_tx_offset_sigma_db = 2.0;
    double node_rx_offset_sigma_db = 1.5;

    // 0 → static asymmetry (sample shadows once at init).
    // >0 → re-sample all per-pair shadows every coherence_ms ms,
    //       modeling slow environmental change. Per-node offsets
    //       stay fixed since they represent hardware. Default 60_000
    //       ms — slow drift is the realistic baseline for fixed-
    //       installation LoRa (foliage, weather, multipath).
    uint64_t asymmetry_coherence_ms = 60000;
};

class PathLossModel {
public:
    PathLossModel(const PathLossConfig& cfg, std::mt19937& rng);

    // Allocate per-node and per-pair state, sample initial values.
    // Idempotent — calling again replaces all sampled state. Pair shadows
    // are populated for every (i, j), i != j; symmetric on (i, j) ordering
    // but each direction stores an independent draw.
    void initializeNodes(int n_nodes);

    // Override a per-node offset (e.g. from JSON nodes[i].tx_power_offset_db).
    // Must be called AFTER initializeNodes(). NaN means "leave the
    // randomly-sampled value alone."
    void setNodeTxOffset(int node, float offset_db);
    void setNodeRxOffset(int node, float offset_db);
    float nodeTxOffset(int node) const;
    float nodeRxOffset(int node) const;

    // Re-sample all per-pair shadows (called by SimController on the
    // asymmetry_coherence_ms tick). No-op if initializeNodes() wasn't
    // called.
    void resamplePairShadows();

    // Returns (snr_db, rssi_dbm) for the directed link sender → receiver.
    // Uses cached per-node offsets and per-pair shadow; deterministic
    // given the seed and last resample time.
    struct LinkSignal { float snr_db; float rssi_dbm; };
    LinkSignal sampleDirectional(int sender, int receiver, double distance_m) const;

    // Backwards-compat: deterministic baseline (no shadowing, no offsets).
    LinkSignal sampleDeterministic(double distance_m) const;

    // Backwards-compat: log-distance baseline + a fresh shadow draw.
    // Used by unit tests that don't model per-node bias. Does NOT consult
    // the per-node / per-pair caches.
    LinkSignal sample(double distance_m);

private:
    PathLossConfig _cfg;
    std::mt19937& _rng;
    std::normal_distribution<double> _shadow;
    std::normal_distribution<double> _node_tx_dist;
    std::normal_distribution<double> _node_rx_dist;

    int _n = 0;
    std::vector<float> _tx_offset;        // [n]
    std::vector<float> _rx_offset;        // [n]
    std::vector<float> _pair_shadow_db;   // [n*n], i*n + j  (sender→receiver)
};
