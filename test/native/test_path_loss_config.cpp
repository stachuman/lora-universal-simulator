// test/native/test_path_loss_config.cpp
//
// Verifies JsonConfig parses the optional simulation.path_loss block and
// the per-node lat/lon fields end-to-end. Loads sample_path_loss.json
// (path passed as argv[1]) and asserts the populated SimConfig.

#include "core/topology/JsonConfig.h"

#include <cassert>
#include <cstdio>

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <config.json>\n", argv[0]);
        return 1;
    }
    SimConfig cfg = JsonConfig::loadFromFile(argv[1]);

    // path_loss block parsed
    assert(cfg.simulation.path_loss.present);
    assert(cfg.simulation.path_loss.model == "log_distance");
    assert(cfg.simulation.path_loss.alpha == 3.0);
    assert(cfg.simulation.path_loss.sigma_db == 4.0);
    assert(cfg.simulation.path_loss.ref_distance_m == 1.0);
    assert(cfg.simulation.path_loss.ref_loss_db == 40.0);
    assert(cfg.simulation.path_loss.noise_floor_db == -120.0);
    assert(cfg.simulation.path_loss.tx_power_dbm == 20.0);

    // lat/lon -> has_location flag
    assert(cfg.nodes.size() == 2);
    assert(cfg.nodes[0].has_location);
    assert(cfg.nodes[0].lat == 41.39);
    assert(cfg.nodes[0].lon == 2.16);
    assert(cfg.nodes[1].has_location);
    assert(cfg.nodes[1].lat == 41.40);
    assert(cfg.nodes[1].lon == 2.17);

    std::printf("test_path_loss_config: OK\n");
    return 0;
}
