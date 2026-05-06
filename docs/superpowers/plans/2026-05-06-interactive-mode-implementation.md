# Interactive mode for lus — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add `-i` interactive REPL + `--lua` script-driven mode to the `lus` orchestrator, with a `sim:` Lua helper library shared between scripts and REPL. Refactor the per-step body of `runSimulation` into a `SimController` class so the same API powers batch, REPL, and (eventually) webapp control.

**Architecture:** `SimController` exposes step/runUntil/runUntilNextEvent/fireCommand. `runSimulation` becomes a thin wrapper. `InteractiveRepl` reads stdin, dispatches `:` meta-commands or Lua expressions. CLI flag dispatch in `main.cpp` selects batch / lua / interactive / interactive+lua mode.

**Spec:** `docs/superpowers/specs/2026-05-06-interactive-mode-design.md`

**Working repo:** `/home/staszek/lora-universal-simulator` on `main`.

---

## Conventions

- Plain commit messages, NO Co-Authored-By trailer
- Includes use repo-root paths
- Each task ends with one commit (or one feat + one test commit when test sources are substantial)
- Existing tests must continue to pass after every commit

---

## Task I1 — Refactor `runSimulation` into `SimController`

**Files:**
- Create: `orchestrator/runtime/SimController.{h,cpp}`
- Modify: `orchestrator/runtime/Loop.{h,cpp}` — `runSimulation` becomes a 4-line wrapper
- Modify: `orchestrator/CMakeLists.txt` — add `SimController.cpp`
- Create: `test/native/test_sim_controller.cpp` — unit test for step / runUntil / runUntilNextEvent / fireCommand
- Modify: `test/native/build_test.sh` — wire the new test in

This is a structural refactor: behavior must be byte-identical to today's `runSimulation`. After this task, `bash test/run_tests.sh` should still report 3/3 PASS for t01_flooder, t02_asymmetric_collision, t99_perf_smoke.

- [ ] **Step I1.1: Create SimController.h**

```cpp
// orchestrator/runtime/SimController.h
#pragma once
#include "core/topology/JsonConfig.h"
#include "orchestrator/runtime/LuaHost.h"
#include "orchestrator/runtime/ScriptedNode.h"
#include "orchestrator/runtime/TimerWheel.h"
#include "core/clock/VirtualClock.h"
#include "core/radio/SimRadio.h"
#include "core/link/LinkModel.h"
#include "core/physics/CollisionModel.h"
#include "core/physics/LbtModel.h"
#include <memory>
#include <ostream>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>

struct StepResult {
    bool     ended      = false;
    int      new_events = 0;
    uint64_t now_ms     = 0;
};

class SimController {
public:
    SimController(const SimConfig& cfg, std::ostream& events_out);
    ~SimController();

    void initialize();
    StepResult step(uint64_t advance_ms = 0);
    StepResult runUntil(uint64_t target_ms);
    StepResult runUntilNextEvent();
    std::string fireCommand(const std::string& node_name, const std::string& cmd);
    int finalize();

    uint64_t simTimeMs() const;
    int      eventCount() const;
    bool     ended() const { return _now_ms >= _cfg.simulation.duration_ms; }

    LuaHost& luaHost() { return _host; }
    const SimConfig& config() const { return _cfg; }

    // For Ctrl-C: REPL sets this to true to abort an in-progress runUntil.
    void requestInterrupt() { _interrupted = true; }

private:
    // Internal per-tick body (extracted from old runSimulation):
    void processCommandsAtStep();
    void deliverReceptionsForStep();
    void tickTimersForStep();
    void registerTransmissionsForStep();

    struct InFlight {
        int sender_id;
        uint64_t start_ms;
        uint64_t end_ms;
        std::string bytes;
        int sf, bw_hz, cr;
        std::vector<bool> collided_at_rcv;
        std::vector<int>  interferer_at_rcv;
        std::vector<float> interferer_snr_at_rcv;
    };

    const SimConfig& _cfg;
    std::ostream&    _events_out;

    LuaHost                       _host;
    VirtualClock                  _clock;
    std::mt19937                  _rng;
    std::unique_ptr<MatrixLinkModel> _links;
    std::unique_ptr<LbtModel>     _lbt;

    std::vector<std::unique_ptr<SimRadio>>     _radios;
    std::vector<std::unique_ptr<ScriptedNode>> _nodes;

    std::unordered_map<std::string, int> _name_to_id;
    std::vector<bool>                    _command_fired;
    std::vector<InFlight>                _in_flight;

    uint64_t _now_ms = 0;
    bool     _initialized = false;
    bool     _finalized = false;
    bool     _interrupted = false;
};
```

- [ ] **Step I1.2: Move per-step body into SimController.cpp**

Take the existing `runSimulation` body in `orchestrator/runtime/Loop.cpp`. The portion before the main `for` loop becomes `SimController::initialize()`. The five-stage per-step body inside the loop becomes the four `processCommandsAtStep / deliverReceptionsForStep / tickTimersForStep / registerTransmissionsForStep` methods. The post-loop `EventLog::simEnd` + `ExpectRunner::evaluate` becomes `SimController::finalize()`.

`SimController::step(advance_ms)` runs ONE pass of the per-step body, advances the clock by `advance_ms` (or `_cfg.simulation.step_ms` if 0), and returns `{ended, new_events, now_ms}`. `new_events` is computed as the buffer-size delta across the step.

`SimController::runUntil(target_ms)` loops `step()` until `_now_ms >= target_ms` OR `_interrupted` OR `ended()`. Returns the last StepResult.

`SimController::runUntilNextEvent()` loops `step()` and stops the moment the buffer-size delta is non-zero, OR `_interrupted`, OR `ended()`. Returns the StepResult.

`SimController::fireCommand(name, text)` looks up the node by name, calls `node->onCommand(text)`, emits a `cmd_reply` event, returns the reply string. If the name doesn't resolve, returns `"ERROR: unknown node"`.

Crucial: do NOT change the per-step body's behavior. The collision-marking work added in `2c31cad` (bidirectional check at TX-start), the warmup_ms instant-delivery branch from `190d984`, the lifecycle events from `3204164`, and the step_ms warning from `845053e` all stay verbatim.

- [ ] **Step I1.3: Refactor Loop.cpp to a thin wrapper**

```cpp
// orchestrator/runtime/Loop.cpp
#include "orchestrator/runtime/Loop.h"
#include "orchestrator/runtime/SimController.h"

LoopResult runSimulation(const SimConfig& cfg, std::ostream& events_out) {
    SimController ctrl(cfg, events_out);
    ctrl.initialize();
    while (!ctrl.ended()) ctrl.step();
    int failures = ctrl.finalize();
    LoopResult r;
    r.events_emitted = ctrl.eventCount();
    r.assertion_failures = failures;
    r.ok = (failures == 0);
    return r;
}
```

The old runSimulation body is fully migrated into SimController.cpp.

- [ ] **Step I1.4: Update orchestrator/CMakeLists.txt**

Add `runtime/SimController.cpp` to the `lus` executable's source list.

- [ ] **Step I1.5: Verify all existing tests pass unchanged**

```bash
cd /home/staszek/lora-universal-simulator
cmake --build build -j 4
bash test/native/build_test.sh
bash test/run_tests.sh
time ./build/orchestrator/lus test/t99_perf_smoke.json /tmp/perf_check.ndjson
```

Expected: 7/7 native + 3/3 integration PASS; perf still under 10s (was 5.9s before refactor).

- [ ] **Step I1.6: Write test/native/test_sim_controller.cpp**

```cpp
// Exercises SimController API in isolation.
#include "orchestrator/runtime/SimController.h"
#include "core/topology/JsonConfig.h"
#include <cassert>
#include <cstdio>
#include <sstream>

int main() {
    // Use the existing sample_config.json for a minimal 2-node topology.
    SimConfig cfg = JsonConfig::loadFromFile("/home/staszek/lora-universal-simulator/test/native/sample_config.json");
    std::ostringstream out;
    SimController ctrl(cfg, out);
    ctrl.initialize();

    // step(0) uses cfg.simulation.step_ms
    auto r1 = ctrl.step();
    assert(r1.now_ms > 0);
    assert(!r1.ended);

    // runUntil
    auto r2 = ctrl.runUntil(500);
    assert(r2.now_ms >= 500);

    // runUntilNextEvent — even with no commands the clock advances; this should
    // either run to end_ms (if no events fire) or stop on first event.
    auto r3 = ctrl.runUntilNextEvent();
    assert(r3.now_ms >= 500);

    // ended check after exhausting duration
    auto r4 = ctrl.runUntil(cfg.simulation.duration_ms + 1000);
    assert(r4.ended);

    int failures = ctrl.finalize();
    (void)failures;

    std::printf("test_sim_controller: OK\n");
    return 0;
}
```

(Adjust the path to sample_config.json if needed; the test's content uses an absolute path for simplicity.)

- [ ] **Step I1.7: Wire into build_test.sh**

```bash
run test_sim_controller test_sim_controller.cpp \
    $REPO_ROOT/orchestrator/runtime/SimController.cpp \
    $REPO_ROOT/orchestrator/runtime/Loop.cpp \
    $REPO_ROOT/orchestrator/runtime/LuaHost.cpp \
    $REPO_ROOT/orchestrator/runtime/ScriptedNode.cpp \
    $REPO_ROOT/orchestrator/runtime/TimerWheel.cpp \
    $REPO_ROOT/orchestrator/test_runner/ExpectRunner.cpp \
    $REPO_ROOT/core/clock/VirtualClock.cpp \
    $REPO_ROOT/core/radio/SimRadio.cpp \
    $REPO_ROOT/core/link/LinkModel.cpp \
    $REPO_ROOT/core/link/LinkFadingState.cpp \
    $REPO_ROOT/core/physics/CollisionModel.cpp \
    $REPO_ROOT/core/physics/LbtModel.cpp \
    $REPO_ROOT/core/events/EventLog.cpp \
    $REPO_ROOT/core/topology/JsonConfig.cpp \
    -llua5.4
```

(VirtualClock is header-only; remove that line if it's not a real .cpp. Adjust the source list to whatever's actually needed for the linker.)

- [ ] **Step I1.8: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add orchestrator/runtime/SimController.h orchestrator/runtime/SimController.cpp orchestrator/runtime/Loop.cpp orchestrator/CMakeLists.txt test/native/test_sim_controller.cpp test/native/build_test.sh
git -C /home/staszek/lora-universal-simulator commit -m "refactor(orchestrator): extract SimController from runSimulation

Pulls the per-step body of runSimulation into a class-based stepper:
SimController. Same per-step semantics (collision marking, warmup
instant-delivery, lifecycle events, step_ms warning) preserved verbatim.

Public API:
  initialize() / step() / runUntil() / runUntilNextEvent() /
  fireCommand() / finalize()

runSimulation is now a 4-line wrapper. All existing batch tests
(t01_flooder, t02_asymmetric_collision, t99_perf_smoke) pass with
identical behavior. New native unit test test_sim_controller exercises
the stepper API in isolation.

This is the foundation for -i interactive mode and --lua script-driven
mode (next tasks)."
```

---

## Task I2 — `sim:` Lua library

**Files:**
- Modify: `orchestrator/runtime/LuaHost.{h,cpp}` — add `bindSimGlobals(SimController&)`
- Modify: `orchestrator/runtime/SimController.cpp` — call `bindSimGlobals(*this)` during `initialize`

`LuaHost::bindSimGlobals` exposes the `sim:` table to Lua. Bindings use the `sol::object self_` first-arg pattern for colon-syntax dispatch.

- [ ] **Step I2.1: Add `LuaHost::bindSimGlobals`**

```cpp
// LuaHost.h
class SimController;   // fwd
class LuaHost {
public:
    // ... existing ...
    void bindSimGlobals(SimController& ctrl);
};
```

```cpp
// LuaHost.cpp
#include "orchestrator/runtime/SimController.h"

void LuaHost::bindSimGlobals(SimController& ctrl) {
    sol::table sim = _lua.create_named_table("sim");
    sim.set_function("time",  [&ctrl](sol::object) { return (uint64_t)ctrl.simTimeMs(); });
    sim.set_function("step",  [&ctrl](sol::object, sol::optional<uint64_t> ms) {
        StepResult r = ctrl.step(ms.value_or(0));
        sol::table t = ctrl.luaHost().lua().create_table();
        t["ended"] = r.ended; t["new_events"] = r.new_events; t["now_ms"] = (uint64_t)r.now_ms;
        return t;
    });
    sim.set_function("run", [&ctrl](sol::object, sol::optional<uint64_t> ms) {
        uint64_t target = ms.has_value()
                          ? ctrl.simTimeMs() + ms.value()
                          : ctrl.config().simulation.duration_ms;
        StepResult r = ctrl.runUntil(target);
        sol::table t = ctrl.luaHost().lua().create_table();
        t["ended"] = r.ended; t["new_events"] = r.new_events; t["now_ms"] = (uint64_t)r.now_ms;
        return t;
    });
    sim.set_function("next", [&ctrl](sol::object) {
        StepResult r = ctrl.runUntilNextEvent();
        sol::table t = ctrl.luaHost().lua().create_table();
        t["ended"] = r.ended; t["new_events"] = r.new_events; t["now_ms"] = (uint64_t)r.now_ms;
        return t;
    });
    sim.set_function("cmd", [&ctrl](sol::object, std::string node, std::string text) {
        return ctrl.fireCommand(node, text);
    });
    sim.set_function("nodes", [&ctrl](sol::object) {
        sol::table out = ctrl.luaHost().lua().create_table();
        const auto& nodes = ctrl.config().nodes;
        for (size_t i = 0; i < nodes.size(); i++) {
            sol::table entry = ctrl.luaHost().lua().create_table();
            entry["id"] = (int)i;
            entry["name"] = nodes[i].name;
            entry["script"] = nodes[i].script_path;
            out[i + 1] = entry;
        }
        return out;
    });
    sim.set_function("events", [&ctrl](sol::object, sol::optional<int> n_opt) {
        // Reach into EventLog::events() for the buffer (or expose via SimController).
        // Implementation: return the last N events as Lua tables.
        // Skipped for brevity here — implement using EventLog::events() iterator.
        // See implementation hint below.
        sol::table out = ctrl.luaHost().lua().create_table();
        (void)n_opt;
        return out;
    });
}
```

For `sim:events(n)` you'll need a JSON→Lua-table converter. ScriptedNode already has `json_to_sol` for `on_init` config; lift it (or duplicate it) into LuaHost so we can serialize the events buffer to Lua tables. Last N events: `auto& evs = EventLog::events(); int start = std::max(0, (int)evs.size() - n); for (i=start; i<evs.size(); i++) out[i-start+1] = json_to_sol(evs[i]);`

- [ ] **Step I2.2: Call `bindSimGlobals` from SimController::initialize**

After all nodes are constructed and registered, before `on_init` fires:
```cpp
_host.bindSimGlobals(*this);
```

(Place AFTER the script load loop; before the on_init loop. This way scripts can reference `sim:*` if they need to during `on_init` — though that's an unusual pattern.)

- [ ] **Step I2.3: Verify**

Quick smoke: open `lus` (no -i), run a t01_flooder. Existing tests should still pass — `sim:*` is now defined but no script uses it.

```bash
cmake --build /home/staszek/lora-universal-simulator/build -j 4
bash test/run_tests.sh
```

3/3 PASS.

- [ ] **Step I2.4: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add orchestrator/runtime/LuaHost.h orchestrator/runtime/LuaHost.cpp orchestrator/runtime/SimController.cpp
git -C /home/staszek/lora-universal-simulator commit -m "feat(runtime): sim: Lua helper library — exposes stepper to scripts/REPL

Bound to the LuaHost main state during SimController::initialize.
sim:time / step / run / next / cmd / nodes / events all use the
sol::object first-arg pattern for colon-syntax dispatch.

Same library is callable from --lua scripts and (next task) from
the interactive REPL."
```

---

## Task I3 — InteractiveRepl class

**Files:**
- Create: `orchestrator/runtime/InteractiveRepl.{h,cpp}`
- Modify: `orchestrator/CMakeLists.txt`

- [ ] **Step I3.1: Write InteractiveRepl.h**

```cpp
// orchestrator/runtime/InteractiveRepl.h
#pragma once
#include <string>

class SimController;

class InteractiveRepl {
public:
    explicit InteractiveRepl(SimController& ctrl);
    int run();
private:
    void printHelp() const;
    bool handleMeta(const std::string& line);
    void evalLua(const std::string& expr);
    SimController& _ctrl;
};

// Install / uninstall a SIGINT handler that calls SimController::requestInterrupt
// when Ctrl-C is pressed. Used by InteractiveRepl::run().
void installInterruptHandler(SimController& ctrl);
void uninstallInterruptHandler();
```

- [ ] **Step I3.2: Write InteractiveRepl.cpp**

```cpp
// orchestrator/runtime/InteractiveRepl.cpp
#include "orchestrator/runtime/InteractiveRepl.h"
#include "orchestrator/runtime/SimController.h"
#include "orchestrator/runtime/LuaHost.h"
#include <csignal>
#include <cstdio>
#include <iostream>
#include <sstream>
#include <string>

namespace {
SimController* g_ctrl_for_signal = nullptr;
extern "C" void sigintHandler(int) {
    if (g_ctrl_for_signal) g_ctrl_for_signal->requestInterrupt();
}
}

void installInterruptHandler(SimController& ctrl) {
    g_ctrl_for_signal = &ctrl;
    std::signal(SIGINT, sigintHandler);
}
void uninstallInterruptHandler() {
    g_ctrl_for_signal = nullptr;
    std::signal(SIGINT, SIG_DFL);
}

InteractiveRepl::InteractiveRepl(SimController& ctrl) : _ctrl(ctrl) {}

int InteractiveRepl::run() {
    installInterruptHandler(_ctrl);
    std::printf("lus interactive — :help for commands, Ctrl-D to exit\n");
    std::string line;
    while (true) {
        std::printf("[t=%llu] > ", (unsigned long long)_ctrl.simTimeMs());
        std::fflush(stdout);
        if (!std::getline(std::cin, line)) {
            std::printf("\n");
            break;
        }
        // Trim trailing whitespace
        while (!line.empty() && (line.back() == ' ' || line.back() == '\t' || line.back() == '\r')) {
            line.pop_back();
        }
        if (line.empty()) continue;
        if (line == ":quit" || line == ":exit") break;
        if (line[0] == ':') {
            if (!handleMeta(line)) {
                std::printf("? unknown command: %s (try :help)\n", line.c_str());
            }
        } else {
            evalLua(line);
        }
    }
    uninstallInterruptHandler();
    return 0;
}

void InteractiveRepl::printHelp() const {
    std::printf(
        ":help                 show this list\n"
        ":quit / :exit         end session (Ctrl-D also works)\n"
        ":step [ms]            advance N ms (default cfg.simulation.step_ms)\n"
        ":run [ms]             run for N ms (default: until end; Ctrl-C aborts)\n"
        ":next                 run until next event fires\n"
        ":cmd <node> <text>    fire a command at named node; print reply\n"
        ":nodes                list nodes (id, name, script)\n"
        ":events [N]           print last N events (default 10)\n"
        ":time                 print current sim time\n"
        ":lua <expr>           evaluate Lua expression (same as bare line)\n");
}

bool InteractiveRepl::handleMeta(const std::string& line) {
    // Tokenize on first space.
    auto sp = line.find(' ');
    std::string cmd = (sp == std::string::npos) ? line : line.substr(0, sp);
    std::string arg = (sp == std::string::npos) ? "" : line.substr(sp + 1);

    if (cmd == ":help") { printHelp(); return true; }
    if (cmd == ":time") { std::printf("%llu\n", (unsigned long long)_ctrl.simTimeMs()); return true; }
    if (cmd == ":nodes") {
        for (size_t i = 0; i < _ctrl.config().nodes.size(); i++) {
            std::printf("  %zu  %-16s  %s\n", i,
                        _ctrl.config().nodes[i].name.c_str(),
                        _ctrl.config().nodes[i].script_path.c_str());
        }
        return true;
    }
    if (cmd == ":step") {
        uint64_t ms = arg.empty() ? 0 : std::stoull(arg);
        auto r = _ctrl.step(ms);
        std::printf("  → t=%llums (+%d events)%s\n", (unsigned long long)r.now_ms,
                    r.new_events, r.ended ? " [end]" : "");
        return true;
    }
    if (cmd == ":run") {
        uint64_t target;
        if (arg.empty()) target = _ctrl.config().simulation.duration_ms;
        else             target = _ctrl.simTimeMs() + std::stoull(arg);
        auto r = _ctrl.runUntil(target);
        std::printf("  → t=%llums (+%d events)%s\n", (unsigned long long)r.now_ms,
                    r.new_events, r.ended ? " [end]" : "");
        return true;
    }
    if (cmd == ":next") {
        auto r = _ctrl.runUntilNextEvent();
        std::printf("  → t=%llums (+%d events)%s\n", (unsigned long long)r.now_ms,
                    r.new_events, r.ended ? " [end]" : "");
        return true;
    }
    if (cmd == ":cmd") {
        // arg is "<node> <text>"
        auto sp2 = arg.find(' ');
        if (sp2 == std::string::npos) {
            std::printf("usage: :cmd <node> <text>\n");
            return true;
        }
        std::string node = arg.substr(0, sp2);
        std::string text = arg.substr(sp2 + 1);
        std::string reply = _ctrl.fireCommand(node, text);
        std::printf("  ← %s\n", reply.c_str());
        return true;
    }
    if (cmd == ":events") {
        int n = arg.empty() ? 10 : std::stoi(arg);
        const auto& evs = EventLog::events();
        int start = std::max(0, (int)evs.size() - n);
        for (int i = start; i < (int)evs.size(); i++) {
            std::printf("  %s\n", evs[i].dump().c_str());
        }
        return true;
    }
    if (cmd == ":lua") {
        evalLua(arg);
        return true;
    }
    return false;
}

void InteractiveRepl::evalLua(const std::string& expr) {
    // Try as expression first (wrap in `return (expr)`); fall back to statement.
    auto& lua = _ctrl.luaHost().lua();
    sol::protected_function_result r = lua.safe_script(
        std::string("return (") + expr + ")",
        sol::script_pass_on_error);
    if (!r.valid()) {
        // Maybe the user typed a statement; try without `return (...)`.
        r = lua.safe_script(expr, sol::script_pass_on_error);
        if (!r.valid()) {
            sol::error err = r;
            std::printf("error: %s\n", err.what());
            return;
        }
    }
    // Print each return value.
    int n = r.return_count();
    for (int i = 0; i < n; i++) {
        sol::object v = r.get<sol::object>(i);
        sol::function tostring = lua["tostring"];
        std::string s = tostring(v);
        std::printf("  %s\n", s.c_str());
    }
}
```

- [ ] **Step I3.3: Wire into orchestrator/CMakeLists.txt**

Add `runtime/InteractiveRepl.cpp` to the `lus` target sources.

- [ ] **Step I3.4: Build sanity**

```bash
cmake --build /home/staszek/lora-universal-simulator/build -j 4
```

Should compile cleanly. The REPL isn't invoked yet — that's I4.

- [ ] **Step I3.5: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add orchestrator/runtime/InteractiveRepl.h orchestrator/runtime/InteractiveRepl.cpp orchestrator/CMakeLists.txt
git -C /home/staszek/lora-universal-simulator commit -m "feat(runtime): InteractiveRepl — line-based REPL with :meta + Lua eval

Class is independent of main.cpp's flag plumbing — that lands in I4.
Reads stdin via std::getline (no readline dep), dispatches lines
starting with ':' as meta commands, evaluates everything else as Lua
expressions in the LuaHost main state.

Meta commands: :help :quit :exit :step :run :next :cmd :nodes :events
:time :lua. Lua eval auto-falls-back from expression form to
statement form so both 'sim:time()' and 'x = 5' work at the prompt.

SIGINT handler sets SimController::requestInterrupt so :run can be
aborted with Ctrl-C without killing the process."
```

---

## Task I4 — CLI flags + mode dispatch

**Files:**
- Modify: `orchestrator/main.cpp`

- [ ] **Step I4.1: Rewrite main.cpp with argument parsing + mode dispatch**

```cpp
// orchestrator/main.cpp
#include "core/topology/JsonConfig.h"
#include "orchestrator/runtime/Loop.h"
#include "orchestrator/runtime/SimController.h"
#include "orchestrator/runtime/InteractiveRepl.h"
#include "orchestrator/runtime/LuaHost.h"
#include <cstdio>
#include <cstring>
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
        "  -h, --help                 Show this help and exit\n"
        "\n"
        "Modes:\n"
        "  (no flags)                 Batch — run to duration_ms, exit\n"
        "  --lua FILE                 Run script's main(), exit\n"
        "  -i                         Initialize then drop into REPL\n"
        "  -i --lua FILE              Run main() then drop into REPL\n",
        prog);
}
}

int main(int argc, char** argv) {
    bool interactive = false;
    std::string lua_script_path;
    std::string config_path;
    std::string events_path;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "-h" || a == "--help") { usage(argv[0]); return 0; }
        if (a == "-i" || a == "--interactive") { interactive = true; continue; }
        if (a == "-l" || a == "--lua") {
            if (i + 1 >= argc) { std::fprintf(stderr, "lus: --lua requires a path\n"); return 1; }
            lua_script_path = argv[++i];
            continue;
        }
        if (config_path.empty()) { config_path = a; continue; }
        if (events_path.empty()) { events_path = a; continue; }
        std::fprintf(stderr, "lus: unexpected arg: %s\n", a.c_str());
        usage(argv[0]); return 1;
    }
    if (config_path.empty()) {
        std::fprintf(stderr, "lus %s — lora-universal-simulator\n", LUS_VERSION);
        usage(argv[0]); return 1;
    }

    SimConfig cfg;
    try {
        cfg = JsonConfig::loadFromFile(config_path);
    } catch (const std::exception& e) {
        std::fprintf(stderr, "lus: failed to load config %s: %s\n",
                     config_path.c_str(), e.what());
        return 1;
    }

    std::ofstream events_file;
    std::ostream* out = &std::cout;
    if (!events_path.empty()) {
        events_file.open(events_path);
        if (!events_file) {
            std::fprintf(stderr, "lus: cannot open output file: %s\n", events_path.c_str());
            return 1;
        }
        out = &events_file;
    }

    // Mode dispatch
    if (!interactive && lua_script_path.empty()) {
        // Pure batch mode — preserves Y1 behavior exactly.
        try {
            LoopResult r = runSimulation(cfg, *out);
            std::fprintf(stderr, "lus: %d events emitted, %d assertion failure(s)\n",
                         r.events_emitted, r.assertion_failures);
            return r.ok ? 0 : 1;
        } catch (const std::exception& e) {
            std::fprintf(stderr, "lus: simulation aborted: %s\n", e.what());
            return 1;
        }
    }

    // Either -i or --lua (or both) — use SimController directly.
    try {
        SimController ctrl(cfg, *out);
        ctrl.initialize();

        if (!lua_script_path.empty()) {
            // Load the script in the main Lua state and try to call main() if defined.
            sol::state& lua = ctrl.luaHost().lua();
            auto r = lua.safe_script_file(lua_script_path, sol::script_pass_on_error);
            if (!r.valid()) {
                sol::error err = r;
                std::fprintf(stderr, "lus: --lua script error: %s\n", err.what());
                return 1;
            }
            sol::object main_fn = lua["main"];
            if (main_fn.is<sol::function>()) {
                auto run = main_fn.as<sol::function>().call();
                if (!run.valid()) {
                    sol::error err = run;
                    std::fprintf(stderr, "lus: main() error: %s\n", err.what());
                    return 1;
                }
            }
        }

        if (interactive) {
            InteractiveRepl repl(ctrl);
            repl.run();
        }

        int failures = ctrl.finalize();
        std::fprintf(stderr, "lus: %d events emitted, %d assertion failure(s)\n",
                     ctrl.eventCount(), failures);
        return failures == 0 ? 0 : 1;

    } catch (const std::exception& e) {
        std::fprintf(stderr, "lus: simulation aborted: %s\n", e.what());
        return 1;
    }
}
```

- [ ] **Step I4.2: Build + smoke**

```bash
cmake --build /home/staszek/lora-universal-simulator/build -j 4
```

Then verify each mode:

```bash
# Batch — should still work identically
./build/orchestrator/lus test/t01_flooder.json /tmp/r.ndjson

# Help
./build/orchestrator/lus --help

# --lua only (no main()) — should load, exit normally
echo 'print("hello from lua script"); print(sim:time())' > /tmp/h.lua
./build/orchestrator/lus --lua /tmp/h.lua test/t01_flooder.json /tmp/r.ndjson

# --lua with main()
cat > /tmp/m.lua <<'EOF'
function main()
  print("running 5s of sim from main()")
  sim:run(5000)
  print("done, t=" .. sim:time())
end
EOF
./build/orchestrator/lus --lua /tmp/m.lua test/t01_flooder.json /tmp/r.ndjson

# -i — interactive (manual test; pipe :quit to verify)
echo ':quit' | ./build/orchestrator/lus -i test/t01_flooder.json /tmp/r.ndjson
echo ':time
:nodes
:step 1000
:cmd alice send hello
:next
sim:time()
:quit' | ./build/orchestrator/lus -i test/t01_flooder.json /tmp/r.ndjson

# -i --lua combo
echo ':quit' | ./build/orchestrator/lus -i --lua /tmp/m.lua test/t01_flooder.json /tmp/r.ndjson
```

Expected outputs reasonable; no crashes.

- [ ] **Step I4.3: Run regression suite**

```bash
bash /home/staszek/lora-universal-simulator/test/native/build_test.sh
bash /home/staszek/lora-universal-simulator/test/run_tests.sh
```

7/7 native + 3/3 integration PASS.

- [ ] **Step I4.4: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add orchestrator/main.cpp
git -C /home/staszek/lora-universal-simulator commit -m "feat(orchestrator): -i interactive mode + --lua script preload

main.cpp gains argument parsing for -i/--interactive and -l/--lua.
Mode dispatch:
  (no flags)        batch — Y1 behavior preserved exactly
  --lua FILE        load script, call main() if defined, exit
  -i                initialize then drop into REPL
  -i --lua FILE     load script, call main(), drop into REPL

Smoke verified for all four modes against t01_flooder. Existing
batch invocations are byte-identical to the pre-flag pipeline."
```

---

## Self-Review

**1. Spec coverage:**
- G1 REPL grammar (`:` + bare-line) → I3
- G2 stepper API → I1
- G3 `--lua` preload → I4
- G4 `-i --lua` combo → I4
- G5 sim: library → I2
- G6 JSON config commands honored → I1 (commands continue to fire from `processCommandsAtStep`)

**2. Placeholder scan:** No "TBD" / "TODO" left as instructions to engineer. The `sim:events` body has a brief implementation hint pointing at EventLog::events() + JSON-to-Lua conversion; that's a small concrete task, not a placeholder.

**3. Type consistency:** `StepResult`, `SimController` API, `bindSimGlobals` signature consistent across I1/I2/I3/I4.

**4. Ambiguity check:**
- "Tokenize on first space" in `:cmd` parser — works for `:cmd alice send hello world` (treats "send hello world" as the command text). Document this as the intended semantic.
- `:step 0` could be ambiguous (advance by 0 or by step_ms?). The spec says default = step_ms when arg missing; explicit 0 falls into "advance by 0" which is a no-op. Acceptable.
- `sim:run()` (no arg) means "run to duration_ms"; `sim:step()` (no arg) means "advance one step_ms". Consistent with REPL.

## Execution

This plan is straightforward subagent-driven implementation. Four tasks, each ends in one commit. Estimated total: ~2 days.
