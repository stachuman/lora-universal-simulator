#include "core/link/PathLossModel.h"
#include <cmath>

PathLossModel::PathLossModel(const PathLossConfig& cfg, std::mt19937& rng)
    : _cfg(cfg), _rng(rng), _shadow(0.0, cfg.sigma_db) {}

PathLossModel::LinkSignal PathLossModel::sampleDeterministic(double distance_m) const {
    if (distance_m < _cfg.ref_distance_m) distance_m = _cfg.ref_distance_m;
    double pl = _cfg.ref_loss_db + 10.0 * _cfg.alpha
                * std::log10(distance_m / _cfg.ref_distance_m);
    double rx_dbm = _cfg.tx_power_dbm - pl;
    double snr   = rx_dbm - _cfg.noise_floor_db;
    return { (float)snr, (float)rx_dbm };
}

PathLossModel::LinkSignal PathLossModel::sample(double distance_m) {
    auto base = sampleDeterministic(distance_m);
    double offset = (_cfg.sigma_db > 0.0) ? _shadow(_rng) : 0.0;
    return { (float)(base.snr_db + offset), (float)(base.rssi_dbm + offset) };
}
