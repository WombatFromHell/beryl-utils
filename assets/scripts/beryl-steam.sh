#!/usr/bin/env bash
set -euo pipefail

# Shared GPU detection (DRM_SYS_PATH + detect_hybrid_graphics).
scripts_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=./gpu-detect.sh disable=SC1091
source "$scripts_dir/gpu-detect.sh"

# ── Configuration ─────────────────────────────────────────────────────────────

STEAM_SHUTDOWN_TIMEOUT="${STEAM_SHUTDOWN_TIMEOUT:-10}"

# ── Logging ──────────────────────────────────────────────────────────────────

HAS_NOTIFY=false
command -v notify-send &>/dev/null && HAS_NOTIFY=true

log_info() { echo "[$MODE_TAG] $*" >&2; }
log_warn() {
  echo "[$MODE_TAG] WARN: $*" >&2
  $HAS_NOTIFY && notify-send -u low "$MODE_TAG" "$*" 2>/dev/null || true
}
log_error() {
  echo "[$MODE_TAG] ERROR: $*" >&2
  $HAS_NOTIFY && notify-send -u critical "$MODE_TAG" "$*" 2>/dev/null || true
}

# ── Helpers ───────────────────────────────────────────────────────────────────

is_steam_running() {
  pgrep -x steam >/dev/null 2>&1
}

# ── Steam Shutdown Logic ─────────────────────────────────────────────────────

wait_for_steam_exit() {
  local elapsed=0
  local nudged=false
  while pgrep -x steam >/dev/null 2>&1; do
    if ((elapsed >= STEAM_SHUTDOWN_TIMEOUT)); then
      log_error "Steam unresponsive — force-closing after ${STEAM_SHUTDOWN_TIMEOUT}s"
      pkill --signal 9 -x steam 2>/dev/null || true
      return 0
    fi
    # After 3s, nudge with SIGINT once before continuing to wait
    if ((elapsed >= 3)) && ! $nudged; then
      pkill --signal INT -x steam 2>/dev/null || true
      nudged=true
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

shutdown_steam_if_running() {
  if is_steam_running; then
    log_info "Shutting down Steam..."
    steam -shutdown || true
    wait_for_steam_exit
  fi
}

# ponytail: replacement matrix — each mode replaces any OTHER active type,
# but never its own (plain = steam running with no lock files present):
#            | plain | nested | tenfoot |
#   plain    |   ✗   |   ✓    |   ✓     |
#   nested   |   ✓   |   ✗    |   ✓     |
#   tenfoot  |   ✓   |   ✓    |   ✗     |
shutdown_if_allowed() {
  local mode="$1"

  is_steam_running || return 0

  local active_type="plain"
  [[ -f "${XDG_RUNTIME_DIR:-}/bazzite-steam-nested.lock" ]] && active_type="nested"
  [[ -f "${XDG_RUNTIME_DIR:-}/bazzite-steam-tenfoot.lock" ]] && active_type="tenfoot"

  [[ $active_type == "$mode" ]] && return 0

  shutdown_steam_if_running
  cleanup_lock_files
}

# ── Dependency Checks ────────────────────────────────────────────────────────

check_dependencies() {
  local missing=()

  [[ -z ${XDG_RUNTIME_DIR:-} ]] && missing+=("XDG_RUNTIME_DIR (not set)")

  command -v flock &>/dev/null || missing+=("flock")
  command -v pgrep &>/dev/null || missing+=("pgrep")
  command -v pkill &>/dev/null || missing+=("pkill")

  # fuser is preferred but not fatal — we have a fallback
  command -v fuser &>/dev/null || log_warn "fuser not found; orphan cleanup will use fallback"

  if ((${#missing[@]})); then
    log_error "Missing dependencies: ${missing[*]}"
    exit 1
  fi
}

# ── State & Signal Handling ──────────────────────────────────────────────────

STEAM_CHILD_PID=0

forward_signal() {
  local sig="$1"
  if ((STEAM_CHILD_PID > 0)); then
    log_info "Received SIG${sig}, initiating graceful Steam shutdown..."
    steam -shutdown 2>/dev/null || true
    wait_for_steam_exit
    cleanup_lock_files
  fi
  exit "$((128 + $(kill -l "$sig" 2>/dev/null || echo 0)))"
}

setup_signal_handlers() {
  # ponytail: pass signal name as quoted argument to avoid unbound variable
  # under set -u; trap handler receives literal string, not expanded var.
  trap 'forward_signal INT' INT
  trap 'forward_signal TERM' TERM
  trap 'forward_signal HUP' HUP
}

# ── Monitor Detection ────────────────────────────────────────────────────────

detect_gamescope_profile_niri() {
  for cmd in niri jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_warn "$cmd not found; skipping monitor detection"
      LG_C1_CONNECTED=0
      GAMESCOPE_ARGS=(-p fallback -e)
      return 1
    fi
  done

  local prefix="" attempt=0
  # Both DP and HDMI outputs may be simultaneously active with non-null
  # current_mode. Identify the LG C1 TV by its EDID model string rather
  # than relying on connection state or connector name priority alone.
  while ((attempt < 3)); do
    if prefix="$(niri msg -j outputs 2>/dev/null | jq -r '
      to_entries
      | map(select(.value.current_mode != null))
      | if any(.value.model | test("SSCR2|C1|OLED"; "i")) then "HDMI-A"
        elif any(.key | startswith("DP-")) then "DP"
        else empty end
    ' 2>/dev/null)" && [[ -n $prefix ]]; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 0.5
  done

  LG_C1_CONNECTED=0
  GAMESCOPE_ARGS=(-p "tenfoot,hdr")
  case "$prefix" in
  HDMI-A)
    LG_C1_CONNECTED=1
    log_info "Detected LG TV → HDR profile"
    ;;
  DP)
    log_info "Detected DP monitor (no TV) → SDR profile"
    ;;
  *)
    local active_names
    active_names="$(niri msg -j outputs 2>/dev/null | jq -r '
      to_entries
      | map(select(.value.current_mode != null))
      | map("\(.key) [\(.value.model)]")
      | join(", ")
    ' 2>/dev/null)"
    log_warn "No known monitor after ${attempt} attempts (active: ${active_names:-none}); using default gamescope args"
    return 1
    ;;
  esac
}

# ponytail: hybrid detection now comes from gpu-detect.sh (sysfs-based,
# "both GPUs drive a connected output"). Replaces the old vulkaninfo check.

# ── Session Cleanup ──────────────────────────────────────────────────────────

cleanup_orphaned_session() {
  log_warn "Orphaned session detected (Steam not running). Cleaning up..."

  # Prefer fuser — single syscall, no tree-walking needed
  if command -v fuser &>/dev/null; then
    # ponytail: fuser -k would also kill THIS process (it holds fd 200 on the
    # lock); kill only the other holder(s) so the lock can be reclaimed.
    for pid in $(fuser "$LOCK_FILE" 2>/dev/null); do
      [[ $pid == "$$" ]] && continue
      kill -9 "$pid" 2>/dev/null || true
    done
  fi

  # ponytail: fuser fallback used to try a gamescope-specific pkill pattern,
  # but that only ever matched in nested mode and this leaf-sweep already
  # catches the real target (steam itself) in every mode — one kill path
  # instead of two converging on the same outcome.
  if is_steam_running; then
    pkill --signal 9 -x steam 2>/dev/null || true
  fi

  # Poll until lock is free
  for ((i = 0; i < 10; i++)); do
    if try_lock; then
      log_info "Lock reclaimed successfully"
      return 0
    fi
    sleep 1
  done

  log_error "Failed to reclaim lock after 10s — run: fuser -k '$LOCK_FILE'"
  return 1
}

# ── Command Building ─────────────────────────────────────────────────────────

# ponytail: single source of truth for steam env defaults. Call with no args to
# default to empty; pass KEY=VALUE… to set a mode's defaults. Keeps any
# env-provided STEAM_ENV_VARS so the override semantics survive centralizing.
with_steam_env() {
  [[ ${STEAM_ENV_VARS+_} ]] || STEAM_ENV_VARS=("$@")
}

# ponytail: assemble the gamescope argument vector in one place. Base profile
# comes from detection; user args + prime (hybrid) + terminator appended here so
# main() stays out of command construction (SoC).
assemble_gamescope_args() {
  detect_gamescope_profile_niri || true
  GAMESCOPE_ARGS+=("$@")
  detect_hybrid_graphics &>/dev/null && GAMESCOPE_ARGS+=(-p prime)
  GAMESCOPE_ARGS+=(--)
}

build_steam_command() {
  # Environment variables
  STEAM_CMD=(env "${STEAM_ENV_VARS[@]}")

  # Pre-launch wrappers (extensible extension point)
  # ponytail: elements are word-split on $IFS; arguments containing
  # spaces are not supported — use simple flag-style args only
  local wrapper wrapper_bin wrapper_args
  for wrapper_str in "${WRAPPERS[@]}"; do
    read -ra wrapper <<<"$wrapper_str"
    wrapper_bin="${wrapper[0]:-}"
    wrapper_args=("${wrapper[@]:1}")

    command -v "$wrapper_bin" &>/dev/null || continue
    STEAM_CMD+=("$wrapper_bin" "${wrapper_args[@]}")
    log_info "Wrapper: $wrapper_bin ${wrapper_args[*]:-}"
  done

  # Gamescope/nscb wrapper (if configured)
  if [[ -n ${GAMESCOPE_PATH:-} ]]; then
    STEAM_CMD+=("$GAMESCOPE_PATH" "${GAMESCOPE_ARGS[@]}")
  fi

  # Steam binary + args
  STEAM_CMD+=("${STEAM}" "${STEAM_ARGS[@]}")
}

# ── Session Launch ───────────────────────────────────────────────────────────

launch_steam() {
  build_steam_command

  "${STEAM_CMD[@]}" &
  # ponytail: PID race window is ~1 instruction; signal between & and $! is
  # theoretically possible but practically unreachable for interactive use
  STEAM_CHILD_PID=$!

  wait "$STEAM_CHILD_PID"
  STEAM_CHILD_PID=0
}

# ── Session Orchestration ────────────────────────────────────────────────────

run_session() {
  local mode="$1"
  LOCK_FILE="${XDG_RUNTIME_DIR:-}/bazzite-steam-${mode}.lock"

  check_dependencies
  setup_signal_handlers

  shutdown_if_allowed "$mode"
  acquire_lock
  launch_steam
  cleanup_lock_files
}

# ── Lock Management ──────────────────────────────────────────────────────────

open_lock_fd() { exec 200>"$LOCK_FILE"; }
try_lock() { flock -n 200; }
wait_lock() {
  local timeout="$1"
  flock -w "$timeout" 200
}

# ponytail: single call site for all lock-file cleanup — plain, tenfoot, nested,
# and signal traps all converge here instead of each hardcoding paths.
cleanup_lock_files() {
  rm -f "${XDG_RUNTIME_DIR:-}/bazzite-steam-tenfoot.lock" \
    "${XDG_RUNTIME_DIR:-}/bazzite-steam-nested.lock"
}

acquire_lock() {
  open_lock_fd

  # Fast path: lock acquired immediately
  if try_lock; then
    return 0
  fi

  # Lock is held — diagnose the situation

  # If Steam is dead, this is an orphaned session — reclaim the lock
  if ! is_steam_running; then
    cleanup_orphaned_session || return 1
    return 0
  fi

  # ponytail: 5s covers the peer's graceful teardown after a replacement-matrix
  # kill; bump to 15s if unrelated-process handoff becomes common.
  log_info "Lock held by another session — waiting (5s timeout)..."
  wait_lock 5 && return 0

  log_error "Could not acquire lock after 5s"
  return 1
}

# ── Plain Mode ───────────────────────────────────────────────────────────────

run_plain() {
  if [[ ${SKIP_RESTART:-} == "1" ]] && is_steam_running; then
    log_info "Steam already running and SKIP_RESTART=1 — leaving existing session alone"
    return 0
  fi

  shutdown_if_allowed "plain"
  # ponytail: route through build_steam_command so plain + session modes share
  # one launch path; extra args become the final steam arguments.
  STEAM_ARGS=("$@")
  with_steam_env
  build_steam_command
  exec "${STEAM_CMD[@]}"
}

# ── Main Execution ───────────────────────────────────────────────────────────

main() {
  local args=("$@")
  local mode_args=() extra_args=() found_sep=false steam_env=()

  for arg in "${args[@]}"; do
    if [[ $arg == "--" ]]; then
      found_sep=true
      continue
    fi
    if [[ $found_sep == true ]]; then extra_args+=("$arg"); else mode_args+=("$arg"); fi
  done

  local cmd="${mode_args[0]:-}"
  MODE_TAG="bazzified-steam"
  STEAM_ARGS=()
  WRAPPERS=()
  GAMESCOPE_PATH=""
  GAMESCOPE_ARGS=()
  LG_C1_CONNECTED=""

  STEAM="$(command -v bazzite-steam || command -v steam)" || {
    log_error "Couldn't find 'steam'!"
    exit 1
  }

  # ponytail: single case block sets all mode-specific state AND dispatches.
  # No separate config phase; no duplicated mode matching; no intermediate vars.
  case "$cmd" in
  "")
    # ponytail: extra args after `--` go to the outermost launcher — steam here,
    # gamescope in nested mode (see assemble_gamescope_args).
    with_steam_env
    run_plain "${extra_args[@]}"
    ;;
  tenfoot)
    MODE_TAG="bazzified-steam-tenfoot"
    STEAM_ARGS+=(-tenfoot -pipewire "${extra_args[@]}")
    WRAPPERS=("gamemode --")
    with_steam_env
    run_session "tenfoot"
    ;;
  nested)
    MODE_TAG="bazzified-steam-nested"
    STEAM_ARGS+=(-tenfoot -steamos3)
    GAMESCOPE_PATH="$(command -v nscb 2>/dev/null)" || {
      log_error "Missing gamescope dependency!"
      exit 1
    }
    assemble_gamescope_args "${extra_args[@]}"
    WRAPPERS=()
    ((LG_C1_CONNECTED)) && WRAPPERS+=(
      "$scripts_dir/lgc1-wold.py --" # tv wol on startup + resume from standby
      "$scripts_dir/pactl_gate_sentinel.sh"
    )
    WRAPPERS+=("gamemode --")
    steam_env=(
      PROTON_ENABLE_WAYLAND=1
      IDLE_TIMEOUT=60
      ENABLE_SLEEP_INHIBIT=0
    )
    # ponytail: skip idle hooks if on_idle.sh isn't installed; the scheduler
    # gets no IDLE/ACTIVE command rather than a dead path.
    if command -v "$scripts_dir/on_idle.sh" &>/dev/null; then
      steam_env+=(IDLE_CMD="$scripts_dir/on_idle.sh idle" ACTIVE_CMD="$scripts_dir/on_idle.sh active")
    else
      log_info "Skipping idle hooks: on_idle.sh not installed"
    fi
    with_steam_env "${steam_env[@]}"
    run_session "nested"
    ;;
  *)
    echo "Usage: bazzified-steam.sh [tenfoot|nested] [-- <args>]" >&2
    exit 1
    ;;
  esac
}

main "$@"
