// test/native/test_tx_settling.cpp
//
// TX->RX turnaround deafness (Wave-4 §6.1.2 of the 2026-07-20 realism review).
//
// A real SX126x cannot receive for tx_to_rx_delay_ms after its own TX ends
// (LNA re-enable + PLL relock; 8 ms bench-measured). The sim used to be
// instantly receptive after a transmission, so it heard frames a real radio
// would have missed: _earliest_rx_ms was set ONLY inside SimRadio::startSendRaw
// — which the live TX path bypasses (§startSendRaw-bypass) — and read ONLY by
// the equally-bypassed isSendComplete(). Nothing on the delivery path consulted
// it. The gate now extends the receiver's own-TX interval to
// [own.start_ms, own.end_ms + tx_to_rx_delay_ms) and emits drop_tx_settling for
// a frame whose preamble lands in that tail.
//
// Why a test and not just suite byte-identity: the corpus cannot pin the
// BOUNDARY. Streams moving proves something changed, not that the window is
// tx_to_rx_delay_ms wide or that it is read from config at all. This drives
// THREE values of the knob over one fixture and shows the verdict flipping:
//
//   delay = 0    -> both senders RECEIVED         (no window at all)
//   delay = 8    -> s_in DROPPED, s_out RECEIVED  (the window is ~8 ms wide)
//   delay = 100  -> both DROPPED                  (s_out's verdict FLIPS)
//
// and asserts deaf_until_ms == own_tx_end + delay in every dropping case, so
// the reported boundary tracks the configured turnaround rather than a literal.
//
// It also asserts ZERO drop_halfduplex throughout: the senders' frames never
// overlap deaf's airtime, so this is provably the settling mechanism and not
// the pre-existing concurrent-TX one.
//
// ★ TIMING: the two sender command times are computed HERE from
// SimRadio::getEstAirtimeFor — the same function the controller debits — so the
// fixture cannot silently drift if the airtime formula changes. The senders
// have NO link back from deaf (see the fixture's one-way topology), so they
// never arm their own RX->TX turnaround and their frames start at exactly the
// commanded millisecond.

#include "core/clock/VirtualClock.h"
#include "core/radio/SimRadio.h"
#include "core/topology/JsonConfig.h"
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
                                  const std::string& from_frag) {
    std::vector<std::string> hits;
    std::istringstream in(ndjson);
    std::string line;
    while (std::getline(in, line)) {
        if (line.find(type_frag) == std::string::npos) continue;
        if (!from_frag.empty() && line.find(from_frag) == std::string::npos) continue;
        hits.push_back(line);
    }
    return hits;
}

size_t countFor(const std::string& ndjson, const std::string& type_frag,
                const std::string& from_frag) {
    return linesFor(ndjson, type_frag, from_frag).size();
}

// Run the fixture at one turnaround value. Returns the whole NDJSON stream.
std::string runAt(const SimConfig& base, float tx_to_rx_delay_ms) {
    SimConfig cfg = base;                                   // fresh copy per run
    cfg.simulation.radio.tx_to_rx_delay_ms = tx_to_rx_delay_ms;
    std::ostringstream out;
    SimController ctrl(cfg, out);
    ctrl.initialize();
    ctrl.runUntil(cfg.simulation.duration_ms + 1000);
    ctrl.finalize();
    return out.str();
}

}  // namespace

int main(int argc, char** argv) {
    assert(argc >= 2 && "usage: test_tx_settling <config.json>");
    SimConfig base = JsonConfig::loadFromFile(argv[1]);

    // ---- Schedule one sender after each of deaf's two TXs ------------------
    // ★ Two deaf TXs, a second apart, one sender each. A single deaf TX cannot
    // host both senders: the frames are ~39 ms long, so an inside-the-window
    // frame and an outside-the-window frame would COLLIDE WITH EACH OTHER and
    // the run would measure the collision model instead of the deaf window
    // (observed, and the reason this fixture is shaped this way).
    assert(base.commands.size() == 2);
    assert(base.commands[0].node == "deaf" && base.commands[1].node == "deaf");

    // deaf's frame is `self:tx("PING")` = 4 bytes at the fixture's PHY. Asking
    // SimRadio — the same airtime function the controller debits — keeps the
    // offsets below correct if that formula ever changes.
    VirtualClock probe_clock;
    SimRadio probe(probe_clock, base.simulation.radio.sf,
                   base.simulation.radio.bw, base.simulation.radio.cr);
    const uint32_t deaf_air = probe.getEstAirtimeFor(4);
    assert(deaf_air > 0);
    // No deferral (deaf hears nothing before it sends — see the fixture's
    // one-way topology), so its frames run [at_ms, at_ms + airtime].
    const unsigned long deaf_end_1 = base.commands[0].at_ms + deaf_air;
    const unsigned long deaf_end_2 = base.commands[1].at_ms + deaf_air;
    assert(deaf_end_1 + deaf_air < base.commands[1].at_ms
           && "the two deaf TXs must be far enough apart not to interact");

    // s_in's preamble lands 2 ms after deaf's FIRST TX ends -> inside 8 ms.
    // s_out's lands 20 ms after deaf's SECOND -> outside 8 ms, inside 100 ms.
    const unsigned long kInsideOffset  = 2;
    const unsigned long kOutsideOffset = 20;
    SimConfig::CmdDef c_in;
    c_in.at_ms = deaf_end_1 + kInsideOffset;
    c_in.node = "s_in";
    c_in.command = "ping";
    SimConfig::CmdDef c_out;
    c_out.at_ms = deaf_end_2 + kOutsideOffset;
    c_out.node = "s_out";
    c_out.command = "ping";
    base.commands.push_back(c_in);
    base.commands.push_back(c_out);

    const std::string want_in  = "\"from\":\"s_in\"";
    const std::string want_out = "\"from\":\"s_out\"";

    // ---- 0 ms: no window at all -> both frames are heard -------------------
    {
        const std::string log = runAt(base, 0.0f);
        // Sanity: the fixture really drove what the assertions below assume.
        assert(countFor(log, "\"type\":\"tx\"", "\"node\":\"deaf\"")  == 2);
        assert(countFor(log, "\"type\":\"tx\"", "\"node\":\"s_in\"")  == 1);
        assert(countFor(log, "\"type\":\"tx\"", "\"node\":\"s_out\"") == 1);
        assert(countFor(log, "\"type\":\"rx\"", want_in)  == 1
               && "with no turnaround the near frame must be heard");
        assert(countFor(log, "\"type\":\"rx\"", want_out) == 1);
        assert(countFor(log, "\"type\":\"drop_tx_settling\"", "") == 0);
        assert(countFor(log, "\"type\":\"drop_halfduplex\"", "") == 0);
        // Neither sender's frame may be lost to anything else, or the two
        // "verdict flipped" results below would not be attributable.
        assert(countFor(log, "\"type\":\"collision\"", "") == 0);
    }

    // ---- 8 ms (the bench-measured default): s_in dies, s_out lives ---------
    {
        const std::string log = runAt(base, 8.0f);
        assert(countFor(log, "\"type\":\"rx\"", want_in) == 0
               && "a frame arriving inside the deaf window must NOT be received");
        assert(countFor(log, "\"type\":\"rx\"", want_out) == 1
               && "a frame arriving after the deaf window MUST be received");

        const auto drops = linesFor(log, "\"type\":\"drop_tx_settling\"", "");
        assert(drops.size() == 1 && "exactly the one in-window frame drops");
        assert(drops[0].find(want_in) != std::string::npos);
        assert(drops[0].find("\"to\":\"deaf\"") != std::string::npos);
        // The reported deaf-until is the receiver's own TX end + the configured
        // turnaround — not a literal, not the frame's own timing.
        const std::string want_deaf =
            "\"deaf_until_ms\":" + std::to_string(deaf_end_1 + 8);
        assert(drops[0].find(want_deaf) != std::string::npos
               && "deaf_until_ms must be own_tx_end + tx_to_rx_delay_ms");

        // Provably the SETTLING mechanism, not the concurrent-TX one.
        assert(countFor(log, "\"type\":\"drop_halfduplex\"", "") == 0);
    }

    // ---- 100 ms: the boundary follows the knob, s_out's verdict FLIPS ------
    {
        const std::string log = runAt(base, 100.0f);
        assert(countFor(log, "\"type\":\"rx\"", want_in)  == 0);
        assert(countFor(log, "\"type\":\"rx\"", want_out) == 0
               && "widening the turnaround must flip the far frame to dropped");

        const auto drops = linesFor(log, "\"type\":\"drop_tx_settling\"", "");
        assert(drops.size() == 2 && "both frames now land inside the window");
        // Each drop reports the deaf-until of the receiver's OWN preceding TX,
        // so the two values differ — the boundary is computed, not constant.
        assert(linesFor(log, "\"deaf_until_ms\":" + std::to_string(deaf_end_1 + 100),
                        want_in).size() == 1);
        assert(linesFor(log, "\"deaf_until_ms\":" + std::to_string(deaf_end_2 + 100),
                        want_out).size() == 1);
        assert(countFor(log, "\"type\":\"drop_halfduplex\"", "") == 0);
    }

    std::printf("test_tx_settling: OK (deaf window honoured, boundary tracks "
                "tx_to_rx_delay_ms, verdict flips at 0/8/100 ms, "
                "no half-duplex confusion)\n");
    return 0;
}
