"""Adaptive Smart Backoff Controller for Worker polling loops."""
from __future__ import annotations

from typing import Sequence


class SmartBackoff:
    """Manages adaptive polling intervals to avoid hitting Supabase when idle."""

    def __init__(
        self,
        *,
        base_interval: float = 2.0,
        idle_steps: Sequence[float] = (2.0, 5.0, 10.0, 20.0, 30.0),
        max_idle_interval: float = 30.0,
    ) -> None:
        self.base_interval = base_interval
        self.idle_steps = tuple(idle_steps)
        self.max_idle_interval = max_idle_interval
        self._index = 0
        self._has_work = False

    def on_task_processed(self) -> None:
        """Call when a task was successfully claimed or processed."""
        self._index = 0
        self._has_work = True

    def on_idle(self) -> float:
        """Call when queue was checked and no task was found. Returns sleep duration."""
        if self._has_work:
            # First idle cycle right after doing work: short rest
            self._has_work = False
            self._index = 0
            return self.base_interval

        interval = self.idle_steps[min(self._index, len(self.idle_steps) - 1)]
        if self._index < len(self.idle_steps) - 1:
            self._index += 1
        return interval

    def reset(self) -> None:
        self._index = 0
        self._has_work = False
