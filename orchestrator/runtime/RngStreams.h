// orchestrator/runtime/RngStreams.h
// Author: Stanislaw Kozicki <cgpsmapper@gmail.com>
//
// Per-stream RNG derivation for the simulator (Wave-4 Slice C).
//
// The engine used to feed EVERY stochastic consumer — path loss, fading, PER
// sigmoid, preamble-miss, per-link loss, clock drift, startup jitter AND every
// node's firmware `simRandRange` — from ONE shared std::mt19937 seeded off the
// scenario seed. That made the draw ORDER load-bearing: a single extra draw
// anywhere (e.g. one more protocol reflood) reshuffled every downstream draw,
// so an unrelated assertion could phantom-flip. Real radios are independent;
// the coupling was itself a sim-vs-metal divergence.
//
// This header derives INDEPENDENT streams from the scenario seed + a domain
// tag + an index, so that:
//   (1) the same (seed, domain, index) ALWAYS yields the same stream —
//       reproducible per scenario seed (resume/re-run identical); the scenario
//       `seed` stays the single knob that reseeds everything;
//   (2) distinct (domain, index) yield statistically-independent streams — a
//       draw in one stream can NEVER perturb another. A node's runtime draw
//       count no longer shifts any other node's stream or the physics stream.
//
// Derivation: boost::hash_combine-style folding of the tag and index into the
// base seed, then the splitmix64 finalizer for strong avalanche, then fold the
// 64-bit result into mt19937's 32-bit seed. splitmix64 is the standard
// "seed one PRNG from another" mixer (Vigna); it de-correlates nearby indices
// (0,1,2,…) that a raw std::mt19937(index) would leave visibly correlated.

#pragma once

#include <cstdint>
#include <random>

namespace mrsim {

// Domain tags — ASCII mnemonics, kept distinct so two stream families never
// alias even at the same index. Values are arbitrary but must stay STABLE
// (changing one silently re-anchors every scenario).
enum class RngDomain : uint64_t {
    Node     = 0x4E4F4445ull,  // "NODE" — per-node behaviour + timing profile
    Link     = 0x4C494E4Bull,  // "LINK" — per-directed-link physics rolls
    PathLoss = 0x50415448ull,  // "PATH" — path-loss offset/shadow draws
    TxFail   = 0x5458464Cull,  // "TXFL" — per-node modem TX-failure rolls
                               //   (nodes[].tx_fail_prob). Its OWN domain
                               //   rather than Node, so switching a node's
                               //   tx_fail_prob on cannot shift that same
                               //   node's firmware/timing draws.
};

// Fold (seed, domain, index) into a 64-bit stream seed.
inline uint64_t deriveSeed(uint64_t seed, RngDomain domain, uint64_t index) {
    uint64_t s = seed;
    auto combine = [&s](uint64_t v) {
        s ^= v + 0x9E3779B97F4A7C15ull + (s << 6) + (s >> 2);
    };
    combine(static_cast<uint64_t>(domain));
    combine(index);
    // splitmix64 finalizer.
    uint64_t z = s + 0x9E3779B97F4A7C15ull;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}

// Build an independent std::mt19937 for (seed, domain, index). The 64-bit
// derived seed is folded to mt19937's 32-bit seed word (high⊕low) so the whole
// derivation still influences the state.
inline std::mt19937 makeStream(uint64_t seed, RngDomain domain, uint64_t index) {
    const uint64_t z = deriveSeed(seed, domain, index);
    return std::mt19937(
        static_cast<std::mt19937::result_type>((z >> 32) ^ (z & 0xFFFFFFFFull)));
}

}  // namespace mrsim
