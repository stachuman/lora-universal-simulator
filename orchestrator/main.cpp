// orchestrator/main.cpp
//
// lora-universal-simulator entry point.
//
// Usage:
//     lus <config.json> [events.ndjson]
//
// Reads + validates the JSON scenario, runs the simulation loop, and writes
// NDJSON events to stdout (default) or to the optional second argument.
// A short summary line is printed to stderr; the exit code reflects the
// assertion-failure count (0 = pass, 1 = fail or fatal error).

#include "core/topology/JsonConfig.h"
#include "orchestrator/runtime/Loop.h"

#include <cstdio>
#include <exception>
#include <fstream>
#include <iostream>

namespace {
constexpr const char* LUS_VERSION = "0.1.0";
}

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr,
            "lus %s - lora-universal-simulator\n"
            "usage: %s <config.json> [events.ndjson]\n",
            LUS_VERSION, argv[0]);
        return 1;
    }

    SimConfig cfg;
    try {
        cfg = JsonConfig::loadFromFile(argv[1]);
    } catch (const std::exception& ex) {
        std::fprintf(stderr, "lus: failed to load config %s: %s\n", argv[1], ex.what());
        return 1;
    }

    std::ofstream events_file;
    std::ostream* out = &std::cout;
    if (argc >= 3) {
        events_file.open(argv[2]);
        if (!events_file) {
            std::fprintf(stderr, "lus: cannot open output file: %s\n", argv[2]);
            return 1;
        }
        out = &events_file;
    }

    LoopResult r;
    try {
        r = runSimulation(cfg, *out);
    } catch (const std::exception& ex) {
        std::fprintf(stderr, "lus: simulation aborted: %s\n", ex.what());
        return 1;
    }

    std::fprintf(stderr,
                 "lus: %d events emitted, %d assertion failure(s)\n",
                 r.events_emitted, r.assertion_failures);
    return r.ok ? 0 : 1;
}
