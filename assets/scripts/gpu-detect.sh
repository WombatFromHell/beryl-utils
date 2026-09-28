#!/usr/bin/env bash
# Shared GPU detection helpers. Sourced by chromium-wrapper.sh and
# bazzified-steam.sh so both use one sysfs-based hybrid-graphics check.
# DRM_SYS_PATH is overridable (tests set it before sourcing).
readonly DRM_SYS_PATH="${DRM_SYS_PATH:-/sys/class/drm}"

# Resolve the PCI id (e.g. "0000:01:00.0") behind a DRM node's `device`
# symlink. Works for any node under DRM_SYS_PATH - cardN or renderDNNN,
# since both expose the same device symlink shape.
# ponytail: single source of truth for this lookup; connector_gpu_map calls
# it instead of re-deriving the PCI id inline.
pci_id_of_drm_node() {
  local dev
  dev=$(readlink -f "$DRM_SYS_PATH/$1/device") || return 1
  echo "${dev##*/}"
}

# Map every CONNECTED connector to the GPU (PCI id) driving it.
# niri output names match the sysfs connector suffix: card0-HDMI-A-2 -> HDMI-A-2.
# Prints one line per connected output: "<output>\t<gpu-pci-id>".
# ponytail: globs /sys/class/drm, no drm lib; connector name derived by
# stripping the card prefix so it lines up with `niri msg outputs` keys.
connector_gpu_map() {
  local card prefix conn name gpu
  for card in "$DRM_SYS_PATH"/card[0-9]*; do
    [[ -d "$card/device" ]] || continue
    gpu=$(pci_id_of_drm_node "${card##*/}") || continue
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

# Parse vulkaninfo --summary into a GPU PCI device-id → deviceType mapping.
# deviceType is DISCRETE_GPU | INTEGRATED_GPU | CPU (plus any future types).
# Cached per process; second call is a no-op.
# ponytail: grep + awk over vulkaninfo text; the --summary format is stable
# across Mesa versions (GPU blocks with vendorID/deviceID/deviceType lines).
# Upgrade path: switch to vulkaninfo --json if it ever ships.
vulkaninfo_gpu_types() {
  [[ ${_VULKANINFO_GPU_TYPES_READY:-} ]] && return 0
  # Declared before the command -v guard so a missing vulkaninfo still
  # leaves a valid empty associative array (string-key lookups, not
  # arithmetic) for best_render_node_for_chromium's loop.
  declare -gA _VULKANINFO_GPU_TYPES=()
  local bin="${VULKANINFO_BIN:-vulkaninfo}" line block="" dtype="" val=""
  command -v "$bin" &>/dev/null || return 1
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    val=$(sed -n 's/.*=[[:space:]]*//p' <<<"$line")
    case "$line" in
    GPU[0-9]*) block=1 ;;
    deviceType*) [[ $block ]] && dtype="$val" ;;
    deviceID*) [[ $block && -n ${dtype:-} ]] && {
      _VULKANINFO_GPU_TYPES[${val#0x}]="$dtype"
      dtype=""
    } ;;
    esac
  done < <("$bin" --summary 2>/dev/null) || return 1
  _VULKANINFO_GPU_TYPES_READY=1
}

# Select the best DRM render node for Chromium's --render-node-override.
# Prints the full /dev/dri/renderDNNN path and returns 0, or returns 1 if
# no override is needed (single-GPU, nothing matches, etc.).
#
# Selection priority:
#   1. Single GPU → no override (let Chromium decide)
#   2. DRI_PRIME=N  — Nth render node by PCI bus address (Mesa convention)
#   3. CHROME_GPU=igpu|dgpu  — prefer DISCRETE or INTEGRATED via vulkaninfo
#   4. Auto-detect  — prefer DISCRETE_GPU, fall back to INTEGRATED_GPU
#   5. No vulkaninfo → VRAM heuristic (iGPUs have 0 dedicated VRAM),
#      bus-order fallback
best_render_node_for_chromium() {
  local nodes=() n pci dev gpu_type="" override="" devid=""
  for n in "$DRM_SYS_PATH"/renderD[0-9]*; do
    [[ -d "$n/device" ]] || continue
    pci=$(pci_id_of_drm_node "${n##*/}") || continue
    devid=$(sed -n 's/^0x//p' "$n/device/device")
    [[ -n $devid ]] || continue
    nodes+=("$pci|$devid|${n##*/}")
  done

  # Single GPU → no override needed.
  ((${#nodes[@]} >= 2)) || return 1

  # Sort by PCI bus address (sort of the leading "0000:NN:DD.F" is correct).
  mapfile -t nodes < <(printf '%s\n' "${nodes[@]}" | sort)

  # DRI_PRIME — explicit index override, standard Mesa convention.
  if [[ -n ${DRI_PRIME:-} ]] && ((DRI_PRIME < ${#nodes[@]})); then
    dev="${nodes[$DRI_PRIME]##*|}"
    echo "/dev/dri/$dev"
    return 0
  fi

  # Auto-detect via vulkaninfo: read device-id from sysfs, map via
  # device-type table. No hardcoded PCI device IDs.
  vulkaninfo_gpu_types
  local prefer="${CHROME_GPU:-}"
  for n in "${nodes[@]}"; do
    pci="${n%%|*}"
    devid="${n#*|}"
    devid="${devid%%|*}"
    gpu_type="${_VULKANINFO_GPU_TYPES[$devid]:-}"
    [[ -n $gpu_type ]] || continue
    case "$prefer" in
    dgpu) [[ $gpu_type == "DISCRETE_GPU" ]] && override="$pci" && dev="${n##*|}" ;;
    igpu) [[ $gpu_type == "INTEGRATED_GPU" ]] && override="$pci" && dev="${n##*|}" ;;
    *) [[ $gpu_type == "DISCRETE_GPU" ]] && override="$pci" && dev="${n##*|}" ;;
    esac
  done

  if [[ -z $override ]]; then
    # Graceful degradation when vulkaninfo is missing or no device-id
    # matches: VRAM heuristic first (iGPUs have no dedicated VRAM in
    # mem_info_vram_total), then bus-order fallback.
    local igpu_dev="" dgpu_dev="" vram
    for n in "${nodes[@]}"; do
      if [[ -f "$DRM_SYS_PATH/${n##*|}/device/mem_info_vram_total" ]]; then
        vram=$(<"$DRM_SYS_PATH/${n##*|}/device/mem_info_vram_total")
        if ((vram == 0)); then
          igpu_dev="${n##*|}"
        else
          dgpu_dev="${n##*|}"
        fi
      fi
    done
    if [[ ${CHROME_GPU:-} == igpu && -n ${igpu_dev:-} ]]; then
      dev="$igpu_dev"
    elif [[ -n ${dgpu_dev:-} ]]; then
      dev="$dgpu_dev"
    elif [[ ${CHROME_GPU:-} == igpu ]]; then
      dev="${nodes[0]##*|}"
    else
      dev="${nodes[-1]##*|}"
    fi
    echo "/dev/dri/$dev"
    return 0
  fi

  echo "/dev/dri/$dev"
}

# Policy wrapper for chromium-wrapper.sh: decide whether Chromium needs a
# --render-node-override at all. Non-hybrid systems (one GPU drives every
# connected output) get no override — Chromium picks its own GPU. Hybrid
# systems with CHROME_GPU unset default to igpu. DRI_PRIME is explicit and
# always honored, even on non-hybrid systems. CHROME_GPU is likewise explicit
# and must not be silently ignored on non-hybrid hosts.
chromium_gpu_override() {
  if [[ -z ${DRI_PRIME:-} ]] && [[ -z ${CHROME_GPU:-} ]] && ! detect_hybrid_graphics &>/dev/null; then
    return 1
  fi
  [[ -z ${CHROME_GPU:-} ]] && CHROME_GPU=igpu
  best_render_node_for_chromium
}
