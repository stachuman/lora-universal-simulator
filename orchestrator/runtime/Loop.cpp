// orchestrator/runtime/Loop.cpp
//
// Main simulation loop. Each step (`step_ms` wall-time) walks the pipeline:
//
//   1. processCommands   - fire any scheduled cfg.commands[] whose at_ms has
//                          arrived; dispatch via ScriptedNode::onCommand and
//                          emit a `cmd_reply` event with the script's return.
//   2. deliverReceptions - for every in-flight TX whose airtime ends in this
//                          step, decide per-receiver whether the packet
//                          survives loss + collision + link-active checks
//                          and call ScriptedNode::onRecv on survivors.
//   3. tickTimers        - fire due timers on every node.
//   4. registerTxs       - drain PendingTx queues, push them onto the in-
//                          flight list, and emit a `tx` event.
//   5. advance           - bump the virtual clock by step_ms.
//
// Several Y2 features are intentionally simplified or skipped here; see the
// TODO comments alongside each one (strict half-duplex enforcement, full LBT
// gating, fading, tx_fail_prob plumbed to SimRadio, lua-only commands).

#include "orchestrator/runtime/Loop.h"

#include "orchestrator/runtime/LuaHost.h"
#include "orchestrator/runtime/ScriptedNode.h"
#include "orchestrator/test_runner/ExpectRunner.h"

#include "core/clock/VirtualClock.h"
#include "core/events/EventLog.h"
#include "core/link/LinkModel.h"
#include "core/physics/CollisionModel.h"
#include "core/physics/LbtModel.h"
#include "core/radio/SimRadio.h"
#include "core/topology/JsonConfig.h"

#include <algorithm>
#include <cstdint>
#include <memory>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

struct InFlight {
    int      sender_id;
    uint64_t start_ms;
    uint64_t end_ms;
    std::string bytes;     // raw payload (kept for delivery + collision events)
    int      sf;
    int      bw_hz;
    int      cr;           // CR denominator (5..8) — universal-sim convention
    uint16_t pre_sym;      // preamble symbols (taken from sender's SimRadio)
    float    t_sym_ms;
    float    t_preamble_ms;

    // Per-receiver collision state. Populated at TX-start time by
    // registerTransmissions (mirroring upstream Orchestrator.cpp lines
    // ~590-619: the bidirectional isDestroyedBy() pair). deliverReceptions
    // just consults these flags — the physics decision is already final.
    //   collided_at_rcv[r] : true if this packet is destroyed at receiver r
    //   interferer_at_rcv[r] : sender_id of the strongest interferer (-1 = none)
    //   interferer_snr_at_rcv[r] : SNR of that interferer at r (for events)
    std::vector<uint8_t>  collided_at_rcv;       // bool-vector workaround
    std::vector<int>      interferer_at_rcv;
    std::vector<float>    interferer_snr_at_rcv;
};

// Build the CapturedSignal struct used by evaluateCollision().
CapturedSignal toCaptured(const InFlight& f, float snr_db_at_rcv) {
    CapturedSignal s{};
    s.src_node       = f.sender_id;
    s.snr_db         = snr_db_at_rcv;
    s.start_ms       = f.start_ms;
    s.end_ms         = f.end_ms;
    s.cr             = static_cast<uint8_t>(f.cr);
    s.pre_sym        = f.pre_sym;
    s.t_sym_ms       = f.t_sym_ms;
    s.t_preamble_ms  = f.t_preamble_ms;
    return s;
}

}  // namespace

LoopResult runSimulation(const SimConfig& cfg, std::ostream& events_out) {
    EventLog::setOutputStream(&events_out);
    // Capture every emitted event into the in-memory buffer so the
    // ExpectRunner can read them at the end of the run.
    EventLog::clearBuffer();
    EventLog::enableBuffer();

    LuaHost       host;
    VirtualClock  global_clock(cfg.simulation.epoch_start);

    // RNG seeded from the config's `seed` (validation already produced it).
    // simulation.seed is already a uint64_t; epoch_start is just metadata.
    std::mt19937 sim_rng(static_cast<std::mt19937::result_type>(cfg.simulation.seed));

    const int n = static_cast<int>(cfg.nodes.size());

    // ---- Build node-name -> id map ------------------------------------------
    std::unordered_map<std::string, int> name_to_id;
    name_to_id.reserve(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) {
        name_to_id.emplace(cfg.nodes[i].name, i);
    }

    // ---- Link model ---------------------------------------------------------
    MatrixLinkModel links(n);
    for (const auto& l : cfg.topology.links) {
        auto fit = name_to_id.find(l.from);
        auto tit = name_to_id.find(l.to);
        if (fit == name_to_id.end() || tit == name_to_id.end()) continue;
        links.setLink(fit->second, tit->second, l.snr, l.rssi, l.snr_std_dev, l.loss);
        if (l.bidir) {
            links.setLink(tit->second, fit->second, l.snr, l.rssi, l.snr_std_dev, l.loss);
        }
    }

    // ---- Radios + nodes -----------------------------------------------------
    // bw in JSON is kHz (matches meshcore_real_sim convention); SimRadio takes Hz.
    std::vector<std::unique_ptr<SimRadio>>    radios;
    std::vector<std::unique_ptr<ScriptedNode>> nodes;
    radios.reserve(static_cast<size_t>(n));
    nodes.reserve(static_cast<size_t>(n));

    for (int i = 0; i < n; ++i) {
        const int sf = cfg.nodes[i].sf;        // already merged with global defaults
        const int bw_khz = cfg.nodes[i].bw;
        const int cr = cfg.nodes[i].cr;
        radios.emplace_back(std::make_unique<SimRadio>(
            global_clock, sf, bw_khz * 1000, cr,
            cfg.simulation.radio.rx_to_tx_delay_ms,
            cfg.simulation.radio.tx_to_rx_delay_ms));
        // TODO(Y2): plumb cfg.nodes[i].tx_fail_prob through SimRadio::setTxFailProb
        // once the loop honours startSendRaw failure paths instead of always
        // staging InFlight entries unconditionally.

        nodes.emplace_back(std::make_unique<ScriptedNode>(
            i, cfg.nodes[i].name,
            host, *radios[i], events_out, global_clock, sim_rng));
    }

    // Register + load scripts (must precede onInit so `self` is populated).
    for (int i = 0; i < n; ++i) {
        host.registerNode(i, nodes[i].get());
        host.loadScript(i, cfg.nodes[i].script_path);
    }

    // sim_start lifecycle event — emitted before per-node onInit so
    // downstream tooling (visualisers, log analyzers) sees a clear
    // bookend marker at the start of the NDJSON stream. Matches upstream
    // Orchestrator::initSimulation (line ~1002).
    EventLog::simStart(0,
                       n,
                       cfg.simulation.step_ms,
                       cfg.simulation.warmup_ms,
                       /*hot_start=*/false);

    // Sanity check: warn if step_ms is coarser than the shortest LoRa
    // symbol time across all nodes. Upstream emits the same diagnostic
    // (Orchestrator::initSimulation lines ~1032-1046) — physics
    // resolution suffers when the tick clock is slower than the radio's
    // own symbol cadence. Pure diagnostic; no behavioural change.
    {
        double min_t_sym = 1e9;
        for (auto& r : radios) {
            const double t = r->getSymbolMs();
            if (t < min_t_sym) min_t_sym = t;
        }
        if (min_t_sym < 1e9 &&
            static_cast<double>(cfg.simulation.step_ms) > min_t_sym) {
            std::fprintf(stderr,
                "lus: warning — step_ms=%d exceeds min t_sym=%.3fms "
                "across nodes; physics resolution may be too coarse\n",
                cfg.simulation.step_ms, min_t_sym);
        }
    }

    // on_init pass; emit node_ready after each on_init returns. Universal
    // sim has no firmware/pub_key concept, so we pass an empty key and
    // use the script-side `role` config field (or "script" as a generic
    // fallback) for the role label.
    for (int i = 0; i < n; ++i) {
        nodes[i]->onInit(cfg.nodes[i].config);
        std::string role = "script";
        const auto& nc = cfg.nodes[i].config;
        if (nc.is_object()) {
            auto it = nc.find("role");
            if (it != nc.end() && it->is_string()) {
                role = it->get<std::string>();
            }
        }
        EventLog::nodeReady(0,
                            cfg.nodes[i].name.c_str(),
                            role.c_str(),
                            /*pub_key=*/nullptr, /*key_len=*/0,
                            cfg.nodes[i].has_location,
                            cfg.nodes[i].lat,
                            cfg.nodes[i].lon,
                            /*firmware=*/nullptr);
    }

    // ---- Main loop state ----------------------------------------------------
    std::vector<bool> command_fired(cfg.commands.size(), false);
    std::vector<InFlight> in_flight;

    // LBT model is constructed but enforcement is deferred (Y2 TODO below).
    LbtModel lbt(n,
                 LbtConfig{cfg.simulation.radio.cad_miss_prob,
                           cfg.simulation.radio.cad_reliable_snr,
                           cfg.simulation.radio.cad_marginal_snr},
                 cfg.simulation.seed ^ 0xCAFEBABEull);
    (void)lbt;  // referenced only by Y2 enforcement path

    // Collision config from radio block.
    CollisionConfig coll_cfg;
    coll_cfg.capture_locked_db   = cfg.simulation.radio.capture_locked_db;
    coll_cfg.capture_unlocked_db = cfg.simulation.radio.capture_unlocked_db;
    // preamble_lock_symbols stays at upstream's default (6).

    // The authoritative event count is the size of EventLog's buffer at
    // the end of the run; stripping the per-emit counter avoids the
    // undercount T14 noted (script_log/script_emit weren't tallied).

    const uint64_t step_ms   = static_cast<uint64_t>(cfg.simulation.step_ms);
    const uint64_t end_ms    = static_cast<uint64_t>(cfg.simulation.duration_ms);
    const uint64_t warmup_ms = static_cast<uint64_t>(cfg.simulation.warmup_ms);

    for (uint64_t now = 0; now < end_ms; now += step_ms) {
        const bool in_warmup = (now < warmup_ms);

        // ---- 1. processCommands -------------------------------------------
        for (size_t k = 0; k < cfg.commands.size(); ++k) {
            if (command_fired[k]) continue;
            if (cfg.commands[k].at_ms > now) continue;

            const auto& cmd = cfg.commands[k];

            // Lua-only commands (cmd.lua_fn set) are deferred to Y2.
            if (!cmd.lua_fn.empty()) {
                // TODO(Y2): dispatch cmd.lua_fn through LuaHost (it needs a
                // generic top-level callback registry; not in T13).
                command_fired[k] = true;
                continue;
            }

            auto it = name_to_id.find(cmd.node);
            if (it == name_to_id.end()) {
                // Unknown node — should be caught at validation, but be safe.
                command_fired[k] = true;
                continue;
            }
            const int target = it->second;
            std::string reply = nodes[target]->onCommand(cmd.command);
            EventLog::cmdReply(static_cast<unsigned long>(now),
                               nodes[target]->name().c_str(),
                               cmd.command.c_str(),
                               reply.c_str());
            command_fired[k] = true;
        }

        // ---- 2. deliverReceptions -----------------------------------------
        // During warmup we skip the in-flight pipeline entirely (matching
        // upstream Orchestrator::executeStep — see lines ~1095-1126: the
        // `if (!in_warmup) deliverReceptions(...)` guard, and the
        // `if (in_warmup) routePackets(...) else registerTransmissions(...)`
        // branch). routePackets is the instant-delivery handler; we
        // implement its equivalent below in section 4.
        std::vector<size_t> ended;
        if (!in_warmup) {
            // Indices of in_flight entries whose airtime has elapsed by `now`.
            ended.reserve(in_flight.size());
            for (size_t i = 0; i < in_flight.size(); ++i) {
                if (in_flight[i].end_ms <= now) ended.push_back(i);
            }
        }

        for (size_t idx : ended) {
            const InFlight& tx = in_flight[idx];

            for (int rcv = 0; rcv < n; ++rcv) {
                if (rcv == tx.sender_id) continue;

                LinkParams lp;
                if (!links.getLink(tx.sender_id, rcv, lp)) continue;  // no link

                // TODO(Y2): apply advanceFading() per-link. Skipped in v1 to
                // keep the loop deterministic-ish without per-link state.
                const float snr_at_rcv = lp.snr;

                // Per-link Bernoulli loss.
                if (lp.loss > 0.0f) {
                    std::uniform_real_distribution<float> u(0.0f, 1.0f);
                    if (u(sim_rng) < lp.loss) {
                        EventLog::dropLoss(
                            static_cast<unsigned long>(now),
                            nodes[tx.sender_id]->name().c_str(),
                            nodes[rcv]->name().c_str(),
                            lp.loss,
                            reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                            static_cast<int>(tx.bytes.size()));
                        continue;
                    }
                }

                // Collision check is now resolved at TX-start time
                // (see registerTransmissions below — bidirectional
                // evaluateCollision matching upstream's behaviour). We
                // just consult the per-receiver flag here.
                if (rcv < static_cast<int>(tx.collided_at_rcv.size()) &&
                    tx.collided_at_rcv[rcv]) {
                    const int   worst_interferer     = tx.interferer_at_rcv[rcv];
                    const float worst_interferer_snr = tx.interferer_snr_at_rcv[rcv];
                    const float snr_margin = snr_at_rcv - worst_interferer_snr;
                    EventLog::collision(
                        static_cast<unsigned long>(now),
                        nodes[tx.sender_id]->name().c_str(),
                        nodes[rcv]->name().c_str(),
                        snr_at_rcv, lp.rssi,
                        reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                        static_cast<int>(tx.bytes.size()),
                        worst_interferer >= 0 ? nodes[worst_interferer]->name().c_str() : nullptr,
                        worst_interferer_snr,
                        snr_margin);
                    continue;
                }

                // TODO(Y2): strict half-duplex enforcement — drop reception if
                // `rcv`'s SimRadio was in TX_WAIT for any of [tx.start, tx.end].
                // For v1 we trust the script.

                // Deliver to the script.
                nodes[rcv]->onRecv(tx.bytes, snr_at_rcv, lp.rssi,
                                   /*link_id=*/0,
                                   /*sim_ms=*/now);
                EventLog::rx(static_cast<unsigned long>(now),
                             nodes[tx.sender_id]->name().c_str(),
                             nodes[rcv]->name().c_str(),
                             snr_at_rcv, lp.rssi,
                             reinterpret_cast<const uint8_t*>(tx.bytes.data()),
                             static_cast<int>(tx.bytes.size()),
                             static_cast<uint32_t>(tx.end_ms - tx.start_ms));
            }
        }

        // Compact in_flight: remove ended entries.
        in_flight.erase(
            std::remove_if(in_flight.begin(), in_flight.end(),
                           [now](const InFlight& f) { return f.end_ms <= now; }),
            in_flight.end());

        // ---- 3. tickTimers ------------------------------------------------
        for (int i = 0; i < n; ++i) {
            nodes[i]->tickTimers(now);
        }

        // ---- 4. registerTransmissions -------------------------------------
        // During warmup, route every drained TX instantly to all reachable
        // receivers — no airtime delay, no collision check, no link loss
        // (mirrors upstream routePackets at lines ~198-228). tx + rx events
        // are still emitted with the computed airtime so downstream
        // visualisers see the wire activity; only the physics path is
        // bypassed. The intent is to let scripts establish steady state
        // (route caches, advert exchanges, etc.) before the stress-test
        // physics phase starts.
        if (in_warmup) {
            for (int i = 0; i < n; ++i) {
                for (auto& p : nodes[i]->drainPendingTxs()) {
                    const int sf    = (p.sf    >= 0) ? p.sf    : radios[i]->getSF();
                    const int bw_hz = (p.bw_hz >= 0) ? p.bw_hz : radios[i]->getBwHz();
                    const int cr    = (p.cr    >= 0) ? p.cr    : radios[i]->getCR();
                    radios[i]->setRadioParams(sf, bw_hz, cr);

                    const uint32_t airtime =
                        radios[i]->getEstAirtimeFor(static_cast<int>(p.bytes.size()));

                    EventLog::tx(static_cast<unsigned long>(now),
                                 nodes[i]->name().c_str(),
                                 reinterpret_cast<const uint8_t*>(p.bytes.data()),
                                 static_cast<int>(p.bytes.size()),
                                 airtime);

                    for (int r = 0; r < n; ++r) {
                        if (r == i) continue;
                        LinkParams lp;
                        if (!links.getLink(i, r, lp)) continue;
                        nodes[r]->onRecv(p.bytes, lp.snr, lp.rssi,
                                         /*link_id=*/0,
                                         /*sim_ms=*/now);
                        EventLog::rx(static_cast<unsigned long>(now),
                                     nodes[i]->name().c_str(),
                                     nodes[r]->name().c_str(),
                                     lp.snr, lp.rssi,
                                     reinterpret_cast<const uint8_t*>(p.bytes.data()),
                                     static_cast<int>(p.bytes.size()),
                                     airtime);
                    }
                }
            }
            // Skip the post-warmup physics path for this step.
            global_clock.advanceMillis(step_ms);
            continue;
        }

        for (int i = 0; i < n; ++i) {
            for (auto& p : nodes[i]->drainPendingTxs()) {
                const int sf    = (p.sf    >= 0) ? p.sf    : radios[i]->getSF();
                const int bw_hz = (p.bw_hz >= 0) ? p.bw_hz : radios[i]->getBwHz();
                const int cr    = (p.cr    >= 0) ? p.cr    : radios[i]->getCR();
                radios[i]->setRadioParams(sf, bw_hz, cr);

                const uint32_t airtime =
                    radios[i]->getEstAirtimeFor(static_cast<int>(p.bytes.size()));

                // TODO(Y2): plumb through SimRadio::startSendRaw so half-
                // duplex/LBT bookkeeping fires; for v1 we synthesise the
                // InFlight directly.
                InFlight f;
                f.sender_id     = i;
                f.start_ms      = now;
                f.end_ms        = now + airtime;
                f.bytes         = std::move(p.bytes);
                f.sf            = sf;
                f.bw_hz         = bw_hz;
                f.cr            = cr;
                f.pre_sym       = static_cast<uint16_t>(radios[i]->getPreambleSymbols());
                f.t_sym_ms      = static_cast<float>(radios[i]->getSymbolMs());
                f.t_preamble_ms = static_cast<float>(radios[i]->getPreambleMs());
                f.collided_at_rcv.assign(static_cast<size_t>(n), 0);
                f.interferer_at_rcv.assign(static_cast<size_t>(n), -1);
                f.interferer_snr_at_rcv.assign(static_cast<size_t>(n), 0.0f);

                // Bidirectional collision evaluation at TX-start time.
                // Matches upstream Orchestrator.cpp::registerTransmissions
                // (lines ~590-619): for every existing in-flight `e` and
                // every receiver `r ≠ e.sender_id, ≠ f.sender_id`, run
                // evaluateCollision both directions and stamp the loser
                // with collided_at_rcv[r] = true. Once a packet is
                // delivered + popped from in_flight, no further check is
                // needed: the flag carries the verdict.
                for (auto& e : in_flight) {
                    // Time overlap?
                    if (e.end_ms <= f.start_ms || e.start_ms >= f.end_ms)
                        continue;
                    for (int r = 0; r < n; ++r) {
                        if (r == f.sender_id || r == e.sender_id) continue;
                        LinkParams lp_f, lp_e;
                        if (!links.getLink(f.sender_id, r, lp_f)) continue;
                        if (!links.getLink(e.sender_id, r, lp_e)) continue;
                        CapturedSignal sig_f = toCaptured(f, lp_f.snr);
                        CapturedSignal sig_e = toCaptured(e, lp_e.snr);

                        // f-vs-e: does the new TX get destroyed by the existing one?
                        auto df = evaluateCollision(coll_cfg, sig_f, sig_e);
                        if (!df.survived) {
                            // Track strongest interferer (highest SNR).
                            if (f.interferer_at_rcv[r] < 0 ||
                                lp_e.snr > f.interferer_snr_at_rcv[r]) {
                                f.interferer_at_rcv[r]     = e.sender_id;
                                f.interferer_snr_at_rcv[r] = lp_e.snr;
                            }
                            f.collided_at_rcv[r] = 1;
                        }
                        // e-vs-f: does the existing TX get destroyed by the new one?
                        auto de = evaluateCollision(coll_cfg, sig_e, sig_f);
                        if (!de.survived) {
                            if (r >= static_cast<int>(e.collided_at_rcv.size())) continue;
                            if (e.interferer_at_rcv[r] < 0 ||
                                lp_f.snr > e.interferer_snr_at_rcv[r]) {
                                e.interferer_at_rcv[r]     = f.sender_id;
                                e.interferer_snr_at_rcv[r] = lp_f.snr;
                            }
                            e.collided_at_rcv[r] = 1;
                        }
                    }
                }

                EventLog::tx(static_cast<unsigned long>(now),
                             nodes[i]->name().c_str(),
                             reinterpret_cast<const uint8_t*>(f.bytes.data()),
                             static_cast<int>(f.bytes.size()),
                             airtime);

                in_flight.push_back(std::move(f));
            }
        }

        // ---- 5. advance ---------------------------------------------------
        global_clock.advanceMillis(step_ms);
    }

    // sim_end lifecycle event — bookend marker at the close of the
    // NDJSON stream, before assertion evaluation. Matches upstream
    // Orchestrator::emitSummary (line ~1236).
    EventLog::simEnd(static_cast<unsigned long>(end_ms));

    LoopResult result;
    result.events_emitted     = static_cast<int>(EventLog::events().size());
    result.assertion_failures = ExpectRunner::evaluate(cfg, EventLog::events());
    result.ok = (result.assertion_failures == 0);
    return result;
}
