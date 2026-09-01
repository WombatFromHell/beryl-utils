#!/usr/bin/env python3
"""niri-hdr.py - run a command with niri HDR enabled, restore the config after.

niri-spicy only accepts `hdr mode="auto"` or `mode="on"` inside an
`output "LABEL" { ... }` block, so "HDR off" means the hdr line/block is
commented out with `//`.

Usage:
  niri-hdr.py [flags] -- CMD [ARGS...]   enable HDR, run CMD, restore HDR
  niri-hdr.py --dry-run CMD              print transformed config, run nothing
  niri-hdr.py --self-test                built-in tests

Note: CMD's own options must not clash with the flags below (niri-hdr's
flags must precede `--`).

If there is nothing to toggle (no `output` blocks, the target output has
no `hdr mode=...` line, or --output matches no block) the wrapper still
runs CMD, leaves the config untouched, and notes it on stderr.

Flags:
  --output LABEL   target a specific `output "LABEL"` block (auto: first
                   block with an `hdr mode=` line)
  --config PATH    override config path (default: $NIRI_CONFIG,
                   else ~/.config/niri/config.kdl)
  --keep           leave HDR enabled after CMD exits
  --dry-run        print the transformed config to stdout, run nothing
  --list           list HDR-capable candidate output labels (one per line,
                   prefixed "HDR: "), run nothing
"""

import argparse
import os
import re
import signal
import subprocess
import sys

OUTPUT_RE = re.compile(r'^\s*output\s+"([^"]*)"\s*\{')
HDR_RE = re.compile(r"^\s*(//\s*)?hdr\s+mode\s*=")
OFF_RE = re.compile(r'mode="off"')


def _brace_delta(line):
    return line.count("{") - line.count("}")


def _block_end(lines, start):
    """Last line index where the brace(s) opened at `start` balance out; the
    last line of the file if they never do."""
    depth = 0
    for j in range(start, len(lines)):
        depth += _brace_delta(lines[j])
        if depth <= 0:
            return j
    return len(lines) - 1


def find_outputs(lines):
    """Return [(label, start_idx, end_idx)] for each top-level output block."""
    outs = []
    for i, line in enumerate(lines):
        m = OUTPUT_RE.match(line)
        if m:
            outs.append((m.group(1), i, _block_end(lines, i)))
    return outs


def find_hdr(lines, start, end):
    """Return (hdr_line_idx, block_end) of the first hdr line in lines[start:end],
    extending to its closing brace if it opens one. None if absent."""
    for i in range(start, end + 1):
        if HDR_RE.match(lines[i]):
            return i, _block_end(lines, i)
    return None


def hdr_blocks(lines):
    """Output blocks [(label, start, end)] that contain an hdr mode= line."""
    return [o for o in find_outputs(lines) if find_hdr(lines, o[1], o[2]) is not None]


def _comment_block(lines, i0, i1):
    out = list(lines)
    for k in range(i0, i1 + 1):
        indent = re.match(r"\s*", lines[k]).end()
        out[k] = lines[k][:indent] + "// " + lines[k][indent:]
    return out


def _uncomment_block(lines, i0, i1):
    out = list(lines)
    for k in range(i0, i1 + 1):
        m = re.match(r"(\s*)//(\s?)", out[k])
        if m:
            out[k] = m.group(1) + out[k][m.end() :]
    return out


def transform(lines, label, enable):
    """Return (new_lines, changed, reason). reason is None when the target
    output's hdr line/block was found and handled, else a message (nothing
    to toggle)."""
    outs = find_outputs(lines)
    matches = [o for o in outs if o[0] == label]
    if not matches:
        return (
            lines,
            False,
            (
                f'output "{label}" not found (candidates: '
                f"{', '.join(l for l, _, _ in outs) or 'none'})"
            ),
        )
    start, end = matches[0][1:]
    h = find_hdr(lines, start, end)
    if h is None:
        return lines, False, f'output "{label}" has no hdr mode= line'
    i0, i1 = h
    commented = lines[i0].lstrip().startswith("//")
    changed = False
    if enable:
        if commented:
            lines = _uncomment_block(lines, i0, i1)
            changed = True
        # niri-spicy has no "off" value: remap legacy mode="off" -> "on".
        if OFF_RE.search(lines[i0]):
            lines = list(lines)
            lines[i0] = OFF_RE.sub('mode="on"', lines[i0], count=1)
            changed = True
    elif not commented:
        lines = _comment_block(lines, i0, i1)
        changed = True
    return lines, changed, None


def self_test():
    orig = (
        'output "A" {\n'
        '    mode "1920x1080@60"\n'
        "    scale 1\n"
        '    hdr mode="on" {\n'
        "        reference-luminance 230\n"
        "    }\n"
        "    layout {\n"
        "        gaps 8\n"
        "    }\n"
        "}\n"
        "\n"
        'output "B" {\n'
        '    mode "2560x1440@144"\n'
        '    // hdr mode="on" { reference-luminance 203; }\n'
        "}\n"
        "\n"
        'output "C" {\n'
        '    hdr mode="off"\n'
        "}"
    )
    lines = orig.split("\n")
    passed = []

    def check(name, cond):
        ok = bool(cond)
        passed.append(ok)
        print(("PASS " if ok else "FAIL ") + name)

    # 1. disable A: exactly the 3-line block commented, nothing else touched
    out, changed, reason = transform(lines, "A", False)
    check(
        "disable expanded block",
        reason is None
        and changed
        and out[3:6]
        == ['    // hdr mode="on" {', "        // reference-luminance 230", "    // }"],
    )
    check("rest of file untouched", out[:3] == lines[:3] and out[6:] == lines[6:])

    # 2. round-trip A
    rt, _, _ = transform(out, "A", True)
    check("enable round-trip", rt == lines)

    # 3. B: one-liner already commented -> disable no-op, enable strips it
    out, changed, reason = transform(lines, "B", False)
    check("disable idempotent", reason is None and not changed and out == lines)
    out, changed, reason = transform(lines, "B", True)
    check(
        "enable one-liner",
        changed and out[13] == '    hdr mode="on" { reference-luminance 203; }',
    )

    # 4. C: single-line mode="off" -> on
    out, changed, reason = transform(lines, "C", True)
    check(
        "off->on remap", reason is None and changed and out[17] == '    hdr mode="on"'
    )

    # 5. targeting: disabling C leaves A and B alone
    out, changed, reason = transform(lines, "C", False)
    check(
        "target only C",
        changed
        and out[:17] == lines[:17]
        and out[17] == '    // hdr mode="off"'
        and out[18:] == lines[18:],
    )

    # 6. unknown label: no exception, nothing changed, reason set
    out, changed, reason = transform(lines, "nope", True)
    check("unknown label noop", out == lines and not changed and "nope" in reason)

    # 7. config with zero output blocks
    plain = 'global {\n    theme "dark"\n}'
    pl = plain.split("\n")
    out, changed, reason = transform(pl, "A", True)
    check("zero outputs noop", out == pl and not changed and reason is not None)

    # 8. output block without any hdr line
    nl = 'output "D" {\n    mode "1080p"\n}'.split("\n")
    out, changed, reason = transform(nl, "D", True)
    check("no hdr line noop", out == nl and not changed and "hdr" in reason)

    # 9. found=True (reason None) even when state already matches
    out, changed, reason = transform(lines, "A", True)
    check("already enabled found", reason is None and not changed)

    return 1 if not all(passed) else 0


def die(msg, code=1):
    print(f"niri-hdr: {msg}", file=sys.stderr)
    sys.exit(code)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--output", help='target `output "LABEL"` block')
    ap.add_argument("--config", help="config path override")
    ap.add_argument(
        "--list",
        action="store_true",
        help="list output labels with an hdr mode= line, run nothing",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="print transformed config to stdout, run nothing",
    )
    ap.add_argument(
        "--keep", action="store_true", help="leave HDR enabled after the command exits"
    )
    ap.add_argument("--self-test", action="store_true")
    args, cmd = ap.parse_known_args()

    if args.self_test:
        sys.exit(self_test())
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd and not args.list:
        ap.print_help()
        sys.exit(2)

    path = (
        args.config
        or os.environ.get("NIRI_CONFIG")
        or os.path.join(os.path.expanduser("~"), ".config", "niri", "config.kdl")
    )
    # resolve symlinks so backup/restore hit the real file
    path = os.path.realpath(path)
    if not os.path.isfile(path):
        die(f"config not found: {path}")

    with open(path) as f:
        text = f.read()
    lines = text.split("\n")

    outs = find_outputs(lines)
    hdr = hdr_blocks(lines)
    if args.list:
        for label, _, _ in hdr:
            print(f"HDR: {label}")
        return
    if args.output:
        label = args.output
    elif len(outs) == 1:
        label = outs[0][0]
    elif hdr:
        # default: first block that actually has an hdr mode= line
        label = hdr[0][0]
    elif outs:
        die(
            f"multiple output blocks, none with an hdr mode= line, use --output "
            f"(candidates: {', '.join(l for l, _, _ in outs)})",
            2,
        )
    else:
        label = None

    enabled, _, reason = (
        transform(lines, label, True)
        if label
        else (lines, False, "no output blocks in config")
    )
    text_enabled = "\n".join(enabled)

    if args.dry_run:
        sys.stdout.write(text_enabled)
        return

    if reason is not None:
        print(
            f"niri-hdr: {path}: {reason}; "
            f"running {' '.join(cmd)} without config changes",
            file=sys.stderr,
        )
        sys.exit(subprocess.run(cmd).returncode)

    # backup, then enable in place
    with open(path + ".bak", "w") as f:
        f.write(text)

    def _restore():
        if args.keep:
            return
        try:
            with open(path, "w") as f:
                f.write(text)
        except OSError as e:
            print(f"niri-hdr: restore failed: {e}", file=sys.stderr)

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(128 + signal.SIGTERM))
    try:
        with open(path, "w") as f:
            f.write(text_enabled)
        rc = subprocess.run(cmd).returncode
    finally:
        _restore()
    sys.exit(rc)


if __name__ == "__main__":
    main()
