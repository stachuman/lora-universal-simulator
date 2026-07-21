// test/native/test_wave2_config.cpp
// Author: Stanislaw Kozicki <cgpsmapper@gmail.com>
//
// Wave 2a (2026-07-21 realism ruling) coverage:
//   2.1  turnaround / rx_window_slop DEFAULTS flipped to the metal values:
//        radio.hardware.rx_to_tx_delay_ms / tx_to_rx_delay_ms default 27/27 ms,
//        simulation.rx_window_slop default "metal". Config-absent == config-present.
//   2.2  duty_cycle unit = PERCENT everywhere (1 = 1%): JsonConfig stores the authored
//        percent verbatim; range (0, 100]; consumers divide /100. Migration sanity:
//        the fraction-era 0.01/0.1 values become 1/10 with identical EFFECTIVE duty.

#include "core/topology/JsonConfig.h"

#include <cassert>
#include <cstdio>
#include <stdexcept>
#include <string>

// Valid config template; {DUTY} substituted per case (empty => key omitted).
static std::string makeConfig(const std::string& duty) {
    std::string radio = "\"radio\": {\"sf\":8,\"bw\":125,\"cr\":5";
    if (!duty.empty()) radio += ",\"duty_cycle\":" + duty;
    radio += "}";
    return std::string("{\"_name\":\"t\",\"simulation\":{\"duration_ms\":1000,\"step_ms\":1,")
         + radio + "},"
         + "\"nodes\":[{\"name\":\"a\",\"script\":\"x.lua\"},{\"name\":\"b\",\"script\":\"x.lua\"}],"
         + "\"topology\":{\"links\":[{\"from\":\"a\",\"to\":\"b\",\"snr\":8.0,\"snr_std_dev\":0}]}}";
}
static bool loadThrows(const std::string& js) {
    try { JsonConfig::loadFromString(js); return false; }
    catch (const std::runtime_error&) { return true; }
}

int main() {
    // ---- 2.1 metal defaults (config-absent) -----------------------------------------
    {
        SimConfig::RadioConfig r;   // struct defaults
        assert(r.rx_to_tx_delay_ms == 27.0f);
        assert(r.tx_to_rx_delay_ms == 27.0f);
        SimConfig::SimulationConfig s;
        assert(s.rx_window_slop == "metal");
        std::printf("  [2.1] metal turnaround/slop defaults (27/27, \"metal\"): OK\n");
    }

    // ---- 2.2 duty percent parse: value stored VERBATIM as percent -------------------
    {
        SimConfig c1 = JsonConfig::loadFromString(makeConfig("1"));      // 1 = 1%
        assert(c1.simulation.radio.duty_cycle == 1.0f);
        SimConfig c10 = JsonConfig::loadFromString(makeConfig("10"));    // 10 = 10%
        assert(c10.simulation.radio.duty_cycle == 10.0f);
        SimConfig c100 = JsonConfig::loadFromString(makeConfig("100"));  // 100 = 100% (edge of range)
        assert(c100.simulation.radio.duty_cycle == 100.0f);
        SimConfig cfrac = JsonConfig::loadFromString(makeConfig("0.1")); // 0.1 = 0.1% (fractional percent ok)
        assert(cfrac.simulation.radio.duty_cycle == 0.1f);
        std::printf("  [2.2] percent parse (1 -> 1%%, 10 -> 10%%, 0.1 -> 0.1%%): OK\n");
    }

    // ---- 2.2 range refusal: (0, 100], key required ----------------------------------
    {
        assert(loadThrows(makeConfig("")));      // required key absent
        assert(loadThrows(makeConfig("0")));     // 0 refused (must be > 0)
        assert(loadThrows(makeConfig("-1")));    // negative refused
        assert(loadThrows(makeConfig("100.5"))); // > 100 refused
        assert(loadThrows(makeConfig("1000")));  // the old ×100 double-migration overshoot is refused
        (void)JsonConfig::loadFromString(makeConfig("100"));  // 100 accepted (boundary)
        std::printf("  [2.2] range refusal ((0,100], required, >100 rejected): OK\n");
    }

    // ---- 2.2 migration sanity: fraction-era value ×100 preserves EFFECTIVE duty -----
    {
        // The corpus migration multiplied every duty_cycle ×100 (0.01 -> 1, 0.1 -> 10).
        // The parsed percent /100 must equal the pre-migration fraction exactly.
        SimConfig m1  = JsonConfig::loadFromString(makeConfig("1"));    // was 0.01 fraction
        SimConfig m10 = JsonConfig::loadFromString(makeConfig("10"));   // was 0.1 fraction
        assert(m1.simulation.radio.duty_cycle  / 100.0 == 0.01);        // effective 1%
        assert(m10.simulation.radio.duty_cycle / 100.0 == 0.10);        // effective 10%
        std::printf("  [2.2] migration sanity (1/100==0.01, 10/100==0.10 effective): OK\n");
    }

    std::printf("test_wave2_config: OK\n");
    return 0;
}
