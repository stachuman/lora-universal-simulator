// core/link/Geo.h
#pragma once
#include <cmath>

namespace lus {
inline double haversineDistanceMeters(double lat1, double lon1,
                                       double lat2, double lon2) {
    const double R = 6371000.0;   // Earth radius, meters
    const double pi = 3.14159265358979323846;
    const double phi1 = lat1 * pi / 180.0;
    const double phi2 = lat2 * pi / 180.0;
    const double dphi = (lat2 - lat1) * pi / 180.0;
    const double dlam = (lon2 - lon1) * pi / 180.0;
    const double a = std::sin(dphi/2)*std::sin(dphi/2)
                    + std::cos(phi1)*std::cos(phi2)
                    * std::sin(dlam/2)*std::sin(dlam/2);
    const double c = 2.0 * std::atan2(std::sqrt(a), std::sqrt(1.0 - a));
    return R * c;
}
}
