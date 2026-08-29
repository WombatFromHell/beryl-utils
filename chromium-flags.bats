#!/usr/bin/env bats

setup() {
  export TEST_CONFIG="$BATS_TMPDIR/chromium-flags.conf"
  export FLAGS_CONFIG="$TEST_CONFIG"
  mkdir -p "$(dirname "$TEST_CONFIG")"
}

teardown() {
  rm -f "$TEST_CONFIG"
}

# Helper to check if an array contains a substring without ShellCheck errors
assert_array_contains() {
  local pattern="$1"
  shift
  local arr=("$@")
  local output_string
  output_string=$(printf '%s\n' "${arr[@]}")
  [[ $output_string == *"$pattern"* ]]
}

assert_array_does_not_contain() {
  local pattern="$1"
  shift
  local arr=("$@")
  local output_string
  output_string=$(printf '%s\n' "${arr[@]}")
  [[ $output_string != *"$pattern"* ]]
}

#------------------------------------------------------------------------------
# CONFIG PARSING TESTS
#------------------------------------------------------------------------------

@test "Config: ignores lines starting with '#' (standard comment)" {
  cat <<EOF >"$TEST_CONFIG"
# --this-is-a-comment
--real-flag
EOF
  run bash chromium-flags.sh --dry-run brave-browser
  [ "$status" -eq 0 ]
  assert_array_contains "--real-flag" "${lines[@]}"
  assert_array_does_not_contain "--this-is-a-comment" "${lines[@]}"
}

@test "Config: ignores lines starting with whitespace then '#'" {
  cat <<EOF >"$TEST_CONFIG"
    # --indented-comment
--active-flag
EOF
  run bash chromium-flags.sh --dry-run brave-browser
  [ "$status" -eq 0 ]
  assert_array_contains "--active-flag" "${lines[@]}"
  assert_array_does_not_contain "--indented-comment" "${lines[@]}"
}

@test "Config: ignores empty lines and whitespace-only lines" {
  cat <<EOF >"$TEST_CONFIG"

    

--valid-flag
EOF
  run bash chromium-flags.sh --dry-run brave-browser
  [ "$status" -eq 0 ]
  # Should only have command + flag (2 items)
  [ "${#lines[@]}" -eq 2 ]
}

@test "Config: trims whitespace from valid flags" {
  echo "   --spaced-flag   " >"$TEST_CONFIG"
  run bash chromium-flags.sh --dry-run brave-browser
  [ "${lines[1]}" = "--spaced-flag" ]
}

#------------------------------------------------------------------------------
# FUNCTIONAL STRATEGY TESTS
#------------------------------------------------------------------------------

@test "Strategy: Standard command injection" {
  echo "--flag1" >"$TEST_CONFIG"
  run bash chromium-flags.sh --dry-run brave-browser --incognito
  [ "${lines[0]}" = "brave-browser" ]
  [ "${lines[1]}" = "--flag1" ]
  [ "${lines[2]}" = "--incognito" ]
}

@test "Strategy: Flatpak injection after App ID" {
  echo "--flatpak-flag" >"$TEST_CONFIG"
  run bash chromium-flags.sh --dry-run flatpak run com.brave.Browser %U
  [ "${lines[0]}" = "flatpak" ]
  [ "${lines[1]}" = "run" ]
  [ "${lines[2]}" = "com.brave.Browser" ]
  [ "${lines[3]}" = "--flatpak-flag" ]
  [ "${lines[4]}" = "%U" ]
}

@test "Strategy: Distrobox injection after '--'" {
  echo "--distro-flag" >"$TEST_CONFIG"
  run bash chromium-flags.sh --dry-run distrobox-enter -n box -- brave-browser
  [ "${lines[0]}" = "distrobox-enter" ]
  [ "${lines[3]}" = "--" ]
  [ "${lines[4]}" = "brave-browser" ]
  [ "${lines[5]}" = "--distro-flag" ]
}
