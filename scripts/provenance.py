#!/usr/bin/env python3
"""Stamp an interpreter with the commits it was built from, and refuse a stale one.

cmods#27. A binary in `bin/` reports MicroPython's own version and a build date
and says nothing about which audiodsp, usbif, displayif or lvgl-bindings was
compiled into it:

    3.4.0; MicroPython v1.28.0-dirty on 2026-09-02

On 2026-09-03 that cost a week of green gates. `bin/micropython` was built at
01:16; an audiodsp C change landed at 01:29, thirteen minutes later; and every
parity run after that certified a binary that did not contain the code the gate
was about. Nothing in the workspace could tell. **A green gate on a stale binary
is the most expensive kind of stale**, because absence of a signal reads as
agreement.

    write   build_interpreters.sh calls this after each install
    check   a gate calls this before it renders anything

`check` exits non-zero and names the rebuild command. It is meant to be a
refusal, not a warning: a gate that prints "possibly stale" and runs anyway has
told nobody anything.

    python3 scripts/provenance.py check bin/micropython --source audiodsp
    python3 scripts/provenance.py check bin/micropython           # every source

What it cannot know: `--install-only` copies a binary somebody built earlier,
and the stamp is written now. The stamp records that (`install_only`), and
`check` says so rather than pretending the two are the same claim.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

FORMAT = 1
CMODS = Path(__file__).resolve().parents[1]

#: Every directory in cmods carrying a `micropython.mk` is in every Make-port
#: build, because py.mk globs `$(USER_C_MODULES)/*/micropython.mk` one level
#: down -- so the link set is not a list somebody maintains, it is whatever is
#: sitting here. Derived, never hardcoded: a module added to cmods for one port
#: silently enters all the others' builds on their next run.
def linked_usermods() -> dict[str, Path]:
    found: dict[str, Path] = {}
    for entry in sorted(CMODS.iterdir()):
        if not entry.is_dir() or entry.name.startswith("."):
            continue
        if entry.name in ("micropython", "circuitpython"):
            continue
        if not ((entry / "micropython.mk").exists()
                or (entry / "micropython.cmake").exists()):
            continue
        # A usermod is a sibling REPOSITORY reached through a symlink here. A
        # directory that resolves inside cmods itself (wasmbridge, and the
        # .cpws_* scratch trees a CircuitPython workspace leaves behind) is
        # cmods' own code: recording it would list cmods' HEAD under three
        # different names and call each one a usermod.
        resolved = entry.resolve()
        top = _git(resolved, "rev-parse", "--show-toplevel")
        if top is None or Path(top).resolve() == CMODS.resolve():
            continue
        found[entry.name] = resolved
    return found


def _git(repo: Path, *args: str) -> str | None:
    try:
        out = subprocess.run(["git", "-C", str(repo), *args],
                             capture_output=True, text=True, timeout=60)
    except OSError:
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip()


def describe_repo(path: Path) -> dict | None:
    head = _git(path, "rev-parse", "HEAD")
    if head is None:
        return None
    status = _git(path, "status", "--porcelain")
    return {
        "path": str(path),
        "head": head,
        "describe": _git(path, "describe", "--always", "--dirty", "--abbrev=7") or head[:7],
        # A dirty tree is the normal state in this workspace. It is recorded
        # rather than refused, because a check that is red every day stops
        # being read -- but it is recorded, because a dirty build is not any
        # commit and nobody can reconstruct it later.
        "dirty": bool(status),
        "committed": _git(path, "log", "-1", "--format=%cI") or "",
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stamp_path(binary: Path) -> Path:
    return binary.with_name(binary.name + ".provenance")


def overlays_applied(port: str) -> list[str]:
    """The patch files build_mp.sh would have applied for this port.

    Recorded because a patched interpreter is not upstream's, and the patch
    series moves independently of every repo above.
    """
    patches = CMODS / "patches"
    if not patches.is_dir():
        return []
    return sorted(p.name for p in patches.glob(f"*micropython-{port}*"))


def cmd_write(args: argparse.Namespace) -> int:
    binary = Path(args.binary).resolve()
    if not binary.exists():
        print(f"no such binary: {binary}", file=sys.stderr)
        return 1
    sources = {}
    for name, path in linked_usermods().items():
        info = describe_repo(path)
        if info is not None:
            sources[name] = info
    # The interpreter checkouts, and cmods itself -- the overlay patches, the
    # frozen manifests and the build scripts all live here and all change what
    # a binary contains.
    for name in ("micropython", "circuitpython"):
        info = describe_repo(CMODS / name)
        if info is not None:
            sources[name] = info
    info = describe_repo(CMODS)
    if info is not None:
        sources["cmods"] = info

    record = {
        "format": FORMAT,
        "target": args.target,
        "stamped": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        # True when the binary was copied rather than built in this run, which
        # means the sources below describe now and not necessarily the build.
        "install_only": bool(args.install_only),
        "binary": {
            "name": binary.name,
            "sha256": sha256(binary),
            "size": binary.stat().st_size,
            "mtime": datetime.datetime.fromtimestamp(
                binary.stat().st_mtime).astimezone().isoformat(timespec="seconds"),
        },
        "overlays": overlays_applied(args.port) if args.port else [],
        "sources": sources,
    }
    out = stamp_path(binary)
    out.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    dirty = sorted(n for n, s in sources.items() if s["dirty"])
    print(f"Stamped {out} ({len(sources)} sources"
          + (f", dirty: {', '.join(dirty)}" if dirty else "") + ")")
    return 0


REBUILD = {
    "micropython": "./build_interpreters.sh --only mp-unix",
    "circuitpython": "./build_interpreters.sh --only cp-unix",
}


def _rebuild_hint(binary: Path) -> str:
    for key, command in REBUILD.items():
        if binary.name.startswith(key):
            return command
    return "./build_interpreters.sh --only <target>"


def cmd_check(args: argparse.Namespace) -> int:
    binary = Path(args.binary).resolve()
    stamp = stamp_path(binary)
    hint = _rebuild_hint(binary)
    if not binary.exists():
        print(f"REFUSED: no interpreter at {binary}\n  build it: {hint}")
        return 1
    if not stamp.exists():
        print(f"REFUSED: {binary.name} has no provenance stamp beside it, so what "
              f"it was built from is unknown and it may predate anything.\n"
              f"  rebuild it: {hint}")
        return 1
    record = json.loads(stamp.read_text(encoding="utf-8"))
    if record.get("format") != FORMAT:
        print(f"REFUSED: {stamp.name} is format {record.get('format')!r}, "
              f"this script writes {FORMAT}.")
        return 1

    problems: list[str] = []
    notes: list[str] = []

    actual = sha256(binary)
    if actual != record["binary"]["sha256"]:
        problems.append(
            f"the binary is not the one that was stamped: {actual[:12]} now, "
            f"{record['binary']['sha256'][:12]} in the stamp. Something replaced "
            f"it without stamping it.")

    wanted = args.source or sorted(record["sources"])
    for name in wanted:
        stamped = record["sources"].get(name)
        if stamped is None:
            problems.append(f"the stamp says nothing about {name}: it was not in "
                            f"cmods when this binary was installed, so it is not "
                            f"in the binary either.")
            continue
        now = describe_repo(Path(stamped["path"]))
        if now is None:
            notes.append(f"{name}: {stamped['path']} is not a git checkout now; "
                         f"cannot compare.")
            continue
        if now["head"] != stamped["head"]:
            behind = _git(Path(stamped["path"]), "rev-list", "--count",
                          f"{stamped['head']}..{now['head']}")
            if behind and behind.isdigit() and int(behind):
                how = "%s commit%s behind" % (behind, "" if behind == "1" else "s")
            else:
                how = "on a different commit from"
            problems.append(
                f"{name}: the binary is {how} the checkout. Built from "
                f"{stamped['describe']}, the tree is at {now['describe']}.")
        if stamped["dirty"]:
            notes.append(f"{name}: built from a dirty tree ({stamped['describe']}), "
                         f"so what it contains is not any commit.")
        if now["dirty"] and now["head"] == stamped["head"]:
            notes.append(f"{name}: the checkout has uncommitted changes now, which "
                         f"this binary cannot contain.")

    if record.get("install_only"):
        notes.append("this stamp was written by --install-only, so it describes the "
                     "sources at install time and not necessarily at build time.")

    for note in notes:
        print(f"  note: {note}")
    if problems:
        print(f"REFUSED: {binary.name} is older than the code it would certify.")
        for problem in problems:
            print(f"  - {problem}")
        print(f"  rebuild it: {hint}")
        return 1
    print(f"{binary.name}: provenance OK "
          f"({len(wanted)} source(s) match the checkout)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    write = sub.add_parser("write", help="stamp a binary that was just installed")
    write.add_argument("binary")
    write.add_argument("--target", default="", help="the build_interpreters.sh target")
    write.add_argument("--port", default="", help="port name, for the overlay list")
    write.add_argument("--install-only", action="store_true")
    write.set_defaults(func=cmd_write)

    check = sub.add_parser("check", help="refuse a binary older than its sources")
    check.add_argument("binary")
    check.add_argument("--source", action="append",
                       help="only compare this source (repeatable); default is all")
    check.set_defaults(func=cmd_check)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
