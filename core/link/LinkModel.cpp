#include "core/link/LinkModel.h"

MatrixLinkModel::MatrixLinkModel(int n_nodes)
    : _n(n_nodes), _links(n_nodes * n_nodes)
{}

void MatrixLinkModel::setLink(int sender, int receiver, float snr, float rssi, float snr_std_dev, float loss) {
    if (sender >= 0 && sender < _n && receiver >= 0 && receiver < _n) {
        auto& e = _links[sender * _n + receiver];
        e.active = true;
        e.snr = snr;
        e.rssi = rssi;
        e.snr_std_dev = snr_std_dev;
        e.loss = loss;
    }
}

void MatrixLinkModel::setBidirectional(int a, int b, float snr, float rssi, float snr_std_dev, float loss) {
    setLink(a, b, snr, rssi, snr_std_dev, loss);
    setLink(b, a, snr, rssi, snr_std_dev, loss);
}

bool MatrixLinkModel::getLink(int sender, int receiver, LinkParams& out) const {
    if (sender < 0 || sender >= _n || receiver < 0 || receiver >= _n)
        return false;
    const auto& e = _links[sender * _n + receiver];
    if (!e.active) return false;
    out.snr = e.snr;
    out.rssi = e.rssi;
    out.snr_std_dev = e.snr_std_dev;
    out.loss = e.loss;
    return true;
}
