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

find_package(Lua 5.4 REQUIRED)
find_package(Threads REQUIRED)

# Subdirectories (added incrementally as Tasks 4..N populate them)
add_subdirectory(core)
add_subdirectory(orchestrator)
