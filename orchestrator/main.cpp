// orchestrator/main.cpp
//
// lora-universal-simulator entry point.
//
// Usage:
//     lus [options] <config.json> [events.ndjson]
//
// Options:
//     -i, --interactive     Open the REPL after preload (if any).
//     -l, --lua <script>    Load a Lua script; if it defines main(), call it.
//     -h, --help            Print usage and exit.
//
// Modes:
//     (no flags)            Batch — runSimulation() to duration_ms, exit.
//                           Byte-identical to the pre-flag pipeline.
//     --lua FILE            Load script, call main() if defined, exit.
//     -i                    Initialize SimController, drop into REPL.
//     -i --lua FILE         Load script, call main(), drop into REPL.
//
// Reads + validates the JSON scenario, runs the simulation, and writes
// NDJSON events to stdout (default) or to the optional positional arg.
// A short summary line is printed to stderr; the exit code reflects the
// assertion-failure count (0 = pass, 1 = fail or fatal error).

#include "core/topology/JsonConfig.h"
#include "orchestrator/runtime/InteractiveRepl.h"
#include "orchestrator/runtime/Loop.h"
#include "orchestrator/runtime/LuaHost.h"
#include "orchestrator/runtime/SimController.h"

#include "sol/sol.hpp"

#include <cstdio>
#include <cstring>
#include <exception>
#include <fstream>
#include <iostream>
#include <string>

namespace {

constexpr const char* LUS_VERSION = "0.1.0";

void usage(const char* prog) {
    std::fprintf(stderr,
        "Usage: %s [options] <config.json> [events.ndjson]\n"
        "\n"
        "Options:\n"
        "  -i, --interactive          Open REPL after preload (if any)\n"
        "  -l, --lua <script>         Load Lua script; if it defines main(), call it\n"
        "  -e, --engine <lua|meshroute>  Force every node onto this engine (overrides per-node engine/script)\n"
        "  -h, --help                 Show this help and exit\n"
        "\n"
        "Modes:\n"
        "  (no flags)                 Batch — run to duration_ms, exit\n"
        "  --lua FILE                 Run script's main(), exit\n"
        "  -i                         Initialize then drop into REPL\n"
        "  -i --lua FILE              Run main() then drop into REPL\n",
        prog);
}

}  // namespace

int main(int argc, char** argv) {
    bool        interactive = false;
    std::string lua_script_path;
    std::string config_path;
    std::string events_path;
    std::string engine_override;   // --engine <lua|meshroute>: force EVERY node to this engine (ignores per-node engine/script)

    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "-h" || a == "--help") {
            usage(argv[0]);
            return 0;
        }
        if (a == "-i" || a == "--interactive") {
            interactive = true;
            continue;
        }
        if (a == "-l" || a == "--lua") {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "lus: --lua requires a path\n");
                return 1;
            }
            lua_script_path = argv[++i];
            continue;
        }
        if (a == "-e" || a == "--engine") {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "lus: --engine requires <lua|meshroute>\n");
                return 1;
            }
            engine_override = argv[++i];
            if (engine_override != "lua" && engine_override != "meshroute") {
                std::fprintf(stderr, "lus: --engine must be lua or meshroute (got '%s')\n", engine_override.c_str());
                return 1;
            }
            continue;
        }
        if (!a.empty() && a[0] == '-') {
            std::fprintf(stderr, "lus: unknown option: %s\n", a.c_str());
            usage(argv[0]);
            return 1;
        }
        if (config_path.empty()) {
            config_path = a;
            continue;
        }
        if (events_path.empty()) {
            events_path = a;
            continue;
        }
        std::fprintf(stderr, "lus: unexpected arg: %s\n", a.c_str());
        usage(argv[0]);
        return 1;
    }

    if (config_path.empty()) {
        std::fprintf(stderr, "lus %s - lora-universal-simulator\n", LUS_VERSION);
        usage(argv[0]);
        return 1;
    }

    SimConfig cfg;
    try {
        cfg = JsonConfig::loadFromFile(config_path);
    } catch (const std::exception& ex) {
        std::fprintf(stderr, "lus: failed to load config %s: %s\n",
                     config_path.c_str(), ex.what());
        return 1;
    }

    // --engine override: force every node onto the chosen engine (the per-node engine/script is ignored).
    // Lets any engine-neutral scenario run on the C++ port (meshroute) or the Lua baseline without editing it.
    if (!engine_override.empty()) {
        for (auto& n : cfg.nodes) n.engine = engine_override;
        std::fprintf(stderr, "lus: --engine %s forced for all %zu nodes\n",
                     engine_override.c_str(), cfg.nodes.size());
    }

    std::ofstream events_file;
    std::ostream* out = &std::cout;
    if (!events_path.empty()) {
        events_file.open(events_path);
        if (!events_file) {
            std::fprintf(stderr, "lus: cannot open output file: %s\n",
                         events_path.c_str());
            return 1;
        }
        out = &events_file;
    }

    // ---- Mode dispatch ----

    // Pure batch: preserve the Y1 pipeline byte-identically.
    if (!interactive && lua_script_path.empty()) {
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

    // -i and/or --lua: drive the SimController directly.
    try {
        SimController ctrl(cfg, *out);
        ctrl.initialize();

        if (!lua_script_path.empty()) {
            sol::state& lua = ctrl.luaHost().lua();
            sol::protected_function_result load_r =
                lua.safe_script_file(lua_script_path,
                                     sol::script_pass_on_error);
            if (!load_r.valid()) {
                sol::error err = load_r;
                std::fprintf(stderr, "lus: --lua script error: %s\n",
                             err.what());
                return 1;
            }

            sol::object main_obj = lua["main"];
            if (main_obj.is<sol::protected_function>()) {
                sol::protected_function main_fn = main_obj;
                sol::protected_function_result main_r = main_fn();
                if (!main_r.valid()) {
                    sol::error err = main_r;
                    std::fprintf(stderr, "lus: main() error: %s\n",
                                 err.what());
                    return 1;
                }
            }
        }

        if (interactive) {
            InteractiveRepl repl(ctrl);
            repl.run();
        }

        int failures = ctrl.finalize();
        std::fprintf(stderr,
                     "lus: %d events emitted, %d assertion failure(s)\n",
                     ctrl.eventCount(), failures);
        return failures == 0 ? 0 : 1;

    } catch (const std::exception& ex) {
        std::fprintf(stderr, "lus: simulation aborted: %s\n", ex.what());
        return 1;
    }
}
