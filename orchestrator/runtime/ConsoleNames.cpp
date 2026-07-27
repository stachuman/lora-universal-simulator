// orchestrator/runtime/ConsoleNames.cpp
//
// Wave-4 #6 (2026-07-26): implementation of the lib/console name bridge.
//
// THE DEFECT THIS CLOSES. NodeRuntime::drainPushes rendered the push `kind` field with a
// 3-arm ternary (msg_recv / send_acked / send_e2e_acked) and defaulted EVERYTHING ELSE to
// "send_failed". PushKind has 14 enumerators, so 11 fell to that default and 10 of them
// were MISLABELLED — channel_recv, hash_resolved, peer_key_cached, config_adopted,
// join_refused, send_blocked, channel_sent, mobile_reg, team_reg and join_adopted all
// reported to every scenario and every analysis tool as a send FAILURE. Meanwhile the
// firmware already carried an exhaustive, -Wswitch-guarded mapper for exactly this enum
// (lib/console/console_json.cpp pushkind_name), used by the shipped companion contract.
// One table, two audiences (U1) — the oracle now calls the firmware's own mapper.
//
// ★ WHY THIS FILE EXISTS INSTEAD OF A DIRECT CALL.
// lib/console opens `namespace meshroute::console` LITERALLY (console_json.h), not
// `MESHROUTE_NS::console`. NodeRuntimeWrapper.cpp is compiled twice, and in the gateway
// compilation the only PushKind in scope is `meshroute_gw::PushKind`; including
// console_json.h there would declare `meshroute::console::pushkind_name(PushKind)` with no
// `PushKind` findable from inside namespace `meshroute` -> hard compile error. Making
// lib/console dual-namespace is a FIRMWARE edit (`namespace MESHROUTE_NS::console`),
// deliberately out of scope for a sim-side slice. So lib/console is compiled ONCE, in the
// default namespace, and the boundary is crossed on the enum's underlying integer here.
//
// ★ WHY THE uint8_t BRIDGE IS SOUND, and what would break it.
// `meshroute::PushKind` and `meshroute_gw::PushKind` are produced from the SAME header
// text (lib/core/command.h) with no preprocessor conditional anywhere inside the enum
// body, so they are value-identical by construction; MESHROUTE_NS only renames the
// enclosing namespace. The static_assert below (mirrored by its twin in
// NodeRuntimeWrapper.cpp, which sees the OTHER namespace) is the tripwire that makes that
// argument non-vacuous: if anyone ever makes an enumerator conditional on
// MR_GATEWAY_BUILD, the two asserts disagree and the gateway build FAILS instead of
// silently renaming a push kind.
#include "orchestrator/runtime/ConsoleNames.h"

#include "command.h"        // meshroute::PushKind (MESHROUTE_NS defaults to `meshroute` in this TU)
#include "console_json.h"   // meshroute::console::pushkind_name — the ONE exhaustive table

namespace mrsim {

// Tripwire, twinned at NodeRuntimeWrapper.cpp's drainPushes (see the header block above).
static_assert(sizeof(meshroute::PushKind) == 1,
              "PushKind must stay uint8_t-backed: the sim bridges it on its underlying type");
static_assert(static_cast<uint8_t>(meshroute::PushKind::join_adopted) == 13,
              "PushKind's enumerator values moved in the DEFAULT namespace — re-check the "
              "twin assert in NodeRuntimeWrapper.cpp before trusting the uint8_t bridge");

const char* pushKindName(uint8_t raw) {
    return meshroute::console::pushkind_name(static_cast<meshroute::PushKind>(raw));
}

}  // namespace mrsim
