# MicroPython patches (cmods)

Mailbox patches applied by `build_mp.sh` onto a **stock**
[micropython/micropython](https://github.com/micropython/micropython) tree
(`git am`). Prefer that over maintaining a long-lived fork.

| Patch | Purpose |
|-------|---------|
| `0001-…windows-networking…` | Windows sockets (via shared `ports/unix/modsocket.c`), `select`/asyncio wakeups, mingw/msvc mbedtls SSL, MSVC project glue, and `tests/**` updates suitable for an upstream PR |
| `0002-…MICROPY_SCHEDULER_DEPTH…` | Raise unix `MICROPY_SCHEDULER_DEPTH` for desktop SDL / usdl2 timers |

## Intentionally omitted

- Metro M7 / ESP32 partition table changes (unrelated board firmware sizing)
- `ports/windows/soak_net.py` and `run_net_soak.py` — local soak harnesses; upstream PRs should use `tests/` instead

## Apply / skip

`build_mp.sh` applies each patch with `git am` when the reverse of the patch
does **not** already match the tree (so a fork tip that already contains the
content is left alone).

Manual:

```bash
cd micropython   # clean checkout of upstream master
git am ../patches/micropython/*.patch
```

## Regenerate from the old fork tip (reference)

```bash
# worktree at upstream/master, then checkout only the scoped paths from the
# fork branch, commit twice, format-patch -2 -o patches/micropython/
```

See the Agent history that introduced this directory for the exact path list.
