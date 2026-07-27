// core/topology/JsonConfig.cpp
//
// See JsonConfig.h for the schema overview. This is the parser +
// validator port from meshcore_real_sim/orchestrator/JsonConfig.cpp,
// with MeshCore-firmware-specific bits surgically removed:
//
//   - simulation.firmware.{default,plugins}      (plugin selection)
//   - simulation.hot_start                        (advert pre-seeding)
//   - simulation.delay_tuning.*                   (delay-optimization tooling)
//   - nodes[i].role                               (Repeater/Companion concept)
//   - nodes[i].firmware                           (per-node plugin override)
//   - nodes[i].adversarial.*                      (drop/corrupt/replay)
//   - message_schedule / channel_schedule         (msg/msga/msgc generators)
//   - @repeaters / @companions group expansion    (role-based)
//   - firmware-name validation ("must start fw_") (plugin naming)
//
// Replaced by:
//   - nodes[i].script (string)  + nodes[i].config (arbitrary JSON object)
//
// The remaining protocol-agnostic schema (simulation timing, global radio
// defaults, capture / CAD / fading / hardware tuning, topology.links,
// generic commands, expect[]) is preserved verbatim.

#include "core/topology/JsonConfig.h"

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <cstdint>
#include <vector>

using json = nlohmann::json;

// --- helpers --------------------------------------------------------------

// Pull a required field from a JSON object, producing a human-readable error
// if it's missing or the wrong type. `ctx` identifies the enclosing scope,
// e.g. "nodes[3]" or "commands[7]", so the user knows where to look.
template <typename T>
static T require_field(const json& j, const char* field, const std::string& ctx) {
    if (!j.contains(field)) {
        throw std::runtime_error(
            "config error at " + ctx + ": missing required field \"" + field + "\"");
    }
    try {
        return j[field].get<T>();
    } catch (const json::type_error& e) {
        throw std::runtime_error(
            "config error at " + ctx + ": field \"" + field
            + "\" has wrong type (" + e.what() + ")");
    }
}

static uint32_t fnv1a32(const std::string& s) {
    uint32_t h = 2166136261u;
    for (unsigned char c : s) {
        h ^= static_cast<uint32_t>(c);
        h *= 16777619u;
    }
    return h == 0 ? 1u : h;
}

// §1.1 (2026-07-20 realism review): the JSON `bw` field is authored in kHz as a DOUBLE; store it
// internally in Hz (×1000, rounded). "62.5" -> 62500 Hz exactly — the old get<int>() truncated it
// to 62 kHz (62000 Hz), diverging from the firmware's own airtime math which runs true 62500.
static int parseBwHz(const json& value) {
    return static_cast<int>(std::lround(value.get<double>() * 1000.0));
}

// §carrier (2026-07-26): `freq_khz` is authored as an INTEGER number of kHz and stored verbatim —
// DELIBERATELY unlike `bw` above. The carrier is compared for exact equality by the reachability
// gate, so it must never pass through a float; and the ONE MHz→kHz rounding path in this project is
// the firmware's `protocol::mhz_to_khz` (applied where the firmware's Hal::set_rx_freq hands a
// double MHz to the sim). A fractional/negative/non-numeric value is REFUSED here rather than
// rounded — that would be exactly the second conversion path this design exists to avoid.
static int requireIntegerKhz(const json& value, const std::string& ctx) {
    if (!value.is_number_integer() || value.get<long long>() <= 0) {
        throw std::runtime_error(
            "config error at " + ctx
            + ": field \"freq_khz\" must be a POSITIVE INTEGER number of kHz "
              "(e.g. 868000 or 869525) — fractional MHz is not accepted here");
    }
    return static_cast<int>(value.get<long long>());
}

static uint32_t parseKeyHash32(const json& value, const std::string& ctx) {
    if (value.is_number_unsigned() || value.is_number_integer()) {
        long long v = value.get<long long>();
        if (v < 0 || v > 0xffffffffLL) {
            throw std::runtime_error(
                "config error at " + ctx
                + ": field \"key_hash32\" must fit uint32");
        }
        return static_cast<uint32_t>(v);
    }
    if (value.is_string()) {
        std::string s = value.get<std::string>();
        if (s.rfind("0x", 0) == 0 || s.rfind("0X", 0) == 0) {
            s = s.substr(2);
        }
        if (s.empty() || s.size() > 8) {
            throw std::runtime_error(
                "config error at " + ctx
                + ": field \"key_hash32\" hex string must be 1..8 digits");
        }
        uint32_t out = 0;
        for (char c : s) {
            out <<= 4;
            if (c >= '0' && c <= '9') out |= static_cast<uint32_t>(c - '0');
            else if (c >= 'a' && c <= 'f') out |= static_cast<uint32_t>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') out |= static_cast<uint32_t>(c - 'A' + 10);
            else {
                throw std::runtime_error(
                    "config error at " + ctx
                    + ": field \"key_hash32\" must be hex or integer");
            }
        }
        return out == 0 ? 1u : out;
    }
    throw std::runtime_error(
        "config error at " + ctx
        + ": field \"key_hash32\" must be an integer or hex string");
}

// Slice A2: parse an identity seed -> 32 bytes (MSB-first hex string, 1..64 digits, left-aligned +
// zero-padded; or an unsigned integer placed little-endian in the low bytes). Crypto-agnostic — the
// seed->key_hash32 derivation (lib/core/identity) happens in SimController, so JsonConfig stays dep-free.
static void parseSeed32(const json& value, const std::string& ctx, std::array<uint8_t, 32>& out) {
    out.fill(0);
    auto nib = [&](char c) -> uint32_t {
        if (c >= '0' && c <= '9') return static_cast<uint32_t>(c - '0');
        if (c >= 'a' && c <= 'f') return static_cast<uint32_t>(c - 'a' + 10);
        if (c >= 'A' && c <= 'F') return static_cast<uint32_t>(c - 'A' + 10);
        throw std::runtime_error("config error at " + ctx + ": field \"seed\" must be hex");
    };
    if (value.is_string()) {
        std::string s = value.get<std::string>();
        if (s.rfind("0x", 0) == 0 || s.rfind("0X", 0) == 0) s = s.substr(2);
        if (s.empty() || s.size() > 64)
            throw std::runtime_error("config error at " + ctx + ": field \"seed\" hex must be 1..64 digits");
        if (s.size() % 2) s = "0" + s;                              // even-length, MSB-first
        for (size_t i = 0; i < s.size() / 2; ++i)                   // left-aligned: "01" -> {0x01, 0, ...}
            out[i] = static_cast<uint8_t>((nib(s[2 * i]) << 4) | nib(s[2 * i + 1]));
    } else if (value.is_number_unsigned() || value.is_number_integer()) {
        long long vv = value.get<long long>();
        if (vv < 0) throw std::runtime_error("config error at " + ctx + ": field \"seed\" must be non-negative");
        uint64_t v = static_cast<uint64_t>(vv);
        for (int i = 0; i < 8; ++i) out[i] = static_cast<uint8_t>((v >> (8 * i)) & 0xffu);   // LE
    } else {
        throw std::runtime_error("config error at " + ctx + ": field \"seed\" must be a hex string or integer");
    }
}

// --- main parse -----------------------------------------------------------

static SimConfig parseJson(const json& j) {
    SimConfig cfg;

    if (j.contains("_name") && j["_name"].is_string())
        cfg.name = j["_name"].get<std::string>();

    if (j.contains("config") && j["config"].is_object())
        cfg.config = j["config"];

    if (j.contains("simulation")) {
        auto& sim = j["simulation"];
        if (sim.contains("duration_ms")) cfg.simulation.duration_ms = sim["duration_ms"].get<unsigned long>();
        if (sim.contains("step_ms"))     cfg.simulation.step_ms     = sim["step_ms"].get<int>();
        if (sim.contains("epoch_start")) cfg.simulation.epoch_start = sim["epoch_start"].get<uint32_t>();
        if (sim.contains("warmup_ms"))   cfg.simulation.warmup_ms   = sim["warmup_ms"].get<unsigned long>();
        if (sim.contains("seed"))        cfg.simulation.seed        = sim["seed"].get<uint64_t>();
        if (sim.contains("node_startup_jitter_ms"))
            cfg.simulation.node_startup_jitter_ms = sim["node_startup_jitter_ms"].get<int>();
        if (sim.contains("rx_window_slop"))
            cfg.simulation.rx_window_slop = sim["rx_window_slop"].get<std::string>();
        // ★ 2026-07-25 ruling: the deprecated-Lua opt-in. Belongs HERE (a
        // simulation-level knob, like rx_window_slop) — deliberately NOT under
        // nodes[].config, whose meshroute key whitelist fails loud on anything
        // it does not know (NodeRuntimeWrapper.cpp "unknown key"), so a
        // misplaced copy is rejected rather than silently ignored. Type-checked
        // the way the "engine" field below is.
        if (sim.contains("allow_deprecated_lua")) {
            if (!sim["allow_deprecated_lua"].is_boolean()) {
                throw std::runtime_error(
                    "config error at simulation: field \"allow_deprecated_lua\" "
                    "must be a boolean");
            }
            cfg.simulation.allow_deprecated_lua = sim["allow_deprecated_lua"].get<bool>();
        }
        if (sim.contains("radio")) {
            auto& r = sim["radio"];
            if (r.contains("sf")) cfg.simulation.radio.sf = r["sf"].get<int>();
            if (r.contains("bw")) cfg.simulation.radio.bw = parseBwHz(r["bw"]);   // kHz-double -> Hz
            if (r.contains("cr")) cfg.simulation.radio.cr = r["cr"].get<int>();
            // §carrier: the scenario's global RF carrier, INTEGER kHz (see RadioConfig::freq_khz for
            // why integer, and why — unlike sf/bw/cr — it is not required).
            if (r.contains("freq_khz"))
                cfg.simulation.radio.freq_khz = requireIntegerKhz(r["freq_khz"], "simulation.radio");
            if (r.contains("capture_locked_db"))   cfg.simulation.radio.capture_locked_db   = r["capture_locked_db"].get<float>();
            if (r.contains("capture_unlocked_db")) cfg.simulation.radio.capture_unlocked_db = r["capture_unlocked_db"].get<float>();
            if (r.contains("cad_miss_prob"))       cfg.simulation.radio.cad_miss_prob       = r["cad_miss_prob"].get<float>();
            if (r.contains("max_packet_bytes"))    cfg.simulation.radio.max_packet_bytes    = r["max_packet_bytes"].get<int>();
            if (r.contains("cad_reliable_snr"))    cfg.simulation.radio.cad_reliable_snr    = r["cad_reliable_snr"].get<float>();
            if (r.contains("cad_marginal_snr"))    cfg.simulation.radio.cad_marginal_snr    = r["cad_marginal_snr"].get<float>();
            if (r.contains("snr_coherence_ms"))    cfg.simulation.radio.snr_coherence_ms    = r["snr_coherence_ms"].get<float>();
            if (r.contains("snr_report_ceiling_db")) cfg.simulation.radio.snr_report_ceiling_db = r["snr_report_ceiling_db"].get<float>();  // §snr-unification A: receiver-report saturation ceiling (default +12; huge = disable)
            // §1A-1 (2026-07-24 realism review): LBT model — "energy" (default, device noise-floor
            // energy detect) | "cad" (legacy probabilistic model, kept for A/B). Unknown = fail-loud
            // validateConfig error. lbt_energy_threshold_snr_db is the energy-detect busy threshold (dB).
            if (r.contains("lbt_model"))           cfg.simulation.radio.lbt_model           = r["lbt_model"].get<std::string>();
            if (r.contains("lbt_energy_threshold_snr_db")) cfg.simulation.radio.lbt_energy_threshold_snr_db = r["lbt_energy_threshold_snr_db"].get<float>();
            // §2.2 (2026-07-21 realism ruling): duty_cycle is authored as a PERCENT (1 = 1%),
            // stored verbatim; consumers divide by 100 (SimController enforcement + injection).
            if (r.contains("duty_cycle"))          cfg.simulation.radio.duty_cycle          = r["duty_cycle"].get<float>();  // PERCENT (1 = 1%)
            if (r.contains("duty_cycle_window_ms")) cfg.simulation.radio.duty_cycle_window_ms = r["duty_cycle_window_ms"].get<unsigned long>();
            if (r.contains("hardware")) {
                auto& hw = r["hardware"];
                if (hw.contains("rx_to_tx_delay_ms")) cfg.simulation.radio.rx_to_tx_delay_ms = hw["rx_to_tx_delay_ms"].get<float>();
                if (hw.contains("tx_to_rx_delay_ms")) cfg.simulation.radio.tx_to_rx_delay_ms = hw["tx_to_rx_delay_ms"].get<float>();
                if (hw.contains("sf_switch_delay_ms")) cfg.simulation.radio.sf_switch_delay_ms = hw["sf_switch_delay_ms"].get<float>();
                if (hw.contains("decode_margin_steepness_db"))
                    cfg.simulation.radio.decode_margin_steepness_db = hw["decode_margin_steepness_db"].get<float>();
                if (hw.contains("rx_preamble_miss_prob"))
                    cfg.simulation.radio.rx_preamble_miss_prob = hw["rx_preamble_miss_prob"].get<float>();
            }
        }
        if (sim.contains("clock_drift_ppm_sigma"))
            cfg.simulation.clock_drift_ppm_sigma = sim["clock_drift_ppm_sigma"].get<double>();
        // Optional log-distance path-loss block (Phase R.2). When present,
        // SimController computes per-pair SNR/RSSI from haversine distance
        // between nodes' (lat, lon) and skips pairs lacking lat/lon.
        if (sim.contains("path_loss")) {
            const auto& pl = sim["path_loss"];
            cfg.simulation.path_loss.present = true;
            if (pl.contains("model"))          cfg.simulation.path_loss.model          = pl["model"].get<std::string>();
            if (pl.contains("alpha"))          cfg.simulation.path_loss.alpha          = pl["alpha"].get<double>();
            if (pl.contains("sigma_db"))       cfg.simulation.path_loss.sigma_db       = pl["sigma_db"].get<double>();
            if (pl.contains("ref_distance_m")) cfg.simulation.path_loss.ref_distance_m = pl["ref_distance_m"].get<double>();
            if (pl.contains("ref_loss_db"))    cfg.simulation.path_loss.ref_loss_db    = pl["ref_loss_db"].get<double>();
            if (pl.contains("noise_floor_db")) cfg.simulation.path_loss.noise_floor_db = pl["noise_floor_db"].get<double>();
            if (pl.contains("tx_power_dbm"))   cfg.simulation.path_loss.tx_power_dbm   = pl["tx_power_dbm"].get<double>();
            if (pl.contains("mobile_only"))    cfg.simulation.path_loss.mobile_only    = pl["mobile_only"].get<bool>();
            if (pl.contains("node_tx_offset_sigma_db"))
                cfg.simulation.path_loss.node_tx_offset_sigma_db = pl["node_tx_offset_sigma_db"].get<double>();
            if (pl.contains("node_rx_offset_sigma_db"))
                cfg.simulation.path_loss.node_rx_offset_sigma_db = pl["node_rx_offset_sigma_db"].get<double>();
            if (pl.contains("asymmetry_coherence_ms"))
                cfg.simulation.path_loss.asymmetry_coherence_ms = pl["asymmetry_coherence_ms"].get<uint64_t>();
            if (pl.contains("frequency_mhz"))
                cfg.simulation.path_loss.frequency_mhz = pl["frequency_mhz"].get<double>();
            // model is validated downstream in validate(); accept any
            // string at parse time so the validator's error message is
            // the canonical one.
        }
        // NOTE: simulation.firmware, simulation.hot_start, simulation.delay_tuning
        // were intentionally stripped during the MeshCore -> universal port.
    }

    if (j.contains("nodes")) {
        size_t node_idx = 0;
        for (auto& nd : j["nodes"]) {
            const std::string ctx = "nodes[" + std::to_string(node_idx++) + "]";
            SimConfig::NodeDef def;
            def.name = require_field<std::string>(nd, "name", ctx);
            if (nd.contains("node_id")) {
                if (nd["node_id"].is_null()) {
                    def.node_id = -1;
                } else if (nd["node_id"].is_number_integer()) {
                    def.node_id = nd["node_id"].get<int>();
                    if (def.node_id < 0 || def.node_id > 254) {
                        throw std::runtime_error(
                            "config error at " + ctx
                            + ": field \"node_id\" must be an integer in [0, 254] or null");
                    }
                } else {
                    throw std::runtime_error(
                        "config error at " + ctx
                        + ": field \"node_id\" must be an integer or null");
                }
            }
            if (nd.contains("public_key")) {
                if (!nd["public_key"].is_string()) {
                    throw std::runtime_error(
                        "config error at " + ctx
                        + ": field \"public_key\" must be a string");
                }
                def.public_key = nd["public_key"].get<std::string>();
            } else {
                def.public_key = "sim:" + def.name;
            }
            if (nd.contains("key_hash32")) {
                def.key_hash32 = parseKeyHash32(nd["key_hash32"], ctx);
            } else {
                def.key_hash32 = fnv1a32(def.public_key);
            }
            // Slice A2: an identity seed (preferred). Parsed here; key_hash32 is DERIVED from it in
            // SimController (lib/core/identity), overriding the literal/fnv fallback above for BOTH engines.
            if (nd.contains("seed")) {
                parseSeed32(nd["seed"], ctx, def.seed);
                def.has_seed = true;
            }

            // New universal fields: script + config.
            if (nd.contains("script"))
                def.script_path = nd["script"].get<std::string>();
            if (nd.contains("config")) {
                if (!nd["config"].is_object()) {
                    throw std::runtime_error(
                        "config error at " + ctx + ": field \"config\" must be a JSON object");
                }
                def.config = nd["config"];
            }
            if (nd.contains("engine")) {
                if (!nd["engine"].is_string()) {
                    throw std::runtime_error(
                        "config error at " + ctx + ": field \"engine\" must be a string");
                }
                def.engine = nd["engine"].get<std::string>();
                // "lua" still PARSES (it is the frozen parity reference, kept on
                // purpose) but is DEPRECATED + UNSUPPORTED: the run is refused at
                // SimController::initialize() unless simulation.allow_deprecated_lua
                // is set. The refusal deliberately does NOT live here — main.cpp's
                // --engine override rewrites n.engine AFTER load, so a check at
                // parse time would miss the CLI path entirely.
                if (def.engine != "lua" && def.engine != "meshroute") {
                    throw std::runtime_error(
                        "config error at " + ctx + ": unknown engine \"" + def.engine
                        + "\" (expected \"meshroute\", or the deprecated \"lua\")");
                }
            }

            // Per-node radio overrides (nested or flat).
            if (nd.contains("radio")) {
                auto& r = nd["radio"];
                if (r.contains("sf")) def.sf = r["sf"].get<int>();
                if (r.contains("bw")) def.bw = parseBwHz(r["bw"]);   // kHz-double -> Hz
                if (r.contains("cr")) def.cr = r["cr"].get<int>();
                if (r.contains("freq_khz")) def.freq_khz = requireIntegerKhz(r["freq_khz"], ctx + ".radio");  // §carrier
            }
            if (nd.contains("sf")) def.sf = nd["sf"].get<int>();
            if (nd.contains("bw")) def.bw = parseBwHz(nd["bw"]);     // kHz-double -> Hz
            if (nd.contains("cr")) def.cr = nd["cr"].get<int>();
            if (nd.contains("freq_khz")) def.freq_khz = requireIntegerKhz(nd["freq_khz"], ctx);   // §carrier

            // Optional sf_rx_set: per-node list of SFs the receiver can
            // decode. Absent -> empty vector; SimController defaults to
            // [node.sf] at init (single-SF, matches real LoRa hardware).
            // Present -> copy values verbatim; out-of-range entries are
            // warn-and-clamped to [5, 12].
            if (nd.contains("sf_rx_set")) {
                if (!nd["sf_rx_set"].is_array()) {
                    throw std::runtime_error(
                        "config error at " + ctx
                        + ": field \"sf_rx_set\" must be a JSON array of integers");
                }
                for (const auto& v : nd["sf_rx_set"]) {
                    if (!v.is_number_integer()) {
                        throw std::runtime_error(
                            "config error at " + ctx
                            + ": each entry of \"sf_rx_set\" must be an integer");
                    }
                    int sf_v = v.get<int>();
                    if (sf_v < 5 || sf_v > 12) {
                        int clamped = sf_v < 5 ? 5 : 12;
                        std::fprintf(stderr,
                            "lus: warning at %s: sf_rx_set entry %d out of range "
                            "[5, 12]; clamping to %d\n",
                            ctx.c_str(), sf_v, clamped);
                        sf_v = clamped;
                    }
                    def.sf_rx_set.push_back(sf_v);
                }
            }

            if (nd.contains("lat") && nd.contains("lon")) {
                def.lat = nd["lat"].get<double>();
                def.lon = nd["lon"].get<double>();
                def.has_location = true;
            }

            if (nd.contains("tx_fail_prob"))
                def.tx_fail_prob = nd["tx_fail_prob"].get<float>();

            if (nd.contains("start_at_ms"))
                def.start_at_ms = nd["start_at_ms"].get<unsigned long>();
            if (nd.contains("dies_at_ms"))
                def.dies_at_ms  = nd["dies_at_ms"].get<unsigned long>();

            // Per-node asymmetry overrides — pin a node's TX/RX bias for
            // tests / known-hardware reproductions. NaN (the default)
            // means "sample from path_loss.node_*_offset_sigma_db".
            if (nd.contains("tx_power_offset_db"))
                def.tx_power_offset_db = nd["tx_power_offset_db"].get<float>();
            if (nd.contains("rx_offset_db"))
                def.rx_offset_db = nd["rx_offset_db"].get<float>();
            if (nd.contains("antenna_height_m"))
                def.antenna_height_m = nd["antenna_height_m"].get<float>();
            if (nd.contains("clock_drift_ppm"))
                def.clock_drift_ppm = nd["clock_drift_ppm"].get<float>();
            if (nd.contains("velocity_mps"))
                def.velocity_mps = nd["velocity_mps"].get<float>();
            if (nd.contains("direction_deg"))
                def.direction_deg = nd["direction_deg"].get<float>();

            // NOTE: role / firmware / adversarial were stripped (MeshCore-only).

            cfg.nodes.push_back(std::move(def));
        }
    }

    // Merge global radio defaults into nodes where not explicitly set.
    for (auto& nd : cfg.nodes) {
        if (nd.sf == -1) nd.sf = cfg.simulation.radio.sf;
        if (nd.bw == -1) nd.bw = cfg.simulation.radio.bw;
        if (nd.cr == -1) nd.cr = cfg.simulation.radio.cr;
        // §carrier: THE inherit that keeps the whole shipped corpus byte-identical — no scenario sets a
        // carrier, so every node lands on the one global value and every reachability comparison matches.
        // Mirrors the firmware's own documented contract (node_carriers.h: "0 = inherit the node's
        // boot/global freq"), which is why this inherit is legitimate rather than a silent default.
        if (nd.freq_khz == -1) nd.freq_khz = cfg.simulation.radio.freq_khz;
    }

    if (j.contains("topology")) {
        auto& topo = j["topology"];
        if (topo.contains("links")) {
            size_t link_idx = 0;
            for (auto& lk : topo["links"]) {
                const std::string ctx = "topology.links[" + std::to_string(link_idx++) + "]";
                SimConfig::LinkDef def;
                def.from = require_field<std::string>(lk, "from", ctx);
                def.to   = require_field<std::string>(lk, "to",   ctx);
                if (lk.contains("snr"))         def.snr         = lk["snr"].get<float>();
                if (lk.contains("rssi"))        def.rssi        = lk["rssi"].get<float>();
                if (lk.contains("snr_std_dev")) def.snr_std_dev = lk["snr_std_dev"].get<float>();
                if (lk.contains("loss"))        def.loss        = lk["loss"].get<float>();
                if (lk.contains("bidir"))       def.bidir       = lk["bidir"].get<bool>();
                cfg.topology.links.push_back(std::move(def));
            }
        }
    }

    // Deterministic forced-frame drops (R3.x lossy gate). Top-level
    // "forced_drops": [ {from,to,label,nth,count}, ... ]. Parsed only when
    // present, so existing scenarios are untouched.
    if (j.contains("forced_drops")) {
        size_t fd_idx = 0;
        for (auto& fd : j["forced_drops"]) {
            const std::string ctx = "forced_drops[" + std::to_string(fd_idx++) + "]";
            SimConfig::DropDirective def;
            if (fd.contains("from"))  def.from  = fd["from"].get<std::string>();
            if (fd.contains("to"))    def.to    = fd["to"].get<std::string>();
            if (fd.contains("label")) def.label = fd["label"].get<std::string>();
            if (fd.contains("nth"))   def.nth   = fd["nth"].get<int>();
            if (fd.contains("count")) def.count = fd["count"].get<int>();
            if (def.nth < 1)
                throw std::runtime_error("config error at " + ctx + ": nth must be >= 1");
            if (def.count < 1)
                throw std::runtime_error("config error at " + ctx + ": count must be >= 1");
            cfg.drop_directives.push_back(std::move(def));
        }
    }

    if (j.contains("commands")) {
        size_t cmd_idx = 0;
        for (auto& cd : j["commands"]) {
            const std::string ctx = "commands[" + std::to_string(cmd_idx++) + "]";
            unsigned long at_ms = require_field<unsigned long>(cd, "at_ms", ctx);

            // Lua-only command: {"at_ms": N, "lua": "function_name"}
            if (cd.contains("lua")) {
                SimConfig::CmdDef def;
                def.at_ms  = at_ms;
                def.lua_fn = cd["lua"].get<std::string>();
                cfg.commands.push_back(std::move(def));
                continue;
            }

            std::string node    = require_field<std::string>(cd, "node",    ctx);
            std::string command = require_field<std::string>(cd, "command", ctx);

            if (!node.empty() && node[0] == '@') {
                // The MeshCore source expanded @repeaters / @companions /
                // @all using NodeRole. Roles were stripped in the universal
                // port, so only @all remains. (Scripts can implement their
                // own routing/role concepts and target by name.)
                if (node == "@all") {
                    for (const auto& nd : cfg.nodes) {
                        SimConfig::CmdDef def;
                        def.at_ms   = at_ms;
                        def.node    = nd.name;
                        def.command = command;
                        cfg.commands.push_back(std::move(def));
                    }
                } else {
                    throw std::runtime_error(
                        "config error at " + ctx + ": unknown target group \""
                        + node + "\" (only @all is supported in the universal simulator)");
                }
            } else {
                SimConfig::CmdDef def;
                def.at_ms   = at_ms;
                def.node    = node;
                def.command = command;
                cfg.commands.push_back(std::move(def));
            }
        }
    }

    // NOTE: message_schedule and channel_schedule were stripped — they
    // expanded into MeshCore CLI commands (msg/msga/msgc). Periodic
    // generation can be done from a Lua script if needed.

    if (j.contains("expect")) {
        size_t ex_idx = 0;
        for (auto& ex : j["expect"]) {
            const std::string ctx = "expect[" + std::to_string(ex_idx++) + "]";
            SimConfig::Assertion a;
            a.type = require_field<std::string>(ex, "type", ctx);
            if (ex.contains("node"))        a.node        = ex["node"].get<std::string>();
            if (ex.contains("command"))     a.command     = ex["command"].get<std::string>();
            if (ex.contains("value"))       a.value       = ex["value"].get<std::string>();
            if (ex.contains("event_type"))  a.event_type  = ex["event_type"].get<std::string>();
            if (ex.contains("emit_type"))   a.emit_type   = ex["emit_type"].get<std::string>();
            if (ex.contains("count"))       a.count       = ex["count"].get<int>();
            if (ex.contains("min"))         a.min         = ex["min"].get<int>();
            if (ex.contains("max"))         a.max         = ex["max"].get<int>();
            if (ex.contains("time_ms_min")) a.time_ms_min = ex["time_ms_min"].get<long>();
            if (ex.contains("time_ms_max")) a.time_ms_max = ex["time_ms_max"].get<long>();
            cfg.assertions.push_back(std::move(a));
        }
    }

    return cfg;
}

// --- validation -----------------------------------------------------------

static void validateConfig(const SimConfig& cfg) {
    std::vector<std::string> errors;

    // §1.3 (2026-07-20 realism review): global radio sf/bw/cr/duty_cycle are REQUIRED. An omitted key
    // used to become a silent physics default (sf 8 / bw 62.5-MHz-as-kHz / cr 1 = outside [5..8]).
    // Sentinel (<0) = unset -> a named error, run refuses to start. (Per-link snr/snr_std_dev are
    // enforced in the link loop below.)
    if (cfg.simulation.radio.sf < 0)
        errors.push_back("simulation.radio.sf is required (spreading factor, 5..12)");
    if (cfg.simulation.radio.bw < 0)
        errors.push_back("simulation.radio.bw is required (kHz, authored as a double e.g. 62.5 or 125)");
    if (cfg.simulation.radio.cr < 0)
        errors.push_back("simulation.radio.cr is required (coding-rate multiplier 5..8; 5 = CR4/5)");

    // Simulation parameters
    if (cfg.simulation.step_ms <= 0)
        errors.push_back("simulation.step_ms must be > 0 (got "
                         + std::to_string(cfg.simulation.step_ms) + ")");
    if (cfg.simulation.duration_ms == 0)
        errors.push_back("simulation.duration_ms must be > 0");
    if (cfg.simulation.warmup_ms >= cfg.simulation.duration_ms && cfg.simulation.warmup_ms > 0)
        errors.push_back("simulation.warmup_ms (" + std::to_string(cfg.simulation.warmup_ms)
                         + ") must be < duration_ms ("
                         + std::to_string(cfg.simulation.duration_ms) + ")");
    if (cfg.simulation.radio.capture_locked_db < 0.0f)
        errors.push_back("simulation.radio.capture_locked_db must be >= 0 (got "
                         + std::to_string(cfg.simulation.radio.capture_locked_db) + ")");
    if (cfg.simulation.radio.capture_unlocked_db < 0.0f)
        errors.push_back("simulation.radio.capture_unlocked_db must be >= 0 (got "
                         + std::to_string(cfg.simulation.radio.capture_unlocked_db) + ")");
    if (cfg.simulation.radio.cad_miss_prob < 0.0f || cfg.simulation.radio.cad_miss_prob > 1.0f)
        errors.push_back("simulation.radio.cad_miss_prob must be [0.0, 1.0] (got "
                         + std::to_string(cfg.simulation.radio.cad_miss_prob) + ")");
    if (cfg.simulation.node_startup_jitter_ms < 0)
        errors.push_back("simulation.node_startup_jitter_ms must be >= 0 (got "
                         + std::to_string(cfg.simulation.node_startup_jitter_ms) + ")");
    if (cfg.simulation.radio.max_packet_bytes < 1
        || cfg.simulation.radio.max_packet_bytes > 65535)
        errors.push_back("simulation.radio.max_packet_bytes must be in [1, 65535] (got "
                         + std::to_string(cfg.simulation.radio.max_packet_bytes) + ")");
    if (cfg.simulation.radio.cad_reliable_snr < cfg.simulation.radio.cad_marginal_snr)
        errors.push_back("simulation.radio.cad_reliable_snr ("
                         + std::to_string(cfg.simulation.radio.cad_reliable_snr)
                         + ") must be >= cad_marginal_snr ("
                         + std::to_string(cfg.simulation.radio.cad_marginal_snr) + ")");
    if (cfg.simulation.radio.snr_coherence_ms < 0.0f)
        errors.push_back("simulation.radio.snr_coherence_ms must be >= 0 (got "
                         + std::to_string(cfg.simulation.radio.snr_coherence_ms) + ")");
    if (cfg.simulation.radio.lbt_model != "energy" && cfg.simulation.radio.lbt_model != "cad")
        errors.push_back("simulation.radio.lbt_model must be \"energy\" or \"cad\" (got \""
                         + cfg.simulation.radio.lbt_model + "\")");
    // §2.2 (2026-07-21 realism ruling): duty_cycle is a PERCENT (1 = 1%). Range (0, 100].
    if (cfg.simulation.radio.duty_cycle < 0.0f)
        errors.push_back("simulation.radio.duty_cycle is required (PERCENT in (0, 100], e.g. 1 = 1%)");
    else if (cfg.simulation.radio.duty_cycle == 0.0f
             || cfg.simulation.radio.duty_cycle > 100.0f)
        errors.push_back("simulation.radio.duty_cycle must be in (0, 100] PERCENT (got "
                         + std::to_string(cfg.simulation.radio.duty_cycle) + ")");
    if (cfg.simulation.radio.duty_cycle_window_ms == 0)
        errors.push_back("simulation.radio.duty_cycle_window_ms must be > 0");
    {
        const auto& m = cfg.simulation.path_loss.model;
        if (cfg.simulation.path_loss.present
            && m != "log_distance" && m != "none") {
            errors.push_back(
                "simulation.path_loss.model must be \"log_distance\" or "
                "\"none\" (got \"" + m + "\")");
        }
    }
    if (cfg.simulation.path_loss.frequency_mhz <= 0.0)
        errors.push_back("simulation.path_loss.frequency_mhz must be > 0 (got "
                         + std::to_string(cfg.simulation.path_loss.frequency_mhz) + ")");
    // §carrier: the global carrier the per-node inherit resolves against. requireIntegerKhz already
    // refuses a non-positive explicit value; this catches a bad DEFAULT (a future edit to the struct).
    if (cfg.simulation.radio.freq_khz <= 0)
        errors.push_back("simulation.radio.freq_khz must be > 0 kHz (got "
                         + std::to_string(cfg.simulation.radio.freq_khz) + ")");

    // Per-node lifecycle constraint validation. start/die at 0 means
    // "not scheduled"; if scheduled, must be in (0, duration_ms) and
    // start < die when both are set.
    {
        size_t i = 0;
        std::map<std::pair<int, int>, std::string> effective_node_ids;
        for (const auto& nd : cfg.nodes) {
            const std::string ctx = "nodes[" + std::to_string(i++) + "]";
            const int effective_node_id = nd.node_id >= 0
                ? nd.node_id
                : static_cast<int>(i - 1);
            int layer_id = 0;
            if (nd.config.is_object()) {
                if (nd.config.contains("layer_id") && nd.config["layer_id"].is_number_integer()) {
                    layer_id = nd.config["layer_id"].get<int>();
                } else if (nd.config.contains("leaf_id") && nd.config["leaf_id"].is_number_integer()) {
                    layer_id = nd.config["leaf_id"].get<int>();
                }
            }
            // node_id 0 is the UNPROVISIONED sentinel (a node that DAD-assigns its id at runtime) — many
            // such nodes legitimately share id 0 at config time, so it is exempt from the duplicate check.
            if (effective_node_id != 0) {
                auto [it, inserted] = effective_node_ids.emplace(
                    std::make_pair(layer_id, effective_node_id), nd.name);
                if (!inserted) {
                    errors.push_back(ctx + ".node_id/effective id ("
                        + std::to_string(effective_node_id)
                        + ") in layer " + std::to_string(layer_id)
                        + " duplicates node \"" + it->second + "\"");
                }
            }
            if (nd.start_at_ms > 0
                && nd.start_at_ms >= cfg.simulation.duration_ms) {
                errors.push_back(ctx + ".start_at_ms ("
                    + std::to_string(nd.start_at_ms)
                    + ") must be < duration_ms ("
                    + std::to_string(cfg.simulation.duration_ms) + ")");
            }
            if (nd.dies_at_ms > 0
                && nd.dies_at_ms >= cfg.simulation.duration_ms) {
                errors.push_back(ctx + ".dies_at_ms ("
                    + std::to_string(nd.dies_at_ms)
                    + ") must be < duration_ms ("
                    + std::to_string(cfg.simulation.duration_ms) + ")");
            }
            if (nd.start_at_ms > 0 && nd.dies_at_ms > 0
                && nd.start_at_ms >= nd.dies_at_ms) {
                errors.push_back(ctx + ".start_at_ms ("
                    + std::to_string(nd.start_at_ms)
                    + ") must be < dies_at_ms ("
                    + std::to_string(nd.dies_at_ms) + ")");
            }
            if (nd.antenna_height_m <= 0.0f) {
                errors.push_back(ctx + ".antenna_height_m must be > 0 (got "
                    + std::to_string(nd.antenna_height_m)
                    + "; ITM divides by antenna height — use 0.1 for"
                    + " a buried sensor instead of 0)");
            }
        }
    }

    // Build node name set for cross-validation.
    std::set<std::string> node_names;
    for (const auto& nd : cfg.nodes) node_names.insert(nd.name);

    // Per-node parameters.
    //
    // CR convention is RadioLib/MeshCore style: cr ∈ [5..8] is the
    // multiplier directly (5 = CR4/5, 8 = CR4/8). This is also what
    // SimRadio::getEstAirtimeFor expects post-fix (no +4 shift). Reject
    // values outside that range so airtimes can't silently be off.
    for (const auto& nd : cfg.nodes) {
        const std::string pfx = "node \"" + nd.name + "\": ";
        if (nd.sf <= 0)
            errors.push_back(pfx + "sf must be > 0 (got " + std::to_string(nd.sf) + ")");
        if (nd.bw <= 0)
            errors.push_back(pfx + "bw must be > 0 (got " + std::to_string(nd.bw) + ")");
        if (nd.cr < 5 || nd.cr > 8)
            errors.push_back(pfx + "cr must be in [5..8] (5=CR4/5, 8=CR4/8); got "
                             + std::to_string(nd.cr));
        // §carrier: post-merge every node MUST carry a positive carrier — it seeds the live tuned
        // frequency the reachability gate compares. FAIL LOUD; the gate has no fallback (a 0 could
        // never equal a real frame carrier, so the node would be silently, totally deaf).
        if (nd.freq_khz <= 0)
            errors.push_back(pfx + "freq_khz must be > 0 kHz (got "
                             + std::to_string(nd.freq_khz) + ")");
        if (nd.tx_fail_prob < 0.0f || nd.tx_fail_prob > 1.0f)
            errors.push_back(pfx + "tx_fail_prob must be [0.0, 1.0] (got "
                             + std::to_string(nd.tx_fail_prob) + ")");
    }

    // NOTE: firmware-name validation was stripped (no fw_* convention here).

    // Link cross-validation.
    for (const auto& lk : cfg.topology.links) {
        if (node_names.find(lk.from) == node_names.end())
            errors.push_back("link from \"" + lk.from + "\" references unknown node");
        if (node_names.find(lk.to) == node_names.end())
            errors.push_back("link to \"" + lk.to + "\" references unknown node");
        // §1.3: per-link snr + snr_std_dev are REQUIRED (NaN sentinel = unset). An omitted snr used to
        // become a silent healthy 8 dB link; an omitted snr_std_dev silently disabled fading.
        if (std::isnan(lk.snr))
            errors.push_back("link " + lk.from + " -> " + lk.to + ": snr is required (dB)");
        if (std::isnan(lk.snr_std_dev))
            errors.push_back("link " + lk.from + " -> " + lk.to
                             + ": snr_std_dev is required (dB; 0 = no fading)");
        if (lk.loss < 0.0f || lk.loss > 1.0f)
            errors.push_back("link " + lk.from + " -> " + lk.to
                             + ": loss must be [0.0, 1.0] (got "
                             + std::to_string(lk.loss) + ")");
    }

    // Command cross-validation (skip lua-only commands).
    for (const auto& cd : cfg.commands) {
        if (!cd.lua_fn.empty()) continue;  // lua commands don't reference nodes
        if (node_names.find(cd.node) == node_names.end())
            errors.push_back("command at " + std::to_string(cd.at_ms)
                             + "ms references unknown node \"" + cd.node + "\"");
    }

    // Forced-drop cross-validation (empty from/to == wildcard, skip those).
    for (const auto& dd : cfg.drop_directives) {
        if (!dd.from.empty() && node_names.find(dd.from) == node_names.end())
            errors.push_back("forced_drop from \"" + dd.from + "\" references unknown node");
        if (!dd.to.empty() && node_names.find(dd.to) == node_names.end())
            errors.push_back("forced_drop to \"" + dd.to + "\" references unknown node");
    }

    if (!errors.empty()) {
        std::string msg = "Config validation failed (" + std::to_string(errors.size())
                          + " error(s)):";
        for (const auto& e : errors) msg += "\n  - " + e;
        throw std::runtime_error(msg);
    }
}

// --- public API -----------------------------------------------------------

namespace JsonConfig {

SimConfig loadFromFile(const std::string& path) {
    std::ifstream f(path);
    if (!f.is_open()) {
        throw std::runtime_error("Cannot open config file: " + path);
    }
    json j = json::parse(f);
    auto cfg = parseJson(j);
    validateConfig(cfg);
    // Record the absolute path so downstream code can resolve relative
    // references (e.g. nodes[i].script) against the config's directory.
    std::error_code ec;
    auto abs = std::filesystem::absolute(path, ec);
    cfg.source_path = ec ? path : abs.string();
    return cfg;
}

SimConfig loadFromString(const std::string& json_str) {
    json j = json::parse(json_str);
    auto cfg = parseJson(j);
    validateConfig(cfg);
    return cfg;
}

}  // namespace JsonConfig
