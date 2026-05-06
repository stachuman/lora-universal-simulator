// core/events/JsonToSol.h
//
// Shared inline helper that converts an nlohmann::json value into a
// sol::object suitable for handing to a Lua script.
//
// Duplicated previously inside ScriptedNode.cpp's anonymous namespace; lifted
// here so LuaHost::bindSimGlobals (sim:events) and ScriptedNode::onInit can
// share one implementation. Tables/arrays/scalars only — Lua nil for any
// type sol cannot represent.

#pragma once

#include "json/json.hpp"
#include "sol/sol.hpp"

#include <cstdint>
#include <string>

namespace lus {

inline sol::object json_to_sol(sol::state_view L, const nlohmann::json& j) {
    if (j.is_null())            return sol::make_object(L, sol::lua_nil);
    if (j.is_boolean())         return sol::make_object(L, j.get<bool>());
    if (j.is_number_integer())  return sol::make_object(L, j.get<int64_t>());
    if (j.is_number_unsigned()) return sol::make_object(L, j.get<uint64_t>());
    if (j.is_number_float())    return sol::make_object(L, j.get<double>());
    if (j.is_string())          return sol::make_object(L, j.get<std::string>());
    if (j.is_array()) {
        sol::table t = L.create_table();
        int i = 1;
        for (const auto& v : j) {
            t[i++] = json_to_sol(L, v);
        }
        return t;
    }
    if (j.is_object()) {
        sol::table t = L.create_table();
        for (auto it = j.begin(); it != j.end(); ++it) {
            t[it.key()] = json_to_sol(L, it.value());
        }
        return t;
    }
    return sol::make_object(L, sol::lua_nil);
}

} // namespace lus
