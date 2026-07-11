# Frozen Python from cmods user-module repos, plus the MicroPython upstream
# freeze for the active port/board/variant.
#
# ``build_mp.sh`` sets ``FROZEN_MANIFEST_UPSTREAM`` to the same manifest file
# MicroPython would have selected (most-specific variant/board/port file).
# This static file includes that path so no generated wrapper is needed.
#
# Optional local overrides: ``my-manifest.py`` (gitignored).

import os

_SKIP = frozenset()

try:
    include("my-manifest.py")
except Exception:
    pass

for _name in sorted(os.listdir(".")):
    if _name in _SKIP or _name.startswith("."):
        continue
    _path = os.path.join(_name, "manifest.py")
    if os.path.isfile(_path):
        try:
            include(_path)
        except Exception:
            pass

_upstream = os.environ.get("FROZEN_MANIFEST_UPSTREAM", "").strip()
if not _upstream:
    raise Exception(
        "FROZEN_MANIFEST_UPSTREAM is not set. "
        "Use ./build_mp.sh, or export FROZEN_MANIFEST_UPSTREAM to the "
        "MicroPython port/board/variant manifest.py for this build."
    )
include(_upstream)
