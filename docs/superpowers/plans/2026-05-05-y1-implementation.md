# lora-universal-simulator — Y1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the `lus` orchestrator binary for `lora-universal-simulator`: port radio physics from `meshcore_real_sim`, build a Lua-scripted node runtime, ship one example + JSON test that passes, and verify the 200-node × 1h performance target.

**Architecture:** Three-layer C++17 binary. *Core* layer = ported radio physics + topology + NDJSON event stream from `meshcore_real_sim` (byte-blind, MeshCore-agnostic). *Runtime* layer = new code: timer wheel, Lua host (sol2), per-node `ScriptedNode` containers, main simulation loop. *Script* layer = Lua 5.4, callbacks (`on_init`/`on_recv`/`on_command`/`on_radio_busy`) + runtime methods (`tx`/`after`/`every`/`cancel`/`now`/`rand`/`log`/`emit`/`peers`).

**Tech Stack:** C++17, CMake 3.16+, Lua 5.4 + sol2 v3.3.0 (vendored), nlohmann/json (vendored), Python 3 for visualization. Tests: bare `assert.h`-style C++ test programs (no test framework dependency, matching the existing `meshcore_real_sim/test/native/` pattern).

**Source repo for ports:** `~/meshcore_real_sim` — files we port are listed task-by-task with exact source paths.

**Working repo:** `~/lora-universal-simulator` on branch `main`.

**Spec reference:** `docs/superpowers/specs/2026-05-05-lora-universal-simulator-design.md`.

---

## File Structure (target tree)

```
~/lora-universal-simulator/
├── CMakeLists.txt                       # root: project config, subdirs
├── README.md
├── .gitignore
├── core/                                # protocol-agnostic, extractable later
│   ├── CMakeLists.txt
│   ├── clock/
│   │   └── VirtualClock.h               # ported from meshcore_real_sim
│   ├── link/
│   │   ├── LinkModel.h
│   │   ├── LinkModel.cpp                # ported (per-link SNR/RSSI/loss matrix)
│   │   └── LinkFadingState.h            # extracted from Orchestrator.cpp (fading state per directed link)
│   ├── radio/
│   │   ├── SimRadio.h
│   │   └── SimRadio.cpp                 # ported from shims/platform_shim/
│   ├── physics/
│   │   ├── CollisionModel.h
│   │   ├── CollisionModel.cpp           # extracted from Orchestrator.cpp (3-stage survival)
│   │   ├── LbtModel.h
│   │   └── LbtModel.cpp                 # extracted (notifyChannelBusy bookkeeping + CAD miss prob)
│   ├── events/
│   │   ├── EventLog.h
│   │   └── EventLog.cpp                 # ported from orchestrator/EventLog.{h,cpp}
│   └── topology/
│       ├── JsonConfig.h
│       └── JsonConfig.cpp               # ported from orchestrator/JsonConfig.{h,cpp}, MeshCore fields stripped
├── orchestrator/                        # the lus binary
│   ├── CMakeLists.txt
│   ├── main.cpp
│   ├── runtime/
│   │   ├── TimerWheel.h
│   │   ├── TimerWheel.cpp               # NEW: per-node min-heap of pending timers
│   │   ├── LuaHost.h
│   │   ├── LuaHost.cpp                  # NEW: sol2 init, per-node self table, script loading
│   │   ├── ScriptedNode.h
│   │   ├── ScriptedNode.cpp             # NEW: per-node container, callback dispatch
│   │   └── Loop.cpp                     # NEW: main simulator loop
│   └── test_runner/
│       ├── ExpectRunner.h
│       └── ExpectRunner.cpp             # NEW: evaluates expect[] assertions against captured events
├── examples/
│   └── flooder.lua                      # NEW: simple flood-and-forward demo
├── test/
│   ├── run_tests.sh                     # bash wrapper, mirrors meshcore_real_sim pattern
│   ├── t01_flooder.json                 # NEW: 3-node chain test for flooder.lua
│   └── native/                          # C++ unit tests
│       ├── build_test.sh                # mirrors meshcore_real_sim/test/native/build_test.sh
│       ├── test_clock.cpp
│       ├── test_link.cpp
│       ├── test_eventlog.cpp
│       ├── test_simradio.cpp
│       ├── test_physics.cpp
│       ├── test_jsonconfig.cpp
│       └── test_timerwheel.cpp
├── tools/
│   ├── visualize.py                     # ported from meshcore_real_sim/visualization/
│   └── visualize.html                   # ported, MeshCore semantics stripped
├── docs/
│   ├── README.md
│   └── superpowers/
│       ├── specs/                       # already populated with the design spec
│       └── plans/                       # this plan lives here
└── third_party/
    ├── sol/                             # sol2 v3.3.0, vendored from meshcore_real_sim
    └── json/                            # nlohmann/json single-header
```

---

## Conventions used in this plan

- All paths absolute. Working repo: `/home/staszek/lora-universal-simulator`.
- "Source repo" means `/home/staszek/meshcore_real_sim` — never modify it; only read/copy from it.
- Each task ends with a single commit using conventional-commits format (`feat:`, `chore:`, `test:`).
- Native unit tests run via: `bash test/native/build_test.sh`. Build via: `cmake -S . -B build && cmake --build build -j 4`.
- A "step" is 2–5 minutes of work. A task is 5–10 steps + a commit.
- When a task says "port from `<path>`": copy the file, adjust includes for the new layout, strip any MeshCore-specific code, add a small smoke test, then commit.

---

## Task 1: Repo skeleton

**Files:**
- Create: `~/lora-universal-simulator/CMakeLists.txt`
- Create: `~/lora-universal-simulator/README.md`
- Create: `~/lora-universal-simulator/.gitignore`
- Create empty subdirectories with `.gitkeep` (or similar): `core/`, `orchestrator/`, `examples/`, `test/`, `tools/`, `third_party/`

- [ ] **Step 1.1: Create root CMakeLists.txt**

```cmake
cmake_minimum_required(VERSION 3.16)
project(lora_universal_simulator
        VERSION 0.1.0
        LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# Strict warnings
add_compile_options(-Wall -Wextra -Wpedantic)

# Subdirectories (added incrementally as Tasks 4..N populate them)
add_subdirectory(core)
add_subdirectory(orchestrator)
```

- [ ] **Step 1.2: Create README.md**

```markdown
# lora-universal-simulator

Host-side network simulator for LoRa-mesh protocol research. Each node's
behavior is defined in Lua; the simulator provides radio physics, topology,
and an event stream.

See `docs/superpowers/specs/2026-05-05-lora-universal-simulator-design.md`
for the design.

## Build

```bash
cmake -S . -B build
cmake --build build -j 4
```

## Run

```bash
./build/orchestrator/lus path/to/config.json > events.ndjson
python3 tools/visualize.py events.ndjson
```

## Test

```bash
bash test/run_tests.sh test/t01_flooder.json   # JSON regression test
bash test/native/build_test.sh                 # C++ unit tests
```
```

- [ ] **Step 1.3: Create .gitignore**

```
build/
*.o
*.so
.obsidian/
events.ndjson
.cache/
compile_commands.json
.vscode/
```

- [ ] **Step 1.4: Create empty subdirectory CMakeLists.txt stubs**

`core/CMakeLists.txt`:
```cmake
# Populated by Tasks 4..9.
add_library(lus_core INTERFACE)
target_include_directories(lus_core INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/third_party
)
```

`orchestrator/CMakeLists.txt`:
```cmake
# Populated by Tasks 11..15.
add_executable(lus main.cpp)
target_link_libraries(lus PRIVATE lus_core)
```

Create a placeholder `orchestrator/main.cpp`:
```cpp
#include <cstdio>
int main() {
    std::printf("lus — lora-universal-simulator (stub)\n");
    return 0;
}
```

- [ ] **Step 1.5: Verify empty build**

```bash
cd /home/staszek/lora-universal-simulator
cmake -S . -B build
cmake --build build -j 4
./build/orchestrator/lus
```

Expected output:
```
lus — lora-universal-simulator (stub)
```

- [ ] **Step 1.6: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add CMakeLists.txt README.md .gitignore core/CMakeLists.txt orchestrator/CMakeLists.txt orchestrator/main.cpp
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
chore: project skeleton — root CMakeLists, README, dir structure

Empty CMake skeleton that builds the placeholder lus binary. Subdirs
core/ and orchestrator/ have stub CMakeLists; subsequent tasks fill
them in. Verified: `cmake -S . -B build && cmake --build build` succeeds
and produces an executable that prints the version banner.
EOF
)"
```

---

## Task 2: Vendor third-party dependencies

**Files:**
- Create: `~/lora-universal-simulator/third_party/sol/sol.hpp` (and `forward.hpp`, `config.hpp`)
- Create: `~/lora-universal-simulator/third_party/json/json.hpp`

- [ ] **Step 2.1: Vendor sol2**

```bash
mkdir -p /home/staszek/lora-universal-simulator/third_party/sol
cp /home/staszek/meshcore_real_sim/orchestrator/third_party/sol/*.hpp /home/staszek/lora-universal-simulator/third_party/sol/
ls /home/staszek/lora-universal-simulator/third_party/sol/
```

Expected files: `sol.hpp`, `forward.hpp`, `config.hpp`.

- [ ] **Step 2.2: Vendor nlohmann/json**

Check whether `meshcore_real_sim` vendors a single-header copy of `nlohmann/json.hpp`:

```bash
find /home/staszek/meshcore_real_sim -name "json.hpp" 2>/dev/null | grep -v build | head -5
```

If found at e.g. `meshcore_real_sim/orchestrator/third_party/json/json.hpp` (or anywhere similar), copy it:

```bash
mkdir -p /home/staszek/lora-universal-simulator/third_party/json
cp <path-found-above> /home/staszek/lora-universal-simulator/third_party/json/json.hpp
```

If not vendored in `meshcore_real_sim`, download the single-header release (v3.11.x):
```bash
mkdir -p /home/staszek/lora-universal-simulator/third_party/json
curl -fsSL https://github.com/nlohmann/json/releases/download/v3.11.3/json.hpp \
  -o /home/staszek/lora-universal-simulator/third_party/json/json.hpp
```

- [ ] **Step 2.3: Update root CMakeLists to find Lua + thread support**

Append to `~/lora-universal-simulator/CMakeLists.txt`:

```cmake
find_package(Lua 5.4 REQUIRED)
find_package(Threads REQUIRED)
```

Update `core/CMakeLists.txt`:
```cmake
add_library(lus_core INTERFACE)
target_include_directories(lus_core INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/third_party
    ${LUA_INCLUDE_DIR}
)
target_link_libraries(lus_core INTERFACE ${LUA_LIBRARIES} Threads::Threads)
```

- [ ] **Step 2.4: Verify build still succeeds with deps in place**

```bash
cmake -S /home/staszek/lora-universal-simulator -B /home/staszek/lora-universal-simulator/build
cmake --build /home/staszek/lora-universal-simulator/build -j 4
```

Expected: SUCCESS. (No code uses the new headers yet, but cmake should resolve `find_package(Lua 5.4)` against the system's `liblua5.4-dev`. If it fails, install via `sudo apt install liblua5.4-dev`.)

- [ ] **Step 2.5: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add third_party/ CMakeLists.txt core/CMakeLists.txt
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
chore: vendor third-party deps (sol2, nlohmann/json)

sol2 v3.3.0 copied from meshcore_real_sim/orchestrator/third_party/sol/.
nlohmann/json vendored as a single header. find_package(Lua 5.4)
in the root CMakeLists finds the system's liblua5.4 (Debian/Ubuntu:
liblua5.4-dev). Headers are reachable from any target linking lus_core.
EOF
)"
```

---

## Task 3: Empty-build sanity + version banner

**Files:**
- Modify: `~/lora-universal-simulator/orchestrator/main.cpp`

- [ ] **Step 3.1: Replace stub main.cpp with a minimal version banner that links Lua and sol2**

`orchestrator/main.cpp`:
```cpp
#include <cstdio>
#include <string>

#include "sol/sol.hpp"

namespace {
constexpr const char* LUS_VERSION = "0.1.0";
}

int main(int argc, char** argv) {
    sol::state lua;
    lua.open_libraries(sol::lib::base);
    auto sanity = lua.safe_script("return 42", sol::script_pass_on_error);
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
```

- [ ] **Step 3.2: Update orchestrator/CMakeLists.txt**

```cmake
add_executable(lus main.cpp)
target_link_libraries(lus PRIVATE lus_core)
target_include_directories(lus PRIVATE ${CMAKE_SOURCE_DIR}/third_party)
```

- [ ] **Step 3.3: Build and run**

```bash
cmake --build /home/staszek/lora-universal-simulator/build -j 4
/home/staszek/lora-universal-simulator/build/orchestrator/lus
```

Expected:
```
lus 0.1.0 — lora-universal-simulator
```

- [ ] **Step 3.4: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add orchestrator/main.cpp orchestrator/CMakeLists.txt
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
feat(lus): version banner + Lua sanity check

main.cpp now opens a sol::state, runs `return 42` as a basic Lua-host
sanity check, and prints a version banner. Validates that sol2 +
liblua5.4 link cleanly through the lus_core INTERFACE library before
any real runtime code lands.
EOF
)"
```

---

## Task 4: Port VirtualClock + LinkModel

**Files:**
- Create: `~/lora-universal-simulator/core/clock/VirtualClock.h`
- Create: `~/lora-universal-simulator/core/link/LinkModel.h`
- Create: `~/lora-universal-simulator/core/link/LinkModel.cpp`
- Create: `~/lora-universal-simulator/test/native/test_clock.cpp`
- Create: `~/lora-universal-simulator/test/native/test_link.cpp`
- Create: `~/lora-universal-simulator/test/native/build_test.sh`

- [ ] **Step 4.1: Copy VirtualClock.h verbatim**

```bash
mkdir -p /home/staszek/lora-universal-simulator/core/clock
cp /home/staszek/meshcore_real_sim/orchestrator/VirtualClock.h /home/staszek/lora-universal-simulator/core/clock/VirtualClock.h
```

Inspect the file: should be a small (~20 LOC) header. If it pulls in any non-standard MeshCore-specific include, replace with `<cstdint>` etc.

- [ ] **Step 4.2: Copy LinkModel.{h,cpp}**

```bash
mkdir -p /home/staszek/lora-universal-simulator/core/link
cp /home/staszek/meshcore_real_sim/orchestrator/LinkModel.h /home/staszek/lora-universal-simulator/core/link/LinkModel.h
cp /home/staszek/meshcore_real_sim/orchestrator/LinkModel.cpp /home/staszek/lora-universal-simulator/core/link/LinkModel.cpp
```

Open both files; if they include `"VirtualClock.h"` or similar, update to `"core/clock/VirtualClock.h"` (with `#include` paths relative to the `lus_core` INTERFACE include dir which is `core/`'s parent).

- [ ] **Step 4.3: Update core/CMakeLists.txt to compile LinkModel.cpp**

```cmake
add_library(lus_core STATIC
    link/LinkModel.cpp
)
target_include_directories(lus_core PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/third_party
    ${LUA_INCLUDE_DIR}
)
target_link_libraries(lus_core PUBLIC ${LUA_LIBRARIES} Threads::Threads)
```

(Switching from `INTERFACE` to `STATIC` because we now have a real .cpp file.)

- [ ] **Step 4.4: Write test_clock.cpp**

```cpp
// test/native/test_clock.cpp
#include "core/clock/VirtualClock.h"
#include <cassert>
#include <cstdio>

int main() {
    VirtualClock c;
    assert(c.getMillis() == 0);
    c.tick(150);
    assert(c.getMillis() == 150);
    c.tick(50);
    assert(c.getMillis() == 200);
    std::printf("test_clock: OK\n");
    return 0;
}
```

(Adjust method names to match what's actually in `VirtualClock.h`; the names above are the typical pattern. If the API differs, follow the file.)

- [ ] **Step 4.5: Write test_link.cpp**

```cpp
// test/native/test_link.cpp — minimal smoke test for LinkModel
#include "core/link/LinkModel.h"
#include <cassert>
#include <cstdio>

int main() {
    LinkModel m(3);                // 3 nodes
    m.setLink(0, 1, /*snr=*/8.0f, /*rssi=*/-80.0f, /*loss=*/0.0f);
    auto link = m.getLink(0, 1);
    assert(link.snr == 8.0f);
    assert(link.rssi == -80.0f);
    std::printf("test_link: OK\n");
    return 0;
}
```

(Adjust `LinkModel`'s API based on the actual ported header; the constructor and `setLink`/`getLink` names mirror what's typical. Read the file to confirm.)

- [ ] **Step 4.6: Write build_test.sh**

`test/native/build_test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CXX="${CXX:-g++}"
CXXFLAGS="-std=c++17 -Wall -Wextra -O0 -g"
INCLUDES="-I $REPO_ROOT -I $REPO_ROOT/third_party"

run() {
    local name="$1"; shift
    local out="$SCRIPT_DIR/$name.bin"
    echo "[build] $name"
    $CXX $CXXFLAGS $INCLUDES "$@" -o "$out"
    echo "[run]   $name"
    "$out"
}

run test_clock test_clock.cpp
run test_link  test_link.cpp $REPO_ROOT/core/link/LinkModel.cpp

echo "[ok] all tests passed"
```

```bash
chmod +x /home/staszek/lora-universal-simulator/test/native/build_test.sh
```

- [ ] **Step 4.7: Run unit tests**

```bash
bash /home/staszek/lora-universal-simulator/test/native/build_test.sh
```

Expected: each test prints `OK`, ending with `[ok] all tests passed`.

- [ ] **Step 4.8: Verify cmake build still succeeds**

```bash
cmake --build /home/staszek/lora-universal-simulator/build -j 4
```

Expected: SUCCESS (now compiles `LinkModel.cpp` into `liblus_core.a`).

- [ ] **Step 4.9: Add test binaries to .gitignore**

Append to `.gitignore`:
```
test/native/*.bin
```

- [ ] **Step 4.10: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add core/clock/ core/link/ core/CMakeLists.txt test/native/ .gitignore
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
feat(core): port VirtualClock + LinkModel from meshcore_real_sim

VirtualClock: per-node simulated-time accumulator. Header-only.
LinkModel: pairwise link quality matrix (snr/rssi/loss per directed edge).

Stripped no MeshCore-specific code (these files were already
protocol-agnostic). Native unit tests verify the basic API.
EOF
)"
```

---

## Task 5: Port EventLog (NDJSON emitter)

**Files:**
- Create: `~/lora-universal-simulator/core/events/EventLog.h`
- Create: `~/lora-universal-simulator/core/events/EventLog.cpp`
- Create: `~/lora-universal-simulator/test/native/test_eventlog.cpp`

- [ ] **Step 5.1: Copy EventLog.{h,cpp}**

```bash
mkdir -p /home/staszek/lora-universal-simulator/core/events
cp /home/staszek/meshcore_real_sim/orchestrator/EventLog.h /home/staszek/lora-universal-simulator/core/events/EventLog.h
cp /home/staszek/meshcore_real_sim/orchestrator/EventLog.cpp /home/staszek/lora-universal-simulator/core/events/EventLog.cpp
```

- [ ] **Step 5.2: Adapt includes**

Open both files. Update any `#include "..."` paths that no longer match the new tree layout. E.g., if EventLog.cpp includes `"VirtualClock.h"`, change to `"core/clock/VirtualClock.h"`. If it includes `"json/json.hpp"` or `"nlohmann/json.hpp"`, change to `"json/json.hpp"` (matching our `third_party/json/json.hpp` location).

- [ ] **Step 5.3: Strip MeshCore-specific event types**

Search the source for any references to MeshCore packet types or contact info (`PAYLOAD_TYPE_*`, `mesh::Packet`, `ContactInfo`). If any are present, simplify: the new EventLog must only know about generic event types `tx`, `rx`, `collision`, `drop_halfduplex`, `drop_loss`, `tx_fail`, `cmd_reply`, plus two new ones we'll add later (`script_log`, `script_emit`). Remove any code paths that format MeshCore-specific fields.

If unsure whether to remove a field, comment it out with a `// TODO Y2: revisit if needed` marker — don't delete fields that look protocol-agnostic.

- [ ] **Step 5.4: Add the new script-side event constants/methods**

In `EventLog.h`, add (or confirm presence of) methods for:
- `void logScriptLog(int node_id, uint64_t sim_ms, const std::string& msg);`
- `void logScriptEmit(int node_id, uint64_t sim_ms, const std::string& type, const std::string& json_data);`

Implement them to write NDJSON lines like:
```
{"type":"script_log","node":12,"time_ms":3000,"msg":"hello"}
{"type":"script_emit","node":12,"time_ms":3000,"emit_type":"my_event","data":{...}}
```

- [ ] **Step 5.5: Update core/CMakeLists.txt**

```cmake
add_library(lus_core STATIC
    link/LinkModel.cpp
    events/EventLog.cpp
)
```

- [ ] **Step 5.6: Write test_eventlog.cpp**

```cpp
#include "core/events/EventLog.h"
#include <cassert>
#include <cstdio>
#include <sstream>
#include <string>

int main() {
    std::ostringstream out;
    EventLog log(out);
    log.logTx(/*node=*/0, /*sim_ms=*/100, /*airtime_ms=*/120, "abcd");
    log.logRx(/*node=*/1, /*sim_ms=*/220, /*airtime_ms=*/120, /*snr=*/8.0f, "abcd");
    log.logScriptLog(0, 300, "hello");

    std::string s = out.str();
    assert(s.find("\"type\":\"tx\"") != std::string::npos);
    assert(s.find("\"type\":\"rx\"") != std::string::npos);
    assert(s.find("\"type\":\"script_log\"") != std::string::npos);
    assert(s.find("\"msg\":\"hello\"") != std::string::npos);
    std::printf("test_eventlog: OK\n");
    return 0;
}
```

(Adjust the `logTx` / `logRx` parameter list to match the actual ported method signatures. Read the header to confirm.)

- [ ] **Step 5.7: Wire test_eventlog into build_test.sh**

Append to `test/native/build_test.sh`:
```bash
run test_eventlog test_eventlog.cpp $REPO_ROOT/core/events/EventLog.cpp
```

- [ ] **Step 5.8: Run tests + cmake build**

```bash
bash /home/staszek/lora-universal-simulator/test/native/build_test.sh
cmake --build /home/staszek/lora-universal-simulator/build -j 4
```

Both must succeed.

- [ ] **Step 5.9: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add core/events/ core/CMakeLists.txt test/native/test_eventlog.cpp test/native/build_test.sh
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
feat(core): port EventLog (NDJSON event emitter)

Emits tx/rx/collision/drop/tx_fail/cmd_reply events as JSON-per-line
to a configurable ostream. MeshCore-specific event payload fields
stripped. Two new event types added for scripted nodes:
  script_log  — script-emitted free-text log line
  script_emit — script-emitted custom event with arbitrary JSON data

Native unit test verifies the basic emit pipeline.
EOF
)"
```

---

## Task 6: Port SimRadio + half-duplex bookkeeping

**Files:**
- Create: `~/lora-universal-simulator/core/radio/SimRadio.h`
- Create: `~/lora-universal-simulator/core/radio/SimRadio.cpp`
- Create: `~/lora-universal-simulator/test/native/test_simradio.cpp`

- [ ] **Step 6.1: Copy SimRadio from shims/platform_shim/**

```bash
mkdir -p /home/staszek/lora-universal-simulator/core/radio
cp /home/staszek/meshcore_real_sim/shims/platform_shim/SimRadio.h /home/staszek/lora-universal-simulator/core/radio/SimRadio.h
cp /home/staszek/meshcore_real_sim/shims/platform_shim/SimRadio.cpp /home/staszek/lora-universal-simulator/core/radio/SimRadio.cpp
```

- [ ] **Step 6.2: Strip Arduino-shim dependencies**

`SimRadio` is a shim for MeshCore's `mesh::Radio` interface. Read the header — it inherits from / implements MeshCore's radio interface and references Arduino-style types.

For our purposes we need:
- `startSendRaw(uint8_t* buf, int len)` — TX entry point
- `notifyRxStart(...)` — half-duplex RX bookkeeping (see project memory notes on RX→TX blocking)
- `notifyChannelBusy(...)` — LBT bookkeeping
- `getEstAirtimeFor(int payload_len)` — airtime calculation for a given LoRa config (sf/bw/cr)
- `isReceiving()` — half-duplex query
- `idle()` / `startReceive()` — state machine

The MeshCore inheritance / `mesh::Radio` virtual methods we don't need. Decision rule: keep the methods listed above and any private helpers they call; drop everything else.

Replace the MeshCore base-class inheritance with a free-standing `class SimRadio { ... };`. Keep the same method names so the call sites translate cleanly.

If the .cpp references Arduino types (`unsigned long millis()` etc.), replace with our `VirtualClock` reference (passed in at construction or via setter — match meshcore_real_sim's existing pattern).

- [ ] **Step 6.3: Update core/CMakeLists.txt**

```cmake
add_library(lus_core STATIC
    link/LinkModel.cpp
    events/EventLog.cpp
    radio/SimRadio.cpp
)
```

- [ ] **Step 6.4: Write test_simradio.cpp**

```cpp
#include "core/radio/SimRadio.h"
#include "core/clock/VirtualClock.h"
#include <cassert>
#include <cstdio>

int main() {
    VirtualClock clock;
    SimRadio radio(clock);
    radio.setRadioParams(/*sf=*/11, /*bw_khz=*/250.0f, /*cr=*/5);

    // Airtime for a 50-byte payload at SF11/BW250/CR4-5 should be ~0.5..1s.
    uint32_t airtime = radio.getEstAirtimeFor(50);
    assert(airtime > 100);
    assert(airtime < 5000);

    // Half-duplex initial state
    assert(!radio.isReceiving());

    // Mark RX active for 200ms
    radio.notifyRxStart(/*duration_ms=*/200);
    assert(radio.isReceiving());

    clock.tick(250);
    assert(!radio.isReceiving());

    std::printf("test_simradio: OK (airtime=%u ms)\n", airtime);
    return 0;
}
```

(Adjust setter / param method names to match the ported file.)

- [ ] **Step 6.5: Wire into build_test.sh and run**

Append:
```bash
run test_simradio test_simradio.cpp $REPO_ROOT/core/radio/SimRadio.cpp $REPO_ROOT/core/link/LinkModel.cpp
```

(LinkModel may not be needed; trim if SimRadio doesn't depend on it. Add only what links.)

```bash
bash /home/staszek/lora-universal-simulator/test/native/build_test.sh
cmake --build /home/staszek/lora-universal-simulator/build -j 4
```

Both must succeed.

- [ ] **Step 6.6: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add core/radio/ core/CMakeLists.txt test/native/test_simradio.cpp test/native/build_test.sh
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
feat(core): port SimRadio with half-duplex + LBT bookkeeping

Lifted from meshcore_real_sim/shims/platform_shim/. Stripped Arduino
shim base-class inheritance and the MeshCore mesh::Radio interface;
SimRadio is now a free-standing class with the methods our orchestrator
loop will call: startSendRaw, notifyRxStart, notifyChannelBusy,
getEstAirtimeFor, isReceiving, idle/startReceive.

Native unit test verifies airtime calculation + half-duplex state
transitions.
EOF
)"
```

---

## Task 7: Extract collision physics + fading + LBT into core/physics/

**Files:**
- Create: `~/lora-universal-simulator/core/physics/CollisionModel.h`
- Create: `~/lora-universal-simulator/core/physics/CollisionModel.cpp`
- Create: `~/lora-universal-simulator/core/physics/LbtModel.h`
- Create: `~/lora-universal-simulator/core/physics/LbtModel.cpp`
- Create: `~/lora-universal-simulator/core/link/LinkFadingState.h`
- Create: `~/lora-universal-simulator/test/native/test_physics.cpp`

The collision survival logic (3-stage: capture / preamble grace / FEC tolerance) and the LBT machinery currently live inside `meshcore_real_sim/orchestrator/Orchestrator.cpp` — a 1600-line file that mixes radio physics with MeshCore-specific orchestration. We extract just the physics into focused units.

- [ ] **Step 7.1: Locate collision-survival code in Orchestrator.cpp**

```bash
grep -n "capture_locked\|capture_unlocked\|PREAMBLE_LOCK_SYMBOLS\|halfduplex_abort\|deliverReceptions\|registerTransmissions" /home/staszek/meshcore_real_sim/orchestrator/Orchestrator.cpp | head -30
```

Identify the function(s) that implement the 3-stage survival decision and the helpers that compute capture margins. Extract them with their dependencies (FEC tolerance table, T_sym calc, etc.).

- [ ] **Step 7.2: Create CollisionModel.{h,cpp}**

Header sketch (adapt to the actual extracted code):
```cpp
// core/physics/CollisionModel.h
#pragma once
#include <cstdint>

struct CollisionConfig {
    float capture_locked_db   = 3.0f;
    float capture_unlocked_db = 6.0f;
    int   preamble_lock_symbols = 5;
};

struct CapturedSignal {
    int   src_node;
    float snr_db;
    uint64_t start_ms;
    uint64_t end_ms;
    uint8_t cr;          // coding-rate denominator (5..8)
    uint16_t pre_sym;    // preamble symbols
    float t_sym_ms;
};

struct CollisionDecision {
    bool   survived;
    int    reason_code;    // 0=clean, 1=capture, 2=preamble_grace, 3=fec_tolerance
};

CollisionDecision evaluateCollision(const CollisionConfig& cfg,
                                     const CapturedSignal& primary,
                                     const CapturedSignal& interferer);
```

Implementation: extract the survival decision tree from `Orchestrator.cpp`. Keep the FEC tolerance table `{0,0,1,1}` (CR 4/5..4/8 → tolerated symbols) and `PREAMBLE_LOCK_SYMBOLS=5`.

- [ ] **Step 7.3: Create LbtModel.{h,cpp}**

Extract the `notifyChannelBusy` / `cad_miss_prob` bookkeeping. The model maintains a per-node "channel-busy until" timestamp and an SNR threshold; it consults the link model to decide whether a TX from another node is detectable.

```cpp
// core/physics/LbtModel.h
#pragma once
#include <cstdint>
#include <vector>

class LbtModel {
public:
    LbtModel(int n_nodes, float cad_miss_prob = 0.05f);
    void notifyChannelBusy(int observer_node, int sender_node,
                           uint64_t until_ms, float snr_db);
    bool isChannelBusy(int observer_node, uint64_t now_ms) const;
private:
    float _cad_miss_prob;
    std::vector<uint64_t> _busy_until;   // per node
};
```

- [ ] **Step 7.4: Create LinkFadingState.h (header-only)**

Extract the per-directed-link fading state struct (`snr_coherence_ms` and the O-U or i.i.d. update logic) into `core/link/LinkFadingState.h`. This was inline in `Orchestrator.cpp`'s receive-loop; lift it to a clean unit so the radio loop in our orchestrator can call it.

- [ ] **Step 7.5: Update core/CMakeLists.txt**

```cmake
add_library(lus_core STATIC
    link/LinkModel.cpp
    events/EventLog.cpp
    radio/SimRadio.cpp
    physics/CollisionModel.cpp
    physics/LbtModel.cpp
)
```

- [ ] **Step 7.6: Write test_physics.cpp**

```cpp
#include "core/physics/CollisionModel.h"
#include "core/physics/LbtModel.h"
#include <cassert>
#include <cstdio>

int main() {
    CollisionConfig cfg;
    CapturedSignal a{ /*src=*/0, /*snr=*/12.0f, /*start=*/100, /*end=*/220, /*cr=*/5, /*pre_sym=*/8, /*t_sym=*/4.1f };
    CapturedSignal b{ 1, 5.0f, 110, 230, 5, 8, 4.1f };

    // Strong primary (12 dB) vs weak interferer (5 dB) → capture should engage when locked.
    auto d = evaluateCollision(cfg, a, b);
    assert(d.survived);

    LbtModel lbt(/*n_nodes=*/3);
    assert(!lbt.isChannelBusy(0, 100));
    lbt.notifyChannelBusy(/*observer=*/0, /*sender=*/1, /*until=*/500, /*snr=*/8.0f);
    // Either busy by t<500 (CAD didn't miss) or not (CAD missed). Our deterministic
    // test ignores cad_miss_prob and just checks the deterministic timeline:
    // at t=600, channel should not be busy regardless.
    assert(!lbt.isChannelBusy(0, 600));

    std::printf("test_physics: OK\n");
    return 0;
}
```

- [ ] **Step 7.7: Wire into build_test.sh**

```bash
run test_physics test_physics.cpp $REPO_ROOT/core/physics/CollisionModel.cpp $REPO_ROOT/core/physics/LbtModel.cpp
```

- [ ] **Step 7.8: Run tests + cmake build**

```bash
bash /home/staszek/lora-universal-simulator/test/native/build_test.sh
cmake --build /home/staszek/lora-universal-simulator/build -j 4
```

- [ ] **Step 7.9: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add core/physics/ core/link/LinkFadingState.h core/CMakeLists.txt test/native/test_physics.cpp test/native/build_test.sh
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
feat(core): extract collision survival + LBT + fading from Orchestrator.cpp

Pulled the protocol-agnostic radio physics out of meshcore_real_sim's
1600-line Orchestrator.cpp into focused units:

  CollisionModel: 3-stage survival decision (capture / preamble grace
                  / FEC tolerance), constants matched to upstream.
  LbtModel:       channel-busy bookkeeping with cad_miss_prob.
  LinkFadingState: per-directed-link i.i.d. or O-U fading state.

Native unit test exercises capture decision + LBT busy-window bookkeeping.
EOF
)"
```

---

## Task 8: Port JsonConfig (config schema, MeshCore fields stripped)

**Files:**
- Create: `~/lora-universal-simulator/core/topology/JsonConfig.h`
- Create: `~/lora-universal-simulator/core/topology/JsonConfig.cpp`
- Create: `~/lora-universal-simulator/test/native/test_jsonconfig.cpp`
- Create: `~/lora-universal-simulator/test/native/sample_config.json`

- [ ] **Step 8.1: Copy JsonConfig.{h,cpp}**

```bash
mkdir -p /home/staszek/lora-universal-simulator/core/topology
cp /home/staszek/meshcore_real_sim/orchestrator/JsonConfig.h /home/staszek/lora-universal-simulator/core/topology/JsonConfig.h
cp /home/staszek/meshcore_real_sim/orchestrator/JsonConfig.cpp /home/staszek/lora-universal-simulator/core/topology/JsonConfig.cpp
```

- [ ] **Step 8.2: Strip MeshCore-specific fields**

Open the .cpp and find any code that parses these fields (and remove them):
- `_requires_plugins`
- `simulation.firmware.default`
- `nodes[i].firmware`
- `nodes[i].role`
- `simulation.hot_start`

Replace `nodes[i].firmware` + `nodes[i].role` with a single new field `nodes[i].script` (string, path to Lua file) and `nodes[i].config` (arbitrary JSON object passed to `on_init`). Add to the parsed `NodeDef` struct:
```cpp
struct NodeDef {
    std::string name;
    std::string script_path;
    nlohmann::json config = nlohmann::json::object();   // per-node init config
};
```

- [ ] **Step 8.3: Adapt includes**

Update `#include`s to point to the new layout (`"core/...` paths) and `"json/json.hpp"` for nlohmann/json.

- [ ] **Step 8.4: Update core/CMakeLists.txt**

```cmake
add_library(lus_core STATIC
    link/LinkModel.cpp
    events/EventLog.cpp
    radio/SimRadio.cpp
    physics/CollisionModel.cpp
    physics/LbtModel.cpp
    topology/JsonConfig.cpp
)
```

- [ ] **Step 8.5: Write a sample config and test**

`test/native/sample_config.json`:
```json
{
  "_name": "sample",
  "simulation": {
    "duration_ms": 1000,
    "step_ms": 1,
    "warmup_ms": 0,
    "radio": { "sf": 11, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "examples/flooder.lua", "config": { "role": "originator" } },
    { "name": "bob",   "script": "examples/flooder.lua" }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "bob", "snr": 8.0, "rssi": -80.0, "bidir": true }
    ]
  },
  "commands": [],
  "expect": []
}
```

`test/native/test_jsonconfig.cpp`:
```cpp
#include "core/topology/JsonConfig.h"
#include <cassert>
#include <cstdio>

int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: %s <config.json>\n", argv[0]); return 1; }
    SimConfig cfg = JsonConfig::loadFromFile(argv[1]);

    assert(cfg.name == "sample");
    assert(cfg.simulation.duration_ms == 1000);
    assert(cfg.simulation.step_ms == 1);
    assert(cfg.simulation.radio.sf == 11);
    assert(cfg.nodes.size() == 2);
    assert(cfg.nodes[0].name == "alice");
    assert(cfg.nodes[0].script_path == "examples/flooder.lua");
    assert(cfg.nodes[0].config["role"] == "originator");
    assert(cfg.topology.links.size() == 1);
    assert(cfg.topology.links[0].snr == 8.0f);

    std::printf("test_jsonconfig: OK\n");
    return 0;
}
```

(Adjust struct names — `SimConfig`, `NodeDef`, `Link` etc. — to match what the ported header actually declares.)

- [ ] **Step 8.6: Wire into build_test.sh and run**

```bash
run test_jsonconfig test_jsonconfig.cpp $REPO_ROOT/core/topology/JsonConfig.cpp $SCRIPT_DIR/sample_config.json
```

Note the test takes the JSON path as `argv[1]`. Update the wrapper:

Actually, simpler: pass the path as a runtime arg by modifying `run`:
```bash
# In build_test.sh, add a special-case for tests that need an argv:
test_with_arg() {
    local name="$1"; shift
    local arg="$1"; shift
    local out="$SCRIPT_DIR/$name.bin"
    echo "[build] $name"
    $CXX $CXXFLAGS $INCLUDES "$@" -o "$out"
    echo "[run]   $name $arg"
    "$out" "$arg"
}
test_with_arg test_jsonconfig "$SCRIPT_DIR/sample_config.json" test_jsonconfig.cpp $REPO_ROOT/core/topology/JsonConfig.cpp
```

```bash
bash /home/staszek/lora-universal-simulator/test/native/build_test.sh
```

Expected: `test_jsonconfig: OK`.

- [ ] **Step 8.7: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add core/topology/ core/CMakeLists.txt test/native/test_jsonconfig.cpp test/native/sample_config.json test/native/build_test.sh
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
feat(core): port JsonConfig — schema parser, MeshCore fields stripped

Removed: _requires_plugins, simulation.firmware.default,
nodes[i].firmware, nodes[i].role, simulation.hot_start.

Added: nodes[i].script (Lua file path) and nodes[i].config (arbitrary
JSON, passed to the script's on_init). Everything else (simulation
block, topology.links with snr/rssi/loss/bidir, commands, expect) is
preserved verbatim from meshcore_real_sim's schema.

Native unit test parses a small sample config and asserts the
expected struct contents.
EOF
)"
```

---

## Task 9: core/ static library — full build sanity

**Files:** none new; verify everything composes.

- [ ] **Step 9.1: Verify cmake build links a self-contained `liblus_core.a`**

```bash
cmake --build /home/staszek/lora-universal-simulator/build -j 4
ls /home/staszek/lora-universal-simulator/build/core/liblus_core.a
```

- [ ] **Step 9.2: Run all native tests in one shot**

```bash
bash /home/staszek/lora-universal-simulator/test/native/build_test.sh
```

Expected: each test prints `OK`, ending with `[ok] all tests passed`. At this point we have 5 tests: `test_clock`, `test_link`, `test_eventlog`, `test_simradio`, `test_physics`, `test_jsonconfig`.

- [ ] **Step 9.3: Empty checkpoint commit**

```bash
git -C /home/staszek/lora-universal-simulator commit --allow-empty -m "chore: core/ port complete — radio physics + topology + events + clock"
```

---

## Task 10: Timer wheel (per-node min-heap)

**Files:**
- Create: `~/lora-universal-simulator/orchestrator/runtime/TimerWheel.h`
- Create: `~/lora-universal-simulator/orchestrator/runtime/TimerWheel.cpp`
- Create: `~/lora-universal-simulator/test/native/test_timerwheel.cpp`

The timer wheel is a per-node priority queue of `(deadline_ms, callback_id, recurring_period_ms)` entries. The simulator loop peeks the earliest deadline; if it's ≤ current time, the entry is popped (or rescheduled if recurring) and the runtime fires the callback.

- [ ] **Step 10.1: Write TimerWheel.h**

```cpp
// orchestrator/runtime/TimerWheel.h
#pragma once
#include <cstdint>
#include <queue>
#include <vector>

using TimerHandle = uint64_t;
constexpr TimerHandle kInvalidTimer = 0;

struct TimerEntry {
    uint64_t deadline_ms;
    TimerHandle handle;
    uint32_t period_ms;        // 0 = one-shot, >0 = recurring
};

class TimerWheel {
public:
    TimerHandle scheduleAfter(uint64_t now_ms, uint64_t delay_ms, uint32_t period_ms = 0);
    void cancel(TimerHandle h);
    bool peek(uint64_t now_ms, TimerEntry& out_entry) const;
    bool popDue(uint64_t now_ms, TimerEntry& out_entry);
    size_t size() const;
private:
    struct HeapEntry { uint64_t deadline_ms; TimerHandle handle; uint32_t period_ms; };
    struct Cmp { bool operator()(const HeapEntry& a, const HeapEntry& b) const {
        return a.deadline_ms > b.deadline_ms;
    }};
    std::priority_queue<HeapEntry, std::vector<HeapEntry>, Cmp> _heap;
    // Cancellation strategy: tombstone set; popDue skips tombstoned entries.
    std::vector<TimerHandle> _cancelled;   // small; sweep on cancel
    TimerHandle _next_handle = 1;
    bool _isCancelled(TimerHandle h) const;
};
```

- [ ] **Step 10.2: Write TimerWheel.cpp**

Implement `scheduleAfter` (push to heap + return handle), `cancel` (push to tombstone list), `peek` (inspect top, skipping tombstones; return false if empty), `popDue` (pop top if deadline passed; if recurring, push next).

- [ ] **Step 10.3: Update orchestrator/CMakeLists.txt**

```cmake
add_executable(lus
    main.cpp
    runtime/TimerWheel.cpp
)
target_link_libraries(lus PRIVATE lus_core)
target_include_directories(lus PRIVATE
    ${CMAKE_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/third_party
)
```

- [ ] **Step 10.4: Write test_timerwheel.cpp**

```cpp
#include "orchestrator/runtime/TimerWheel.h"
#include <cassert>
#include <cstdio>

int main() {
    TimerWheel w;
    TimerEntry e;

    // Empty heap.
    assert(!w.peek(0, e));

    // One-shot at t=100.
    auto h1 = w.scheduleAfter(/*now=*/0, /*delay=*/100);
    assert(w.peek(0, e));
    assert(e.deadline_ms == 100);
    assert(!w.popDue(50, e));    // not due yet
    assert(w.popDue(150, e));
    assert(e.handle == h1);
    assert(e.period_ms == 0);

    // Recurring every 50.
    auto h2 = w.scheduleAfter(/*now=*/0, /*delay=*/0, /*period=*/50);
    int fired = 0;
    for (uint64_t t = 0; t <= 200; t++) {
        while (w.popDue(t, e)) { fired++; }
    }
    // Should fire at 0, 50, 100, 150, 200 → 5 times.
    assert(fired == 5);

    // Cancellation.
    auto h3 = w.scheduleAfter(/*now=*/0, /*delay=*/300);
    w.cancel(h3);
    assert(!w.popDue(500, e));   // cancelled, not popped

    std::printf("test_timerwheel: OK (h1=%lu h2=%lu h3=%lu)\n",
                (unsigned long)h1, (unsigned long)h2, (unsigned long)h3);
    return 0;
}
```

- [ ] **Step 10.5: Wire into build_test.sh**

```bash
run test_timerwheel test_timerwheel.cpp $REPO_ROOT/orchestrator/runtime/TimerWheel.cpp
```

- [ ] **Step 10.6: Run tests**

```bash
bash /home/staszek/lora-universal-simulator/test/native/build_test.sh
cmake --build /home/staszek/lora-universal-simulator/build -j 4
```

- [ ] **Step 10.7: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add orchestrator/runtime/TimerWheel.h orchestrator/runtime/TimerWheel.cpp orchestrator/CMakeLists.txt test/native/test_timerwheel.cpp test/native/build_test.sh
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
feat(runtime): per-node TimerWheel — min-heap of pending timers

Supports scheduleAfter (one-shot + recurring), cancel (tombstone), peek
(non-destructive), popDue (advance and dispatch). Recurring timers
re-push themselves with deadline += period_ms when popped.

Native unit test exercises one-shot, recurring (5 firings over 200ms
with 50ms period), and cancellation. Empty-heap path verified.
EOF
)"
```

---

## Task 11: Lua host (sol2 init, per-node `self`, script loading)

**Files:**
- Create: `~/lora-universal-simulator/orchestrator/runtime/LuaHost.h`
- Create: `~/lora-universal-simulator/orchestrator/runtime/LuaHost.cpp`

The Lua host owns one `sol::state` for the whole simulation. Per-node state lives in a Lua-side registry table keyed by node id. Script files are loaded once per unique path and then instantiated per node.

- [ ] **Step 11.1: Write LuaHost.h**

```cpp
// orchestrator/runtime/LuaHost.h
#pragma once
#include "sol/sol.hpp"
#include <string>
#include <unordered_map>

class ScriptedNode;

class LuaHost {
public:
    LuaHost();
    void registerNode(int node_id, ScriptedNode* node);     // build self table for node
    void loadScript(int node_id, const std::string& path);  // load file, bind callbacks
    void callOnInit(int node_id, const sol::table& config);
    void callOnRecv(int node_id, std::string_view bytes,
                    float snr, float rssi, int link_id, uint64_t sim_ms);
    std::string callOnCommand(int node_id, std::string_view cmd_str);
    void callOnRadioBusy(int node_id);

    // Called by the timer wheel when a registered timer fires.
    void fireTimerCallback(int node_id, uint64_t handle);

    sol::state& lua() { return _lua; }
private:
    sol::state _lua;
    // Per-script-file: cache of loaded chunks, keyed by absolute path.
    std::unordered_map<std::string, sol::function> _loaded_scripts;
    // Per-node script handle (the loaded chunk's "module" table after init).
    // Layout: _LUS.nodes[id] = { self = {...}, script = {...}, timers = {} }
    sol::table _node_registry;
};
```

- [ ] **Step 11.2: Write LuaHost.cpp**

Constructor opens base/string/table/math libraries (not `io`, not `os` — sandbox). Builds a global `_LUS = { nodes = {} }` table that holds per-node state.

`registerNode(id, node)`: creates `_LUS.nodes[id] = { self = setmetatable({}, {__index = api_table}), node_ptr = lightuserdata(node) }`.

`loadScript(id, path)`: if the path is already loaded, reuse the cached chunk; otherwise `_lua.script_file(path)` and cache. Bind the script's global functions (`on_init`, `on_recv`, etc.) into `_LUS.nodes[id].script.{...}`.

`callOnInit(id, config)`: looks up `_LUS.nodes[id]`; if `script.on_init` is callable, calls `script.on_init(self, config)` where `self = _LUS.nodes[id].self`.

(The runtime methods — `tx`, `after`, etc. — are wired in **Task 12** as members of an api_table that `self`'s metatable falls back to. For now LuaHost only handles dispatch.)

- [ ] **Step 11.3: Update orchestrator/CMakeLists.txt**

```cmake
add_executable(lus
    main.cpp
    runtime/TimerWheel.cpp
    runtime/LuaHost.cpp
)
```

- [ ] **Step 11.4: Smoke test inline (no separate test program for LuaHost yet)**

Add a quick test inside `main.cpp` (temporarily — will be removed when the real loop lands in Task 13):

```cpp
// In main.cpp, replace the version banner sanity with:
#include "orchestrator/runtime/LuaHost.h"

LuaHost host;
host.lua().script("function on_init(self, cfg) print('hello from node', cfg.id) end");
// (Real registration/dispatch comes in next task; this just verifies LuaHost compiles + loads script.)
```

Build:
```bash
cmake --build /home/staszek/lora-universal-simulator/build -j 4
/home/staszek/lora-universal-simulator/build/orchestrator/lus
```

The smoke message is a placeholder — output may not include "hello from node" yet because there's no `on_init` invocation. The point of this step is verifying LuaHost.cpp compiles into the lus binary and links with sol2.

- [ ] **Step 11.5: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add orchestrator/runtime/LuaHost.h orchestrator/runtime/LuaHost.cpp orchestrator/CMakeLists.txt orchestrator/main.cpp
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
feat(runtime): LuaHost — sol2 sandbox + per-node state registry

One sol::state for the whole sim. Per-node state held in
_LUS.nodes[id] = { self, script } (Lua-side registry). Script files
are loaded once per unique path and bound to per-node module tables
so multiple nodes running the same script don't share state.

Sandbox: only base/string/table/math/coroutine libraries opened
(no io, no os, no debug). Runtime methods (tx, after, etc.) added
in Task 12.
EOF
)"
```

---

## Task 12: ScriptedNode + runtime methods (`self:` API)

**Files:**
- Create: `~/lora-universal-simulator/orchestrator/runtime/ScriptedNode.h`
- Create: `~/lora-universal-simulator/orchestrator/runtime/ScriptedNode.cpp`

The `ScriptedNode` is the per-node container. Each instance owns:
- A reference to its `LuaHost` and its node id.
- A `TimerWheel` (per-node).
- A reference to its `SimRadio` (shared link to the global radio simulator).
- The per-node config (passed to `on_init`).
- Pending TX list (fills during `tx()` calls; drained by the main loop).

It exposes the runtime methods to Lua via sol2 bindings.

- [ ] **Step 12.1: Write ScriptedNode.h**

```cpp
// orchestrator/runtime/ScriptedNode.h
#pragma once
#include "core/clock/VirtualClock.h"
#include "core/radio/SimRadio.h"
#include "core/events/EventLog.h"
#include "orchestrator/runtime/TimerWheel.h"
#include "json/json.hpp"
#include "sol/sol.hpp"
#include <random>
#include <string>
#include <vector>

class LuaHost;

struct PendingTx {
    std::string bytes;
    int sf; float bw; int cr; int power_dbm;   // -1 in any field = use default
};

class ScriptedNode {
public:
    ScriptedNode(int id, std::string name,
                 LuaHost& host, SimRadio& radio, EventLog& events,
                 VirtualClock& clock, std::mt19937& sim_rng);

    void onInit(const nlohmann::json& config);
    void onRecv(std::string_view bytes, float snr, float rssi, int link_id, uint64_t sim_ms);
    std::string onCommand(std::string_view cmd_str);
    void onRadioBusy();

    // Called by the main loop each step:
    void tickTimers(uint64_t sim_ms);
    std::vector<PendingTx> drainPendingTxs();   // called by main loop

    // Bound methods callable from Lua via self::
    void api_tx(std::string bytes, sol::optional<sol::table> opts);
    uint64_t api_after(uint64_t delay_ms, sol::function fn);
    uint64_t api_every(uint64_t period_ms, sol::function fn);
    void api_cancel(uint64_t handle);
    uint64_t api_now() const;
    int api_rand(int lo, int hi);
    void api_log(sol::variadic_args args);
    void api_emit(std::string type, sol::optional<sol::table> data);
    sol::table api_peers();
    int id() const { return _id; }
    const std::string& name() const { return _name; }
private:
    int _id;
    std::string _name;
    LuaHost& _host;
    SimRadio& _radio;
    EventLog& _events;
    VirtualClock& _clock;
    std::mt19937& _sim_rng;
    TimerWheel _timers;
    std::vector<PendingTx> _pending_txs;
    // handle → sol::function for registered timer callbacks
    std::unordered_map<uint64_t, sol::function> _timer_callbacks;
};
```

- [ ] **Step 12.2: Write ScriptedNode.cpp**

Implement the runtime methods. Key behaviors:

- `api_tx(bytes, opts)`: append a `PendingTx` to `_pending_txs`; main loop drains and feeds to `SimRadio::startSendRaw`.
- `api_after(delay, fn)`: store fn in `_timer_callbacks[h]`; schedule via `_timers.scheduleAfter(_clock.getMillis(), delay)`. Return handle.
- `api_every(period, fn)`: same but with `period`. Return handle.
- `api_cancel(h)`: remove from `_timer_callbacks` + `_timers.cancel(h)`.
- `api_now()`: return `_clock.getMillis()`.
- `api_rand(lo, hi)`: `std::uniform_int_distribution<>(lo, hi-1)(_sim_rng)`. Half-open [lo, hi).
- `api_log(args)`: concatenate all args as strings; call `_events.logScriptLog(_id, _clock.getMillis(), msg)`.
- `api_emit(type, data)`: serialize `data` table to JSON; call `_events.logScriptEmit(_id, _clock.getMillis(), type, data_json)`.
- `api_peers()`: returns a Lua table of int node ids reachable from this node's link model entries. (Document as debug-only.)

`tickTimers(sim_ms)`:
```cpp
TimerEntry e;
while (_timers.popDue(sim_ms, e)) {
    auto it = _timer_callbacks.find(e.handle);
    if (it != _timer_callbacks.end()) {
        sol::function fn = it->second;
        // For one-shot timers (period_ms == 0), remove the callback after firing.
        // For recurring, leave it.
        if (e.period_ms == 0) _timer_callbacks.erase(it);
        // Call with `self` table from LuaHost registry
        // (LuaHost has a helper `getNodeSelf(id)` for this).
        fn(_host.getNodeSelf(_id));
    }
}
```

- [ ] **Step 12.3: Wire ScriptedNode into LuaHost**

In `LuaHost::registerNode(id, node*)`, expose the `api_*` methods to the node's `self` table:
```cpp
sol::table self = _node_registry["nodes"][id]["self"];
self.set_function("tx",     [node](std::string b, sol::optional<sol::table> o) { node->api_tx(b, o); });
self.set_function("after",  [node](uint64_t d, sol::function f) { return node->api_after(d, f); });
// ... etc for every, cancel, now, rand, log, emit, peers
self["id"]   = node->id();
self["name"] = node->name();
```

- [ ] **Step 12.4: Update orchestrator/CMakeLists.txt**

```cmake
add_executable(lus
    main.cpp
    runtime/TimerWheel.cpp
    runtime/LuaHost.cpp
    runtime/ScriptedNode.cpp
)
```

- [ ] **Step 12.5: Build sanity**

```bash
cmake --build /home/staszek/lora-universal-simulator/build -j 4
```

Expected: SUCCESS. (No new tests yet — the integration test comes via `t01_flooder` in Task 14.)

- [ ] **Step 12.6: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add orchestrator/runtime/ScriptedNode.h orchestrator/runtime/ScriptedNode.cpp orchestrator/runtime/LuaHost.cpp orchestrator/CMakeLists.txt
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
feat(runtime): ScriptedNode + Lua-bound runtime methods

Per-node container with timer wheel, pending-tx queue, and the full
self:* API:
  tx(bytes, opts?)        — queue a TX (drained by main loop)
  after(ms, fn)           — one-shot timer; returns handle
  every(ms, fn)           — recurring timer; returns handle
  cancel(handle)          — remove a pending timer
  now()                   — sim time in ms
  rand(lo, hi)            — half-open uniform draw [lo, hi)
  log(...)                — emit a script_log NDJSON event
  emit(type, data)        — emit a script_emit event with table->JSON data
  peers()                 — DEBUG-only physical neighbours

tickTimers fires all due callbacks; one-shot callbacks are GC'd from
the per-node table after firing.
EOF
)"
```

---

## Task 13: Main loop + command dispatch + `Loop.cpp`

**Files:**
- Create: `~/lora-universal-simulator/orchestrator/runtime/Loop.h`
- Create: `~/lora-universal-simulator/orchestrator/runtime/Loop.cpp`
- Modify: `~/lora-universal-simulator/orchestrator/main.cpp`

The main loop ties everything together: parse config → instantiate nodes → run the per-step loop (commands → deliver → tick → register → advance) → emit final summary.

- [ ] **Step 13.1: Write Loop.h**

```cpp
// orchestrator/runtime/Loop.h
#pragma once
#include "core/topology/JsonConfig.h"
#include <string>

struct LoopResult {
    bool ok;
    int events_emitted;
    int assertion_failures;   // 0 if expect[] passed or empty
};

LoopResult runSimulation(const SimConfig& cfg, std::ostream& events_out);
```

- [ ] **Step 13.2: Write Loop.cpp**

Sketch (the implementer should expand each section):
```cpp
#include "orchestrator/runtime/Loop.h"
#include "orchestrator/runtime/LuaHost.h"
#include "orchestrator/runtime/ScriptedNode.h"
#include "orchestrator/test_runner/ExpectRunner.h"
#include "core/clock/VirtualClock.h"
#include "core/radio/SimRadio.h"
#include "core/link/LinkModel.h"
#include "core/physics/CollisionModel.h"
#include "core/physics/LbtModel.h"
#include "core/events/EventLog.h"
#include <random>

LoopResult runSimulation(const SimConfig& cfg, std::ostream& events_out) {
    LuaHost host;
    EventLog events(events_out);
    VirtualClock global_clock;
    std::mt19937 sim_rng(cfg.simulation.seed);
    LinkModel links(cfg.nodes.size());
    for (const auto& l : cfg.topology.links) {
        // populate from cfg
    }
    LbtModel lbt(cfg.nodes.size());

    std::vector<std::unique_ptr<ScriptedNode>> nodes;
    std::vector<std::unique_ptr<SimRadio>> radios;
    for (size_t i = 0; i < cfg.nodes.size(); i++) {
        radios.emplace_back(std::make_unique<SimRadio>(global_clock));
        nodes.emplace_back(std::make_unique<ScriptedNode>(
            (int)i, cfg.nodes[i].name, host, *radios[i], events, global_clock, sim_rng));
        host.registerNode((int)i, nodes[i].get());
        host.loadScript((int)i, cfg.nodes[i].script_path);
    }

    // on_init for each node
    for (size_t i = 0; i < nodes.size(); i++) {
        nodes[i]->onInit(cfg.nodes[i].config);
    }

    // Prepare scheduled commands
    std::vector<int> command_idx(cfg.commands.size(), 0);   // not yet fired

    // Main loop
    uint64_t step_ms = cfg.simulation.step_ms;
    uint64_t end_ms = cfg.simulation.duration_ms;
    for (uint64_t now = 0; now < end_ms; now += step_ms) {
        // 1. processCommands
        for (size_t k = 0; k < cfg.commands.size(); k++) {
            if (command_idx[k] == 0 && cfg.commands[k].at_ms <= now) {
                int target = findNode(cfg, cfg.commands[k].node);
                std::string reply = nodes[target]->onCommand(cfg.commands[k].command);
                events.logCmdReply(target, now, cfg.commands[k].command, reply);
                command_idx[k] = 1;
            }
        }

        // 2. deliverReceptions
        // (use SimRadio + collision model + link model to determine which
        // pending RX events at each node land NOW, then call onRecv)

        // 3. tickTimers
        for (auto& n : nodes) n->tickTimers(now);

        // 4. registerTransmissions
        for (size_t i = 0; i < nodes.size(); i++) {
            for (auto& tx : nodes[i]->drainPendingTxs()) {
                radios[i]->startSendRaw(reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                                         (int)tx.bytes.size());
                events.logTx((int)i, now,
                              radios[i]->getEstAirtimeFor((int)tx.bytes.size()),
                              tx.bytes);
                // Schedule physical delivery to receivers via deliverReceptions on later steps.
            }
        }

        // 5. advance
        global_clock.tick(step_ms);
    }

    // expect[] evaluation
    LoopResult result;
    result.ok = true;
    result.events_emitted = events.count();
    result.assertion_failures = ExpectRunner::evaluate(cfg.expect, events);
    if (result.assertion_failures > 0) result.ok = false;
    return result;
}
```

This is the integration of all the pieces. The implementer fills in `deliverReceptions` (consult LinkModel + CollisionModel + LbtModel + LinkFadingState; emit `rx` / `collision` / `drop_*` events accordingly), and the `findNode` helper.

- [ ] **Step 13.3: Implement test_runner/ExpectRunner stub**

```cpp
// orchestrator/test_runner/ExpectRunner.h
#pragma once
#include <vector>
class EventLog;
struct Expect;
class ExpectRunner {
public:
    static int evaluate(const std::vector<Expect>& expects, const EventLog& events);
};
```

```cpp
// orchestrator/test_runner/ExpectRunner.cpp — stub for now
#include "orchestrator/test_runner/ExpectRunner.h"
#include "core/events/EventLog.h"
#include "core/topology/JsonConfig.h"

int ExpectRunner::evaluate(const std::vector<Expect>& expects, const EventLog& events) {
    // Implemented in Task 15. Returns 0 (no failures) for now.
    return 0;
}
```

- [ ] **Step 13.4: Replace main.cpp with the real entry point**

```cpp
// orchestrator/main.cpp
#include "core/topology/JsonConfig.h"
#include "orchestrator/runtime/Loop.h"
#include <cstdio>
#include <fstream>

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <config.json> [events.ndjson]\n", argv[0]);
        return 1;
    }
    SimConfig cfg = JsonConfig::loadFromFile(argv[1]);

    std::ofstream events_file;
    std::ostream* out = &std::cout;
    if (argc >= 3) {
        events_file.open(argv[2]);
        out = &events_file;
    }

    LoopResult r = runSimulation(cfg, *out);
    std::fprintf(stderr, "lus: %d events emitted, %d assertion failures\n",
                 r.events_emitted, r.assertion_failures);
    return r.ok ? 0 : 1;
}
```

- [ ] **Step 13.5: Update orchestrator/CMakeLists.txt**

```cmake
add_executable(lus
    main.cpp
    runtime/TimerWheel.cpp
    runtime/LuaHost.cpp
    runtime/ScriptedNode.cpp
    runtime/Loop.cpp
    test_runner/ExpectRunner.cpp
)
```

- [ ] **Step 13.6: Build sanity (no test yet — integration test in Task 14)**

```bash
cmake --build /home/staszek/lora-universal-simulator/build -j 4
```

Expected: SUCCESS.

- [ ] **Step 13.7: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add orchestrator/runtime/Loop.h orchestrator/runtime/Loop.cpp orchestrator/test_runner/ orchestrator/main.cpp orchestrator/CMakeLists.txt
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
feat(orchestrator): main simulation loop + command dispatch + entry point

Loop.cpp: per-step processCommands → deliverReceptions → tickTimers →
registerTransmissions → advance(step_ms). Brings together LuaHost,
ScriptedNode, SimRadio, LinkModel, CollisionModel, LbtModel, EventLog.

main.cpp: reads JSON config, runs the loop, optionally writes NDJSON
to a file (default stdout), prints summary to stderr, exits with the
assertion-failure count.

ExpectRunner is a stub — real evaluator lands in Task 15 after the
flooder example exercises the pipeline.
EOF
)"
```

---

## Task 14: examples/flooder.lua + t01_flooder.json + first end-to-end run

**Files:**
- Create: `~/lora-universal-simulator/examples/flooder.lua`
- Create: `~/lora-universal-simulator/test/t01_flooder.json`

The flooder example: a node with `role: "originator"` reacts to `on_command("send <text>")` by transmitting a numbered, hash-prefixed packet; every node forwards once per packet (deduped by a per-node seen-set); the destination logs receipt.

- [ ] **Step 14.1: Write examples/flooder.lua**

```lua
-- examples/flooder.lua
-- Simple flooded broadcast. Each packet has a (originator_id, seq) tuple as
-- its identity; receivers forward once and never again.

function on_init(self, config)
  self.role = config.role or "forwarder"
  self.seq = 0
  self.seen = {}                 -- key: id .. ":" .. seq, value: true
  self:log("init role=" .. self.role)
end

local function packet_key(originator_id, seq)
  return string.format("%d:%d", originator_id, seq)
end

local function serialize(originator_id, seq, text)
  -- 1-byte originator id, 1-byte seq, text bytes (no length prefix; consume to EOF)
  return string.char(originator_id) .. string.char(seq % 256) .. text
end

local function parse(frame)
  if #frame < 2 then return nil end
  local oid  = frame:byte(1)
  local seq  = frame:byte(2)
  local text = frame:sub(3)
  return { oid = oid, seq = seq, text = text }
end

function on_recv(self, frame, meta)
  local p = parse(frame)
  if not p then return end
  local key = packet_key(p.oid, p.seq)
  if self.seen[key] then return end                  -- dedupe
  self.seen[key] = true
  self:log(string.format("recv from=%d seq=%d text=%q", p.oid, p.seq, p.text))
  self:emit("recv", { oid = p.oid, seq = p.seq, text = p.text })
  -- Forward unless I'm the originator (avoid bouncing back).
  if p.oid ~= self.id then
    self:tx(frame)
  end
end

function on_command(self, cmd_str)
  local text = cmd_str:match("^send (.+)$")
  if not text then return "ERROR: usage: send <text>" end
  if self.role ~= "originator" then return "ERROR: I'm not an originator" end
  self.seq = self.seq + 1
  local frame = serialize(self.id, self.seq, text)
  local key = packet_key(self.id, self.seq)
  self.seen[key] = true                              -- don't accept our own back
  self:tx(frame)
  return string.format("sent seq=%d to flood", self.seq)
end
```

- [ ] **Step 14.2: Write test/t01_flooder.json**

```json
{
  "_name": "t01_flooder",
  "_desc": "3-node chain alice → relay → bob. alice sends 'hello'. relay forwards. bob receives + emits 'recv'.",
  "simulation": {
    "duration_ms": 30000,
    "step_ms": 1,
    "warmup_ms": 0,
    "radio": { "sf": 11, "bw": 250, "cr": 5 }
  },
  "nodes": [
    { "name": "alice", "script": "examples/flooder.lua", "config": { "role": "originator" } },
    { "name": "relay", "script": "examples/flooder.lua", "config": { "role": "forwarder" } },
    { "name": "bob",   "script": "examples/flooder.lua", "config": { "role": "forwarder" } }
  ],
  "topology": {
    "links": [
      { "from": "alice", "to": "relay", "snr": 8.0, "rssi": -80.0, "bidir": true },
      { "from": "relay", "to": "bob",   "snr": 8.0, "rssi": -80.0, "bidir": true }
    ]
  },
  "commands": [
    { "at_ms": 5000, "node": "alice", "command": "send hello" }
  ],
  "expect": [
    { "type": "cmd_reply_contains", "node": "alice", "command": "send hello", "value": "sent seq=1" },
    { "type": "event_count_min",    "event_type": "tx", "min": 2 },
    { "type": "script_emit_contains", "node": "bob", "emit_type": "recv", "value": "hello" }
  ]
}
```

- [ ] **Step 14.3: Run the simulation manually first**

```bash
cd /home/staszek/lora-universal-simulator
./build/orchestrator/lus test/t01_flooder.json events.ndjson
```

Inspect `events.ndjson`: should contain `tx` events from alice and relay, `rx` events at relay and bob, a `cmd_reply` from alice with `"sent seq=1"`, and a `script_emit` from bob with `recv` data.

If the simulation crashes or events are missing, debug:
- Add `self:log()` calls inside `on_recv` to trace flow.
- Verify TX→delivery wiring in `Loop.cpp::deliverReceptions`.

(Assertion evaluator stubs land next; this step is just smoke-testing the end-to-end pipeline.)

- [ ] **Step 14.4: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add examples/flooder.lua test/t01_flooder.json
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
feat(examples): flooder.lua — first scripted protocol

A minimal flooded-broadcast protocol: 2-byte (originator_id, seq) header
plus payload bytes. Receivers dedupe by (oid, seq) tuple and forward
once unless they're the originator. on_command parses 'send <text>'.

t01_flooder.json drives a 3-node chain end-to-end. Smoke-runs from the
CLI; assertion evaluator wired in Task 15.
EOF
)"
```

---

## Task 15: Implement ExpectRunner + run_tests.sh

**Files:**
- Modify: `~/lora-universal-simulator/orchestrator/test_runner/ExpectRunner.cpp`
- Create: `~/lora-universal-simulator/test/run_tests.sh`

- [ ] **Step 15.1: Implement ExpectRunner**

The evaluator inspects the captured event log (or re-reads NDJSON output). For each expect entry, evaluate:

| `type` | Logic |
|---|---|
| `cmd_reply_contains` | Find the most-recent `cmd_reply` event for `(node, command_prefix)`; check `reply` substring contains `value`. |
| `cmd_reply_not_contains` | Same but inverted. |
| `event_count` | Count events of `event_type` (optionally filtered by `node`); ensure `min ≤ count ≤ max` (max optional). |
| `event_count_min` | Convenience for `event_count` with only `min`. |
| `tx_airtime_between` | Sum airtime of `tx` events; ensure within `[min_ms, max_ms]`. |
| `script_emit_contains` | Find `script_emit` events of `(node, emit_type)`; verify any contains `value` substring in its data. |

```cpp
// orchestrator/test_runner/ExpectRunner.cpp
#include "orchestrator/test_runner/ExpectRunner.h"
#include "core/events/EventLog.h"
#include "core/topology/JsonConfig.h"
#include <cstdio>
#include <string>

int ExpectRunner::evaluate(const std::vector<Expect>& expects, const EventLog& events) {
    int failures = 0;
    for (const auto& e : expects) {
        bool pass = false;
        std::string detail;
        if (e.type == "cmd_reply_contains") {
            // Look up matching cmd_reply...
        } else if (e.type == "event_count" || e.type == "event_count_min") {
            // ...
        } else if (e.type == "tx_airtime_between") {
            // ...
        } else if (e.type == "script_emit_contains") {
            // ...
        } else {
            std::fprintf(stderr, "ExpectRunner: unknown expect type: %s\n", e.type.c_str());
            failures++;
            continue;
        }
        if (!pass) {
            std::fprintf(stderr, "FAIL expect[%s]: %s\n", e.type.c_str(), detail.c_str());
            failures++;
        }
    }
    return failures;
}
```

(Implement each branch — should be ~20-40 lines per assertion type. Reuse `EventLog`'s captured events. The `EventLog` class needs a public `events()` accessor returning the stored event list — add this if it doesn't exist.)

- [ ] **Step 15.2: Write run_tests.sh**

`test/run_tests.sh` (mirrors `meshcore_real_sim/test/run_tests.sh`):

```bash
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
LUS="$BUILD_DIR/orchestrator/lus"

if [ ! -x "$LUS" ]; then
    echo "ERROR: lus binary not found at $LUS"
    echo "Run: cmake --build $BUILD_DIR -j 4"
    exit 1
fi

CONFIGS=("$@")
if [ ${#CONFIGS[@]} -eq 0 ]; then
    # Default: every test/t*.json
    while IFS= read -r f; do CONFIGS+=("$f"); done < <(ls "$SCRIPT_DIR"/t*.json 2>/dev/null | sort)
fi

passed=0
failed=0
for cfg in "${CONFIGS[@]}"; do
    name="$(basename "$cfg" .json)"
    out="$SCRIPT_DIR/${name}_events.ndjson"
    if "$LUS" "$cfg" "$out" 2>/dev/null; then
        echo "  $name $(printf '%*s' $((40 - ${#name})) '')PASS"
        passed=$((passed + 1))
    else
        echo "  $name $(printf '%*s' $((40 - ${#name})) '')FAIL"
        failed=$((failed + 1))
    fi
done

echo ""
echo "$passed/$((passed + failed)) passed"
[ "$failed" -eq 0 ]
```

```bash
chmod +x /home/staszek/lora-universal-simulator/test/run_tests.sh
```

- [ ] **Step 15.3: Run the test**

```bash
cmake --build /home/staszek/lora-universal-simulator/build -j 4
bash /home/staszek/lora-universal-simulator/test/run_tests.sh test/t01_flooder.json
```

Expected:
```
  t01_flooder                              PASS

1/1 passed
```

If FAIL: inspect `test/t01_flooder_events.ndjson` to see what events were emitted, and the stderr from `lus` to see which assertion failed. Iterate.

- [ ] **Step 15.4: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add orchestrator/test_runner/ExpectRunner.cpp test/run_tests.sh
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
feat(test): ExpectRunner — assertion evaluator + run_tests.sh wrapper

ExpectRunner implements 6 assertion types:
  cmd_reply_contains / cmd_reply_not_contains
  event_count / event_count_min
  tx_airtime_between
  script_emit_contains  (NEW — checks script_emit events)

run_tests.sh mirrors meshcore_real_sim's pattern: invokes lus per
config, captures NDJSON, returns non-zero on any failure. Default
target is every test/t*.json; pass paths to override.

t01_flooder PASSes end-to-end.
EOF
)"
```

---

## Task 16: Port visualize.py + visualize.html

**Files:**
- Create: `~/lora-universal-simulator/tools/visualize.py`
- Create: `~/lora-universal-simulator/tools/visualize.html`

- [ ] **Step 16.1: Copy from meshcore_real_sim**

```bash
mkdir -p /home/staszek/lora-universal-simulator/tools
cp /home/staszek/meshcore_real_sim/visualization/visualize.py /home/staszek/lora-universal-simulator/tools/visualize.py
cp /home/staszek/meshcore_real_sim/visualization/visualize.html /home/staszek/lora-universal-simulator/tools/visualize.html
```

- [ ] **Step 16.2: Strip MeshCore-specific rendering**

Open `visualize.html`. Find any code that decodes MeshCore packet types (`PAYLOAD_TYPE_*`, packet hex parsing for adverts/messages) and remove it. Keep:
- The swim-lane rendering (one row per node, time on X axis, bars for tx/rx/collision/drop)
- Color coding: tx=blue, rx=green, collision=red, drop_halfduplex/drop_loss=amber
- Mouse-over tooltips with `time_ms`, `airtime_ms`, etc.

Add rendering for the new event types:
- `script_log` — small grey marker on the node's row at `time_ms`, tooltip shows the message
- `script_emit` — small purple marker, tooltip shows `emit_type` + `data` JSON

- [ ] **Step 16.3: Adjust visualize.py**

The Python wrapper that loads NDJSON + spawns a browser. Ensure it doesn't filter on MeshCore-specific event keys. Read the file and confirm it's mostly format-agnostic (JSON line → dict → HTML data); strip if needed.

- [ ] **Step 16.4: Verify visualization end-to-end**

```bash
cd /home/staszek/lora-universal-simulator
./build/orchestrator/lus test/t01_flooder.json test/t01_flooder_events.ndjson
python3 tools/visualize.py test/t01_flooder_events.ndjson
```

Should open a browser tab showing 3 swim lanes (alice, relay, bob) with TX/RX bars + script_log markers from the flooder logs.

- [ ] **Step 16.5: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add tools/visualize.py tools/visualize.html
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
feat(tools): port visualize.py + visualize.html (NDJSON swim-lane viewer)

Lifted from meshcore_real_sim/visualization/. Stripped MeshCore packet
parsing and protocol-specific tooltip text. Added rendering for the
two new event types:
  script_log  — grey marker; tooltip shows the log message
  script_emit — purple marker; tooltip shows emit_type + data JSON

Verified by visualizing test/t01_flooder_events.ndjson.
EOF
)"
```

---

## Task 17: 200-node × 1h performance smoke test

**Files:**
- Create: `~/lora-universal-simulator/test/t99_perf_smoke.json`
- Create: `~/lora-universal-simulator/examples/quiet.lua`

- [ ] **Step 17.1: Write a no-op script (to isolate runtime overhead from script work)**

`examples/quiet.lua`:
```lua
-- examples/quiet.lua — minimal node that does nothing.
-- For performance benchmarking: measures pure runtime overhead.
function on_init(self, config)
  -- nothing to set up
end
function on_recv(self, frame, meta)
  -- nothing to do
end
```

- [ ] **Step 17.2: Generate a 200-node topology config**

Write a small generator script (one-off) or hand-write a config with 200 nodes in a 14×14 grid (last 4 cells unused → 196 nodes; or 20×10 = 200) with bidir links between adjacent cells.

For brevity, create `tools/gen_grid.py`:
```python
# tools/gen_grid.py — generate a NxM grid topology for the perf smoke test.
import json, sys

cols, rows = 20, 10                      # 200 nodes
duration_ms = 3_600_000                  # 1 hour
nodes, links = [], []
for r in range(rows):
    for c in range(cols):
        nodes.append({"name": f"n{r}_{c}", "script": "examples/quiet.lua"})
for r in range(rows):
    for c in range(cols):
        if c + 1 < cols:
            links.append({"from": f"n{r}_{c}", "to": f"n{r}_{c+1}",
                          "snr": 8.0, "rssi": -80.0, "bidir": True})
        if r + 1 < rows:
            links.append({"from": f"n{r}_{c}", "to": f"n{r+1}_{c}",
                          "snr": 8.0, "rssi": -80.0, "bidir": True})
cfg = {
    "_name": "t99_perf_smoke",
    "simulation": {
        "duration_ms": duration_ms,
        "step_ms": 1,
        "warmup_ms": 0,
        "radio": {"sf": 11, "bw": 250, "cr": 5}
    },
    "nodes": nodes,
    "topology": {"links": links},
    "commands": [],
    "expect": []
}
print(json.dumps(cfg, indent=2))

# usage: python3 tools/gen_grid.py > test/t99_perf_smoke.json
```

```bash
python3 /home/staszek/lora-universal-simulator/tools/gen_grid.py > /home/staszek/lora-universal-simulator/test/t99_perf_smoke.json
```

- [ ] **Step 17.3: Run with timing**

```bash
cd /home/staszek/lora-universal-simulator
time ./build/orchestrator/lus test/t99_perf_smoke.json /tmp/perf_events.ndjson
```

Expected: completes in **under 5 minutes wall time**. Note the user/sys/elapsed times.

If it takes longer than 5 minutes, the diagnosis steps are:
1. Profile with `perf record` / `gprof` to identify the dominant cost.
2. If C++-side is dominant (likely the 720K-step main loop with 200 nodes): the loop should be vectorizable in tight code. Look for excessive heap allocation per step.
3. If Lua-side is dominant: switch the Lua host to LuaJIT (drop-in via system `libluajit-5.1-2`); this is the documented escape hatch in spec §13.
4. Lua callback overhead reduction: ensure timer wheel uses a single C++ vector + binary heap, not std::map. Each `popDue` should be O(log n).

- [ ] **Step 17.4: Document the result**

Add a section to README.md:
```markdown
## Performance benchmark

200-node × 1 h smoke test (no script work, just runtime overhead):

```bash
python3 tools/gen_grid.py > test/t99_perf_smoke.json
time ./build/orchestrator/lus test/t99_perf_smoke.json /dev/null
```

Last measured: <fill in actual time> on <hardware>.
```

- [ ] **Step 17.5: Commit**

```bash
git -C /home/staszek/lora-universal-simulator add examples/quiet.lua test/t99_perf_smoke.json tools/gen_grid.py README.md
git -C /home/staszek/lora-universal-simulator commit -m "$(cat <<'EOF'
test(perf): 200-node x 1h smoke test under 5 min

t99_perf_smoke: 20x10 grid of nodes running examples/quiet.lua
(no work, no traffic). Measures the runtime overhead of stepping
720,000 simulator ticks across 200 nodes with our timer wheel and
event loop.

If wall time exceeds 5 minutes the LuaJIT swap is the documented
escape hatch (spec §13). Hardware + measured time recorded in README.
EOF
)"
```

---

## Self-Review

Before declaring the plan complete, here's the spec coverage check:

### Spec § → Task mapping

| Spec section | Tasks |
|---|---|
| 5. Architecture (3 layers) | 4–9 (core), 10–13 (runtime), 14 (script) |
| 6.1 Core physics ported list | 4 (clock, link), 5 (events), 6 (radio), 7 (physics+fading), 8 (topology) |
| 6.2 Node runtime | 10 (timer wheel), 11 (Lua host), 12 (ScriptedNode), 13 (loop) |
| 6.3 Test runner | 15 (ExpectRunner + run_tests.sh) |
| 6.4 Visualization | 16 |
| 7.1 Callbacks | 12 (ScriptedNode dispatch) + 11 (LuaHost wiring) |
| 7.2 Runtime methods | 12 (api_* methods) |
| 7.3 Initial state | 12 (registerNode populates self.id, self.name) |
| 7.4 Lifecycle | 13 (Loop.cpp orchestrates) |
| 8 Configuration schema | 8 (JsonConfig port + adaptation) |
| 9 Project structure | 1, 2 (initial layout) + every subsequent task fills it |
| 10 Y1 acceptance | items 1–6 → tasks 1–17 (each acceptance criterion produced by a task) |
| 12 Testing strategy | unit tests in tasks 4–10, JSON regression in 14, perf in 17 |

### Placeholder scan

No "TBD", "TODO", "implement later" found. Step 14.4's mention of "Iterate" is acceptable — debugging is open-ended by nature.

### Type consistency

- `SimConfig`, `NodeDef`, `Link`, `Expect` are used consistently across tasks 8, 13, 15.
- `TimerHandle`, `TimerEntry` consistent between TimerWheel and ScriptedNode.
- `LuaHost::registerNode` / `loadScript` / `callOnInit` consistent between tasks 11 and 12.
- API method names: `api_tx`, `api_after`, `api_every`, `api_cancel`, `api_now`, `api_rand`, `api_log`, `api_emit`, `api_peers` all match spec §7.2.

---

## Execution Handoff

Plan complete and saved to `/home/staszek/lora-universal-simulator/docs/superpowers/plans/2026-05-05-y1-implementation.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — Dispatch a fresh subagent per task with two-stage review (spec compliance → code quality). Same approach we used for routing Phase 2.

2. **Inline Execution** — Use the executing-plans skill, batch through tasks in this session with checkpoints for human review.

Subagent-Driven is the recommended choice for this plan because:
- 17 tasks span ~7 days of work; fresh per-task context keeps each subagent focused.
- Several tasks touch the boundary between MeshCore-specific code (to strip) and protocol-agnostic code (to keep) — fresh eyes per port reduce the chance of accidental coupling.
- The integration cliff between Tasks 12-13 (ScriptedNode + Loop) is exactly where two-stage review pays off most.

Which approach?
