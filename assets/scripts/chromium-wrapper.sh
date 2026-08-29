#!/usr/bin/env bash
# Generic Chromium browser wrapper: launches any Chromium fork via host binary,
# flatpak, or (custom-named) distrobox container, driven by per-browser profile
# files. Injects flags through chromium-flags.sh; runs background updates for
# the strategy in use.
#
# Profiles: ~/.config/chromium-wrapper/<profile>.conf (env: PROFILE_DIR)
#   chromium-wrapper.sh -p brave <URL>     load profile "brave"
#   chromium-wrapper.sh --init brave       write a template profile
# No profile (or missing .conf) → legacy hardcoded Brave path, with a warning.

set -euo pipefail

# chromium-flags.sh is mandatory: the browser is always launched through it.
# ponytail: prefer a PATH-resolved chromium-flags.sh (covers install.sh's
# symlink and the store bin); fall back to a sibling of this script.
scripts_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
CHROMIUM_FLAGS_SCRIPT="$(command -v chromium-flags.sh 2>/dev/null || true)"
[[ -x $CHROMIUM_FLAGS_SCRIPT ]] ||
  CHROMIUM_FLAGS_SCRIPT="$scripts_dir/chromium-flags.sh"
if [[ ! -x $CHROMIUM_FLAGS_SCRIPT ]]; then
  echo "Error: chromium-flags.sh not found" >&2
  exit 1
fi
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
IGPU_PCI_ID="${IGPU_PCI_ID:-0x164e}" # render-node PCI device id (igpu: Raphael APU)
DGPU_PCI_ID="${DGPU_PCI_ID:-0x7550}" # render-node PCI device id (dgpu: RX 9070 XT)
CHROME_GPU="${CHROME_GPU:-}"         # igpu|dgpu — selects the render node

# Legacy hardcoded path (today's brave-wrapper.sh behaviour), used when no
# profile is requested or the named .conf does not exist.
readonly LEGACY_CONTAINER="bravebox"
readonly LEGACY_FLATPAK_ID="com.brave.Browser"
readonly LEGACY_CANDIDATES=(brave brave-browser-beta brave-browser)

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
  local env_app="$NOTIFY_APP" env_igpu="$IGPU_PCI_ID" env_dgpu="$DGPU_PCI_ID" env_gpu="$CHROME_GPU"
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
  IGPU_PCI_ID="${env_igpu:-$IGPU_PCI_ID}"
  DGPU_PCI_ID="${env_dgpu:-$DGPU_PCI_ID}"
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
# IGPU_PCI_ID=0x164e
# DGPU_PCI_ID=0x7550
CHROME_GPU=
EOF
    echo "Wrote $f — edit it, then run: ${0##*/} -p $name"
    return 0
  }
  die "profile already exists: $f"
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

# Legacy: flatpak first, then host candidates, then bravebox.
find_browser() {
  if is_flatpak_installed; then
    echo "flatpak"
    return 0
  fi
  local b
  for b in "${LEGACY_CANDIDATES[@]}"; do
    command -v "$b" &>/dev/null && {
      echo "$b"
      return 0
    }
  done
  # ponytail: `distrobox-enter` hangs when probed (blocks on terminal/tty),
  # so container existence via `distrobox ls` is the only cheap signal.
  if command -v distrobox &>/dev/null &&
    distrobox ls 2>/dev/null | grep -qw "$CONTAINER_NAME"; then
    echo "brave-browser"
    return 0
  fi
  return 1
}

resolve_legacy_browser() {
  local container=false
  is_in_container && container=true
  BROWSER=$(find_browser) || die "no Brave found (legacy path — try: ${0##*/} --init brave)"
  if [[ $BROWSER == "flatpak" ]]; then
    LAUNCH_METHOD=flatpak
    UPDATE_METHOD=flatpak
    UPDATE_TARGET="$FLATPAK_NAME"
  elif [[ $container == false ]]; then
    LAUNCH_METHOD=distrobox
    UPDATE_METHOD=distrobox
    UPDATE_TARGET="$BROWSER"
  else
    LAUNCH_METHOD=direct
    UPDATE_METHOD=dnf
    UPDATE_TARGET="$BROWSER"
  fi
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

# CHROME_GPU=igpu|dgpu selects the GPU via --render-node-override: the only
# lever that moves Chromium's Wayland GL renderer (env vars / --gpu-* are
# ignored by the Wayland GL path). Match the render node by PCI id, then
# verify the resolved /dev node still exists.
# (detect_hybrid_graphics is provided by gpu-detect.sh)
apply_gpu_selection() {
  local target="$IGPU_PCI_ID"
  [[ $CHROME_GPU == "dgpu" ]] && target="$DGPU_PCI_ID"
  GPU_FLAGS=()
  local rn v d dev
  for rn in "$DRM_SYS_PATH"/renderD[0-9]*; do
    [[ -r "$rn/device/vendor" && -r "$rn/device/device" ]] || continue
    v=$(cat "$rn/device/vendor")
    d=$(cat "$rn/device/device")
    [[ $v == "0x1002" && $d == "$target" ]] || continue
    dev="/dev/dri/${rn##*/}"
    [[ -e $dev ]] || continue
    GPU_FLAGS=(--render-node-override="$dev")
    break
  done
}

# Hybrid graphics: when ≥2 GPUs each drive an output, pick one explicitly.
# Default to the iGPU; only CHROME_GPU=dgpu overrides that. Single-GPU systems
# leave CHROME_GPU unset and let apply_gpu_selection's own default handle it.
resolve_gpu_flags() {
  if [[ -z $CHROME_GPU ]] && detect_hybrid_graphics &>/dev/null; then
    CHROME_GPU=igpu
  fi
  apply_gpu_selection
}

# ── Notifications / updates ──────────────────────────────────────────────────

notify() {
  local title="$1" body="$2" urgency="${3:-normal}" timeout="${4:-3000}"
  [[ -z $title || -z $body ]] && return 0
  command -v notify-send &>/dev/null &&
    notify-send -a "$NOTIFY_APP" -u "$urgency" -t "$timeout" "$title" "$body" 2>/dev/null || true
}

run_command_or_fail() {
  local cmd="$1"
  shift
  command -v "$cmd" &>/dev/null || {
    echo "Error: $cmd command not found" >&2
    return 1
  }
  "$@"
}

# Flatpak updates via flatpak; everything else (host dnf / distrobox) via dnf.
# For distrobox, prefix the dnf/sudo calls with a distrobox-enter wrapper.
# ponytail: applying can still race a browser launched from the same container;
# safe only because dnf/rpm renames into place and a running inode stays valid.
_check_update() {
  if [[ $1 == "flatpak" ]]; then
    local probe
    probe=$(flatpak update --no-deploy -y "$2" 2>&1) || true
    [[ $probe != *"Nothing to do"* ]]
    return
  fi
  local prefix=()
  [[ $1 == "distrobox" ]] && prefix=(distrobox-enter -n "$CONTAINER_NAME" --)
  "${prefix[@]}" dnf check-update "$2" &>/dev/null
  [[ $? -eq 100 ]] # 100 = updates available; 0 = none; anything else = error
}

_apply_update() {
  local strategy="$1" target="$2" out rc=0 prefix=()
  if [[ $strategy == "flatpak" ]]; then
    out=$(flatpak update -y "$target" 2>&1) || rc=$?
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

execute_launch() {
  local method="$1" browser="$2"
  shift 2
  case "$method" in
  flatpak)
    run_command_or_fail flatpak "$CHROMIUM_FLAGS_SCRIPT" flatpak run "$FLATPAK_NAME" "$@"
    ;;
  distrobox)
    run_command_or_fail distrobox-enter "$CHROMIUM_FLAGS_SCRIPT" \
      distrobox-enter -n "$CONTAINER_NAME" -- "$browser" "$@"
    ;;
  direct)
    exec "$CHROMIUM_FLAGS_SCRIPT" "$browser" "$@"
    ;;
  esac
}

_dispatch() {
  local cmd="$1"
  shift
  case "$cmd" in
  in-container) is_in_container ;;
  # Legacy default: the helper runs outside legacy_setup, so apply the
  # legacy container here or the distrobox check is skipped.
  find-browser)
    CONTAINER_NAME="${CONTAINER_NAME:-$LEGACY_CONTAINER}"
    find_browser
    ;;
  flatpak-installed) is_flatpak_installed "${1:-$FLATPAK_NAME}" ;;
  detect-hybrid) detect_hybrid_graphics ;;
  notify) notify "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
  launch-flatpak) execute_launch flatpak flatpak "$@" ;;
  launch-distrobox) execute_launch distrobox "${1:-brave-browser}" "${@:2}" ;;
  launch-direct) execute_launch direct "${1:-brave-browser}" "${@:2}" ;;
  bg-update) perform_browser_update "${1:-dnf}" "${2:-brave-browser}" ;;
  flatpak-update-check) perform_browser_update flatpak "${1:-$LEGACY_FLATPAK_ID}" ;;
  *)
    die "unknown helper: $cmd"
    ;;
  esac
}

usage() {
  cat <<EOF
Usage: ${0##*/} [-p PROFILE] [ARGS...]     Launch a Chromium browser
       ${0##*/} --init PROFILE             Write a template profile .conf
       ${0##*/} --helper-<name> [ARGS...]  Internal (used by tests/spawn-browser)

  -p PROFILE    load \$PROFILE_DIR/PROFILE.conf (env: BROWSER_PROFILE;
                PROFILE_DIR defaults to ~/.config/chromium-wrapper)
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

  # No profile requested, or the named .conf does not exist → legacy path.
  if [[ -n $profile ]] && load_profile "$profile"; then
    resolve_profile_browser
  else
    legacy_setup
    resolve_legacy_browser
  fi

  if [[ $LAUNCH_METHOD != "direct" ]]; then
    perform_browser_update "$UPDATE_METHOD" "$UPDATE_TARGET" </dev/null &
    disown || true
  fi

  resolve_gpu_flags
  execute_launch "$LAUNCH_METHOD" "$BROWSER" "${GPU_FLAGS[@]}" "${launch_args[@]}"
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  if [[ ${1:-} == --helper-* ]]; then
    _dispatch "${1#--helper-}" "${@:2}"
  else
    main "$@"
  fi
fi
