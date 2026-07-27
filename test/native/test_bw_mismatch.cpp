// test/native/test_bw_mismatch.cpp
//
// BW-mismatch delivery gating (§6.1.1 of the 2026-07-20 realism review).
//
// A real LoRa modem demodulates only the BANDWIDTH its registers are set to,
// so a node listening on 125 kHz cannot decode a 250 kHz frame at any SNR (nor
// the reverse). The sim used to gate reception on SF alone, which made a
// dual-BW gateway's layers RF-CONNECTED in sim while they are RF-ISOLATED on
// metal. This test pins the gate that fixes it, driving the real
// SimController delivery pipeline over test_bw_mismatch.json:
//
//   1. matched BW      (125 -> 125)          => rx, no drop
//   2. mismatched BW   (125 -> 250)          => drop_bw_mismatch, no rx
//   3. RETUNE 250->125 changes the verdict    => drop becomes rx
//      RETUNE 125->250 changes the verdict    => rx becomes drop
//      (both via the live per-node RX-BW slot — the same slot the firmware
//       seam Hal::set_rx_bw -> ISimHal::simSetRxBw writes on a dual-BW
//       gateway's per-layer window switch; the Lua self:set_rx_bw is the
//       engine-agnostic twin, exercised here because build_test.sh cannot
//       link FirmwareNode without the whole MeshRoute firmware.)
//   4. the would_decode guard is preserved: a receiver whose link is below
//      the demod floor stays SILENT on a BW mismatch (it is off-net, exactly
//      as the SF gate treats it) rather than spamming a drop per frame.
//   5. the emitted event carries both bandwidths + the matched SF.
//   6. §w4-#7 (2026-07-26) — THE PREAMBLE HALF. The decode gate above was only
//      half the predicate: the PreambleDetected observer loop matched SF alone,
//      so a 125 kHz node still "detected" a 250 kHz preamble it could never
//      demodulate, and that signal feeds beacon throttling. The gate now carries
//      the same bw predicate beside its SF one, and cases 1-3 below each gained a
//      preamble assertion (matched => 1, mismatched => 0, and the retune flips it
//      both ways, since both gates read the same live _node_rx_bw_hz slot).
//      ★ THIS TEST IS THE ONLY THING THAT COVERS IT. Measured, not assumed: all
//      29 corpus scenarios are single-BW (one global `bw`, zero per-node and zero
//      per-layer overrides), so the gate is a tautology there — adding it moved
//      0 of 29 streams. A poison probe that INVERTED the predicate moved 15 of 29,
//      which is what proves the site is reached rather than dead.
//      ⚠ Deliberately NOT asserted here, because it must stay TRUE: a BW mismatch
//      still charges the observer's RX->TX turnaround, still marks the channel busy
//      for LBT and still feeds the collision verdict. Bandwidth grants no
//      orthogonality; only a separate carrier does (test_freq_mismatch).
//
// ★ 2026-07-25: the Lua engine is DEPRECATED + UNSUPPORTED, so the fixture now
// tags every node "engine":"lua" EXPLICITLY (the default is "meshroute") and sets
// simulation.allow_deprecated_lua so SimController::initialize() sanctions the run
// instead of refusing it. That opt-in exists precisely for this case — the
// coverage below is BW-gate coverage, not Lua coverage, and build_test.sh cannot
// link FirmwareNode. The run prints the one-time deprecation warning to stderr.

#include "core/topology/JsonConfig.h"
#include "orchestrator/runtime/SimController.h"

#include <cassert>
#include <cstdio>
#include <sstream>
#include <string>
#include <vector>

namespace {

std::vector<std::string> linesFor(const std::string& ndjson,
                                  const std::string& type_frag,
                                  const std::string& to_frag) {
    std::vector<std::string> hits;
    std::istringstream in(ndjson);
    std::string line;
    while (std::getline(in, line)) {
        if (line.find(type_frag) == std::string::npos) continue;
        if (!to_frag.empty() && line.find(to_frag) == std::string::npos) continue;
        hits.push_back(line);
    }
    return hits;
}

size_t countFor(const std::string& ndjson, const std::string& type_frag,
                const std::string& to_frag) {
    return linesFor(ndjson, type_frag, to_frag).size();
}

// §w4-#7: script_emit identifies the node by its NUMERIC runtime index, not its name
// ({"type":"script_emit","node":4,...}), unlike the physics events' "to":"<name>". Resolve
// the index from the config by name so a fixture reorder cannot silently re-point an
// assertion. The trailing comma matters: without it "node":1 also substring-matches
// "node":17. Same helper, same reasoning, as test_freq_mismatch.cpp (U1).
std::string emitNode(const SimConfig& cfg, const std::string& name) {
    for (size_t i = 0; i < cfg.nodes.size(); ++i)
        if (cfg.nodes[i].name == name) return "\"node\":" + std::to_string(i) + ",";
    assert(false && "fixture has no node with that name");
    return {};
}

}  // namespace

int main(int argc, char** argv) {
    assert(argc >= 2 && "usage: test_bw_mismatch <config.json>");
    SimConfig cfg = JsonConfig::loadFromFile(argv[1]);

    std::ostringstream out;
    SimController ctrl(cfg, out);
    ctrl.initialize();
    ctrl.runUntil(cfg.simulation.duration_ms + 1000);
    ctrl.finalize();
    const std::string log = out.str();

    // The one and only TX must have gone out at the sender's configured BW.
    const auto txs = linesFor(log, "\"type\":\"tx\"", "\"node\":\"tx125\"");
    assert(txs.size() == 1);
    assert(txs[0].find("\"bw_hz\":125000") != std::string::npos);
    assert(txs[0].find("\"sf\":7") != std::string::npos);

    const std::string kRx   = "\"type\":\"rx\"";
    const std::string kBwMm = "\"type\":\"drop_bw_mismatch\"";
    const std::string kWeak = "\"type\":\"drop_weak\"";

    // §w4-#7: "did node <name> raise a PreambleDetected IRQ?" — the direct probe of the
    // observer-loop predicate, which the decode-path drop events cannot see. Same shape as
    // test_freq_mismatch's `preambles` helper (U1: one idiom for the same question).
    const std::string kPre = "\"emit_type\":\"preamble\"";
    const auto preambles = [&](const char* nm) {
        return countFor(log, kPre, emitNode(cfg, nm));
    };

    // ---- 1. matched BW decodes -------------------------------------------
    assert(countFor(log, kRx,   "\"to\":\"rx125\"") == 1);
    assert(countFor(log, kBwMm, "\"to\":\"rx125\"") == 0);
    // ...and its preamble IS detected. This is the non-vacuity control for every
    // `== 0` preamble assertion below: it proves the emit path works at all, so a
    // zero elsewhere is the gate and not a broken fixture.
    assert(preambles("rx125") == 1);

    // ---- 2. mismatched BW is dropped, never delivered --------------------
    const auto mm = linesFor(log, kBwMm, "\"to\":\"rx250\"");
    assert(mm.size() == 1);
    assert(countFor(log, kRx, "\"to\":\"rx250\"") == 0);
    // ★ §w4-#7: and it never even detects the preamble. Before the gate this was 1 —
    // the modem "saw" a chirp rate it cannot correlate, and fed it to beacon throttling.
    assert(preambles("rx250") == 0);
    // ---- 5. the event carries both bandwidths + the (matched) SF ---------
    assert(mm[0].find("\"packet_bw_hz\":125000") != std::string::npos);
    assert(mm[0].find("\"rx_bw_hz\":250000")     != std::string::npos);
    assert(mm[0].find("\"sf\":7")                != std::string::npos);
    assert(mm[0].find("\"from\":\"tx125\"")      != std::string::npos);
    // Diagnostic link quality is present (the gate is would_decode-gated, so
    // these values are meaningful — same rationale as drop_sf_mismatch).
    assert(mm[0].find("\"snr_db\":")   != std::string::npos);
    assert(mm[0].find("\"rssi_dbm\":") != std::string::npos);

    // ---- 3. a RETUNE flips the verdict, both directions ------------------
    // 250 -> 125 at init: would have been dropped, now decodes.
    assert(countFor(log, kRx,   "\"to\":\"rx250to125\"") == 1);
    assert(countFor(log, kBwMm, "\"to\":\"rx250to125\"") == 0);
    assert(preambles("rx250to125") == 1);   // §w4-#7: the retune flips the DETECT verdict too
    // 125 -> 250 at init: would have decoded, now dropped. This is the
    // dual-BW-gateway window switch in miniature: same node, same link, the
    // verdict is decided purely by the live RX-BW slot.
    const auto flipped = linesFor(log, kBwMm, "\"to\":\"rx125to250\"");
    assert(flipped.size() == 1);
    assert(countFor(log, kRx, "\"to\":\"rx125to250\"") == 0);
    assert(flipped[0].find("\"rx_bw_hz\":250000") != std::string::npos);
    assert(preambles("rx125to250") == 0);   // §w4-#7: ...and in the other direction
    // ★ Both gates read ONE slot: the decode verdict and the detect verdict agree on
    // all four receivers above, which is the property that would break first if the
    // preamble gate were ever re-forked onto its own bandwidth source.

    // ---- 4. the would_decode guard is preserved --------------------------
    // Below the SF7 demod floor (-7.5 dB) at -20 dB: a BW-mismatched receiver
    // is off-net and must stay SILENT — no drop_bw_mismatch, no rx.
    assert(countFor(log, kBwMm, "\"to\":\"far250\"") == 0);
    assert(countFor(log, kRx,   "\"to\":\"far250\"") == 0);
    // Control: the matched-BW far receiver still reports the honest reason it
    // missed the frame, proving the silence above is the BW gate's
    // would_decode carve-out and not a broken link in the fixture.
    assert(countFor(log, kWeak, "\"to\":\"far125\"") == 1);
    assert(countFor(log, kRx,   "\"to\":\"far125\"") == 0);
    // §w4-#7: the far pair is below the energy-detect threshold, so neither raises a
    // preamble regardless of BW — the detect gate above the SF/BW pair already stopped them.
    assert(preambles("far250") == 0);
    assert(preambles("far125") == 0);

    // Only the two intended mismatches fired anywhere in the run.
    assert(countFor(log, kBwMm, "") == 2);
    // §w4-#7: and exactly the two BW-matched, in-range receivers detected a preamble —
    // pinning the corpus-wide total, not just the per-node counts.
    assert(countFor(log, kPre, "") == 2);

    std::printf("test_bw_mismatch: OK "
                "(matched rx, mismatch dropped, retune flips both ways, "
                "would_decode guard silent, preamble gated on BW too)\n");
    return 0;
}
