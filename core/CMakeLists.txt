add_library(lus_core STATIC
    link/LinkModel.cpp
)
target_include_directories(lus_core PUBLIC
    ${CMAKE_SOURCE_DIR}                # so includes look like "core/clock/..."
    ${CMAKE_SOURCE_DIR}/third_party
    ${LUA_INCLUDE_DIR}
)
target_link_libraries(lus_core PUBLIC ${LUA_LIBRARIES} Threads::Threads)
