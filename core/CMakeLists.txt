# Populated by Tasks 4..9.
add_library(lus_core INTERFACE)
target_include_directories(lus_core INTERFACE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/third_party
    ${LUA_INCLUDE_DIR}
)
target_link_libraries(lus_core INTERFACE ${LUA_LIBRARIES} Threads::Threads)
