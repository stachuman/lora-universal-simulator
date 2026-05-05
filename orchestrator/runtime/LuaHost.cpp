// orchestrator/runtime/LuaHost.cpp
#include "orchestrator/runtime/LuaHost.h"

#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>

LuaHost::LuaHost() {
    // Sandbox: base/string/table/math/coroutine only. No io, no os, no debug.
    _lua.open_libraries(
        sol::lib::base,
        sol::lib::string,
        sol::lib::table,
        sol::lib::math,
        sol::lib::coroutine);

    // Build the registry root.
    _lua.script(R"LUA(
        _LUS = { nodes = {} }
    )LUA");
    _node_registry = _lua["_LUS"]["nodes"];
}

void LuaHost::registerNode(int node_id, ScriptedNode* /*node*/) {
    sol::table node_tbl = _lua.create_table();
    node_tbl["self"]   = _lua.create_table();
    node_tbl["script"] = _lua.create_table();
    node_tbl["timers"] = _lua.create_table();   // handle -> sol::function (T12)
    _node_registry[node_id] = node_tbl;
}

void LuaHost::loadScript(int node_id, const std::string& path) {
    // Look up (or load + cache) the compiled chunk.
    sol::function chunk;
    auto cached = _loaded_scripts.find(path);
    if (cached != _loaded_scripts.end()) {
        chunk = cached->second;
    } else {
        std::ifstream f(path);
        if (!f.is_open()) {
            throw std::runtime_error("LuaHost: cannot open script: " + path);
        }
        std::ostringstream oss;
        oss << f.rdbuf();
        sol::load_result loaded = _lua.load(oss.str(), path);
        if (!loaded.valid()) {
            sol::error err = loaded;
            throw std::runtime_error("LuaHost: syntax error in " + path + ": " + err.what());
        }
        chunk = loaded;
        _loaded_scripts[path] = chunk;
    }

    // Run the chunk in a fresh environment so each node gets an isolated
    // global namespace (the script's "globals" become this env's locals).
    sol::environment env(_lua, sol::create, _lua.globals());
    sol::set_environment(env, chunk);
    sol::protected_function_result run = chunk.call();
    if (!run.valid()) {
        sol::error err = run;
        throw std::runtime_error("LuaHost: error executing " + path + ": " + err.what());
    }

    // Copy any defined callbacks into _LUS.nodes[id].script.
    sol::table script_tbl = _node_registry[node_id]["script"];
    for (const char* name : {"on_init", "on_recv", "on_command", "on_radio_busy"}) {
        sol::object fn = env[name];
        if (fn.is<sol::function>()) {
            script_tbl[name] = fn;
        }
    }
}

void LuaHost::callOnInit(int node_id, const sol::table& config) {
    sol::object fn_obj = _node_registry[node_id]["script"]["on_init"];
    if (!fn_obj.is<sol::function>()) return;   // optional callback
    sol::function fn = fn_obj;
    sol::table self = _node_registry[node_id]["self"];
    sol::protected_function_result r = fn.call(self, config);
    if (!r.valid()) {
        sol::error err = r;
        throw std::runtime_error(std::string("on_init: ") + err.what());
    }
}

void LuaHost::callOnRecv(int node_id, std::string_view bytes,
                         float snr, float rssi, int link_id, uint64_t sim_ms) {
    sol::object fn_obj = _node_registry[node_id]["script"]["on_recv"];
    if (!fn_obj.is<sol::function>()) return;
    sol::function fn = fn_obj;
    sol::table self = _node_registry[node_id]["self"];
    sol::table meta = _lua.create_table();
    meta["snr"]     = snr;
    meta["rssi"]    = rssi;
    meta["link_id"] = link_id;
    meta["recv_ms"] = sim_ms;
    sol::protected_function_result r = fn.call(self, std::string(bytes), meta);
    if (!r.valid()) {
        sol::error err = r;
        throw std::runtime_error(std::string("on_recv: ") + err.what());
    }
}

std::string LuaHost::callOnCommand(int node_id, std::string_view cmd_str) {
    sol::object fn_obj = _node_registry[node_id]["script"]["on_command"];
    if (!fn_obj.is<sol::function>()) return "ERROR: no on_command handler";
    sol::function fn = fn_obj;
    sol::table self = _node_registry[node_id]["self"];
    sol::protected_function_result r = fn.call(self, std::string(cmd_str));
    if (!r.valid()) {
        sol::error err = r;
        return std::string("ERROR: ") + err.what();
    }
    sol::object reply = r;
    if (reply.is<std::string>()) return reply.as<std::string>();
    return "";
}

void LuaHost::callOnRadioBusy(int node_id) {
    sol::object fn_obj = _node_registry[node_id]["script"]["on_radio_busy"];
    if (!fn_obj.is<sol::function>()) return;
    sol::function fn = fn_obj;
    sol::table self = _node_registry[node_id]["self"];
    sol::protected_function_result r = fn.call(self);
    if (!r.valid()) {
        sol::error err = r;
        throw std::runtime_error(std::string("on_radio_busy: ") + err.what());
    }
}

void LuaHost::fireTimerCallback(int node_id, uint64_t handle) {
    // T12 will populate _LUS.nodes[id].timers[handle] = function.
    sol::table timers = _node_registry[node_id]["timers"];
    sol::object fn_obj = timers[handle];
    if (!fn_obj.is<sol::function>()) return;
    sol::function fn = fn_obj;
    sol::table self = _node_registry[node_id]["self"];
    sol::protected_function_result r = fn.call(self);
    if (!r.valid()) {
        sol::error err = r;
        throw std::runtime_error(std::string("timer cb: ") + err.what());
    }
}
