// orchestrator/runtime/InteractiveRepl.cpp
//
// Implementation of the InteractiveRepl class. See header for the API
// contract. Notes worth highlighting at the implementation level:
//
//   * SIGINT handler. Installed at run() entry, uninstalled at every
//     exit path (including EOF / Ctrl-D). The handler must be C-linkage
//     to be portable in C++17, hence the `extern "C"` on sigintHandler.
//     The static `g_ctrl_for_signal` pointer is the only handle the
//     handler has to the controller; we clear it on uninstall to avoid
//     dangling-pointer surprises if a stray SIGINT fires post-shutdown.
//
//   * Lua eval fallback. We first try the input as an expression by
//     wrapping it in `return (...)`. If that fails to compile or run we
//     fall through and retry the raw line as a statement. This way
//     `sim:time()` prints its result and `x = 5` is a silent
//     assignment, both at the same prompt.
//
//   * `:cmd <node> <text>` parsing. The first space after `:cmd`
//     separates the node name; everything after that — up to and
//     including end-of-line — is treated as the command text, exactly
//     as the shell-style cfg.commands[].command field is.
//
//   * Empty input + trailing whitespace. A bare Enter just re-prompts.
//     Trailing spaces / tabs / `\r` are trimmed before parsing so that
//     terminals which emit `\r\n` (and pasted lines from such sources)
//     still match the static `:quit` / `:exit` / etc. literals.

#include "orchestrator/runtime/InteractiveRepl.h"

#include "orchestrator/runtime/LuaHost.h"
#include "orchestrator/runtime/SimController.h"

#include "core/events/EventLog.h"
#include "core/topology/JsonConfig.h"

#include "sol/sol.hpp"

#include <algorithm>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

SimController* g_ctrl_for_signal = nullptr;

extern "C" void sigintHandler(int /*signum*/) {
    if (g_ctrl_for_signal) {
        g_ctrl_for_signal->requestInterrupt();
    }
}

}  // namespace

void installInterruptHandler(SimController& ctrl) {
    g_ctrl_for_signal = &ctrl;
    std::signal(SIGINT, sigintHandler);
}

void uninstallInterruptHandler() {
    std::signal(SIGINT, SIG_DFL);
    g_ctrl_for_signal = nullptr;
}

InteractiveRepl::InteractiveRepl(SimController& ctrl) : _ctrl(ctrl) {}

int InteractiveRepl::run() {
    installInterruptHandler(_ctrl);

    std::printf("lus interactive — :help for commands, Ctrl-D to exit\n");

    std::string line;
    while (true) {
        std::printf("[t=%llu] > ",
                    static_cast<unsigned long long>(_ctrl.simTimeMs()));
        std::fflush(stdout);

        if (!std::getline(std::cin, line)) {
            // EOF (Ctrl-D) or stream error — exit cleanly with a newline
            // so the next shell prompt isn't glued to our last prompt.
            std::printf("\n");
            break;
        }

        // Trim trailing whitespace (spaces, tabs, CR).
        while (!line.empty() &&
               (line.back() == ' ' || line.back() == '\t' ||
                line.back() == '\r')) {
            line.pop_back();
        }

        if (line.empty()) continue;

        if (line == ":quit" || line == ":exit") break;

        if (line[0] == ':') {
            if (!handleMeta(line)) {
                std::printf("? unknown command: %s (try :help)\n",
                            line.c_str());
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
        ":run  [ms]            run for N ms (default: until end; Ctrl-C aborts)\n"
        ":next                 run until next event fires\n"
        ":cmd <node> <text>    fire a command at named node; print reply\n"
        ":nodes                list nodes (id, name, script)\n"
        ":events [N]           print last N events (default 10)\n"
        ":time                 print current sim time\n"
        ":lua <expr>           evaluate Lua expression (same as bare line)\n");
}

bool InteractiveRepl::handleMeta(const std::string& line) {
    // Tokenize on first space: cmd / arg.
    const auto sp = line.find(' ');
    const std::string cmd = (sp == std::string::npos) ? line : line.substr(0, sp);
    const std::string arg = (sp == std::string::npos) ? std::string() : line.substr(sp + 1);

    if (cmd == ":help") {
        printHelp();
        return true;
    }
    if (cmd == ":time") {
        std::printf("%llu\n", static_cast<unsigned long long>(_ctrl.simTimeMs()));
        return true;
    }
    if (cmd == ":nodes") {
        const auto& nodes = _ctrl.config().nodes;
        for (size_t i = 0; i < nodes.size(); ++i) {
            const int protocol_id = nodes[i].node_id >= 0
                ? nodes[i].node_id
                : static_cast<int>(i);
            std::printf("  %zu  proto=%-3d  %-16s  %s\n", i, protocol_id,
                        nodes[i].name.c_str(),
                        nodes[i].script_path.c_str());
        }
        return true;
    }
    if (cmd == ":step") {
        uint64_t ms = 0;
        if (!arg.empty()) {
            try {
                ms = std::stoull(arg);
            } catch (const std::exception&) {
                std::printf("usage: :step [ms]\n");
                return true;
            }
        }
        StepResult r = _ctrl.step(ms);
        std::printf("  -> t=%llums (+%d events)%s\n",
                    static_cast<unsigned long long>(r.now_ms),
                    r.new_events,
                    r.ended ? " [end]" : "");
        return true;
    }
    if (cmd == ":run") {
        uint64_t target;
        if (arg.empty()) {
            target = static_cast<uint64_t>(_ctrl.config().simulation.duration_ms);
        } else {
            try {
                target = _ctrl.simTimeMs() + std::stoull(arg);
            } catch (const std::exception&) {
                std::printf("usage: :run [ms]\n");
                return true;
            }
        }
        StepResult r = _ctrl.runUntil(target);
        std::printf("  -> t=%llums (+%d events)%s\n",
                    static_cast<unsigned long long>(r.now_ms),
                    r.new_events,
                    r.ended ? " [end]" : "");
        return true;
    }
    if (cmd == ":next") {
        StepResult r = _ctrl.runUntilNextEvent();
        std::printf("  -> t=%llums (+%d events)%s\n",
                    static_cast<unsigned long long>(r.now_ms),
                    r.new_events,
                    r.ended ? " [end]" : "");
        return true;
    }
    if (cmd == ":cmd") {
        // arg is "<node> <text>" — split on the FIRST space; everything
        // after that is the command text (which may itself contain spaces).
        const auto sp2 = arg.find(' ');
        if (sp2 == std::string::npos) {
            std::printf("usage: :cmd <node> <text>\n");
            return true;
        }
        const std::string node = arg.substr(0, sp2);
        const std::string text = arg.substr(sp2 + 1);
        const std::string reply = _ctrl.fireCommand(node, text);
        std::printf("  <- %s\n", reply.c_str());
        return true;
    }
    if (cmd == ":events") {
        int n = 10;
        if (!arg.empty()) {
            try {
                n = std::stoi(arg);
            } catch (const std::exception&) {
                std::printf("usage: :events [N]\n");
                return true;
            }
        }
        const auto& evs = EventLog::events();
        const int total = static_cast<int>(evs.size());
        const int start = std::max(0, total - n);
        for (int i = start; i < total; ++i) {
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
    if (expr.empty()) return;

    sol::state& lua = _ctrl.luaHost().lua();

    // Try as expression first: wrap in `return (...)` so a single
    // value-producing line prints its result. If that compile/run fails
    // we silently retry the raw text as a statement so assignments etc.
    // still work.
    sol::protected_function_result r = lua.safe_script(
        std::string("return (") + expr + ")",
        sol::script_pass_on_error);

    if (!r.valid()) {
        r = lua.safe_script(expr, sol::script_pass_on_error);
        if (!r.valid()) {
            sol::error err = r;
            std::printf("error: %s\n", err.what());
            return;
        }
    }

    // Print every return value via tostring().
    sol::function tostring = lua["tostring"];
    const int n = r.return_count();
    for (int i = 0; i < n; ++i) {
        sol::object v = r.get<sol::object>(i);
        std::string s = tostring(v);
        std::printf("  %s\n", s.c_str());
    }
}
