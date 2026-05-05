// test/native/test_jsonconfig.cpp
//
// Parses test/native/sample_config.json (path given as argv[1]) and
// asserts the populated SimConfig matches the prescribed schema.
//
// Top-level type is `SimConfig`; the entry point is namespaced as
// `JsonConfig::loadFromFile`. (The MeshCore source used free functions
// `parseConfigFile` / `parseConfigString` returning `OrchestratorConfig`;
// both names changed during the universal-simulator port.)

#include "core/topology/JsonConfig.h"

#include <cassert>
#include <cstdio>
#include <string>

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <config.json>\n", argv[0]);
        return 1;
    }
    SimConfig cfg = JsonConfig::loadFromFile(argv[1]);

    assert(cfg.name == "sample");

    // simulation block
    assert(cfg.simulation.duration_ms == 1000);
    assert(cfg.simulation.step_ms == 1);
    assert(cfg.simulation.warmup_ms == 0);
    assert(cfg.simulation.radio.sf == 11);
    assert(cfg.simulation.radio.bw == 250);
    assert(cfg.simulation.radio.cr == 5);

    // nodes
    assert(cfg.nodes.size() == 2);
    assert(cfg.nodes[0].name == "alice");
    assert(cfg.nodes[0].script_path == "examples/flooder.lua");
    assert(cfg.nodes[0].config.is_object());
    assert(cfg.nodes[0].config.contains("role"));
    assert(cfg.nodes[0].config["role"] == "originator");

    assert(cfg.nodes[1].name == "bob");
    assert(cfg.nodes[1].script_path == "examples/flooder.lua");
    // bob has no config block -> default empty object
    assert(cfg.nodes[1].config.is_object());
    assert(cfg.nodes[1].config.empty());

    // global radio defaults should have merged into nodes
    assert(cfg.nodes[0].sf == 11);
    assert(cfg.nodes[0].bw == 250);
    assert(cfg.nodes[0].cr == 5);

    // topology
    assert(cfg.topology.links.size() == 1);
    const auto& lk = cfg.topology.links[0];
    assert(lk.from == "alice");
    assert(lk.to   == "bob");
    assert(lk.snr  == 8.0f);
    assert(lk.rssi == -80.0f);
    assert(lk.bidir == true);

    // commands / expect should be empty (present-but-empty arrays)
    assert(cfg.commands.empty());
    assert(cfg.assertions.empty());

    std::printf("test_jsonconfig: OK\n");
    return 0;
}
