"""Helpers for using the pip-installed pycparser package."""

from __future__ import annotations

from pathlib import Path

_PKG_DIR = Path(__file__).resolve().parent


def fake_libc_include() -> str:
    """Path to fake libc headers for gcc -E (vendored; not in pip wheels)."""
    local = _PKG_DIR / "fake_libc_include"
    if local.is_dir():
        return str(local)
    import pycparser

    return str(Path(pycparser.__file__).resolve().parent / "utils" / "fake_libc_include")
