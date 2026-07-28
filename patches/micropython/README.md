# MicroPython patches

Mailbox patches for a stock
[micropython/micropython](https://github.com/micropython/micropython) tree
(`git am`).

**Base:** tag `v1.28.0` (`e0e9fbb17`).

| Patch | Purpose |
|-------|---------|
| `0001-…windows…networking…` | Windows-local `modsocket.c` (Winsock), `select`/asyncio wakeups, mingw/msvc mbedtls SSL, MSVC project glue, and related `tests/**` updates |
| `0002-…MICROPY_SCHEDULER_DEPTH…` | Raise unix `MICROPY_SCHEDULER_DEPTH` for desktop SDL / host display timers |

## Apply

From a clean `v1.28.0` checkout:

```bash
git checkout v1.28.0
git am 0001-*.patch
git am 0002-*.patch
```

## Regenerate

On a tree with these two commits atop `v1.28.0`:

```bash
git format-patch -2 -o .
```
