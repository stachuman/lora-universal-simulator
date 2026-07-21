// test/native/test_wave1_config.cpp
// Author: Stanislaw Kozicki <cgpsmapper@gmail.com>
//
// Wave 1 (2026-07-20 realism/duplication review) coverage:
//   1.1  bw double-parse + kHz->Hz convention (JsonConfig): "62.5" -> 62500 Hz.
//   1.3  required-key refusal (JsonConfig::validateConfig): radio.{sf,bw,cr,duty_cycle}
//        and per-link {snr,snr_std_dev} — each absence is a named validation error.
//   1.4  SF5/SF6 sim airtime (SimRadio): the SX126x §6.1.4 branch, matching the firmware
//        airtime.cpp pins (airtime_ms(6,125000,5,16,50) == 61); SF7+ unchanged.
//   1.5  per-frame TX-power link-budget delta (LinkBudget.h): -127 sentinel = 0 delta.

#include "core/topology/JsonConfig.h"
#include "core/radio/SimRadio.h"
#include "core/clock/VirtualClock.h"
#include "orchestrator/runtime/LinkBudget.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>

// A fully-valid config template. Each required-key test removes ONE key and asserts the
// load throws. {SF} / {BW} / {CR} / {DUTY} / {SNR} / {STD} are substituted per case.
static std::string makeConfig(const std::string& sf, const std::string& bw, const std::string& cr,
                              const std::string& duty, const std::string& snr, const std::string& std) {
    std::string radio = "\"radio\": {";
    bool first = true;
    auto add = [&](const char* k, const std::string& v) {
        if (v.empty()) return;
        if (!first) radio += ", ";
        radio += std::string("\"") + k + "\": " + v; first = false;
    };
    add("sf", sf); add("bw", bw); add("cr", cr); add("duty_cycle", duty);
    radio += "}";

    std::string link = "{ \"from\": \"a\", \"to\": \"b\"";
    if (!snr.empty()) link += ", \"snr\": " + snr;
    if (!std.empty()) link += ", \"snr_std_dev\": " + std;
    link += " }";

    return std::string("{\"_name\":\"t\",\"simulation\":{\"duration_ms\":1000,\"step_ms\":1,")
         + radio + "},"
         + "\"nodes\":[{\"name\":\"a\",\"script\":\"x.lua\"},{\"name\":\"b\",\"script\":\"x.lua\"}],"
         + "\"topology\":{\"links\":[" + link + "]}}";
}

static bool loadThrows(const std::string& js) {
    try { JsonConfig::loadFromString(js); return false; }
    catch (const std::runtime_error&) { return true; }
}

int main() {
    // ---- 1.1 bw double-parse: kHz-double -> Hz --------------------------------------
    {
        SimConfig cfg = JsonConfig::loadFromString(makeConfig("8", "62.5", "5", "0.01", "8.0", "0"));
        assert(cfg.simulation.radio.bw == 62500);   // NOT 62 (the old get<int>() truncation) -> NOT 62000 Hz
        SimConfig cfg2 = JsonConfig::loadFromString(makeConfig("8", "125", "5", "0.01", "8.0", "0"));
        assert(cfg2.simulation.radio.bw == 125000);
        SimConfig cfg3 = JsonConfig::loadFromString(makeConfig("8", "250", "5", "0.01", "8.0", "0"));
        assert(cfg3.simulation.radio.bw == 250000);
        // per-node bw override also converts (flat form)
        const std::string pernode =
            "{\"_name\":\"t\",\"simulation\":{\"duration_ms\":1000,\"step_ms\":1,"
            "\"radio\":{\"sf\":8,\"bw\":125,\"cr\":5,\"duty_cycle\":0.01}},"
            "\"nodes\":[{\"name\":\"a\",\"script\":\"x.lua\",\"bw\":62.5}],"
            "\"topology\":{\"links\":[]}}";
        SimConfig cfg4 = JsonConfig::loadFromString(pernode);
        assert(cfg4.nodes[0].bw == 62500);
        std::printf("  [1.1] bw double-parse (62.5 -> 62500 Hz): OK\n");
    }

    // ---- 1.3 required-key refusal (one per key) -------------------------------------
    {
        // The full template loads cleanly...
        (void)JsonConfig::loadFromString(makeConfig("8", "62.5", "5", "0.01", "8.0", "0"));
        // ...and removing ANY one required key refuses the run.
        assert(loadThrows(makeConfig("",  "62.5", "5", "0.01", "8.0", "0")));  // radio.sf
        assert(loadThrows(makeConfig("8", "",     "5", "0.01", "8.0", "0")));  // radio.bw
        assert(loadThrows(makeConfig("8", "62.5", "",  "0.01", "8.0", "0")));  // radio.cr
        assert(loadThrows(makeConfig("8", "62.5", "5", "",     "8.0", "0")));  // radio.duty_cycle
        assert(loadThrows(makeConfig("8", "62.5", "5", "0.01", "",    "0")));  // link.snr
        assert(loadThrows(makeConfig("8", "62.5", "5", "0.01", "8.0", "")));   // link.snr_std_dev
        std::printf("  [1.3] required-key refusal (sf/bw/cr/duty_cycle/snr/snr_std_dev): OK\n");
    }

    // ---- 1.4 SF5/SF6 airtime (SX126x §6.1.4) matches the firmware airtime.cpp -------
    {
        VirtualClock clock;
        SimRadio r(clock);
        r.setPreambleSymbols(16);
        // firmware test pin: airtime_ms(6, 125000, 5, 16, 50) == 61
        r.setRadioParams(6, 125000, 5);
        assert(r.getEstAirtimeFor(50) == 61);
        // SF5 exercises the same low-SF branch (6.25 sync / +36 numerator).
        r.setRadioParams(5, 125000, 5);
        assert(r.getEstAirtimeFor(50) == 34);
        // SF7 uses the unchanged AN1200.13 4.25/+44 branch -> value must not move.
        r.setRadioParams(7, 125000, 5);
        assert(r.getEstAirtimeFor(50) == 105);
        std::printf("  [1.4] SF5/SF6 airtime (SF6/BW125/len50=61ms) + SF7 unchanged: OK\n");
    }

    // ---- 1.5 per-frame TX-power link-budget delta -----------------------------------
    {
        assert(txPowerDeltaDb(-127, 20.0) == 0.0f);   // sentinel -> no delta (the corpus today)
        assert(txPowerDeltaDb(22,   20.0) == 2.0f);   // +2 dB above the model reference
        assert(txPowerDeltaDb(10,   20.0) == -10.0f); // -10 dB below
        assert(txPowerDeltaDb(20,   20.0) == 0.0f);   // exactly the reference
        std::printf("  [1.5] tx-power delta (-127 sentinel = 0; explicit shifts): OK\n");
    }

    std::printf("test_wave1_config: OK\n");
    return 0;
}
