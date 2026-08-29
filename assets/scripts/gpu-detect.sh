#!/usr/bin/env bash
# Shared GPU detection helpers. Sourced by chromium-wrapper.sh and
# bazzified-steam.sh so both use one sysfs-based hybrid-graphics check.
# DRM_SYS_PATH is overridable (tests set it before sourcing).

readonly DRM_SYS_PATH="${DRM_SYS_PATH:-/sys/class/drm}"

# Map every CONNECTED connector to the GPU (PCI id) driving it.
# niri output names match the sysfs connector suffix: card0-HDMI-A-2 -> HDMI-A-2.
# Prints one line per connected output: "<output>\t<gpu-pci-id>".
# ponytail: globs /sys/class/drm, no drm lib; connector name derived by
# stripping the card prefix so it lines up with `niri msg outputs` keys.
connector_gpu_map() {
  local card prefix conn name gpu
  for card in "$DRM_SYS_PATH"/card[0-9]*; do
    [[ -d "$card/device" ]] || continue
    gpu=$(readlink -f "$card/device")
    gpu=${gpu##*/}
    prefix=${card##*/}
    for conn in "$card"/*; do
      [[ -f "$conn/status" ]] || continue
      grep -q '^connected$' "$conn/status" || continue
      name=${conn##*/}
      name=${name#"$prefix"-}
      printf '%s\t%s\n' "$name" "$gpu"
    done
  done
}

gpu_of_output() {
  local map
  map="$(connector_gpu_map)"
  awk -F'\t' -v o="$1" '$1 == o { print $2; exit }' <<<"$map"
}

outputs_of_gpu() {
  local map
  map="$(connector_gpu_map)"
  awk -F'\t' -v g="$1" '$2 == g { print $1 }' <<<"$map"
}

# Hybrid graphics is "in use" (not merely enabled) only when >=2 distinct GPU
# devices each drive a connected output - i.e. the desktop actually spans GPUs.
# ponytail: derived from connector_gpu_map (single source of truth); counts
# distinct GPUs with a connected connector. Prints the count, returns 0 if hybrid.
detect_hybrid_graphics() {
  local gpu
  local -A seen=()
  while read -r _ gpu; do
    [[ -n ${seen[$gpu]:-} ]] && continue
    seen[$gpu]=1
  done < <(connector_gpu_map)
  echo "${#seen[@]}"
  ((${#seen[@]} >= 2))
}

gpu_detect_self_test() {
  local root self
  self="${BASH_SOURCE[0]}"
  root="$(mktemp -d)"
  trap 'rm -rf "$root"' RETURN
  mkdir -p "$root/sys/devices/pci/0000:00:02.0" "$root/sys/devices/pci/0000:01:00.0"
  mkdir -p "$root/sys/class/drm/card0/card0-DP-4"
  mkdir -p "$root/sys/class/drm/card1/card1-HDMI-A-2" "$root/sys/class/drm/card1/card1-HDMI-A-1"
  ln -s "$root/sys/devices/pci/0000:00:02.0" "$root/sys/class/drm/card0/device"
  ln -s "$root/sys/devices/pci/0000:01:00.0" "$root/sys/class/drm/card1/device"
  printf 'connected' >"$root/sys/class/drm/card0/card0-DP-4/status"
  printf 'connected' >"$root/sys/class/drm/card1/card1-HDMI-A-2/status"
  printf 'disconnected' >"$root/sys/class/drm/card1/card1-HDMI-A-1/status"

  # ponytail: DRM_SYS_PATH is readonly here, so exercise the helpers in a
  # child that sources this file with the mock path passed via env.
  # shellcheck disable=SC2016 # $SELFTEST_SELF is expanded by the child bash
  env DRM_SYS_PATH="$root/sys/class/drm" SELFTEST_SELF="$self" bash -c '
    source "$SELFTEST_SELF"
    connector_gpu_map >/dev/null || { echo "self-test: connector_gpu_map failed" >&2; exit 1; }
    out="$(gpu_of_output HDMI-A-2)"
    [[ $out == "0000:01:00.0" ]] || { echo "self-test: gpu_of_output HDMI-A-2 = $out" >&2; exit 1; }
    out="$(gpu_of_output DP-4)"
    [[ $out == "0000:00:02.0" ]] || { echo "self-test: gpu_of_output DP-4 = $out" >&2; exit 1; }
    out="$(outputs_of_gpu 0000:01:00.0)"
    [[ $out == "HDMI-A-2" ]] || { echo "self-test: outputs_of_gpu = $out" >&2; exit 1; }
    out="$(gpu_of_output HDMI-A-1)"
    [[ -z $out ]] || { echo "self-test: disconnected HDMI-A-1 mapped = $out" >&2; exit 1; }
    echo "gpu-detect self-test ok"
  ' || return 1
}

if [[ ${BASH_SOURCE[0]} == "$0" && ${1:-} == "--self-test" ]]; then
  gpu_detect_self_test
fi
