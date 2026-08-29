#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
SOURCE_FILE="${BATS_TEST_DIRNAME}/spawn-browser.sh"

# ── Setup / Teardown ─────────────────────────────────────────────────────────

setup() {
  export HOME="$BATS_TMPDIR/home"
  rm -rf "$HOME"
  mkdir -p "$HOME/.local/share/applications"
  mkdir -p "$HOME/.local/share/flatpak/exports/share/applications"
  mkdir -p "$HOME/.var/app/com.brave.Browser/data/applications"
  mkdir -p "$HOME/.var/app/com.firefox.Firefox/data/applications"

  export PATH="$BATS_TEST_DIRNAME:$PATH"
}

teardown() {
  unset DESKTOP_FILE 2>/dev/null || true
  unset FLATPAK_APP_ID 2>/dev/null || true
  unset BROWSER_NAME 2>/dev/null || true
  unset LAUNCHER_TYPE 2>/dev/null || true
  unset DESKTOP_PATH 2>/dev/null || true
}

# ── Test Helpers ──────────────────────────────────────────────────────────────

run_script() {
  run bash -c "HOME='$HOME' PATH='$PATH' '${SOURCE_FILE}' $(printf '%q ' "$@")"
}

create_desktop_file() {
  local path="$1" filename="$2" exec_line="$3"
  mkdir -p "$(dirname "$path/$filename")"
  printf '[Desktop Entry]\nExec=%s\n' "$exec_line" >"$path/$filename"
}

# ── Desktop File Lookup ──────────────────────────────────────────────────────

@test "find_desktop_path: finds file in user home first" {
  create_desktop_file "$HOME/.local/share/applications" "com.brave.Browser.desktop" "flatpak run com.brave.Browser"
  create_desktop_file "$HOME/.local/share/flatpak/exports/share/applications" "com.brave.Browser.desktop" "flatpak run com.brave.Browser"

  run_script --helper-find-path <<<"com.brave.Browser.desktop"
  [[ $output == "$HOME/.local/share/applications/com.brave.Browser.desktop" ]]
}

@test "find_desktop_path: user-local takes priority over flatpak exports" {
  create_desktop_file "$HOME/.local/share/applications" "firefox.desktop" "firefox --new-window"
  create_desktop_file "$HOME/.local/share/flatpak/exports/share/applications" "firefox.desktop" "firefox --new-window"

  run_script --helper-find-path <<<"firefox.desktop"
  [[ $output == "$HOME/.local/share/applications/firefox.desktop" ]]
}

@test "find_desktop_path: returns empty when not found" {
  run_script --helper-find-path <<<"nonexistent.desktop"
  [[ $output == "" ]]
}

@test "find_desktop_path: finds file in nix-profile" {
  create_desktop_file "$HOME/.local/share/nix-profile/share/applications" "firefox.desktop" "firefox --new-window"

  run_script --helper-find-path <<<"firefox.desktop"
  [[ $output == "$HOME/.local/share/nix-profile/share/applications/firefox.desktop" ]]
}

@test "find_desktop_path: finds file in flatpak exports when not in user home" {
  create_desktop_file "$HOME/.local/share/flatpak/exports/share/applications" "com.brave.Browser.desktop" "flatpak run com.brave.Browser"

  run_script --helper-find-path <<<"com.brave.Browser.desktop"
  [[ $output == "$HOME/.local/share/flatpak/exports/share/applications/com.brave.Browser.desktop" ]]
}

# ── Flatpak Desktop File Validation ───────────────────────────────────────────────────

@test "is_flatpak_desktop_file: valid all-lowercase" {
  run_script --helper-is-flatpak-desktop "com.brave.browser.desktop"
  [[ $status -eq 0 ]]
}

@test "is_flatpak_desktop_file: valid with uppercase segments" {
  run_script --helper-is-flatpak-desktop "org.mozilla.firefox.desktop"
  [[ $status -eq 0 ]]
}

@test "is_flatpak_desktop_file: valid with mixed case" {
  run_script --helper-is-flatpak-desktop "com.brave.Browser.desktop"
  [[ $status -eq 0 ]]
}

@test "is_flatpak_desktop_file: invalid - starts with number" {
  run_script --helper-is-flatpak-desktop "123.example.desktop"
  [[ $status -ne 0 ]]
}

@test "is_flatpak_desktop_file: invalid - missing dot" {
  run_script --helper-is-flatpak-desktop "combravedesktop"
  [[ $status -ne 0 ]]
}

# ── Text Processing ──────────────────────────────────────────────────────────

@test "extract_exec_line: returns raw exec line" {
  create_desktop_file "$HOME/.local/share/applications" "brave.desktop" "chromium-flags.sh brave-browser %U"

  run_script --helper-extract-exec "$HOME/.local/share/applications/brave.desktop"
  [[ $output == "chromium-flags.sh brave-browser %U" ]]
}

@test "strip_field_codes: removes %u %U %f %F" {
  run_script --helper-strip-field-codes "firefox -new-window -P default %u %U"
  [[ $output == "firefox -new-window -P default" ]]
}

@test "strip_field_codes: removes @@ markers" {
  run_script --helper-strip-field-codes "google-chrome-stable @@u %U"
  [[ $output == "google-chrome-stable" ]]
}

@test "strip_field_codes: removes combined field codes and @@ markers" {
  run_script --helper-strip-field-codes "browser @@c %u %U %f %F"
  [[ $output == "browser" ]]
}

@test "strip_field_codes: trims leading and trailing whitespace" {
  run_script --helper-strip-field-codes "  firefox %u  "
  [[ $output == "firefox" ]]
}

@test "apply_url: replaces %U and %u with url" {
  run_script --helper-substitute-url "chromium-flags.sh %U" "https://example.com"
  [[ $output == "chromium-flags.sh https://example.com" ]]
}

@test "apply_url: replaces %u when %U is absent" {
  run_script --helper-substitute-url "firefox %u" "https://example.com"
  [[ $output == "firefox https://example.com" ]]
}

@test "apply_url: replaces both %U and %u" {
  run_script --helper-substitute-url "browser %U %u" "https://example.com"
  [[ $output == "browser https://example.com https://example.com" ]]
}

@test "apply_url: strips remaining field codes after substitution" {
  run_script --helper-substitute-url "chromium-flags.sh %U %f %F" "https://example.com"
  [[ $output == "chromium-flags.sh https://example.com" ]]
}

@test "apply_url: handles empty url by removing all field codes" {
  run_script --helper-substitute-url "chromium-flags.sh %U" ""
  [[ $output == "chromium-flags.sh" ]]
}

@test "apply_url: preserves command when no field codes present" {
  run_script --helper-substitute-url "firefox --new-window" "https://example.com"
  [[ $output == "firefox --new-window" ]]
}

# ── Launcher Detection ───────────────────────────────────────────────────────

@test "detect_launcher_type: flatpak run" {
  run_script --helper-detect-launcher <<<"flatpak run com.brave.Browser"
  [[ $output == "flatpak" ]]
}

@test "detect_launcher_type: flatpak run with absolute path" {
  run_script --helper-detect-launcher <<<"/usr/bin/flatpak run com.brave.Browser"
  [[ $output == "flatpak" ]]
}

@test "detect_launcher_type: distrobox run" {
  run_script --helper-detect-launcher <<<"distrobox run bravebox -- brave-browser"
  [[ $output == "distrobox" ]]
}

@test "detect_launcher_type: native absolute path" {
  run_script --helper-detect-launcher <<<"/usr/bin/firefox --new-window"
  [[ $output == "native" ]]
}

@test "detect_launcher_type: native tilde path" {
  run_script --helper-detect-launcher <<<"$HOME/bin/firefox --new-window"
  [[ $output == "native" ]]
}

@test "detect_launcher_type: bare binary name treated as native" {
  run_script --helper-detect-launcher <<<"firefox --name firefox"
  [[ $output == "native" ]]
}

@test "detect_launcher_type: unknown bare command treated as native" {
  run_script --helper-detect-launcher <<<"unknown-command"
  [[ $output == "native" ]]
}

# ── Browser Capabilities (via build_spawn_cmd) ───────────────────────────────

@test "build_spawn_cmd: flatpak with --new-window for known browser" {
  run_script --helper-build-cmd "flatpak" "com.brave.Browser" "brave"
  [[ $output == "flatpak run com.brave.Browser --new-window" ]]
}

@test "build_spawn_cmd: flatpak with --new-window for firefox" {
  run_script --helper-build-cmd "flatpak" "org.mozilla.firefox" "firefox"
  [[ $output == "flatpak run org.mozilla.firefox --new-window" ]]
}

@test "build_spawn_cmd: distrobox with --new-window for known browser" {
  run_script --helper-build-cmd "distrobox" "bravebox" "brave-browser"
  [[ $output == "distrobox run bravebox -- --new-window" ]]
}

@test "build_spawn_cmd: native with --new-window for known browser" {
  run_script --helper-build-cmd "native" "/usr/bin/firefox" "firefox"
  [[ $output == "/usr/bin/firefox --new-window" ]]
}

@test "build_spawn_cmd: flatpak without --new-window for unknown browser" {
  run_script --helper-build-cmd "flatpak" "com.unknown.App" "unknown-browser"
  [[ $output == "flatpak run com.unknown.App" ]]
}

@test "build_spawn_cmd: distrobox without --new-window for unknown browser" {
  run_script --helper-build-cmd "distrobox" "testbox" "unknown-bin"
  [[ $output == "distrobox run testbox --" ]]
}

@test "build_spawn_cmd: native without --new-window for unknown browser" {
  run_script --helper-build-cmd "native" "/usr/bin/unknown" "unknown"
  [[ $output == "/usr/bin/unknown" ]]
}

@test "build_spawn_cmd: all NEW_WINDOW_BROWSERS get --new-window (flatpak)" {
  local browsers=(firefox librewolf waterfox google-chrome chromium brave microsoft-edge vivaldi floorp epiphany gnome-web)
  for browser in "${browsers[@]}"; do
    run_script --helper-build-cmd "flatpak" "com.test.App" "$browser"
    [[ $output == "flatpak run com.test.App --new-window" ]]
  done
}

# ── Helper Dispatch ──────────────────────────────────────────────────────────

@test "helper dispatch: find-desktop-file rejects empty stdin" {
  run_script --helper-find-desktop-file <<<""
  [[ $output == *"could not determine"* ]]
}

@test "helper dispatch: find-desktop-file echoes non-empty stdin" {
  run_script --helper-find-desktop-file <<<"firefox.desktop"
  [[ $output == "firefox.desktop" ]]
}

@test "helper dispatch: unknown helper returns error" {
  run bash -c "HOME='$HOME' PATH='$PATH' '${SOURCE_FILE}' --helper-nonexistent" 2>&1
  [[ $status -ne 0 ]]
}

# ── Integration: Full Pipeline ───────────────────────────────────────────────

@test "integration: flatpak desktop entry to spawn command" {
  create_desktop_file "$HOME/.local/share/applications" "com.firefox.Firefox.desktop" "flatpak run org.mozilla.firefox --new-window %u"

  run_script --helper-find-path <<<"com.firefox.Firefox.desktop"
  local path="$output"

  run_script --helper-extract-exec "$path"
  run_script --helper-detect-launcher <<<"$output"
  [[ $output == "flatpak" ]]

  run_script --helper-build-cmd "flatpak" "org.mozilla.firefox" "firefox"
  [[ $output == "flatpak run org.mozilla.firefox --new-window" ]]
}

@test "integration: distrobox desktop entry to spawn command" {
  create_desktop_file "$HOME/.local/share/applications" "bravebox.desktop" "distrobox run bravebox -- brave-browser %U"

  run_script --helper-find-path <<<"bravebox.desktop"
  local path="$output"

  run_script --helper-extract-exec "$path"
  run_script --helper-detect-launcher <<<"$output"
  [[ $output == "distrobox" ]]

  run_script --helper-build-cmd "distrobox" "bravebox" "brave-browser"
  [[ $output == "distrobox run bravebox -- --new-window" ]]
}

@test "integration: native desktop entry to spawn command" {
  create_desktop_file "$HOME/.local/share/applications" "firefox.desktop" "firefox %u"

  run_script --helper-find-path <<<"firefox.desktop"
  local path="$output"

  run_script --helper-extract-exec "$path"
  [[ $output == "firefox %u" ]]

  run_script --helper-strip-field-codes "$output"
  [[ $output == "firefox" ]]

  run_script --helper-build-cmd "native" "firefox" "firefox"
  [[ $output == "firefox --new-window" ]]
}

@test "integration: url substitution in wrapper scripts" {
  run_script --helper-substitute-url "chromium-flags.sh brave-browser %U" "https://example.com/page"
  [[ $output == "chromium-flags.sh brave-browser https://example.com/page" ]]
}

@test "integration: flatpak pipeline with field code stripping" {
  create_desktop_file "$HOME/.local/share/applications" "com.brave.Browser.desktop" "flatpak run com.brave.Browser @@u %U"

  run_script --helper-extract-exec "$HOME/.local/share/applications/com.brave.Browser.desktop"
  local exec_line="$output"

  run_script --helper-strip-field-codes "$exec_line"
  [[ $output == "flatpak run com.brave.Browser" ]]
}
