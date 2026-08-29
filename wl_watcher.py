#!/usr/bin/env python3
"""
niri_watcher.py — Track fullscreen applications in niri and fire hooks.

Architecture:
    config       — Pure dataclasses / settings (no I/O at import time)
    models       — Immutable value objects parsed from niri JSON
    fetchers     — Thin I/O wrappers that return raw JSON strings
    parsers      — Pure JSON → model converters (easy to unit-test)
    evaluators   — Pure business-logic predicates (easy to unit-test)
    hooks        — Hook execution (side-effectful, mockable)
    state        — Mutable runtime state containers
    orchestrator — Main poll loop; wires all layers together
"""

from __future__ import annotations

import fnmatch
import json
import logging
import os
import shutil
import signal
import subprocess
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass, field, replace
from pathlib import Path

# ---------------------------------------------------------------------------
# Logging — module-level reference; handlers attached in main()
# ---------------------------------------------------------------------------

log = logging.getLogger("niri_watcher")


# ===========================================================================
# subprocess factory — centralized process execution
# ===========================================================================


@dataclass(frozen=True)
class SubprocessConfig:
    """Configuration for subprocess execution.

    Parameters
    ----------
    default_timeout:
        Default timeout in seconds for blocking operations.
    log_failures:
        Whether to log failures at WARNING level (DEBUG for timeouts).
    """

    default_timeout: float = 5.0
    log_failures: bool = True


class SubprocessRunner:
    """Factory for consistent subprocess execution across the codebase.

    Centralizes timeout handling, error logging, and return-value extraction.
    Designed to be injectable for testing — production code uses the default
    instance; tests inject a mock.

    Usage:
        runner = SubprocessRunner()
        text = runner.run_text(["niri", "msg", "-j", "outputs"])
        data = runner.run_json(["nvtop", "-s"])
        alive = runner.run_check(["pgrep", "-x", "niri"])
        runner.spawn_detached(["/path/to/hook.sh", "on"], env={...})
    """

    def __init__(self, config: SubprocessConfig | None = None):
        self.config = config or SubprocessConfig()

    def run_text(self, args: list[str]) -> str | None:
        """Run a command and return stripped stdout, or ``None`` on failure."""
        try:
            result = subprocess.run(
                args,
                capture_output=True,
                text=True,
                timeout=self.config.default_timeout,
            )
            stripped = result.stdout.strip()
            return stripped if stripped else None
        except FileNotFoundError:
            if self.config.log_failures:
                log.debug("Command not found: %s", args[0])
            return None
        except subprocess.TimeoutExpired:
            if self.config.log_failures:
                log.debug("Command timed out: %s", args[0])
            return None
        except OSError as exc:
            if self.config.log_failures:
                log.warning("Command failed (%s): %s", args[0], exc)
            return None

    def run_json(self, args: list[str]) -> dict | list | None:
        """Run a command and parse stdout as JSON.

        Returns parsed data (dict or list), or ``None`` on failure.
        """
        text = self.run_text(args)
        if text is None:
            return None
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            if self.config.log_failures:
                log.warning("Invalid JSON from %s", args[0])
            return None

    def run_check(self, args: list[str]) -> bool:
        """Run a command and return True if exit code is 0.

        Failures are silent — suitable for readiness probes like pgrep.
        """
        try:
            result = subprocess.run(
                args,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=self.config.default_timeout,
            )
            return result.returncode == 0
        except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
            return False

    def spawn_detached(
        self,
        args: list[str],
        env: dict[str, str] | None = None,
    ) -> subprocess.Popen | None:
        """Spawn a detached process (for hooks/daemons).

        Returns the Popen object on success, or ``None`` if the command
        is not found.  stdout/stderr are suppressed.
        """
        cmd = args[0]
        if not shutil.which(cmd) and not Path(cmd).is_file():
            if self.config.log_failures:
                log.warning("Command not found/executable: %s", cmd)
            return None
        try:
            proc = subprocess.Popen(
                args,
                env=env or os.environ,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            log.info("Spawned: %s", " ".join(args))
            return proc
        except OSError as exc:
            if self.config.log_failures:
                log.warning("Spawn failed (%s): %s", cmd, exc)
            return None


# Module-level singleton (default instance used when none injected)
_default_runner = SubprocessRunner()


# ===========================================================================
# AppFilter — glob-based app matching
# ===========================================================================


@dataclass(frozen=True)
class AppFilter:
    """A filter rule matching an app_id and optionally a window title.

    Matching semantics:

    - ``app_id`` is always an **exact** string match (no glob patterns).
      Must be specified — ``None`` is not allowed.
    - ``title`` supports **fnmatch**-style glob patterns (``*``, ``?``, etc.).
      When ``title`` is ``None``, the filter matches **any** title.
      When ``title`` is a string (including ``""``), the title must match
      the glob pattern.
    """

    app_id: str
    title: str | None = None

    def matches(self, app_id: str, title: str | None) -> bool:
        """Return True if the given app_id and title match this filter.

        Parameters
        ----------
        app_id:
            The window's app_id (e.g., ``"mpv"``, ``"brave-browser"``).
        title:
            The window's title (can be ``None`` if not set by the compositor).

        Matching semantics:

        - ``app_id`` is matched **exactly** (no glob patterns).
        - ``title=None`` in the filter  → matches **any** title.
        - ``title=""`` in the filter    → matches only empty/absent title.
        - Otherwise, fnmatch glob matching on ``title``.
        """
        # app_id must match exactly (no fnmatch)
        if app_id != self.app_id:
            return False

        # title=None filter means "match any title"
        if self.title is None:
            return True

        # title is a string (possibly empty): fnmatch against window title
        window_title = title if title is not None else ""
        return fnmatch.fnmatchcase(window_title, self.title)

    def __repr__(self) -> str:
        return f"AppFilter(app_id={self.app_id!r}, title={self.title!r})"


def parse_config_entry(entry: str) -> AppFilter | None:
    """Parse a single ``app_id[,title]`` entry into an ``AppFilter``.

    Supported formats (comma-separated within a rule, semicolon-delimited list):

    - ``"mpv"``                  → ``AppFilter("mpv", None)``       (match any title)
    - ``"steam,Steam Big Picture"`` → ``AppFilter("steam", "Steam Big Picture")``
    - ``"steam,Steam Big*"``     → ``AppFilter("steam", "Steam Big*")`` (title glob)
    - ``"steam,"``               → ``AppFilter("steam", "")``       (match only empty title)
    - ``",My Title"``            → ``None`` (app_id is required, cannot be "any")

    ``app_id`` is always required and matched exactly (no glob patterns).
    ``title`` supports fnmatch globs, or ``None`` to match any title.

    Returns ``None`` for empty/whitespace-only entries or entries with no app_id.
    """
    if not entry or not entry.strip():
        return None

    if "," in entry:
        parts = entry.split(",", 1)
        app_id_raw = parts[0].strip()
        title_raw = parts[1]  # preserve title as-is (don't strip, might be intentional)

        # app_id is required — no "any app_id" matching
        if not app_id_raw:
            return None

        return AppFilter(app_id=app_id_raw, title=title_raw if title_raw else "")
    else:
        # No comma: app_id only, match any title
        return AppFilter(app_id=entry.strip(), title=None)


def _parse_app_filter_list(raw: str) -> frozenset[AppFilter]:
    """Parse a semicolon-separated list of app filter entries.

    Empty entries are skipped.  Returns a frozenset (deduplicated).
    """
    return frozenset(
        parsed
        for entry in raw.split(";")
        if (parsed := parse_config_entry(entry)) is not None
    )


# ===========================================================================
# Defaults — built-in exclusion list
# ===========================================================================

#: Apps excluded from fullscreen detection by default.
DEFAULT_EXCLUDED_APPS: frozenset[AppFilter] = frozenset(
    {
        AppFilter("brave-browser"),
        AppFilter("brave-browser-beta"),
        AppFilter("org.mozilla.firefox"),
        AppFilter("org.kde.haruna"),
        AppFilter("vlc"),
        AppFilter("mpv"),
        AppFilter("io.mpv.Mpv"),
        AppFilter("vesktop"),
        AppFilter("com.discordapp.Discord"),
    }
)

#: Apps always detected as fullscreen (bypass nvtop check).
DEFAULT_INCLUDED_APPS: frozenset[AppFilter] = frozenset(
    {AppFilter("steam", "Steam Big Picture Mode")}
)


# ===========================================================================
# config — immutable settings, no I/O at import time
# ===========================================================================


@dataclass(frozen=True)
class Config:
    """Immutable watcher configuration.

    Construct directly for testing (all fields default to zero-values),
    or use ``Config.from_env()`` to populate from environment variables.
    """

    poll_interval: float = 2.0
    log_file: Path = Path("/tmp/niri_watcher.log")
    startup_delay: float = 3.0
    debug_mode: bool = False
    hook_on: list[str] = field(default_factory=list)
    hook_off: list[str] = field(default_factory=list)
    #: User-defined exclusions from ``WATCHER_EXCLUDED_APPS`` (priority over defaults).
    excluded_apps: frozenset[AppFilter] = field(default_factory=frozenset)
    #: User-defined inclusions from ``WATCHER_INCLUDED_APPS`` (highest priority).
    included_apps: frozenset[AppFilter] = field(default_factory=frozenset)
    relaxed_mode: bool = False
    hold_mode: bool = True
    #: Compositor backend, auto-detected at startup ("niri" or "hyprland").
    backend: str = "niri"

    @classmethod
    def from_env(cls) -> Config:
        """Build a Config from the ``WATCHER_*`` environment variables.

        Designed to be called once at startup (in ``main()``).  Env vars
        are read at call time, not at import time, so the module can be
        safely imported without side effects.
        """
        runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
        return cls(
            poll_interval=float(os.environ.get("WATCHER_POLL_INTERVAL", "2")),
            log_file=Path(
                os.environ.get(
                    "WATCHER_LOG_FILE",
                    f"{runtime_dir}/niri_watcher.log",
                )
            ),
            startup_delay=float(os.environ.get("WATCHER_STARTUP_DELAY", "3")),
            debug_mode=os.environ.get("WATCHER_DEBUG", "0") == "1",
            hook_on=_parse_hook_var("WATCHER_HOOK_ON"),
            hook_off=_parse_hook_var("WATCHER_HOOK_OFF"),
            excluded_apps=_parse_app_filter_list(
                os.environ.get("WATCHER_EXCLUDED_APPS", "")
            ),
            included_apps=_parse_app_filter_list(
                os.environ.get("WATCHER_INCLUDED_APPS", "")
            ),
            relaxed_mode=os.environ.get("WATCHER_RELAXED_MODE", "0") == "1",
            hold_mode=os.environ.get("WATCHER_HOLD_MODE", "1") != "0",
        )


def _parse_hook_var(name: str) -> list[str]:
    """Parse a colon-separated hook environment variable into a list.

    Format (set in the systemd ``.service`` file or shell):

    ::

        WATCHER_HOOK_ON="/path/to/boost.sh on"
        WATCHER_HOOK_ON="/path/to/boost.sh on:/path/to/notify.sh on"

    Colons delimit individual commands.  Leading/trailing whitespace
    around each command is stripped.  Empty entries are ignored.
    If the variable is unset or empty, returns an empty list.
    """
    raw = os.environ.get(name, "").strip()
    if not raw:
        return []
    return [entry.strip() for entry in raw.split(":") if entry.strip()]


# ===========================================================================
# models — immutable value objects
# ===========================================================================


@dataclass(frozen=True)
class OutputInfo:
    name: str
    width: int
    height: int
    enabled: bool = True
    scale: float = 1.0

    @property
    def resolution(self) -> tuple[int, int]:
        """Logical resolution (before scale is applied)."""
        return (self.width, self.height)

    @property
    def physical_resolution(self) -> tuple[int, int]:
        """Actual pixel resolution after applying scale factor."""
        return (
            int(self.width * self.scale),
            int(self.height * self.scale),
        )

    @property
    def is_enabled(self) -> bool:
        """Whether this output is currently enabled (has a valid mode)."""
        return self.enabled

    @property
    def is_scaled(self) -> bool:
        """Whether this output has a scale factor other than 1.0."""
        return self.scale != 1.0


@dataclass(frozen=True)
class WindowInfo:
    app_id: str
    pid: int | None
    workspace_id: int | None
    tile_w: int | None
    tile_h: int | None
    win_w: int | None
    win_h: int | None
    is_focused: bool
    title: str | None = None
    fullscreen: bool | None = None

    @property
    def effective_size(self) -> tuple[int, int] | None:
        """Prefer tile size, fall back to window size."""
        if self.tile_w is not None and self.tile_h is not None:
            return (self.tile_w, self.tile_h)
        if self.win_w is not None and self.win_h is not None:
            return (self.win_w, self.win_h)
        return None


# ===========================================================================
# fetchers — thin I/O wrappers (mockable in tests)
# ===========================================================================


def fetch_niri_outputs() -> str:
    return _default_runner.run_text(["niri", "msg", "-j", "outputs"]) or "{}"


def fetch_niri_windows() -> str:
    return _default_runner.run_text(["niri", "msg", "-j", "windows"]) or "[]"


def fetch_niri_workspaces() -> str:
    return _default_runner.run_text(["niri", "msg", "-j", "workspaces"]) or "[]"


# --- Hyprland (hyprctl) twins -----------------------------------------------
# Same mockable I/O contract as the niri fetchers above.


def fetch_hyprland_monitors() -> str:
    return _default_runner.run_text(["hyprctl", "monitors", "-j"]) or "[]"


def fetch_hyprland_clients() -> str:
    return _default_runner.run_text(["hyprctl", "clients", "-j"]) or "[]"


def fetch_hyprland_workspaces() -> str:
    return _default_runner.run_text(["hyprctl", "workspaces", "-j"]) or "[]"


# ===========================================================================
# /proc readers — thin helpers for process metadata
# ===========================================================================


def _read_proc_file(pid: int, filename: str, mode: str = "rb") -> bytes | str | None:
    """Read a ``/proc/<pid>/<filename>`` file. Returns ``None`` on failure.

    Used internally by ``_get_parent_pid``, ``_get_process_env``, and
    ``_get_process_cmdline`` to centralize proc error handling.
    """
    try:
        with open(f"/proc/{pid}/{filename}", mode) as f:
            return f.read()
    except OSError:
        return None


def _get_parent_pid(pid: int) -> int | None:
    """Return the parent PID (PPID) of the given PID via /proc.

    Reads /proc/<pid>/status and extracts the PPid field.
    Returns None if the process no longer exists or the field is unreadable.
    """
    data = _read_proc_file(pid, "status", mode="r")
    if data is None or not isinstance(data, str):
        return None
    try:
        for line in data.splitlines():
            if line.startswith("PPid:"):
                ppid_str = line.split(":", 1)[1].strip()
                return int(ppid_str)
    except (ValueError, IndexError):
        pass
    return None


def _collect_ancestor_pids(pid: int) -> set[int]:
    """Collect all ancestor PIDs of a process (parent, grandparent, etc.).

    Walks up the process tree via /proc/<pid>/status until PID 1 (init)
    is reached or the process tree becomes unreadable.

    Returns a set containing all ancestor PIDs (excluding the process itself).
    """
    ancestors: set[int] = set()
    current = pid
    while True:
        ppid = _get_parent_pid(current)
        if ppid is None or ppid == 0:
            break
        ancestors.add(ppid)
        if ppid == 1:
            break
        current = ppid
    return ancestors


def _get_process_env(pid: int, var: str) -> str | None:
    """Read an environment variable from /proc/<pid>/environ.

    Returns the value of the variable, or None if the process is
    inaccessible or the variable is not set.
    """
    data = _read_proc_file(pid, "environ")
    if data is None or not isinstance(data, bytes):
        return None
    # environ entries are null-byte separated KEY=VALUE pairs
    for entry in data.split(b"\0"):
        if entry.startswith(f"{var}=".encode()):
            return entry.decode(errors="replace").split("=", 1)[1]
    return None


def _get_process_cmdline(pid: int) -> list[str]:
    """Read the command line of a process from /proc/<pid>/cmdline.

    Returns a list of arguments, or an empty list on failure.
    """
    data = _read_proc_file(pid, "cmdline")
    if data is None or not isinstance(data, bytes) or not data:
        return []
    return [arg.decode(errors="replace") for arg in data.split(b"\0") if arg]


def _find_gpu_process_displays(gpu_pids: set[int]) -> dict[int, str]:
    """Map GPU-active PIDs to their DISPLAY environment variable.

    Returns a dict {pid: display} for each PID that has a DISPLAY set.
    """
    result: dict[int, str] = {}
    for pid in gpu_pids:
        display = _get_process_env(pid, "DISPLAY")
        if display:
            result[pid] = display
    return result


def _extract_xwayland_display(pid: int) -> str | None:
    """Extract the DISPLAY number from an Xwayland process command line.

    Parses argv to find the display argument (e.g., ":0" from
    "Xwayland :0 -listenfd 93 ...").
    Returns the display string (e.g., ":0") or None.
    """
    cmdline = _get_process_cmdline(pid)
    for arg in cmdline:
        # Xwayland display is the first argument starting with ":"
        if arg.startswith(":"):
            return arg
    return None


def _is_xwayland_process(pid: int) -> bool:
    """Check if a PID is an Xwayland or xwayland-satellite process."""
    cmdline = _get_process_cmdline(pid)
    if not cmdline:
        return False
    cmd = cmdline[0]
    return "xwayland" in cmd.lower() or "Xwayland" in cmd


def _match_window_to_gpu(
    window_pid: int | None,
    gpu_pids: set[int],
) -> bool:
    """Check if the window's process tree is connected to GPU-active processes.

    Matching strategies (tried in order):
    1. **Direct PID match**: window_pid is in gpu_pids (native games)
    2. **Ancestor match**: a GPU process shares an ancestor with window_pid
       (Proton games launched via wine/umu where window PID is a wrapper)
    3. **Xwayland match**: window PID is Xwayland/satellite and a GPU
       process has a DISPLAY env var matching the Xwayland display number

    Returns True if any strategy succeeds.
    """
    if window_pid is None or not gpu_pids:
        return False

    # Strategy 1: Direct PID match
    if window_pid in gpu_pids:
        return True

    # Strategy 2: Check if any GPU process shares a common ancestor
    # with the window PID (covers Proton/Wine launchers).
    # Compute window's ancestor chain once, then check each GPU PID.
    window_ancestors = _collect_ancestor_pids(window_pid) | {window_pid}
    for gpu_pid in gpu_pids:
        if gpu_pid in window_ancestors:
            return True
        gpu_ancestors = _collect_ancestor_pids(gpu_pid)
        if gpu_ancestors & window_ancestors:
            return True

    # Strategy 3: Xwayland matching
    # If the window PID is Xwayland or xwayland-satellite, extract the
    # display number and check if any GPU process uses that display
    if _is_xwayland_process(window_pid):
        window_display = _extract_xwayland_display(window_pid)
        if window_display:
            gpu_displays = _find_gpu_process_displays(gpu_pids)
            for gpu_pid, display in gpu_displays.items():
                if display == window_display:
                    return True

    return False


def fetch_gpu_pids() -> list[int]:
    """Return PIDs of processes doing GPU graphic+compute work via ``nvtop -s``.

    A process qualifies only if:
    1. Its ``kind`` is ``"graphic & compute"``
    2. Its ``gpu_usage`` is **not** ``null`` (must report an actual percentage)

    This is the "strict" filter used when relaxed mode is **disabled**:
    only processes reported by ``nvtop`` as ``"graphic & compute"`` with
    measurable GPU activity are considered fullscreen gaming apps.

    **Proton/Wine support**: For each GPU-active process, all ancestor PIDs
    (parent, grandparent, etc.) are also included. This handles the common
    case where a compositor reports the wine/proton wrapper PID while nvtop
    reports the actual game executable PID (a child process).

    Returns an empty list if ``nvtop`` is unavailable or returns invalid
    output.  Failures are silent — this is an optional enhancement.
    """
    data = _default_runner.run_json(["nvtop", "-s"])
    if data is None:
        return []

    pids: set[int] = set()
    for entry in data:
        for proc in entry.get("processes", []):
            if proc.get("kind") == "graphic & compute":
                # Skip processes with no GPU usage reading (null)
                gpu_usage = proc.get("gpu_usage")
                if gpu_usage is None:
                    continue

                pid = proc.get("pid")
                if pid is not None:
                    try:
                        pid_int = int(pid)
                        pids.add(pid_int)
                        # Include all ancestor PIDs (handles Wine/Proton
                        # where the compositor reports the wrapper PID but
                        # nvtop reports the child game executable PID)
                        pids.update(_collect_ancestor_pids(pid_int))
                    except (ValueError, TypeError):
                        pass
    return sorted(pids)


# ===========================================================================
# parsers — pure JSON → model converters
# ===========================================================================


def _physical_to_logical(width: int, height: int, scale: float) -> tuple[int, int]:
    """Convert physical (device-pixel) dimensions to logical via scale."""
    if scale == 0:
        return width, height
    return int(width / scale), int(height / scale)


def parse_outputs(outputs_json: str | None) -> dict[str, OutputInfo]:
    """
    Parse niri outputs JSON (object keyed by output name).
    Returns {output_name: OutputInfo}.

    An output with ``current_mode: null`` is considered disabled (e.g., a
    disconnected monitor) and is marked with ``enabled=False``.  Disabled
    outputs are still returned in the dict so the orchestrator can track
    them, but their resolution defaults to (0, 0).

    The mode ``width``/``height`` from niri is the physical resolution.
    Scale is read from the ``logical.scale`` field, defaulting to 1.0.
    The stored ``width``/``height`` are the logical resolution (physical / scale),
    so that ``physical_resolution`` correctly returns the actual pixel dimensions.
    """
    if not outputs_json:
        return {}
    try:
        data: dict = json.loads(outputs_json)
    except json.JSONDecodeError:
        log.warning("Failed to parse outputs JSON")
        return {}

    result: dict[str, OutputInfo] = {}
    for name, info in data.items():
        modes = info.get("modes", [])
        current_idx = info.get("current_mode")

        # Detect disabled output: current_mode is explicitly null
        if current_idx is None:
            result[name] = OutputInfo(name=name, width=0, height=0, enabled=False)
            continue

        try:
            mode = modes[current_idx]
            physical_w, physical_h = int(mode["width"]), int(mode["height"])
        except (IndexError, KeyError, TypeError, ValueError):
            log.debug("Could not determine mode for output %s", name)
            continue

        # Extract scale from logical section
        logical = info.get("logical", {})
        scale = float(logical.get("scale", 1.0)) if logical else 1.0

        # Store logical dimensions (physical / scale) so that
        # physical_resolution = logical * scale = physical
        logical_w, logical_h = _physical_to_logical(physical_w, physical_h, scale)

        result[name] = OutputInfo(
            name=name,
            width=logical_w,
            height=logical_h,
            scale=scale,
        )

    return result


def parse_workspaces(workspaces_json: str | None) -> dict[int, str]:
    """
    Parse niri workspaces JSON (array).
    Returns {workspace_id: output_name}.
    """
    if not workspaces_json:
        return {}
    try:
        data: list = json.loads(workspaces_json)
    except json.JSONDecodeError:
        log.warning("Failed to parse workspaces JSON")
        return {}

    result: dict[int, str] = {}
    for ws in data:
        ws_id = ws.get("id")
        output = ws.get("output", "")
        if ws_id is not None and output:
            result[int(ws_id)] = output

    return result


def parse_windows(windows_json: str | None) -> list[WindowInfo]:
    """
    Parse niri windows JSON (array).
    Returns list of WindowInfo objects.
    """

    def _int_or_none(v: object) -> int | None:
        try:
            return int(float(str(v)))  # handles "1920.0" etc.
        except (TypeError, ValueError):
            return None

    if not windows_json:
        return []
    try:
        data: list = json.loads(windows_json)
    except json.JSONDecodeError:
        log.warning("Failed to parse windows JSON")
        return []

    windows: list[WindowInfo] = []
    for win in data:
        layout = win.get("layout", {})
        tile_size = layout.get("tile_size") or []
        win_size = layout.get("window_size") or []

        windows.append(
            WindowInfo(
                app_id=str(win.get("app_id") or ""),
                pid=_int_or_none(win.get("pid")),
                workspace_id=_int_or_none(win.get("workspace_id")),
                tile_w=_int_or_none(tile_size[0]) if len(tile_size) > 0 else None,
                tile_h=_int_or_none(tile_size[1]) if len(tile_size) > 1 else None,
                win_w=_int_or_none(win_size[0]) if len(win_size) > 0 else None,
                win_h=_int_or_none(win_size[1]) if len(win_size) > 1 else None,
                is_focused=bool(win.get("is_focused", False)),
                title=win.get("title") or None,
            )
        )

    return windows


def parse_hyprland_outputs(monitors_json: str | None) -> dict[str, OutputInfo]:
    """Parse ``hyprctl monitors -j`` (array). Returns {name: OutputInfo}.

    ``monitors -j`` width/height are physical pixels; convert to logical
    via the shared ``_physical_to_logical`` helper (same as niri).
    ``disabled`` is a bool (there is no ``active`` key in hyprctl).
    """
    if not monitors_json:
        return {}
    try:
        data: list = json.loads(monitors_json)
    except json.JSONDecodeError:
        log.warning("Failed to parse monitors JSON")
        return {}

    result: dict[str, OutputInfo] = {}
    for m in data:
        name = m.get("name")
        if not name:
            continue
        scale = float(m.get("scale", 1.0))
        logical_w, logical_h = _physical_to_logical(
            int(m.get("width", 0)), int(m.get("height", 0)), scale
        )
        result[name] = OutputInfo(
            name=name,
            width=logical_w,
            height=logical_h,
            scale=scale,
            enabled=not m.get("disabled", False),
        )
    return result


def parse_hyprland_workspaces(workspaces_json: str | None) -> dict[int, str]:
    """Parse ``hyprctl workspaces -j`` (array). Returns {ws_id: output_name}.

    Hyprland's ``monitor`` field is the output-name string (e.g. "DP-1").
    """
    if not workspaces_json:
        return {}
    try:
        data: list = json.loads(workspaces_json)
    except json.JSONDecodeError:
        log.warning("Failed to parse workspaces JSON")
        return {}

    result: dict[int, str] = {}
    for ws in data:
        ws_id = ws.get("id")
        monitor = ws.get("monitor")
        if ws_id is not None and monitor:
            result[int(ws_id)] = monitor
    return result


def parse_hyprland_windows(clients_json: str | None) -> list[WindowInfo]:
    """Parse ``hyprctl clients -j`` (array). Returns list[WindowInfo]."""
    if not clients_json:
        return []
    try:
        data: list = json.loads(clients_json)
    except json.JSONDecodeError:
        log.warning("Failed to parse clients JSON")
        return []

    windows: list[WindowInfo] = []
    for c in data:
        size = c.get("size") or [None, None]
        ws = c.get("workspace") or {}
        # ponytail: hyprctl fullscreen_state_internal (Hyprland >=0.55) is an
        # int, not a bool: 0=none, 1=maximize, 2=fullscreen, 3=max+fullscreen.
        # bit1 is the fullscreen bit, so we test & 2 to select truly-fullscreen
        # states (2 and 3) and exclude maximize-only (state 1) — matching
        # niri's size-gate intent. (Pre-0.55 bool fullscreen + fullscreenMode
        # schema is out of scope per the "currently documented" ask.)
        fs_state = int(c.get("fullscreen") or 0)
        windows.append(
            WindowInfo(
                app_id=str(c.get("class") or ""),
                pid=c.get("pid"),
                workspace_id=ws.get("id"),
                tile_w=None,
                tile_h=None,
                win_w=size[0],
                win_h=size[1],
                # ponytail: hyprctl clients has no explicit "focused" flag;
                # focusHistoryID==0 is its documented purpose (added upstream
                # specifically so external tools can find the focused window).
                # Upgrade path if ever needed: cross-check against
                # `hyprctl activewindow -j` address, at the cost of a 4th IPC
                # call.
                is_focused=(c.get("focusHistoryID") == 0),
                title=c.get("title") or None,
                # bit1 = fullscreen (states 2,3); bit0 = maximize (state 1)
                fullscreen=bool(fs_state & 2),
            )
        )
    return windows


# ===========================================================================
# evaluators — pure business-logic predicates
# ===========================================================================


@dataclass(frozen=True)
class EvalContext:
    """Groups the per-cycle context for ``window_is_fullscreen_and_active``.

    Built-in inclusion/exclusion (``DEFAULT_INCLUDED_APPS`` /
    ``DEFAULT_EXCLUDED_APPS``) are module constants, not per-cycle state,
    so they are referenced directly rather than threaded through here.
    """

    ws_to_output: dict[int, str]
    outputs: dict[str, OutputInfo]
    excluded_apps: frozenset[AppFilter] = field(default_factory=frozenset)
    included_apps: frozenset[AppFilter] = field(default_factory=frozenset)
    relaxed_mode: bool = False


def is_app_excluded(
    app_id: str,
    excluded: frozenset[AppFilter],
    *,
    title: str | None = None,
) -> bool:
    """Return True if the given app_id/title matches any exclusion rule."""
    return any(rule.matches(app_id, title) for rule in excluded)


def is_app_included(
    app_id: str,
    included: frozenset[AppFilter],
    *,
    title: str | None = None,
) -> bool:
    """Return True if the given app_id/title matches any inclusion rule."""
    return any(rule.matches(app_id, title) for rule in included)


def _app_is_included(app_id: str, ctx: EvalContext, *, title: str | None) -> bool:
    """User or built-in inclusion (drives the focus-bypass decision)."""
    return is_app_included(app_id, ctx.included_apps, title=title) or is_app_included(
        app_id, DEFAULT_INCLUDED_APPS, title=title
    )


_FULLSCREEN_TOLERANCE = 2  # px; handles fractional-scalating drift (e.g. 2562 vs 2560)


def is_fullscreen(window: WindowInfo, output: OutputInfo) -> bool:
    """Check if the window fills the output's logical viewport.

    A window carrying an explicit ``fullscreen`` hint (set by a backend
    that reports fullscreen state directly, e.g. Hyprland's
    ``fullscreen_state_internal``) short-circuits this geometry check.

    Otherwise, both window dimensions and the output's logical
    resolution are reported by the compositor in the same coordinate
    space, so scale does not affect fullscreen detection.  A small
    tolerance (``_FULLSCREEN_TOLERANCE``) is applied to each axis to
    account for minor discrepancies from fractional scaling or
    compositor tile math.
    """
    if window.fullscreen is not None:
        return window.fullscreen
    size = window.effective_size
    if size is None:
        return False
    ow, oh = output.resolution
    return (
        abs(size[0] - ow) <= _FULLSCREEN_TOLERANCE
        and abs(size[1] - oh) <= _FULLSCREEN_TOLERANCE
    )


def resolve_output_for_window(
    window: WindowInfo,
    ctx: EvalContext,
) -> OutputInfo | None:
    """Return the OutputInfo the window lives on, or None if unknown."""
    if window.workspace_id is None:
        return None
    output_name = ctx.ws_to_output.get(window.workspace_id)
    if output_name is None:
        return None
    return ctx.outputs.get(output_name)


def window_is_fullscreen_and_active(
    window: WindowInfo,
    ctx: EvalContext,
    *,
    gpu_pids: set[int] | None = None,
) -> OutputInfo | None:
    """
    Return the OutputInfo if this window is fullscreen and active,
    or None otherwise.

    Priority chain (checked in order, first match wins):

        1. **User inclusion** — ``WATCHER_INCLUDED_APPS`` → DETECTED
        2. **User exclusion** — ``WATCHER_EXCLUDED_APPS`` → SKIP
        3. **Default inclusion** — ``DEFAULT_INCLUDED_APPS`` → DETECTED
        4. **Default exclusion** — ``DEFAULT_EXCLUDED_APPS`` → SKIP

    If none of the above match:
        5. **Relaxed mode** — detect without nvtop check
        6. **Strict mode** — require PID in ``nvtop -s`` output

    Included apps (user or default) bypass the focus requirement — they
    are detected as fullscreen regardless of whether they are focused.
    All other apps must be focused to be detected.

    Pure function — all external state passed via EvalContext.
    The ``gpu_pids`` parameter injects the nvtop result for testability.
    """
    app_id = window.app_id
    title = window.title

    # --- Step 0: Determine inclusion status (controls focus bypass) ---
    is_included = bool(app_id and _app_is_included(app_id, ctx, title=title))

    # Focus gate — included apps bypass this requirement
    if not window.is_focused and not is_included:
        return None

    output = resolve_output_for_window(window, ctx)
    if output is None:
        return None

    # Skip disabled outputs (current_mode: null)
    if not output.is_enabled:
        log.debug("\u2298 Disabled output ignored: %s", output.name)
        return None

    # Must be logically fullscreen
    if not is_fullscreen(window, output):
        return None

    # --- Steps 1–4: Priority chain (first match wins) ---
    if app_id:
        if is_app_included(app_id, ctx.included_apps, title=title):
            log.debug("\u2713 User-included: %s", app_id)
            return output
        if is_app_excluded(app_id, ctx.excluded_apps, title=title):
            log.debug("\u2298 User-excluded: %s", app_id)
            return None
        if is_app_included(app_id, DEFAULT_INCLUDED_APPS, title=title):
            log.debug("\u2713 Default-included: %s", app_id)
            return output
        if is_app_excluded(app_id, DEFAULT_EXCLUDED_APPS, title=title):
            log.debug("\u2298 Default-excluded: %s", app_id)
            return None

    # --- Step 5: Relaxed mode — detect all non-matched apps ---
    if ctx.relaxed_mode:
        log.debug("\u2713 Relaxed mode fullscreen: %s", app_id)
        return output

    # --- Step 6: Strict mode — connect the fullscreen window to a GPU
    #         process via shared ancestor, direct PID, or Xwayland display.
    if gpu_pids is not None and window.pid is not None:
        if not _match_window_to_gpu(window.pid, gpu_pids):
            log.debug(
                "\u2298 No GPU connection: %s (PID %d, %d GPU processes active)",
                app_id,
                window.pid,
                len(gpu_pids),
            )
            return None
        log.debug("\u2713 Fullscreen + GPU matched: %s (PID %d)", app_id, window.pid)
        return output

    # If gpu_pids is None (nvtop unavailable), default to allowing detection
    log.debug("\u2713 Fullscreen: %s", app_id)
    return output


def compute_desired_fullscreen(
    windows: list[WindowInfo],
    ctx: EvalContext,
    *,
    gpu_pids: set[int] | None = None,
) -> dict[str, bool]:
    """
    Return {output_name: has_fullscreen_app} for all known outputs.

    Pure function — deterministic given its inputs.
    """
    desired = {name: False for name in ctx.outputs}

    for window in windows:
        output = window_is_fullscreen_and_active(window, ctx, gpu_pids=gpu_pids)
        if output is not None:
            desired[output.name] = True

    return desired


# ===========================================================================
# hooks — hook execution
# ===========================================================================


def execute_hook(
    hook_spec: str,
    output_name: str,
    app_pid: int | None = None,
) -> None:
    """Execute a hook command asynchronously. Failures are logged, not raised."""
    if not hook_spec:
        return
    parts = hook_spec.split()
    cmd, args = parts[0], parts[1:]
    env = {
        **os.environ,
        "WATCHER_OUTPUT_NAME": output_name,
        "WATCHER_APP_PID": str(app_pid) if app_pid is not None else "",
    }
    result = _default_runner.spawn_detached([cmd, *args], env=env)
    if result is not None:
        log.info("Executing hook: %s", hook_spec)


# ===========================================================================
# state — mutable runtime state containers
# ===========================================================================


@dataclass
class FullscreenState:
    """Tracks which outputs currently have a fullscreen app."""

    _has_fullscreen: dict[str, bool] = field(default_factory=dict)

    def get(self, output_name: str) -> bool | None:
        return self._has_fullscreen.get(output_name)

    def mark(self, output_name: str, active: bool) -> None:
        self._has_fullscreen[output_name] = active

    def clear(self, output_name: str) -> None:
        self._has_fullscreen.pop(output_name, None)

    def all_tracked(self) -> set[str]:
        """Return names of all outputs with a recorded state."""
        return set(self._has_fullscreen)


@dataclass
class AppTracker:
    """Deduplicates fullscreen-app log lines per output."""

    _output_current_app: dict[str, str] = field(default_factory=dict)

    def record_app(self, output_name: str, window: WindowInfo) -> bool:
        """Record the fullscreen app. Returns True if it changed."""
        key = f"{window.app_id}:{window.pid}"
        if self._output_current_app.get(output_name) != key:
            self._output_current_app[output_name] = key
            return True
        return False

    def clear(self, output_name: str) -> None:
        self._output_current_app.pop(output_name, None)


@dataclass
class VerifiedPIDCache:
    """Caches PIDs that passed the nvtop strict filter.

    A PID remains cached until it loses focus, at which point
    it's evicted (the app may have exited or switched to a
    non-3D window).
    """

    _verified: set[int] = field(default_factory=set)

    def is_verified(self, pid: int) -> bool:
        return pid in self._verified

    def verify(self, pid: int) -> None:
        self._verified.add(pid)

    def evict_unfocused(self, focused_pids: set[int]) -> None:
        """Remove PIDs that are no longer focused."""
        self._verified &= focused_pids

    def clear(self) -> None:
        self._verified.clear()


# ===========================================================================
# Hold Mode — process existence tracking for included apps
# ===========================================================================


def is_process_alive(pid: int) -> bool:
    """Return True if a process with the given PID exists.

    Uses ``os.kill(pid, 0)`` which checks permissions/existence
    without sending a signal.  Returns False for invalid PIDs
    or when the process has exited.
    """
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


@dataclass
class HoldPIDTracker:
    """Tracks PIDs of included apps that triggered fullscreen.

    When hold mode is enabled, these PIDs are checked on each cycle.
    As long as a tracked PID is still alive, HOOK_OFF is suppressed
    for the corresponding output — even if the window is no longer
    fullscreen.
    """

    _pids: dict[str, int] = field(default_factory=dict)  # output_name → pid
    _pid_to_output: dict[int, str] = field(default_factory=dict)  # reverse index

    def _link(self, pid: int, output_name: str) -> None:
        """Link a PID to an output name in both indexes."""
        self._pids[output_name] = pid
        self._pid_to_output[pid] = output_name

    def _unlink(self, output_name: str) -> None:
        """Remove an output from both indexes."""
        pid = self._pids.pop(output_name, None)
        if pid is not None:
            self._pid_to_output.pop(pid, None)

    def record(self, pid: int, output_name: str) -> None:
        """Record a PID for the given output."""
        self._link(pid, output_name)

    def has_running_pid(self, pid: int) -> bool:
        """Return True if the PID is recorded and still alive."""
        output_name = self._pid_to_output.get(pid)
        if output_name is None:
            return False
        return is_process_alive(pid)

    def is_output_held(self, output_name: str) -> bool:
        """Return True if the output's recorded PID is still alive."""
        pid = self._pids.get(output_name)
        if pid is None:
            return False
        return is_process_alive(pid)

    def evict_dead_pids(self) -> None:
        """Remove all recorded PIDs that are no longer alive."""
        for name in [n for n, p in self._pids.items() if not is_process_alive(p)]:
            self._unlink(name)

    def evict_missing_pids(self, present_pids: set[int]) -> None:
        """Remove recorded PIDs that no longer appear in the compositor window list."""
        for name in [n for n, p in self._pids.items() if p not in present_pids]:
            self._unlink(name)

    def evict_non_matching_pids(self, valid_pids: set[int]) -> None:
        """Remove recorded PIDs that are no longer in the valid set."""
        for name in [n for n, p in self._pids.items() if p not in valid_pids]:
            self._unlink(name)

    def clear(self) -> None:
        self._pids.clear()
        self._pid_to_output.clear()

    def clear_output(self, output_name: str) -> None:
        self._unlink(output_name)


# ===========================================================================
# orchestrator — main poll loop
# ===========================================================================


class VrrOrchestrator:
    """
    Wires all layers together.  The constructor accepts injectable
    callables for every I/O operation — making it fully testable.
    """

    def __init__(
        self,
        config: Config,
        *,
        fetch_outputs: Callable[[], str] = fetch_niri_outputs,
        fetch_windows: Callable[[], str] = fetch_niri_windows,
        fetch_workspaces: Callable[[], str] = fetch_niri_workspaces,
        fetch_gpu_pids: Callable[[], list[int]] = fetch_gpu_pids,
        run_hook: Callable[[str, str, int | None], None] = execute_hook,
        parse_outputs_fn: Callable[[str | None], dict[str, OutputInfo]] = parse_outputs,
        parse_windows_fn: Callable[[str | None], list[WindowInfo]] = parse_windows,
        parse_workspaces_fn: Callable[[str | None], dict[int, str]] = parse_workspaces,
    ):
        self.config = config
        self._fetch_outputs = fetch_outputs
        self._fetch_windows = fetch_windows
        self._fetch_workspaces = fetch_workspaces
        self._fetch_gpu_pids = fetch_gpu_pids
        self._run_hook = run_hook
        self._parse_outputs_fn = parse_outputs_fn
        self._parse_windows_fn = parse_windows_fn
        self._parse_workspaces_fn = parse_workspaces_fn
        self._fullscreen_state = FullscreenState()
        self._app_tracker = AppTracker()
        self._pid_cache = VerifiedPIDCache()
        self._hold_pid_tracker = HoldPIDTracker()
        self._last_cycle_hash: int | None = None

    # ------------------------------------------------------------------
    # Phase 1: Collect
    # ------------------------------------------------------------------

    def _collect(self) -> tuple[str, str, str]:
        return (
            self._fetch_outputs(),
            self._fetch_windows(),
            self._fetch_workspaces(),
        )

    # ------------------------------------------------------------------
    # Stable hash (excludes volatile fields like focus_timestamp)
    # ------------------------------------------------------------------

    @staticmethod
    def _stable_cycle_hash(
        outputs_json: str,
        windows: list[WindowInfo],
        ws_to_output: dict[int, str],
    ) -> int:
        """Hash the cycle state, ignoring volatile fields (focus_timestamp).

        Windows are hashed via their consumed fields only; outputs_json is
        hashed raw (it has no volatile fields); workspaces as sorted tuples.
        """
        windows_key = tuple(
            (
                w.app_id,
                w.pid,
                w.workspace_id,
                w.tile_w,
                w.tile_h,
                w.win_w,
                w.win_h,
                w.is_focused,
                w.title,
                w.fullscreen,
            )
            for w in windows
        )
        ws_key = tuple(sorted(ws_to_output.items()))
        return hash((outputs_json, windows_key, ws_key))

    # ------------------------------------------------------------------
    # Phase 2: Parse  (delegates to pure parsers)
    # ------------------------------------------------------------------

    def _parse(
        self,
        outputs_json: str,
        windows_json: str,
        workspaces_json: str,
    ) -> tuple[dict[str, OutputInfo], list[WindowInfo], dict[int, str]]:
        outputs = self._parse_outputs_fn(outputs_json)
        windows = self._parse_windows_fn(windows_json)
        ws_to_output = self._parse_workspaces_fn(workspaces_json)
        log.debug(
            "Parsed: %d outputs, %d windows, %d workspaces",
            len(outputs),
            len(windows),
            len(ws_to_output),
        )
        return outputs, windows, ws_to_output

    # ------------------------------------------------------------------
    # Phase 3: Decide  (delegates to pure evaluators)
    # ------------------------------------------------------------------

    def _decide(
        self,
        outputs: dict[str, OutputInfo],
        windows: list[WindowInfo],
        ws_to_output: dict[int, str],
    ) -> dict[str, bool]:
        # Collect currently focused window PIDs
        focused_pids: set[int] = {
            w.pid for w in windows if w.is_focused and w.pid is not None
        }

        # Evict stale entries (windows that lost focus)
        self._pid_cache.evict_unfocused(focused_pids)

        # Evict hold-mode entries for windows that disappeared from the
        # compositor (closed window → safe to fire HOOK_OFF).
        all_window_pids: set[int] = {w.pid for w in windows if w.pid is not None}
        self._hold_pid_tracker.evict_missing_pids(all_window_pids)

        # Resolve GPU PIDs (cached verified + fresh nvtop if needed)
        gpu_pids = self._resolve_gpu_pids(focused_pids)

        ctx = EvalContext(
            ws_to_output=ws_to_output,
            outputs=outputs,
            excluded_apps=self.config.excluded_apps,
            included_apps=self.config.included_apps,
            relaxed_mode=self.config.relaxed_mode,
        )
        desired = compute_desired_fullscreen(windows, ctx, gpu_pids=gpu_pids)

        # Evict hold-mode entries for windows that no longer match inclusion
        # rules (e.g. Steam BPM title changed to something else).
        still_included_pids: set[int] = {
            w.pid
            for w in windows
            if w.pid is not None and self._is_included_app(w.app_id, ctx, title=w.title)
        }
        self._hold_pid_tracker.evict_non_matching_pids(still_included_pids)

        # Log fullscreen apps and record hold-mode PIDs
        self._record_fullscreen_windows(windows, ctx, desired)

        return desired

    def _resolve_gpu_pids(self, focused_pids: set[int]) -> set[int] | None:
        """Resolve GPU-active PIDs, using verified cache to skip nvtop when possible.

        Returns the set of GPU PIDs if strict mode is enabled and nvtop
        is functional, or ``None`` if nvtop is unavailable.
        """
        if self.config.relaxed_mode:
            return None

        unverified = focused_pids - self._pid_cache._verified
        fresh: set[int] = set()
        if unverified:
            # Only call nvtop -s if we have unverified focused PIDs
            fresh = set(self._fetch_gpu_pids())
            for pid in unverified:
                if pid in fresh:
                    self._pid_cache.verify(pid)

        return self._pid_cache._verified | (fresh or set())

    def _record_fullscreen_windows(
        self,
        windows: list[WindowInfo],
        ctx: EvalContext,
        desired: dict[str, bool],
    ) -> None:
        """Log focused fullscreen apps and record hold-mode PIDs for included apps."""
        for window in windows:
            output = resolve_output_for_window(window, ctx)
            if not output or not desired.get(output.name):
                continue

            # Log only focused windows that are actually fullscreen
            # (not just any focused window on a fullscreen output —
            # unfocused included apps can make an output "fullscreen"
            # without being the focused window).
            if window.is_focused and is_fullscreen(window, output):
                if self._app_tracker.record_app(output.name, window):
                    log.info(
                        "Fullscreen: %s (PID %s) on %s",
                        window.app_id,
                        window.pid,
                        output.name,
                    )

            # Record PID for hold mode if it's an included app
            if window.pid is not None and self._is_included_app(
                window.app_id, ctx, title=window.title
            ):
                already_tracked = self._hold_pid_tracker.is_output_held(output.name)
                self._hold_pid_tracker.record(window.pid, output.name)
                if self.config.hold_mode and not already_tracked:
                    log.info(
                        "Hold mode: tracking PID %s for %s on %s",
                        window.pid,
                        window.app_id,
                        output.name,
                    )

    @staticmethod
    def _is_included_app(
        app_id: str,
        ctx: EvalContext,
        *,
        title: str | None = None,
    ) -> bool:
        """Return True if the app matches user or default inclusion rules."""
        return _app_is_included(app_id, ctx, title=title)

    # ------------------------------------------------------------------
    # Phase 4: Act
    # ------------------------------------------------------------------

    def _apply_fullscreen_transitions(
        self, desired: dict[str, bool], outputs: dict[str, OutputInfo]
    ) -> list[tuple[str, bool]]:
        """Compare desired vs current state, record transitions.

        Returns a list of ``(output_name, new_state)`` transitions that
        were logically applied.

        When hold mode is enabled and an output's recorded PID is still
        alive, transitions to False are suppressed — the output stays
        logically fullscreen until the process exits.
        """
        transitions: list[tuple[str, bool]] = []

        for output_name, want_on in desired.items():
            prev = self._fullscreen_state.get(output_name)

            if prev == want_on:
                continue  # no change in state
            if prev is None and not want_on:
                continue  # never set and it should be off — skip

            # Hold mode: suppress transition to False if PID alive
            if (
                self.config.hold_mode
                and not want_on
                and self._hold_pid_tracker.is_output_held(output_name)
            ):
                log.debug(
                    "Hold mode: suppressing fullscreen off for %s (PID alive)",
                    output_name,
                )
                continue  # skip transition — state stays True

            self._fullscreen_state.mark(output_name, want_on)
            transitions.append((output_name, want_on))
            log.info(
                "%s fullscreen tracking on %s",
                "Enabling" if want_on else "Disabling",
                output_name,
            )
        return transitions

    def _execute_transition_hooks(
        self,
        transitions: list[tuple[str, bool]],
        windows: list[WindowInfo],
        ws_to_output: dict[int, str],
    ) -> None:
        """Run on/off hooks for completed fullscreen transitions."""
        for output_name, want_on in transitions:
            hooks = self.config.hook_on if want_on else self.config.hook_off
            for spec in hooks:
                pid = self._focused_window_pid(output_name, windows, ws_to_output)
                self._run_hook(spec, output_name, pid)
            if not want_on:
                self._app_tracker.clear(output_name)

    @staticmethod
    def _focused_window_pid(
        output_name: str,
        windows: list[WindowInfo],
        ws_to_output: dict[int, str],
    ) -> int | None:
        """Return the PID of the focused window on the given output."""
        for window in windows:
            if window.is_focused and window.workspace_id is not None:
                if ws_to_output.get(window.workspace_id) == output_name:
                    return window.pid
        return None

    def _cleanup_stale_outputs(self, known_outputs: set[str]) -> None:
        """Remove state for outputs that disappeared."""
        for gone in self._fullscreen_state.all_tracked() - known_outputs:
            log.info("Output %s disconnected, cleaning state", gone)
            self._fullscreen_state.clear(gone)
            self._app_tracker.clear(gone)
            self._hold_pid_tracker.clear_output(gone)
        # Clear PID cache when outputs change (focus context may have shifted)
        if self._fullscreen_state.all_tracked() - known_outputs:
            self._pid_cache.clear()

        # Evict dead PIDs from hold tracker
        self._hold_pid_tracker.evict_dead_pids()

    def _act(
        self,
        desired: dict[str, bool],
        outputs: dict[str, OutputInfo],
        windows: list[WindowInfo],
        ws_to_output: dict[int, str],
    ) -> None:
        transitions = self._apply_fullscreen_transitions(desired, outputs)
        self._execute_transition_hooks(transitions, windows, ws_to_output)
        self._cleanup_stale_outputs(set(desired))

    # ------------------------------------------------------------------
    # Single poll cycle (exposed for testing)
    # ------------------------------------------------------------------

    def poll_once(self) -> None:
        outputs_json, windows_json, workspaces_json = self._collect()
        outputs, windows, ws_to_output = self._parse(
            outputs_json, windows_json, workspaces_json
        )

        # Content-hash skip: if nothing changed, skip _decide() and _act()
        cycle_hash = self._stable_cycle_hash(outputs_json, windows, ws_to_output)
        if cycle_hash == self._last_cycle_hash:
            log.debug("No state change detected, skipping cycle")
            return
        self._last_cycle_hash = cycle_hash

        desired = self._decide(outputs, windows, ws_to_output)
        self._act(desired, outputs, windows, ws_to_output)

    # ------------------------------------------------------------------
    # Shutdown
    # ------------------------------------------------------------------

    def shutdown(self) -> None:
        """Run off-hooks for all tracked outputs."""
        log.info("Shutting down, clearing all fullscreen states...")
        for output_name in list(self._fullscreen_state._has_fullscreen):
            was_active = self._fullscreen_state.get(output_name)
            if was_active:
                for spec in self.config.hook_off:
                    self._run_hook(spec, output_name, None)
            self._fullscreen_state.clear(output_name)
            self._app_tracker.clear(output_name)
            self._hold_pid_tracker.clear_output(output_name)
        self._pid_cache.clear()
        self._hold_pid_tracker.clear()

    # ------------------------------------------------------------------
    # Startup readiness
    # ------------------------------------------------------------------

    def _wait_for_compositor(self) -> None:
        """Poll for the compositor process until it is running.

        Replaces the old hard sleep with a lightweight readiness gate.
        Retries up to ``config.startup_delay`` seconds (as a timeout
        budget), checking every 1 s.  If the timeout is reached we log
        a warning and proceed anyway — the first real ``poll_once``
        cycle will handle failure gracefully.
        """
        proc = "Hyprland" if self.config.backend == "hyprland" else "niri"
        deadline = time.monotonic() + self.config.startup_delay
        attempt = 0
        while time.monotonic() < deadline:
            attempt += 1
            if _default_runner.run_check(["pgrep", "-x", proc]):
                if attempt > 1:
                    elapsed = time.monotonic() - (deadline - self.config.startup_delay)
                    log.info(
                        "%s ready after %.1fs (attempt %d)", proc, elapsed, attempt
                    )
                return
            if attempt == 1:
                log.info(
                    "Waiting for %s (timeout %.0fs)…", proc, self.config.startup_delay
                )
            log.debug("Waiting for %s… (attempt %d)", proc, attempt)
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(1, remaining))
        log.warning(
            "%s did not respond within %.0fs, proceeding anyway",
            proc,
            self.config.startup_delay,
        )

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------

    def run(self, *, handle_signals: bool = True) -> None:
        """Run the poll loop. Set ``handle_signals=False`` for testing or embedding."""
        self._wait_for_compositor()

        if handle_signals:

            def _handle_signal(signum, _frame):  # noqa: ANN001
                log.info("Received signal %s", signum)
                self.shutdown()
                sys.exit(0)

            signal.signal(signal.SIGINT, _handle_signal)
            signal.signal(signal.SIGTERM, _handle_signal)

        log.info(
            "Monitoring active (interval: %.1fs)",
            self.config.poll_interval,
        )

        while True:
            cycle_start = time.monotonic()

            try:
                self.poll_once()
            except Exception:
                log.exception("Unexpected error in poll cycle")

            elapsed = time.monotonic() - cycle_start
            remaining = self.config.poll_interval - elapsed
            if remaining > 0.1:
                time.sleep(remaining)


# ===========================================================================
# Dependency checking
# ===========================================================================


def check_dependencies(backend: str = "niri") -> bool:
    missing: list[str] = []
    required = ["hyprctl"] if backend == "hyprland" else ["niri"]
    for cmd in required:
        if not shutil.which(cmd):
            missing.append(cmd)
    if missing:
        log.error("Missing required commands: %s", ", ".join(missing))
        print(f"Error: Missing: {', '.join(missing)}", file=sys.stderr)
        return False
    return True


# ===========================================================================
# entry point
# ===========================================================================


def _configure_logging(
    log_path: Path,
    debug: bool,
    *,
    service_mode: bool = False,
) -> None:
    """Attach handlers to the module-level ``niri_vrr`` logger.

    Parameters
    ----------
    log_path:
        Path to the log file (always written).
    debug:
        If True, set level to DEBUG; otherwise INFO.
    service_mode:
        If True, mirror output to stderr with a compact format.
        When running under systemd, stderr is natively captured into
        the journal — no ``python3-systemd`` package needed.
    """
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("niri_watcher")
    logger.setLevel(logging.DEBUG if debug else logging.INFO)

    # Clear stale handlers (important for re-configuration in tests)
    logger.handlers.clear()

    # File handler (always present)
    file_fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%F %T",
    )
    fh = logging.FileHandler(log_path, mode="w", encoding="utf-8")
    fh.setFormatter(file_fmt)
    logger.addHandler(fh)

    # Stderr handler — useful when running as a systemd service (stderr is
    # automatically captured into the journal) or for interactive debugging.
    if service_mode:
        stderr_fmt = logging.Formatter("%(levelname)s: %(message)s")
        sh = logging.StreamHandler(sys.stderr)
        sh.setFormatter(stderr_fmt)
        logger.addHandler(sh)


def _detect_systemd_service() -> bool:
    """Return True if we appear to be running as a systemd service."""
    return (
        os.environ.get("INVOCATION_ID") is not None
        or os.environ.get("JOURNAL_STREAM") is not None
    )


def print_help() -> None:
    """Print comprehensive usage information."""
    help_text = """\
Usage: niri_watcher.py [OPTIONS]

Track fullscreen applications in niri or Hyprland and fire hooks when they
enter or exit fullscreen mode.  Designed for per-output variable refresh
rate (VRR) control — e.g. enabling VRR when a game goes fullscreen and
disabling it when it does not.  The compositor backend is auto-detected
(see REQUIREMENTS).

OPTIONS
  -h, --help    Show this help message and exit.
  --version     Print version and exit.

ENVIRONMENT VARIABLES

  Polling & Startup
    WATCHER_POLL_INTERVAL     float   Poll interval in seconds.
                                          Default: 2
    WATCHER_STARTUP_DELAY     float   Seconds to wait before first poll.
                                          Default: 3
    WATCHER_LOG_FILE          path    Log file location.
                                          Default: $XDG_RUNTIME_DIR/niri_watcher.log

  Logging
    WATCHER_DEBUG             0|1     Enable DEBUG-level logging.
                                          Default: 0
    WATCHER_STDERR            0|1     Mirror log to stderr (auto-enabled
                                      when running as a systemd service).
                                          Default: 0

  Hooks
    WATCHER_HOOK_ON           str     Colon-separated command(s) to run when
                                        a fullscreen app is detected.
                                        Receives WATCHER_OUTPUT_NAME and
                                        WATCHER_APP_PID in the environment.
                                            Default: (none)
    WATCHER_HOOK_OFF          str     Colon-separated command(s) to run when
                                      fullscreen app exits.
                                          Default: (none)

  App Filters

    Filters use the format:  app_id[,title][;app_id[,title] ...]

    - app_id  is an exact match (no globs).  Required.
    - title   supports fnmatch globs (*, ?, etc.).  Optional.
              - Omitted (no comma) → matches any title.
              - Empty (trailing comma, e.g. "mpv,") → matches empty title.
    - Multiple rules are separated by semicolons.

    WATCHER_EXCLUDED_APPS     str     Semicolon-separated app filters to
                                      exclude from fullscreen detection.
                                      Takes priority over default exclusions.
                                          Default: (none)

    WATCHER_INCLUDED_APPS     str     Semicolon-separated app filters to
                                      always detect as fullscreen (bypass
                                      nvtop GPU check).  Highest priority.
                                          Default: (none)

    Built-in included:
      steam,Steam Big Picture Mode

    Built-in excluded:
      brave-browser, brave-browser-beta, org.mozilla.firefox,
      org.kde.haruna, vlc, mpv, io.mpv.Mpv, vesktop,
      com.discordapp.Discord

  Modes
    WATCHER_RELAXED_MODE      0|1     When enabled, detects all non-excluded
                                      apps without nvtop GPU check.
                                          Default: 0

    WATCHER_HOLD_MODE         0|1     When enabled (default), suppresses
                                      WATCHER_HOOK_OFF for included apps as
                                      long as their window is present in
                                      niri and the process is alive.
                                      Release conditions:
                                        - Window closed (removed from niri)
                                        - app_id/title no longer matches
                                          inclusion rules
                                        - Process exits
                                          Default: 1

EXAMPLES

  Basic usage with VRR hooks:

    export WATCHER_HOOK_ON="ksuperkey -e 'vrr on'"
    export WATCHER_HOOK_OFF="ksuperkey -e 'vrr off'"
    niri_watcher.py

  Include custom apps with glob title matching:

    export WATCHER_INCLUDED_APPS="wine.exe,*Game*;wine-staging,"
    niri_watcher.py

  Exclude a specific app:

    export WATCHER_EXCLUDED_APPS="com.mitchellh.ghostty"
    niri_watcher.py

  Relaxed mode (no nvtop required):

    export WATCHER_RELAXED_MODE=1
    niri_watcher.py

  Disable hold mode (always fire hook_off when fullscreen ends):

    export WATCHER_HOLD_MODE=0
    niri_watcher.py

REQUIREMENTS
  niri        The niri Wayland compositor (must be running), OR
  hyprctl     The Hyprland compositor + its `hyprctl` CLI (Hyprland >= 0.55
              for the integer fullscreen-state schema this script relies on).
              The backend is auto-detected; override with WATCHER_BACKEND.
  nvtop       Optional. Used for GPU activity detection in strict mode.
              If unavailable, relaxed mode or nvtop fallback applies.

ARCHITECTURE
  The compositor backend (niri or Hyprland) is auto-detected at startup and
  selected via WATCHER_BACKEND (niri|hyprland).  The decision layer above is
  fully compositor-agnostic; only the IPC fetchers/parsers differ per backend.

  Fullscreen detection priority chain (first match wins):
    1. WATCHER_INCLUDED_APPS  → detected (focus not required)
    2. WATCHER_EXCLUDED_APPS  → skipped
    3. DEFAULT_INCLUDED_APPS  → detected (focus not required)
    4. DEFAULT_EXCLUDED_APPS  → skipped
    5. Relaxed mode           → detected (no nvtop check)
    6. Strict mode            → detected only if PID shows GPU
                                activity via nvtop -s (graphic & compute)

  Included apps bypass the focus requirement — they are detected as
  fullscreen regardless of whether they are focused.  All other apps
  must be focused to be detected.

  Hold mode prevents HOOK_OFF from firing while an included app's
  process is alive and its window exists in niri.  This prevents VRR
  from toggling when Steam BPM briefly loses focus during game launch.
"""
    print(help_text, end="")


def detect_backend() -> str:
    """Auto-detect the running compositor backend.

    Order: explicit ``WATCHER_BACKEND`` override → ``XDG_CURRENT_DESKTOP``
    hint → live ``pgrep -x`` process check (verifying the hinted compositor
    is actually running, falling back to the other).  Defaults to ``niri``
    if nothing is found (non-fatal; matching prior behavior).
    """
    override = os.environ.get("WATCHER_BACKEND")
    if override in ("niri", "hyprland"):
        return override

    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").lower()
    if "hyprland" in desktop:
        candidates = ["Hyprland", "niri"]
    elif "niri" in desktop:
        candidates = ["niri", "Hyprland"]
    else:
        candidates = ["Hyprland", "niri"]

    for proc in candidates:
        if _default_runner.run_check(["pgrep", "-x", proc]):
            return "hyprland" if proc == "Hyprland" else "niri"
    return "niri"


def build_backend(backend: str) -> dict[str, Callable]:
    """Return the backend-specific fetchers + parsers for ``VrrOrchestrator``.

    ``fetch_gpu_pids`` and ``run_hook`` are compositor-agnostic and left to
    the orchestrator's defaults.
    """
    if backend == "hyprland":
        return {
            "fetch_outputs": fetch_hyprland_monitors,
            "fetch_windows": fetch_hyprland_clients,
            "fetch_workspaces": fetch_hyprland_workspaces,
            "parse_outputs_fn": parse_hyprland_outputs,
            "parse_windows_fn": parse_hyprland_windows,
            "parse_workspaces_fn": parse_hyprland_workspaces,
        }
    return {
        "fetch_outputs": fetch_niri_outputs,
        "fetch_windows": fetch_niri_windows,
        "fetch_workspaces": fetch_niri_workspaces,
        "parse_outputs_fn": parse_outputs,
        "parse_windows_fn": parse_windows,
        "parse_workspaces_fn": parse_workspaces,
    }


def main() -> None:
    # Handle --help / -h before any configuration
    if "-h" in sys.argv or "--help" in sys.argv:
        print_help()
        sys.exit(0)

    if "--version" in sys.argv:
        print("niri_watcher.py 1.0.0")
        sys.exit(0)

    config = Config.from_env()
    config = replace(config, backend=detect_backend())

    # Mirror to stderr when running as a systemd service (captured by
    # journald natively — no python3-systemd required) or when opted-in
    # via WATCHER_STDERR.
    use_stderr = os.environ.get("WATCHER_STDERR", "").lower() in ("1", "true", "yes")
    if not use_stderr:
        use_stderr = _detect_systemd_service()

    _configure_logging(config.log_file, config.debug_mode, service_mode=use_stderr)

    if not check_dependencies(config.backend):
        sys.exit(1)

    orchestrator = VrrOrchestrator(config, **build_backend(config.backend))
    orchestrator.run()


if __name__ == "__main__":
    main()
