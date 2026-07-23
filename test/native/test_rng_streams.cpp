// test/native/test_rng_streams.cpp
// Author: Stanislaw Kozicki <cgpsmapper@gmail.com>
//
// Wave-4 Slice C — per-node/per-link RNG stream derivation.
// Verifies the three guarantees the design rests on:
//   1. DETERMINISM/REPRODUCIBILITY — same (seed,domain,index) => same stream
//      (resume/re-run identical).
//   2. ISOLATION — distinct (domain,index) => independent streams; a draw in
//      one stream never perturbs another. Modeled here as: draining N values
//      from stream A does not change stream B's sequence.
//   3. The derivation FUNCTION — the scenario seed is the single knob (a
//      different seed moves every stream), and nearby indices/domains are
//      de-correlated (no aliasing).

#include "orchestrator/runtime/RngStreams.h"

#include <cassert>
#include <cstdio>
#include <set>
#include <vector>

using mrsim::RngDomain;
using mrsim::makeStream;
using mrsim::deriveSeed;

static std::vector<uint32_t> draw(std::mt19937 g, int n) {
    std::vector<uint32_t> v;
    v.reserve(n);
    for (int i = 0; i < n; ++i) v.push_back(g());
    return v;
}

int main() {
    const uint64_t SEED = 42;

    // 1. Reproducibility: two independently-built streams for the same
    //    (seed,domain,index) produce byte-identical sequences.
    {
        auto a = draw(makeStream(SEED, RngDomain::Node, 3), 16);
        auto b = draw(makeStream(SEED, RngDomain::Node, 3), 16);
        assert(a == b);
        std::printf("  [1] reproducible: node#3 stream identical across builds (%u...)\n", a[0]);
    }

    // 2. Isolation: node A's DRAW COUNT never perturbs node B's sequence.
    //    Reference = node B drawn cold. Then draw a wildly different number of
    //    values from node A first — node B's fresh sequence must be unchanged.
    {
        const int B_IDX = 7;
        auto ref = draw(makeStream(SEED, RngDomain::Node, B_IDX), 32);
        for (int extra : {0, 1, 5, 100, 9999}) {
            std::mt19937 a = makeStream(SEED, RngDomain::Node, 3);
            for (int k = 0; k < extra; ++k) (void)a();      // node 3 burns `extra` draws
            std::mt19937 b = makeStream(SEED, RngDomain::Node, B_IDX);  // node 7, fresh
            auto seq = draw(b, 32);
            assert(seq == ref);   // node 7 unaffected by how much node 3 drew
        }
        std::printf("  [2] isolation: node#3 burning 0..9999 draws leaves node#7 identical\n");
    }

    // 2b. Cross-domain isolation: same index, different domain => independent.
    {
        auto node = draw(makeStream(SEED, RngDomain::Node, 5), 8);
        auto link = draw(makeStream(SEED, RngDomain::Link, 5), 8);
        auto path = draw(makeStream(SEED, RngDomain::PathLoss, 5), 8);
        assert(node != link);
        assert(node != path);
        assert(link != path);
        std::printf("  [2b] cross-domain: Node/Link/PathLoss at index 5 all differ\n");
    }

    // 3. The seed is the single knob: a different scenario seed moves the
    //    stream (derivation actually consumes the seed).
    {
        auto s42  = draw(makeStream(42,  RngDomain::Link, 100), 8);
        auto s100 = draw(makeStream(100, RngDomain::Link, 100), 8);
        assert(s42 != s100);
        std::printf("  [3] seed knob: seed 42 vs 100 (same domain/index) differ\n");
    }

    // 3b. Nearby indices are de-correlated — no aliasing across a dense grid.
    //     Collect the first derived seed of a 200-index sweep; all distinct,
    //     and the first-draws are not trivially sequential.
    {
        std::set<uint64_t> seeds;
        std::set<uint32_t> firsts;
        for (uint64_t i = 0; i < 200; ++i) {
            seeds.insert(deriveSeed(SEED, RngDomain::Link, i));
            firsts.insert(makeStream(SEED, RngDomain::Link, i)());
        }
        assert(seeds.size() == 200);    // no derived-seed collisions
        assert(firsts.size() == 200);   // no first-draw collisions
        std::printf("  [3b] 200 nearby link indices -> 200 distinct streams (no aliasing)\n");
    }

    std::printf("test_rng_streams: OK\n");
    return 0;
}
