#!/usr/bin/env bash
# Build a pydisplay/LVGL Android APK from the cmods workspace.
#
# Usage:
#   ./build_android.sh [buildozer android debug args...]
#
# Environment:
#   CMODS                   Workspace root (default: directory containing this script)
#   PYDISPLAY_ANDROID_DIR   pydisplay_android checkout (default: $CMODS/pydisplay_android)
#   MANIFEST                frozen module manifest (default: $CMODS/manifest.py)
#   ANDROID_BUILD_DIR       staging/buildozer dir (default: $PYDISPLAY_ANDROID_DIR/.cmods_build)
#   VENV_DIR                Host build venv (default: $CMODS/.venv)
#   ANDROID_HOME            Android SDK (default: ~/.buildozer/android/platform/android-sdk)
#   ANDROID_NDK_HOME        Android NDK (auto-detected under $ANDROID_HOME/ndk when unset)
#   JAVA_HOME               JDK for Android tooling (auto-detected from java on PATH when unset)
#
# Runtime deps (usdl2, displaysys, eventsys, graphics, multimer, lvgl-cpython) are installed
# from TestPyPI via p4a PyProjectRecipe wrappers in pydisplay_android/p4a_recipes/.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CMODS="${CMODS:-$SCRIPT_DIR}"
VENV_DIR="${VENV_DIR:-$CMODS/.venv}"
PYDISPLAY_ANDROID_DIR="${PYDISPLAY_ANDROID_DIR:-$CMODS/pydisplay_android}"
MANIFEST="${MANIFEST:-$CMODS/manifest.py}"
ANDROID_BUILD_DIR="${ANDROID_BUILD_DIR:-$PYDISPLAY_ANDROID_DIR/.cmods_build}"
REQUIREMENTS_ANDROID="${REQUIREMENTS_ANDROID:-$CMODS/requirements-android.txt}"
TESTPYPI_INDEX="${TESTPYPI_INDEX:-https://test.pypi.org/simple/}"
PYPI_INDEX="${PYPI_INDEX:-https://pypi.org/simple/}"

APP_DIR="$ANDROID_BUILD_DIR/android_demo"
RECIPE_DIR="$ANDROID_BUILD_DIR/p4a_recipes"

PYTHON="$VENV_DIR/bin/python3"
PIP="$VENV_DIR/bin/pip"
BUILDOZER="$VENV_DIR/bin/buildozer"

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage 0
fi

require_dir() {
    local path=$1
    local label=$2
    [[ -d "$path" ]] || {
        echo "Missing $label: $path" >&2
        exit 1
    }
}

require_file() {
    local path=$1
    local label=$2
    [[ -f "$path" ]] || {
        echo "Missing $label: $path" >&2
        exit 1
    }
}

ensure_build_venv() {
    require_file "$REQUIREMENTS_ANDROID" "requirements-android.txt"
    if [[ ! -x "$PYTHON" ]]; then
        echo "==> Creating build venv at $VENV_DIR"
        python3 -m venv "$VENV_DIR"
    fi
    echo "==> Installing Android build Python deps in $VENV_DIR"
    "$PIP" install -q -U pip setuptools wheel
    "$PIP" install -q -r "$REQUIREMENTS_ANDROID"
    [[ -x "$BUILDOZER" ]] || {
        echo "buildozer not found in $VENV_DIR after pip install" >&2
        exit 1
    }
}

setup_android_env() {
    export BUILDOZER_ANDROID_HOME="${BUILDOZER_ANDROID_HOME:-$HOME/.buildozer/android}"
    export ANDROID_HOME="${ANDROID_HOME:-$BUILDOZER_ANDROID_HOME/platform/android-sdk}"
    export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"

    if [[ -z "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_HOME/ndk" ]]; then
        local ndk
        ndk=$(find "$ANDROID_HOME/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)
        if [[ -n "$ndk" ]]; then
            export ANDROID_NDK_HOME="$ndk"
        fi
    fi

    if [[ -z "${JAVA_HOME:-}" ]] && command -v java >/dev/null 2>&1; then
        JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")
        export JAVA_HOME
    fi

    export PATH="$VENV_DIR/bin:$PATH"
}

ensure_build_venv
setup_android_env

require_dir "$PYDISPLAY_ANDROID_DIR/android_demo" "pydisplay_android android_demo"
require_dir "$PYDISPLAY_ANDROID_DIR/p4a_recipes" "pydisplay_android p4a_recipes"
require_file "$MANIFEST" "cmods manifest"

rm -rf "$APP_DIR" "$RECIPE_DIR"
mkdir -p "$APP_DIR" "$RECIPE_DIR"

# Stage the pydisplay_android demo so manifest modules can be baked into the APK
# without editing the pydisplay_android checkout.
cp "$PYDISPLAY_ANDROID_DIR/android_demo"/*.py "$APP_DIR/"
cp "$PYDISPLAY_ANDROID_DIR/android_demo/buildozer.spec" "$APP_DIR/"
cp -a "$PYDISPLAY_ANDROID_DIR/p4a_recipes/." "$RECIPE_DIR/"

echo "==> Fetching display_driver.py and lv_utils.py from pydisplay on GitHub"
"$PYDISPLAY_ANDROID_DIR/scripts/fetch_pydisplay_addons.sh" "$APP_DIR"

echo "==> Freezing modules from $MANIFEST into $APP_DIR"
"$PYTHON" - "$MANIFEST" "$APP_DIR" <<'PY'
import os
import shutil
import sys
from pathlib import Path

manifest = Path(sys.argv[1]).resolve()
app_dir = Path(sys.argv[2]).resolve()
current_dirs = []
copied = []
skipped = []


def _current_dir():
    return current_dirs[-1]


def _resolve(path):
    expanded = os.path.expandvars(os.path.expanduser(str(path)))
    resolved = Path(expanded)
    if not resolved.is_absolute():
        resolved = _current_dir() / resolved
    return resolved.resolve()


def _copy_py(src, dst_rel):
    src = Path(src)
    dst = app_dir / dst_rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    copied.append(str(dst_rel))


def _copy_package(package_name, base_path=".", files=None):
    base = _resolve(base_path)
    package_root = base / package_name
    if files is None:
        if not package_root.is_dir():
            skipped.append(f"package {package_name!r}: missing {package_root}")
            return
        for src in sorted(package_root.rglob("*.py")):
            if "__pycache__" in src.parts:
                continue
            _copy_py(src, Path(package_name) / src.relative_to(package_root))
        return

    for name in files:
        src = package_root / name
        if src.is_file():
            _copy_py(src, Path(package_name) / name)
        else:
            skipped.append(f"package {package_name!r} file {name!r}: missing {src}")


def include(path, **_kwargs):
    included = _resolve(path)
    if not included.is_file():
        raise FileNotFoundError(included)
    _run_manifest(included)


def package(package_name, base_path=".", files=None, **_kwargs):
    _copy_package(package_name, base_path=base_path, files=files)


def module(file, base_path=".", **_kwargs):
    src = _resolve(Path(base_path) / file)
    if src.is_file():
        _copy_py(src, Path(file))
    else:
        skipped.append(f"module {file!r}: missing {src}")


def freeze(path, script=None, **_kwargs):
    root = _resolve(path)
    if script is not None:
        module(script, base_path=root)
        return
    if not root.is_dir():
        skipped.append(f"freeze path: missing {root}")
        return
    for src in sorted(root.rglob("*.py")):
        if "__pycache__" in src.parts:
            continue
        _copy_py(src, src.relative_to(root))


def require(*_args, **_kwargs):
    skipped.append(f"require{_args!r}: unsupported for Android freeze")


def _noop(*_args, **_kwargs):
    return None


namespace = {
    "__name__": "__manifest__",
    "include": include,
    "package": package,
    "module": module,
    "freeze": freeze,
    "require": require,
    "metadata": _noop,
    "add_library": _noop,
}


def _run_manifest(path):
    path = Path(path).resolve()
    current_dirs.append(path.parent)
    old_file = namespace.get("__file__")
    namespace["__file__"] = str(path)
    try:
        exec(compile(path.read_text(), str(path), "exec"), namespace)
    finally:
        if old_file is None:
            namespace.pop("__file__", None)
        else:
            namespace["__file__"] = old_file
        current_dirs.pop()


_run_manifest(manifest)

report = app_dir / "manifest-freeze-report.txt"
report.write_text(
    "Copied modules:\n"
    + "".join(f"  {name}\n" for name in copied)
    + "\nSkipped entries:\n"
    + "".join(f"  {name}\n" for name in skipped)
)

print(f"Copied {len(copied)} manifest file(s)")
if skipped:
    print(f"Skipped {len(skipped)} manifest entr(y/ies); see {report}")
PY

echo "==> Building Android APK in $APP_DIR"
echo "    venv=$VENV_DIR"
echo "    TestPyPI=$TESTPYPI_INDEX"
echo "    ANDROID_HOME=$ANDROID_HOME"
if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
    echo "    ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
else
    echo "    ANDROID_NDK_HOME=(unset — buildozer may download NDK on first run)"
fi
if [[ -n "${JAVA_HOME:-}" ]]; then
    echo "    JAVA_HOME=$JAVA_HOME"
fi

cd "$APP_DIR"
"$BUILDOZER" android debug "$@"

echo "==> APK output:"
ls -1 "$APP_DIR"/bin/*.apk
