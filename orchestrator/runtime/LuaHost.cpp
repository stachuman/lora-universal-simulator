// orchestrator/runtime/LuaHost.cpp
#include "orchestrator/runtime/LuaHost.h"

#include "core/events/EventLog.h"
#include "core/events/JsonToSol.h"
#include "orchestrator/runtime/ScriptedNode.h"
#include "orchestrator/runtime/SimController.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
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

void LuaHost::registerNode(int node_id, ScriptedNode* node) {
    sol::table node_tbl = _lua.create_table();
    node_tbl["self"]   = _lua.create_table();
    node_tbl["script"] = _lua.create_table();
    node_tbl["timers"] = _lua.create_table();   // handle -> sol::function
    _node_registry[node_id] = node_tbl;

    if (node != nullptr) {
        // Bind id/name + the runtime-method lambdas onto self. Lambdas capture
        // `node` by pointer; the orchestrator owns ScriptedNode lifetime and
        // must keep it alive for as long as the Lua state references self.
        sol::table self = node_tbl["self"];
        self["id"]   = node->id();
        self["name"] = node->name();
        // NOTE: Each lambda takes a leading sol::object parameter that we
        // discard. Lua's colon syntax (`self:method(...)`) desugars to
        // `method(self, ...)`, so the bound function must accept that first
        // argument. We don't need it — `node` is already captured by pointer.
        self.set_function("tx",
            [node](sol::object /*self*/, std::string b, sol::optional<sol::table> o) {
                node->api_tx(std::move(b), o);
            });
        self.set_function("after",
            [node](sol::object /*self*/, uint64_t d, sol::function f) {
                return node->api_after(d, f);
            });
        self.set_function("every",
            [node](sol::object /*self*/, uint64_t p, sol::function f) {
                return node->api_every(p, f);
            });
        self.set_function("cancel",
            [node](sol::object /*self*/, uint64_t h) { node->api_cancel(h); });
        self.set_function("now",
            [node](sol::object /*self*/) { return node->api_now(); });
        self.set_function("rand",
            [node](sol::object /*self*/, int lo, int hi) { return node->api_rand(lo, hi); });
        self.set_function("log",
            [node](sol::object /*self*/, sol::variadic_args va) { node->api_log(va); });
        self.set_function("emit",
            [node](sol::object /*self*/, std::string type, sol::optional<sol::table> data) {
                node->api_emit(std::move(type), data);
            });
        self.set_function("peers",
            [node](sol::object /*self*/) { return node->api_peers(); });
        self.set_function("set_rx_sf",
            [node](sol::object /*self*/, int sf) { node->api_set_rx_sf(sf); });
        self.set_function("set_rx_sf_set",
            [node](sol::object /*self*/, sol::table t) { node->api_set_rx_sf_set(t); });
        self.set_function("channel_busy_until",
            [node](sol::object /*self*/) { return node->api_channel_busy_until(); });
        self.set_function("tx_in_flight",
            [node](sol::object /*self*/) { return node->api_tx_in_flight(); });
        self.set_function("airtime_used_ms",
            [node](sol::object /*self*/, uint64_t window_ms) {
                return node->api_airtime_used_ms(window_ms);
            });
        self.set_function("oldest_tx_end_ms",
            [node](sol::object /*self*/) { return node->api_oldest_tx_end_ms(); });
    }
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
    for (const char* name : {"on_init", "on_recv", "on_command", "on_radio_busy",
                              "on_preamble_detected"}) {
        sol::object fn = env[name];
        if (fn.is<sol::function>()) {
            script_tbl[name] = fn;
        }
    }
}

void LuaHost::bindSimGlobals(SimController& ctrl) {
    // Replace any previous binding so a re-init produces a fresh sim table.
    sol::table sim = _lua.create_named_table("sim");

    // sim:time()  -> uint64 millis
    sim.set_function("time",
        [&ctrl](sol::object /*self*/) -> uint64_t {
            return ctrl.simTimeMs();
        });

    // Internal helper: pack a StepResult into a Lua table.
    auto pack_result = [&ctrl](const StepResult& r) {
        sol::table t = ctrl.luaHost().lua().create_table();
        t["ended"]      = r.ended;
        t["new_events"] = r.new_events;
        t["now_ms"]     = r.now_ms;
        return t;
    };

    // sim:step(ms?) -> { ended, new_events, now_ms }
    // ms omitted (or 0) uses cfg.simulation.step_ms.
    sim.set_function("step",
        [&ctrl, pack_result](sol::object /*self*/, sol::optional<uint64_t> ms) {
            StepResult r = ctrl.step(ms.value_or(0));
            return pack_result(r);
        });

    // sim:run(ms?) -> { ended, new_events, now_ms }
    // ms = relative duration to run for; if omitted, runs to cfg.duration_ms.
    sim.set_function("run",
        [&ctrl, pack_result](sol::object /*self*/, sol::optional<uint64_t> ms) {
            uint64_t target = ms.has_value()
                ? ctrl.simTimeMs() + ms.value()
                : static_cast<uint64_t>(ctrl.config().simulation.duration_ms);
            StepResult r = ctrl.runUntil(target);
            return pack_result(r);
        });

    // sim:next() -> { ended, new_events, now_ms }
    // Step until the EventLog buffer grows.
    sim.set_function("next",
        [&ctrl, pack_result](sol::object /*self*/) {
            StepResult r = ctrl.runUntilNextEvent();
            return pack_result(r);
        });

    // sim:cmd(node_name, text) -> reply string
    sim.set_function("cmd",
        [&ctrl](sol::object /*self*/, std::string node, std::string text) {
            return ctrl.fireCommand(node, text);
        });

    // sim:nodes() -> { {id, name, script}, ... }
    sim.set_function("nodes",
        [&ctrl](sol::object /*self*/) {
            sol::state_view L(ctrl.luaHost().lua());
            sol::table out = L.create_table();
            const auto& nodes = ctrl.config().nodes;
            for (size_t i = 0; i < nodes.size(); ++i) {
                sol::table entry = L.create_table();
                entry["id"]     = static_cast<int>(i);
                entry["name"]   = nodes[i].name;
                entry["script"] = nodes[i].script_path;
                out[i + 1] = entry;
            }
            return out;
        });

    // sim:link_snr(from_name, to_name) -> number | nil
    // Returns the static link SNR in dB (after path-loss + topology.links
    // overrides). nil if either node name is unknown or no link exists.
    // Useful for adaptive scripts that want to inspect link quality.
    sim.set_function("link_snr",
        [&ctrl](sol::object /*self*/, std::string from, std::string to) -> sol::object {
            sol::state_view L(ctrl.luaHost().lua());
            int fi = -1, ti = -1;
            const auto& nodes = ctrl.config().nodes;
            for (size_t i = 0; i < nodes.size(); ++i) {
                if (nodes[i].name == from) fi = static_cast<int>(i);
                if (nodes[i].name == to)   ti = static_cast<int>(i);
            }
            if (fi < 0 || ti < 0) return sol::lua_nil;
            float s = ctrl.linkSnrDb(fi, ti);
            if (std::isnan(s)) return sol::lua_nil;
            return sol::make_object(L, s);
        });

    // sim:events(n?) -> { event_table, ... }    (last N, default 10)
    // Each event is parsed back from EventLog::events()'s in-memory buffer
    // into a Lua table via lus::json_to_sol.
    sim.set_function("events",
        [&ctrl](sol::object /*self*/, sol::optional<int> n_opt) {
            sol::state_view L(ctrl.luaHost().lua());
            sol::table out = L.create_table();
            const auto& evs = EventLog::events();
            const int total = static_cast<int>(evs.size());
            const int n = std::max(0, n_opt.value_or(10));
            const int start = std::max(0, total - n);
            int out_idx = 1;
            for (int i = start; i < total; ++i) {
                out[out_idx++] = lus::json_to_sol(L, evs[i]);
            }
            return out;
        });
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
                         float snr, float rssi, int link_id, int src_id,
                         uint64_t sim_ms) {
    sol::object fn_obj = _node_registry[node_id]["script"]["on_recv"];
    if (!fn_obj.is<sol::function>()) return;
    sol::function fn = fn_obj;
    sol::table self = _node_registry[node_id]["self"];
    sol::table meta = _lua.create_table();
    meta["snr"]     = snr;
    meta["rssi"]    = rssi;
    meta["link_id"] = link_id;
    meta["src"]     = src_id;
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

void LuaHost::callOnRadioBusy(int node_id, const RadioBusyInfo& info) {
    sol::object fn_obj = _node_registry[node_id]["script"]["on_radio_busy"];
    if (!fn_obj.is<sol::function>()) return;
    sol::function fn = fn_obj;
    sol::table self = _node_registry[node_id]["self"];
    sol::table tbl = _lua.create_table();
    tbl["reason"]        = info.reason;
    tbl["len"]           = info.len;
    tbl["sf"]            = info.sf;
    tbl["label"]         = info.label;
    tbl["tx_info"]       = info.tx_info;
    tbl["busy_until_ms"] = info.busy_until_ms;
    sol::protected_function_result r = fn.call(self, tbl);
    if (!r.valid()) {
        sol::error err = r;
        throw std::runtime_error(std::string("on_radio_busy: ") + err.what());
    }
}

void LuaHost::callOnPreambleDetected(int node_id, uint64_t time_ms,
                                     int from_id, float snr_db) {
    sol::object fn_obj = _node_registry[node_id]["script"]["on_preamble_detected"];
    if (!fn_obj.is<sol::function>()) return;
    sol::function fn = fn_obj;
    sol::table self = _node_registry[node_id]["self"];
    sol::table tbl = _lua.create_table();
    tbl["time_ms"] = time_ms;
    tbl["from"]    = from_id;
    tbl["snr_db"]  = snr_db;
    sol::protected_function_result r = fn.call(self, tbl);
    if (!r.valid()) {
        sol::error err = r;
        throw std::runtime_error(std::string("on_preamble_detected: ") + err.what());
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
