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
    message(STATUS "MeshRoute found at ${MESHROUTE_DIR} — engine:meshroute ENABLED (faithful two-lib: normal + gateway)")

    # Slice 5 (faithful two-lib): the firmware core is built TWICE as ODR-distinct static libs so a
    # FirmwareNode can run EITHER a single-layer node (meshroute_core_normal, namespace meshroute) OR a
    # dual-layer gateway (meshroute_core_gw, namespace meshroute_gw, MR_N_LAYERS=2 + the gateway caps). The
    # ODR isolation is the MESHROUTE_NS macro; the per-variant wrapper TU (NodeRuntimeWrapper.cpp) bridges
    # the namespace-neutral sim interfaces (ISimHal/INodeRuntime) to each lib's Hal/Node.

    # monocypher (C, namespace-free): ONE copy. If BOTH C++ core libs compiled it, lus (which links both)
    # would see duplicate crypto_* symbols. identity.cpp in each variant resolves against this single lib.
    add_library(meshroute_monocypher STATIC
        ${MESHROUTE_DIR}/lib/monocypher/src/monocypher.c)
    target_include_directories(meshroute_monocypher PUBLIC ${MESHROUTE_DIR}/lib/monocypher/src)

    # The shared C++ firmware sources. The per-variant wrapper is added per-lib (so it compiles in that
    # lib's namespace + picks the matching factory symbol via MR_GATEWAY_BUILD).
    set(_meshroute_core_srcs
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
        ${MESHROUTE_DIR}/lib/core/node_join.cpp
        ${MESHROUTE_DIR}/lib/core/node_budget.cpp
        ${MESHROUTE_DIR}/lib/core/node_cascade.cpp
        ${MESHROUTE_DIR}/lib/core/identity.cpp
        ${MESHROUTE_DIR}/lib/core/inbox.cpp
    )

    # Build one core-lib variant. ARGN = extra PRIVATE compile definitions (the gateway -D set, or none).
    function(add_meshroute_core_variant libname)
        add_library(${libname} STATIC
            ${_meshroute_core_srcs}
            ${CMAKE_SOURCE_DIR}/orchestrator/runtime/NodeRuntimeWrapper.cpp
        )
        target_compile_features(${libname} PRIVATE cxx_std_20)
        target_compile_definitions(${libname} PRIVATE
            PROTOCOL_VERSION=1
            LORA_FREQ_HZ=869462500
            LORA_BW_HZ=125000
            LORA_SF=8
            LORA_CR=5
            LORA_PREAMBLE_SYM=16
            LORA_DUTY_CYCLE_PCT=10
            ${ARGN}
        )
        # firmware headers (hal.h/node.h/command.h) + monocypher (identity.cpp); the wrapper also needs the
        # neutral contract headers (CMAKE_SOURCE_DIR) + the vendored json it parses (third_party).
        target_include_directories(${libname} PUBLIC
            ${MESHROUTE_DIR}/lib/core
            ${MESHROUTE_DIR}/lib/monocypher/src)
        target_include_directories(${libname} PRIVATE
            ${CMAKE_SOURCE_DIR}
            ${CMAKE_SOURCE_DIR}/third_party)
        target_link_libraries(${libname} PUBLIC meshroute_monocypher)
    endfunction()

    # normal: MR_N_LAYERS defaults to 1, MESHROUTE_NS defaults to `meshroute` (header guard) — byte-identical
    # to the pre-split meshroute_core, so the s18 single-layer baseline holds.
    add_meshroute_core_variant(meshroute_core_normal)
    # gateway: a second LayerRuntime + the dedicated-gateway caps (mirrors platformio [env:gateway]).
    add_meshroute_core_variant(meshroute_core_gw
        MESHROUTE_NS=meshroute_gw
        MR_N_LAYERS=2
        MR_GATEWAY_BUILD=1
        MR_CAP_CHANNEL_BUFFER=8
        MR_CAP_DEFERRED_SENDS=16
    )
    set(MESHROUTE_ENABLED ON)
else()
    message(WARNING "MeshRoute not found at ${MESHROUTE_DIR} — building WITHOUT engine:meshroute "
                    "(scenarios using it error at runtime). Override with -DMESHROUTE_DIR=<path>.")
    set(MESHROUTE_ENABLED OFF)
endif()

add_subdirectory(orchestrator)
