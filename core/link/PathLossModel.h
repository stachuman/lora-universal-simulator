// core/link/PathLossModel.h
#pragma once
#include <random>
#include <string>

struct PathLossConfig {
    std::string model = "log_distance";
    double alpha = 3.0;
    double sigma_db = 0.0;
    double ref_distance_m = 1.0;
    double ref_loss_db = 40.0;
    double noise_floor_db = -120.0;
    double tx_power_dbm = 20.0;
};

class PathLossModel {
public:
    PathLossModel(const PathLossConfig& cfg, std::mt19937& rng);

    // Returns (snr_db, rssi_dbm) for a link of length distance_m.
    // Sigma_db is sampled once per call; persistent shadowing per directed
    // link is the caller's responsibility (sample once at init).
    struct LinkSignal { float snr_db; float rssi_dbm; };
    LinkSignal sample(double distance_m);

    // Deterministic version (sigma_db ignored) for analytic tests.
    LinkSignal sampleDeterministic(double distance_m) const;

private:
    PathLossConfig _cfg;
    std::mt19937& _rng;
    std::normal_distribution<double> _shadow;
};
