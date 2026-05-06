# Interactive mode for lus — design

**Status:** approved by user 2026-05-06
**Scope:** orchestrator-only addition; no webapp.

---

## 1. Background

Y1's `lus` binary runs in batch mode only: read config, run to `duration_ms`, exit. We want parity with `meshcore_real_sim`'s `-i` interactive mode for protocol exploration / debugging, plus `--lua` for scripted scenario automation. The future webapp port will likely build on top of the same stepper API, so the architecture should support that.

## 2. Goals

- **G1.** REPL grammar: `:` meta-commands + bare-line Lua expressions
- **G2.** Stepper API: `step / run / run-to-next-event`
- **G3.** `--lua script.lua` preload mode (script-driven automation)
- **G4.** `-i --lua` combo: load script, run its `main()` if defined, then drop into REPL
- **G5.** `sim:` Lua helper library shared between scripts and REPL
- **G6.** JSON config's `commands[]` are honored at their `at_ms` during interactive sessions; user may also fire ad-hoc commands

## 3. Non-goals (this round)

- Webapp / WebSocket bridge (deferred to a later phase)
- Tab completion at REPL
- Persistent REPL history (no readline)
- Multi-line Lua input
- Concurrent / async simulation control

## 4. Architecture

Refactor `runSimulation()` into a class-based stepper. Public surface:

```cpp
class SimController {
public:
    SimController(const SimConfig& cfg, std::ostream& events_out);
    ~SimController();

    void initialize();                            // load scripts, on_init, emit sim_start + node_ready
    StepResult step(uint64_t advance_ms = 0);     // 0 → use cfg.simulation.step_ms
    StepResult runUntil(uint64_t target_ms);      // step until now >= target or duration ends
    StepResult runUntilNextEvent();               // step until any new event emitted (or end)
    std::string fireCommand(const std::string& node_name, const std::string& cmd);
    int finalize();                                // emit sim_end; return assertion failures

    uint64_t simTimeMs() const;
    int      eventCount() const;
    bool     ended() const;

    LuaHost& luaHost();                           // for REPL Lua eval + sim: bindings
    const SimConfig& config() const;
};

struct StepResult {
    bool     ended;        // hit duration_ms
    int      new_events;   // events emitted in this batch
    uint64_t now_ms;
};
```

The existing `runSimulation` becomes a 4-line wrapper:
```cpp
LoopResult runSimulation(const SimConfig& cfg, std::ostream& events_out) {
    SimController ctrl(cfg, events_out);
    ctrl.initialize();
    while (!ctrl.ended()) ctrl.step();
    int failures = ctrl.finalize();
    return {failures == 0, ctrl.eventCount(), failures};
}
```

The per-step body (processCommands → deliverReceptions → tickTimers → registerTransmissions → advance) moves into `SimController::step` unchanged. Constants and behavior are preserved exactly; this is a structural refactor, not a behavioral change.

## 5. `sim:` Lua library

Bound to the LuaHost's main state during `SimController::initialize`. All bindings use the leading `sol::object` pattern (matches the existing `self:` convention from commit `1c5ff86` so colon syntax works):

```lua
sim:time()                       -- → integer ms
sim:step(ms)                     -- → table {ended, new_events, now_ms}
sim:run(ms)                      -- → table {ended, new_events, now_ms}
sim:next()                       -- → table {ended, new_events, now_ms}; runs to next event
sim:cmd(name, text)              -- → string reply (whatever the node's on_command returned)
sim:nodes()                      -- → array of {id, name, script}
sim:events(n)                    -- → array of last N events as Lua tables
```

These are the C++ stepper methods exposed verbatim. Same library is callable from `--lua` scripts and from the REPL.

## 6. REPL

```cpp
class InteractiveRepl {
public:
    InteractiveRepl(SimController& ctrl);
    int run();               // returns exit code
private:
    void processLine(const std::string& line);
    bool handleMeta(const std::string& line);     // returns true if handled
    void evalLua(const std::string& expr);
    SimController& _ctrl;
    bool _interrupt = false;                      // set by SIGINT
};
```

- Line input: `std::getline(std::cin, line)`. No readline dependency for v1.
- Meta-command dispatch by string-prefix match on lines starting with `:`.
- Bare lines (no `:`) are evaluated as Lua expressions in the main state. Print each return value via `tostring()`.
- SIGINT installs a handler that sets `_interrupt`; `:run` checks it between steps.

### Meta-command set

| Command | Behavior |
|---|---|
| `:help` | Print command list |
| `:quit` / `:exit` / Ctrl-D | Exit REPL |
| `:step [ms]` | Advance N ms (default: cfg.simulation.step_ms) |
| `:run [ms]` | Run N ms (default: until duration_ms; Ctrl-C aborts) |
| `:next` | Run until next event fires; print the event |
| `:cmd <node> <text>` | Fire a command; print reply |
| `:nodes` | List nodes (id, name, script) |
| `:events [N]` | Print last N events from the buffer (default 10) |
| `:time` | Print current sim time |
| `:lua <expr>` | Explicit Lua-eval form (same as a bare line) |

## 7. CLI flags

```
Usage: lus [options] <config.json> [events.ndjson]

Options:
  -i, --interactive          Open REPL after preload (if any)
  -l, --lua <script>         Load Lua script; if it defines main(), call it
  -h, --help                 Show help and exit
```

Mode dispatch in `main.cpp`:

| Flags | Behavior |
|---|---|
| (none) | Batch — run to `duration_ms`, exit (current behavior, unchanged) |
| `--lua FILE` | Load script, call `main()` if defined, exit |
| `-i` | Initialize sim, drop into REPL immediately |
| `-i --lua FILE` | Load script, call `main()` if defined, then drop into REPL |

## 8. Files

- New: `orchestrator/runtime/SimController.{h,cpp}`
- New: `orchestrator/runtime/InteractiveRepl.{h,cpp}`
- Modify: `orchestrator/runtime/Loop.{h,cpp}` — `runSimulation` becomes a thin wrapper
- Modify: `orchestrator/main.cpp` — argument parsing + mode dispatch
- Modify: `orchestrator/CMakeLists.txt` — add new sources

## 9. Acceptance

- All existing tests still pass (T1 flooder, T2 asymmetric collision, T99 perf smoke, 7 native unit tests)
- New native unit test exercises `SimController::step / runUntil / runUntilNextEvent / fireCommand`
- Manual smoke verification:
  - `lus -i test/t01_flooder.json` → REPL opens, user can type `:step 1000`, `:cmd alice send hello`, `:next`, `sim:time()`
  - `lus --lua some_script.lua test/t01_flooder.json` → script's `main()` runs, exits cleanly
  - Combined `lus -i --lua some_script.lua test/t01_flooder.json` → script's `main()` runs, then REPL opens

## 10. Risks

- **Re-entrancy.** A node's `on_recv` could in principle call `sim:step()`. Document as undefined; if we hit it, add a re-entrancy guard that errors from `sim.*` while already in step.
- **Ctrl-C UX.** Need a SIGINT handler that sets a stop flag the run loop checks between steps. Don't use `std::abort` from the handler — set the flag, let the main loop exit cleanly.
- **Performance.** REPL is human-paced; `step` semantics in batch mode shouldn't regress (all the existing per-step machinery moves verbatim).
- **Interrupted run during script-driven mode.** If `--lua` script calls `sim:run(60s)` and Ctrl-C arrives, `runUntil` should return cleanly with the interrupt flag set; the script can decide what to do.

## 11. Open questions deferred

- Tab completion + readline history — Y3+
- Multi-line Lua input — punt; expressions only for v1
- WebSocket-driven REPL — comes with the future webapp port
