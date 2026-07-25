// test/native/test_lua_deprecated.cpp
//
// ★ The DEPRECATED-LUA contract (2026-07-25 owner ruling: "We do NOT support lua
// engine anymore ... it is far behind firmware already").
//
// Three properties, each of which failing silently would cost a whole test run:
//
//   1. THE DEFAULT IS "meshroute". Lua used to be the default, and most of the
//      MeshRoute corpus (389 of 722 nodes, the entire mandatory s21-s30 suite
//      among them) carries no `engine` key — so every one of those scenarios was
//      one forgotten `-e meshroute` away from silently running the frozen Lua
//      reference and reporting the result as if it were the firmware's. Pinning
//      the default here is what keeps that foot-gun dead.
//   2. A NODE RESOLVING TO "lua" IS REFUSED, LOUDLY (C2: fail loud, no silent
//      downgrade), and the message names the deprecation, the offending node and
//      the way to opt in.
//   3. THE OPT-IN WORKS AND IS EXPRESSIBLE IN CONFIG, not only as a CLI flag —
//      because native tests construct SimController directly and never touch the
//      lus CLI (this test, and test_bw_mismatch, are exactly that case).
//
// ★ The refusal is checked at the SimController::initialize() choke point, not at
// config-parse time, because `lus --engine lua` rewrites NodeDef::engine AFTER
// loadFromFile() returns. Case 4 below reproduces that CLI rewrite verbatim
// against a config whose nodes are all "meshroute" on disk, which is the property
// a JsonConfig-side check could not have.
//
// The Lua engine itself is KEPT: dv_dual_sf.lua, ScriptedNode, LuaHost and the
// --engine flag all remain, as the frozen parity reference the C++ port was
// validated against. This test asserts they still RUN under the opt-in.

#include "core/topology/JsonConfig.h"
#include "orchestrator/runtime/SimController.h"

#include <cassert>
#include <cstdio>
#include <sstream>
#include <stdexcept>
#include <string>

namespace {

// A minimal-but-valid config with one node, whose `engine` line is injected by
// the caller ("" = omit the key entirely, i.e. take the default).
std::string oneNodeConfig(const std::string& engine_line,
                          const std::string& sim_extra_line) {
    return std::string(
        "{\"_name\":\"probe\",\"simulation\":{\"duration_ms\":1000,\"step_ms\":1,")
        + sim_extra_line
        + "\"radio\":{\"sf\":7,\"bw\":125,\"cr\":5,\"duty_cycle\":1}},"
          "\"nodes\":[{\"name\":\"n0\"" + engine_line + "}],"
          "\"topology\":{\"links\":[]}}";
}

// Run cfg through a fresh controller; return the throw message ("" = no throw).
std::string initFailure(const SimConfig& cfg) {
    std::ostringstream out;
    SimController ctrl(cfg, out);
    try {
        ctrl.initialize();
    } catch (const std::exception& ex) {
        return ex.what();
    }
    return "";
}

bool has(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

}  // namespace

int main(int argc, char** argv) {
    assert(argc >= 2 && "usage: test_lua_deprecated <config.json>");

    // ---- 1. the DEFAULT engine is "meshroute" ----------------------------
    {
        const SimConfig d = JsonConfig::loadFromString(oneNodeConfig("", ""));
        assert(d.nodes.size() == 1);
        assert(d.nodes[0].engine == "meshroute" &&
               "★ an engine-less node must default to meshroute, NOT lua");
        // ...and "lua" still parses: the engine is deprecated, not removed.
        const SimConfig l =
            JsonConfig::loadFromString(oneNodeConfig(",\"engine\":\"lua\"", ""));
        assert(l.nodes[0].engine == "lua");
        // An unknown engine is still rejected outright.
        bool threw = false;
        try {
            JsonConfig::loadFromString(oneNodeConfig(",\"engine\":\"nope\"", ""));
        } catch (const std::exception&) { threw = true; }
        assert(threw && "an unknown engine must still be a config error");
    }

    // ---- 2. the opt-in parses, defaults false, and is type-checked --------
    {
        const SimConfig off = JsonConfig::loadFromString(oneNodeConfig("", ""));
        assert(off.simulation.allow_deprecated_lua == false &&
               "the deprecated-Lua opt-in must default to OFF");
        const SimConfig on = JsonConfig::loadFromString(
            oneNodeConfig("", "\"allow_deprecated_lua\":true,"));
        assert(on.simulation.allow_deprecated_lua == true);
        bool threw = false;
        try {
            JsonConfig::loadFromString(
                oneNodeConfig("", "\"allow_deprecated_lua\":\"yes\","));
        } catch (const std::exception&) { threw = true; }
        assert(threw && "allow_deprecated_lua must be type-checked (boolean)");
    }

    // ---- 3. a config-declared Lua node is REFUSED, loudly ----------------
    // The fixture is two explicit engine:"lua" nodes with NO opt-in.
    SimConfig cfg = JsonConfig::loadFromFile(argv[1]);
    assert(cfg.nodes.size() == 2);
    assert(cfg.nodes[0].engine == "lua" && cfg.nodes[1].engine == "lua");
    assert(cfg.simulation.allow_deprecated_lua == false);
    {
        const std::string msg = initFailure(cfg);
        assert(!msg.empty() && "★ a lua node must REFUSE the run, not warn");
        // The message must be self-explanatory to a reader who has never seen the
        // ruling: what is deprecated, which node, and how to opt in.
        assert(has(msg, "REFUSED"));
        assert(has(msg, "DEPRECATED"));
        assert(has(msg, "luasender") && "the offending node must be named");
        assert(has(msg, "allow_deprecated_lua") &&
               "the message must state how to opt in");
        assert(has(msg, "--allow-deprecated-lua"));
    }

    // ---- 3b. an unrecognised engine cannot sneak past as a Lua node -------
    // The node dispatch builds a ScriptedNode for ANY non-"meshroute" value, so
    // the gate keys on != "meshroute", not == "lua". Config and CLI both reject
    // unknown engine strings, so this is only reachable from a hand-built
    // SimConfig — which is exactly what a native test is.
    {
        SimConfig bogus = JsonConfig::loadFromString(oneNodeConfig("", ""));
        bogus.nodes[0].engine = "Lua";              // wrong case = not meshroute
        const std::string msg = initFailure(bogus);
        assert(!msg.empty() && "an unrecognised engine must not silently run Lua");
        assert(has(msg, "\"Lua\"") && "the message must quote the offending value");
    }

    // ---- 4. ★ the CLI --engine path is covered by the SAME check ----------
    // main.cpp overwrites every NodeDef::engine AFTER loadFromFile(); reproduce
    // that here against an all-meshroute config. A parse-time check would pass
    // this case happily — which is why the refusal lives in initialize().
    {
        SimConfig mr = JsonConfig::loadFromString(oneNodeConfig("", ""));
        assert(mr.nodes[0].engine == "meshroute");
        for (auto& n : mr.nodes) n.engine = "lua";      // == `lus --engine lua`
        const std::string msg = initFailure(mr);
        assert(!msg.empty() && "★ --engine lua must be refused too");
        assert(has(msg, "DEPRECATED"));
    }

    // ---- 5. the opt-in sanctions the run, and Lua actually RUNS -----------
    // Same cfg object, opt-in flipped in memory (the CLI flag's effect).
    cfg.simulation.allow_deprecated_lua = true;
    {
        std::ostringstream out;
        SimController ctrl(cfg, out);
        ctrl.initialize();                              // must not throw
        ctrl.runUntil(cfg.simulation.duration_ms + 1000);
        ctrl.finalize();
        const std::string log = out.str();
        // Non-vacuous: the frozen Lua engine really executed — the scripted
        // sender transmitted and the scripted receiver emitted its "heard".
        assert(has(log, "\"type\":\"tx\"") &&
               "the sanctioned Lua run must actually transmit");
        assert(has(log, "\"emit_type\":\"heard\"") &&
               "the Lua script's on_recv must have run");
    }

    std::printf("test_lua_deprecated: OK "
                "(default=meshroute, lua REFUSED via config + via --engine, "
                "opt-in parses/type-checked and runs the frozen reference)\n");
    return 0;
}
