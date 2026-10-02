"""Browse order for a category's slider stops.

A category's slider is a row of discrete stops: Auto, then one stop per preset. It is NOT an
intensity control, so presets are not sorted by strength. The order is chosen for browsing:

    the shortest visual path that starts at Auto and visits every preset once,

where the distance between two stops is the mean CIEDE2000 difference between their renders on the
reference photos. Each drag to the next stop is then the smallest change still available, the
first stop is a gentle step away from Auto, and the user never jumps back and forth between two
characters (e.g. warm-cool-warm). The criterion is about similarity between looks, not about
"how much": a strong preset that resembles its neighbour sits next to it.

Categories hold a handful of presets, so the path is found exactly (all permutations) rather than
greedily. Ties are broken by the preset's display name so the order is reproducible.
"""
from __future__ import annotations

from dataclasses import dataclass
from itertools import permutations
from typing import Sequence

# A step smaller than this (mean ΔE00 on the reference photos) is hard to see as a separate stop.
NEAR_DUPLICATE_STEP_DE = 2.0
# Exhaustive search is exact and cheap up to this many presets per category (8! = 40,320 paths).
MAX_EXACT_STOPS = 8


@dataclass(frozen=True)
class BrowsePath:
    order: tuple[int, ...]            # indices into the category's presets, first stop first
    step_de: tuple[float, ...]        # ΔE from Auto to stop 1, then between consecutive stops
    total_de: float

    def near_duplicate_steps(self) -> list[int]:
        """Positions (0 = Auto → first stop) whose step is too small to read as a different stop."""
        return [i for i, d in enumerate(self.step_de) if d < NEAR_DUPLICATE_STEP_DE]


def shortest_browse_path(
    distance_from_auto: Sequence[float],
    pairwise_distance: Sequence[Sequence[float]],
    names: Sequence[str],
) -> BrowsePath:
    """Exact shortest Hamiltonian path that starts at Auto and visits each preset once.

    distance_from_auto[i]: ΔE between Auto (identity) and preset i.
    pairwise_distance[i][j]: symmetric ΔE between presets i and j.
    """
    count = len(distance_from_auto)
    if count == 0:
        return BrowsePath((), (), 0.0)
    if count > MAX_EXACT_STOPS:
        raise ValueError(f"{count} presets in one category; the slider is meant for a handful (max {MAX_EXACT_STOPS})")
    _check_symmetric(pairwise_distance, count)

    best_key = None
    best: BrowsePath | None = None
    for order in permutations(range(count)):
        steps = [distance_from_auto[order[0]]] + [pairwise_distance[a][b] for a, b in zip(order, order[1:])]
        total = sum(steps)
        # Round so float noise cannot flip a genuine tie; the name tuple makes the result reproducible.
        key = (round(total, 6), tuple(names[i] for i in order))
        if best_key is None or key < best_key:
            best_key = key
            best = BrowsePath(tuple(order), tuple(steps), total)
    assert best is not None
    return best


def _check_symmetric(matrix: Sequence[Sequence[float]], count: int) -> None:
    if len(matrix) != count or any(len(row) != count for row in matrix):
        raise ValueError("pairwise_distance must be square and match distance_from_auto")
    for i in range(count):
        for j in range(i + 1, count):
            if abs(matrix[i][j] - matrix[j][i]) > 1e-6:
                raise ValueError(f"pairwise_distance is not symmetric at ({i}, {j})")
