#!/usr/bin/env bash
set -euo pipefail

readonly FLAGS_CONFIG="${FLAGS_CONFIG:-${HOME}/.config/chromium-flags.conf}"

# Skip blank/comment lines. `read` with default IFS already trims surrounding
# whitespace, so the read line is the trimmed flag.
load_flags() {
  [[ -f $FLAGS_CONFIG ]] || return 0

  local flags=() line
  while read -r line || [[ -n $line ]]; do
    [[ -n $line && $line != \#* ]] && flags+=("$line")
  done <"$FLAGS_CONFIG"
  printf '%s\n' "${flags[@]}"
}

# Each strategy rewrites the full argument list, injecting FLAGS_LIST after
# the command / app id / browser binary as appropriate.
strategy_standard() {
  printf '%s\n' "$1" "${FLAGS_LIST[@]}" "${@:2}"
}

strategy_flatpak() {
  local args=("$@")
  # Format: flatpak run [global opts...] <app-id> [args...]. Skip the global
  # options after `run` so flags land right after the app id — the only
  # position flatpak forwards them to the launched command.
  local i=2
  while ((i < ${#args[@]})) && [[ ${args[i]} == -* ]]; do ((i++)); done
  printf '%s\n' "${args[0]:-}" "${args[1]:-}" "${args[@]:2:i-2}" \
    "${args[i]:-}" "${FLAGS_LIST[@]}" "${args[@]:i+1}"
}

strategy_distrobox() {
  local args=("$@")
  local flags=("${FLAGS_LIST[@]}")
  local after_dash_dash=false
  local browser_found=false
  local result=()

  for arg in "${args[@]}"; do
    if [[ $after_dash_dash == true && $browser_found == false ]]; then
      browser_found=true
      result+=("$arg")
      [[ ${#flags[@]} -gt 0 ]] && result+=("${flags[@]}")
    elif [[ $arg == "--" ]]; then
      after_dash_dash=true
      result+=("$arg")
    else
      result+=("$arg")
    fi
  done
  printf '%s\n' "${result[@]}"
}

main() {
  local dry_run=false
  if [[ ${1:-} == "--dry-run" ]]; then
    dry_run=true
    shift
  fi

  if [[ $# -lt 1 ]]; then
    echo "Usage: ${0##*/} [--dry-run] <command> [args...]" >&2
    exit 1
  fi

  # Load flags into a global array for strategies to access
  mapfile -t FLAGS_LIST < <(load_flags)

  local cmd="${1:-}"
  local final_args=()

  # Dispatch on the basename so an absolute path (e.g. /usr/bin/flatpak)
  # selects the same strategy as the bare command name.
  if [[ ${cmd##*/} == "flatpak" && ${2:-} == "run" ]]; then
    mapfile -t final_args < <(strategy_flatpak "$@")
  elif [[ ${cmd##*/} == "distrobox-enter" || ${cmd##*/} == "distrobox" ]]; then
    mapfile -t final_args < <(strategy_distrobox "$@")
  else
    mapfile -t final_args < <(strategy_standard "$@")
  fi

  if [[ $dry_run == true ]]; then
    printf '%s\n' "${final_args[@]}"
    exit 0
  fi

  exec "${final_args[@]}"
}

main "$@"
