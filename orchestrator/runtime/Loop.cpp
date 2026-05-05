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

    // on_init pass.
    for (int i = 0; i < n; ++i) {
        nodes[i]->onInit(cfg.nodes[i].config);
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

    const uint64_t step_ms = static_cast<uint64_t>(cfg.simulation.step_ms);
    const uint64_t end_ms  = static_cast<uint64_t>(cfg.simulation.duration_ms);

    for (uint64_t now = 0; now < end_ms; now += step_ms) {
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
        // Indices of in_flight entries whose airtime has elapsed by `now`.
        std::vector<size_t> ended;
        ended.reserve(in_flight.size());
        for (size_t i = 0; i < in_flight.size(); ++i) {
            if (in_flight[i].end_ms <= now) ended.push_back(i);
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

                // Collision check against every other in-flight TX that
                // overlaps in time with this one and is also heard at `rcv`.
                bool collided = false;
                int  worst_interferer = -1;
                float worst_interferer_snr = 0.0f;
                for (size_t j = 0; j < in_flight.size(); ++j) {
                    if (j == idx) continue;
                    const InFlight& other = in_flight[j];
                    if (other.sender_id == rcv) continue;  // self-TX irrelevant
                    // Time overlap?
                    if (other.end_ms <= tx.start_ms ||
                        other.start_ms >= tx.end_ms) continue;
                    LinkParams lp2;
                    if (!links.getLink(other.sender_id, rcv, lp2)) continue;
                    CapturedSignal primary    = toCaptured(tx,    snr_at_rcv);
                    CapturedSignal interferer = toCaptured(other, lp2.snr);
                    auto d = evaluateCollision(coll_cfg, primary, interferer);
                    if (!d.survived) {
                        collided = true;
                        worst_interferer     = other.sender_id;
                        worst_interferer_snr = lp2.snr;
                        break;
                    }
                }
                if (collided) {
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

    LoopResult result;
    result.events_emitted     = static_cast<int>(EventLog::events().size());
    result.assertion_failures = ExpectRunner::evaluate(cfg, EventLog::events());
    result.ok = (result.assertion_failures == 0);
    return result;
}
