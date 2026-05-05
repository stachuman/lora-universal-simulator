#include "core/physics/LbtModel.h"

LbtModel::LbtModel(int n_nodes, LbtConfig cfg, uint64_t rng_seed)
    : _cfg(cfg),
      _rng(static_cast<std::mt19937::result_type>(rng_seed)),
      _busy_until(n_nodes > 0 ? (size_t)n_nodes : 0u, 0ULL) {}

LbtModel::LbtModel(int n_nodes, float cad_miss_prob, uint64_t rng_seed)
    : LbtModel(n_nodes, LbtConfig{cad_miss_prob, 0.0f, -15.0f}, rng_seed) {}

float LbtModel::effectiveMissProb(float rx_snr_db) const {
    // Upstream Orchestrator.cpp 518-526.
    if (rx_snr_db >= _cfg.cad_reliable_snr) {
        return _cfg.cad_miss_prob;
    }
    if (rx_snr_db <= _cfg.cad_marginal_snr) {
        return 1.0f;
    }
    // Linear interpolation between (marginal → 1.0) and (reliable → cad_miss).
    const float span = _cfg.cad_reliable_snr - _cfg.cad_marginal_snr;
    if (span <= 0.0f) return _cfg.cad_miss_prob;  // pathological config guard
    const float t = (rx_snr_db - _cfg.cad_marginal_snr) / span;
    return 1.0f - t * (1.0f - _cfg.cad_miss_prob);
}

bool LbtModel::shouldNotifyBusy(float rx_snr_db) {
    const float miss = effectiveMissProb(rx_snr_db);
    if (miss <= 0.0f) return true;
    if (miss >= 1.0f) return false;
    std::uniform_real_distribution<float> u(0.0f, 1.0f);
    return u(_rng) >= miss;  // notify when we did NOT miss
}

void LbtModel::notifyChannelBusy(int observer_node, int /*sender_node*/,
                                 uint64_t until_ms, float /*snr_db*/) {
    if (observer_node < 0 || (size_t)observer_node >= _busy_until.size()) return;
    if (until_ms > _busy_until[(size_t)observer_node]) {
        _busy_until[(size_t)observer_node] = until_ms;
    }
}

bool LbtModel::isChannelBusy(int observer_node, uint64_t now_ms) const {
    if (observer_node < 0 || (size_t)observer_node >= _busy_until.size()) {
        return false;
    }
    return _busy_until[(size_t)observer_node] > now_ms;
}
