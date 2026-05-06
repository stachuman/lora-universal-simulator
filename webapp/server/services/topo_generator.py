"""Topology generator service — pure log-distance path-loss model.

No ITM/SRTM/terrain dependencies. All formulas match the C++ implementation in
core/link/PathLossModel.cpp and core/link/Geo.h.
"""

from __future__ import annotations

import math
import random


# ---------------------------------------------------------------------------
# Haversine distance
# ---------------------------------------------------------------------------

_EARTH_RADIUS_M = 6_371_000.0


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Return great-circle distance between two coordinates in metres.

    Matches the formula in core/link/Geo.h haversine().
    """
    lat1_r = math.radians(lat1)
    lat2_r = math.radians(lat2)
    d_lat = math.radians(lat2 - lat1)
    d_lon = math.radians(lon2 - lon1)

    a = (math.sin(d_lat / 2) ** 2
         + math.cos(lat1_r) * math.cos(lat2_r) * math.sin(d_lon / 2) ** 2)
    c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))
    return _EARTH_RADIUS_M * c


# ---------------------------------------------------------------------------
# Path-loss / SNR computation
# ---------------------------------------------------------------------------

def compute_snr(
    distance_m: float,
    alpha: float,
    sigma_db: float,
    ref_distance_m: float,
    ref_loss_db: float,
    noise_floor_db: float,
    tx_power_dbm: float,
) -> float:
    """Deterministic SNR at *distance_m* using log-distance model.

    Matches PathLossModel::sampleDeterministic().  sigma_db is accepted but
    ignored (use compute_snr_stochastic for the random variant).

    PL = ref_loss_db + 10 * alpha * log10(max(distance_m, ref_distance_m) / ref_distance_m)
    rx  = tx_power_dbm - PL
    snr = rx - noise_floor_db
    """
    d = max(distance_m, ref_distance_m)
    pl_db = ref_loss_db + 10.0 * alpha * math.log10(d / ref_distance_m)
    rx_dbm = tx_power_dbm - pl_db
    return rx_dbm - noise_floor_db


# ---------------------------------------------------------------------------
# SNR matrix
# ---------------------------------------------------------------------------

def compute_snr_matrix(
    nodes: list[dict],
    path_loss: dict,
) -> list[list[float]]:
    """Return NxN symmetric SNR matrix (dB).

    Diagonal entries are set to +inf (self-link sentinel).
    All off-diagonal entries are deterministic (sigma ignored).
    """
    alpha = path_loss["alpha"]
    sigma_db = path_loss.get("sigma_db", 0.0)
    ref_distance_m = path_loss["ref_distance_m"]
    ref_loss_db = path_loss["ref_loss_db"]
    noise_floor_db = path_loss["noise_floor_db"]
    tx_power_dbm = path_loss["tx_power_dbm"]

    n = len(nodes)
    matrix: list[list[float]] = [[0.0] * n for _ in range(n)]

    for i in range(n):
        matrix[i][i] = math.inf
        for j in range(i + 1, n):
            a, b = nodes[i], nodes[j]
            dist = haversine_m(a["lat"], a["lon"], b["lat"], b["lon"])
            snr = compute_snr(
                dist, alpha, sigma_db, ref_distance_m,
                ref_loss_db, noise_floor_db, tx_power_dbm,
            )
            matrix[i][j] = snr
            matrix[j][i] = snr

    return matrix


# ---------------------------------------------------------------------------
# Node placement helpers
# ---------------------------------------------------------------------------

def _meters_to_deg(lat_deg: float) -> tuple[float, float]:
    """Return (lat_deg_per_m, lon_deg_per_m) at the given latitude."""
    lat_per_m = 1.0 / 111_000.0
    lon_per_m = 1.0 / (111_000.0 * math.cos(math.radians(lat_deg)))
    return lat_per_m, lon_per_m


def generate_grid(
    center_lat: float,
    center_lon: float,
    n_x: int,
    n_y: int,
    spacing_m: float,
    name_prefix: str = "n",
) -> list[dict]:
    """Generate a rectangular grid of nodes centred on (center_lat, center_lon).

    Returns [{name, lat, lon}, ...] with n_x * n_y entries.
    """
    lat_per_m, lon_per_m = _meters_to_deg(center_lat)

    # Offset so the grid is centred
    x_half = (n_x - 1) / 2.0
    y_half = (n_y - 1) / 2.0

    nodes: list[dict] = []
    idx = 0
    for row in range(n_y):
        for col in range(n_x):
            lat = center_lat + (row - y_half) * spacing_m * lat_per_m
            lon = center_lon + (col - x_half) * spacing_m * lon_per_m
            name = f"{name_prefix}{idx + 1:02d}"
            nodes.append({"name": name, "lat": round(lat, 7), "lon": round(lon, 7)})
            idx += 1

    return nodes


def generate_random(
    bbox: list[float],
    count: int,
    name_prefix: str = "n",
    seed: int | None = None,
) -> list[dict]:
    """Place *count* nodes uniformly at random inside *bbox*.

    bbox = [south, west, north, east]
    Returns [{name, lat, lon}, ...].
    """
    south, west, north, east = bbox
    rng = random.Random(seed)

    nodes: list[dict] = []
    for i in range(count):
        lat = rng.uniform(south, north)
        lon = rng.uniform(west, east)
        name = f"{name_prefix}{i + 1:02d}"
        nodes.append({"name": name, "lat": round(lat, 7), "lon": round(lon, 7)})

    return nodes
