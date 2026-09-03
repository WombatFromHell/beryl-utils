#!/usr/bin/env bash
# Shared GPU detection helpers. Sourced by chromium-wrapper.sh and
# bazzified-steam.sh so both use one sysfs-based hybrid-graphics check.
# DRM_SYS_PATH is overridable (tests set it before sourcing).
readonly DRM_SYS_PATH="${DRM_SYS_PATH:-/sys/class/drm}"

# Resolve the PCI id (e.g. "0000:01:00.0") behind a DRM node's `device`
# symlink. Works for any node under DRM_SYS_PATH - cardN or renderDNNN,
# since both expose the same device symlink shape.
# ponytail: single source of truth for this lookup; connector_gpu_map and
# render_node_of_gpu both call it instead of re-deriving it inline.
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

outputs_of_gpu() {
  local map
  map="$(connector_gpu_map)"
  awk -F'\t' -v g="$1" '$2 == g { print $1 }' <<<"$map"
}

# Find the render node (e.g. "renderD128") backed by a given GPU PCI id.
# Prints the node name and returns 0 on match, 1 if none found.
render_node_of_gpu() {
  local node pci
  for node in "$DRM_SYS_PATH"/renderD*; do
    [[ -d "$node/device" ]] || continue
    pci=$(pci_id_of_drm_node "${node##*/}") || continue
    if [[ $pci == "$1" ]]; then
      echo "${node##*/}"
      return 0
    fi
  done
  return 1
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

gpu_detect_self_test() {
  local root self single
  self="$(cd "${BASH_SOURCE[0]%/*}" && pwd)/${BASH_SOURCE[0]##*/}"
  root="$(mktemp -d)"
  trap 'rm -rf "$root"' RETURN
  mkdir -p "$root/sys/devices/pci/0000:00:02.0" "$root/sys/devices/pci/0000:01:00.0"
  mkdir -p "$root/sys/class/drm/card0/card0-DP-4"
  mkdir -p "$root/sys/class/drm/card1/card1-HDMI-A-2" "$root/sys/class/drm/card1/card1-HDMI-A-1"
  mkdir -p "$root/sys/class/drm/renderD128" "$root/sys/class/drm/renderD129"
  ln -s "$root/sys/devices/pci/0000:00:02.0" "$root/sys/class/drm/card0/device"
  ln -s "$root/sys/devices/pci/0000:01:00.0" "$root/sys/class/drm/card1/device"
  ln -s "$root/sys/devices/pci/0000:00:02.0" "$root/sys/class/drm/renderD128/device"
  ln -s "$root/sys/devices/pci/0000:01:00.0" "$root/sys/class/drm/renderD129/device"
  printf 'disconnected' >"$root/sys/class/drm/card1/card1-HDMI-A-1/status"
  printf 'connected' >"$root/sys/class/drm/card1/card1-HDMI-A-2/status"
  # device-ids (iGPU Raphael 0x164e, dGPU RX 9070 XT 0x7550)
  printf '0x164e\n' >"$root/sys/devices/pci/0000:00:02.0/device"
  printf '0x7550\n' >"$root/sys/devices/pci/0000:01:00.0/device"
  printf '0\n' >"$root/sys/devices/pci/0000:00:02.0/mem_info_vram_total"
  printf '16384000000\n' >"$root/sys/devices/pci/0000:01:00.0/mem_info_vram_total"
  mkdir -p "$root/bin"
  cat >"$root/bin/vulkaninfo" <<'VULK'
#!/usr/bin/env bash
cat <<EOF
==========DEVICES==========
GPU0 :
        deviceName     = AMD Radeon RX 9070 XT
        deviceType     = DISCRETE_GPU
        vendorID       = 0x1002
        deviceID       = 0x7550
GPU1 :
        deviceName     = AMD Raphael
        deviceType     = INTEGRATED_GPU
        vendorID       = 0x1002
        deviceID       = 0x164e
EOF
VULK
  chmod +x "$root/bin/vulkaninfo"
  printf 'connected' >"$root/sys/class/drm/card0/card0-DP-4/status"
  # ponytail: DRM_SYS_PATH is readonly here, so exercise the helpers in a
  # child that sources this file with the mock path passed via env.
  # shellcheck disable=SC2016 # $SELFTEST_SELF is expanded by the child bash
  env DRM_SYS_PATH="$root/sys/class/drm" SELFTEST_SELF="$self" \
    VULKANINFO_BIN="$root/bin/vulkaninfo" bash -c '
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
    out="$(pci_id_of_drm_node renderD129)"
    [[ $out == "0000:01:00.0" ]] || { echo "self-test: pci_id_of_drm_node renderD129 = $out" >&2; exit 1; }
    out="$(render_node_of_gpu 0000:01:00.0)"
    [[ $out == "renderD129" ]] || { echo "self-test: render_node_of_gpu 0000:01:00.0 = $out" >&2; exit 1; }
    render_node_of_gpu 0000:99:00.0 >/dev/null && { echo "self-test: render_node_of_gpu matched nonexistent GPU" >&2; exit 1; }
    # best_render_node_for_chromium: two GPUs (00:02.0 iGPU=164e, 01:00.0 dGPU=7550)
    # auto-detect prefers DISCRETE → renderD129
    out="$(best_render_node_for_chromium)"
    [[ $out == "/dev/dri/renderD129" ]] || { echo "self-test: auto-detect = $out" >&2; exit 1; }
    # CHROME_GPU=igpu → iGPU → renderD128
    out="$(CHROME_GPU=igpu best_render_node_for_chromium)"
    [[ $out == "/dev/dri/renderD128" ]] || { echo "self-test: CHROME_GPU=igpu = $out" >&2; exit 1; }
    # DRI_PRIME=0 / 1 → renderD128 / renderD129 (by PCI bus order)
    out="$(DRI_PRIME=0 best_render_node_for_chromium)"
    [[ $out == "/dev/dri/renderD128" ]] || { echo "self-test: DRI_PRIME=0 = $out" >&2; exit 1; }
    out="$(DRI_PRIME=1 best_render_node_for_chromium)"
    [[ $out == "/dev/dri/renderD129" ]] || { echo "self-test: DRI_PRIME=1 = $out" >&2; exit 1; }
    # chromium_gpu_override: hybrid + unset CHROME_GPU → default igpu → renderD128
    out="$(chromium_gpu_override)"
    [[ $out == "/dev/dri/renderD128" ]] || { echo "self-test: chromium_gpu_override = $out" >&2; exit 1; }
    # DRI_PRIME is explicit and beats the hybrid default → renderD129
    out="$(DRI_PRIME=1 chromium_gpu_override)"
    [[ $out == "/dev/dri/renderD129" ]] || { echo "self-test: DRI_PRIME=1 override = $out" >&2; exit 1; }
    echo "gpu-detect self-test ok"
  ' || return 1

  # No vulkaninfo: graceful degradation to the bus-order heuristic
  # (lowest PCI bus = iGPU, highest = discrete) for CHROME_GPU + auto.
  # shellcheck disable=SC2016
  env DRM_SYS_PATH="$root/sys/class/drm" SELFTEST_SELF="$self" \
    VULKANINFO_BIN="$root/bin/not-there/vulkaninfo" bash -c '
    source "$SELFTEST_SELF"
    out="$(best_render_node_for_chromium)"
    [[ $out == "/dev/dri/renderD129" ]] || { echo "self-test: no-vulkaninfo auto = $out" >&2; exit 1; }
    out="$(CHROME_GPU=igpu best_render_node_for_chromium)"
    [[ $out == "/dev/dri/renderD128" ]] || { echo "self-test: no-vulkaninfo igpu = $out" >&2; exit 1; }
    echo "gpu-detect no-vulkaninfo self-test ok"
  ' || return 1

  # Non-hybrid topology (mirrors the live box): dGPU 0000:03:00.0 drives
  # DP-1; iGPU 0000:13:00.0 is enabled but drives no output. Auto-detect
  # must pick the DISCRETE dGPU, and chromium_gpu_override must inject
  # nothing (Chromium picks its own GPU).
  local nonhybrid="$root/nonhybrid"
  mkdir -p "$nonhybrid/sys/devices/pci/0000:03:00.0" "$nonhybrid/sys/devices/pci/0000:13:00.0"
  printf '0x7550\n' >"$nonhybrid/sys/devices/pci/0000:03:00.0/device"
  printf '0x164e\n' >"$nonhybrid/sys/devices/pci/0000:13:00.0/device"
  printf '16384000000\n' >"$nonhybrid/sys/devices/pci/0000:03:00.0/mem_info_vram_total"
  printf '0\n' >"$nonhybrid/sys/devices/pci/0000:13:00.0/mem_info_vram_total"
  mkdir -p "$nonhybrid/sys/class/drm/card0/card0-DP-1"
  mkdir -p "$nonhybrid/sys/class/drm/renderD128" "$nonhybrid/sys/class/drm/renderD129"
  ln -s "$nonhybrid/sys/devices/pci/0000:03:00.0" "$nonhybrid/sys/class/drm/card0/device"
  ln -s "$nonhybrid/sys/devices/pci/0000:03:00.0" "$nonhybrid/sys/class/drm/renderD128/device"
  ln -s "$nonhybrid/sys/devices/pci/0000:13:00.0" "$nonhybrid/sys/class/drm/renderD129/device"
  printf 'connected' >"$nonhybrid/sys/class/drm/card0/card0-DP-1/status"
  # shellcheck disable=SC2016
  env DRM_SYS_PATH="$nonhybrid/sys/class/drm" SELFTEST_SELF="$self" \
    VULKANINFO_BIN="$root/bin/vulkaninfo" bash -c '
    source "$SELFTEST_SELF"
    out="$(best_render_node_for_chromium)"
    [[ $out == "/dev/dri/renderD128" ]] || { echo "self-test: non-hybrid auto-detect = $out" >&2; exit 1; }
    out="$(chromium_gpu_override)"
    [[ -z $out ]] || { echo "self-test: non-hybrid override = $out" >&2; exit 1; }
    CHROME_GPU=igpu out="$(chromium_gpu_override)"
    [[ $out == "/dev/dri/renderD129" ]] || { echo "self-test: non-hybrid CHROME_GPU=igpu = $out" >&2; exit 1; }
    CHROME_GPU=dgpu out="$(chromium_gpu_override)"
    [[ $out == "/dev/dri/renderD128" ]] || { echo "self-test: non-hybrid CHROME_GPU=dgpu = $out" >&2; exit 1; }
    echo "gpu-detect non-hybrid self-test ok"
  ' || return 1

  # Non-hybrid + no vulkaninfo: VRAM heuristic must still pick the right
  # GPU (iGPU=renderD129 with VRAM=0, dGPU=renderD128 with VRAM>0).
  # shellcheck disable=SC2016
  env DRM_SYS_PATH="$nonhybrid/sys/class/drm" SELFTEST_SELF="$self" \
    VULKANINFO_BIN="$root/bin/not-there/vulkaninfo" bash -c '
    source "$SELFTEST_SELF"
    out="$(best_render_node_for_chromium)"
    [[ $out == "/dev/dri/renderD128" ]] || { echo "self-test: non-hybrid no-vulkaninfo auto = $out" >&2; exit 1; }
    out="$(CHROME_GPU=igpu best_render_node_for_chromium)"
    [[ $out == "/dev/dri/renderD129" ]] || { echo "self-test: non-hybrid no-vulkaninfo igpu = $out" >&2; exit 1; }
    echo "gpu-detect non-hybrid no-vulkaninfo self-test ok"
  ' || return 1

  # Single-GPU topology: best_render_node_for_chromium returns nothing
  # (no --render-node-override; Chromium picks its own GPU).
  local single="$root/single"
  mkdir -p "$single/sys/class/drm/renderD128" "$single/sys/devices/pci/0000:00:02.0"
  ln -s "$single/sys/devices/pci/0000:00:02.0" "$single/sys/class/drm/renderD128/device"
  printf '0x164e\n' >"$single/sys/devices/pci/0000:00:02.0/device"
  # shellcheck disable=SC2016
  env DRM_SYS_PATH="$single/sys/class/drm" SELFTEST_SELF="$self" bash -c '
    source "$SELFTEST_SELF"
    out="$(best_render_node_for_chromium)"
    [[ -z $out ]] || { echo "self-test: single-GPU returned override = $out" >&2; exit 1; }
    echo "gpu-detect single-GPU self-test ok"
  ' || return 1
}

if [[ ${BASH_SOURCE[0]} == "$0" && ${1:-} == "--self-test" ]]; then
  gpu_detect_self_test
fi
