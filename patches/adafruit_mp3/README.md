# Adafruit_MP3 patches

Local patches for the sibling `mp3/` checkout
([adafruit/Adafruit_MP3](https://github.com/adafruit/Adafruit_MP3)).
These are **not** applied by `build_mp.sh` (its mailbox queue is the
`micropython-<port>` files in the parent directory); apply by hand:

    git -C mp3 apply ../patches/adafruit_mp3/0001-windows-msvc-inline-assembly.patch

## 0001-windows-msvc-inline-assembly

- **Purpose:** `src/assembly.h` guards MSVC-only `__asm { }` syntax with
  `_WIN32`, which mingw-w64 GCC also defines; add `!defined(__GNUC__)` so the
  Windows MicroPython build falls through to the portable C fallback (the
  same one the unix build uses). Upstream never hits this: CircuitPython has
  no Windows port.
- **Base:** `aac02af` ("Fix undefined behavior on host"). Expected to apply
  to any revision while upstream's `_WIN32` guard is unchanged.
- **Provenance:** Brad's workspace, previously uncommitted; documented in
  `micropython-audio`'s upstream-diff notes. Captured 2026-08-27 per the
  modernization roadmap's pre-handoff checklist
  (dotgithub `docs/pydevices-organization-modernization.md`, section 2.2).
- **Demonstrated by:** the Windows MicroPython + audioif build compiling at
  all with mingw-w64 (the guarded branch is a compile error there).
- **Disposition:** moves to the native component's own patch queue in Phase 2
  of the modernization program; candidate for upstreaming to Adafruit_MP3
  (trivially safe for MSVC users).
