import os

# PyScript browser builds (webassembly VARIANT=pyscript) need the full frozen stdlib
# from variants/pyscript/manifest.py (pathlib, os, gzip, logging, …). That file
# exists only on the webassembly port; other ports fall through to the chain below.
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
