# Populated by Tasks 11..15.
add_executable(lus
    main.cpp
    runtime/TimerWheel.cpp
    runtime/LuaHost.cpp
)
target_link_libraries(lus PRIVATE lus_core)
target_include_directories(lus PRIVATE
    ${CMAKE_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/third_party
)
