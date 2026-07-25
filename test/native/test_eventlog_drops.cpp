// test/native/test_eventlog_drops.cpp
//
// Wire-format pin for ALL ELEVEN drop_* emitters.
//
// Why this exists: the scenario suite only ever fires FIVE of them
// (drop_sf_mismatch / drop_weak / drop_preamble_miss / drop_rx_blind /
// drop_halfduplex). drop_loss, drop_no_link, drop_receiver_inactive,
// drop_forced and drop_bw_mismatch never appear in any baseline stream, so
// scenario byte-identity proves NOTHING about them — including across the
// dropCommon()/DropLine refactor that rewrote all ten bodies (and, since
// 2026-07-25, drop_tx_settling — the TX->RX-turnaround twin of
// drop_halfduplex, which no scenario fired before that slice either). This test is
// the missing half of that proof: each emitter's exact NDJSON line, field
// order included, asserted verbatim.
//
// It also pins the three shape carve-outs that make the shared builder
// non-trivial and would otherwise rot silently:
//   - drop_weak / drop_loss carry NO "airtime_ms"
//   - drop_sf_mismatch carries "packet_sf" and NO "sf"
//   - drop_bw_mismatch carries "packet_bw_hz" and NO "bw_hz"
// plus the optional label/info tail (present, absent, and JSON-escaped).

#include "core/events/EventLog.h"

#include <cassert>
#include <cstdio>
#include <cstdint>
#include <sstream>
#include <string>
#include <vector>

namespace {

std::ostringstream g_out;

// Emit one event, return the exact line it produced (newline stripped).
template <typename F>
std::string emitted(F&& f) {
    g_out.str("");
    g_out.clear();
    f();
    std::string s = g_out.str();
    assert(!s.empty() && "emitter produced no output");
    assert(s.back() == '\n' && "line must end in a newline");
    s.pop_back();
    assert(s.find('\n') == std::string::npos && "emitter produced >1 line");
    return s;
}

void expect(const std::string& got, const std::string& want) {
    if (got != want) {
        std::fprintf(stderr, "\nWIRE MISMATCH\n  want: %s\n  got:  %s\n",
                     want.c_str(), got.c_str());
        assert(false && "drop_* wire format changed");
    }
}

}  // namespace

int main() {
    EventLog::setOutputStream(&g_out);

    // FNV-1a of {0xab,0xcd} — the "pkt" fingerprint every drop_* line carries.
    const uint8_t p[] = {0xab, 0xcd};
    const int     n   = (int)sizeof(p);
    const char*   kPkt = "e3a027a5";

    // Sanity-pin the hash itself first: every golden line below embeds it, so
    // a packetHash change must fail HERE with a clear message rather than
    // scattering nine confusing diffs.
    {
        const std::string l = emitted([&] {
            EventLog::dropHalfDuplex(1, "a", "b", p, n, 120, 7, 125000);
        });
        assert(l.find(std::string("\"pkt\":\"") + kPkt + "\"") != std::string::npos
               && "packetHash of {0xab,0xcd} changed — update kPkt");
    }

    // ---- 1. drop_rx_blind: blind_until_ms middle, full PHY tail ------------
    expect(emitted([&] {
        EventLog::dropRxBlind(1000, "alice", "bob", 1234567890123ULL,
                              p, n, 120, 7, 125000);
    }),
    "{\"type\":\"drop_rx_blind\",\"time_ms\":1000,\"from\":\"alice\",\"to\":\"bob\","
    "\"blind_until_ms\":1234567890123,\"pkt\":\"e3a027a5\",\"airtime_ms\":120,"
    "\"sf\":7,\"bw_hz\":125000}");

    // ---- 2. drop_preamble_miss: %.3f probability --------------------------
    expect(emitted([&] {
        EventLog::dropPreambleMiss(1001, "alice", "bob", 0.02f,
                                   p, n, 121, 8, 250000);
    }),
    "{\"type\":\"drop_preamble_miss\",\"time_ms\":1001,\"from\":\"alice\",\"to\":\"bob\","
    "\"miss_prob\":0.020,\"pkt\":\"e3a027a5\",\"airtime_ms\":121,"
    "\"sf\":8,\"bw_hz\":250000}");

    // ---- 3. drop_halfduplex: no middle at all -----------------------------
    expect(emitted([&] {
        EventLog::dropHalfDuplex(1002, "alice", "bob", p, n, 122, 9, 62500);
    }),
    "{\"type\":\"drop_halfduplex\",\"time_ms\":1002,\"from\":\"alice\",\"to\":\"bob\","
    "\"pkt\":\"e3a027a5\",\"airtime_ms\":122,\"sf\":9,\"bw_hz\":62500}");

    // ---- 3b. drop_tx_settling: drop_halfduplex's TX->RX-turnaround twin ----
    // §tx-turnaround (2026-07-25). Deliberately a SEPARATE event from
    // drop_halfduplex — "was still transmitting" and "was still coming back
    // from transmitting" are different hardware mechanisms, and a stream that
    // merged them could attribute neither. Shaped like drop_rx_blind (the other
    // settling-window drop): one uint64 absolute "receptive again at" field
    // ahead of the shared PHY tail.
    expect(emitted([&] {
        EventLog::dropTxSettling(1017, "alice", "bob",
                                 /*deaf_until_ms=*/1234567890124ull,
                                 p, n, 131, 10, 250000);
    }),
    "{\"type\":\"drop_tx_settling\",\"time_ms\":1017,\"from\":\"alice\",\"to\":\"bob\","
    "\"deaf_until_ms\":1234567890124,\"pkt\":\"e3a027a5\",\"airtime_ms\":131,"
    "\"sf\":10,\"bw_hz\":250000}");

    // ---- 4. drop_weak: CARRIES NO airtime_ms ------------------------------
    {
        const std::string l = emitted([&] {
            EventLog::dropWeak(1003, "alice", "bob", -9.25f, -7.5f, p, n, 7, 125000);
        });
        expect(l,
        "{\"type\":\"drop_weak\",\"time_ms\":1003,\"from\":\"alice\",\"to\":\"bob\","
        "\"snr\":-9.2,\"threshold\":-7.5,\"pkt\":\"e3a027a5\","
        "\"sf\":7,\"bw_hz\":125000}");
        assert(l.find("airtime_ms") == std::string::npos);
    }

    // ---- 5. drop_loss: CARRIES NO airtime_ms ------------------------------
    {
        const std::string l = emitted([&] {
            EventLog::dropLoss(1004, "alice", "bob", 0.125f, p, n, 10, 125000);
        });
        expect(l,
        "{\"type\":\"drop_loss\",\"time_ms\":1004,\"from\":\"alice\",\"to\":\"bob\","
        "\"loss\":0.125,\"pkt\":\"e3a027a5\",\"sf\":10,\"bw_hz\":125000}");
        assert(l.find("airtime_ms") == std::string::npos);
    }

    // ---- 6. drop_receiver_inactive: escaped reason + label + info ---------
    expect(emitted([&] {
        EventLog::dropReceiverInactive(1005, "alice", "bob", "node_not_alive",
                                       p, n, 123, 7, 125000, "RTS", "next=bob");
    }),
    "{\"type\":\"drop_receiver_inactive\",\"time_ms\":1005,\"from\":\"alice\",\"to\":\"bob\","
    "\"reason\":\"node_not_alive\",\"pkt\":\"e3a027a5\",\"airtime_ms\":123,"
    "\"sf\":7,\"bw_hz\":125000,\"label\":\"RTS\",\"info\":\"next=bob\"}");

    // Escaping goes through json_escape on reason AND on the optional text.
    expect(emitted([&] {
        EventLog::dropReceiverInactive(1006, "alice", "bob", "we\"ird\\reason",
                                       p, n, 123, 7, 125000, "RTS", "a\"b\tc");
    }),
    "{\"type\":\"drop_receiver_inactive\",\"time_ms\":1006,\"from\":\"alice\",\"to\":\"bob\","
    "\"reason\":\"we\\\"ird\\\\reason\",\"pkt\":\"e3a027a5\",\"airtime_ms\":123,"
    "\"sf\":7,\"bw_hz\":125000,\"label\":\"RTS\",\"info\":\"a\\\"b\\tc\"}");

    // ---- 7. drop_no_link: optional tail present, then fully absent --------
    expect(emitted([&] {
        EventLog::dropNoLink(1007, "alice", "bob", p, n, 124, 7, 125000,
                             "RTS-fwd", "next=bob");
    }),
    "{\"type\":\"drop_no_link\",\"time_ms\":1007,\"from\":\"alice\",\"to\":\"bob\","
    "\"pkt\":\"e3a027a5\",\"airtime_ms\":124,\"sf\":7,\"bw_hz\":125000,"
    "\"label\":\"RTS-fwd\",\"info\":\"next=bob\"}");

    // nullptr label/info AND empty-string label/info must both emit nothing.
    {
        const std::string with_null = emitted([&] {
            EventLog::dropNoLink(1008, "alice", "bob", p, n, 124, 7, 125000,
                                 nullptr, nullptr);
        });
        expect(with_null,
        "{\"type\":\"drop_no_link\",\"time_ms\":1008,\"from\":\"alice\",\"to\":\"bob\","
        "\"pkt\":\"e3a027a5\",\"airtime_ms\":124,\"sf\":7,\"bw_hz\":125000}");
        const std::string with_empty = emitted([&] {
            EventLog::dropNoLink(1008, "alice", "bob", p, n, 124, 7, 125000, "", "");
        });
        expect(with_empty, with_null);
    }

    // ---- 8. drop_forced: label only (no info parameter) -------------------
    expect(emitted([&] {
        EventLog::dropForced(1009, "alice", "bob", p, n, 125, 7, 125000, "DATA");
    }),
    "{\"type\":\"drop_forced\",\"time_ms\":1009,\"from\":\"alice\",\"to\":\"bob\","
    "\"pkt\":\"e3a027a5\",\"airtime_ms\":125,\"sf\":7,\"bw_hz\":125000,"
    "\"label\":\"DATA\"}");
    expect(emitted([&] {
        EventLog::dropForced(1010, "alice", "bob", p, n, 125, 7, 125000, nullptr);
    }),
    "{\"type\":\"drop_forced\",\"time_ms\":1010,\"from\":\"alice\",\"to\":\"bob\","
    "\"pkt\":\"e3a027a5\",\"airtime_ms\":125,\"sf\":7,\"bw_hz\":125000}");

    // ---- 9. drop_sf_mismatch: packet_sf/rx_sf, %.2f pair, NO "sf" ---------
    {
        const std::string l = emitted([&] {
            EventLog::dropSfMismatch(1011, "alice", "bob", /*packet_sf=*/9,
                                     /*rx_sf=*/7, 8.0f, -80.0f, p, n, 126, 125000);
        });
        expect(l,
        "{\"type\":\"drop_sf_mismatch\",\"time_ms\":1011,\"from\":\"alice\",\"to\":\"bob\","
        "\"packet_sf\":9,\"rx_sf\":7,\"snr_db\":8.00,\"rssi_dbm\":-80.00,"
        "\"pkt\":\"e3a027a5\",\"airtime_ms\":126,\"bw_hz\":125000}");
        assert(l.find("\"sf\":") == std::string::npos);   // packet_sf, never "sf"
    }
    // rx_sf == -1 is the documented multi-SF/scanner flag, not an omission.
    expect(emitted([&] {
        EventLog::dropSfMismatch(1012, "alice", "bob", 9, -1, 8.0f, -80.0f,
                                 p, n, 126, 125000);
    }),
    "{\"type\":\"drop_sf_mismatch\",\"time_ms\":1012,\"from\":\"alice\",\"to\":\"bob\","
    "\"packet_sf\":9,\"rx_sf\":-1,\"snr_db\":8.00,\"rssi_dbm\":-80.00,"
    "\"pkt\":\"e3a027a5\",\"airtime_ms\":126,\"bw_hz\":125000}");

    // ---- 10. drop_bw_mismatch: packet_bw_hz/rx_bw_hz, NO "bw_hz" ----------
    {
        const std::string l = emitted([&] {
            EventLog::dropBwMismatch(1013, "alice", "bob",
                                     /*packet_bw_hz=*/125000, /*rx_bw_hz=*/250000,
                                     8.0f, -80.0f, p, n, 127, /*sf=*/7);
        });
        expect(l,
        "{\"type\":\"drop_bw_mismatch\",\"time_ms\":1013,\"from\":\"alice\",\"to\":\"bob\","
        "\"packet_bw_hz\":125000,\"rx_bw_hz\":250000,\"snr_db\":8.00,\"rssi_dbm\":-80.00,"
        "\"pkt\":\"e3a027a5\",\"airtime_ms\":127,\"sf\":7}");
        assert(l.find("\"bw_hz\":") == std::string::npos);  // packet_bw_hz, never "bw_hz"
    }
    // The reverse direction (narrow receiver, wide frame) is the same shape.
    expect(emitted([&] {
        EventLog::dropBwMismatch(1014, "alice", "bob", 250000, 62500,
                                 -3.5f, -110.25f, p, n, 40, 8);
    }),
    "{\"type\":\"drop_bw_mismatch\",\"time_ms\":1014,\"from\":\"alice\",\"to\":\"bob\","
    "\"packet_bw_hz\":250000,\"rx_bw_hz\":62500,\"snr_db\":-3.50,\"rssi_dbm\":-110.25,"
    "\"pkt\":\"e3a027a5\",\"airtime_ms\":40,\"sf\":8}");

    // ---- 11. overflow semantics: all-or-nothing, ALWAYS terminated --------
    // Unreachable from the corpus (the longest `label` ever emitted is "DATA"
    // and the longest NDJSON line of any type is ~1.5 kB against a 2 kB
    // buffer), but the shared builder must not be able to emit a half-written
    // field or — worse — an unterminated line that MERGES with the next event
    // and corrupts the stream. A field that does not fit whole is dropped
    // whole; the closing brace is always reserved.
    {
        // A single optional VALUE is capped at 1023 chars by json_escape's
        // esc[1024] scratch buffer. That cap is PRE-EXISTING (the old
        // append_optional_text_field escaped through the same 1024 buffer) and
        // is deliberately preserved — pinned here so it is a decision on
        // record rather than a surprise.
        const std::string over_cap(2000, 'X');
        const std::string capped = emitted([&] {
            EventLog::dropForced(1015, "alice", "bob", p, n, 129, 7, 125000,
                                 over_cap.c_str());
        });
        expect(capped,
        "{\"type\":\"drop_forced\",\"time_ms\":1015,\"from\":\"alice\",\"to\":\"bob\","
        "\"pkt\":\"e3a027a5\",\"airtime_ms\":129,\"sf\":7,\"bw_hz\":125000,"
        "\"label\":\"" + std::string(1023, 'X') + "\"}");

        // Two 1000-char values: the label fits the line budget, the info
        // cannot. The label must appear WHOLE, the info must be absent
        // ENTIRELY (never half-written), and the line must still close.
        const std::string big(1000, 'L');
        const std::string l = emitted([&] {
            EventLog::dropNoLink(1016, "alice", "bob", p, n, 128, 7, 125000,
                                 big.c_str(), big.c_str());
        });
        assert(l.back() == '}' && "a drop_* line must always be terminated");
        assert(l.find("\"label\":\"" + big + "\"") != std::string::npos
               && "the label that fits must be written WHOLE");
        assert(l.find("\"info\"") == std::string::npos
               && "the field that cannot fit must be dropped whole, not truncated");
        // The mandatory prefix + PHY tail survive intact and nothing is
        // written past the brace.
        assert(l.find("{\"type\":\"drop_no_link\",\"time_ms\":1016,"
                      "\"from\":\"alice\",\"to\":\"bob\",\"pkt\":\"e3a027a5\","
                      "\"airtime_ms\":128,\"sf\":7,\"bw_hz\":125000,") == 0);
        assert(l.size() < 2048 && "the line must stay inside the emit buffer");
    }

    EventLog::setOutputStream(nullptr);
    std::printf("test_eventlog_drops: OK (all 11 drop_* wire formats pinned, "
                "overflow all-or-nothing + always terminated)\n");
    return 0;
}
