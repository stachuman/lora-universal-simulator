// test/native/test_freq_mismatch.cpp
// Author: Stanislaw Kozicki <cgpsmapper@gmail.com>
//
// FREQUENCY-SELECTIVE PHY — the carrier reachability gate (§carrier, owner ruling 2026-07-26:
// "we aim to have a realistic simulator able to test our multi layer / multi freq simulations").
//
// ★★ WHY THIS TEST IS THE ONLY THING THAT PROVES THE FEATURE WORKS.
// The shipped corpus is CARRIER-DARK BY CONSTRUCTION: not one of the 27 scenarios sets a second
// carrier (s29's own _desc even states its layers "SHARE the PHY (freq/bw/sf) but differ in leaf
// NIBBLE"), so with correct inherit semantics every node lands on the single global carrier and every
// comparison in the gate is a tautology. Corpus byte-identity therefore proves ONLY "no regression"
// and NOTHING WHATSOEVER about whether the gate isolates. Everything below is that missing proof.
//
// PART 1 — schema + inherit (JsonConfig, no controller):
//   1a. simulation.radio.freq_khz DEFAULTS to 868000 when absent (so the whole shipped corpus lands
//       on one carrier — the byte-identity tripwire's actual mechanism).
//   1b. a node with no freq_khz INHERITS the global; an explicit per-node value overrides it.
//   1c. FAIL LOUD: a fractional "freq_khz" is REFUSED, not rounded (the sim owns no MHz->kHz
//       conversion — that one path is the firmware's protocol::mhz_to_khz), and so are 0 / negative.
//
// PART 2 — the gate itself, driving the real SimController delivery pipeline over
//          test_freq_mismatch.json. Three isolated groups, one per consumer of the shared predicate:
//   2a. same carrier (INHERITED, no key at all)      => rx + preamble, no drop
//   2b. different carrier (869.5 MHz)                => drop_freq_mismatch, no rx, ★ no preamble
//   2c. ADJACENT carrier (868.1 MHz, 100 kHz away)   => ALSO fully dropped — the HARD SPLIT. No
//       partial adjacent-channel overlap is modelled; we have no bench data on adjacent-channel
//       rejection and inventing the parameters was explicitly forbidden.
//   2d. a RETUNE flips the verdict BOTH ways (the dual-carrier gateway window switch in miniature),
//       through the same live slot the firmware seam Hal::set_rx_freq -> ISimHal::simSetRxFreqKhz
//       writes. Driven through the Lua twin self:set_rx_freq_khz because build_test.sh cannot link
//       FirmwareNode — the same sanctioned arrangement test_bw_mismatch uses.
//   2e. the off-net carve-out: a receiver below the demod floor stays SILENT on a carrier mismatch
//       (no drop spam), with a matched-carrier control at the same SNR proving the link is real.
//   2f. LBT ORTHOGONALITY: a same-carrier neighbour IS deferred (tx_deferred) by an in-flight frame;
//       a cross-carrier neighbour is NOT. Without the gate in the energy-busy provider, two layers on
//       two carriers would still block each other — the exact thing channelization prevents.
//   2g. COLLISION ORTHOGONALITY (hidden terminal, no link between the two senders so neither is
//       LBT-deferred): same-carrier overlapping frames destroy each other; cross-carrier ones do not.
//       ⚠ This is the DELIBERATE ASYMMETRY vs the BW gate, which keeps feeding collisions on purpose
//       ("bandwidth grants NO orthogonality"). A separate CHANNEL genuinely does.
//   2h. the emitted event carries both carriers + the matched sf/bw.
//
// PART 3 — the CR-retune half of the same slice (§cr-retune), unit level only.
//   ⚠ HONEST GAP, STATED: the CR chain (Hal::set_rx_cr -> HalAdapter -> ISimHal::simSetRxCr ->
//   FirmwareNode) is NOT reachable from here. CR is not a decode gate (LoRa's explicit header carries
//   the coding rate, so any receiver demodulates any CR); its only observable is AIRTIME, and it has
//   no Lua twin because ScriptedNode needs none. build_test.sh cannot link FirmwareNode, so the
//   plumbing itself is covered by NOTHING automated — see the note at the bottom for what is owed.
//   What IS pinned here is the one genuinely risky part of the implementation: that a CR-only retune
//   PRESERVES sf/bw (SimRadio has only the all-three setRadioParams) and does move the airtime.

#include "core/radio/SimRadio.h"
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

// A minimal but VALID config skeleton for the schema half. `radio_extra` and `node_extra` are spliced
// in so each case differs by exactly the key under test.
std::string skeleton(const std::string& radio_extra, const std::string& node_extra) {
    return std::string(
        "{\"simulation\":{\"duration_ms\":1000,\"step_ms\":1,"
        "\"radio\":{\"sf\":7,\"bw\":125,\"cr\":5,\"duty_cycle\":100") + radio_extra + "}},"
        "\"nodes\":[{\"name\":\"a\",\"engine\":\"lua\",\"script\":\"x.lua\"" + node_extra + "},"
        "{\"name\":\"b\",\"engine\":\"lua\",\"script\":\"x.lua\"}],"
        "\"topology\":{\"links\":[{\"from\":\"a\",\"to\":\"b\",\"snr\":8.0,\"snr_std_dev\":0}]}}";
}

// script_emit identifies the node by its NUMERIC runtime index, not its name
// ({"type":"script_emit","node":4,"time_ms":...}), so resolve the index from the config by name —
// robust to a fixture reorder, unlike a hardcoded number. The trailing comma matters: without it
// "node":1 would also substring-match "node":17.
std::string emitNode(const SimConfig& cfg, const std::string& name) {
    for (size_t i = 0; i < cfg.nodes.size(); ++i)
        if (cfg.nodes[i].name == name) return "\"node\":" + std::to_string(i) + ",";
    assert(false && "fixture has no node with that name");
    return {};
}

bool refuses(const std::string& radio_extra, const std::string& node_extra) {
    try {
        (void)JsonConfig::loadFromString(skeleton(radio_extra, node_extra));
    } catch (const std::exception&) {
        return true;
    }
    return false;
}

}  // namespace

int main(int argc, char** argv) {
    assert(argc >= 2 && "usage: test_freq_mismatch <config.json>");

    // =========================================================================
    // PART 1 — schema, default, inherit, fail-loud
    // =========================================================================
    {
        // 1a + 1b: no global key anywhere -> 868000 default -> both nodes inherit it. This IS the
        // mechanism that keeps all 27 shipped scenarios byte-identical: none of them names a carrier.
        const SimConfig d = JsonConfig::loadFromString(skeleton("", ""));
        assert(d.simulation.radio.freq_khz == 868000);
        assert(d.nodes[0].freq_khz == 868000);
        assert(d.nodes[1].freq_khz == 868000);

        // An explicit global is inherited by a key-less node...
        const SimConfig g = JsonConfig::loadFromString(skeleton(",\"freq_khz\":915000", ""));
        assert(g.simulation.radio.freq_khz == 915000);
        assert(g.nodes[0].freq_khz == 915000);
        assert(g.nodes[1].freq_khz == 915000);

        // ...and a per-node value overrides it for that node ONLY (the other still inherits).
        const SimConfig p = JsonConfig::loadFromString(
            skeleton(",\"freq_khz\":915000", ",\"freq_khz\":869525"));
        assert(p.nodes[0].freq_khz == 869525);
        assert(p.nodes[1].freq_khz == 915000);

        // The nested per-node form works too (same shape as radio.sf/bw/cr).
        const SimConfig nested = JsonConfig::loadFromString(
            skeleton("", ",\"radio\":{\"freq_khz\":867100}"));
        assert(nested.nodes[0].freq_khz == 867100);
        assert(nested.nodes[1].freq_khz == 868000);

        // 1c: FAIL LOUD. A fractional value is REFUSED, never silently rounded — rounding here would
        // fork a second MHz->kHz path against the firmware's protocol::mhz_to_khz.
        assert(refuses(",\"freq_khz\":868.1", ""));
        assert(refuses("", ",\"freq_khz\":869.525"));
        // Non-positive is refused on both levels; a string is refused too.
        assert(refuses(",\"freq_khz\":0", ""));
        assert(refuses(",\"freq_khz\":-868000", ""));
        assert(refuses("", ",\"freq_khz\":0"));
        assert(refuses("", ",\"freq_khz\":\"868000\""));
        // Control: the honest integer forms are ACCEPTED (so the refusals above aren't vacuous).
        assert(!refuses(",\"freq_khz\":868000", ",\"freq_khz\":869500"));
    }

    // =========================================================================
    // PART 2 — the gate, over the real delivery pipeline
    // =========================================================================
    SimConfig cfg = JsonConfig::loadFromFile(argv[1]);
    // The fixture deliberately omits simulation.radio.freq_khz, so this run ALSO exercises the
    // default + inherit path end-to-end (rx868 carries no freq_khz key at all).
    assert(cfg.simulation.radio.freq_khz == 868000);

    std::ostringstream out;
    SimController ctrl(cfg, out);
    ctrl.initialize();
    ctrl.runUntil(cfg.simulation.duration_ms + 1000);
    ctrl.finalize();
    const std::string log = out.str();

    const std::string kRx    = "\"type\":\"rx\"";
    const std::string kFqMm  = "\"type\":\"drop_freq_mismatch\"";
    const std::string kWeak  = "\"type\":\"drop_weak\"";
    const std::string kPre   = "\"emit_type\":\"preamble\"";
    const std::string kDefer = "\"type\":\"tx_deferred\"";
    const std::string kColl  = "\"type\":\"collision\"";
    // "did node <name> see a preamble?" — the direct probe of the SECOND reachability predicate.
    const auto preambles = [&](const char* nm) {
        return countFor(log, kPre, emitNode(cfg, nm));
    };

    // The group-A sender transmitted exactly once, on its configured PHY.
    const auto txs = linesFor(log, "\"type\":\"tx\"", "\"node\":\"tx868\"");
    assert(txs.size() == 1);
    assert(txs[0].find("\"sf\":7") != std::string::npos);
    assert(txs[0].find("\"bw_hz\":125000") != std::string::npos);

    // ---- 2a. same (INHERITED) carrier decodes, and its preamble is detected ----
    assert(countFor(log, kRx,   "\"to\":\"rx868\"") == 1);
    assert(countFor(log, kFqMm, "\"to\":\"rx868\"") == 0);
    assert(preambles("rx868") == 1);

    // ---- 2b. a different carrier is dropped, never delivered, and NEVER detected ----
    const auto mm = linesFor(log, kFqMm, "\"to\":\"rx869\"");
    assert(mm.size() == 1);
    assert(countFor(log, kRx, "\"to\":\"rx869\"") == 0);
    // ★ THE SECOND PREDICATE. A node that cannot decode a frame must not detect its preamble either;
    // the alternative is physically impossible and would corrupt LBT + beacon throttling. This is the
    // assertion that catches a carrier gate wired into the delivery fan-out ONLY.
    assert(preambles("rx869") == 0);

    // ---- 2h. the event carries both carriers + the matched sf/bw ----
    assert(mm[0].find("\"packet_freq_khz\":868000") != std::string::npos);
    assert(mm[0].find("\"rx_freq_khz\":869500")     != std::string::npos);
    assert(mm[0].find("\"sf\":7")                   != std::string::npos);
    assert(mm[0].find("\"bw_hz\":125000")           != std::string::npos);
    assert(mm[0].find("\"from\":\"tx868\"")         != std::string::npos);
    assert(mm[0].find("\"snr_db\":")                != std::string::npos);
    assert(mm[0].find("\"rssi_dbm\":")              != std::string::npos);
    // ★ NEVER drop_no_link: "wrong channel" and "no RF link" are different physical facts, and
    // mislabelling one as the other is the defect class this project keeps paying for.
    assert(countFor(log, "\"type\":\"drop_no_link\"", "") == 0);

    // ---- 2c. HARD SPLIT: an ADJACENT 100 kHz-away carrier is dropped just as completely ----
    const auto adj = linesFor(log, kFqMm, "\"to\":\"rx868p1\"");
    assert(adj.size() == 1);
    assert(adj[0].find("\"rx_freq_khz\":868100") != std::string::npos);
    assert(countFor(log, kRx,  "\"to\":\"rx868p1\"") == 0);
    assert(preambles("rx868p1") == 0);

    // ---- 2d. a RETUNE flips the verdict, both directions ----
    // 869500 -> 868000 at init: would have been dropped, now decodes.
    assert(countFor(log, kRx,   "\"to\":\"rx869to868\"") == 1);
    assert(countFor(log, kFqMm, "\"to\":\"rx869to868\"") == 0);
    assert(preambles("rx869to868") == 1);
    // 868000 -> 869500 at init: would have decoded, now dropped. Same node, same link — the verdict
    // is decided purely by the live carrier slot, exactly as a gateway's window switch decides it.
    const auto flipped = linesFor(log, kFqMm, "\"to\":\"rx868to869\"");
    assert(flipped.size() == 1);
    assert(flipped[0].find("\"rx_freq_khz\":869500") != std::string::npos);
    assert(countFor(log, kRx,  "\"to\":\"rx868to869\"") == 0);
    assert(preambles("rx868to869") == 0);

    // ---- 2e. the off-net carve-out is preserved ----
    // Below the SF7 demod floor (-7.5 dB) at -20 dB: a carrier-mismatched receiver is off-net and
    // stays SILENT — no drop_freq_mismatch, no rx — instead of one drop per frame forever.
    assert(countFor(log, kFqMm, "\"to\":\"far869\"") == 0);
    assert(countFor(log, kRx,   "\"to\":\"far869\"") == 0);
    // Control: the matched-carrier far receiver still reports the honest reason it missed the frame,
    // proving the silence above is the carve-out and not a broken link in the fixture.
    assert(countFor(log, kWeak, "\"to\":\"far868\"") == 1);
    assert(countFor(log, kRx,   "\"to\":\"far868\"") == 0);

    // ---- 2f. LBT orthogonality ----
    // Same carrier: busyB's TX, submitted in the same step as busyA's, finds the channel busy.
    assert(countFor(log, kDefer, "\"node\":\"busyB\"") == 1);
    // Cross carrier: freeB is on 869.5 while freeA is on the air at 868 -> NOT busy, TX goes out.
    // (Identical topology, identical timing, identical SNR — the carrier is the only difference.)
    assert(countFor(log, kDefer, "\"node\":\"freeB\"") == 0);
    assert(countFor(log, "\"type\":\"tx\"", "\"node\":\"freeB\"") == 1);
    // And the control's own TX still happened, so the deferral above isn't a dead node.
    assert(countFor(log, "\"type\":\"tx\"", "\"node\":\"busyA\"") == 1);
    // The isolation is SYMMETRIC: with both on the air simultaneously, each refuses the other's frame
    // and neither ever detects the other's preamble. (busyB, on the same carrier, DID see busyA's.)
    assert(countFor(log, kFqMm, "\"to\":\"freeB\"") == 1);
    assert(countFor(log, kFqMm, "\"to\":\"freeA\"") == 1);
    assert(preambles("freeA") == 0);
    assert(preambles("freeB") == 0);
    assert(preambles("busyB") == 1);

    // ---- 2g. collision orthogonality (hidden terminal) ----
    // Same carrier, equal SNR, overlapping in time, no link between the senders -> mutual destruction.
    assert(countFor(log, kColl, "\"to\":\"hidRx\"") == 2);
    assert(countFor(log, kRx,   "\"to\":\"hidRx\"") == 0);
    // Cross carrier, everything else identical: xhidB's frame cannot destroy xhidA's, so the
    // matched-carrier frame arrives and NO collision is recorded at all.
    assert(countFor(log, kColl, "\"to\":\"xhidRx\"") == 0);
    assert(countFor(log, kRx,   "\"to\":\"xhidRx\"") == 1);
    // xhidB's foreign-carrier frame is itself refused at xhidRx (it is on 869.5, xhidRx on 868).
    assert(countFor(log, kFqMm, "\"to\":\"xhidRx\"") == 1);
    // hidRx's two preambles vs xhidRx's ONE: the same-carrier pair is both heard (then collides), the
    // cross-carrier interferer is never detected at all.
    assert(preambles("hidRx")  == 2);
    assert(preambles("xhidRx") == 1);

    // Exactly the intended mismatches fired anywhere in the run and nowhere else: rx869, rx868p1,
    // rx868to869, freeA<-freeB, freeB<-freeA, xhidRx<-xhidB.
    assert(countFor(log, kFqMm, "") == 6);

    // =========================================================================
    // PART 3 — §cr-retune: a CR-only retune preserves sf/bw and moves the airtime
    // =========================================================================
    {
        VirtualClock clock;
        SimRadio r(clock, /*sf=*/9, /*bw_hz=*/125000, /*cr=*/5,
                   /*rx_to_tx_delay_ms=*/0.0f, /*tx_to_rx_delay_ms=*/0.0f);
        const uint32_t airtime_cr5 = r.getEstAirtimeFor(64);
        // This is exactly what FirmwareNode::simSetRxCr does: read sf/bw back, re-stamp them unchanged,
        // change only cr. SimRadio has no narrower setter, and adding one would fork a second way to
        // mutate the same field — so the read-back IS the contract, and it is the part that can break.
        r.setRadioParams(r.getSF(), r.getBwHz(), 8);
        assert(r.getSF()    == 9);        // ★ preserved
        assert(r.getBwHz()  == 125000);   // ★ preserved
        assert(r.getCR()    == 8);
        const uint32_t airtime_cr8 = r.getEstAirtimeFor(64);
        // CR4/8 sends more redundancy bits than CR4/5 -> strictly longer on air. If this ever compares
        // equal, the retune is not reaching the airtime model and the gateway's per-layer CR is a no-op
        // again (the exact defect §cr-retune fixed).
        assert(airtime_cr8 > airtime_cr5);
    }

    std::printf("test_freq_mismatch: OK "
                "(default+inherit, fractional refused, hard split incl. adjacent, retune flips both "
                "ways, preamble/LBT/collision all gated, off-net silent, cr-retune preserves sf/bw)\n");
    return 0;
}
