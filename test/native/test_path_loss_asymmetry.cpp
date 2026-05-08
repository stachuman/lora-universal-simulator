// Verifies the per-node + per-pair asymmetry components of PathLossModel:
//   1. With node sigmas > 0, sampling the same pair (i,j) and (j,i) yields
//      different SNRs (real LoRa exhibits this; symmetric model masks bugs).
//   2. Stats over many nodes match the configured sigmas.
//   3. setNodeTxOffset/setNodeRxOffset overrides win over sampled values
//      (used by the JSON nodes[i].tx_power_offset_db field).
//   4. resamplePairShadows() changes the per-pair shadow component but
//      leaves per-node offsets fixed (hardware vs environment).
//   5. With everything zeroed, sampleDirectional returns the deterministic
//      baseline — analytic-test escape hatch.

#include "core/link/PathLossModel.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <random>

int main() {
    PathLossConfig cfg;
    cfg.alpha = 3.0;
    cfg.sigma_db = 3.0;
    cfg.ref_distance_m = 1.0;
    cfg.ref_loss_db = 40.0;
    cfg.noise_floor_db = -120.0;
    cfg.tx_power_dbm = 20.0;
    cfg.node_tx_offset_sigma_db = 2.0;
    cfg.node_rx_offset_sigma_db = 1.5;

    std::mt19937 rng(42);
    PathLossModel pl(cfg, rng);
    pl.initializeNodes(8);

    // 1. Asymmetry — SNR(0→1) ≠ SNR(1→0) when components are non-zero.
    auto a_to_b = pl.sampleDirectional(0, 1, 100.0);
    auto b_to_a = pl.sampleDirectional(1, 0, 100.0);
    assert(std::fabs(a_to_b.snr_db - b_to_a.snr_db) > 0.05f);
    std::printf("  asymmetry: SNR(0→1)=%.2f vs SNR(1→0)=%.2f (Δ=%.2f dB)\n",
                a_to_b.snr_db, b_to_a.snr_db,
                std::fabs(a_to_b.snr_db - b_to_a.snr_db));

    // 2. Stats — sample many node populations, check that the empirical
    //    sigmas converge near config.
    std::mt19937 rng2(123);
    PathLossModel pl_stats(cfg, rng2);
    const int N = 2000;
    pl_stats.initializeNodes(N);
    double tx_sum = 0, tx_sq = 0, rx_sum = 0, rx_sq = 0;
    for (int i = 0; i < N; ++i) {
        double tx = pl_stats.nodeTxOffset(i);
        double rx = pl_stats.nodeRxOffset(i);
        tx_sum += tx; tx_sq += tx * tx;
        rx_sum += rx; rx_sq += rx * rx;
    }
    double tx_mean = tx_sum / N;
    double rx_mean = rx_sum / N;
    double tx_sigma = std::sqrt(tx_sq / N - tx_mean * tx_mean);
    double rx_sigma = std::sqrt(rx_sq / N - rx_mean * rx_mean);
    assert(std::fabs(tx_sigma - cfg.node_tx_offset_sigma_db) < 0.15);
    assert(std::fabs(rx_sigma - cfg.node_rx_offset_sigma_db) < 0.15);
    std::printf("  stats:     tx_sigma=%.2f (target %.2f), rx_sigma=%.2f (target %.2f)\n",
                tx_sigma, cfg.node_tx_offset_sigma_db,
                rx_sigma, cfg.node_rx_offset_sigma_db);

    // 3. Override wins.
    pl.setNodeTxOffset(2, -5.0f);
    pl.setNodeRxOffset(2, +3.0f);
    assert(std::fabs(pl.nodeTxOffset(2) - (-5.0f)) < 0.001f);
    assert(std::fabs(pl.nodeRxOffset(2) - (+3.0f)) < 0.001f);
    // NaN means "leave alone" — should not overwrite.
    float nan = std::nanf("");
    pl.setNodeTxOffset(2, nan);
    assert(std::fabs(pl.nodeTxOffset(2) - (-5.0f)) < 0.001f);
    std::printf("  override:  tx[2]=%.2f, rx[2]=%.2f (NaN preserves)\n",
                pl.nodeTxOffset(2), pl.nodeRxOffset(2));

    // 4. Resample changes pair shadow but not node offsets.
    auto before_pair = pl.sampleDirectional(3, 4, 100.0);
    float tx_before = pl.nodeTxOffset(3);
    float rx_before = pl.nodeRxOffset(4);
    pl.resamplePairShadows();
    auto after_pair = pl.sampleDirectional(3, 4, 100.0);
    float tx_after = pl.nodeTxOffset(3);
    float rx_after = pl.nodeRxOffset(4);
    assert(std::fabs(tx_before - tx_after) < 0.001f);  // unchanged
    assert(std::fabs(rx_before - rx_after) < 0.001f);
    // The pair component changed, so the directional SNR differs.
    assert(std::fabs(before_pair.snr_db - after_pair.snr_db) > 0.05f);
    std::printf("  resample:  pair-shadow drifted SNR(3→4) %.2f → %.2f (offsets fixed)\n",
                before_pair.snr_db, after_pair.snr_db);

    // 5. Zeroed escape hatch — sampleDirectional == sampleDeterministic.
    PathLossConfig zero_cfg = cfg;
    zero_cfg.sigma_db = 0.0;
    zero_cfg.node_tx_offset_sigma_db = 0.0;
    zero_cfg.node_rx_offset_sigma_db = 0.0;
    PathLossModel pl_det(zero_cfg, rng);
    pl_det.initializeNodes(4);
    auto det_directional = pl_det.sampleDirectional(0, 1, 100.0);
    auto det_baseline    = pl_det.sampleDeterministic(100.0);
    assert(std::fabs(det_directional.snr_db - det_baseline.snr_db) < 0.001f);
    std::printf("  zero cfg:  directional=%.2f matches baseline=%.2f\n",
                det_directional.snr_db, det_baseline.snr_db);

    std::printf("test_path_loss_asymmetry: OK\n");
    return 0;
}
