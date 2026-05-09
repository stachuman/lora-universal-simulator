// orchestrator/runtime/LuaHost.h
//
// LuaHost owns one sol::state for the whole simulation. Per-node state lives
// in a Lua-side registry table:
//   _LUS = {
//       nodes = {
//           [id] = { self = {...}, script = {...}, timers = {...} }
//       }
//   }
//
// Script files are loaded once per unique path (cached chunk) and then run
// in a fresh sol::environment per node so that nodes running the same script
// have isolated globals.
//
// Sandbox: only base/string/table/math/coroutine libraries are opened. No io,
// no os, no debug.
//
// The runtime methods bound onto each node's `self` table (tx, after, every,
// cancel, log, emit, ...) are wired by ScriptedNode in Task 12; LuaHost itself
// is just the dispatch + state-registry layer.

#pragma once
#include "sol/sol.hpp"
#include <string>
#include <string_view>
#include <unordered_map>
#include <cstdint>

class ScriptedNode;
class SimController;
struct RadioBusyInfo;

class LuaHost {
public:
    LuaHost();

    // Build the per-node registry slot: _LUS.nodes[node_id] = { self, script, timers }.
    // The ScriptedNode pointer is currently unused here; T12 will use it to bind
    // runtime callbacks (tx/after/every/...) onto self before on_init runs.
    void registerNode(int node_id, ScriptedNode* node);

    // Load (or reuse cached) script chunk at `path`, run it in a fresh environment,
    // and copy any of {on_init, on_recv, on_command, on_radio_busy} into the
    // node's script table.
    void loadScript(int node_id, const std::string& path);

    // Expose a global `sim` table to Lua, bound to the supplied SimController.
    // Methods are dispatched colon-style (sim:time(), sim:step(ms), ...).
    // Bindings hold `ctrl` by reference; the controller must outlive this
    // LuaHost (true for the standard SimController-owns-LuaHost ownership).
    // Idempotent in spirit — calling twice replaces the previous bindings.
    void bindSimGlobals(SimController& ctrl);

    // Callback dispatchers. Each tolerates a missing optional callback (no-op).
    void callOnInit(int node_id, const sol::table& config);
    void callOnRecv(int node_id, std::string_view bytes,
                    float snr, float rssi, int link_id, int src_id,
                    uint64_t sim_ms);
    std::string callOnCommand(int node_id, std::string_view cmd_str);
    void callOnRadioBusy(int node_id, const RadioBusyInfo& info);
    // Dispatch the SX1262-PreambleDetected-equivalent callback. No-op if the
    // script doesn't define on_preamble_detected. info table carries
    // {time_ms, from, snr_db}.
    void callOnPreambleDetected(int node_id, uint64_t time_ms,
                                int from_id, float snr_db);

    // Called by the timer wheel when a registered timer fires. Looks up
    // _LUS.nodes[node_id].timers[handle] and invokes it with `self`.
    void fireTimerCallback(int node_id, uint64_t handle);

    sol::state& lua() { return _lua; }

private:
    sol::state _lua;
    // Cache of loaded chunks keyed by absolute path. The same compiled chunk
    // is re-run per node (in a fresh environment) to populate per-node closures.
    std::unordered_map<std::string, sol::function> _loaded_scripts;
    // Convenience handle to _LUS.nodes (top-level table built at construction).
    sol::table _node_registry;
};
