// orchestrator/runtime/ConsoleNames.h
//
// Wave-4 #6 (2026-07-26): the sim's NAMESPACE-NEUTRAL door to MeshRoute's lib/console
// enum->string mappers, so the scenario oracle and the shipped companion contract read
// from ONE table and cannot drift.
//
// Why a neutral door exists at all: the firmware core is compiled TWICE into ODR-distinct
// libs (namespace `meshroute` and `meshroute_gw`), but lib/console is written in the
// LITERAL namespace `meshroute::console` — so it can only be compiled ONCE. Everything
// that crosses this header therefore crosses on a PRIMITIVE type, exactly like ISimHal.
//
// ★ HARD LIMIT — read before adding a second function here. Only mappers whose ENTIRE
//   argument list is the enum's underlying integer may be bridged this way (pushkind_name,
//   cmdcode_name, sendfailreason_name, joinrefusereason_name). Anything taking a
//   `Node` / `NodeConfig` / `Push` MUST NOT be: this lib is built with the NORMAL variant's
//   MR_N_LAYERS=1 layout, so a gateway node's struct passed into it would be reinterpreted
//   at the wrong layout. See ConsoleNames.cpp for the soundness argument for the enum case.
#pragma once
#include <cstdint>

namespace mrsim {

// MeshRoute PushKind -> its canonical JSON name (lib/console/console_json.cpp pushkind_name,
// -Wswitch-exhaustive there). `raw` is static_cast<uint8_t>(NS::PushKind). An out-of-range
// value renders "unknown" rather than a plausible-but-wrong kind (C2: fail visible).
const char* pushKindName(uint8_t raw);

}  // namespace mrsim
