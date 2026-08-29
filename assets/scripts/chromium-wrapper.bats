#!/usr/bin/env bats

# shellcheck disable=SC2030,SC2031 # bats runs each @test in a subshell; `export` here is the intended way to pass env into `run bash -c` children
bats_require_minimum_version 1.5.0

SOURCE_FILE="${BATS_TEST_DIRNAME}/chromium-wrapper.sh"

# ── Setup / Teardown ─────────────────────────────────────────────────────────

setup() {
  export TEST_ROOT="${BATS_TMPDIR:-/tmp/bats_test}/cw_sandbox_$$"
  rm -rf "$TEST_ROOT"
  mkdir -p "$TEST_ROOT/bin"
  mkdir -p "$TEST_ROOT/home/.local/bin/scripts"

  export HOME="$TEST_ROOT/home"
  export PATH="$TEST_ROOT/bin:$HOME/.local/bin/scripts:$PATH"
  # Collapse the deferred-update sleep so tests run at normal speed.
  export UPDATE_DEFER_SECONDS=0
  # No-op notify so update paths never reach a real notify-send.
  make_stub notify-send

  stub_chromium_flags
}

teardown() {
  [[ -n ${GPU_DEV_CREATED:-} ]] && rm -f /dev/dri/renderD128
  rm -rf "$TEST_ROOT"
}

# ── Test Helpers ──────────────────────────────────────────────────────────────

make_stub() {
  local name="$1" exit_code="${2:-0}"
  printf '#!/bin/bash\nexit %d\n' "$exit_code" >"$TEST_ROOT/bin/$name"
  chmod +x "$TEST_ROOT/bin/$name"
}

stub_chromium_flags() {
  cat >"${HOME}/.local/bin/scripts/chromium-flags.sh" <<'STUB'
#!/bin/bash
echo "chromium-flags: $*"
STUB
  chmod +x "${HOME}/.local/bin/scripts/chromium-flags.sh"
}

# flatpak mock: reports installed (info/list) and, for launch, execs the
# chromium-flags.sh wrapper passed as its first arg (mirrors real
# `flatpak run` executing the binary). Update behaviour is parameterised.
stub_flatpak() {
  local installed="${1:-yes}" has_update="${2:-no}"
  if [[ $installed == "no" ]]; then
    cat >"$TEST_ROOT/bin/flatpak" <<'MOCK'
#!/bin/bash
if [[ "$1" == *"chromium-flags.sh"* ]]; then exec "$@"; fi
if [[ "$1" == "info" ]]; then exit 1; fi
if [[ "$1" == "list" ]]; then exit 1; fi
if [[ "$1" == "update" ]]; then
  if [[ "$*" == *"--no-deploy"* ]]; then printf 'Nothing to do.\n'; exit 0; fi
  printf 'Flatpak update failed.\n'; exit 1
fi
exit 1
MOCK
  elif [[ $has_update == "yes" ]]; then
    cat >"$TEST_ROOT/bin/flatpak" <<'MOCK'
#!/bin/bash
if [[ "$1" == *"chromium-flags.sh"* ]]; then exec "$@"; fi
if [[ "$1" == "info" ]]; then exit 0; fi
if [[ "$1" == "list" ]]; then printf 'com.brave.Browser\n'; exit 0; fi
if [[ "$1" == "update" ]]; then
  if [[ "$*" == *"--no-deploy"* ]]; then printf 'Updates available.\n'; exit 0; fi
  printf 'Updates complete.\n'; exit 0
fi
exit 1
MOCK
  else
    cat >"$TEST_ROOT/bin/flatpak" <<'MOCK'
#!/bin/bash
if [[ "$1" == *"chromium-flags.sh"* ]]; then exec "$@"; fi
if [[ "$1" == "info" ]]; then exit 0; fi
if [[ "$1" == "list" ]]; then printf 'com.brave.Browser\n'; exit 0; fi
if [[ "$1" == "update" ]]; then
  if [[ "$*" == *"--no-deploy"* ]]; then printf 'Nothing to do.\n'; exit 0; fi
  printf 'Flatpak update failed.\n'; exit 1
fi
exit 1
MOCK
  fi
  chmod +x "$TEST_ROOT/bin/flatpak"
}

stub_distrobox() {
  cat >"$TEST_ROOT/bin/distrobox" <<'MOCK'
#!/bin/bash
# ls: list containers (bravebox + the profile's $CONTAINER_NAME). Disable with
# MOCK_DISTROBOX_CONTAINER=no to simulate "no container".
if [[ "$1" == "ls" ]]; then
  if [[ "${MOCK_DISTROBOX_CONTAINER:-yes}" != "no" ]]; then
    printf 'ID           | NAME                 | STATUS             | IMAGE\n'
    printf 'abc123 | bravebox             | Up               | img\n'
    if [[ -n ${CONTAINER_NAME:-} && $CONTAINER_NAME != "bravebox" ]]; then
      printf 'def456 | %s | Up | img\n' "$CONTAINER_NAME"
    fi
  fi
  exit 0
fi
exit 1
MOCK
  chmod +x "$TEST_ROOT/bin/distrobox"
  cat >"$TEST_ROOT/bin/distrobox-enter" <<'MOCK'
#!/bin/bash
# Launch: first arg is the chromium-flags.sh wrapper; exec it with the rest
# (which re-invokes distrobox-enter inside the container).
if [[ "$1" == *"chromium-flags.sh"* ]]; then exec "$@"; fi
# Update: args are `-n <container> -- <cmd> ...`; drop the prefix.
shift 2; shift
case "$1" in
  dnf) if [[ "$2" == "check-update" ]]; then
         [[ "${MOCK_DNF_UPDATE:-no}" == "yes" ]] && exit 100 || exit 0; fi; exit 1;;
  sudo) if [[ "$2" == "-n" && "$3" == "true" ]]; then
          [[ "${MOCK_SUDO_OK:-yes}" == "yes" ]] && exit 0 || exit 1; fi
        if [[ "$2" == "dnf" && "$3" == "upgrade" ]]; then printf 'Upgrading in container...\n'; exit 0; fi
        exit 1;;
  *) exec "$@";;
esac
MOCK
  chmod +x "$TEST_ROOT/bin/distrobox-enter"
}

stub_dnf() {
  cat >"$TEST_ROOT/bin/dnf" <<'MOCK'
#!/bin/bash
if [[ "$1" == "check-update" ]]; then
  [[ "${MOCK_DNF_UPDATE:-no}" == "yes" ]] && exit 100 || exit 0
fi
exit 1
MOCK
  chmod +x "$TEST_ROOT/bin/dnf"
}

stub_sudo() {
  cat >"$TEST_ROOT/bin/sudo" <<'MOCK'
#!/bin/bash
if [[ "$1" == "-n" && "$2" == "true" ]]; then
  [[ "${MOCK_SUDO_OK:-yes}" == "yes" ]] && exit 0 || exit 1
fi
if [[ "$1" == "dnf" && "$2" == "upgrade" ]]; then printf 'Upgrading...\n'; exit 0; fi
exit 1
MOCK
  chmod +x "$TEST_ROOT/bin/sudo"
}

# Fake /sys/class/drm tree for GPU tests.
make_fake_drm() { mkdir -p "$1"; }

add_fake_card() {
  local drm="$1" card="$2" pci="$3" conn="$4" conn_status="${5:-connected}"
  mkdir -p "$drm/$card/$pci" "$drm/$card/$conn"
  ln -s "$pci" "$drm/$card/device"
  printf '%s\n' "$conn_status" >"$drm/$card/$conn/status"
}

add_fake_render_node() {
  local drm="$1" node="$2" vendor="$3" device="$4"
  mkdir -p "$drm/$node/device"
  printf '%s\n' "$vendor" >"$drm/$node/device/vendor"
  printf '%s\n' "$device" >"$drm/$node/device/device"
}

# Run main() as a subprocess so `exec` and background updates behave naturally.
run_main() {
  run bash -c "HOME='$HOME' PATH='$PATH' '${SOURCE_FILE}' $(printf '%q ' "$@")"
}

# ── Mandatory guard ───────────────────────────────────────────────────────────

@test "chromium-flags.sh is mandatory: exit 1 when absent" {
  rm -f "$HOME/.local/bin/scripts/chromium-flags.sh"
  # Run from a dir with no chromium-flags.sh sibling and a PATH that can't
  # resolve one, so both resolution paths fail.
  mkdir -p "$TEST_ROOT/standalone" "$TEST_ROOT/sh"
  cp "$SOURCE_FILE" "$TEST_ROOT/standalone/chromium-wrapper.sh"
  ln -sf "$(command -v bash)" "$TEST_ROOT/sh/bash"
  PATH="$TEST_ROOT/bin:$TEST_ROOT/sh" run bash -c "'$TEST_ROOT/standalone/chromium-wrapper.sh'"
  [[ $status -ne 0 ]]
  [[ $output == *"chromium-flags.sh not found"* ]]
}

# ── is_in_container ───────────────────────────────────────────────────────────

@test "is_in_container: true when CONTAINER_ID is set" {
  run bash -c "export CONTAINER_ID='test_id'; source '$SOURCE_FILE'; is_in_container"
  [[ $status -eq 0 ]]
}

@test "is_in_container: true when CONTAINER_ENV_FILE exists" {
  touch "$TEST_ROOT/fake_containerenv"
  run bash -c "export CONTAINER_ENV_FILE='$TEST_ROOT/fake_containerenv'; source '$SOURCE_FILE'; is_in_container"
  [[ $status -eq 0 ]]
}

@test "is_in_container: false when no container markers exist" {
  run bash -c "unset CONTAINER_ID; export CONTAINER_ENV_FILE='$TEST_ROOT/none'; source '$SOURCE_FILE'; is_in_container"
  [[ $status -ne 0 ]]
}

# ── is_flatpak_installed ──────────────────────────────────────────────────────

@test "is_flatpak_installed: false when flatpak absent" {
  stub_flatpak no
  run bash -c "source '$SOURCE_FILE'; is_flatpak_installed com.brave.Browser"
  [[ $status -ne 0 ]]
}

@test "is_flatpak_installed: true when flatpak info succeeds" {
  stub_flatpak yes
  run bash -c "source '$SOURCE_FILE'; is_flatpak_installed com.brave.Browser"
  [[ $status -eq 0 ]]
}

@test "is_flatpak_installed: true when only flatpak list matches" {
  cat >"$TEST_ROOT/bin/flatpak" <<'MOCK'
#!/bin/bash
[[ "$1" == "info" ]] && exit 1
[[ "$1" == "list" ]] && { printf 'com.brave.Browser\n'; exit 0; }
exit 1
MOCK
  chmod +x "$TEST_ROOT/bin/flatpak"
  run bash -c "source '$SOURCE_FILE'; is_flatpak_installed com.brave.Browser"
  [[ $status -eq 0 ]]
}

@test "is_flatpak_installed: false when neither info nor list matches" {
  cat >"$TEST_ROOT/bin/flatpak" <<'MOCK'
#!/bin/bash
[[ "$1" == "info" ]] && exit 1
[[ "$1" == "list" ]] && { printf 'com.other.App\n'; exit 0; }
exit 1
MOCK
  chmod +x "$TEST_ROOT/bin/flatpak"
  run bash -c "source '$SOURCE_FILE'; is_flatpak_installed com.brave.Browser"
  [[ $status -ne 0 ]]
}

# ── find_browser ──────────────────────────────────────────────────────────────

@test "find_browser: returns flatpak when installed" {
  stub_flatpak yes
  export FLATPAK_NAME="com.brave.Browser"
  run bash -c "export FLATPAK_NAME='com.brave.Browser'; source '$SOURCE_FILE'; find_browser"
  [[ $status -eq 0 ]]
  [[ $output == "flatpak" ]]
}

@test "find_browser: returns first legacy candidate on PATH" {
  make_stub brave
  run bash -c "source '$SOURCE_FILE'; find_browser"
  [[ $status -eq 0 ]]
  [[ $output == "brave" ]]
}

@test "find_browser: returns brave-browser when bravebox container exists" {
  stub_distrobox
  run bash -c "source '$SOURCE_FILE'; find_browser"
  [[ $status -eq 0 ]]
  [[ $output == "brave-browser" ]]
}

@test "find_browser: helper dispatch uses legacy container default" {
  stub_flatpak no
  stub_distrobox
  run_main --helper-find-browser
  [[ $status -eq 0 ]]
  [[ $output == "brave-browser" ]]
}

@test "find_browser: returns nonzero when nothing found" {
  stub_flatpak no
  stub_distrobox
  export MOCK_DISTROBOX_CONTAINER=no
  run bash -c "source '$SOURCE_FILE'; find_browser"
  [[ $status -ne 0 ]]
}

# ── load_profile ───────────────────────────────────────────────────────────────

write_profile() {
  local name="$1"
  mkdir -p "$PROFILE_DIR"
  printf '%s\n' "$2" >"$PROFILE_DIR/$name.conf"
}

@test "load_profile: missing .conf is a soft failure (returns 1)" {
  export PROFILE_DIR="$TEST_ROOT/profiles"
  run bash -c "source '$SOURCE_FILE'; load_profile nope || true; echo \"PROFILE=\${PROFILE:-}\""
  [[ $status -eq 0 ]]
  [[ $output == *"PROFILE=nope"* ]]
}

@test "load_profile: sources values from the .conf" {
  export PROFILE_DIR="$TEST_ROOT/profiles"
  write_profile brave $'BROWSER_BINARY=mybrave\n'
  run bash -c "source '$SOURCE_FILE'; load_profile brave || true; echo \"BIN=\${BROWSER_BINARY:-} FP=\${FLATPAK_NAME:-}\""
  [[ $output == *"BIN=mybrave"* ]]
  [[ $output == *"FP="* ]]
}

@test "load_profile: environment always overrides the .conf" {
  export PROFILE_DIR="$TEST_ROOT/profiles"
  export FLATPAK_NAME="com.env.App"
  write_profile brave $'FLATPAK_NAME=com.conf.App\n'
  run bash -c "source '$SOURCE_FILE'; load_profile brave || true; echo \"FP=\${FLATPAK_NAME:-}\""
  [[ $output == *"FP=com.env.App"* ]]
}

@test "load_profile: BROWSER_BINARY + FLATPAK_NAME is fatal" {
  export PROFILE_DIR="$TEST_ROOT/profiles"
  write_profile brave $'BROWSER_BINARY=x\nFLATPAK_NAME=y\n'
  run bash -c "source '$SOURCE_FILE'; load_profile brave"
  [[ $status -ne 0 ]]
  [[ $output == *"mutually exclusive"* ]]
}

@test "load_profile: neither BROWSER_BINARY nor FLATPAK_NAME is fatal" {
  export PROFILE_DIR="$TEST_ROOT/profiles"
  write_profile brave $'CHROME_GPU=igpu\n'
  run bash -c "source '$SOURCE_FILE'; load_profile brave"
  [[ $status -ne 0 ]]
  [[ $output == *"set exactly one"* ]]
}

# ── resolve_profile_browser (three launch codepaths) ──────────────────────────

@test "resolve_profile_browser: FLATPAK_NAME -> flatpak" {
  stub_flatpak yes
  export PROFILE_DIR="$TEST_ROOT/profiles"
  write_profile brave $'FLATPAK_NAME=com.brave.Browser\n'
  run bash -c "source '$SOURCE_FILE'; load_profile brave; resolve_profile_browser; echo \"M=\${LAUNCH_METHOD:-} B=\${BROWSER:-}\""
  [[ $output == *"M=flatpak"* ]]
  [[ $output == *"B=flatpak"* ]]
}

@test "resolve_profile_browser: BROWSER_BINARY on host -> direct" {
  make_stub mybrave
  export PROFILE_DIR="$TEST_ROOT/profiles"
  write_profile brave $'BROWSER_BINARY=mybrave\n'
  run bash -c "source '$SOURCE_FILE'; load_profile brave; resolve_profile_browser; echo \"M=\${LAUNCH_METHOD:-} B=\${BROWSER:-}\""
  [[ $output == *"M=direct"* ]]
  [[ $output == *"B=mybrave"* ]]
}

@test "resolve_profile_browser: BROWSER_BINARY only in container -> distrobox" {
  stub_distrobox
  export PROFILE_DIR="$TEST_ROOT/profiles"
  export CONTAINER_NAME="mybox"
  write_profile brave $'BROWSER_BINARY=cbrave\nCONTAINER_NAME=mybox\n'
  run bash -c "source '$SOURCE_FILE'; load_profile brave; resolve_profile_browser; echo \"M=\${LAUNCH_METHOD:-} B=\${BROWSER:-}\""
  [[ $output == *"M=distrobox"* ]]
  [[ $output == *"B=cbrave"* ]]
}

@test "resolve_profile_browser: binary nowhere is fatal" {
  export PROFILE_DIR="$TEST_ROOT/profiles"
  write_profile brave $'BROWSER_BINARY=ghost\n'
  run bash -c "source '$SOURCE_FILE'; load_profile brave; resolve_profile_browser"
  [[ $status -ne 0 ]]
  [[ $output == *"not found"* ]]
}

# ── resolve_legacy_browser (three launch codepaths) ──────────────────────────

@test "resolve_legacy_browser: flatpak installed -> flatpak" {
  stub_flatpak yes
  run bash -c "source '$SOURCE_FILE'; legacy_setup; resolve_legacy_browser; echo \"M=\${LAUNCH_METHOD:-}\""
  [[ $output == *"M=flatpak"* ]]
}

@test "resolve_legacy_browser: not in container + candidate -> distrobox" {
  stub_flatpak no
  make_stub brave
  run bash -c "source '$SOURCE_FILE'; legacy_setup; resolve_legacy_browser; echo \"M=\${LAUNCH_METHOD:-} B=\${BROWSER:-}\""
  [[ $output == *"M=distrobox"* ]]
  [[ $output == *"B=brave"* ]]
}

@test "resolve_legacy_browser: in container + candidate -> direct" {
  stub_flatpak no
  make_stub brave
  touch "$TEST_ROOT/fake_containerenv"
  run bash -c "export CONTAINER_ENV_FILE='$TEST_ROOT/fake_containerenv'; source '$SOURCE_FILE'; legacy_setup; resolve_legacy_browser; echo \"M=\${LAUNCH_METHOD:-} B=\${BROWSER:-}\""
  [[ $output == *"M=direct"* ]]
  [[ $output == *"B=brave"* ]]
}

@test "resolve_legacy_browser: nothing found is fatal" {
  stub_flatpak no
  stub_distrobox
  export MOCK_DISTROBOX_CONTAINER=no
  run bash -c "source '$SOURCE_FILE'; legacy_setup; resolve_legacy_browser"
  [[ $status -ne 0 ]]
  [[ $output == *"no Brave found"* ]]
}

# ── main() integration: the three launch codepaths (profile) ──────────────────

@test "main: profile flatpak launches via chromium-flags" {
  stub_flatpak yes
  export PROFILE_DIR="$TEST_ROOT/profiles"
  write_profile brave $'FLATPAK_NAME=com.brave.Browser\n'
  run_main -p brave
  [[ $status -eq 0 ]]
  [[ $output == *"chromium-flags: flatpak run com.brave.Browser"* ]]
}

@test "main: profile direct launches the host binary" {
  make_stub mybrave
  export PROFILE_DIR="$TEST_ROOT/profiles"
  write_profile brave $'BROWSER_BINARY=mybrave\n'
  run_main -p brave
  [[ $status -eq 0 ]]
  [[ $output == *"chromium-flags: mybrave"* ]]
}

@test "main: profile distrobox launches through the container" {
  stub_distrobox
  export PROFILE_DIR="$TEST_ROOT/profiles"
  export CONTAINER_NAME="mybox"
  write_profile brave $'BROWSER_BINARY=cbrave\nCONTAINER_NAME=mybox\n'
  run_main -p brave
  [[ $status -eq 0 ]]
  [[ $output == *"chromium-flags: distrobox-enter -n mybox -- cbrave"* ]]
}

# ── main() integration: the three launch codepaths (legacy) ───────────────────

@test "main: legacy flatpak launches via chromium-flags" {
  stub_flatpak yes
  run_main
  [[ $status -eq 0 ]]
  [[ $output == *"chromium-flags: flatpak run com.brave.Browser"* ]]
}

@test "main: legacy distrobox launches through bravebox" {
  stub_flatpak no
  stub_distrobox
  make_stub brave
  run_main
  [[ $status -eq 0 ]]
  [[ $output == *"chromium-flags: distrobox-enter -n bravebox -- brave"* ]]
}

@test "main: legacy direct launches host binary when in container" {
  stub_flatpak no
  make_stub brave
  touch "$TEST_ROOT/fake_containerenv"
  export CONTAINER_ENV_FILE="$TEST_ROOT/fake_containerenv"
  run_main
  [[ $status -eq 0 ]]
  [[ $output == *"chromium-flags: brave"* ]]
}

@test "main: missing profile falls back to legacy with a warning" {
  stub_flatpak no
  stub_distrobox
  make_stub brave
  export PROFILE_DIR="$TEST_ROOT/profiles"
  run_main -p ghost
  [[ $status -eq 0 ]]
  [[ $output == *"profile 'ghost' not found"* ]]
  [[ $output == *"chromium-flags: distrobox-enter -n bravebox -- brave"* ]]
}

# ── GPU selection ─────────────────────────────────────────────────────────────

@test "detect_hybrid_graphics: two GPUs each driving an output => hybrid" {
  local drm="$TEST_ROOT/sys/drm"
  make_fake_drm "$drm"
  add_fake_card "$drm" card0 0000:13:00.0 DP-1
  add_fake_card "$drm" card1 0000:03:00.0 HDMI-A-1
  run bash -c "export DRM_SYS_PATH='$drm'; source '$SOURCE_FILE'; detect_hybrid_graphics"
  [[ $status -eq 0 ]]
  [[ $output == "2" ]]
}

@test "detect_hybrid_graphics: single active GPU => not hybrid" {
  local drm="$TEST_ROOT/sys/drm"
  make_fake_drm "$drm"
  add_fake_card "$drm" card0 0000:13:00.0 DP-1
  run bash -c "export DRM_SYS_PATH='$drm'; source '$SOURCE_FILE'; detect_hybrid_graphics"
  [[ $status -ne 0 ]]
  [[ $output == "1" ]]
}

@test "detect_hybrid_graphics: no connected outputs => not hybrid" {
  local drm="$TEST_ROOT/sys/drm"
  make_fake_drm "$drm"
  add_fake_card "$drm" card0 0000:13:00.0 DP-1 disconnected
  run bash -c "export DRM_SYS_PATH='$drm'; source '$SOURCE_FILE'; detect_hybrid_graphics"
  [[ $status -ne 0 ]]
  [[ $output == "0" ]]
}

@test "resolve_gpu_flags: hybrid defaults CHROME_GPU to igpu" {
  local drm="$TEST_ROOT/sys/drm"
  make_fake_drm "$drm"
  add_fake_card "$drm" card0 0000:13:00.0 DP-1
  add_fake_card "$drm" card1 0000:03:00.0 HDMI-A-1
  run bash -c "export DRM_SYS_PATH='$drm'; source '$SOURCE_FILE'; resolve_gpu_flags; echo \"GPU=\${CHROME_GPU:-}\""
  [[ $output == *"GPU=igpu"* ]]
}

@test "resolve_gpu_flags: explicit CHROME_GPU=dgpu is honored" {
  local drm="$TEST_ROOT/sys/drm"
  make_fake_drm "$drm"
  add_fake_card "$drm" card0 0000:13:00.0 DP-1
  add_fake_card "$drm" card1 0000:03:00.0 HDMI-A-1
  run bash -c "export DRM_SYS_PATH='$drm' CHROME_GPU=dgpu; source '$SOURCE_FILE'; resolve_gpu_flags; echo \"GPU=\${CHROME_GPU:-}\""
  [[ $output == *"GPU=dgpu"* ]]
}

@test "resolve_gpu_flags: single GPU leaves CHROME_GPU unset" {
  local drm="$TEST_ROOT/sys/drm"
  make_fake_drm "$drm"
  add_fake_card "$drm" card0 0000:13:00.0 DP-1
  run bash -c "export DRM_SYS_PATH='$drm'; source '$SOURCE_FILE'; resolve_gpu_flags; echo \"GPU=\${CHROME_GPU:-}\""
  [[ $output == "GPU=" ]]
}

@test "apply_gpu_selection: wrong PCI device id sets no override" {
  local drm="$TEST_ROOT/sys/drm"
  make_fake_drm "$drm"
  add_fake_render_node "$drm" renderD128 0x1002 0x9999
  run bash -c "export DRM_SYS_PATH='$drm' CHROME_GPU=igpu; source '$SOURCE_FILE'; apply_gpu_selection; echo \"FLAGS=\${GPU_FLAGS[*]:-}\""
  [[ $output == "FLAGS=" ]]
}

# ponytail: the dev path is hardcoded to /dev/dri in the script. We inject a
# matching render node only when a /dev/dri/renderD128 exists (real, or a fake
# we can create). Where neither is possible the assertion would be false, so we
# skip instead of asserting the safe-default-empty case.
@test "apply_gpu_selection: matching PCI id injects --render-node-override" {
  local drm="$TEST_ROOT/sys/drm"
  if [[ ! -e /dev/dri/renderD128 ]]; then
    if ! mkdir -p /dev/dri 2>/dev/null || ! touch /dev/dri/renderD128 2>/dev/null; then
      skip "/dev/dri/renderD128 unavailable — cannot exercise the device gate"
    fi
    GPU_DEV_CREATED=1
  fi
  make_fake_drm "$drm"
  add_fake_render_node "$drm" renderD128 0x1002 0x164e
  run bash -c "export DRM_SYS_PATH='$drm' CHROME_GPU=igpu; source '$SOURCE_FILE'; apply_gpu_selection; echo \"FLAGS=\${GPU_FLAGS[*]:-}\""
  [[ $output == *"--render-node-override=/dev/dri/renderD128"* ]]
}

# ── notify ─────────────────────────────────────────────────────────────────────

@test "notify: invokes notify-send with the configured app id" {
  cat >"$TEST_ROOT/bin/notify-send" <<'MOCK'
#!/bin/bash
printf 'notify-send: %s\n' "$*"
MOCK
  chmod +x "$TEST_ROOT/bin/notify-send"
  run bash -c "source '$SOURCE_FILE'; notify 'Title' 'Body' low 5000"
  [[ $status -eq 0 ]]
  [[ $output == *"-a chromium-wrapper"* ]]
  [[ $output == *"Title"* ]]
  [[ $output == *"Body"* ]]
}

# ── perform_browser_update ────────────────────────────────────────────────────

@test "perform_browser_update [flatpak]: reports no updates" {
  stub_flatpak
  run bash -c "source '$SOURCE_FILE'; perform_browser_update flatpak com.brave.Browser"
  [[ $status -eq 0 ]]
  [[ $output == *"No updates found."* ]]
}

@test "perform_browser_update [flatpak]: notifies on successful upgrade" {
  stub_flatpak yes yes
  run bash -c "source '$SOURCE_FILE'; perform_browser_update flatpak com.brave.Browser"
  [[ $status -eq 0 ]]
  [[ $output == *"Updates complete"* ]]
}

@test "perform_browser_update [dnf]: check phase does not invoke sudo" {
  make_stub brave
  stub_dnf
  stub_sudo
  run bash -c "source '$SOURCE_FILE'; perform_browser_update dnf brave"
  [[ $status -eq 0 ]]
  [[ $output == *"No updates found."* ]]
}

@test "perform_browser_update [dnf]: notifies on successful upgrade" {
  make_stub brave
  stub_dnf
  stub_sudo
  export MOCK_DNF_UPDATE=yes
  run bash -c "source '$SOURCE_FILE'; perform_browser_update dnf brave"
  [[ $status -eq 0 ]]
  [[ $output == *"Upgrading..."* ]]
}

@test "perform_browser_update [dnf]: skips when passwordless sudo unavailable" {
  make_stub brave
  stub_dnf
  stub_sudo
  export MOCK_DNF_UPDATE=yes MOCK_SUDO_OK=no
  run bash -c "source '$SOURCE_FILE'; perform_browser_update dnf brave"
  [[ $status -eq 0 ]]
  [[ $output == *"Skipping update: passwordless sudo not configured."* ]]
}

@test "perform_browser_update [distrobox]: notifies on successful upgrade" {
  stub_distrobox
  export CONTAINER_NAME=bravebox MOCK_DNF_UPDATE=yes MOCK_SUDO_OK=yes
  run bash -c "source '$SOURCE_FILE'; perform_browser_update distrobox brave-browser"
  [[ $status -eq 0 ]]
  [[ $output == *"Upgrading in container..."* ]]
}

@test "perform_browser_update [distrobox]: skips when passwordless sudo unavailable" {
  stub_distrobox
  export CONTAINER_NAME=bravebox MOCK_DNF_UPDATE=yes MOCK_SUDO_OK=no
  run bash -c "source '$SOURCE_FILE'; perform_browser_update distrobox brave-browser"
  [[ $status -eq 0 ]]
  [[ $output == *"Skipping update: passwordless sudo not configured in bravebox."* ]]
}

# ── init_profile ──────────────────────────────────────────────────────────────

@test "init_profile: writes a template .conf" {
  export PROFILE_DIR="$TEST_ROOT/profiles"
  run_main --init brave
  [[ $status -eq 0 ]]
  [[ $output == *"Wrote"* ]]
  [[ -f "$PROFILE_DIR/brave.conf" ]]
}

@test "init_profile: refuses to overwrite an existing profile" {
  export PROFILE_DIR="$TEST_ROOT/profiles"
  mkdir -p "$PROFILE_DIR"
  touch "$PROFILE_DIR/brave.conf"
  run_main --init brave
  [[ $status -ne 0 ]]
  [[ $output == *"already exists"* ]]
}

@test "init_profile: rejects invalid profile names" {
  export PROFILE_DIR="$TEST_ROOT/profiles"
  run_main --init "bad name"
  [[ $status -ne 0 ]]
  [[ $output == *"invalid profile name"* ]]
}

# ── CLI guards ────────────────────────────────────────────────────────────────

@test "CLI: unknown --helper-* dispatch returns error" {
  run_main --helper-bogus
  [[ $status -ne 0 ]]
  [[ $output == *"unknown helper"* ]]
}
