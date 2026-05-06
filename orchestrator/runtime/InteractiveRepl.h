// orchestrator/runtime/InteractiveRepl.h
//
// Line-based REPL on top of SimController. Reads stdin via std::getline,
// dispatches lines starting with ':' as meta commands, and evaluates
// everything else as Lua expressions in the LuaHost main state.
//
// Meta commands handled by handleMeta():
//   :help               show help
//   :quit / :exit       end session (also EOF / Ctrl-D)
//   :step [ms]          advance N ms (default cfg.simulation.step_ms)
//   :run  [ms]          run for N ms (default: until end; Ctrl-C aborts)
//   :next               run until next event fires
//   :cmd <node> <text>  fire a command at the named node; print reply
//   :nodes              list nodes (id, name, script)
//   :events [N]         print last N events (default 10)
//   :time               print current sim time
//   :lua <expr>         evaluate Lua expression (same as bare line)
//
// Bare lines fall through to evalLua, which first tries the input as a
// Lua expression (`return (line)`) and, if that fails, retries it as a
// statement so both `sim:time()` and `x = 5` work at the prompt.
//
// run() installs a SIGINT handler at entry that flips
// SimController::requestInterrupt(), so :run can be aborted with Ctrl-C
// without killing the process. The handler is uninstalled on exit
// (including the EOF / Ctrl-D path).
//
// This class is independent of main.cpp's flag plumbing — that lands in I4.

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

// Install / uninstall a SIGINT handler that calls
// SimController::requestInterrupt when Ctrl-C is pressed. Used by
// InteractiveRepl::run().
void installInterruptHandler(SimController& ctrl);
void uninstallInterruptHandler();
