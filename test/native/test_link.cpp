// test/native/test_link.cpp
#include "core/link/LinkModel.h"
#include <cassert>
#include <cstdio>

int main() {
    MatrixLinkModel m(3);                  // 3 nodes

    // No links set yet -> getLink returns false.
    LinkParams p{};
    assert(!m.getLink(0, 1, p));

    // setLink(sender, receiver, snr, rssi, snr_std_dev=0, loss=0)
    m.setLink(0, 1, /*snr=*/8.0f, /*rssi=*/-80.0f);
    assert(m.getLink(0, 1, p));
    assert(p.snr == 8.0f);
    assert(p.rssi == -80.0f);
    assert(p.snr_std_dev == 0.0f);
    assert(p.loss == 0.0f);

    // Reverse direction is independent -> still false.
    LinkParams q{};
    assert(!m.getLink(1, 0, q));

    // setBidirectional sets both directions.
    m.setBidirectional(1, 2, /*snr=*/3.5f, /*rssi=*/-95.0f, /*snr_std_dev=*/1.0f, /*loss=*/0.25f);
    LinkParams a{}, b{};
    assert(m.getLink(1, 2, a));
    assert(m.getLink(2, 1, b));
    assert(a.snr == 3.5f && a.rssi == -95.0f && a.snr_std_dev == 1.0f && a.loss == 0.25f);
    assert(b.snr == 3.5f && b.rssi == -95.0f && b.snr_std_dev == 1.0f && b.loss == 0.25f);

    // Out-of-range indices -> false.
    LinkParams r{};
    assert(!m.getLink(-1, 0, r));
    assert(!m.getLink(0, 5, r));

    assert(m.nodeCount() == 3);

    std::printf("test_link: OK\n");
    return 0;
}
