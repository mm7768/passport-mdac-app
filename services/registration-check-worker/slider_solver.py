"""Compatibility proxy pointing to shared.slider_solver."""
from __future__ import annotations

import os
import sys

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from shared.slider_solver import (
    compute_target_distances,
    generate_track,
    get_detector,
    solve_mdac_slider,
)

__all__ = [
    "compute_target_distances",
    "generate_track",
    "get_detector",
    "solve_mdac_slider",
]
