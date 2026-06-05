cmake_minimum_required(VERSION 3.16)
project(lora_universal_simulator
        VERSION 0.1.0
        LANGUAGES C CXX)        # C: monocypher.c (lib/core/identity seed -> key_hash32 derivation)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# Strict warnings
add_compile_options(-Wall -Wextra -Wpedantic)

find_package(Lua 5.4 REQUIRED)
find_package(Threads REQUIRED)

# Subdirectories (added incrementally as Tasks 4..N populate them)
add_subdirectory(core)

# --- MeshRoute C++ firmware core (optional; sim-integration track S2) ---------
# Build the platform-neutral MeshRoute lib/core as a C++20 static lib so
# engine:"meshroute" nodes (FirmwareNode) run the real firmware in-loop. Only
# this target is C++20 (D-S2a = B); the sim stays C++17 and includes the
# C++17-clean hal.h/node.h. Build-optional: if MeshRoute isn't found, the sim
# still builds (Lua-only) and meshroute nodes error at runtime.
set(MESHROUTE_DIR "${CMAKE_SOURCE_DIR}/../MeshRoute" CACHE PATH
    "Path to the MeshRoute repo (for engine:meshroute firmware nodes)")
if(EXISTS "${MESHROUTE_DIR}/lib/core/protocol_constants.h")
    message(STATUS "MeshRoute found at ${MESHROUTE_DIR} — engine:meshroute ENABLED (meshroute_core)")
    add_library(meshroute_core STATIC
        ${MESHROUTE_DIR}/lib/core/airtime.cpp
        ${MESHROUTE_DIR}/lib/core/frame_codec.cpp
        ${MESHROUTE_DIR}/lib/core/node.cpp
        ${MESHROUTE_DIR}/lib/core/node_beacon.cpp
        ${MESHROUTE_DIR}/lib/core/node_routing.cpp
        ${MESHROUTE_DIR}/lib/core/node_mac.cpp
        ${MESHROUTE_DIR}/lib/core/node_mac_rx.cpp
        ${MESHROUTE_DIR}/lib/core/node_route_discovery.cpp
        ${MESHROUTE_DIR}/lib/core/node_query.cpp
        ${MESHROUTE_DIR}/lib/core/node_channel.cpp
        ${MESHROUTE_DIR}/lib/core/node_hashlocate.cpp
        ${MESHROUTE_DIR}/lib/core/node_budget.cpp
        ${MESHROUTE_DIR}/lib/core/node_cascade.cpp
        ${MESHROUTE_DIR}/lib/core/identity.cpp
        ${MESHROUTE_DIR}/lib/monocypher/src/monocypher.c
    )
    target_compile_features(meshroute_core PRIVATE cxx_std_20)
    target_compile_definitions(meshroute_core PRIVATE
        PROTOCOL_VERSION=1
        LORA_FREQ_HZ=869462500
        LORA_BW_HZ=125000
        LORA_SF=8
        LORA_CR=5
        LORA_PREAMBLE_SYM=16
        LORA_DUTY_CYCLE_PCT=10
    )
    target_include_directories(meshroute_core PUBLIC ${MESHROUTE_DIR}/lib/core)
    # identity.cpp -> monocypher (seed -> key_hash32 derivation, shared with the device)
    target_include_directories(meshroute_core PUBLIC ${MESHROUTE_DIR}/lib/monocypher/src)
    set(MESHROUTE_ENABLED ON)
else()
    message(WARNING "MeshRoute not found at ${MESHROUTE_DIR} — building WITHOUT engine:meshroute "
                    "(scenarios using it error at runtime). Override with -DMESHROUTE_DIR=<path>.")
    set(MESHROUTE_ENABLED OFF)
endif()

add_subdirectory(orchestrator)
