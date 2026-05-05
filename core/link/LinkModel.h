#pragma once

#include <vector>
#include <string>

struct LinkParams {
    float snr  = 0.0f;
    float rssi = -100.0f;
    float snr_std_dev = 0.0f;
    float loss = 0.0f;
};

// Matrix-based link model: stores whether each (sender, receiver) pair is connected
// and the SNR/RSSI for that link.
class MatrixLinkModel {
    int _n;  // number of nodes
    // _links[sender * _n + receiver] = {active, snr, rssi}
    struct LinkEntry {
        bool active = false;
        float snr   = 0.0f;
        float rssi  = -100.0f;
        float snr_std_dev = 0.0f;
        float loss  = 0.0f;
    };
    std::vector<LinkEntry> _links;

public:
    explicit MatrixLinkModel(int n_nodes);

    void setLink(int sender, int receiver, float snr, float rssi, float snr_std_dev = 0.0f, float loss = 0.0f);
    void setBidirectional(int a, int b, float snr, float rssi, float snr_std_dev = 0.0f, float loss = 0.0f);
    bool getLink(int sender, int receiver, LinkParams& out) const;
    int nodeCount() const { return _n; }
};
