# One task runner for this repo. Run it from the repo root: `nix build .#default`
# and the paths below both assume relative paths.
# ponytail: file sets come from find, so a new script, test, or helper is covered
# here without editing this file.

# fmt and lint share one shell-file set so they cannot drift apart. The -print0
# and xargs pairing keeps that set on one line: just pastes every line of a
# multi-line value into a recipe as its own command, which would run the scripts.
SHELL_FILES := `find . -name '*.sh' -o -name '*.bats' -print0 | xargs -0 echo`

fmt:
    shfmt -w -s -i 2 {{ SHELL_FILES }}

lint:
    shellcheck {{ SHELL_FILES }}

test:
    bats $(find . -name '*.bats')
    python3 -m pytest -q $(find . -name 'test-*.py')

build:
    nix build .#default

# Named set, not git clean: -x would delete .pi/ (the gate log) and reach
# .direnv/flake-inputs, which symlinks into the read-only nix store. -prune keeps
# find from descending into a directory it already deleted.

# Remove tool caches at any depth and the nix result link.
clean:
    find . -path ./.git -prune -o -path ./.direnv -prune -o -type d \( -name __pycache__ -o -name .pytest_cache -o -name .ruff_cache \) -prune -exec rm -rf {} +
    rm -f result
