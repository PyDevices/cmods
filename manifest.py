import os


# Find all manifest.py files in immediate subdirectories of the current directory
# and include them.
try:
    include("my-manifest.py")
except Exception:
    pass

# User C module frozen manifests (paths relative to cmods root manifest).
# graphics is provided by the linked C usermod (graphics/micropython.mk), not frozen Python.
try:
    include("lv_micropython_cmod/manifest.py")
except Exception:
    pass

try:
    include("$(PORT_DIR)/variants/pyscript/manifest.py")
except Exception:
    try:
        include("$(BOARD_DIR)/manifest.py")
    except Exception:
        try:
            include("$(PORT_DIR)/boards/manifest.py")
        except Exception:
            try:
                include("$(PORT_DIR)/variants/standard/manifest.py")
            except Exception:
                try:
                    include("$(PORT_DIR)/variants/pyscript/manifest.py")
                except Exception:
                    try:
                        include("$(PORT_DIR)/variants/manifest.py")
                    except Exception:
                        pass
