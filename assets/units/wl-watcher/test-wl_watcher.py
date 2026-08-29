#!/usr/bin/env python3
"""Tests for wl_watcher.py — composable, DRY, minimal.

Pure layers (parsers, evaluators, filters) are tested directly with
factory helpers. The orchestrator is tested through its injected I/O
callables so no real compositor/nvtop is touched.
"""

from __future__ import annotations

import os
from unittest.mock import MagicMock

import pytest

import wl_watcher as nw


# ===========================================================================
# Factories — composable builders (one place to change a default)
# ===========================================================================


def make_window(**overrides) -> nw.WindowInfo:
    """Build a WindowInfo with sensible fullscreen defaults; override anything."""
    base = dict(
        app_id="mpv",
        pid=None,
        workspace_id=1,
        tile_w=None,
        tile_h=None,
        win_w=1920,
        win_h=1080,
        is_focused=True,
        title=None,
        fullscreen=None,
    )
    base.update(overrides)
    return nw.WindowInfo(**base)


def make_output(**overrides) -> nw.OutputInfo:
    base = dict(name="DP-1", width=1920, height=1080, enabled=True, scale=1.0)
    base.update(overrides)
    return nw.OutputInfo(**base)


def make_ctx(outputs=None, ws_to_output=None, **overrides) -> nw.EvalContext:
    base = dict(
        ws_to_output=ws_to_output or {1: "DP-1"},
        outputs=outputs or {"DP-1": make_output()},
        excluded_apps=frozenset(),
        included_apps=frozenset(),
        relaxed_mode=False,
    )
    base.update(overrides)
    return nw.EvalContext(**base)


def fs_window(output="DP-1", **kw) -> nw.WindowInfo:
    """A window that geometrically fills the default 1920x1080 output."""
    kw.setdefault("app_id", "mygame")  # not in default excluded/included
    kw.setdefault("workspace_id", 1)
    kw.setdefault("win_w", 1920)
    kw.setdefault("win_h", 1080)
    return make_window(**kw)


# ===========================================================================
# AppFilter + parsing config entries
# ===========================================================================


class TestAppFilter:
    def test_exact_app_id_required(self):
        assert nw.AppFilter("mpv").matches("mpv", None)
        assert not nw.AppFilter("mpv").matches("vlc", None)

    def test_title_none_matches_any(self):
        f = nw.AppFilter("mpv")
        assert f.matches("mpv", "whatever title")
        assert f.matches("mpv", None)

    @pytest.mark.parametrize(
        "title,window_title,expect",
        [
            ("Steam Big*", "Steam Big Picture Mode", True),
            ("Steam Big*", "Steam Library", False),
            ("", "", True),
            ("", None, True),
        ],
    )
    def test_title_glob(self, title, window_title, expect):
        assert nw.AppFilter("steam", title).matches("steam", window_title) is expect


class TestParseConfigEntry:
    @pytest.mark.parametrize(
        "entry,expect",
        [
            ("mpv", nw.AppFilter("mpv", None)),
            ("steam,Steam Big Picture", nw.AppFilter("steam", "Steam Big Picture")),
            ("steam,", nw.AppFilter("steam", "")),
            ("", None),
            (",My Title", None),  # app_id required
        ],
    )
    def test_entries(self, entry, expect):
        assert nw.parse_config_entry(entry) == expect

    def test_list_dedups(self):
        fs = nw._parse_app_filter_list("mpv;mpv;vlc")
        assert fs == frozenset({nw.AppFilter("mpv"), nw.AppFilter("vlc")})


# ===========================================================================
# Parsers — niri
# ===========================================================================


class TestParseNiriOutputs:
    def test_disabled_output(self):
        data = '{"DP-1": {"modes": [], "current_mode": null}}'
        out = nw.parse_outputs(data)["DP-1"]
        assert out.enabled is False and out.resolution == (0, 0)

    def test_physical_to_logical_via_scale(self):
        data = (
            '{"DP-1": {"modes": [{"width": 3840, "height": 2160}], '
            '"current_mode": 0, "logical": {"scale": 2.0}}}'
        )
        out = nw.parse_outputs(data)["DP-1"]
        assert out.resolution == (1920, 1080)  # logical
        assert out.physical_resolution == (3840, 2160)
        assert out.is_scaled

    def test_invalid_json_returns_empty(self):
        assert nw.parse_outputs("not json") == {}


class TestParseNiriWindows:
    def test_basic_fields(self):
        data = (
            '[{"app_id": "mpv", "pid": 42, "workspace_id": 1, '
            '"is_focused": true, "title": "Movie", '
            '"layout": {"tile_size": [1900, 1000], "window_size": [1920, 1080]}}]'
        )
        w = nw.parse_windows(data)[0]
        assert w.app_id == "mpv" and w.pid == 42 and w.is_focused
        assert w.effective_size == (1900, 1000)  # tile preferred

    def test_empty(self):
        assert nw.parse_windows("") == []


class TestParseNiriWorkspaces:
    def test_mapping(self):
        data = '[{"id": 1, "output": "DP-1"}, {"id": 2, "output": "HDMI-1"}]'
        assert nw.parse_workspaces(data) == {1: "DP-1", 2: "HDMI-1"}


# ===========================================================================
# Parsers — Hyprland
# ===========================================================================


class TestParseHyprlandOutputs:
    def test_disabled_flag(self):
        data = '[{"name": "DP-1", "width": 1920, "height": 1080, "disabled": true}]'
        out = nw.parse_hyprland_outputs(data)["DP-1"]
        assert out.enabled is False

    def test_scale_conversion(self):
        data = '[{"name": "DP-1", "width": 3840, "height": 2160, "scale": 2.0}]'
        out = nw.parse_hyprland_outputs(data)["DP-1"]
        assert out.resolution == (1920, 1080)


class TestParseHyprlandWindows:
    # ponytail: hyprctl fullscreen is an int; bit1 is the fullscreen bit.
    @pytest.mark.parametrize(
        "fs_state,expect",
        [(0, False), (1, False), (2, True), (3, True)],
    )
    def test_fullscreen_bit(self, fs_state, expect):
        data = f'[{{"class":"mpv","pid":1,"size":[100,100],"workspace":{{"id":1}},"focusHistoryID":0,"fullscreen":{fs_state}}}]'
        w = nw.parse_hyprland_windows(data)[0]
        assert w.fullscreen is expect

    def test_focus_via_focus_history_zero(self):
        data = '[{"class":"mpv","pid":1,"size":[1,1],"workspace":{"id":1},"focusHistoryID":0}]'
        assert nw.parse_hyprland_windows(data)[0].is_focused
        data2 = data.replace('"focusHistoryID":0', '"focusHistoryID":3')
        assert not nw.parse_hyprland_windows(data2)[0].is_focused

    def test_workspace_id_from_nested(self):
        data = '[{"class":"mpv","pid":1,"size":[1,1],"workspace":{"id":7},"focusHistoryID":0}]'
        assert nw.parse_hyprland_windows(data)[0].workspace_id == 7


class TestParseHyprlandWorkspaces:
    def test_monitor_field(self):
        data = '[{"id": 1, "monitor": "DP-1"}]'
        assert nw.parse_hyprland_workspaces(data) == {1: "DP-1"}


# ===========================================================================
# Evaluators — fullscreen geometry + filters
# ===========================================================================


class TestIsFullscreen:
    def test_hint_short_circuits(self):
        w = make_window(fullscreen=True, win_w=10, win_h=10)
        assert nw.is_fullscreen(w, make_output())

    def test_geometry_with_tolerance(self):
        w = make_window(win_w=1922, win_h=1079)  # within tolerance
        assert nw.is_fullscreen(w, make_output())

    def test_no_size_is_false(self):
        assert not nw.is_fullscreen(make_window(win_w=None, win_h=None), make_output())

    def test_disabled_output_not_fullscreen(self):
        # resolve_output returns the output; is_fullscreen doesn't check enabled,
        # but the caller does. Geometry still computes on logical res.
        w = fs_window()
        assert nw.is_fullscreen(w, make_output(enabled=False))


class TestResolveOutput:
    def test_unknown_workspace(self):
        assert (
            nw.resolve_output_for_window(make_window(workspace_id=99), make_ctx())
            is None
        )

    def test_known(self):
        out = make_output()
        w = nw.resolve_output_for_window(make_window(), make_ctx(outputs={"DP-1": out}))
        assert w is out


# ===========================================================================
# Evaluators — priority chain (window_is_fullscreen_and_active)
# ===========================================================================


def _eval(window, gpu_pids=None, **ctx_kw) -> nw.OutputInfo | None:
    return nw.window_is_fullscreen_and_active(
        window, make_ctx(**ctx_kw), gpu_pids=gpu_pids
    )


class TestFullscreenDecision:
    def test_focus_required_for_normal_app(self):
        assert _eval(fs_window(is_focused=False)) is None
        assert _eval(fs_window(is_focused=True)) is not None

    def test_default_excluded_skipped(self):
        w = fs_window(app_id="brave-browser")
        assert _eval(w) is None

    def test_default_included_bypasses_focus(self):
        w = fs_window(app_id="steam", title="Steam Big Picture Mode", is_focused=False)
        assert _eval(w) is not None

    def test_relaxed_mode_detects_focused(self):
        w = fs_window(app_id="someapp", is_focused=True)
        assert _eval(w, relaxed_mode=True) is not None

    def test_strict_mode_requires_gpu_match(self):
        w = fs_window(app_id="game", pid=555, is_focused=True)
        # no gpu pids -> not matched (strict mode)
        assert _eval(w, gpu_pids=set()) is None
        assert _eval(w, gpu_pids={555}) is not None

    def test_disabled_output_skipped(self):
        out = make_output(enabled=False)
        ctx = make_ctx(outputs={"DP-1": out})
        w = fs_window()
        assert nw.window_is_fullscreen_and_active(w, ctx) is None


class TestAppFilterPriority:
    # First match wins: user-included > user-excluded > default-included >
    # default-excluded. Each case is one focused fullscreen window on DP-1.

    @pytest.mark.parametrize(
        "ctx_kw,expect",
        [
            # user-included beats default-excluded
            (dict(included_apps=frozenset({nw.AppFilter("mpv")})), "DP-1"),
            # user-excluded beats default-included (steam BPM)
            (
                dict(
                    excluded_apps=frozenset(
                        {nw.AppFilter("steam", "Steam Big Picture Mode")}
                    )
                ),
                None,
            ),
            # user-excluded beats everything
            (
                dict(excluded_apps=frozenset({nw.AppFilter("mpv")})),
                None,
            ),
            # user-included (unfocused) still detected
            (
                dict(included_apps=frozenset({nw.AppFilter("mpv")})),
                "DP-1",
            ),
        ],
    )
    def test_priority(self, ctx_kw, expect):
        w = fs_window(app_id="mpv", is_focused=False, title="x")
        out = _eval(w, **ctx_kw)
        assert (out.name if out else None) == expect


class TestComputeDesired:
    def test_aggregates_per_output(self):
        ctx = make_ctx(
            outputs={"DP-1": make_output(), "HDMI-1": make_output(name="HDMI-1")},
            ws_to_output={1: "DP-1", 2: "HDMI-1"},
            relaxed_mode=True,
        )
        windows = [
            fs_window(workspace_id=1, app_id="mygame"),
            fs_window(workspace_id=2, app_id="mygame", is_focused=False),
        ]
        desired = nw.compute_desired_fullscreen(windows, ctx)
        assert desired == {"DP-1": True, "HDMI-1": False}


# ===========================================================================
# State containers
# ===========================================================================


class TestState:
    def test_fullscreen_state(self):
        s = nw.FullscreenState()
        assert s.get("DP-1") is None
        s.mark("DP-1", True)
        assert s.get("DP-1") is True
        assert "DP-1" in s.all_tracked()
        s.clear("DP-1")
        assert s.get("DP-1") is None

    def test_app_tracker_changes(self):
        t = nw.AppTracker()
        w = make_window(pid=1)
        assert t.record_app("DP-1", w)
        assert not t.record_app("DP-1", w)
        t.clear("DP-1")
        assert t.record_app("DP-1", w)

    def test_verified_pid_cache_evict(self):
        c = nw.VerifiedPIDCache()
        c.verify(7)
        assert c.is_verified(7)
        c.evict_unfocused({8})
        assert not c.is_verified(7)

    def test_hold_pid_tracker(self):
        h = nw.HoldPIDTracker()
        h.record(os.getpid(), "DP-1")
        assert h.is_output_held("DP-1")
        h.evict_missing_pids({-1})
        assert not h.is_output_held("DP-1")


# ===========================================================================
# Orchestrator — driven through injected I/O
# ===========================================================================


def niri_windows_payload(app_id="mygame", focused=True, ws=1, w=1920, h=1080):
    return (
        f'[{{"app_id":"{app_id}","pid":{os.getpid()},"workspace_id":{ws},'
        f'"is_focused":{str(focused).lower()},"title":"t",'
        f'"layout":{{"window_size":[{w},{h}]}}}}]'
    )


def niri_workspaces_payload(ws=1, output="DP-1"):
    return f'[{{"id":{ws},"output":"{output}"}}]'


# Standard niri 1920x1080 output used across orchestrator tests.
NIRI_OUTPUTS_JSON = (
    '{"DP-1": {"modes": [{"width": 1920, "height": 1080}], '
    '"current_mode": 0, "logical": {"scale": 1.0}}}'
)


def orch_with_state(
    cfg, windows=niri_windows_payload(), workspaces=niri_workspaces_payload()
):
    """Build an orchestrator whose fetchers read from a mutable state dict."""
    state = {"outputs": NIRI_OUTPUTS_JSON, "windows": windows, "workspaces": workspaces}
    orch = nw.VrrOrchestrator(
        cfg,
        fetch_outputs=lambda: state["outputs"],
        fetch_windows=lambda: state["windows"],
        fetch_workspaces=lambda: state["workspaces"],
        fetch_gpu_pids=lambda: [],
        run_hook=MagicMock(),
    )
    return orch, state


class TestOrchestratorTransitions:
    def test_on_then_off_fires_hooks(self):
        cfg = nw.Config(hook_on=["on.sh"], hook_off=["off.sh"], relaxed_mode=True)
        orch, state = orch_with_state(cfg)
        orch.poll_once()
        orch._run_hook.assert_called_once()
        assert "on" in orch._run_hook.call_args[0][0]

        state["windows"] = "[]"
        orch.poll_once()
        assert orch._run_hook.call_count == 2  # on then off
        assert "off" in orch._run_hook.call_args[0][0]

    def test_identical_cycle_skipped(self):
        cfg = nw.Config(hook_on=["on.sh"], relaxed_mode=True)
        orch, state = orch_with_state(cfg)
        orch.poll_once()
        orch.poll_once()  # same hash -> skipped
        orch._run_hook.assert_called_once()

    def test_shutdown_fires_hook_off(self):
        cfg = nw.Config(hook_off=["off.sh"])
        orch, _ = orch_with_state(cfg)
        orch._fullscreen_state.mark("DP-1", True)
        orch.shutdown()
        orch._run_hook.assert_called_once()
        assert "off" in orch._run_hook.call_args[0][0]


class TestHoldMode:
    def test_hook_off_suppressed_while_pid_alive(self):
        # steam BPM is default-included; its PID stays alive (os.getpid()).
        cfg = nw.Config(hook_on=["on.sh"], hook_off=["off.sh"], relaxed_mode=True)
        win = niri_windows_payload(app_id="steam", w=1920, h=1080).replace(
            '"title":"t"', '"title":"Steam Big Picture Mode"'
        )
        orch, state = orch_with_state(cfg, windows=win)
        orch.poll_once()  # turns on, records hold PID
        # Window still present (so hold PID not evicted) but no longer
        # fullscreen -> off would fire, but hold mode suppresses it.
        present = niri_windows_payload(app_id="steam", w=800, h=600).replace(
            '"title":"t"', '"title":"Steam Big Picture Mode"'
        )
        state["windows"] = present
        orch.poll_once()
        orch._run_hook.assert_called_once()  # only the "on" call; off suppressed


class TestFocusedWindowPid:
    def test_finds_pid_on_output(self):
        ctx = make_ctx(ws_to_output={1: "DP-1"})
        w = make_window(workspace_id=1, pid=1234)
        assert (
            nw.VrrOrchestrator._focused_window_pid("DP-1", [w], ctx.ws_to_output)
            == 1234
        )


# ===========================================================================
# Backend detection + dependency check
# ===========================================================================


class TestBackend:
    def test_override_wins(self, monkeypatch):
        monkeypatch.setenv("WATCHER_BACKEND", "hyprland")
        assert nw.detect_backend() == "hyprland"

    def test_env_hint_falls_back_to_pgrep(self, monkeypatch):
        monkeypatch.delenv("WATCHER_BACKEND", raising=False)
        monkeypatch.setenv("XDG_CURRENT_DESKTOP", "Hyprland")
        # pgrep returns nothing -> default niri
        monkeypatch.setattr(nw._default_runner, "run_check", lambda args: False)
        assert nw.detect_backend() == "niri"

    def test_build_backend_keys(self):
        hypr = nw.build_backend("hyprland")
        assert hypr["fetch_outputs"] is nw.fetch_hyprland_monitors
        niri = nw.build_backend("niri")
        assert niri["fetch_outputs"] is nw.fetch_niri_outputs


class TestCheckDependencies:
    def test_missing_command(self, monkeypatch):
        monkeypatch.setattr(nw.shutil, "which", lambda c: False)
        assert nw.check_dependencies("hyprland") is False
        assert nw.check_dependencies("niri") is False


# ===========================================================================
# Hook execution — env plumbing
# ===========================================================================


class _FakeRunner:
    def __init__(self):
        self.calls = []

    def spawn_detached(self, args, env=None):
        self.calls.append((args, env))
        return None


def test_execute_hook_sets_env(monkeypatch):
    fake = _FakeRunner()
    monkeypatch.setattr(nw, "_default_runner", fake)
    nw.execute_hook("echo hi", "DP-1", 4242)
    args, env = fake.calls[0]
    assert args[0] == "echo"
    assert env["WATCHER_OUTPUT_NAME"] == "DP-1"
    assert env["WATCHER_APP_PID"] == "4242"


def test_execute_hook_empty_spec_noop(monkeypatch):
    fake = _FakeRunner()
    monkeypatch.setattr(nw, "_default_runner", fake)
    nw.execute_hook("", "DP-1")
    assert fake.calls == []


# ===========================================================================
# Self-check — a single runnable assertion that the bit-bug is fixed.
# ===========================================================================


def test_selfcheck_hyprland_fullscreen_bit():
    for fs_state, expect in [(0, False), (1, False), (2, True), (3, True)]:
        data = f'[{{"class":"x","pid":1,"size":[1,1],"workspace":{{"id":1}},"focusHistoryID":0,"fullscreen":{fs_state}}}]'
        assert nw.parse_hyprland_windows(data)[0].fullscreen is expect


if __name__ == "__main__":
    import sys

    sys.exit(pytest.main([__file__, "-q"]))
