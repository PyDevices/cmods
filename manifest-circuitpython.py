# Frozen Python from cmods extension repos, plus the CircuitPython upstream
# freeze for the active port/board/variant.
#
# ``build_cp.sh`` sets ``FROZEN_MANIFEST_UPSTREAM`` to the freeze CircuitPython
# would use: a unix variant/port manifest, or a generated ``BUILD/manifest.py``
# when ``FROZEN_MPY_DIRS`` is nonempty. Upstream may be empty for boards with
# no generated freeze.
#
# Optional local overrides: ``manifest-user.py`` (gitignored). Use ``package()``
# to freeze a tree; paths are relative to the current (workspace) directory.
#
# Child ``*/manifest.py`` inclusion (no hard-coded repo names): include when the
# sibling has ``apply_cp_patches.sh``, or lacks ``micropython.mk`` (skips
# MicroPython-only trees that would double-freeze shared helpers).

import os

try:
    include("manifest-user.py")
except OSError:
    pass

for _name in sorted(os.listdir(".")):
    if _name.startswith("."):
        continue
    _path = os.path.join(_name, "manifest.py")
    if not os.path.isfile(_path):
        continue
    _has_mp = os.path.isfile(os.path.join(_name, "micropython.mk"))
    _has_cp_patches = os.path.isfile(os.path.join(_name, "apply_cp_patches.sh"))
    if not (_has_cp_patches or not _has_mp):
        continue
    try:
        include(_path)
    except Exception:
        pass

_upstream = os.environ.get("FROZEN_MANIFEST_UPSTREAM", "").strip()
if _upstream:
    include(_upstream)
