#!/usr/bin/env bash
# Generic Chromium browser wrapper: launches any Chromium fork via host binary,
# flatpak, or (custom-named) distrobox container, driven by per-browser profile
# files, or wraps an arbitrary command. Injects flags through
# chromium-flags.sh; background updates run for the profile/legacy strategies.
#
# Profiles: ~/.config/chromium-wrapper/<profile>.conf (env: PROFILE_DIR)
#   chromium-wrapper.sh -p brave <URL>     load profile "brave"
#   chromium-wrapper.sh --init brave       write a template profile
#   chromium-wrapper.sh --install FILE     wrap FILE's Exec= line (user override)
# No profile (or missing .conf) → legacy hardcoded Brave path, with a warning.

set -euo pipefail

# scripts_dir: resolve symlinked installs (install.sh's ~/.local/bin links) via
# realpath; fall back to the raw path on minimal systems without coreutils.
if command -v realpath &>/dev/null; then
  scripts_dir="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
else
  scripts_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
fi

# chromium-flags.sh is mandatory: the browser is always launched through it.
# Order: env override (tests), this script's realpath sibling, then PATH. The
# sibling is deterministic (install.sh copies everything into one dir; the
# store puts all scripts in bin/) — PATH-hunting once let a stale Nix-store
# /usr/bin copy shadow the fresh sibling under GUI/systemd launches.
CHROMIUM_FLAGS_SCRIPT="${CHROMIUM_FLAGS_SCRIPT:-$scripts_dir/chromium-flags.sh}"
[[ -x $CHROMIUM_FLAGS_SCRIPT ]] ||
  CHROMIUM_FLAGS_SCRIPT="$(command -v chromium-flags.sh 2>/dev/null || true)"
[[ -x $CHROMIUM_FLAGS_SCRIPT ]] || {
  echo "Error: chromium-flags.sh not found" >&2
  exit 1
}
readonly CHROMIUM_FLAGS_SCRIPT

# Overridable for tests; only PROFILE_DIR/CONTAINER_ENV_FILE/DRM_SYS_PATH are
# (the rest are root paths a test can't create). No DI scaffolding beyond tests.
readonly UPDATE_DEFER_SECONDS="${UPDATE_DEFER_SECONDS:-10}"
readonly PROFILE_DIR="${PROFILE_DIR:-$HOME/.config/chromium-wrapper}"
readonly CONTAINER_ENV_FILE="${CONTAINER_ENV_FILE:-/run/.containerenv}"

# GPU detection (DRM_SYS_PATH + detect_hybrid_graphics) lives in gpu-detect.sh.
# shellcheck source=./gpu-detect.sh disable=SC1091
source "$scripts_dir/gpu-detect.sh"

# Effective config. Defaults are legacy-safe; a profile (sourced) and the
# environment override these — environment ALWAYS wins over the .conf.
NOTIFY_APP="${NOTIFY_APP:-chromium-wrapper}"
CONTAINER_NAME="${CONTAINER_NAME:-}"
BROWSER_BINARY="${BROWSER_BINARY:-}"
FLATPAK_NAME="${FLATPAK_NAME:-}"
CHROME_GPU="${CHROME_GPU:-}" # igpu|dgpu — selects render node via vulkaninfo type

# --mode pins the legacy search to one path (flatpak|distrobox|legacy);
# empty = auto (legacy > flatpak > distrobox). --dry-run prints the launch
# command without executing (and skips background updates).
MODE="${MODE:-}"
DRY_RUN="${DRY_RUN:-false}"

# Legacy hardcoded path (today's brave-wrapper.sh behaviour), used when no
# profile is requested or the named .conf does not exist.
readonly LEGACY_CONTAINER="bravebox"
readonly LEGACY_FLATPAK_ID="com.brave.Browser"
readonly LEGACY_CANDIDATES=(brave brave-browser brave-browser-stable brave-browser-beta)

die() {
  echo "Error: $*" >&2
  exit 1
}

is_in_container() {
  [[ -n ${CONTAINER_ID:-} ]] ||
    [[ -f $CONTAINER_ENV_FILE ]] ||
    [[ -f /.dockerenv ]] ||
    grep -q container /proc/1/cgroup 2>/dev/null
}

is_flatpak_installed() {
  local id="${1:-$FLATPAK_NAME}"
  [[ -n $id ]] &&
    command -v flatpak &>/dev/null &&
    (flatpak info "$id" &>/dev/null || flatpak list --app 2>/dev/null | grep -q "$id")
}

# Load and validate a profile. Returns 1 (no error) if the .conf does not
# exist — main() then falls back to the legacy path.
load_profile() {
  local name="$1" f="$PROFILE_DIR/$1.conf"
  PROFILE="$1"
  [[ -f $f ]] || return 1
  # ponytail: profiles are sourced, not parsed — values must be valid bash.
  # Swap in a strict parser only if untrusted profiles become a concern.
  local env_bin="$BROWSER_BINARY" env_fp="$FLATPAK_NAME" env_cont="$CONTAINER_NAME"
  local env_app="$NOTIFY_APP" env_gpu="$CHROME_GPU"
  # shellcheck source=/dev/null
  source "$f"
  # Environment always overrides the .conf (and clears the mutually
  # exclusive counterpart).
  if [[ -n $env_fp ]]; then BROWSER_BINARY=""; fi
  if [[ -n $env_bin ]]; then FLATPAK_NAME=""; fi
  BROWSER_BINARY="${env_bin:-$BROWSER_BINARY}"
  FLATPAK_NAME="${env_fp:-$FLATPAK_NAME}"
  CONTAINER_NAME="${env_cont:-$CONTAINER_NAME}"
  NOTIFY_APP="${env_app:-$NOTIFY_APP}"
  CHROME_GPU="${env_gpu:-$CHROME_GPU}"
  if [[ -n $BROWSER_BINARY && -n $FLATPAK_NAME ]]; then
    die "profile '$PROFILE': BROWSER_BINARY and FLATPAK_NAME are mutually exclusive"
  fi
  if [[ -z $BROWSER_BINARY && -z $FLATPAK_NAME ]]; then
    die "profile '$PROFILE': set exactly one of BROWSER_BINARY or FLATPAK_NAME"
  fi
  return 0
}

init_profile() {
  local name="${1:-}"
  [[ -n $name ]] || die "--init requires a profile name"
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid profile name: $name"
  mkdir -p "$PROFILE_DIR"
  local f="$PROFILE_DIR/$name.conf"
  [[ -e $f ]] || {
    cat >"$f" <<EOF
# chromium-wrapper profile: $name
# Exactly ONE of BROWSER_BINARY / FLATPAK_NAME is required (mutually exclusive).
BROWSER_BINARY=
# FLATPAK_NAME=com.brave.Browser
# Optional — distrobox container to look up BROWSER_BINARY in:
# CONTAINER_NAME=bravebox
# Optional overrides — an env var of the same name always wins:
# NOTIFY_APP=chromium-wrapper
CHROME_GPU=
EOF
    echo "Wrote $f — edit it, then run: ${0##*/} -p $name"
    return 0
  }
  die "profile already exists: $f"
}

# Wrap a .desktop file's Exec= line in this wrapper and install it as a user
# override in $XDG_DATA_HOME/applications — the XDG user dir shadows system
# entries of the same name, and store paths are read-only, so the original
# file is never modified. The wrapper is referenced by absolute path: GUI/
# portal launches have no reliable PATH.
install_desktop() {
  local f="${1:-}"
  [[ -n $f ]] || die "--install requires a .desktop file path"
  [[ -f $f ]] || die "desktop file not found: $f"
  local exec_line rest
  exec_line=$(grep -m1 '^Exec=' "$f") || die "no Exec= line in $f"
  rest="${exec_line#Exec=}"
  local wrapper="$scripts_dir/chromium-wrapper.sh"
  if [[ ${rest%% *} == "$wrapper" || ${rest%% *} == "chromium-wrapper" ]]; then
    echo "Already wrapped: $f"
    return 0
  fi
  local dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  local dest="$dir/${f##*/}"
  mkdir -p "$dir"
  # --mode (if set) is baked in before the original binary, pinning the
  # search path for GUI/portal launches.
  local prefix="$wrapper"
  [[ -n $MODE ]] && prefix="$wrapper --mode $MODE"
  # ponytail: bash loop, not sed — the replacement side of sed would need
  # &/\ escaped for an arbitrary Exec value; a read loop can't be injected.
  # Each Exec= line keeps its own args (the store file carries several:
  # %U, none, --incognito).
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == Exec=* ]]; then
      printf 'Exec=%s %s\n' "$prefix" "${line#Exec=}"
    else
      printf '%s\n' "$line"
    fi
  done <"$f" >"$dest"
  echo "Installed: $dest"
}

legacy_setup() {
  if [[ -n ${PROFILE:-} ]]; then
    echo "Warning: profile '$PROFILE' not found ($PROFILE_DIR/$PROFILE.conf) — using legacy Brave defaults (create it with: ${0##*/} --init $PROFILE)" >&2
  else
    echo "Warning: no profile — using legacy Brave defaults (create one with: ${0##*/} --init brave)" >&2
  fi
  CONTAINER_NAME="$LEGACY_CONTAINER"
  FLATPAK_NAME="$LEGACY_FLATPAK_ID"
  # BRAVE_GPU is the legacy name; honored here only (env CHROME_GPU already wins).
  CHROME_GPU="${CHROME_GPU:-${BRAVE_GPU:-}}"
}

# ── Browser resolution ───────────────────────────────────────────────────────

# Sets BROWSER/LAUNCH_METHOD/UPDATE_METHOD/UPDATE_TARGET. Search order:
# legacy (local PATH) > flatpak > distrobox; --mode pins to one path.
# ponytail: `distrobox-enter` hangs when probed (blocks on terminal/tty), so
# container existence via `distrobox ls` is the only cheap signal.
find_browser() {
  local b
  if [[ $MODE == legacy || $MODE == "" ]]; then
    for b in "${LEGACY_CANDIDATES[@]}"; do
      if command -v "$b" &>/dev/null; then
        BROWSER="$b"
        LAUNCH_METHOD=direct
        UPDATE_METHOD=dnf
        UPDATE_TARGET="$b"
        return 0
      fi
    done
  fi
  if [[ $MODE == flatpak || $MODE == "" ]] && is_flatpak_installed; then
    BROWSER=flatpak
    LAUNCH_METHOD=flatpak
    UPDATE_METHOD=flatpak
    UPDATE_TARGET="$FLATPAK_NAME"
    return 0
  fi
  if [[ $MODE == distrobox || $MODE == "" ]] &&
    command -v distrobox &>/dev/null &&
    distrobox ls 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
    BROWSER=brave-browser
    LAUNCH_METHOD=distrobox
    UPDATE_METHOD=distrobox
    UPDATE_TARGET=brave-browser
    return 0
  fi
  return 1
}

resolve_legacy_browser() {
  find_browser || die "no Brave found (legacy path — try: ${0##*/} --init brave)"
}

# Profile: FLATPAK_NAME → flatpak; BROWSER_BINARY on host PATH → direct;
# BROWSER_BINARY in CONTAINER_NAME → distrobox; otherwise fail loudly.
resolve_profile_browser() {
  if [[ -n $FLATPAK_NAME ]]; then
    is_flatpak_installed || die "profile '$PROFILE': flatpak app $FLATPAK_NAME is not installed"
    BROWSER=flatpak
    LAUNCH_METHOD=flatpak
    UPDATE_METHOD=flatpak
    UPDATE_TARGET="$FLATPAK_NAME"
    return 0
  fi
  if command -v "$BROWSER_BINARY" &>/dev/null; then
    BROWSER="$BROWSER_BINARY"
    LAUNCH_METHOD=direct
    UPDATE_METHOD=dnf
    UPDATE_TARGET="$BROWSER"
    return 0
  fi
  # ponytail: same enter-hang as find_browser; container existence via ls.
  # If the container exists but lacks the binary, the failure surfaces at
  # launch (command not found) instead of resolution.
  if [[ -n $CONTAINER_NAME ]] &&
    command -v distrobox &>/dev/null &&
    distrobox ls 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
    BROWSER="$BROWSER_BINARY"
    LAUNCH_METHOD=distrobox
    UPDATE_METHOD=distrobox
    UPDATE_TARGET="$BROWSER"
    return 0
  fi
  die "profile '$PROFILE': $BROWSER_BINARY not found${CONTAINER_NAME:+ (host PATH or container $CONTAINER_NAME)}"
}

# ── GPU selection ────────────────────────────────────────────────────────────

# GPU policy (hybrid guard, CHROME_GPU/DRI_PRIME, node selection) lives in
# gpu-detect.sh's chromium_gpu_override; here we only inject the flag it
# names. No override (exit 1) or missing device → Chromium picks its own GPU.
apply_gpu_selection() {
  GPU_FLAGS=()
  local dev
  dev=$(chromium_gpu_override) || return 0
  [[ -e $dev ]] || return 0
  GPU_FLAGS=(--render-node-override="$dev")
}

# ── Notifications / updates ──────────────────────────────────────────────────

notify() {
  local title="$1" body="$2" urgency="${3:-normal}" timeout="${4:-3000}"
  [[ -z $title || -z $body ]] && return 0
  command -v notify-send &>/dev/null &&
    notify-send -a "$NOTIFY_APP" -u "$urgency" -t "$timeout" "$title" "$body" 2>/dev/null || true
}

# Flatpak updates via flatpak; everything else (host dnf / distrobox) via dnf.
# For distrobox, prefix the dnf/sudo calls with a distrobox-enter wrapper.
# ponytail: applying can still race a browser launched from the same container;
# safe only because dnf/rpm renames into place and a running inode stays valid.
_check_update() {
  if [[ $1 == "flatpak" ]]; then
    local probe
    probe=$(LC_ALL=C flatpak update --no-deploy -y "$2" 2>&1) || true
    [[ $probe != *"Nothing to do"* ]]
    return
  fi
  local prefix=() rc=0
  [[ $1 == "distrobox" ]] && prefix=(distrobox-enter -n "$CONTAINER_NAME" --)
  # ponytail: rc captured locally — a bare `$?` here only survives because
  # callers use `if !`, which suppresses errexit.
  "${prefix[@]}" dnf check-upgrade "$2" &>/dev/null || rc=$?
  [[ $rc -eq 100 ]] # 100 = updates available; 0 = none; anything else = error
}

_apply_update() {
  local strategy="$1" target="$2" out rc=0 prefix=()
  if [[ $strategy == "flatpak" ]]; then
    out=$(LC_ALL=C flatpak update -y "$target" 2>&1) || rc=$?
    if [[ $rc -eq 0 ]] && [[ $out == *"Updates complete"* ]]; then
      echo "$out"
      notify "Browser Updated" "Restart the browser to finish updating."
      return 0
    fi
    echo "Flatpak update failed." >&2
    notify "Update Failed" "Failed to update $target." critical
    return "$rc"
  fi
  [[ $strategy == "distrobox" ]] && prefix=(distrobox-enter -n "$CONTAINER_NAME" --)
  if ! "${prefix[@]}" sudo -n true &>/dev/null; then
    echo "Skipping update: passwordless sudo not configured${prefix[*]:+ in ${CONTAINER_NAME}}." >&2
    return 0
  fi
  out=$("${prefix[@]}" sudo dnf upgrade -y "$target" </dev/null 2>&1) || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "$out"
    notify "Update Available" "$target was upgraded. Restart the browser to apply updates."
    return 0
  fi
  echo "$out" >&2
  notify "Upgrade Failed" "Failed to upgrade $target." critical
  return "$rc"
}

perform_browser_update() {
  local strategy="$1" target="$2"
  echo "Checking for ${target} updates (${strategy})..."
  if ! _check_update "$strategy" "$target"; then
    echo "No updates found."
    return 0
  fi
  echo "Update available — deferring install until the browser is up."
  sleep "$UPDATE_DEFER_SECONDS"
  _apply_update "$strategy" "$target"
}

# ── Launch ───────────────────────────────────────────────────────────────────

# Print a command (one arg per word) for --dry-run; %q-quoting keeps the
# output copy-paste-runnable.
display_command() {
  printf 'Would launch:'
  local arg
  for arg in "$@"; do
    printf ' %q' "$arg"
  done
  printf '\n'
}

execute_launch() {
  local method="$1" browser="$2"
  shift 2
  local -a launch_cmd=()
  case "$method" in
  flatpak)
    launch_cmd=(flatpak "$CHROMIUM_FLAGS_SCRIPT" flatpak run "$FLATPAK_NAME" "$@")
    ;;
  distrobox)
    launch_cmd=(distrobox-enter "$CHROMIUM_FLAGS_SCRIPT"
      distrobox-enter -n "$CONTAINER_NAME" -- "$browser" "$@")
    ;;
  direct)
    launch_cmd=("$CHROMIUM_FLAGS_SCRIPT" "$browser" "$@")
    ;;
  esac
  if [[ $DRY_RUN == true ]]; then
    display_command "${launch_cmd[@]}"
    return 0
  fi
  if [[ $method == direct ]]; then
    exec "${launch_cmd[@]}"
  fi
  command -v "${launch_cmd[0]}" &>/dev/null || die "${launch_cmd[0]} not found"
  "${launch_cmd[@]}"
}

usage() {
  cat <<EOF
Usage: ${0##*/} [-p PROFILE] [--mode flatpak|distrobox|legacy] [--dry-run] [ARGS...]
                Launch a Chromium browser
       ${0##*/} --init PROFILE             Write a template profile .conf
       ${0##*/} --install FILE.desktop     Wrap FILE's Exec= line in this wrapper
                                            (writes a user override to $XDG_DATA_HOME/applications)
       ${0##*/} EXECUTABLE [ARGS...]       Wrap an arbitrary command via chromium-flags.sh

  -p PROFILE    load \$PROFILE_DIR/PROFILE.conf (env: BROWSER_PROFILE;
                PROFILE_DIR defaults to ~/.config/chromium-wrapper)
  --mode M      pin the legacy search to one path: flatpak, distrobox, or
                legacy (local PATH binary). Default (no --mode): legacy >
                flatpak > distrobox. Mutually exclusive with -p.
  --dry-run     print the command that would launch (with GPU flags) and
                exit; no browser, no background update.
  ARGS          passed through to the browser via chromium-flags.sh
EOF
}

main() {
  local profile="${BROWSER_PROFILE:-}" explicit=false
  local -a launch_args=()
  while (($#)); do
    case "$1" in
    -p | --profile)
      explicit=true
      (($# >= 2)) || die "-p requires a profile name (try: ${0##*/} --init brave)"
      profile="$2"
      shift 2
      ;;
    --init)
      init_profile "${2:-}"
      return 0
      ;;
    --install)
      install_desktop "${2:-}"
      return 0
      ;;
    --mode)
      (($# >= 2)) || die "--mode requires a value (flatpak|distrobox|legacy)"
      case "$2" in
      flatpak | distrobox | legacy) MODE="$2" ;;
      *) die "invalid --mode: $2 (expected flatpak|distrobox|legacy)" ;;
      esac
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h | --help)
      usage
      return 0
      ;;
    *)
      launch_args+=("$1")
      shift
      ;;
    esac
  done
  if [[ $explicit == true && -z $profile ]]; then
    die "-p requires a profile name (try: ${0##*/} --init brave)"
  fi
  if [[ $explicit == true && $MODE != "" ]]; then
    die "--mode and -p are mutually exclusive (profile already pins the path)"
  fi

  # Explicit executable first arg (absolute path, or a name PATH-resolved like
  # `flatpak run dev.vencord.Vesktop`): wrap the whole command via
  # chromium-flags.sh, appending GPU flags so a `flatpak run <appid>` keeps
  # them after the app id. No profile/legacy resolution, no background update —
  # we can't know what package owns the command.
  local cmd="${launch_args[0]:-}"
  [[ $cmd != /* ]] && cmd="$(command -v "$cmd" 2>/dev/null || true)"
  if [[ -n $cmd ]]; then
    [[ -x $cmd ]] || die "command not executable: ${launch_args[0]}"
    apply_gpu_selection
    if [[ $DRY_RUN == true ]]; then
      display_command "$CHROMIUM_FLAGS_SCRIPT" "$cmd" "${launch_args[@]:1}" "${GPU_FLAGS[@]}"
      return 0
    fi
    exec "$CHROMIUM_FLAGS_SCRIPT" "$cmd" "${launch_args[@]:1}" "${GPU_FLAGS[@]}"
  fi

  # No profile requested, or the named .conf does not exist → legacy path.
  if [[ -n $profile ]] && load_profile "$profile"; then
    resolve_profile_browser
  else
    legacy_setup
    resolve_legacy_browser
  fi

  # --dry-run: no side effects (no background update).
  if [[ $DRY_RUN != true && $LAUNCH_METHOD != "direct" ]]; then
    perform_browser_update "$UPDATE_METHOD" "$UPDATE_TARGET" </dev/null &
    disown || true
  fi

  apply_gpu_selection
  execute_launch "$LAUNCH_METHOD" "$BROWSER" "${GPU_FLAGS[@]}" "${launch_args[@]}"
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
