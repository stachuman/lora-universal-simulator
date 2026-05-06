// orchestrator/runtime/SimController.h
//
// SimController is the class-based stepper that owns the entire per-tick
// simulation pipeline. It exposes step() / runUntil() / runUntilNextEvent() /
// fireCommand() / finalize() so the same engine can be driven by:
//   - the existing batch entry point (Loop.cpp::runSimulation) — a thin
//     wrapper that calls initialize -> step* -> finalize;
//   - a Lua-script entry point (--lua mode); and
//   - the interactive REPL.
//
// Per-tick semantics are byte-identical to the pre-refactor runSimulation.
// The four-stage pipeline (processCommands -> deliverReceptions -> tickTimers
// -> registerTransmissions -> advance clock) lives in the four private
// processCommandsAtStep / deliverReceptionsForStep / tickTimersForStep /
// registerTransmissionsForStep helpers; step() composes them.

#pragma once

#include "core/clock/VirtualClock.h"
#include "core/link/LinkFadingState.h"
#include "core/link/LinkModel.h"
#include "core/physics/CollisionModel.h"
#include "core/physics/LbtModel.h"
#include "core/radio/SimRadio.h"
#include "core/topology/JsonConfig.h"
#include "orchestrator/runtime/LuaHost.h"
#include "orchestrator/runtime/ScriptedNode.h"

#include <cstdint>
#include <memory>
#include <ostream>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>

struct StepResult {
    bool     ended      = false;
    int      new_events = 0;
    uint64_t now_ms     = 0;
};

class SimController {
public:
    SimController(const SimConfig& cfg, std::ostream& events_out);
    ~SimController();

    // Build link model + radios + nodes, load scripts, run on_init, emit
    // sim_start + node_ready lifecycle events. Idempotent (a second call is
    // a no-op).
    void initialize();

    // Run one pass of the per-step pipeline: commands -> receptions ->
    // timers -> registrations, then advance the virtual clock by
    // `advance_ms` (or cfg.simulation.step_ms when 0).
    StepResult step(uint64_t advance_ms = 0);

    // Loop step() until _now_ms >= target_ms, _interrupted, or ended().
    // Returns the last StepResult. new_events counts events accumulated
    // across the entire runUntil call.
    StepResult runUntil(uint64_t target_ms);

    // Loop step() and stop the moment the EventLog buffer-size delta is
    // non-zero, _interrupted is set, or ended() is true. Returns the
    // StepResult that observed the events (or the final no-event one if
    // we ran to end / got interrupted).
    StepResult runUntilNextEvent();

    // Look up a node by name and dispatch ScriptedNode::onCommand. Emit a
    // cmd_reply event. Returns the script's reply string, or
    // "ERROR: unknown node" if `node_name` does not resolve.
    std::string fireCommand(const std::string& node_name, const std::string& cmd);

    // Emit sim_end and run ExpectRunner. Returns assertion failure count.
    // Idempotent: a second call returns 0 without re-emitting sim_end.
    int finalize();

    uint64_t simTimeMs() const { return _now_ms; }
    int      eventCount() const;
    bool     ended() const {
        return _now_ms >= static_cast<uint64_t>(_cfg.simulation.duration_ms);
    }

    LuaHost&         luaHost()        { return _host; }
    const SimConfig& config() const   { return _cfg; }

    // For Ctrl-C: REPL sets this to true to abort an in-progress runUntil.
    void requestInterrupt() { _interrupted = true; }

private:
    // Internal per-tick body (extracted from old runSimulation):
    void processCommandsAtStep();
    void deliverReceptionsForStep();
    void tickTimersForStep();
    void registerTransmissionsForStep();

    struct InFlight {
        int      sender_id;
        uint64_t start_ms;
        uint64_t end_ms;
        std::string bytes;
        int      sf;
        int      bw_hz;
        int      cr;
        uint16_t pre_sym;
        float    t_sym_ms;
        float    t_preamble_ms;

        // Per-receiver collision verdict, populated at TX-start time by
        // registerTransmissionsForStep (mirroring upstream's bidirectional
        // evaluateCollision pair).
        std::vector<uint8_t> collided_at_rcv;       // bool-vector workaround
        std::vector<int>     interferer_at_rcv;
        std::vector<float>   interferer_snr_at_rcv;
    };

    const SimConfig& _cfg;
    std::ostream&    _events_out;

    LuaHost                          _host;
    VirtualClock                     _clock;
    std::mt19937                     _rng;
    std::unique_ptr<MatrixLinkModel> _links;
    std::unique_ptr<LbtModel>        _lbt;
    CollisionConfig                  _coll_cfg;

    std::vector<std::unique_ptr<SimRadio>>     _radios;
    std::vector<std::unique_ptr<ScriptedNode>> _nodes;

    std::unordered_map<std::string, int> _name_to_id;
    std::vector<bool>                    _command_fired;
    std::vector<InFlight>                _in_flight;

    // Per-node receive-SF set. Defaults to [node.sf] when the JSON config
    // leaves nodes[i].sf_rx_set empty (single-SF reception, matching real
    // Semtech LoRa hardware). Configurable to a multi-element vector for
    // opt-in idealized multi-SF reception. Consulted by
    // deliverReceptionsForStep before the SNR-threshold gate to drop
    // off-band packets with drop_sf_mismatch.
    std::vector<std::vector<int>>        _node_sf_rx_set;

    // Per-link fading state. Indexed `sender * n + receiver` (directed:
    // n*n entries, not symmetric n*(n-1)/2). Directed lets the forward
    // and reverse links of a pair fade independently — typical of real-
    // world link models. Upstream FLoRa uses reciprocal/symmetric fading;
    // matching that would be a future refinement.
    std::vector<LinkFadingState> _fading;
    std::vector<uint64_t>        _fading_last_update_ms;

    uint64_t _now_ms      = 0;
    bool     _initialized = false;
    bool     _finalized   = false;
    bool     _interrupted = false;
};
