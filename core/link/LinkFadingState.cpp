#include "core/link/LinkFadingState.h"

#include <cmath>

float advanceFading(LinkFadingState& s,
                    float snr_std_dev,
                    uint64_t snr_coherence_ms,
                    uint64_t step_ms,
                    std::mt19937& rng) {
    if (snr_std_dev <= 0.0f) {
        return 0.0f;  // no fading at all
    }

    if (snr_coherence_ms > 0) {
        // Ornstein-Uhlenbeck (continuous-time AR(1)) correlated fading.
        // Upstream Orchestrator.cpp 467-482.
        const float dt       = (float)((step_ms >= s.last_update_ms)
                                            ? step_ms - s.last_update_ms : 0ULL);
        const float alpha    = std::exp(-dt / (float)snr_coherence_ms);
        float alpha_sq       = alpha * alpha;
        if (alpha_sq > 1.0f) alpha_sq = 1.0f;  // float-precision guard
        std::normal_distribution<float> unit(0.0f, 1.0f);
        s.current_offset_db =
            alpha * s.current_offset_db
            + std::sqrt(1.0f - alpha_sq) * snr_std_dev * unit(rng);
        s.last_update_ms = step_ms;
        return s.current_offset_db;
    }

    // i.i.d. Gaussian (original behavior). The state is not consulted.
    std::normal_distribution<float> dist(0.0f, snr_std_dev);
    return dist(rng);
}
