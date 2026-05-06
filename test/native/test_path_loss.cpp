#include "core/link/PathLossModel.h"
#include "core/link/Geo.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <random>

int main() {
    // Haversine sanity (Barcelona to Madrid ~ 506 km)
    double d_bcn_mad = lus::haversineDistanceMeters(41.39, 2.16, 40.42, -3.70);
    assert(d_bcn_mad > 500000.0 && d_bcn_mad < 510000.0);

    // Same point
    double d_zero = lus::haversineDistanceMeters(41.39, 2.16, 41.39, 2.16);
    assert(d_zero < 0.1);

    // Path-loss deterministic check
    PathLossConfig cfg;
    cfg.alpha = 3.0;
    cfg.sigma_db = 0.0;
    cfg.ref_distance_m = 1.0;
    cfg.ref_loss_db = 40.0;
    cfg.noise_floor_db = -120.0;
    cfg.tx_power_dbm = 20.0;
    std::mt19937 rng(42);
    PathLossModel pl(cfg, rng);

    auto at_1m = pl.sampleDeterministic(1.0);
    // PL(1m) = 40 dB; RxPower = 20 - 40 = -20; SNR = -20 - (-120) = 100
    assert(std::fabs(at_1m.snr_db - 100.0f) < 0.01f);

    auto at_100m = pl.sampleDeterministic(100.0);
    // PL(100m) = 40 + 10*3*log10(100) = 40 + 60 = 100 dB
    // RxPower = 20 - 100 = -80; SNR = -80 - (-120) = 40
    assert(std::fabs(at_100m.snr_db - 40.0f) < 0.01f);

    auto at_1km = pl.sampleDeterministic(1000.0);
    // PL(1000m) = 40 + 10*3*log10(1000) = 40 + 90 = 130 dB
    // RxPower = -110; SNR = -110 - (-120) = 10
    assert(std::fabs(at_1km.snr_db - 10.0f) < 0.01f);

    // Stochastic (sigma_db > 0): mean over many samples should be near deterministic
    cfg.sigma_db = 4.0;
    PathLossModel pls(cfg, rng);
    double sum_snr = 0;
    int N = 10000;
    for (int i = 0; i < N; i++) {
        sum_snr += pls.sample(100.0).snr_db;
    }
    double mean_snr = sum_snr / N;
    // Expected mean = 40 +/- something small (4 dB sigma / sqrt(10000) ~ 0.04 dB stderr)
    assert(std::fabs(mean_snr - 40.0) < 0.5);

    std::printf("test_path_loss: OK (1m=%.2f, 100m=%.2f, 1km=%.2f, MC mean(100m, sigma=4)=%.2f)\n",
                at_1m.snr_db, at_100m.snr_db, at_1km.snr_db, mean_snr);
    return 0;
}
