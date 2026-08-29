#!/usr/bin/env bash
set -euo pipefail

#==============================================================================
# Chromium Flags Loader (Strategy Pattern Refactor)
#==============================================================================

readonly FLAGS_CONFIG="${FLAGS_CONFIG:-${HOME}/.config/chromium-flags.conf}"

#------------------------------------------------------------------------------
# DATA LAYER: Load and clean flags
#------------------------------------------------------------------------------
load_flags() {
  if [[ ! -f $FLAGS_CONFIG ]]; then
    return 0
  fi

  local flags=()
  while IFS= read -r line || [[ -n $line ]]; do
    # Trim whitespace and skip empty/comments
    local trimmed
    trimmed=$(echo "$line" | xargs)
    [[ -z $trimmed || $trimmed == \#* ]] && continue
    flags+=("$trimmed")
  done <"$FLAGS_CONFIG"

  printf '%s\n' "${flags[@]}"
}

#------------------------------------------------------------------------------
# STRATEGY LAYER: Argument Transformation Logic
# Each strategy receives the FULL list of arguments passed to the script.
#------------------------------------------------------------------------------

strategy_standard() {
  local args=("$@")
  local cmd="${args[0]:-}"
  shift # Remove command from array for processing

  local remaining=("${args[@]:1}")
  local flags=("${FLAGS_LIST[@]}")

  # Output: [command] [flags...] [remaining args...]
  printf '%s\n' "$cmd" "${flags[@]}" "${remaining[@]}"
}

strategy_flatpak() {
  local args=("$@")
  # Expected format: flatpak run <app-id> [args...]
  local cmd="${args[0]:-}"
  local action="${args[1]:-}"
  local app_id="${args[2]:-}"

  shift 3 || true # Safely shift to get remaining args
  local remaining=("$@")
  local flags=("${FLAGS_LIST[@]}")

  printf '%s\n' "$cmd" "$action" "$app_id" "${flags[@]}" "${remaining[@]}"
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

#------------------------------------------------------------------------------
# DISPATCHER / CONTEXT LAYER
#------------------------------------------------------------------------------

main() {
  local dry_run=false
  if [[ ${1:-} == "--dry-run" ]]; then
    dry_run=true
    shift
  fi

  if [[ $# -lt 1 ]]; then
    echo "Usage: chromium-flags.sh [--dry-run] <command> [args...]" >&2
    exit 1
  fi

  # Load flags into a global array for strategies to access
  mapfile -t FLAGS_LIST < <(load_flags)

  local command="${1:-}"
  local final_args=()

  # Strategy Selection (The "Context")
  if [[ $command == "flatpak" && ${2:-} == "run" ]]; then
    mapfile -t final_args < <(strategy_flatpak "$@")
  elif [[ $command == "distrobox-enter" || $command == "distrobox" ]]; then
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
