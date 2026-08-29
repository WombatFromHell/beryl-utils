#!/usr/bin/env bash
set -euo pipefail

# Power off every enabled output except the designated "external" monitor
# (e.g. the living-room TV) when idle, and restore exactly those outputs
# when active. Disabled outputs are left disabled.
#
# The external monitor is identified by (first match wins):
#   1. ON_IDLE_EXTERNAL_NAME   - exact niri output name (e.g. HDMI-A-2)
#   2. ON_IDLE_EXTERNAL_IDENT  - EDID identity string (default below),
#                                matched case-insensitively as a substring of
#                                "<make> <model> <serial>"
#
# Output<->GPU association comes from gpu-detect.sh's sysfs map.

scripts_dir="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=./gpu-detect.sh disable=SC1091
source "$scripts_dir/gpu-detect.sh"

STATE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/on_idle_off.lst"
EXT_NAME="${ON_IDLE_EXTERNAL_NAME:-}"
# Default external monitor identity: the LG TV's EDID string. Pin the serial
# (append " 0x01010101") for a strict make+model+serial match.
EXT_IDENT="${ON_IDLE_EXTERNAL_IDENT:-LG Electronics LG TV SSCR2}"

for cmd in niri jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "$cmd not found; aborting on_idle" >&2
    exit 1
  }
done

# Single niri interface so the `niri msg -j outputs` invocation lives in one
# place (change it once if niri's call shape changes).
niri_outputs() {
  niri msg -j outputs 2>/dev/null
}

enabled_outputs() {
  niri_outputs | jq -r 'to_entries[] | select(.value.current_mode != null) | .key'
}

external_by_name() {
  [[ -n $EXT_NAME ]] || return 0
  niri_outputs | jq -r --arg n "$EXT_NAME" 'to_entries[] | select(.key == $n) | .key'
}

external_by_edid() {
  [[ -z $EXT_IDENT ]] && return 0
  # ponytail: substring match (grep -iF) of EXT_IDENT against the joined
  # "<make> <model> <serial>" identity. Upgrade to exact-field jq if a
  # collision ever appears. `|| true` neutralizes grep's no-match exit
  # under pipefail.
  niri_outputs | jq -r '
    to_entries[] | "\(.key)\t\(.value.make) \(.value.model) \(.value.serial)"' |
    grep -iF "$EXT_IDENT" | head -n1 | cut -f1 || true
}

find_external() {
  local o
  o="$(external_by_name)"
  [[ -n $o ]] && {
    echo "$o"
    return
  }
  external_by_edid
}

idle() {
  local ext gpu
  ext="$(find_external)"
  if [[ -z $ext ]]; then
    echo "no external monitor identified; nothing to do" >&2
    return 0
  fi
  gpu="$(gpu_of_output "$ext")"
  echo "idle: keeping external '$ext'${gpu:+ (gpu $gpu)} powered, DPMS-off the rest" >&2
  : >"$STATE"
  while read -r o; do
    [[ -n $o && $o != "$ext" ]] || continue
    if niri msg output "$o" off 2>/dev/null; then
      echo "$o" >>"$STATE"
    fi
  done < <(enabled_outputs)
}

active() {
  [[ -f $STATE ]] || return 0
  while read -r o; do
    [[ -n $o ]] || continue
    niri msg output "$o" on 2>/dev/null || true
  done <"$STATE"
  rm -f "$STATE"
}

case "${1:-}" in
idle) idle ;;
active) active ;;
find-external) find_external ;;
*)
  echo "Usage: $0 {idle|active|find-external}" >&2
  exit 1
  ;;
esac
