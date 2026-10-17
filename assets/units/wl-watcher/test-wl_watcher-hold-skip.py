#!/usr/bin/env python3
"""One check for the cycle-skip fix: a held PID dying must change the cycle hash.

The daemon skips a poll cycle when the compositor payload is unchanged. Hold mode
decides on process liveness (/proc), which is not part of that payload, so the
hash has to carry it — otherwise HOOK_OFF never fires after a tracked process
exits while every compositor field stays identical.
"""

from __future__ import annotations

import os

import wl_watcher as nw


def test_cycle_hash_changes_when_held_pid_dies() -> None:
    dead_pid = 999_999  # never allocated; is_process_alive() is False
    tracker = nw.HoldPIDTracker()
    tracker.record(dead_pid, "DP-1")
    dead_signature = tracker.alive_pids()
    assert dead_signature == ()

    tracker.clear()
    tracker.record(os.getpid(), "DP-1")
    alive_signature = tracker.alive_pids()
    assert alive_signature == (os.getpid(),)

    # Identical payload, only liveness differs.
    dead_hash = nw.VrrOrchestrator._stable_cycle_hash("{}", [], {}, dead_signature)
    alive_hash = nw.VrrOrchestrator._stable_cycle_hash("{}", [], {}, alive_signature)
    assert dead_hash != alive_hash
