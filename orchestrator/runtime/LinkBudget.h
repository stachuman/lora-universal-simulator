#pragma once
// orchestrator/runtime/LinkBudget.h
// Author: Stanislaw Kozicki <cgpsmapper@gmail.com>
//
// §1.5 (2026-07-20 realism review): per-frame TX-power link-budget delta.
//
// A frame that carries an EXPLICIT TX power (power_dbm != -127, the "use radio default" sentinel)
// shifts the received signal by (power_dbm - the path-loss model's reference tx_power_dbm); snr and
// rssi move by the same dB. Applied at the InFlight delivery + collision link-budget sites in
// SimController. Inert on the whole corpus today (the MeshRoute firmware always passes the -127
// sentinel, so no frame carries an explicit power) -> byte-identical streams; it makes a future
// adaptive-power scenario actually take effect in the sim instead of being silently ignored.
//
// Free inline in its own header so the SimController delivery/collision sites AND the sim-native
// unit test (test/native/test_wave1_config.cpp) share exactly ONE definition, without the test
// having to pull in the whole SimController translation unit.

inline float txPowerDeltaDb(int power_dbm, double ref_tx_power_dbm) {
    if (power_dbm == -127) return 0.0f;   // sentinel: no explicit power -> no delta
    return static_cast<float>(static_cast<double>(power_dbm) - ref_tx_power_dbm);
}
