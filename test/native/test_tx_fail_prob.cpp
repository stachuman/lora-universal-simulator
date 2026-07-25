// test/native/test_tx_fail_prob.cpp
//
// Per-node modem TX-failure injection (Wave-4 §6.1.2 of the 2026-07-20 realism
// review) — the C2 half of the turnaround slice.
//
// nodes[].tx_fail_prob was parsed by JsonConfig and range-validated there, and
// then SILENTLY DISCARDED: SimController never called setTxFailProb, and the
// roll itself lived inside SimRadio::startSendRaw, which the live TX path
// bypasses entirely (§startSendRaw-bypass). A scenario could ask for a 30 %
// failing modem and get a perfect one.
//
// Two halves, because the corpus can prove neither:
//
//   [1] MECHANISM (SimRadio unit) — a nonzero probability really fires, and
//       ★ prob 0 is DRAW-FREE. The draw-free property is the load-bearing one:
//       every scenario in the corpus omits tx_fail_prob, so corpus byte-identity
//       is only evidence that the guard works — it can never show the guard is
//       NEEDED. Here it is shown directly: N rolls at prob 0 must leave the
//       stream in a state indistinguishable from never having rolled at all.
//
//   [2] PLUMBING (SimController) — the config key reaches the radio and a
//       failed arm removes the frame from the air, visibly. Metal semantics are
//       asserted too (lib/hal/device_hal.cpp pump_tx: "A failed arm drops the
//       frame (rare radio_error; not retried here)"): the frame vanishes from
//       the air but is NOT silent — a tx_fail event names the node — and the
//       protocol is NOT notified, so no tx_deferred / on_radio_busy appears.

#include "core/clock/VirtualClock.h"
#include "core/radio/SimRadio.h"
#include "core/topology/JsonConfig.h"
#include "orchestrator/runtime/RngStreams.h"
#include "orchestrator/runtime/SimController.h"

#include <cassert>
#include <cstdio>
#include <cstdint>
#include <sstream>
#include <string>
#include <vector>

namespace {

std::vector<std::string> linesFor(const std::string& ndjson,
                                  const std::string& type_frag,
                                  const std::string& who_frag) {
    std::vector<std::string> hits;
    std::istringstream in(ndjson);
    std::string line;
    while (std::getline(in, line)) {
        if (line.find(type_frag) == std::string::npos) continue;
        if (!who_frag.empty() && line.find(who_frag) == std::string::npos) continue;
        hits.push_back(line);
    }
    return hits;
}

size_t countFor(const std::string& ndjson, const std::string& type_frag,
                const std::string& who_frag) {
    return linesFor(ndjson, type_frag, who_frag).size();
}

}  // namespace

int main(int argc, char** argv) {
    assert(argc >= 2 && "usage: test_tx_fail_prob <config.json>");

    // ======================= [1] MECHANISM ==================================
    VirtualClock clock;

    // ---- prob 0 never fails --------------------------------------------
    {
        SimRadio r(clock);
        r.seed(0xC0FFEEu);
        r.setTxFailProb(0.0f);
        for (int i = 0; i < 500; ++i) assert(!r.rollTxFail());
        assert(r.getTxFailCount() == 0);
    }

    // ---- ★ prob 0 is DRAW-FREE ------------------------------------------
    // Two identically-seeded radios. `warmed` rolls 500 times at prob 0 FIRST,
    // then both are set to 0.5 and rolled in lockstep. If a prob-0 roll had
    // advanced the xorshift state, the two sequences would diverge immediately
    // — which is exactly how an unguarded draw would move every scenario in the
    // corpus (each TX would consume a value it does not use).
    {
        SimRadio warmed(clock), fresh(clock);
        warmed.seed(0x12345678u);
        fresh.seed(0x12345678u);

        warmed.setTxFailProb(0.0f);
        for (int i = 0; i < 500; ++i) assert(!warmed.rollTxFail());

        warmed.setTxFailProb(0.5f);
        fresh.setTxFailProb(0.5f);
        int fails = 0;
        for (int i = 0; i < 400; ++i) {
            const bool a = warmed.rollTxFail();
            const bool b = fresh.rollTxFail();
            assert(a == b && "a prob-0 roll must consume NOTHING from the stream");
            if (a) ++fails;
        }
        assert(warmed.getTxFailCount() == fresh.getTxFailCount());
        // Non-vacuous: the lockstep comparison only means something if the
        // sequence is actually doing some failing and some passing.
        assert(fails > 100 && fails < 300 && "a 0.5 prob must fail ~half the rolls");
    }

    // ---- prob 1 always fails, and the counter tracks it -------------------
    {
        SimRadio r(clock);
        r.seed(0xABCDEF01u);
        r.setTxFailProb(1.0f);
        for (int i = 0; i < 50; ++i) assert(r.rollTxFail());
        assert(r.getTxFailCount() == 50);
    }

    // ---- per-node independence (Slice C) ---------------------------------
    // Two nodes' failure streams must not be the same sequence. Before this
    // slice nothing ever called seed(), so every radio shared _rng_state == 1.
    {
        SimRadio a(clock), b(clock);
        a.seed(mrsim::deriveSeed(4242, mrsim::RngDomain::TxFail, 0));
        b.seed(mrsim::deriveSeed(4242, mrsim::RngDomain::TxFail, 1));
        a.setTxFailProb(0.5f);
        b.setTxFailProb(0.5f);
        bool differed = false;
        for (int i = 0; i < 64 && !differed; ++i) {
            if (a.rollTxFail() != b.rollTxFail()) differed = true;
        }
        assert(differed && "two nodes must not share one TX-failure sequence");
    }

    // ======================= [2] PLUMBING ===================================
    SimConfig cfg = JsonConfig::loadFromFile(argv[1]);
    // The fixture's intent, pinned so a config edit cannot quietly void the run.
    assert(cfg.nodes.size() == 3);
    assert(cfg.nodes[0].name == "always_fails" && cfg.nodes[0].tx_fail_prob == 1.0f);
    assert(cfg.nodes[1].name == "never_fails"  && cfg.nodes[1].tx_fail_prob == 0.0f);

    std::ostringstream out;
    SimController ctrl(cfg, out);
    ctrl.initialize();
    ctrl.runUntil(cfg.simulation.duration_ms + 1000);
    ctrl.finalize();
    const std::string log = out.str();

    // The control node transmits and is heard; the failing node does neither.
    assert(countFor(log, "\"type\":\"tx\"", "\"node\":\"never_fails\"") == 1);
    assert(countFor(log, "\"type\":\"rx\"", "\"from\":\"never_fails\"") == 1);
    assert(countFor(log, "\"type\":\"tx\"", "\"node\":\"always_fails\"") == 0
           && "a failed arm must put NO frame on the air");
    assert(countFor(log, "\"type\":\"rx\"", "\"from\":\"always_fails\"") == 0);

    // ...and the loss is VISIBLE, never a silent vanish.
    const auto fails = linesFor(log, "\"type\":\"tx_fail\"", "");
    assert(fails.size() == 1 && "the dropped TX must be reported exactly once");
    assert(fails[0].find("\"node\":\"always_fails\"") != std::string::npos);
    assert(fails[0].find("\"count\":1") != std::string::npos);

    // Metal semantics: the protocol is NOT told (no busy/defer path is taken).
    assert(countFor(log, "\"type\":\"tx_deferred\"", "\"node\":\"always_fails\"") == 0
           && "device_hal pump_tx drops a failed arm without notifying the protocol");

    std::printf("test_tx_fail_prob: OK (prob 0 draw-free, prob 1 always fails, "
                "per-node streams independent, config reaches the radio, "
                "failed arm drops the frame and reports tx_fail)\n");
    return 0;
}
