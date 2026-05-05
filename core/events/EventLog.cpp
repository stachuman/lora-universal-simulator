#include "core/events/EventLog.h"

#include <cstring>
#include <cstdio>
#include <ostream>

static const char HEX[] = "0123456789abcdef";

static void to_hex(char* out, const uint8_t* in, int len) {
    for (int i = 0; i < len; i++) {
        out[i*2]     = HEX[in[i] >> 4];
        out[i*2 + 1] = HEX[in[i] & 0x0F];
    }
    out[len*2] = '\0';
}

static void json_escape(char* out, size_t out_sz, const char* in) {
    char* dp = out;
    char* end = out + out_sz - 1;
    for (const char* sp = in; *sp && dp < end; sp++) {
        if (*sp == '"' || *sp == '\\') {
            if (dp + 1 >= end) break;
            *dp++ = '\\';
            *dp++ = *sp;
        } else if (*sp == '\n') {
            if (dp + 1 >= end) break;
            *dp++ = '\\'; *dp++ = 'n';
        } else if (*sp == '\t') {
            if (dp + 1 >= end) break;
            *dp++ = '\\'; *dp++ = 't';
        } else {
            *dp++ = *sp;
        }
    }
    *dp = '\0';
}

// MeshCore-specific packet-header decoders (decodePayloadType / decodeRouteType)
// from meshcore_real_sim were dropped here: they decoded MeshCore's packed
// header byte (route type in bits 1-0, payload type in bits 5-2) into labels
// like "advert", "msg", "ack", "flood", "direct", etc. The universal simulator
// is protocol-agnostic, so tx/rx events now only carry the FNV fingerprint
// and (for tx) the raw hex dump. Adapters that need protocol-specific labels
// should emit their own NDJSON lines or wrap these calls.
// TODO Y2: revisit if a generic "kind" field is wanted at the core level.

namespace EventLog {

static EventHook s_event_hook;
static std::ostream* s_out_stream = nullptr;  // nullptr == stdout

void setOutputStream(std::ostream* os) {
    s_out_stream = os;
}

void setEventHook(EventHook hook) {
    s_event_hook = std::move(hook);
}

static void emitLine(const char* line) {
    if (s_out_stream) {
        (*s_out_stream) << line;
    } else {
        fputs(line, stdout);
    }
    if (s_event_hook) {
        s_event_hook(std::string(line));
    }
}

uint32_t packetHash(const uint8_t* data, int len) {
    uint32_t h = 0x811c9dc5u;
    for (int i = 0; i < len; i++) {
        h ^= data[i];
        h *= 0x01000193u;
    }
    return h;
}

void packetHashHex(char out[9], const uint8_t* data, int len) {
    uint32_t h = packetHash(data, len);
    for (int i = 7; i >= 0; i--) {
        out[i] = HEX[h & 0x0F];
        h >>= 4;
    }
    out[8] = '\0';
}

void simStart(unsigned long time_ms, int n_nodes, int step_ms,
              unsigned long warmup_ms, bool hot_start) {
    char buf[2048];
    snprintf(buf, sizeof(buf),
        "{\"type\":\"sim_start\",\"time_ms\":%lu,\"n_nodes\":%d,\"step_ms\":%d,"
        "\"warmup_ms\":%lu,\"hot_start\":%s}\n",
        time_ms, n_nodes, step_ms, warmup_ms, hot_start ? "true" : "false");
    emitLine(buf);
}

void simEnd(unsigned long time_ms) {
    char buf[2048];
    snprintf(buf, sizeof(buf), "{\"type\":\"sim_end\",\"time_ms\":%lu}\n", time_ms);
    emitLine(buf);
}

void nodeReady(unsigned long time_ms, const char* node, const char* role,
               const uint8_t* pub_key, int key_len,
               bool has_location, double lat, double lon,
               const char* firmware) {
    char hex[128];
    if (key_len > 63) key_len = 63;
    to_hex(hex, pub_key, key_len);
    char buf[2048];
    char loc_part[64] = "";
    if (has_location)
        snprintf(loc_part, sizeof(loc_part), ",\"lat\":%.6f,\"lon\":%.6f", lat, lon);
    char fw_part[128] = "";
    if (firmware)
        snprintf(fw_part, sizeof(fw_part), ",\"firmware\":\"%s\"", firmware);
    snprintf(buf, sizeof(buf),
        "{\"type\":\"node_ready\",\"time_ms\":%lu,\"node\":\"%s\",\"role\":\"%s\","
        "\"pub\":\"%s\"%s%s}\n",
        time_ms, node, role, hex, loc_part, fw_part);
    emitLine(buf);
}

void tx(unsigned long time_ms, const char* node,
        const uint8_t* data, int len, uint32_t airtime_ms) {
    char hex[512 * 2 + 1];
    char pkt[9];
    if (len > 512) len = 512;
    to_hex(hex, data, len);
    packetHashHex(pkt, data, len);
    char buf[4096];
    snprintf(buf, sizeof(buf),
        "{\"type\":\"tx\",\"time_ms\":%lu,\"node\":\"%s\",\"pkt\":\"%s\","
        "\"hex\":\"%s\",\"airtime_ms\":%u}\n",
        time_ms, node, pkt, hex, (unsigned)airtime_ms);
    emitLine(buf);
}

void rx(unsigned long time_ms, const char* from, const char* to,
        float snr, float rssi,
        const uint8_t* data, int len, uint32_t airtime_ms) {
    char pkt[9];
    packetHashHex(pkt, data, len);
    char buf[4096];
    if (airtime_ms > 0) {
        snprintf(buf, sizeof(buf),
            "{\"type\":\"rx\",\"time_ms\":%lu,\"from\":\"%s\",\"to\":\"%s\","
            "\"snr\":%.1f,\"rssi\":%.1f,\"pkt\":\"%s\",\"airtime_ms\":%u}\n",
            time_ms, from, to, snr, rssi, pkt, (unsigned)airtime_ms);
    } else {
        snprintf(buf, sizeof(buf),
            "{\"type\":\"rx\",\"time_ms\":%lu,\"from\":\"%s\",\"to\":\"%s\","
            "\"snr\":%.1f,\"rssi\":%.1f,\"pkt\":\"%s\"}\n",
            time_ms, from, to, snr, rssi, pkt);
    }
    emitLine(buf);
}

void cmdReply(unsigned long time_ms, const char* node,
              const char* command, const char* reply) {
    char esc_cmd[512], esc_reply[1024];
    json_escape(esc_cmd, sizeof(esc_cmd), command);
    json_escape(esc_reply, sizeof(esc_reply), reply);
    char buf[2048];
    snprintf(buf, sizeof(buf),
        "{\"type\":\"cmd_reply\",\"time_ms\":%lu,\"node\":\"%s\","
        "\"command\":\"%s\",\"reply\":\"%s\"}\n",
        time_ms, node, esc_cmd, esc_reply);
    emitLine(buf);
}

void collision(unsigned long time_ms, const char* from, const char* to,
               float snr, float rssi,
               const uint8_t* data, int len,
               const char* interferer, float interferer_snr, float snr_margin) {
    char pkt[9];
    packetHashHex(pkt, data, len);
    char buf[2048];
    if (interferer) {
        snprintf(buf, sizeof(buf),
            "{\"type\":\"collision\",\"time_ms\":%lu,\"from\":\"%s\",\"to\":\"%s\","
            "\"snr\":%.1f,\"rssi\":%.1f,\"pkt\":\"%s\","
            "\"interferer\":\"%s\",\"interferer_snr\":%.1f,\"snr_margin\":%.1f}\n",
            time_ms, from, to, snr, rssi, pkt,
            interferer, interferer_snr, snr_margin);
    } else {
        snprintf(buf, sizeof(buf),
            "{\"type\":\"collision\",\"time_ms\":%lu,\"from\":\"%s\",\"to\":\"%s\","
            "\"snr\":%.1f,\"rssi\":%.1f,\"pkt\":\"%s\"}\n",
            time_ms, from, to, snr, rssi, pkt);
    }
    emitLine(buf);
}

void dropHalfDuplex(unsigned long time_ms, const char* from, const char* to,
                    const uint8_t* data, int len, uint32_t airtime_ms) {
    char pkt[9];
    packetHashHex(pkt, data, len);
    char buf[2048];
    if (airtime_ms > 0) {
        snprintf(buf, sizeof(buf),
            "{\"type\":\"drop_halfduplex\",\"time_ms\":%lu,\"from\":\"%s\",\"to\":\"%s\","
            "\"pkt\":\"%s\",\"airtime_ms\":%u}\n",
            time_ms, from, to, pkt, (unsigned)airtime_ms);
    } else {
        snprintf(buf, sizeof(buf),
            "{\"type\":\"drop_halfduplex\",\"time_ms\":%lu,\"from\":\"%s\",\"to\":\"%s\","
            "\"pkt\":\"%s\"}\n",
            time_ms, from, to, pkt);
    }
    emitLine(buf);
}

void dropWeak(unsigned long time_ms, const char* from, const char* to,
              float snr, float threshold,
              const uint8_t* data, int len) {
    char pkt[9];
    packetHashHex(pkt, data, len);
    char buf[2048];
    snprintf(buf, sizeof(buf),
        "{\"type\":\"drop_weak\",\"time_ms\":%lu,\"from\":\"%s\",\"to\":\"%s\","
        "\"snr\":%.1f,\"threshold\":%.1f,\"pkt\":\"%s\"}\n",
        time_ms, from, to, snr, threshold, pkt);
    emitLine(buf);
}

void dropLoss(unsigned long time_ms, const char* from, const char* to,
              float loss_prob,
              const uint8_t* data, int len) {
    char pkt[9];
    packetHashHex(pkt, data, len);
    char buf[2048];
    snprintf(buf, sizeof(buf),
        "{\"type\":\"drop_loss\",\"time_ms\":%lu,\"from\":\"%s\",\"to\":\"%s\","
        "\"loss\":%.3f,\"pkt\":\"%s\"}\n",
        time_ms, from, to, loss_prob, pkt);
    emitLine(buf);
}

void nodeStats(unsigned long time_ms, const char* node,
               const char* stats_type, const char* json_data) {
    char buf[4096];
    snprintf(buf, sizeof(buf),
        "{\"type\":\"node_stats\",\"time_ms\":%lu,\"node\":\"%s\","
        "\"stats_type\":\"%s\",\"data\":%s}\n",
        time_ms, node, stats_type, json_data);
    emitLine(buf);
}

void txFail(unsigned long time_ms, const char* node, uint32_t count) {
    char buf[2048];
    snprintf(buf, sizeof(buf),
        "{\"type\":\"tx_fail\",\"time_ms\":%lu,\"node\":\"%s\",\"count\":%u}\n",
        time_ms, node, (unsigned)count);
    emitLine(buf);
}

void luaCallback(unsigned long time_ms, const char* fn_name) {
    char fn_esc[256];
    json_escape(fn_esc, sizeof(fn_esc), fn_name);
    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"type\":\"lua_callback\",\"time_ms\":%lu,\"function\":\"%s\"}\n",
        time_ms, fn_esc);
    emitLine(buf);
}

// --- script-side events ------------------------------------------------

void logScriptLog(int node_id, uint64_t sim_ms, const std::string& msg) {
    // JSON-escape the message in a heap-friendly way; reuse json_escape with
    // a sized stack buffer (truncates at 4 KiB which is plenty for a log line).
    char esc[4096];
    json_escape(esc, sizeof(esc), msg.c_str());
    char buf[4352];
    snprintf(buf, sizeof(buf),
        "{\"type\":\"script_log\",\"node\":%d,\"time_ms\":%llu,\"msg\":\"%s\"}\n",
        node_id, (unsigned long long)sim_ms, esc);
    emitLine(buf);
}

void logScriptEmit(int node_id, uint64_t sim_ms,
                   const std::string& type, const std::string& json_data) {
    // `type` goes in a JSON string field, so it must be escaped.
    // `json_data` is already-serialized JSON and is spliced verbatim into
    // the `data` field (it may be an object, array, number, string, etc.).
    char esc_type[512];
    json_escape(esc_type, sizeof(esc_type), type.c_str());

    // We stream rather than snprintf so we don't need a fixed-size buffer
    // big enough for an arbitrarily large json_data payload.
    if (s_out_stream) {
        (*s_out_stream)
            << "{\"type\":\"script_emit\",\"node\":" << node_id
            << ",\"time_ms\":" << (unsigned long long)sim_ms
            << ",\"emit_type\":\"" << esc_type << "\""
            << ",\"data\":" << json_data << "}\n";
    } else {
        std::fprintf(stdout,
            "{\"type\":\"script_emit\",\"node\":%d,\"time_ms\":%llu,"
            "\"emit_type\":\"%s\",\"data\":%s}\n",
            node_id, (unsigned long long)sim_ms, esc_type, json_data.c_str());
    }
    if (s_event_hook) {
        std::string line;
        line.reserve(64 + json_data.size());
        line.append("{\"type\":\"script_emit\",\"node\":");
        line.append(std::to_string(node_id));
        line.append(",\"time_ms\":");
        line.append(std::to_string((unsigned long long)sim_ms));
        line.append(",\"emit_type\":\"");
        line.append(esc_type);
        line.append("\",\"data\":");
        line.append(json_data);
        line.append("}\n");
        s_event_hook(line);
    }
}

} // namespace EventLog
