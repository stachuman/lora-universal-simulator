"""SRTM + ITM (Longley-Rice) terrain-aware topology generator.

Mirrors the math in ~/meshcore_real_sim/topology_generator/
(propagation.py + terrain.py) but exposes a webapp-shaped API:
compute_link_matrix(nodes, params) -> list of {from, to, snr, rssi, ...}.
"""

from __future__ import annotations

import math
from concurrent.futures import ProcessPoolExecutor, as_completed
from typing import Optional


_EARTH_RADIUS_KM = 6371.0


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in kilometres (WGS-84 spherical approx)."""
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (math.sin(dlat / 2) ** 2
         + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2))
         * math.sin(dlon / 2) ** 2)
    return _EARTH_RADIUS_KM * 2 * math.asin(math.sqrt(min(1.0, a)))


def fspl_db(distance_km: float, freq_mhz: float) -> float:
    """Free-space path loss in dB.

    FSPL = 32.44 + 20*log10(d_km) + 20*log10(f_MHz)
    """
    if distance_km <= 0:
        return 0.0
    return 32.44 + 20.0 * math.log10(distance_km) + 20.0 * math.log10(freq_mhz)


def noise_floor_dbm(bandwidth_hz: float, noise_figure_db: float = 6.0) -> float:
    """Thermal noise floor in dBm.

    noise_floor = -174 + 10*log10(BW_Hz) + NF_dB
    For BW=62500 Hz, NF=6 dB: -174 + 47.96 + 6 ≈ -120.04 dBm.
    """
    return -174.0 + 10.0 * math.log10(bandwidth_hz) + noise_figure_db


def compute_link_itm(
    surface_profile_m: list[float],
    distance_km: float,
    freq_mhz: float,
    antenna_heights_m: tuple[float, float],
    polarization: int = 1,
    climate: int = 6,
    ground_permittivity: float = 15.0,
    ground_conductivity: float = 0.005,
    surface_refractivity: float = 314.0,
) -> dict:
    """Run ITM (Longley-Rice) point-to-point path loss for one link.

    Returns dict {loss_median_db, loss_10pct_db, loss_90pct_db, kwx}.
    kwx is the itmlogic warning flag: 0=ok, 1-4=increasing severity.

    Mirrors meshcore_real_sim/topology_generator/propagation.py exactly.
    """
    # Lazy import — keeps test discovery fast and lets tests skip on
    # missing optional dep.
    from itmlogic.preparatory_subroutines.qlrps import qlrps
    from itmlogic.preparatory_subroutines.qlrpfl import qlrpfl
    from itmlogic.statistics.avar import avar
    from itmlogic.misc.qerfi import qerfi

    num_pts = len(surface_profile_m)
    if num_pts < 3 or distance_km <= 0:
        return {"loss_median_db": 0.0, "loss_10pct_db": 0.0,
                "loss_90pct_db": 0.0, "kwx": 4}

    step_m = distance_km * 1000.0 / (num_pts - 1)
    pfl = [num_pts - 1, step_m] + list(surface_profile_m)

    wn, gme, ens, zgnd = qlrps(freq_mhz, 0.0, surface_refractivity,
                                polarization, ground_permittivity,
                                ground_conductivity)

    prop = {
        "pfl": pfl,
        "hg": list(antenna_heights_m),
        "wn": wn, "gme": gme, "ens": ens, "zgnd": zgnd,
        "kwx": 0,
        "lvar": 5,
        "mdvar": 12, "mdvarx": 12,
        "klimx": climate, "klim": climate,
    }
    prop = qlrpfl(prop)

    fspl = fspl_db(distance_km, freq_mhz)

    zc_50 = qerfi([0.5])[0]
    zt_50 = qerfi([0.5])[0]

    excess_50, prop = avar(zt_50, qerfi([0.5])[0], zc_50, prop)
    excess_10, _    = avar(zt_50, qerfi([0.1])[0], zc_50, prop)
    excess_90, _    = avar(zt_50, qerfi([0.9])[0], zc_50, prop)

    return {
        "loss_median_db": fspl + excess_50,
        "loss_10pct_db": fspl + excess_10,
        "loss_90pct_db": fspl + excess_90,
        "kwx": prop.get("kwx", 0),
    }


def intermediate_point(
    lat1: float, lon1: float,
    lat2: float, lon2: float,
    fraction: float,
) -> tuple[float, float]:
    """Compute intermediate point on the great-circle path at given fraction
    [0, 1]. Spherical interpolation."""
    lat1_r = math.radians(lat1)
    lon1_r = math.radians(lon1)
    lat2_r = math.radians(lat2)
    lon2_r = math.radians(lon2)

    d = 2 * math.asin(math.sqrt(
        math.sin((lat2_r - lat1_r) / 2) ** 2
        + math.cos(lat1_r) * math.cos(lat2_r)
        * math.sin((lon2_r - lon1_r) / 2) ** 2
    ))
    if d < 1e-12:
        return lat1, lon1

    a = math.sin((1 - fraction) * d) / math.sin(d)
    b = math.sin(fraction * d) / math.sin(d)

    x = a * math.cos(lat1_r) * math.cos(lon1_r) + b * math.cos(lat2_r) * math.cos(lon2_r)
    y = a * math.cos(lat1_r) * math.sin(lon1_r) + b * math.cos(lat2_r) * math.sin(lon2_r)
    z = a * math.sin(lat1_r) + b * math.sin(lat2_r)

    lat = math.degrees(math.atan2(z, math.sqrt(x * x + y * y)))
    lon = math.degrees(math.atan2(y, x))
    return lat, lon


def get_elevation_data(cache_dir: Optional[str] = None):
    """Initialize the srtm-py elevation source. Tiles auto-cache to
    ~/.cache/srtm/ unless cache_dir is set. Imports srtm lazily so
    test environments without the dep can skip cleanly."""
    import srtm
    if cache_dir:
        return srtm.get_data(local_cache_dir=cache_dir)
    return srtm.get_data()


def sample_elevation_profile(
    srtm_data,
    lat1: float, lon1: float,
    lat2: float, lon2: float,
    num_pts: int,
) -> Optional[list[float]]:
    """Sample N elevation points along the great-circle path between two
    coordinates. Returns None if any sample point misses SRTM coverage
    (e.g., over ocean or outside the dataset's latitude range).

    The endpoints (fraction=0 and fraction=1) are included; total
    samples = num_pts."""
    if num_pts < 2:
        return None
    profile = []
    for i in range(num_pts):
        f = i / (num_pts - 1)
        lat, lon = intermediate_point(lat1, lon1, lat2, lon2, f)
        elev = srtm_data.get_elevation(lat, lon)
        if elev is None:
            return None
        profile.append(float(elev))
    return profile


def compute_pair_link(
    node_a: dict, node_b: dict,
    srtm_data,
    freq_mhz: float,
    tx_power_dbm: float,
    bandwidth_hz: float,
    noise_figure_db: float,
    profile_resolution_m: float,
    climate: int = 6,
    polarization: int = 1,
    ground_permittivity: float = 15.0,
    ground_conductivity: float = 0.005,
    surface_refractivity: float = 314.0,
) -> Optional[dict]:
    """Compute one (a, b) link's SNR / RSSI / std-dev via SRTM + ITM.

    Returns None if SRTM is missing data along the path. Returns a
    dict {snr_db, rssi_dbm, snr_std_dev} otherwise. snr_std_dev is
    derived from ITM's 10/90 reliability spread: (loss_10 - loss_90) / 2
    (rough zeroth-order shadow estimate; the next sibling spec
    refines this).
    """
    lat_a, lon_a = node_a["lat"], node_a["lon"]
    lat_b, lon_b = node_b["lat"], node_b["lon"]
    # Defensive floor — ITM's qlrpfl divides by antenna height, so 0
    # crashes with ZeroDivisionError. Pydantic + C++ validators reject
    # 0 at the schema layer; this clamp is the last-line safety in case
    # a caller bypasses validation.
    h_a = max(0.1, float(node_a.get("antenna_height_m", 1.5)))
    h_b = max(0.1, float(node_b.get("antenna_height_m", 1.5)))

    distance_km = haversine_km(lat_a, lon_a, lat_b, lon_b)
    if distance_km <= 0:
        return None

    num_pts = max(3, int(distance_km * 1000.0 / profile_resolution_m) + 1)
    profile = sample_elevation_profile(srtm_data, lat_a, lon_a, lat_b, lon_b, num_pts)
    if profile is None:
        return None

    r = compute_link_itm(
        profile, distance_km, freq_mhz, (h_a, h_b),
        polarization=polarization, climate=climate,
        ground_permittivity=ground_permittivity,
        ground_conductivity=ground_conductivity,
        surface_refractivity=surface_refractivity,
    )
    rx_dbm = tx_power_dbm - r["loss_median_db"]
    nf_dbm = noise_floor_dbm(bandwidth_hz, noise_figure_db)
    snr_db = rx_dbm - nf_dbm
    # Reliability spread: ITM's loss_10 (worse) - loss_90 (better) gives
    # the dB range across 80% of conditions; halve for a ~1-sigma proxy.
    spread_db = max(0.0, r["loss_10pct_db"] - r["loss_90pct_db"]) / 2.0
    return {
        "snr_db": snr_db,
        "rssi_dbm": rx_dbm,
        "snr_std_dev": spread_db,
    }


def compute_link_matrix(
    nodes: list[dict],
    freq_mhz: float = 868.0,
    tx_power_dbm: float = 14.0,
    bandwidth_hz: float = 62500.0,
    noise_figure_db: float = 6.0,
    profile_resolution_m: float = 90.0,
    min_snr_db: float = -20.0,
    max_links_per_node: int = 8,
    climate: int = 6,
    polarization: int = 1,
    cache_dir: Optional[str] = None,
    srtm_data=None,
    max_workers: int = 4,
) -> dict:
    """Compute every node-pair link in parallel.

    Returns dict:
      links: list[dict] of {from, to, snr, rssi, snr_std_dev, bidir}.
              `bidir` is always True (ITM is symmetric for a given
              pair of antenna heights; we emit one entry per pair).
      n_pairs_evaluated, n_links_kept, n_srtm_misses: int.

    For testability, callers can pass an explicit `srtm_data` mock;
    otherwise we resolve it from `cache_dir` (or default).
    """
    if srtm_data is None:
        srtm_data = get_elevation_data(cache_dir)

    n = len(nodes)
    pairs = [(i, j) for i in range(n) for j in range(i + 1, n)]
    n_pairs_evaluated = len(pairs)
    n_srtm_misses = 0
    raw_results: list[tuple[int, int, dict]] = []

    # ProcessPoolExecutor would parallelize the compute, but srtm_data is
    # not picklable for unit tests; for clarity we run serially here and
    # rely on natural-call parallelism inside itmlogic. (TODO follow-up:
    # restructure so workers can receive a fresh srtm handle each.)
    for (i, j) in pairs:
        link = compute_pair_link(
            nodes[i], nodes[j], srtm_data,
            freq_mhz=freq_mhz, tx_power_dbm=tx_power_dbm,
            bandwidth_hz=bandwidth_hz, noise_figure_db=noise_figure_db,
            profile_resolution_m=profile_resolution_m,
            climate=climate, polarization=polarization,
        )
        if link is None:
            n_srtm_misses += 1
            continue
        if link["snr_db"] < min_snr_db:
            continue
        raw_results.append((i, j, link))

    # Apply max_links_per_node cap: keep top-N strongest per node.
    keep_count: dict[int, int] = {i: 0 for i in range(n)}
    sorted_results = sorted(
        raw_results,
        key=lambda t: (-t[2]["snr_db"], t[0], t[1]),
    )
    kept: list[dict] = []
    for (i, j, link) in sorted_results:
        if keep_count[i] >= max_links_per_node or keep_count[j] >= max_links_per_node:
            continue
        keep_count[i] += 1
        keep_count[j] += 1
        kept.append({
            "from": nodes[i]["name"],
            "to": nodes[j]["name"],
            "snr": round(link["snr_db"], 2),
            "rssi": round(link["rssi_dbm"], 2),
            "snr_std_dev": round(link["snr_std_dev"], 3),
            "bidir": True,
        })
    return {
        "links": kept,
        "n_pairs_evaluated": n_pairs_evaluated,
        "n_links_kept": len(kept),
        "n_srtm_misses": n_srtm_misses,
    }
