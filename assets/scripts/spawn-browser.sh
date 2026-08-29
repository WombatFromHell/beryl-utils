#!/usr/bin/env bash
# new-browser-window — open a new browser window using the system default

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

SEARCH_PATHS=(
  "$HOME/.local/share/applications"
  "$HOME/.local/share/flatpak/exports/share/applications"
  /usr/local/share/applications
  /usr/share/applications
  /var/lib/flatpak/exports/share/applications
  /run/current-system/sw/share/applications
  "$HOME/.nix-profile/share/applications"
  "$HOME/.local/share/nix-profile/share/applications"
)

NEW_WINDOW_BROWSERS=(
  firefox librewolf waterfox google-chrome chromium
  brave microsoft-edge vivaldi floorp epiphany gnome-web
)

# ── Text Processing ──────────────────────────────────────────────────────────

# Remove FreeDesktop field codes (%f, %u, %U, etc.) and @@ markers.
strip_field_codes() {
  echo "$1" | sed 's/%[a-zA-Z]//g; s/@@[^ ]*//g; s/^ *//; s/ *$//'
}

# Substitute %U/%u with a URL, then strip remaining field codes.
apply_url() {
  local cmd="$1" url="${2:-}"
  if [[ -n $url ]]; then
    cmd="$(echo "$cmd" | sed "s|%U|$url|g; s|%u|$url|g")"
  fi
  strip_field_codes "$cmd"
}

# ── Desktop File Lookup ──────────────────────────────────────────────────────

find_desktop_path() {
  local desktop_file="$1" dir
  for dir in "${SEARCH_PATHS[@]}"; do
    [[ -f "$dir/$desktop_file" ]] && {
      echo "$dir/$desktop_file"
      return 0
    }
  done
  return 1
}

is_flatpak_desktop_file() {
  [[ $1 =~ ^[a-zA-Z][a-zA-Z0-9-]*\.[a-zA-Z][a-zA-Z0-9-]*\.[a-zA-Z0-9][a-zA-Z0-9-]*\.desktop$ ]]
}

extract_exec_line() {
  grep -m1 '^Exec=' "$1" | sed 's/^Exec=//'
}

# ── Browser Capabilities ─────────────────────────────────────────────────────

supports_new_window() {
  local name="$1" pattern
  for pattern in "${NEW_WINDOW_BROWSERS[@]}"; do
    [[ $name == "$pattern"* ]] && return 0
  done
  return 1
}

new_window_flag() {
  supports_new_window "$1" && echo "--new-window" || true
}

# ── Launcher Detection ───────────────────────────────────────────────────────

detect_launcher_type() {
  local line="$1"
  if [[ $line =~ ^(/usr/bin/)?flatpak[[:space:]]+run ]]; then
    echo "flatpak"
  elif [[ $line =~ ^distrobox[[:space:]]+run[[:space:]]+([^[:space:]]+) ]]; then
    echo "distrobox"
  else
    echo "native"
  fi
}

# ── Command Building ─────────────────────────────────────────────────────────

build_spawn_cmd() {
  local launcher_type="$1" target="$2" browser_name="$3"
  local flag
  flag="$(new_window_flag "$browser_name")"

  case "$launcher_type" in
  flatpak) echo "flatpak run $target${flag:+ $flag}" ;;
  distrobox) echo "distrobox run $target --${flag:+ $flag}" ;;
  native) echo "$target${flag:+ $flag}" ;;
  esac
}

# ── Browser Spawning ─────────────────────────────────────────────────────────

spawn_browser() {
  local launcher_type="$1" target="$2" browser_name="$3"
  shift 3

  if ! supports_new_window "$browser_name"; then
    echo "Warning: unknown browser '$browser_name', trying without --new-window" >&2
  fi

  local cmd=()
  [[ -n ${PREFIX:-} ]] && cmd+=("$PREFIX")

  local spawn_cmd
  spawn_cmd="$(build_spawn_cmd "$launcher_type" "$target" "$browser_name")"
  read -ra cmd_parts <<<"$spawn_cmd"
  cmd+=("${cmd_parts[@]}")

  exec "${cmd[@]}" "$@"
}

# ── Launcher-Specific Resolution ─────────────────────────────────────────────

resolve_flatpak() {
  local exec_line="$1"
  local app_id
  app_id="$(echo "$exec_line" | grep -oiE '[a-z][a-z0-9]*\.[a-z][a-z0-9.-]*\.[a-z][a-z0-9.-]*' | head -n1)"

  [[ -z $app_id ]] && {
    echo "Error: could not determine flatpak app ID from '$exec_line'" >&2
    exit 1
  }

  local browser_name
  if [[ $exec_line =~ --command=([^[:space:]]+) ]]; then
    browser_name="${BASH_REMATCH[1]}"
  else
    browser_name="$app_id"
  fi

  spawn_browser "flatpak" "$app_id" "$browser_name" "${URL:+"$URL"}"
}

resolve_distrobox() {
  local exec_line="$1"
  [[ $exec_line =~ ^distrobox[[:space:]]+run[[:space:]]+([^[:space:]]+) ]] || {
    echo "Error: could not parse distrobox command" >&2
    exit 1
  }

  local container="${BASH_REMATCH[1]}"
  local distro_cmd
  distro_cmd="${exec_line##*--}"
  distro_cmd="${distro_cmd#"${distro_cmd%%[![:space:]]*}"}"

  local browser_bin="${distro_cmd%% *}"
  [[ -z $browser_bin ]] && {
    echo "Error: could not determine browser command from '$exec_line'" >&2
    exit 1
  }

  spawn_browser "distrobox" "$container" "$browser_bin" "${URL:+"$URL"}"
}

resolve_native() {
  local exec_line="$1"
  local browser_bin="${exec_line%% *}"
  browser_bin="$(command -v "$browser_bin" 2>/dev/null || echo "$browser_bin")"

  [[ -z $browser_bin ]] && {
    echo "Error: could not resolve browser binary" >&2
    exit 1
  }

  spawn_browser "native" "$browser_bin" "$(basename "$browser_bin")" "${URL:+"$URL"}"
}

# ── Helper Subcommands ───────────────────────────────────────────────────────

run_helper() {
  local name="$1"
  shift
  case "$name" in
  find-path) find_desktop_path "$(cat)" ;;
  extract-exec) extract_exec_line "$1" ;;
  strip-field-codes) strip_field_codes "$1" ;;
  detect-launcher) detect_launcher_type "$(cat)" ;;
  is-flatpak-desktop) is_flatpak_desktop_file "$1" ;;
  substitute-url) apply_url "$1" "$2" ;;
  build-cmd) build_spawn_cmd "$1" "$2" "$3" ;;
  find-desktop-file)
    local input
    input="$(cat)"
    if [[ -z $input ]]; then
      echo "Error: could not determine default browser" >&2
      return 1
    fi
    echo "$input"
    ;;
  *)
    echo "Error: unknown helper '$name'" >&2
    return 1
    ;;
  esac
}

# ── Main ─────────────────────────────────────────────────────────────────────

URL="${1:-}"

if [[ ${1:-} == --helper-* ]]; then
  run_helper "${1#--helper-}" "${@:2}"
  exit $?
fi

# Locate the default browser's .desktop file
DESKTOP_FILE="$(xdg-settings get default-web-browser 2>/dev/null)" || {
  echo "Error: could not determine default browser" >&2
  exit 1
}

DESKTOP_PATH="$(find_desktop_path "$DESKTOP_FILE")"

[[ -z $DESKTOP_PATH ]] && {
  echo "Error: .desktop file not found for '$DESKTOP_FILE'" >&2
  exit 1
}

RAW_EXEC_LINE="$(extract_exec_line "$DESKTOP_PATH")"

# Wrapper scripts (chromium-flags.sh, chromium-wrapper.sh) are exec'd directly
if [[ $RAW_EXEC_LINE =~ chromium-flags\.sh|chromium-wrapper\.sh ]]; then
  exec bash -c "$(apply_url "$RAW_EXEC_LINE" "$URL")"
fi

# Standard path: strip field codes then dispatch by launcher type
EXEC_LINE="$(strip_field_codes "$RAW_EXEC_LINE")"
LAUNCHER_TYPE="$(detect_launcher_type "$EXEC_LINE")"

case "$LAUNCHER_TYPE" in
flatpak) resolve_flatpak "$EXEC_LINE" ;;
distrobox) resolve_distrobox "$EXEC_LINE" ;;
native)
  # Sanity-check: the base command must be resolvable on PATH
  base_cmd="${EXEC_LINE%% *}"
  if ! command -v "$base_cmd" &>/dev/null; then
    echo "Error: '$base_cmd' from '$EXEC_LINE' not found on PATH" >&2
    exit 1
  fi
  resolve_native "$EXEC_LINE"
  ;;
esac
