#include <cstdio>
#include <string>

#include "orchestrator/runtime/LuaHost.h"
#include "sol/sol.hpp"

namespace {
constexpr const char* LUS_VERSION = "0.1.0";
}

int main(int argc, char** argv) {
    LuaHost host;
    auto sanity = host.lua().safe_script("return 42", sol::script_pass_on_error);
    if (!sanity.valid() || sanity.get<int>() != 42) {
        std::fprintf(stderr, "lus: lua sanity check failed\n");
        return 1;
    }

    std::printf("lus %s — lora-universal-simulator\n", LUS_VERSION);
    if (argc > 1) {
        std::printf("(would simulate config: %s — but the runtime isn't wired yet)\n", argv[1]);
    }
    return 0;
}
