# Frozen Python from cmods user-module repos, plus the MicroPython upstream
# freeze for the active port/board/variant.
#
# ``build_mp.sh`` sets ``FROZEN_MANIFEST_UPSTREAM`` to the same manifest file
# MicroPython would have selected (most-specific variant/board/port file).
# This static file includes that path so no generated wrapper is needed.
#
# Optional local overrides: ``manifest-user.py`` (gitignored). Use ``package()`` to
# freeze a tree; paths are relative to the current (workspace) directory. The
# first argument is the import name; that name must be a folder under
# ``base_path``. Example::
#
#     package("pdwidgets", base_path="../pdwidgets/lib", opt=3)
#
# freezes ``../pdwidgets/lib/pdwidgets/`` as importable ``pdwidgets`` (not
# ``lib``).
#
# Child ``*/manifest.py`` inclusion (no hard-coded repo names): include when the
# sibling has ``micropython.mk``, or lacks ``apply_cp_patches.sh`` (skips
# CircuitPython-only trees that would double-freeze shared helpers).

import os

# The direct WebAssembly variant must freeze its Fetch-backed requests module
# before mip's dependency resolver adds the socket implementation; frozen
# module lookup keeps the first matching module.
_upstream_hint = os.environ.get("FROZEN_MANIFEST_UPSTREAM", "")
if "/variants/webassembly/pydevices/" in _upstream_hint.replace("\\", "/"):
    freeze("variants/webassembly/pydevices", "requests.py", opt=3)
    # Freeze mip without resolving its socket-based requests dependency. The
    # sources import the Fetch facade above at runtime.
    require("argparse")
    freeze("$(MPY_LIB_DIR)/micropython/mip", ("mip/__init__.py",), opt=3)
    freeze("$(MPY_LIB_DIR)/micropython/mip-cmdline", ("mip/__main__.py",), opt=3)
    # Deliberately NOT freezing the pydevices libs (appdev, audiodev,
    # displaydev, multimer, boarddev, events, keys): pydevices is a work in
    # progress, and frozen copies silently shadow mip-installed / VFS-staged
    # ones -- a stale frozen audiodev cost a whole debugging session before
    # anyone realized the browser wasn't running the published code. Until
    # development settles, every host installs pydevices-desktop via mip
    # (hero-runtime.js, the simulator, and the browser contract harness all
    # already do), so what runs is always what is published or staged --
    # never a build-time snapshot.
else:
    # ``micropython -m mip`` (mip/__main__.py). Unix variants already require
    # this; windows/webassembly get ``mip`` via networking bundles but not the
    # cmdline. CircuitPython also includes this file and has no mip.
    require("mip-cmdline")

# Optional personal overrides. A missing file is fine; errors inside an
# existing file must surface. Guard by existence, not exception: the
# manifest freezer wraps a missing include in its own ManifestFileError,
# which an ``except OSError`` never catches -- so on a clean checkout
# (no gitignored manifest-user.py) the freeze failed outright.
if os.path.isfile("manifest-user.py"):
    include("manifest-user.py")

for _name in sorted(os.listdir(".")):
    if _name.startswith("."):
        continue
    _path = os.path.join(_name, "manifest.py")
    if not os.path.isfile(_path):
        continue
    _has_mp = os.path.isfile(os.path.join(_name, "micropython.mk"))
    _has_cp_patches = os.path.isfile(os.path.join(_name, "apply_cp_patches.sh"))
    if not (_has_mp or not _has_cp_patches):
        continue
    try:
        include(_path)
    except Exception:
        pass

_upstream = _upstream_hint.strip()
if not _upstream:
    raise Exception(
        "FROZEN_MANIFEST_UPSTREAM is not set. "
        "Use ./build_mp.sh, or export FROZEN_MANIFEST_UPSTREAM to the "
        "MicroPython port/board/variant manifest.py for this build."
    )
include(_upstream)
