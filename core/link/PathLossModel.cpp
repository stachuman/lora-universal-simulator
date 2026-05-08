#include "core/link/PathLossModel.h"
#include <cmath>

PathLossModel::PathLossModel(const PathLossConfig& cfg, std::mt19937& rng)
    : _cfg(cfg),
      _rng(rng),
      _shadow(0.0, cfg.sigma_db),
      _node_tx_dist(0.0, cfg.node_tx_offset_sigma_db),
      _node_rx_dist(0.0, cfg.node_rx_offset_sigma_db) {}

void PathLossModel::initializeNodes(int n_nodes) {
    _n = n_nodes;
    _tx_offset.assign((size_t)n_nodes, 0.0f);
    _rx_offset.assign((size_t)n_nodes, 0.0f);
    if (_cfg.node_tx_offset_sigma_db > 0.0) {
        for (int i = 0; i < n_nodes; ++i)
            _tx_offset[(size_t)i] = (float)_node_tx_dist(_rng);
    }
    if (_cfg.node_rx_offset_sigma_db > 0.0) {
        for (int i = 0; i < n_nodes; ++i)
            _rx_offset[(size_t)i] = (float)_node_rx_dist(_rng);
    }
    _pair_shadow_db.assign((size_t)n_nodes * (size_t)n_nodes, 0.0f);
    resamplePairShadows();
}

void PathLossModel::setNodeTxOffset(int node, float offset_db) {
    if (node < 0 || node >= _n) return;
    if (std::isnan(offset_db)) return;
    _tx_offset[(size_t)node] = offset_db;
}

void PathLossModel::setNodeRxOffset(int node, float offset_db) {
    if (node < 0 || node >= _n) return;
    if (std::isnan(offset_db)) return;
    _rx_offset[(size_t)node] = offset_db;
}

float PathLossModel::nodeTxOffset(int node) const {
    if (node < 0 || node >= _n) return 0.0f;
    return _tx_offset[(size_t)node];
}

float PathLossModel::nodeRxOffset(int node) const {
    if (node < 0 || node >= _n) return 0.0f;
    return _rx_offset[(size_t)node];
}

void PathLossModel::resamplePairShadows() {
    if (_n <= 0 || _cfg.sigma_db <= 0.0) {
        // Even with sigma_db=0 we keep the buffer allocated (zeros) so
        // sampleDirectional() can index into it without bounds checks.
        return;
    }
    for (int i = 0; i < _n; ++i) {
        for (int j = 0; j < _n; ++j) {
            if (i == j) continue;
            _pair_shadow_db[(size_t)i * (size_t)_n + (size_t)j]
                = (float)_shadow(_rng);
        }
    }
}

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

PathLossModel::LinkSignal PathLossModel::sampleDirectional(
        int sender, int receiver, double distance_m) const {
    auto base = sampleDeterministic(distance_m);
    float tx_off = (sender   >= 0 && sender   < _n) ? _tx_offset[(size_t)sender]   : 0.0f;
    float rx_off = (receiver >= 0 && receiver < _n) ? _rx_offset[(size_t)receiver] : 0.0f;
    float shadow = 0.0f;
    if (sender >= 0 && sender < _n && receiver >= 0 && receiver < _n
        && sender != receiver) {
        shadow = _pair_shadow_db[(size_t)sender * (size_t)_n + (size_t)receiver];
    }
    float total = tx_off + rx_off + shadow;
    return { base.snr_db + total, base.rssi_dbm + total };
}
