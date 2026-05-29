# Populated by Tasks 11..15.
add_executable(lus
    main.cpp
    runtime/TimerWheel.cpp
    runtime/LuaHost.cpp
    runtime/ScriptedNode.cpp
    runtime/SimController.cpp
    runtime/InteractiveRepl.cpp
    runtime/Loop.cpp
    test_runner/ExpectRunner.cpp
)
target_link_libraries(lus PRIVATE lus_core)
target_include_directories(lus PRIVATE
    ${CMAKE_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/third_party
)

# Sim-integration track (S2): the meshroute engine + FirmwareNode build only when
# MeshRoute was found at configure time (meshroute_core). See root CMakeLists.
if(MESHROUTE_ENABLED)
    target_sources(lus PRIVATE runtime/FirmwareNode.cpp)
    target_link_libraries(lus PRIVATE meshroute_core)
    target_compile_definitions(lus PRIVATE MESHROUTE_ENABLED=1)
endif()
