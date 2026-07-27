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
#include "core/link/PathLossModel.h"
#include "core/physics/CollisionModel.h"
#include "core/physics/LbtModel.h"
#include "core/radio/SimRadio.h"
#include "core/topology/JsonConfig.h"
#include "orchestrator/runtime/INode.h"
#include "orchestrator/runtime/LuaHost.h"
#include "orchestrator/runtime/ScriptedNode.h"

#include "orchestrator/runtime/RngStreams.h"

#include <cstdint>
#include <memory>
#include <ostream>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>

#include "orchestrator/runtime/LinkBudget.h"   // §1.5: txPowerDeltaDb() (shared with the unit test)

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
    int              protocolNodeId(size_t runtime_id) const;

    // Current link SNR (dB) between two node ids. Returns NaN when no link
    // is configured (sender == receiver, or path-loss/topology produced no
    // entry). Reflects the static link configuration; per-step fading is
    // applied at delivery time and is not visible here.
    float linkSnrDb(int from, int to) const;

    // For Ctrl-C: REPL sets this to true to abort an in-progress runUntil.
    void requestInterrupt() { _interrupted = true; }

private:
    // Internal per-tick body (extracted from old runSimulation):
    // Fire on_init for any node whose staged startup offset has elapsed.
    // Lifecycle: handle scheduled deferred starts (start_at_ms) and
    // scheduled deaths (dies_at_ms). Runs at the top of step() before
    // any per-step work; toggles _node_alive and emits node_started /
    // node_died.
    void processLifecycleAtStep();

    // Called at the top of each step before processCommandsAtStep so that
    // a node initialized this tick is fully alive before any of its
    // commands or rx deliveries are processed in the same step.
    void processStartupAtStep();

    void processCommandsAtStep();

    // Pre-flight (initialize()): every scenario `send <name>` / `send_e2e <name>` must
    // resolve to an id the addressee wears on the SENDER's layer. THROWS on a scenario
    // that names a node it shares no layer with, or that sends by name from a
    // multi-layer gateway — both are authoring errors whose verb is send_layer. Run
    // before the first event is emitted so a refused run produces zero bytes.
    void validateSendByNameCommands() const;

    void deliverReceptionsForStep();
    void tickTimersForStep();
    void registerTransmissionsForStep();

    // ★ §carrier — THE ONE CARRIER-REACHABILITY RULE. "Is node `idx`'s modem tuned to the channel this
    // frame is on?" HARD SPLIT: exact integer-kHz equality, or unreachable. No partial adjacent-channel
    // overlap is modelled — we have no bench data on our radios' adjacent-channel rejection, and
    // inventing the parameters would be fabricated physics (2026-07-26 ruling).
    //
    // ⚠ IT EXISTS AS ONE FUNCTION BECAUSE THERE ARE FOUR CALLERS AND THEY MUST NEVER DISAGREE:
    //   1. deliverReceptionsForStep  — the decode gate (emits drop_freq_mismatch)
    //   2. registerTransmissionsForStep's observer loop — RX->TX turnaround charge, LBT busy-notify and
    //      the PreambleDetected callback. A node that CANNOT DECODE a frame must equally not DETECT its
    //      preamble; the alternative is physically impossible and would corrupt LBT + beacon throttling.
    //   3. the energy-LBT ask-time busy provider — an out-of-band frame deposits no in-band energy.
    //   4. the frame-vs-frame collision evaluation — two carriers cannot interfere. (This is the
    //      DELIBERATE ASYMMETRY vs the BW gate, which keeps feeding collisions on purpose because
    //      bandwidth grants NO orthogonality; a separate CHANNEL genuinely does.)
    // Comparing integer kHz — never a double MHz — because exact float equality is a latent bug; the
    // canonicalization is the firmware's own protocol::mhz_to_khz, applied once at the HalAdapter seam.
    bool tunedToCarrier(int idx, uint32_t frame_freq_khz) const {
        return _node_rx_freq_khz[static_cast<size_t>(idx)] == frame_freq_khz;
    }

    struct InFlight {
        int      sender_id;
        uint64_t start_ms;
        uint64_t end_ms;
        std::string bytes;
        std::string label;
        std::string info;
        int      sf;
        int      bw_hz;
        int      cr;
        int      power_dbm = -127;   // §1.5: explicit per-frame TX power (-127 = radio default); link-budget delta applied at delivery/collision
        // §carrier: the RF carrier this frame flew on, INTEGER kHz. Stamped from the SENDER's live tuned
        // carrier (_node_rx_freq_khz[sender]) — a radio has one synthesizer, so it transmits on whatever
        // it is tuned to (the device makes the same guarantee: DeviceRadio::set_rx_freq latches the
        // frequency and start_transmit never sets one). There is no per-frame override to resolve: the
        // firmware's TxParams carries no frequency field at all, unlike sf/bw/cr.
        uint32_t freq_khz = 0;
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

    // ---- Per-stream RNG (Wave-4 Slice C — kill the shared-mt19937 coupling) --
    // Every stochastic consumer draws from an INDEPENDENT stream derived from
    // the scenario seed (see RngStreams.h), so one consumer's draw count can
    // never perturb another's sequence. The scenario `seed` remains the single
    // knob that reseeds all of them.
    //
    // _node_rng[i]  — per-node behaviour + timing profile: the node's firmware
    //   simRandRange (FirmwareNode/ScriptedNode hold a reference), plus its
    //   clock-drift and startup-jitter draws. Keyed by the RUNTIME index i
    //   (0..n-1), which is guaranteed unique & stable; the protocol node_id is
    //   NOT usable as the key (fresh/unprovisioned nodes all boot node_id=0 and
    //   would collide). Sized once in initialize() BEFORE nodes are built and
    //   never resized, so the references handed to nodes stay valid.
    std::vector<std::mt19937> _node_rng;
    // _pathloss_rng — the path-loss offset/shadow draws (per-node hardware bias
    //   + per-pair shadow + coherence resamples). One dedicated stream: these
    //   are fixed-count init draws + fixed-cadence resamples, NEVER driven by
    //   node runtime behaviour, so a single stream already gives the isolation
    //   guarantee (no coupling to node draw counts or to the per-link physics).
    //   Passed by reference into PathLossModel.
    std::mt19937 _pathloss_rng;
    // _link_rng — per-directed-link physics rolls (fading, PER sigmoid,
    //   preamble-miss, Bernoulli loss). Keyed by link_idx = sender*n + rcv
    //   (matches _fading indexing). LAZY: a stream is created on first use,
    //   deterministically seeded from (seed, Link, link_idx) regardless of
    //   WHEN first touched, so reproducibility holds while a dense n*n grid
    //   (e.g. s18's 138 nodes → 19k links) never eagerly allocates ~19k
    //   generators for links that carry no traffic.
    std::unordered_map<uint64_t, std::mt19937> _link_rng;
    std::mt19937& linkRng(uint64_t link_idx);

    std::unique_ptr<MatrixLinkModel> _links;
    std::unique_ptr<LbtModel>        _lbt;
    std::unique_ptr<PathLossModel>   _path_loss;
    void rebuildLinksFromPathLoss();
    // When asymmetry_coherence_ms > 0, the per-pair shadow component of
    // the path-loss model is re-sampled at this absolute sim-time. Rebuild
    // every directed link in _links from the new draws + cached per-node
    // offsets, then re-apply explicit topology.links overrides on top.
    uint64_t                         _next_pair_shadow_resample_ms = UINT64_MAX;
    CollisionConfig                  _coll_cfg;

    std::vector<std::unique_ptr<SimRadio>>     _radios;
    // Polymorphic over INode so a future FirmwareNode (MeshRoute C++ firmware
    // in-loop) can sit beside the Lua-backed ScriptedNode. Today every node is
    // a ScriptedNode; the only site needing the concrete type is the Lua
    // binding in initialize() (see the static_cast there).
    std::vector<std::unique_ptr<INode>>        _nodes;

    std::unordered_map<std::string, int> _name_to_id;
    std::vector<bool>                    _command_fired;
    // Per-directive match tally for _cfg.drop_directives (R3.x forced-drop
    // gate); the tally lives here (not in the const _cfg). Sized in
    // initialize(), incremented in deliverReceptionsForStep. Empty when no
    // forced_drops are configured (the common case — zero overhead).
    std::vector<int>                     _drop_match_count;
    // Mutable per-node positions. Initialized from _cfg.nodes[].lat/lon at
    // initialize(); advanced by rebuildLinksFromPathLoss() at each
    // asymmetry_coherence_ms tick for nodes with velocity_mps > 0.
    // Path-loss recompute always reads from here, not from _cfg, so the
    // const SimConfig stays untouched.
    std::vector<double>                  _node_lat;
    std::vector<double>                  _node_lon;
    std::vector<InFlight>                _in_flight;

    // Per-node receive-SF set. Defaults to [node.sf] when the JSON config
    // leaves nodes[i].sf_rx_set empty (single-SF reception, matching real
    // Semtech LoRa hardware). Configurable to a multi-element vector for
    // opt-in idealized multi-SF reception. Consulted by
    // deliverReceptionsForStep before the SNR-threshold gate to drop
    // off-band packets with drop_sf_mismatch.
    std::vector<std::vector<int>>        _node_sf_rx_set;

    // Per-node LIVE receive bandwidth in Hz — the BW twin of _node_sf_rx_set.
    // Seeded from nodes[i].bw (REQUIRED and validated > 0 by JsonConfig, so a
    // seed is never 0/unset) and moved at runtime by a retune through the
    // borrowed slot handed out via INode::attachRxBwSlot:
    //   firmware  Hal::set_rx_bw -> ISimHal::simSetRxBw  (a dual-BW gateway's
    //             per-layer window switch, a mobile adopting a host's PHY)
    //   Lua       self:set_rx_bw(hz)
    // Consulted by deliverReceptionsForStep immediately after the SF gate: a
    // real LoRa modem demodulates only the bandwidth it is tuned to, so a
    // BW-mismatched frame is dropped with drop_bw_mismatch. Sized once via
    // assign() so &_node_rx_bw_hz[i] stays valid for this controller's life.
    // NOT derived from _radios[i]->getBwHz(): that tracks the node's last
    // TRANSMISSION (setRadioParams is called with each TX frame's params).
    std::vector<int>                     _node_rx_bw_hz;

    // ★ §carrier (2026-07-26 owner ruling — "a realistic simulator able to test our multi layer /
    // multi freq simulations"): per-node LIVE RF CARRIER in INTEGER kHz, the frequency twin of
    // _node_sf_rx_set / _node_rx_bw_hz. Seeded from nodes[i].freq_khz (post-inherit, validated > 0) and
    // moved at runtime through the borrowed slot handed out via INode::attachRxFreqSlot:
    //   firmware  Hal::set_rx_freq(MHz) -> HalAdapter (mhz_to_khz) -> ISimHal::simSetRxFreqKhz
    //             (a gateway's per-layer window switch; a mobile adopting a host's PHY)
    //   Lua       self:set_rx_freq_khz(khz)
    //
    // SINGLE-VALUED, deliberately unlike _node_sf_rx_set: a node has ONE synthesizer, so it hears
    // exactly one carrier — a dual-carrier gateway IS genuinely deaf to layer 1 while tuned to layer 0.
    // That is the physics the window scheduler exists to manage; simultaneous multi-carrier RX is NOT
    // modelled. The same value is also what the node TRANSMITS on (InFlight::freq_khz is stamped from it).
    //
    // ★ FOUR consumers, ONE predicate — tunedToCarrier(). See its comment for why every one of them
    // must agree: a node that cannot decode a frame must equally not detect its preamble, not treat the
    // channel as busy, and not suffer collisions from it. Splitting the rule across hand-written copies
    // is the drift this codebase keeps paying for.
    // Sized once via assign() so &_node_rx_freq_khz[i] stays valid for this controller's life.
    std::vector<uint32_t>                _node_rx_freq_khz;

    // Slice A2: per-node key_hash32 actually fed to the engines. Derived from the node's identity
    // seed (lib/core/identity) when present, else the literal/fnv fallback in the const _cfg. Lives
    // here (not in the const _cfg) so sim+device share one derivation without mutating the config.
    std::vector<uint32_t>                _resolved_key_hash32;

    // Per-node "TX in flight until" slot. Set to InFlight.end_ms when an
    // InFlight is pushed for sender i; cleared to 0 when the InFlight is
    // compacted out at end_ms. Read by ScriptedNode::api_tx_in_flight via
    // a borrowed pointer (assigned once via attachTxInFlightSlot — outer
    // vector is sized via assign() below and never reallocates).
    std::vector<uint64_t>                _node_tx_in_flight_until;

    // Per-node window of the most recent transmission [start, end], PERSISTED
    // after the TX ends (unlike _node_tx_in_flight_until, never reset to 0).
    // The half-duplex check needs it because an incoming frame is delivered at
    // its end_ms, by which point a receiver TX that overlapped the frame's
    // airtime (but ended a few ms earlier) has already been compacted out of
    // _in_flight — so scanning _in_flight alone would miss it and wrongly
    // deliver a frame whose preamble arrived while the receiver was TX'ing.
    std::vector<uint64_t>                _node_last_tx_start_ms;
    std::vector<uint64_t>                _node_last_tx_end_ms;

    // Per-node sim-time at which on_init fires. Drawn uniformly from
    // [0, simulation.node_startup_jitter_ms] using the node's own stream
    // (_node_rng[i], so reproducible per seed AND isolated from other nodes'
    // draw counts). Nodes with offset 0 init synchronously at SimController
    // init time as before; the rest are fired during step() once
    // _now_ms >= their offset. When jitter is 0 (the default), no rand
    // draws are made and all offsets stay 0 — bit-identical to legacy.
    std::vector<uint64_t>                _node_init_at_ms;

    // Per-link fading state. Indexed `sender * n + receiver` (directed:
    // n*n entries, not symmetric n*(n-1)/2). Directed lets the forward
    // and reverse links of a pair fade independently — typical of real-
    // world link models. Upstream FLoRa uses reciprocal/symmetric fading;
    // matching that would be a future refinement.
    std::vector<LinkFadingState> _fading;
    std::vector<uint64_t>        _fading_last_update_ms;

    uint64_t _now_ms      = 0;
    bool     _initialized = false;
    // True once the warmup_end NDJSON event has been emitted for this
    // simulation. Flipped at the top of step() the first time _now_ms
    // crosses simulation.warmup_ms.
    bool     _warmup_end_emitted = false;

    // Per-node lifecycle "is currently alive" flag. Initialized in
    // initialize(): true if start_at_ms == 0 (alive from t=0) else
    // false. Flipped to true at start_at_ms (node_started emitted) and
    // back to false at dies_at_ms (node_died emitted). Each per-step
    // helper consults this to skip dead / unborn nodes.
    std::vector<bool> _node_alive;
    bool     _finalized   = false;
    bool     _interrupted = false;
};
