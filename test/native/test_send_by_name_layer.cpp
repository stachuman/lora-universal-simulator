// test/native/test_send_by_name_layer.cpp
//
// ★ The SEND-BY-NAME RESOLUTION contract: a scenario's `send <name>` / `send_e2e
// <name>` must resolve to the id the addressee wears ON THE SENDER'S LAYER, and must
// REFUSE (C2) when that is not well defined.
//
// Why this needs a permanent test rather than suite byte-identity: the whole
// MeshRoute corpus contains exactly SIX send-by-name commands aimed at a multi-layer
// node (s09 / s09_metal / s10, two each) and ZERO commands that hit any refusal path.
// So the scenario anchors pin the happy path and pin NOTHING about the guard — a
// future edit could quietly restore the `protocolId()` fallback for the refusal cases
// and every anchor would still be byte-identical.
//
// ★ What went wrong before (MeshRoute simulation/BASELINE.md note 2026-07-25d): the
// host resolved <name> to the addressee's LIVE INode::protocolId(). A dual-layer
// gateway time-multiplexes its leaves and MeshRoute's Node::activate_layer() restamps
// the HAL short id to the entering leaf's node_id every window swap, so protocolId()
// ALTERNATES with the window phase. A layer-4 `send gw_4` fired during the gateway's
// layer-5 window went to a layer-5-only id, was unroutable, and died in
// send_deferred_giveup — i.e. whether a scenario passed depended on WHEN its command
// fired. s10's surviving assertion had been red on that for weeks.
//
// SCOPE. This test pins the GUARD (which shapes refuse, which do not, and what the
// message says), because that is the half the corpus cannot cover. The resolved VALUE
// is pinned by the corpus: s09 `l4_seed -> gw_4` delivering 1/1 and s10's
// `gw_4 delivered l4-local-seed-to-gw` assertion, both of which are red under the old
// resolution. build_test.sh deliberately does not link MeshRoute, so a meshroute node
// cannot actually be CONSTRUCTED here — which this test exploits: the pre-flight runs
// before node construction, so "refused" vs "MeshRoute not built in" is exactly the
// discriminator for "was this shape rejected by the layer guard or accepted by it".

#include "core/topology/JsonConfig.h"
#include "orchestrator/runtime/SimController.h"

#include <cassert>
#include <cstdio>
#include <sstream>
#include <stdexcept>
#include <string>

namespace {

// The marker the layer guard puts in its refusal, and the marker the (unrelated)
// "you did not build with MeshRoute" throw puts in its own. A config that clears the
// guard reaches the latter, which is how an ACCEPTED shape is recognised here.
const char* kRefused  = "REFUSED: cannot resolve the same-layer send";
const char* kNoEngine = "requires building with MeshRoute";

// Four nodes, each with a caller-supplied `config` object, plus one command.
//   n_l4 / n_l5  : single-layer leaves on layers 4 and 5
//   gw           : dual-layer gateway, id 10 on layer 4 and 111 on layer 5
// `sender_cfg` overrides the sender node's config so the sender's layer can be moved.
std::string cfgWith(const std::string& sender_cfg,
                    const std::string& sender_name,
                    const std::string& command) {
    return std::string("{\"_name\":\"probe\",\"simulation\":{\"duration_ms\":1000,")
         + "\"step_ms\":1,\"radio\":{\"sf\":7,\"bw\":125,\"cr\":5,\"duty_cycle\":1}},"
           "\"nodes\":["
           "{\"name\":\"n_l4\",\"node_id\":1,\"config\":" + (sender_name == "n_l4" ? sender_cfg : std::string("{\"layer_id\":4}")) + "},"
           "{\"name\":\"n_l5\",\"node_id\":2,\"config\":" + (sender_name == "n_l5" ? sender_cfg : std::string("{\"layer_id\":5}")) + "},"
           "{\"name\":\"leaf4\",\"node_id\":113,\"config\":{\"layer_id\":4}},"
           "{\"name\":\"gw\",\"node_id\":10,\"config\":" + (sender_name == "gw" ? sender_cfg : std::string(
               "{\"layer_id\":4,\"n_layers\":2,\"layers\":["
               "{\"layer_id\":4,\"node_id\":10},{\"layer_id\":5,\"node_id\":111}]}")) + "}"
           "],"
           "\"commands\":[{\"at_ms\":100,\"node\":\"" + sender_name + "\","
           "\"command\":\"" + command + "\"}],"
           "\"topology\":{\"links\":[]}}";
}

// Run cfg through a fresh controller; return the throw message ("" = no throw).
std::string initFailure(const SimConfig& cfg) {
    std::ostringstream out;
    SimController ctrl(cfg, out);
    try {
        ctrl.initialize();
    } catch (const std::exception& ex) {
        return ex.what();
    }
    return "";
}

std::string refusalFor(const std::string& sender_cfg,
                       const std::string& sender_name,
                       const std::string& command) {
    return initFailure(JsonConfig::loadFromString(
        cfgWith(sender_cfg, sender_name, command)));
}

bool has(const std::string& hay, const std::string& needle) {
    return hay.find(needle) != std::string::npos;
}

// An ACCEPTED shape: the layer guard let it through, so the run died later on the
// unrelated "MeshRoute not linked" throw instead.
void assertAccepted(const std::string& msg, const char* what) {
    assert(!has(msg, kRefused) && what);
    assert(has(msg, kNoEngine) &&
           "the probe must reach node construction, i.e. clear the layer guard");
    (void)what;
}

void assertRefused(const std::string& msg, const char* what) {
    assert(has(msg, kRefused) && what);
    (void)what;
}

}  // namespace

int main() {
    const std::string kL4 = "{\"layer_id\":4}";
    const std::string kL5 = "{\"layer_id\":5}";
    const std::string kL9 = "{\"layer_id\":9}";
    const std::string kGw = "{\"layer_id\":4,\"n_layers\":2,\"layers\":["
                            "{\"layer_id\":4,\"node_id\":10},"
                            "{\"layer_id\":5,\"node_id\":111}]}";

    // ---- 1. the ordinary same-layer send is untouched ----------------------
    // Both single-layer, same layer -> resolve against the addressee's LIVE id.
    assertAccepted(refusalFor(kL4, "n_l4", "send leaf4 hello"),
                   "a same-layer send between single-layer nodes must not be refused");
    assertAccepted(refusalFor(kL4, "n_l4", "send_e2e leaf4 hello"),
                   "send_e2e must behave exactly like send");

    // ---- 2. a MULTI-LAYER addressee that shares the sender's layer ---------
    // This is the s09/s10 case the slice fixes: accepted, and resolved off
    // layers[], not off the gateway's momentary protocolId().
    assertAccepted(refusalFor(kL4, "n_l4", "send gw hello"),
                   "layer-4 sender -> gateway's layer-4 entry must resolve");
    assertAccepted(refusalFor(kL5, "n_l5", "send gw hello"),
                   "layer-5 sender -> gateway's layer-5 entry must resolve");

    // ---- 3. ★ NO SHARED LAYER refuses, loudly -----------------------------
    // A cross-layer DM's verb is send_layer; `send <name>` must never quietly
    // address a node that has no id in the sender's namespace.
    {
        const std::string msg = refusalFor(kL4, "n_l4", "send n_l5 wrong-plane");
        assertRefused(msg, "★ a cross-layer send-by-name must REFUSE, not guess");
        // Self-explanatory to a reader who has never seen the ruling: the command,
        // both nodes, both layers, and the correct verb.
        assert(has(msg, "send n_l5 wrong-plane") && "the command must be quoted");
        assert(has(msg, "'n_l4'") && has(msg, "'n_l5'") &&
               "both nodes must be named");
        assert(has(msg, "layer 4") && has(msg, "layer 5") &&
               "both layers must be named");
        assert(has(msg, "send_layer") && "the message must name the correct verb");
        assert(has(msg, "at_ms=100") && "the offending command must be locatable");
    }
    {
        // Same refusal when the addressee IS multi-layer but has no entry for the
        // sender's layer -- the gateway is {4,5}, the sender is on 9.
        const std::string msg = refusalFor(kL9, "n_l4", "send gw no-layer-9");
        assertRefused(msg, "a gateway with no entry on the sender's layer must refuse");
        assert(has(msg, "layers {4:10, 5:111}") &&
               "the refusal must list the addressee's per-layer ids to pick from");
        assert(has(msg, "layer-9") && "the sender's layer must be named");
    }

    // ---- 4. ★ a MULTI-LAYER SENDER refuses rather than picking a leaf ------
    // Its "current" layer is whichever window its scheduler has active at command
    // time -- the same timing accident, moved to the sender side. Resolving against
    // its home leaf would be well-defined but still silently wrong in the other
    // window, so the scenario has to say which layer it means.
    {
        const std::string msg = refusalFor(kGw, "gw", "send leaf4 from-a-gateway");
        assertRefused(msg, "★ a send-by-name FROM a dual-layer gateway must refuse");
        assert(has(msg, "multi-layer gateway"));
        assert(has(msg, "window") && "the message must explain WHY it is ambiguous");
        assert(has(msg, "send_layer"));
    }

    // ---- 5. only the two name-taking verbs are inspected -------------------
    // Everything else is addressed by layer+key_hash32, by hash, or by channel, and
    // must pass through even when the layers do not line up. `send <numeric>` is
    // likewise untouched (no name to resolve).
    for (const char* cmd : {"send_layer 5 1426063473 xl",
                            "send_layerx 5 1426063473 xl",
                            "send_hash 38e8b9f4 by-hash",
                            "send_hashx 38e8b9f4 by-hash",
                            "send_channel 5 broadcast",
                            "send 111 numeric-dst",
                            "send_e2e 111 numeric-dst"}) {
        assertAccepted(refusalFor(kL4, "n_l4", cmd),
                       "a non-name-taking send verb must never hit the layer guard");
    }
    // A name with no message body is not a resolvable send-by-name either (the
    // pre-existing parser requires a space after the name) -- must not refuse.
    assertAccepted(refusalFor(kL4, "n_l4", "send n_l5"),
                   "a bodyless send is not rewritten, so it must not be refused");
    // An unknown addressee name stays a pass-through (it is a numeric dst, or the
    // scenario's own error) -- the guard must not claim it.
    assertAccepted(refusalFor(kL4, "n_l4", "send nosuchnode hello"),
                   "an unknown addressee name must pass through untouched");

    // ---- 6. the legacy `leaf_id` spelling of layer_id is honoured ----------
    // JsonConfig's own duplicate-id check accepts either spelling; the resolver must
    // agree with it, or a leaf_id scenario would refuse its own valid sends.
    assertAccepted(refusalFor("{\"leaf_id\":4}", "n_l4", "send leaf4 hello"),
                   "leaf_id must be accepted as layer_id (same layer)");
    assertRefused(refusalFor("{\"leaf_id\":5}", "n_l4", "send leaf4 hello"),
                  "leaf_id must be accepted as layer_id (different layer)");
    assertAccepted(refusalFor("{\"leaf_id\":5}", "n_l4", "send gw hello"),
                   "leaf_id 5 must match the gateway's layer-5 entry");

    // ---- 7. a layer-less corpus stays inert -------------------------------
    // No single-layer scenario writes layer_id at all, so every node reads layer 0
    // and resolution is unchanged. Proven by 16 byte-identical anchors; pinned here
    // so the "absent => 0" default cannot be quietly changed to "absent => refuse".
    {
        const std::string all_layerless =
            std::string("{\"_name\":\"probe\",\"simulation\":{\"duration_ms\":1000,")
            + "\"step_ms\":1,\"radio\":{\"sf\":7,\"bw\":125,\"cr\":5,\"duty_cycle\":1}},"
              "\"nodes\":[{\"name\":\"a\",\"node_id\":1},{\"name\":\"b\",\"node_id\":2}],"
              "\"commands\":[{\"at_ms\":100,\"node\":\"a\",\"command\":\"send b hi\"}],"
              "\"topology\":{\"links\":[]}}";
        assertAccepted(initFailure(JsonConfig::loadFromString(all_layerless)),
                       "nodes with no layer_id must all read layer 0 and resolve");
    }

    // ---- 8. the refusal costs ZERO output ---------------------------------
    // The pre-flight sits in initialize() before the first EventLog write, so a
    // refused run leaves no truncated NDJSON behind for a tool to misread.
    {
        const SimConfig cfg = JsonConfig::loadFromString(
            cfgWith(kL4, "n_l4", "send n_l5 wrong-plane"));
        std::ostringstream out;
        SimController ctrl(cfg, out);
        bool threw = false;
        try { ctrl.initialize(); } catch (const std::exception&) { threw = true; }
        assert(threw);
        assert(out.str().empty() && "★ a refused run must emit ZERO bytes");
    }

    std::printf("test_send_by_name_layer: OK "
                "(same-layer + gateway-on-sender's-layer resolve; no-shared-layer and "
                "multi-layer-sender REFUSED with 0 bytes; other verbs/numeric/unknown "
                "pass through; leaf_id alias and the layer-less default held)\n");
    return 0;
}
